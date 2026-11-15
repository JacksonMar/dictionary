// I1a sanity checks of the minimal deep-link parser and `Router`. Full `DeepLinkTests` come with I4.
import XCTest
@testable import VocabMobile

final class RouterTests: XCTestCase {
    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string), string)
    }

    func testVoiceLinkParsesLanguage() throws {
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice")), .voiceCapture(languageID: nil))
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice?lang=it")), .voiceCapture(languageID: "it"))
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice?lang=EN")), .voiceCapture(languageID: "en"))
        XCTAssertEqual(DeepLink.parse(try url("VOCABAPP://Voice?lang=It")), .voiceCapture(languageID: "it"))
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice?lang=de")), .voiceCapture(languageID: nil),
                       "unsupported voice language falls back to the last used one")
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://voice?lang=")), .voiceCapture(languageID: nil))
    }

    func testAddAndUnknownLinks() throws {
        XCTAssertEqual(DeepLink.parse(try url("vocabapp://add")), .addSheet)
        XCTAssertNil(DeepLink.parse(try url("vocabapp://settings")))
        XCTAssertNil(DeepLink.parse(try url("vocabapp:voice")), "no host")
        XCTAssertNil(DeepLink.parse(try url("https://voice/?lang=it")), "foreign scheme")
        XCTAssertNil(DeepLink.parse(try url("otherapp://voice")))
    }

    @MainActor
    func testRouterOpensRecognizedLinksAndIgnoresOthers() async throws {
        let router = Router()
        XCTAssertEqual(router.route, .list)

        XCTAssertFalse(router.open(url: try url("https://example.com")))
        XCTAssertEqual(router.route, .list, "unknown URL leaves the route unchanged")

        XCTAssertTrue(router.open(url: try url("vocabapp://voice?lang=it")))
        XCTAssertEqual(router.route, .voiceCapture(languageID: "it"))

        XCTAssertFalse(router.open(url: try url("vocabapp://unknown")))
        XCTAssertEqual(router.route, .voiceCapture(languageID: "it"))

        router.dismiss()
        XCTAssertEqual(router.route, .list)

        router.open(.addSheet)
        XCTAssertEqual(router.route, .addSheet)
    }
}
