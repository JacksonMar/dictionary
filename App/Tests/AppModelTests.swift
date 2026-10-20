import XCTest
import VocabCore
@testable import VocabApp

/// M1.7 — AppModel: ручне додавання/редагування/видалення через репозиторій у тимчасовому каталозі.
/// Реальний `~/Library/Application Support/VocabApp` не використовується.
final class AppModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        pinInterfaceLanguage(.uk)
    }

    private struct Harness {
        let model: AppModel
        let paths: AppPaths
        let dates: FixedDateProvider
        let store: FileDictionaryStore
    }

    @MainActor
    private func makeHarness(preexistingJSON: String? = nil) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabAppModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = AppPaths(applicationSupportDirectory: directory)
        if let preexistingJSON {
            try Data(preexistingJSON.utf8).write(to: paths.dictionaryURL)
        }
        let dates = FixedDateProvider(Date(timeIntervalSince1970: 1_791_885_600))
        let store = FileDictionaryStore(
            fileURL: paths.dictionaryURL,
            fileSystem: LocalFileSystem(),
            dateProvider: dates,
            backups: BackupManager(directory: paths.backupsDirectory, dateProvider: dates)
        )
        let repository = DictionaryRepository(store: store, dateProvider: dates)
        let model = AppModel(repository: repository, languagePairID: LanguagePairRegistry.defaultPairID)
        await model.load()
        XCTAssertNil(model.loadError)
        return Harness(model: model, paths: paths, dates: dates, store: store)
    }

    private func draft(_ word: String, translations: [String] = ["бігти", "керувати"]) -> EntryDraft {
        EntryDraft(
            word: word,
            languagePair: LanguagePairRegistry.defaultPairID,
            lemma: word,
            partOfSpeech: "verb",
            transcription: "/rʌn/",
            translations: translations,
            example: Example(source: "I run every day.", translation: "Я бігаю щодня."),
            status: .ready
        )
    }

    @MainActor
    func testManualAddAppears() async throws {
        let harness = try await makeHarness()
        XCTAssertTrue(harness.model.isLoaded)
        XCTAssertTrue(harness.model.entries.isEmpty)

        let added = await harness.model.addManual(draft("  run "))

        let entry = try XCTUnwrap(added)
        XCTAssertEqual(entry.word, "run", "word is cleaned before saving")
        XCTAssertEqual(harness.model.entries.map(\.id), [entry.id])
        XCTAssertNil(harness.model.operationError)
        XCTAssertEqual(try harness.store.load().file.entries.map(\.word), ["run"])
    }

    @MainActor
    func testEditUpdatesEntry() async throws {
        let harness = try await makeHarness()
        let added = await harness.model.addManual(draft("run"))
        let entry = try XCTUnwrap(added)
        harness.dates.advance(by: 60)

        var edited = entry
        edited.translations = ["бігати"]
        let result = await harness.model.update(edited)
        let updated = try XCTUnwrap(result)

        XCTAssertEqual(updated.translations, ["бігати"])
        XCTAssertEqual(updated.updatedAt, entry.updatedAt.addingTimeInterval(60))
        XCTAssertEqual(harness.model.entries.first?.translations, ["бігати"])
        XCTAssertNil(harness.model.operationError)
        XCTAssertEqual(try harness.store.load().file.entries.first?.translations, ["бігати"])
    }

    @MainActor
    func testDeleteRemovesEntry() async throws {
        let harness = try await makeHarness()
        let addedRun = await harness.model.addManual(draft("run"))
        let addedWalk = await harness.model.addManual(draft("walk"))
        let run = try XCTUnwrap(addedRun)
        let walk = try XCTUnwrap(addedWalk)

        let deleted = await harness.model.delete(id: run.id)

        XCTAssertTrue(deleted)
        XCTAssertEqual(harness.model.entries.map(\.id), [walk.id])
        XCTAssertEqual(try harness.store.load().file.entries.map(\.id), [walk.id])
    }

    @MainActor
    func testDuplicateManualAddShowsError() async throws {
        let harness = try await makeHarness()
        _ = await harness.model.addManual(draft("run"))

        let duplicate = await harness.model.addManual(draft("Run "))

        XCTAssertNil(duplicate)
        XCTAssertEqual(harness.model.operationError, "«run» вже є в словнику")
        XCTAssertEqual(harness.model.entries.count, 1)
    }

    @MainActor
    func testReadyWithoutTranslationsShowsError() async throws {
        let harness = try await makeHarness()

        let result = await harness.model.addManual(draft("run", translations: []))

        XCTAssertNil(result)
        XCTAssertEqual(harness.model.operationError, "Додайте хоча б один переклад")
        XCTAssertTrue(harness.model.entries.isEmpty)
    }

    @MainActor
    func testCorruptedFileSetsWarning() async throws {
        let harness = try await makeHarness(preexistingJSON: "garbage")

        XCTAssertTrue(harness.model.isLoaded)
        XCTAssertNotNil(harness.model.loadWarning)
        XCTAssertTrue(harness.model.entries.isEmpty)
    }

    func testTestEnvironmentUsesTemporaryDirectory() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
        let paths = AppEnvironment.makePaths()
        XCTAssertFalse(paths.applicationSupportDirectory.path.contains("Library/Application Support"),
                       "tests must never use the real Application Support directory")
    }
}
