import Foundation

/// Що робити із записом після помилки Claude (§8.1, D6).
public enum ErrorDisposition {
    /// - Parameters:
    ///   - error: помилка поточної спроби.
    ///   - attempts: кількість **попередніх** зарахованих невдалих спроб (до поточної).
    ///   - maxAttempts: після стількох зарахованих невдач запис стає `failed`.
    /// - Returns: новий статус запису і чи зараховується поточна спроба в лічильник.
    ///
    /// | помилка | статус | лічильник |
    /// |---|---|---|
    /// | `.offline`, `.missingAPIKey` | `pending` | ні |
    /// | `.timeout`, `.rateLimited`, `.server`, `.transport` | `pending`, на `maxAttempts`-й — `failed` | так |
    /// | `.unauthorized`, `.forbidden`, `.badRequest`, `.invalidResponse`, `.refused` | `failed` | ні |
    public static func `for`(
        _ error: ClaudeError,
        attempts: Int,
        maxAttempts: Int = RetryPolicy.defaultMaxAttempts
    ) -> (status: EntryStatus, countsAttempt: Bool) {
        switch error {
        case .offline, .missingAPIKey:
            return (.pending, false)
        case .timeout, .rateLimited, .server, .transport:
            let total = attempts + 1
            return (total >= maxAttempts ? .failed : .pending, true)
        case .unauthorized, .forbidden, .badRequest, .invalidResponse, .refused:
            return (.failed, false)
        }
    }
}
