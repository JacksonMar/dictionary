import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VocabCore

/// M2.6 — API-ключ ніколи не потрапляє в логи, `dictionary.json` чи `lastError`.
final class RedactingLoggerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// Усі шляхи відповіді, які може пройти lookup.
    private static let allReplyPaths: [(String, [MockURLProtocol.Reply])] = [
        ("success", [ClaudeFixtures.ok()]),
        ("401", [ClaudeFixtures.http(401, body: ClaudeFixtures.errorBody(type: "authentication_error",
                                                                          message: "invalid x-api-key"))]),
        ("402", [ClaudeFixtures.http(402)]),
        ("403", [ClaudeFixtures.http(403)]),
        ("429", [ClaudeFixtures.http(429, headers: ["retry-after": "5"])]),
        ("500", [ClaudeFixtures.http(500)]),
        ("529", [ClaudeFixtures.http(529)]),
        ("400 echoing key", [ClaudeFixtures.http(400, body: ClaudeFixtures.errorBody(
            type: "invalid_request_error", message: "bad header x-api-key: \(ClaudeFixtures.apiKey)"))]),
        ("offline", [ClaudeFixtures.urlError(.notConnectedToInternet)]),
        ("timeout", [ClaudeFixtures.urlError(.timedOut)]),
        ("transport", [ClaudeFixtures.urlError(.badServerResponse)]),
        ("invalid twice", [ClaudeFixtures.ok("nope"), ClaudeFixtures.ok("nope again")]),
        ("invalid then ok", [ClaudeFixtures.ok("nope"), ClaudeFixtures.ok()]),
        ("max_tokens", [ClaudeFixtures.ok("{\"word\":", stopReason: "max_tokens")]),
        ("refusal", [ClaudeFixtures.ok("", stopReason: "refusal")]),
    ]

    func testRedactsKnownSecret() {
        let sink = CapturingLogSink()
        let logger = RedactingLogger(sink: sink, secretsProvider: { ["my-secret-value-123"] })

        logger.info("header=my-secret-value-123 and again my-secret-value-123")
        logger.error("error: my-secret-value-123")
        logger.debug("debug my-secret-value-123")

        XCTAssertEqual(sink.lines.map(\.message), [
            "header=[REDACTED] and again [REDACTED]",
            "error: [REDACTED]",
            "debug [REDACTED]",
        ])
        XCTAssertEqual(sink.lines.map(\.level), [.info, .error, .debug])
    }

    func testShortSecretsNotRedacted() {
        let sink = CapturingLogSink()
        let logger = RedactingLogger(sink: sink, secretsProvider: { ["short", ""] })

        logger.info("a short message")

        XCTAssertEqual(sink.lines.map(\.message), ["a short message"])
    }

    func testRedactsSkAntPattern() {
        let sink = CapturingLogSink()
        let logger = RedactingLogger(sink: sink, secretsProvider: { [] })

        logger.error("key sk-ant-api03-AbC_d-ef123 leaked; other sk-ant-xyz")

        XCTAssertEqual(sink.lines.map(\.message), ["key sk-ant-[REDACTED] leaked; other sk-ant-[REDACTED]"])
        XCTAssertEqual(RedactingLogger.redactAPIKeyPattern(ClaudeFixtures.apiKey), "sk-ant-[REDACTED]")
    }

    func testSecretsProviderReadEachTime() {
        let sink = CapturingLogSink()
        let current = LockedValue<[String]>(["first-secret-1"])
        let logger = RedactingLogger(sink: sink, secretsProvider: { current.value })

        logger.info("first-secret-1")
        current.value = ["second-secret-2"]
        logger.info("first-secret-1 second-secret-2")

        XCTAssertEqual(sink.lines.map(\.message), ["[REDACTED]", "first-secret-1 [REDACTED]"])
    }

    func testLookupFlowNeverLogsKey() async {
        // Сценарії: успіх, 401, 500, offline та всі інші шляхи. Два режими:
        // з редагуванням (як у застосунку) і без нього — тоді ключа не має бути вже в сирих повідомленнях
        // (крім випадку, коли його повертає сам сервер — для нього працює шаблон sk-ant-).
        for redact in [true, false] {
            for (name, replies) in Self.allReplyPaths {
                MockURLProtocol.reset()
                MockURLProtocol.setReplies(replies)
                let harness = LookupHarness(redactKnownSecret: redact)

                let outcome: String
                do {
                    _ = try await harness.lookupRun()
                    outcome = "ok"
                } catch {
                    outcome = String(describing: error)
                    XCTAssertFalse(outcome.contains(ClaudeFixtures.apiKey), "\(name): error must not contain key")
                    if let claudeError = error as? ClaudeError {
                        XCTAssertFalse(claudeError.userMessage.contains(ClaudeFixtures.apiKey), "\(name): userMessage")
                    }
                }
                XCTAssertFalse(harness.sink.lines.isEmpty, "\(name): flow must log something (\(outcome))")
                XCTAssertFalse(harness.sink.text.contains(ClaudeFixtures.apiKey),
                               "\(name) (redact=\(redact)): key leaked into log:\n\(harness.sink.text)")
                XCTAssertFalse(harness.sink.text.contains("api03-TESTKEY"),
                               "\(name) (redact=\(redact)): key fragment leaked into log")
            }
        }
    }

    func testNonPatternKeyNeverLogged() async {
        // Ключ, що не підпадає під sk-ant- шаблон, і логер без secretsProvider: код не повинен логувати
        // ні заголовки, ні тіло запиту.
        let key = "custom-proxy-key-0123456789abcdef"
        for (name, replies) in Self.allReplyPaths where name != "400 echoing key" {
            MockURLProtocol.reset()
            MockURLProtocol.setReplies(replies)
            let harness = LookupHarness(apiKey: key, redactKnownSecret: false)

            _ = try? await harness.lookupRun()

            XCTAssertFalse(harness.sink.text.contains(key), "\(name): key leaked into log:\n\(harness.sink.text)")
        }
    }

    func testDictionaryFileNeverContainsKey() async throws {
        let fixture = try StoreFixture()
        defer { fixture.directory.remove() }
        let repository = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)
        _ = try await repository.load()
        let harness = LookupHarness()
        let processor = EntryProcessor(
            repository: repository,
            lookup: harness.service,
            registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly]),
            dateProvider: fixture.dateProvider
        )

        for (index, (name, replies)) in Self.allReplyPaths.enumerated() {
            MockURLProtocol.reset()
            MockURLProtocol.setReplies(replies)
            let entry = try await repository.add(EntryDraft(word: "word\(index)", languagePair: "en-uk", status: .pending))

            let result = await processor.process(entryID: entry.id, attempts: 0)

            let stored = try XCTUnwrap(result.entry)
            XCTAssertFalse(stored.lastError?.contains(ClaudeFixtures.apiKey) ?? false, "\(name): lastError has key")
            XCTAssertFalse(stored.lastError?.contains("api03-TESTKEY") ?? false, "\(name): lastError has key fragment")
            let raw = String(decoding: try fixture.readRaw(), as: UTF8.self)
            XCTAssertFalse(raw.contains(ClaudeFixtures.apiKey), "\(name): dictionary.json contains key")
            XCTAssertFalse(raw.contains("api03-TESTKEY"), "\(name): dictionary.json contains key fragment")
        }

        // Санітарна перевірка: усі шляхи справді записали щось у файл (і помилки з lastError).
        let entries = try fixture.store.load().file.entries
        XCTAssertEqual(entries.count, Self.allReplyPaths.count)
        XCTAssertTrue(entries.contains { $0.status == .ready })
        XCTAssertTrue(entries.contains { $0.status == .failed && $0.lastError != nil })
        XCTAssertTrue(entries.contains { $0.status == .pending && $0.lastError != nil })
        let raw = String(decoding: try fixture.readRaw(), as: UTF8.self)
        XCTAssertFalse(raw.contains("sk-ant-api"))
        XCTAssertTrue(raw.contains("sk-ant-[REDACTED]"), "server-echoed key must be stored redacted")
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
