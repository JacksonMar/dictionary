import Foundation
import XCTest
@testable import VocabCore

/// M2.7 — таблиця ErrorDisposition (D6).
final class ErrorDispositionTests: XCTestCase {
    func testDispositionTable() {
        // Офлайн / немає ключа → pending, без лічильника (навіть на останній спробі).
        for error: ClaudeError in [.offline, .missingAPIKey] {
            for attempts in [0, 3, 4, 10] {
                let disposition = ErrorDisposition.for(error, attempts: attempts)
                XCTAssertEqual(disposition.status, .pending, "\(error) attempts=\(attempts)")
                XCTAssertFalse(disposition.countsAttempt, "\(error)")
            }
        }
        // Тимчасові → pending з лічильником; 5-та невдача → failed.
        let transient: [ClaudeError] = [.timeout, .rateLimited(retryAfter: 10), .rateLimited(retryAfter: nil),
                                        .server(status: 500), .server(status: 529), .transport("x")]
        for error in transient {
            for attempts in 0...3 {
                let disposition = ErrorDisposition.for(error, attempts: attempts)
                XCTAssertEqual(disposition.status, .pending, "\(error) attempts=\(attempts)")
                XCTAssertTrue(disposition.countsAttempt)
            }
            let last = ErrorDisposition.for(error, attempts: 4)
            XCTAssertEqual(last.status, .failed, "\(error): 5th failure → failed")
            XCTAssertTrue(last.countsAttempt)
        }
        // Постійні → failed одразу.
        let permanent: [ClaudeError] = [.unauthorized, .forbidden, .badRequest(status: 400, message: ""),
                                        .invalidResponse("x"), .refused]
        for error in permanent {
            let disposition = ErrorDisposition.for(error, attempts: 0)
            XCTAssertEqual(disposition.status, .failed, "\(error)")
            XCTAssertFalse(disposition.countsAttempt)
        }
    }

    func testCustomMaxAttempts() {
        XCTAssertEqual(ErrorDisposition.for(.timeout, attempts: 0, maxAttempts: 1).status, .failed)
        XCTAssertEqual(ErrorDisposition.for(.timeout, attempts: 1, maxAttempts: 3).status, .pending)
        XCTAssertEqual(ErrorDisposition.for(.timeout, attempts: 2, maxAttempts: 3).status, .failed)
    }
}

/// M2.7 — RetryPolicy (D7).
final class RetryPolicyTests: XCTestCase {
    func testExponentialDelays() {
        let policy = RetryPolicy()
        XCTAssertEqual((1...5).map { policy.delay(forAttempt: $0) }, [30, 60, 120, 240, 480])
        XCTAssertEqual(policy.maxAttempts, 5)
    }

    func testCappedAt15Minutes() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.delay(forAttempt: 6), 900)
        XCTAssertEqual(policy.delay(forAttempt: 7), 900)
        XCTAssertEqual(policy.delay(forAttempt: 1000), 900)
        XCTAssertEqual(policy.delay(forAttempt: Int.max), 900)
    }

    func testRetryAfterHonored() {
        let policy = RetryPolicy()
        XCTAssertEqual(policy.delay(forAttempt: 1, error: .rateLimited(retryAfter: 120)), 120)
        XCTAssertEqual(policy.delay(forAttempt: 1, error: .rateLimited(retryAfter: 5)), 30, "max(retryAfter, delay)")
        XCTAssertEqual(policy.delay(forAttempt: 3, error: .rateLimited(retryAfter: nil)), 120)
        XCTAssertEqual(policy.delay(forAttempt: 2, error: .server(status: 500)), 60)
    }
}

/// M2.7 — PendingQueueProcessor + EntryProcessor зі stub-lookup і керованим часом.
final class PendingQueueProcessorTests: XCTestCase {
    private var harness: QueueHarness?

    override func tearDown() {
        harness?.remove()
        harness = nil
        super.tearDown()
    }

    private func make(_ script: [Result<LookupResult, ClaudeError>], gate: Gate? = nil,
                      registry: LanguagePairRegistry = LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly])) async throws -> QueueHarness {
        let made = try await QueueHarness.make(script, gate: gate, registry: registry)
        harness = made
        return made
    }

    private static let runResult = ClaudeFixtures.expectedRunResult

    func testPendingBecomesReady() async throws {
        let h = try await make([.success(Self.runResult)])
        let entry = try await h.addPending("run")

        let results = await h.queue.processAll(ignoringBackoff: false)

        XCTAssertEqual(results.count, 1)
        guard case .ready(let ready) = results.first else { return XCTFail("expected ready, got \(results)") }
        XCTAssertEqual(ready.id, entry.id)
        XCTAssertEqual(ready.status, .ready)
        XCTAssertNil(ready.lastError)
        XCTAssertEqual(ready.lemma, "run")
        XCTAssertEqual(ready.partOfSpeech, "verb")
        XCTAssertEqual(ready.transcription, "/rʌn/")
        XCTAssertEqual(ready.translations, ["бігти", "керувати"])
        XCTAssertEqual(ready.example, Self.runResult.example)
        XCTAssertEqual(try h.fixture.store.load().file.entries, [ready], "persisted")
        XCTAssertEqual(h.lookup.texts, ["run"])
    }

    func testPhraseEntryLookedUpAsPhraseAndClearsPreviousError() async throws {
        let phrase = LookupResult(word: "give up", lemma: "give up", partOfSpeech: "phrase", transcription: "",
                                  translations: ["здаватися"], example: Example(source: "Never give up.",
                                                                                translation: "Ніколи не здавайся."))
        let h = try await make([.failure(.offline), .success(phrase)])
        let entry = try await h.addPending("give up")

        _ = await h.queue.processAll(ignoringBackoff: false)
        let awaited1 = await h.entry(entry.id)?.lastError
        XCTAssertEqual(awaited1, ClaudeError.offline.userMessage)
        _ = await h.queue.processAll(ignoringBackoff: false)

        let awaited2 = await h.entry(entry.id)
        let ready = try XCTUnwrap(awaited2)
        XCTAssertEqual(ready.status, .ready)
        XCTAssertNil(ready.lastError)
        XCTAssertNil(ready.transcription, "empty transcription stored as nil")
        XCTAssertEqual(ready.partOfSpeech, "phrase")
    }

    func testOfflineStaysPendingWithoutAttempt() async throws {
        let h = try await make([.failure(.offline)])
        let entry = try await h.addPending("run")

        for _ in 0..<7 {
            let results = await h.queue.processAll(ignoringBackoff: false)
            XCTAssertEqual(results.count, 1, "offline entry is retried on every trigger (no backoff)")
            guard case .pending(let pending, .offline) = results.first else {
                return XCTFail("expected pending offline, got \(results)")
            }
            XCTAssertEqual(pending.status, .pending)
            XCTAssertEqual(pending.lastError, "Немає мережі")
        }
        let awaited3 = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(awaited3, 0)
        let awaited4 = await h.queue.nextAttempt(for: entry.id)
        XCTAssertNil(awaited4)
        let awaited5 = await h.entry(entry.id)?.status
        XCTAssertEqual(awaited5, .pending)
        XCTAssertEqual(h.lookup.callCount, 7)
    }

    func testMissingKeyStaysPendingWithoutAttempt() async throws {
        let h = try await make([.failure(.missingAPIKey)])
        let entry = try await h.addPending("run")

        for _ in 0..<6 {
            _ = await h.queue.processAll(ignoringBackoff: false)
        }

        let awaited6 = await h.entry(entry.id)?.status
        XCTAssertEqual(awaited6, .pending)
        let awaited7 = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(awaited7, 0)
    }

    func testUnauthorizedBecomesFailed() async throws {
        let h = try await make([.failure(.unauthorized)])
        let entry = try await h.addPending("run")

        let results = await h.queue.processAll(ignoringBackoff: false)

        guard case .failed(let failed, .unauthorized) = results.first else {
            return XCTFail("expected failed unauthorized, got \(results)")
        }
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastError, ClaudeError.unauthorized.userMessage)
        XCTAssertEqual(try h.fixture.store.load().file.entries.first?.status, .failed, "persisted")
        // failed не підхоплюється автоматично.
        let again = await h.queue.processAll(ignoringBackoff: true)
        XCTAssertEqual(again, [])
        XCTAssertEqual(h.lookup.callCount, 1)
        let awaited8 = await h.entry(entry.id)?.status
        XCTAssertEqual(awaited8, .failed)
    }

    func testPermanentErrorsBecomeFailed() async throws {
        let errors: [ClaudeError] = [.forbidden, .badRequest(status: 404, message: "model"), .invalidResponse("x"), .refused]
        for error in errors {
            let h = try await make([.failure(error)])
            _ = try await h.addPending("run")

            let results = await h.queue.processAll(ignoringBackoff: false)

            XCTAssertEqual(results.first?.entry?.status, .failed, "\(error)")
            XCTAssertEqual(results.first?.error, error)
            h.remove()
        }
    }

    func testServerErrorFailsAfterFiveAttempts() async throws {
        let h = try await make([.failure(.server(status: 500))])
        let entry = try await h.addPending("run")
        let expectedDelays: [TimeInterval] = [30, 60, 120, 240]

        for attempt in 1...4 {
            let results = await h.queue.processDue()
            guard case .pending(let pending, .server(status: 500)) = results.first else {
                return XCTFail("attempt \(attempt): expected pending, got \(results)")
            }
            XCTAssertEqual(pending.status, .pending)
            let awaited9 = await h.queue.attemptCount(for: entry.id)
            XCTAssertEqual(awaited9, attempt)
            let awaited10 = await h.queue.nextAttempt(for: entry.id)
            let next = try XCTUnwrap(awaited10)
            XCTAssertEqual(next.timeIntervalSince(h.dates.now()), expectedDelays[attempt - 1])
            h.dates.current = next
        }

        let final = await h.queue.processDue()
        guard case .failed(let failed, .server(status: 500)) = final.first else {
            return XCTFail("5th failure: expected failed, got \(final)")
        }
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastError, "Помилка сервера Claude (500)")
        XCTAssertEqual(h.lookup.callCount, 5)
        let awaited11 = await h.queue.nextAttempt(for: entry.id)
        XCTAssertNil(awaited11)
        let awaited12 = await h.queue.processAll(ignoringBackoff: true)
        XCTAssertEqual(awaited12, [], "failed is not retried automatically")
    }

    func testRateLimitedBackoffHonorsRetryAfter() async throws {
        let h = try await make([.failure(.rateLimited(retryAfter: 300))])
        let entry = try await h.addPending("run")

        _ = await h.queue.processDue()

        let awaited13 = await h.queue.nextAttempt(for: entry.id)
        let next = try XCTUnwrap(awaited13)
        XCTAssertEqual(next.timeIntervalSince(h.dates.now()), 300)
    }

    func testBackoffSkipsNotDueEntries() async throws {
        let h = try await make([.failure(.timeout)])
        let entry = try await h.addPending("run")

        _ = await h.queue.processDue()
        XCTAssertEqual(h.lookup.callCount, 1)

        h.dates.advance(by: 29)
        let awaited14 = await h.queue.processDue()
        XCTAssertEqual(awaited14, [], "not due yet")
        XCTAssertEqual(h.lookup.callCount, 1)

        h.dates.advance(by: 1)
        let due = await h.queue.processDue()
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(h.lookup.callCount, 2)
        let awaited15 = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(awaited15, 2)

        // processAll(ignoringBackoff: true) ігнорує nextAttemptAt, але лічильник не скидає.
        let forced = await h.queue.processAll(ignoringBackoff: true)
        XCTAssertEqual(forced.count, 1)
        XCTAssertEqual(h.lookup.callCount, 3)
        let awaited16 = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(awaited16, 3)
    }

    func testBackoffOnlyAffectsFailingEntry() async throws {
        let h = try await make([.failure(.timeout)])
        let first = try await h.addPending("run")
        _ = await h.queue.processDue()
        h.lookup.setScript([.success(Self.runResult)])
        let second = try await h.addPending("walk")

        let results = await h.queue.processDue()

        XCTAssertEqual(results.map { $0.entry?.id }, [second.id], "only the due entry is processed")
        let awaited17 = await h.entry(first.id)?.status
        XCTAssertEqual(awaited17, .pending)
        let awaited18 = await h.entry(second.id)?.status
        XCTAssertEqual(awaited18, .ready)
    }

    func testManualRetryOfFailed() async throws {
        let h = try await make([.failure(.unauthorized)])
        let entry = try await h.addPending("run")
        _ = await h.queue.processAll(ignoringBackoff: false)
        let awaited19 = await h.entry(entry.id)?.status
        XCTAssertEqual(awaited19, .failed)

        h.lookup.setScript([.success(Self.runResult)])
        let result = await h.queue.retry(entryID: entry.id)

        guard case .ready(let ready) = result else { return XCTFail("expected ready, got \(result)") }
        XCTAssertEqual(ready.status, .ready)
        XCTAssertNil(ready.lastError)
        XCTAssertEqual(h.lookup.callCount, 2)
    }

    func testManualRetryResetsAttemptsAndIgnoresBackoff() async throws {
        let h = try await make([.failure(.server(status: 503))])
        let entry = try await h.addPending("run")
        for _ in 1...3 {
            _ = await h.queue.processAll(ignoringBackoff: true)
        }
        let awaited20 = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(awaited20, 3)
        let awaited21 = await h.queue.nextAttempt(for: entry.id)
        XCTAssertNotNil(awaited21)

        // Manual retry while in backoff: runs immediately, counter restarts from 0 → after failure = 1.
        let result = await h.queue.retry(entryID: entry.id)

        XCTAssertEqual(result.entry?.status, .pending)
        let awaited22 = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(awaited22, 1)
        XCTAssertEqual(h.lookup.callCount, 4)
        // Тепер ще 4 невдачі до failed (а не 2).
        for _ in 1...3 {
            let next = await h.queue.processAll(ignoringBackoff: true)
            XCTAssertEqual(next.first?.entry?.status, .pending)
        }
        let last = await h.queue.processAll(ignoringBackoff: true)
        XCTAssertEqual(last.first?.entry?.status, .failed)
    }

    func testManualRetryOfFailedAfterMaxAttemptsGetsFullBudget() async throws {
        let h = try await make([.failure(.timeout)])
        let entry = try await h.addPending("run")
        for _ in 1...5 {
            _ = await h.queue.processAll(ignoringBackoff: true)
        }
        let awaited23 = await h.entry(entry.id)?.status
        XCTAssertEqual(awaited23, .failed)

        let result = await h.queue.retry(entryID: entry.id)

        XCTAssertEqual(result.entry?.status, .pending, "reset counter: first failure after retry is pending")
        let awaited24 = await h.queue.attemptCount(for: entry.id)
        XCTAssertEqual(awaited24, 1)
    }

    func testRetryOfReadyIsSkippedAndMissingIsNotFound() async throws {
        let h = try await make([.success(Self.runResult)])
        let ready = try await h.repository.add(TestFixtures.draft(word: "run"))

        let skipped = await h.queue.retry(entryID: ready.id)
        XCTAssertEqual(skipped, .skipped(ready))

        let missing = UUID()
        let awaited25 = await h.queue.retry(entryID: missing)
        XCTAssertEqual(awaited25, .notFound(missing))
        XCTAssertEqual(h.lookup.callCount, 0)
    }

    func testRetryOfInFlightEntryIsSkipped() async throws {
        let gate = Gate()
        let h = try await make([.success(Self.runResult)], gate: gate)
        let entry = try await h.addPending("run")

        let queue = h.queue
        let processing = Task { await queue.processAll(ignoringBackoff: false) }
        await waitUntil { h.lookup.callCount == 1 }

        let retried = await h.queue.retry(entryID: entry.id)

        guard case .skipped(let skipped) = retried else { return XCTFail("expected skipped, got \(retried)") }
        XCTAssertEqual(skipped.id, entry.id)
        XCTAssertEqual(h.lookup.callCount, 1, "no second HTTP request for in-flight entry")

        gate.open()
        let results = await processing.value
        XCTAssertEqual(results.first?.entry?.status, .ready)
        XCTAssertEqual(h.lookup.callCount, 1)
        let awaited26 = await h.entry(entry.id)?.status
        XCTAssertEqual(awaited26, .ready)
    }

    func testConcurrentProcessAllDoesNotDoubleProcess() async throws {
        let gate = Gate()
        let h = try await make([.success(Self.runResult)], gate: gate)
        let entry = try await h.addPending("run")
        _ = try await h.addPending("walk")

        let queue = h.queue
        let first = Task { await queue.processAll(ignoringBackoff: false) }
        await waitUntil { h.lookup.callCount == 1 }

        let second = await queue.processAll(ignoringBackoff: true)
        let due = await queue.processDue()
        XCTAssertEqual(second, [], "second pass while running returns immediately")
        XCTAssertEqual(due, [])

        gate.open()
        let results = await first.value
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(h.lookup.callCount, 2, "each entry looked up exactly once")
        XCTAssertEqual(Set(h.lookup.texts), ["run", "walk"])
        let awaited27 = await h.entry(entry.id)?.status
        XCTAssertEqual(awaited27, .ready)
    }

    func testEntriesProcessedSequentially() async throws {
        let h = try await make([.success(Self.runResult)])
        for word in ["run", "walk", "jump"] {
            _ = try await h.addPending(word)
        }

        let results = await h.queue.processAll(ignoringBackoff: false)

        XCTAssertEqual(h.lookup.texts, ["run", "walk", "jump"])
        XCTAssertEqual(results.compactMap { $0.entry?.status }, [.ready, .ready, .ready])
    }

    func testWordReplacedByModelWordWhenKeysMatch() async throws {
        var capitalized = Self.runResult
        capitalized.word = "Run"
        let h = try await make([.success(capitalized)])
        let entry = try await h.addPending("run")

        _ = await h.queue.processAll(ignoringBackoff: false)
        let awaited28 = await h.entry(entry.id)?.word
        XCTAssertEqual(awaited28, "Run", "same key → model's word")

        var lemma = Self.runResult
        lemma.word = "run"
        h.lookup.setScript([.success(lemma)])
        let runs = try await h.addPending("runs")

        _ = await h.queue.processAll(ignoringBackoff: false)
        let awaited29 = await h.entry(runs.id)
        let updated = try XCTUnwrap(awaited29)
        XCTAssertEqual(updated.word, "runs", "different key → selection kept")
        XCTAssertEqual(updated.lemma, "run")
        XCTAssertEqual(updated.status, .ready)
    }

    func testUnknownPairBecomesFailedWithoutLookup() async throws {
        let h = try await make([.success(Self.runResult)])
        let entry = try await h.addPending("correre", languagePair: "it-uk")

        let results = await h.queue.processAll(ignoringBackoff: false)

        XCTAssertEqual(results.first?.entry?.status, .failed)
        let awaited30 = await h.entry(entry.id)?.lastError
        XCTAssertEqual(awaited30, "Невідома мовна пара")
        XCTAssertEqual(h.lookup.callCount, 0)
    }

    func testDeletedDuringLookupReturnsNotFound() async throws {
        let gate = Gate()
        let h = try await make([.success(Self.runResult)], gate: gate)
        let entry = try await h.addPending("run")

        let queue = h.queue
        let task = Task { await queue.retry(entryID: entry.id) }
        await waitUntil { h.lookup.callCount == 1 }
        try await h.repository.delete(id: entry.id)
        gate.open()

        let result = await task.value
        XCTAssertEqual(result, .notFound(entry.id))
        let awaited31 = await h.repository.allEntries()
        XCTAssertEqual(awaited31, [])
    }

    func testAttemptsNotPersistedInJSON() async throws {
        let h = try await make([.failure(.timeout)])
        _ = try await h.addPending("run")
        _ = await h.queue.processDue()

        let entryObject = try XCTUnwrap((jsonObject(h.fixture.readRaw())["entries"] as? [[String: Any]])?.first)
        XCTAssertNil(entryObject["attempts"])
        XCTAssertNil(entryObject["nextAttemptAt"])
        XCTAssertEqual(entryObject["status"] as? String, "pending")
    }
}
