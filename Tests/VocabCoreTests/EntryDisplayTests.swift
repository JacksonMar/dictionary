import Foundation
import XCTest
@testable import VocabCore

/// M7.7 — що показується в рядку для активної мови (`EntryDisplay`, чиста логіка).
final class EntryDisplayTests: XCTestCase {
    private let run = M7.entry(word: "run", translations: ["бігти"],
                               variants: ["it": M7.readyVariant("correre", sourceWord: "run", translations: ["бігати"])])

    func testPrimaryModeShowsEnglish() {
        let display = EntryDisplay.make(run, languageID: nil)
        XCTAssertEqual(display.word, "run")
        XCTAssertEqual(display.lemma, "run")
        XCTAssertEqual(display.partOfSpeech, "noun")
        XCTAssertEqual(display.transcription, "/run/")
        XCTAssertEqual(display.translations, ["бігти"])
        XCTAssertEqual(display.example, run.example)
        XCTAssertFalse(display.isFallback)
        XCTAssertNil(display.state)
        XCTAssertNil(display.languageID)
        XCTAssertEqual(display.id, run.id)
        XCTAssertEqual(display.entry, run)
    }

    func testItalianModeShowsVariant() {
        let display = EntryDisplay.make(run, languageID: "it")
        XCTAssertEqual(display.word, "correre")
        XCTAssertEqual(display.lemma, "correre")
        XCTAssertEqual(display.transcription, "/correre/")
        XCTAssertEqual(display.translations, ["бігати"])
        XCTAssertEqual(display.example, Example(source: "Vedo correre.", translation: "Я бачу correre."))
        XCTAssertFalse(display.isFallback)
        XCTAssertEqual(display.state, .ready)
        XCTAssertEqual(display.languageID, "it")

        // Італійське виділення: показується слово користувача.
        let house = M7.entry(word: "house", variants: ["it": M7.readyVariant("casa", sourceWord: "house")],
                             sourceLanguage: "it")
        XCTAssertEqual(EntryDisplay.make(house, languageID: "it").word, "casa")
        XCTAssertEqual(EntryDisplay.make(house, languageID: nil).word, "house")
    }

    func testMissingVariantFallback() {
        let plain = M7.entry(word: "dog", translations: ["собака"])
        let display = EntryDisplay.make(plain, languageID: "it")
        XCTAssertTrue(display.isFallback)
        XCTAssertEqual(display.state, .missing)
        XCTAssertEqual(display.word, "dog")
        XCTAssertNil(display.lemma)
        XCTAssertNil(display.partOfSpeech)
        XCTAssertNil(display.transcription)
        XCTAssertEqual(display.translations, [])
        XCTAssertNil(display.example)

        for status in [EntryStatus.pending, .failed] {
            let entry = M7.entry(word: "dog", variants: ["it": M7.unfilledVariant(status, sourceWord: "dog")])
            let shown = EntryDisplay.make(entry, languageID: "it")
            XCTAssertTrue(shown.isFallback)
            XCTAssertEqual(shown.state, status == .pending ? .pending : .failed)
            XCTAssertEqual(shown.word, "dog")
            XCTAssertEqual(shown.translations, [])
        }
        // Англійський pending-запис без варіанта.
        let pending = M7.entry(word: "naïve", status: .pending)
        XCTAssertEqual(EntryDisplay.make(pending, languageID: "it").word, "naïve")
        XCTAssertTrue(EntryDisplay.make(pending, languageID: "it").isFallback)
    }

    func testStaleVariantFallback() {
        let stale = M7.entry(word: "sprint", translations: ["спринт"],
                             variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        let display = EntryDisplay.make(stale, languageID: "it")
        XCTAssertTrue(display.isFallback)
        XCTAssertEqual(display.state, .stale)
        XCTAssertEqual(display.word, "sprint")
        XCTAssertNil(display.transcription)
        XCTAssertEqual(display.translations, [])
    }
}
