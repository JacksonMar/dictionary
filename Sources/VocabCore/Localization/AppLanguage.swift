import Foundation

/// Мова інтерфейсу застосунку (M9, D32). Вміст словника (переклади українською) від неї не залежить.
public enum AppLanguage: String, CaseIterable, Sendable {
    case en
    case uk

    /// Мова за замовчуванням (нова установка, відсутнє чи невідоме збережене значення).
    public static let `default`: AppLanguage = .en

    /// Двомовна мітка перемикача в налаштуваннях: однаково зрозуміла за будь-якої поточної мови.
    public static let pickerLabel = "Interface language / Мова інтерфейсу"

    /// Значення з `UserDefaults` (`rawValue`); `nil` або невідоме → `.default`.
    public init(storedValue: String?) {
        let trimmed = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = AppLanguage(rawValue: trimmed) ?? .default
    }

    /// Мова за списком мов системи (`Locale.preferredLanguages`, напр. `["uk-UA", "en-US"]`): перша підтримувана
    /// за порядком переваги; жодної → `.default`. Для процесів, які не бачать налаштувань застосунку (Share
    /// Extension: `UserDefaults` застосунку йому недоступні, IOS_PLAN I3).
    public init(preferredLanguages: [String]) {
        for identifier in preferredLanguages {
            let code = identifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first
                .map(String.init) ?? ""
            if let language = AppLanguage(rawValue: code) {
                self = language
                return
            }
        }
        self = .default
    }

    /// Автонім — назва мови нею самою (не ключ таблиці, щоб користувач знайшов свою мову за будь-якого UI).
    public var nativeName: String {
        switch self {
        case .en:
            return "English"
        case .uk:
            return "Українська"
        }
    }
}
