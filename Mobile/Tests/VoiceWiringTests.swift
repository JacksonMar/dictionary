// I2b wiring: hosted tests never touch the microphone or the real `voiceLanguage` default (§4 "under tests"), and the
// `vocabapp://voice` route is consumed once by the add sheet (DI10).
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

final class VoiceWiringTests: XCTestCase {
    @MainActor
    func testMakeLiveUnderXCTestHasNoMicrophoneAndInMemoryVoiceLanguage() async {
        let container = AppContainer.makeLive(environment: [AppContainer.xcTestEnvironmentKey: "/tmp/x.xctestconfiguration"])
        XCTAssertNil(container.speechRecognizer, "hosted tests never start speech recognition")
        XCTAssertNil(container.audioSession, "hosted tests never change the audio session")
        XCTAssertTrue(container.voiceLanguageStore is InMemoryVoiceLanguageStore)

        // The voice model built from such a container shows the "unavailable" error with a manual field.
        let model = MobileAppModel(container: container)
        let voice = model.makeVoiceCaptureModel(scheduler: ManualVoiceScheduler())
        await voice.toggleListening()
        XCTAssertEqual(voice.phase, .error(.recognizerUnavailable))
        XCTAssertTrue(voice.showsEditableField)
    }

    @MainActor
    func testMakeLiveOutsideXCTestUsesUserDefaultsVoiceLanguage() async {
        // Construction only (no recognition is started).
        let container = AppContainer.makeLive(environment: [:])
        XCTAssertTrue(container.voiceLanguageStore is UserDefaultsVoiceLanguageStore)
        #if os(iOS)
        XCTAssertNotNil(container.speechRecognizer)
        XCTAssertNotNil(container.audioSession)
        #else
        XCTAssertNil(container.speechRecognizer)
        XCTAssertNil(container.audioSession)
        #endif
    }

    @MainActor
    func testVoiceRouteIsTakenOnceByTheAddSheet() async throws {
        let router = Router()
        XCTAssertNil(router.takeVoiceCapture(), "nothing to take on the list")

        XCTAssertTrue(router.open(url: try XCTUnwrap(URL(string: "vocabapp://voice?lang=it"))))
        XCTAssertEqual(router.presentedSheet, .addWord)
        XCTAssertEqual(router.takeVoiceCapture(), VoiceCaptureLaunch(languageID: "it"))
        XCTAssertEqual(router.route, .addSheet, "the sheet stays open")
        XCTAssertEqual(router.presentedSheet, .addWord)
        XCTAssertNil(router.takeVoiceCapture(), "taken once")

        // A second link while the sheet is open starts listening again.
        router.open(url: try XCTUnwrap(URL(string: "vocabapp://voice")))
        XCTAssertEqual(router.takeVoiceCapture(), VoiceCaptureLaunch(languageID: nil))

        router.open(.addSheet)
        XCTAssertNil(router.takeVoiceCapture(), "the plain add sheet does not listen")
    }

    func testVoiceLanguageBasics() {
        XCTAssertEqual(VoiceLanguage.default, .english)
        XCTAssertEqual(VoiceLanguage.allCases.map(\.languageHint), ["en", "it"])
        XCTAssertEqual(VoiceLanguage.allCases.map(\.shortTitle), ["EN", "IT"])
        XCTAssertEqual(VoiceLanguage(storedValue: nil), .english)
        XCTAssertEqual(VoiceLanguage(storedValue: "it"), .italian)
        XCTAssertEqual(VoiceLanguage(storedValue: "it-IT"), .english)
        XCTAssertEqual(VoicePermissionStatus.combine(speech: .authorized, microphone: .denied), .denied)
        XCTAssertEqual(VoicePermissionStatus.combine(speech: .restricted, microphone: .authorized), .restricted)
        XCTAssertEqual(VoicePermissionStatus.combine(speech: .authorized, microphone: .notDetermined), .notDetermined)
        XCTAssertEqual(VoicePermissionStatus.combine(speech: .authorized, microphone: .authorized), .authorized)
        XCTAssertEqual(AudioLevel.normalized(rms: 0), 0)
        XCTAssertEqual(AudioLevel.normalized(rms: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioLevel.normalized(rms: .nan), 0)
        XCTAssertEqual(AudioLevel.normalized(rms: 0.001), 0, "−60 dB clamps to silence")
        for language in [AppLanguage.en, .uk] {
            XCTAssertNotEqual(VoiceLanguage.english.displayName(language: language),
                              VoiceLanguage.italian.displayName(language: language))
        }
    }
}
