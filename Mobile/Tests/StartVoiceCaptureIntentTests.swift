// I4.2 (IOS_PLAN §7 I4, §4): «Add by Voice» (Siri / Shortcuts / Action Button). The AppIntents wrapper
// `StartVoiceCaptureIntent` (openAppWhenRun = true) only calls `StartVoiceCaptureRunner.run` with
// `AppContainer.shared.router`, so the runner and the process-wide router are tested here: the voice route with
// the language from the parameter, consumed by the add sheet via `takeVoiceCapture()`, the same route as
// `vocabapp://voice[?lang=…]`, and the router owned by the container (the one `VocabMobileApp` observes).
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

final class StartVoiceCaptureIntentTests: XCTestCase {
    @MainActor
    func testPerformRoutesToVoiceCapture() async throws {
        let router = Router()
        XCTAssertEqual(router.route, .list)

        StartVoiceCaptureRunner.run(language: nil, router: router)
        XCTAssertEqual(router.route, .voiceCapture(languageID: nil), "no parameter → last used voice language")
        XCTAssertEqual(router.presentedSheet, .addWord, "the add sheet is presented")
        XCTAssertEqual(router.takeVoiceCapture(), VoiceCaptureLaunch(languageID: nil))
        XCTAssertEqual(router.route, .addSheet, "request consumed, sheet stays open")
        XCTAssertNil(router.takeVoiceCapture(), "consumed only once")

        // Running again while the sheet is open re-arms listening.
        StartVoiceCaptureRunner.run(language: .auto, router: router)
        XCTAssertEqual(router.route, .voiceCapture(languageID: nil), "Auto → last used voice language")
    }

    @MainActor
    func testLanguageParameterPassedToRoute() async throws {
        let router = Router()
        StartVoiceCaptureRunner.run(language: .italian, router: router)
        XCTAssertEqual(router.route, .voiceCapture(languageID: "it"))
        XCTAssertEqual(router.takeVoiceCapture(), VoiceCaptureLaunch(languageID: "it"))

        StartVoiceCaptureRunner.run(language: .english, router: router)
        XCTAssertEqual(router.takeVoiceCapture(), VoiceCaptureLaunch(languageID: "en"))

        // From another sheet (Settings) the voice sheet replaces it.
        router.open(.settings)
        StartVoiceCaptureRunner.run(language: .italian, router: router)
        XCTAssertEqual(router.route, .voiceCapture(languageID: "it"))
        XCTAssertEqual(router.presentedSheet, .addWord)
    }

    @MainActor
    func testIntentRouteEqualsDeepLinkRoute() async throws {
        // The intent and the widget's `vocabapp://voice` open exactly the same route.
        let cases: [(VoiceLanguageAppEnum?, String)] = [
            (nil, "vocabapp://voice"),
            (.auto, "vocabapp://voice"),
            (.english, "vocabapp://voice?lang=en"),
            (.italian, "vocabapp://voice?lang=it"),
        ]
        for (language, link) in cases {
            let viaIntent = Router()
            StartVoiceCaptureRunner.run(language: language, router: viaIntent)
            let viaLink = Router()
            XCTAssertTrue(viaLink.open(url: try XCTUnwrap(URL(string: link))))
            XCTAssertEqual(viaIntent.route, viaLink.route, "\(String(describing: language)) vs \(link)")
        }
    }

    @MainActor
    func testRouterSharedWithAppViaContainer() async throws {
        let directory = makeTemporaryDirectory(self)
        let container = AppContainer(baseDirectory: directory, settings: InMemorySettingsStore())
        let router = container.router
        XCTAssertTrue(container.router === router, "one router per container (process)")
        XCTAssertEqual(router.route, .list)

        // What the intent does with `AppContainer.shared.router` is visible to whoever observes the container's router.
        StartVoiceCaptureRunner.run(language: .italian, router: container.router)
        XCTAssertEqual(router.route, .voiceCapture(languageID: "it"))

        // Deep links through the same router land in the same state.
        router.dismiss()
        XCTAssertTrue(container.router.open(url: try XCTUnwrap(URL(string: "vocabapp://voice?lang=en"))))
        XCTAssertEqual(router.route, .voiceCapture(languageID: "en"))

        // Another container (e.g. another test) has its own router.
        let other = AppContainer(baseDirectory: makeTemporaryDirectory(self), settings: InMemorySettingsStore())
        XCTAssertFalse(other.router === router)
        XCTAssertEqual(other.router.route, .list)
    }

    func testVoiceLanguageAppEnumMapping() {
        XCTAssertEqual(VoiceLanguageAppEnum.allCases, [.auto, .english, .italian])
        XCTAssertEqual(VoiceLanguageAppEnum.allCases.map(\.rawValue), ["auto", "english", "italian"])

        XCTAssertNil(VoiceLanguageAppEnum.voiceLanguage(for: nil))
        XCTAssertNil(VoiceLanguageAppEnum.voiceLanguage(for: .auto))
        XCTAssertEqual(VoiceLanguageAppEnum.voiceLanguage(for: .english), .english)
        XCTAssertEqual(VoiceLanguageAppEnum.voiceLanguage(for: .italian), .italian)

        XCTAssertNil(VoiceLanguageAppEnum.auto.languageHint)
        XCTAssertEqual(VoiceLanguageAppEnum.english.languageHint, "en")
        XCTAssertEqual(VoiceLanguageAppEnum.italian.languageHint, "it")

        XCTAssertNil(VoiceLanguageAppEnum.auto.voiceLanguageID)
        XCTAssertEqual(VoiceLanguageAppEnum.english.voiceLanguageID, "en")
        XCTAssertEqual(VoiceLanguageAppEnum.italian.voiceLanguageID, "it")

        // Every route language is one the deep-link parser accepts.
        for value in VoiceLanguageAppEnum.allCases {
            if let id = value.voiceLanguageID {
                XCTAssertTrue(DeepLink.voiceLanguageIDs.contains(id), id)
            }
        }
    }
}
