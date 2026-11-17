// I6 (PROGRESS «I6 — контекст»): (1) the import copy of a picked file happens inside `FileReadCoordinating`
// (`NSFileCoordinator` on device: a not-yet-downloaded iCloud Drive file is downloaded first), within the
// security-scoped access window, and reads the URL the coordinator hands back; (2) the inbox banner "Not saved yet: N"
// shows the real number of items left in the inbox after a storage failure mid-pass.
//
// Real stack: `AppContainer(…securityScopedAccess:importCoordinator:importStagingDirectory:)` → `MobileAppModel`
// (`handleImportSelection` → `selectImportMode`) → `ImportFileStager` → `DictionaryTransferService`. The
// `LiveFileReadCoordinator` test is Darwin-only (`NSFileCoordinator` is not in swift-corelibs-foundation).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import VocabCore
@testable import VocabMobile

final class ImportCoordinationTests: XCTestCase {
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
        let files: URL
        let staging: URL
        let access: RecordingScopedAccess
        let coordinator: RecordingReadCoordinator

        var log: TransferEventLog { access.log }

        func writePickedFile(_ entries: [Entry], name: String = "dictionary.json") throws -> URL {
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            let url = files.appendingPathComponent(name)
            try DictionaryExporter.exportData(entries: entries, now: mobileTestEpoch).write(to: url)
            return url
        }

        func stagedFiles() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).filter { !$0.hasPrefix(".") }
        }

        func words() -> [String] {
            model.entries.map(\.word).sorted()
        }
    }

    @MainActor
    private func makeHarness(
        accessGranted: Bool = true,
        coordinatorBehavior: RecordingReadCoordinator.Behavior = .passthrough
    ) async throws -> Harness {
        let root = makeTemporaryDirectory(self)
        let access = RecordingScopedAccess(granted: accessGranted)
        let fileSystem = RecordingFileSystem(log: access.log)
        let coordinator = RecordingReadCoordinator(log: access.log, behavior: coordinatorBehavior)
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        let container = AppContainer(
            paths: AppPaths(applicationSupportDirectory: root.appendingPathComponent("Data", isDirectory: true)),
            settings: InMemorySettingsStore(),
            fileSystem: fileSystem,
            secrets: InMemorySecretStore(values: [:]),
            transport: URLSessionTransport(session: MockURLProtocol.makeSession()),
            logSink: MobileCapturingLogSink(),
            securityScopedAccess: access,
            importCoordinator: coordinator,
            importStagingDirectory: staging
        )
        let model = MobileAppModel(container: container)
        await model.start()
        XCTAssertTrue(model.isLoaded)
        return Harness(
            model: model,
            files: root.appendingPathComponent("Files", isDirectory: true),
            staging: staging,
            access: access,
            coordinator: coordinator
        )
    }

    // MARK: - Coordinated copy

    @MainActor
    func testCopyHappensInsideCoordinationWithinScopedAccess() async throws {
        let harness = try await makeHarness()
        let picked = try harness.writePickedFile([makeTestEntry("house", translations: ["дім"], createdOffset: 0)])
        harness.log.clear()

        harness.model.handleImportSelection(.success(picked))
        guard case .chooseMode(let staged)? = harness.model.importStage else {
            return XCTFail("expected the mode dialog, got \(String(describing: harness.model.importStage)); "
                           + "message: \(String(describing: harness.model.transferMessage?.text))")
        }
        let pickedPath = picked.standardizedFileURL.path
        let stagedPath = staged.standardizedFileURL.path
        XCTAssertEqual(harness.log.events, [
            "start \(pickedPath)",
            "coordinate-begin \(pickedPath)",
            "copy \(pickedPath) -> \(stagedPath)",
            "coordinate-end \(pickedPath)",
            "stop \(pickedPath)",
        ], "start → coordinate { copy } → stop")
        XCTAssertEqual(harness.coordinator.requestedURLs.map(\.standardizedFileURL.path), [pickedPath],
                       "coordinated exactly once, for the picked URL")
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: picked))

        await harness.model.selectImportMode(.merge)?.value
        XCTAssertEqual(harness.words(), ["house"])
        XCTAssertEqual(harness.coordinator.requestedURLs.count, 1, "the core reads the local copy — no coordination")
        XCTAssertEqual(harness.stagedFiles(), [])
    }

    @MainActor
    func testCopyReadsFromURLCoordinatorHandsBack() async throws {
        // iCloud placeholder: the picked URL has no readable bytes; the coordinator hands back the downloaded file.
        let root = makeTemporaryDirectory(self)
        let downloaded = root.appendingPathComponent("Downloaded/dictionary.json")
        try FileManager.default.createDirectory(at: downloaded.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try DictionaryExporter.exportData(
            entries: [makeTestEntry("tree", translations: ["дерево"], createdOffset: 0)], now: mobileTestEpoch
        ).write(to: downloaded)
        let harness = try await makeHarness(coordinatorBehavior: .redirect(to: downloaded))
        let picked = harness.files.appendingPathComponent("not-downloaded.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: picked.path))
        harness.log.clear()

        harness.model.handleImportSelection(.success(picked))
        guard case .chooseMode(let staged)? = harness.model.importStage else {
            return XCTFail("expected the mode dialog; message: \(String(describing: harness.model.transferMessage?.text))")
        }
        let pickedPath = picked.standardizedFileURL.path
        let downloadedPath = downloaded.standardizedFileURL.path
        let stagedPath = staged.standardizedFileURL.path
        XCTAssertEqual(harness.log.events, [
            "start \(pickedPath)",
            "coordinate-begin \(pickedPath)",
            "copy \(downloadedPath) -> \(stagedPath)",
            "coordinate-end \(pickedPath)",
            "stop \(pickedPath)",
        ], "copy source is the URL from the coordinator; scoped access is for the picked URL")
        XCTAssertEqual(try Data(contentsOf: staged), try Data(contentsOf: downloaded))

        await harness.model.selectImportMode(.merge)?.value
        XCTAssertEqual(harness.words(), ["tree"])
        XCTAssertEqual(harness.stagedFiles(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloaded.path), "the user's file is never deleted")
    }

    @MainActor
    func testCoordinatorErrorBecomesReadFailed() async throws {
        let failure = NSError(domain: NSCocoaErrorDomain, code: 4353)   // ubiquitous file unavailable
        let harness = try await makeHarness(coordinatorBehavior: .fail(failure))
        let picked = try harness.writePickedFile([makeTestEntry("house", translations: ["дім"], createdOffset: 0)])
        harness.log.clear()

        // Directly through the stager: typed error, no copy, no leftovers, scope closed.
        let stager = harness.model.container.importStager
        XCTAssertThrowsError(try stager.stage(picked)) { error in
            XCTAssertEqual(error as? ImportError, .readFailed(FileErrorText.describe(failure)))
        }
        let pickedPath = picked.standardizedFileURL.path
        XCTAssertEqual(harness.log.events, [
            "start \(pickedPath)",
            "coordinate-begin \(pickedPath)",
            "coordinate-end \(pickedPath)",
            "stop \(pickedPath)",
        ], "accessor never ran; access still stopped")
        XCTAssertEqual(harness.stagedFiles(), [], "no partial copy in the staging directory")

        // Through the model: error alert, no mode dialog, dictionary untouched.
        harness.log.clear()
        harness.model.handleImportSelection(.success(picked))
        XCTAssertNil(harness.model.importStage)
        let message = try XCTUnwrap(harness.model.transferMessage)
        XCTAssertTrue(message.isError)
        XCTAssertEqual(message.text, ImportError.readFailed(FileErrorText.describe(failure)).userMessage)
        XCTAssertFalse(message.text.contains(harness.files.path), "no paths in the message")
        XCTAssertEqual(harness.log.events.filter { $0.hasPrefix("stop ") }.count, 1)
        XCTAssertEqual(harness.log.events.filter { $0.hasPrefix("copy ") }.count, 0)
        XCTAssertEqual(harness.stagedFiles(), [])
        XCTAssertEqual(harness.words(), [])
        XCTAssertTrue(harness.model.canTransfer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))
    }

    @MainActor
    func testCopyFailureInsideCoordinationBecomesReadFailed() async throws {
        // The coordinator succeeds but the copy inside it fails (file vanished) → the accessor error propagates.
        let harness = try await makeHarness()
        let missing = harness.files.appendingPathComponent("gone.json")
        harness.log.clear()

        let stager = harness.model.container.importStager
        XCTAssertThrowsError(try stager.stage(missing)) { error in
            guard case .readFailed? = error as? ImportError else {
                return XCTFail("expected ImportError.readFailed, got \(error)")
            }
        }
        let events = harness.log.events
        let path = missing.standardizedFileURL.path
        XCTAssertEqual(events.first, "start \(path)")
        XCTAssertEqual(events.last, "stop \(path)", "access stopped after a failed copy: \(events)")
        let copyIndex = try XCTUnwrap(events.firstIndex { $0.hasPrefix("copy ") })
        let beginIndex = try XCTUnwrap(events.firstIndex(of: "coordinate-begin \(path)"))
        let endIndex = try XCTUnwrap(events.firstIndex(of: "coordinate-end \(path)"))
        XCTAssertLessThan(beginIndex, copyIndex)
        XCTAssertLessThan(copyIndex, endIndex)
        XCTAssertEqual(harness.stagedFiles(), [])
    }

    @MainActor
    func testCoordinationWithoutScopedAccessDoesNotStop() async throws {
        let harness = try await makeHarness(accessGranted: false)
        let picked = try harness.writePickedFile([makeTestEntry("house", translations: ["дім"], createdOffset: 0)])
        harness.log.clear()

        harness.model.handleImportSelection(.success(picked))
        guard case .chooseMode? = harness.model.importStage else { return XCTFail("expected the mode dialog") }
        let events = harness.log.events
        XCTAssertEqual(events.filter { $0.hasPrefix("coordinate-begin ") }.count, 1, "still coordinated")
        XCTAssertEqual(events.filter { $0.hasPrefix("copy ") }.count, 1)
        XCTAssertEqual(events.filter { $0.hasPrefix("stop ") }.count, 0)
        harness.model.cancelImport()
        XCTAssertEqual(harness.stagedFiles(), [])
    }

    func testCoordinatorDefaults() throws {
        let directory = makeTemporaryDirectory(self)
        let stager = ImportFileStager(access: URLSecurityScopedAccess(), fileSystem: LocalFileSystem(),
                                      directory: directory)
        XCTAssertTrue(stager.coordinator is PassthroughFileReadCoordinator, "tests/Linux default: no coordination")

        #if canImport(Darwin)
        XCTAssertTrue(ImportFileStager.liveCoordinator() is LiveFileReadCoordinator)
        #else
        XCTAssertTrue(ImportFileStager.liveCoordinator() is PassthroughFileReadCoordinator)
        #endif

        // Passthrough: accessor gets the same URL; its error propagates unchanged.
        let url = directory.appendingPathComponent("x.json")
        var received: URL?
        try PassthroughFileReadCoordinator().coordinateReading(at: url) { received = $0 }
        XCTAssertEqual(received, url)
        struct Boom: Error, Equatable {}
        XCTAssertThrowsError(try PassthroughFileReadCoordinator().coordinateReading(at: url) { _ in throw Boom() }) {
            XCTAssertEqual($0 as? Boom, Boom())
        }
    }

    #if canImport(Darwin)
    func testLiveCoordinatorCopiesLocalFile() throws {
        let directory = makeTemporaryDirectory(self)
        let source = directory.appendingPathComponent("source.json")
        let bytes = Data(#"{"schemaVersion":1,"entries":[]}"#.utf8)
        try bytes.write(to: source)
        let staging = directory.appendingPathComponent("Staging", isDirectory: true)
        let stager = ImportFileStager(access: URLSecurityScopedAccess(), coordinator: LiveFileReadCoordinator(),
                                      fileSystem: LocalFileSystem(), directory: staging)

        let staged = try stager.stage(source)
        XCTAssertEqual(try Data(contentsOf: staged), bytes)
        XCTAssertEqual(staged.deletingLastPathComponent().standardizedFileURL.path, staging.standardizedFileURL.path)

        // Accessor runs synchronously; its error propagates out of the live coordinator.
        var calls = 0
        try LiveFileReadCoordinator().coordinateReading(at: source) { readable in
            calls += 1
            XCTAssertEqual(try Data(contentsOf: readable), bytes)
        }
        XCTAssertEqual(calls, 1)
        struct Boom: Error, Equatable {}
        XCTAssertThrowsError(try LiveFileReadCoordinator().coordinateReading(at: source) { _ in throw Boom() }) {
            XCTAssertEqual($0 as? Boom, Boom())
        }

        // Missing file → readFailed, nothing staged.
        XCTAssertThrowsError(try stager.stage(directory.appendingPathComponent("missing.json"))) { error in
            guard case .readFailed? = error as? ImportError else {
                return XCTFail("expected ImportError.readFailed, got \(error)")
            }
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: staging.path)
        XCTAssertEqual(leftovers, [staged.lastPathComponent])
    }
    #endif

    // MARK: - Inbox banner shows the real number of items left (I6 core change)

    /// Selected text of a combined request (`<text>…</text>` in the user message).
    private static func selection(_ request: MockURLProtocol.RecordedRequest) -> String? {
        guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let messages = body["messages"] as? [[String: Any]],
              let content = messages.first?["content"] as? String,
              let start = content.range(of: "<text>"),
              let end = content.range(of: "</text>", range: start.upperBound..<content.endIndex) else {
            return nil
        }
        return String(content[start.upperBound..<end.lowerBound])
    }

    @MainActor
    func testBannerShowsItemsLeftAfterStorageFailure() async throws {
        let root = makeTemporaryDirectory(self)
        let inboxDirectory = root.appendingPathComponent("Group/Inbox", isDirectory: true)
        // 2 saves succeed, then the disk "fails"; the first Claude request (queue run after the pass) restores it.
        let store = FailingAfterSavesStore(allowedSaves: 2)
        MockURLProtocol.setHandler { request in
            store.stopFailing()
            let word = Self.selection(request) ?? "unknown"
            return MobileClaudeFixtures.ok(MobileClaudeFixtures.combinedJSON(
                word: word, translations: ["переклад \(word)"], italian: "\(word)o", italianTranslations: ["переклад"]
            ))
        }
        let container = AppContainer(
            paths: AppPaths(applicationSupportDirectory: root.appendingPathComponent("Data", isDirectory: true)),
            settings: InMemorySettingsStore(),
            store: store,
            secrets: InMemorySecretStore(values: [.anthropicAPIKey: MobileClaudeFixtures.apiKey]),
            transport: URLSessionTransport(session: MockURLProtocol.makeSession()),
            logSink: MobileCapturingLogSink(),
            inboxDirectory: inboxDirectory
        )
        let model = MobileAppModel(container: container)
        for (index, text) in ["brisk", "wane", "thrive", "quaint", "ephemeral"].enumerated() {
            let outcome = ShareInboxWriter.save(
                ShareTextExtractor.extract(from: [.plainText(text)]),
                directory: inboxDirectory,
                now: Date().addingTimeInterval(TimeInterval(index) / 10)
            )
            XCTAssertEqual(outcome, .saved(truncated: false))
        }

        await model.becameActive()

        let report = try XCTUnwrap(model.inboxReport)
        XCTAssertEqual(report, InboxIngestReport(queued: 2, duplicates: 0, rejected: 0, failed: 3))
        XCTAssertEqual(MobileAppModel.inboxBannerLines(for: report, language: .en), [
            "Added for translation: 2",
            "Not saved yet, will be retried next time you open the app: 3",
        ])
        XCTAssertEqual(MobileAppModel.inboxBannerLines(for: report, language: .uk).last,
                       "Ще не збережено, повторна спроба під час наступного відкриття: 3")
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: inboxDirectory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        XCTAssertEqual(left.count, 3, "banner N == files actually left in the inbox")
        XCTAssertEqual(Set(model.entries.map(\.word)), ["brisk", "wane"])

        // Next activation drains the rest; banner now shows only the newly queued words.
        await model.becameActive()
        XCTAssertEqual(model.inboxReport, InboxIngestReport(queued: 3))
        XCTAssertEqual(Set(model.entries.map(\.word)), ["brisk", "wane", "thrive", "quaint", "ephemeral"])
        XCTAssertEqual(MockURLProtocol.requestCount, 5)
    }
}

// MARK: - Fakes

/// Fake `FileReadCoordinating`: logs `coordinate-begin`/`coordinate-end` into the shared transfer log (same log as
/// `RecordingScopedAccess`/`RecordingFileSystem`), and either passes the URL through, hands back another URL
/// (downloaded iCloud file), or fails without calling the accessor.
final class RecordingReadCoordinator: FileReadCoordinating, @unchecked Sendable {
    enum Behavior {
        case passthrough
        case redirect(to: URL)
        case fail(Error)
    }

    private let log: TransferEventLog
    private let behavior: Behavior
    private let lock = NSLock()
    private var requested: [URL] = []

    init(log: TransferEventLog, behavior: Behavior) {
        self.log = log
        self.behavior = behavior
    }

    var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    func coordinateReading(at url: URL, _ accessor: (URL) throws -> Void) throws {
        lock.lock()
        requested.append(url)
        lock.unlock()
        let path = url.standardizedFileURL.path
        log.append("coordinate-begin \(path)")
        defer { log.append("coordinate-end \(path)") }
        switch behavior {
        case .passthrough:
            try accessor(url)
        case .redirect(let readable):
            try accessor(readable)
        case .fail(let error):
            throw error
        }
    }
}

/// In-memory `DictionaryStoring`: the first `allowedSaves` saves succeed, later ones throw until `stopFailing()`.
final class FailingAfterSavesStore: DictionaryStoring, @unchecked Sendable {
    struct DiskFull: Error {}

    let fileURL = URL(fileURLWithPath: "/dev/null/vocab-failing/dictionary.json")
    private let lock = NSLock()
    private var file = DictionaryFile(entries: [])
    private var remaining: Int
    private var failing = true

    init(allowedSaves: Int) {
        self.remaining = allowedSaves
    }

    func stopFailing() {
        lock.lock(); defer { lock.unlock() }
        failing = false
    }

    func load() throws -> LoadResult {
        lock.lock(); defer { lock.unlock() }
        return LoadResult(file: file)
    }

    func save(_ newFile: DictionaryFile) throws {
        lock.lock(); defer { lock.unlock() }
        if failing {
            if remaining == 0 {
                throw DiskFull()
            }
            remaining -= 1
        }
        file = newFile
    }
}
