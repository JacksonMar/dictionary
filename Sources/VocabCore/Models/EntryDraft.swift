import Foundation

/// Дані для створення нового запису (без `id` і дат — їх призначає репозиторій).
public struct EntryDraft: Equatable, Sendable {
    public var word: String
    public var languagePair: String
    public var lemma: String?
    public var partOfSpeech: String?
    public var transcription: String?
    public var translations: [String]
    public var example: Example?
    public var status: EntryStatus

    public init(
        word: String,
        languagePair: String,
        lemma: String? = nil,
        partOfSpeech: String? = nil,
        transcription: String? = nil,
        translations: [String] = [],
        example: Example? = nil,
        status: EntryStatus
    ) {
        self.word = word
        self.languagePair = languagePair
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.transcription = transcription
        self.translations = translations
        self.example = example
        self.status = status
    }
}
