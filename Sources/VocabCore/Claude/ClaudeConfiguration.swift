import Foundation

/// Параметри виклику Messages API (§7.1).
public struct ClaudeConfiguration: Equatable, Sendable {
    // Літерал URL коректний за побудовою; force unwrap дозволено §1.4 для констант-літералів.
    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"
    public static let defaultModel = SettingsDefaults.model
    public static let defaultMaxTokens = 4096
    public static let defaultTimeout: TimeInterval = 30

    public var endpoint: URL
    public var model: String
    public var maxTokens: Int
    public var timeout: TimeInterval

    public init(
        endpoint: URL = ClaudeConfiguration.defaultEndpoint,
        model: String = ClaudeConfiguration.defaultModel,
        maxTokens: Int = ClaudeConfiguration.defaultMaxTokens,
        timeout: TimeInterval = ClaudeConfiguration.defaultTimeout
    ) {
        self.endpoint = endpoint
        self.model = model
        self.maxTokens = maxTokens
        self.timeout = timeout
    }
}
