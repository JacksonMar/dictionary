import Foundation

public enum LogLevel: String, Sendable {
    case debug
    case info
    case error
}

/// Приймач уже відредагованих повідомлень.
public protocol LogSink: Sendable {
    func write(level: LogLevel, message: String)
}

/// Друк у stdout (ядро, Linux/CLI).
public struct PrintLogSink: LogSink {
    public init() {}

    public func write(level: LogLevel, message: String) {
        print("[\(level.rawValue)] \(message)")
    }
}

/// Логер, що вирізає секрети перед записом у `LogSink`:
/// (1) кожне входження рядків із `secretsProvider()` довжиною ≥ 8 → `[REDACTED]`;
/// (2) шаблон `sk-ant-[A-Za-z0-9_\-]+` → `sk-ant-[REDACTED]`.
public final class RedactingLogger: Sendable {
    public static let redactedMarker = "[REDACTED]"
    static let minimumSecretLength = 8
    static let apiKeyPattern = "sk-ant-[A-Za-z0-9_\\-]+"

    private let sink: LogSink
    private let secretsProvider: @Sendable () -> [String]

    public init(sink: LogSink, secretsProvider: @escaping @Sendable () -> [String]) {
        self.sink = sink
        self.secretsProvider = secretsProvider
    }

    public func debug(_ message: @autoclosure () -> String) {
        log(.debug, message())
    }

    public func info(_ message: @autoclosure () -> String) {
        log(.info, message())
    }

    public func error(_ message: @autoclosure () -> String) {
        log(.error, message())
    }

    /// Застосовує обидва правила редагування.
    public func redact(_ message: String) -> String {
        var result = message
        for secret in secretsProvider() where secret.count >= Self.minimumSecretLength {
            result = result.replacingOccurrences(of: secret, with: Self.redactedMarker)
        }
        return Self.redactAPIKeyPattern(result)
    }

    /// Лише правило (2): `sk-ant-…` → `sk-ant-[REDACTED]`. Використовується й поза логером
    /// (напр. для тексту помилки від API, що може потрапити в `lastError`).
    public static func redactAPIKeyPattern(_ message: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: apiKeyPattern) else {
            return message
        }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        return regex.stringByReplacingMatches(
            in: message,
            options: [],
            range: range,
            withTemplate: "sk-ant-" + NSRegularExpression.escapedTemplate(for: redactedMarker)
        )
    }

    private func log(_ level: LogLevel, _ message: String) {
        sink.write(level: level, message: redact(message))
    }
}
