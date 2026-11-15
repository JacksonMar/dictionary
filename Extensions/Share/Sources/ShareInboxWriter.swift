import Foundation
import VocabCore

/// Чим закінчилось збереження в листі «Поділитися».
enum ShareSaveOutcome: Equatable, Sendable {
    /// Слово лежить в inbox; `truncated` — текст обрізано до `ShareTextExtractor.maxLength`.
    case saved(truncated: Bool)
    /// Немає тексту (лише URL / порожньо).
    case empty
    /// Немає App Group (ключ Info.plist не підставлено або контейнер не видано) — нічого не збережено.
    case unavailable
    /// Inbox переповнено (`InboxError.full`).
    case full
    /// Помилка файлової системи; текст — без вмісту слова.
    case failed(reason: String)

    var isSuccess: Bool {
        if case .saved = self {
            return true
        }
        return false
    }

    /// Повідомлення для `ShareView` мовою `language`.
    func message(language: AppLanguage) -> String {
        switch self {
        case .saved(let truncated):
            let saved = L10n.text(.shareSaved, language: language)
            guard truncated else { return saved }
            let note = L10n.text(.shareSavedTruncated, ["max": String(ShareTextExtractor.maxLength)], language: language)
            return saved + "\n" + note
        case .empty:
            return L10n.text(.shareEmpty, language: language)
        case .unavailable:
            return L10n.text(.shareUnavailable, language: language)
        case .full:
            return L10n.text(.shareFull, language: language)
        case .failed(let reason):
            return L10n.text(.shareFailed, ["reason": reason], language: language)
        }
    }
}

/// Логіка розширення без UIKit (IOS_PLAN DI7, §3.3): вилучений текст → `InboxItem` (`source = .share`, без
/// підказки мови) → `InboxStore.enqueue` у каталозі inbox App Group. Розширення не викликає Claude, не читає
/// Keychain і не пише словник — переклад робить застосунок при наступній активації.
enum ShareInboxWriter {
    /// `directory == nil` — App Group недоступна (`InboxLocation.live()`).
    static func save(
        _ extraction: ShareTextExtraction,
        directory: URL?,
        fileSystem: FileSystem = LocalFileSystem(),
        now: Date = Date()
    ) -> ShareSaveOutcome {
        guard case .accepted(let text, let truncated) = extraction else {
            return .empty
        }
        guard let directory else {
            return .unavailable
        }
        let store = InboxStore(directory: directory, fileSystem: fileSystem)
        do {
            try store.enqueue(InboxItem(text: text, source: .share, createdAt: now))
            return .saved(truncated: truncated)
        } catch InboxError.full {
            return .full
        } catch InboxError.storage(let reason) {
            return .failed(reason: reason)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Мова інтерфейсу розширення: `UserDefaults` застосунку йому недоступні (не спільні), тож — за мовами
    /// системи (`Locale.preferredLanguages`): перша з EN/UK, інакше EN.
    static func interfaceLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        AppLanguage(preferredLanguages: preferredLanguages)
    }
}
