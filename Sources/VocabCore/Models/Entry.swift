import Foundation

/// Запис словника. Ключі JSON збігаються з іменами властивостей (camelCase, див. REQUIREMENTS.md).
/// Опційні поля при кодуванні пропускаються, якщо `nil` (синтезований `encodeIfPresent`).
public struct Entry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Ідентифікатор мовної пари, напр. `"en-uk"`.
    public var languagePair: String
    public var word: String
    public var lemma: String?
    /// `"phrase"` для фраз.
    public var partOfSpeech: String?
    public var transcription: String?
    /// Порожній для `pending`/`failed`.
    public var translations: [String]
    public var example: Example?
    public var status: EntryStatus
    /// Розширення схеми (D16): опис останньої помилки для `pending`/`failed`. Без секретів.
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        languagePair: String,
        word: String,
        lemma: String? = nil,
        partOfSpeech: String? = nil,
        transcription: String? = nil,
        translations: [String] = [],
        example: Example? = nil,
        status: EntryStatus,
        lastError: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.languagePair = languagePair
        self.word = word
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.transcription = transcription
        self.translations = translations
        self.example = example
        self.status = status
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
