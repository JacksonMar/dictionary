// I5 (IOS_PLAN §7 «I5», ARCHITECTURE §10, D1, D13): export/import on the iPhone. Real stack:
// `AppContainer(paths:…securityScopedAccess:importStagingDirectory:)` → `MobileAppModel` transfer API
// (`prepareExport`/`finishExport`, `handleImportSelection` → `selectImportMode` → `confirmReplaceImport`/`cancelImport`)
// → `ImportFileStager` → `DictionaryTransferService` (core) → queue → `ClaudeLookupService` → `URLSessionTransport`
// with `MockURLProtocol` (token check: imported pending = 1 request, ready = 0, re-import = 0).
//
// Linking note (IOS_ALL.md §3: the test bundle does not link VocabCore, symbols come from the host app): the export
// bytes are parsed back **through the app's own import path** (`handleImportSelection` → `DictionaryTransferService`),
// not by calling `DictionaryImporter` directly (the app never references it); structural checks of the JSON use
// Foundation's `JSONSerialization`. Fixture files are written with `DictionaryExporter` (referenced by the app).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import VocabCore
@testable import VocabMobile
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

final class MobileTransferTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        L10n.setCurrent(.en)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        L10n.setCurrent(.en)
        super.tearDown()
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let model: MobileAppModel
        let root: URL
        let data: URL
        /// Stand-in for a file provider location outside the sandbox (what `fileImporter` returns).
        let files: URL
        let staging: URL
        let access: RecordingScopedAccess
        let fileSystem: RecordingFileSystem
        let sink: MobileCapturingLogSink

        var paths: AppPaths { AppPaths(applicationSupportDirectory: data) }

        var backupsDirectory: URL { paths.backupsDirectory }

        /// Writes `entries` as an export file in `files/` (as if picked in Files).
        func writePickedFile(_ entries: [Entry], name: String = "dictionary.json") throws -> URL {
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let url = files.appendingPathComponent(name)
            try DictionaryExporter.exportData(entries: entries, now: mobileTestEpoch).write(to: url)
            return url
        }

        func writePickedRaw(_ bytes: Data, name: String) throws -> URL {
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let url = files.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }

        /// Files left in the staging directory (temporary copies).
        func stagedFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).filter { !$0.hasPrefix(".") }
        }

        func backupFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)) ?? [])
                .filter { $0.hasPrefix("dictionary-backup-") && $0.hasSuffix(".json") }
                .sorted()
        }

        func dictionaryBytes() -> Data? {
            try? Data(contentsOf: paths.dictionaryURL)
        }

        func words() -> [String] {
            model.entries.map(\.word).sorted()
        }
    }

    @MainActor
    private func makeHarness(
        entries: [Entry] = [],
        withKey: Bool = false,
        accessGranted: Bool = true,
        store: DictionaryStoring? = nil
    ) async throws -> Harness {
        let root = makeTemporaryDirectory(self)
        let data = root.appendingPathComponent("Data", isDirectory: true)
        if !entries.isEmpty {
            try writeDictionary(entries, to: data)
        }
        let access = RecordingScopedAccess(granted: accessGranted)
        let fileSystem = RecordingFileSystem(log: access.log)
        let sink = MobileCapturingLogSink()
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        let secrets = InMemorySecretStore(values: withKey ? [.anthropicAPIKey: MobileClaudeFixtures.apiKey] : [:])
        let container = AppContainer(
            paths: AppPaths(applicationSupportDirectory: data),
            settings: InMemorySettingsStore(),
            store: store,
            fileSystem: fileSystem,
            secrets: secrets,
            transport: URLSessionTransport(session: MockURLProtocol.makeSession()),
            logSink: sink,
            securityScopedAccess: access,
            importStagingDirectory: staging
        )
        let model = MobileAppModel(container: container)
        await model.start()
        XCTAssertTrue(model.isLoaded)
        return Harness(
            model: model,
            root: root,
            data: data,
            files: root.appendingPathComponent("Files", isDirectory: true),
            staging: staging,
            access: access,
            fileSystem: fileSystem,
            sink: sink
        )
    }

    /// Picks `url` in the (fake) Files sheet and chooses Merge; waits for the import.
    @MainActor
    private func importMerging(_ url: URL, into model: MobileAppModel, file: StaticString = #filePath, line: UInt = #line) async {
        model.handleImportSelection(.success(url))
        guard case .chooseMode? = model.importStage else {
            return XCTFail("expected the mode dialog, got \(String(describing: model.importStage)); message: \(String(describing: model.transferMessage?.text))", file: file, line: line)
        }
        let task = model.selectImportMode(.merge)
        XCTAssertNotNil(task, file: file, line: line)
        XCTAssertNil(model.importStage, "Merge closes the dialog synchronously", file: file, line: line)
        await task?.value
    }

    /// Entries with every field the export must carry: lemma/POS/IPA/example, IT variant, `sourceLanguage`, a
    /// pending entry with `languageHint`, a failed one with `lastError` and a hint.
    private static func richEntries() -> [Entry] {
        let italian = EntryVariant(
            word: "casa",
            lemma: "casa",
            partOfSpeech: "noun",
            transcription: "/ˈka.za/",
            translations: ["дім", "будинок"],
            example: Example(source: "La casa è grande.", translation: "Будинок великий."),
            status: .ready,
            sourceKey: "house"
        )
        let house = Entry(
            languagePair: LanguagePair.englishUkrainian.id,
            word: "house",
            lemma: "house",
            partOfSpeech: "noun",
            transcription: "/haʊs/",
            translations: ["будинок", "дім"],
            example: Example(source: "The house is big.", translation: "Будинок великий."),
            status: .ready,
            createdAt: mobileTestEpoch,
            updatedAt: mobileTestEpoch.addingTimeInterval(60),
            variants: ["it": italian],
            sourceLanguage: nil
        )
        let pendingVariant = EntryVariant(status: .pending, sourceKey: "window")
        let window = Entry(
            languagePair: LanguagePair.englishUkrainian.id,
            word: "window",
            translations: ["вікно"],
            status: .ready,
            createdAt: mobileTestEpoch.addingTimeInterval(10),
            updatedAt: mobileTestEpoch.addingTimeInterval(10),
            variants: ["it": pendingVariant],
            sourceLanguage: nil
        )
        let come = Entry(
            languagePair: LanguagePair.englishUkrainian.id,
            word: "come",
            status: .pending,
            createdAt: mobileTestEpoch.addingTimeInterval(20),
            updatedAt: mobileTestEpoch.addingTimeInterval(20),
            languageHint: "it"
        )
        let pane = Entry(
            languagePair: LanguagePair.englishUkrainian.id,
            word: "pane",
            status: .failed,
            lastError: "Network unavailable",
            createdAt: mobileTestEpoch.addingTimeInterval(30),
            updatedAt: mobileTestEpoch.addingTimeInterval(30),
            languageHint: "it"
        )
        // Italian selection (`sourceLanguage = "it"`; EN entries keep `nil` = pair source language, D25).
        let gelato = Entry(
            languagePair: LanguagePair.englishUkrainian.id,
            word: "gelato",
            translations: ["морозиво"],
            status: .ready,
            createdAt: mobileTestEpoch.addingTimeInterval(40),
            updatedAt: mobileTestEpoch.addingTimeInterval(40),
            sourceLanguage: "it"
        )
        return [house, window, come, pane, gelato]
    }

    private static func sortedByWord(_ entries: [Entry]) -> [Entry] {
        entries.sorted { $0.word < $1.word }
    }

    // MARK: - I5.1 Export = schema v1

    @MainActor
    func testExportRoundTripsThroughCoreImporter() async throws {
        let original = Self.richEntries()
        let source = try await makeHarness(entries: original)
        XCTAssertEqual(source.model.entries.count, original.count)

        let prepared = await source.model.prepareExport()
        XCTAssertTrue(prepared)
        let export = try XCTUnwrap(source.model.preparedExport)
        XCTAssertTrue(source.model.isExporterPresented, "fileExporter is shown")
        XCTAssertFalse(source.model.isTransferring)
        XCTAssertNil(source.model.transferMessage)
        XCTAssertEqual(export.entryCount, original.count)

        // Structural check (Foundation only): schema v1, `exportedAt`, all entries; optional fields present as is.
        let top = try XCTUnwrap(try JSONSerialization.jsonObject(with: export.data) as? [String: Any])
        XCTAssertEqual(top["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(top["exportedAt"] as? String)
        let rawEntries = try XCTUnwrap(top["entries"] as? [[String: Any]])
        XCTAssertEqual(rawEntries.count, original.count)
        let rawByWord = Dictionary(uniqueKeysWithValues: rawEntries.compactMap { raw in
            (raw["word"] as? String).map { ($0, raw) }
        })
        XCTAssertEqual(rawByWord["come"]?["languageHint"] as? String, "it")
        XCTAssertEqual(rawByWord["pane"]?["languageHint"] as? String, "it")
        XCTAssertNil(rawByWord["house"]?["languageHint"], "no hint → key omitted (bytes as before I2a)")
        let houseVariants = rawByWord["house"]?["variants"] as? [String: Any]
        XCTAssertEqual((houseVariants?["it"] as? [String: Any])?["word"] as? String, "casa")

        // The user saves the file in Files; the alert reports the count and the file name.
        let saved = source.files.appendingPathComponent(export.fileName)
        try FileManager.default.createDirectory(at: source.files, withIntermediateDirectories: true)
        try export.data.write(to: saved)
        source.model.finishExport(.success(saved))
        XCTAssertNil(source.model.preparedExport)
        XCTAssertFalse(source.model.isExporterPresented)
        let message = try XCTUnwrap(source.model.transferMessage)
        XCTAssertFalse(message.isError)
        XCTAssertEqual(message.title, L10n.text(.transferExportedTitle))
        XCTAssertTrue(message.text.contains(L10n.text(
            .transferExportedText, ["count": String(original.count), "path": "dictionary.json"]
        )), message.text)
        XCTAssertTrue(message.text.contains(L10n.text(.mobileTransferAirDropHint)))

        // Semantic round trip through the app's own import (core `DictionaryTransferService` → importer) into an
        // empty dictionary on "another device": same entries, fields, variants and `languageHint` (not bytes).
        let target = try await makeHarness()
        target.model.handleImportSelection(.success(saved))
        let task = target.model.selectImportMode(.merge)
        await task?.value
        // `entries` was refreshed right after the import, before the post-import queue pass touched anything.
        let report = try XCTUnwrap(target.model.lastImportReport)
        XCTAssertEqual(report, ImportReport(added: original.count, updated: 0, skipped: 0))
        XCTAssertEqual(Self.sortedByWord(target.model.entries), Self.sortedByWord(original))
        // Field by field for the parts the plan names explicitly.
        let imported = Dictionary(uniqueKeysWithValues: target.model.entries.map { ($0.id, $0) })
        for entry in original {
            let copy = try XCTUnwrap(imported[entry.id], "entry \(entry.word) kept its id")
            XCTAssertEqual(copy.word, entry.word)
            XCTAssertEqual(copy.status, entry.status)
            XCTAssertEqual(copy.translations, entry.translations)
            XCTAssertEqual(copy.transcription, entry.transcription)
            XCTAssertEqual(copy.example, entry.example)
            XCTAssertEqual(copy.lemma, entry.lemma)
            XCTAssertEqual(copy.partOfSpeech, entry.partOfSpeech)
            XCTAssertEqual(copy.sourceLanguage, entry.sourceLanguage)
            XCTAssertEqual(copy.createdAt, entry.createdAt)
            XCTAssertEqual(copy.updatedAt, entry.updatedAt)
            XCTAssertEqual(copy.variants, entry.variants)
        }
        XCTAssertEqual(imported[original[2].id]?.languageHint, "it", "pending hint survives the round trip")
        XCTAssertEqual(imported[original[3].id]?.lastError, "Network unavailable")
        XCTAssertEqual(imported[original[3].id]?.languageHint, "it")
        XCTAssertEqual(imported[original[4].id]?.sourceLanguage, "it", "Italian-selection marker survives")

        await target.model.postImportProcessing?.value
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "no key → no request")
    }

    @MainActor
    func testExportFileNameAndContentType() async throws {
        XCTAssertEqual(DictionaryFileFormat.defaultFileName, "dictionary.json")
        XCTAssertEqual(MobileAppModel.exportFileName, "dictionary.json", "same default name as on macOS")
        XCTAssertEqual(DictionaryFileFormat.contentTypeIdentifier, "public.json")
        XCTAssertEqual(PreparedExport(data: Data(), entryCount: 0).fileName, "dictionary.json")

        let harness = try await makeHarness(entries: [makeTestEntry("house", translations: ["дім"], createdOffset: 0)])
        let ok = await harness.model.prepareExport()
        XCTAssertTrue(ok)
        let prepared = try XCTUnwrap(harness.model.preparedExport)
        XCTAssertEqual(prepared.fileName, "dictionary.json")
        XCTAssertFalse(prepared.fileName.hasSuffix(".json.json"))
        XCTAssertEqual(prepared.entryCount, 1)

        #if canImport(UniformTypeIdentifiers)
        XCTAssertEqual(UTType.json.identifier, DictionaryFileFormat.contentTypeIdentifier)
        XCTAssertEqual(UTType(DictionaryFileFormat.contentTypeIdentifier), .json)
        #endif
        #if canImport(SwiftUI) && canImport(UniformTypeIdentifiers)
        XCTAssertEqual(DictionaryFileFormat.contentType, .json)
        XCTAssertEqual(DictionaryJSONDocument.readableContentTypes, [.json])
        XCTAssertEqual(DictionaryJSONDocument.writableContentTypes, [.json])
        XCTAssertEqual(DictionaryJSONDocument(prepared).data, prepared.data, "the document writes the prepared bytes")
        #endif
    }

    @MainActor
    func testExportCancelledShowsNoAlertAndWriteFailureDoes() async throws {
        let harness = try await makeHarness(entries: [makeTestEntry("house", translations: ["дім"], createdOffset: 0)])
        await harness.model.prepareExport()
        harness.model.finishExport(.failure(CocoaError(.userCancelled)))
        XCTAssertNil(harness.model.transferMessage, "cancelling the Files sheet is not an error")
        XCTAssertNil(harness.model.preparedExport)
        XCTAssertFalse(harness.model.isExporterPresented)

        await harness.model.prepareExport()
        harness.model.finishExport(.failure(CocoaError(.fileWriteNoPermission)))
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.title, L10n.text(.transferExportFailedTitle))
        XCTAssertTrue(harness.model.canTransfer)
    }

    // MARK: - I5.2 Import merge/replace

    @MainActor
    func testImportCopiesSecurityScopedFileBeforeReading() async throws {
        let harness = try await makeHarness()
        let picked = try harness.writePickedFile([makeTestEntry("house", translations: ["дім"], createdOffset: 0)])
        harness.access.log.clear()

        harness.model.handleImportSelection(.success(picked))
        guard case .chooseMode(let staged)? = harness.model.importStage else {
            return XCTFail("expected the mode dialog, got \(String(describing: harness.model.importStage))")
        }
        XCTAssertFalse(harness.model.isImporterPresented)
        XCTAssertNotEqual(staged, picked, "the import reads a local copy, not the picked URL")
        XCTAssertEqual(staged.deletingLastPathComponent().standardizedFileURL.path, harness.staging.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "copy exists while the dialog is shown")
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: picked))

        // start → copy (inside the scope) → stop, all before the mode dialog; nothing read yet.
        let pickedPath = picked.standardizedFileURL.path
        let stagedPath = staged.standardizedFileURL.path
        XCTAssertEqual(harness.access.log.events, [
            "start \(pickedPath)",
            "copy \(pickedPath) -> \(stagedPath)",
            "stop \(pickedPath)",
        ])

        let task = harness.model.selectImportMode(.merge)
        await task?.value
        XCTAssertEqual(harness.words(), ["house"])

        let events = harness.access.log.events
        XCTAssertTrue(events.contains("read \(stagedPath)"), "core reads the staged copy: \(events)")
        XCTAssertFalse(events.contains("read \(pickedPath)"), "the security-scoped URL is never read directly")
        XCTAssertEqual(events.filter { $0.hasPrefix("start ") }.count, 1)
        XCTAssertEqual(events.filter { $0.hasPrefix("stop ") }.count, 1, "access is balanced")
        let stopIndex = try XCTUnwrap(events.firstIndex(of: "stop \(pickedPath)"))
        let readIndex = try XCTUnwrap(events.firstIndex(of: "read \(stagedPath)"))
        XCTAssertLessThan(stopIndex, readIndex, "scope is closed before the import reads the copy")

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staged copy deleted after the import")
        XCTAssertEqual(harness.stagedFiles(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path), "the user's file is never deleted")
    }

    @MainActor
    func testStagingWithoutScopedAccessDoesNotStop() async throws {
        // `startAccessing` → false (file already reachable): copy is attempted, `stop` is not called.
        let harness = try await makeHarness(accessGranted: false)
        let picked = try harness.writePickedFile([makeTestEntry("house", translations: ["дім"], createdOffset: 0)])
        harness.access.log.clear()

        harness.model.handleImportSelection(.success(picked))
        guard case .chooseMode? = harness.model.importStage else { return XCTFail("expected the mode dialog") }
        let events = harness.access.log.events
        XCTAssertEqual(events.filter { $0.hasPrefix("start ") }.count, 1)
        XCTAssertEqual(events.filter { $0.hasPrefix("stop ") }.count, 0, "stop only after a successful start")
        XCTAssertEqual(events.filter { $0.hasPrefix("copy ") }.count, 1)
        harness.model.cancelImport()
    }

    @MainActor
    func testStagerDiscardNeverDeletesFilesOutsideItsDirectory() async throws {
        let harness = try await makeHarness()
        let picked = try harness.writePickedFile([])
        harness.model.container.importStager.discard(picked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))
    }

    @MainActor
    func testMergeReportShown() async throws {
        let local = [
            makeTestEntry("house", translations: ["дім"], createdOffset: 0),
            makeTestEntry("window", translations: ["вікно"], createdOffset: 10),
        ]
        let harness = try await makeHarness(entries: local)
        let backupsBefore = harness.model.backupCount

        // File: newer `house` (updated), same `window` (skipped, equal updatedAt), new `tree` (added) and one
        // invalid entry without `word` (skipped with a reason, D13).
        var newerHouse = local[0]
        newerHouse.translations = ["будинок"]
        newerHouse.updatedAt = mobileTestEpoch.addingTimeInterval(500)
        let tree = makeTestEntry("tree", translations: ["дерево"], createdOffset: 20)
        let valid = try DictionaryExporter.exportData(entries: [newerHouse, local[1], tree], now: mobileTestEpoch)
        var top = try XCTUnwrap(try JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var rawEntries = try XCTUnwrap(top["entries"] as? [[String: Any]])
        var broken = try XCTUnwrap(rawEntries.last)
        broken["id"] = UUID().uuidString
        broken.removeValue(forKey: "word")
        rawEntries.append(broken)
        top["entries"] = rawEntries
        let picked = try harness.writePickedRaw(try JSONSerialization.data(withJSONObject: top), name: "from-mac.json")

        await importMerging(picked, into: harness.model)

        let report = try XCTUnwrap(harness.model.lastImportReport)
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.skipped, 2)
        XCTAssertEqual(report.skippedReasons.count, 2)
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertFalse(message.isError)
        XCTAssertEqual(message.title, L10n.text(.transferImportedTitle))
        XCTAssertEqual(message.text, MobileAppModel.reportText(report))
        XCTAssertTrue(message.text.hasPrefix("Added 1, updated 1, skipped 2"), message.text)
        XCTAssertTrue(message.text.contains(L10n.text(.transferReportSkippedHeader)))
        for reason in report.skippedReasons {
            XCTAssertTrue(message.text.contains("• \(reason)"), message.text)
        }

        XCTAssertEqual(harness.words(), ["house", "tree", "window"])
        XCTAssertEqual(harness.model.entries.first { $0.word == "house" }?.translations, ["будинок"])
        XCTAssertEqual(harness.model.backupCount, backupsBefore, "merge makes no backup")
        XCTAssertEqual(harness.backupFiles(), [])
        XCTAssertFalse(harness.model.isTransferring)
        XCTAssertTrue(harness.model.canTransfer)
        XCTAssertEqual(harness.stagedFiles(), [])
        let runner = try XCTUnwrap(harness.model.container.backgroundTasks as? NoopBackgroundTaskRunner)
        XCTAssertTrue(runner.startedNames.contains("VocabImport"), "import runs in a background task (DI18)")
        XCTAssertTrue(runner.activeTokens.isEmpty)
    }

    @MainActor
    func testMergeReportInUkrainian() async throws {
        let harness = try await makeHarness()
        harness.model.setInterfaceLanguage(.uk)
        let picked = try harness.writePickedFile([makeTestEntry("house", translations: ["дім"], createdOffset: 0)])
        await importMerging(picked, into: harness.model)
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertEqual(message.title, L10n.text(.transferImportedTitle, language: .uk))
        XCTAssertTrue(message.text.hasPrefix(ImportReport(added: 1).summary(in: .uk)), message.text)
    }

    @MainActor
    func testReportTextTruncatesSkipReasons() async {
        L10n.setCurrent(.en)
        let reasons = (1...7).map { "Entry #\($0): missing field word" }
        let report = ImportReport(added: 0, updated: 0, skipped: 7, skippedReasons: reasons)
        let text = MobileAppModel.reportText(report)
        XCTAssertTrue(text.hasPrefix("Added 0, updated 0, skipped 7"))
        for reason in reasons.prefix(MobileAppModel.maxReportedSkipReasons) {
            XCTAssertTrue(text.contains("• \(reason)"))
        }
        XCTAssertFalse(text.contains(reasons[5]))
        XCTAssertFalse(text.contains(reasons[6]))
        XCTAssertTrue(text.contains("…and 2 more"), text)

        XCTAssertEqual(MobileAppModel.reportText(ImportReport(added: 3)), "Added 3, updated 0, skipped 0")
    }

    @MainActor
    func testReplaceMakesBackup() async throws {
        let local = [
            makeTestEntry("house", translations: ["дім"], createdOffset: 0),
            makeTestEntry("window", translations: ["вікно"], createdOffset: 10),
        ]
        let harness = try await makeHarness(entries: local)
        XCTAssertEqual(harness.model.backupCount, 0)
        let bytesBefore = try XCTUnwrap(harness.dictionaryBytes())
        let picked = try harness.writePickedFile([makeTestEntry("tree", translations: ["дерево"], createdOffset: 20)])

        harness.model.handleImportSelection(.success(picked))
        guard case .chooseMode(let staged)? = harness.model.importStage else { return XCTFail("expected the mode dialog") }
        XCTAssertNil(harness.model.selectImportMode(.replace), "Replace… asks for confirmation first")
        XCTAssertEqual(harness.model.importStage, .confirmReplace(staged))
        XCTAssertEqual(harness.words(), ["house", "window"], "nothing replaced before confirmation")
        XCTAssertEqual(harness.backupFiles(), [])

        let task = harness.model.confirmReplaceImport()
        XCTAssertNotNil(task)
        XCTAssertNil(harness.model.importStage)
        await task?.value

        XCTAssertEqual(harness.words(), ["tree"], "dictionary replaced by the file")
        XCTAssertEqual(harness.model.lastImportReport, ImportReport(added: 1))
        XCTAssertEqual(harness.model.transferMessage?.isError, false)

        // Backup of the previous dictionary in Backups/, counted in Settings → Data.
        let backups = harness.backupFiles()
        XCTAssertEqual(backups.count, 1, "exactly one replace backup: \(backups)")
        XCTAssertEqual(harness.model.backupCount, 1, "backup count refreshed after the import")
        let backupURL = harness.backupsDirectory.appendingPathComponent(try XCTUnwrap(backups.first))
        XCTAssertEqual(try Data(contentsOf: backupURL), bytesBefore, "the backup is the previous file, byte for byte")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "staged copy deleted")

        // The new file on disk holds only the imported entry.
        let onDisk = try XCTUnwrap(harness.dictionaryBytes())
        let top = try XCTUnwrap(try JSONSerialization.jsonObject(with: onDisk) as? [String: Any])
        XCTAssertEqual((top["entries"] as? [[String: Any]])?.compactMap { $0["word"] as? String }, ["tree"])
    }

    @MainActor
    func testCancelDeletesStagedCopy() async throws {
        let local = [makeTestEntry("house", translations: ["дім"], createdOffset: 0)]
        let harness = try await makeHarness(entries: local)
        let bytesBefore = harness.dictionaryBytes()
        let picked = try harness.writePickedFile([makeTestEntry("tree", translations: ["дерево"], createdOffset: 20)])

        // Cancel in the mode dialog.
        harness.model.handleImportSelection(.success(picked))
        guard case .chooseMode(let first)? = harness.model.importStage else { return XCTFail("expected the mode dialog") }
        harness.model.cancelImport()
        XCTAssertNil(harness.model.importStage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        // Cancel in the Replace confirmation.
        harness.model.handleImportSelection(.success(picked))
        guard case .chooseMode(let second)? = harness.model.importStage else { return XCTFail("expected the mode dialog") }
        harness.model.selectImportMode(.replace)
        harness.model.cancelImport()
        XCTAssertNil(harness.model.importStage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))

        XCTAssertEqual(harness.stagedFiles(), [])
        XCTAssertNil(harness.model.transferMessage, "cancel shows no alert")
        XCTAssertNil(harness.model.lastImportReport)
        XCTAssertEqual(harness.words(), ["house"])
        XCTAssertEqual(harness.dictionaryBytes(), bytesBefore, "dictionary file untouched")
        XCTAssertEqual(harness.backupFiles(), [], "cancelled Replace makes no backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))
        XCTAssertNil(harness.model.confirmReplaceImport(), "nothing to confirm after cancel")
        XCTAssertNil(harness.model.selectImportMode(.merge), "nothing to merge after cancel")
    }

    @MainActor
    func testUserCancelledPickerShowsNoAlert() async throws {
        let harness = try await makeHarness()
        harness.model.beginImport()
        XCTAssertTrue(harness.model.isImporterPresented)
        harness.model.handleImportSelection(.failure(CocoaError(.userCancelled)))
        XCTAssertFalse(harness.model.isImporterPresented)
        XCTAssertNil(harness.model.transferMessage)
        XCTAssertNil(harness.model.importStage)
        XCTAssertTrue(DocumentPickerError.isUserCancellation(CocoaError(.userCancelled)))
        XCTAssertFalse(DocumentPickerError.isUserCancellation(CocoaError(.fileReadNoPermission)))

        // A real picker error is reported.
        harness.model.handleImportSelection(.failure(CocoaError(.fileReadNoPermission)))
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.title, L10n.text(.transferImportFailedTitle))
        XCTAssertNil(harness.model.importStage)
    }

    @MainActor
    func testMissingFileShowsErrorAndLeavesDictionaryUnchanged() async throws {
        let local = [makeTestEntry("house", translations: ["дім"], createdOffset: 0)]
        let harness = try await makeHarness(entries: local)
        let bytesBefore = harness.dictionaryBytes()
        let missing = harness.files.appendingPathComponent("gone.json")

        harness.model.handleImportSelection(.success(missing))

        XCTAssertNil(harness.model.importStage, "no mode dialog for an unreadable file")
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.title, L10n.text(.transferImportFailedTitle))
        XCTAssertTrue(message.text.hasSuffix(L10n.text(.importUntouched)), message.text)
        XCTAssertFalse(message.text.contains(harness.root.path), "no file paths in the alert: \(message.text)")
        XCTAssertEqual(harness.stagedFiles(), [])
        XCTAssertEqual(harness.words(), ["house"])
        XCTAssertEqual(harness.dictionaryBytes(), bytesBefore)
        XCTAssertEqual(harness.access.log.events.filter { $0.hasPrefix("stop ") }.count, 1, "scope closed on failure too")
        XCTAssertTrue(harness.model.canTransfer)
    }

    @MainActor
    func testCorruptFileShowsErrorAndLeavesDictionaryUnchanged() async throws {
        let local = [makeTestEntry("house", translations: ["дім"], createdOffset: 0)]
        let harness = try await makeHarness(entries: local)
        let bytesBefore = harness.dictionaryBytes()

        // (a) not JSON, Merge.
        let notJSON = try harness.writePickedRaw(Data("hello, this is not json".utf8), name: "notes.json")
        await importMerging(notJSON, into: harness.model)
        var message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.title, L10n.text(.transferImportFailedTitle))
        XCTAssertEqual(message.text, ImportError.notJSON.userMessage)
        XCTAssertNil(harness.model.lastImportReport)
        harness.model.transferMessage = nil

        // (b) newer schema, Replace (confirmed) → no backup, nothing replaced.
        let newer = try harness.writePickedRaw(Data(#"{"schemaVersion": 2, "entries": []}"#.utf8), name: "v2.json")
        harness.model.handleImportSelection(.success(newer))
        harness.model.selectImportMode(.replace)
        await harness.model.confirmReplaceImport()?.value
        message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.text, ImportError.unsupportedSchemaVersion(2).userMessage)

        // (c) empty file.
        harness.model.transferMessage = nil
        let empty = try harness.writePickedRaw(Data(), name: "empty.json")
        await importMerging(empty, into: harness.model)
        XCTAssertEqual(harness.model.transferMessage?.text, ImportError.emptyFile.userMessage)

        XCTAssertEqual(harness.words(), ["house"])
        XCTAssertEqual(harness.dictionaryBytes(), bytesBefore, "dictionary file untouched")
        XCTAssertEqual(harness.backupFiles(), [], "an invalid file never triggers a backup")
        XCTAssertEqual(harness.stagedFiles(), [], "staged copies deleted on failure")
        XCTAssertFalse(harness.model.isTransferring)
        XCTAssertTrue(harness.model.canTransfer)
    }

    @MainActor
    func testConcurrentTransferBlocked() async throws {
        let store = SlowSavingStore(entries: [makeTestEntry("house", translations: ["дім"], createdOffset: 0)], saveDelay: 0.4)
        let harness = try await makeHarness(store: store)
        let first = try harness.writePickedFile([makeTestEntry("tree", translations: ["дерево"], createdOffset: 20)])
        let second = try harness.writePickedFile(
            [makeTestEntry("river", translations: ["річка"], createdOffset: 30)], name: "second.json"
        )

        harness.model.handleImportSelection(.success(first))
        let task = harness.model.selectImportMode(.merge)
        for _ in 0..<400 where !harness.model.isTransferring {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(harness.model.isTransferring, "import in flight")
        XCTAssertFalse(harness.model.canTransfer)

        // Everything else is refused while the import runs.
        let exported = await harness.model.prepareExport()
        XCTAssertFalse(exported)
        XCTAssertNil(harness.model.preparedExport)
        XCTAssertFalse(harness.model.isExporterPresented)
        harness.model.beginImport()
        XCTAssertFalse(harness.model.isImporterPresented)
        harness.model.handleImportSelection(.success(second))
        XCTAssertNil(harness.model.importStage, "no second mode dialog during an import")
        let direct = await harness.model.import(from: second, mode: .replace)
        XCTAssertNil(direct, "a second import does not run concurrently")
        XCTAssertTrue(harness.model.isTransferring, "the first import still owns the flag")

        await task?.value
        XCTAssertFalse(harness.model.isTransferring)
        XCTAssertTrue(harness.model.canTransfer)
        XCTAssertEqual(harness.words(), ["house", "tree"], "only the first import applied")
        XCTAssertEqual(harness.model.lastImportReport, ImportReport(added: 1))
        XCTAssertEqual(store.saveCount, 1, "one save for the one import")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path), "the user's file is never deleted")
    }

    @MainActor
    func testImportedPendingProcessedOnce() async throws {
        let harness = try await makeHarness(withKey: true)
        XCTAssertTrue(harness.model.hasAPIKey)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        MockURLProtocol.setDelay(0.2)

        let pendingHouse = makeTestEntry("house", status: .pending, createdOffset: 0)
        let readyWindow = makeTestEntry(
            "window",
            translations: ["вікно"],
            createdOffset: 10,
            variants: ["it": EntryVariant(word: "finestra", translations: ["вікно"], status: .ready, sourceKey: "window")]
        )
        let picked = try harness.writePickedFile([pendingHouse, readyWindow])

        await importMerging(picked, into: harness.model)
        XCTAssertEqual(harness.model.lastImportReport, ImportReport(added: 2))
        let processing = try XCTUnwrap(harness.model.postImportProcessing, "imported pending → one queue pass")
        // A foreground activation arriving while the post-import pass is in flight must not ask again.
        await harness.model.processPending(trigger: .foreground)
        await processing.value

        XCTAssertEqual(MockURLProtocol.requestCount, 1, "pending imported entry → exactly 1 request; ready → 0")
        XCTAssertEqual(harness.model.entries.first { $0.word == "house" }?.status, .ready)
        XCTAssertEqual(harness.model.entries.first { $0.word == "house" }?.readyVariant("it")?.word, "casa")
        XCTAssertEqual(harness.sink.lines.filter { $0.contains("trigger=imported") && $0.contains("started") }.count, 1,
                       "one post-import queue run: \(harness.sink.lines)")

        // Later activations: nothing pending → 0.
        await harness.model.processPending(trigger: .foreground)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        // Re-import the same file: the pending copy does not overwrite the local ready entry → 0 requests.
        let processingBefore = harness.model.postImportProcessing
        await importMerging(picked, into: harness.model)
        let report = try XCTUnwrap(harness.model.lastImportReport)
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped, 2)
        await harness.model.postImportProcessing?.value
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "re-import of the same file → 0 requests")
        XCTAssertTrue(harness.model.postImportProcessing == processingBefore, "no new queue pass without pending entries")
        XCTAssertEqual(harness.words(), ["house", "window"])
    }

    @MainActor
    func testImportedReadyEntriesMakeNoRequests() async throws {
        let harness = try await makeHarness(withKey: true)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])
        let picked = try harness.writePickedFile(Self.richEntries().filter { $0.status == .ready })
        await importMerging(picked, into: harness.model)
        XCTAssertEqual(harness.model.lastImportReport?.added, 3)
        XCTAssertNil(harness.model.postImportProcessing, "no pending → no queue pass")
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "ready entries (with IT versions) → 0 requests")
        // Italian mode is off: no backfill is triggered by the import either.
        XCTAssertNil(harness.model.backfillTask)
    }

    @MainActor
    func testTransferUnavailableBeforeLoad() async throws {
        let root = makeTemporaryDirectory(self)
        let container = AppContainer(
            paths: AppPaths(applicationSupportDirectory: root),
            settings: InMemorySettingsStore(),
            importStagingDirectory: root.appendingPathComponent("Staging", isDirectory: true)
        )
        let model = MobileAppModel(container: container)
        XCTAssertFalse(model.canTransfer)
        let exported = await model.prepareExport()
        XCTAssertFalse(exported)
        model.beginImport()
        XCTAssertFalse(model.isImporterPresented)
    }
}

// MARK: - Fakes

/// Shared ordered event log for the fake security-scoped access and the recording file system.
final class TransferEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(event)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = []
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Fake `SecurityScopedAccessing`: records `start`/`stop` with the standardized path.
final class RecordingScopedAccess: SecurityScopedAccessing, @unchecked Sendable {
    let log = TransferEventLog()
    private let granted: Bool

    init(granted: Bool) {
        self.granted = granted
    }

    func startAccessing(_ url: URL) -> Bool {
        log.append("start \(url.standardizedFileURL.path)")
        return granted
    }

    func stopAccessing(_ url: URL) {
        log.append("stop \(url.standardizedFileURL.path)")
    }
}

/// `LocalFileSystem` that records copies and reads into the same log (to check the order start → copy → stop and
/// that the core reads only the staged copy).
final class RecordingFileSystem: FileSystem, @unchecked Sendable {
    private let base = LocalFileSystem()
    private let log: TransferEventLog

    init(log: TransferEventLog) {
        self.log = log
    }

    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }

    func readData(at url: URL) throws -> Data {
        log.append("read \(url.standardizedFileURL.path)")
        return try base.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws { try base.writeData(data, to: url) }

    func replaceItem(at target: URL, withItemAt temp: URL) throws { try base.replaceItem(at: target, withItemAt: temp) }

    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }

    func copyItem(at source: URL, to destination: URL) throws {
        log.append("copy \(source.standardizedFileURL.path) -> \(destination.standardizedFileURL.path)")
        try base.copyItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws { try base.removeItem(at: url) }

    func createDirectory(at url: URL) throws { try base.createDirectory(at: url) }

    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
}

/// In-memory `DictionaryStoring` whose `save` is slow (keeps an import in flight).
final class SlowSavingStore: DictionaryStoring, @unchecked Sendable {
    let fileURL = URL(fileURLWithPath: "/dev/null/vocab-slow/dictionary.json")
    private let lock = NSLock()
    private var file: DictionaryFile
    private var saves = 0
    private let saveDelay: TimeInterval

    init(entries: [Entry], saveDelay: TimeInterval) {
        self.file = DictionaryFile(entries: entries)
        self.saveDelay = saveDelay
    }

    var saveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return saves
    }

    func load() throws -> LoadResult {
        lock.lock(); defer { lock.unlock() }
        return LoadResult(file: file)
    }

    func save(_ newFile: DictionaryFile) throws {
        Thread.sleep(forTimeInterval: saveDelay)
        lock.lock(); defer { lock.unlock() }
        saves += 1
        file = newFile
    }
}
