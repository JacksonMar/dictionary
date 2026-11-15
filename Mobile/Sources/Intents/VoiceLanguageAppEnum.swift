import Foundation
#if canImport(AppIntents)
import AppIntents
#endif

/// Параметр «Мова» дій Siri / Швидких команд (IOS_PLAN §7 I4): «Авто» / «Англійська» / «Італійська».
///
/// Сам enum і відображення на мову — чисті (Foundation), тож тайпчекаються й тестуються на Linux; відповідність
/// `AppEnum` (метадані для системи) — нижче, лише там, де є `AppIntents`.
enum VoiceLanguageAppEnum: String, CaseIterable, Sendable {
    case auto
    case english
    case italian

    /// Мова голосу / підказка; `nil` — «Авто»: без підказки для тексту (мову визначає Claude, D25) і остання вибрана
    /// мова для голосового введення.
    var voiceLanguage: VoiceLanguage? {
        Self.voiceLanguage(for: self)
    }

    /// Підказка мови для `AddWordUseCase.execute(rawText:sourceLanguageHint:)` (DI13): `"en"` / `"it"` / `nil`.
    var languageHint: String? {
        voiceLanguage?.languageHint
    }

    /// Мова для `AppRoute.voiceCapture(languageID:)`: `"en"` / `"it"` / `nil` (остання вибрана).
    var voiceLanguageID: String? {
        voiceLanguage?.rawValue
    }

    /// Чисте відображення параметра intent-а (зокрема відсутнього, `nil`) на мову голосу.
    static func voiceLanguage(for value: VoiceLanguageAppEnum?) -> VoiceLanguage? {
        switch value {
        case .english?:
            return .english
        case .italian?:
            return .italian
        case .auto?, nil:
            return nil
        }
    }
}

#if canImport(AppIntents)
// Рядки метаданих читає система (DI17): ключ — англійський текст, переклад — `Mobile/Resources/uk.lproj/Localizable.strings`.
extension VoiceLanguageAppEnum: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Language"

    static let caseDisplayRepresentations: [VoiceLanguageAppEnum: DisplayRepresentation] = [
        .auto: "Auto",
        .english: "English",
        .italian: "Italian",
    ]
}
#endif
