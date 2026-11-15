// I4.2 (IOS_PLAN §4, §7 I4): `vocabapp://` deep links used by the voice widget (`widgetURL(vocabapp://voice)`) and
// manual links. `vocabapp://voice[?lang=en|it]` → voice capture; `vocabapp://add` → add sheet; anything else is
// ignored (nil, route unchanged).
import Foundation
import XCTest
@testable import VocabMobile

final class DeepLinkTests: XCTestCase {
    private func url(_ string: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        try XCTUnwrap(URL(string: string), string, file: file, line: line)
    }

    func testVoiceURL() throws {
        XCTAssertEqual(DeepLink.scheme, "vocabapp")
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice")), .voiceCapture(languageID: nil))
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice/")), .voiceCapture(languageID: nil), "path ignored")
        XCTAssertEqual(DeepLink.parse(try url("VocabApp://VOICE")), .voiceCapture(languageID: nil), "case-insensitive")
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice?source=widget")), .voiceCapture(languageID: nil),
                       "extra parameters ignored")
    }

    func testVoiceURLWithLanguage() throws {
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice?lang=it")), .voiceCapture(languageID: "it"))
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice?lang=en")), .voiceCapture(languageID: "en"))
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice?lang=IT")), .voiceCapture(languageID: "it"))
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice?x=1&lang=en&y=2")), .voiceCapture(languageID: "en"))
    }

    func testBadLanguageFallsBackToLastUsed() throws {
        for link in ["vocabapp://voice?lang=de", "vocabapp://voice?lang=", "vocabapp://voice?lang",
                     "vocabapp://voice?lang=italian", "vocabapp://voice?language=it"] {
            XCTAssertEqual(DeepLink.parse(try url(link)), .voiceCapture(languageID: nil), link)
        }
    }

    func testAddURL() throws {
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://add")), .addSheet)
        XCTAssertEqual(DeepLink.parse(try url("VOCABAPP://Add?word=house")), .addSheet)
    }

    func testUnknownURLIgnored() throws {
        for link in ["vocabapp://settings", "vocabapp://", "vocabapp:voice", "vocabapp://unknown?lang=it",
                     "vocabapp://voicex"] {
            XCTAssertNil(DeepLink.parse(try url(link)), link)
        }
    }

    func testOtherSchemeIgnored() throws {
        for link in ["https://voice?lang=it", "http://vocabapp/voice", "otherapp://voice", "file:///voice",
                     "vocabapps://voice"] {
            XCTAssertNil(DeepLink.parse(try url(link)), link)
        }
    }

    @MainActor
    func testRouterIgnoresUnknownURLAndKeepsRoute() async throws {
        let router = Router()
        router.open(.settings)
        XCTAssertFalse(router.open(url: try url("otherapp://voice")))
        XCTAssertFalse(router.open(url: try url("vocabapp://nope")))
        XCTAssertEqual(router.route, .settings, "ignored links do not change the route")

        XCTAssertTrue(router.open(url: try url("vocabapp://voice?lang=it")))
        XCTAssertEqual(router.takeVoiceCapture(), VoiceCaptureLaunch(languageID: "it"))
        XCTAssertTrue(router.open(url: try url("vocabapp://add")))
        XCTAssertEqual(router.route, .addSheet)
        XCTAssertNil(router.takeVoiceCapture(), "add link does not start listening")
    }
}
