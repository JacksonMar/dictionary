import Foundation
import XCTest
@testable import VocabCore

/// M7.4 — дедуплікація в обох мовах (D26, D27): три різні правила для add / update / setVariants.
final class CrossLanguageDedupTests: XCTestCase {
    private var stack: M7Stack?
    private var queueHarness: QueueHarness?

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        stack?.remove()
        queueHarness?.remove()
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeStack(seed: [Entry]) async throws -> M7Stack {
        let made = try await M7Stack.make(seed: seed)
        stack = made
        return made
    }

    private var houseWithCasa: Entry {
        M7.entry(word: "house", translations: ["будинок"],
                 variants: ["it": M7.readyVariant("casa", sourceWord: "house", translations: ["дім"])])
    }

    /// Результат комбінованого lookup для виділення «casa» (італійське).
    private var casaLookupResult: LookupResult {
        LookupResult(
            word: "house", lemma: "house", partOfSpeech: "noun", transcription: "/haʊs/",
            translations: ["будинок"], example: Example(source: "A house.", translation: "Будинок."),
            sourceLanguage: "it",
            variants: ["it": LookupResult(
                word: "casa", lemma: "casa", partOfSpeech: "noun", transcription: "/ˈkaːza/",
                translations: ["дім"], example: Example(source: "Una casa.", translation: "Дім.")
            )]
        )
    }

    // MARK: - add (D26)

    func testItalianSelectionMatchesExistingItalianVariant() async throws {
        let house = houseWithCasa
        let stack = try await makeStack(seed: [house])
        MockURLProtocol.setReplies([ClaudeFixtures.ok(M7.casaItalianJSON)])

        let outcome = await stack.addWord.execute(rawText: "Casa")

        XCTAssertEqual(outcome, .duplicate(house))
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertEqual(try stack.entriesOnDisk(), [house])
        let notification = NotificationText.make(for: outcome)
        XCTAssertEqual(notification.title, "Вже є в словнику")
    }

    func testEnglishSelectionMatchesExisting() async throws {
        let house = houseWithCasa
        let stack = try await makeStack(seed: [house])

        let outcome = await stack.addWord.execute(rawText: "House!")

        XCTAssertEqual(outcome, .duplicate(house))
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertEqual(try stack.entriesOnDisk().count, 1)
    }

    func testPendingVariantNotUsedForDedup() async throws {
        let house = M7.entry(word: "house", variants: ["it": M7.unfilledVariant(.pending, sourceWord: "house", word: "casa")])
        let stack = try await makeStack(seed: [house])

        let found = await stack.repository.findDuplicate(of: "casa", languagePair: "en-uk")
        XCTAssertNil(found)
        let added = try await stack.repository.add(EntryDraft(word: "casa", languagePair: "en-uk", status: .pending))
        XCTAssertEqual(added.word, "casa")
        let failedVariant = M7.entry(word: "dog", variants: ["it": M7.unfilledVariant(.failed, sourceWord: "dog", word: "cane")])
        _ = try await stack.repository.replaceAll(await stack.repository.allEntries() + [failedVariant])
        let noCane = await stack.repository.findDuplicate(of: "cane", languagePair: "en-uk")
        XCTAssertNil(noCane)
    }

    func testStaleVariantNotUsedForDedup() async throws {
        // Варіант згенеровано для «house», але слово запису вже «home» → stale, не ключ дубля.
        let home = M7.entry(word: "home", variants: ["it": M7.readyVariant("casa", sourceWord: "house")])
        let stack = try await makeStack(seed: [home])

        let found = await stack.repository.findDuplicate(of: "casa", languagePair: "en-uk")
        XCTAssertNil(found)
        let added = try await stack.repository.add(EntryDraft(word: "casa", languagePair: "en-uk", status: .pending))
        XCTAssertEqual(added.word, "casa")
    }

    func testDedupScopedToLanguagePair() async throws {
        let other = M7.entry(pair: "xx-yy", word: "house", variants: ["it": M7.readyVariant("casa", sourceWord: "house")])
        let stack = try await makeStack(seed: [other])
        let found = await stack.repository.findDuplicate(of: "casa", languagePair: "en-uk")
        XCTAssertNil(found)
        let foundOther = await stack.repository.findDuplicate(of: "casa", languagePair: "xx-yy")
        XCTAssertEqual(foundOther?.id, other.id)
    }

    // MARK: - after response (D27)

    func testPostResponseDuplicateRemovesPendingAndReturnsExisting() async throws {
        let harness = try await QueueHarness.make([.success(casaLookupResult)],
                                                  registry: LanguagePairRegistry(pairs: [.englishUkrainian]))
        queueHarness = harness
        // Наявний запис «house» без італійського варіанта; нове виділення «casa» до відповіді не є дублем.
        let house = try await harness.repository.add(EntryDraft(
            word: "house", languagePair: "en-uk", translations: ["будинок"], status: .ready
        ))
        let pending = try await harness.addPending("casa")

        let result = await harness.queue.retry(entryID: pending.id)

        guard case .duplicate(let existing, let removedID) = result else {
            return XCTFail("expected .duplicate, got \(result)")
        }
        XCTAssertEqual(existing.id, house.id)
        XCTAssertEqual(removedID, pending.id)
        let removed = await harness.entry(pending.id)
        XCTAssertNil(removed, "pending duplicate entry removed")
        let all = await harness.repository.allEntries()
        XCTAssertEqual(all.map(\.id), [house.id])
        XCTAssertEqual(harness.lookup.callCount, 1)
        // Черга забула про видалений запис.
        let attempts = await harness.queue.attemptCount(for: pending.id)
        XCTAssertEqual(attempts, 0)
        let next = await harness.queue.nextAttempt(for: pending.id)
        XCTAssertNil(next)
        // Повторна обробка — notFound, не новий lookup.
        let again = await harness.queue.retry(entryID: pending.id)
        XCTAssertEqual(again, .notFound(pending.id))
        XCTAssertEqual(harness.lookup.callCount, 1)
    }

    func testPostResponseDuplicateViaItalianKeyOfOtherConcept() async throws {
        // Наявний запис «home» з ready-варіантом «casa»; нова відповідь «house»/«casa» → дубль за італійським
        // ключем, але інше англійське поняття → варіанти наявного не змінюються.
        let harness = try await QueueHarness.make([.success(casaLookupResult)],
                                                  registry: LanguagePairRegistry(pairs: [.englishUkrainian]))
        queueHarness = harness
        let home = M7.entry(word: "home", variants: ["it": M7.readyVariant("casa", sourceWord: "home")])
        try await harness.repository.replaceAll([home])
        // Додаємо pending «casa» в обхід add (у add «casa» вже дубль за ключем варіанта).
        var pending = M7.entry(word: "casa", status: .pending, created: 10)
        pending.id = UUID()
        try await harness.repository.replaceAll([home, pending])

        let result = await harness.processor.process(entryID: pending.id, attempts: 0)

        XCTAssertEqual(result, .duplicate(existing: home, removedID: pending.id))
        let all = await harness.repository.allEntries()
        XCTAssertEqual(all, [home])
    }

    func testPostResponseDuplicateFillsMissingVariantOfExisting() async throws {
        // «house» без італійських даних; виділення «casa» → 1 запит, дубль, варіант заповнено з тієї ж відповіді.
        let house = M7.entry(word: "house", translations: ["будинок"], created: -100)
        let stack = try await makeStack(seed: [house])
        MockURLProtocol.setReplies([ClaudeFixtures.ok(M7.casaItalianJSON)])

        let outcome = await stack.addWord.execute(rawText: "casa")

        guard case .duplicate(let existing) = outcome else { return XCTFail("expected .duplicate, got \(outcome)") }
        XCTAssertEqual(existing.id, house.id)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        let onDisk = try stack.entriesOnDisk()
        XCTAssertEqual(onDisk.map(\.id), [house.id], "pending entry removed")
        let stored = try XCTUnwrap(onDisk.first)
        XCTAssertEqual(stored.variants?["it"]?.word, "casa")
        XCTAssertEqual(stored.variants?["it"]?.status, .ready)
        XCTAssertEqual(stored.variants?["it"]?.sourceKey, "house")
        XCTAssertEqual(stored.translations, ["будинок"], "main fields of the existing entry untouched")
        XCTAssertEqual(stored.updatedAt, house.updatedAt, "variants do not change updatedAt (D24)")
        XCTAssertEqual(existing.variants?["it"]?.word, "casa", "outcome carries the filled entry")

        // 0 додаткових запитів: доповнення вже нема чого робити.
        let report = await stack.backfill.backfill(pairID: "en-uk", languageID: "it", ignoringBackoff: true)
        XCTAssertEqual(report.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testPostResponseDuplicateDoesNotOverwriteReadyVariantOfExisting() async throws {
        let house = M7.entry(word: "house", variants: ["it": M7.readyVariant("abitazione", sourceWord: "house")])
        let stack = try await makeStack(seed: [house])
        // Виділення «houses» до відповіді не дубль; відповідь має той самий італійський ready-варіант.
        let reply = M7.combinedJSON(sourceLanguage: "en", top: M7.object(word: "houses"),
                                    variants: ["it": M7.object(word: "abitazione")])
        MockURLProtocol.setReplies([ClaudeFixtures.ok(reply)])

        let outcome = await stack.addWord.execute(rawText: "houses")

        // «houses» ≠ «house», але ready-варіант «abitazione» збігся → дубль; варіант наявного не змінено.
        guard case .duplicate(let existing) = outcome else { return XCTFail("expected .duplicate, got \(outcome)") }
        XCTAssertEqual(existing, house)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(try stack.entriesOnDisk(), [house])
    }

    func testConcurrentSameItalianWordAddedOnce() async throws {
        let gate = Gate()
        let harness = try await QueueHarness.make([.success(casaLookupResult)], gate: gate,
                                                  registry: LanguagePairRegistry(pairs: [.englishUkrainian]))
        queueHarness = harness
        let useCase = AddWordUseCase(
            repository: harness.repository,
            processor: harness.queue,
            settings: InMemorySettingsStore(),
            registry: LanguagePairRegistry(pairs: [.englishUkrainian])
        )

        let first = Task { await useCase.execute(rawText: "casa") }
        await waitUntil { harness.lookup.callCount == 1 }
        let second = await useCase.execute(rawText: "Casa")
        gate.open()
        let firstOutcome = await first.value

        guard case .added(let added) = firstOutcome else { return XCTFail("expected .added, got \(firstOutcome)") }
        guard case .duplicate(let duplicate) = second else { return XCTFail("expected .duplicate, got \(second)") }
        XCTAssertEqual(duplicate.id, added.id)
        XCTAssertEqual(harness.lookup.callCount, 1)
        let all = await harness.repository.allEntries()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.variants?["it"]?.word, "casa")

        // Після відповіді — третє виділення «casa» відсікається за італійським ключем без lookup.
        let third = await useCase.execute(rawText: "casa")
        XCTAssertEqual(third, .duplicate(all[0]))
        XCTAssertEqual(harness.lookup.callCount, 1)
    }

    // MARK: - update / setVariants

    func testEditEnglishEntryNotBlockedByOtherItalianVariant() async throws {
        let house = houseWithCasa
        let other = M7.entry(word: "home", created: 10)
        let stack = try await makeStack(seed: [house, other])

        var edited = other
        edited.word = "casa"
        let updated = try await stack.repository.update(edited)

        XCTAssertEqual(updated.word, "casa")
        XCTAssertEqual(try stack.entriesOnDisk().map(\.word).sorted(), ["casa", "house"])
    }

    func testUpdateChecksDuplicateOnlyWhenKeyChanged() async throws {
        // Два записи з тим самим ключем (напр., після старого імпорту) — редагування без зміни слова не блокується.
        let first = M7.entry(word: "run", created: 0)
        let second = M7.entry(word: "Run", created: 10)
        let third = M7.entry(word: "walk", created: 20)
        let stack = try await makeStack(seed: [first, second, third])

        var edited = second
        edited.translations = ["бігати"]
        let saved = try await stack.repository.update(edited)
        XCTAssertEqual(saved.translations, ["бігати"])

        var renamed = third
        renamed.word = "RUN"
        do {
            _ = try await stack.repository.update(renamed)
            XCTFail("expected duplicate")
        } catch RepositoryError.duplicate(let existing) {
            XCTAssertEqual(TextNormalizer.key(existing.word), "run")
        }
    }

    func testSetVariantsNeverBlockedByDuplicates() async throws {
        let house = houseWithCasa
        let home = M7.entry(word: "home", created: 10)
        let stack = try await makeStack(seed: [house, home])

        let applied = try await stack.repository.setVariants([
            VariantUpdate(entryID: home.id, languageID: "it", variant: M7.readyVariant("casa", sourceWord: "home")),
        ])

        XCTAssertEqual(applied.map(\.id), [home.id])
        let stored = try XCTUnwrap(stack.entryOnDisk(home.id))
        XCTAssertEqual(stored.variants?["it"]?.word, "casa")
        XCTAssertEqual(stored.updatedAt, home.updatedAt)

        // update(replacingVariants: true) теж не перевіряє варіанти.
        var replaced = house
        replaced.variants = ["it": M7.readyVariant("casa", sourceWord: "house")]
        let saved = try await stack.repository.update(replaced, replacingVariants: true)
        XCTAssertEqual(saved.variants?["it"]?.word, "casa")
    }

    func testSetVariantsSkipsStaleAndMissingEntries() async throws {
        let run = M7.entry(word: "run")
        let stack = try await makeStack(seed: [run])

        let applied = try await stack.repository.setVariants([
            VariantUpdate(entryID: run.id, languageID: "it", variant: M7.readyVariant("correre", sourceWord: "sprint")),
            VariantUpdate(entryID: UUID(), languageID: "it", variant: M7.readyVariant("x", sourceWord: "x")),
        ])
        XCTAssertEqual(applied, [])
        XCTAssertNil(try stack.entryOnDisk(run.id)?.variants)
    }
}
