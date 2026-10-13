import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Один HTTP-виклик Messages API: запит → транспорт → мапінг помилок. Без повторів (§7.5).
/// Логує лише модель, статус, тривалість і тип помилки — ні заголовків, ні тіла.
public struct ClaudeAPIClient: Sendable {
    private let transport: HTTPTransport
    private let logger: RedactingLogger

    public init(transport: HTTPTransport, logger: RedactingLogger) {
        self.transport = transport
        self.logger = logger
    }

    /// Повертає тіло відповіді з 2xx; інакше кидає `ClaudeError`.
    public func send(prompt: BuiltPrompt, apiKey: String, configuration: ClaudeConfiguration) async throws -> Data {
        let request = try ClaudeRequestBuilder.makeRequest(prompt: prompt, apiKey: apiKey, configuration: configuration)
        let model = configuration.model
        let started = Date()

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            let mapped = ClaudeError.from(transportError: error)
            logger.error("Claude request failed: model=\(model) error=\(mapped.logName) duration=\(Self.elapsed(since: started))")
            throw mapped
        }

        let status = response.statusCode
        guard (200..<300).contains(status) else {
            // Текст помилки сервера може потрапити в `lastError`/UI, тож проходить повне редагування:
            // шаблон `sk-ant-…`, відомі секрети логера і ключ поточного запиту.
            let logger = self.logger
            let mapped = ClaudeError.from(
                status: status,
                retryAfterHeader: response.value(forHTTPHeaderField: "retry-after"),
                body: data,
                redact: { Self.redact($0, logger: logger, apiKey: apiKey) }
            )
            logger.error(
                "Claude request failed: model=\(model) status=\(status) error=\(mapped.logName) "
                    + "duration=\(Self.elapsed(since: started))"
            )
            throw mapped
        }
        logger.info("Claude request ok: model=\(model) status=\(status) duration=\(Self.elapsed(since: started))")
        return data
    }

    /// Повне редагування тексту, що може вийти за межі клієнта.
    static func redact(_ text: String, logger: RedactingLogger, apiKey: String) -> String {
        var result = logger.redact(text)
        if apiKey.count >= RedactingLogger.minimumSecretLength {
            result = result.replacingOccurrences(of: apiKey, with: RedactingLogger.redactedMarker)
        }
        return result
    }

    private static func elapsed(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }
}
