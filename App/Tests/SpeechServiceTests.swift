import AVFoundation
import XCTest
import VocabCore
@testable import VocabApp

/// M5.3 — `SpeechService`: висловлювання без відтворення. Наявність голосу не перевіряється (U11: на CI
/// голосів може не бути — `voice == nil` допустимо).
final class SpeechServiceTests: XCTestCase {
    @MainActor
    func testUtteranceUsesPairSpeechLanguage() {
        let pair = LanguagePair.englishUkrainian
        XCTAssertEqual(pair.speechLanguageCode, "en-US")
        let service = SpeechService()

        let utterance = service.makeUtterance(text: "run", languageCode: pair.speechLanguageCode)

        XCTAssertEqual(utterance.speechString, "run")
        if let voice = utterance.voice {
            XCTAssertEqual(SpeechService.baseLanguage(of: voice.language), "en",
                           "if a voice is found it must be English, got \(voice.language)")
        }
        XCTAssertNil(service.lastRequestedLanguageCode, "makeUtterance does not speak")
    }

    @MainActor
    func testUtteranceKeepsPhraseText() {
        let utterance = SpeechService().makeUtterance(text: "give up", languageCode: "en-US")
        XCTAssertEqual(utterance.speechString, "give up")
    }

    func testVoiceLookupIsNilSafe() {
        for code in ["en-US", "en-GB", "en", "uk-UA", "xx-ZZ"] {
            // Не падає; голос може бути nil (U11). Якщо знайдено — тієї ж базової мови.
            if let voice = SpeechService.voice(forLanguageCode: code) {
                XCTAssertEqual(SpeechService.baseLanguage(of: voice.language), SpeechService.baseLanguage(of: code),
                               "\(code) → \(voice.language)")
            }
        }
    }

    func testBaseLanguage() {
        XCTAssertEqual(SpeechService.baseLanguage(of: "en-US"), "en")
        XCTAssertEqual(SpeechService.baseLanguage(of: "en_GB"), "en")
        XCTAssertEqual(SpeechService.baseLanguage(of: "EN"), "en")
        XCTAssertEqual(SpeechService.baseLanguage(of: "uk-UA"), "uk")
    }

    @MainActor
    func testSpeakBlankTextDoesNothing() {
        let service = SpeechService()
        service.speak("   \n", languageCode: "en-US")
        XCTAssertNil(service.lastRequestedLanguageCode)
        service.stop() // не падає без активного озвучення
    }
}
