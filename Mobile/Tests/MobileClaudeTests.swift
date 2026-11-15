// I1b.2 (IOS_PLAN §7, §8): «Add with Claude» = exactly 1 combined request (EN + IT); a duplicate by any dedup key
// = 0 requests. Real stack: `AppContainer(baseDirectory:settings:secrets:transport:)` →
// `URLSessionTransport(session:)` with `MockURLProtocol` → `ClaudeLookupService` → queue → `AddWordUseCase`.
import Foundation
import XCTest
import VocabCore
@testable import VocabMobile

final class MobileClaudeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    private func makeModel(entries: [Entry] = [], directory: URL, withKey: Bool = true) async throws -> MobileAppModel {
        if !entries.isEmpty {
            try writeDictionary(entries, to: directory)
        }
        let secrets = InMemorySecretStore(values: withKey ? [.anthropicAPIKey: MobileClaudeFixtures.apiKey] : [:])
        let container = AppContainer(
            baseDirectory: directory,
            settings: InMemorySettingsStore(),
            secrets: secrets,
            transport: URLSessionTransport(session: MockURLProtocol.makeSession())
        )
        let model = MobileAppModel(container: container)
        await model.start()
        XCTAssertTrue(model.isLoaded)
        return model
    }

    private func entriesOnDisk(_ directory: URL) throws -> [Entry] {
        let data = try Data(contentsOf: AppPaths(applicationSupportDirectory: directory).dictionaryURL)
        return try JSONCoding.makeDecoder().decode(DictionaryFile.self, from: data).entries
    }

    // MARK: - I1b.2 required

    @MainActor
    func testAddViaClaudeMakesOneRequest() async throws {
        let directory = makeTemporaryDirectory(self)
        let model = try await makeModel(directory: directory)
        XCTAssertTrue(model.hasAPIKey)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])

        let outcome = await model.addViaClaude("  house ")

        guard case .added(let entry) = outcome else { return XCTFail("expected .added, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "new word → exactly one combined request")
        XCTAssertNil(model.operationError)
        XCTAssertEqual(entry.word, "house")
        XCTAssertEqual(entry.status, .ready)
        XCTAssertEqual(entry.translations, ["будинок", "дім"])
        XCTAssertEqual(entry.readyVariant("it")?.word, "casa", "the same request fills the Italian version")
        XCTAssertEqual(model.entry(id: entry.id)?.status, .ready, "model refreshed right after the await")

        // The request is a Messages API call carrying the key in the header (never in the URL/body).
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "x-api-key"), MobileClaudeFixtures.apiKey)
        XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains(MobileClaudeFixtures.apiKey))
        XCTAssertTrue(String(decoding: request.body, as: UTF8.self).contains("house"))

        // Persisted.
        let onDisk = try XCTUnwrap(try entriesOnDisk(directory).first { $0.id == entry.id })
        XCTAssertEqual(onDisk.status, .ready)
        XCTAssertEqual(onDisk.variants?["it"]?.status, .ready)

        // Switching to IT afterwards → nothing to backfill, 0 requests (§8).
        let task = model.setDisplayLanguage("it")
        await task?.value
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        // Background task wrapped the network work and ended (DI18).
        let runner = try XCTUnwrap(model.container.backgroundTasks as? NoopBackgroundTaskRunner)
        XCTAssertTrue(runner.startedNames.contains("VocabAddWord"))
        XCTAssertTrue(runner.activeTokens.isEmpty)
    }

    @MainActor
    func testDuplicateMakesNoRequest() async throws {
        let directory = makeTemporaryDirectory(self)
        let house = makeTestEntry(
            "house",
            translations: ["будинок"],
            createdOffset: 0,
            variants: [
                "it": EntryVariant(
                    word: "casa",
                    translations: ["дім"],
                    status: .ready,
                    sourceKey: TextNormalizer.key("house")
                ),
            ]
        )
        let pending = makeTestEntry("tree", status: .pending, createdOffset: 5)
        let model = try await makeModel(entries: [house, pending], directory: directory)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])

        // Same word in another case, the Italian rendering, and a pending entry — all duplicates, 0 requests.
        for text in ["House", "  HOUSE  ", "casa", "Casa", "tree"] {
            let outcome = await model.addViaClaude(text)
            guard case .duplicate(let existing) = outcome else {
                XCTFail("\(text): expected .duplicate, got \(outcome)")
                continue
            }
            XCTAssertTrue([house.id, pending.id].contains(existing.id), text)
            XCTAssertEqual(model.operationError, RepositoryError.duplicate(existing).userMessage, text)
            XCTAssertEqual(model.consumeOperationError(), RepositoryError.duplicate(existing).userMessage)
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "duplicates must never reach Claude")
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(try entriesOnDisk(directory).count, 2)

        // In the IT display mode too.
        let switchTask = model.setDisplayLanguage("it")
        await switchTask?.value
        let base = MockURLProtocol.requestCount
        let italian = await model.addViaClaude("casa")
        if case .duplicate = italian {} else { XCTFail("expected .duplicate, got \(italian)") }
        XCTAssertEqual(MockURLProtocol.requestCount, base)

        // Rejected input never reaches Claude either.
        let rejected = await model.addViaClaude("   ")
        if case .rejected(.empty) = rejected {} else { XCTFail("expected .rejected(.empty), got \(rejected)") }
        XCTAssertEqual(model.operationError, L10n.text(.inputEnterWord))
        XCTAssertEqual(MockURLProtocol.requestCount, base)

        let runner = try XCTUnwrap(model.container.backgroundTasks as? NoopBackgroundTaskRunner)
        XCTAssertTrue(runner.activeTokens.isEmpty)
    }

    // MARK: - Extra

    @MainActor
    func testAddWithoutKeyQueuesWithoutRequestAndKeySaveProcessesOnce() async throws {
        let directory = makeTemporaryDirectory(self)
        let model = try await makeModel(directory: directory, withKey: false)
        XCTAssertFalse(model.hasAPIKey)
        MockURLProtocol.setReplies([MobileClaudeFixtures.ok(MobileClaudeFixtures.houseJSON)])

        let outcome = await model.addViaClaude("house")

        guard case .queued(let entry, _) = outcome else { return XCTFail("expected .queued, got \(outcome)") }
        XCTAssertEqual(entry.status, .pending, "saved before any request (D14)")
        XCTAssertEqual(MockURLProtocol.requestCount, 0, "no key → no request")
        XCTAssertNil(model.operationError)

        // Saving the key processes waiting entries: exactly one request.
        XCTAssertTrue(model.saveAPIKey("  \(MobileClaudeFixtures.apiKey)  "))
        XCTAssertTrue(model.hasAPIKey)
        await model.settingsProcessingTask?.value
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(model.entry(id: entry.id)?.status, .ready)
        XCTAssertEqual(try model.container.secrets.readSecret(for: .anthropicAPIKey), MobileClaudeFixtures.apiKey,
                       "key stored trimmed")
    }

    @MainActor
    func testUnauthorizedAddFailsWithOneRequestAndMessage() async throws {
        let directory = makeTemporaryDirectory(self)
        let model = try await makeModel(directory: directory)
        MockURLProtocol.setReplies([MobileClaudeFixtures.http(401)])

        let outcome = await model.addViaClaude("river")

        guard case .failed(let entry, _) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertEqual(MockURLProtocol.requestCount, 1, "401 → failed immediately, no retries (D-rules)")
        XCTAssertEqual(model.entry(id: entry.id)?.status, .failed)
        XCTAssertNotNil(model.operationError)
        XCTAssertFalse(model.operationError?.contains(MobileClaudeFixtures.apiKey) ?? false)
    }
}
