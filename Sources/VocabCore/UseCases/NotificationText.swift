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
    /// - Parameter language: мова інтерфейсу (за замовчуванням — `L10n.current`).
    public static func make(
        for outcome: AddWordOutcome,
        selection: String? = nil,
        language: AppLanguage = L10n.current
    ) -> NotificationContent {
        switch outcome {
        case .added(let entry):
            let display = selectionDisplay(entry)
            let translations = translationsText(display)
            let body = translations.isEmpty
                ? L10n.text(.notificationAddedBody, ["word": display.word], language: language)
                : L10n.text(
                    .notificationAddedBodyWithTranslations,
                    ["word": display.word, "translations": translations],
                    language: language
                )
            return NotificationContent(title: L10n.text(.notificationAddedTitle, language: language), body: body)

        case .duplicate(let entry):
            let details: String
            switch entry.status {
            case .ready:
                let display = selection.map { duplicateDisplay(entry, selection: $0) } ?? selectionDisplay(entry)
                let translations = translationsText(display)
                details = translations.isEmpty ? display.word : "\(display.word) — \(translations)"
            case .pending, .failed:
                details = L10n.text(.notificationDuplicatePending, ["word": entry.word], language: language)
            }
            return NotificationContent(title: L10n.text(.notificationDuplicateTitle, language: language), body: details)

        case .queued(let entry, let error):
            guard let error else {
                // D17: запис уже обробляється паралельним проходом черги.
                return NotificationContent(
                    title: L10n.text(.notificationProcessingTitle, language: language),
                    body: L10n.text(.notificationProcessingBody, ["word": entry.word], language: language)
                )
            }
            let reasonKey: L10nKey
            switch error {
            case .offline:
                reasonKey = .notificationQueuedOffline
            case .missingAPIKey:
                reasonKey = .notificationQueuedMissingKey
            case .storage:
                // Збій запису на диск, а не мережі (не «Помилка мережі»).
                reasonKey = .notificationQueuedStorage
            default:
                reasonKey = .notificationQueuedLater
            }
            let reason = L10n.text(reasonKey, language: language)
            return NotificationContent(
                title: L10n.text(.notificationQueuedTitle, language: language),
                body: "\(entry.word): \(reason)"
            )

        case .failed(let entry, let error):
            return NotificationContent(
                title: L10n.text(.notificationFailedTitle, language: language),
                body: "\(entry.word): \(error.userMessage(in: language))"
            )

        case .rejected(let rejection):
            return NotificationContent(
                title: rejectedTitle(in: language),
                body: rejectionText(rejection, language: language)
            )

        case .storageError(let message):
            return NotificationContent(title: L10n.text(.notificationFailedTitle, language: language), body: message)
        }
    }

    /// Заголовок сповіщень про відхилене виділення (поточною мовою інтерфейсу).
    public static var rejectedTitle: String {
        rejectedTitle(in: L10n.current)
    }

    public static func rejectedTitle(in language: AppLanguage) -> String {
        L10n.text(.notificationRejectedTitle, language: language)
    }

    /// Текст причини відхилення виділення (D3).
    public static func rejectionText(_ rejection: SelectionRejection, language: AppLanguage = L10n.current) -> String {
        switch rejection {
        case .empty:
            return L10n.text(.rejectionEmpty, language: language)
        case .tooLong(let max):
            return L10n.text(.rejectionTooLong, ["max": String(max)], language: language)
        case .tooManyWords(let max):
            return L10n.text(.rejectionTooManyWords, ["max": String(max)], language: language)
        case .noLetters:
            return L10n.text(.rejectionNoLetters, language: language)
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
