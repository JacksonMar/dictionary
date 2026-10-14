import Foundation
import XCTest
@testable import VocabCore

/// M7.2 — комбінований промт (§7.7). Промт-тести M2 лишаються в `ClaudeRequestBuilderTests.swift`
/// (`final class PromptBuilderTests`), тому клас тут називається інакше.
final class CombinedPromptBuilderTests: XCTestCase {
    func testPairWithoutRenderingsPromptUnchanged() {
        let pair = LanguagePair.englishUkrainianSourceOnly
        let word = PromptBuilder.build(text: "run", kind: .word, pair: pair)
        XCTAssertEqual(word.system, pair.prompt.system)
        XCTAssertEqual(word.user, pair.prompt.userWord.replacingOccurrences(of: "{{TEXT}}", with: "run"))
        XCTAssertTrue(word.system.contains("exactly this shape"))
        XCTAssertFalse(word.system.contains("source_language"))
        XCTAssertFalse(word.system.contains("variants"))
        XCTAssertTrue(word.user.contains("Translate this English word"))

        let phrase = PromptBuilder.build(text: "give up", kind: .phrase, pair: pair)
        XCTAssertEqual(phrase.user, pair.prompt.userPhrase.replacingOccurrences(of: "{{TEXT}}", with: "give up"))

        // Шаблони пари не змінилися відносно M2: та сама пара з `.englishUkrainian` без renderings.
        XCTAssertEqual(LanguagePair.englishUkrainian.prompt, pair.prompt)
    }

    func testCombinedPromptContainsItalianSchemaAndDetection() {
        let pair = LanguagePair.englishUkrainian
        XCTAssertEqual(pair.renderings, [.italian])
        XCTAssertEqual(pair.sourceLanguageCode, "en")
        XCTAssertEqual(pair.sourceShortTitle, "EN")
        XCTAssertEqual(pair.allowedSourceLanguages, ["en", "it"])

        let prompt = PromptBuilder.build(text: "casa", kind: .word, pair: pair)
        // Детекція мови й варіанти.
        XCTAssertTrue(prompt.system.contains("\"source_language\""))
        XCTAssertTrue(prompt.system.contains("\"en\", \"it\""))
        XCTAssertTrue(prompt.system.contains("\"variants\""))
        XCTAssertTrue(prompt.system.contains("\"it\" (Italian)"))
        XCTAssertTrue(prompt.system.contains("use \"en\""), "ambiguous word → en (D25)")
        // Італійська інструкція повністю.
        XCTAssertTrue(prompt.system.contains(RenderingLanguage.italian.prompt.combinedInstruction))
        XCTAssertTrue(prompt.system.contains("Italian IPA"))
        // Схема M2 розширена, а не заборонена.
        XCTAssertTrue(prompt.system.contains(PromptBuilder.extendedShapePhrase))
        XCTAssertFalse(prompt.system.contains("exactly this shape"))
        XCTAssertTrue(prompt.system.contains("For the word or phrase"))
        XCTAssertFalse(prompt.system.contains("For the English word or phrase"))
        // Мовно-нейтральне user-повідомлення, виділення лише в <text>.
        XCTAssertTrue(prompt.user.contains("Translate this word into Ukrainian"))
        XCTAssertFalse(prompt.user.contains("English"))
        XCTAssertTrue(prompt.user.hasSuffix("<text>casa</text>"))
        XCTAssertFalse(prompt.system.contains("casa</text>"))

        let phrase = PromptBuilder.build(text: "l'acqua fresca", kind: .phrase, pair: pair)
        XCTAssertTrue(phrase.user.contains("Translate this phrase into Ukrainian"))
        XCTAssertTrue(phrase.user.contains("\"part_of_speech\" must be \"phrase\""))
        XCTAssertFalse(phrase.user.contains("English"))
        XCTAssertEqual(phrase.system, prompt.system, "system prompt does not depend on the selection")
    }

    func testCombinedPromptWithoutUnfilledPlaceholders() {
        for kind in [SelectionKind.word, .phrase] {
            let prompt = PromptBuilder.build(text: "perché", kind: kind, pair: .englishUkrainian)
            // `}}` трапляється в JSON-прикладі форми відповіді, тож перевіряємо саме плейсхолдери `{{…}}`.
            XCTAssertFalse(prompt.system.contains("{{"), "\(kind) system")
            XCTAssertFalse(prompt.system.contains(PromptTemplate.textPlaceholder), "\(kind) system")
            XCTAssertFalse(prompt.system.contains(RenderingPromptTemplate.itemsPlaceholder), "\(kind) system")
            XCTAssertFalse(prompt.user.contains("{{"), "\(kind) user")
            XCTAssertFalse(prompt.user.contains("}}"), "\(kind) user")
            XCTAssertTrue(prompt.user.contains("<text>perché</text>"))
        }
    }

    func testRetryingCombinedPromptKeepsSystem() {
        let prompt = PromptBuilder.build(text: "run", kind: .word, pair: .englishUkrainian)
        let retry = PromptBuilder.retrying(prompt)
        XCTAssertEqual(retry.system, prompt.system)
        XCTAssertTrue(retry.user.hasSuffix(PromptBuilder.retrySuffix))
    }
}
