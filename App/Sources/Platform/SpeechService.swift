import AVFoundation
import Foundation

/// Озвучення слів (§11). Протокол — щоб `AppModel` тестувався без відтворення звуку.
@MainActor
protocol SpeechSpeaking: AnyObject {
    /// Озвучує `text` голосом мови `languageCode` (BCP-47, напр. `en-US` з `LanguagePair.speechLanguageCode`).
    /// Попереднє озвучення переривається.
    func speak(_ text: String, languageCode: String)
    func stop()
}

/// `AVSpeechSynthesizer` з англійським (для пари `en-uk`) голосом.
///
/// Синтезатор — властивість (а не локальна змінна): інакше його буде звільнено до кінця відтворення.
/// Створюється ліниво, щоб саме створення сервісу (напр. під XCTest) не чіпало аудіосистему.
@MainActor
final class SpeechService: SpeechSpeaking {
    private lazy var synthesizer = AVSpeechSynthesizer()

    /// Код мови останнього запиту (для діагностики й тестів).
    private(set) var lastRequestedLanguageCode: String?

    init() {}

    func speak(_ text: String, languageCode: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastRequestedLanguageCode = languageCode
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        synthesizer.speak(makeUtterance(text: trimmed, languageCode: languageCode))
    }

    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Висловлювання без відтворення (M5.3). `voice` може бути `nil`, якщо в системі нема голосу цієї мови
    /// (U11, напр. CI-раннер) — тоді система використає голос за замовчуванням.
    func makeUtterance(text: String, languageCode: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(forLanguageCode: languageCode)
        return utterance
    }

    /// Голос для мови: точний код (`en-US`) → для англійської `en-GB` → будь-який голос тієї ж мови (`en-*`) → `nil`.
    nonisolated static func voice(forLanguageCode code: String) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: code) {
            return exact
        }
        let base = baseLanguage(of: code)
        if base == "en", code.lowercased() != "en-gb", let british = AVSpeechSynthesisVoice(language: "en-GB") {
            return british
        }
        return AVSpeechSynthesisVoice.speechVoices().first { voice in
            baseLanguage(of: voice.language) == base
        }
    }

    /// `en-US` → `en`, `en_GB` → `en`.
    nonisolated static func baseLanguage(of code: String) -> String {
        let separators = CharacterSet(charactersIn: "-_")
        return code.components(separatedBy: separators).first?.lowercased() ?? code.lowercased()
    }
}
