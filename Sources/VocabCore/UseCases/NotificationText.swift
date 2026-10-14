import Foundation

/// Текст системного сповіщення (заголовок + тіло).
public struct NotificationContent: Equatable, Sendable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    /// Один рядок для показу в меню (`AppModel.lastServiceMessage`): тіло, якщо воно вже містить заголовок
    /// на початку, інакше «заголовок: тіло» (або лише заголовок, якщо тіло порожнє).
    public var singleLine: String {
        if body.isEmpty {
            return title
        }
        if body.hasPrefix(title) {
            return body
        }
        return "\(title): \(body)"
    }
}

/// Тексти сповіщень для результатів `AddWordUseCase` (§9).
public enum NotificationText {
    /// Скільки перекладів показувати в сповіщенні.
    public static let maxTranslations = 3

    public static func make(for outcome: AddWordOutcome) -> NotificationContent {
        switch outcome {
        case .added(let entry):
            let display = selectionDisplay(entry)
            let translations = translationsText(display)
            let body = translations.isEmpty ? "Додано: \(display.word)" : "Додано: \(display.word) — \(translations)"
            return NotificationContent(title: "Додано", body: body)

        case .duplicate(let entry):
            let details: String
            switch entry.status {
            case .ready:
                let display = selectionDisplay(entry)
                let translations = translationsText(display)
                details = translations.isEmpty ? display.word : "\(display.word) — \(translations)"
            case .pending, .failed:
                details = "\(entry.word) — очікує обробки"
            }
            return NotificationContent(title: "Вже є в словнику", body: details)

        case .queued(let entry, let error):
            guard let error else {
                // D17: запис уже обробляється паралельним проходом черги.
                return NotificationContent(title: "Обробляється", body: "Обробляється: \(entry.word)")
            }
            let reason: String
            switch error {
            case .offline:
                reason = "немає мережі, переклад буде додано пізніше"
            case .missingAPIKey:
                reason = "додайте API-ключ у налаштуваннях"
            case .storage:
                // Збій запису на диск, а не мережі (не «Помилка мережі»).
                reason = "не вдалося зберегти запис, повторимо пізніше"
            default:
                reason = "повторимо пізніше"
            }
            return NotificationContent(title: "Збережено в чергу", body: "\(entry.word): \(reason)")

        case .failed(let entry, let error):
            return NotificationContent(title: "Не вдалося додати", body: "\(entry.word): \(error.userMessage)")

        case .rejected(let rejection):
            return NotificationContent(title: rejectedTitle, body: rejectionText(rejection))

        case .storageError(let message):
            return NotificationContent(title: "Не вдалося додати", body: message)
        }
    }

    /// Заголовок сповіщень про відхилене виділення.
    public static let rejectedTitle = "Не додано"

    /// Текст причини відхилення виділення (D3).
    public static func rejectionText(_ rejection: SelectionRejection) -> String {
        switch rejection {
        case .empty:
            return "Нічого не виділено"
        case .tooLong(let max):
            return "Виділено забагато тексту (макс. \(max) символів)"
        case .tooManyWords(let max):
            return "Виділено забагато тексту (макс. \(max) слів)"
        case .noLetters:
            return "Виділений текст не містить слів"
        }
    }

    /// M7 (§9): відображення мовою виділення (`entry.sourceLanguage`; `nil` → як раніше). Якщо варіант мови
    /// виділення не ready — англійське відображення.
    private static func selectionDisplay(_ entry: Entry) -> EntryDisplay {
        let display = EntryDisplay.make(entry, languageID: entry.sourceLanguage)
        return display.isFallback ? EntryDisplay.make(entry, languageID: nil) : display
    }

    private static func translationsText(_ display: EntryDisplay) -> String {
        display.translations.prefix(maxTranslations).joined(separator: ", ")
    }
}
