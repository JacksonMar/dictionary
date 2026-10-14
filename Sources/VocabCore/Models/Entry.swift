import Foundation

/// Запис словника. Ключі JSON збігаються з іменами властивостей (camelCase, див. REQUIREMENTS.md).
/// Опційні поля при кодуванні пропускаються, якщо `nil` (`encodeIfPresent`).
///
/// M7: `variants` (додаткові відображення, §3.2) і `sourceLanguage` (мова виділення, D25) — адитивні опційні
/// поля; запис без них кодується байт-у-байт як у M6 (D21). Некоректний варіант при декодуванні відкидається,
/// не ламаючи запис (D22).
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
    /// M7: відображення іншими мовами за id мови (`"it"`). `nil`/порожній → ключ у JSON відсутній.
    /// Змінюються лише через `DictionaryRepository.setVariants`, `update(_:replacingVariants: true)` та імпорт.
    public var variants: [String: EntryVariant]?
    /// M7: мова виділеного тексту, якщо вона не мова джерела пари (зараз лише `"it"`); `nil` = мова пари.
    public var sourceLanguage: String?

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
        updatedAt: Date,
        variants: [String: EntryVariant]? = nil,
        sourceLanguage: String? = nil
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
        self.variants = variants
        self.sourceLanguage = sourceLanguage
    }

    private enum CodingKeys: String, CodingKey {
        case id, languagePair, word, lemma, partOfSpeech, transcription, translations, example, status, lastError
        case createdAt, updatedAt, variants, sourceLanguage
    }

    /// Поля M1–M6 декодуються суворо (як синтезований `Codable`); `variants` — поелементно: некоректний варіант
    /// (не той тип, невідомий `status`, відсутній `sourceKey`) відкидається. `variants`, що не є об'єктом,
    /// і некоректний `sourceLanguage` ігноруються.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        languagePair = try container.decode(String.self, forKey: .languagePair)
        word = try container.decode(String.self, forKey: .word)
        lemma = try container.decodeIfPresent(String.self, forKey: .lemma)
        partOfSpeech = try container.decodeIfPresent(String.self, forKey: .partOfSpeech)
        transcription = try container.decodeIfPresent(String.self, forKey: .transcription)
        translations = try container.decode([String].self, forKey: .translations)
        example = try container.decodeIfPresent(Example.self, forKey: .example)
        status = try container.decode(EntryStatus.self, forKey: .status)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        let lenientVariants = (try? container.decodeIfPresent([String: LenientVariant].self, forKey: .variants)) ?? nil
        var decodedVariants: [String: EntryVariant] = [:]
        for (languageID, wrapper) in lenientVariants ?? [:] {
            if let variant = wrapper.value {
                decodedVariants[languageID] = variant
            }
        }
        variants = decodedVariants.isEmpty ? nil : decodedVariants

        let rawSourceLanguage = (try? container.decodeIfPresent(String.self, forKey: .sourceLanguage)) ?? nil
        let trimmedSourceLanguage = rawSourceLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sourceLanguage = trimmedSourceLanguage.isEmpty ? nil : trimmedSourceLanguage
    }

    /// Еквівалент синтезованого кодування; порожній `variants` не пишеться.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(languagePair, forKey: .languagePair)
        try container.encode(word, forKey: .word)
        try container.encodeIfPresent(lemma, forKey: .lemma)
        try container.encodeIfPresent(partOfSpeech, forKey: .partOfSpeech)
        try container.encodeIfPresent(transcription, forKey: .transcription)
        try container.encode(translations, forKey: .translations)
        try container.encodeIfPresent(example, forKey: .example)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        if let variants, !variants.isEmpty {
            try container.encode(variants, forKey: .variants)
        }
        try container.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
    }
}

/// Обгортка для стійкого декодування одного варіанта: помилка → `nil` замість помилки всього запису.
private struct LenientVariant: Decodable {
    let value: EntryVariant?

    init(from decoder: Decoder) throws {
        value = try? EntryVariant(from: decoder)
    }
}
