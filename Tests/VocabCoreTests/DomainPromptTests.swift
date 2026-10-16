import Foundation
import XCTest
@testable import VocabCore

/// M8.1 (D31) — IT/QA-інструкція в усіх промтах; JSON-схеми, правила й user-шаблони без змін;
/// форма запиту (4 ключі тіла) і кількість запитів (1 на нове слово) не змінюються.
final class DomainPromptTests: XCTestCase {
    private var stack: M7Stack?

    override func setUp() async throws {
        try await super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        stack?.remove()
        stack = nil
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Фікстури

    private static let english = LanguagePair.englishUkrainian
    private static let italian = RenderingLanguage.italian
    private static var englishInstruction: String { english.prompt.domainInstruction }
    private static var italianInstruction: String { italian.prompt.domainInstruction }

    /// Пара en-uk без renderings, але з `domainInstruction` (одиночний промт M2 + інструкція).
    private static let singleWithDomain = LanguagePair(
        id: english.id,
        sourceLanguageName: english.sourceLanguageName,
        targetLanguageName: english.targetLanguageName,
        speechLanguageCode: english.speechLanguageCode,
        prompt: english.prompt,
        sourceLanguageCode: english.sourceLanguageCode,
        sourceShortTitle: english.sourceShortTitle,
        renderings: []
    )

    /// Італійська без `domainInstruction` — пакетний промт рівно як у M7.
    private static let italianWithoutDomain = RenderingLanguage(
        id: italian.id,
        shortTitle: italian.shortTitle,
        languageName: italian.languageName,
        speechLanguageCode: italian.speechLanguageCode,
        prompt: RenderingPromptTemplate(
            combinedInstruction: italian.prompt.combinedInstruction,
            batchSystem: italian.prompt.batchSystem,
            batchUser: italian.prompt.batchUser
        )
    )

    /// en-uk з renderings, але без жодної `domainInstruction` — комбінований промт рівно як у M7.
    private static let combinedWithoutDomain = LanguagePair(
        id: english.id,
        sourceLanguageName: english.sourceLanguageName,
        targetLanguageName: english.targetLanguageName,
        speechLanguageCode: english.speechLanguageCode,
        prompt: PromptTemplate(
            system: english.prompt.system,
            userWord: english.prompt.userWord,
            userPhrase: english.prompt.userPhrase
        ),
        sourceLanguageCode: english.sourceLanguageCode,
        sourceShortTitle: english.sourceShortTitle,
        renderings: [italianWithoutDomain]
    )

    private static let items = [
        VariantRequestItem(ref: 1, word: "flaky", kind: .word, partOfSpeech: "adjective", meaning: ["нестабільний"]),
        VariantRequestItem(ref: 2, word: "smoke test", kind: .phrase),
    ]

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// FNV-1a 64 над UTF-8 — стабільний відбиток тексту промту (Hasher рандомізований між запусками).
    private func fingerprint(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    // MARK: - M8.1

    func testSinglePromptContainsITQAInstruction() {
        let pair = Self.singleWithDomain
        let instruction = Self.englishInstruction
        XCTAssertFalse(instruction.isEmpty)
        XCTAssertTrue(pair.renderings.isEmpty)

        let word = PromptBuilder.build(text: "flaky", kind: .word, pair: pair)
        XCTAssertEqual(word.system, pair.prompt.system + "\n\n" + instruction)
        XCTAssertTrue(word.system.hasSuffix(instruction))
        XCTAssertEqual(occurrences(of: instruction, in: word.system), 1)
        XCTAssertTrue(word.system.contains("QA"))
        XCTAssertTrue(word.system.contains("software development"))
        // User — без змін і без інструкції.
        XCTAssertEqual(word.user, pair.prompt.userWord.replacingOccurrences(of: "{{TEXT}}", with: "flaky"))
        XCTAssertFalse(word.user.contains(instruction))
        // Одиночний промт лишається M2-формою (без детекції мови/варіантів).
        XCTAssertTrue(word.system.contains("exactly this shape"))
        XCTAssertFalse(word.system.contains("source_language"))

        let phrase = PromptBuilder.build(text: "smoke test", kind: .phrase, pair: pair)
        XCTAssertEqual(phrase.system, pair.prompt.system + "\n\n" + instruction)
        XCTAssertEqual(phrase.user, pair.prompt.userPhrase.replacingOccurrences(of: "{{TEXT}}", with: "smoke test"))

        // Повтор після невалідної відповіді зберігає інструкцію (system не змінюється).
        let retry = PromptBuilder.retrying(word)
        XCTAssertEqual(retry.system, word.system)
        XCTAssertFalse(retry.user.contains(instruction))
    }

    func testCombinedPromptContainsITQAInstructionOnce() {
        let pair = Self.english
        XCTAssertEqual(pair.renderings, [.italian])
        let instruction = Self.englishInstruction

        for (text, kind) in [("flaky", SelectionKind.word), ("smoke test", .phrase), ("casa", .word)] {
            let prompt = PromptBuilder.build(text: text, kind: kind, pair: pair)
            XCTAssertEqual(prompt.system, PromptBuilder.combinedSystem(for: pair) + "\n\n" + instruction)
            XCTAssertEqual(occurrences(of: instruction, in: prompt.system), 1, "instruction exactly once")
            XCTAssertTrue(prompt.system.hasSuffix(instruction))
            // Італійська інструкція в комбінований промт не додається (без дублювання токенів).
            XCTAssertFalse(prompt.system.contains(Self.italianInstruction))
            XCTAssertEqual(occurrences(of: "Context: the user works in software development and QA", in: prompt.system), 1)
            // Комбінований промт і далі просить детекцію мови й варіанти.
            XCTAssertTrue(prompt.system.contains("\"source_language\""))
            XCTAssertTrue(prompt.system.contains("\"variants\""))
            XCTAssertFalse(prompt.user.contains(instruction))
            XCTAssertEqual(M7.tagged(prompt.user, tag: "text"), text)
        }
        // Формулювання охоплює і верхній рівень, і варіанти.
        XCTAssertTrue(instruction.contains("variant"))
        XCTAssertTrue(instruction.contains("top level"))
    }

    func testVariantBatchPromptContainsItalianITQAInstruction() {
        let instruction = Self.italianInstruction
        XCTAssertFalse(instruction.isEmpty)
        XCTAssertTrue(instruction.contains("Italian"))
        XCTAssertTrue(instruction.contains("QA"))

        let prompt = VariantPromptBuilder.buildBatch(items: Self.items, language: .italian, pair: .englishUkrainian)
        XCTAssertEqual(prompt.system, Self.italian.prompt.batchSystem + "\n\n" + instruction)
        XCTAssertEqual(occurrences(of: instruction, in: prompt.system), 1)
        XCTAssertTrue(prompt.system.hasSuffix(instruction))
        // Інструкція пари (en) у пакетний промт не потрапляє.
        XCTAssertFalse(prompt.system.contains(Self.englishInstruction))
        XCTAssertEqual(occurrences(of: "Context: the user works in software development and QA", in: prompt.system), 1)
        // User — той самий шаблон із <items>.
        XCTAssertTrue(prompt.user.hasPrefix("Give the Italian rendering"))
        XCTAssertFalse(prompt.user.contains(instruction))
        let expectedUser = Self.italian.prompt.batchUser.replacingOccurrences(
            of: RenderingPromptTemplate.itemsPlaceholder,
            with: VariantPromptBuilder.encodeItems(Self.items)
        )
        XCTAssertEqual(prompt.user, expectedUser)
    }

    func testPairWithoutDomainInstructionPromptUnchanged() {
        // Одиночний режим (M2).
        let pair = LanguagePair.englishUkrainianSourceOnly
        XCTAssertEqual(pair.prompt.domainInstruction, "")
        let word = PromptBuilder.build(text: "run", kind: .word, pair: pair)
        XCTAssertEqual(word.system, pair.prompt.system)
        XCTAssertFalse(word.system.contains("Context:"))
        let phrase = PromptBuilder.build(text: "give up", kind: .phrase, pair: pair)
        XCTAssertEqual(phrase.system, pair.prompt.system)

        // Комбінований режим без інструкції — рівно system M7.
        let combined = PromptBuilder.build(text: "run", kind: .word, pair: Self.combinedWithoutDomain)
        XCTAssertEqual(combined.system, PromptBuilder.combinedSystem(for: Self.combinedWithoutDomain))
        XCTAssertFalse(combined.system.contains("Context:"))
        XCTAssertFalse(combined.system.hasSuffix("\n\n"))

        // Дефолт `init` — порожня інструкція.
        XCTAssertEqual(PromptTemplate(system: "s", userWord: "w", userPhrase: "p").domainInstruction, "")
        XCTAssertEqual(PromptBuilder.build(
            text: "x", kind: .word,
            pair: LanguagePair(id: "xx-yy", sourceLanguageName: "X", targetLanguageName: "Y", speechLanguageCode: "x",
                               prompt: PromptTemplate(system: "SYS", userWord: "<text>{{TEXT}}</text>", userPhrase: "P"))
        ).system, "SYS")
    }

    func testRenderingWithoutDomainInstructionBatchUnchanged() {
        let language = Self.italianWithoutDomain
        XCTAssertEqual(language.prompt.domainInstruction, "")
        XCTAssertEqual(
            RenderingPromptTemplate(combinedInstruction: "c", batchSystem: "b", batchUser: "u").domainInstruction, ""
        )
        let prompt = VariantPromptBuilder.buildBatch(items: Self.items, language: language, pair: Self.combinedWithoutDomain)
        XCTAssertEqual(prompt.system, language.prompt.batchSystem)
        XCTAssertEqual(prompt.system, Self.italian.prompt.batchSystem)
        XCTAssertFalse(prompt.system.contains("Context:"))

        // Та сама побудова з `.italian` відрізняється рівно суфіксом інструкції.
        let withDomain = VariantPromptBuilder.buildBatch(items: Self.items, language: .italian, pair: .englishUkrainian)
        XCTAssertEqual(withDomain.user, prompt.user)
        XCTAssertEqual(withDomain.system, prompt.system + "\n\n" + Self.italianInstruction)
    }

    func testSchemaTextUnchanged() {
        // System без інструкції == system M7: інструкція — лише суфікс, усе до нього — незмінне.
        let combined = PromptBuilder.build(text: "run", kind: .word, pair: Self.english)
        let m7Combined = PromptBuilder.build(text: "run", kind: .word, pair: Self.combinedWithoutDomain)
        XCTAssertEqual(combined.system, m7Combined.system + "\n\n" + Self.englishInstruction)
        XCTAssertEqual(combined.user, m7Combined.user)

        let batch = VariantPromptBuilder.buildBatch(items: Self.items, language: .italian, pair: .englishUkrainian)
        XCTAssertEqual(batch.system, Self.italian.prompt.batchSystem + "\n\n" + Self.italianInstruction)

        // Відбитки текстів M7 (ті самі значення, що й до M8): схеми, правила полів, user-шаблони.
        XCTAssertEqual(fingerprint(Self.english.prompt.system), Self.m7SystemFingerprint, "en-uk system changed")
        XCTAssertEqual(fingerprint(Self.english.prompt.userWord), Self.m7UserWordFingerprint, "userWord changed")
        XCTAssertEqual(fingerprint(Self.english.prompt.userPhrase), Self.m7UserPhraseFingerprint, "userPhrase changed")
        XCTAssertEqual(fingerprint(m7Combined.system), Self.m7CombinedSystemFingerprint, "combined system changed")
        XCTAssertEqual(fingerprint(Self.italian.prompt.combinedInstruction), Self.m7CombinedInstructionFingerprint)
        XCTAssertEqual(fingerprint(Self.italian.prompt.batchSystem), Self.m7BatchSystemFingerprint, "batchSystem changed")
        XCTAssertEqual(fingerprint(Self.italian.prompt.batchUser), Self.m7BatchUserFingerprint, "batchUser changed")

        // Ключові фрагменти схем на місці; інструкції не містять JSON-схем/нових ключів.
        XCTAssertTrue(combined.system.contains(#""part_of_speech": "verb""#))
        XCTAssertTrue(combined.system.contains("1 to 5 Ukrainian translations"))
        for instruction in [Self.englishInstruction, Self.italianInstruction] {
            XCTAssertFalse(instruction.contains("{"))
            XCTAssertFalse(instruction.contains("\""))
            XCTAssertFalse(instruction.contains("<text>"))
            XCTAssertFalse(instruction.contains("<items>"))
        }
    }

    func testDomainInstructionsAtMost70Words() {
        func words(_ text: String) -> Int {
            text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
        var checked = 0
        for pair in LanguagePairRegistry.shared.all {
            let count = words(pair.prompt.domainInstruction)
            XCTAssertGreaterThan(count, 0, "\(pair.id) domainInstruction empty")
            XCTAssertLessThanOrEqual(count, 70, "\(pair.id) domainInstruction has \(count) words")
            checked += 1
            for rendering in pair.renderings {
                let renderingCount = words(rendering.prompt.domainInstruction)
                XCTAssertGreaterThan(renderingCount, 0, "\(rendering.id) domainInstruction empty")
                XCTAssertLessThanOrEqual(renderingCount, 70, "\(rendering.id) domainInstruction has \(renderingCount) words")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 2, "en-uk + italian")
        // Без зайвих пробілів по краях (інакше «\n\n» + пробіли в кінці system).
        for instruction in [Self.englishInstruction, Self.italianInstruction] {
            XCTAssertEqual(instruction, instruction.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Форма запиту й кількість запитів (повний стек M7)

    func testNewWordOneRequestFourBodyKeysWithITQASystem() async throws {
        let made = try await M7Stack.make()
        stack = made
        let flaky = M7.combinedJSON(
            sourceLanguage: "en",
            top: M7.object(word: "flaky", pos: "adjective", ipa: "/ˈfleɪki/", translations: ["нестабільний", "лускатий"],
                           example: ("This test is flaky on CI.", "Цей тест нестабільний на CI.")),
            variants: ["it": M7.object(word: "instabile", pos: "adjective", ipa: "/insˈtaːbile/",
                                       translations: ["нестабільний"],
                                       example: ("Il test è instabile.", "Тест нестабільний."))]
        )
        MockURLProtocol.setReplies([ClaudeFixtures.ok(flaky)])

        let outcome = await made.addWord.execute(rawText: "flaky")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(entry.translations, ["нестабільний", "лускатий"])
        XCTAssertEqual(entry.variants?["it"]?.status, .ready)

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = M7.body(request)
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "system", "messages"])
        XCTAssertEqual(body["max_tokens"] as? Int, ClaudeConfiguration.defaultMaxTokens)
        XCTAssertEqual(ClaudeConfiguration.defaultMaxTokens, 4096)
        let expected = PromptBuilder.build(text: "flaky", kind: .word, pair: .englishUkrainian)
        XCTAssertEqual(body["system"] as? String, expected.system)
        XCTAssertEqual(occurrences(of: Self.englishInstruction, in: M7.systemText(request)), 1)
        XCTAssertEqual(M7.selection(request), "flaky")
        XCTAssertFalse(M7.userText(request).contains(Self.englishInstruction))

        // Варіант уже є — перемикання на IT запитів не робить.
        let report = await made.backfill.backfill(pairID: "en-uk", languageID: "it", ignoringBackoff: true)
        XCTAssertEqual(report.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testSourceOnlyPairRequestHasNoInstruction() async throws {
        let made = try await M7Stack.make(registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly]))
        stack = made
        MockURLProtocol.setReplies([ClaudeFixtures.ok()])

        _ = await made.addWord.execute(rawText: "run")

        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = M7.body(request)
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "system", "messages"])
        XCTAssertEqual(body["system"] as? String, LanguagePair.englishUkrainianSourceOnly.prompt.system)
    }

    func testBackfillRequestCarriesItalianInstructionOnce() async throws {
        let made = try await M7Stack.make(seed: [M7.entry(word: "run"), M7.entry(word: "house")])
        stack = made
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let report = await made.backfill.backfill(pairID: "en-uk", languageID: "it", ignoringBackoff: true)

        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = M7.body(request)
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "system", "messages"])
        XCTAssertEqual(body["max_tokens"] as? Int, ClaudeConfiguration.batchMaxTokens)
        let system = M7.systemText(request)
        XCTAssertEqual(system, Self.italian.prompt.batchSystem + "\n\n" + Self.italianInstruction)
        XCTAssertFalse(system.contains(Self.englishInstruction))
    }

    // MARK: - Відбитки текстів M7 (FNV-1a 64, UTF-8), обчислені на коміті a3c06da (M7, до M8)

    private static let m7SystemFingerprint: UInt64 = 0xC0DB_4B5C_D059_D333
    private static let m7UserWordFingerprint: UInt64 = 0x214F_7C75_98A4_EC5E
    private static let m7UserPhraseFingerprint: UInt64 = 0xB6C8_C24C_6834_21C7
    private static let m7CombinedSystemFingerprint: UInt64 = 0xD4DE_7E39_49DC_85D4
    private static let m7CombinedInstructionFingerprint: UInt64 = 0x55EC_CE1C_1900_4447
    private static let m7BatchSystemFingerprint: UInt64 = 0x17B5_FD05_BE79_2156
    private static let m7BatchUserFingerprint: UInt64 = 0xDBD4_6C97_93FB_DCC9
}
