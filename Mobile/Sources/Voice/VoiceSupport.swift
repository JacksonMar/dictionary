import Foundation
import VocabCore

// Допоміжні залежності `VoiceCaptureModel` (IOS_PLAN DI10, DI12): збережена мова голосу і планувальник таймерів
// автозупинки. Лише Foundation — тайпчекається на Linux; тести підставляють ручний планувальник і сховище в пам'яті.

// MARK: - Мова голосу (UserDefaults `voiceLanguage`, лише iOS-застосунок)

/// Остання вибрана мова голосу (перемикач EN | IT біля мікрофона = «мова голосу за замовчуванням» у Налаштуваннях).
protocol VoiceLanguageStoring: AnyObject {
    var voiceLanguage: VoiceLanguage { get set }
}

/// `UserDefaults`, ключ `voiceLanguage` (DI12). Відсутнє/невідоме значення → `VoiceLanguage.default`.
final class UserDefaultsVoiceLanguageStore: VoiceLanguageStoring {
    static let key = "voiceLanguage"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var voiceLanguage: VoiceLanguage {
        get { VoiceLanguage(storedValue: defaults.string(forKey: Self.key)) }
        set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
}

/// Сховище в пам'яті (тести; застосунок під XCTest).
final class InMemoryVoiceLanguageStore: VoiceLanguageStoring {
    var voiceLanguage: VoiceLanguage

    init(voiceLanguage: VoiceLanguage = .default) {
        self.voiceLanguage = voiceLanguage
    }
}

// MARK: - Таймери (тиша ~1,5 с, максимум 10 с — DI10)

/// Запланована дія; `cancel()` гарантує, що вона не виконається (повторний виклик — нічого не робить).
@MainActor
protocol VoiceTimer: AnyObject {
    func cancel()
}

/// Планувальник одноразових дій на головному акторі. Живий — `TaskVoiceTimerScheduler` (`Task.sleep`); тести —
/// ручний годинник, що виконує дії детерміновано при «перемотуванні» часу.
@MainActor
protocol VoiceTimerScheduling: AnyObject {
    /// Виконає `action` на головному акторі через `delay` секунд, якщо таймер не скасовано.
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> VoiceTimer
}

/// `Task.sleep` на головному акторі.
@MainActor
final class TaskVoiceTimerScheduler: VoiceTimerScheduling {
    init() {}

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> VoiceTimer {
        let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
        let task = Task<Void, Never> { @MainActor in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                // Скасовано (`cancel()`) — дію не виконуємо.
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return TaskVoiceTimer(task: task)
    }
}

/// Таймер поверх `Task`.
@MainActor
final class TaskVoiceTimer: VoiceTimer {
    private var task: Task<Void, Never>?

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Додавання слова й аудіосесія

/// Додає розпізнане (підтверджене кнопкою «Додати», iU15 = (а)) слово: рівно один виклик
/// `AddWordUseCase.execute(rawText:sourceLanguageHint:)` із підказкою мови голосу. У застосунку — `MobileAppModel`.
@MainActor
protocol VoiceWordSubmitting: AnyObject {
    func submitVoiceWord(_ rawText: String, languageHint: String) async -> AddWordOutcome
}

/// Озвучення, що повідомляє про завершення (iOS): після «Озвучити» на картці модель вимикає аудіосесію `.playback`,
/// щоб інші застосунки відновили звук. Спільний з macOS `SpeechSpeaking` не змінюється; живий —
/// `VoiceSpeechService` (лише iOS).
@MainActor
protocol SpeechCompletionReporting: SpeechSpeaking {
    /// `completion` викликається рівно один раз на головному акторі, коли це висловлювання закінчилось або
    /// перервалось (`stop()`, нове `speak`, порожній текст — одразу).
    func speak(_ text: String, languageCode: String, completion: @escaping @MainActor @Sendable () -> Void)
}

/// Категорія аудіосесії (IOS_PLAN §2): запис (`.record`/`.measurement`) ↔ відтворення (`.playback`) для озвучення
/// одразу після запису (iU14). Живий — `AudioSessionController` (AVFoundation, лише iOS).
@MainActor
protocol AudioSessionControlling: AnyObject {
    /// Перед стартом розпізнавання.
    func activateForRecording() throws
    /// Перед озвученням (`SpeechSpeaking.speak`).
    func activateForPlayback() throws
    /// Після запису (інші застосунки відновлюють звук).
    func deactivate() throws
}
