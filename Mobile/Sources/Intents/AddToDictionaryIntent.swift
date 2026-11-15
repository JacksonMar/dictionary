#if canImport(AppIntents)
import AppIntents
import Foundation

/// Siri / Швидкі команди: «Додати до словника» (IOS_PLAN §7 I4). Виконується **в процесі застосунку** без його
/// відкриття (`openAppWhenRun = false`, iU5) і користується тим самим `AppContainer.shared` (словник, Keychain DI8,
/// черга). Уся логіка — у `AddToDictionaryRunner` (тестується без `AppIntents`); тут лише метадані й діалог.
///
/// `authenticationPolicy = .requiresAuthentication`: на заблокованому iPhone система спершу просить розблокувати —
/// API-ключ у Keychain доступний лише після розблокування (`WhenUnlocked`).
/// Рядки метаданих читає система (DI17): ключ — англійський текст, переклад — `uk.lproj/Localizable.strings`.
struct AddToDictionaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Dictionary"
    static let description: IntentDescription? = IntentDescription("Translates a word or a short phrase with Claude and saves it to VocabApp.")
    static let openAppWhenRun: Bool = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Word", requestValueDialog: "Which word?")
    var text: String

    @Parameter(title: "Language")
    var language: VoiceLanguageAppEnum?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to the dictionary") {
            \.$language
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let runner = AddToDictionaryRunner(container: AppContainer.shared)
        let response = await runner.run(text: text, language: language)
        // Інтерполяція: текст уже локалізовано `L10n` (мовою інтерфейсу застосунку), а не ключ таблиці рядків.
        return .result(dialog: "\(response.dialog)")
    }
}
#endif
