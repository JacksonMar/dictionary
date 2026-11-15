// I2b.2 (IOS_PLAN DI12): on-device recognition first (`requiresOnDeviceRecognition = supportsOnDeviceRecognition`);
// without an on-device model — Apple server recognition with a note under the field; offline without an on-device
// model — a clear error and the manual field.
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

final class RecognitionConfigTests: XCTestCase {
    @MainActor
    private func makeModel(_ recognizer: FakeSpeechRecognizer, language: VoiceLanguage = .english) -> VoiceCaptureModel {
        VoiceCaptureModel(
            recognizer: recognizer,
            submitter: FakeVoiceSubmitter(),
            languageStore: InMemoryVoiceLanguageStore(voiceLanguage: language),
            scheduler: ManualVoiceScheduler()
        )
    }

    @MainActor
    func testOnDeviceRequiredWhenSupported() async throws {
        // Pure config: on-device whenever the model exists — online or offline.
        for availability in [RecognizerAvailability.available, .unavailable] {
            let config = try RecognitionConfig.make(
                localeIdentifier: "it-IT", supportsOnDevice: true, availability: availability
            ).get()
            XCTAssertEqual(config.localeIdentifier, "it-IT")
            XCTAssertTrue(config.requiresOnDeviceRecognition, "\(availability)")
            XCTAssertFalse(config.usesServerRecognition, "\(availability)")
        }

        // Through the model: the recognizer is started with onDevice = true and no server note.
        for language in VoiceLanguage.allCases {
            let recognizer = FakeSpeechRecognizer()
            let model = makeModel(recognizer, language: language)
            await model.toggleListening()
            XCTAssertEqual(recognizer.startCalls, [.init(locale: language.localeIdentifier, onDevice: true)])
            XCTAssertFalse(model.usesServerRecognition)
            model.cancel()
        }
        XCTAssertEqual(VoiceLanguage.english.localeIdentifier, "en-US")
        XCTAssertEqual(VoiceLanguage.italian.localeIdentifier, "it-IT")

        // Offline but the on-device model exists → still listens.
        let offline = FakeSpeechRecognizer(availability: ["en-US": .unavailable, "it-IT": .unavailable])
        let offlineModel = makeModel(offline)
        await offlineModel.toggleListening()
        XCTAssertEqual(offlineModel.phase, .listening)
        XCTAssertEqual(offline.startCalls.last?.onDevice, true)
    }

    @MainActor
    func testServerFallbackFlagged() async throws {
        let config = try RecognitionConfig.make(
            localeIdentifier: "it-IT", supportsOnDevice: false, availability: .available
        ).get()
        XCTAssertFalse(config.requiresOnDeviceRecognition)
        XCTAssertTrue(config.usesServerRecognition)

        // Only Italian lacks an on-device model: Italian → server + note; English → on-device, no note.
        let recognizer = FakeSpeechRecognizer(onDeviceLocales: ["en-US"])
        let italian = makeModel(recognizer, language: .italian)
        await italian.toggleListening()
        XCTAssertEqual(italian.phase, .listening)
        XCTAssertEqual(recognizer.startCalls.last, .init(locale: "it-IT", onDevice: false))
        XCTAssertTrue(italian.usesServerRecognition, "the UI shows the server-recognition note")

        // The note stays with the recognized text (shown under the field) …
        recognizer.emit(.final(RecognitionTranscript(text: "perché")))
        await waitUntil { italian.phase == .recognized }
        XCTAssertTrue(italian.usesServerRecognition)
        // … and is cleared when the sheet is cancelled.
        italian.cancel()
        XCTAssertFalse(italian.usesServerRecognition)

        let english = makeModel(recognizer, language: .english)
        await english.toggleListening()
        XCTAssertEqual(recognizer.startCalls.last, .init(locale: "en-US", onDevice: true))
        XCTAssertFalse(english.usesServerRecognition)

        // Same model, switching language between sessions updates the flag.
        english.cancel()
        english.selectLanguage(.italian)
        await english.toggleListening()
        XCTAssertTrue(english.usesServerRecognition)
        XCTAssertEqual(recognizer.startCalls.last, .init(locale: "it-IT", onDevice: false))

        // Server note text exists in both interface languages.
        XCTAssertFalse(L10n.text(.voiceServerNote, language: .en).isEmpty)
        XCTAssertFalse(L10n.text(.voiceServerNote, language: .uk).isEmpty)
    }

    @MainActor
    func testOfflineWithoutOnDeviceShowsError() async {
        let result = RecognitionConfig.make(localeIdentifier: "it-IT", supportsOnDevice: false, availability: .unavailable)
        XCTAssertEqual(result, .failure(.offlineWithoutOnDevice))
        XCTAssertEqual(
            RecognitionConfig.make(localeIdentifier: "xx-XX", supportsOnDevice: false, availability: .unsupported),
            .failure(.unsupportedLanguage)
        )
        XCTAssertEqual(
            RecognitionConfig.make(localeIdentifier: "xx-XX", supportsOnDevice: true, availability: .unsupported),
            .failure(.unsupportedLanguage)
        )
        XCTAssertEqual(VoiceCaptureError.from(.offlineWithoutOnDevice), .offline)

        // Model: no on-device model and no network → clear error, recognizer not started, manual field.
        let recognizer = FakeSpeechRecognizer(
            onDeviceLocales: [],
            availability: ["en-US": .unavailable, "it-IT": .unavailable]
        )
        let submitter = FakeVoiceSubmitter()
        let model = VoiceCaptureModel(
            recognizer: recognizer,
            submitter: submitter,
            languageStore: InMemoryVoiceLanguageStore(voiceLanguage: .italian),
            scheduler: ManualVoiceScheduler()
        )
        await model.toggleListening()
        XCTAssertEqual(model.phase, .error(.offline))
        XCTAssertTrue(recognizer.startCalls.isEmpty, "the microphone does not start offline without a model")
        XCTAssertFalse(model.showsSettingsLink)
        XCTAssertTrue(model.showsEditableField, "manual entry instead")
        let english = VoiceCaptureError.offline.message(language: .en)
        let ukrainian = VoiceCaptureError.offline.message(language: .uk)
        XCTAssertFalse(english.isEmpty)
        XCTAssertFalse(ukrainian.isEmpty)
        XCTAssertNotEqual(english, ukrainian)
        XCTAssertNotEqual(english, VoiceCaptureError.recognitionFailed.message(language: .en), "a specific message")

        model.editableText = "perché"
        XCTAssertTrue(model.canSubmit)
        await model.submit()
        XCTAssertEqual(submitter.calls, [.init(text: "perché", languageHint: "it")])

        // Unsupported locale → its own error.
        let unsupported = FakeSpeechRecognizer(availability: [:])
        let unsupportedModel = makeModel(unsupported)
        await unsupportedModel.toggleListening()
        XCTAssertEqual(unsupportedModel.phase, .error(.unsupportedLanguage))
        XCTAssertTrue(unsupported.startCalls.isEmpty)
    }
}
