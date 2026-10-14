import Foundation
import XCTest
@testable import VocabCore

/// §9 — AddWordUseCase (M2): валідація → збереження pending до запиту → обробка → outcome.
/// Сценарії Services / тексти сповіщень (`ServiceRequestHandlerTests`, `NotificationTextTests`,
/// `testAddDuringProcessAllReportsOutcome`) — етап M3.
final class AddWordUseCaseTests: XCTestCase {
    private var harness: QueueHarness?

    override func tearDown() {
        harness?.remove()
        harness = nil
        super.tearDown()
    }

    private func make(
        _ script: [Result<LookupResult, ClaudeError>],
        settings: InMemorySettingsStore = InMemorySettingsStore()
    ) async throws -> (QueueHarness, AddWordUseCase) {
        let h = try await QueueHarness.make(script)
        harness = h
        let useCase = AddWordUseCase(
            repository: h.repository,
            processor: h.queue,
            settings: settings,
            registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly])
        )
        return (h, useCase)
    }

    func testNewWordAddedReady() async throws {
        let (h, useCase) = try await make([.success(ClaudeFixtures.expectedRunResult)])

        let outcome = await useCase.execute(rawText: "  Run, ")

        guard case .added(let entry) = outcome else { return XCTFail("expected added, got \(outcome)") }
        XCTAssertEqual(entry.status, .ready)
        XCTAssertEqual(h.lookup.texts, ["Run"])
        XCTAssertEqual(try h.fixture.store.load().file.entries.map(\.status), [.ready])
    }

    func testOfflineQueuedAndPersistedAsPending() async throws {
        let (h, useCase) = try await make([.failure(.offline)])

        let outcome = await useCase.execute(rawText: "run")

        guard case .queued(let entry, .offline?) = outcome else { return XCTFail("expected queued, got \(outcome)") }
        XCTAssertEqual(entry.status, .pending)
        XCTAssertEqual(try h.fixture.store.load().file.entries.map(\.status), [.pending])
    }

    func testUnauthorizedFailed() async throws {
        let (_, useCase) = try await make([.failure(.unauthorized)])

        let outcome = await useCase.execute(rawText: "run")

        guard case .failed(let entry, .unauthorized) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertEqual(entry.status, .failed)
        XCTAssertEqual(entry.lastError, ClaudeError.unauthorized.userMessage)
    }

    func testDuplicateNoLookup() async throws {
        let (h, useCase) = try await make([.success(ClaudeFixtures.expectedRunResult)])
        let existing = try await h.repository.add(TestFixtures.draft(word: "run"))

        let outcome = await useCase.execute(rawText: "RUN")

        XCTAssertEqual(outcome, .duplicate(existing))
        XCTAssertEqual(h.lookup.callCount, 0)
    }

    func testRejectedCreatesNoEntry() async throws {
        let (h, useCase) = try await make([.success(ClaudeFixtures.expectedRunResult)])

        let awaited1 = await useCase.execute(rawText: nil)
        XCTAssertEqual(awaited1, .rejected(.empty))
        let awaited2 = await useCase.execute(rawText: "   ")
        XCTAssertEqual(awaited2, .rejected(.empty))
        let awaited3 = await useCase.execute(rawText: String(repeating: "a", count: 121))
        XCTAssertEqual(awaited3, .rejected(.tooLong(max: 120)))
        let awaited4 = await useCase.execute(rawText: "a b c d e f g h i")
        XCTAssertEqual(awaited4, .rejected(.tooManyWords(max: 8)))
        let awaited5 = await useCase.execute(rawText: "1234")
        XCTAssertEqual(awaited5, .rejected(.noLetters))

        let awaited6 = await h.repository.allEntries()
        XCTAssertEqual(awaited6, [])
        XCTAssertEqual(h.lookup.callCount, 0)
    }

    func testUnknownConfiguredPairFallsBackToDefault() async throws {
        let (h, useCase) = try await make([.success(ClaudeFixtures.expectedRunResult)],
                                          settings: InMemorySettingsStore(languagePairID: "xx-yy"))

        _ = await useCase.execute(rawText: "run")

        let awaited7 = await h.repository.allEntries().map(\.languagePair)
        XCTAssertEqual(awaited7, ["en-uk"])
    }
}
