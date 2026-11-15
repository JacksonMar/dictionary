// I1a → I1b carry-overs (PROGRESS.md «Перенесено в I1b»; IOS_PLAN §4, DI18):
// - every concurrent `ensureLoaded()` caller sees `isLoaded`/`loadError` right after its own await;
// - background tasks are balanced (`NoopBackgroundTaskRunner.activeTokens` empty after every operation);
// - `becameActive()` runs `processAll(.foreground)` with no requests for ready entries.
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

final class MobileCarryOverTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    private func makeContainer(store: CountingDictionaryStore) -> AppContainer {
        AppContainer(
            paths: AppPaths(applicationSupportDirectory: makeTemporaryDirectory(self)),
            settings: InMemorySettingsStore(),
            store: store
        )
    }

    // MARK: - ensureLoaded: every caller sees the outcome

    @MainActor
    func testEveryConcurrentEnsureLoadedCallerSeesIsLoaded() async {
        let entry = makeTestEntry("house", translations: ["будинок"], createdOffset: 0)
        let store = CountingDictionaryStore(entries: [entry], loadDelay: 0.2)
        let container = makeContainer(store: store)

        let callers = 10
        // Each child task runs on the main actor and reads `isLoaded` synchronously right after its await.
        let seen = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<callers {
                group.addTask { @MainActor in
                    _ = await container.ensureLoaded()
                    return container.isLoaded && container.loadError == nil
                }
            }
            var collected: [Bool] = []
            for await value in group {
                collected.append(value)
            }
            return collected
        }

        XCTAssertEqual(seen.count, callers)
        XCTAssertTrue(seen.allSatisfy { $0 }, "a caller saw isLoaded == false after its await: \(seen)")
        XCTAssertEqual(store.loadCount, 1)
    }

    @MainActor
    func testEveryConcurrentEnsureLoadedCallerSeesLoadError() async {
        let store = CountingDictionaryStore(loadDelay: 0.2, failure: StorageError.unsupportedSchemaVersion(9))
        let container = makeContainer(store: store)

        let seen = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<8 {
                group.addTask { @MainActor in
                    _ = await container.ensureLoaded()
                    return !container.isLoaded && container.loadError != nil
                }
            }
            var collected: [Bool] = []
            for await value in group {
                collected.append(value)
            }
            return collected
        }

        XCTAssertEqual(seen.count, 8)
        XCTAssertTrue(seen.allSatisfy { $0 }, "a caller did not see loadError after its await: \(seen)")
        XCTAssertEqual(store.loadCount, 1)
    }

    @MainActor
    func testConcurrentModelStartsAllSeeLoadedModel() async {
        let entry = makeTestEntry("house", translations: ["будинок"], createdOffset: 0)
        let store = CountingDictionaryStore(entries: [entry], loadDelay: 0.2)
        let model = MobileAppModel(container: makeContainer(store: store))

        // (isLoaded, entries loaded, empty state shown) as seen by each caller right after `start()` returns.
        let seen = await withTaskGroup(of: (Bool, Bool, Bool).self) { group -> [(Bool, Bool, Bool)] in
            for _ in 0..<5 {
                group.addTask { @MainActor in
                    await model.start()
                    return (model.isLoaded, model.entries.map(\.id) == [entry.id], model.isDictionaryEmpty)
                }
            }
            var collected: [(Bool, Bool, Bool)] = []
            for await value in group {
                collected.append(value)
            }
            return collected
        }

        XCTAssertEqual(seen.count, 5)
        XCTAssertTrue(seen.allSatisfy { $0.0 }, "a caller saw isLoaded == false: \(seen.map(\.0))")
        // `isLoaded == true` must imply the entries are there: otherwise `isDictionaryEmpty` is true for a non-empty
        // dictionary (the empty-state overlay flashes) and the caller works with an empty `entries`.
        XCTAssertTrue(seen.allSatisfy { $0.1 }, "a caller saw isLoaded == true with entries not loaded: \(seen.map(\.1))")
        XCTAssertFalse(seen.contains { $0.2 }, "a caller saw the empty state for a non-empty dictionary: \(seen.map(\.2))")
        XCTAssertEqual(store.loadCount, 1)
        XCTAssertNotNil(model.changesTask)
    }

    // MARK: - becameActive → processAll(.foreground)

    @MainActor
    func testBecameActiveProcessesForegroundWithoutRequestsForReadyEntries() async throws {
        let directory = makeTemporaryDirectory(self)
        let ready = makeTestEntry("house", translations: ["будинок"], createdOffset: 0)
        let pending = makeTestEntry("tree", status: .pending, createdOffset: 5)
        try writeDictionary([ready, pending], to: directory)
        let sink = MobileCapturingLogSink()
        let container = AppContainer(
            paths: AppPaths(applicationSupportDirectory: directory),
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(values: [.anthropicAPIKey: MobileClaudeFixtures.apiKey]),
            transport: MockURLProtocol.makeTransport(),
            logSink: sink
        )
        let model = MobileAppModel(container: container)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.combinedJSON(
            word: "tree", translations: ["дерево"], italian: "albero", italianTranslations: ["дерево"]
        ))])

        await model.becameActive()

        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "only the pending entry is sent; ready → 0 requests")
        XCTAssertEqual(model.entry(id: pending.id)?.status, .ready)
        XCTAssertEqual(model.entry(id: ready.id)?.translations, ["будинок"])
        XCTAssertTrue(sink.lines.contains { $0.contains("Queue run started: trigger=foreground") }, sink.lines.joined(separator: "\n"))

        // Repeated activations (Control Center etc.): everything ready → 0 more requests.
        await model.becameActive()
        await model.becameActive()
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(sink.lines.filter { $0.contains("Queue run started: trigger=foreground") }.count, 3)

        // No backfill in EN mode during activation.
        XCTAssertFalse(sink.lines.contains { $0.contains("Variant backfill") })

        let runner = try XCTUnwrap(container.backgroundTasks as? NoopBackgroundTaskRunner)
        XCTAssertTrue(runner.activeTokens.isEmpty)
        XCTAssertEqual(runner.startedNames.filter { $0 == "VocabProcessPending" }.count, 3)
    }

    @MainActor
    func testBecameActiveWithAllReadyMakesNoRequest() async throws {
        let directory = makeTemporaryDirectory(self)
        try writeDictionary([
            makeTestEntry("house", translations: ["будинок"], createdOffset: 0),
            makeTestEntry("tree", translations: ["дерево"], createdOffset: 5),
        ], to: directory)
        let container = AppContainer(
            baseDirectory: directory,
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(values: [.anthropicAPIKey: MobileClaudeFixtures.apiKey]),
            transport: MockURLProtocol.makeTransport()
        )
        let model = MobileAppModel(container: container)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])

        await model.becameActive()

        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    @MainActor
    func testBecameActiveAfterLoadFailureDoesNothing() async throws {
        let directory = makeTemporaryDirectory(self)
        try writeRawDictionary(#"{"schemaVersion": 99, "entries": []}"#, to: directory)
        let container = AppContainer(
            baseDirectory: directory,
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(values: [.anthropicAPIKey: MobileClaudeFixtures.apiKey]),
            transport: MockURLProtocol.makeTransport()
        )
        let model = MobileAppModel(container: container)

        await model.becameActive()

        XCTAssertFalse(model.isLoaded)
        XCTAssertNotNil(model.loadError)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    // MARK: - Background tasks balanced

    @MainActor
    func testBackgroundTasksBalancedAfterAllOperations() async throws {
        let directory = makeTemporaryDirectory(self)
        let failed = makeTestEntry("house", status: .failed, createdOffset: 0)
        let pending = makeTestEntry("tree", status: .pending, createdOffset: 5)
        let ready = makeTestEntry("apple", translations: ["яблуко"], createdOffset: 10)
        try writeDictionary([failed, pending, ready], to: directory)
        let container = AppContainer(
            baseDirectory: directory,
            settings: InMemorySettingsStore(),
            secrets: InMemorySecretStore(values: [.anthropicAPIKey: MobileClaudeFixtures.apiKey]),
            transport: MockURLProtocol.makeTransport()
        )
        let runner = try XCTUnwrap(container.backgroundTasks as? NoopBackgroundTaskRunner)
        let model = MobileAppModel(container: container)
        await model.start()
        // Every request fails with 500 → entries stay pending; keeps the test independent of the reply shape.
        MockURLProtocol.setReplies([MobileClaudeFixtures.http(500)])

        _ = await model.addViaClaude("river")
        XCTAssertTrue(runner.activeTokens.isEmpty, "after addViaClaude")
        _ = await model.retry(id: failed.id)
        XCTAssertTrue(runner.activeTokens.isEmpty, "after retry")
        await model.retryAll()
        XCTAssertTrue(runner.activeTokens.isEmpty, "after retryAll")
        XCTAssertFalse(model.isRetryingAll)
        await model.processPending(trigger: .foreground)
        XCTAssertTrue(runner.activeTokens.isEmpty, "after processPending")
        _ = await model.refreshVariant(id: ready.id, languageID: "it")
        XCTAssertTrue(runner.activeTokens.isEmpty, "after refreshVariant")
        let task = model.setDisplayLanguage("it")
        await task?.value
        XCTAssertTrue(runner.activeTokens.isEmpty, "after backfill")
        await model.becameActive()
        XCTAssertTrue(runner.activeTokens.isEmpty, "after becameActive")

        for name in ["VocabAddWord", "VocabRetry", "VocabRetryAll", "VocabProcessPending", "VocabVariantRefresh"] {
            XCTAssertTrue(runner.startedNames.contains(name), "\(name) not started: \(runner.startedNames)")
        }
        XCTAssertTrue(model.retryingIDs.isEmpty)
        XCTAssertFalse(model.isBackfilling)
    }

    // MARK: - Runner itself

    @MainActor
    func testNoopRunnerBalancesTokens() async {
        let runner = NoopBackgroundTaskRunner()
        let first = runner.beginTask(named: "a")
        let second = runner.beginTask(named: "b")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(runner.activeTokens, [first, second])
        runner.endTask(first)
        runner.endTask(first)
        XCTAssertEqual(runner.activeTokens, [second])
        let value = await runner.run(named: "c") { () async -> Int in 42 }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(runner.activeTokens, [second])
        runner.endTask(second)
        XCTAssertTrue(runner.activeTokens.isEmpty)
        XCTAssertEqual(runner.startedNames, ["a", "b", "c"])
    }
}
