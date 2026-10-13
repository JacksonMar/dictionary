import Foundation
import XCTest
@testable import VocabCore

/// M2.3 — розбір і валідація відповіді Claude.
final class LookupResponseParserTests: XCTestCase {
    private func parseEnvelope(_ text: String, stopReason: String = "end_turn", kind: SelectionKind = .word) throws -> LookupResult {
        try LookupResponseParser.parseMessagesResponse(
            ClaudeFixtures.messagesResponse(text: text, stopReason: stopReason),
            kind: kind
        )
    }

    /// Валідний JSON слова з заміною/видаленням одного поля.
    private func wordJSON(replacing key: String, with value: Any?) throws -> String {
        var object = try jsonObject(Data(ClaudeFixtures.validWordJSON.utf8))
        object[key] = value
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func assertInvalid(
        _ text: String,
        kind: SelectionKind = .word,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try LookupResponseParser.parse(text, kind: kind), file: file, line: line) { error in
            guard case ClaudeError.invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)", file: file, line: line)
            }
        }
    }

    func testParsesValid() throws {
        XCTAssertEqual(try parseEnvelope(ClaudeFixtures.validWordJSON), ClaudeFixtures.expectedRunResult)
    }

    func testParsesInsideCodeFence() throws {
        let fenced = "```json\n\(ClaudeFixtures.validWordJSON)\n```"
        XCTAssertEqual(try parseEnvelope(fenced), ClaudeFixtures.expectedRunResult)

        let bareFence = "```\n\(ClaudeFixtures.validWordJSON)\n```"
        XCTAssertEqual(try parseEnvelope(bareFence), ClaudeFixtures.expectedRunResult)
    }

    func testParsesWithSurroundingProse() throws {
        let text = "Here you go:\n\(ClaudeFixtures.validWordJSON)\nHope it helps!"
        XCTAssertEqual(try LookupResponseParser.parse(text, kind: .word), ClaudeFixtures.expectedRunResult)
    }

    func testIgnoresThinkingBlocks() throws {
        let data = ClaudeFixtures.messagesResponse(blocks: [
            ["type": "thinking", "thinking": "{\"word\": \"not this\"}", "signature": "abc"],
            ["type": "text", "text": ClaudeFixtures.validWordJSON],
        ])

        XCTAssertEqual(try LookupResponseParser.extractText(fromMessagesResponse: data), ClaudeFixtures.validWordJSON)
        XCTAssertEqual(try LookupResponseParser.parseMessagesResponse(data, kind: .word), ClaudeFixtures.expectedRunResult)
    }

    func testConcatenatesMultipleTextBlocks() throws {
        let json = ClaudeFixtures.validWordJSON
        let middle = json.index(json.startIndex, offsetBy: json.count / 2)
        let data = ClaudeFixtures.messagesResponse(blocks: [
            ["type": "text", "text": String(json[..<middle])],
            ["type": "text", "text": String(json[middle...])],
        ])
        XCTAssertEqual(try LookupResponseParser.parseMessagesResponse(data, kind: .word), ClaudeFixtures.expectedRunResult)
    }

    func testMissingTranslationsInvalid() throws {
        assertInvalid(try wordJSON(replacing: "translations", with: nil))
    }

    func testEmptyTranslationsInvalid() throws {
        assertInvalid(try wordJSON(replacing: "translations", with: [String]()))
        assertInvalid(try wordJSON(replacing: "translations", with: ["  ", ""]))
    }

    func testTranslationsWrongTypeInvalid() throws {
        assertInvalid(try wordJSON(replacing: "translations", with: "бігти"))
        assertInvalid(try wordJSON(replacing: "translations", with: ["бігти", 42]))
    }

    func testTranslationsTrimmedDeduplicatedAndLimited() throws {
        let result = try LookupResponseParser.parse(
            try wordJSON(replacing: "translations", with: [" бігти ", "бігти", "", "керувати"]),
            kind: .word
        )
        XCTAssertEqual(result.translations, ["бігти", "керувати"])

        let ten = (1...10).map { "переклад\($0)" }
        XCTAssertEqual(try LookupResponseParser.parse(try wordJSON(replacing: "translations", with: ten), kind: .word)
            .translations.count, 10)
        assertInvalid(try wordJSON(replacing: "translations", with: ten + ["переклад11"]))
    }

    func testNonJSONInvalid() throws {
        assertInvalid("Sorry, I cannot help with that.")
        assertInvalid("{not json}")
        assertInvalid("")
        assertInvalid("[\"run\"]")
        XCTAssertThrowsError(try LookupResponseParser.extractText(fromMessagesResponse: Data("<html>".utf8))) { error in
            guard case ClaudeError.invalidResponse = error else { return XCTFail("got \(error)") }
        }
    }

    func testMissingExampleInvalid() throws {
        assertInvalid(try wordJSON(replacing: "example", with: nil))
        assertInvalid(try wordJSON(replacing: "example", with: "She runs."))
        assertInvalid(try wordJSON(replacing: "example", with: ["source": "She runs."]))
        assertInvalid(try wordJSON(replacing: "example", with: ["source": " ", "translation": "Вона біжить."]))
    }

    func testMissingOrWrongTypeRequiredFieldsInvalid() throws {
        assertInvalid(try wordJSON(replacing: "word", with: nil))
        assertInvalid(try wordJSON(replacing: "word", with: 1))
        assertInvalid(try wordJSON(replacing: "word", with: "   "))
        assertInvalid(try wordJSON(replacing: "part_of_speech", with: nil))
        assertInvalid(try wordJSON(replacing: "part_of_speech", with: ["verb"]))
        assertInvalid(try wordJSON(replacing: "lemma", with: 5))
        assertInvalid(try wordJSON(replacing: "transcription", with: true))
    }

    func testWordRequiresTranscription() throws {
        assertInvalid(try wordJSON(replacing: "transcription", with: ""))
        assertInvalid(try wordJSON(replacing: "transcription", with: nil))
    }

    func testEmptyLemmaFallsBackToWord() throws {
        XCTAssertEqual(try LookupResponseParser.parse(try wordJSON(replacing: "lemma", with: " "), kind: .word).lemma, "run")
        XCTAssertEqual(try LookupResponseParser.parse(try wordJSON(replacing: "lemma", with: nil), kind: .word).lemma, "run")
    }

    func testPhraseForcesPhrasePOS() throws {
        let result = try parseEnvelope(ClaudeFixtures.validPhraseJSON, kind: .phrase)

        XCTAssertEqual(result.partOfSpeech, "phrase")
        XCTAssertEqual(result.word, "give up")
        XCTAssertEqual(result.transcription, "", "phrase may have an empty transcription")
        XCTAssertEqual(result.translations, ["здаватися", "кидати"])
    }

    func testExtraKeysIgnored() throws {
        let text = try wordJSON(replacing: "frequency", with: "high")
        XCTAssertEqual(try LookupResponseParser.parse(text, kind: .word), ClaudeFixtures.expectedRunResult)
    }

    func testMaxTokensStopReasonWithTruncatedJSONInvalid() {
        let truncated = String(ClaudeFixtures.validWordJSON.prefix(60))

        XCTAssertThrowsError(try parseEnvelope(truncated, stopReason: "max_tokens")) { error in
            XCTAssertEqual(error as? ClaudeError, .invalidResponse("max_tokens"))
        }
    }

    func testMaxTokensStopReasonWithCompleteJSONAccepted() throws {
        XCTAssertEqual(try parseEnvelope(ClaudeFixtures.validWordJSON, stopReason: "max_tokens"),
                       ClaudeFixtures.expectedRunResult)
    }

    func testRefusalStopReason() {
        XCTAssertThrowsError(try parseEnvelope("", stopReason: "refusal")) { error in
            XCTAssertEqual(error as? ClaudeError, .refused)
        }
        // Навіть якщо є текст — refusal має пріоритет.
        XCTAssertThrowsError(try parseEnvelope(ClaudeFixtures.validWordJSON, stopReason: "refusal")) { error in
            XCTAssertEqual(error as? ClaudeError, .refused)
        }
    }
}
