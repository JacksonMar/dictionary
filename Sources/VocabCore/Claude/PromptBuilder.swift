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
public enum PromptBuilder {
    /// Рядок, що додається в кінець user-повідомлення при повторі після невалідної відповіді (§7.5).
    public static let retrySuffix = "Попередня відповідь була невалідною. Поверни лише JSON."

    public static func build(text: String, kind: SelectionKind, pair: LanguagePair) -> BuiltPrompt {
        let template: String
        switch kind {
        case .word: template = pair.prompt.userWord
        case .phrase: template = pair.prompt.userPhrase
        }
        let user = template.replacingOccurrences(of: PromptTemplate.textPlaceholder, with: text)
        return BuiltPrompt(system: pair.prompt.system, user: user)
    }

    /// Той самий промт з інструкцією повернути лише JSON у кінці user-повідомлення.
    public static func retrying(_ prompt: BuiltPrompt) -> BuiltPrompt {
        BuiltPrompt(system: prompt.system, user: prompt.user + "\n\n" + retrySuffix)
    }
}
