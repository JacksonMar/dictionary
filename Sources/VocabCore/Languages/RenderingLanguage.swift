import Foundation

/// Шаблони промтів для мови відображення (§3.2, §7.7).
///
/// Тексти — константи для конкретної пари (для `en-uk` англійська/українська записані прямо в тексті).
/// Єдиний плейсхолдер — `{{ITEMS}}` у `batchUser`. Використання мови з іншою парою — окреме значення
/// `RenderingLanguage` у новому файлі (код ядра не змінюється).
public struct RenderingPromptTemplate: Hashable, Sendable {
    /// Плейсхолдер JSON-масиву елементів у `batchUser`.
    public static let itemsPlaceholder = "{{ITEMS}}"

    /// Додається до system-промту пари в комбінованому запиті (нове слово, §7.7): правила для `variants.<id>`.
    public let combinedInstruction: String
    /// System-промт пакетного доповнення (§7.7).
    public let batchSystem: String
    /// Шаблон user-повідомлення пакетного доповнення з плейсхолдером `{{ITEMS}}`.
    public let batchUser: String
    /// M8 (D31): доменна інструкція (IT/QA-контекст) для пакетного доповнення; `VariantPromptBuilder` додає її
    /// в кінець `batchSystem`, якщо вона непорожня. У комбінований промт не додається (там — інструкція пари).
    public let domainInstruction: String

    public init(combinedInstruction: String, batchSystem: String, batchUser: String, domainInstruction: String = "") {
        self.combinedInstruction = combinedInstruction
        self.batchSystem = batchSystem
        self.batchUser = batchUser
        self.domainInstruction = domainInstruction
    }
}

/// Додаткова мова показу записів пари (M7, напр. італійська для `en-uk`). Не `LanguagePair`: записи лишаються
/// в парі джерела, а відображення зберігається в `Entry.variants[id]`.
public struct RenderingLanguage: Hashable, Sendable {
    /// Ключ у `Entry.variants` і значення `source_language`; стабільний, пишеться у файл. Напр. `"it"`.
    public let id: String
    /// Підпис сегмента перемикача, напр. `"IT"`.
    public let shortTitle: String
    /// Англійська назва мови для промтів, напр. `"Italian"`.
    public let languageName: String
    /// Код мови для `AVSpeechSynthesisVoice(language:)`, напр. `"it-IT"`.
    public let speechLanguageCode: String
    public let prompt: RenderingPromptTemplate

    public init(
        id: String,
        shortTitle: String,
        languageName: String,
        speechLanguageCode: String,
        prompt: RenderingPromptTemplate
    ) {
        self.id = id
        self.shortTitle = shortTitle
        self.languageName = languageName
        self.speechLanguageCode = speechLanguageCode
        self.prompt = prompt
    }
}
