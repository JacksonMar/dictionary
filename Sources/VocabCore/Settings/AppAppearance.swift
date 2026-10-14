import Foundation

/// Тема застосунку (§7.6, D20, M6). Зберігається в `SettingsStore.appearance` (ключ `appearance`, rawValue).
public enum AppAppearance: String, CaseIterable, Sendable {
    /// Як у системі (за замовчуванням).
    case system
    case light
    case dark

    /// Назва в налаштуваннях.
    public var title: String {
        switch self {
        case .system:
            return "Як у системі"
        case .light:
            return "Світла"
        case .dark:
            return "Темна"
        }
    }
}
