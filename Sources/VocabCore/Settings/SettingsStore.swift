import Foundation

/// Налаштування застосунку (не секрети). Автозапуск тут не зберігається — істина в `SMAppService` (M5).
public protocol SettingsStore: AnyObject, Sendable {
    /// Модель Claude; порожнє значення → `SettingsDefaults.model`.
    var model: String { get set }
    /// Мовна пара для нових записів; за замовчуванням `en-uk`.
    var languagePairID: String { get set }
}

public enum SettingsDefaults {
    public static let model = "claude-haiku-5-5"
    public static let languagePairID = LanguagePairRegistry.defaultPairID
}

/// `SettingsStore` поверх `UserDefaults` (потокобезпечний сам по собі).
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public static let modelKey = "claudeModel"
    public static let languagePairKey = "languagePairID"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var model: String {
        get { Self.normalized(defaults.string(forKey: Self.modelKey)) ?? SettingsDefaults.model }
        set { store(Self.normalized(newValue), forKey: Self.modelKey) }
    }

    public var languagePairID: String {
        get { Self.normalized(defaults.string(forKey: Self.languagePairKey)) ?? SettingsDefaults.languagePairID }
        set { store(Self.normalized(newValue), forKey: Self.languagePairKey) }
    }

    private func store(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Обрізає пробіли; порожній рядок → `nil`.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// `SettingsStore` у пам'яті (тести; застосунок під XCTest). Ті самі правила: порожнє значення → default.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedModel: String?
    private var storedLanguagePairID: String?

    public init(model: String? = nil, languagePairID: String? = nil) {
        self.storedModel = model
        self.storedLanguagePairID = languagePairID
    }

    public var model: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Self.nonEmpty(storedModel) ?? SettingsDefaults.model
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedModel = newValue
        }
    }

    public var languagePairID: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Self.nonEmpty(storedLanguagePairID) ?? SettingsDefaults.languagePairID
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedLanguagePairID = newValue
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
