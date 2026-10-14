import Foundation
import XCTest
@testable import VocabCore

/// M3.2 — `ServiceRequestHandler` поверх реального `AddWordUseCase`, репозиторію в тимчасовому каталозі,
/// черги і `StubLookupService` (без мережі): додавання, дубль, офлайн, помилки, відхилення, D17.
final class ServiceRequestHandlerTests: XCTestCase {
    private var harness: QueueHarness?

    override func tearDown() {
        harness?.remove()
        harness = nil
        super.tearDown()
    }

    private func make(
        _ script: [Result<LookupResult, ClaudeError>],
        gate: Gate? = nil
    ) async throws -> (QueueHarness, ServiceRequestHandler) {
        let h = try await QueueHarness.make(script, gate: gate)
        harness?.remove()
        harness = h
        let useCase = AddWordUseCase(
            repository: h.repository,
            processor: h.queue,
            settings: InMemorySettingsStore(),
            registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly])
        )
        return (h, ServiceRequestHandler(useCase: useCase))
    }

    private func persistedStatuses(_ h: QueueHarness) throws -> [EntryStatus] {
        try h.fixture.store.load().file.entries.map(\.status)
    }

    func testNewWordAddedReady() async throws {
        let (h, handler) = try await make([.success(ClaudeFixtures.expectedRunResult)])

        let response = await handler.handle(text: "  run.\n")

        guard case .added(let entry) = response.outcome else { return XCTFail("expected added, got \(response)") }
        XCTAssertEqual(entry.word, "run")
        XCTAssertEqual(entry.status, .ready)
        XCTAssertEqual(entry.translations, ["бігти", "керувати"])
        XCTAssertNil(entry.lastError)
        XCTAssertEqual(response.notification, NotificationContent(title: "Додано", body: "Додано: run — бігти, керувати"))
        XCTAssertEqual(h.lookup.texts, ["run"], "cleaned text sent to lookup exactly once")
        XCTAssertEqual(try persistedStatuses(h), [.ready])
    }

    func testDuplicateNoLookupCall() async throws {
        let (h, handler) = try await make([.success(ClaudeFixtures.expectedRunResult)])
        let existing = try await h.repository.add(TestFixtures.draft(word: "run"))

        let response = await handler.handle(text: " RUN ")

        XCTAssertEqual(response.outcome, .duplicate(existing))
        XCTAssertEqual(response.notification, NotificationContent(title: "Вже є в словнику", body: "run — бігти"))
        XCTAssertEqual(h.lookup.callCount, 0)
        let count = await h.repository.allEntries().count
        XCTAssertEqual(count, 1)
    }

    func testDuplicateOfPendingReported() async throws {
        let (h, handler) = try await make([.failure(.offline)])
        let first = await handler.handle(text: "run")
        guard case .queued(let pending, .offline?) = first.outcome else { return XCTFail("expected queued, got \(first)") }

        let second = await handler.handle(text: "Run")

        guard case .duplicate(let duplicate) = second.outcome else { return XCTFail("expected duplicate, got \(second)") }
        XCTAssertEqual(duplicate.id, pending.id)
        XCTAssertEqual(duplicate.status, .pending)
        XCTAssertEqual(second.notification, NotificationContent(title: "Вже є в словнику", body: "run — очікує обробки"))
        XCTAssertEqual(h.lookup.callCount, 1, "duplicate does not trigger another lookup")
    }

    func testDuplicateOfFailedReported() async throws {
        let (h, handler) = try await make([.failure(.unauthorized)])
        _ = await handler.handle(text: "run")

        let second = await handler.handle(text: "run")

        guard case .duplicate(let duplicate) = second.outcome else { return XCTFail("expected duplicate, got \(second)") }
        XCTAssertEqual(duplicate.status, .failed)
        XCTAssertEqual(second.notification.body, "run — очікує обробки")
        XCTAssertEqual(h.lookup.callCount, 1)
    }

    func testOfflineQueued() async throws {
        let (h, handler) = try await make([.failure(.offline)])

        let response = await handler.handle(text: "run")

        guard case .queued(let entry, .offline?) = response.outcome else { return XCTFail("expected queued, got \(response)") }
        XCTAssertEqual(entry.status, .pending)
        XCTAssertEqual(entry.lastError, ClaudeError.offline.userMessage)
        XCTAssertEqual(response.notification, NotificationContent(
            title: "Збережено в чергу", body: "run: немає мережі, переклад буде додано пізніше"))
        XCTAssertEqual(try persistedStatuses(h), [.pending], "word is not lost while offline")
        let attempts = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(attempts, 0, "offline does not count an attempt")
    }

    func testMissingKeyQueued() async throws {
        let (h, handler) = try await make([.failure(.missingAPIKey)])

        let response = await handler.handle(text: "run")

        guard case .queued(let entry, .missingAPIKey?) = response.outcome else {
            return XCTFail("expected queued, got \(response)")
        }
        XCTAssertEqual(entry.status, .pending)
        XCTAssertEqual(response.notification, NotificationContent(
            title: "Збережено в чергу", body: "run: додайте API-ключ у налаштуваннях"))
        XCTAssertEqual(try persistedStatuses(h), [.pending])
    }

    func testServerErrorQueuedForRetry() async throws {
        let (h, handler) = try await make([.failure(.server(status: 529))])

        let response = await handler.handle(text: "run")

        guard case .queued(let entry, .server(status: 529)?) = response.outcome else {
            return XCTFail("expected queued, got \(response)")
        }
        XCTAssertEqual(response.notification.body, "run: повторимо пізніше")
        let attempts = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(attempts, 1)
    }

    func testUnauthorizedFailed() async throws {
        let (h, handler) = try await make([.failure(.unauthorized)])

        let response = await handler.handle(text: "run")

        guard case .failed(let entry, .unauthorized) = response.outcome else { return XCTFail("expected failed, got \(response)") }
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.lastError, "Невірний API-ключ (401)")
        XCTAssertEqual(response.notification, NotificationContent(title: "Не вдалося додати", body: "run: Невірний API-ключ (401)"))
        XCTAssertEqual(try persistedStatuses(h), [.failed])
    }

    func testRejectedCreatesNoEntry() async throws {
        let (h, handler) = try await make([.success(ClaudeFixtures.expectedRunResult)])
        let cases: [(String?, SelectionRejection, String)] = [
            (nil, .empty, "Нічого не виділено"),
            ("", .empty, "Нічого не виділено"),
            ("  \n\t ", .empty, "Нічого не виділено"),
            (String(repeating: "a", count: 121), .tooLong(max: 120), "Виділено забагато тексту (макс. 120 символів)"),
            ("one two three four five six seven eight nine", .tooManyWords(max: 8),
             "Виділено забагато тексту (макс. 8 слів)"),
            ("12345", .noLetters, "Виділений текст не містить слів"),
        ]

        for (text, rejection, body) in cases {
            let response = await handler.handle(text: text)
            XCTAssertEqual(response.outcome, .rejected(rejection), String(describing: text))
            XCTAssertEqual(response.notification.body, body, String(describing: text))
            XCTAssertEqual(response.notification.title, NotificationText.rejectedTitle)
        }

        let entries = await h.repository.allEntries()
        XCTAssertEqual(entries, [])
        XCTAssertEqual(h.lookup.callCount, 0)
        XCTAssertEqual(try persistedStatuses(h), [])
    }

    func testConcurrentSameWordAddedOnce() async throws {
        let gate = Gate()
        let (h, handler) = try await make([.success(ClaudeFixtures.expectedRunResult)], gate: gate)

        let first = Task { await handler.handle(text: "run") }
        let second = Task { await handler.handle(text: "Run ") }
        await waitUntil { h.lookup.callCount >= 1 }
        gate.open()
        let responses = [await first.value, await second.value]

        let added = responses.filter { if case .added = $0.outcome { return true } else { return false } }
        let duplicates = responses.filter { if case .duplicate = $0.outcome { return true } else { return false } }
        XCTAssertEqual(added.count, 1, "\(responses)")
        XCTAssertEqual(duplicates.count, 1, "\(responses)")
        XCTAssertEqual(h.lookup.callCount, 1)
        let entries = await h.repository.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.status, .ready)
        XCTAssertEqual(try persistedStatuses(h), [.ready])
    }

    /// D17: Services-виклик, поки паралельний `processAll` обробляє щойно доданий запис.
    /// `processAll` запускається, щойно запис з'являється в репозиторії (через `changes()`); lookup заблокований
    /// шлюзом, тож один із двох шляхів (use-case `retry` або `processAll`) гарантовано застає запис «в обробці».
    /// Очікування: outcome `.added(entry)`, якщо на момент `.skipped` запис уже `ready`, інакше `.queued(entry, nil)`
    /// («Обробляється: run»); рівно 1 lookup; без дубля запису. Повторюється кілька разів, щоб охопити обидва
    /// порядки планування.
    func testAddDuringProcessAllReportsOutcome() async throws {
        var observedInFlight = 0
        var observedAdded = 0
        for iteration in 0..<25 {
            let gate = Gate()
            let (h, handler) = try await make([.success(ClaudeFixtures.expectedRunResult)], gate: gate)
            let queue = h.queue
            let stream = await h.repository.changes()

            let processAllDone = LockedValue(false)
            let processAllTask = Task { () -> [ProcessingResult] in
                for await snapshot in stream where snapshot.contains(where: { $0.word == "run" }) {
                    let results = await queue.processAll(ignoringBackoff: true)
                    processAllDone.value = true
                    return results
                }
                return []
            }
            let serviceDone = LockedValue(false)
            let serviceTask = Task { () -> ServiceResponse in
                let response = await handler.handle(text: "run")
                serviceDone.value = true
                return response
            }

            // Поки шлюз закритий, той шлях, що застав запис «в обробці», завершується сам.
            await waitUntil(timeout: 5) {
                h.lookup.callCount >= 1 && (processAllDone.value || serviceDone.value)
            }
            gate.open()
            let response = await serviceTask.value
            let results = await processAllTask.value

            XCTAssertEqual(h.lookup.callCount, 1, "iteration \(iteration): exactly one lookup, got \(h.lookup.texts)")
            let entries = await h.repository.allEntries()
            XCTAssertEqual(entries.count, 1, "iteration \(iteration): no duplicate entry")
            let stored = try XCTUnwrap(entries.first)
            XCTAssertEqual(stored.status, .ready, "iteration \(iteration)")

            switch response.outcome {
            case .added(let entry):
                observedAdded += 1
                XCTAssertEqual(entry.id, stored.id)
                XCTAssertEqual(entry.status, .ready)
                XCTAssertEqual(response.notification.title, "Додано")
                // `processAll` або пропустив запис (в обробці), або вже не застав його pending.
                for result in results {
                    guard case .skipped(let skipped) = result else {
                        return XCTFail("iteration \(iteration): processAll must not process again, got \(results)")
                    }
                    XCTAssertEqual(skipped.id, stored.id)
                }
            case .queued(let entry, nil):
                observedInFlight += 1
                XCTAssertEqual(entry.id, stored.id)
                XCTAssertEqual(entry.status, .pending, "in-flight entry is still pending at the time of .skipped")
                XCTAssertEqual(response.notification, NotificationContent(title: "Обробляється", body: "Обробляється: run"))
                XCTAssertEqual(results.count, 1, "iteration \(iteration): \(results)")
                guard case .ready(let ready)? = results.first else {
                    return XCTFail("iteration \(iteration): processAll should finish the entry, got \(results)")
                }
                XCTAssertEqual(ready.id, stored.id)
            default:
                XCTFail("iteration \(iteration): expected .added or .queued(_, nil), got \(response.outcome)")
            }
            XCTAssertEqual(try persistedStatuses(h), [.ready])
        }
        XCTAssertEqual(observedAdded + observedInFlight, 25)
        print("testAddDuringProcessAllReportsOutcome: added=\(observedAdded) inFlight=\(observedInFlight)")
    }

    // MARK: - M7: duplicate notification in the selection language

    func testItalianSelectionDuplicateNotifiesInItalianWithoutLookup() async throws {
        let h = try await QueueHarness.make([.success(ClaudeFixtures.expectedRunResult)],
                                            registry: LanguagePairRegistry(pairs: [.englishUkrainian]))
        harness?.remove()
        harness = h
        let house = M7.entry(word: "house", translations: ["будинок", "дім"],
                             variants: ["it": M7.readyVariant("casa", sourceWord: "house", translations: ["дім", "оселя"])])
        try await h.repository.replaceAll([house])
        let handler = ServiceRequestHandler(useCase: AddWordUseCase(
            repository: h.repository,
            processor: h.queue,
            settings: InMemorySettingsStore(),
            registry: LanguagePairRegistry(pairs: [.englishUkrainian])
        ))

        let italian = await handler.handle(text: "casa")

        guard case .duplicate(let existing) = italian.outcome else { return XCTFail("expected duplicate, got \(italian)") }
        XCTAssertEqual(existing.id, house.id)
        XCTAssertEqual(italian.notification, NotificationContent(title: "Вже є в словнику", body: "casa — дім, оселя"))
        XCTAssertTrue(italian.notification.body.hasPrefix("casa —"))

        let english = await handler.handle(text: "House")
        guard case .duplicate = english.outcome else { return XCTFail("expected duplicate, got \(english)") }
        XCTAssertEqual(english.notification.body, "house — будинок, дім")

        XCTAssertEqual(h.lookup.callCount, 0, "duplicates never reach Claude")
        let count = await h.repository.allEntries().count
        XCTAssertEqual(count, 1)
    }
}
