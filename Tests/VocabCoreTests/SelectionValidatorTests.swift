import Foundation
import XCTest
@testable import VocabCore

/// M3.1 — валідація виділення (§4, D3): порожньо, забагато тексту, без літер, слово/фраза, очищення.
final class SelectionValidatorTests: XCTestCase {
    private func valid(
        _ raw: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CleanedSelection? {
        switch SelectionValidator.validate(raw) {
        case .valid(let selection):
            return selection
        case .rejected(let rejection):
            XCTFail("expected valid for \(String(describing: raw)), got \(rejection)", file: file, line: line)
            return nil
        }
    }

    func testEmptyRejected() {
        XCTAssertEqual(SelectionValidator.validate(nil), .rejected(.empty))
        XCTAssertEqual(SelectionValidator.validate(""), .rejected(.empty))
        // Лише крайня пунктуація → після `clean` порожньо.
        XCTAssertEqual(SelectionValidator.validate("…"), .rejected(.empty))
        XCTAssertEqual(SelectionValidator.validate("«»()"), .rejected(.empty))
        XCTAssertEqual(SelectionValidator.validate(" . , ! ? "), .rejected(.empty))
    }

    func testWhitespaceOnlyRejected() {
        XCTAssertEqual(SelectionValidator.validate(" "), .rejected(.empty))
        XCTAssertEqual(SelectionValidator.validate("   \t  "), .rejected(.empty))
        XCTAssertEqual(SelectionValidator.validate("\n\r\n"), .rejected(.empty))
        XCTAssertEqual(SelectionValidator.validate("\u{00A0}\u{2003}"), .rejected(.empty), "NBSP / em space")
    }

    func testTooLongRejected() {
        XCTAssertEqual(SelectionValidator.maxLength, 120)
        XCTAssertEqual(SelectionValidator.validate(String(repeating: "a", count: 121)), .rejected(.tooLong(max: 120)))
        // Кілька слів, але понад 120 символів: довжина перевіряється першою.
        let longPhrase = Array(repeating: String(repeating: "b", count: 30), count: 5).joined(separator: " ")
        XCTAssertEqual(longPhrase.count, 154)
        XCTAssertEqual(SelectionValidator.validate(longPhrase), .rejected(.tooLong(max: 120)))

        // Рівно 120 — ще дозволено.
        let exactly = String(repeating: "a", count: 120)
        XCTAssertEqual(valid(exactly)?.text, exactly)
        // Довжина рахується ПІСЛЯ очищення: пробіли й крайня пунктуація не враховуються.
        XCTAssertEqual(valid("   \(exactly).  \n")?.text, exactly)
        // Згортання пробілів теж до перевірки довжини: 60 + 60 літер, розділені багатьма пробілами.
        let spaced = String(repeating: "c", count: 59) + String(repeating: " ", count: 40) + String(repeating: "d", count: 60)
        XCTAssertEqual(valid(spaced)?.text.count, 120)
    }

    func testTooManyWordsRejected() {
        XCTAssertEqual(SelectionValidator.maxWords, 8)
        XCTAssertEqual(SelectionValidator.validate("a b c d e f g h i"), .rejected(.tooManyWords(max: 8)))
        XCTAssertEqual(
            SelectionValidator.validate("one two three four five six seven eight nine ten"),
            .rejected(.tooManyWords(max: 8))
        )
        // 8 слів — ще фраза; переноси/кілька пробілів не створюють «порожніх» слів.
        let eight = valid("one  two\nthree\tfour five six seven eight")
        XCTAssertEqual(eight?.kind, .phrase)
        XCTAssertEqual(eight?.text, "one two three four five six seven eight")
    }

    func testNoLettersRejected() {
        XCTAssertEqual(SelectionValidator.validate("1234"), .rejected(.noLetters))
        XCTAssertEqual(SelectionValidator.validate("42 17"), .rejected(.noLetters))
        XCTAssertEqual(SelectionValidator.validate("$%"), .rejected(.noLetters))
        XCTAssertEqual(SelectionValidator.validate("— – -"), .rejected(.noLetters))
        XCTAssertEqual(SelectionValidator.validate("3.14"), .rejected(.noLetters))
        XCTAssertEqual(SelectionValidator.validate("🙂"), .rejected(.noLetters))
        // Хоч одна літера — валідно (у т.ч. кирилиця, цифри з літерами).
        XCTAssertEqual(valid("mp3")?.text, "mp3")
        XCTAssertEqual(valid("бігти")?.text, "бігти")
        XCTAssertEqual(valid("Ärger")?.kind, .word)
    }

    func testSingleWordIsWord() {
        let selection = valid("run")
        XCTAssertEqual(selection, CleanedSelection(text: "run", key: "run", kind: .word))
        // Регістр тексту зберігається, ключ — у нижньому регістрі.
        XCTAssertEqual(valid("Run"), CleanedSelection(text: "Run", key: "run", kind: .word))
        XCTAssertEqual(valid("don't")?.kind, .word)
    }

    func testHyphenatedIsWord() {
        XCTAssertEqual(valid("well-known"), CleanedSelection(text: "well-known", key: "well-known", kind: .word))
        XCTAssertEqual(valid("Mother-in-law")?.kind, .word)
        XCTAssertEqual(valid("Mother-in-law")?.key, "mother-in-law")
        XCTAssertEqual(valid("(state-of-the-art)")?.text, "state-of-the-art")
    }

    func testMultiWordIsPhrase() {
        XCTAssertEqual(valid("give up"), CleanedSelection(text: "give up", key: "give up", kind: .phrase))
        XCTAssertEqual(valid("Look Forward To"), CleanedSelection(text: "Look Forward To", key: "look forward to",
                                                                  kind: .phrase))
        XCTAssertEqual(valid("break the ice")?.kind, .phrase)
    }

    func testMultilineCollapsed() {
        XCTAssertEqual(valid("give\nup"), CleanedSelection(text: "give up", key: "give up", kind: .phrase))
        XCTAssertEqual(valid("  give \r\n\t  up \n")?.text, "give up")
        XCTAssertEqual(valid("\nrun\n")?.kind, .word, "surrounding newlines do not make a phrase")
        XCTAssertEqual(valid("\u{00A0}run\u{00A0}"), CleanedSelection(text: "run", key: "run", kind: .word))
    }

    func testTrailingPunctuationStripped() {
        XCTAssertEqual(valid("run.")?.text, "run")
        XCTAssertEqual(valid("run,")?.text, "run")
        XCTAssertEqual(valid("run!?")?.text, "run")
        XCTAssertEqual(valid("“run,”")?.text, "run")
        XCTAssertEqual(valid("«run»")?.text, "run")
        XCTAssertEqual(valid("(give up)…")?.text, "give up")
        XCTAssertEqual(valid("\"Run\";"), CleanedSelection(text: "Run", key: "run", kind: .word))
    }

    func testCurlyApostropheNormalized() {
        XCTAssertEqual(valid("don’t"), CleanedSelection(text: "don't", key: "don't", kind: .word))
        XCTAssertEqual(valid("Don‘t")?.key, "don't")
        XCTAssertEqual(valid("rock ʼnʼ roll")?.text, "rock 'n' roll")
    }

    func testKeyMatchesTextNormalizerKey() {
        for raw in ["Run", "  Give\nUP ", "Don’t.", "«Well-Known»", "Ärger"] {
            XCTAssertEqual(valid(raw)?.key, TextNormalizer.key(raw), raw)
            XCTAssertEqual(valid(raw)?.text, TextNormalizer.clean(raw), raw)
        }
    }

    func testKindOfCleanedText() {
        XCTAssertEqual(SelectionValidator.kind(of: "run"), .word)
        XCTAssertEqual(SelectionValidator.kind(of: "well-known"), .word)
        XCTAssertEqual(SelectionValidator.kind(of: "give up"), .phrase)
    }
}
