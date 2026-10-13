import Foundation
import XCTest
@testable import VocabCore

/// M1.4 — нормалізація тексту (§4, D8).
final class TextNormalizerTests: XCTestCase {
    func testTrims() {
        XCTAssertEqual(TextNormalizer.clean("  run  "), "run")
        XCTAssertEqual(TextNormalizer.clean("Run "), "Run")
        XCTAssertEqual(TextNormalizer.clean("\t\nrun\r\n"), "run")
        XCTAssertEqual(TextNormalizer.clean("\u{00A0}run\u{00A0}"), "run", "non-breaking spaces trimmed")
        XCTAssertEqual(TextNormalizer.clean("   "), "")
        XCTAssertEqual(TextNormalizer.clean(""), "")
    }

    func testLowercasesKey() {
        XCTAssertEqual(TextNormalizer.key("Run "), "run")
        XCTAssertEqual(TextNormalizer.key("RUN"), "run")
        XCTAssertEqual(TextNormalizer.key("Give Up"), "give up")
        XCTAssertEqual(TextNormalizer.clean("Run"), "Run", "clean keeps original case")
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(TextNormalizer.clean("give   up"), "give up")
        XCTAssertEqual(TextNormalizer.clean("give\n\tup"), "give up")
        XCTAssertEqual(TextNormalizer.clean("give \r\n  up  now"), "give up now")
        XCTAssertEqual(TextNormalizer.key("Give\nUP"), TextNormalizer.key("give up"))
    }

    func testStripsSurroundingPunctuation() {
        XCTAssertEqual(TextNormalizer.clean("run."), "run")
        XCTAssertEqual(TextNormalizer.clean("\"run\","), "run")
        XCTAssertEqual(TextNormalizer.clean("«біг»"), "біг")
        XCTAssertEqual(TextNormalizer.clean("(run)!?"), "run")
        XCTAssertEqual(TextNormalizer.clean("\u{201C}run\u{201D}"), "run")
        XCTAssertEqual(TextNormalizer.clean("[{run}];:"), "run")
        XCTAssertEqual(TextNormalizer.clean("run…"), "run")
        XCTAssertEqual(TextNormalizer.clean(" ( run ) "), "run", "spaces between punctuation and word removed")
        XCTAssertEqual(TextNormalizer.clean("e.g. run"), "e.g. run", "inner punctuation kept")
        XCTAssertEqual(TextNormalizer.clean("..."), "")
    }

    func testKeepsInnerApostropheAndHyphen() {
        XCTAssertEqual(TextNormalizer.clean("don't"), "don't")
        XCTAssertEqual(TextNormalizer.clean("well-known"), "well-known")
        XCTAssertEqual(TextNormalizer.clean("  mother-in-law. "), "mother-in-law")
        XCTAssertEqual(TextNormalizer.key("Don't"), "don't")
    }

    func testNormalizesCurlyApostrophe() {
        XCTAssertEqual(TextNormalizer.clean("don\u{2019}t"), "don't")
        XCTAssertEqual(TextNormalizer.clean("don\u{2018}t"), "don't")
        XCTAssertEqual(TextNormalizer.clean("don\u{02BC}t"), "don't")
        XCTAssertEqual(TextNormalizer.key("Don\u{2019}t"), TextNormalizer.key("don't"))
    }

    func testKeyIsIdempotent() {
        for raw in ["  Run. ", "Give\n  Up", "«Don\u{2019}t»", "well-known"] {
            let key = TextNormalizer.key(raw)
            XCTAssertEqual(TextNormalizer.key(key), key, "key must be idempotent for \(raw)")
        }
    }
}
