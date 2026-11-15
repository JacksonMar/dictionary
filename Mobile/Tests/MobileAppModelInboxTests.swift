// I3.4 (IOS_PLAN §4, DI7, DI9, DI18): inbox ingest on `scenePhase == .active` — banner, single-flight across repeated
// activations, graceful "no App Group". Real stack: `AppContainer(paths:…inboxDirectory:)` → `InboxIngestor` →
// queue → `ClaudeLookupService` → `URLSessionTransport` with `MockURLProtocol` (token check: 1 request per new
// shared word, 0 per duplicate). Words are put into the inbox by the extension's own `ShareInboxWriter`.
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

final class MobileAppModelInboxTests: XCTestCase {
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

    // MARK: - Helpers

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

    /// Valid combined answer for whatever word was asked.
    private static func echoReply(_ request: MockURLProtocol.RecordedRequest) -> MockURLProtocol.Reply {
        let word = selection(request) ?? "unknown"
        return MobileClaudeFixtures.ok(MobileClaudeFixtures.combinedJSON(
            word: word, translations: ["переклад \(word)"], italian: "\(word)o", italianTranslations: ["переклад"]
        ))
    }

    private static var requestedWords: [String] {
        MockURLProtocol.requests.compactMap { selection($0) }
    }

    @MainActor
    private struct Harness {
        let model: MobileAppModel
        let inboxDirectory: URL?
        let sink: MobileCapturingLogSink

        var runner: NoopBackgroundTaskRunner? {
            model.container.backgroundTasks as? NoopBackgroundTaskRunner
        }

        /// What the Share extension does for each word.
        func share(_ texts: [String], file: StaticString = #filePath, line: UInt = #line) {
            for (index, text) in texts.enumerated() {
                let outcome = ShareInboxWriter.save(
                    ShareTextExtractor.extract(from: [.plainText(text)]),
                    directory: inboxDirectory,
                    now: Date().addingTimeInterval(TimeInterval(index) / 10)
                )
                XCTAssertEqual(outcome, .saved(truncated: false), file: file, line: line)
            }
        }

        func inboxFiles() -> [String] {
            guard let inboxDirectory else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(atPath: inboxDirectory.path)) ?? [])
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
        }
    }

    @MainActor
    private func makeHarness(entries: [Entry] = [], withInbox: Bool = true) throws -> Harness {
        let directory = makeTemporaryDirectory(self)
        let data = directory.appendingPathComponent("Data", isDirectory: true)
        if !entries.isEmpty {
            try writeDictionary(entries, to: data)
        }
        // Stand-in for `<App Group container>/Inbox` (InboxLocation.live() is nil in tests).
        let inboxDirectory = withInbox ? directory.appendingPathComponent("Group/Inbox", isDirectory: true) : nil
        let sink = MobileCapturingLogSink()
        let container = AppContainer(
            paths: AppPaths(applicationSupportDirectory: data),
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(values: [.anthropicAPIKey: MobileClaudeFixtures.apiKey]),
            transport: URLSessionTransport(session: MockURLProtocol.makeSession()),
            logSink: sink,
            inboxDirectory: inboxDirectory
        )
        return Harness(model: MobileAppModel(container: container), inboxDirectory: inboxDirectory, sink: sink)
    }

    // MARK: - I3.4 required

    @MainActor
    func testActivePhaseIngestsAndShowsBanner() async throws {
        let harness = try makeHarness()
        MockURLProtocol.setHandler(Self.echoReply)
        // Extension wrote words while the app was not running.
        harness.share(["serendipity", "ubiquitous", "ephemeral"])
        XCTAssertEqual(harness.inboxFiles().count, 3)
        XCTAssertTrue(harness.model.isInboxAvailable)
        XCTAssertNil(harness.model.inboxReport)

        await harness.model.becameActive()

        let model = harness.model
        XCTAssertEqual(model.inboxReport, InboxIngestReport(queued: 3, duplicates: 0, rejected: 0, failed: 0))
        XCTAssertEqual(MobileAppModel.inboxBannerLines(for: try XCTUnwrap(model.inboxReport), language: .en),
                       ["Added for translation: 3"])
        XCTAssertEqual(MockURLProtocol.requestCount, 3, "3 shared words → 3 requests total")
        XCTAssertEqual(Set(Self.requestedWords), ["serendipity", "ubiquitous", "ephemeral"])
        XCTAssertEqual(Set(model.entries.map(\.word)), ["serendipity", "ubiquitous", "ephemeral"],
                       "model refreshed right after the await")
        XCTAssertTrue(model.entries.allSatisfy { $0.status == .ready })
        XCTAssertTrue(harness.inboxFiles().isEmpty, "inbox drained")

        // Order (§4): ingest (trigger=inbox) runs before processAll(.foreground).
        let lines = harness.sink.lines
        let inboxRun = try XCTUnwrap(lines.firstIndex(of: QueueLog.started(.inbox)), "\(lines)")
        let foregroundRun = try XCTUnwrap(lines.firstIndex(of: QueueLog.started(.foreground)), "\(lines)")
        XCTAssertLessThan(inboxRun, foregroundRun)
        XCTAssertEqual(lines.filter { $0 == QueueLog.started(.inbox) }.count, 1)
        XCTAssertTrue(lines.contains(InboxLog.finished(InboxIngestReport(queued: 3))))
        XCTAssertFalse(lines.joined().contains("serendipity"), "logs carry counters, never words")

        // Wrapped in a background task that ended (DI18).
        let runner = try XCTUnwrap(harness.runner)
        XCTAssertEqual(runner.startedNames.filter { $0 == "VocabInboxIngest" }.count, 1)
        XCTAssertTrue(runner.activeTokens.isEmpty)

        // Dismissing hides the banner; an empty pass does not bring it back.
        model.dismissInboxReport()
        XCTAssertNil(model.inboxReport)
        await model.becameActive()
        XCTAssertNil(model.inboxReport)
        XCTAssertEqual(MockURLProtocol.requestCount, 3)

        // Ukrainian banner text.
        let uk = MobileAppModel.inboxBannerLines(for: InboxIngestReport(queued: 1, duplicates: 2), language: .uk)
        XCTAssertEqual(uk, ["Додано на переклад: 1", "Уже є в словнику: 2"])
    }

    @MainActor
    func testRepeatedActiveDoesNotDuplicate() async throws {
        let harness = try makeHarness()
        MockURLProtocol.setHandler(Self.echoReply)
        MockURLProtocol.setDelay(0.05)   // keep requests in flight while further activations arrive
        harness.share(["brisk", "wane"])
        let model = harness.model

        // Control Center opened/closed several times: overlapping `.active` callbacks.
        async let first: Void = model.becameActive()
        async let second: Void = model.becameActive()
        async let third: Void = model.becameActive()
        _ = await (first, second, third)

        XCTAssertEqual(MockURLProtocol.requestCount, 2, "one request per new word: \(Self.requestedWords)")
        XCTAssertEqual(Self.requestedWords.sorted(), ["brisk", "wane"])
        XCTAssertEqual(model.entries.count, 2, "each word added once")
        XCTAssertEqual(model.inboxReport, InboxIngestReport(queued: 2), "banner not doubled")
        XCTAssertTrue(harness.inboxFiles().isEmpty)

        // A further activation with an empty inbox: nothing changes, banner stays as it was.
        await model.becameActive()
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        XCTAssertEqual(model.inboxReport, InboxIngestReport(queued: 2))
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertTrue(harness.runner?.activeTokens.isEmpty ?? false)
    }

    @MainActor
    func testNoAppGroupDisablesInboxGracefully() async throws {
        let harness = try makeHarness(entries: [makeTestEntry("run", translations: ["бігти"], createdOffset: 0)],
                                      withInbox: false)
        let model = harness.model
        XCTAssertFalse(model.isInboxAvailable)
        XCTAssertNil(model.container.inbox)
        XCTAssertNil(model.container.inboxIngestor)

        await model.becameActive()

        XCTAssertTrue(model.isLoaded)
        XCTAssertNil(model.loadError)
        XCTAssertNil(model.operationError)
        XCTAssertNil(model.inboxReport)
        XCTAssertEqual(model.entries.map(\.word), ["run"])
        let report = await model.ingestInbox()
        XCTAssertNil(report, "no inbox → ingest is a no-op")
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertFalse(harness.sink.lines.contains(QueueLog.started(.inbox)))
        XCTAssertFalse(harness.runner?.startedNames.contains("VocabInboxIngest") ?? true)

        // Location resolution: missing / unsubstituted / empty group id, or no container → nil.
        XCTAssertNil(InboxLocation.groupID(infoDictionary: nil))
        XCTAssertNil(InboxLocation.groupID(infoDictionary: [:]))
        XCTAssertNil(InboxLocation.groupID(infoDictionary: [InboxLocation.infoPlistKey: "$(VOCAB_APP_GROUP)"]))
        XCTAssertNil(InboxLocation.groupID(infoDictionary: [InboxLocation.infoPlistKey: "  "]))
        XCTAssertNil(InboxLocation.groupID(infoDictionary: [InboxLocation.infoPlistKey: 42]))
        XCTAssertEqual(InboxLocation.groupID(infoDictionary: [InboxLocation.infoPlistKey: " group.com.example.vocab "]),
                       "group.com.example.vocab")
        XCTAssertNil(InboxLocation.directory(groupID: nil) { _ in URL(fileURLWithPath: "/tmp") })
        XCTAssertNil(InboxLocation.directory(groupID: "group.x") { _ in nil })
        var askedFor: String?
        let resolved = InboxLocation.directory(groupID: "group.x") { identifier in
            askedFor = identifier
            return URL(fileURLWithPath: "/containers/group.x", isDirectory: true)
        }
        XCTAssertEqual(askedFor, "group.x")
        XCTAssertEqual(resolved?.path, "/containers/group.x/Inbox")

        // Hosted tests never touch the real App Group inbox.
        let live = AppContainer.makeLive(environment: [AppContainer.xcTestEnvironmentKey: "/tmp/x.xctestconfiguration"])
        XCTAssertNil(live.inboxIngestor)
    }

    // MARK: - Token check / banner content

    @MainActor
    func testSharedDuplicateMakesNoRequest() async throws {
        let existing = makeTestEntry("run", translations: ["бігти"], createdOffset: 0)
        let harness = try makeHarness(entries: [existing])
        MockURLProtocol.setHandler(Self.echoReply)
        harness.share(["run"])

        await harness.model.becameActive()

        XCTAssertEqual(harness.model.inboxReport, InboxIngestReport(duplicates: 1))
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "shared duplicate → 0 requests")
        XCTAssertEqual(harness.model.entries, [existing], "existing entry untouched")
        XCTAssertTrue(harness.inboxFiles().isEmpty)
        XCTAssertFalse(harness.sink.lines.contains(QueueLog.started(.inbox)), "no queue run for duplicates only")

        // Duplicate + new word → exactly 1 request, two banner lines.
        harness.share(["run", "thrive"])
        await harness.model.becameActive()
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(Self.requestedWords, ["thrive"])
        let report = try XCTUnwrap(harness.model.inboxReport)
        XCTAssertEqual(report, InboxIngestReport(queued: 1, duplicates: 1))
        XCTAssertEqual(MobileAppModel.inboxBannerLines(for: report, language: .en),
                       ["Added for translation: 1", "Already in the dictionary: 1"])
    }

    @MainActor
    func testRejectedSharedTextCountedWithoutRequest() async throws {
        let harness = try makeHarness()
        MockURLProtocol.setHandler(Self.echoReply)
        harness.share(["one two three four five six seven eight nine"])

        await harness.model.becameActive()

        XCTAssertEqual(harness.model.inboxReport, InboxIngestReport(rejected: 1))
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        XCTAssertTrue(harness.model.entries.isEmpty)
        XCTAssertTrue(harness.inboxFiles().isEmpty)
    }

    @MainActor
    func testBannerLinesShowOnlyNonZeroCounts() async {
        XCTAssertEqual(MobileAppModel.inboxBannerLines(for: InboxIngestReport(), language: .en), [])
        XCTAssertEqual(
            MobileAppModel.inboxBannerLines(for: InboxIngestReport(queued: 2, duplicates: 1, rejected: 3, failed: 4),
                                            language: .en),
            [
                "Added for translation: 2",
                "Already in the dictionary: 1",
                "Not added (empty, longer than 120 characters or more than 8 words): 3",
                "Not saved yet, will be retried next time you open the app: 4",
            ]
        )
        XCTAssertEqual(MobileAppModel.inboxBannerLines(for: InboxIngestReport(failed: 1), language: .en).count, 1)
        for line in MobileAppModel.inboxBannerLines(for: InboxIngestReport(queued: 1, duplicates: 1, rejected: 1,
                                                                            failed: 1), language: .uk) {
            XCTAssertFalse(line.contains("{count}"))
            XCTAssertTrue(line.hasSuffix("1"))
        }
    }
}
