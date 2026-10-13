import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Мінімальний HTTP-транспорт (для ін'єкції в тестах).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Транспорт через `URLSession.dataTask` + continuation: однаково працює на macOS і Linux
/// (не покладаємось на `data(for:)` у FoundationNetworking). Тести — `MockURLProtocol` у конфігурації сесії.
public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    // `URLSession` потокобезпечний; `@unchecked` — бо на деяких SDK він не позначений `Sendable`.
    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (data ?? Data(), httpResponse))
            }
            task.resume()
        }
    }
}
