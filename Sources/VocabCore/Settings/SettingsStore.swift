import Foundation

/// Налаштування застосунку (не секрети). Автозапуск тут не зберігається — істина в `SMAppService` (M5).
public protocol SettingsStore: AnyObject, Sendable {
    /// Модель Claude; порожнє значення → `SettingsDefaults.model`.
    var model: String { get set }
    /// Мовна пара для нових записів; за замовчуванням `en-uk`.
    var languagePairID: String { get set }
    /// Тема застосунку (M6); відсутнє/невідоме значення → `.system`.
    var appearance: AppAppearance { get set }
    /// Записів на сторінці в головному вікні (M6); значення поза `Pagination.pageSizeOptions` →
    /// `Pagination.defaultPageSize`.
    var pageSize: Int { get set }
    /// M7: активна мова відображення (id мови варіанта, напр. `"it"`); `nil` = мова джерела пари («EN»).
    /// Сховище лише зберігає рядок (порожній → `nil`); перевірка «невідома для пари» — в `AppModel`.
    var displayLanguageID: String? { get set }
    /// M9: мова інтерфейсу; відсутнє/невідоме значення → `AppLanguage.default` (`.en`). Застосовується після
    /// перезапуску застосунку (D36).
    var interfaceLanguage: AppLanguage { get set }
}

extension SettingsStore {
    /// Реалізація за замовчуванням для сторонніх сховищ (тестові дублі): англійська, запис ігнорується.
    public var interfaceLanguage: AppLanguage {
        get { .default }
        set { _ = newValue }
    }

    /// Реалізація за замовчуванням для сторонніх сховищ (напр. тестові дублі M6): режим мови джерела, запис
    /// ігнорується. `UserDefaultsSettingsStore` і `InMemorySettingsStore` зберігають значення.
    public var displayLanguageID: String? {
        get { nil }
        set { _ = newValue }
    }
}

public enum SettingsDefaults {
    public static let model = "claude-haiku-5-5"
    public static let languagePairID = LanguagePairRegistry.defaultPairID
}

/// `SettingsStore` поверх `UserDefaults` (потокобезпечний сам по собі).
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public static let modelKey = "claudeModel"
    public static let languagePairKey = "languagePairID"
    public static let appearanceKey = "appearance"
    public static let pageSizeKey = "entriesPageSize"
    public static let displayLanguageKey = "displayLanguage"
    public static let interfaceLanguageKey = "interfaceLanguage"

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

    public var appearance: AppAppearance {
        get { defaults.string(forKey: Self.appearanceKey).flatMap(AppAppearance.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Self.appearanceKey) }
    }

    public var pageSize: Int {
        get {
            // `integer(forKey:)` повертає 0 для відсутнього ключа → нормалізується до значення за замовчуванням.
            Pagination.normalizedPageSize(defaults.integer(forKey: Self.pageSizeKey))
        }
        set { defaults.set(Pagination.normalizedPageSize(newValue), forKey: Self.pageSizeKey) }
    }

    public var displayLanguageID: String? {
        get { Self.normalized(defaults.string(forKey: Self.displayLanguageKey)) }
        set { store(Self.normalized(newValue), forKey: Self.displayLanguageKey) }
    }

    public var interfaceLanguage: AppLanguage {
        get { AppLanguage(storedValue: defaults.string(forKey: Self.interfaceLanguageKey)) }
        set { defaults.set(newValue.rawValue, forKey: Self.interfaceLanguageKey) }
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
    private var storedAppearance: AppAppearance
    private var storedPageSize: Int
    private var storedDisplayLanguageID: String?
    private var storedInterfaceLanguage: AppLanguage

    public init(
        model: String? = nil,
        languagePairID: String? = nil,
        appearance: AppAppearance = .system,
        pageSize: Int = Pagination.defaultPageSize,
        displayLanguageID: String? = nil,
        interfaceLanguage: AppLanguage = .default
    ) {
        self.storedModel = model
        self.storedLanguagePairID = languagePairID
        self.storedAppearance = appearance
        self.storedPageSize = Pagination.normalizedPageSize(pageSize)
        self.storedDisplayLanguageID = displayLanguageID
        self.storedInterfaceLanguage = interfaceLanguage
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

    public var appearance: AppAppearance {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedAppearance
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedAppearance = newValue
        }
    }

    public var pageSize: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedPageSize
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedPageSize = Pagination.normalizedPageSize(newValue)
        }
    }

    public var displayLanguageID: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Self.nonEmpty(storedDisplayLanguageID)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedDisplayLanguageID = newValue
        }
    }

    public var interfaceLanguage: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedInterfaceLanguage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedInterfaceLanguage = newValue
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
