import Foundation

/// Готовий промт: системне повідомлення + текст user-повідомлення.
public struct BuiltPrompt: Equatable, Sendable {
    public var system: String
    public var user: String

    public init(system: String, user: String) {
        self.system = system
        self.user = user
    }
}

/// Побудова промту з шаблонів мовної пари (§7.3). Виділений текст підставляється замість `{{TEXT}}`
/// (у шаблонах він обгорнутий у `<text>…</text>`).
///
/// M7 (§7.7): для пари з непорожнім `renderings` — комбінований промт (один запит на всі мови):
/// `system` = system пари (з «this shape, plus the extra keys requested below» замість «exactly this shape» і
/// без назви мови джерела в «For the … word or phrase») + інструкція детекції мови + `combinedInstruction`
/// кожної мови відображення; `user` — шаблон пари без назви мови джерела («Translate this word…»).
/// Для пари без `renderings` промт **рівно** як у M2.
///
/// M8 (D31): якщо `pair.prompt.domainInstruction` непорожня, вона додається в кінець system (один раз, в обох
/// режимах). `domainInstruction` мов відображення сюди не додається.
public enum PromptBuilder {
    /// Рядок, що додається в кінець user-повідомлення при повторі після невалідної відповіді (§7.5).
    public static let retrySuffix = "Попередня відповідь була невалідною. Поверни лише JSON."

    /// Фраза system-промту M2, що забороняє додаткові ключі; у комбінованому промті замінюється на
    /// `extendedShapePhrase`.
    public static let exactShapePhrase = "exactly this shape"
    public static let extendedShapePhrase = "this shape, plus the extra keys requested below"

    public static func build(text: String, kind: SelectionKind, pair: LanguagePair) -> BuiltPrompt {
        let template: String
        switch kind {
        case .word: template = pair.prompt.userWord
        case .phrase: template = pair.prompt.userPhrase
        }
        guard !pair.renderings.isEmpty else {
            let user = template.replacingOccurrences(of: PromptTemplate.textPlaceholder, with: text)
            let system = withDomainInstruction(pair.prompt.system, pair.prompt.domainInstruction)
            return BuiltPrompt(system: system, user: user)
        }
        let user = neutralizedUserTemplate(template, pair: pair)
            .replacingOccurrences(of: PromptTemplate.textPlaceholder, with: text)
        let system = withDomainInstruction(combinedSystem(for: pair), pair.prompt.domainInstruction)
        return BuiltPrompt(system: system, user: user)
    }

    /// M8 (D31): `system + "\n\n" + instruction`, якщо інструкція непорожня; інакше `system` без змін.
    static func withDomainInstruction(_ system: String, _ instruction: String) -> String {
        instruction.isEmpty ? system : system + "\n\n" + instruction
    }

    /// Той самий промт з інструкцією повернути лише JSON у кінці user-повідомлення.
    public static func retrying(_ prompt: BuiltPrompt) -> BuiltPrompt {
        BuiltPrompt(system: prompt.system, user: prompt.user + "\n\n" + retrySuffix)
    }

    // MARK: - M7: комбінований промт

    /// System-промт комбінованого запиту (пара з `renderings`). Виділений текст сюди не потрапляє.
    static func combinedSystem(for pair: LanguagePair) -> String {
        let base = pair.prompt.system
            .replacingOccurrences(of: exactShapePhrase, with: extendedShapePhrase)
            .replacingOccurrences(
                of: "For the \(pair.sourceLanguageName) word or phrase",
                with: "For the word or phrase"
            )
        var parts = [base, detectionInstruction(for: pair)]
        parts.append(contentsOf: pair.renderings.map(\.prompt.combinedInstruction))
        return parts.joined(separator: "\n\n")
    }

    /// Інструкція автовизначення мови виділення та форми `variants` (§7.7, D25).
    static func detectionInstruction(for pair: LanguagePair) -> String {
        let source = pair.sourceLanguageName
        let names = [source] + pair.renderings.map(\.languageName)
        let codes = pair.allowedSourceLanguages.map { "\"\($0)\"" }
        let variantKeys = pair.renderings.map { "\"\($0.id)\" (\($0.languageName))" }
        let sourceCode = "\"\(pair.sourceLanguageCode)\""
        return """
        Extra keys requested:
        - "source_language": the language of the text inside <text>, one of \(codes.joined(separator: ", ")) \
        (\(names.joined(separator: ", "))). If the text is a valid word or phrase in more than one of these \
        languages, use \(sourceCode). If it is in none of them, use \(sourceCode) and translate it as best you can.
        - The top-level keys ("word", "lemma", "part_of_speech", "transcription", "translations", "example") \
        always describe the \(source) rendering. If the text is not \(source), "word" is the \(source) word or \
        phrase with the same meaning, and every rule above applies to that \(source) word.
        - "variants": an object with one key per language: \(variantKeys.joined(separator: ", ")). Each value is an \
        object with the same keys as the top level ("word", "lemma", "part_of_speech", "transcription", \
        "translations", "example"), describing the same meaning in that language, following the rules below.
        Shape of the whole object: {"source_language": \(sourceCode), "word": "…", "lemma": "…", \
        "part_of_speech": "…", "transcription": "…", "translations": ["…"], \
        "example": {"source": "…", "translation": "…"}, "variants": {\(variantShape(for: pair))}}
        """
    }

    private static func variantShape(for pair: LanguagePair) -> String {
        pair.renderings
            .map { "\"\($0.id)\": {\"word\": \"…\", \"lemma\": \"…\", \"part_of_speech\": \"…\", "
                + "\"transcription\": \"…\", \"translations\": [\"…\"], "
                + "\"example\": {\"source\": \"…\", \"translation\": \"…\"}}" }
            .joined(separator: ", ")
    }

    /// Шаблон user-повідомлення без назви мови джерела («this English word» → «this word»).
    static func neutralizedUserTemplate(_ template: String, pair: LanguagePair) -> String {
        template
            .replacingOccurrences(of: "this \(pair.sourceLanguageName) word", with: "this word")
            .replacingOccurrences(of: "this \(pair.sourceLanguageName) phrase", with: "this phrase")
    }
}
