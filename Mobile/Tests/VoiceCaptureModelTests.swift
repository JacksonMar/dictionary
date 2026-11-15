// I2b.1 (IOS_PLAN DI10–DI13, §4, §7 I2b): `VoiceCaptureModel` state machine with `FakeSpeechRecognizer` and a
// manual clock. Confirmation is always required (iU15 = (a)): recognized text never reaches `VoiceWordSubmitting`
// without an explicit `submit()`; one submit = exactly one call with the voice language as the hint.
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

final class VoiceCaptureModelTests: XCTestCase {
    @MainActor
    private struct Harness {
        let model: VoiceCaptureModel
        let recognizer: FakeSpeechRecognizer
        let submitter: FakeVoiceSubmitter
        let store: InMemoryVoiceLanguageStore
        let scheduler: ManualVoiceScheduler
        let audio: FakeAudioSession
        let speech: FakeVoiceSpeech
    }

    @MainActor
    private func makeHarness(
        recognizer: FakeSpeechRecognizer? = nil,
        submitter: FakeVoiceSubmitter? = nil,
        language: VoiceLanguage = .english
    ) -> Harness {
        let recognizer = recognizer ?? FakeSpeechRecognizer()
        let submitter = submitter ?? FakeVoiceSubmitter()
        let store = InMemoryVoiceLanguageStore(voiceLanguage: language)
        let scheduler = ManualVoiceScheduler()
        let audio = FakeAudioSession()
        let speech = FakeVoiceSpeech()
        let model = VoiceCaptureModel(
            recognizer: recognizer,
            submitter: submitter,
            languageStore: store,
            scheduler: scheduler,
            speech: speech,
            audioSession: audio
        )
        return Harness(
            model: model, recognizer: recognizer, submitter: submitter, store: store,
            scheduler: scheduler, audio: audio, speech: speech
        )
    }

    /// Starts listening and checks the session really started.
    @MainActor
    private func startListening(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) async {
        await harness.model.toggleListening()
        XCTAssertEqual(harness.model.phase, .listening, file: file, line: line)
    }

    // MARK: - I2b.1 required

    @MainActor
    func testPermissionDeniedShowsSettingsLink() async {
        // Denied up front: no system prompt, no recognition, error with the Settings link and a manual field.
        let denied = makeHarness(recognizer: FakeSpeechRecognizer(permission: .denied))
        await denied.model.toggleListening()
        XCTAssertEqual(denied.model.phase, .error(.permissionDenied))
        XCTAssertTrue(denied.model.showsSettingsLink)
        XCTAssertTrue(denied.model.showsEditableField, "manual entry stays available")
        XCTAssertEqual(denied.recognizer.authorizeCount, 0)
        XCTAssertTrue(denied.recognizer.startCalls.isEmpty, "microphone must not start without permission")
        XCTAssertFalse(denied.audio.events.contains(.recording))
        XCTAssertFalse(VoiceCaptureError.permissionDenied.message(language: .en).isEmpty)
        XCTAssertFalse(VoiceCaptureError.permissionDenied.message(language: .uk).isEmpty)
        XCTAssertNotEqual(
            VoiceCaptureError.permissionDenied.message(language: .en),
            VoiceCaptureError.permissionDenied.message(language: .uk)
        )

        // Manual entry in the error state submits with the voice language hint.
        denied.model.editableText = " run "
        XCTAssertTrue(denied.model.canSubmit)
        await denied.model.submit()
        XCTAssertEqual(denied.submitter.calls, [.init(text: "run", languageHint: "en")])

        // Not asked yet → the system prompt is shown once; the user refuses → the same error.
        let refused = makeHarness(recognizer: FakeSpeechRecognizer(permission: .notDetermined, authorizeResult: .denied))
        await refused.model.toggleListening()
        XCTAssertEqual(refused.recognizer.authorizeCount, 1)
        XCTAssertEqual(refused.model.phase, .error(.permissionDenied))
        XCTAssertTrue(refused.model.showsSettingsLink)
        XCTAssertTrue(refused.recognizer.startCalls.isEmpty)

        // Restricted by policy → error without the Settings link (the user cannot change it).
        let restricted = makeHarness(recognizer: FakeSpeechRecognizer(permission: .restricted))
        await restricted.model.toggleListening()
        XCTAssertEqual(restricted.model.phase, .error(.permissionRestricted))
        XCTAssertFalse(restricted.model.showsSettingsLink)
        XCTAssertTrue(restricted.recognizer.startCalls.isEmpty)

        // Deep link (`vocabapp://voice`) with a denied permission → the same Settings link, no listening.
        let linked = makeHarness(recognizer: FakeSpeechRecognizer(permission: .denied))
        await linked.model.launch(languageID: "it")
        XCTAssertEqual(linked.model.phase, .error(.permissionDenied))
        XCTAssertTrue(linked.model.showsSettingsLink)
        XCTAssertTrue(linked.recognizer.startCalls.isEmpty)

        // Granted on the prompt → listens right away.
        let granted = makeHarness(recognizer: FakeSpeechRecognizer(permission: .notDetermined, authorizeResult: .authorized))
        await granted.model.toggleListening()
        XCTAssertEqual(granted.recognizer.authorizeCount, 1)
        XCTAssertEqual(granted.model.phase, .listening)
        XCTAssertEqual(granted.recognizer.startCalls.count, 1)
    }

    @MainActor
    func testPartialThenFinalFillsEditableText() async {
        let harness = makeHarness()
        let model = harness.model
        await startListening(harness)
        XCTAssertEqual(harness.recognizer.startCalls, [.init(locale: "en-US", onDevice: true)])
        XCTAssertEqual(harness.audio.events, [.recording], "recording session activated before the recognizer")
        XCTAssertFalse(model.showsEditableField, "while listening only the live text is shown")

        harness.recognizer.emit(.level(0.6))
        harness.recognizer.emit(.partial(RecognitionTranscript(text: "ta")))
        await waitUntil { model.partialText == "ta" }
        XCTAssertEqual(model.level, 0.6, accuracy: 0.0001)
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(model.editableText, "", "partials do not touch the editable field")

        harness.recognizer.emit(.partial(RecognitionTranscript(text: "take")))
        await waitUntil { model.partialText == "take" }
        harness.recognizer.emit(.final(RecognitionTranscript(text: "take off", confidence: 0.95, alternatives: ["take of"])))
        await waitUntil { model.phase == .recognized }

        XCTAssertEqual(model.editableText, "take off")
        XCTAssertEqual(model.partialText, "take off")
        XCTAssertEqual(model.alternatives, ["take of"])
        XCTAssertTrue(model.showsEditableField)
        XCTAssertTrue(model.canSubmit)
        XCTAssertFalse(model.isFinalizing)
        XCTAssertEqual(model.level, 0)
        XCTAssertEqual(harness.audio.events.last, .deactivate, "microphone released after the final result")
        XCTAssertTrue(harness.scheduler.pendingTimers.isEmpty, "no timer may stop a finished session")

        // The text stays editable and is not submitted on its own (iU15).
        model.editableText = "take-off"
        await settleMainActor()
        XCTAssertTrue(harness.submitter.calls.isEmpty)
        XCTAssertEqual(model.phase, .recognized)
    }

    @MainActor
    func testAutoStopAfterSilence() async {
        let harness = makeHarness()
        let model = harness.model
        await startListening(harness)

        // No partial yet → the silence timer is not armed (only the 10 s cap).
        harness.scheduler.advance(by: 3)
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(harness.recognizer.stopCount, 0)

        harness.recognizer.emit(.partial(RecognitionTranscript(text: "ca")))
        await waitUntil { model.partialText == "ca" }
        harness.scheduler.advance(by: 1.4)
        XCTAssertEqual(model.phase, .listening, "1.4 s of silence is not enough")

        // A new partial restarts the 1.5 s window.
        harness.recognizer.emit(.partial(RecognitionTranscript(text: "casa")))
        await waitUntil { model.partialText == "casa" }
        harness.scheduler.advance(by: 1.4)
        XCTAssertEqual(model.phase, .listening, "silence counts from the last partial")
        harness.scheduler.advance(by: 0.11)

        XCTAssertEqual(model.phase, .recognized)
        XCTAssertEqual(harness.recognizer.stopCount, 1)
        XCTAssertEqual(harness.recognizer.cancelCount, 0, "stop, not cancel: the final text is still wanted")
        XCTAssertEqual(model.editableText, "casa", "the field shows what was recognized so far")
        XCTAssertTrue(model.isFinalizing)
        XCTAssertEqual(VoiceCaptureModel.defaultSilenceTimeout, 1.5)

        // The final result arrives after the stop and replaces the (unedited) field.
        harness.recognizer.emit(.final(RecognitionTranscript(text: "casa")))
        await waitUntil { !model.isFinalizing }
        XCTAssertEqual(model.editableText, "casa")
        XCTAssertTrue(harness.submitter.calls.isEmpty, "auto-stop never auto-adds (iU15)")
    }

    @MainActor
    func testMaxDurationStops() async {
        let harness = makeHarness()
        let model = harness.model
        await startListening(harness)
        XCTAssertEqual(VoiceCaptureModel.defaultMaxDuration, 10)
        XCTAssertTrue(harness.scheduler.timers.contains { $0.delay == 10 }, "10 s cap armed at start")

        // Continuous speech: a partial every second keeps the silence timer from firing.
        for second in 1...9 {
            harness.recognizer.emit(.partial(RecognitionTranscript(text: "word\(second)")))
            await waitUntil { model.partialText == "word\(second)" }
            harness.scheduler.advance(by: 1)
            XCTAssertEqual(model.phase, .listening, "still listening after \(second) s")
        }
        harness.recognizer.emit(.partial(RecognitionTranscript(text: "word10")))
        await waitUntil { model.partialText == "word10" }
        harness.scheduler.advance(by: 1)

        XCTAssertEqual(model.phase, .recognized, "stopped at 10 s")
        XCTAssertEqual(harness.scheduler.now, 10, accuracy: 0.0001)
        XCTAssertEqual(harness.recognizer.stopCount, 1)
        XCTAssertEqual(model.editableText, "word10")
        XCTAssertTrue(harness.scheduler.pendingTimers.isEmpty)

        // Nothing fires later.
        harness.scheduler.advance(by: 30)
        XCTAssertEqual(harness.recognizer.stopCount, 1)
        XCTAssertTrue(harness.submitter.calls.isEmpty)
    }

    @MainActor
    func testTapStopsListening() async {
        let harness = makeHarness()
        let model = harness.model
        await startListening(harness)
        XCTAssertTrue(model.isListening)

        harness.recognizer.emit(.partial(RecognitionTranscript(text: "perch")))
        await waitUntil { model.partialText == "perch" }

        await model.toggleListening()   // second tap

        XCTAssertEqual(model.phase, .recognized)
        XCTAssertFalse(model.isListening)
        XCTAssertEqual(harness.recognizer.stopCount, 1)
        XCTAssertEqual(harness.recognizer.cancelCount, 0)
        XCTAssertEqual(model.editableText, "perch")
        XCTAssertTrue(model.isFinalizing)
        XCTAssertEqual(harness.audio.events, [.recording, .deactivate])
        XCTAssertTrue(harness.scheduler.pendingTimers.isEmpty, "tap cancels the silence and max timers")

        harness.recognizer.emit(.final(RecognitionTranscript(text: "perché")))
        await waitUntil { model.editableText == "perché" }
        XCTAssertFalse(model.isFinalizing)

        // Timers of the stopped session never fire.
        harness.scheduler.advance(by: 20)
        XCTAssertEqual(harness.recognizer.stopCount, 1)
        XCTAssertEqual(model.phase, .recognized)

        // A third tap starts a new session.
        await model.toggleListening()
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(harness.recognizer.startCalls.count, 2)
        XCTAssertEqual(model.editableText, "")
    }

    @MainActor
    func testSubmitCallsUseCaseOnceWithLanguageHint() async {
        let harness = makeHarness()
        let model = harness.model
        model.selectLanguage(.italian)
        await startListening(harness)
        XCTAssertEqual(harness.recognizer.startCalls.last, .init(locale: "it-IT", onDevice: true))

        harness.recognizer.emit(.final(RecognitionTranscript(text: "  casa ")))
        await waitUntil { model.phase == .recognized }
        XCTAssertTrue(harness.submitter.calls.isEmpty, "nothing is sent before «Add»")

        await model.submit()

        XCTAssertEqual(harness.submitter.calls, [.init(text: "casa", languageHint: "it")])
        guard case .result(let result) = model.phase else { return XCTFail("expected .result, got \(model.phase)") }
        XCTAssertFalse(result.isFailure)
        XCTAssertFalse(result.title.isEmpty)

        // Repeated taps on the result card do not resend.
        await model.submit()
        XCTAssertEqual(harness.submitter.calls.count, 1)

        // English hint and the user's edit are what gets sent.
        let english = makeHarness()
        await startListening(english)
        english.recognizer.emit(.final(RecognitionTranscript(text: "tak of")))
        await waitUntil { english.model.phase == .recognized }
        english.model.editableText = "take off"
        await english.model.submit()
        XCTAssertEqual(english.submitter.calls, [.init(text: "take off", languageHint: "en")])
    }

    @MainActor
    func testEmptyRecognitionDoesNotSubmit() async {
        // Tap-stop without any speech.
        let silent = makeHarness()
        await startListening(silent)
        await silent.model.toggleListening()
        silent.recognizer.finish()   // the recognizer ends the stream without a final text
        await waitUntil { !silent.model.isFinalizing }
        XCTAssertEqual(silent.model.phase, .recognized)
        XCTAssertTrue(silent.model.isRecognitionEmpty)
        XCTAssertFalse(silent.model.canSubmit)
        await silent.model.submit()
        XCTAssertTrue(silent.submitter.calls.isEmpty)

        // Empty / whitespace-only final result.
        for text in ["", "   ", "\n"] {
            let harness = makeHarness()
            await startListening(harness)
            harness.recognizer.emit(.final(RecognitionTranscript(text: text)))
            await waitUntil { harness.model.phase == .recognized }
            XCTAssertFalse(harness.model.canSubmit, text.debugDescription)
            await harness.model.submit()
            XCTAssertTrue(harness.submitter.calls.isEmpty, text.debugDescription)
        }

        // `noSpeech` from the recognizer → recognized-empty state (not an error), still nothing sent.
        let noSpeech = makeHarness()
        await startListening(noSpeech)
        noSpeech.recognizer.emit(.failed(.noSpeech))
        await waitUntil { noSpeech.model.phase != .listening }
        XCTAssertEqual(noSpeech.model.phase, .recognized)
        XCTAssertTrue(noSpeech.model.isRecognitionEmpty)
        await noSpeech.model.submit()
        XCTAssertTrue(noSpeech.submitter.calls.isEmpty)

        // Clearing a recognized word by hand disables «Add» too.
        let cleared = makeHarness()
        await startListening(cleared)
        cleared.recognizer.emit(.final(RecognitionTranscript(text: "run")))
        await waitUntil { cleared.model.phase == .recognized }
        cleared.model.editableText = "  "
        XCTAssertFalse(cleared.model.canSubmit)
        await cleared.model.submit()
        XCTAssertTrue(cleared.submitter.calls.isEmpty)
    }

    @MainActor
    func testLanguageToggleRemembered() async throws {
        let harness = makeHarness()
        XCTAssertEqual(harness.model.language, .english)

        harness.model.selectLanguage(.italian)
        XCTAssertEqual(harness.model.language, .italian)
        XCTAssertEqual(harness.store.voiceLanguage, .italian, "saved as the voice language")

        // A new sheet (new model over the same store) starts in Italian and listens with it-IT.
        let next = VoiceCaptureModel(
            recognizer: harness.recognizer,
            submitter: harness.submitter,
            languageStore: harness.store,
            scheduler: harness.scheduler
        )
        XCTAssertEqual(next.language, .italian)
        await next.toggleListening()
        XCTAssertEqual(harness.recognizer.startCalls.last?.locale, "it-IT")

        // The toggle is ignored while listening.
        next.selectLanguage(.english)
        XCTAssertEqual(next.language, .italian)
        XCTAssertEqual(harness.store.voiceLanguage, .italian)
        next.cancel()

        // Deep-link language applies to that session only.
        let linked = makeHarness(language: .english)
        await linked.model.launch(languageID: "it")
        XCTAssertEqual(linked.recognizer.startCalls.last?.locale, "it-IT")
        XCTAssertEqual(linked.store.voiceLanguage, .english, "the link does not change the remembered language")

        // UserDefaults store: key `voiceLanguage`, values "en"/"it", unknown → English.
        let suite = "VoiceCaptureModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = UserDefaultsVoiceLanguageStore(defaults: defaults)
        XCTAssertEqual(UserDefaultsVoiceLanguageStore.key, "voiceLanguage")
        XCTAssertEqual(stored.voiceLanguage, .english)
        stored.voiceLanguage = .italian
        XCTAssertEqual(defaults.string(forKey: "voiceLanguage"), "it")
        XCTAssertEqual(UserDefaultsVoiceLanguageStore(defaults: defaults).voiceLanguage, .italian)
        defaults.set("fr", forKey: "voiceLanguage")
        XCTAssertEqual(stored.voiceLanguage, .english)
        defaults.set(" IT ", forKey: "voiceLanguage")
        XCTAssertEqual(stored.voiceLanguage, .italian)
    }

    @MainActor
    func testCancelStopsEngine() async {
        let harness = makeHarness()
        let model = harness.model
        await startListening(harness)
        harness.recognizer.emit(.partial(RecognitionTranscript(text: "come")))
        await waitUntil { model.partialText == "come" }

        model.cancel()

        XCTAssertEqual(harness.recognizer.cancelCount, 1, "cancel stops the recognizer and the audio engine")
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.editableText, "")
        XCTAssertEqual(model.partialText, "")
        XCTAssertEqual(harness.audio.events.last, .deactivate)
        XCTAssertGreaterThanOrEqual(harness.speech.stopCount, 1)
        XCTAssertTrue(harness.scheduler.pendingTimers.isEmpty)

        // Late events of the cancelled session are ignored; timers never fire.
        harness.recognizer.emit(.final(RecognitionTranscript(text: "come")), toSession: 0)
        harness.scheduler.advance(by: 20)
        await settleMainActor()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.editableText, "")
        XCTAssertEqual(harness.recognizer.stopCount, 0)
        XCTAssertTrue(harness.submitter.calls.isEmpty, "cancel never submits")

        // Cancelling during finalizing (after a tap-stop) also cancels the recognizer.
        let finalizing = makeHarness()
        await startListening(finalizing)
        finalizing.recognizer.emit(.partial(RecognitionTranscript(text: "run")))
        await waitUntil { finalizing.model.partialText == "run" }
        await finalizing.model.toggleListening()
        XCTAssertTrue(finalizing.model.isFinalizing)
        finalizing.model.cancel()
        XCTAssertEqual(finalizing.recognizer.cancelCount, 1)
        XCTAssertEqual(finalizing.model.phase, .idle)
    }

    // MARK: - iU15 / concurrency / edits

    @MainActor
    func testRecognizedTextNeverAutoSubmits() async {
        // High-confidence single word (the case iU15 option (b) would have auto-added) — still needs «Add».
        let harness = makeHarness()
        await startListening(harness)
        harness.recognizer.emit(.final(RecognitionTranscript(text: "run", confidence: 0.99)))
        await waitUntil { harness.model.phase == .recognized }
        harness.scheduler.advance(by: 120)
        await settleMainActor()
        XCTAssertTrue(harness.submitter.calls.isEmpty)
        XCTAssertEqual(harness.model.phase, .recognized)

        // Auto-stop by silence and by the cap, a stream that ends without a final — none submits.
        let silence = makeHarness()
        await startListening(silence)
        silence.recognizer.emit(.partial(RecognitionTranscript(text: "casa")))
        await waitUntil { silence.model.partialText == "casa" }
        silence.scheduler.advance(by: 1.5)
        silence.recognizer.emit(.final(RecognitionTranscript(text: "casa", confidence: 1)))
        await waitUntil { !silence.model.isFinalizing }
        silence.scheduler.advance(by: 60)
        await settleMainActor()
        XCTAssertTrue(silence.submitter.calls.isEmpty)

        let ended = makeHarness()
        await startListening(ended)
        ended.recognizer.emit(.partial(RecognitionTranscript(text: "come")))
        await waitUntil { ended.model.partialText == "come" }
        ended.recognizer.finish()
        await waitUntil { ended.model.phase == .recognized }
        XCTAssertEqual(ended.model.editableText, "come")
        await settleMainActor()
        XCTAssertTrue(ended.submitter.calls.isEmpty)

        // Deep-link launch that listens right away does not auto-add either.
        let linked = makeHarness()
        await linked.model.launch(languageID: nil)
        XCTAssertEqual(linked.model.phase, .listening)
        linked.recognizer.emit(.final(RecognitionTranscript(text: "take off", confidence: 0.98)))
        await waitUntil { linked.model.phase == .recognized }
        await settleMainActor()
        XCTAssertTrue(linked.submitter.calls.isEmpty)
    }

    @MainActor
    func testConcurrentSubmitMakesOneCall() async {
        let submitter = FakeVoiceSubmitter()
        submitter.holdsSubmissions = true
        let harness = makeHarness(submitter: submitter)
        let model = harness.model
        await startListening(harness)
        harness.recognizer.emit(.final(RecognitionTranscript(text: "run")))
        await waitUntil { model.phase == .recognized }

        let first = Task { @MainActor in await model.submit() }
        await waitUntil { submitter.waitingCount == 1 }
        XCTAssertEqual(model.phase, .submitting)
        XCTAssertFalse(model.canSubmit)
        XCTAssertTrue(model.isBusy)

        // Double tap / keyboard «Done» + button while the request is in flight.
        let second = Task { @MainActor in await model.submit() }
        let third = Task { @MainActor in await model.submit() }
        await settleMainActor()
        XCTAssertEqual(submitter.calls.count, 1, "a second «Add» while the first is in flight must not submit")
        // Mic and «Again» do nothing while submitting.
        await model.toggleListening()
        await model.again()
        model.selectLanguage(.italian)
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(harness.recognizer.startCalls.count, 1)

        // Release everything first (a buggy model would otherwise hang on its extra held calls).
        submitter.releaseAll()
        await first.value
        await second.value
        await third.value
        submitter.releaseAll()
        XCTAssertEqual(submitter.calls, [.init(text: "run", languageHint: "en")])
        if case .result = model.phase {} else { XCTFail("expected .result, got \(model.phase)") }
    }

    @MainActor
    func testUserEditNotOverwrittenByLateFinal() async {
        let harness = makeHarness()
        let model = harness.model
        await startListening(harness)
        harness.recognizer.emit(.partial(RecognitionTranscript(text: "tak")))
        await waitUntil { model.partialText == "tak" }
        await model.toggleListening()
        XCTAssertTrue(model.isFinalizing)
        XCTAssertEqual(model.editableText, "tak")

        model.editableText = "take off"          // user edits while the recognizer finalizes
        harness.recognizer.emit(.partial(RecognitionTranscript(text: "take")))
        harness.recognizer.emit(.final(RecognitionTranscript(text: "take of")))
        await waitUntil { !model.isFinalizing }

        XCTAssertEqual(model.editableText, "take off", "the late final must not overwrite the user's edit")
        XCTAssertEqual(model.phase, .recognized)

        await model.submit()
        XCTAssertEqual(harness.submitter.calls, [.init(text: "take off", languageHint: "en")])
    }

    // MARK: - Extra

    @MainActor
    func testLateFinalReplacesUneditedTextAndOldSessionIsIgnored() async {
        let harness = makeHarness()
        let model = harness.model
        await startListening(harness)
        harness.recognizer.emit(.partial(RecognitionTranscript(text: "pane")))
        await waitUntil { model.partialText == "pane" }
        await model.toggleListening()
        harness.recognizer.emit(.final(RecognitionTranscript(text: "pane e", alternatives: ["panne"])))
        await waitUntil { model.editableText == "pane e" }
        XCTAssertEqual(model.alternatives, ["panne"])

        // «Again» starts a new session; events of the first one are ignored.
        await model.again()
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(model.editableText, "")
        harness.recognizer.emit(.partial(RecognitionTranscript(text: "stale")), toSession: 0)
        harness.recognizer.emit(.partial(RecognitionTranscript(text: "fresh")), toSession: 1)
        await waitUntil { model.partialText == "fresh" }
        await settleMainActor()
        XCTAssertEqual(model.partialText, "fresh")
    }

    @MainActor
    func testRecognitionFailureShowsErrorWithManualEntry() async {
        // Offline mid-session with nothing recognized → error + manual field.
        let offline = makeHarness()
        await startListening(offline)
        offline.recognizer.emit(.failed(.offlineWithoutOnDevice))
        await waitUntil { offline.model.phase != .listening }
        XCTAssertEqual(offline.model.phase, .error(.offline))
        XCTAssertFalse(offline.model.showsSettingsLink)
        XCTAssertTrue(offline.model.showsEditableField)
        XCTAssertGreaterThanOrEqual(offline.recognizer.cancelCount, 1)
        XCTAssertEqual(offline.audio.events.last, .deactivate)
        offline.model.editableText = "perché"
        await offline.model.submit()
        XCTAssertEqual(offline.submitter.calls, [.init(text: "perché", languageHint: "en")])

        // A failure after something was recognized keeps the text for confirmation.
        let partial = makeHarness()
        await startListening(partial)
        partial.recognizer.emit(.partial(RecognitionTranscript(text: "come")))
        await waitUntil { partial.model.partialText == "come" }
        partial.recognizer.emit(.failed(.failed("kAFAssistantErrorDomain 1101")))
        await waitUntil { partial.model.phase != .listening }
        XCTAssertEqual(partial.model.phase, .recognized)
        XCTAssertEqual(partial.model.editableText, "come")
        XCTAssertTrue(partial.submitter.calls.isEmpty)

        // The microphone cannot start → audio error, recognizer never started.
        let audio = makeHarness()
        audio.audio.failsRecording = true
        await audio.model.toggleListening()
        XCTAssertEqual(audio.model.phase, .error(.audio))
        XCTAssertTrue(audio.recognizer.startCalls.isEmpty)

        // No recognizer at all (Linux / simulator without Speech) → unavailable error, manual field.
        let none = VoiceCaptureModel(
            recognizer: nil,
            submitter: FakeVoiceSubmitter(),
            languageStore: InMemoryVoiceLanguageStore(),
            scheduler: ManualVoiceScheduler()
        )
        await none.toggleListening()
        XCTAssertEqual(none.phase, .error(.recognizerUnavailable))
        XCTAssertTrue(none.showsEditableField)
    }

    @MainActor
    func testRejectedTextKeepsFieldForEditing() async {
        let submitter = FakeVoiceSubmitter(outcome: .rejected(.tooManyWords(max: 8)))
        let harness = makeHarness(submitter: submitter)
        await startListening(harness)
        harness.recognizer.emit(.final(RecognitionTranscript(text: "one two three four five six seven eight nine")))
        await waitUntil { harness.model.phase == .recognized }
        await harness.model.submit()
        XCTAssertEqual(submitter.calls.count, 1)
        XCTAssertEqual(harness.model.phase, .recognized, "back to the editable field")
        XCTAssertNotNil(harness.model.submitError)
        XCTAssertTrue(harness.model.canSubmit)
    }

    @MainActor
    func testSpeakResultSwitchesAudioToPlayback() async {
        let ready = makeTestEntry(
            "house",
            translations: ["будинок"],
            createdOffset: 0,
            variants: ["it": EntryVariant(word: "casa", translations: ["дім"], status: .ready,
                                          sourceKey: TextNormalizer.key("house"))]
        )
        let harness = makeHarness(submitter: FakeVoiceSubmitter(outcome: .added(ready)), language: .italian)
        await startListening(harness)
        harness.recognizer.emit(.final(RecognitionTranscript(text: "casa")))
        await waitUntil { harness.model.phase == .recognized }
        await harness.model.submit()
        let result = harness.model.result
        XCTAssertEqual(result?.speakText, "casa")
        XCTAssertEqual(result?.speakLanguageCode, "it-IT")

        harness.model.speakResult()
        XCTAssertEqual(harness.audio.events.last, .playback, "playback category before speaking (iU14)")
        XCTAssertEqual(harness.speech.spoken, [.init(text: "casa", languageCode: "it-IT")])
    }

    @MainActor
    func testLaunchListensImmediatelyOnlyWhenAuthorized() async {
        let authorized = makeHarness()
        await authorized.model.launch(languageID: "IT")
        XCTAssertEqual(authorized.model.phase, .listening)
        XCTAssertEqual(authorized.recognizer.startCalls, [.init(locale: "it-IT", onDevice: true)])
        XCTAssertEqual(authorized.model.language, .italian)

        // Not asked yet → idle (the prompt appears after the user taps the mic).
        let notAsked = makeHarness(recognizer: FakeSpeechRecognizer(permission: .notDetermined))
        await notAsked.model.launch(languageID: nil)
        XCTAssertEqual(notAsked.model.phase, .idle)
        XCTAssertEqual(notAsked.recognizer.authorizeCount, 0)
        XCTAssertTrue(notAsked.recognizer.startCalls.isEmpty)

        // Unknown language in the link → the remembered language.
        let unknown = makeHarness(language: .italian)
        await unknown.model.launch(languageID: "fr")
        XCTAssertEqual(unknown.recognizer.startCalls.last?.locale, "it-IT")
    }
}
