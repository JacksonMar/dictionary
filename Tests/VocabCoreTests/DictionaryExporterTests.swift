import Foundation
import XCTest
@testable import VocabCore

/// M4.4 — експорт: `schemaVersion: 1`, `exportedAt` = now, усі записи, атомарний запис, round-trip.
final class DictionaryExporterTests: XCTestCase {
    private var fixture: TransferFixture!

    private var sampleEntries: [Entry] = []

    override func setUpWithError() throws {
        fixture = try TransferFixture()
        sampleEntries = Self.makeSampleEntries()
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
    }

    private static func makeSampleEntries() -> [Entry] {
        [
            M4.entry(word: "run", created: 0, updated: 100),
            M4.entry(word: "give up", created: 10, updated: 10),
            M4.entry(word: "serendipity", status: .pending, lastError: "Немає з'єднання з інтернетом", created: 20, updated: 30),
            M4.entry(word: "xyzzy", status: .failed, lastError: "Модель не розпізнала слово", created: 40, updated: 50),
            Entry(languagePair: "en-uk", word: "minimal", translations: ["мінімальний"], status: .ready,
                  createdAt: M4.date(60), updatedAt: M4.date(60)),
            M4.entry(pair: "de-uk", word: "laufen", created: 70, updated: 70),
        ]
    }

    func testExportSetsExportedAt() async throws {
        try await fixture.seed(sampleEntries)
        let exportTime = M4.date(86_400 + 42)
        fixture.dates.current = exportTime
        let url = fixture.transferDirectory.appendingPathComponent("dictionary.json")

        try await fixture.service.exportDictionary(to: url)

        let data = try Data(contentsOf: url)
        let object = try jsonObject(data)
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["exportedAt"] as? String, "2026-10-14T10:00:42Z")
        XCTAssertEqual((object["entries"] as? [Any])?.count, sampleEntries.count)

        let file = try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: data)
        XCTAssertEqual(file.schemaVersion, DictionaryFile.currentSchemaVersion)
        XCTAssertEqual(file.exportedAt, exportTime)
        XCTAssertEqual(file.entries, sampleEntries, "all entries, in repository order")
    }

    func testExportDataPure() throws {
        let now = M4.date(5)
        let data = try DictionaryExporter.exportData(entries: sampleEntries, now: now)
        let expected = try JSONCoding.makeEncoder().encode(
            DictionaryFile(schemaVersion: 1, exportedAt: now, entries: sampleEntries)
        )
        XCTAssertEqual(data, expected, "same encoder settings as dictionary.json")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"), text)
        XCTAssertTrue(text.contains("\"exportedAt\" : \"2026-10-13T10:00:05Z\""), text)
    }

    func testExportEmptyDictionary() async throws {
        try await fixture.seed([])
        let url = fixture.transferDirectory.appendingPathComponent("empty.json")

        try await fixture.service.exportDictionary(to: url)

        let file = try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(file, DictionaryFile(schemaVersion: 1, exportedAt: TestDates.reference, entries: []))
        // Порожній експорт — валідний файл імпорту з нульовим звітом.
        XCTAssertEqual(try DictionaryImporter.parse(Data(contentsOf: url)), ParsedImport(entries: []))
    }

    func testExportImportRoundTrip() async throws {
        try await fixture.seed(sampleEntries)
        let url = fixture.transferDirectory.appendingPathComponent("dictionary.json")
        try await fixture.service.exportDictionary(to: url)

        // «Інший комп'ютер»: окремий каталог з порожнім словником.
        let other = try TransferFixture()
        defer { other.remove() }
        try await other.seed([])

        let report = try await other.service.importDictionary(from: url, mode: .merge)

        XCTAssertEqual(report, ImportReport(added: sampleEntries.count, updated: 0, skipped: 0, skippedReasons: []))
        XCTAssertEqual(report.summary, "Додано 6, оновлено 0, пропущено 0")
        let imported = await other.repository.allEntries()
        XCTAssertEqual(imported, sampleEntries, "ids, dates, statuses and optional fields identical")
        XCTAssertEqual(try other.store.load().file.entries, sampleEntries)

        // Повторний імпорт того самого файлу нічого не змінює.
        let again = try await other.service.importDictionary(from: url, mode: .merge)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.updated, 0)
        XCTAssertEqual(again.skipped, sampleEntries.count)
        let unchanged = await other.repository.allEntries()
        XCTAssertEqual(unchanged, sampleEntries)
    }

    func testExportImportReplaceRoundTrip() async throws {
        try await fixture.seed(sampleEntries)
        let url = fixture.transferDirectory.appendingPathComponent("dictionary.json")
        try await fixture.service.exportDictionary(to: url)

        let other = try TransferFixture()
        defer { other.remove() }
        try await other.seed([M4.entry(word: "local-only")])

        let report = try await other.service.importDictionary(from: url, mode: .replace)

        XCTAssertEqual(report.added, sampleEntries.count)
        let imported = await other.repository.allEntries()
        XCTAssertEqual(imported, sampleEntries)
        XCTAssertEqual(try other.backupNames().count, 1)
    }

    func testExportWritesAtomically() async throws {
        try await fixture.seed(sampleEntries)
        let url = fixture.transferDirectory.appendingPathComponent("dictionary.json")

        try await fixture.service.exportDictionary(to: url)
        XCTAssertEqual(try fixture.directory.fileNames(in: fixture.transferDirectory), ["dictionary.json"],
                       "no temp leftovers")
        let first = try Data(contentsOf: url)

        // Перезапис наявного файлу — теж без залишків.
        fixture.dates.advance(by: 60)
        try await fixture.service.exportDictionary(to: url)
        XCTAssertEqual(try fixture.directory.fileNames(in: fixture.transferDirectory), ["dictionary.json"])
        let second = try Data(contentsOf: url)
        XCTAssertNotEqual(first, second, "exportedAt advanced")

        // Збій заміни: попередній файл експорту не пошкоджено, тимчасовий файл прибрано.
        fixture.dates.advance(by: 60)
        fixture.fileSystem.fail(.replaceItem)
        do {
            try await fixture.service.exportDictionary(to: url)
            XCTFail("expected writeFailed")
        } catch let error as StorageError {
            guard case .writeFailed = error else { return XCTFail("expected writeFailed, got \(error)") }
        }
        fixture.fileSystem.stopFailing()
        XCTAssertEqual(try Data(contentsOf: url), second)
        XCTAssertEqual(try fixture.directory.fileNames(in: fixture.transferDirectory), ["dictionary.json"])

        // Збій запису тимчасового файлу: цільовий файл ще не існує → і не з'являється.
        let fresh = fixture.transferDirectory.appendingPathComponent("fresh.json")
        fixture.fileSystem.fail(.writeData)
        do {
            try await fixture.service.exportDictionary(to: fresh)
            XCTFail("expected writeFailed")
        } catch let error as StorageError {
            guard case .writeFailed = error else { return XCTFail("expected writeFailed, got \(error)") }
        }
        fixture.fileSystem.stopFailing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(try fixture.directory.fileNames(in: fixture.transferDirectory), ["dictionary.json"])
    }

    func testExportUsesTempFileInTargetDirectory() async throws {
        try await fixture.seed(sampleEntries)
        let url = fixture.transferDirectory.appendingPathComponent("dictionary.json")
        let before = fixture.fileSystem.recordedCalls.count

        try await fixture.service.exportDictionary(to: url)

        let calls = Array(fixture.fileSystem.recordedCalls.dropFirst(before))
        XCTAssertEqual(calls.filter { $0 != .createDirectory }, [.writeData, .replaceItem],
                       "write to temp, then atomic rename")
    }

    func testExportDoesNotModifyDictionary() async throws {
        try await fixture.seed(sampleEntries)
        let before = try fixture.dictionaryBytes()
        fixture.dates.advance(by: 600)

        try await fixture.service.exportDictionary(to: fixture.transferDirectory.appendingPathComponent("x.json"))

        XCTAssertEqual(try fixture.dictionaryBytes(), before)
        XCTAssertEqual(try fixture.backupNames(), [])
    }

    func testExportBeforeLoadNotLoaded() async throws {
        try fixture.store.save(DictionaryFile(entries: sampleEntries))
        let url = fixture.transferDirectory.appendingPathComponent("dictionary.json")

        do {
            try await fixture.service.exportDictionary(to: url)
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .notLoaded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no empty export written")

        do {
            _ = try await fixture.repository.loadedEntries()
            XCTFail("expected notLoaded")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .notLoaded)
        }
        _ = try await fixture.repository.load()
        let loaded = try await fixture.repository.loadedEntries()
        XCTAssertEqual(loaded, sampleEntries)
    }
}
