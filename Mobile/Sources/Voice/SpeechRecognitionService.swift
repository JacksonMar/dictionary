// Живе розпізнавання мовлення (IOS_PLAN DI12, §4). Протокол і чисті типи — у `SpeechRecognizing.swift`
// (тайпчекаються на Linux); ця реалізація існує лише на iOS (Speech + AVFoundation). Тести — `FakeSpeechRecognizer`.
#if canImport(Speech) && canImport(AVFoundation) && os(iOS)
import AVFoundation
import Foundation
import Speech

/// `SFSpeechRecognizer(locale:)` + `AVAudioEngine` + `SFSpeechAudioBufferRecognitionRequest`
/// (`shouldReportPartialResults = true`, `requiresOnDeviceRecognition` з `RecognitionConfig`).
///
/// Потоки: tap `AVAudioEngine` (аудіопотік) і колбек `SFSpeechRecognitionTask` (черга розпізнавача) створюються в
/// `nonisolated static` фабриках — без ізоляції головного актора (у Swift 6 SDK замикання, створене в `@MainActor`
/// методі, інакше могло б вважатися ізольованим і падати на перевірці виконавця). Вони лише пишуть у
/// `AsyncStream.Continuation` (потокобезпечний); стан сервісу змінюється тільки на головному акторі.
///
/// `AVAudioEngine` створюється ліниво: створення сервісу (напр. в `AppContainer`) не чіпає аудіосистему.
@MainActor
final class SpeechRecognitionService: SpeechRecognizing {
    /// Розмір буфера tap (кадри): ~23 мс при 44,1 кГц — достатньо часто для індикатора рівня.
    static let tapBufferSize: AVAudioFrameCount = 1024

    private lazy var audioEngine = AVAudioEngine()
    private var recognizers: [String: SFSpeechRecognizer] = [:]
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<RecognitionUpdate>.Continuation?
    private var isTapInstalled = false
    /// Номер сеансу: `onTermination` старого потоку не прибирає новий сеанс.
    private var sessionID = 0

    init() {}

    // MARK: - Дозволи

    var permissionStatus: VoicePermissionStatus {
        VoicePermissionStatus.combine(
            speech: Self.map(SFSpeechRecognizer.authorizationStatus()),
            microphone: Self.microphoneStatus()
        )
    }

    func authorize() async -> VoicePermissionStatus {
        let speechStatus = Self.map(await Self.requestSpeechAuthorization())
        guard speechStatus == .authorized else {
            return VoicePermissionStatus.combine(speech: speechStatus, microphone: Self.microphoneStatus())
        }
        // iOS 17: `AVAudioApplication.requestRecordPermission()` (замість застарілого методу `AVAudioSession`).
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? .authorized : .denied
    }

    /// `requestAuthorization` викликає колбек на довільній черзі; `@Sendable` колбек не має ізоляції актора.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable (status: SFSpeechRecognizerAuthorizationStatus) in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermissionStatus {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// `AVAudioApplication.shared.recordPermission` (iOS 17). Тип переліку навмисно не називаємо явно.
    private nonisolated static func microphoneStatus() -> VoicePermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .authorized
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    // MARK: - Можливості

    func supportsOnDevice(locale: String) -> Bool {
        recognizer(for: locale)?.supportsOnDeviceRecognition ?? false
    }

    func availability(locale: String) -> RecognizerAvailability {
        guard let recognizer = recognizer(for: locale) else { return .unsupported }
        return recognizer.isAvailable ? .available : .unavailable
    }

    private func recognizer(for locale: String) -> SFSpeechRecognizer? {
        if let cached = recognizers[locale] {
            return cached
        }
        // `nil` — локаль не підтримується.
        guard let created = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { return nil }
        recognizers[locale] = created
        return created
    }

    // MARK: - Сеанс

    func start(locale: String, onDevice: Bool) -> AsyncStream<RecognitionUpdate> {
        cancel()
        sessionID += 1
        let session = sessionID
        let (stream, continuation) = AsyncStream<RecognitionUpdate>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { @Sendable [weak self] (_: AsyncStream<RecognitionUpdate>.Continuation.Termination) in
            guard let service = self else { return }
            Task<Void, Never> { @MainActor in
                service.sessionTerminated(session)
            }
        }

        guard let recognizer = recognizer(for: locale) else {
            continuation.yield(.failed(.unsupportedLanguage))
            continuation.finish()
            return stream
        }
        if !onDevice && !recognizer.isAvailable {
            continuation.yield(.failed(.offlineWithoutOnDevice))
            continuation.finish()
            return stream
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        // Окремі слова й короткі фрази; без автоматичної пунктуації (крапка після слова заважала б).
        request.taskHint = .search
        request.addsPunctuation = false

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            // Немає вхідного аудіо (напр. симулятор без мікрофона або сесію не активовано).
            continuation.yield(.failed(.audioUnavailable("input format unavailable")))
            continuation.finish()
            return stream
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: format,
            block: Self.makeTapBlock(request: request, continuation: continuation)
        )
        isTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stopAudio()
            continuation.yield(.failed(.audioUnavailable(error.localizedDescription)))
            continuation.finish()
            return stream
        }

        self.request = request
        self.continuation = continuation
        self.task = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeResultHandler(continuation: continuation, onDevice: onDevice)
        )
        return stream
    }

    func stop() {
        stopAudio()
        // Розпізнавач дообробить записане й надішле `.final` (потік завершить колбек).
        request?.endAudio()
    }

    func cancel() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.finish()
    }

    /// Потік завершився (остаточний результат, помилка або споживач скасував задачу) — звільняємо мікрофон.
    private func sessionTerminated(_ session: Int) {
        guard session == sessionID else { return }
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        continuation = nil
    }

    private func stopAudio() {
        if isTapInstalled {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
    }

    // MARK: - Колбеки поза головним актором

    /// Tap мікрофона (аудіопотік): буфер → запит розпізнавання, рівень → індикатор.
    private nonisolated static func makeTapBlock(
        request: SFSpeechAudioBufferRecognitionRequest,
        continuation: AsyncStream<RecognitionUpdate>.Continuation
    ) -> AVAudioNodeTapBlock {
        return { (buffer: AVAudioPCMBuffer, _: AVAudioTime) in
            request.append(buffer)
            continuation.yield(.level(level(of: buffer)))
        }
    }

    /// Колбек `SFSpeechRecognitionTask` (черга розпізнавача): частковий/остаточний текст або помилка.
    private nonisolated static func makeResultHandler(
        continuation: AsyncStream<RecognitionUpdate>.Continuation,
        onDevice: Bool
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        return { (result: SFSpeechRecognitionResult?, error: Error?) in
            if let result {
                let recognized = transcript(of: result)
                if result.isFinal {
                    continuation.yield(.final(recognized))
                    continuation.finish()
                    return
                }
                continuation.yield(.partial(recognized))
            }
            if let error {
                continuation.yield(.failed(recognitionError(from: error, onDevice: onDevice)))
                continuation.finish()
            }
        }
    }

    private nonisolated static func transcript(of result: SFSpeechRecognitionResult) -> RecognitionTranscript {
        let best = result.bestTranscription
        let segments = best.segments
        // Впевненість відома лише для остаточного результату (у часткових — 0).
        var confidence: Float?
        if result.isFinal, !segments.isEmpty {
            confidence = segments.reduce(Float(0)) { $0 + $1.confidence } / Float(segments.count)
        }
        let alternatives = result.transcriptions
            .map { $0.formattedString }
            .filter { $0 != best.formattedString }
        return RecognitionTranscript(
            text: best.formattedString,
            confidence: confidence,
            alternatives: Array(alternatives.prefix(3))
        )
    }

    /// Помилки розпізнавача мають недокументовані коди (`kAFAssistantErrorDomain`): 1110 / 203 — мовлення не
    /// виявлено, 216 / 301 — запит скасовано. Мережеві помилки серверного розпізнавання → «офлайн без моделі».
    private nonisolated static func recognitionError(from error: Error, onDevice: Bool) -> RecognitionError {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" {
            switch nsError.code {
            case 1110, 203:
                return .noSpeech
            case 216, 301:
                return .cancelled
            default:
                break
            }
        }
        if !onDevice && nsError.domain == NSURLErrorDomain {
            return .offlineWithoutOnDevice
        }
        return .failed("\(nsError.domain) \(nsError.code)")
    }

    /// RMS першого каналу → 0…1 (`AudioLevel`).
    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }
        return AudioLevel.normalized(rms: (sum / Float(count)).squareRoot())
    }
}
#endif
