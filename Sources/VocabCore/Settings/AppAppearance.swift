import Foundation

/// Тема застосунку (§7.6, D20, M6). Зберігається в `SettingsStore.appearance` (ключ `appearance`, rawValue).
public enum AppAppearance: String, CaseIterable, Sendable {
    /// Як у системі (за замовчуванням).
    case system
    case light
    case dark

    /// Назва в налаштуваннях поточною мовою інтерфейсу.
    public var title: String {
        title(in: L10n.current)
    }

    public func title(in language: AppLanguage) -> String {
        switch self {
        case .system:
            return L10n.text(.appearanceSystem, language: language)
        case .light:
            return L10n.text(.appearanceLight, language: language)
        case .dark:
            return L10n.text(.appearanceDark, language: language)
        }
    }
}
