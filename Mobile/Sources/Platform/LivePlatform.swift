import Foundation
import VocabCore

/// Платформні реалізації для реального запуску (IOS_PLAN DI4, DI8, DI12, DI18). Файли з Security/AVFoundation/os/UIKit
/// (`KeychainSecretStore`, `SpeechService`, `OSLogSink` — спільні з macOS за шляхом у `project.yml`;
/// `UIApplicationBackgroundTaskRunner`) підставляються лише тут, тож `AppContainer` і `MobileAppModel` не імпортують
/// ці фреймворки й тайпчекаються на Linux (там — запасні реалізації з ядра).
enum LivePlatform {
    /// Запасний `kSecAttrService`, якщо `Bundle.main.bundleIdentifier` недоступний.
    static let fallbackKeychainService = "com.vocabapp.VocabMobile"

    /// `kSecAttrService` для API-ключа (DI8): bundle id застосунку (`<prefix>.VocabMobile`).
    static func keychainService(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return fallbackKeychainService }
        return bundleIdentifier
    }

    /// Keychain застосунку (без access groups, DI8).
    static func makeSecretStore(service: String) -> SecretStore {
        #if canImport(Security)
        return KeychainSecretStore(service: service)
        #else
        return InMemorySecretStore()
        #endif
    }

    /// Unified logging (повідомлення вже відредаговані `RedactingLogger`).
    static func makeLogSink(category: String) -> LogSink {
        #if canImport(os)
        return OSLogSink(category: category)
        #else
        return PrintLogSink()
        #endif
    }

    /// `UIApplication.beginBackgroundTask` (DI18).
    @MainActor
    static func makeBackgroundTaskRunner() -> BackgroundTaskRunning {
        #if canImport(UIKit)
        return UIApplicationBackgroundTaskRunner()
        #else
        return NoopBackgroundTaskRunner()
        #endif
    }

    /// Озвучення (`AVSpeechSynthesizer`); `nil` — недоступне.
    @MainActor
    static func makeSpeech() -> SpeechSpeaking? {
        #if canImport(AVFoundation) && os(iOS)
        // I2b: те саме озвучення + сповіщення про завершення (голос вимикає аудіосесію після «Озвучити»).
        return VoiceSpeechService()
        #elseif canImport(AVFoundation)
        return SpeechService()
        #else
        return nil
        #endif
    }

    /// I2b: `SFSpeechRecognizer` + `AVAudioEngine`; `nil` — недоступне. Умова — та сама, що в
    /// `Voice/SpeechRecognitionService.swift`.
    @MainActor
    static func makeSpeechRecognizer() -> SpeechRecognizing? {
        #if canImport(Speech) && canImport(AVFoundation) && os(iOS)
        return SpeechRecognitionService()
        #else
        return nil
        #endif
    }

    /// I2b: `AVAudioSession` (лише iOS); `nil` — категорією не керуємо. Умова — як у
    /// `Voice/AudioSessionController.swift`.
    @MainActor
    static func makeAudioSessionController() -> AudioSessionControlling? {
        #if canImport(AVFoundation) && os(iOS)
        return AudioSessionController()
        #else
        return nil
        #endif
    }
}
