import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Помилки звернення до Claude (§7.5). Жодна не містить API-ключа.
public enum ClaudeError: Error, Equatable {
    case missingAPIKey
    /// Немає з'єднання: `.notConnectedToInternet`, `.networkConnectionLost`, `.cannotFindHost`,
    /// `.cannotConnectToHost`, `.dnsLookupFailed`, `.dataNotAllowed`, `.internationalRoamingOff`.
    case offline
    /// `URLError.timedOut`.
    case timeout
    /// HTTP 401.
    case unauthorized
    /// HTTP 403 (і 402 — billing).
    case forbidden
    /// HTTP 429; `retry-after` у секундах, якщо є.
    case rateLimited(retryAfter: TimeInterval?)
    /// HTTP 500…599, включно з 529 overloaded.
    case server(status: Int)
    /// HTTP 400, 404 (невідома модель), 413, інші 4xx. `message` — з тіла помилки, ≤ 200 символів.
    case badRequest(status: Int, message: String)
    /// Невалідний JSON / порушення схеми / обрізання через `max_tokens`.
    case invalidResponse(String)
    /// `stop_reason == "refusal"`.
    case refused
    /// Інші помилки транспорту (включно з `cancelled`).
    case transport(String)
}

extension ClaudeError {
    public static let maxErrorMessageLength = 200

    /// Україномовний опис для UI і `Entry.lastError`. Без секретів.
    public var userMessage: String {
        switch self {
        case .missingAPIKey:
            return "Немає API-ключа. Додайте його в налаштуваннях"
        case .offline:
            return "Немає мережі"
        case .timeout:
            return "Claude не відповів вчасно"
        case .unauthorized:
            return "Невірний API-ключ (401)"
        case .forbidden:
            return "Доступ заборонено (403): перевірте ключ і баланс"
        case .rateLimited:
            return "Забагато запитів (429)"
        case .server(let status):
            return "Помилка сервера Claude (\(status))"
        case .badRequest(let status, let message):
            return message.isEmpty ? "Помилка запиту (\(status))" : "Помилка запиту (\(status)): \(message)"
        case .invalidResponse(let reason):
            return "Невалідна відповідь Claude: \(reason)"
        case .refused:
            return "Claude відмовився відповідати"
        case .transport(let reason):
            return "Помилка мережі: \(reason)"
        }
    }

    /// Коротка назва для логу (без деталей і секретів).
    public var logName: String {
        switch self {
        case .missingAPIKey: return "missingAPIKey"
        case .offline: return "offline"
        case .timeout: return "timeout"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .rateLimited: return "rateLimited"
        case .server(let status): return "server(\(status))"
        case .badRequest(let status, _): return "badRequest(\(status))"
        case .invalidResponse: return "invalidResponse"
        case .refused: return "refused"
        case .transport: return "transport"
        }
    }

    // MARK: - Mapping

    /// Помилка транспорту → `ClaudeError`. `URLError` (або `NSError` з `NSURLErrorDomain`) мапиться за кодом.
    public static func from(transportError error: Error) -> ClaudeError {
        if let claudeError = error as? ClaudeError {
            return claudeError
        }
        if let urlError = error as? URLError {
            return from(urlErrorCode: urlError.code)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            // `init(rawValue:)` не failable на Darwin і failable у swift-corelibs-foundation.
            let code: URLError.Code? = URLError.Code(rawValue: nsError.code)
            if let code {
                return from(urlErrorCode: code)
            }
            return .transport("URLError \(nsError.code)")
        }
        return .transport(nsError.domain)
    }

    public static func from(urlErrorCode code: URLError.Code) -> ClaudeError {
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timeout
        case .cancelled:
            return .transport("cancelled")
        default:
            return .transport("URLError \(code.rawValue)")
        }
    }

    /// HTTP-статус поза 2xx → `ClaudeError`. `retryAfter` — значення заголовка `retry-after`,
    /// `body` — тіло відповіді (для `message` у `badRequest`).
    public static func from(status: Int, retryAfterHeader: String?, body: Data) -> ClaudeError {
        switch status {
        case 401:
            return .unauthorized
        case 402, 403:
            return .forbidden
        case 429:
            return .rateLimited(retryAfter: parseRetryAfter(retryAfterHeader))
        case 500...599:
            return .server(status: status)
        case 400...499:
            return .badRequest(status: status, message: errorMessage(from: body))
        default:
            return .transport("HTTP \(status)")
        }
    }

    /// `retry-after` у секундах (ціле або дробове, ≥ 0); інший формат → `nil`.
    static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 else {
            return nil
        }
        return seconds
    }

    /// `error.message` з тіла `{"type":"error","error":{"type","message"}}`, обрізане до 200 символів;
    /// шаблон ключа `sk-ant-…` вирізається. Інакше — порожній рядок.
    static func errorMessage(from body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return ""
        }
        let redacted = RedactingLogger.redactAPIKeyPattern(
            message.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return String(redacted.prefix(maxErrorMessageLength))
    }
}
