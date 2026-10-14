import Foundation
import XCTest
@testable import VocabCore

/// M7.2 — розбір комбінованої відповіді з детекцією мови (§7.7).
final class CombinedLookupParserTests: XCTestCase {
    private let pair = LanguagePair.englishUkrainian

    private func parse(_ text: String, kind: SelectionKind = .word, selection: String) throws -> LookupResult {
        try LookupResponseParser.parse(text, kind: kind, pair: pair, selectionKey: TextNormalizer.key(selection))
    }

    func testEnglishSourceWithItalianVariant() throws {
        let result = try parse(M7.houseEnglishJSON, selection: "house")
        XCTAssertEqual(result.sourceLanguage, "en")
        XCTAssertEqual(result.word, "house")
        XCTAssertEqual(result.translations, ["будинок", "дім"])
        XCTAssertEqual(Array(result.variants.keys), ["it"])
        let italian = try XCTUnwrap(result.variants["it"])
        XCTAssertEqual(italian.word, "casa")
        XCTAssertEqual(italian.transcription, "/ˈkaːza/")
        XCTAssertEqual(italian.translations, ["дім", "будинок", "оселя"])
        XCTAssertEqual(italian.example, Example(source: "La casa è grande.", translation: "Будинок великий."))
        XCTAssertNil(italian.sourceLanguage, "nested results carry no source language")
        XCTAssertTrue(italian.variants.isEmpty)
    }

    func testItalianSourceDetected() throws {
        let result = try parse(M7.casaItalianJSON, selection: "casa")
        XCTAssertEqual(result.sourceLanguage, "it")
        XCTAssertEqual(result.word, "house", "top level is always the English rendering")
        XCTAssertEqual(result.variants["it"]?.word, "casa")

        // Регістр/пробіли source_language нормалізуються.
        let upper = M7.casaItalianJSON.replacingOccurrences(of: "\"source_language\":\"it\"",
                                                            with: "\"source_language\":\" IT \"")
        XCTAssertNotEqual(upper, M7.casaItalianJSON)
        XCTAssertEqual(try parse(upper, selection: "casa").sourceLanguage, "it")
    }

    func testMissingSourceLanguageInferredFromKeys() throws {
        let noSource = M7.combinedJSON(
            sourceLanguage: nil,
            top: M7.object(word: "house"),
            variants: ["it": M7.object(word: "casa")]
        )
        XCTAssertEqual(try parse(noSource, selection: "Casa").sourceLanguage, "it")
        XCTAssertEqual(try parse(noSource, selection: "house").sourceLanguage, "en")
        // Виділення не збігається ні з чим → мова пари.
        XCTAssertEqual(try parse(noSource, selection: "home").sourceLanguage, "en")
        // Однакове написання в обох мовах → en (верхній рівень має пріоритет).
        let same = M7.combinedJSON(sourceLanguage: nil, top: M7.object(word: "come"),
                                   variants: ["it": M7.object(word: "come")])
        XCTAssertEqual(try parse(same, selection: "come").sourceLanguage, "en")
    }

    func testUnknownSourceLanguageFallsBackToPrimary() throws {
        let french = M7.combinedJSON(sourceLanguage: "fr", top: M7.object(word: "house"),
                                     variants: ["it": M7.object(word: "casa")])
        XCTAssertEqual(try parse(french, selection: "maison").sourceLanguage, "en")
        // Невідомий код, але виділення збігається з італійським варіантом → виводиться it.
        XCTAssertEqual(try parse(french, selection: "casa").sourceLanguage, "it")
        // Не рядок.
        var object = M7.object(word: "house")
        object["source_language"] = 5
        object["variants"] = ["it": M7.object(word: "casa")]
        XCTAssertEqual(try parse(M7.jsonString(object), selection: "house").sourceLanguage, "en")
    }

    func testInvalidVariantDroppedWhenSourceIsEnglish() throws {
        var invalid = M7.object(word: "casa")
        invalid["translations"] = []
        let text = M7.combinedJSON(sourceLanguage: "en", top: M7.object(word: "house"), variants: ["it": invalid])
        let result = try parse(text, selection: "house")
        XCTAssertEqual(result.word, "house")
        XCTAssertEqual(result.sourceLanguage, "en")
        XCTAssertTrue(result.variants.isEmpty)

        // Варіант без транскрипції для слова (kind .word) теж невалідний; відсутній variants — теж не помилка.
        let noIPA = M7.combinedJSON(sourceLanguage: "en", top: M7.object(word: "house"),
                                    variants: ["it": M7.object(word: "casa", ipa: "")])
        XCTAssertTrue(try parse(noIPA, selection: "house").variants.isEmpty)
        let noVariants = M7.combinedJSON(sourceLanguage: "en", top: M7.object(word: "house"))
        XCTAssertTrue(try parse(noVariants, selection: "house").variants.isEmpty)
    }

    func testInvalidVariantInvalidatesResponseWhenSourceIsItalian() {
        var invalid = M7.object(word: "casa")
        invalid.removeValue(forKey: "example")
        let text = M7.combinedJSON(sourceLanguage: "it", top: M7.object(word: "house"), variants: ["it": invalid])
        XCTAssertThrowsError(try parse(text, selection: "casa")) { error in
            guard case .invalidResponse = error as? ClaudeError else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
        let missing = M7.combinedJSON(sourceLanguage: "it", top: M7.object(word: "house"))
        XCTAssertThrowsError(try parse(missing, selection: "casa"))
    }

    func testInvalidTopLevelStillInvalidatesResponse() {
        var top = M7.object(word: "house")
        top["translations"] = "будинок"
        let text = M7.combinedJSON(sourceLanguage: "en", top: top, variants: ["it": M7.object(word: "casa")])
        XCTAssertThrowsError(try parse(text, selection: "house"))
    }

    func testPhraseForcesPhraseInVariant() throws {
        let text = M7.combinedJSON(
            sourceLanguage: "en",
            top: M7.object(word: "give up", pos: "verb", ipa: ""),
            variants: ["it": M7.object(word: "arrendersi", pos: "verb", ipa: "")]
        )
        let result = try parse(text, kind: .phrase, selection: "give up")
        XCTAssertEqual(result.partOfSpeech, "phrase")
        XCTAssertEqual(result.variants["it"]?.partOfSpeech, "phrase")
        XCTAssertEqual(result.variants["it"]?.transcription, "", "phrase may have empty transcription")
    }

    func testUnknownVariantIdsIgnored() throws {
        let text = M7.combinedJSON(
            sourceLanguage: "en",
            top: M7.object(word: "house"),
            variants: ["it": M7.object(word: "casa"), "de": M7.object(word: "Haus"), "fr": "maison"]
        )
        let result = try parse(text, selection: "house")
        XCTAssertEqual(Set(result.variants.keys), ["it"])
        // source_language = невідомий для пари id з variants → не береться.
        let deSource = M7.combinedJSON(sourceLanguage: "de", top: M7.object(word: "house"),
                                       variants: ["de": M7.object(word: "Haus")])
        let parsed = try parse(deSource, selection: "Haus")
        XCTAssertEqual(parsed.sourceLanguage, "en")
        XCTAssertTrue(parsed.variants.isEmpty)
    }

    func testOldShapeStillParses() throws {
        // Відповідь у формі M2 (без source_language і variants) для пари з renderings.
        let result = try parse(ClaudeFixtures.validWordJSON, selection: "run")
        XCTAssertEqual(result.word, "run")
        XCTAssertEqual(result.sourceLanguage, "en")
        XCTAssertTrue(result.variants.isEmpty)

        // Пара без renderings: як M2, без детекції.
        let m2 = try LookupResponseParser.parse(
            M7.houseEnglishJSON, kind: .word, pair: .englishUkrainianSourceOnly, selectionKey: "house"
        )
        XCTAssertNil(m2.sourceLanguage)
        XCTAssertTrue(m2.variants.isEmpty)
        XCTAssertEqual(try LookupResponseParser.parse(ClaudeFixtures.validWordJSON, kind: .word),
                       ClaudeFixtures.expectedRunResult)
    }

    func testCodeFenceAndEnvelope() throws {
        let fenced = "```json\n\(M7.casaItalianJSON)\n```"
        let data = ClaudeFixtures.messagesResponse(text: fenced)
        let result = try LookupResponseParser.parseMessagesResponse(data, kind: .word, pair: pair, selectionKey: "casa")
        XCTAssertEqual(result.sourceLanguage, "it")
        // Обрізана відповідь → max_tokens.
        let truncated = ClaudeFixtures.messagesResponse(text: "{\"word\": \"ho", stopReason: "max_tokens")
        XCTAssertThrowsError(
            try LookupResponseParser.parseMessagesResponse(truncated, kind: .word, pair: pair, selectionKey: "house")
        ) { error in
            XCTAssertEqual(error as? ClaudeError, .invalidResponse(LookupResponseParser.maxTokensReason))
        }
    }
}
