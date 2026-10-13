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
            let translations = translationsText(entry)
            let body = translations.isEmpty ? "Додано: \(entry.word)" : "Додано: \(entry.word) — \(translations)"
            return NotificationContent(title: "Додано", body: body)

        case .duplicate(let entry):
            let details: String
            switch entry.status {
            case .ready:
                let translations = translationsText(entry)
                details = translations.isEmpty ? entry.word : "\(entry.word) — \(translations)"
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

    private static func translationsText(_ entry: Entry) -> String {
        entry.translations.prefix(maxTranslations).joined(separator: ", ")
    }
}
