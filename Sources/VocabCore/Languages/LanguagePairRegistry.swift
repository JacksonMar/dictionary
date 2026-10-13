import Foundation

/// Потокобезпечний реєстр мовних пар. Порядок реєстрації зберігається; повторна реєстрація з тим самим `id`
/// замінює попереднє визначення.
public final class LanguagePairRegistry: @unchecked Sendable {
    public static let defaultPairID = "en-uk"

    /// Спільний реєстр із вбудованою парою `en-uk`.
    public static let shared = LanguagePairRegistry(pairs: [.englishUkrainian])

    private let lock = NSLock()
    private var pairs: [LanguagePair]

    public init(pairs: [LanguagePair]) {
        var unique: [LanguagePair] = []
        for pair in pairs {
            if let index = unique.firstIndex(where: { $0.id == pair.id }) {
                unique[index] = pair
            } else {
                unique.append(pair)
            }
        }
        self.pairs = unique
    }

    public func register(_ pair: LanguagePair) {
        lock.lock()
        defer { lock.unlock() }
        if let index = pairs.firstIndex(where: { $0.id == pair.id }) {
            pairs[index] = pair
        } else {
            pairs.append(pair)
        }
    }

    public func pair(id: String) -> LanguagePair? {
        lock.lock()
        defer { lock.unlock() }
        return pairs.first { $0.id == id }
    }

    public var all: [LanguagePair] {
        lock.lock()
        defer { lock.unlock() }
        return pairs
    }
}
