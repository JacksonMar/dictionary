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

    public init(
        word: String,
        lemma: String,
        partOfSpeech: String,
        transcription: String,
        translations: [String],
        example: Example
    ) {
        self.word = word
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.transcription = transcription
        self.translations = translations
        self.example = example
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

    /// Повний розбір тіла відповіді Messages API: конверт → текст → JSON → `LookupResult`.
    /// `stop_reason == "refusal"` → `.refused`; `stop_reason == "max_tokens"` з текстом, що не проходить
    /// валідацію → `.invalidResponse("max_tokens")`; повна валідна відповідь при `max_tokens` приймається.
    public static func parseMessagesResponse(_ data: Data, kind: SelectionKind) throws -> LookupResult {
        let response = try extract(fromMessagesResponse: data)
        do {
            return try parse(response.text, kind: kind)
        } catch {
            if response.stopReason == "max_tokens" {
                throw ClaudeError.invalidResponse("max_tokens")
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
            throw ClaudeError.invalidResponse("відповідь API не є JSON-об'єктом")
        }
        let stopReason = envelope["stop_reason"] as? String
        if stopReason == "refusal" {
            throw ClaudeError.refused
        }
        guard let content = envelope["content"] as? [Any] else {
            throw ClaudeError.invalidResponse("немає поля content")
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
        let object = try jsonObject(in: text)

        let word = try requiredString(object, "word")
        let partOfSpeech = try requiredString(object, "part_of_speech")

        guard let exampleObject = object["example"] as? [String: Any] else {
            throw ClaudeError.invalidResponse("немає поля example")
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
            throw ClaudeError.invalidResponse("поле lemma не є рядком")
        }

        let transcription: String
        switch object["transcription"] {
        case let value as String:
            transcription = trim(value)
        case nil, is NSNull:
            transcription = ""
        default:
            throw ClaudeError.invalidResponse("поле transcription не є рядком")
        }
        if kind == .word && transcription.isEmpty {
            throw ClaudeError.invalidResponse("порожнє поле transcription")
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
            throw ClaudeError.invalidResponse("відповідь не містить JSON-об'єкта")
        }
        let candidate = String(unfenced[start...end])
        guard let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)),
              let dictionary = object as? [String: Any] else {
            throw ClaudeError.invalidResponse("невалідний JSON")
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
            throw ClaudeError.invalidResponse("немає поля \(name)")
        }
        guard let string = value as? String else {
            throw ClaudeError.invalidResponse("поле \(name) не є рядком")
        }
        let trimmed = trim(string)
        guard !trimmed.isEmpty else {
            throw ClaudeError.invalidResponse("порожнє поле \(name)")
        }
        return trimmed
    }

    private static func validatedTranslations(_ value: Any?) throws -> [String] {
        guard let value else {
            throw ClaudeError.invalidResponse("немає поля translations")
        }
        guard let array = value as? [Any] else {
            throw ClaudeError.invalidResponse("поле translations не є масивом")
        }
        var result: [String] = []
        for element in array {
            guard let string = element as? String else {
                throw ClaudeError.invalidResponse("translations містить не рядок")
            }
            let trimmed = trim(string)
            if !trimmed.isEmpty && !result.contains(trimmed) {
                result.append(trimmed)
            }
        }
        guard !result.isEmpty else {
            throw ClaudeError.invalidResponse("порожній список translations")
        }
        guard result.count <= maxTranslations else {
            throw ClaudeError.invalidResponse("забагато translations")
        }
        return result
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
