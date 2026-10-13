import Foundation

/// Політика авто-повторів pending-записів (§8.2, D7).
public struct RetryPolicy: Equatable, Sendable {
    public static let defaultMaxAttempts = 5

    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var maxAttempts: Int

    public init(baseDelay: TimeInterval = 30, maxDelay: TimeInterval = 900, maxAttempts: Int = RetryPolicy.defaultMaxAttempts) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    /// `min(30 * 2^(n-1), 900)` секунд для `n`-ї невдалої спроби (n ≥ 1): 30 с, 1 хв, 2 хв, 4 хв, 8 хв, далі 15 хв.
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponent = max(0, attempt - 1)
        // Обмеження степеня, щоб не переповнитись; 2^20 * 30 значно більше за maxDelay.
        let factor = pow(2.0, Double(min(exponent, 20)))
        return min(baseDelay * factor, maxDelay)
    }

    /// Для `.rateLimited` — `max(retryAfter ?? 0, delay)`, для інших помилок — `delay`.
    public func delay(forAttempt attempt: Int, error: ClaudeError) -> TimeInterval {
        let base = delay(forAttempt: attempt)
        if case .rateLimited(let retryAfter) = error {
            return max(retryAfter ?? 0, base)
        }
        return base
    }
}
