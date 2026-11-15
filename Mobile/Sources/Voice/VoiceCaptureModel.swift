import Foundation
import VocabCore
#if canImport(Combine)
import Combine
#endif

/// Помилка голосового введення для UI. У кожному стані помилки є поле для ручного введення (кнопка «Додати» працює).
enum VoiceCaptureError: Equatable, Sendable {
    /// Відмова в доступі до мікрофона або розпізнавання — посилання «Відкрити Налаштування».
    case permissionDenied
    /// Обмежено політикою пристрою.
    case permissionRestricted
    /// Розпізнавання мовлення недоступне в цьому середовищі (немає реалізації).
    case recognizerUnavailable
    /// Мова не підтримується розпізнавачем.
    case unsupportedLanguage
    /// Офлайн без моделі на пристрої (DI12).
    case offline
    /// Мікрофон не запустився.
    case audio
    /// Інша помилка розпізнавання.
    case recognitionFailed

    /// Показувати «Відкрити Налаштування» (`UIApplication.openSettingsURLString`).
    var showsSettingsLink: Bool {
        self == .permissionDenied
    }

    func message(language: AppLanguage = L10n.current) -> String {
        let key: L10nKey
        switch self {
        case .permissionDenied:
            key = .voiceErrorPermissionDenied
        case .permissionRestricted:
            key = .voiceErrorRestricted
        case .recognizerUnavailable:
            key = .voiceErrorUnavailable
        case .unsupportedLanguage:
            key = .voiceErrorUnsupported
        case .offline:
            key = .voiceErrorOffline
        case .audio:
            key = .voiceErrorAudio
        case .recognitionFailed:
            key = .voiceErrorFailed
        }
        return L10n.text(key, language: language)
    }

    /// Помилка розпізнавача → стан UI (`noSpeech`/`cancelled` сюди не потрапляють — це не помилки для користувача).
    static func from(_ error: RecognitionError) -> VoiceCaptureError {
        switch error {
        case .unsupportedLanguage:
            return .unsupportedLanguage
        case .offlineWithoutOnDevice:
            return .offline
        case .audioUnavailable:
            return .audio
        case .noSpeech, .cancelled, .failed:
            return .recognitionFailed
        }
    }
}

/// Результат-картка після «Додати» (IOS_PLAN §4): текст — `NotificationText.make`, озвучення — слово мовою голосу.
struct VoiceCaptureResult: Equatable, Sendable {
    let outcome: AddWordOutcome
    let title: String
    let body: String
    /// Помилка збереження/запиту (`failed`, `storageError`) — картка червона.
    let isFailure: Bool
    /// Що озвучити кнопкою «Озвучити»; `nil` — кнопки немає.
    let speakText: String?
    /// Голос (`en-US` / `it-IT`).
    let speakLanguageCode: String

    /// - Parameters:
    ///   - submittedText: текст, який надіслано (для `selection` у `NotificationText` і озвучення pending-запису).
    ///   - language: мова голосу.
    static func make(
        outcome: AddWordOutcome,
        submittedText: String,
        language: VoiceLanguage,
        interfaceLanguage: AppLanguage = L10n.current
    ) -> VoiceCaptureResult {
        let content = NotificationText.make(for: outcome, selection: submittedText, language: interfaceLanguage)
        let spoken = speech(for: outcome, submittedText: submittedText, language: language)
        let isFailure: Bool
        switch outcome {
        case .failed, .storageError, .rejected:
            isFailure = true
        case .added, .queued, .duplicate:
            isFailure = false
        }
        return VoiceCaptureResult(
            outcome: outcome,
            title: content.title,
            body: content.body,
            isFailure: isFailure,
            speakText: spoken?.text,
            speakLanguageCode: spoken?.languageCode ?? language.speechLanguageCode
        )
    }

    /// Ready-запис: слово мовою голосу (італійський ready-варіант для IT), інакше англійське слово запису;
    /// pending/failed: надісланий текст голосом мови мовлення; відхилено/збій сховища — нічого.
    private static func speech(
        for outcome: AddWordOutcome,
        submittedText: String,
        language: VoiceLanguage
    ) -> (text: String, languageCode: String)? {
        let cleaned = TextNormalizer.clean(submittedText)
        switch outcome {
        case .added(let entry), .duplicate(let entry):
            guard entry.status == .ready else {
                return cleaned.isEmpty ? nil : (cleaned, language.speechLanguageCode)
            }
            let languageID: String? = language == .english ? nil : language.rawValue
            let display = EntryDisplay.make(entry, languageID: languageID)
            if languageID != nil, !display.isFallback {
                return (display.word, language.speechLanguageCode)
            }
            return (entry.word, VoiceLanguage.english.speechLanguageCode)
        case .queued, .failed:
            return cleaned.isEmpty ? nil : (cleaned, language.speechLanguageCode)
        case .rejected, .storageError:
            return nil
        }
    }
}

/// Голосове введення (IOS_PLAN DI10–DI13, §4, §5): `@MainActor` стан-машина
/// `idle → requestingPermission → listening → recognized → submitting → result` (+ `error`).
///
/// - Tap-to-talk (DI10): `toggleListening()` починає слухати; зупинка — повторним дотиком, через `silenceTimeout`
///   (~1,5 с) після останнього часткового результату або через `maxDuration` (10 с). Таймери — з ін'єктованого
///   `VoiceTimerScheduling` (тести детерміновані).
/// - Підтвердження завжди (iU15 = (а)): розпізнаний текст — у редагованому `editableText`; «Додати» (`submit()`)
///   викликає `VoiceWordSubmitting` **один раз** із підказкою мови голосу; порожній текст не надсилається.
///   Автододавання немає.
/// - Перемикач EN | IT (`selectLanguage`) запам'ятовується у `VoiceLanguageStoring` (`voiceLanguage`). Мова з
///   глибокого посилання (`launch(languageID:)`) діє лише на цей сеанс.
/// - Розпізнаний текст, що прийшов після зупинки (`.final`), замінює поле, якщо користувач його ще не редагував.
@MainActor
final class VoiceCaptureModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requestingPermission
        case listening
        case recognized
        case submitting
        case result(VoiceCaptureResult)
        case error(VoiceCaptureError)
    }

    nonisolated static let defaultSilenceTimeout: TimeInterval = 1.5
    nonisolated static let defaultMaxDuration: TimeInterval = 10

    @Published private(set) var phase: Phase = .idle
    /// Живий частковий текст під час слухання.
    @Published private(set) var partialText: String = ""
    /// Редаговане поле після зупинки (і поле ручного введення в стані помилки).
    @Published var editableText: String = ""
    /// Мова мовлення (і підказки Claude).
    @Published private(set) var language: VoiceLanguage
    /// Сеанс іде через сервери Apple (немає моделі на пристрої) — позначка під полем (DI12).
    @Published private(set) var usesServerRecognition = false
    /// Рівень мікрофона 0…1 (індикатор).
    @Published private(set) var level: Float = 0
    /// Альтернативи останнього результату (опційні чипи).
    @Published private(set) var alternatives: [String] = []
    /// Після зупинки розпізнавач ще може надіслати остаточний текст.
    @Published private(set) var isFinalizing = false
    /// Причина, з якої «Додати» не спрацювало (відхилений текст: забагато слів тощо).
    @Published private(set) var submitError: String?

    private let recognizer: SpeechRecognizing?
    /// Сильне посилання: циклу немає (`MobileAppModel` не тримає модель голосу).
    private let submitter: VoiceWordSubmitting
    private let languageStore: VoiceLanguageStoring
    private let scheduler: VoiceTimerScheduling
    private let speech: SpeechSpeaking?
    private let audioSession: AudioSessionControlling?
    let silenceTimeout: TimeInterval
    let maxDuration: TimeInterval

    /// Номер поточного сеансу: події старих сеансів (після «Ще раз»/скасування) ігноруються.
    private(set) var sessionID = 0
    /// Споживач потоку розпізнавання (тести можуть дочекатися `recognitionTask?.value`).
    private(set) var recognitionTask: Task<Void, Never>?
    private var silenceTimer: VoiceTimer?
    private var maxDurationTimer: VoiceTimer?
    /// Текст, яким модель востаннє заповнила `editableText` (щоб не перезаписати правки користувача).
    private var autoFilledText = ""

    init(
        recognizer: SpeechRecognizing?,
        submitter: VoiceWordSubmitting,
        languageStore: VoiceLanguageStoring,
        scheduler: VoiceTimerScheduling,
        speech: SpeechSpeaking? = nil,
        audioSession: AudioSessionControlling? = nil,
        silenceTimeout: TimeInterval = VoiceCaptureModel.defaultSilenceTimeout,
        maxDuration: TimeInterval = VoiceCaptureModel.defaultMaxDuration
    ) {
        self.recognizer = recognizer
        self.submitter = submitter
        self.languageStore = languageStore
        self.scheduler = scheduler
        self.speech = speech
        self.audioSession = audioSession
        self.silenceTimeout = silenceTimeout
        self.maxDuration = maxDuration
        self.language = languageStore.voiceLanguage
    }

    // MARK: - Похідні стани для UI

    var isListening: Bool {
        phase == .listening
    }

    /// Іде запит дозволу, слухання або додавання — перемикач мови й «Ще раз» недоступні.
    var isBusy: Bool {
        switch phase {
        case .requestingPermission, .listening, .submitting:
            return true
        case .idle, .recognized, .result, .error:
            return false
        }
    }

    var currentError: VoiceCaptureError? {
        if case .error(let error) = phase {
            return error
        }
        return nil
    }

    var result: VoiceCaptureResult? {
        if case .result(let result) = phase {
            return result
        }
        return nil
    }

    /// Посилання «Відкрити Налаштування» (відмова в дозволі).
    var showsSettingsLink: Bool {
        currentError?.showsSettingsLink ?? false
    }

    /// Редаговане поле видно після зупинки й у стані помилки (ручне введення).
    var showsEditableField: Bool {
        switch phase {
        case .recognized, .error, .submitting:
            return true
        case .idle, .requestingPermission, .listening, .result:
            return false
        }
    }

    /// Зупинено, але нічого не розпізнано (і остаточного тексту вже не буде).
    var isRecognitionEmpty: Bool {
        phase == .recognized && !isFinalizing && trimmedText.isEmpty
    }

    /// «Додати» активна: є текст і стан дозволяє (розпізнано або помилка з ручним введенням).
    var canSubmit: Bool {
        guard !trimmedText.isEmpty else { return false }
        switch phase {
        case .recognized, .error:
            return true
        case .idle, .requestingPermission, .listening, .submitting, .result:
            return false
        }
    }

    var isSpeechAvailable: Bool {
        speech != nil
    }

    private var trimmedText: String {
        editableText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Мова

    /// Перемикач EN | IT: запам'ятовується (`voiceLanguage`). Під час слухання/додавання ігнорується.
    func selectLanguage(_ newLanguage: VoiceLanguage) {
        guard !isBusy else { return }
        language = newLanguage
        languageStore.voiceLanguage = newLanguage
    }

    // MARK: - Запуск

    /// Глибоке посилання `vocabapp://voice[?lang=…]` (DI10, §4): мова з посилання — лише на цей сеанс; якщо дозволи
    /// вже є — одразу слухає; не питали — лишається `idle` (екран із пропозицією торкнутися мікрофона, системний
    /// запит з'явиться після дотику); відмовлено/обмежено — стан помилки з посиланням на Налаштування.
    func launch(languageID: String?) async {
        guard !isBusy else { return }
        if let languageID, let requested = VoiceLanguage(rawValue: languageID.lowercased()) {
            language = requested
        }
        guard let recognizer else {
            enterError(.recognizerUnavailable)
            return
        }
        switch recognizer.permissionStatus {
        case .authorized:
            await startListening()
        case .notDetermined:
            resetToIdle()
        case .denied:
            enterError(.permissionDenied)
        case .restricted:
            enterError(.permissionRestricted)
        }
    }

    /// Дотик до мікрофона: слухає → зупиняє; інакше починає слухати.
    func toggleListening() async {
        switch phase {
        case .listening:
            stopListening()
        case .requestingPermission, .submitting:
            return
        case .idle, .recognized, .result, .error:
            await startListening()
        }
    }

    /// «Ще раз»: скидає поточний сеанс і знову слухає.
    func again() async {
        guard !isBusy else { return }
        await startListening()
    }

    /// Починає новий сеанс: дозволи (запит, якщо ще не питали) → налаштування on-device/сервер → аудіосесія запису →
    /// `recognizer.start`.
    func startListening() async {
        guard !isBusy else { return }
        endRecognitionSession(cancelRecognizer: true)
        speech?.stop()
        submitError = nil
        guard let recognizer else {
            enterError(.recognizerUnavailable)
            return
        }

        var status = recognizer.permissionStatus
        if status == .notDetermined {
            phase = .requestingPermission
            status = await recognizer.authorize()
            // Сеанс могли скасувати, поки показувався системний запит.
            guard phase == .requestingPermission else { return }
        }
        switch status {
        case .authorized:
            break
        case .denied, .notDetermined:
            enterError(.permissionDenied)
            return
        case .restricted:
            enterError(.permissionRestricted)
            return
        }

        let config: RecognitionConfig
        switch RecognitionConfig.make(for: language, recognizer: recognizer) {
        case .success(let made):
            config = made
        case .failure(let error):
            enterError(VoiceCaptureError.from(error))
            return
        }

        if let audioSession {
            do {
                try audioSession.activateForRecording()
            } catch {
                enterError(.audio)
                return
            }
        }

        sessionID += 1
        let session = sessionID
        partialText = ""
        editableText = ""
        autoFilledText = ""
        alternatives = []
        level = 0
        isFinalizing = false
        usesServerRecognition = config.usesServerRecognition
        phase = .listening

        let stream = recognizer.start(locale: config.localeIdentifier, onDevice: config.requiresOnDeviceRecognition)
        maxDurationTimer = scheduler.schedule(after: maxDuration) { [weak self] in
            self?.autoStop(session: session)
        }
        recognitionTask = Task<Void, Never> { @MainActor [weak self] in
            for await update in stream {
                guard let self else { return }
                self.handle(update, session: session)
            }
            self?.streamEnded(session: session)
        }
    }

    // MARK: - Зупинка й скасування

    /// Зупинка дотиком (або таймером): розпізнавач завершує запис і ще може надіслати остаточний текст; поле одразу
    /// показує вже розпізнане.
    func stopListening() {
        guard phase == .listening else { return }
        cancelTimers()
        recognizer?.stop()
        deactivateAudioSession()
        level = 0
        isFinalizing = recognitionTask != nil
        enterRecognized(partialText)
    }

    /// «Скасувати» / закриття аркуша: зупиняє розпізнавач і мікрофон, повертає `idle`. Результат не надсилається.
    func cancel() {
        endRecognitionSession(cancelRecognizer: true)
        speech?.stop()
        if phase != .submitting {
            resetToIdle()
        }
    }

    // MARK: - Додавання

    /// «Додати»: рівно один виклик `VoiceWordSubmitting` з підказкою мови голосу. Порожній текст, повторний дотик під
    /// час додавання або стан без тексту — нічого не роблять. Відхилений текст (забагато слів…) лишає поле для правки.
    func submit() async {
        guard canSubmit else { return }
        let text = trimmedText
        let submittedLanguage = language
        // Остаточний текст розпізнавача, якщо ще йде, більше не потрібен.
        endRecognitionSession(cancelRecognizer: true)
        submitError = nil
        let previousPhase = phase
        phase = .submitting
        let outcome = await submitter.submitVoiceWord(text, languageHint: submittedLanguage.languageHint)
        if case .rejected(let rejection) = outcome {
            submitError = NotificationText.rejectionText(rejection)
            phase = previousPhase
            return
        }
        phase = .result(VoiceCaptureResult.make(outcome: outcome, submittedText: text, language: submittedLanguage))
    }

    // MARK: - Озвучення результату

    /// «Озвучити» на картці: аудіосесія → відтворення (після запису вона була `.record`, iU14), далі `SpeechSpeaking`.
    func speakResult() {
        guard let result, let text = result.speakText, let speech else { return }
        if let audioSession {
            do {
                try audioSession.activateForPlayback()
            } catch {
                // Без перемикання категорії озвучення може бути тихим, але спробувати варто (не блокуємо).
            }
        }
        speech.speak(text, languageCode: result.speakLanguageCode)
    }

    // MARK: - Події розпізнавача

    /// Обробка події потоку (внутрішнє API для тестів; події старих сеансів ігноруються).
    func handle(_ update: RecognitionUpdate, session: Int) {
        guard session == sessionID else { return }
        switch update {
        case .level(let value):
            if phase == .listening {
                level = min(max(value, 0), 1)
            }
        case .partial(let transcript):
            if phase == .listening {
                partialText = transcript.text
                alternatives = transcript.alternatives
                scheduleSilenceTimer(session: session)
            } else {
                applyLateText(transcript)
            }
        case .final(let transcript):
            if phase == .listening {
                partialText = transcript.text
                alternatives = transcript.alternatives
                cancelTimers()
                recognizer?.stop()
                deactivateAudioSession()
                level = 0
                enterRecognized(transcript.text)
            } else {
                applyLateText(transcript)
            }
            isFinalizing = false
        case .failed(let error):
            handleFailure(error)
        }
    }

    private func handleFailure(_ error: RecognitionError) {
        let wasListening = phase == .listening
        isFinalizing = false
        guard wasListening else {
            // Після зупинки поле вже показує розпізнане: помилку (часто «скасовано») не показуємо.
            return
        }
        cancelTimers()
        recognizer?.cancel()
        deactivateAudioSession()
        level = 0
        switch error {
        case .noSpeech, .cancelled:
            enterRecognized(partialText)
        case .unsupportedLanguage, .offlineWithoutOnDevice, .audioUnavailable, .failed:
            if partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                enterError(VoiceCaptureError.from(error))
            } else {
                // Уже щось розпізнано — віддаємо на підтвердження, а не губимо.
                enterRecognized(partialText)
            }
        }
    }

    private func streamEnded(session: Int) {
        guard session == sessionID else { return }
        recognitionTask = nil
        isFinalizing = false
        if phase == .listening {
            // Потік закінчився без `.final` (напр. система перервала сеанс) — віддаємо те, що є.
            cancelTimers()
            recognizer?.stop()
            deactivateAudioSession()
            level = 0
            enterRecognized(partialText)
        }
    }

    /// Текст, що прийшов після зупинки: замінює поле, лише якщо користувач його не редагував.
    private func applyLateText(_ transcript: RecognitionTranscript) {
        guard phase == .recognized, isFinalizing else { return }
        let text = transcript.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, editableText == autoFilledText else {
            return
        }
        partialText = text
        alternatives = transcript.alternatives
        editableText = text
        autoFilledText = text
    }

    // MARK: - Таймери

    private func scheduleSilenceTimer(session: Int) {
        silenceTimer?.cancel()
        silenceTimer = scheduler.schedule(after: silenceTimeout) { [weak self] in
            self?.autoStop(session: session)
        }
    }

    private func autoStop(session: Int) {
        guard session == sessionID, phase == .listening else { return }
        stopListening()
    }

    private func cancelTimers() {
        silenceTimer?.cancel()
        silenceTimer = nil
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
    }

    // MARK: - Переходи

    private func enterRecognized(_ text: String) {
        editableText = text
        autoFilledText = text
        phase = .recognized
    }

    private func enterError(_ error: VoiceCaptureError) {
        phase = .error(error)
    }

    private func resetToIdle() {
        partialText = ""
        editableText = ""
        autoFilledText = ""
        alternatives = []
        level = 0
        usesServerRecognition = false
        submitError = nil
        phase = .idle
    }

    /// Завершує поточний сеанс: таймери, споживач потоку, (опційно) розпізнавач і аудіосесія. Наступні події
    /// цього сеансу ігноруються (новий `sessionID`).
    private func endRecognitionSession(cancelRecognizer: Bool) {
        cancelTimers()
        let hadSession = recognitionTask != nil || phase == .listening
        recognitionTask?.cancel()
        recognitionTask = nil
        isFinalizing = false
        sessionID += 1
        if cancelRecognizer && hadSession {
            recognizer?.cancel()
        }
        if hadSession {
            deactivateAudioSession()
        }
        level = 0
    }

    private func deactivateAudioSession() {
        guard let audioSession else { return }
        do {
            try audioSession.deactivate()
        } catch {
            // Деактивація може не вдатися, поки інший звук ще грає; на роботу застосунку це не впливає.
        }
    }
}
