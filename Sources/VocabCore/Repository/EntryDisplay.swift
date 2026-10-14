import Foundation

/// Те, що показується в рядку таблиці для активної мови відображення (§6, M7). Чиста логіка.
///
/// - Режим мови джерела (`languageID == nil`): поля запису як є.
/// - Режим варіанта з ready-варіантом: поля варіанта.
/// - Режим варіанта без ready-варіанта (missing/stale/pending/failed): `isFallback = true`, `word` — англійське
///   слово (UI показує його приглушеним з бейджем), `lemma`/`partOfSpeech`/`transcription`/`example` — `nil`,
///   `translations` — `[]`.
public struct EntryDisplay: Equatable, Identifiable, Sendable {
    public let entry: Entry
    /// `nil` = мова джерела пари.
    public let languageID: String?
    public let word: String
    public let lemma: String?
    public let partOfSpeech: String?
    public let transcription: String?
    public let translations: [String]
    public let example: Example?
    /// Показуємо англійське слово, бо варіант не ready.
    public let isFallback: Bool
    /// `nil` у режимі джерела; інакше `entry.variantState(languageID)`.
    public let state: VariantState?

    public var id: UUID {
        entry.id
    }

    public init(
        entry: Entry,
        languageID: String?,
        word: String,
        lemma: String?,
        partOfSpeech: String?,
        transcription: String?,
        translations: [String],
        example: Example?,
        isFallback: Bool,
        state: VariantState?
    ) {
        self.entry = entry
        self.languageID = languageID
        self.word = word
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.transcription = transcription
        self.translations = translations
        self.example = example
        self.isFallback = isFallback
        self.state = state
    }

    public static func make(_ entry: Entry, languageID: String?) -> EntryDisplay {
        guard let languageID else {
            return EntryDisplay(
                entry: entry,
                languageID: nil,
                word: entry.word,
                lemma: entry.lemma,
                partOfSpeech: entry.partOfSpeech,
                transcription: entry.transcription,
                translations: entry.translations,
                example: entry.example,
                isFallback: false,
                state: nil
            )
        }
        let state = entry.variantState(languageID)
        if state == .ready, let variant = entry.variants?[languageID], let variantWord = variant.word {
            return EntryDisplay(
                entry: entry,
                languageID: languageID,
                word: variantWord,
                lemma: variant.lemma,
                partOfSpeech: variant.partOfSpeech,
                transcription: variant.transcription,
                translations: variant.translations,
                example: variant.example,
                isFallback: false,
                state: state
            )
        }
        return EntryDisplay(
            entry: entry,
            languageID: languageID,
            word: entry.word,
            lemma: nil,
            partOfSpeech: nil,
            transcription: nil,
            translations: [],
            example: nil,
            isFallback: true,
            state: state
        )
    }
}
