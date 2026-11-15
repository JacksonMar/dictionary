// Local helpers for the VocabMobile tests. Core test support (Tests/VocabCoreTests) lives in another module and is
// not visible here, so the few helpers needed are re-implemented in a minimal form.
import Foundation
import XCTest
import VocabCore

/// Unique temporary data directory, removed after the test.
func makeTemporaryDirectory(_ testCase: XCTestCase, file: StaticString = #filePath, line: UInt = #line) -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("VocabMobileTests-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        XCTFail("cannot create temporary directory: \(error)", file: file, line: line)
    }
    testCase.addTeardownBlock {
        try? FileManager.default.removeItem(at: directory)
    }
    return directory
}

/// Writes `entries` as a schema-v1 `dictionary.json` into `directory`.
func writeDictionary(_ entries: [Entry], to directory: URL) throws {
    let paths = AppPaths(applicationSupportDirectory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONCoding.makeEncoder().encode(DictionaryFile(entries: entries))
    try data.write(to: paths.dictionaryURL)
}

/// Writes raw bytes as `dictionary.json` (corrupted / newer-schema files).
func writeRawDictionary(_ text: String, to directory: URL) throws {
    let paths = AppPaths(applicationSupportDirectory: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: paths.dictionaryURL)
}

/// Fixed reference time for entries.
let mobileTestEpoch = Date(timeIntervalSince1970: 1_700_000_000)

func makeTestEntry(
    _ word: String,
    translations: [String] = [],
    transcription: String? = nil,
    example: Example? = nil,
    status: EntryStatus = .ready,
    createdOffset: TimeInterval,
    variants: [String: EntryVariant]? = nil
) -> Entry {
    Entry(
        languagePair: LanguagePair.englishUkrainian.id,
        word: word,
        transcription: transcription,
        translations: translations,
        example: example,
        status: status,
        createdAt: mobileTestEpoch.addingTimeInterval(createdOffset),
        updatedAt: mobileTestEpoch.addingTimeInterval(createdOffset),
        variants: variants
    )
}

/// Error that is not a `StorageError` (generic load failure path).
struct MobileTestError: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// Fake `DictionaryStoring`: counts `load()` calls, optionally delays them (to keep the load in flight while other
/// callers arrive) and can fail with a fixed error. Thread-safe: `load()` runs on the repository actor's executor.
final class CountingDictionaryStore: DictionaryStoring, @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()
    private var loads = 0
    private var saves = 0
    private var file: DictionaryFile
    private let loadDelay: TimeInterval
    private let failure: Error?

    init(
        entries: [Entry] = [],
        loadDelay: TimeInterval = 0,
        failure: Error? = nil,
        fileURL: URL = URL(fileURLWithPath: "/dev/null/vocab-fake/dictionary.json")
    ) {
        self.file = DictionaryFile(entries: entries)
        self.loadDelay = loadDelay
        self.failure = failure
        self.fileURL = fileURL
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saves
    }

    func load() throws -> LoadResult {
        lock.lock()
        loads += 1
        let snapshot = file
        lock.unlock()
        if loadDelay > 0 {
            Thread.sleep(forTimeInterval: loadDelay)
        }
        if let failure {
            throw failure
        }
        return LoadResult(file: snapshot)
    }

    func save(_ newFile: DictionaryFile) throws {
        lock.lock()
        saves += 1
        file = newFile
        lock.unlock()
    }
}
