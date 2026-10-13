import XCTest
import VocabCore
@testable import VocabApp

/// Фейкові панелі: повертають заданий URL або `nil` (= користувач натиснув «Скасувати»).
@MainActor
private final class FakeFilePanels: FilePanelPresenting {
    var exportDestination: URL?
    var importSource: URL?
    private(set) var exportRequests: [String] = []
    private(set) var importRequests = 0

    func chooseExportDestination(defaultFileName: String) -> URL? {
        exportRequests.append(defaultFileName)
        return exportDestination
    }

    func chooseImportSource() -> URL? {
        importRequests += 1
        return importSource
    }
}

/// M4.6 — інтеграція експорту/імпорту в `AppModel`: панелі, вибір режиму, підтвердження заміни, звіт, помилки.
/// Усі файли — у тимчасовому каталозі; реальний `~/Library/Application Support/VocabApp` не використовується.
final class AppModelTransferTests: XCTestCase {
    private struct Harness {
        let model: AppModel
        let panels: FakeFilePanels
        let paths: AppPaths
        let dates: FixedDateProvider
        let store: FileDictionaryStore
        let repository: DictionaryRepository
        /// Каталог для файлів експорту/імпорту («інший комп'ютер»).
        let transferDirectory: URL
    }

    private static let reference = Date(timeIntervalSince1970: 1_791_885_600)

    @MainActor
    private func makeHarness(seed: [Entry] = [], load: Bool = true, withTransfer: Bool = true) async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabAppTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let paths = AppPaths(applicationSupportDirectory: directory.appendingPathComponent("VocabApp", isDirectory: true))
        let transferDirectory = directory.appendingPathComponent("Transfer", isDirectory: true)
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)

        let dates = FixedDateProvider(Self.reference)
        let fileSystem = LocalFileSystem()
        let backups = BackupManager(directory: paths.backupsDirectory, fileSystem: fileSystem, dateProvider: dates)
        let store = FileDictionaryStore(
            fileURL: paths.dictionaryURL,
            fileSystem: fileSystem,
            dateProvider: dates,
            backups: backups
        )
        if !seed.isEmpty {
            try store.save(DictionaryFile(entries: seed))
        }
        let repository = DictionaryRepository(store: store, dateProvider: dates)
        let transfer = DictionaryTransferService(
            repository: repository,
            store: store,
            backups: backups,
            fileSystem: fileSystem,
            dateProvider: dates
        )
        let panels = FakeFilePanels()
        let model = AppModel(
            repository: repository,
            languagePairID: LanguagePairRegistry.defaultPairID,
            claude: nil,
            transfer: withTransfer ? transfer : nil,
            filePanels: panels
        )
        if load {
            await model.load()
            XCTAssertNil(model.loadError)
        }
        return Harness(
            model: model,
            panels: panels,
            paths: paths,
            dates: dates,
            store: store,
            repository: repository,
            transferDirectory: transferDirectory
        )
    }

    private func entry(
        _ word: String,
        id: UUID = UUID(),
        translations: [String]? = nil,
        status: EntryStatus = .ready,
        updatedOffset: TimeInterval = 0
    ) -> Entry {
        Entry(
            id: id,
            languagePair: LanguagePairRegistry.defaultPairID,
            word: word,
            lemma: word,
            partOfSpeech: "verb",
            transcription: "/\(word)/",
            translations: translations ?? (status == .ready ? ["переклад-\(word)"] : []),
            example: nil,
            status: status,
            lastError: nil,
            createdAt: Self.reference,
            updatedAt: Self.reference.addingTimeInterval(updatedOffset)
        )
    }

    private func writeImportFile(_ entries: [Entry], in harness: Harness, name: String = "import.json") throws -> URL {
        let data = try JSONCoding.makeEncoder().encode(DictionaryFile(exportedAt: Self.reference, entries: entries))
        return try writeImportFile(data, in: harness, name: name)
    }

    private func writeImportFile(_ data: Data, in harness: Harness, name: String = "import.json") throws -> URL {
        let url = harness.transferDirectory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url)
        return url
    }

    private func backupNames(_ harness: Harness) throws -> [String] {
        guard FileManager.default.fileExists(atPath: harness.paths.backupsDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: harness.paths.backupsDirectory.path).sorted()
    }

    // MARK: - Експорт

    @MainActor
    func testExportWithPanelWritesFile() async throws {
        let local = [entry("run"), entry("walk")]
        let harness = try await makeHarness(seed: local)
        let url = harness.transferDirectory.appendingPathComponent("dictionary.json")
        harness.panels.exportDestination = url
        harness.dates.advance(by: 3600)

        await harness.model.exportWithPanel()

        XCTAssertEqual(harness.panels.exportRequests, ["dictionary.json"])
        let file = try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertEqual(file.exportedAt, Self.reference.addingTimeInterval(3600))
        XCTAssertEqual(file.entries, local)
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertFalse(message.isError)
        XCTAssertEqual(message.title, "Словник експортовано")
        XCTAssertEqual(message.text, "Записів: 2. Файл: \(url.path)")
        XCTAssertFalse(harness.model.isTransferring)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.transferDirectory.path)
        XCTAssertEqual(leftovers, ["dictionary.json"], "atomic write leaves no temp files")
    }

    @MainActor
    func testExportPanelCancelDoesNothing() async throws {
        let harness = try await makeHarness(seed: [entry("run")])
        harness.panels.exportDestination = nil

        await harness.model.exportWithPanel()

        XCTAssertEqual(harness.panels.exportRequests.count, 1)
        XCTAssertNil(harness.model.transferMessage)
        XCTAssertFalse(harness.model.isTransferring)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.transferDirectory.path), [])
    }

    @MainActor
    func testExportFailureSetsError() async throws {
        let harness = try await makeHarness(seed: [entry("run")])
        // Батьківський «каталог» — звичайний файл → запис неможливий.
        let blocker = harness.transferDirectory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let url = blocker.appendingPathComponent("dictionary.json")

        let ok = await harness.model.export(to: url)

        XCTAssertFalse(ok)
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.title, "Не вдалося експортувати")
        XCTAssertTrue(message.text.hasPrefix("Не вдалося записати файл: "), message.text)
    }

    @MainActor
    func testExportBeforeLoadSetsError() async throws {
        let harness = try await makeHarness(seed: [entry("run")], load: false)
        let url = harness.transferDirectory.appendingPathComponent("dictionary.json")

        let ok = await harness.model.export(to: url)

        XCTAssertFalse(ok)
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.text, "Словник ще не завантажено")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no empty export written")
    }

    // MARK: - Імпорт: вибір файлу і режиму

    @MainActor
    func testBeginImportSetsChooseMode() async throws {
        let harness = try await makeHarness()
        let url = try writeImportFile([entry("run")], in: harness)
        harness.panels.importSource = url

        harness.model.beginImport()

        XCTAssertEqual(harness.panels.importRequests, 1)
        XCTAssertEqual(harness.model.importStage, .chooseMode(url))
        XCTAssertNil(harness.model.transferMessage)
        XCTAssertTrue(harness.model.entries.isEmpty, "nothing imported before a mode is chosen")

        harness.model.cancelImport()
        XCTAssertNil(harness.model.importStage)
    }

    @MainActor
    func testBeginImportCancelledPanelDoesNothing() async throws {
        let harness = try await makeHarness(seed: [entry("run")])
        harness.panels.importSource = nil

        harness.model.beginImport()

        XCTAssertEqual(harness.panels.importRequests, 1)
        XCTAssertNil(harness.model.importStage)
        XCTAssertNil(harness.model.transferMessage)
        XCTAssertEqual(harness.model.entries.map(\.word), ["run"])
    }

    @MainActor
    func testSelectModeWithoutPendingImportDoesNothing() async throws {
        let harness = try await makeHarness()
        XCTAssertNil(harness.model.selectImportMode(.merge))
        XCTAssertNil(harness.model.selectImportMode(.replace))
        XCTAssertNil(harness.model.confirmReplaceImport())
        XCTAssertNil(harness.model.importStage)
    }

    @MainActor
    func testImportMergeUpdatesEntriesAndReport() async throws {
        let sharedID = UUID()
        let local = [entry("run", id: sharedID, translations: ["бігти"]), entry("walk", updatedOffset: 100)]
        let harness = try await makeHarness(seed: local)
        let imported = [
            entry("run", id: sharedID, translations: ["бігти", "керувати"], updatedOffset: 50), // оновлено
            entry("Walk", translations: ["старе"], updatedOffset: 10),                          // пропущено
            entry("swim"),                                                                       // додано
        ]
        harness.panels.importSource = try writeImportFile(imported, in: harness)

        harness.model.beginImport()
        let task = harness.model.selectImportMode(.merge)
        XCTAssertNil(harness.model.importStage, "dialog state cleared synchronously")
        try await XCTUnwrap(task).value

        let report = try XCTUnwrap(harness.model.lastReport)
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.skipped, 1)
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertFalse(message.isError)
        XCTAssertEqual(message.title, "Імпорт завершено")
        XCTAssertEqual(message.text,
                       "Додано 1, оновлено 1, пропущено 1\n\nПропущено:\n• «Walk»: у словнику та сама або новіша версія")
        XCTAssertEqual(message.text, AppModel.reportText(report))

        XCTAssertEqual(Set(harness.model.entries.map(\.word)), ["run", "walk", "swim"])
        let run = try XCTUnwrap(harness.model.entries.first { $0.id == sharedID })
        XCTAssertEqual(run.translations, ["бігти", "керувати"])
        XCTAssertEqual(harness.model.entries.first { $0.word == "walk" }?.translations, local[1].translations)
        XCTAssertEqual(try harness.store.load().file.entries.count, 3)
        XCTAssertEqual(try backupNames(harness), [], "merge makes no backup")
        XCTAssertFalse(harness.model.isTransferring)
    }

    @MainActor
    func testImportMergeCleanReportHasNoSkipList() async throws {
        let harness = try await makeHarness()
        harness.panels.importSource = try writeImportFile([entry("run"), entry("walk")], in: harness)

        harness.model.beginImport()
        try await XCTUnwrap(harness.model.selectImportMode(.merge)).value

        XCTAssertEqual(harness.model.transferMessage?.text, "Додано 2, оновлено 0, пропущено 0")
        XCTAssertEqual(harness.model.transferMessage?.isError, false)
        XCTAssertEqual(harness.model.entries.count, 2)
    }

    // MARK: - Імпорт: заміна

    @MainActor
    func testReplaceRequiresConfirmation() async throws {
        let local = [entry("run"), entry("walk")]
        let harness = try await makeHarness(seed: local)
        let before = try Data(contentsOf: harness.paths.dictionaryURL)
        let url = try writeImportFile([entry("swim")], in: harness)
        harness.panels.importSource = url

        harness.model.beginImport()
        let noTask = harness.model.selectImportMode(.replace)

        XCTAssertNil(noTask, "replace does not start before confirmation")
        XCTAssertEqual(harness.model.importStage, .confirmReplace(url))
        XCTAssertEqual(try Data(contentsOf: harness.paths.dictionaryURL), before)
        XCTAssertEqual(try backupNames(harness), [])
        XCTAssertNil(harness.model.transferMessage)

        try await XCTUnwrap(harness.model.confirmReplaceImport()).value

        XCTAssertNil(harness.model.importStage)
        XCTAssertEqual(harness.model.entries.map(\.word), ["swim"])
        XCTAssertEqual(harness.model.lastReport?.summary, "Додано 1, оновлено 0, пропущено 0")
        XCTAssertEqual(harness.model.transferMessage?.text, "Додано 1, оновлено 0, пропущено 0")
        XCTAssertEqual(harness.model.transferMessage?.isError, false)
        let backups = try backupNames(harness)
        XCTAssertEqual(backups.count, 1)
        let backupName = try XCTUnwrap(backups.first)
        XCTAssertTrue(backupName.hasPrefix("dictionary-backup-") && backupName.hasSuffix(".json"), backupName)
        let backup = try Data(contentsOf: harness.paths.backupsDirectory.appendingPathComponent(backupName))
        XCTAssertEqual(backup, before, "backup is a byte copy of the previous dictionary")
    }

    @MainActor
    func testCancelReplaceKeepsDictionary() async throws {
        let harness = try await makeHarness(seed: [entry("run")])
        let before = try Data(contentsOf: harness.paths.dictionaryURL)
        harness.panels.importSource = try writeImportFile([entry("swim")], in: harness)

        harness.model.beginImport()
        harness.model.selectImportMode(.replace)
        harness.model.cancelImport()

        XCTAssertNil(harness.model.importStage)
        XCTAssertNil(harness.model.confirmReplaceImport())
        XCTAssertEqual(harness.model.entries.map(\.word), ["run"])
        XCTAssertEqual(try Data(contentsOf: harness.paths.dictionaryURL), before)
        XCTAssertEqual(try backupNames(harness), [])
    }

    // MARK: - Імпорт: помилки

    @MainActor
    func testImportInvalidSetsError() async throws {
        let local = [entry("run")]
        let harness = try await makeHarness(seed: local)
        let before = try Data(contentsOf: harness.paths.dictionaryURL)
        let cases: [(String, Data, ImportError)] = [
            ("not-json.json", Data("not json".utf8), .notJSON),
            ("empty.json", Data(), .emptyFile),
            ("v2.json", Data(#"{"schemaVersion":2,"entries":[]}"#.utf8), .unsupportedSchemaVersion(2)),
            ("array.json", Data("[]".utf8), .notJSON),
        ]

        for (name, data, expected) in cases {
            for mode in [ImportMode.merge, .replace] {
                harness.model.transferMessage = nil
                let url = try writeImportFile(data, in: harness, name: name)
                let report = await harness.model.`import`(from: url, mode: mode)

                XCTAssertNil(report, "\(name) \(mode)")
                let message = try XCTUnwrap(harness.model.transferMessage, "\(name) \(mode)")
                XCTAssertTrue(message.isError, "\(name) \(mode)")
                XCTAssertEqual(message.title, "Не вдалося імпортувати")
                XCTAssertEqual(message.text, expected.userMessage, "\(name) \(mode)")
                XCTAssertTrue(message.text.hasSuffix("Словник не змінено."), message.text)
            }
        }
        XCTAssertNil(harness.model.lastReport)
        XCTAssertEqual(harness.model.entries, local)
        XCTAssertEqual(try Data(contentsOf: harness.paths.dictionaryURL), before)
        XCTAssertEqual(try backupNames(harness), [])
        XCTAssertFalse(harness.model.isTransferring)
    }

    @MainActor
    func testImportInvalidViaDialogSetsError() async throws {
        let harness = try await makeHarness(seed: [entry("run")])
        harness.panels.importSource = try writeImportFile(Data("   \n".utf8), in: harness)

        harness.model.beginImport()
        try await XCTUnwrap(harness.model.selectImportMode(.merge)).value

        XCTAssertEqual(harness.model.transferMessage?.isError, true)
        XCTAssertEqual(harness.model.transferMessage?.text, "Файл порожній. Словник не змінено.")
        XCTAssertEqual(harness.model.entries.map(\.word), ["run"])
    }

    @MainActor
    func testImportSkippedInvalidEntriesListedInReport() async throws {
        let harness = try await makeHarness()
        let valid = try JSONSerialization.jsonObject(with: JSONCoding.makeEncoder().encode(entry("run")))
        let broken: [String: Any] = ["id": "bad", "word": "x"]
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "entries": [valid, broken]])
        let url = try writeImportFile(data, in: harness)

        let report = await harness.model.`import`(from: url, mode: .merge)

        XCTAssertEqual(report?.summary, "Додано 1, оновлено 0, пропущено 1")
        XCTAssertEqual(harness.model.transferMessage?.text,
                       "Додано 1, оновлено 0, пропущено 1\n\nПропущено:\n• Запис #2: некоректне поле id")
        XCTAssertEqual(harness.model.entries.map(\.word), ["run"])
    }

    @MainActor
    func testReportTextTruncatesSkipReasons() async {
        let reasons = (1...12).map { "Запис #\($0): відсутнє поле word" }
        let report = ImportReport(added: 0, updated: 0, skipped: 12, skippedReasons: reasons)

        let text = AppModel.reportText(report)

        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Додано 0, оновлено 0, пропущено 12")
        XCTAssertEqual(lines.filter { $0.hasPrefix("• ") }.count, AppModel.maxReportedSkipReasons)
        XCTAssertEqual(lines.last, "…та ще 2")
        XCTAssertEqual(AppModel.reportText(ImportReport(added: 2, updated: 1, skipped: 0)),
                       "Додано 2, оновлено 1, пропущено 0")
    }

    @MainActor
    func testTransferUnavailableWithoutService() async throws {
        let harness = try await makeHarness(withTransfer: false)
        XCTAssertFalse(harness.model.isTransferAvailable)
        harness.panels.exportDestination = harness.transferDirectory.appendingPathComponent("x.json")
        harness.panels.importSource = harness.transferDirectory.appendingPathComponent("x.json")

        await harness.model.exportWithPanel()
        harness.model.beginImport()

        XCTAssertEqual(harness.panels.exportRequests, [], "panel not shown when transfer is unavailable")
        XCTAssertEqual(harness.panels.importRequests, 0)
        XCTAssertNil(harness.model.importStage)

        let ok = await harness.model.export(to: harness.transferDirectory.appendingPathComponent("x.json"))
        XCTAssertFalse(ok)
        XCTAssertEqual(harness.model.transferMessage?.isError, true)
    }

    @MainActor
    func testExportThenImportOnAnotherMachine() async throws {
        let source = try await makeHarness(seed: [entry("run"), entry("walk", status: .pending), entry("give up")])
        let url = source.transferDirectory.appendingPathComponent("dictionary.json")
        source.panels.exportDestination = url
        await source.model.exportWithPanel()

        let target = try await makeHarness()
        target.panels.importSource = url
        target.model.beginImport()
        try await XCTUnwrap(target.model.selectImportMode(.merge)).value

        XCTAssertEqual(target.model.transferMessage?.text, "Додано 3, оновлено 0, пропущено 0")
        let byID: (Entry, Entry) -> Bool = { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(target.model.entries.sorted(by: byID), source.model.entries.sorted(by: byID))
        XCTAssertEqual(target.model.entries.count, 3)
    }
}
