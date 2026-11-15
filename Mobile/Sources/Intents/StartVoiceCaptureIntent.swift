import Foundation
#if canImport(AppIntents)
import AppIntents
#endif

/// Логіка «Додати голосом» без `AppIntents` (тестується на Linux): відкриває аркуш додавання в режимі голосу через
/// `Router` процесу (`AppContainer.shared.router`) — той самий маршрут, що й `vocabapp://voice[?lang=…]`. Аркуш
/// забирає запит (`Router.takeVoiceCapture()`) і одразу слухає, якщо дозволи вже є (I2b).
@MainActor
enum StartVoiceCaptureRunner {
    /// `language`: `nil` / `.auto` — остання вибрана мова голосу.
    static func run(language: VoiceLanguageAppEnum?, router: Router) {
        router.open(.voiceCapture(languageID: VoiceLanguageAppEnum.voiceLanguage(for: language)?.rawValue))
    }
}

#if canImport(AppIntents)
/// Siri / Швидкі команди / кнопка дії: «Додати голосом» (IOS_PLAN §7 I4). `openAppWhenRun = true` — система
/// відкриває застосунок, далі `perform` (головний актор) лише змінює маршрут. Без `authenticationPolicy`: на
/// заблокованому iPhone відкриття застосунку однаково вимагає розблокування.
/// Рядки метаданих читає система (DI17): ключ — англійський текст, переклад — `uk.lproj/Localizable.strings`.
struct StartVoiceCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Add by Voice"
    static let description = IntentDescription("Opens VocabApp and starts listening for a word.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Language")
    var language: VoiceLanguageAppEnum?

    static var parameterSummary: some ParameterSummary {
        Summary("Add a word by voice in \(\.$language)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        StartVoiceCaptureRunner.run(language: language, router: AppContainer.shared.router)
        return .result()
    }
}
#endif
