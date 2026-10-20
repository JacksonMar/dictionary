import Foundation
import XCTest
@testable import VocabCore

/// M5 — зміни ядра поза `EntryQuery`: `ClaudeError.storage`, тексти помилок файлів/імпорту, очищення імпорту,
/// кількість у `exportDictionary`.
final class M5CoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        pinInterfaceLanguage(.uk)
    }

    // MARK: - ClaudeError.storage disposition (§8.1: як .transport)

    func testStorageDispositionBehavesLikeTransport() {
        let max = RetryPolicy.defaultMaxAttempts
        for attempts in 0..<(max - 1) {
            let result = ErrorDisposition.for(.storage("не вдалося зберегти запис: x"), attempts: attempts)
            XCTAssertEqual(result.status, .pending, "attempts \(attempts)")
            XCTAssertTrue(result.countsAttempt, "attempts \(attempts)")
        }
        let last = ErrorDisposition.for(.storage("x"), attempts: max - 1)
        XCTAssertEqual(last.status, .failed, "max-th counted failure → failed")
        XCTAssertTrue(last.countsAttempt)

        for attempts in 0...max {
            let storage = ErrorDisposition.for(.storage("x"), attempts: attempts, maxAttempts: 3)
            let transport = ErrorDisposition.for(.transport("x"), attempts: attempts, maxAttempts: 3)
            XCTAssertEqual(storage.status, transport.status, "attempts \(attempts)")
            XCTAssertEqual(storage.countsAttempt, transport.countsAttempt, "attempts \(attempts)")
        }
    }

    func testStorageUserMessageAndLogName() {
        XCTAssertEqual(ClaudeError.storage("не вдалося зберегти запис: диск заповнено").userMessage,
                       "Не вдалося зберегти запис: диск заповнено")
        XCTAssertEqual(ClaudeError.storage("").userMessage, "Не вдалося зберегти запис")
        XCTAssertFalse(ClaudeError.storage("x").userMessage.contains("мережі"))
        XCTAssertEqual(ClaudeError.storage("secret detail").logName, "storage")
    }

    // MARK: - NotificationText for queued .storage

    func testQueuedStorageNotification() {
        let entry = M4.entry(word: "run", status: .pending)
        let content = NotificationText.make(for: .queued(entry, .storage("не вдалося зберегти запис: диск")))
        XCTAssertEqual(content, NotificationContent(
            title: "Збережено в чергу",
            body: "run: не вдалося зберегти запис, повторимо пізніше"
        ))
        XCTAssertFalse(content.body.contains("мережі"))
    }

    // MARK: - ImportError messages

    func testImportErrorMessagesHaveNoDoublePeriodAndEndWithUntouched() {
        let reasons = ["диск заповнено", "диск заповнено.", "диск заповнено...", " The file couldn’t be saved. ", ""]
        var errors: [ImportError] = [.emptyFile, .notJSON, .missingSchemaVersion, .unsupportedSchemaVersion(2),
                                     .missingEntries]
        for reason in reasons {
            errors += [.readFailed(reason), .backupFailed(reason), .storage(reason)]
        }
        for error in errors {
            let message = error.userMessage
            XCTAssertFalse(message.contains(".."), "\(error): \(message)")
            XCTAssertTrue(message.hasSuffix("Словник не змінено."), "\(error): \(message)")
            XCTAssertFalse(message.contains(". . "), "\(error): \(message)")
        }
    }

    func testImportErrorReasonsEmbedded() {
        XCTAssertEqual(ImportError.readFailed("файл не знайдено.").userMessage,
                       "Не вдалося прочитати файл: файл не знайдено. Словник не змінено.")
        XCTAssertEqual(ImportError.backupFailed("немає доступу до файлу").userMessage,
                       "Не вдалося створити резервну копію поточного словника (немає доступу до файлу). "
                       + "Словник не змінено.")
        XCTAssertEqual(ImportError.storage("Не вдалося зберегти словник: диск заповнено.").userMessage,
                       "Не вдалося зберегти словник: диск заповнено. Словник не змінено.")
    }

    // MARK: - FileErrorText

    func testFileErrorTextCocoaCodes() {
        let cases: [(CocoaError.Code, String)] = [
            (.fileNoSuchFile, "файл не знайдено"),
            (.fileReadNoSuchFile, "файл не знайдено"),
            (.fileReadNoPermission, "немає доступу до файлу"),
            (.fileWriteNoPermission, "немає доступу до файлу"),
            (.fileWriteOutOfSpace, "недостатньо місця на диску"),
            (.fileWriteVolumeReadOnly, "диск доступний лише для читання"),
            (.fileReadCorruptFile, "файл пошкоджений або має невідоме кодування"),
            (.fileReadTooLarge, "файл завеликий"),
            (.fileReadInvalidFileName, "некоректне ім'я файлу"),
            (.fileWriteFileExists, "файл уже існує"),
            (.fileLocking, "файл заблоковано"),
        ]
        for (code, text) in cases {
            XCTAssertEqual(FileErrorText.describe(CocoaError(code)), text, "\(code)")
            let nsError = NSError(domain: NSCocoaErrorDomain, code: code.rawValue,
                                  userInfo: [NSFilePathErrorKey: "/Users/secret/dictionary.json"])
            XCTAssertEqual(FileErrorText.describe(nsError), text, "\(code) as NSError")
        }
    }

    func testFileErrorTextPOSIXCodes() {
        let cases: [(POSIXErrorCode, String)] = [
            (.ENOENT, "файл не знайдено"),
            (.EACCES, "немає доступу до файлу"),
            (.EPERM, "немає доступу до файлу"),
            (.ENOSPC, "недостатньо місця на диску"),
            (.EROFS, "диск доступний лише для читання"),
            (.EISDIR, "вказано каталог, а не файл"),
            (.EEXIST, "файл уже існує"),
        ]
        for (code, text) in cases {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue))
            XCTAssertEqual(FileErrorText.describe(error), text, "\(code)")
        }
    }

    func testFileErrorTextUsesUnderlyingError() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))
        let wrapper = NSError(domain: NSCocoaErrorDomain, code: 999_999, userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertEqual(FileErrorText.describe(wrapper), "недостатньо місця на диску")
    }

    func testFileErrorTextFallbackIsUkrainianWithoutPath() {
        let error = NSError(domain: "com.example.Custom", code: 42,
                            userInfo: [NSLocalizedDescriptionKey: "Something failed at /Users/secret/x.json"])
        let text = FileErrorText.describe(error)
        XCTAssertEqual(text, "системна помилка (com.example.Custom, код 42)")
        XCTAssertFalse(text.contains("/Users"))
        XCTAssertFalse(text.hasSuffix("."))
    }

    func testFileErrorTextStorageErrorWithoutTrailingPeriod() {
        let text = FileErrorText.describe(StorageError.unsupportedSchemaVersion(9))
        XCTAssertFalse(text.hasSuffix("."))
        XCTAssertEqual(FileErrorText.describe(StorageError.writeFailed("диск заповнено")),
                       "Не вдалося зберегти словник: диск заповнено")
    }

    func testTrimmingTrailingPeriods() {
        XCTAssertEqual(FileErrorText.trimmingTrailingPeriods("abc. . ."), "abc")
        XCTAssertEqual(FileErrorText.trimmingTrailingPeriods("  a.b  "), "a.b")
        XCTAssertEqual(FileErrorText.trimmingTrailingPeriods("..."), "")
        XCTAssertEqual(FileErrorText.trimmingTrailingPeriods("abc…"), "abc…", "ellipsis char is not a period")
    }

    // MARK: - DictionaryImporter cleaning

    private func parseSingle(_ mutate: (inout [String: Any]) -> Void,
                             status: EntryStatus = .ready) throws -> ParsedImport {
        var raw = try M4.rawEntry(M4.entry(word: "run", status: status))
        mutate(&raw)
        return try DictionaryImporter.parse(M4.rawFileData([raw]))
    }

    func testImporterCleansWord() throws {
        let parsed = try parseSingle { $0["word"] = "  «Run»\n\t" }
        XCTAssertEqual(parsed.entries.first?.word, "Run")
        XCTAssertEqual(parsed.skippedReasons, [])

        let apostrophe = try parseSingle { $0["word"] = "don\u{2019}t   give  up!" }
        XCTAssertEqual(apostrophe.entries.first?.word, "don't give up")
    }

    func testImporterWordOnlyPunctuationSkipped() throws {
        let parsed = try parseSingle { $0["word"] = " ... " }
        XCTAssertTrue(parsed.entries.isEmpty)
        XCTAssertEqual(parsed.skippedReasons, ["Запис #1: некоректне поле word"])
    }

    func testImporterTrimsCollapsesAndDropsEmptyTranslations() throws {
        let parsed = try parseSingle {
            $0["translations"] = ["  бігти  ", "керувати\n   машиною", "   ", "", "\t", "бігти (швидко)"]
        }
        XCTAssertEqual(parsed.entries.first?.translations, ["бігти", "керувати машиною", "бігти (швидко)"])
        XCTAssertEqual(parsed.skippedReasons, [])
    }

    func testImporterPreservesEdgePunctuationInTranslations() throws {
        let parsed = try parseSingle { $0["translations"] = ["бігти (швидко)", "«керувати»", "ну!"] }
        XCTAssertEqual(parsed.entries.first?.translations, ["бігти (швидко)", "«керувати»", "ну!"])
    }

    func testImporterReadyWithOnlyBlankTranslationsSkipped() throws {
        var good = try M4.rawEntry(M4.entry(word: "walk"))
        good["translations"] = ["ходити"]
        var bad = try M4.rawEntry(M4.entry(word: "run"))
        bad["translations"] = ["  ", "\n", ""]
        let parsed = try DictionaryImporter.parse(M4.rawFileData([good, bad]))
        XCTAssertEqual(parsed.entries.map(\.word), ["walk"])
        XCTAssertEqual(parsed.skippedReasons, ["Запис #2: готовий запис без перекладів"])
    }

    func testImporterPendingWithBlankTranslationsKeptWithEmptyList() throws {
        for status in [EntryStatus.pending, .failed] {
            let parsed = try parseSingle({ $0["translations"] = ["  ", ""] }, status: status)
            XCTAssertEqual(parsed.entries.count, 1, "\(status)")
            XCTAssertEqual(parsed.entries.first?.translations, [], "\(status)")
        }
    }

    func testCollapseWhitespace() {
        XCTAssertEqual(DictionaryImporter.collapseWhitespace("  a \u{00A0}\n b\t"), "a b")
        XCTAssertEqual(DictionaryImporter.collapseWhitespace(" \n "), "")
    }

    // MARK: - exportDictionary count

    func testExportReturnsCountOfEntriesWritten() async throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        let entries = [M4.entry(word: "run"), M4.entry(word: "walk"), M4.entry(word: "fly", status: .pending)]
        try await fixture.seed(entries)
        try FileManager.default.createDirectory(at: fixture.transferDirectory, withIntermediateDirectories: true)
        let url = fixture.transferDirectory.appendingPathComponent("export.json")

        let count = try await fixture.service.exportDictionary(to: url)

        let file = try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(count, 3)
        XCTAssertEqual(count, file.entries.count)
    }

    func testExportEmptyDictionaryReturnsZero() async throws {
        let fixture = try TransferFixture()
        defer { fixture.remove() }
        try await fixture.seed([])
        try FileManager.default.createDirectory(at: fixture.transferDirectory, withIntermediateDirectories: true)
        let url = fixture.transferDirectory.appendingPathComponent("export.json")

        let count = try await fixture.service.exportDictionary(to: url)

        let file = try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(count, 0)
        XCTAssertEqual(file.entries.count, 0)
    }
}
