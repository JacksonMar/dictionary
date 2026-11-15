// Test doubles for the I2b voice tests (IOS_PLAN DI10–DI13, §7 I2b): a scripted `SpeechRecognizing`, a manual
// clock (`VoiceTimerScheduling`), a recording `VoiceWordSubmitting`, audio session and speech fakes. Foundation only —
// the voice model tests also run in the Linux harness.
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

// MARK: - FakeSpeechRecognizer

/// Scripted recognizer: records every call; the test pushes events into the current session's stream with `emit`.
@MainActor
final class FakeSpeechRecognizer: SpeechRecognizing {
    struct StartCall: Equatable {
        let locale: String
        let onDevice: Bool
    }

    var permissionStatus: VoicePermissionStatus
    /// What `authorize()` returns (and then stores as `permissionStatus`).
    var authorizeResult: VoicePermissionStatus
    /// Locales with an on-device model.
    var onDeviceLocales: Set<String>
    var availabilityByLocale: [String: RecognizerAvailability]
    /// If set, `stop()` delivers this transcript as `.final` and finishes the stream (like the real recognizer).
    var finalOnStop: RecognitionTranscript?

    private(set) var authorizeCount = 0
    private(set) var startCalls: [StartCall] = []
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private var continuations: [AsyncStream<RecognitionUpdate>.Continuation] = []

    init(
        permission: VoicePermissionStatus = .authorized,
        authorizeResult: VoicePermissionStatus = .authorized,
        onDeviceLocales: Set<String> = ["en-US", "it-IT"],
        availability: [String: RecognizerAvailability] = ["en-US": .available, "it-IT": .available]
    ) {
        self.permissionStatus = permission
        self.authorizeResult = authorizeResult
        self.onDeviceLocales = onDeviceLocales
        self.availabilityByLocale = availability
    }

    func authorize() async -> VoicePermissionStatus {
        authorizeCount += 1
        permissionStatus = authorizeResult
        return authorizeResult
    }

    func supportsOnDevice(locale: String) -> Bool {
        onDeviceLocales.contains(locale)
    }

    func availability(locale: String) -> RecognizerAvailability {
        availabilityByLocale[locale] ?? .unsupported
    }

    func start(locale: String, onDevice: Bool) -> AsyncStream<RecognitionUpdate> {
        startCalls.append(StartCall(locale: locale, onDevice: onDevice))
        let (stream, continuation) = AsyncStream<RecognitionUpdate>.makeStream(bufferingPolicy: .unbounded)
        continuations.append(continuation)
        return stream
    }

    func stop() {
        stopCount += 1
        if let finalOnStop {
            emit(.final(finalOnStop))
            finish()
        }
    }

    func cancel() {
        cancelCount += 1
        finish()
    }

    /// Pushes an event into the latest session's stream.
    func emit(_ update: RecognitionUpdate) {
        continuations.last?.yield(update)
    }

    /// Pushes an event into the stream of session `index` (0-based start order).
    func emit(_ update: RecognitionUpdate, toSession index: Int) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].yield(update)
    }

    func finish() {
        continuations.last?.finish()
    }
}

// MARK: - Manual clock

/// Deterministic `VoiceTimerScheduling`: actions run only when the test advances the clock.
@MainActor
final class ManualVoiceScheduler: VoiceTimerScheduling {
    @MainActor
    final class Timer: VoiceTimer {
        let fireAt: TimeInterval
        let delay: TimeInterval
        let action: @MainActor @Sendable () -> Void
        private(set) var isCancelled = false
        var hasFired = false

        init(fireAt: TimeInterval, delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
            self.fireAt = fireAt
            self.delay = delay
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var now: TimeInterval = 0
    private(set) var timers: [Timer] = []

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) -> VoiceTimer {
        let timer = Timer(fireAt: now + delay, delay: delay, action: action)
        timers.append(timer)
        return timer
    }

    /// Moves the clock forward, firing due (not cancelled) timers in time order.
    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = timers
            .filter({ !$0.isCancelled && !$0.hasFired && $0.fireAt <= target + 1e-9 })
            .min(by: { $0.fireAt < $1.fireAt }) {
            now = max(now, next.fireAt)
            next.hasFired = true
            next.action()
        }
        now = target
    }

    /// Timers that are still armed.
    var pendingTimers: [Timer] {
        timers.filter { !$0.isCancelled && !$0.hasFired }
    }
}

// MARK: - Submitter

/// Records `submitVoiceWord` calls. With `holdsSubmissions`, each call suspends until `releaseAll()`.
@MainActor
final class FakeVoiceSubmitter: VoiceWordSubmitting {
    struct Call: Equatable {
        let text: String
        let languageHint: String
    }

    var outcome: AddWordOutcome
    var holdsSubmissions = false
    private(set) var calls: [Call] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(outcome: AddWordOutcome = .added(makeTestEntry("run", translations: ["бігти"], createdOffset: 0))) {
        self.outcome = outcome
    }

    func submitVoiceWord(_ rawText: String, languageHint: String) async -> AddWordOutcome {
        calls.append(Call(text: rawText, languageHint: languageHint))
        if holdsSubmissions {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiting.append(continuation)
            }
        }
        return outcome
    }

    var waitingCount: Int {
        waiting.count
    }

    func releaseAll() {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }
}

// MARK: - Audio session / speech

@MainActor
final class FakeAudioSession: AudioSessionControlling {
    enum Event: Equatable {
        case recording
        case playback
        case deactivate
    }

    var failsRecording = false
    private(set) var events: [Event] = []

    func activateForRecording() throws {
        events.append(.recording)
        if failsRecording {
            throw MobileTestError(reason: "audio session unavailable")
        }
    }

    func activateForPlayback() throws {
        events.append(.playback)
    }

    func deactivate() throws {
        events.append(.deactivate)
    }
}

@MainActor
final class FakeVoiceSpeech: SpeechSpeaking {
    struct Spoken: Equatable {
        let text: String
        let languageCode: String
    }

    private(set) var spoken: [Spoken] = []
    private(set) var stopCount = 0

    func speak(_ text: String, languageCode: String) {
        spoken.append(Spoken(text: text, languageCode: languageCode))
    }

    func stop() {
        stopCount += 1
    }
}

// MARK: - Async helpers

/// Lets main-actor jobs (the model's stream consumer) run until `condition` holds or the timeout expires.
@MainActor
func waitUntil(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("condition not met within \(timeout) s", file: file, line: line)
            return
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Gives pending main-actor jobs a chance to run (used before asserting that something did NOT happen).
@MainActor
func settleMainActor() async {
    for _ in 0..<20 {
        await Task.yield()
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<20 {
        await Task.yield()
    }
}
