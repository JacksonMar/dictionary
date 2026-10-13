import Foundation

/// Шаблони промту для мовної пари. Плейсхолдер `{{TEXT}}` замінюється виділеним текстом.
public struct PromptTemplate: Hashable, Sendable {
    public static let textPlaceholder = "{{TEXT}}"

    /// Системний промт: JSON-схема, правила, мова перекладу.
    public let system: String
    /// Шаблон user-повідомлення для одного слова.
    public let userWord: String
    /// Шаблон user-повідомлення для фрази.
    public let userPhrase: String

    public init(system: String, userWord: String, userPhrase: String) {
        self.system = system
        self.userWord = userWord
        self.userPhrase = userPhrase
    }
}

/// Опис мовної пари. Нова пара = нове значення `LanguagePair` + реєстрація в `LanguagePairRegistry`.
public struct LanguagePair: Hashable, Sendable {
    /// Ідентифікатор, що зберігається в `Entry.languagePair`, напр. `"en-uk"`.
    public let id: String
    public let sourceLanguageName: String
    public let targetLanguageName: String
    /// Код мови для `AVSpeechSynthesisVoice(language:)`, напр. `"en-US"`.
    public let speechLanguageCode: String
    public let prompt: PromptTemplate

    public init(
        id: String,
        sourceLanguageName: String,
        targetLanguageName: String,
        speechLanguageCode: String,
        prompt: PromptTemplate
    ) {
        self.id = id
        self.sourceLanguageName = sourceLanguageName
        self.targetLanguageName = targetLanguageName
        self.speechLanguageCode = speechLanguageCode
        self.prompt = prompt
    }
}
