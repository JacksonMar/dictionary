import Foundation
import XCTest
@testable import VocabCore

/// M1.3 — атомарний запис, читання, зіпсований файл, новіша схема.
final class FileDictionaryStoreTests: XCTestCase {
    private var fixture: StoreFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pinInterfaceLanguage(.uk)
        fixture = try StoreFixture()
    }

    override func tearDown() {
        fixture?.directory.remove()
        fixture = nil
        super.tearDown()
    }

    private var store: FileDictionaryStore { fixture.store }

    func testLoadMissingFileReturnsEmpty() throws {
        let result = try store.load()

        XCTAssertEqual(result.file, DictionaryFile.empty)
        XCTAssertEqual(result.file.schemaVersion, 1)
        XCTAssertNil(result.recoveredBackupURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path), "load must not create the file")
    }

    func testSaveThenLoad() throws {
        let file = DictionaryFile(exportedAt: nil, entries: [TestFixtures.entry(), TestFixtures.entry(word: "walk")])

        try store.save(file)
        let result = try store.load()

        XCTAssertNil(result.recoveredBackupURL)
        XCTAssertEqual(result.file.entries, file.entries)
        XCTAssertEqual(result.file.schemaVersion, 1)
    }

    func testSaveOverwritesExistingFile() throws {
        try store.save(DictionaryFile(entries: [TestFixtures.entry(word: "first")]))
        try store.save(DictionaryFile(entries: [TestFixtures.entry(word: "second")]))

        XCTAssertEqual(try store.load().file.entries.map(\.word), ["second"])
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testSaveCreatesDirectory() throws {
        let nested = fixture.directory.url
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("VocabApp", isDirectory: true)
        let store = FileDictionaryStore(
            fileURL: nested.appendingPathComponent("dictionary.json"),
            fileSystem: LocalFileSystem(),
            dateProvider: fixture.dateProvider,
            backups: BackupManager(directory: nested.appendingPathComponent("Backups"))
        )

        try store.save(DictionaryFile(entries: [TestFixtures.entry()]))

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("dictionary.json").path))
        XCTAssertEqual(try store.load().file.entries.count, 1)
    }

    func testSaveLeavesNoTemporaryFiles() throws {
        for index in 0..<5 {
            try store.save(DictionaryFile(entries: [TestFixtures.entry(word: "word\(index)")]))
        }

        XCTAssertEqual(try fixture.directory.fileNames(), ["dictionary.json"])
        // Кожен запис (і перший, коли цілі ще нема) — лише replaceItem (rename(2)); moveItem не використовується.
        let calls = fixture.fileSystem.recordedCalls
        XCTAssertEqual(calls.filter { $0 == .moveItem }.count, 0)
        XCTAssertEqual(calls.filter { $0 == .replaceItem }.count, 5)
        XCTAssertEqual(calls.filter { $0 == .writeData }.count, 5)
    }

    func testFailedReplaceKeepsOriginalAndRemovesTemp() throws {
        try store.save(DictionaryFile(entries: [TestFixtures.entry(word: "original")]))
        let originalBytes = try fixture.readRaw()

        fixture.fileSystem.fail(.replaceItem)
        XCTAssertThrowsError(try store.save(DictionaryFile(entries: [TestFixtures.entry(word: "changed")]))) { error in
            guard case StorageError.writeFailed = error else {
                return XCTFail("expected StorageError.writeFailed, got \(error)")
            }
        }

        XCTAssertEqual(try fixture.readRaw(), originalBytes, "original file must be byte-identical")
        XCTAssertEqual(try fixture.temporaryFiles(), [], "temp file must be removed")
        XCTAssertEqual(try fixture.directory.fileNames(), ["dictionary.json"])
        fixture.fileSystem.stopFailing()
        XCTAssertEqual(try store.load().file.entries.map(\.word), ["original"])
    }

    func testFailedTemporaryWriteKeepsOriginal() throws {
        try store.save(DictionaryFile(entries: [TestFixtures.entry(word: "original")]))
        let originalBytes = try fixture.readRaw()

        fixture.fileSystem.fail(.writeData)
        XCTAssertThrowsError(try store.save(DictionaryFile(entries: [TestFixtures.entry(word: "changed")]))) { error in
            guard case StorageError.writeFailed = error else {
                return XCTFail("expected StorageError.writeFailed, got \(error)")
            }
        }

        XCTAssertEqual(try fixture.readRaw(), originalBytes)
        XCTAssertEqual(try fixture.temporaryFiles(), [])
    }

    func testFailedFirstReplaceLeavesNoFiles() throws {
        // Цілі ще нема: перший запис теж іде через replaceItem; збій не лишає ні цілі, ні тимчасового файлу.
        fixture.fileSystem.fail(.replaceItem)

        XCTAssertThrowsError(try store.save(DictionaryFile(entries: [TestFixtures.entry()]))) { error in
            guard case StorageError.writeFailed = error else {
                return XCTFail("expected StorageError.writeFailed, got \(error)")
            }
        }

        XCTAssertEqual(try fixture.directory.fileNames(), [])
    }

    func testSaveUpdatesExportedAt() throws {
        let stale = TestDates.reference.addingTimeInterval(-86_400)
        fixture.dateProvider.advance(by: 3600)

        try store.save(DictionaryFile(exportedAt: stale, entries: []))

        let root = try jsonObject(fixture.readRaw())
        XCTAssertEqual(root["exportedAt"] as? String, "2026-10-13T11:00:00Z")
        XCTAssertEqual(try store.load().file.exportedAt, TestDates.reference.addingTimeInterval(3600))

        fixture.dateProvider.advance(by: 60)
        try store.save(DictionaryFile(exportedAt: nil, entries: []))
        XCTAssertEqual(try store.load().file.exportedAt, TestDates.reference.addingTimeInterval(3660))
    }

    func testSavedFileMatchesSchemaKeys() throws {
        try store.save(DictionaryFile(entries: [TestFixtures.entry()]))

        let root = try jsonObject(fixture.readRaw())
        XCTAssertEqual(Set(root.keys), ["schemaVersion", "exportedAt", "entries"])
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
    }

    func testCorruptedFileMovedToBackups() throws {
        try fixture.writeRaw("garbage {")

        let result = try store.load()

        XCTAssertEqual(result.file, DictionaryFile.empty)
        let backupURL = try XCTUnwrap(result.recoveredBackupURL)
        XCTAssertEqual(backupURL.deletingLastPathComponent().standardizedFileURL.path,
                       fixture.directory.paths.backupsDirectory.standardizedFileURL.path)
        XCTAssertEqual(backupURL.lastPathComponent, "dictionary-corrupted-20261013-100000.json")
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "garbage {")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path), "corrupted file must be moved")
    }

    func testCorruptedEntryContentMovedToBackups() throws {
        // Валідний JSON, але невідомий статус → помилка декодування → бекап.
        let json = TestFixtures.requirementsExample
            .replacingOccurrences(of: "\"status\": \"ready\"", with: "\"status\": \"done\"")
        try fixture.writeRaw(json)

        let result = try store.load()

        XCTAssertEqual(result.file.entries, [])
        XCTAssertNotNil(result.recoveredBackupURL)
    }

    func testEmptyFileTreatedAsCorrupted() throws {
        try fixture.writeRaw("")

        let result = try store.load()

        XCTAssertEqual(result.file.entries, [])
        XCTAssertNotNil(result.recoveredBackupURL)
    }

    func testCorruptedTwiceInSameSecondGetsSuffix() throws {
        try fixture.writeRaw("garbage 1")
        let first = try XCTUnwrap(try store.load().recoveredBackupURL)
        try fixture.writeRaw("garbage 2")
        let second = try XCTUnwrap(try store.load().recoveredBackupURL)

        XCTAssertEqual(first.lastPathComponent, "dictionary-corrupted-20261013-100000.json")
        XCTAssertEqual(second.lastPathComponent, "dictionary-corrupted-20261013-100000-2.json")
    }

    func testCorruptedBackupFailureThrowsAndKeepsFile() throws {
        try fixture.writeRaw("garbage")
        fixture.fileSystem.fail(.moveItem)

        XCTAssertThrowsError(try store.load()) { error in
            guard case StorageError.backupFailed = error else {
                return XCTFail("expected StorageError.backupFailed, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: fixture.fileURL, encoding: .utf8), "garbage")
    }

    func testNewerSchemaVersionThrowsAndKeepsFile() throws {
        let json = TestFixtures.requirementsExample
            .replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
        try fixture.writeRaw(json)
        let originalBytes = try fixture.readRaw()

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? StorageError, .unsupportedSchemaVersion(2))
        }

        XCTAssertEqual(try fixture.readRaw(), originalBytes, "file must not be touched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.paths.backupsDirectory.path),
                       "no backup for newer schema")
    }

    func testNewerSchemaVersionWithUnknownEntryFormatStillThrows() throws {
        // Новіший формат може мати інші записи — це не «зіпсований» файл.
        try fixture.writeRaw("{\"schemaVersion\": 5, \"items\": {\"x\": 1}}")

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? StorageError, .unsupportedSchemaVersion(5))
        }
        XCTAssertEqual(try fixture.directory.fileNames(), ["dictionary.json"])
    }

    func testUnsupportedSchemaVersionMessageIsUkrainian() {
        let message = StorageError.unsupportedSchemaVersion(2).userMessage
        XCTAssertTrue(message.contains("новішу версію схеми"))
        XCTAssertTrue(message.contains("2"))
    }

    func testConcurrentSavesProduceValidFileWithoutTemporaryFiles() throws {
        let store = self.store
        let iterations = 40
        // Без попереднього запису: файлу ще нема, усі паралельні записи — перші.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        let errors = ErrorCollector()

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            do {
                try store.save(DictionaryFile(entries: [TestFixtures.entry(word: "word\(index)")]))
            } catch {
                errors.append(error)
            }
        }

        XCTAssertEqual(errors.all.count, 0, "unexpected errors: \(errors.all)")
        let result = try store.load()
        XCTAssertNil(result.recoveredBackupURL, "file must never be left corrupted")
        XCTAssertEqual(result.file.entries.count, 1)
        let word = try XCTUnwrap(result.file.entries.first?.word)
        XCTAssertTrue(word.hasPrefix("word"))
        XCTAssertEqual(try fixture.directory.fileNames(), ["dictionary.json"])
    }
}

final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    func append(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        errors.append(error)
    }

    var all: [Error] {
        lock.lock(); defer { lock.unlock() }
        return errors
    }
}
