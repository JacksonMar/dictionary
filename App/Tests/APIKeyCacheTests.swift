import Foundation
import XCTest
import VocabCore
@testable import VocabApp

/// `LogSink`, що запам'ятовує вже відредаговані повідомлення.
final class RecordingLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func write(level: LogLevel, message: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(message)
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Транспорт, що на будь-який запит відповідає HTTP 400 з заданим текстом помилки (без мережі).
struct EchoErrorTransport: HTTPTransport {
    let message: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.data(withJSONObject: [
            "type": "error",
            "error": ["type": "invalid_request_error", "message": message],
        ])
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1",
                                             headerFields: ["content-type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }
}

/// Регресія після рев'ю M2: `APIKeyCache` накопичує ключі, тож після зміни/видалення ключа старий
/// і далі вирізається з логів і текстів помилок (`lastError`, `dictionary.json`).
final class APIKeyCacheTests: XCTestCase {
    private static let oldKey = "old-proxy-key-0123456789abcdef"
    private static let newKey = "new-proxy-key-fedcba9876543210"

    func testKeepsOldKeysAfterChange() {
        let cache = APIKeyCache()
        cache.set(Self.oldKey)
        cache.set(Self.newKey)

        XCTAssertEqual(Set(cache.secrets()), [Self.oldKey, Self.newKey])
    }

    func testNilOrEmptyDoesNotRemoveKeys() {
        let cache = APIKeyCache()
        cache.set(Self.oldKey)
        cache.set(nil)
        cache.set("")

        XCTAssertEqual(cache.secrets(), [Self.oldKey])
    }

    func testDuplicatesStoredOnceAndLongestFirst() {
        let cache = APIKeyCache()
        cache.set("short-key-123")
        cache.set("a-much-longer-key-0123456789")
        cache.set("short-key-123")

        XCTAssertEqual(cache.secrets(), ["a-much-longer-key-0123456789", "short-key-123"])
    }

    func testLoggerRedactsOldAndNewKeys() {
        let cache = APIKeyCache()
        let sink = RecordingLogSink()
        let logger = RedactingLogger(sink: sink, secretsProvider: { cache.secrets() })
        cache.set(Self.oldKey)
        cache.set(Self.newKey)

        logger.error("old=\(Self.oldKey) new=\(Self.newKey)")

        XCTAssertEqual(sink.messages, ["old=[REDACTED] new=[REDACTED]"])
    }

    @MainActor
    func testAppModelKeyChangeKeepsOldKeyRedacted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabAPIKeyCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(applicationSupportDirectory: directory)
        let dates = FixedDateProvider(Date(timeIntervalSince1970: 1_791_885_600))
        let store = FileDictionaryStore(
            fileURL: paths.dictionaryURL,
            fileSystem: LocalFileSystem(),
            dateProvider: dates,
            backups: BackupManager(directory: paths.backupsDirectory, dateProvider: dates)
        )
        let repository = DictionaryRepository(store: store, dateProvider: dates)
        let sink = RecordingLogSink()
        let claude = ClaudeServices.make(
            repository: repository,
            secrets: InMemorySecretStore(),
            settings: InMemorySettingsStore(),
            transport: EchoErrorTransport(message: "previous key \(Self.oldKey) was revoked"),
            logSink: sink,
            dateProvider: dates
        )
        let model = AppModel(repository: repository, claude: claude)
        await model.load()

        XCTAssertTrue(model.saveAPIKey(Self.oldKey))
        XCTAssertTrue(model.saveAPIKey(Self.newKey))
        XCTAssertEqual(Set(claude.keyCache.secrets()), [Self.oldKey, Self.newKey])
        // `saveAPIKey` запускає `processPending` у фоновій задачі на головному акторі — даємо їй завершитися,
        // щоб вона не перетиналася з додаванням нижче.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Сервер повторює старий ключ (не у форматі sk-ant-) — він має бути вирізаний.
        let outcome = await model.addViaClaude("run")

        guard case .failed(let entry, .badRequest(400, let message))? = outcome else {
            return XCTFail("expected failed badRequest, got \(String(describing: outcome))")
        }
        XCTAssertEqual(message, "previous key [REDACTED] was revoked")
        XCTAssertFalse(entry.lastError?.contains(Self.oldKey) ?? false)
        let raw = String(decoding: try Data(contentsOf: paths.dictionaryURL), as: UTF8.self)
        XCTAssertFalse(raw.contains(Self.oldKey), "dictionary.json must not contain the old key")
        XCTAssertFalse(raw.contains(Self.newKey))
        XCTAssertTrue(raw.contains("[REDACTED]"))

        // Після видалення ключа обидва досі вирізаються з логів.
        XCTAssertTrue(model.deleteAPIKey())
        claude.logger.info("leak \(Self.oldKey) \(Self.newKey)")
        let log = sink.messages.joined(separator: "\n")
        XCTAssertFalse(log.contains(Self.oldKey), log)
        XCTAssertFalse(log.contains(Self.newKey), log)
        XCTAssertTrue(log.contains("leak [REDACTED] [REDACTED]"), log)
    }
}
