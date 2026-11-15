// Copy of the core test `MockURLProtocol` (Tests/VocabCoreTests/M2TestSupport.swift) for the VocabMobile tests
// (IOS_PLAN §7 I1b.2, §8): the core test module is not visible from this target. Counts every HTTP request that the
// real `URLSessionTransport` → `ClaudeLookupService` stack sends, so tests can assert "1 request per new word,
// 0 per duplicate". On Linux `URLProtocol`/`URLSession` live in FoundationNetworking.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VocabCore

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
    private static var delay: TimeInterval = 0

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        recorded = []
        delay = 0
    }

    static func setHandler(_ newHandler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handler = newHandler
    }

    /// Replies in order; the last one repeats for further requests.
    static func setReplies(_ replies: [Reply]) {
        let queue = MockReplyQueue(replies)
        setHandler { _ in queue.next() }
    }

    /// Delay before each reply (keeps a request in flight while a second caller arrives).
    static func setDelay(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        delay = seconds
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recorded.count
    }

    static var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Ephemeral session with this protocol.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// `HTTPTransport` for `AppContainer(baseDirectory:settings:secrets:transport:)`.
    static func makeTransport() -> HTTPTransport {
        URLSessionTransport(session: makeSession())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(of: request)
        let recordedRequest = RecordedRequest(request: request, body: body)
        Self.lock.lock()
        Self.recorded.append(recordedRequest)
        let currentHandler = Self.handler
        let currentDelay = Self.delay
        Self.lock.unlock()

        if currentDelay > 0 {
            Thread.sleep(forTimeInterval: currentDelay)
        }
        let reply = currentHandler?(recordedRequest) ?? .failure(URLError(.unsupportedURL))
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

private final class MockReplyQueue: @unchecked Sendable {
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

// MARK: - Claude fixtures (minimal copy of the core `ClaudeFixtures` / `M7` helpers)

enum MobileClaudeFixtures {
    /// Realistic-looking but fake key.
    static let apiKey = "sk-ant-api03-MOBILETESTKEY_abcdefghijklmnopqrstuvwxyz-0123456789"

    /// Messages API envelope with one text block.
    static func messagesResponse(text: String) -> Data {
        let envelope: [String: Any] = [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-5-5",
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 10, "output_tokens": 20],
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: envelope)
    }

    static func ok(_ text: String) -> MockURLProtocol.Reply {
        .response(status: 200, headers: ["content-type": "application/json"], body: messagesResponse(text: text))
    }

    static func http(_ status: Int) -> MockURLProtocol.Reply {
        let body = try? JSONSerialization.data(withJSONObject: [
            "type": "error",
            "error": ["type": "api_error", "message": "HTTP \(status)"],
        ])
        return .response(status: status, headers: ["content-type": "application/json"], body: body ?? Data())
    }

    /// Model-format object (snake_case) for the top level, a variant or a batch element.
    static func object(word: String, ipa: String = "/ipa/", translations: [String]) -> [String: Any] {
        [
            "word": word,
            "lemma": word,
            "part_of_speech": "noun",
            "transcription": ipa,
            "translations": translations,
            "example": ["source": "Example with \(word).", "translation": "Приклад речення."],
        ]
    }

    /// Combined response (EN + IT) for an English word.
    static func combinedJSON(word: String, translations: [String], italian: String, italianTranslations: [String]) -> String {
        var top = object(word: word, translations: translations)
        top["source_language"] = "en"
        top["variants"] = ["it": object(word: italian, translations: italianTranslations)]
        return jsonString(top)
    }

    /// `house` / `casa`.
    static let houseJSON = combinedJSON(
        word: "house", translations: ["будинок", "дім"], italian: "casa", italianTranslations: ["дім", "будинок"]
    )

    /// Batch backfill response: elements `{"id": n, ...}` with n = 1...count.
    static func batchJSON(count: Int) -> String {
        let elements: [[String: Any]] = (1...max(count, 1)).map { index in
            var element = object(word: "parola\(index)", translations: ["переклад \(index)"])
            element["id"] = index
            return element
        }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: elements, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func jsonString(_ object: [String: Any]) -> String {
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Log sink that keeps lines (to assert queue triggers such as `trigger=foreground`).
final class MobileCapturingLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func write(level: LogLevel, message: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(message)
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
