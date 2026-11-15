import Foundation

/// Потокобезпечний кеш API-ключів — джерело `secretsProvider` для `RedactingLogger` (щоб не читати Keychain на
/// кожен рядок логу). Копія macOS `APIKeyCache` (`App/Sources/AppModel.swift`; DI5 — macOS-код не рефакторимо).
/// Ключі **накопичуються** до перезапуску: після заміни чи видалення старий ключ і далі вирізається з логів.
final class APIKeyCache: @unchecked Sendable {
    // `@unchecked`: `values` читається й пишеться лише під `lock`.
    private let lock = NSLock()
    private var values: Set<String> = []

    init() {}

    /// Додає ключ до множини відомих секретів; `nil`/порожній рядок ігнорується (нічого не видаляє).
    func set(_ newValue: String?) {
        guard let newValue, !newValue.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        values.insert(newValue)
    }

    /// Усі відомі секрети (довші першими, щоб ключ-префікс не лишив хвіст іншого).
    func secrets() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values.sorted { lhs, rhs in
            lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs
        }
    }
}
