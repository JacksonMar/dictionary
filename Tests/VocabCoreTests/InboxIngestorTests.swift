import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VocabCore

/// Реальний стек Claude (`M7Stack`: `ClaudeLookupService` + `MockURLProtocol`) + inbox у тому самому тимчасовому
/// каталозі (окрема `RecordingInboxFileSystem`, тож збої словника й inbox ін'єктуються незалежно).
struct InboxIngestStack {
    let stack: M7Stack
    let inboxFileSystem: RecordingInboxFileSystem
    let store: InboxStore
    let ingestor: InboxIngestor
    let sink: CapturingLogSink

    static func make(
        seed: [Entry] = [],
        registry: LanguagePairRegistry = LanguagePairRegistry(pairs: [.englishUkrainian]),
        reusing previous: InboxIngestStack? = nil
    ) async throws -> InboxIngestStack {
        let stack: M7Stack
        let inboxFileSystem: RecordingInboxFileSystem
        if let previous {
            // «Перезапуск застосунку»: новий репозиторій/черга/інжестор над тими самими файлами.
            stack = try await M7Stack.make(fixture: previous.stack.fixture, registry: registry)
            inboxFileSystem = previous.inboxFileSystem
        } else {
            stack = try await M7Stack.make(seed: seed, registry: registry)
            inboxFileSystem = RecordingInboxFileSystem()
        }
        let store = InboxStore(
            directory: stack.fixture.directory.url.appendingPathComponent("Inbox", isDirectory: true),
            fileSystem: inboxFileSystem
        )
        let sink = CapturingLogSink()
        let ingestor = InboxIngestor(
            store: store,
            repository: stack.repository,
            processor: stack.queue,
            registry: registry,
            settings: stack.lookup.settings,
            logger: RedactingLogger(sink: sink, secretsProvider: { [] })
        )
        return InboxIngestStack(stack: stack, inboxFileSystem: inboxFileSystem, store: store, ingestor: ingestor,
                                sink: sink)
    }

    func enqueue(_ texts: [String], hint: String? = nil) throws {
        for (index, text) in texts.enumerated() {
            try store.enqueue(InboxItem(text: text, languageHint: hint, source: .share,
                                        createdAt: TestDates.reference.addingTimeInterval(TimeInterval(index))))
        }
    }

    func inboxFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? [])
            .filter { InboxStore.isItemFileName($0) }
            .sorted()
    }

    func entries() async -> [Entry] {
        await stack.repository.allEntries()
    }

    /// Скільки разів інжест запускав чергу (`Queue run started: trigger=inbox`).
    var inboxQueueRuns: Int {
        sink.lines.filter { $0.message == QueueLog.started(.inbox) }.count
    }

    func remove() {
        stack.remove()
    }
}

enum InboxIngestFixtures {
    /// Відповідь моделі на будь-яке слово: верхній рівень = виділений текст запиту (1 запит на слово).
    static func echoReply(_ request: MockURLProtocol.RecordedRequest) -> MockURLProtocol.Reply {
        let word = M7.selection(request) ?? "unknown"
        return ClaudeFixtures.ok(M7.combinedJSON(
            sourceLanguage: "en",
            top: M7.object(word: word, translations: ["переклад \(word)"]),
            variants: ["it": M7.italianObject(for: word)]
        ))
    }

    static func requestedWords() -> [String] {
        MockURLProtocol.requests.compactMap { M7.selection($0) }
    }
}

/// I3.2 (IOS_PLAN §3.3, §4, DI7, DI9): інжест inbox у словник — pending → один `processAll`, дублі без запитів,
/// відхилені рахуються, збій сховища лишає файл, ідемпотентність після падіння, підказка мови, single-flight.
final class InboxIngestorTests: XCTestCase {
    private var stacks: [InboxIngestStack] = []
    private var extraFixtures: [StoreFixture] = []

    override func setUp() async throws {
        try await super.setUp()
        pinInterfaceLanguage(.en)
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        stacks.forEach { $0.remove() }
        stacks = []
        extraFixtures.forEach { $0.directory.remove() }
        extraFixtures = []
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeStack(
        seed: [Entry] = [],
        registry: LanguagePairRegistry = LanguagePairRegistry(pairs: [.englishUkrainian]),
        reusing previous: InboxIngestStack? = nil
    ) async throws -> InboxIngestStack {
        let made = try await InboxIngestStack.make(seed: seed, registry: registry, reusing: previous)
        stacks.append(made)
        return made
    }

    // MARK: - I3.2 required

    func testNewWordsQueuedThenOneProcessAll() async throws {
        let inbox = try await makeStack()
        MockURLProtocol.setHandler(InboxIngestFixtures.echoReply)
        try inbox.enqueue(["serendipity", "  ubiquitous \n", "ephemeral"])

        let report = await inbox.ingestor.ingest()

        XCTAssertEqual(report, InboxIngestReport(queued: 3, duplicates: 0, rejected: 0, failed: 0))
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "1 request per new word")
        XCTAssertEqual(Set(InboxIngestFixtures.requestedWords()), ["serendipity", "ubiquitous", "ephemeral"])
        XCTAssertEqual(inbox.inboxQueueRuns, 1, "exactly one processAll(.inbox) per pass:\n\(inbox.sink.text)")
        XCTAssertEqual(
            inbox.sink.lines.filter { $0.message.hasPrefix("Queue run started") }.count, 1,
            "no per-item queue runs"
        )
        let entries = await inbox.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.allSatisfy { $0.status == .ready }, "\(entries.map { ($0.word, $0.status) })")
        XCTAssertEqual(Set(entries.map(\.word)), ["serendipity", "ubiquitous", "ephemeral"], "text trimmed")
        XCTAssertTrue(inbox.inboxFileNames().isEmpty, "processed files removed")
        XCTAssertTrue(inbox.sink.text.contains(InboxLog.finished(report)))
        XCTAssertFalse(inbox.sink.text.contains("serendipity"), "log carries counters only, never words")

        // Порожній inbox → порожній звіт, жодного прогону черги й жодного запиту.
        let empty = await inbox.ingestor.ingest()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(inbox.inboxQueueRuns, 1)
        XCTAssertEqual(MockURLProtocol.requestCount, 3)

        // Записи pending зберігаються до запиту: офлайн → лишаються pending (нічого не губиться), файл прибрано.
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.notConnectedToInternet)])
        try inbox.enqueue(["quaint"])
        let offline = await inbox.ingestor.ingest()
        XCTAssertEqual(offline.queued, 1)
        XCTAssertEqual(inbox.inboxQueueRuns, 2)
        let quaint = await inbox.entries().first { $0.word == "quaint" }
        XCTAssertEqual(quaint?.status, .pending)
        XCTAssertTrue(inbox.inboxFileNames().isEmpty)
    }

    func testDuplicateRemovedWithoutRequest() async throws {
        let existing = M7.entry(word: "run")
        let inbox = try await makeStack(seed: [existing])
        MockURLProtocol.setHandler(InboxIngestFixtures.echoReply)
        try inbox.enqueue(["run", "RUN "])

        let report = await inbox.ingestor.ingest()

        XCTAssertEqual(report, InboxIngestReport(queued: 0, duplicates: 2, rejected: 0, failed: 0))
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "duplicate → 0 requests")
        XCTAssertEqual(inbox.inboxQueueRuns, 0, "nothing queued → no queue run")
        XCTAssertTrue(inbox.inboxFileNames().isEmpty, "duplicate files removed")
        let entries = await inbox.entries()
        XCTAssertEqual(entries, [existing], "existing entry untouched")

        // Дубль разом з новим словом: 1 запит (лише нове слово).
        try inbox.enqueue(["run", "brisk"])
        let mixed = await inbox.ingestor.ingest()
        XCTAssertEqual(mixed, InboxIngestReport(queued: 1, duplicates: 1))
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(InboxIngestFixtures.requestedWords(), ["brisk"])
    }

    func testRejectedCounted() async throws {
        let inbox = try await makeStack()
        MockURLProtocol.setHandler(InboxIngestFixtures.echoReply)
        let tooLong = String(repeating: "a", count: 121)
        let nineWords = "one two three four five six seven eight nine"
        try inbox.enqueue(["   \n", tooLong, nineWords, "12345", "thrive"])
        try Data("not json".utf8).write(to: inbox.store.directory.appendingPathComponent("0-corrupt.json"))

        let report = await inbox.ingestor.ingest()

        XCTAssertEqual(report, InboxIngestReport(queued: 1, duplicates: 0, rejected: 5, failed: 0))
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "rejected texts never reach Claude")
        XCTAssertEqual(InboxIngestFixtures.requestedWords(), ["thrive"])
        XCTAssertTrue(inbox.inboxFileNames().isEmpty, "rejected files removed / corrupt moved to Rejected")
        let rejectedDir = (try? FileManager.default.contentsOfDirectory(atPath: inbox.store.rejectedDirectory.path)) ?? []
        XCTAssertEqual(rejectedDir, ["0-corrupt.json"])
        let words = await inbox.entries().map(\.word)
        XCTAssertEqual(words, ["thrive"])

        // Межі валідації: рівно 120 символів і рівно 8 слів — приймаються.
        MockURLProtocol.reset()
        MockURLProtocol.setHandler(InboxIngestFixtures.echoReply)
        try inbox.enqueue([String(repeating: "b", count: 120), "one two three four five six seven eight"])
        let edge = await inbox.ingestor.ingest()
        XCTAssertEqual(edge, InboxIngestReport(queued: 2))
    }

    func testStorageFailureKeepsFile() async throws {
        let inbox = try await makeStack()
        MockURLProtocol.setHandler(InboxIngestFixtures.echoReply)
        try inbox.enqueue(["brisk", "wane", "thrive"])
        let before = inbox.inboxFileNames()
        XCTAssertEqual(before.count, 3)
        inbox.stack.fixture.fileSystem.fail(.writeData)   // dictionary.json can't be saved

        let report = await inbox.ingestor.ingest()

        XCTAssertEqual(report, InboxIngestReport(queued: 0, duplicates: 0, rejected: 0, failed: 3),
                       "pass stops at the first storage error; failed counts every item left in the inbox")
        XCTAssertEqual(inbox.inboxFileNames(), before, "files stay in the inbox for the next activation")
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertEqual(inbox.inboxQueueRuns, 0)
        let none = await inbox.entries()
        XCTAssertTrue(none.isEmpty, "failed add is not kept in memory")

        // Диск відновився → наступний прохід забирає все (без дублів від невдалої спроби).
        inbox.stack.fixture.fileSystem.stopFailing()
        let retry = await inbox.ingestor.ingest()
        XCTAssertEqual(retry, InboxIngestReport(queued: 3))
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
        XCTAssertTrue(inbox.inboxFileNames().isEmpty)
        let words = await inbox.entries().map(\.word)
        XCTAssertEqual(Set(words), ["brisk", "wane", "thrive"])

        // Каталог inbox не читається → failed = 1, без падіння.
        inbox.inboxFileSystem.fail(.contentsOfDirectory)
        let unreadable = await inbox.ingestor.ingest()
        XCTAssertEqual(unreadable, InboxIngestReport(failed: 1))
    }

    func testCrashBetweenAddAndRemoveIsIdempotent() async throws {
        let first = try await makeStack()
        MockURLProtocol.setHandler(InboxIngestFixtures.echoReply)
        try first.enqueue(["serendipity"])
        // «Падіння» між add і видаленням файлу: видалення не відбувається.
        first.inboxFileSystem.fail(.removeItem)

        let report = await first.ingestor.ingest()

        XCTAssertEqual(report.queued, 1)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(first.inboxFileNames().count, 1, "file survived the 'crash'")

        // Перезапуск: новий репозиторій з диска, новий інжестор, той самий inbox.
        first.inboxFileSystem.stopFailing()
        let relaunched = try await makeStack(reusing: first)
        let second = await relaunched.ingestor.ingest()

        XCTAssertEqual(second, InboxIngestReport(queued: 0, duplicates: 1, rejected: 0, failed: 0))
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "second pass: 0 requests")
        XCTAssertEqual(relaunched.inboxQueueRuns, 0)
        XCTAssertTrue(relaunched.inboxFileNames().isEmpty, "duplicate file removed")
        let entries = await relaunched.entries()
        XCTAssertEqual(entries.map(\.word), ["serendipity"])
        XCTAssertEqual(entries.first?.status, .ready)

        let third = await relaunched.ingestor.ingest()
        XCTAssertTrue(third.isEmpty)
    }

    func testHintStoredAsLanguageHint() async throws {
        let inbox = try await makeStack()
        // Офлайн: запис лишається pending, тож підказку видно в збереженому записі (на ready вона очищується).
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.notConnectedToInternet)])
        try inbox.store.enqueue(InboxItem(text: "come", languageHint: "it", source: .share,
                                          createdAt: TestDates.reference))
        try inbox.store.enqueue(InboxItem(text: "pane", languageHint: "fr", source: .share,
                                          createdAt: TestDates.reference.addingTimeInterval(1)))
        try inbox.store.enqueue(InboxItem(text: "casa", languageHint: nil, source: .share,
                                          createdAt: TestDates.reference.addingTimeInterval(2)))

        let report = await inbox.ingestor.ingest()

        XCTAssertEqual(report.queued, 3)
        let entries = await inbox.entries()
        let byWord = Dictionary(uniqueKeysWithValues: entries.map { ($0.word, $0) })
        XCTAssertEqual(byWord["come"]?.languageHint, "it", "allowed hint stored on the pending entry")
        XCTAssertNil(byWord["pane"]?.languageHint, "hint outside allowedSourceLanguages dropped")
        XCTAssertNil(byWord["casa"]?.languageHint)
        let onDisk = try inbox.stack.entriesOnDisk().first { $0.word == "come" }
        XCTAssertEqual(onDisk?.languageHint, "it", "persisted")

        // Підказка доходить до Claude тим самим (єдиним) запитом на слово.
        let comeRequest = MockURLProtocol.requests.first { M7.selection($0) == "come" }
        XCTAssertTrue(M7.systemText(try XCTUnwrap(comeRequest)).contains("Italian"))
        let paneRequest = MockURLProtocol.requests.first { M7.selection($0) == "pane" }
        XCTAssertFalse(M7.systemText(try XCTUnwrap(paneRequest)).contains("The user stated the text is"))
    }

    func testConcurrentIngestCallsShareOneRun() async throws {
        let fixture = try StoreFixture()
        extraFixtures.append(fixture)
        let repository = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)
        _ = try await repository.load()
        let gate = Gate()
        let lookup = StubLookupService([.success(ClaudeFixtures.expectedRunResult)], gate: gate)
        let registry = LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly])
        let processor = EntryProcessor(repository: repository, lookup: lookup, registry: registry,
                                       dateProvider: fixture.dateProvider)
        let queue = PendingQueueProcessor(repository: repository, processor: processor,
                                          dateProvider: fixture.dateProvider)
        let inboxFS = RecordingInboxFileSystem()
        let store = InboxStore(directory: fixture.directory.url.appendingPathComponent("Inbox"), fileSystem: inboxFS)
        let ingestor = InboxIngestor(store: store, repository: repository, processor: queue, registry: registry,
                                     settings: InMemorySettingsStore())
        try store.enqueue(InboxItem(text: "run", createdAt: TestDates.reference))

        let firstCall = Task { await ingestor.ingest() }
        await waitUntil { lookup.callCount == 1 }      // перший прохід стоїть у processAll
        let scansBefore = inboxFS.calls(.contentsOfDirectory).count
        // Новий файл посеред проходу + повторні `.active`.
        try store.enqueue(InboxItem(text: "walk", createdAt: TestDates.reference.addingTimeInterval(1)))
        let secondCall = Task { await ingestor.ingest() }
        let thirdCall = Task { await ingestor.ingest() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(lookup.callCount, 1, "joined calls start no second pass")
        XCTAssertEqual(inboxFS.calls(.contentsOfDirectory).count, scansBefore + 1,
                       "only the enqueue scanned the directory; joined calls did not scan")
        gate.open()

        let reports = [await firstCall.value, await secondCall.value, await thirdCall.value]
        XCTAssertEqual(reports, Array(repeating: InboxIngestReport(queued: 1), count: 3), "same report for all")
        XCTAssertEqual(lookup.callCount, 1)
        XCTAssertEqual(try store.pendingItems().map(\.item.text), ["walk"], "late file waits for the next pass")
        let entryCount = await repository.allEntries().count
        XCTAssertEqual(entryCount, 1)

        // Після завершення `current` скинуто — наступний виклик запускає новий прохід і бере пізній файл.
        let next = await ingestor.ingest()
        XCTAssertEqual(next.queued + next.duplicates, 1)
        XCTAssertGreaterThanOrEqual(lookup.callCount, next.queued == 1 ? 2 : 1)
        XCTAssertTrue(try store.pendingItems().isEmpty)
    }

    func testIngestConcurrentWithAddWordMakesOneRequestPerWord() async throws {
        for iteration in 0..<5 {
            MockURLProtocol.reset()
            MockURLProtocol.setHandler(InboxIngestFixtures.echoReply)
            let inbox = try await makeStack()
            try inbox.enqueue(["run", "house", "dog"])
            let addWord = inbox.stack.addWord
            let queue = inbox.stack.queue
            let ingestor = inbox.ingestor

            async let ingestA = ingestor.ingest()
            async let addRun = addWord.execute(rawText: "run")
            async let addHouse = addWord.execute(rawText: "house", sourceLanguageHint: "en")
            async let foreground = queue.processAll(ignoringBackoff: false)
            async let ingestB = ingestor.ingest()
            async let addDog = addWord.execute(rawText: "dog")
            _ = await (ingestA, addRun, addHouse, foreground, ingestB, addDog)

            let requested = InboxIngestFixtures.requestedWords()
            XCTAssertEqual(MockURLProtocol.requestCount, 3, "iteration \(iteration): \(requested)")
            XCTAssertEqual(requested.sorted(), ["dog", "house", "run"], "iteration \(iteration)")
            let entries = await inbox.entries()
            XCTAssertEqual(entries.count, 3, "iteration \(iteration)")
            XCTAssertEqual(Set(entries.map(\.word)), ["run", "house", "dog"])
            XCTAssertTrue(entries.allSatisfy { $0.status == .ready }, "iteration \(iteration)")
            XCTAssertTrue(inbox.inboxFileNames().isEmpty, "iteration \(iteration)")

            // Повторний інжест / додавання тих самих слів — 0 запитів.
            let again = await ingestor.ingest()
            XCTAssertTrue(again.isEmpty)
            _ = await addWord.execute(rawText: "dog")
            XCTAssertEqual(MockURLProtocol.requestCount, 3)
        }
    }
}
