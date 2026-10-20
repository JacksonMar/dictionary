import Foundation
import XCTest
@testable import VocabCore

/// M7.3 — рівно один HTTP-запит на нове слово (комбінований промт), обидва відображення збережено у файлі.
/// Реальний HTTP-шар: `ClaudeLookupService` + `MockURLProtocol` (лічильник запитів).
final class TokenEconomyTests: XCTestCase {
    private var stack: M7Stack!

    override func setUp() async throws {
        try await super.setUp()
        pinInterfaceLanguage(.uk)
        MockURLProtocol.reset()
        stack = try await M7Stack.make()
    }

    override func tearDown() async throws {
        stack?.remove()
        stack = nil
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    func testNewEnglishWordOneRequestBothRenderings() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok(M7.houseEnglishJSON)])

        let outcome = await stack.addWord.execute(rawText: "house")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(entry.word, "house")
        XCTAssertNil(entry.sourceLanguage)
        XCTAssertEqual(entry.variants?["it"]?.status, .ready)
        XCTAssertEqual(entry.variantState("it"), .ready)

        // Дані у файлі після перезавантаження стору.
        let onDisk = try XCTUnwrap(stack.entryOnDisk(entry.id))
        XCTAssertEqual(onDisk.translations, ["будинок", "дім"])
        let italian = try XCTUnwrap(onDisk.variants?["it"])
        XCTAssertEqual(italian.status, .ready)
        XCTAssertEqual(italian.word, "casa")
        XCTAssertEqual(italian.translations, ["дім", "будинок", "оселя"])
        XCTAssertEqual(italian.transcription, "/ˈkaːza/")
        XCTAssertEqual(italian.example?.source, "La casa è grande.")
        XCTAssertEqual(italian.sourceKey, "house")
        XCTAssertNil(onDisk.sourceLanguage)

        // Запит — комбінований (одна відповідь на обидві мови).
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertTrue(M7.systemText(request).contains("\"variants\""))
        XCTAssertEqual(M7.selection(request), "house")

        // Подальше перемикання на IT не робить запитів (D28).
        let report = await stack.backfill.backfill(pairID: "en-uk", languageID: "it", ignoringBackoff: true)
        XCTAssertEqual(report.requests, 0)
        XCTAssertEqual(report.eligible, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testNewItalianWordOneRequestStoresSourceLanguage() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok(M7.casaItalianJSON)])

        let outcome = await stack.addWord.execute(rawText: "casa")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(entry.word, "house")
        XCTAssertEqual(entry.sourceLanguage, "it")
        XCTAssertEqual(entry.variants?["it"]?.word, "casa")

        let onDisk = try XCTUnwrap(stack.entryOnDisk(entry.id))
        XCTAssertEqual(onDisk.word, "house")
        XCTAssertEqual(onDisk.translations, ["будинок", "дім"])
        XCTAssertEqual(onDisk.sourceLanguage, "it")
        XCTAssertEqual(onDisk.variants?["it"]?.word, "casa")
        XCTAssertEqual(onDisk.variants?["it"]?.status, .ready)
        XCTAssertEqual(onDisk.variantState("it"), .ready)
        XCTAssertEqual(onDisk.dedupKeys(), ["house", "casa"])

        // Сповіщення — мовою виділення.
        XCTAssertEqual(NotificationText.make(for: outcome).body, "Додано: casa — дім, будинок, оселя")
    }

    func testItalianSelectionKeepsUserWordingWhenModelChangesIt() async throws {
        // Модель повернула іншу форму слова (ключ не збігається з виділенням) → лишається очищене виділення (D5).
        let reply = M7.combinedJSON(
            sourceLanguage: "it",
            top: M7.object(word: "water", ipa: "/ˈwɔːtə/"),
            variants: ["it": M7.object(word: "acqua", ipa: "/ˈakkwa/")]
        )
        MockURLProtocol.setReplies([ClaudeFixtures.ok(reply)])

        let outcome = await stack.addWord.execute(rawText: "  l'acqua, ")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(entry.word, "water")
        XCTAssertEqual(entry.variants?["it"]?.word, "l'acqua")
        XCTAssertEqual(entry.sourceLanguage, "it")
    }

    func testInvalidVariantNotRetriedMarkedPending() async throws {
        var badItalian = M7.object(word: "casa")
        badItalian["translations"] = []
        let reply = M7.combinedJSON(sourceLanguage: "en", top: M7.object(word: "house", ipa: "/haʊs/"),
                                    variants: ["it": badItalian])
        MockURLProtocol.setReplies([ClaudeFixtures.ok(reply)])

        let outcome = await stack.addWord.execute(rawText: "house")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "invalid variant must not trigger a retry")
        XCTAssertEqual(entry.status, .ready)
        XCTAssertEqual(entry.variants?["it"]?.status, .pending)
        XCTAssertNil(entry.variants?["it"]?.word)
        XCTAssertEqual(entry.variants?["it"]?.sourceKey, "house")
        XCTAssertEqual(try stack.entryOnDisk(entry.id)?.variantState("it"), .pending)
    }

    func testInvalidSelectedItalianVariantRetriesOnceAsInvalidResponse() async throws {
        // Виняток: варіант мови виділення невалідний → уся відповідь невалідна → рівно один повтор (§7.5).
        var badItalian = M7.object(word: "casa")
        badItalian.removeValue(forKey: "example")
        let bad = M7.combinedJSON(sourceLanguage: "it", top: M7.object(word: "house"), variants: ["it": badItalian])
        MockURLProtocol.setReplies([ClaudeFixtures.ok(bad), ClaudeFixtures.ok(M7.casaItalianJSON)])

        let outcome = await stack.addWord.execute(rawText: "casa")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        XCTAssertEqual(entry.sourceLanguage, "it")
    }

    func testMaxTokensForSingleLookupStays4096() async throws {
        MockURLProtocol.setReplies([ClaudeFixtures.ok(M7.houseEnglishJSON)])

        _ = await stack.addWord.execute(rawText: "house")

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = M7.body(request)
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "system", "messages"])
        XCTAssertEqual(ClaudeConfiguration.defaultMaxTokens, 4096)
    }

    func testPairWithoutRenderingsNoVariantsStored() async throws {
        // Та сама пара без renderings — поведінка M2: варіантів у записі нема.
        stack.remove()
        stack = try await M7Stack.make(registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly]))
        MockURLProtocol.setReplies([ClaudeFixtures.ok(ClaudeFixtures.validWordJSON)])

        let outcome = await stack.addWord.execute(rawText: "run")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertNil(entry.variants)
        XCTAssertNil(entry.sourceLanguage)
        XCTAssertFalse(M7.systemText(MockURLProtocol.requests[0]).contains("source_language"))
    }
}
