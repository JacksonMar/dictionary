import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import VocabCore

/// I2a (DI13, IOS_PLAN §3.2): підказка мови (`Entry.languageHint`) — промт, формат, життєвий цикл, перенесення, токени.
/// Реальний HTTP-шар там, де рахуються запити: `ClaudeLookupService` + `MockURLProtocol` (`M7Stack`).
final class LanguageHintTests: XCTestCase {
    private var stack: M7Stack?

    override func setUp() async throws {
        try await super.setUp()
        pinInterfaceLanguage(.en)
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        stack?.remove()
        stack = nil
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Помічники

    private func makeStack(
        seed: [Entry] = [],
        registry: LanguagePairRegistry = LanguagePairRegistry(pairs: [.englishUkrainian])
    ) async throws -> M7Stack {
        let made = try await M7Stack.make(seed: seed, registry: registry)
        stack = made
        return made
    }

    /// Очікуване речення-підказка (текст плану §3.2 з підставленими назвою й кодом).
    private static func hintSentence(name: String, code: String) -> String {
        "The user stated the text is \(name); set source_language to \"\(code)\" unless the text is clearly not \(name)."
    }

    private static let italianHint = hintSentence(name: "Italian", code: "it")
    private static let englishHint = hintSentence(name: "English", code: "en")

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// FNV-1a 64 над UTF-8 (платформонезалежний відбиток для golden-порівняння промтів).
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Італійська відповідь моделі на «come» (верхній рівень — англійський відповідник `how`).
    private static let comeItalianJSON = M7.combinedJSON(
        sourceLanguage: "it",
        top: M7.object(word: "how", pos: "adverb", ipa: "/haʊ/", translations: ["як"],
                       example: ("How are you?", "Як справи?")),
        variants: ["it": M7.object(word: "come", pos: "avverbio", ipa: "/ˈkoːme/", translations: ["як"],
                                   example: ("Come stai?", "Як справи?"))]
    )

    /// Англійська відповідь на «come» (модель не послухала підказку).
    private static let comeEnglishJSON = M7.combinedJSON(
        sourceLanguage: "en",
        top: M7.object(word: "come", pos: "verb", ipa: "/kʌm/", translations: ["приходити"],
                       example: ("Come here.", "Іди сюди.")),
        variants: ["it": M7.object(word: "venire", pos: "verbo", ipa: "/veˈniːre/", translations: ["приходити"],
                                   example: ("Vieni qui.", "Іди сюди."))]
    )

    private static func fixedID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix)) ?? UUID()
    }

    /// Пара з `renderings: []`, але з непорожнім `sourceHintInstruction` (щоб перевірити саме умову «без renderings»).
    private static let sourceOnlyPairWithHintTemplate = LanguagePair(
        id: LanguagePair.englishUkrainian.id,
        sourceLanguageName: LanguagePair.englishUkrainian.sourceLanguageName,
        targetLanguageName: LanguagePair.englishUkrainian.targetLanguageName,
        speechLanguageCode: LanguagePair.englishUkrainian.speechLanguageCode,
        prompt: LanguagePair.englishUkrainian.prompt,
        sourceLanguageCode: "en",
        sourceShortTitle: "EN",
        renderings: []
    )

    /// Пара з `renderings`, але з порожнім `sourceHintInstruction`.
    private static let renderingsPairWithoutHintTemplate = LanguagePair(
        id: LanguagePair.englishUkrainian.id,
        sourceLanguageName: LanguagePair.englishUkrainian.sourceLanguageName,
        targetLanguageName: LanguagePair.englishUkrainian.targetLanguageName,
        speechLanguageCode: LanguagePair.englishUkrainian.speechLanguageCode,
        prompt: PromptTemplate(
            system: LanguagePair.englishUkrainian.prompt.system,
            userWord: LanguagePair.englishUkrainian.prompt.userWord,
            userPhrase: LanguagePair.englishUkrainian.prompt.userPhrase,
            domainInstruction: LanguagePair.englishUkrainian.prompt.domainInstruction
        ),
        sourceLanguageCode: "en",
        sourceShortTitle: "EN",
        renderings: [.italian]
    )

    // MARK: - I2a.1 Промт

    /// Відбитки промтів, знятих з коду **до I2a** (коміт HEAD~1, `PromptBuilder.build(text:kind:pair:)`).
    private struct Golden {
        let pair: LanguagePair
        let text: String
        let kind: SelectionKind
        let systemHash: UInt64
        let systemLength: Int
        let userHash: UInt64
        let userLength: Int
    }

    private static let goldens: [Golden] = [
        Golden(pair: .englishUkrainian, text: "come", kind: .word,
               systemHash: 8_400_354_817_231_125_460, systemLength: 3972,
               userHash: 4_666_935_792_426_015_187, userLength: 80),
        Golden(pair: .englishUkrainian, text: "give up", kind: .phrase,
               systemHash: 8_400_354_817_231_125_460, systemLength: 3972,
               userHash: 9_550_697_607_790_668_248, userLength: 139),
        Golden(pair: .englishUkrainianSourceOnly, text: "come", kind: .word,
               systemHash: 13_896_783_937_186_419_507, systemLength: 1478,
               userHash: 3_189_286_181_394_722_767, userLength: 88),
        Golden(pair: .englishUkrainianSourceOnly, text: "give up", kind: .phrase,
               systemHash: 13_896_783_937_186_419_507, systemLength: 1478,
               userHash: 6_673_999_618_639_255_244, userLength: 147),
    ]

    func testPromptWithoutHintIsByteIdentical() {
        for golden in Self.goldens {
            let context = "\(golden.pair.renderings.isEmpty ? "source-only" : "en-uk") \(golden.text)"
            let old = PromptBuilder.build(text: golden.text, kind: golden.kind, pair: golden.pair)
            let new = PromptBuilder.build(text: golden.text, kind: golden.kind, pair: golden.pair, sourceLanguageHint: nil)

            XCTAssertEqual(new, old, context)
            // Golden: байти промту такі самі, як до I2a.
            XCTAssertEqual(new.system.utf8.count, golden.systemLength, context)
            XCTAssertEqual(Self.fnv1a(new.system), golden.systemHash, context)
            XCTAssertEqual(new.user.utf8.count, golden.userLength, context)
            XCTAssertEqual(Self.fnv1a(new.user), golden.userHash, context)
            XCTAssertFalse(new.system.contains("The user stated"), context)
        }

        // Структурно: комбінований system = combinedSystem + доменна інструкція, нічого більше.
        let pair = LanguagePair.englishUkrainian
        let prompt = PromptBuilder.build(text: "come", kind: .word, pair: pair, sourceLanguageHint: nil)
        XCTAssertEqual(prompt.system, PromptBuilder.combinedSystem(for: pair) + "\n\n" + pair.prompt.domainInstruction)
    }

    func testHintAppendedOnceForPairWithRenderings() {
        let pair = LanguagePair.englishUkrainian
        for kind in [SelectionKind.word, .phrase] {
            let text = kind == .word ? "come" : "come stai"
            let base = PromptBuilder.build(text: text, kind: kind, pair: pair)

            let italian = PromptBuilder.build(text: text, kind: kind, pair: pair, sourceLanguageHint: "it")
            XCTAssertEqual(italian.system, base.system + "\n\n" + Self.italianHint)
            XCTAssertEqual(italian.user, base.user, "hint must not touch the user message")
            XCTAssertEqual(Self.occurrences(of: Self.italianHint, in: italian.system), 1)
            XCTAssertEqual(Self.occurrences(of: "The user stated", in: italian.system), 1)
            XCTAssertFalse(italian.system.contains(PromptTemplate.languageNamePlaceholder))
            XCTAssertFalse(italian.system.contains(PromptTemplate.languageCodePlaceholder))

            let english = PromptBuilder.build(text: text, kind: kind, pair: pair, sourceLanguageHint: "en")
            XCTAssertEqual(english.system, base.system + "\n\n" + Self.englishHint)
            XCTAssertEqual(english.user, base.user)
        }

        // ≤ 40 слів (DI13: ≈25 вхідних токенів).
        let words = Self.italianHint.split(whereSeparator: { $0.isWhitespace }).count
        XCTAssertLessThanOrEqual(words, 40)
        let templateWords = pair.prompt.sourceHintInstruction.split(whereSeparator: { $0.isWhitespace }).count
        XCTAssertLessThanOrEqual(templateWords, 40)

        // Ретрай-промт (невалідний JSON) зберігає system з підказкою рівно один раз.
        let hinted = PromptBuilder.build(text: "come", kind: .word, pair: pair, sourceLanguageHint: "it")
        let retried = PromptBuilder.retrying(hinted)
        XCTAssertEqual(retried.system, hinted.system)
        XCTAssertEqual(Self.occurrences(of: Self.italianHint, in: retried.system), 1)
    }

    func testUnknownHintIgnored() {
        let pair = LanguagePair.englishUkrainian
        let base = PromptBuilder.build(text: "come", kind: .word, pair: pair)
        for hint in ["fr", "", "xx", "uk", "Italian", "it-IT"] {
            let prompt = PromptBuilder.build(text: "come", kind: .word, pair: pair, sourceLanguageHint: hint)
            XCTAssertEqual(prompt, base, "hint \(hint.debugDescription) must be ignored")
        }
    }

    func testHintIgnoredForPairWithoutRenderings() {
        // Тестова пара M2 (без renderings, без шаблону підказки).
        let sourceOnly = LanguagePair.englishUkrainianSourceOnly
        for hint in ["en", "it"] {
            XCTAssertEqual(
                PromptBuilder.build(text: "come", kind: .word, pair: sourceOnly, sourceLanguageHint: hint),
                PromptBuilder.build(text: "come", kind: .word, pair: sourceOnly)
            )
        }

        // Без renderings, але з непорожнім шаблоном — підказка однаково не додається.
        let withTemplate = Self.sourceOnlyPairWithHintTemplate
        XCTAssertFalse(withTemplate.prompt.sourceHintInstruction.isEmpty)
        for hint in ["en", "it"] {
            let prompt = PromptBuilder.build(text: "come", kind: .word, pair: withTemplate, sourceLanguageHint: hint)
            XCTAssertEqual(prompt, PromptBuilder.build(text: "come", kind: .word, pair: withTemplate), "hint \(hint)")
            XCTAssertFalse(prompt.system.contains("The user stated"))
            // Помічник сам по собі теж відмовляє парі без renderings (не лише рання гілка `build`).
            XCTAssertNil(PromptBuilder.sourceHintInstruction(for: hint, pair: withTemplate), "hint \(hint)")
        }
        XCTAssertEqual(
            PromptBuilder.sourceHintInstruction(for: "it", pair: .englishUkrainian),
            Self.italianHint
        )
        XCTAssertNil(PromptBuilder.sourceHintInstruction(for: nil, pair: .englishUkrainian))

        // З renderings, але з порожнім шаблоном — промт без змін.
        let noTemplate = Self.renderingsPairWithoutHintTemplate
        XCTAssertEqual(
            PromptBuilder.build(text: "come", kind: .word, pair: noTemplate, sourceLanguageHint: "it"),
            PromptBuilder.build(text: "come", kind: .word, pair: noTemplate)
        )
    }

    // MARK: - I2a.2 Модель і формат

    /// Кодування запису з варіантом і `sourceLanguage`, зняте з коду **до I2a** (HEAD~1, `JSONCoding.makeEncoder()`).
    private static let preI2aReadyEntryJSON = """
    {
      "createdAt" : "2026-10-13T10:00:00Z",
      "example" : {
        "source" : "My house.",
        "translation" : "Мій дім."
      },
      "id" : "00000000-0000-4000-8000-000000000042",
      "languagePair" : "en-uk",
      "lemma" : "house",
      "partOfSpeech" : "noun",
      "sourceLanguage" : "it",
      "status" : "ready",
      "transcription" : "/haʊs/",
      "translations" : [
        "будинок"
      ],
      "updatedAt" : "2026-10-13T10:00:05Z",
      "variants" : {
        "it" : {
          "lemma" : "casa",
          "partOfSpeech" : "noun",
          "sourceKey" : "house",
          "status" : "ready",
          "transcription" : "/ˈkaːza/",
          "translations" : [
            "дім"
          ],
          "word" : "casa"
        }
      },
      "word" : "house"
    }
    """

    private static func goldenReadyEntry(languageHint: String? = nil) -> Entry {
        Entry(
            id: fixedID(42),
            languagePair: "en-uk",
            word: "house",
            lemma: "house",
            partOfSpeech: "noun",
            transcription: "/haʊs/",
            translations: ["будинок"],
            example: Example(source: "My house.", translation: "Мій дім."),
            status: .ready,
            lastError: nil,
            createdAt: TestDates.reference,
            updatedAt: TestDates.reference.addingTimeInterval(5),
            variants: ["it": EntryVariant(word: "casa", lemma: "casa", partOfSpeech: "noun", transcription: "/ˈkaːza/",
                                          translations: ["дім"], status: .ready, sourceKey: "house")],
            sourceLanguage: "it",
            languageHint: languageHint
        )
    }

    func testEntryWithoutHintEncodesUnchanged() throws {
        let encoder = JSONCoding.makeEncoder()

        // Байти — як до I2a (literal golden).
        let ready = try encoder.encode(Self.goldenReadyEntry())
        XCTAssertEqual(String(decoding: ready, as: UTF8.self), Self.preI2aReadyEntryJSON)
        XCTAssertFalse(String(decoding: ready, as: UTF8.self).contains("languageHint"))

        // Записи M6-формату (pending/failed/без опційних полів) — байти як у M6-дзеркала, ключа нема.
        let entries = M7.m6Entries()
        let fileData = try encoder.encode(DictionaryFile(schemaVersion: 1, exportedAt: TestDates.reference, entries: entries))
        XCTAssertEqual(fileData, try M7.m6FileData(entries))
        XCTAssertFalse(String(decoding: fileData, as: UTF8.self).contains("languageHint"))

        // Експорт теж без ключа.
        let exported = try DictionaryExporter.exportData(entries: entries, now: TestDates.reference)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("languageHint"))
    }

    func testHintRoundTrips() throws {
        let encoder = JSONCoding.makeEncoder()
        let decoder = JSONCoding.makeDecoder()

        var pending = M7.entry(id: Self.fixedID(1), word: "come", status: .pending)
        pending.languageHint = "it"
        let data = try encoder.encode(pending)
        let object = try jsonObject(data)
        XCTAssertEqual(object["languageHint"] as? String, "it")
        let decoded = try decoder.decode(Entry.self, from: data)
        XCTAssertEqual(decoded, pending)
        XCTAssertEqual(decoded.languageHint, "it")

        // З підказкою байти = до-I2a байти + рівно один ключ (решта не змінилась).
        let hinted = try encoder.encode(Self.goldenReadyEntry(languageHint: "en"))
        var hintedObject = try jsonObject(hinted)
        XCTAssertEqual(hintedObject.removeValue(forKey: "languageHint") as? String, "en")
        let plainObject = try jsonObject(Data(Self.preI2aReadyEntryJSON.utf8))
        XCTAssertEqual(NSDictionary(dictionary: hintedObject), NSDictionary(dictionary: plainObject))

        // Невідомий код зберігається (ігнорується лише при використанні).
        var unknown = pending
        unknown.languageHint = "fr"
        XCTAssertEqual(try decoder.decode(Entry.self, from: encoder.encode(unknown)).languageHint, "fr")

        // Через сховище (файл на диску) — теж без втрат.
        let fixture = try StoreFixture()
        defer { fixture.directory.remove() }
        try fixture.store.save(DictionaryFile(entries: [pending, unknown.withID(Self.fixedID(2))]))
        let loaded = try fixture.store.load().file.entries
        XCTAssertEqual(loaded.map(\.languageHint), ["it", "fr"])
        XCTAssertEqual(loaded.first, pending)
    }

    func testEmptyHintDecodesNil() throws {
        let decoder = JSONCoding.makeDecoder()
        var base = try M4.rawEntry(M7.entry(id: Self.fixedID(1), word: "come", status: .pending))
        let values: [Any] = ["", "   ", "\n\t", 42, true, NSNull(), ["it"], ["code": "it"]]
        for value in values {
            base["languageHint"] = value
            let data = try JSONSerialization.data(withJSONObject: base)
            let entry = try decoder.decode(Entry.self, from: data)
            XCTAssertNil(entry.languageHint, "value \(value) must decode as nil")
            XCTAssertEqual(entry.word, "come", "entry must still decode for \(value)")
        }

        // Пробіли навколо коду обрізаються.
        base["languageHint"] = "  it \n"
        let trimmed = try decoder.decode(Entry.self, from: JSONSerialization.data(withJSONObject: base))
        XCTAssertEqual(trimmed.languageHint, "it")

        // Імпорт: некоректна підказка не робить запис невалідним.
        base["languageHint"] = 7
        let file = try M4.rawFileData([base])
        let parsed = try DictionaryImporter.parse(file)
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertTrue(parsed.skippedReasons.isEmpty)
        XCTAssertNil(parsed.entries.first?.languageHint)
    }

    func testSourceLanguageUntouchedByHint() async throws {
        // Модель: підказка не впливає на кодування/декодування `sourceLanguage`.
        var entry = M7.entry(id: Self.fixedID(1), word: "come", status: .pending)
        entry.languageHint = "it"
        let decoded = try JSONCoding.makeDecoder().decode(Entry.self, from: JSONCoding.makeEncoder().encode(entry))
        XCTAssertNil(decoded.sourceLanguage)
        XCTAssertNil(try jsonObject(JSONCoding.makeEncoder().encode(entry))["sourceLanguage"])

        let stack = try await makeStack()

        // Use-case: pending-запис має підказку, але `sourceLanguage` = nil.
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.notConnectedToInternet)])
        let queued = await stack.addWord.execute(rawText: "come", sourceLanguageHint: "it")
        guard case .queued(let pending, _) = queued else { return XCTFail("expected .queued, got \(queued)") }
        XCTAssertEqual(pending.languageHint, "it")
        XCTAssertNil(pending.sourceLanguage)

        // Модель не послухала підказку ("en") → `sourceLanguage` визначає відповідь (nil), не підказка.
        MockURLProtocol.setReplies([ClaudeFixtures.ok(Self.comeEnglishJSON)])
        let result = await stack.queue.retry(entryID: pending.id)
        guard case .ready(let ready) = result else { return XCTFail("expected .ready, got \(result)") }
        XCTAssertNil(ready.sourceLanguage)
        XCTAssertNil(ready.languageHint)
        XCTAssertEqual(ready.word, "come")
        XCTAssertNil(try stack.entryOnDisk(pending.id)?.sourceLanguage)
    }

    // MARK: - I2a.3 Життєвий цикл

    func testUseCaseStoresHintOnPendingEntry() async throws {
        let stack = try await makeStack()
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.notConnectedToInternet)])

        let outcome = await stack.addWord.execute(rawText: "come", sourceLanguageHint: "it")

        guard case .queued(let entry, let error) = outcome else { return XCTFail("expected .queued, got \(outcome)") }
        XCTAssertEqual(error, .offline)
        XCTAssertEqual(entry.status, .pending)
        XCTAssertEqual(entry.languageHint, "it")
        let stored1 = await stack.repository.entry(id: entry.id)
        XCTAssertEqual(stored1?.languageHint, "it")
        XCTAssertEqual(try stack.entryOnDisk(entry.id)?.languageHint, "it")

        // Пробіли навколо коду обрізаються.
        let trimmed = await stack.addWord.execute(rawText: "pane", sourceLanguageHint: " it\n")
        guard case .queued(let trimmedEntry, _) = trimmed else { return XCTFail("expected .queued, got \(trimmed)") }
        XCTAssertEqual(trimmedEntry.languageHint, "it")

        // Мова джерела пари теж допустима.
        let english = await stack.addWord.execute(rawText: "run", sourceLanguageHint: "en")
        guard case .queued(let englishEntry, _) = english else { return XCTFail("expected .queued, got \(english)") }
        XCTAssertEqual(englishEntry.languageHint, "en")

        // Стара сигнатура — без підказки.
        let plain = await stack.addWord.execute(rawText: "house")
        guard case .queued(let plainEntry, _) = plain else { return XCTFail("expected .queued, got \(plain)") }
        XCTAssertNil(plainEntry.languageHint)
    }

    func testHintOutsideAllowedSourceLanguagesDropped() async throws {
        let stack = try await makeStack()
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.notConnectedToInternet)])

        let cases: [(String, String)] = [("come", "fr"), ("pane", "uk"), ("no", ""), ("casa", "   "), ("run", "xx")]
        for (word, hint) in cases {
            let outcome = await stack.addWord.execute(rawText: word, sourceLanguageHint: hint)
            guard case .queued(let entry, _) = outcome else { return XCTFail("expected .queued for \(word), got \(outcome)") }
            XCTAssertNil(entry.languageHint, "hint \(hint.debugDescription) must be dropped")
            XCTAssertNil(try stack.entryOnDisk(entry.id)?.languageHint)
        }

        // Для пари без renderings допустима лише мова джерела.
        let sourceOnly = try await M7Stack.make(registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly]))
        defer { sourceOnly.remove() }
        let italian = await sourceOnly.addWord.execute(rawText: "come", sourceLanguageHint: "it")
        guard case .queued(let dropped, _) = italian else { return XCTFail("expected .queued, got \(italian)") }
        XCTAssertNil(dropped.languageHint)
        let english = await sourceOnly.addWord.execute(rawText: "run", sourceLanguageHint: "en")
        guard case .queued(let kept, _) = english else { return XCTFail("expected .queued, got \(english)") }
        XCTAssertEqual(kept.languageHint, "en")

        // Запит для відкинутої підказки — без речення-підказки.
        MockURLProtocol.reset()
        MockURLProtocol.setReplies([ClaudeFixtures.ok(Self.comeEnglishJSON)])
        stack.remove()
        let fresh = try await makeStack()
        _ = await fresh.addWord.execute(rawText: "come", sourceLanguageHint: "fr")
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertFalse(M7.systemText(request).contains("The user stated"))
    }

    func testHintClearedWhenReady() async throws {
        // 1) Одразу успіх.
        let stack = try await makeStack()
        MockURLProtocol.setReplies([ClaudeFixtures.ok(Self.comeItalianJSON)])
        let outcome = await stack.addWord.execute(rawText: "come", sourceLanguageHint: "it")
        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(entry.status, .ready)
        XCTAssertNil(entry.languageHint)
        let stored2 = await stack.repository.entry(id: entry.id)
        XCTAssertNil(stored2?.languageHint)
        XCTAssertNil(try stack.entryOnDisk(entry.id)?.languageHint)
        XCTAssertEqual(entry.sourceLanguage, "it")

        // 2) Офлайн → pending з підказкою → черга → ready, підказку очищено.
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.notConnectedToInternet)])
        let queued = await stack.addWord.execute(rawText: "pane", sourceLanguageHint: "it")
        guard case .queued(let pending, _) = queued else { return XCTFail("expected .queued, got \(queued)") }
        XCTAssertEqual(pending.languageHint, "it")
        let paneJSON = M7.combinedJSON(
            sourceLanguage: "it",
            top: M7.object(word: "bread", ipa: "/brɛd/", translations: ["хліб"]),
            variants: ["it": M7.object(word: "pane", ipa: "/ˈpaːne/", translations: ["хліб"])]
        )
        MockURLProtocol.setReplies([ClaudeFixtures.ok(paneJSON)])
        let results = await stack.queue.processAll(ignoringBackoff: true)
        XCTAssertEqual(results.count, 1)
        let stored3 = await stack.repository.entry(id: pending.id)
        let processed = try XCTUnwrap(stored3)
        XCTAssertEqual(processed.status, .ready)
        XCTAssertNil(processed.languageHint)
        XCTAssertNil(try stack.entryOnDisk(pending.id)?.languageHint)

        // 3) Пара без renderings: ready теж очищує.
        MockURLProtocol.reset()
        MockURLProtocol.setReplies([ClaudeFixtures.ok(ClaudeFixtures.validWordJSON)])
        let sourceOnly = try await M7Stack.make(registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly]))
        defer { sourceOnly.remove() }
        let added = await sourceOnly.addWord.execute(rawText: "run", sourceLanguageHint: "en")
        guard case .added(let runEntry) = added else { return XCTFail("expected .added, got \(added)") }
        XCTAssertNil(runEntry.languageHint)
        XCTAssertNil(try sourceOnly.entryOnDisk(runEntry.id)?.languageHint)
    }

    func testManualFillAsReadyClearsHint() async throws {
        var seeded = M7.entry(id: Self.fixedID(1), word: "come", status: .failed)
        seeded.languageHint = "it"
        let stack = try await makeStack(seed: [seeded])

        let stored4 = await stack.repository.entry(id: seeded.id)
        var edited = try XCTUnwrap(stored4)
        edited.translations = ["як"]
        edited.status = .ready
        let saved = try await stack.repository.update(edited)
        XCTAssertEqual(saved.status, .ready)
        XCTAssertNil(saved.languageHint)
        XCTAssertNil(try stack.entryOnDisk(seeded.id)?.languageHint)
    }

    func testEditKeepsHint() async throws {
        var seeded = M7.entry(id: Self.fixedID(1), word: "come", status: .failed)
        seeded.languageHint = "it"
        let stack = try await makeStack(seed: [seeded])

        // Редактор із застарілою копією без підказки (напр. Mac-UI) — збережена підказка лишається.
        var stale = seeded
        stale.languageHint = nil
        stale.word = "come!"
        let saved = try await stack.repository.update(stale)
        XCTAssertEqual(saved.languageHint, "it")
        XCTAssertEqual(try stack.entryOnDisk(seeded.id)?.languageHint, "it")

        // Копія з іншою підказкою — `update` поле не змінює.
        var other = saved
        other.languageHint = "en"
        other.translations = ["щось"]
        let savedAgain = try await stack.repository.update(other)
        XCTAssertEqual(savedAgain.languageHint, "it")

        // Pending-статус також зберігає підказку.
        var toPending = savedAgain
        toPending.status = .pending
        let stored5 = try await stack.repository.update(toPending)
        XCTAssertEqual(stored5.languageHint, "it")
    }

    func testHintKeptOnFailedAndOffline() async throws {
        let stack = try await makeStack()

        // Офлайн → pending, підказка лишається (у т. ч. на диску).
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.notConnectedToInternet)])
        let outcome = await stack.addWord.execute(rawText: "come", sourceLanguageHint: "it")
        guard case .queued(let pending, _) = outcome else { return XCTFail("expected .queued, got \(outcome)") }
        XCTAssertEqual(pending.languageHint, "it")

        // Ще одна офлайн-спроба з черги.
        _ = await stack.queue.processAll(ignoringBackoff: true)
        let stored6 = await stack.repository.entry(id: pending.id)
        XCTAssertEqual(stored6?.status, .pending)
        let stored7 = await stack.repository.entry(id: pending.id)
        XCTAssertEqual(stored7?.languageHint, "it")

        // Тимчасова помилка сервера → pending (лічильник), підказка лишається.
        MockURLProtocol.setReplies([ClaudeFixtures.http(500)])
        let serverResult = await stack.queue.retry(entryID: pending.id)
        XCTAssertEqual(serverResult.entry?.status, .pending)
        XCTAssertEqual(serverResult.entry?.languageHint, "it")

        // Постійна помилка (400) → failed, підказка лишається.
        MockURLProtocol.setReplies([ClaudeFixtures.http(400)])
        let failedResult = await stack.queue.retry(entryID: pending.id)
        guard case .failed(let failed, _) = failedResult else { return XCTFail("expected .failed, got \(failedResult)") }
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.languageHint, "it")
        XCTAssertEqual(try stack.entryOnDisk(pending.id)?.languageHint, "it")
        XCTAssertEqual(try stack.entryOnDisk(pending.id)?.status, .failed)

        // Невалідна відповідь (двічі) → failed, підказка лишається.
        MockURLProtocol.setReplies([ClaudeFixtures.ok("not json")])
        let invalid = await stack.queue.retry(entryID: pending.id)
        XCTAssertEqual(invalid.entry?.status, .failed)
        XCTAssertEqual(invalid.entry?.languageHint, "it")

        // Усі запити несли підказку.
        let requests = MockURLProtocol.requests
        XCTAssertFalse(requests.isEmpty)
        for request in requests {
            XCTAssertEqual(Self.occurrences(of: Self.italianHint, in: M7.systemText(request)), 1)
        }
    }

    func testManualRetryUsesHint() async throws {
        // Failed-запис з підказкою (напр. імпортований з iPhone на Mac).
        var seeded = M7.entry(id: Self.fixedID(1), word: "come", status: .failed)
        seeded.lastError = "Bad request"
        seeded.languageHint = "it"
        let stack = try await makeStack(seed: [seeded])
        MockURLProtocol.setReplies([ClaudeFixtures.ok(Self.comeItalianJSON)])

        let result = await stack.queue.retry(entryID: seeded.id)

        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let system = M7.systemText(request)
        XCTAssertTrue(system.hasSuffix("\n\n" + Self.italianHint), "hint must be the last sentence of system")
        XCTAssertEqual(Self.occurrences(of: Self.italianHint, in: system), 1)
        XCTAssertEqual(M7.selection(request), "come")
        XCTAssertFalse(M7.userText(request).contains("The user stated"))

        guard case .ready(let ready) = result else { return XCTFail("expected .ready, got \(result)") }
        XCTAssertNil(ready.languageHint)
        XCTAssertEqual(ready.sourceLanguage, "it")
        XCTAssertEqual(ready.variants?["it"]?.word, "come")
    }

    func testRequestWithoutHintHasNoHintSentence() async throws {
        let stack = try await makeStack()
        MockURLProtocol.setReplies([ClaudeFixtures.ok(Self.comeEnglishJSON)])
        _ = await stack.addWord.execute(rawText: "come")
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(
            M7.systemText(request),
            PromptBuilder.build(text: "come", kind: .word, pair: .englishUkrainian).system
        )
        XCTAssertFalse(M7.systemText(request).contains("The user stated"))
    }

    func testJSONRetryKeepsHintOnce() async throws {
        let stack = try await makeStack()
        MockURLProtocol.setReplies([ClaudeFixtures.ok("not json"), ClaudeFixtures.ok(Self.comeItalianJSON)])

        let outcome = await stack.addWord.execute(rawText: "come", sourceLanguageHint: "it")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertNil(entry.languageHint)
        XCTAssertEqual(MockURLProtocol.requestCount, 2, "one retry after invalid JSON")
        let requests = MockURLProtocol.requests
        XCTAssertEqual(M7.systemText(requests[0]), M7.systemText(requests[1]))
        for request in requests {
            XCTAssertEqual(Self.occurrences(of: Self.italianHint, in: M7.systemText(request)), 1)
        }
        XCTAssertTrue(M7.userText(requests[1]).hasSuffix(PromptBuilder.retrySuffix))
    }

    func testStubLookupWithoutHintOverloadStillWorks() async throws {
        // Default-реалізація `lookup(…sourceLanguageHint:)` у extension делегує в стару (заглушки не ламаються).
        let harness = try await QueueHarness.make([.success(ClaudeFixtures.expectedRunResult)])
        defer { harness.remove() }
        let entry = try await harness.repository.add(
            EntryDraft(word: "run", languagePair: "en-uk", status: .pending, languageHint: "en")
        )
        XCTAssertEqual(entry.languageHint, "en")
        let result = await harness.processor.process(entryID: entry.id, attempts: 0)
        guard case .ready(let ready) = result else { return XCTFail("expected .ready, got \(result)") }
        XCTAssertEqual(harness.lookup.texts, ["run"])
        XCTAssertNil(ready.languageHint)
    }

    func testImportCarriesHint() async throws {
        var hinted = M4.entry(id: Self.fixedID(1), word: "come", status: .pending, created: 0, updated: 10)
        hinted.languageHint = "it"
        let plain = M4.entry(id: Self.fixedID(2), word: "run", created: 0, updated: 10)

        // Експорт пише поле лише для запису з підказкою.
        let exported = try DictionaryExporter.exportData(entries: [hinted, plain], now: M4.date(20))
        let exportedEntries = try XCTUnwrap(try jsonObject(exported)["entries"] as? [[String: Any]])
        XCTAssertEqual(exportedEntries.first { $0["word"] as? String == "come" }?["languageHint"] as? String, "it")
        XCTAssertNil(exportedEntries.first { $0["word"] as? String == "run" }?["languageHint"])

        // Парсер імпорту зберігає поле.
        let parsed = try DictionaryImporter.parse(exported)
        XCTAssertEqual(parsed.entries.first { $0.word == "come" }?.languageHint, "it")
        XCTAssertNil(parsed.entries.first { $0.word == "run" }?.languageHint)

        // Merge у порожній словник.
        let mergeFixture = try TransferFixture()
        defer { mergeFixture.remove() }
        try await mergeFixture.seed([])
        let mergeURL = try mergeFixture.writeImportFile(exported)
        let mergeReport = try await mergeFixture.service.importDictionary(from: mergeURL, mode: .merge)
        XCTAssertEqual(mergeReport.added, 2)
        let stored8 = await mergeFixture.repository.entry(id: hinted.id)
        XCTAssertEqual(stored8?.languageHint, "it")
        let stored9 = await mergeFixture.repository.entry(id: plain.id)
        XCTAssertNil(stored9?.languageHint)
        let mergedOnDisk = try mergeFixture.store.load().file.entries
        XCTAssertEqual(mergedOnDisk.first { $0.id == hinted.id }?.languageHint, "it")

        // Replace.
        let replaceFixture = try TransferFixture()
        defer { replaceFixture.remove() }
        try await replaceFixture.seed([M4.entry(word: "dog")])
        let replaceURL = try replaceFixture.writeImportFile(exported)
        _ = try await replaceFixture.service.importDictionary(from: replaceURL, mode: .replace)
        let stored10 = await replaceFixture.repository.entry(id: hinted.id)
        XCTAssertEqual(stored10?.languageHint, "it")

        // Імпортований pending-запис з підказкою обробляється з нею (той самий `EntryProcessor`, напр. на Mac).
        let stack = try await makeStack(seed: [hinted])
        MockURLProtocol.setReplies([ClaudeFixtures.ok(Self.comeItalianJSON)])
        let results = await stack.queue.processAll(ignoringBackoff: true)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(Self.occurrences(of: Self.italianHint, in: M7.systemText(request)), 1)
        let stored11 = await stack.repository.entry(id: hinted.id)
        XCTAssertNil(stored11?.languageHint)
    }

    func testHintDoesNotCreateSpuriousConflict() async throws {
        let id = Self.fixedID(7)
        // Mac-копія без підказки і iPhone-копія з нею: той самий id/word/updatedAt.
        let macCopy = M4.entry(id: id, word: "come", status: .pending, created: 0, updated: 10)
        var phoneCopy = macCopy
        phoneCopy.languageHint = "it"
        XCTAssertNotEqual(macCopy, phoneCopy, "synthesized Entry == takes languageHint into account")

        // 1) Рівний updatedAt, імпорт із підказкою → skipped, локальний без змін.
        do {
            let result = ImportMerger.merge(local: [macCopy], imported: [phoneCopy])
            XCTAssertEqual(result.report.added, 0)
            XCTAssertEqual(result.report.updated, 0)
            XCTAssertEqual(result.report.skipped, 1)
            XCTAssertEqual(result.entries, [macCopy])
            XCTAssertNil(result.entries.first?.languageHint)
        }
        // 1b) Навпаки: локальна з підказкою, імпорт без → skipped, локальна підказка лишається.
        do {
            let result = ImportMerger.merge(local: [phoneCopy], imported: [macCopy])
            XCTAssertEqual(result.report.added, 0)
            XCTAssertEqual(result.report.updated, 0)
            XCTAssertEqual(result.report.skipped, 1)
            XCTAssertEqual(result.entries, [phoneCopy])
            XCTAssertEqual(result.entries.first?.languageHint, "it")
        }
        // 1c) Збіг за ключем (інший id), рівний updatedAt → теж skipped.
        do {
            var otherID = phoneCopy
            otherID.id = Self.fixedID(8)
            let result = ImportMerger.merge(local: [macCopy], imported: [otherID])
            XCTAssertEqual(result.report, ImportReport(added: 0, updated: 0, skipped: 1,
                                                       skippedReasons: result.report.skippedReasons))
            XCTAssertEqual(result.entries, [macCopy])
        }
        // 1d) Ready-копії (підказку на одній з них ще не очищено) → skipped.
        do {
            let readyMac = M4.entry(id: id, word: "come", created: 0, updated: 10)
            var readyPhone = readyMac
            readyPhone.languageHint = "it"
            let result = ImportMerger.merge(local: [readyMac], imported: [readyPhone])
            XCTAssertEqual(result.report.added, 0)
            XCTAssertEqual(result.report.updated, 0)
            XCTAssertEqual(result.report.skipped, 1)
            XCTAssertEqual(result.entries, [readyMac])
        }

        // 2) Новіший імпорт із підказкою → звичайна заміна D1, підказка переможця.
        do {
            var newerPhone = phoneCopy
            newerPhone.updatedAt = M4.date(20)
            let result = ImportMerger.merge(local: [macCopy], imported: [newerPhone])
            XCTAssertEqual(result.report.added, 0)
            XCTAssertEqual(result.report.updated, 1)
            XCTAssertEqual(result.report.skipped, 0)
            XCTAssertEqual(result.entries.count, 1)
            XCTAssertEqual(result.entries.first?.languageHint, "it")
            XCTAssertEqual(result.entries.first?.updatedAt, M4.date(20))
            XCTAssertEqual(result.entries.first?.id, id)
        }
        // 3) Новіший імпорт без підказки над локальною з підказкою → заміна, підказка переможця (nil).
        do {
            var newerMac = macCopy
            newerMac.updatedAt = M4.date(20)
            let result = ImportMerger.merge(local: [phoneCopy], imported: [newerMac])
            XCTAssertEqual(result.report.updated, 1)
            XCTAssertEqual(result.report.skipped, 0)
            XCTAssertNil(result.entries.first?.languageHint)
            XCTAssertEqual(result.entries.first?.updatedAt, M4.date(20))
        }

        // 4) Через сервіс імпорту: рівний updatedAt → словник не перезаписується (байти без змін).
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try await fixture.seed([macCopy])
        let before = try fixture.dictionaryBytes()
        let url = try fixture.writeImportFile(try M4.fileData([phoneCopy]))
        let report = try await fixture.service.importDictionary(from: url, mode: .merge)
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(try fixture.dictionaryBytes(), before)
        let stored12 = await fixture.repository.entry(id: id)
        XCTAssertEqual(stored12, macCopy)

        // 5) Через сервіс: новіший → updated, підказка імпортованого.
        var newerPhone = phoneCopy
        newerPhone.updatedAt = M4.date(30)
        let newerURL = try fixture.writeImportFile(try M4.fileData([newerPhone]), name: "newer.json")
        let newerReport = try await fixture.service.importDictionary(from: newerURL, mode: .merge)
        XCTAssertEqual(newerReport.updated, 1)
        XCTAssertEqual(newerReport.skipped, 0)
        let stored13 = await fixture.repository.entry(id: id)
        XCTAssertEqual(stored13?.languageHint, "it")
        XCTAssertEqual(try fixture.store.load().file.entries.first?.languageHint, "it")
    }

    // MARK: - I2a.4 Токени

    func testHintedWordMakesExactlyOneRequest() async throws {
        let stack = try await makeStack()
        MockURLProtocol.setReplies([ClaudeFixtures.ok(Self.comeItalianJSON)])

        let outcome = await stack.addWord.execute(rawText: "come", sourceLanguageHint: "it")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(Self.occurrences(of: Self.italianHint, in: M7.systemText(request)), 1)
        XCTAssertTrue(M7.systemText(request).contains("\"variants\""), "same combined prompt")
        XCTAssertEqual(M7.selection(request), "come")
        XCTAssertEqual(entry.sourceLanguage, "it")
        XCTAssertEqual(entry.word, "how")
        XCTAssertEqual(entry.variants?["it"]?.word, "come")
        XCTAssertEqual(entry.variants?["it"]?.status, .ready)

        // Подальше перемикання на IT — без запитів (D28).
        let report = await stack.backfill.backfill(pairID: "en-uk", languageID: "it", ignoringBackoff: true)
        XCTAssertEqual(report.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        // Повторне додавання того самого слова з підказкою — дубль, 0 запитів.
        let again = await stack.addWord.execute(rawText: "come", sourceLanguageHint: "it")
        guard case .duplicate = again else { return XCTFail("expected .duplicate, got \(again)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testSpokenItalianDuplicateOfReadyVariantMakesNoRequest() async throws {
        let house = M7.entry(id: Self.fixedID(1), word: "house",
                             variants: ["it": M7.readyVariant("casa", sourceWord: "house")])
        let englishCome = M7.entry(id: Self.fixedID(2), word: "come")
        let stack = try await makeStack(seed: [house, englishCome])
        MockURLProtocol.setReplies([ClaudeFixtures.ok(Self.comeItalianJSON)])

        // Італійське «casa» уже є як ready-варіант → дубль, 0 запитів.
        let casa = await stack.addWord.execute(rawText: "casa", sourceLanguageHint: "it")
        guard case .duplicate(let existing) = casa else { return XCTFail("expected .duplicate, got \(casa)") }
        XCTAssertEqual(existing.id, house.id)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)

        // Наслідок D26: італійське «come» при наявному англійському «come» → дубль, 0 запитів.
        let come = await stack.addWord.execute(rawText: "come", sourceLanguageHint: "it")
        guard case .duplicate(let existingCome) = come else { return XCTFail("expected .duplicate, got \(come)") }
        XCTAssertEqual(existingCome.id, englishCome.id)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)

        // Наявні записи не змінено (підказка дубля нікуди не записується).
        XCTAssertEqual(try stack.entriesOnDisk().count, 2)
        XCTAssertNil(try stack.entryOnDisk(house.id)?.languageHint)
        XCTAssertNil(try stack.entryOnDisk(englishCome.id)?.languageHint)
    }
}

private extension Entry {
    func withID(_ id: UUID) -> Entry {
        var copy = self
        copy.id = id
        return copy
    }
}
