import Foundation
import XCTest
@testable import VocabCore

/// M4: спільні помічники для тестів експорту/імпорту.
enum M4 {
    static let pair = "en-uk"

    /// `TestDates.reference + seconds`.
    static func date(_ seconds: TimeInterval) -> Date {
        TestDates.reference.addingTimeInterval(seconds)
    }

    /// Готовий запис з повним набором полів.
    static func entry(
        id: UUID = UUID(),
        pair: String = M4.pair,
        word: String,
        translations: [String]? = nil,
        status: EntryStatus = .ready,
        lastError: String? = nil,
        created: TimeInterval = 0,
        updated: TimeInterval = 0
    ) -> Entry {
        Entry(
            id: id,
            languagePair: pair,
            word: word,
            lemma: word,
            partOfSpeech: "verb",
            transcription: "/\(word)/",
            translations: translations ?? (status == .ready ? ["переклад-\(word)"] : []),
            example: status == .ready ? Example(source: "I \(word).", translation: "Я \(word).") : nil,
            status: status,
            lastError: lastError,
            createdAt: date(created),
            updatedAt: date(updated)
        )
    }

    /// Файл імпорту з записами, закодованими звичайним енкодером.
    static func fileData(_ entries: [Entry], schemaVersion: Int = 1) throws -> Data {
        try JSONCoding.makeEncoder().encode(
            DictionaryFile(schemaVersion: schemaVersion, exportedAt: date(0), entries: entries)
        )
    }

    /// Сирий JSON-об'єкт запису (для пошкодження окремих полів).
    static func rawEntry(_ entry: Entry) throws -> [String: Any] {
        try jsonObject(JSONCoding.makeEncoder().encode(entry))
    }

    /// `{"schemaVersion":1,"entries":[…]}` з сирих об'єктів.
    static func rawFileData(_ entries: [Any], schemaVersion: Any = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": schemaVersion, "entries": entries])
    }
}

/// Репозиторій + сховище + бекапи + сервіс перенесення в тимчасовому каталозі.
struct TransferFixture {
    let directory: TemporaryDirectory
    let fileSystem: FailingFileSystem
    let dates: FixedDateProvider
    let backups: BackupManager
    let store: FileDictionaryStore
    let repository: DictionaryRepository
    let service: DictionaryTransferService

    init() throws {
        directory = try TemporaryDirectory()
        fileSystem = FailingFileSystem()
        dates = FixedDateProvider(TestDates.reference)
        backups = BackupManager(
            directory: directory.paths.backupsDirectory,
            fileSystem: fileSystem,
            dateProvider: dates
        )
        store = FileDictionaryStore(
            fileURL: directory.paths.dictionaryURL,
            fileSystem: fileSystem,
            dateProvider: dates,
            backups: backups
        )
        repository = DictionaryRepository(store: store, dateProvider: dates)
        service = DictionaryTransferService(
            repository: repository,
            store: store,
            backups: backups,
            fileSystem: fileSystem,
            dateProvider: dates
        )
    }

    var dictionaryURL: URL { directory.paths.dictionaryURL }
    var backupsURL: URL { directory.paths.backupsDirectory }

    /// Каталог для файлів експорту/імпорту (поза каталогом словника).
    var transferDirectory: URL {
        directory.url.appendingPathComponent("transfer", isDirectory: true)
    }

    /// Записує `dictionary.json` з `entries` (через сховище) і завантажує репозиторій.
    func seed(_ entries: [Entry]) async throws {
        if !entries.isEmpty {
            try store.save(DictionaryFile(entries: entries))
        }
        _ = try await repository.load()
    }

    /// Пише файл імпорту і повертає його URL.
    func writeImportFile(_ data: Data, name: String = "import.json") throws -> URL {
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true)
        let url = transferDirectory.appendingPathComponent(name, isDirectory: false)
        try data.write(to: url)
        return url
    }

    func writeImportFile(_ string: String, name: String = "import.json") throws -> URL {
        try writeImportFile(Data(string.utf8), name: name)
    }

    func dictionaryBytes() throws -> Data {
        try Data(contentsOf: dictionaryURL)
    }

    /// Імена файлів у `Backups/` (порожньо, якщо каталогу нема).
    func backupNames() throws -> [String] {
        guard FileManager.default.fileExists(atPath: backupsURL.path) else { return [] }
        return try directory.fileNames(in: backupsURL)
    }

    /// Тимчасові файли `*.tmp` у каталозі.
    func tempFiles(in url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try directory.fileNames(in: url).filter { $0.hasSuffix(".tmp") }
    }

    func remove() {
        directory.remove()
    }
}

/// Перевіряє, що виклик кидає саме `expected` (`ImportError`).
func assertImportError<T>(
    _ expected: ImportError,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected), got success. \(message)", file: file, line: line)
    } catch let error as ImportError {
        XCTAssertEqual(error, expected, message, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error). \(message)", file: file, line: line)
    }
}

/// Синхронний варіант для `DictionaryImporter.parse`.
func assertParseError(
    _ expected: ImportError,
    _ data: Data,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try DictionaryImporter.parse(data), message, file: file, line: line) { error in
        XCTAssertEqual(error as? ImportError, expected, message, file: file, line: line)
    }
}
