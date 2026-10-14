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

    /// - Parameter selection: сирий виділений текст запиту (Services). Для `.duplicate` визначає мову, ключ якої
    ///   збігся з виділенням (`duplicateLanguage`); `nil` — як раніше (мова `entry.sourceLanguage`).
    public static func make(for outcome: AddWordOutcome, selection: String? = nil) -> NotificationContent {
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
                let display = selection.map { duplicateDisplay(entry, selection: $0) } ?? selectionDisplay(entry)
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

    /// Мова, ключ якої збігся з виділенням (D26): id ready-варіанта `x`, якщо `key(selection) == key(x.word)`;
    /// `nil` — англійське слово запису (зокрема коли ключ збігається і з `entry.word`, D25) або збігу немає.
    public static func duplicateLanguage(selection: String, entry: Entry) -> String? {
        let selectionKey = TextNormalizer.key(TextNormalizer.clean(selection))
        guard !selectionKey.isEmpty, selectionKey != TextNormalizer.key(entry.word) else {
            return nil
        }
        // Сортування — детермінований вибір, якщо кілька варіантів мають однаковий ключ.
        for languageID in (entry.variants ?? [:]).keys.sorted() {
            if let variantWord = entry.readyVariant(languageID)?.word, TextNormalizer.key(variantWord) == selectionKey {
                return languageID
            }
        }
        return nil
    }

    /// Відображення дубля мовою, ключ якої збігся з виділенням; інакше англійське.
    private static func duplicateDisplay(_ entry: Entry, selection: String) -> EntryDisplay {
        let display = EntryDisplay.make(entry, languageID: duplicateLanguage(selection: selection, entry: entry))
        return display.isFallback ? EntryDisplay.make(entry, languageID: nil) : display
    }

    private static func translationsText(_ display: EntryDisplay) -> String {
        display.translations.prefix(maxTranslations).joined(separator: ", ")
    }
}
