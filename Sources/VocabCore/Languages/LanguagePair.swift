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
    /// M7: код мови джерела — значення `source_language` для первинного відображення, напр. `"en"`.
    public let sourceLanguageCode: String
    /// M7: підпис сегмента перемикача для мови джерела, напр. `"EN"`.
    public let sourceShortTitle: String
    /// M7: додаткові мови відображення записів пари (§3.2). Порожньо → поведінка M2 (без детекції й варіантів).
    public let renderings: [RenderingLanguage]

    /// `sourceLanguageCode` за замовчуванням — `id` до першого `-`; `sourceShortTitle` — `sourceLanguageCode`
    /// у верхньому регістрі; `renderings` — порожньо. Наявні виклики (M1–M6) компілюються без змін.
    public init(
        id: String,
        sourceLanguageName: String,
        targetLanguageName: String,
        speechLanguageCode: String,
        prompt: PromptTemplate,
        sourceLanguageCode: String? = nil,
        sourceShortTitle: String? = nil,
        renderings: [RenderingLanguage] = []
    ) {
        self.id = id
        self.sourceLanguageName = sourceLanguageName
        self.targetLanguageName = targetLanguageName
        self.speechLanguageCode = speechLanguageCode
        self.prompt = prompt
        let code = sourceLanguageCode ?? String(id.split(separator: "-", maxSplits: 1).first ?? Substring(id))
        self.sourceLanguageCode = code
        self.sourceShortTitle = sourceShortTitle ?? code.uppercased()
        self.renderings = renderings
    }

    /// Мова відображення пари за id (`"it"`), або `nil`.
    public func rendering(id: String) -> RenderingLanguage? {
        renderings.first { $0.id == id }
    }

    /// Допустимі значення `source_language` (§3.2): мова джерела + мови відображення.
    public var allowedSourceLanguages: [String] {
        [sourceLanguageCode] + renderings.map(\.id)
    }
}
