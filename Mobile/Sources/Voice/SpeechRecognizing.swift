import Foundation
import VocabCore

// Голосове введення (IOS_PLAN DI10–DI13, §4): чисті типи й протокол розпізнавання. Лише Foundation/VocabCore —
// файл тайпчекається й виконується на Linux; живу реалізацію (`SpeechRecognitionService`, Speech + AVFoundation)
// підставляє `LivePlatform`, тести — `FakeSpeechRecognizer`.

/// Мова мовлення (перемикач EN | IT біля мікрофона, DI12). `rawValue` — код мови для підказки Claude
/// (`AddWordUseCase.execute(rawText:sourceLanguageHint:)`, DI13) і значення в `UserDefaults` (`voiceLanguage`).
enum VoiceLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case italian = "it"

    /// Мова за замовчуванням (нічого не збережено або збережено невідоме значення).
    static let `default`: VoiceLanguage = .english

    var id: String {
        rawValue
    }

    /// Збережене значення → мова; `nil`, порожнє або невідоме → `.default`. Регістр і пробіли ігноруються.
    init(storedValue: String?) {
        let normalized = storedValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = VoiceLanguage(rawValue: normalized) ?? .default
    }

    /// Локаль `SFSpeechRecognizer` (DI12).
    var localeIdentifier: String {
        switch self {
        case .english:
            return "en-US"
        case .italian:
            return "it-IT"
        }
    }

    /// Голос озвучення (`SpeechSpeaking`) — той самий BCP-47 код, що й `LanguagePair`/`RenderingLanguage`.
    var speechLanguageCode: String {
        localeIdentifier
    }

    /// Підказка мови для Claude (`Entry.languageHint`, DI13): `"en"` / `"it"`.
    var languageHint: String {
        rawValue
    }

    /// Підпис сегмента («EN» / «IT») — код мови, не перекладається (як `RenderingLanguage.shortTitle`).
    var shortTitle: String {
        rawValue.uppercased()
    }

    /// Повна назва мовою інтерфейсу (Налаштування, VoiceOver).
    func displayName(language: AppLanguage = L10n.current) -> String {
        switch self {
        case .english:
            return L10n.text(.voiceLanguageEnglish, language: language)
        case .italian:
            return L10n.text(.voiceLanguageItalian, language: language)
        }
    }
}

/// Стан дозволів (мікрофон + розпізнавання мовлення разом).
enum VoicePermissionStatus: Equatable, Sendable {
    /// Користувача ще не питали (хоча б про один дозвіл).
    case notDetermined
    /// Обидва дозволи надано.
    case authorized
    /// Користувач відмовив (хоча б в одному) — змінити можна лише в iOS Settings («Відкрити Налаштування»).
    case denied
    /// Обмежено політикою пристрою (екранний час, MDM) — користувач сам не змінить.
    case restricted

    /// Поєднання статусів двох дозволів: відмова в будь-якому → `.denied`; обмеження → `.restricted`;
    /// обидва надано → `.authorized`; інакше (хоча б один ще не питали) → `.notDetermined`.
    static func combine(speech: VoicePermissionStatus, microphone: VoicePermissionStatus) -> VoicePermissionStatus {
        if speech == .denied || microphone == .denied {
            return .denied
        }
        if speech == .restricted || microphone == .restricted {
            return .restricted
        }
        if speech == .authorized && microphone == .authorized {
            return .authorized
        }
        return .notDetermined
    }
}

/// Доступність розпізнавача для локалі (`SFSpeechRecognizer(locale:)` + `isAvailable`).
enum RecognizerAvailability: Equatable, Sendable {
    /// Локаль не підтримується (розпізнавача немає).
    case unsupported
    /// Розпізнавач є, але зараз недоступний (зазвичай немає мережі для серверного розпізнавання).
    case unavailable
    case available
}

/// Розпізнаний текст (частковий або остаточний).
struct RecognitionTranscript: Equatable, Sendable {
    /// Найкращий варіант (`bestTranscription.formattedString`).
    var text: String
    /// Середня впевненість сегментів 0…1; `nil` — невідомо (часткові результати мають 0).
    var confidence: Float?
    /// Інші варіанти (`transcriptions` без найкращого); опційно, не критерій приймання (DI12).
    var alternatives: [String]

    init(text: String, confidence: Float? = nil, alternatives: [String] = []) {
        self.text = text
        self.confidence = confidence
        self.alternatives = alternatives
    }
}

/// Помилка розпізнавання, яку повідомляє `SpeechRecognizing` у потоці.
enum RecognitionError: Error, Equatable, Sendable {
    /// Локаль не підтримується.
    case unsupportedLanguage
    /// Офлайн, а моделі на пристрої для цієї мови немає (DI12): потрібна мережа.
    case offlineWithoutOnDevice
    /// Не вдалося запустити мікрофон/аудіо (опис — для діагностики, без даних користувача).
    case audioUnavailable(String)
    /// Мовлення не виявлено.
    case noSpeech
    /// Розпізнавання скасовано (системою або `cancel()`).
    case cancelled
    /// Інша помилка розпізнавача.
    case failed(String)
}

/// Подія потоку `SpeechRecognizing.start(locale:onDevice:)`. Після `.final` або `.failed` потік завершується.
enum RecognitionUpdate: Equatable, Sendable {
    case partial(RecognitionTranscript)
    case final(RecognitionTranscript)
    /// Рівень сигналу мікрофона 0…1 (індикатор рівня, опційно).
    case level(Float)
    case failed(RecognitionError)
}

/// Налаштування сеансу розпізнавання (DI12): на пристрої, якщо модель є (`requiresOnDeviceRecognition =
/// supportsOnDeviceRecognition`); інакше — серверне розпізнавання Apple з позначкою під полем; офлайн без моделі на
/// пристрої → помилка (і поле для ручного введення).
struct RecognitionConfig: Equatable, Sendable {
    let localeIdentifier: String
    /// `SFSpeechRecognitionRequest.requiresOnDeviceRecognition`.
    let requiresOnDeviceRecognition: Bool

    /// Аудіо йде на сервери Apple — UI показує позначку.
    var usesServerRecognition: Bool {
        !requiresOnDeviceRecognition
    }

    /// - Parameters:
    ///   - supportsOnDevice: `SFSpeechRecognizer.supportsOnDeviceRecognition` для локалі.
    ///   - availability: доступність розпізнавача зараз (`isAvailable` стає `false` без мережі, якщо моделі на
    ///     пристрої немає).
    static func make(
        localeIdentifier: String,
        supportsOnDevice: Bool,
        availability: RecognizerAvailability
    ) -> Result<RecognitionConfig, RecognitionError> {
        switch availability {
        case .unsupported:
            return .failure(.unsupportedLanguage)
        case .unavailable, .available:
            if supportsOnDevice {
                // Модель на пристрої працює й офлайн; аудіо не залишає iPhone.
                return .success(RecognitionConfig(localeIdentifier: localeIdentifier, requiresOnDeviceRecognition: true))
            }
            guard availability == .available else {
                return .failure(.offlineWithoutOnDevice)
            }
            return .success(RecognitionConfig(localeIdentifier: localeIdentifier, requiresOnDeviceRecognition: false))
        }
    }

    /// Те саме, із запитом можливостей у розпізнавача.
    @MainActor
    static func make(for language: VoiceLanguage, recognizer: SpeechRecognizing) -> Result<RecognitionConfig, RecognitionError> {
        let locale = language.localeIdentifier
        return make(
            localeIdentifier: locale,
            supportsOnDevice: recognizer.supportsOnDevice(locale: locale),
            availability: recognizer.availability(locale: locale)
        )
    }
}

/// Перетворення сигналу мікрофона на рівень 0…1 для індикатора.
enum AudioLevel {
    /// Нижня межа шкали (тиша), дБ відносно повної шкали.
    static let floorDecibels: Float = -50

    /// RMS семплів (−1…1) → 0…1: −50 дБ і тихіше → 0, 0 дБ → 1, лінійно в дБ.
    static func normalized(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        guard decibels.isFinite else { return 0 }
        let clamped = min(max(decibels, floorDecibels), 0)
        return (clamped - floorDecibels) / -floorDecibels
    }
}

/// Розпізнавання мовлення (IOS_PLAN §2, §4). Усі виклики — з головного актора; колбеки розпізнавача й аудіо
/// (не головний потік) живі реалізації передають через `AsyncStream.Continuation`.
///
/// Життєвий цикл сеансу: `start` → `.partial…` → (`stop()` → `.final`) | `.failed`; потік завершується після
/// `.final`/`.failed` або `cancel()`. Новий `start` скасовує попередній сеанс.
@MainActor
protocol SpeechRecognizing: AnyObject {
    /// Поточний стан дозволів без показу системного запиту.
    var permissionStatus: VoicePermissionStatus { get }
    /// Запитує дозволи (системні діалоги лише для `notDetermined`) і повертає підсумковий стан.
    func authorize() async -> VoicePermissionStatus
    /// Чи є модель розпізнавання на пристрої для локалі (`en-US`, `it-IT`).
    func supportsOnDevice(locale: String) -> Bool
    /// Чи підтримується локаль і чи доступний розпізнавач зараз.
    func availability(locale: String) -> RecognizerAvailability
    /// Починає слухати мікрофон (аудіосесію для запису вже активовано). `onDevice` →
    /// `requiresOnDeviceRecognition`. Помилки старту приходять у потоці як `.failed`.
    func start(locale: String, onDevice: Bool) -> AsyncStream<RecognitionUpdate>
    /// Зупиняє запис; розпізнавач ще надішле `.final` (або `.failed`) і завершить потік.
    func stop()
    /// Перериває сеанс без результату; потік завершується. Повторний виклик — нічого не робить.
    func cancel()
}
