import XCTest
import VocabCore
@testable import VocabApp

/// Spy теми: запам'ятовує кожне `apply` (без `NSApp`).
@MainActor
final class SpyAppearanceApplier: AppearanceApplying {
    private(set) var applied: [AppAppearance] = []

    func apply(_ appearance: AppAppearance) {
        applied.append(appearance)
    }
}

/// `SettingsStore`, що рахує записи `pageSize` / `appearance` (перевірка «нічого не зберігається»).
private final class CountingSettingsStore: SettingsStore, @unchecked Sendable {
    private let base: InMemorySettingsStore
    private(set) var pageSizeWrites = 0
    private(set) var appearanceWrites = 0

    init(appearance: AppAppearance = .system, pageSize: Int = Pagination.defaultPageSize) {
        base = InMemorySettingsStore(appearance: appearance, pageSize: pageSize)
    }

    var model: String {
        get { base.model }
        set { base.model = newValue }
    }

    var languagePairID: String {
        get { base.languagePairID }
        set { base.languagePairID = newValue }
    }

    var appearance: AppAppearance {
        get { base.appearance }
        set {
            appearanceWrites += 1
            base.appearance = newValue
        }
    }

    var pageSize: Int {
        get { base.pageSize }
        set {
            pageSizeWrites += 1
            base.pageSize = newValue
        }
    }
}

/// M6.3–M6.5 — `AppModel`: стан сторінки, тема (spy), одне сховище налаштувань із Claude, тригери черги в логах.
final class AppModelM6Tests: XCTestCase {
    private static let reference = Date(timeIntervalSince1970: 1_791_885_600)

    private struct Fixture {
        let model: AppModel
        let repository: DictionaryRepository
    }

    /// Записи `w1…wN`; `w1` найстаріший (createdAt зростає з номером) → у моделі `wN` перший, `w1` останній.
    private func seedEntries(_ count: Int, status: EntryStatus = .ready) -> [Entry] {
        (0..<count).map { index in
            entry("w\(index + 1)", created: TimeInterval(index), status: status)
        }
    }

    private func entry(_ word: String, created: TimeInterval, status: EntryStatus = .ready) -> Entry {
        let date = Self.reference.addingTimeInterval(created)
        return Entry(
            languagePair: LanguagePairRegistry.defaultPairID,
            word: word,
            lemma: word,
            translations: status == .ready ? ["переклад-\(word)"] : [],
            status: status,
            lastError: status == .failed ? "HTTP 400: bad request for \(word)" : nil,
            createdAt: date,
            updatedAt: date
        )
    }

    @MainActor
    private func makeFixture(
        seed: [Entry] = [],
        settings: SettingsStore? = nil,
        appearanceApplier: AppearanceApplying? = nil,
        claudeSettings: SettingsStore? = nil,
        logSink: LogSink? = nil
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabAppM6Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
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
        var claude: ClaudeServices?
        if claudeSettings != nil || logSink != nil {
            claude = ClaudeServices.make(
                repository: repository,
                secrets: InMemorySecretStore(),
                settings: claudeSettings ?? InMemorySettingsStore(),
                transport: EchoErrorTransport(message: "no network in tests"),
                logSink: logSink ?? RecordingLogSink(),
                dateProvider: dates
            )
        }
        let model = AppModel(
            repository: repository,
            languagePairID: LanguagePairRegistry.defaultPairID,
            claude: claude,
            settings: settings,
            appearanceApplier: appearanceApplier
        )
        await model.load()
        XCTAssertNil(model.loadError)
        return Fixture(model: model, repository: repository)
    }

    /// Чекає (до `timeout`), доки умова на головному акторі не стане істинною.
    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ message: String,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("timed out: \(message)")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - M6.3 Сторінки

    @MainActor
    func testCurrentPageUsesPageSize() async throws {
        let model = try await makeFixture(seed: seedEntries(60)).model

        XCTAssertEqual(model.pageSize, 25)
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(model.pagination, Pagination(pageSize: 25))
        var page = model.currentPage
        XCTAssertEqual(page.entries.count, 25)
        XCTAssertEqual(page.entries, Array(model.visibleEntries.prefix(25)))
        XCTAssertEqual(page.number, 1)
        XCTAssertEqual(page.pageCount, 3)
        XCTAssertEqual(page.totalCount, 60)
        XCTAssertEqual(page.entries.first?.word, "w60", "newest first")

        let twenty = try await makeFixture(seed: seedEntries(60), settings: InMemorySettingsStore(pageSize: 20)).model
        XCTAssertEqual(twenty.pageSize, 20)
        page = twenty.currentPage
        XCTAssertEqual(page.entries.count, 20)
        XCTAssertEqual(page.pageCount, 3)
    }

    @MainActor
    func testNextAndPreviousPage() async throws {
        let model = try await makeFixture(seed: seedEntries(60)).model

        model.nextPage()
        XCTAssertEqual(model.pageNumber, 2)
        XCTAssertEqual(model.currentPage.entries, Array(model.visibleEntries[25..<50]))

        model.nextPage()
        XCTAssertEqual(model.pageNumber, 3)
        XCTAssertEqual(model.currentPage.entries.count, 10)
        XCTAssertFalse(model.currentPage.hasNext)

        model.nextPage()
        XCTAssertEqual(model.pageNumber, 3, "does not go past the last page")

        model.previousPage()
        XCTAssertEqual(model.pageNumber, 2)
        model.previousPage()
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertFalse(model.currentPage.hasPrevious)
        model.previousPage()
        XCTAssertEqual(model.pageNumber, 1, "does not go below 1")
    }

    @MainActor
    func testSearchChangeResetsPageToOne() async throws {
        let model = try await makeFixture(seed: seedEntries(60)).model
        model.pageNumber = 3

        let sameText = model.query.searchText
        model.query.searchText = sameText
        XCTAssertEqual(model.pageNumber, 3, "assigning the same search text keeps the page")

        model.query.searchText = "w"
        XCTAssertEqual(model.pageNumber, 1)

        model.pageNumber = 2
        model.query.searchText = ""
        XCTAssertEqual(model.pageNumber, 1, "clearing the search also resets the page")
    }

    @MainActor
    func testSortChangeResetsPageToOne() async throws {
        let model = try await makeFixture(seed: seedEntries(60)).model
        model.pageNumber = 2

        let sameSort = model.query.sort
        model.query.sort = sameSort
        XCTAssertEqual(model.pageNumber, 2, "same sort keeps the page")

        model.query.sort = .alphabetical
        XCTAssertEqual(model.pageNumber, 1)

        model.pageNumber = 3
        model.query.sort = .dateOldest
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(model.currentPage.entries.first?.word, "w1")
    }

    @MainActor
    func testPageSizeChangeResetsPageAndPersists() async throws {
        let settings = InMemorySettingsStore()
        let model = try await makeFixture(seed: seedEntries(60), settings: settings).model
        model.pageNumber = 3

        model.setPageSize(20)

        XCTAssertEqual(model.pageSize, 20)
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(settings.pageSize, 20)
        XCTAssertEqual(model.currentPage.entries.count, 20)

        model.pageNumber = 2
        model.setPageSize(30)
        XCTAssertEqual(model.pageSize, 30)
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(settings.pageSize, 30)

        let reloaded = try await makeFixture(seed: seedEntries(60), settings: settings).model
        XCTAssertEqual(reloaded.pageSize, 30, "page size survives a new model over the same settings")
    }

    @MainActor
    func testSetPageSizeIgnoresUnsupportedValue() async throws {
        let settings = CountingSettingsStore(pageSize: 30)
        let model = try await makeFixture(seed: seedEntries(60), settings: settings).model
        XCTAssertEqual(model.pageSize, 30)
        model.pageNumber = 2

        for invalid in [50, 0, -1, 24, 100] {
            model.setPageSize(invalid)
        }

        XCTAssertEqual(model.pageSize, 30)
        XCTAssertEqual(model.pageNumber, 2, "page is not reset by an ignored value")
        XCTAssertEqual(settings.pageSize, 30)
        XCTAssertEqual(settings.pageSizeWrites, 0, "nothing is persisted")
    }

    @MainActor
    func testDeleteOnLastPageClampsPage() async throws {
        let model = try await makeFixture(seed: seedEntries(26)).model
        model.nextPage()
        XCTAssertEqual(model.pageNumber, 2)
        let lonely = try XCTUnwrap(model.currentPage.entries.first)
        XCTAssertEqual(model.currentPage.entries.count, 1)
        XCTAssertEqual(lonely.word, "w1")

        let deleted = await model.delete(id: lonely.id)

        XCTAssertTrue(deleted)
        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(model.currentPage.pageCount, 1)
        XCTAssertEqual(model.currentPage.entries.count, 25)
    }

    @MainActor
    func testRepositoryChangeClampsPage() async throws {
        let fixture = try await makeFixture(seed: seedEntries(26))
        let model = fixture.model
        model.nextPage()
        XCTAssertEqual(model.pageNumber, 2)
        let lonely = try XCTUnwrap(model.currentPage.entries.first)

        // Зміна приходить через `repository.changes()` (напр. Services/черга), а не через `AppModel.delete`.
        try await fixture.repository.delete(id: lonely.id)
        try await waitUntil("model receives repository snapshot") { model.entries.count == 25 }

        XCTAssertEqual(model.pageNumber, 1)
        XCTAssertEqual(model.currentPage.pageCount, 1)
        XCTAssertFalse(model.currentPage.entries.contains { $0.id == lonely.id })
    }

    @MainActor
    func testSearchAppliesToWholeDictionaryNotPage() async throws {
        var seed = seedEntries(60)
        seed.append(entry("needle", created: -100))
        let model = try await makeFixture(seed: seed).model
        XCTAssertFalse(model.currentPage.entries.contains { $0.word == "needle" }, "oldest entry is not on page 1")

        model.query.searchText = "needle"

        let page = model.currentPage
        XCTAssertEqual(page.entries.map(\.word), ["needle"])
        XCTAssertEqual(page.number, 1)
        XCTAssertEqual(page.pageCount, 1)
        XCTAssertEqual(page.totalCount, 1)

        model.query.searchText = "переклад-w6"
        XCTAssertEqual(Set(model.currentPage.entries.map(\.word)), ["w6", "w60"],
                       "translation search covers all pages")
    }

    // MARK: - M6.4 Тема

    @MainActor
    func testAppearanceLoadedFromSettings() async throws {
        let spy = SpyAppearanceApplier()
        let settings = InMemorySettingsStore(appearance: .dark, pageSize: 30)
        let model = try await makeFixture(settings: settings, appearanceApplier: spy).model

        XCTAssertEqual(model.appearance, .dark)
        XCTAssertEqual(model.pageSize, 30)
        XCTAssertEqual(spy.applied, [], "init does not apply; AppDelegate calls applyCurrentAppearance")

        model.applyCurrentAppearance()
        XCTAssertEqual(spy.applied, [.dark])

        let defaultModel = try await makeFixture().model
        XCTAssertEqual(defaultModel.appearance, .system)
        XCTAssertEqual(defaultModel.pageSize, 25)
        defaultModel.applyCurrentAppearance() // без applier — нічого не відбувається
    }

    @MainActor
    func testSetAppearancePersistsAndApplies() async throws {
        let spy = SpyAppearanceApplier()
        let settings = InMemorySettingsStore()
        let model = try await makeFixture(settings: settings, appearanceApplier: spy).model

        model.setAppearance(.dark)
        XCTAssertEqual(model.appearance, .dark)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(spy.applied, [.dark])

        model.setAppearance(.light)
        model.setAppearance(.system)
        XCTAssertEqual(model.appearance, .system)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(spy.applied, [.dark, .light, .system])
    }

    @MainActor
    func testAppModelUsesSameSettingsStoreAsClaude() async throws {
        let claudeSettings = InMemorySettingsStore(appearance: .light, pageSize: 20)
        let fixture = try await makeFixture(seed: seedEntries(30), claudeSettings: claudeSettings)
        let model = fixture.model
        XCTAssertTrue(model.isClaudeAvailable)

        XCTAssertEqual(model.appearance, .light, "initial values come from claude.settings")
        XCTAssertEqual(model.pageSize, 20)

        model.setAppearance(.dark)
        model.setPageSize(30)

        XCTAssertEqual(claudeSettings.appearance, .dark)
        XCTAssertEqual(claudeSettings.pageSize, 30)
    }

    // MARK: - M6.5 Тригери черги в логах

    @MainActor
    func testRetryLogsManualTrigger() async throws {
        let sink = RecordingLogSink()
        let failed = entry("secretword", created: 0, status: .failed)
        let fixture = try await makeFixture(seed: [failed], logSink: sink)

        _ = await fixture.model.retry(id: failed.id)

        let queueLines = sink.messages.filter { $0.hasPrefix("Queue run") }
        XCTAssertEqual(queueLines.count, 2, "\(sink.messages)")
        XCTAssertEqual(queueLines.first, "Queue run started: trigger=manual id=\(failed.id.uuidString)")
        let finished = try XCTUnwrap(queueLines.last)
        XCTAssertTrue(finished.hasPrefix("Queue run finished: trigger=manual id=\(failed.id.uuidString) ready="),
                      finished)
        XCTAssertTrue(finished.contains("notFound="), finished)
        for line in queueLines {
            XCTAssertFalse(line.contains("secretword"), line)
            XCTAssertFalse(line.contains("bad request"), line)
            XCTAssertFalse(line.contains("no network in tests"), line)
        }
    }

    @MainActor
    func testRetryAllLogsRetryAllTrigger() async throws {
        let sink = RecordingLogSink()
        let seed = [
            entry("pendingword", created: 0, status: .pending),
            entry("failedword", created: 1, status: .failed),
        ]
        let fixture = try await makeFixture(seed: seed, logSink: sink)

        await fixture.model.retryAll()

        let queueLines = sink.messages.filter { $0.hasPrefix("Queue run") }
        XCTAssertEqual(queueLines.first, "Queue run started: trigger=retryAll", "\(sink.messages)")
        let finished = try XCTUnwrap(queueLines.last)
        XCTAssertTrue(finished.hasPrefix("Queue run finished: trigger=retryAll ready="), finished)
        XCTAssertFalse(finished.contains(" id="), "retryAll line has no entry id")
        XCTAssertFalse(queueLines.contains { $0.contains("trigger=manual") }, "\(queueLines)")
        for line in queueLines {
            XCTAssertFalse(line.contains("pendingword"), line)
            XCTAssertFalse(line.contains("failedword"), line)
        }

        // Лічильники: 2 записи оброблено (pending → processAll, failed → retry), без ключа жоден не ready.
        let counts = finished.split(separator: " ").compactMap { part -> (String, Int)? in
            let pair = part.split(separator: "=")
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            return (String(pair[0]), value)
        }
        let total = counts.filter { ["ready", "pending", "failed", "skipped", "notFound"].contains($0.0) }
            .reduce(0) { $0 + $1.1 }
        XCTAssertEqual(total, 2, finished)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: counts)["ready"], 0, finished)
    }
}
