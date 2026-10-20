import Foundation
import XCTest
@testable import VocabCore

/// M4.3 — імпорт через `DictionaryTransferService`: merge/replace, бекап, ротація, незмінність словника при помилках.
final class DictionaryTransferServiceTests: XCTestCase {
    private var fixture: TransferFixture!

    /// Локальні записи (фіксовані id на один тест).
    private var localEntries: [Entry] = []

    override func setUpWithError() throws {
        pinInterfaceLanguage(.uk)
        fixture = try TransferFixture()
        localEntries = [
            M4.entry(word: "run", updated: 10),
            M4.entry(word: "walk", updated: 10),
        ]
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
    }

    // MARK: - Replace

    func testReplaceCreatesBackupThenReplaces() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()
        let imported = [M4.entry(word: "swim", updated: 5), M4.entry(word: "fly", status: .pending, updated: 6)]
        let url = try fixture.writeImportFile(M4.fileData(imported))
        fixture.dates.advance(by: 3600)

        let report = try await fixture.service.importDictionary(from: url, mode: .replace)

        XCTAssertEqual(report, ImportReport(added: 2, updated: 0, skipped: 0, skippedReasons: []))
        XCTAssertEqual(report.summary, "Додано 2, оновлено 0, пропущено 0")

        // Бекап — точна копія старого файлу.
        let names = try fixture.backupNames()
        XCTAssertEqual(names, ["dictionary-backup-20261013-110000.json"])
        let backup = try Data(contentsOf: fixture.backupsURL.appendingPathComponent(names[0]))
        XCTAssertEqual(backup, before)
        XCTAssertEqual(try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: backup).entries, localEntries)

        // Повна заміна: і в пам'яті, і на диску.
        let repositoryEntries = await fixture.repository.allEntries()
        XCTAssertEqual(repositoryEntries, imported)
        XCTAssertEqual(try fixture.store.load().file.entries, imported)
        XCTAssertEqual(try fixture.tempFiles(in: fixture.directory.url), [])
    }

    func testReplaceWithoutExistingFileMakesNoBackup() async throws {
        try await fixture.seed([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dictionaryURL.path))
        let imported = [M4.entry(word: "swim")]
        let url = try fixture.writeImportFile(M4.fileData(imported))

        let report = try await fixture.service.importDictionary(from: url, mode: .replace)

        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(try fixture.backupNames(), [])
        XCTAssertEqual(try fixture.store.load().file.entries, imported)
    }

    func testReplaceCollapsesDuplicatesAndCountsInvalid() async throws {
        try await fixture.seed(localEntries)
        let older = M4.entry(word: "swim", translations: ["старе"], updated: 1)
        let newer = M4.entry(word: "Swim", translations: ["нове"], updated: 2)
        var broken = try M4.rawEntry(M4.entry(word: "bad"))
        broken["status"] = "unknown"
        let url = try fixture.writeImportFile(M4.rawFileData([M4.rawEntry(older), broken, M4.rawEntry(newer)]))

        let report = try await fixture.service.importDictionary(from: url, mode: .replace)

        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped, 2)
        XCTAssertEqual(report.skippedReasons.first, "Запис #2: некоректне поле status")
        XCTAssertEqual(report.summary, "Додано 1, оновлено 0, пропущено 2")
        let entries = await fixture.repository.allEntries()
        XCTAssertEqual(entries, [newer])
    }

    func testReplaceWithEmptyEntriesClearsDictionaryAfterBackup() async throws {
        try await fixture.seed(localEntries)
        let url = try fixture.writeImportFile(#"{"schemaVersion":1,"entries":[]}"#)

        let report = try await fixture.service.importDictionary(from: url, mode: .replace)

        XCTAssertEqual(report, ImportReport())
        XCTAssertEqual(report.summary, "Додано 0, оновлено 0, пропущено 0")
        let entries = await fixture.repository.allEntries()
        XCTAssertEqual(entries, [])
        XCTAssertEqual(try fixture.backupNames().count, 1)
    }

    func testBackupFileNaming() async throws {
        try await fixture.seed(localEntries)
        let url = try fixture.writeImportFile(M4.fileData([M4.entry(word: "swim")]))
        let pattern = try NSRegularExpression(pattern: #"^dictionary-backup-\d{8}-\d{6}(-\d+)?\.json$"#)

        _ = try await fixture.service.importDictionary(from: url, mode: .replace)
        // Ще одна заміна в ту саму секунду → суфікс колізії.
        _ = try await fixture.service.importDictionary(from: url, mode: .replace)
        fixture.dates.advance(by: 86_400 + 3_661) // 2026-10-14 11:01:01 UTC
        _ = try await fixture.service.importDictionary(from: url, mode: .replace)

        let names = try fixture.backupNames()
        XCTAssertEqual(names, [
            "dictionary-backup-20261013-100000-2.json",
            "dictionary-backup-20261013-100000.json",
            "dictionary-backup-20261014-110101.json",
        ])
        for name in names {
            let range = NSRange(name.startIndex..., in: name)
            XCTAssertNotNil(pattern.firstMatch(in: name, range: range), name)
        }
    }

    func testBackupRetentionKeepsTen() async throws {
        try await fixture.seed(localEntries)
        // Чужий файл і копія зіпсованого словника не чіпаються ротацією.
        try FileManager.default.createDirectory(at: fixture.backupsURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: fixture.backupsURL.appendingPathComponent("dictionary-corrupted-20200101-000000.json"))
        try Data("note".utf8).write(to: fixture.backupsURL.appendingPathComponent("notes.txt"))

        var contents: [String: Data] = [:]
        for index in 0..<12 {
            fixture.dates.current = M4.date(TimeInterval(index * 60))
            let stamp = BackupManager.timestamp(for: fixture.dates.now())
            contents["dictionary-backup-\(stamp).json"] = try fixture.dictionaryBytes()
            let url = try fixture.writeImportFile(M4.fileData([M4.entry(word: "word\(index)")]))
            _ = try await fixture.service.importDictionary(from: url, mode: .replace)
        }

        let backups = try fixture.backupNames().filter { $0.hasPrefix("dictionary-backup-") }
        let expected = (2..<12).map { "dictionary-backup-20261013-10\(String(format: "%02d", $0))00.json" }
        XCTAssertEqual(backups, expected, "the 10 newest kept, the 2 oldest removed")
        for name in backups {
            let data = try Data(contentsOf: fixture.backupsURL.appendingPathComponent(name))
            XCTAssertEqual(data, contents[name], "\(name) is a byte copy of the dictionary before that import")
        }
        let others = try fixture.backupNames().filter { !$0.hasPrefix("dictionary-backup-") }
        XCTAssertEqual(others, ["dictionary-corrupted-20200101-000000.json", "notes.txt"])
        let entries = await fixture.repository.allEntries()
        XCTAssertEqual(entries.map(\.word), ["word11"])
    }

    func testBackupFailureLeavesDictionaryUntouched() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()
        let url = try fixture.writeImportFile(M4.fileData([M4.entry(word: "swim")]))

        for operation in [FailingFileSystem.Operation.copyItem, .createDirectory] {
            let callsBefore = fixture.fileSystem.recordedCalls.count
            fixture.fileSystem.fail(operation)
            await assertImportError(
                .backupFailed("The operation could not be completed. (VocabCoreTests.FailingFileSystem.InjectedError error 1.)"),
                "\(operation)",
                isAnyBackupFailure: true
            ) {
                try await self.fixture.service.importDictionary(from: url, mode: .replace)
            }
            fixture.fileSystem.stopFailing()

            XCTAssertEqual(try fixture.dictionaryBytes(), before, "\(operation)")
            let entries = await fixture.repository.allEntries()
            XCTAssertEqual(entries, localEntries, "\(operation)")
            XCTAssertEqual(try fixture.backupNames().filter { $0.hasPrefix("dictionary-backup-") }, [], "\(operation)")
            let calls = fixture.fileSystem.recordedCalls.dropFirst(callsBefore)
            XCTAssertFalse(calls.contains(.writeData), "nothing written after failed backup: \(Array(calls))")
            XCTAssertFalse(calls.contains(.replaceItem), "nothing written after failed backup: \(Array(calls))")
        }

        // Після усунення збою імпорт працює.
        let report = try await fixture.service.importDictionary(from: url, mode: .replace)
        XCTAssertEqual(report.added, 1)
    }

    func testBackupFailedMessageIsUkrainian() async throws {
        try await fixture.seed(localEntries)
        let url = try fixture.writeImportFile(M4.fileData([M4.entry(word: "swim")]))
        fixture.fileSystem.fail(.copyItem)

        do {
            _ = try await fixture.service.importDictionary(from: url, mode: .replace)
            XCTFail("expected backupFailed")
        } catch let error as ImportError {
            guard case .backupFailed = error else {
                return XCTFail("expected backupFailed, got \(error)")
            }
            XCTAssertTrue(error.userMessage.hasPrefix("Не вдалося створити резервну копію поточного словника ("),
                          error.userMessage)
            XCTAssertTrue(error.userMessage.hasSuffix("Словник не змінено."), error.userMessage)
            XCTAssertFalse(error.userMessage.contains("Не вдалося створити резервну копію: "),
                           "StorageError prefix is stripped: \(error.userMessage)")
        }
    }

    // MARK: - Невалідний файл

    private static let fileLevelFailures: [(name: String, data: Data, error: ImportError)] = [
        ("zero bytes", Data(), .emptyFile),
        ("whitespace", Data(" \n\t\n ".utf8), .emptyFile),
        ("not JSON", Data("not json at all".utf8), .notJSON),
        ("top-level array", Data(#"[{"schemaVersion":1,"entries":[]}]"#.utf8), .notJSON),
        ("missing schemaVersion", Data(#"{"entries":[]}"#.utf8), .missingSchemaVersion),
        ("schemaVersion 2", Data(#"{"schemaVersion":2,"entries":[]}"#.utf8), .unsupportedSchemaVersion(2)),
        ("schemaVersion 0", Data(#"{"schemaVersion":0,"entries":[]}"#.utf8), .unsupportedSchemaVersion(0)),
        ("schemaVersion \"1\"", Data(#"{"schemaVersion":"1","entries":[]}"#.utf8), .missingSchemaVersion),
        ("schemaVersion 1.5", Data(#"{"schemaVersion":1.5,"entries":[]}"#.utf8), .missingSchemaVersion),
        ("missing entries", Data(#"{"schemaVersion":1}"#.utf8), .missingEntries),
        ("entries object", Data(#"{"schemaVersion":1,"entries":{"a":1}}"#.utf8), .missingEntries),
    ]

    func testInvalidFileLeavesDictionaryUntouched() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()

        for mode in [ImportMode.merge, .replace] {
            for failure in Self.fileLevelFailures {
                let label = "\(mode) / \(failure.name)"
                let url = try fixture.writeImportFile(failure.data, name: "bad.json")

                await assertImportError(failure.error, label) {
                    try await self.fixture.service.importDictionary(from: url, mode: mode)
                }
                XCTAssertTrue(failure.error.userMessage.hasSuffix("Словник не змінено."), label)

                XCTAssertEqual(try fixture.dictionaryBytes(), before, label)
                let entries = await fixture.repository.allEntries()
                XCTAssertEqual(entries, localEntries, label)
                XCTAssertEqual(try fixture.backupNames(), [], "no backup for a rejected file: \(label)")
                XCTAssertEqual(try fixture.tempFiles(in: fixture.directory.url), [], label)
            }
        }
    }

    func testMissingImportFileRejected() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()
        let url = fixture.transferDirectory.appendingPathComponent("absent.json")

        for mode in [ImportMode.merge, .replace] {
            do {
                _ = try await fixture.service.importDictionary(from: url, mode: mode)
                XCTFail("expected readFailed")
            } catch let error as ImportError {
                guard case .readFailed = error else {
                    return XCTFail("expected readFailed, got \(error)")
                }
                XCTAssertTrue(error.userMessage.hasPrefix("Не вдалося прочитати файл: "), error.userMessage)
                XCTAssertTrue(error.userMessage.hasSuffix("Словник не змінено."), error.userMessage)
            }
        }
        XCTAssertEqual(try fixture.dictionaryBytes(), before)
        XCTAssertEqual(try fixture.backupNames(), [])
    }

    func testImportBeforeLoadRejected() async throws {
        try fixture.store.save(DictionaryFile(entries: localEntries))
        let before = try fixture.dictionaryBytes()
        let url = try fixture.writeImportFile(M4.fileData([M4.entry(word: "swim")]))

        for mode in [ImportMode.merge, .replace] {
            await assertImportError(.storage("Словник ще не завантажено"), "\(mode)") {
                try await self.fixture.service.importDictionary(from: url, mode: mode)
            }
        }
        XCTAssertEqual(ImportError.storage("Словник ще не завантажено").userMessage,
                       "Словник ще не завантажено. Словник не змінено.")
        XCTAssertEqual(try fixture.dictionaryBytes(), before)
        XCTAssertEqual(try fixture.backupNames(), [], "no backup when the repository is not loaded")
    }

    func testInvalidEntriesSkippedWhileValidImported() async throws {
        try await fixture.seed(localEntries)
        let good1 = M4.entry(word: "swim")
        let good2 = M4.entry(word: "fly", status: .pending)
        var missingField = try M4.rawEntry(M4.entry(word: "a")); missingField["word"] = nil
        var badUUID = try M4.rawEntry(M4.entry(word: "b")); badUUID["id"] = "123"
        var badDate = try M4.rawEntry(M4.entry(word: "c")); badDate["createdAt"] = "yesterday"
        var badStatus = try M4.rawEntry(M4.entry(word: "d")); badStatus["status"] = "done"
        var noTranslations = try M4.rawEntry(M4.entry(word: "e")); noTranslations["translations"] = [String]()
        let data = try M4.rawFileData([
            missingField, M4.rawEntry(good1), badUUID, badDate, badStatus, M4.rawEntry(good2), noTranslations,
        ])
        let url = try fixture.writeImportFile(data)

        let report = try await fixture.service.importDictionary(from: url, mode: .merge)

        XCTAssertEqual(report.added, 2)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped, 5)
        XCTAssertEqual(report.skippedReasons, [
            "Запис #1: відсутнє поле word",
            "Запис #3: некоректне поле id",
            "Запис #4: некоректне поле createdAt",
            "Запис #5: некоректне поле status",
            "Запис #7: готовий запис без перекладів",
        ])
        XCTAssertEqual(report.summary, "Додано 2, оновлено 0, пропущено 5")
        let entries = await fixture.repository.allEntries()
        XCTAssertEqual(entries, localEntries + [good1, good2])
        XCTAssertEqual(try fixture.store.load().file.entries, localEntries + [good1, good2])
    }

    // MARK: - Merge

    func testMergeWithConflictsThroughService() async throws {
        let id = UUID()
        let local = [
            M4.entry(id: id, word: "run", translations: ["бігти"], updated: 10),
            M4.entry(word: "walk", translations: ["йти"], updated: 30),
        ]
        try await fixture.seed(local)
        let importedRun = M4.entry(id: id, word: "run", translations: ["бігти", "керувати"], updated: 20)
        let importedWalk = M4.entry(word: "Walk", translations: ["старе"], updated: 20)
        let importedNew = M4.entry(word: "swim", updated: 1)
        let url = try fixture.writeImportFile(M4.fileData([importedRun, importedWalk, importedNew]))

        let report = try await fixture.service.importDictionary(from: url, mode: .merge)

        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.summary, "Додано 1, оновлено 1, пропущено 1")
        let expected = [importedRun, local[1], importedNew]
        let entries = await fixture.repository.allEntries()
        XCTAssertEqual(entries, expected)
        XCTAssertEqual(try fixture.store.load().file.entries, expected)
        XCTAssertEqual(try fixture.backupNames(), [], "merge makes no backup")
    }

    func testMergePersistsAtomically() async throws {
        try await fixture.seed(localEntries)
        let imported = [M4.entry(word: "swim")]
        let url = try fixture.writeImportFile(M4.fileData(imported))

        // Збій атомарної заміни → словник (файл і пам'ять) не змінено, тимчасових файлів нема.
        let before = try fixture.dictionaryBytes()
        fixture.fileSystem.fail(.replaceItem)
        do {
            _ = try await fixture.service.importDictionary(from: url, mode: .merge)
            XCTFail("expected storage error")
        } catch let error as ImportError {
            guard case .storage(let reason) = error else {
                return XCTFail("expected storage, got \(error)")
            }
            XCTAssertTrue(reason.hasPrefix("Не вдалося зберегти словник: "), reason)
            XCTAssertTrue(error.userMessage.hasSuffix("Словник не змінено."), error.userMessage)
        }
        fixture.fileSystem.stopFailing()
        XCTAssertEqual(try fixture.dictionaryBytes(), before)
        var entries = await fixture.repository.allEntries()
        XCTAssertEqual(entries, localEntries)
        XCTAssertEqual(try fixture.tempFiles(in: fixture.directory.url), [])

        // Успішний merge: один запис на диск (writeData → replaceItem), файл = стан репозиторію.
        let callsBefore = fixture.fileSystem.recordedCalls.count
        let report = try await fixture.service.importDictionary(from: url, mode: .merge)
        XCTAssertEqual(report.added, 1)
        let calls = Array(fixture.fileSystem.recordedCalls.dropFirst(callsBefore))
        XCTAssertEqual(calls.filter { $0 == .writeData }.count, 1, "\(calls)")
        XCTAssertEqual(calls.filter { $0 == .replaceItem }.count, 1, "\(calls)")
        entries = await fixture.repository.allEntries()
        XCTAssertEqual(try fixture.store.load().file.entries, entries)
        XCTAssertEqual(entries, localEntries + imported)
        XCTAssertEqual(try fixture.tempFiles(in: fixture.directory.url), [])
    }

    func testReplaceStorageFailureLeavesDictionaryUntouched() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()
        let url = try fixture.writeImportFile(M4.fileData([M4.entry(word: "swim")]))
        fixture.fileSystem.fail(.replaceItem)

        do {
            _ = try await fixture.service.importDictionary(from: url, mode: .replace)
            XCTFail("expected storage error")
        } catch let error as ImportError {
            guard case .storage = error else { return XCTFail("expected storage, got \(error)") }
        }
        fixture.fileSystem.stopFailing()

        XCTAssertEqual(try fixture.dictionaryBytes(), before)
        let entries = await fixture.repository.allEntries()
        XCTAssertEqual(entries, localEntries)
        XCTAssertEqual(try fixture.tempFiles(in: fixture.directory.url), [])
    }

    func testMergeWithNothingNewDoesNotRewriteFile() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()
        fixture.dates.advance(by: 60)
        let url = try fixture.writeImportFile(M4.fileData(localEntries))

        let report = try await fixture.service.importDictionary(from: url, mode: .merge)

        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped, 2)
        XCTAssertEqual(report.summary, "Додано 0, оновлено 0, пропущено 2")
        XCTAssertEqual(try fixture.dictionaryBytes(), before, "exportedAt not bumped: no write at all")
    }

    func testEmptyEntriesFileReportsZero() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()
        let url = try fixture.writeImportFile(#"{"schemaVersion":1,"entries":[]}"#)

        let report = try await fixture.service.importDictionary(from: url, mode: .merge)

        XCTAssertEqual(report, ImportReport(added: 0, updated: 0, skipped: 0, skippedReasons: []))
        XCTAssertEqual(report.summary, "Додано 0, оновлено 0, пропущено 0")
        XCTAssertEqual(try fixture.dictionaryBytes(), before)
    }

    func testEmptyFileRejectedBothModes() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()
        for (name, data) in [("zero", Data()), ("spaces", Data("   \n\n".utf8))] {
            let url = try fixture.writeImportFile(data, name: "\(name).json")
            for mode in [ImportMode.merge, .replace] {
                await assertImportError(.emptyFile, "\(name) \(mode)") {
                    try await self.fixture.service.importDictionary(from: url, mode: mode)
                }
            }
        }
        XCTAssertEqual(try fixture.dictionaryBytes(), before)
        XCTAssertEqual(try fixture.backupNames(), [])
    }

    func testOtherSchemaVersionsRejectedBothModes() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()
        let entry = try M4.rawEntry(M4.entry(word: "swim"))
        let cases: [(Any?, ImportError)] = [
            (2, .unsupportedSchemaVersion(2)),
            (0, .unsupportedSchemaVersion(0)),
            (nil, .missingSchemaVersion),
            ("1", .missingSchemaVersion),
            (1.5, .missingSchemaVersion),
        ]
        for (version, expected) in cases {
            var object: [String: Any] = ["entries": [entry]]
            object["schemaVersion"] = version
            let url = try fixture.writeImportFile(JSONSerialization.data(withJSONObject: object))
            for mode in [ImportMode.merge, .replace] {
                await assertImportError(expected, "\(String(describing: version)) \(mode)") {
                    try await self.fixture.service.importDictionary(from: url, mode: mode)
                }
            }
        }
        XCTAssertEqual(try fixture.dictionaryBytes(), before)
        let entries = await fixture.repository.allEntries()
        XCTAssertEqual(entries, localEntries)
        XCTAssertEqual(try fixture.backupNames(), [])
    }

    func testRepositoryMergeImportedRequiresLoad() async throws {
        do {
            _ = try await fixture.repository.mergeImported([M4.entry(word: "run")])
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .notLoaded)
        }
    }

    func testRepositoryReplaceAllBeforeSaveErrorPropagatesAndNothingWritten() async throws {
        try await fixture.seed(localEntries)
        let before = try fixture.dictionaryBytes()
        struct Boom: Error {}
        do {
            try await fixture.repository.replaceAll([M4.entry(word: "swim")]) { throw Boom() }
            XCTFail("expected Boom")
        } catch {
            XCTAssertTrue(error is Boom, "\(error)")
        }
        XCTAssertEqual(try fixture.dictionaryBytes(), before)
        let entries = await fixture.repository.allEntries()
        XCTAssertEqual(entries, localEntries)
    }

    func testRepositoryMergeBroadcastsChange() async throws {
        try await fixture.seed(localEntries)
        let stream = await fixture.repository.changes()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // поточний знімок
        let swim = M4.entry(word: "swim")

        _ = try await fixture.repository.mergeImported([swim])

        let snapshot = await iterator.next()
        XCTAssertEqual(snapshot, localEntries + [swim])
    }
}

/// Варіант `assertImportError`, що приймає будь-який `.backupFailed(_)` (текст причини залежить від платформи).
private func assertImportError<T>(
    _ expected: ImportError,
    _ message: String,
    isAnyBackupFailure: Bool,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected), got success. \(message)", file: file, line: line)
    } catch let error as ImportError {
        if isAnyBackupFailure, case .backupFailed = error, case .backupFailed = expected {
            return
        }
        XCTAssertEqual(error, expected, message, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error). \(message)", file: file, line: line)
    }
}
