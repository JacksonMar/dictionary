import Foundation
import XCTest
@testable import VocabCore

/// Унікальний тимчасовий каталог `temporaryDirectory/<UUID>`; видаляється в `remove()`.
/// Тести ніколи не працюють з реальним `~/Library`.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var paths: AppPaths { AppPaths(applicationSupportDirectory: url) }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Імена файлів у каталозі (включно з прихованими).
    func fileNames(in directory: URL? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (directory ?? url).path).sorted()
    }
}

/// Обгортка над `LocalFileSystem` з ін'єкцією збоїв (§14).
final class FailingFileSystem: FileSystem, @unchecked Sendable {
    enum Operation: Hashable {
        case writeData, replaceItem, moveItem, copyItem, createDirectory, readData
    }

    struct InjectedError: Error, Equatable {
        let operation: Operation
    }

    private let base = LocalFileSystem()
    private let lock = NSLock()
    private var failing: Set<Operation> = []
    private var calls: [Operation] = []

    func fail(_ operation: Operation) {
        lock.lock(); defer { lock.unlock() }
        failing.insert(operation)
    }

    func stopFailing() {
        lock.lock(); defer { lock.unlock() }
        failing.removeAll()
    }

    var recordedCalls: [Operation] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    private func check(_ operation: Operation) throws {
        lock.lock(); defer { lock.unlock() }
        calls.append(operation)
        if failing.contains(operation) {
            throw InjectedError(operation: operation)
        }
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }

    func readData(at url: URL) throws -> Data {
        try check(.readData)
        return try base.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try check(.writeData)
        try base.writeData(data, to: url)
    }

    func replaceItem(at target: URL, withItemAt temp: URL) throws {
        try check(.replaceItem)
        try base.replaceItem(at: target, withItemAt: temp)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try check(.moveItem)
        try base.moveItem(at: source, to: destination)
    }

    func copyItem(at source: URL, to destination: URL) throws {
        try check(.copyItem)
        try base.copyItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws { try base.removeItem(at: url) }

    func createDirectory(at url: URL) throws {
        try check(.createDirectory)
        try base.createDirectory(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
}

enum TestDates {
    /// `2026-10-13T10:00:00Z`.
    static let reference: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 13
        components.hour = 10
        components.minute = 0
        components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        guard let date = calendar.date(from: components) else {
            preconditionFailure("invalid reference date")
        }
        return date
    }()
}

enum TestFixtures {
    static let entryID = "6F1C2A4E-8B7D-4C3A-9E2F-1A2B3C4D5E6F"

    /// Приклад зі схеми вимог (docs/REQUIREMENTS.md) з конкретними значеннями.
    static let requirementsExample = """
    {
      "schemaVersion": 1,
      "exportedAt": "2026-10-13T10:00:00Z",
      "entries": [
        {
          "id": "\(entryID)", "languagePair": "en-uk", "word": "run", "lemma": "run",
          "partOfSpeech": "verb", "transcription": "/rʌn/", "translations": ["бігти", "керувати"],
          "example": { "source": "She runs every morning.", "translation": "Вона бігає щоранку." },
          "status": "ready",
          "createdAt": "2026-10-13T10:00:00Z", "updatedAt": "2026-10-13T11:30:15Z"
        }
      ]
    }
    """

    static func entry(
        id: UUID = UUID(),
        languagePair: String = "en-uk",
        word: String = "run",
        status: EntryStatus = .ready,
        date: Date = TestDates.reference
    ) -> Entry {
        Entry(
            id: id,
            languagePair: languagePair,
            word: word,
            lemma: word,
            partOfSpeech: "verb",
            transcription: "/rʌn/",
            translations: ["бігти", "керувати"],
            example: Example(source: "She runs every morning.", translation: "Вона бігає щоранку."),
            status: status,
            lastError: nil,
            createdAt: date,
            updatedAt: date
        )
    }

    static func draft(word: String, languagePair: String = "en-uk") -> EntryDraft {
        EntryDraft(
            word: word,
            languagePair: languagePair,
            lemma: word,
            partOfSpeech: "verb",
            transcription: "/rʌn/",
            translations: ["бігти"],
            example: Example(source: "I run.", translation: "Я біжу."),
            status: .ready
        )
    }
}

/// Сховище `dictionary.json` + бекапи в тимчасовому каталозі.
struct StoreFixture {
    let directory: TemporaryDirectory
    let fileSystem: FailingFileSystem
    let dateProvider: FixedDateProvider
    let store: FileDictionaryStore

    init() throws {
        directory = try TemporaryDirectory()
        fileSystem = FailingFileSystem()
        dateProvider = FixedDateProvider(TestDates.reference)
        let backups = BackupManager(
            directory: directory.paths.backupsDirectory,
            fileSystem: fileSystem,
            dateProvider: dateProvider
        )
        store = FileDictionaryStore(
            fileURL: directory.paths.dictionaryURL,
            fileSystem: fileSystem,
            dateProvider: dateProvider,
            backups: backups
        )
    }

    var fileURL: URL { directory.paths.dictionaryURL }

    func writeRaw(_ string: String) throws {
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        try Data(string.utf8).write(to: fileURL)
    }

    func readRaw() throws -> Data {
        try Data(contentsOf: fileURL)
    }

    /// Імена тимчасових файлів `.dictionary.json.*.tmp` у каталозі словника.
    func temporaryFiles() throws -> [String] {
        try directory.fileNames().filter { $0.hasSuffix(".tmp") }
    }
}

func jsonObject(_ data: Data) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dictionary = object as? [String: Any] else {
        throw NSError(domain: "TestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a JSON object"])
    }
    return dictionary
}

extension XCTestCase {
    /// M9 (D39): фіксує мову інтерфейсу для набору, що перевіряє тексти певною мовою.
    /// Викликати в `setUp`; після тесту мова повертається до `.en` (значення за замовчуванням).
    func pinInterfaceLanguage(_ language: AppLanguage) {
        L10n.setCurrent(language)
        addTeardownBlock {
            L10n.setCurrent(.en)
        }
    }
}
