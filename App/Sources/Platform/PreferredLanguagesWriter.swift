import Foundation

/// Запис `AppleLanguages` у домені застосунку (M9, D36/D37): системні рядки AppKit/SwiftUI (стандартні кнопки,
/// `NSOpenPanel`) після перезапуску йдуть обраною мовою. Протокол — щоб тести не чіпали реальні `UserDefaults`.
protocol PreferredLanguagesWriting {
    /// Поточне значення `AppleLanguages` саме в домені застосунку (без глобального домену); `nil` — не задано
    /// або невідомо.
    var appleLanguages: [String]? { get }
    func setAppleLanguages(_ codes: [String])
}

extension PreferredLanguagesWriting {
    /// За замовчуванням значення невідоме → `InterfaceLanguageBootstrap` записує завжди.
    var appleLanguages: [String]? {
        nil
    }
}

/// Реальний запис у `UserDefaults.standard` (домен застосунку).
struct UserDefaultsPreferredLanguagesWriter: PreferredLanguagesWriting {
    static let key = "AppleLanguages"

    private let defaults: UserDefaults
    private let domainName: String?

    init(defaults: UserDefaults = .standard, domainName: String? = Bundle.main.bundleIdentifier) {
        self.defaults = defaults
        self.domainName = domainName
    }

    var appleLanguages: [String]? {
        // `stringArray(forKey:)` повернув би й системний список із глобального домену — тут потрібен лише
        // persistent-домен застосунку.
        guard let domainName else { return nil }
        return defaults.persistentDomain(forName: domainName)?[Self.key] as? [String]
    }

    func setAppleLanguages(_ codes: [String]) {
        defaults.set(codes, forKey: Self.key)
    }
}
