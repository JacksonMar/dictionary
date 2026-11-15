// Озвучення з повідомленням про завершення (iOS, I2b): після «Озвучити» на картці голосу модель вимикає аудіосесію,
// щоб інші застосунки відновили звук. Спільний з macOS `SpeechService` (App/Sources/Platform) не змінюється — вибір
// голосу береться з нього (`SpeechService.voice(forLanguageCode:)`).
#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Foundation

/// `AVSpeechSynthesizer` + делегат (`didFinish` / `didCancel`). Поводиться як `SpeechService` (перериває попереднє
/// озвучення, порожній текст ігнорує) і додатково викликає `completion` рівно один раз на висловлювання.
/// Синтезатор створюється ліниво (створення сервісу не чіпає аудіосистему).
@MainActor
final class VoiceSpeechService: NSObject, SpeechCompletionReporting {
    private var synthesizer: AVSpeechSynthesizer?
    private var completions: [ObjectIdentifier: @MainActor @Sendable () -> Void] = [:]

    func speak(_ text: String, languageCode: String) {
        speak(text, languageCode: languageCode) {}
    }

    func speak(_ text: String, languageCode: String, completion: @escaping @MainActor @Sendable () -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion()
            return
        }
        let synthesizer = activeSynthesizer()
        if synthesizer.isSpeaking {
            // Попереднє висловлювання отримає `didCancel` → його `completion`.
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = SpeechService.voice(forLanguageCode: languageCode)
        completions[ObjectIdentifier(utterance)] = completion
        synthesizer.speak(utterance)
    }

    func stop() {
        guard let synthesizer, synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func activeSynthesizer() -> AVSpeechSynthesizer {
        if let synthesizer {
            return synthesizer
        }
        let created = AVSpeechSynthesizer()
        created.delegate = self
        synthesizer = created
        return created
    }

    fileprivate func finish(_ id: ObjectIdentifier) {
        completions.removeValue(forKey: id)?()
    }
}

extension VoiceSpeechService: AVSpeechSynthesizerDelegate {
    // Потік виклику делегата не гарантовано — переходимо на головний актор; висловлювання ідентифікуємо за
    // `ObjectIdentifier` (сам `AVSpeechUtterance` не `Sendable`).
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task<Void, Never> { @MainActor [weak self] in
            self?.finish(id)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task<Void, Never> { @MainActor [weak self] in
            self?.finish(id)
        }
    }
}
#endif
