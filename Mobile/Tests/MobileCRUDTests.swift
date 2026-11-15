// I1b.1 (IOS_PLAN §7, §5): manual add (ready, 0 requests), edit keeps variants, delete, retry = one queue call,
// variant backfill only in the Italian display mode. Real `AppContainer` over a temporary directory; HTTP through
// `MockURLProtocol` so every request is counted.
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

final class MobileCRUDTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    @MainActor
    private func makeModel(
        entries: [Entry] = [],
        directory: URL? = nil,
        settings: SettingsStore = InMemorySettingsStore(),
        withKey: Bool = true
    ) async throws -> MobileAppModel {
        let directory = directory ?? makeTemporaryDirectory(self)
        if !entries.isEmpty {
            try writeDictionary(entries, to: directory)
        }
        let secrets = InMemorySecretStore(values: withKey ? [.anthropicAPIKey: MobileClaudeFixtures.apiKey] : [:])
        let container = AppContainer(
            baseDirectory: directory,
            settings: settings,
            secrets: secrets,
            transport: MockURLProtocol.makeTransport()
        )
        let model = MobileAppModel(container: container)
        await model.start()
        XCTAssertTrue(model.isLoaded)
        return model
    }

    /// Entries as stored on disk (fresh repository over the same directory).
    private func entriesOnDisk(_ directory: URL) throws -> [Entry] {
        let paths = AppPaths(applicationSupportDirectory: directory)
        let data = try Data(contentsOf: paths.dictionaryURL)
        return try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: data).entries
    }

    @MainActor
    private func runner(_ model: MobileAppModel) -> NoopBackgroundTaskRunner? {
        model.container.backgroundTasks as? NoopBackgroundTaskRunner
    }

    private func italianReady(_ word: String, for source: String) -> EntryVariant {
        EntryVariant(
            word: word,
            transcription: "/it/",
            translations: ["італійський переклад"],
            example: Example(source: "Frase.", translation: "Речення."),
            status: .ready,
            sourceKey: TextNormalizer.key(source)
        )
    }

    // MARK: - I1b.1 required

    @MainActor
    func testManualAddReady() async throws {
        let directory = makeTemporaryDirectory(self)
        let model = try await makeModel(directory: directory)

        var form = EntryForm(word: "  apple ")
        form.translations = "яблуко, плід;  ; фрукт"
        form.transcription = "/ˈæp.əl/"
        form.exampleSource = "An apple a day."
        form.exampleTranslation = "Яблуко на день."
        XCTAssertTrue(form.canSave)
        let draft = form.makeDraft(languagePair: model.languagePairID)
        XCTAssertEqual(draft.status, .ready)

        let created = await model.addManual(draft)

        let entry = try XCTUnwrap(created, "operationError: \(model.operationError ?? "nil")")
        XCTAssertNil(model.operationError)
        XCTAssertEqual(entry.word, "apple")
        XCTAssertEqual(entry.status, .ready)
        XCTAssertEqual(entry.languagePair, LanguagePair.englishUkrainian.id)
        XCTAssertEqual(entry.translations, ["яблуко", "плід", "фрукт"])
        XCTAssertEqual(entry.transcription, "/ˈæp.əl/")
        XCTAssertEqual(entry.example, Example(source: "An apple a day.", translation: "Яблуко на день."))
        XCTAssertEqual(model.entries.map(\.id), [entry.id], "model sees the new entry right after the await")
        XCTAssertEqual(model.visibleRows.first?.word, "apple")
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "manual add must not call Claude")

        let onDisk = try entriesOnDisk(directory)
        XCTAssertEqual(onDisk.map(\.id), [entry.id])
        XCTAssertEqual(onDisk.first?.status, .ready)

        // `ready` without translations is rejected (import validation, §10) — nothing saved.
        var noTranslation = EntryForm(word: "pear")
        noTranslation.translations = " , "
        let rejected = await model.addManual(noTranslation.makeDraft(languagePair: model.languagePairID))
        XCTAssertNil(rejected)
        XCTAssertEqual(model.operationError, L10n.text(.inputAddTranslation))
        XCTAssertEqual(model.consumeOperationError(), L10n.text(.inputAddTranslation))
        XCTAssertNil(model.operationError)

        // Empty word.
        var empty = EntryForm(word: "   ")
        empty.translations = "щось"
        XCTAssertFalse(empty.canSave)
        let emptyResult = await model.addManual(empty.makeDraft(languagePair: model.languagePairID))
        XCTAssertNil(emptyResult)
        XCTAssertEqual(model.operationError, L10n.text(.inputEnterWord))

        // Duplicate (other case) — error, nothing saved.
        var duplicate = EntryForm(word: "Apple")
        duplicate.translations = "яблуко"
        let duplicateResult = await model.addManual(duplicate.makeDraft(languagePair: model.languagePairID))
        XCTAssertNil(duplicateResult)
        XCTAssertNotNil(model.operationError)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(try entriesOnDisk(directory).count, 1)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    @MainActor
    func testEditKeepsVariants() async throws {
        let directory = makeTemporaryDirectory(self)
        var house = makeTestEntry(
            "house",
            translations: ["будинок"],
            transcription: "/haʊs/",
            createdOffset: 0,
            variants: ["it": italianReady("casa", for: "house")]
        )
        house.sourceLanguage = "it"
        let model = try await makeModel(entries: [house], directory: directory)
        let original = try XCTUnwrap(model.entry(id: house.id))

        var form = EntryForm(entry: original)
        XCTAssertEqual(form.word, "house")
        XCTAssertEqual(form.translations, "будинок")
        form.translations = "будинок, дім, оселя"
        form.partOfSpeech = "noun"
        form.exampleSource = "This is my house."
        form.exampleTranslation = "Це мій будинок."

        let updated = await model.update(form.applied(to: original))

        let saved = try XCTUnwrap(updated, "operationError: \(model.operationError ?? "nil")")
        XCTAssertNil(model.operationError)
        XCTAssertEqual(saved.id, house.id)
        XCTAssertEqual(saved.translations, ["будинок", "дім", "оселя"])
        XCTAssertEqual(saved.partOfSpeech, "noun")
        XCTAssertEqual(saved.example?.source, "This is my house.")
        XCTAssertEqual(saved.status, .ready)
        XCTAssertEqual(saved.variants, house.variants, "edit must keep the Italian variant")
        XCTAssertEqual(saved.readyVariant("it")?.word, "casa")
        XCTAssertEqual(saved.sourceLanguage, "it", "edit must keep sourceLanguage")
        XCTAssertEqual(model.entry(id: house.id)?.translations, ["будинок", "дім", "оселя"])

        let onDisk = try XCTUnwrap(try entriesOnDisk(directory).first { $0.id == house.id })
        XCTAssertEqual(onDisk.translations, ["будинок", "дім", "оселя"])
        XCTAssertEqual(onDisk.variants, house.variants)
        XCTAssertEqual(onDisk.sourceLanguage, "it")

        // Even an entry value with the variants stripped does not erase them (`update(_:)` ignores variants, §6).
        var stripped = saved
        stripped.variants = nil
        stripped.sourceLanguage = nil
        stripped.translations = ["дім"]
        let againResult = await model.update(stripped)
        let again = try XCTUnwrap(againResult)
        XCTAssertEqual(again.variants, house.variants)
        XCTAssertEqual(again.sourceLanguage, "it")
        XCTAssertEqual(again.translations, ["дім"])

        // Invalid edits are rejected: empty word, ready without translations.
        var emptyWord = again
        emptyWord.word = "  "
        let emptyResult = await model.update(emptyWord)
        XCTAssertNil(emptyResult)
        XCTAssertEqual(model.operationError, L10n.text(.inputEnterWord))
        var noTranslations = again
        noTranslations.translations = []
        let noTranslationsResult = await model.update(noTranslations)
        XCTAssertNil(noTranslationsResult)
        XCTAssertEqual(model.operationError, L10n.text(.inputAddTranslation))
        XCTAssertEqual(model.entry(id: house.id)?.translations, ["дім"])
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "editing must not call Claude")
    }

    @MainActor
    func testDeleteRemovesEntry() async throws {
        let directory = makeTemporaryDirectory(self)
        let house = makeTestEntry("house", translations: ["будинок"], createdOffset: 0)
        let tree = makeTestEntry("tree", translations: ["дерево"], createdOffset: 5)
        let model = try await makeModel(entries: [house, tree], directory: directory)

        let deleted = await model.delete(id: house.id)

        XCTAssertTrue(deleted)
        XCTAssertNil(model.operationError)
        XCTAssertNil(model.entry(id: house.id))
        XCTAssertEqual(model.entries.map(\.id), [tree.id])
        XCTAssertEqual(model.visibleRows.map(\.word), ["tree"])
        XCTAssertEqual(try entriesOnDisk(directory).map(\.id), [tree.id])

        // Unknown id → false + error, nothing else touched.
        let missing = await model.delete(id: UUID())
        XCTAssertFalse(missing)
        XCTAssertNotNil(model.operationError)
        XCTAssertEqual(model.entries.map(\.id), [tree.id])

        // Deleting the last entry → empty state.
        model.operationError = nil
        let last = await model.delete(id: tree.id)
        XCTAssertTrue(last)
        XCTAssertTrue(model.isDictionaryEmpty)
        XCTAssertEqual(try entriesOnDisk(directory).count, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    @MainActor
    func testRetryCallsProcessorOnce() async throws {
        let failed = makeTestEntry("house", status: .failed, createdOffset: 0)
        let pending = makeTestEntry("tree", status: .pending, createdOffset: 5)
        let ready = makeTestEntry("apple", translations: ["яблуко"], createdOffset: 10)
        let model = try await makeModel(entries: [failed, pending, ready])
        XCTAssertTrue(model.hasRetryableEntries)

        // Leading swipe: retry for pending/failed, nothing for ready in EN mode.
        let rows = Dictionary(uniqueKeysWithValues: model.visibleRows.map { ($0.id, $0) })
        XCTAssertEqual(model.leadingAction(for: try XCTUnwrap(rows[failed.id])), .retry)
        XCTAssertEqual(model.leadingAction(for: try XCTUnwrap(rows[pending.id])), .retry)
        XCTAssertNil(model.leadingAction(for: try XCTUnwrap(rows[ready.id])))

        // Two taps on «Retry» while the first request is still in flight → one queue call, one HTTP request.
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        MockURLProtocol.setDelay(0.3)
        async let first = model.retry(id: failed.id)
        async let second = model.retry(id: failed.id)
        let results = await [first, second]

        XCTAssertEqual(MockURLProtocol.requestCount, 1, "retry must call the processor exactly once")
        let nonNil = results.compactMap { $0 }
        XCTAssertEqual(nonNil.count, 1, "second concurrent retry must be ignored: \(results)")
        guard case .ready(let entry)? = nonNil.first else {
            return XCTFail("expected .ready, got \(String(describing: nonNil.first))")
        }
        XCTAssertEqual(entry.id, failed.id)
        XCTAssertEqual(model.entry(id: failed.id)?.status, .ready)
        XCTAssertEqual(model.entry(id: failed.id)?.translations, ["будинок", "дім"])
        XCTAssertTrue(model.retryingIDs.isEmpty)
        // Only the retried entry was processed; the other pending entry waits.
        XCTAssertEqual(model.entry(id: pending.id)?.status, .pending)

        // A single retry of the pending entry → exactly one more request.
        MockURLProtocol.setDelay(0)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.combinedJSON(
            word: "tree", translations: ["дерево"], italian: "albero", italianTranslations: ["дерево"]
        ))])
        let treeResult = await model.retry(id: pending.id)
        guard case .ready? = treeResult else { return XCTFail("expected .ready, got \(String(describing: treeResult))") }
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        XCTAssertFalse(model.hasRetryableEntries)

        // Retrying a ready entry does nothing (skipped, 0 requests).
        let skipped = await model.retry(id: ready.id)
        if case .skipped? = skipped {} else { XCTFail("expected .skipped, got \(String(describing: skipped))") }
        XCTAssertEqual(MockURLProtocol.requestCount, 2)

        // Background tasks balanced (DI18).
        let runner = try XCTUnwrap(runner(model))
        XCTAssertTrue(runner.activeTokens.isEmpty)
        XCTAssertEqual(runner.startedNames.filter { $0 == "VocabRetry" }.count, 3)
    }

    @MainActor
    func testBackfillOnlyInItalianMode() async throws {
        // Two old ready entries without an Italian variant → eligible for backfill.
        let house = makeTestEntry("house", translations: ["будинок"], createdOffset: 0)
        let tree = makeTestEntry("tree", translations: ["дерево"], createdOffset: 5)
        let settings = InMemorySettingsStore()
        let model = try await makeModel(entries: [house, tree], settings: settings)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.batchJSON(count: 2))])

        // EN mode: activation, foreground processing and key-saved processing never backfill.
        XCTAssertNil(model.displayLanguageID)
        await model.becameActive()
        await model.processPending(trigger: .foreground)
        await model.processPending(trigger: .keySaved)
        await model.runBackfill(trigger: .foreground)
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "no backfill in source-language mode")
        XCTAssertNil(model.lastBackfillReport)
        XCTAssertNil(model.setDisplayLanguage(nil), "switching to EN starts no backfill")
        XCTAssertNil(model.setDisplayLanguage("de"), "unknown language → source mode, no backfill")
        XCTAssertNil(model.displayLanguageID)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)

        // Switch to IT → one batch request for both entries.
        let task = try XCTUnwrap(model.setDisplayLanguage("it"))
        await task.value
        XCTAssertEqual(settings.displayLanguageID, "it")
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "ceil(2/15) = 1 batch request")
        let report = try XCTUnwrap(model.lastBackfillReport)
        XCTAssertEqual(report.eligible, 2)
        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(model.entry(id: house.id)?.variantState("it"), .ready)
        XCTAssertEqual(model.entry(id: tree.id)?.variantState("it"), .ready)

        // IT again / foreground in IT mode: nothing eligible → 0 requests.
        await model.becameActive()
        let again = model.setDisplayLanguage("it")
        await again?.value
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(model.lastBackfillReport?.eligible, 0)

        // `.modelChanged` never backfills even in IT mode (only `backfillTriggers`).
        XCTAssertEqual(MobileAppModel.backfillTriggers, [.foreground, .keySaved])

        // Leading swipe on a ready row in IT mode → «Update Italian».
        let row = try XCTUnwrap(model.visibleRows.first { $0.id == house.id })
        XCTAssertEqual(model.leadingAction(for: row), .refreshVariant(languageID: "it"))

        // Explicit «Update Italian» → exactly one request even with a ready variant.
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.batchJSON(count: 1))])
        let refresh = await model.refreshVariant(id: house.id)
        XCTAssertEqual(refresh?.requests, 1)
        XCTAssertEqual(MockURLProtocol.requestCount, 2)

        let runner = try XCTUnwrap(runner(model))
        XCTAssertTrue(runner.activeTokens.isEmpty)
    }

    @MainActor
    func testBackfillOnForegroundWhenStartedInItalianMode() async throws {
        let house = makeTestEntry("house", translations: ["будинок"], createdOffset: 0)
        let model = try await makeModel(entries: [house], settings: InMemorySettingsStore(displayLanguageID: "it"))
        XCTAssertEqual(model.displayLanguageID, "it")
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.batchJSON(count: 1))])

        await model.becameActive()

        XCTAssertEqual(MockURLProtocol.requestCount, 1, "IT mode: first activation (.foreground) backfills")
        XCTAssertEqual(model.entry(id: house.id)?.variantState("it"), .ready)
        await model.becameActive()
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "repeated activation: 0 eligible → 0 requests")
    }
}
