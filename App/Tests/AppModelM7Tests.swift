import Foundation
import XCTest
import VocabCore
@testable import VocabApp

/// `VariantBatchLookupService` з лічильником викликів і записаними елементами; кожен елемент — ready
/// (`word` = `keepWord` або `<word>-it`).
private final class CountingVariantLookup: VariantBatchLookupService, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[VariantRequestItem]] = []

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recorded.count
    }

    var calls: [[VariantRequestItem]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ items: [VariantRequestItem]) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(items)
    }

    func lookupVariants(
        items: [VariantRequestItem],
        language: RenderingLanguage,
        pair: LanguagePair
    ) async throws -> [Int: VariantItemOutcome] {
        record(items)
        var result: [Int: VariantItemOutcome] = [:]
        for item in items {
            let word = item.keepWord ?? "\(item.word)-it"
            result[item.ref] = .ready(LookupResult(
                word: word,
                lemma: word,
                partOfSpeech: "noun",
                transcription: "/it/",
                translations: ["італ-\(item.word)"],
                example: Example(source: "Frase.", translation: "Речення.")
            ))
        }
        return result
    }
}

/// Транспорт Messages API: на кожен запит — HTTP 200 з текстом моделі `text`.
private struct FixedTextTransport: HTTPTransport {
    let text: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.data(withJSONObject: [
            "id": "msg_test",
            "type": "message",
            "role": "assistant",
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
        ])
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["content-type": "application/json"]) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }
}

/// M7.10 — `AppModel`: перемикач EN | IT, збереження режиму, рендер в активній мові, одноразове доповнення.
final class AppModelM7Tests: XCTestCase {
    private static let reference = Date(timeIntervalSince1970: 1_791_885_600)

    private struct Fixture {
        let model: AppModel
        let repository: DictionaryRepository
        let lookup: CountingVariantLookup
        let settings: InMemorySettingsStore
    }

    private func entry(
        _ word: String,
        created: TimeInterval = 0,
        status: EntryStatus = .ready,
        variants: [String: EntryVariant]? = nil,
        sourceLanguage: String? = nil
    ) -> Entry {
        let date = Self.reference.addingTimeInterval(created)
        return Entry(
            languagePair: LanguagePairRegistry.defaultPairID,
            word: word,
            lemma: status == .ready ? word : nil,
            partOfSpeech: status == .ready ? "noun" : nil,
            transcription: status == .ready ? "/\(word)/" : nil,
            translations: status == .ready ? ["переклад-\(word)"] : [],
            status: status,
            createdAt: date,
            updatedAt: date,
            variants: variants,
            sourceLanguage: sourceLanguage
        )
    }

    private func readyVariant(_ word: String, for english: String) -> EntryVariant {
        EntryVariant(
            word: word,
            lemma: word,
            partOfSpeech: "noun",
            transcription: "/\(word)/",
            translations: ["італ-\(word)"],
            example: Example(source: "Vedo \(word).", translation: "Бачу \(word)."),
            status: .ready,
            sourceKey: TextNormalizer.key(english)
        )
    }

    /// Записи `w1…wN` без варіантів (`w1` найстаріший).
    private func seedEntries(_ count: Int) -> [Entry] {
        (0..<count).map { entry("w\($0 + 1)", created: TimeInterval($0)) }
    }

    /// - Parameters:
    ///   - withBackfill: передати `VariantBackfillProcessor` зі стабом-лічильником.
    ///   - claudeText: якщо задано — `ClaudeServices` з ключем і транспортом, що повертає цей текст моделі;
    ///     `withClaude` без тексту — транспорт з HTTP 400 (без мережі).
    @MainActor
    private func makeFixture(
        seed: [Entry] = [],
        settings: InMemorySettingsStore = InMemorySettingsStore(),
        withBackfill: Bool = true,
        withClaude: Bool = false,
        claudeText: String? = nil,
        directory reuse: URL? = nil
    ) async throws -> Fixture {
        let directory: URL
        if let reuse {
            directory = reuse
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("VocabAppM7Tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let paths = AppPaths(applicationSupportDirectory: directory)
        let dates = FixedDateProvider(Self.reference)
        let store = FileDictionaryStore(
            fileURL: paths.dictionaryURL,
            fileSystem: LocalFileSystem(),
            dateProvider: dates,
            backups: BackupManager(directory: paths.backupsDirectory, dateProvider: dates)
        )
        if !seed.isEmpty {
            try store.save(DictionaryFile(entries: seed))
        }
        let repository = DictionaryRepository(store: store, dateProvider: dates)
        let lookup = CountingVariantLookup()
        let backfill = withBackfill
            ? VariantBackfillProcessor(repository: repository, lookup: lookup, registry: .shared, dateProvider: dates)
            : nil
        var claude: ClaudeServices?
        if withClaude || claudeText != nil {
            let secrets = InMemorySecretStore()
            if claudeText != nil {
                try secrets.writeSecret("sk-ant-api03-TESTKEY-m7-app", for: .anthropicAPIKey)
            }
            let transport: HTTPTransport = claudeText.map { FixedTextTransport(text: $0) }
                ?? EchoErrorTransport(message: "no network in tests")
            claude = ClaudeServices.make(
                repository: repository,
                secrets: secrets,
                settings: settings,
                transport: transport,
                logSink: RecordingLogSink(),
                dateProvider: dates
            )
        }
        let model = AppModel(
            repository: repository,
            languagePairID: LanguagePairRegistry.defaultPairID,
            claude: claude,
            settings: settings,
            variantBackfill: backfill
        )
        await model.load()
        XCTAssertNil(model.loadError)
        return Fixture(model: model, repository: repository, lookup: lookup, settings: settings)
    }

    // MARK: - Режим

    @MainActor
    func testDisplayLanguagePersistsAcrossModelInstances() async throws {
        let settings = InMemorySettingsStore()
        let first = try await makeFixture(settings: settings, withBackfill: false)
        XCTAssertNil(first.model.displayLanguageID, "EN by default")
        XCTAssertEqual(first.model.renderings.map(\.id), ["it"])

        first.model.setDisplayLanguage("it")
        XCTAssertEqual(first.model.displayLanguageID, "it")
        XCTAssertEqual(first.model.displayLanguageSelection, "it")
        XCTAssertEqual(first.model.query.languageID, "it")
        XCTAssertEqual(first.model.activeRendering?.id, "it")
        XCTAssertEqual(settings.displayLanguageID, "it")

        let second = try await makeFixture(settings: settings, withBackfill: false)
        XCTAssertEqual(second.model.displayLanguageID, "it")
        XCTAssertEqual(second.model.query.languageID, "it")

        second.model.displayLanguageSelection = nil
        XCTAssertNil(settings.displayLanguageID)
        let third = try await makeFixture(settings: settings, withBackfill: false)
        XCTAssertNil(third.model.displayLanguageID)
        XCTAssertNil(third.model.query.languageID)
    }

    @MainActor
    func testUnknownStoredLanguageFallsBackToPrimary() async throws {
        let settings = InMemorySettingsStore(displayLanguageID: "de")
        let fixture = try await makeFixture(seed: seedEntries(2), settings: settings)
        XCTAssertNil(fixture.model.displayLanguageID)
        XCTAssertNil(fixture.model.query.languageID)
        XCTAssertNil(fixture.model.activeRendering)

        let task = fixture.model.setDisplayLanguage("de")
        XCTAssertNil(task, "unknown language → source language, no backfill")
        XCTAssertNil(fixture.model.displayLanguageID)
        XCTAssertNil(settings.displayLanguageID)
        XCTAssertEqual(fixture.lookup.callCount, 0)
    }

    // MARK: - Доповнення

    @MainActor
    func testSwitchToItalianTriggersBackfillOnce() async throws {
        let fixture = try await makeFixture(seed: seedEntries(20))

        let firstTask = try XCTUnwrap(fixture.model.setDisplayLanguage("it"))
        await firstTask.value
        XCTAssertEqual(fixture.lookup.callCount, 2, "20 entries → ceil(20/15) = 2 requests in one pass")
        XCTAssertEqual(fixture.model.lastBackfillReport?.requests, 2)
        XCTAssertEqual(fixture.model.lastBackfillReport?.ready, 20)
        XCTAssertFalse(fixture.model.isBackfilling)
        XCTAssertEqual(fixture.model.backfillableCount, 0)
        XCTAssertTrue(fixture.model.entries.allSatisfy { $0.variantState("it") == .ready })

        fixture.model.setDisplayLanguage(nil)
        let secondTask = try XCTUnwrap(fixture.model.setDisplayLanguage("it"))
        await secondTask.value
        XCTAssertEqual(fixture.lookup.callCount, 2, "second switch: 0 lookup calls")
        XCTAssertEqual(fixture.model.lastBackfillReport?.requests, 0)
    }

    @MainActor
    func testSwitchToEnglishDoesNotBackfill() async throws {
        let fixture = try await makeFixture(seed: seedEntries(3), settings: InMemorySettingsStore(displayLanguageID: "it"))
        XCTAssertEqual(fixture.model.displayLanguageID, "it")

        let task = fixture.model.setDisplayLanguage(nil)

        XCTAssertNil(task)
        XCTAssertNil(fixture.model.displayLanguageID)
        XCTAssertEqual(fixture.lookup.callCount, 0)
        XCTAssertFalse(fixture.model.isBackfillAvailable)
        await fixture.model.runBackfill(trigger: .displaySwitch)
        await fixture.model.backfillAll()
        XCTAssertEqual(fixture.lookup.callCount, 0, "no backfill in source-language mode")
    }

    @MainActor
    func testStartupInItalianModeBackfills() async throws {
        let italian = try await makeFixture(
            seed: seedEntries(3),
            settings: InMemorySettingsStore(displayLanguageID: "it"),
            withClaude: true
        )
        await italian.model.processPending(trigger: .startup)
        XCTAssertEqual(italian.lookup.callCount, 1)
        XCTAssertEqual(italian.model.lastBackfillReport?.ready, 3)

        // Таймер/зміна моделі не запускають доповнення.
        await italian.model.processPending(trigger: .modelChanged)
        await italian.model.processDue()
        XCTAssertEqual(italian.lookup.callCount, 1)

        let english = try await makeFixture(seed: seedEntries(3), withClaude: true)
        await english.model.processPending(trigger: .startup)
        await english.model.processPending(trigger: .network)
        XCTAssertEqual(english.lookup.callCount, 0, "EN mode: no backfill at startup")
    }

    @MainActor
    func testSwitchResetsPageToOne() async throws {
        let fixture = try await makeFixture(seed: seedEntries(60), withBackfill: false)
        fixture.model.pageNumber = 3

        fixture.model.setDisplayLanguage("it")
        XCTAssertEqual(fixture.model.pageNumber, 1)

        fixture.model.pageNumber = 2
        fixture.model.setDisplayLanguage(nil)
        XCTAssertEqual(fixture.model.pageNumber, 1)
    }

    @MainActor
    func testDisplayedPageUsesItalianFields() async throws {
        let run = entry("run", created: 0, variants: ["it": readyVariant("correre", for: "run")])
        let dog = entry("dog", created: 1)
        let stale = entry("sprint", created: 2, variants: ["it": readyVariant("correre", for: "run")])
        let fixture = try await makeFixture(seed: [run, dog, stale], withBackfill: false)

        XCTAssertEqual(fixture.model.displayedPage.map(\.word), ["sprint", "dog", "run"], "EN, newest first")
        XCTAssertTrue(fixture.model.displayedPage.allSatisfy { !$0.isFallback && $0.state == nil })

        fixture.model.setDisplayLanguage("it")
        let rows = fixture.model.displayedPage
        XCTAssertEqual(rows.map(\.word), ["sprint", "dog", "correre"])
        let italian = try XCTUnwrap(rows.first { $0.id == run.id })
        XCTAssertFalse(italian.isFallback)
        XCTAssertEqual(italian.translations, ["італ-correre"])
        XCTAssertEqual(italian.transcription, "/correre/")
        XCTAssertEqual(italian.state, .ready)
        let missing = try XCTUnwrap(rows.first { $0.id == dog.id })
        XCTAssertTrue(missing.isFallback)
        XCTAssertEqual(missing.state, .missing)
        XCTAssertEqual(missing.translations, [])
        XCTAssertEqual(rows.first { $0.id == stale.id }?.state, .stale)

        // Пошук в активній мові.
        fixture.model.query.searchText = "corr"
        XCTAssertEqual(fixture.model.displayedPage.map(\.id), [run.id])
        XCTAssertEqual(fixture.model.speechLanguageCode(for: LanguagePairRegistry.defaultPairID, languageID: "it"), "it-IT")
        XCTAssertEqual(fixture.model.speechLanguageCode(for: LanguagePairRegistry.defaultPairID, languageID: nil), "en-US")
    }

    @MainActor
    func testBackfillAllIncludesFailed() async throws {
        let failedVariant = EntryVariant(status: .failed, lastError: "помилка", sourceKey: "run")
        let run = entry("run", variants: ["it": failedVariant])
        let fixture = try await makeFixture(seed: [run])

        let task = try XCTUnwrap(fixture.model.setDisplayLanguage("it"))
        await task.value
        XCTAssertEqual(fixture.lookup.callCount, 0, "failed variant is not auto-backfilled")
        XCTAssertEqual(fixture.model.backfillableCount, 1)
        XCTAssertTrue(fixture.model.isBackfillAvailable)

        await fixture.model.backfillAll()

        XCTAssertEqual(fixture.lookup.callCount, 1)
        XCTAssertEqual(fixture.lookup.calls.first?.map(\.word), ["run"])
        XCTAssertEqual(fixture.model.lastBackfillReport?.ready, 1)
        XCTAssertEqual(fixture.model.backfillableCount, 0)
        XCTAssertEqual(fixture.model.entries.first?.variants?["it"]?.word, "run-it")
    }

    @MainActor
    func testRefreshVariantCallsLookupOnce() async throws {
        let run = entry("run", variants: ["it": readyVariant("vecchio", for: "run")])
        let fixture = try await makeFixture(seed: [run])

        // Режим EN: refresh бере першу мову відображення пари.
        let report = await fixture.model.refreshVariant(id: run.id)

        XCTAssertEqual(fixture.lookup.callCount, 1)
        XCTAssertEqual(report?.requests, 1)
        XCTAssertEqual(report?.ready, 1)
        XCTAssertEqual(fixture.model.entries.first?.variants?["it"]?.word, "run-it")
        XCTAssertNil(fixture.model.operationError)
        XCTAssertFalse(fixture.model.retryingIDs.contains(run.id))
    }

    @MainActor
    func testRefreshVariantKeepsEntryUpdatedAt() async throws {
        let house = entry("house", variants: ["it": readyVariant("casa", for: "house")], sourceLanguage: "it")
        let fixture = try await makeFixture(seed: [house])

        _ = await fixture.model.refreshVariant(id: house.id, languageID: "it")

        let storedEntry = await fixture.repository.entry(id: house.id)
        let stored = try XCTUnwrap(storedEntry)
        XCTAssertEqual(stored.updatedAt, house.updatedAt)
        XCTAssertEqual(stored.variants?["it"]?.word, "casa", "user's Italian word kept")
        XCTAssertEqual(fixture.lookup.calls.first?.first?.keepWord, "casa")
        XCTAssertEqual(fixture.lookup.callCount, 1)
    }

    @MainActor
    func testDuplicateResultHandledInRetry() async throws {
        // Наявний «house»; pending «casa» → відповідь: італійське виділення того ж поняття → дубль.
        let house = entry("house", created: 0)
        let pending = entry("casa", created: 1, status: .pending)
        let reply = """
        {"source_language":"it","word":"house","lemma":"house","part_of_speech":"noun","transcription":"/haʊs/",\
        "translations":["будинок"],"example":{"source":"A house.","translation":"Будинок."},\
        "variants":{"it":{"word":"casa","lemma":"casa","part_of_speech":"noun","transcription":"/ˈkaːza/",\
        "translations":["дім"],"example":{"source":"Una casa.","translation":"Дім."}}}}
        """
        let fixture = try await makeFixture(seed: [house, pending], withBackfill: false, claudeText: reply)

        let result = await fixture.model.retry(id: pending.id)

        guard case .duplicate(let existing, let removedID)? = result else {
            return XCTFail("expected .duplicate, got \(String(describing: result))")
        }
        XCTAssertEqual(existing.id, house.id)
        XCTAssertEqual(removedID, pending.id)
        XCTAssertEqual(fixture.model.operationError, RepositoryError.duplicate(existing).userMessage)
        XCTAssertEqual(fixture.model.entries.map(\.id), [house.id])
        XCTAssertEqual(fixture.model.entries.first?.variants?["it"]?.word, "casa")
        XCTAssertFalse(fixture.model.retryingIDs.contains(pending.id))
        XCTAssertEqual(fixture.model.retryableCount, 0)
    }
}
