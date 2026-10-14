import Foundation

/// Додаткове відображення запису іншою мовою (§3.2, M7), напр. італійське `correre` для `run`.
/// Зберігається в `Entry.variants[<id мови>]`. Власного `updatedAt` немає (D24, D30).
public struct EntryVariant: Codable, Equatable, Sendable {
    /// Слово мовою варіанта; `nil` для `pending`/`failed`.
    public var word: String?
    public var lemma: String?
    /// `"phrase"` для фраз.
    public var partOfSpeech: String?
    /// IPA мови варіанта, напр. `"/korˈrere/"`.
    public var transcription: String?
    /// Українські переклади слова варіанта; порожній для `pending`/`failed`.
    public var translations: [String]
    /// `source` — речення мовою варіанта, `translation` — українською.
    public var example: Example?
    public var status: EntryStatus
    /// Опис останньої помилки доповнення (без секретів).
    public var lastError: String?
    /// `TextNormalizer.key(entry.word)` на момент генерації (D23): не збігається → варіант застарів.
    public var sourceKey: String

    public init(
        word: String? = nil,
        lemma: String? = nil,
        partOfSpeech: String? = nil,
        transcription: String? = nil,
        translations: [String] = [],
        example: Example? = nil,
        status: EntryStatus,
        lastError: String? = nil,
        sourceKey: String
    ) {
        self.word = word
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.transcription = transcription
        self.translations = translations
        self.example = example
        self.status = status
        self.lastError = lastError
        self.sourceKey = sourceKey
    }

    /// Готовий варіант з провалідованого результату Claude.
    public init(result: LookupResult, sourceKey: String) {
        self.init(
            word: result.word,
            lemma: result.lemma,
            partOfSpeech: result.partOfSpeech,
            transcription: result.transcription.isEmpty ? nil : result.transcription,
            translations: result.translations,
            example: result.example,
            status: .ready,
            lastError: nil,
            sourceKey: sourceKey
        )
    }

    /// Порожній варіант, що чекає на доповнення (або остаточно невдалий, якщо `status == .failed`).
    public static func unfilled(status: EntryStatus = .pending, sourceKey: String, lastError: String? = nil) -> EntryVariant {
        EntryVariant(status: status, lastError: lastError, sourceKey: sourceKey)
    }

    private enum CodingKeys: String, CodingKey {
        case word, lemma, partOfSpeech, transcription, translations, example, status, lastError, sourceKey
    }

    /// `translations` може бути відсутнім (→ `[]`); `status` і `sourceKey` обов'язкові — інакше помилка
    /// декодування, і `Entry` відкидає цей варіант (D22).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decodeIfPresent(String.self, forKey: .word)
        lemma = try container.decodeIfPresent(String.self, forKey: .lemma)
        partOfSpeech = try container.decodeIfPresent(String.self, forKey: .partOfSpeech)
        transcription = try container.decodeIfPresent(String.self, forKey: .transcription)
        translations = try container.decodeIfPresent([String].self, forKey: .translations) ?? []
        example = try container.decodeIfPresent(Example.self, forKey: .example)
        status = try container.decode(EntryStatus.self, forKey: .status)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        sourceKey = try container.decode(String.self, forKey: .sourceKey)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(word, forKey: .word)
        try container.encodeIfPresent(lemma, forKey: .lemma)
        try container.encodeIfPresent(partOfSpeech, forKey: .partOfSpeech)
        try container.encodeIfPresent(transcription, forKey: .transcription)
        try container.encode(translations, forKey: .translations)
        try container.encodeIfPresent(example, forKey: .example)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(sourceKey, forKey: .sourceKey)
    }
}

/// Стан варіанта запису для конкретної мови (§3.2).
public enum VariantState: Equatable, Sendable {
    /// Варіанта немає.
    case missing
    /// Варіант згенеровано для іншого `word` (запис відредаговано, D23).
    case stale
    case pending
    case failed
    case ready
}

extension Entry {
    /// Стан варіанта мови `languageID`. `stale` має пріоритет над статусом; варіант мови `sourceLanguage`
    /// (слово, виділене користувачем) ніколи не `stale`.
    public func variantState(_ languageID: String) -> VariantState {
        guard let variant = variants?[languageID] else {
            return .missing
        }
        if languageID != sourceLanguage && variant.sourceKey != TextNormalizer.key(word) {
            return .stale
        }
        switch variant.status {
        case .ready:
            // Готовий варіант без слова — фактично відсутній (захист від некоректних даних).
            guard let variantWord = variant.word, !TextNormalizer.clean(variantWord).isEmpty else {
                return .missing
            }
            return .ready
        case .pending:
            return .pending
        case .failed:
            return .failed
        }
    }

    /// Варіант, який можна показувати: `ready` і не застарілий.
    public func readyVariant(_ languageID: String) -> EntryVariant? {
        guard variantState(languageID) == .ready else { return nil }
        return variants?[languageID]
    }

    /// Ключі дедуплікації нового слова (D26): `key(word)` і `key(v.word)` кожного ready-варіанта.
    public func dedupKeys() -> Set<String> {
        var keys: Set<String> = [TextNormalizer.key(word)]
        for languageID in (variants ?? [:]).keys {
            if let variantWord = readyVariant(languageID)?.word {
                keys.insert(TextNormalizer.key(variantWord))
            }
        }
        return keys
    }
}
