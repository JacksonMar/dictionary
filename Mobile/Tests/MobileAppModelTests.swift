// I1a.2 (IOS_PLAN §7): loading and the read-only list of `MobileAppModel` against a temporary data directory.
import XCTest
import VocabCore
@testable import VocabMobile

final class MobileAppModelTests: XCTestCase {
    // MARK: - Fixtures

    /// house (oldest, ready IT variant), zebra (pending, no variant), apple (newest, failed IT variant).
    private func sampleEntries() -> [Entry] {
        let house = makeTestEntry(
            "house",
            translations: ["будинок", "дім"],
            transcription: "/haʊs/",
            example: Example(source: "A big house.", translation: "Великий будинок."),
            createdOffset: 0,
            variants: [
                "it": EntryVariant(
                    word: "casa",
                    transcription: "/ˈkaːsa/",
                    translations: ["хата"],
                    example: Example(source: "Una casa grande.", translation: "Велика хата."),
                    status: .ready,
                    sourceKey: TextNormalizer.key("house")
                ),
            ]
        )
        let zebra = makeTestEntry("zebra", status: .pending, createdOffset: 5)
        let apple = makeTestEntry(
            "apple",
            translations: ["яблуко"],
            createdOffset: 10,
            variants: ["it": EntryVariant.unfilled(status: .failed, sourceKey: TextNormalizer.key("apple"))]
        )
        return [house, zebra, apple]
    }

    @MainActor
    private func makeLoadedModel(
        entries: [Entry],
        settings: SettingsStore = InMemorySettingsStore()
    ) async throws -> MobileAppModel {
        let directory = makeTemporaryDirectory(self)
        try writeDictionary(entries, to: directory)
        let container = AppContainer(baseDirectory: directory, settings: settings)
        let model = MobileAppModel(container: container)
        await model.start()
        return model
    }

    // MARK: - I1a.2 required

    @MainActor
    func testLoadsEntriesFromTemporaryDirectory() async throws {
        let directory = makeTemporaryDirectory(self)
        let entries = sampleEntries()
        try writeDictionary(entries, to: directory)
        let container = AppContainer(baseDirectory: directory, settings: InMemorySettingsStore())
        XCTAssertEqual(container.paths.dictionaryURL.deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
        let model = MobileAppModel(container: container)
        XCTAssertFalse(model.isLoaded)
        XCTAssertTrue(model.entries.isEmpty)

        await model.start()

        XCTAssertTrue(model.isLoaded)
        XCTAssertNil(model.loadError)
        XCTAssertNil(model.loadWarning)
        XCTAssertFalse(model.isDictionaryEmpty)
        XCTAssertEqual(Set(model.entries.map(\.id)), Set(entries.map(\.id)))
        XCTAssertEqual(model.entries.count, 3)
        // Default sort: newest first; the default display language is the source language (EN).
        XCTAssertNil(model.displayLanguageID)
        XCTAssertEqual(model.visibleEntries.map(\.word), ["apple", "zebra", "house"])
        XCTAssertEqual(container.loadOutcome, .loaded(recoveredBackupURL: nil))
        XCTAssertTrue(container.isLoaded)
    }

    @MainActor
    func testSearchAndSortUseEntryQuery() async throws {
        let entries = sampleEntries()
        let model = try await makeLoadedModel(entries: entries)

        for sort in EntrySort.allCases {
            for search in ["", "HOUSE", "будин", "ябл", "  zeb  ", "qqqzzz"] {
                model.sort = sort
                model.searchText = search
                let expected = EntryQuery(searchText: search, sort: sort, languageID: nil).apply(to: model.entries)
                XCTAssertEqual(model.query, EntryQuery(searchText: search, sort: sort, languageID: nil))
                XCTAssertEqual(model.visibleEntries.map(\.id), expected.map(\.id), "sort \(sort), search '\(search)'")
                XCTAssertEqual(model.visibleRows.map(\.id), expected.map(\.id), "rows: sort \(sort), search '\(search)'")
            }
        }

        model.searchText = ""
        model.sort = .alphabetical
        XCTAssertEqual(model.visibleEntries.map(\.word), ["apple", "house", "zebra"])
        model.sort = .dateOldest
        XCTAssertEqual(model.visibleEntries.map(\.word), ["house", "zebra", "apple"])
        model.sort = .dateNewest
        XCTAssertEqual(model.visibleEntries.map(\.word), ["apple", "zebra", "house"])

        // Search by translation, case- and whitespace-insensitive (D19).
        model.searchText = "  Будинок "
        XCTAssertEqual(model.visibleEntries.map(\.word), ["house"])
        XCTAssertFalse(model.hasNoSearchResults)

        model.searchText = "qqqzzz"
        XCTAssertTrue(model.visibleEntries.isEmpty)
        XCTAssertTrue(model.hasNoSearchResults)
        XCTAssertFalse(model.isDictionaryEmpty, "no-results is not the empty-dictionary state")
    }

    @MainActor
    func testDisplayLanguageSwitchShowsVariants() async throws {
        let settings = InMemorySettingsStore()
        let model = try await makeLoadedModel(entries: sampleEntries(), settings: settings)
        XCTAssertEqual(model.renderings.map(\.id), ["it"])
        XCTAssertEqual(model.sourceShortTitle, LanguagePair.englishUkrainian.sourceShortTitle)

        // EN: source words, translations, example and transcription.
        let enHouse = try XCTUnwrap(model.visibleRows.first { $0.word == "house" })
        XCTAssertEqual(enHouse.translations, "будинок, дім")
        XCTAssertEqual(enHouse.transcription, "/haʊs/")
        XCTAssertEqual(enHouse.example, "A big house. — Великий будинок.")
        XCTAssertFalse(enHouse.isFallback)
        XCTAssertNil(enHouse.badge)

        // Switch to IT through the Picker binding.
        model.displayLanguageSelection = "it"
        XCTAssertEqual(model.displayLanguageID, "it")
        XCTAssertEqual(model.displayLanguageSelection, "it")
        XCTAssertEqual(settings.displayLanguageID, "it", "display language is persisted")
        XCTAssertEqual(model.activeRendering?.id, "it")
        XCTAssertEqual(model.query.languageID, "it")

        let rows = model.visibleRows
        XCTAssertEqual(rows.map(\.word), ["apple", "zebra", "casa"])

        let casa = rows[2]
        XCTAssertFalse(casa.isFallback)
        XCTAssertEqual(casa.translations, "хата")
        XCTAssertEqual(casa.transcription, "/ˈkaːsa/")
        XCTAssertEqual(casa.example, "Una casa grande. — Велика хата.")
        XCTAssertNil(casa.badge)

        // Failed variant of a ready entry: English word, fallback, "error" badge.
        let apple = rows[0]
        XCTAssertTrue(apple.isFallback)
        XCTAssertEqual(apple.translations, "")
        XCTAssertEqual(apple.badge, EntryRowContent.Badge(title: L10n.text(.tableBadgeFailed), kind: .failed))

        // Pending entry: entry status wins over the variant state.
        let zebra = rows[1]
        XCTAssertEqual(zebra.badge, EntryRowContent.Badge(title: L10n.text(.tableBadgePending), kind: .pending))

        // Search in IT finds the Italian word; alphabetical sorting uses it too.
        model.searchText = "cas"
        XCTAssertEqual(model.visibleRows.map(\.word), ["casa"])
        model.searchText = ""
        model.sort = .alphabetical
        XCTAssertEqual(model.visibleRows.map(\.word), ["apple", "casa", "zebra"])

        // Unknown language → source language; also persisted.
        model.setDisplayLanguage("xx")
        XCTAssertNil(model.displayLanguageID)
        XCTAssertNil(settings.displayLanguageID)

        model.setDisplayLanguage("it")
        model.displayLanguageSelection = nil
        XCTAssertNil(model.displayLanguageID)
        XCTAssertNil(settings.displayLanguageID)
        XCTAssertNil(model.activeRendering)
        XCTAssertEqual(model.visibleRows.map(\.word), ["apple", "house", "zebra"])
    }

    @MainActor
    func testItalianVariantPendingBadge() async throws {
        let pendingVariant = makeTestEntry(
            "tree",
            translations: ["дерево"],
            createdOffset: 0,
            variants: ["it": EntryVariant.unfilled(status: .pending, sourceKey: TextNormalizer.key("tree"))]
        )
        let missingVariant = makeTestEntry("cat", translations: ["кіт"], createdOffset: 1)
        let model = try await makeLoadedModel(entries: [pendingVariant, missingVariant])
        model.setDisplayLanguage("it")

        let expected = EntryRowContent.Badge(title: L10n.text(.renderingItalianPendingBadge), kind: .pending)
        let rows = model.visibleRows
        XCTAssertEqual(rows.map(\.word), ["cat", "tree"])
        XCTAssertTrue(rows.allSatisfy(\.isFallback))
        XCTAssertEqual(rows.map(\.badge), [expected, expected])
        XCTAssertEqual(
            EntryRowContent.variantPendingTitle(rendering: model.activeRendering, language: .en),
            "Italian version pending"
        )
    }

    @MainActor
    func testEmptyStateWhenNoFile() async throws {
        let directory = makeTemporaryDirectory(self).appendingPathComponent("missing", isDirectory: true)
        let container = AppContainer(baseDirectory: directory, settings: InMemorySettingsStore())
        let model = MobileAppModel(container: container)
        XCTAssertFalse(model.isDictionaryEmpty, "not empty-state before loading")

        await model.start()

        XCTAssertTrue(model.isLoaded)
        XCTAssertNil(model.loadError)
        XCTAssertNil(model.loadWarning)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.isDictionaryEmpty)
        XCTAssertFalse(model.hasNoSearchResults)
        XCTAssertTrue(model.visibleRows.isEmpty)
        model.searchText = "anything"
        XCTAssertFalse(model.hasNoSearchResults, "empty dictionary shows the empty state, not 'no results'")
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.paths.dictionaryURL.path),
                       "loading an absent dictionary must not create the file")
    }

    // MARK: - Errors and warnings

    @MainActor
    func testLoadErrorForNewerSchema() async throws {
        let directory = makeTemporaryDirectory(self)
        let raw = #"{"schemaVersion": 99, "entries": []}"#
        try writeRawDictionary(raw, to: directory)
        let container = AppContainer(baseDirectory: directory, settings: InMemorySettingsStore())
        let model = MobileAppModel(container: container)

        await model.start()

        XCTAssertFalse(model.isLoaded)
        XCTAssertEqual(model.loadError, StorageError.unsupportedSchemaVersion(99).userMessage)
        XCTAssertFalse(model.isDictionaryEmpty, "error state is not the empty state")
        XCTAssertTrue(model.entries.isEmpty)
        let onDisk = try String(contentsOf: container.paths.dictionaryURL, encoding: .utf8)
        XCTAssertEqual(onDisk, raw, "newer-schema file must not be changed")

        // A second start (e.g. scene re-activation) keeps the cached error.
        await model.start()
        XCTAssertFalse(model.isLoaded)
        XCTAssertEqual(model.loadError, StorageError.unsupportedSchemaVersion(99).userMessage)
    }

    @MainActor
    func testCorruptedFileShowsRecoveredWarning() async throws {
        let directory = makeTemporaryDirectory(self)
        try writeRawDictionary("not json", to: directory)
        let container = AppContainer(baseDirectory: directory, settings: InMemorySettingsStore())
        let model = MobileAppModel(container: container)

        await model.start()

        XCTAssertTrue(model.isLoaded)
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.isDictionaryEmpty)
        guard case .loaded(let backupURL?)? = container.loadOutcome else {
            return XCTFail("expected a recovered backup URL, got \(String(describing: container.loadOutcome))")
        }
        XCTAssertTrue(backupURL.path.hasPrefix(container.paths.backupsDirectory.path), backupURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(model.loadWarning, L10n.text(.modelLoadRecovered, ["path": backupURL.path]))

        // The banner's Close button clears the warning.
        model.loadWarning = nil
        XCTAssertNil(model.loadWarning)
    }

    // MARK: - Persisted display language, live updates, repeated start

    @MainActor
    func testPersistedDisplayLanguageIsRestoredAndValidated() async throws {
        let directory = makeTemporaryDirectory(self)
        let italian = MobileAppModel(container: AppContainer(
            baseDirectory: directory,
            settings: InMemorySettingsStore(displayLanguageID: "it")
        ))
        XCTAssertEqual(italian.displayLanguageID, "it")
        XCTAssertEqual(italian.activeRendering?.id, "it")

        let unknown = MobileAppModel(container: AppContainer(
            baseDirectory: directory,
            settings: InMemorySettingsStore(displayLanguageID: "xx")
        ))
        XCTAssertNil(unknown.displayLanguageID, "unknown stored language falls back to the source language")

        let unknownPair = MobileAppModel(container: AppContainer(
            baseDirectory: directory,
            settings: InMemorySettingsStore(languagePairID: "xx-yy", displayLanguageID: "it")
        ))
        XCTAssertNil(unknownPair.displayLanguageID)
    }

    @MainActor
    func testRepositoryChangesUpdateEntries() async throws {
        let model = try await makeLoadedModel(entries: sampleEntries())
        XCTAssertEqual(model.entries.count, 3)

        _ = try await model.container.repository.add(EntryDraft(
            word: "tree",
            languagePair: LanguagePair.englishUkrainian.id,
            translations: ["дерево"],
            status: .ready
        ))

        for _ in 0..<200 where model.entries.count < 4 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.entries.count, 4)
        XCTAssertTrue(model.entries.contains { $0.word == "tree" })
    }

    @MainActor
    func testRepeatedStartLoadsOnceAndSubscribesOnce() async throws {
        let store = CountingDictionaryStore(entries: sampleEntries())
        let directory = makeTemporaryDirectory(self)
        let container = AppContainer(
            paths: AppPaths(applicationSupportDirectory: directory),
            settings: InMemorySettingsStore(),
            store: store
        )
        let model = MobileAppModel(container: container)

        await model.start()
        let firstTask = model.changesTask
        XCTAssertNotNil(firstTask)
        await model.start()
        await model.start()

        XCTAssertEqual(store.loadCount, 1)
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.entries.count, 3)
        XCTAssertEqual(model.changesTask, firstTask, "a single repository subscription")
    }

    func testRowContentWithoutExampleTranslationOrTranscription() {
        let entry = makeTestEntry(
            "word",
            translations: ["слово"],
            transcription: "   ",
            example: Example(source: "Only source.", translation: " "),
            createdOffset: 0
        )
        let row = EntryRowContent.make(EntryDisplay.make(entry, languageID: nil), rendering: nil, language: .en)
        XCTAssertNil(row.transcription, "blank transcription is hidden")
        XCTAssertEqual(row.example, "Only source.")

        let noExample = makeTestEntry("bare", createdOffset: 0)
        let bareRow = EntryRowContent.make(EntryDisplay.make(noExample, languageID: nil), rendering: nil, language: .en)
        XCTAssertNil(bareRow.example)
        XCTAssertEqual(bareRow.translations, "")
        XCTAssertNil(bareRow.badge)

        let failed = makeTestEntry("oops", status: .failed, createdOffset: 0)
        let failedRow = EntryRowContent.make(EntryDisplay.make(failed, languageID: nil), rendering: nil, language: .uk)
        XCTAssertEqual(failedRow.badge, EntryRowContent.Badge(title: L10n.text(.tableBadgeFailed, language: .uk),
                                                              kind: .failed))
    }
}
