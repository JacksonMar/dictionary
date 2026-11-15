// I4.1 (IOS_PLAN §7 I4, §4, §8, DI13, DI18): «Add to Dictionary» (Siri / Shortcuts). The AppIntents wrapper
// `AddToDictionaryIntent` only forwards to `AddToDictionaryRunner`, so the runner is tested here over a real
// `AppContainer` (temporary directory) with the real `URLSessionTransport` → `ClaudeLookupService` stack and
// `MockURLProtocol` counting requests: a new word = 1 request, a duplicate = 0, empty text = 0 and no load,
// the Language parameter becomes the hint sentence in the same system prompt, and a slow lookup answers
// "still being translated" after the timeout while the add task keeps running (never cancelled).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import VocabCore
@testable import VocabMobile

/// Controlled timeout clock: `sleep` returns only after `release()` or when the sleeping task is cancelled.
/// Records the requested durations and how many sleeps ended by cancellation.
final class GatedIntentSleeper: IntentSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledIDs: Set<UUID> = []
    private var released = false
    private var requested: [TimeInterval] = []
    private var cancellations = 0

    var requestedSeconds: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    var cancelledCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cancellations
    }

    var waitingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    func sleep(seconds: TimeInterval) async {
        let id = UUID()
        record(seconds)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released || cancelledIDs.contains(id) {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            cancelledIDs.insert(id)
            cancellations += 1
            let waiting = waiters.removeValue(forKey: id)
            lock.unlock()
            waiting?.resume()
        }
    }

    private func record(_ seconds: TimeInterval) {
        lock.lock()
        requested.append(seconds)
        lock.unlock()
    }

    /// The timeout "elapses" for every current and future sleeper.
    func release() {
        lock.lock()
        released = true
        let waiting = Array(waiters.values)
        waiters = [:]
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}

/// Blocks the mocked HTTP reply until `open()` (keeps the Claude request in flight past the timeout).
final class HTTPGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false

    func wait() {
        semaphore.wait()
    }

    func open() {
        lock.lock()
        let first = !opened
        opened = true
        lock.unlock()
        // Wake the blocked request once; later requests (none expected) are not blocked forever either.
        if first {
            for _ in 0..<16 { semaphore.signal() }
        }
    }
}

final class AddToDictionaryIntentTests: XCTestCase {
    private var savedCurrentLanguage: AppLanguage = .default

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        savedCurrentLanguage = L10n.current
    }

    override func tearDown() {
        MockURLProtocol.reset()
        L10n.setCurrent(savedCurrentLanguage)
        super.tearDown()
    }

    // MARK: - Helpers

    private static func hintSentence(name: String, code: String) -> String {
        "The user stated the text is \(name); set source_language to \"\(code)\" unless the text is clearly not \(name)."
    }

    private static let italianHint = hintSentence(name: "Italian", code: "it")
    private static let englishHint = hintSentence(name: "English", code: "en")

    /// Italian «come» → top level `how`, Italian variant `come`.
    private static let comeItalianJSON: String = {
        var top = MobileClaudeFixtures.object(word: "how", translations: ["як"])
        top["source_language"] = "it"
        top["variants"] = ["it": MobileClaudeFixtures.object(word: "come", translations: ["як"])]
        return MobileClaudeFixtures.jsonString(top)
    }()

    private static func systemText(_ request: MockURLProtocol.RecordedRequest) -> String {
        let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        return object?["system"] as? String ?? ""
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private struct Fixture {
        let container: AppContainer
        let backgroundTasks: NoopBackgroundTaskRunner
        let store: CountingDictionaryStore?
    }

    /// Container over a temporary directory (or a counting fake store), API key present, mocked transport.
    @MainActor
    private func makeFixture(
        entries: [Entry] = [],
        interfaceLanguage: AppLanguage = .en,
        countingStore: CountingDictionaryStore? = nil
    ) throws -> Fixture {
        let directory = makeTemporaryDirectory(self)
        if !entries.isEmpty, countingStore == nil {
            try writeDictionary(entries, to: directory)
        }
        let backgroundTasks = NoopBackgroundTaskRunner()
        let container = AppContainer(
            paths: AppPaths(applicationSupportDirectory: directory),
            settings: InMemorySettingsStore(interfaceLanguage: interfaceLanguage),
            store: countingStore,
            secrets: InMemorySecretStore(values: [.anthropicAPIKey: MobileClaudeFixtures.apiKey]),
            transport: URLSessionTransport(session: MockURLProtocol.makeSession()),
            backgroundTasks: backgroundTasks
        )
        return Fixture(container: container, backgroundTasks: backgroundTasks, store: countingStore)
    }

    private static func readyHouse() -> Entry {
        makeTestEntry(
            "house",
            translations: ["будинок", "дім"],
            createdOffset: 0,
            variants: ["it": EntryVariant(word: "casa", translations: ["дім"], status: .ready,
                                          sourceKey: TextNormalizer.key("house"))]
        )
    }

    /// Polls `condition` on the main actor (the runner's tasks run there too).
    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    // MARK: - I4.1

    @MainActor
    func testPerformAddsWordWithOneRequest() async throws {
        let fixture = try makeFixture()
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        let sleeper = GatedIntentSleeper()
        let runner = AddToDictionaryRunner(container: fixture.container, sleeper: sleeper)

        let response = await runner.run(text: "house", language: nil)

        guard case .completed(.added(let entry)) = response.result else {
            return XCTFail("expected .completed(.added), got \(response.result)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "new word → exactly one request (§8)")
        XCTAssertEqual(entry.word, "house")
        XCTAssertEqual(entry.status, .ready)
        XCTAssertTrue(response.dialog.hasPrefix("Added: house — "), response.dialog)
        XCTAssertTrue(response.dialog.contains("будинок"), response.dialog)
        XCTAssertEqual(response.dialog,
                       NotificationText.make(for: .added(entry), selection: "house", language: .en).singleLine)

        // Saved through the shared repository (same one the UI uses).
        let stored = await fixture.container.repository.allEntries()
        XCTAssertEqual(stored.map(\.word), ["house"])
        XCTAssertEqual(stored.first?.status, .ready)

        // No Language parameter → no hint sentence.
        let system = Self.systemText(try XCTUnwrap(MockURLProtocol.requests.first))
        XCTAssertFalse(system.contains("The user stated"), "no hint without a Language parameter")

        // The 8-second timeout was armed and, once the answer came, the timer was cancelled (no leaked sleeper).
        XCTAssertEqual(sleeper.requestedSeconds, [AddToDictionaryRunner.slowLookupTimeout])
        XCTAssertEqual(AddToDictionaryRunner.slowLookupTimeout, 8)
        let timerCancelled = await waitUntil { sleeper.cancelledCount == 1 }
        XCTAssertTrue(timerCancelled, "timer must be cancelled after the add finished")

        // DI18: the add ran inside one background task, and the task was ended.
        XCTAssertEqual(fixture.backgroundTasks.startedNames, [AddToDictionaryRunner.backgroundTaskName])
        XCTAssertEqual(AddToDictionaryRunner.backgroundTaskName, "VocabIntentAddWord")
        XCTAssertTrue(fixture.backgroundTasks.activeTokens.isEmpty, "background task balanced")
    }

    @MainActor
    func testPerformDuplicateNoRequest() async throws {
        let house = Self.readyHouse()
        let fixture = try makeFixture(entries: [house])
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        let runner = AddToDictionaryRunner(container: fixture.container, sleeper: GatedIntentSleeper())

        for (text, language) in [("house", nil), (" House ", VoiceLanguageAppEnum.english),
                                 ("casa", .italian), ("Casa", .auto)] as [(String, VoiceLanguageAppEnum?)] {
            let response = await runner.run(text: text, language: language)
            guard case .completed(.duplicate(let existing)) = response.result else {
                XCTFail("\(text): expected .duplicate, got \(response.result)")
                continue
            }
            XCTAssertEqual(existing.id, house.id)
            XCTAssertTrue(response.dialog.hasPrefix("Already in the dictionary"), "\(text): \(response.dialog)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "duplicate by any dedup key → 0 requests (§8)")
        let stored = await fixture.container.repository.allEntries()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(fixture.backgroundTasks.activeTokens.isEmpty)
    }

    @MainActor
    func testEmptyTextRejectedDialog() async throws {
        let store = CountingDictionaryStore()
        let fixture = try makeFixture(countingStore: store)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        let sleeper = GatedIntentSleeper()
        let runner = AddToDictionaryRunner(container: fixture.container, sleeper: sleeper)

        for text in [nil, "", "   ", "\n\t"] as [String?] {
            let response = await runner.run(text: text, language: .italian)
            XCTAssertEqual(response.result, .completed(.rejected(.empty)), "\(String(describing: text))")
            XCTAssertEqual(response.dialog, "Not added: there is no word. Say or type a word or a short phrase.")
        }

        // Other rejections: the shared rejection text, also without load / request.
        let long = await runner.run(text: "one two three four five six seven eight nine", language: nil)
        XCTAssertEqual(long.result, .completed(.rejected(.tooManyWords(max: 8))))
        XCTAssertTrue(long.dialog.hasPrefix("Not added"), long.dialog)
        let digits = await runner.run(text: "12345", language: nil)
        XCTAssertEqual(digits.result, .completed(.rejected(.noLetters)))

        XCTAssertEqual(store.loadCount, 0, "rejected text must not load the dictionary")
        XCTAssertFalse(fixture.container.isLoaded)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertTrue(fixture.backgroundTasks.startedNames.isEmpty, "no background task for rejected text")
        XCTAssertTrue(sleeper.requestedSeconds.isEmpty, "no timeout armed for rejected text")
        XCTAssertNil(runner.lastAddTask)
    }

    @MainActor
    func testItalianParameterPassedAsHint() async throws {
        let fixture = try makeFixture()
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(Self.comeItalianJSON)])
        let runner = AddToDictionaryRunner(container: fixture.container, sleeper: GatedIntentSleeper())

        let response = await runner.run(text: "come", language: .italian)

        guard case .completed(.added(let entry)) = response.result else {
            return XCTFail("expected .added, got \(response.result)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "the hint adds no request")
        let system = Self.systemText(try XCTUnwrap(MockURLProtocol.requests.first))
        XCTAssertEqual(Self.occurrences(of: Self.italianHint, in: system), 1, "Italian hint sentence once in system")
        XCTAssertFalse(system.contains(Self.englishHint))
        XCTAssertEqual(entry.sourceLanguage, "it")
        XCTAssertEqual(entry.variants?["it"]?.word, "come")

        // English parameter → the English sentence.
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        _ = await runner.run(text: "house", language: .english)
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        let englishSystem = Self.systemText(MockURLProtocol.requests[1])
        XCTAssertEqual(Self.occurrences(of: Self.englishHint, in: englishSystem), 1)
        XCTAssertFalse(englishSystem.contains(Self.italianHint))

        // Auto → no hint at all.
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.combinedJSON(
            word: "window", translations: ["вікно"], italian: "finestra", italianTranslations: ["вікно"]
        ))])
        _ = await runner.run(text: "window", language: .auto)
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
        XCTAssertFalse(Self.systemText(MockURLProtocol.requests[2]).contains("The user stated"))
    }

    @MainActor
    func testSlowLookupReturnsQueuedDialog() async throws {
        let fixture = try makeFixture()
        let gate = HTTPGate()
        defer { gate.open() }
        let reply = MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)
        MockURLProtocol.setHandler { _ in
            gate.wait()
            return reply
        }
        let sleeper = GatedIntentSleeper()
        let runner = AddToDictionaryRunner(container: fixture.container, sleeper: sleeper)

        let responseTask = Task { @MainActor in
            await runner.run(text: "house", language: nil)
        }
        // The request is in flight and the timer is waiting; then the timeout "elapses".
        let inFlight = await waitUntil { MockURLProtocol.requestCount == 1 && sleeper.waitingCount == 1 }
        XCTAssertTrue(inFlight, "request should be in flight with the timer armed")
        sleeper.release()

        let response = await responseTask.value
        XCTAssertEqual(response.result, .translating(word: "house"))
        XCTAssertEqual(response.dialog,
                       "Saved “house”. It is still being translated — open VocabApp to see the result.")

        // The entry is already saved as pending (DI18) while the request is still running.
        let pending = await fixture.container.repository.allEntries()
        XCTAssertEqual(pending.map(\.word), ["house"])
        XCTAssertEqual(pending.first?.status, .pending)
        XCTAssertEqual(fixture.backgroundTasks.activeTokens.count, 1, "background task still open while translating")

        // The add task is NOT cancelled by the timeout answer; it finishes with the one request.
        let addTask = try XCTUnwrap(runner.lastAddTask)
        XCTAssertFalse(addTask.isCancelled, "timeout must not cancel the add task")
        gate.open()
        let outcome = await addTask.value
        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertFalse(addTask.isCancelled)
        XCTAssertEqual(entry.status, .ready)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "still exactly one request, no retry/duplicate")
        let stored = await fixture.container.repository.allEntries()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.status, .ready)
        XCTAssertEqual(fixture.backgroundTasks.startedNames, [AddToDictionaryRunner.backgroundTaskName])
        XCTAssertTrue(fixture.backgroundTasks.activeTokens.isEmpty, "background task ended after the add finished")
    }

    @MainActor
    func testLoadFailureDialogSavesNothing() async throws {
        let store = CountingDictionaryStore(failure: MobileTestError(reason: "disk is on fire"))
        let fixture = try makeFixture(countingStore: store)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        let sleeper = GatedIntentSleeper()
        let runner = AddToDictionaryRunner(container: fixture.container, sleeper: sleeper)

        let response = await runner.run(text: "house", language: nil)

        guard case .loadFailed(let message) = response.result else {
            return XCTFail("expected .loadFailed, got \(response.result)")
        }
        XCTAssertTrue(message.contains("disk is on fire"), message)
        XCTAssertTrue(response.dialog.hasPrefix("The dictionary could not be opened, so the word was not saved: "),
                      response.dialog)
        XCTAssertTrue(response.dialog.contains("disk is on fire"), response.dialog)
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertEqual(store.saveCount, 0, "nothing saved")
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertTrue(fixture.backgroundTasks.startedNames.isEmpty)
        XCTAssertNil(runner.lastAddTask)
        XCTAssertTrue(sleeper.requestedSeconds.isEmpty)

        // The failure is cached (single-flight, §4): a second run does not reload.
        let again = await runner.run(text: "window", language: nil)
        guard case .loadFailed = again.result else { return XCTFail("expected .loadFailed, got \(again.result)") }
        XCTAssertEqual(store.loadCount, 1)
    }

    @MainActor
    func testDialogLanguageFollowsAppInterfaceLanguage() async throws {
        // The process-global L10n says English; the app's interface setting says Ukrainian → Ukrainian dialogs.
        L10n.setCurrent(.en)
        let fixture = try makeFixture(interfaceLanguage: .uk)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        let runner = AddToDictionaryRunner(container: fixture.container, sleeper: GatedIntentSleeper())

        let added = await runner.run(text: "house", language: nil)
        XCTAssertTrue(added.dialog.hasPrefix("Додано: house — "), added.dialog)
        let duplicate = await runner.run(text: "house", language: nil)
        XCTAssertTrue(duplicate.dialog.hasPrefix("Вже є в словнику"), duplicate.dialog)
        let empty = await runner.run(text: " ", language: nil)
        XCTAssertEqual(empty.dialog, "Не додано: немає слова. Скажіть або введіть слово чи коротку фразу.")
        XCTAssertEqual(AddToDictionaryRunner.dialogText(for: .translating(word: "pane"), selection: "pane", language: .uk),
                       "Збережено «pane». Переклад ще триває — відкрийте VocabApp, щоб побачити результат.")
        XCTAssertTrue(AddToDictionaryRunner.dialogText(for: .loadFailed(message: "x"), selection: nil, language: .uk)
            .hasPrefix("Не вдалося відкрити словник"))

        // Interface language changed in Settings → next run answers in English, whatever L10n.current says.
        L10n.setCurrent(.uk)
        fixture.container.settings.interfaceLanguage = .en
        let englishDuplicate = await runner.run(text: "house", language: nil)
        XCTAssertTrue(englishDuplicate.dialog.hasPrefix("Already in the dictionary"), englishDuplicate.dialog)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    @MainActor
    func testConcurrentRunsOfSameWordMakeOneRequest() async throws {
        // §4: parallel invocations (e.g. Siri + Shortcuts, or intent + inbox ingest) → at most 1 request per word.
        let fixture = try makeFixture()
        MockURLProtocol.setDelay(0.2)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        let first = AddToDictionaryRunner(container: fixture.container, sleeper: GatedIntentSleeper())
        let second = AddToDictionaryRunner(container: fixture.container, sleeper: GatedIntentSleeper())

        async let a = first.run(text: "house", language: nil)
        async let b = second.run(text: "House", language: .english)
        let results = await [a.result, b.result]

        XCTAssertEqual(MockURLProtocol.requestCount, 1, "\(results)")
        let stored = await fixture.container.repository.allEntries()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(fixture.backgroundTasks.activeTokens.isEmpty)
    }
}
