import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VocabCore

// MARK: - MockURLProtocol

/// `URLProtocol`, що відповідає з тестового обробника (§14). Статичний стан під `NSLock`:
/// обробник, лічильник запитів, записані запити з тілом (з `httpBody` або `httpBodyStream` — на Linux
/// FoundationNetworking передає тіло потоком).
final class MockURLProtocol: URLProtocol {
    struct RecordedRequest {
        let request: URLRequest
        let body: Data
    }

    enum Reply {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(Error)
    }

    typealias Handler = (RecordedRequest) -> Reply

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recorded: [RecordedRequest] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        recorded = []
    }

    static func setHandler(_ newHandler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handler = newHandler
    }

    /// Відповіді по черзі; останню повторює для наступних запитів.
    static func setReplies(_ replies: [Reply]) {
        let queue = ReplyQueue(replies)
        setHandler { _ in queue.next() }
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recorded.count
    }

    static var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Сесія з цим протоколом (`URLSessionConfiguration.ephemeral`).
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(of: request)
        let recordedRequest = RecordedRequest(request: request, body: body)
        Self.lock.lock()
        Self.recorded.append(recordedRequest)
        let currentHandler = Self.handler
        Self.lock.unlock()

        let reply = currentHandler?(recordedRequest)
            ?? .failure(URLError(.unsupportedURL))
        switch reply {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let headers, let data):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class ReplyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [MockURLProtocol.Reply]

    init(_ replies: [MockURLProtocol.Reply]) {
        self.replies = replies
    }

    func next() -> MockURLProtocol.Reply {
        lock.lock(); defer { lock.unlock() }
        if replies.count > 1 {
            return replies.removeFirst()
        }
        return replies.first ?? .failure(URLError(.unsupportedURL))
    }
}

// MARK: - Log capture

final class CapturingLogSink: LogSink, @unchecked Sendable {
    struct Line: Equatable {
        let level: LogLevel
        let message: String
    }

    private let lock = NSLock()
    private var stored: [Line] = []

    func write(level: LogLevel, message: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(Line(level: level, message: message))
    }

    var lines: [Line] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var text: String {
        lines.map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: "\n")
    }
}

// MARK: - Claude fixtures

enum ClaudeFixtures {
    /// Реалістичний за формою, але фіктивний ключ.
    static let apiKey = "sk-ant-api03-TESTKEY_abcdefghijklmnopqrstuvwxyz-0123456789"

    static let validWordJSON = """
    {"word":"run","lemma":"run","part_of_speech":"verb","transcription":"/rʌn/",\
    "translations":["бігти","керувати"],\
    "example":{"source":"She runs every morning.","translation":"Вона бігає щоранку."}}
    """

    static let validPhraseJSON = """
    {"word":"give up","lemma":"give up","part_of_speech":"verb","transcription":"",\
    "translations":["здаватися","кидати"],\
    "example":{"source":"Never give up.","translation":"Ніколи не здавайся."}}
    """

    /// Тіло відповіді Messages API з одним text-блоком (або кількома блоками).
    static func messagesResponse(text: String, stopReason: String = "end_turn") -> Data {
        messagesResponse(blocks: [["type": "text", "text": text]], stopReason: stopReason)
    }

    static func messagesResponse(blocks: [[String: Any]], stopReason: String? = "end_turn") -> Data {
        var envelope: [String: Any] = [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-5-5",
            "content": blocks,
            "usage": ["input_tokens": 10, "output_tokens": 20],
        ]
        envelope["stop_reason"] = stopReason ?? NSNull()
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    static func errorBody(type: String, message: String) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": type, "message": message]])
    }

    static func ok(_ text: String = validWordJSON, stopReason: String = "end_turn") -> MockURLProtocol.Reply {
        .response(status: 200, headers: ["content-type": "application/json"],
                  body: messagesResponse(text: text, stopReason: stopReason))
    }

    static func http(_ status: Int, headers: [String: String] = [:], body: Data? = nil) -> MockURLProtocol.Reply {
        var allHeaders = headers
        allHeaders["content-type"] = "application/json"
        return .response(status: status, headers: allHeaders,
                         body: body ?? errorBody(type: "api_error", message: "HTTP \(status)"))
    }

    static func urlError(_ code: URLError.Code) -> MockURLProtocol.Reply {
        .failure(URLError(code))
    }

    static let expectedRunResult = LookupResult(
        word: "run",
        lemma: "run",
        partOfSpeech: "verb",
        transcription: "/rʌn/",
        translations: ["бігти", "керувати"],
        example: Example(source: "She runs every morning.", translation: "Вона бігає щоранку.")
    )
}

/// Повний стек `ClaudeLookupService` поверх `MockURLProtocol` + реальної `URLSession`.
struct LookupHarness {
    let service: ClaudeLookupService
    let secrets: InMemorySecretStore
    let settings: InMemorySettingsStore
    let sink: CapturingLogSink

    /// - Parameter redactKnownSecret: чи передавати ключ у `secretsProvider` логера (як у застосунку).
    ///   `false` перевіряє, що код узагалі не намагається логувати ключ.
    init(apiKey: String? = ClaudeFixtures.apiKey, model: String? = nil, redactKnownSecret: Bool = true) {
        let secrets = InMemorySecretStore()
        if let apiKey {
            try? secrets.writeSecret(apiKey, for: .anthropicAPIKey)
        }
        let settings = InMemorySettingsStore(model: model)
        let sink = CapturingLogSink()
        let logger = RedactingLogger(sink: sink, secretsProvider: {
            guard redactKnownSecret, let key = try? secrets.readSecret(for: .anthropicAPIKey) else { return [] }
            return [key]
        })
        self.secrets = secrets
        self.settings = settings
        self.sink = sink
        self.service = ClaudeLookupService(
            transport: URLSessionTransport(session: MockURLProtocol.makeSession()),
            secrets: secrets,
            settings: settings,
            logger: logger
        )
    }

    func lookupRun() async throws -> LookupResult {
        try await service.lookup(text: "run", kind: .word, pair: .englishUkrainianSourceOnly)
    }
}

func XCTAssertThrowsClaudeError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: ClaudeError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected), got success", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? ClaudeError, expected, file: file, line: line)
    }
}

// MARK: - Stub lookup

/// Відкривний «шлюз» для блокування lookup у тестах конкурентності.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

/// `WordLookupService` зі сценарієм результатів. Останній результат повторюється.
final class StubLookupService: WordLookupService, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<LookupResult, ClaudeError>]
    private var receivedTexts: [String] = []
    private let gate: Gate?

    init(_ script: [Result<LookupResult, ClaudeError>], gate: Gate? = nil) {
        self.script = script
        self.gate = gate
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return receivedTexts.count
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return receivedTexts
    }

    func setScript(_ newScript: [Result<LookupResult, ClaudeError>]) {
        lock.lock(); defer { lock.unlock() }
        script = newScript
    }

    func lookup(text: String, kind: SelectionKind, pair: LanguagePair) async throws -> LookupResult {
        lock.lock()
        receivedTexts.append(text)
        let result: Result<LookupResult, ClaudeError>
        if script.count > 1 {
            result = script.removeFirst()
        } else if let last = script.first {
            result = last
        } else {
            result = .failure(.transport("empty script"))
        }
        lock.unlock()
        if let gate {
            await gate.wait()
        }
        return try result.get()
    }
}

/// Чекає (без реальних пауз понад ~1 с) поки умова стане істинною.
func waitUntil(
    timeout: TimeInterval = 1,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("condition not met within \(timeout)s", file: file, line: line)
}

/// Репозиторій у тимчасовому каталозі + процесори черги з керованим часом.
struct QueueHarness {
    let fixture: StoreFixture
    let repository: DictionaryRepository
    let lookup: StubLookupService
    let processor: EntryProcessor
    let queue: PendingQueueProcessor

    var dates: FixedDateProvider { fixture.dateProvider }

    static func make(
        _ script: [Result<LookupResult, ClaudeError>],
        gate: Gate? = nil,
        registry: LanguagePairRegistry = LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly])
    ) async throws -> QueueHarness {
        let fixture = try StoreFixture()
        let repository = DictionaryRepository(store: fixture.store, dateProvider: fixture.dateProvider)
        _ = try await repository.load()
        let lookup = StubLookupService(script, gate: gate)
        let processor = EntryProcessor(
            repository: repository,
            lookup: lookup,
            registry: registry,
            dateProvider: fixture.dateProvider
        )
        let queue = PendingQueueProcessor(
            repository: repository,
            processor: processor,
            policy: RetryPolicy(),
            dateProvider: fixture.dateProvider
        )
        return QueueHarness(fixture: fixture, repository: repository, lookup: lookup, processor: processor, queue: queue)
    }

    func addPending(_ word: String, languagePair: String = "en-uk") async throws -> Entry {
        try await repository.add(EntryDraft(word: word, languagePair: languagePair, status: .pending))
    }

    func entry(_ id: UUID) async -> Entry? {
        await repository.entry(id: id)
    }

    func remove() {
        fixture.directory.remove()
    }
}

extension ProcessingResult {
    var entry: Entry? {
        switch self {
        case .ready(let entry), .pending(let entry, _), .failed(let entry, _), .skipped(let entry):
            return entry
        case .duplicate(let existing, _):
            return existing
        case .notFound:
            return nil
        }
    }

    var error: ClaudeError? {
        switch self {
        case .pending(_, let error), .failed(_, let error):
            return error
        default:
            return nil
        }
    }
}
