import Foundation
import XCTest
@testable import VocabCore

/// M7.5 — розбір пакетної відповіді: часткові успіхи, відсутні/невідомі/дубльовані id.
final class VariantBatchParserTests: XCTestCase {
    private let items = [
        VariantRequestItem(ref: 1, word: "run", kind: .word),
        VariantRequestItem(ref: 2, word: "dog", kind: .word),
        VariantRequestItem(ref: 3, word: "give up", kind: .phrase),
    ]

    private func element(_ id: Any, _ word: String, ipa: String = "/x/", pos: String = "noun") -> [String: Any] {
        M7.batchElement(id: id, word: word, pos: pos, ipa: ipa)
    }

    private func readyWord(_ outcome: VariantItemOutcome?) -> String? {
        if case .ready(let result) = outcome { return result.word }
        return nil
    }

    private func isInvalid(_ outcome: VariantItemOutcome?) -> Bool {
        if case .invalid = outcome { return true }
        return false
    }

    func testAllValid() throws {
        let text = M7.batchJSON([element(1, "correre"), element(2, "cane"), element(3, "arrendersi", ipa: "", pos: "verb")])
        let outcomes = try VariantBatchResponseParser.parse(text, items: items)
        XCTAssertEqual(outcomes.count, 3)
        XCTAssertEqual(readyWord(outcomes[1]), "correre")
        XCTAssertEqual(readyWord(outcomes[2]), "cane")
        guard case .ready(let phrase) = outcomes[3] else { return XCTFail("phrase not ready") }
        XCTAssertEqual(phrase.partOfSpeech, "phrase", "kind of the item forces phrase")
        XCTAssertEqual(phrase.transcription, "")
    }

    func testPartialInvalidKeepsValid() throws {
        var bad = element(2, "cane")
        bad["translations"] = []
        let noIPA = element(1, "correre", ipa: "")
        let text = M7.batchJSON([noIPA, bad, element(3, "arrendersi", ipa: "")])
        let outcomes = try VariantBatchResponseParser.parse(text, items: items)
        XCTAssertTrue(isInvalid(outcomes[1]), "word item requires transcription")
        XCTAssertTrue(isInvalid(outcomes[2]))
        XCTAssertEqual(readyWord(outcomes[3]), "arrendersi")
        if case .invalid(let reason) = outcomes[2] {
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testMissingIdsReportedMissing() throws {
        let outcomes = try VariantBatchResponseParser.parse(M7.batchJSON([element(2, "cane")]), items: items)
        XCTAssertEqual(outcomes[1], .missing)
        XCTAssertEqual(readyWord(outcomes[2]), "cane")
        XCTAssertEqual(outcomes[3], .missing)
        XCTAssertEqual(Set(outcomes.keys), [1, 2, 3], "every requested ref present")
        XCTAssertEqual(try VariantBatchResponseParser.parse("[]", items: items), [1: .missing, 2: .missing, 3: .missing])
    }

    func testUnknownIdsIgnored() throws {
        let text = M7.batchJSON([element(7, "sette"), element(0, "zero"), element(1.5, "x"), element(1, "correre")])
        let outcomes = try VariantBatchResponseParser.parse(text, items: items)
        XCTAssertEqual(Set(outcomes.keys), [1, 2, 3])
        XCTAssertEqual(readyWord(outcomes[1]), "correre")
        XCTAssertEqual(outcomes[2], .missing)
        // Елемент без id або не-об'єкт — ігнорується.
        let weird = "[1, \"x\", {\"word\": \"cane\"}, \(M7.jsonString(element(2, "cane")))]"
        let weirdOutcomes = try VariantBatchResponseParser.parse(weird, items: items)
        XCTAssertEqual(readyWord(weirdOutcomes[2]), "cane")
        XCTAssertEqual(weirdOutcomes[1], .missing)
    }

    func testDuplicateIdFirstWins() throws {
        var invalidFirst = element(2, "primo")
        invalidFirst["example"] = "x"
        let text = M7.batchJSON([element(1, "correre"), element(1, "corsa"), invalidFirst, element(2, "cane")])
        let outcomes = try VariantBatchResponseParser.parse(text, items: items)
        XCTAssertEqual(readyWord(outcomes[1]), "correre")
        XCTAssertTrue(isInvalid(outcomes[2]), "first element wins even if invalid")
    }

    func testStringNumericIdAccepted() throws {
        let text = M7.batchJSON([element("1", "correre"), element(" 2 ", "cane"), element("three", "x")])
        let outcomes = try VariantBatchResponseParser.parse(text, items: items)
        XCTAssertEqual(readyWord(outcomes[1]), "correre")
        XCTAssertEqual(readyWord(outcomes[2]), "cane")
        XCTAssertEqual(outcomes[3], .missing)
    }

    func testNotArrayInvalid() {
        for text in ["", "not json", "{\"id\": 1, \"word\": \"correre\"}", "[{\"id\": 1, ", "{\"items\": 1}", "] then ["] {
            XCTAssertThrowsError(try VariantBatchResponseParser.parse(text, items: items), text) { error in
                guard case .invalidResponse = error as? ClaudeError else {
                    return XCTFail("expected invalidResponse for \(text), got \(error)")
                }
            }
        }
    }

    func testCodeFenceStripped() throws {
        let fenced = "```json\n\(M7.batchJSON([element(1, "correre")]))\n```"
        XCTAssertEqual(readyWord(try VariantBatchResponseParser.parse(fenced, items: items)[1]), "correre")
        let chatty = "Here you go:\n\(M7.batchJSON([element(2, "cane")]))\nDone."
        XCTAssertEqual(readyWord(try VariantBatchResponseParser.parse(chatty, items: items)[2]), "cane")
    }

    func testWholeTextArrayParsed() throws {
        // Увесь текст — масив; дужки всередині рядків не заважають (першою пробою є розбір усього тексту).
        var tricky = element(1, "correre")
        tricky["example"] = ["source": "Run ] [ fast.", "translation": "Біжи ] [ швидко."]
        let text = "  " + M7.batchJSON([tricky, element(2, "cane")]) + "\n"
        let outcomes = try VariantBatchResponseParser.parse(text, items: items)
        XCTAssertEqual(readyWord(outcomes[1]), "correre")
        XCTAssertEqual(readyWord(outcomes[2]), "cane")
        XCTAssertEqual(outcomes[3], .missing)
        guard case .ready(let first) = outcomes[1] else { return XCTFail("not ready") }
        XCTAssertEqual(first.example.source, "Run ] [ fast.")
    }

    /// Поточна поведінка: обгортка `{"items":[…]}` не є масивом верхнього рівня, але запасний шлях
    /// (підрядок від першої `[` до останньої `]`) витягує внутрішній масив — елементи розбираються.
    func testItemsObjectWrapperCurrentBehaviour() throws {
        let wrapped = M7.jsonString(["items": [element(1, "correre"), element(3, "arrendersi", ipa: "", pos: "verb")]])
        let outcomes = try VariantBatchResponseParser.parse(wrapped, items: items)
        XCTAssertEqual(readyWord(outcomes[1]), "correre")
        XCTAssertEqual(outcomes[2], .missing)
        XCTAssertEqual(readyWord(outcomes[3]), "arrendersi")
    }
}
