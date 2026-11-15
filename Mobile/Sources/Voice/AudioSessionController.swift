// Жива аудіосесія (IOS_PLAN §2, iU14). Протокол `AudioSessionControlling` — у `VoiceSupport.swift` (без
// AVFoundation, тайпчекається на Linux); ця реалізація існує лише там, де є `AVAudioSession` (iOS).
#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Foundation

/// `AVAudioSession.sharedInstance()`: `.record`/`.measurement` на час розпізнавання (без обробки голосу системою,
/// як рекомендує Apple для `SFSpeechRecognizer`) ↔ `.playback`/`.spokenAudio` перед озвученням (інакше після запису
/// `AVSpeechSynthesizer` мовчить у категорії `.record`).
@MainActor
final class AudioSessionController: AudioSessionControlling {
    init() {}

    func activateForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: [.notifyOthersOnDeactivation])
    }

    func activateForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
    }

    /// Вимикає сесію й повертає типову категорію `.soloAmbient`: категорія переживає `setActive(false)`, і без
    /// цього озвучення в інших екранах (деталі запису) після запису лишилося б у `.record` — без звуку.
    func deactivate() throws {
        let session = AVAudioSession.sharedInstance()
        var firstError: Error?
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            firstError = error
        }
        do {
            try session.setCategory(.soloAmbient, mode: .default, options: [])
        } catch {
            firstError = firstError ?? error
        }
        if let firstError {
            throw firstError
        }
    }
}
#endif
