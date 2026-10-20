import Foundation
import XCTest
@testable import VocabCore

/// M9.3 — тексти ядра обома мовами: явні `language:`/`in:` перевантаження (D34) і властивості, що читають
/// `L10n.current` (перевіряються через `pinInterfaceLanguage`, D39).
final class LocalizedMessagesTests: XCTestCase {
    private func entry(
        _ word: String = "run",
        translations: [String] = ["бігти", "керувати"],
        status: EntryStatus = .ready
    ) -> Entry {
        var entry = TestFixtures.entry(word: word, status: status)
        entry.translations = translations
        return entry
    }

    private static let allClaudeErrors: [ClaudeError] = [
        .missingAPIKey, .offline, .timeout, .unauthorized, .forbidden,
        .rateLimited(retryAfter: 5), .rateLimited(retryAfter: nil),
        .server(status: 529), .badRequest(status: 404, message: ""), .badRequest(status: 400, message: "model: x"),
        .invalidResponse("bad"), .refused, .transport("cancelled"), .storage(""),
    ]

    // MARK: - NotificationText

    func testNotificationTextsEnglish() {
        let en = AppLanguage.en
        XCTAssertEqual(
            NotificationText.make(for: .added(entry()), language: en),
            NotificationContent(title: "Added", body: "Added: run — бігти, керувати")
        )
        XCTAssertEqual(
            NotificationText.make(for: .added(entry(translations: [])), language: en),
            NotificationContent(title: "Added", body: "Added: run")
        )
        XCTAssertEqual(
            NotificationText.make(for: .duplicate(entry(translations: ["бігти"])), selection: "run", language: en),
            NotificationContent(title: "Already in the dictionary", body: "run — бігти")
        )
        XCTAssertEqual(
            NotificationText.make(for: .duplicate(entry(translations: [], status: .pending)), language: en),
            NotificationContent(title: "Already in the dictionary", body: "run — waiting to be processed")
        )
        let pending = entry(status: .pending)
        XCTAssertEqual(
            NotificationText.make(for: .queued(pending, nil), language: en),
            NotificationContent(title: "Processing", body: "Processing: run")
        )
        let queued: [(ClaudeError, String)] = [
            (.offline, "run: no network connection, the translation will be added later"),
            (.missingAPIKey, "run: add an API key in Settings"),
            (.storage("x"), "run: could not save the entry, will retry later"),
            (.timeout, "run: will retry later"),
            (.server(status: 500), "run: will retry later"),
        ]
        for (error, body) in queued {
            XCTAssertEqual(
                NotificationText.make(for: .queued(pending, error), language: en),
                NotificationContent(title: "Saved to the queue", body: body),
                "\(error)"
            )
        }
        XCTAssertEqual(
            NotificationText.make(for: .failed(entry(status: .failed), .unauthorized), language: en),
            NotificationContent(title: "Could not add", body: "run: Invalid API key (401)")
        )
        let rejections: [(SelectionRejection, String)] = [
            (.empty, "Nothing is selected"),
            (.tooLong(max: 100), "Too much text selected (max 100 characters)"),
            (.tooManyWords(max: 5), "Too much text selected (max 5 words)"),
            (.noLetters, "The selected text contains no words"),
        ]
        for (rejection, body) in rejections {
            XCTAssertEqual(
                NotificationText.make(for: .rejected(rejection), language: en),
                NotificationContent(title: "Not added", body: body)
            )
        }
        XCTAssertEqual(NotificationText.rejectedTitle(in: en), "Not added")
        XCTAssertEqual(NotificationText.rejectionText(.empty, language: en), "Nothing is selected")
        XCTAssertEqual(
            NotificationText.make(for: .storageError("disk full"), language: en),
            NotificationContent(title: "Could not add", body: "disk full")
        )
    }

    func testNotificationTextsUkrainian() {
        // Явна мова перекриває поточну (`L10n.current` лишається `.en`).
        XCTAssertEqual(L10n.current, .en)
        let uk = AppLanguage.uk
        XCTAssertEqual(
            NotificationText.make(for: .added(entry()), language: uk),
            NotificationContent(title: "Додано", body: "Додано: run — бігти, керувати")
        )
        XCTAssertEqual(
            NotificationText.make(for: .duplicate(entry(translations: ["бігти"])), selection: "run", language: uk),
            NotificationContent(title: "Вже є в словнику", body: "run — бігти")
        )
        XCTAssertEqual(
            NotificationText.make(for: .duplicate(entry(translations: [], status: .failed)), language: uk),
            NotificationContent(title: "Вже є в словнику", body: "run — очікує обробки")
        )
        let pending = entry(status: .pending)
        XCTAssertEqual(
            NotificationText.make(for: .queued(pending, nil), language: uk),
            NotificationContent(title: "Обробляється", body: "Обробляється: run")
        )
        let queued: [(ClaudeError, String)] = [
            (.offline, "run: немає мережі, переклад буде додано пізніше"),
            (.missingAPIKey, "run: додайте API-ключ у налаштуваннях"),
            (.storage("x"), "run: не вдалося зберегти запис, повторимо пізніше"),
            (.rateLimited(retryAfter: nil), "run: повторимо пізніше"),
        ]
        for (error, body) in queued {
            XCTAssertEqual(
                NotificationText.make(for: .queued(pending, error), language: uk),
                NotificationContent(title: "Збережено в чергу", body: body),
                "\(error)"
            )
        }
        XCTAssertEqual(
            NotificationText.make(for: .failed(entry(status: .failed), .unauthorized), language: uk),
            NotificationContent(title: "Не вдалося додати", body: "run: Невірний API-ключ (401)")
        )
        let rejections: [(SelectionRejection, String)] = [
            (.empty, "Нічого не виділено"),
            (.tooLong(max: 100), "Виділено забагато тексту (макс. 100 символів)"),
            (.tooManyWords(max: 5), "Виділено забагато тексту (макс. 5 слів)"),
            (.noLetters, "Виділений текст не містить слів"),
        ]
        for (rejection, body) in rejections {
            XCTAssertEqual(
                NotificationText.make(for: .rejected(rejection), language: uk),
                NotificationContent(title: "Не додано", body: body)
            )
        }
    }

    func testNotificationLegacySignatureFollowsCurrentLanguage() {
        XCTAssertEqual(NotificationText.make(for: .added(entry(translations: []))).title, "Added")
        XCTAssertEqual(NotificationText.rejectedTitle, "Not added")
        pinInterfaceLanguage(.uk)
        XCTAssertEqual(NotificationText.make(for: .added(entry(translations: []))).title, "Додано")
        XCTAssertEqual(NotificationText.make(for: .duplicate(entry()), selection: "run").title, "Вже є в словнику")
        XCTAssertEqual(NotificationText.rejectedTitle, "Не додано")
    }

    // MARK: - ClaudeError

    func testClaudeErrorMessagesBothLanguages() {
        for error in Self.allClaudeErrors {
            let english = error.userMessage(in: .en)
            let ukrainian = error.userMessage(in: .uk)
            XCTAssertFalse(english.isEmpty, "\(error)")
            XCTAssertFalse(ukrainian.isEmpty, "\(error)")
            XCTAssertNotEqual(english, ukrainian, "\(error)")
            XCTAssertFalse(LocalizationTests.containsCyrillic(english), "\(error): \(english)")
            XCTAssertTrue(LocalizationTests.containsCyrillic(ukrainian), "\(error): \(ukrainian)")
            XCTAssertEqual(error.userMessage, english, "default follows L10n.current (.en)")
        }
        XCTAssertEqual(ClaudeError.missingAPIKey.userMessage(in: .en), "No API key. Add it in Settings")
        XCTAssertEqual(ClaudeError.offline.userMessage(in: .uk), "Немає мережі")
        XCTAssertEqual(ClaudeError.server(status: 529).userMessage(in: .en), "Claude server error (529)")
        XCTAssertEqual(
            ClaudeError.badRequest(status: 400, message: "bad model").userMessage(in: .uk),
            "Помилка запиту (400): bad model"
        )
        XCTAssertEqual(ClaudeError.transport("cancelled").userMessage(in: .en), "Network error: cancelled")
        // `.storage` з причиною — причина як є (вже мовою моменту запису), з великої літери.
        XCTAssertEqual(ClaudeError.storage("could not save").userMessage(in: .uk), "Could not save")

        pinInterfaceLanguage(.uk)
        XCTAssertEqual(ClaudeError.refused.userMessage, ClaudeError.refused.userMessage(in: .uk))
    }

    // MARK: - Storage / Repository / Import / Secret errors

    func testStorageRepositoryImportErrorMessagesBothLanguages() {
        XCTAssertEqual(StorageError.readFailed("x").userMessage(in: .en), "Could not read the dictionary: x")
        XCTAssertEqual(StorageError.readFailed("x").userMessage(in: .uk), "Не вдалося прочитати словник: x")
        XCTAssertEqual(StorageError.writeFailed("x").userMessage(in: .en), "Could not save the dictionary: x")
        XCTAssertTrue(StorageError.unsupportedSchemaVersion(9).userMessage(in: .en).contains("(9)"))
        XCTAssertTrue(StorageError.unsupportedSchemaVersion(9).userMessage(in: .uk).contains("(9)"))
        XCTAssertEqual(StorageError.backupFailed("x").userMessage(in: .en), "Could not create a backup: x")

        let duplicate = RepositoryError.duplicate(entry())
        XCTAssertEqual(duplicate.userMessage(in: .en), "“run” is already in the dictionary")
        XCTAssertEqual(duplicate.userMessage(in: .uk), "«run» вже є в словнику")
        XCTAssertEqual(RepositoryError.notFound(UUID()).userMessage(in: .en), "Entry not found")
        XCTAssertEqual(RepositoryError.notLoaded.userMessage(in: .uk), "Словник ще не завантажено")
        XCTAssertEqual(RepositoryError.storage("reason").userMessage(in: .en), "reason")

        XCTAssertEqual(ImportError.emptyFile.userMessage(in: .en), "The file is empty. The dictionary was not changed.")
        XCTAssertEqual(ImportError.emptyFile.userMessage(in: .uk), "Файл порожній. Словник не змінено.")
        XCTAssertEqual(
            ImportError.readFailed("file not found.").userMessage(in: .en),
            "Could not read the file: file not found. The dictionary was not changed.",
            "trailing period of the reason is not doubled"
        )
        let importErrors: [ImportError] = [
            .emptyFile, .notJSON, .missingSchemaVersion, .unsupportedSchemaVersion(7), .missingEntries,
            .readFailed("r"), .backupFailed("r"), .storage("r"),
        ]
        for error in importErrors {
            XCTAssertTrue(error.userMessage(in: .en).hasSuffix("The dictionary was not changed."), "\(error)")
            XCTAssertTrue(error.userMessage(in: .uk).hasSuffix("Словник не змінено."), "\(error)")
            XCTAssertEqual(error.userMessage, error.userMessage(in: .en))
        }

        XCTAssertEqual(SecretStoreError.keychain(status: -25300).userMessage(in: .en), "Keychain error (code -25300)")
        XCTAssertEqual(SecretStoreError.keychain(status: -25300).userMessage(in: .uk), "Помилка Keychain (код -25300)")
        XCTAssertNotEqual(SecretStoreError.encoding.userMessage(in: .en), SecretStoreError.encoding.userMessage(in: .uk))

        // Властивості без мови читають `L10n.current` (D34/D39).
        pinInterfaceLanguage(.uk)
        XCTAssertEqual(StorageError.readFailed("x").userMessage, "Не вдалося прочитати словник: x")
        XCTAssertEqual(RepositoryError.notFound(UUID()).userMessage, "Запис не знайдено")
        XCTAssertEqual(ImportError.notJSON.userMessage, "Файл не є словником у форматі JSON. Словник не змінено.")
        XCTAssertEqual(SecretStoreError.encoding.userMessage, "Не вдалося прочитати ключ з Keychain")
    }

    // MARK: - FileErrorText

    func testFileErrorTextBothLanguages() {
        let notFound = NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileReadNoSuchFile.rawValue)
        XCTAssertEqual(FileErrorText.describe(notFound, language: .en), "file not found")
        XCTAssertEqual(FileErrorText.describe(notFound, language: .uk), "файл не знайдено")

        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue))
        XCTAssertEqual(FileErrorText.describe(posix, language: .en), "no permission to access the file")
        XCTAssertEqual(FileErrorText.describe(posix, language: .uk), "немає доступу до файлу")

        let unknown = NSError(domain: "Custom", code: 42)
        XCTAssertEqual(FileErrorText.describe(unknown, language: .en), "system error (Custom, code 42)")
        XCTAssertEqual(FileErrorText.describe(unknown, language: .uk), "системна помилка (Custom, код 42)")

        XCTAssertEqual(
            FileErrorText.describe(StorageError.writeFailed("disk"), language: .en),
            "Could not save the dictionary: disk"
        )

        XCTAssertEqual(FileErrorText.describe(notFound), "file not found", "default follows L10n.current")
        pinInterfaceLanguage(.uk)
        XCTAssertEqual(FileErrorText.describe(notFound), "файл не знайдено")
    }

    // MARK: - ImportReport

    func testImportReportSummaryBothLanguages() {
        let report = ImportReport(added: 3, updated: 1, skipped: 0)
        XCTAssertEqual(report.summary(in: .en), "Added 3, updated 1, skipped 0")
        XCTAssertEqual(report.summary(in: .uk), "Додано 3, оновлено 1, пропущено 0")
        XCTAssertEqual(report.summary, "Added 3, updated 1, skipped 0")
        pinInterfaceLanguage(.uk)
        XCTAssertEqual(report.summary, "Додано 3, оновлено 1, пропущено 0")
    }

    // MARK: - Pagination

    func testPaginationLabelBothLanguages() {
        let page = EntryPage(entries: [], number: 2, pageCount: 5, totalCount: 230)
        XCTAssertEqual(page.label(in: .en), "Page 2 of 5")
        XCTAssertEqual(page.label(in: .uk), "Сторінка 2 з 5")
        XCTAssertEqual(page.label, "Page 2 of 5")
        pinInterfaceLanguage(.uk)
        XCTAssertEqual(page.label, "Сторінка 2 з 5")
    }

    // MARK: - Appearance / sort

    func testAppearanceAndSortTitlesBothLanguages() {
        XCTAssertEqual(AppAppearance.allCases.map { $0.title(in: .en) }, ["System", "Light", "Dark"])
        XCTAssertEqual(AppAppearance.allCases.map { $0.title(in: .uk) }, ["Як у системі", "Світла", "Темна"])
        XCTAssertEqual(
            EntrySort.allCases.map { $0.title(in: .en) }.sorted(),
            ["Alphabetical", "Newest first", "Oldest first"]
        )
        XCTAssertEqual(EntrySort.dateNewest.title(in: .uk), "Спершу нові")
        XCTAssertEqual(EntrySort.dateOldest.title(in: .uk), "Спершу старі")
        XCTAssertEqual(EntrySort.alphabetical.title(in: .uk), "За алфавітом")
        XCTAssertEqual(AppAppearance.dark.title, "Dark")
        XCTAssertEqual(EntrySort.alphabetical.title, "Alphabetical")
        pinInterfaceLanguage(.uk)
        XCTAssertEqual(AppAppearance.dark.title, "Темна")
        XCTAssertEqual(EntrySort.alphabetical.title, "За алфавітом")
    }

    // MARK: - Регресія українських текстів

    func testUkrainianTextsUnchangedFromM8() {
        pinInterfaceLanguage(.uk)
        XCTAssertEqual(NotificationText.make(for: .added(entry(translations: []))).title, "Додано")
        XCTAssertEqual(NotificationText.make(for: .duplicate(entry())).title, "Вже є в словнику")
        XCTAssertEqual(EntryPage(entries: [], number: 2, pageCount: 5, totalCount: 5).label, "Сторінка 2 з 5")
        XCTAssertEqual(ImportReport(added: 1, updated: 2, skipped: 3).summary, "Додано 1, оновлено 2, пропущено 3")
        XCTAssertEqual(ClaudeError.missingAPIKey.userMessage, "Немає API-ключа. Додайте його в налаштуваннях")
        XCTAssertEqual(ImportError.emptyFile.userMessage, "Файл порожній. Словник не змінено.")
    }

    // MARK: - Причини з парсерів і процесорів ідуть через L10n

    func testParserReasonsFollowCurrentLanguage() {
        func reason() -> String? {
            do {
                _ = try LookupResponseParser.parse("no json here", kind: .word)
                return nil
            } catch let ClaudeError.invalidResponse(reason) {
                return reason
            } catch {
                return "unexpected \(error)"
            }
        }
        let english = reason()
        XCTAssertNotNil(english)
        XCTAssertFalse(LocalizationTests.containsCyrillic(english ?? ""), english ?? "")
        pinInterfaceLanguage(.uk)
        let ukrainian = reason()
        XCTAssertTrue(LocalizationTests.containsCyrillic(ukrainian ?? ""), ukrainian ?? "")
        XCTAssertNotEqual(english, ukrainian)
    }
}
