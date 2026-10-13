import Foundation
import XCTest
@testable import VocabCore

/// M4.1 — валідація файлу імпорту (§10, D13): помилки рівня файлу й пропуск окремих невалідних записів.
final class DictionaryImporterTests: XCTestCase {
    // MARK: - Валідний файл

    func testValidFileParsed() throws {
        let parsed = try DictionaryImporter.parse(Data(TestFixtures.requirementsExample.utf8))

        XCTAssertEqual(parsed.skippedReasons, [])
        XCTAssertEqual(parsed.entries.count, 1)
        let entry = try XCTUnwrap(parsed.entries.first)
        XCTAssertEqual(entry.id, UUID(uuidString: TestFixtures.entryID))
        XCTAssertEqual(entry.languagePair, "en-uk")
        XCTAssertEqual(entry.word, "run")
        XCTAssertEqual(entry.lemma, "run")
        XCTAssertEqual(entry.partOfSpeech, "verb")
        XCTAssertEqual(entry.transcription, "/rʌn/")
        XCTAssertEqual(entry.translations, ["бігти", "керувати"])
        XCTAssertEqual(entry.example, Example(source: "She runs every morning.", translation: "Вона бігає щоранку."))
        XCTAssertEqual(entry.status, .ready)
        XCTAssertEqual(entry.createdAt, TestDates.reference)
        XCTAssertEqual(entry.updatedAt, TestDates.reference.addingTimeInterval(5415))
    }

    func testValidFileRoundTripsEncodedEntries() throws {
        let entries = [
            M4.entry(word: "run", updated: 10),
            M4.entry(word: "give up", status: .pending, lastError: "Немає з'єднання", updated: 20),
            M4.entry(word: "walk", status: .failed, lastError: "HTTP 400", updated: 30),
        ]
        let parsed = try DictionaryImporter.parse(M4.fileData(entries))
        XCTAssertEqual(parsed, ParsedImport(entries: entries, skippedReasons: []))
    }

    func testEmptyEntriesArrayParsed() throws {
        let parsed = try DictionaryImporter.parse(Data(#"{"schemaVersion":1,"entries":[]}"#.utf8))
        XCTAssertEqual(parsed, ParsedImport(entries: [], skippedReasons: []))
    }

    func testMissingExportedAtIsAccepted() throws {
        let raw = try M4.rawEntry(M4.entry(word: "run"))
        let parsed = try DictionaryImporter.parse(M4.rawFileData([raw]))
        XCTAssertEqual(parsed.entries.map(\.word), ["run"])
    }

    func testUnknownLanguagePairAccepted() throws {
        let entry = M4.entry(pair: "de-uk", word: "laufen")
        let parsed = try DictionaryImporter.parse(M4.fileData([entry]))
        XCTAssertEqual(parsed.entries, [entry])
        XCTAssertEqual(parsed.skippedReasons, [])
    }

    func testFractionalSecondDatesAccepted() throws {
        var raw = try M4.rawEntry(M4.entry(word: "run"))
        raw["updatedAt"] = "2026-10-13T10:00:00.500Z"
        let parsed = try DictionaryImporter.parse(M4.rawFileData([raw]))
        XCTAssertEqual(parsed.entries.first?.updatedAt, TestDates.reference.addingTimeInterval(0.5))
    }

    func testPendingWithoutTranslationsAccepted() throws {
        let entries = [M4.entry(word: "run", status: .pending), M4.entry(word: "walk", status: .failed)]
        let parsed = try DictionaryImporter.parse(M4.fileData(entries))
        XCTAssertEqual(parsed.entries, entries)
    }

    // MARK: - Помилки рівня файлу

    func testEmptyFileRejected() {
        assertParseError(.emptyFile, Data())
    }

    func testWhitespaceFileRejected() {
        assertParseError(.emptyFile, Data("   \n\t  \r\n ".utf8))
    }

    func testNotJSONRejected() {
        assertParseError(.notJSON, Data("hello, world".utf8))
        assertParseError(.notJSON, Data(#"{"schemaVersion": 1, "entries": ["#.utf8), "truncated JSON")
        assertParseError(.notJSON, Data([0xFF, 0xFE, 0x00, 0x7B]), "non-UTF-8 bytes")
    }

    func testArrayTopLevelRejected() {
        assertParseError(.notJSON, Data(#"[{"schemaVersion":1,"entries":[]}]"#.utf8))
    }

    func testScalarTopLevelRejected() {
        assertParseError(.notJSON, Data("42".utf8))
        assertParseError(.notJSON, Data(#""text""#.utf8))
        assertParseError(.notJSON, Data("null".utf8))
    }

    func testMissingSchemaVersionRejected() {
        assertParseError(.missingSchemaVersion, Data(#"{"entries":[]}"#.utf8))
    }

    func testSchemaVersion2Rejected() {
        assertParseError(.unsupportedSchemaVersion(2), Data(#"{"schemaVersion":2,"entries":[]}"#.utf8))
    }

    func testSchemaVersion0Rejected() {
        assertParseError(.unsupportedSchemaVersion(0), Data(#"{"schemaVersion":0,"entries":[]}"#.utf8))
    }

    func testSchemaVersionNegativeRejected() {
        assertParseError(.unsupportedSchemaVersion(-1), Data(#"{"schemaVersion":-1,"entries":[]}"#.utf8))
    }

    func testSchemaVersionStringRejected() {
        assertParseError(.missingSchemaVersion, Data(#"{"schemaVersion":"1","entries":[]}"#.utf8))
    }

    func testSchemaVersionFractionalRejected() {
        assertParseError(.missingSchemaVersion, Data(#"{"schemaVersion":1.5,"entries":[]}"#.utf8))
    }

    func testSchemaVersionNullRejected() {
        assertParseError(.missingSchemaVersion, Data(#"{"schemaVersion":null,"entries":[]}"#.utf8))
    }

    func testSchemaVersionCheckedBeforeEntries() {
        // Файл новішої версії відхиляється за версією, а не за відсутністю entries.
        assertParseError(.unsupportedSchemaVersion(2), Data(#"{"schemaVersion":2,"words":[]}"#.utf8))
    }

    func testMissingEntriesRejected() {
        assertParseError(.missingEntries, Data(#"{"schemaVersion":1}"#.utf8))
    }

    func testEntriesNotArrayRejected() {
        assertParseError(.missingEntries, Data(#"{"schemaVersion":1,"entries":{}}"#.utf8))
        assertParseError(.missingEntries, Data(#"{"schemaVersion":1,"entries":"run"}"#.utf8))
        assertParseError(.missingEntries, Data(#"{"schemaVersion":1,"entries":null}"#.utf8))
    }

    // MARK: - Невалідні окремі записи (D13)

    /// Один пошкоджений запис між двома валідними → пропущений з причиною «Запис #2: …», валідні лишаються.
    private func assertSkipped(
        reason expected: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        corrupt: (inout [String: Any]) -> Void
    ) throws {
        let first = M4.entry(word: "first")
        let third = M4.entry(word: "third")
        var broken = try M4.rawEntry(M4.entry(word: "broken"))
        corrupt(&broken)
        let data = try M4.rawFileData([M4.rawEntry(first), broken, M4.rawEntry(third)])

        let parsed = try DictionaryImporter.parse(data)

        XCTAssertEqual(parsed.entries, [first, third], file: file, line: line)
        XCTAssertEqual(parsed.skippedReasons, ["Запис #2: \(expected)"], file: file, line: line)
    }

    func testEntryMissingWordSkipped() throws {
        try assertSkipped(reason: "відсутнє поле word") { $0["word"] = nil }
    }

    func testEntryBlankWordSkipped() throws {
        try assertSkipped(reason: "некоректне поле word") { $0["word"] = "   " }
    }

    func testEntryMissingIdSkipped() throws {
        try assertSkipped(reason: "відсутнє поле id") { $0["id"] = nil }
    }

    func testInvalidUUIDSkipped() throws {
        try assertSkipped(reason: "некоректне поле id") { $0["id"] = "not-a-uuid" }
    }

    func testEntryMissingLanguagePairSkipped() throws {
        try assertSkipped(reason: "відсутнє поле languagePair") { $0["languagePair"] = nil }
    }

    func testEntryMissingStatusSkipped() throws {
        try assertSkipped(reason: "відсутнє поле status") { $0["status"] = nil }
    }

    func testUnknownStatusSkipped() throws {
        try assertSkipped(reason: "некоректне поле status") { $0["status"] = "done" }
    }

    func testEntryMissingCreatedAtSkipped() throws {
        try assertSkipped(reason: "відсутнє поле createdAt") { $0["createdAt"] = nil }
    }

    func testBadDateSkipped() throws {
        try assertSkipped(reason: "некоректне поле updatedAt") { $0["updatedAt"] = "13.10.2026" }
        try assertSkipped(reason: "некоректне поле createdAt") { $0["createdAt"] = "2026-13-45T99:00:00Z" }
        try assertSkipped(reason: "некоректне поле updatedAt") { $0["updatedAt"] = 1_791_885_600 }
    }

    func testEntryMissingTranslationsSkipped() throws {
        try assertSkipped(reason: "відсутнє поле translations") { $0["translations"] = nil }
    }

    func testTranslationsNotStringsSkipped() throws {
        try assertSkipped(reason: "некоректне поле translations") { $0["translations"] = ["бігти", 42] }
        try assertSkipped(reason: "некоректне поле translations") { $0["translations"] = "бігти" }
    }

    func testReadyWithoutTranslationsSkipped() throws {
        try assertSkipped(reason: "готовий запис без перекладів") { $0["translations"] = [String]() }
    }

    func testInvalidOptionalFieldSkipped() throws {
        try assertSkipped(reason: "некоректне поле example") { $0["example"] = "She runs." }
    }

    func testNonObjectEntrySkipped() throws {
        let valid = M4.entry(word: "run")
        let data = try M4.rawFileData([42, M4.rawEntry(valid), "text"])

        let parsed = try DictionaryImporter.parse(data)

        XCTAssertEqual(parsed.entries, [valid])
        XCTAssertEqual(parsed.skippedReasons, ["Запис #1: не є об'єктом", "Запис #3: не є об'єктом"])
    }

    func testAllEntriesInvalidStillParses() throws {
        var raw = try M4.rawEntry(M4.entry(word: "run"))
        raw["id"] = "bad"
        let parsed = try DictionaryImporter.parse(M4.rawFileData([raw, raw]))
        XCTAssertEqual(parsed.entries, [])
        XCTAssertEqual(parsed.skippedReasons, ["Запис #1: некоректне поле id", "Запис #2: некоректне поле id"])
    }

    func testDuplicatesAreNotCollapsedByParser() throws {
        // Згортання дублікатів — задача ImportMerger; parse повертає всі валідні записи.
        let id = UUID()
        let entries = [M4.entry(id: id, word: "run", updated: 1), M4.entry(id: id, word: "run", updated: 2)]
        XCTAssertEqual(try DictionaryImporter.parse(M4.fileData(entries)).entries, entries)
    }

    // MARK: - Тексти помилок

    func testErrorMessagesUkrainian() {
        let untouched = "Словник не змінено."
        let expected: [(ImportError, String)] = [
            (.emptyFile, "Файл порожній. Словник не змінено."),
            (.notJSON, "Файл не є словником у форматі JSON. Словник не змінено."),
            (.missingSchemaVersion,
             "У файлі немає коректного поля schemaVersion — це не файл словника. Словник не змінено."),
            (.unsupportedSchemaVersion(2),
             "Непідтримувана версія схеми файлу (2); підтримується версія 1. Словник не змінено."),
            (.missingEntries, "У файлі немає списку записів (entries). Словник не змінено."),
            (.readFailed("немає доступу"), "Не вдалося прочитати файл: немає доступу. Словник не змінено."),
            (.backupFailed("диск заповнено"),
             "Не вдалося створити резервну копію поточного словника (диск заповнено). Словник не змінено."),
            (.storage("Не вдалося зберегти словник: диск заповнено"),
             "Не вдалося зберегти словник: диск заповнено. Словник не змінено."),
        ]
        let cyrillic = CharacterSet(charactersIn: "абвгґдеєжзиіїйклмнопрстуфхцчшщьюяАБВГҐДЕЄЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЬЮЯ")
        for (error, text) in expected {
            XCTAssertEqual(error.userMessage, text, "\(error)")
            XCTAssertTrue(error.userMessage.hasSuffix(untouched), "\(error)")
            XCTAssertNotNil(error.userMessage.rangeOfCharacter(from: cyrillic), "\(error)")
        }
    }

    func testParseErrorsMapToUkrainianMessages() {
        let cases: [(String, ImportError)] = [
            ("", .emptyFile),
            ("[]", .notJSON),
            (#"{"entries":[]}"#, .missingSchemaVersion),
            (#"{"schemaVersion":2,"entries":[]}"#, .unsupportedSchemaVersion(2)),
            (#"{"schemaVersion":1}"#, .missingEntries),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try DictionaryImporter.parse(Data(text.utf8))) { error in
                XCTAssertEqual(error as? ImportError, expected)
                XCTAssertEqual((error as? ImportError)?.userMessage.hasSuffix("Словник не змінено."), true)
            }
        }
    }
}
