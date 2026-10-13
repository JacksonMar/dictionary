import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VocabCore

/// Регресійні тести для виправлень після рев'ю M2:
/// - текст помилки сервера, що повторює ключ **не** у форматі `sk-ant-…`, повністю редагується в `lastError`
///   і `dictionary.json` (у т.ч. на межі обрізання до 200 символів і для попереднього ключа);
/// - невдале збереження в `EntryProcessor` логується (відредаговано), а результат відповідає збереженому статусу;
/// - черга перестає авто-повторювати запис, що вичерпав `maxAttempts`, поки збереження `failed` не вдається
///   (`exhausted`), а ручний «Повторити» це скидає.
final class M2ReviewRegressionTests: XCTestCase {
    private static let customKey = "custom-proxy-key-0123456789abcdef"
    private static let oldKey = "previous-proxy-key-9876543210zyx"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Server error text redaction

    private func makeProcessor(
        lookup: WordLookupService
    ) async throws -> (StoreFixture, DictionaryRepository, EntryProcessor) {
        let fixture = try StoreFixture()
        addTeardownBlock { fixture.directory.remove() }
        let repository = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)
        _ = try await repository.load()
        let processor = EntryProcessor(
            repository: repository,
            lookup: lookup,
            registry: LanguagePairRegistry(pairs: [.englishUkrainian]),
            dateProvider: fixture.dateProvider
        )
        return (fixture, repository, processor)
    }

    private func assertNoKey(
        _ key: String,
        in text: String?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let text else { return }
        XCTAssertFalse(text.contains(key), "\(message): contains key: \(text)", file: file, line: line)
        // Жодного помітного фрагмента ключа (напр. на межі обрізання).
        let fragment = String(key.prefix(10))
        XCTAssertFalse(text.contains(fragment), "\(message): contains key fragment: \(text)", file: file, line: line)
    }

    func testServerErrorEchoingNonSkAntKeyRedactedInLastErrorAndFile() async throws {
        // Логер не знає ключа (redactKnownSecret: false) — редагує сам клієнт за ключем поточного запиту.
        let harness = LookupHarness(apiKey: Self.customKey, redactKnownSecret: false)
        let (fixture, repository, processor) = try await makeProcessor(lookup: harness.service)

        let messages: [(Int, String)] = [
            (400, "invalid x-api-key header: \(Self.customKey)"),
            (404, "model not found for key \(Self.customKey)"),
            (413, "\(Self.customKey) \(Self.customKey) twice"),
            (422, "key=\(Self.customKey);"),
            // Ключ на межі обрізання до 200 символів: редагування має відбутися ДО обрізання.
            (400, String(repeating: "x", count: 190) + Self.customKey),
            (400, String(repeating: "y", count: 195) + Self.customKey + " tail"),
        ]

        for (index, (status, text)) in messages.enumerated() {
            MockURLProtocol.reset()
            MockURLProtocol.setReplies([ClaudeFixtures.http(status, body: ClaudeFixtures.errorBody(
                type: "invalid_request_error", message: text))])
            let entry = try await repository.add(EntryDraft(word: "word\(index)", languagePair: "en-uk", status: .pending))

            let result = await processor.process(entryID: entry.id, attempts: 0)

            guard case .failed(let failed, .badRequest(let gotStatus, let message)) = result else {
                XCTFail("\(status): expected failed badRequest, got \(result)")
                continue
            }
            XCTAssertEqual(gotStatus, status)
            XCTAssertLessThanOrEqual(message.count, ClaudeError.maxErrorMessageLength)
            assertNoKey(Self.customKey, in: message, "\(index) error message")
            assertNoKey(Self.customKey, in: failed.lastError, "\(index) lastError")
            assertNoKey(Self.customKey, in: harness.sink.text, "\(index) log")
            let stored = await repository.entry(id: entry.id)
            assertNoKey(Self.customKey, in: stored?.lastError, "\(index) stored lastError")
            let raw = String(decoding: try fixture.readRaw(), as: UTF8.self)
            assertNoKey(Self.customKey, in: raw, "\(index) dictionary.json")
        }

        // Санітарна перевірка: маркер редагування справді потрапив у файл (повідомлення не просто відкинуто).
        let first = try XCTUnwrap(try fixture.store.load().file.entries.first)
        XCTAssertEqual(first.lastError, "Помилка запиту (400): invalid x-api-key header: [REDACTED]")
    }

    func testServerErrorEchoingPreviousKeyRedacted() async throws {
        // Ключ змінено: запит іде з новим ключем, а сервер повторює старий. Старий ключ відомий логеру
        // (у застосунку — `APIKeyCache` накопичує ключі), тож має бути вирізаний із тексту помилки.
        let secrets = InMemorySecretStore()
        try secrets.writeSecret(Self.customKey, for: .anthropicAPIKey)
        let sink = CapturingLogSink()
        let logger = RedactingLogger(sink: sink, secretsProvider: { [Self.oldKey, Self.customKey] })
        let service = ClaudeLookupService(
            transport: URLSessionTransport(session: MockURLProtocol.makeSession()),
            secrets: secrets,
            settings: InMemorySettingsStore(),
            logger: logger
        )
        let (fixture, repository, processor) = try await makeProcessor(lookup: service)
        MockURLProtocol.setReplies([ClaudeFixtures.http(400, body: ClaudeFixtures.errorBody(
            type: "invalid_request_error", message: "old key \(Self.oldKey) revoked; current \(Self.customKey)"))])
        let entry = try await repository.add(EntryDraft(word: "run", languagePair: "en-uk", status: .pending))

        let result = await processor.process(entryID: entry.id, attempts: 0)

        let failed = try XCTUnwrap(result.entry)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastError, "Помилка запиту (400): old key [REDACTED] revoked; current [REDACTED]")
        let raw = String(decoding: try fixture.readRaw(), as: UTF8.self)
        assertNoKey(Self.oldKey, in: raw, "dictionary.json (old key)")
        assertNoKey(Self.customKey, in: raw, "dictionary.json (current key)")
        assertNoKey(Self.oldKey, in: sink.text, "log")
    }

    func testErrorMessageRedactionHappensBeforeTruncation() {
        let body = ClaudeFixtures.errorBody(type: "x", message: String(repeating: "z", count: 195) + Self.customKey)
        let error = ClaudeError.from(status: 400, retryAfterHeader: nil, body: body, redact: {
            $0.replacingOccurrences(of: Self.customKey, with: RedactingLogger.redactedMarker)
        })
        guard case .badRequest(400, let message) = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(message, String(repeating: "z", count: 195) + "[REDA")
        XCTAssertFalse(message.contains("custom"))
    }

    // MARK: - EntryProcessor save failure

    /// Сховище, що на запит кидає помилку запису з чутливим текстом (щоб перевірити редагування логу).
    private final class SwitchableFailingStore: DictionaryStoring, @unchecked Sendable {
        let base: FileDictionaryStore
        private let lock = NSLock()
        private var failure: Error?

        init(base: FileDictionaryStore) {
            self.base = base
        }

        var fileURL: URL { base.fileURL }

        func fail(with error: Error?) {
            lock.lock(); defer { lock.unlock() }
            failure = error
        }

        func load() throws -> LoadResult {
            try base.load()
        }

        func save(_ file: DictionaryFile) throws {
            lock.lock()
            let error = failure
            lock.unlock()
            if let error {
                throw error
            }
            try base.save(file)
        }
    }

    private struct SaveFailureHarness {
        let fixture: StoreFixture
        let store: SwitchableFailingStore
        let repository: DictionaryRepository
        let lookup: StubLookupService
        let processor: EntryProcessor
        let sink: CapturingLogSink

        func persistedStatus(_ id: UUID) throws -> EntryStatus? {
            try fixture.store.load().file.entries.first { $0.id == id }?.status
        }
    }

    private func makeSaveFailureHarness(
        _ script: [Result<LookupResult, ClaudeError>]
    ) async throws -> SaveFailureHarness {
        let fixture = try StoreFixture()
        addTeardownBlock { fixture.directory.remove() }
        let store = SwitchableFailingStore(base: fixture.store)
        let repository = DictionaryRepository(store: store, dateProvider: fixture.dateProvider)
        _ = try await repository.load()
        let lookup = StubLookupService(script)
        let sink = CapturingLogSink()
        let logger = RedactingLogger(sink: sink, secretsProvider: { [Self.customKey] })
        let processor = EntryProcessor(
            repository: repository,
            lookup: lookup,
            registry: LanguagePairRegistry(pairs: [.englishUkrainian]),
            dateProvider: fixture.dateProvider,
            logger: logger
        )
        return SaveFailureHarness(fixture: fixture, store: store, repository: repository, lookup: lookup,
                                  processor: processor, sink: sink)
    }

    func testEntryProcessorSaveFailureIsLoggedRedacted() async throws {
        let h = try await makeSaveFailureHarness([.success(ClaudeFixtures.expectedRunResult)])
        let entry = try await h.repository.add(EntryDraft(word: "run", languagePair: "en-uk", status: .pending))
        h.store.fail(with: StorageError.writeFailed(
            "volume /Volumes/\(Self.customKey) is read-only; sk-ant-api03-LEAKED_value"))

        let result = await h.processor.process(entryID: entry.id, attempts: 0)

        let errorLines = h.sink.lines.filter { $0.level == .error }
        XCTAssertEqual(errorLines.count, 1, h.sink.text)
        let line = try XCTUnwrap(errorLines.first?.message)
        XCTAssertTrue(line.contains("Entry save failed"), line)
        XCTAssertTrue(line.contains(entry.id.uuidString), line)
        XCTAssertTrue(line.contains("status=ready"), line)
        XCTAssertTrue(line.contains("[REDACTED]"), line)
        XCTAssertFalse(line.contains(Self.customKey), line)
        XCTAssertFalse(line.contains("LEAKED_value"), line)
        // Lookup пройшов, але `ready` не збережено → результат відповідає збереженому `pending`.
        guard case .pending(let current, _) = result else { return XCTFail("expected pending, got \(result)") }
        XCTAssertEqual(current.status, .pending)
        XCTAssertEqual(try h.persistedStatus(entry.id), .pending)
        let inMemory = await h.repository.entry(id: entry.id)
        XCTAssertEqual(inMemory, current)
    }

    func testEntryProcessorSaveFailureResultMatchesPersistedStatus() async throws {
        struct Scenario {
            let name: String
            let initial: EntryStatus
            let lookup: Result<LookupResult, ClaudeError>
            let expectedStatus: EntryStatus
            let expectedError: ClaudeError?   // nil — `.storage(…)` про збереження (M5: не `.transport`)
        }
        let scenarios: [Scenario] = [
            Scenario(name: "pending+success", initial: .pending, lookup: .success(ClaudeFixtures.expectedRunResult),
                     expectedStatus: .pending, expectedError: nil),
            Scenario(name: "pending+unauthorized (wants failed)", initial: .pending, lookup: .failure(.unauthorized),
                     expectedStatus: .pending, expectedError: nil),
            Scenario(name: "pending+offline (wants pending)", initial: .pending, lookup: .failure(.offline),
                     expectedStatus: .pending, expectedError: .offline),
            Scenario(name: "pending+server (wants pending)", initial: .pending, lookup: .failure(.server(status: 503)),
                     expectedStatus: .pending, expectedError: .server(status: 503)),
            Scenario(name: "failed+offline (wants pending)", initial: .failed, lookup: .failure(.offline),
                     expectedStatus: .failed, expectedError: nil),
            Scenario(name: "failed+success (wants ready)", initial: .failed,
                     lookup: .success(ClaudeFixtures.expectedRunResult), expectedStatus: .failed, expectedError: nil),
            Scenario(name: "failed+refused (wants failed)", initial: .failed, lookup: .failure(.refused),
                     expectedStatus: .failed, expectedError: nil),
        ]

        for scenario in scenarios {
            let h = try await makeSaveFailureHarness([scenario.lookup])
            let entry = try await h.repository.add(EntryDraft(word: "run", languagePair: "en-uk", status: scenario.initial))
            h.store.fail(with: StorageError.writeFailed("disk full"))

            let result = await h.processor.process(entryID: entry.id, attempts: 0)

            let persisted = try h.persistedStatus(entry.id)
            XCTAssertEqual(persisted, scenario.initial, "\(scenario.name): nothing was saved")
            XCTAssertEqual(result.entry?.status, persisted, "\(scenario.name): result must match persisted status, got \(result)")
            XCTAssertEqual(result.entry?.status, scenario.expectedStatus, "\(scenario.name): \(result)")
            switch (scenario.expectedStatus, result) {
            case (.pending, .pending), (.failed, .failed):
                break
            default:
                XCTFail("\(scenario.name): result case does not match persisted status: \(result)")
            }
            if let expectedError = scenario.expectedError {
                XCTAssertEqual(result.error, expectedError, scenario.name)
            } else {
                guard case .storage(let reason)? = result.error else {
                    XCTFail("\(scenario.name): expected storage save error, got \(String(describing: result.error))")
                    continue
                }
                XCTAssertTrue(reason.contains("не вдалося зберегти запис"), reason)
            }
            XCTAssertEqual(h.sink.lines.filter { $0.level == .error }.count, 1, "\(scenario.name): \(h.sink.text)")
            XCTAssertTrue(h.sink.text.contains("Entry save failed"), scenario.name)
        }
    }

    // MARK: - Queue: exhausted attempts while saving `failed` keeps failing

    func testQueueStopsRetryingExhaustedEntryWhenFailedCannotBeSaved() async throws {
        let h = try await QueueHarness.make([.failure(.server(status: 500))])
        defer { h.remove() }
        let entry = try await h.addPending("run")
        h.fixture.fileSystem.fail(.replaceItem)

        for attempt in 1...RetryPolicy.defaultMaxAttempts {
            let results = await h.queue.processAll(ignoringBackoff: true)
            XCTAssertEqual(results.count, 1, "attempt \(attempt): \(results)")
            guard case .pending(let pending, _)? = results.first else {
                return XCTFail("attempt \(attempt): entry stays pending on disk, got \(results)")
            }
            XCTAssertEqual(pending.status, .pending)
            let count = await h.queue.attemptCount(for: entry.id)
            XCTAssertEqual(count, attempt)
        }
        XCTAssertEqual(h.lookup.callCount, RetryPolicy.defaultMaxAttempts)
        let stored = await h.entry(entry.id)
        XCTAssertEqual(stored?.status, .pending, "failed could not be saved")

        // Вичерпано: ні processAll (без backoff), ні processDue після спливу backoff не роблять нових запитів.
        let again = await h.queue.processAll(ignoringBackoff: true)
        XCTAssertEqual(again, [])
        h.dates.advance(by: 3600)
        let due = await h.queue.processDue()
        XCTAssertEqual(due, [])
        XCTAssertEqual(h.lookup.callCount, RetryPolicy.defaultMaxAttempts, "no further automatic lookups")

        // Ручний «Повторити» скидає `exhausted` і лічильник: запис знову обробляється.
        let retried = await h.queue.retry(entryID: entry.id)
        guard case .pending = retried else { return XCTFail("expected pending after manual retry, got \(retried)") }
        XCTAssertEqual(h.lookup.callCount, RetryPolicy.defaultMaxAttempts + 1)
        let countAfterRetry = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(countAfterRetry, 1, "manual retry resets attempts")
        // Після ручного повтору авто-повтори знову працюють (запис більше не в `exhausted`).
        let resumed = await h.queue.processAll(ignoringBackoff: true)
        XCTAssertEqual(resumed.count, 1, "\(resumed)")
        XCTAssertEqual(h.lookup.callCount, RetryPolicy.defaultMaxAttempts + 2)
    }

    func testManualRetryOfExhaustedEntrySucceedsOnceDiskRecovers() async throws {
        let h = try await QueueHarness.make([.failure(.timeout)])
        defer { h.remove() }
        let entry = try await h.addPending("run")
        h.fixture.fileSystem.fail(.replaceItem)
        for _ in 1...RetryPolicy.defaultMaxAttempts {
            _ = await h.queue.processAll(ignoringBackoff: true)
        }
        let exhausted = await h.queue.processAll(ignoringBackoff: true)
        XCTAssertEqual(exhausted, [])

        h.fixture.fileSystem.stopFailing()
        h.lookup.setScript([.success(ClaudeFixtures.expectedRunResult)])
        let retried = await h.queue.retry(entryID: entry.id)

        guard case .ready(let ready) = retried else { return XCTFail("expected ready, got \(retried)") }
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(try h.fixture.store.load().file.entries.map(\.status), [.ready])
        let count = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(count, 0)
    }

    func testExhaustedStateDoesNotAffectOtherEntries() async throws {
        let h = try await QueueHarness.make([.failure(.server(status: 500))])
        defer { h.remove() }
        _ = try await h.addPending("run")
        h.fixture.fileSystem.fail(.replaceItem)
        // Довести `run` до вичерпання через авто-проходи.
        for _ in 1...RetryPolicy.defaultMaxAttempts {
            _ = await h.queue.processAll(ignoringBackoff: true)
        }
        h.fixture.fileSystem.stopFailing()
        let walk = try await h.addPending("walk")
        h.lookup.setScript([.success(ClaudeFixtures.expectedRunResult)])

        let results = await h.queue.processAll(ignoringBackoff: true)

        XCTAssertEqual(results.compactMap { $0.entry?.id }, [walk.id], "only the non-exhausted entry is processed")
    }
}
