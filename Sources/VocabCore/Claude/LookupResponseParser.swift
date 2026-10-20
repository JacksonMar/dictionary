import Foundation

/// Провалідований результат пошуку слова.
public struct LookupResult: Equatable, Sendable {
    public var word: String
    public var lemma: String
    public var partOfSpeech: String
    /// Може бути порожнім для фрази.
    public var transcription: String
    public var translations: [String]
    public var example: Example
    /// M7: визначена мова виділення (`source_language`, §7.7) — код мови пари або id мови відображення.
    /// `nil` для пари без `renderings` (поведінка M2) і у вкладених результатах.
    public var sourceLanguage: String?
    /// M7: провалідовані відображення за id мови (`"it"`); порожньо для пари без `renderings` і у вкладених.
    public var variants: [String: LookupResult]

    public init(
        word: String,
        lemma: String,
        partOfSpeech: String,
        transcription: String,
        translations: [String],
        example: Example,
        sourceLanguage: String? = nil,
        variants: [String: LookupResult] = [:]
    ) {
        self.word = word
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.transcription = transcription
        self.translations = translations
        self.example = example
        self.sourceLanguage = sourceLanguage
        self.variants = variants
    }
}

/// Текст відповіді Messages API разом зі `stop_reason`.
public struct MessagesResponseText: Equatable, Sendable {
    public var text: String
    public var stopReason: String?

    public init(text: String, stopReason: String?) {
        self.text = text
        self.stopReason = stopReason
    }
}

/// Розбір і валідація відповіді Claude (§7.4).
public enum LookupResponseParser {
    public static let phrasePartOfSpeech = "phrase"
    public static let maxTranslations = 10
    /// Причина `.invalidResponse` для відповіді, обрізаної через `max_tokens` (§7.4, §7.7).
    public static let maxTokensReason = "max_tokens"

    /// Повний розбір тіла відповіді Messages API: конверт → текст → JSON → `LookupResult`.
    /// `stop_reason == "refusal"` → `.refused`; `stop_reason == "max_tokens"` з текстом, що не проходить
    /// валідацію → `.invalidResponse("max_tokens")`; повна валідна відповідь при `max_tokens` приймається.
    public static func parseMessagesResponse(_ data: Data, kind: SelectionKind) throws -> LookupResult {
        let response = try extract(fromMessagesResponse: data)
        return try rethrowingTruncation(stopReason: response.stopReason) {
            try parse(response.text, kind: kind)
        }
    }

    /// M7: те саме для комбінованої відповіді пари (`parse(_:kind:pair:selectionKey:)`).
    public static func parseMessagesResponse(
        _ data: Data,
        kind: SelectionKind,
        pair: LanguagePair,
        selectionKey: String
    ) throws -> LookupResult {
        let response = try extract(fromMessagesResponse: data)
        return try rethrowingTruncation(stopReason: response.stopReason) {
            try parse(response.text, kind: kind, pair: pair, selectionKey: selectionKey)
        }
    }

    /// Помилка розбору при `stop_reason == "max_tokens"` → `.invalidResponse(maxTokensReason)`.
    static func rethrowingTruncation<T>(stopReason: String?, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            if stopReason == "max_tokens" {
                throw ClaudeError.invalidResponse(maxTokensReason)
            }
            throw error
        }
    }

    /// Конкатенація всіх блоків `type == "text"` (інші, напр. `thinking`, ігноруються).
    /// `stop_reason == "refusal"` → `ClaudeError.refused`.
    public static func extractText(fromMessagesResponse data: Data) throws -> String {
        try extract(fromMessagesResponse: data).text
    }

    /// Те саме, що `extractText`, але разом зі `stop_reason`.
    public static func extract(fromMessagesResponse data: Data) throws -> MessagesResponseText {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any] else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseEnvelopeNotObject))
        }
        let stopReason = envelope["stop_reason"] as? String
        if stopReason == "refusal" {
            throw ClaudeError.refused
        }
        guard let content = envelope["content"] as? [Any] else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseMissingField, ["name": "content"]))
        }
        let text = content
            .compactMap { $0 as? [String: Any] }
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return MessagesResponseText(text: text, stopReason: stopReason)
    }

    /// Розбір і валідація тексту моделі. Для `.phrase` `partOfSpeech` примусово `"phrase"`.
    public static func parse(_ text: String, kind: SelectionKind) throws -> LookupResult {
        try parseObject(try jsonObject(in: text), kind: kind)
    }

    /// M7 (§7.7): комбінована відповідь з детекцією мови. Пара без `renderings` → `parse(_:kind:)` (M2).
    /// 1. Верхній рівень валідується як у M2 (невалідний → `.invalidResponse`).
    /// 2. `source_language` з допустимого набору береться; інакше/відсутній — виводиться: виділення збігається
    ///    з `word` варіанта `x`, але не з верхнім `word` → `x`, інакше код мови пари.
    /// 3. Кожен `variants.<id>` для мов пари валідується тими ж правилами; невалідний/відсутній просто не
    ///    потрапляє в результат — **крім** варіанта мови виділення (тоді вся відповідь невалідна).
    /// 4. Невідомі id у `variants` ігноруються.
    /// - Parameter selectionKey: `TextNormalizer.key` виділеного тексту.
    public static func parse(
        _ text: String,
        kind: SelectionKind,
        pair: LanguagePair,
        selectionKey: String
    ) throws -> LookupResult {
        guard !pair.renderings.isEmpty else {
            return try parse(text, kind: kind)
        }
        let object = try jsonObject(in: text)
        var result = try parseObject(object, kind: kind)

        let rawVariants = object["variants"] as? [String: Any] ?? [:]
        var variants: [String: LookupResult] = [:]
        for rendering in pair.renderings {
            guard let variantObject = rawVariants[rendering.id] as? [String: Any],
                  let variant = try? parseObject(variantObject, kind: kind) else {
                continue
            }
            variants[rendering.id] = variant
        }

        let allowed = pair.allowedSourceLanguages
        let declared = (object["source_language"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let sourceLanguage: String
        if let declared, allowed.contains(declared) {
            sourceLanguage = declared
        } else {
            sourceLanguage = inferredSourceLanguage(
                topWord: result.word,
                variants: variants,
                pair: pair,
                selectionKey: selectionKey
            )
        }
        if sourceLanguage != pair.sourceLanguageCode && variants[sourceLanguage] == nil {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseMissingSourceVariant, ["language": sourceLanguage]))
        }
        result.sourceLanguage = sourceLanguage
        result.variants = variants
        return result
    }

    /// Мова виділення без (коректного) `source_language`: збіг ключа виділення з варіантом, але не з верхнім рівнем.
    private static func inferredSourceLanguage(
        topWord: String,
        variants: [String: LookupResult],
        pair: LanguagePair,
        selectionKey: String
    ) -> String {
        guard TextNormalizer.key(topWord) != selectionKey else {
            return pair.sourceLanguageCode
        }
        for rendering in pair.renderings {
            if let variant = variants[rendering.id], TextNormalizer.key(variant.word) == selectionKey {
                return rendering.id
            }
        }
        return pair.sourceLanguageCode
    }

    /// Валідація одного об'єкта відповіді (верхній рівень, варіант або елемент пакета) за правилами §7.4.
    static func parseObject(_ object: [String: Any], kind: SelectionKind) throws -> LookupResult {
        let word = try requiredString(object, "word")
        let partOfSpeech = try requiredString(object, "part_of_speech")

        guard let exampleObject = object["example"] as? [String: Any] else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseMissingField, ["name": "example"]))
        }
        let exampleSource = try requiredString(exampleObject, "source", path: "example.source")
        let exampleTranslation = try requiredString(exampleObject, "translation", path: "example.translation")

        let translations = try validatedTranslations(object["translations"])

        let lemma: String
        switch object["lemma"] {
        case nil, is NSNull:
            lemma = word
        case let value as String:
            let trimmed = trim(value)
            lemma = trimmed.isEmpty ? word : trimmed
        default:
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseFieldNotString, ["name": "lemma"]))
        }

        let transcription: String
        switch object["transcription"] {
        case let value as String:
            transcription = trim(value)
        case nil, is NSNull:
            transcription = ""
        default:
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseFieldNotString, ["name": "transcription"]))
        }
        if kind == .word && transcription.isEmpty {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseEmptyField, ["name": "transcription"]))
        }

        return LookupResult(
            word: word,
            lemma: lemma,
            partOfSpeech: kind == .phrase ? phrasePartOfSpeech : partOfSpeech,
            transcription: transcription,
            translations: translations,
            example: Example(source: exampleSource, translation: exampleTranslation)
        )
    }

    // MARK: - Private

    /// Знімає обгортку ```` ```json … ``` ````, бере підрядок від першої `{` до останньої `}`.
    static func jsonObject(in text: String) throws -> [String: Any] {
        let unfenced = stripCodeFence(trim(text))
        guard let start = unfenced.firstIndex(of: "{"),
              let end = unfenced.lastIndex(of: "}"),
              start < end else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseNoJSONObject))
        }
        let candidate = String(unfenced[start...end])
        guard let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)),
              let dictionary = object as? [String: Any] else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseInvalidJSON))
        }
        return dictionary
    }

    static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var body = Substring(text)
        // Перший рядок: ``` або ```json.
        if let newline = body.firstIndex(where: \.isNewline) {
            body = body[body.index(after: newline)...]
        } else {
            body = body.dropFirst(3)
        }
        let trimmedBody = trim(String(body))
        if trimmedBody.hasSuffix("```") {
            return trim(String(trimmedBody.dropLast(3)))
        }
        return trimmedBody
    }

    private static func requiredString(_ object: [String: Any], _ key: String, path: String? = nil) throws -> String {
        let name = path ?? key
        guard let value = object[key] else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseMissingField, ["name": name]))
        }
        guard let string = value as? String else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseFieldNotString, ["name": name]))
        }
        let trimmed = trim(string)
        guard !trimmed.isEmpty else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseEmptyField, ["name": name]))
        }
        return trimmed
    }

    private static func validatedTranslations(_ value: Any?) throws -> [String] {
        guard let value else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseMissingField, ["name": "translations"]))
        }
        guard let array = value as? [Any] else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseFieldNotArray, ["name": "translations"]))
        }
        var result: [String] = []
        for element in array {
            guard let string = element as? String else {
                throw ClaudeError.invalidResponse(L10n.text(.claudeParseNonStringElement, ["name": "translations"]))
            }
            let trimmed = trim(string)
            if !trimmed.isEmpty && !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        guard !result.isEmpty else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseEmptyList, ["name": "translations"]))
        }
        guard result.count <= maxTranslations else {
            throw ClaudeError.invalidResponse(L10n.text(.claudeParseTooMany, ["name": "translations"]))
        }
        return result
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
