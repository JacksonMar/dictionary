import Foundation
import VocabCore

/// Вміст рядка списку (чиста логіка поза SwiftUI, щоб тайпчекатися й тестуватися без UI).
/// Бейджі — як macOS `StatusActionsCell` (M7): статус запису важливіший за стан варіанта.
struct EntryRowContent: Equatable, Identifiable {
    enum BadgeKind: Equatable {
        case pending
        case failed
    }

    struct Badge: Equatable {
        let title: String
        let kind: BadgeKind
    }

    let id: UUID
    let word: String
    let transcription: String?
    /// Переклади через кому (порожньо для fallback-рядка без ready-варіанта).
    let translations: String
    /// «приклад — переклад прикладу» або `nil`.
    let example: String?
    /// Варіант не ready: показується англійське слово (приглушено) з бейджем.
    let isFallback: Bool
    let badge: Badge?
    /// Статус запису (для свайпів «Повторити» / «Оновити італійський»).
    let status: EntryStatus

    static func make(
        _ display: EntryDisplay,
        rendering: RenderingLanguage?,
        language: AppLanguage = L10n.current
    ) -> EntryRowContent {
        EntryRowContent(
            id: display.id,
            word: display.word,
            transcription: nonEmpty(display.transcription),
            translations: display.translations.joined(separator: ", "),
            example: exampleText(display.example),
            isFallback: display.isFallback,
            badge: badge(for: display, rendering: rendering, language: language),
            status: display.entry.status
        )
    }

    static func badge(for display: EntryDisplay, rendering: RenderingLanguage?, language: AppLanguage) -> Badge? {
        switch display.entry.status {
        case .pending:
            return Badge(title: L10n.text(.tableBadgePending, language: language), kind: .pending)
        case .failed:
            return Badge(title: L10n.text(.tableBadgeFailed, language: language), kind: .failed)
        case .ready:
            break
        }
        guard let state = display.state, state != .ready else { return nil }
        if state == .failed {
            return Badge(title: L10n.text(.tableBadgeFailed, language: language), kind: .failed)
        }
        return Badge(title: variantPendingTitle(rendering: rendering, language: language), kind: .pending)
    }

    /// «Italian version pending» / «італійська версія очікує»; інші мови — нейтральне формулювання.
    static func variantPendingTitle(rendering: RenderingLanguage?, language: AppLanguage) -> String {
        guard let rendering else {
            return L10n.text(.tableBadgePending, language: language)
        }
        if rendering.id == "it" {
            return L10n.text(.renderingItalianPendingBadge, language: language)
        }
        return L10n.text(.renderingOtherPendingBadge, ["language": rendering.shortTitle], language: language)
    }

    private static func exampleText(_ example: Example?) -> String? {
        guard let example, let source = nonEmpty(example.source) else { return nil }
        guard let translation = nonEmpty(example.translation) else { return source }
        return "\(source) — \(translation)"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
