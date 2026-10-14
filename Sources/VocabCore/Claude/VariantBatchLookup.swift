import Foundation

/// Один запис у пакетному запиті доповнення варіантів (§7.7).
public struct VariantRequestItem: Equatable, Sendable {
    /// 1…n у межах пакета (не UUID — економія токенів).
    public var ref: Int
    /// Англійське `entry.word`.
    public var word: String
    /// `SelectionValidator.kind(of: word)`.
    public var kind: SelectionKind
    public var partOfSpeech: String?
    /// До 3 перших `translations` запису — щоб модель взяла те саме значення.
    public var meaning: [String]
    /// Лише `refresh` для запису з італійським виділенням: слово, яке треба зберегти (§8.4).
    public var keepWord: String?

    public static let maxMeaningCount = 3

    public init(
        ref: Int,
        word: String,
        kind: SelectionKind,
        partOfSpeech: String? = nil,
        meaning: [String] = [],
        keepWord: String? = nil
    ) {
        self.ref = ref
        self.word = word
        self.kind = kind
        self.partOfSpeech = partOfSpeech
        self.meaning = Array(meaning.prefix(Self.maxMeaningCount))
        self.keepWord = keepWord
    }
}

/// Результат одного елемента пакета.
public enum VariantItemOutcome: Equatable, Sendable {
    case ready(LookupResult)
    /// Елемент є, але не пройшов валідацію (причина — без секретів).
    case invalid(String)
    /// Модель не повернула елемент з цим `id`.
    case missing
}

/// Пакетне доповнення варіантів однієї мови (§7.7). Рівно один HTTP-запит на виклик, без повтору.
public protocol VariantBatchLookupService: Sendable {
    /// Ключ результату — `ref`; кожен запитаний `ref` присутній у результаті.
    func lookupVariants(
        items: [VariantRequestItem],
        language: RenderingLanguage,
        pair: LanguagePair
    ) async throws -> [Int: VariantItemOutcome]
}

extension ClaudeLookupService: VariantBatchLookupService {
    /// Той самий ключ/модель/логер/клієнт, що й для слова, але `max_tokens = batchMaxTokens` (8192) і **без
    /// повтору** того самого промту: обрізаний пакет ділить `VariantBackfillProcessor`, іншу невалідну відповідь
    /// обробляють спроби черги доповнення.
    public func lookupVariants(
        items: [VariantRequestItem],
        language: RenderingLanguage,
        pair: LanguagePair
    ) async throws -> [Int: VariantItemOutcome] {
        guard !items.isEmpty else { return [:] }
        let apiKey = try readAPIKey()
        var configuration = currentConfiguration()
        configuration.maxTokens = ClaudeConfiguration.batchMaxTokens
        let prompt = VariantPromptBuilder.buildBatch(items: items, language: language, pair: pair)
        return try await attempt(prompt: prompt, apiKey: apiKey, configuration: configuration) { data in
            let response = try LookupResponseParser.extract(fromMessagesResponse: data)
            return try LookupResponseParser.rethrowingTruncation(stopReason: response.stopReason) {
                try VariantBatchResponseParser.parse(response.text, items: items)
            }
        }
    }
}
