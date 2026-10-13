import Foundation
import XCTest
@testable import VocabCore

/// M1.2 — серіалізація/десеріалізація за схемою.
final class EntryCodingTests: XCTestCase {
    private func encode(_ file: DictionaryFile) throws -> Data {
        try JSONCoding.makeEncoder().encode(file)
    }

    private func decode(_ string: String) throws -> DictionaryFile {
        try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: Data(string.utf8))
    }

    func testRoundTrip() throws {
        var pending = TestFixtures.entry(word: "serendipity", status: .pending)
        pending.translations = []
        pending.lastError = "Немає мережі"
        pending.updatedAt = TestDates.reference.addingTimeInterval(65)
        var failed = TestFixtures.entry(languagePair: "it-uk", word: "casa", status: .failed)
        failed.lemma = nil
        failed.partOfSpeech = nil
        failed.transcription = nil
        failed.example = nil
        let file = DictionaryFile(
            schemaVersion: 1,
            exportedAt: TestDates.reference,
            entries: [TestFixtures.entry(), pending, failed]
        )

        let decoded = try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: encode(file))

        XCTAssertEqual(decoded, file)
        XCTAssertEqual(decoded.entries.map(\.status), [.ready, .pending, .failed])
    }

    func testEncodedKeysMatchSchema() throws {
        let entry = TestFixtures.entry()
        let file = DictionaryFile(schemaVersion: 1, exportedAt: TestDates.reference, entries: [entry])

        let root = try jsonObject(encode(file))

        XCTAssertEqual(Set(root.keys), ["schemaVersion", "exportedAt", "entries"])
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        let entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        let encodedEntry = entries[0]
        XCTAssertEqual(
            Set(encodedEntry.keys),
            ["id", "languagePair", "word", "lemma", "partOfSpeech", "transcription", "translations",
             "example", "status", "createdAt", "updatedAt"]
        )
        XCTAssertEqual(encodedEntry["id"] as? String, entry.id.uuidString)
        XCTAssertEqual(encodedEntry["languagePair"] as? String, "en-uk")
        XCTAssertEqual(encodedEntry["word"] as? String, "run")
        XCTAssertEqual(encodedEntry["translations"] as? [String], ["бігти", "керувати"])
        XCTAssertEqual(encodedEntry["status"] as? String, "ready")
        let example = try XCTUnwrap(encodedEntry["example"] as? [String: Any])
        XCTAssertEqual(Set(example.keys), ["source", "translation"])
    }

    func testStatusRawValuesMatchSchema() throws {
        XCTAssertEqual(EntryStatus.allCases.map(\.rawValue), ["ready", "pending", "failed"])
        for status in EntryStatus.allCases {
            let file = DictionaryFile(exportedAt: nil, entries: [TestFixtures.entry(status: status)])
            let root = try jsonObject(encode(file))
            let entries = try XCTUnwrap(root["entries"] as? [[String: Any]])
            XCTAssertEqual(entries.first?["status"] as? String, status.rawValue)
        }
    }

    func testDecodesRequirementsExample() throws {
        let file = try decode(TestFixtures.requirementsExample)

        XCTAssertEqual(file.schemaVersion, 1)
        XCTAssertEqual(file.exportedAt, TestDates.reference)
        XCTAssertEqual(file.entries.count, 1)
        let entry = file.entries[0]
        XCTAssertEqual(entry.id, UUID(uuidString: TestFixtures.entryID))
        XCTAssertEqual(entry.languagePair, "en-uk")
        XCTAssertEqual(entry.word, "run")
        XCTAssertEqual(entry.lemma, "run")
        XCTAssertEqual(entry.partOfSpeech, "verb")
        XCTAssertEqual(entry.transcription, "/rʌn/")
        XCTAssertEqual(entry.translations, ["бігти", "керувати"])
        XCTAssertEqual(entry.example, Example(source: "She runs every morning.", translation: "Вона бігає щоранку."))
        XCTAssertEqual(entry.status, .ready)
        XCTAssertNil(entry.lastError)
        XCTAssertEqual(entry.createdAt, TestDates.reference)
        XCTAssertEqual(entry.updatedAt, TestDates.reference.addingTimeInterval(90 * 60 + 15))
    }

    func testDecodesFractionalSecondDates() throws {
        let json = TestFixtures.requirementsExample
            .replacingOccurrences(of: "\"createdAt\": \"2026-10-13T10:00:00Z\"",
                                  with: "\"createdAt\": \"2026-10-13T10:00:00.250Z\"")
        XCTAssertNotEqual(json, TestFixtures.requirementsExample, "fixture replacement must apply")

        let file = try decode(json)

        let createdAt = try XCTUnwrap(file.entries.first?.createdAt)
        XCTAssertEqual(createdAt.timeIntervalSince1970, TestDates.reference.timeIntervalSince1970 + 0.25, accuracy: 0.001)
    }

    func testDecodesDatesWithTimeZoneOffset() throws {
        let json = TestFixtures.requirementsExample
            .replacingOccurrences(of: "\"createdAt\": \"2026-10-13T10:00:00Z\"",
                                  with: "\"createdAt\": \"2026-10-13T13:00:00+03:00\"")

        let file = try decode(json)

        XCTAssertEqual(file.entries.first?.createdAt, TestDates.reference)
    }

    func testInvalidDateFailsDecoding() {
        let json = TestFixtures.requirementsExample
            .replacingOccurrences(of: "\"createdAt\": \"2026-10-13T10:00:00Z\"",
                                  with: "\"createdAt\": \"13.10.2026\"")

        XCTAssertThrowsError(try decode(json))
    }

    func testOptionalFieldsOmittedWhenNil() throws {
        let entry = Entry(
            languagePair: "en-uk",
            word: "serendipity",
            translations: [],
            status: .pending,
            createdAt: TestDates.reference,
            updatedAt: TestDates.reference
        )
        let file = DictionaryFile(schemaVersion: 1, exportedAt: nil, entries: [entry])

        let root = try jsonObject(encode(file))

        XCTAssertNil(root["exportedAt"], "nil exportedAt must be omitted")
        let encodedEntry = try XCTUnwrap((root["entries"] as? [[String: Any]])?.first)
        for key in ["lemma", "partOfSpeech", "transcription", "example", "lastError"] {
            XCTAssertNil(encodedEntry[key], "\(key) must be omitted when nil")
        }
        XCTAssertEqual(encodedEntry["translations"] as? [String], [])
    }

    func testLastErrorEncodedWhenPresent() throws {
        var entry = TestFixtures.entry(status: .failed)
        entry.lastError = "Невірний API-ключ"
        let root = try jsonObject(encode(DictionaryFile(entries: [entry])))
        let encodedEntry = try XCTUnwrap((root["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(encodedEntry["lastError"] as? String, "Невірний API-ключ")
    }

    func testMissingExportedAtDecodes() throws {
        let json = TestFixtures.requirementsExample
            .replacingOccurrences(of: "\"exportedAt\": \"2026-10-13T10:00:00Z\",", with: "")

        let file = try decode(json)

        XCTAssertNil(file.exportedAt)
        XCTAssertEqual(file.entries.count, 1)
    }

    func testMissingOptionalEntryFieldsDecode() throws {
        let json = """
        {"schemaVersion": 1, "entries": [{"id": "\(TestFixtures.entryID)", "languagePair": "en-uk",
          "word": "serendipity", "translations": [], "status": "pending",
          "createdAt": "2026-10-13T10:00:00Z", "updatedAt": "2026-10-13T10:00:00Z"}]}
        """

        let entry = try XCTUnwrap(decode(json).entries.first)

        XCTAssertNil(entry.lemma)
        XCTAssertNil(entry.partOfSpeech)
        XCTAssertNil(entry.transcription)
        XCTAssertNil(entry.example)
        XCTAssertNil(entry.lastError)
        XCTAssertEqual(entry.status, .pending)
    }

    func testUnknownKeysIgnored() throws {
        let json = TestFixtures.requirementsExample
            .replacingOccurrences(of: "\"schemaVersion\": 1,", with: "\"schemaVersion\": 1, \"futureRootKey\": [1, 2],")
            .replacingOccurrences(of: "\"status\": \"ready\",", with: "\"status\": \"ready\", \"futureKey\": {\"a\": 1},")

        let file = try decode(json)

        XCTAssertEqual(file.entries.first?.word, "run")
        XCTAssertEqual(file.entries.first?.status, .ready)
    }

    func testMissingRequiredFieldFailsDecoding() {
        let json = TestFixtures.requirementsExample
            .replacingOccurrences(of: "\"word\": \"run\",", with: "")

        XCTAssertThrowsError(try decode(json))
    }

    func testUnknownStatusFailsDecoding() {
        let json = TestFixtures.requirementsExample
            .replacingOccurrences(of: "\"status\": \"ready\"", with: "\"status\": \"done\"")
        XCTAssertNotEqual(json, TestFixtures.requirementsExample, "fixture replacement must apply")

        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertTrue(error is DecodingError, "expected DecodingError, got \(error)")
        }
    }

    func testDatesEncodedAsISO8601UTC() throws {
        // Дробова частина відкидається; часовий пояс — завжди UTC з суфіксом Z.
        let created = TestDates.reference.addingTimeInterval(0.75)
        let entry = TestFixtures.entry(date: created)
        let file = DictionaryFile(schemaVersion: 1, exportedAt: TestDates.reference, entries: [entry])

        let root = try jsonObject(encode(file))

        XCTAssertEqual(root["exportedAt"] as? String, "2026-10-13T10:00:00Z")
        let encodedEntry = try XCTUnwrap((root["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(encodedEntry["createdAt"] as? String, "2026-10-13T10:00:00Z")
        XCTAssertEqual(encodedEntry["updatedAt"] as? String, "2026-10-13T10:00:00Z")
        XCTAssertEqual(JSONCoding.formatDate(TestDates.reference.addingTimeInterval(3 * 3600 + 7)),
                       "2026-10-13T13:00:07Z")
    }

    func testEncoderDoesNotEscapeSlashesAndSortsKeys() throws {
        let data = try encode(DictionaryFile(exportedAt: nil, entries: [TestFixtures.entry()]))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("\"/rʌn/\""), "slashes in transcription must not be escaped")
        XCTAssertFalse(text.contains("\\/"))
        let entriesRange = try XCTUnwrap(text.range(of: "\"entries\""))
        let schemaRange = try XCTUnwrap(text.range(of: "\"schemaVersion\""))
        XCTAssertLessThan(entriesRange.lowerBound, schemaRange.lowerBound, "keys must be sorted")
    }

    func testSystemDateProviderTruncatesToWholeSeconds() {
        let now = SystemDateProvider().now()
        XCTAssertEqual(now.timeIntervalSince1970, now.timeIntervalSince1970.rounded(.down))
    }
}
