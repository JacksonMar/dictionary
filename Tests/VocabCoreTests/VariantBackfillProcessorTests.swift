import Foundation
import XCTest
@testable import VocabCore

/// M7.6 — пакетне доповнення (§8.4, D28, D29): `ceil(n/15)` запитів, 0 для кешованих, часткові успіхи збережено.
/// Тести кількості запитів — через реальний HTTP-шар (`ClaudeLookupService` + `MockURLProtocol`).
final class VariantBackfillProcessorTests: XCTestCase {
    private var stack: M7Stack?
    private var stubHarness: BackfillStubHarness?

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        stack?.remove()
        stubHarness?.remove()
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    /// `count` готових англійських записів без варіантів, `createdAt` за зростанням.
    private func englishEntries(_ count: Int, pair: String = "en-uk", offset: Int = 0) -> [Entry] {
        (0..<count).map { index in
            M7.entry(pair: pair, word: "word\(index + offset)", created: TimeInterval((index + offset) * 10))
        }
    }

    private func makeStack(seed: [Entry], registry: LanguagePairRegistry = LanguagePairRegistry(pairs: [.englishUkrainian])) async throws -> M7Stack {
        let made = try await M7Stack.make(seed: seed, registry: registry)
        stack = made
        return made
    }

    private func makeStub(seed: [Entry], lookup: StubVariantBatchLookupService = StubVariantBatchLookupService()) async throws -> BackfillStubHarness {
        let made = try await BackfillStubHarness.make(seed: seed, lookup: lookup)
        stubHarness = made
        return made
    }

    private func backfill(_ stack: M7Stack, ignoringBackoff: Bool = true) async -> VariantBackfillReport {
        await stack.backfill.backfill(pairID: "en-uk", languageID: "it", ignoringBackoff: ignoringBackoff)
    }

    private static let truncatedReply = ClaudeFixtures.ok(#"[{"id":1,"word":"corr"#, stopReason: "max_tokens")
    private static let notJSONReply = ClaudeFixtures.ok("Sorry, I cannot produce JSON right now.")

    // MARK: - Request counts

    func testBackfill37EntriesMakesThreeRequests() async throws {
        let entries = englishEntries(37)
        let stack = try await makeStack(seed: entries)
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let report = await backfill(stack)

        XCTAssertEqual(MockURLProtocol.requestCount, 3)
        XCTAssertEqual(report.requests, 3)
        XCTAssertEqual(report.eligible, 37)
        XCTAssertEqual(report.ready, 37)
        XCTAssertEqual(report.pending, 0)
        XCTAssertNil(report.stoppedBy)
        let itemCounts = MockURLProtocol.requests.map { M7.items($0).count }
        XCTAssertEqual(itemCounts, [15, 15, 7])
        for request in MockURLProtocol.requests {
            let ids = M7.items(request).compactMap { $0["id"] as? Int }
            XCTAssertEqual(ids, Array(1...ids.count), "refs are 1…n within a batch")
        }
        // Порядок — createdAt за зростанням.
        XCTAssertEqual(M7.items(MockURLProtocol.requests[0]).first?["word"] as? String, "word0")
        XCTAssertEqual(M7.items(MockURLProtocol.requests[2]).last?["word"] as? String, "word36")

        let onDisk = try stack.entriesOnDisk()
        XCTAssertEqual(onDisk.count, 37)
        for entry in onDisk {
            XCTAssertEqual(entry.variantState("it"), .ready, entry.word)
            XCTAssertEqual(entry.variants?["it"]?.word, entry.word + "ino")
            XCTAssertEqual(entry.variants?["it"]?.sourceKey, entry.word)
        }
    }

    func testBackfillPersistsAfterEachBatch() async throws {
        let entries = englishEntries(20)
        let stack = try await makeStack(seed: entries)
        let firstBatch = M7.batchJSON((1...15).map { M7.batchElement(id: $0, word: "parola") })
        MockURLProtocol.setReplies([ClaudeFixtures.ok(firstBatch), ClaudeFixtures.http(500)])

        let report = await backfill(stack)

        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        XCTAssertEqual(report.requests, 2)
        XCTAssertEqual(report.stoppedBy, .server(status: 500))
        XCTAssertEqual(report.ready, 15)
        XCTAssertEqual(report.pending, 5)
        let onDisk = try stack.entriesOnDisk().sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(onDisk.prefix(15).map { $0.variantState("it") }, Array(repeating: .ready, count: 15))
        XCTAssertEqual(onDisk.suffix(5).map { $0.variantState("it") }, Array(repeating: .pending, count: 5))
    }

    func testSecondBackfillMakesZeroRequests() async throws {
        let stack = try await makeStack(seed: englishEntries(20))
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let first = await backfill(stack)
        XCTAssertEqual(first.requests, 2)
        let second = await backfill(stack)
        XCTAssertEqual(second.requests, 0)
        XCTAssertEqual(second.eligible, 0)
        let all = await stack.backfill.backfillAll(pairID: "en-uk", languageID: "it")
        XCTAssertEqual(all.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 2)

        // «Перезапуск»: новий стек над тим самим файлом — даних достатньо, запитів 0.
        let restarted = try await M7Stack.make(fixture: stack.fixture)
        let afterRestart = await backfill(restarted)
        XCTAssertEqual(afterRestart.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testReadyVariantsNeverRequested() async throws {
        let ready1 = M7.entry(word: "run", created: 0, variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        let missing = M7.entry(word: "dog", created: 10)
        let ready2 = M7.entry(word: "house", created: 20, variants: ["it": M7.readyVariant("casa", sourceWord: "house")])
        let stack = try await makeStack(seed: [ready1, missing, ready2])
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let report = await backfill(stack)

        XCTAssertEqual(report.eligible, 1)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(M7.items(MockURLProtocol.requests[0]).map { $0["word"] as? String }, ["dog"])
        let onDisk = try stack.entriesOnDisk()
        XCTAssertEqual(onDisk.first { $0.id == ready1.id }, ready1, "ready variant untouched")
        XCTAssertEqual(onDisk.first { $0.id == missing.id }?.variants?["it"]?.word, "cane")
    }

    func testStaleVariantReRequested() async throws {
        let stale = M7.entry(word: "sprint", variants: ["it": M7.readyVariant("correre", sourceWord: "run")])
        let stack = try await makeStack(seed: [stale])
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let report = await backfill(stack)

        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(report.ready, 1)
        let stored = try XCTUnwrap(stack.entryOnDisk(stale.id))
        XCTAssertEqual(stored.variants?["it"]?.word, "sprintino")
        XCTAssertEqual(stored.variants?["it"]?.sourceKey, "sprint")
        XCTAssertEqual(stored.variantState("it"), .ready)
    }

    func testPendingVariantRequested() async throws {
        let pending = M7.entry(word: "dog", variants: ["it": M7.unfilledVariant(.pending, sourceWord: "dog")])
        let stack = try await makeStack(seed: [pending])
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let report = await backfill(stack)

        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(try stack.entryOnDisk(pending.id)?.variants?["it"]?.word, "cane")
    }

    func testNonReadyEntriesSkipped() async throws {
        let pending = M7.entry(word: "pend", status: .pending)
        let failed = M7.entry(word: "fail", status: .failed, created: 10)
        let stack = try await makeStack(seed: [pending, failed])
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let report = await backfill(stack)
        let all = await stack.backfill.backfillAll(pairID: "en-uk", languageID: "it")
        let ids = await stack.backfill.eligibleEntryIDs(pairID: "en-uk", languageID: "it", includeFailed: true)

        XCTAssertEqual(report.eligible, 0)
        XCTAssertEqual(all.eligible, 0)
        XCTAssertEqual(ids, [])
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
        let refresh = await stack.backfill.refresh(entryID: pending.id, languageID: "it")
        XCTAssertEqual(refresh.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    // MARK: - Batch errors (D29)

    func testOfflineStopsRunAfterOneRequestNoAttemptCounted() async throws {
        let entries = englishEntries(20)
        let stack = try await makeStack(seed: entries)
        MockURLProtocol.setReplies([ClaudeFixtures.urlError(.notConnectedToInternet)])

        let report = await backfill(stack)

        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(report.stoppedBy, .offline)
        XCTAssertEqual(report.ready + report.pending + report.failed, 0)
        XCTAssertTrue(try stack.entriesOnDisk().allSatisfy { $0.variants == nil })
        let attempts = await stack.backfill.attemptCount(entryID: entries[0].id, languageID: "it")
        XCTAssertEqual(attempts, 0)
        let next = await stack.backfill.nextAttempt(entryID: entries[0].id, languageID: "it")
        XCTAssertNil(next)
        // Без backoff: наступний прохід знову пробує.
        MockURLProtocol.setHandler(M7.batchEchoReply)
        let retry = await backfill(stack, ignoringBackoff: false)
        XCTAssertEqual(retry.requests, 2)
        XCTAssertEqual(retry.ready, 20)
    }

    func testUnauthorizedStopsRunVariantsUnchanged() async throws {
        let entries = englishEntries(20)
        let stack = try await makeStack(seed: entries)
        let before = try stack.entriesOnDisk()
        MockURLProtocol.setReplies([ClaudeFixtures.http(401)])

        let report = await backfill(stack)

        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(report.stoppedBy, .unauthorized)
        XCTAssertEqual(try stack.entriesOnDisk(), before)
        let attempts = await stack.backfill.attemptCount(entryID: entries[0].id, languageID: "it")
        XCTAssertEqual(attempts, 0)

        // Без ключа — жодного HTTP-запиту, прохід зупинено.
        try stack.lookup.secrets.deleteSecret(for: .anthropicAPIKey)
        let noKey = await backfill(stack)
        XCTAssertEqual(noKey.stoppedBy, .missingAPIKey)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testServerErrorMarksPendingWithBackoff() async throws {
        let run = M7.entry(word: "run")
        let stack = try await makeStack(seed: [run])
        MockURLProtocol.setReplies([ClaudeFixtures.http(500)])

        let report = await backfill(stack)

        XCTAssertEqual(report.stoppedBy, .server(status: 500))
        XCTAssertEqual(report.pending, 1)
        let stored = try XCTUnwrap(stack.entryOnDisk(run.id))
        XCTAssertEqual(stored.variantState("it"), .pending)
        XCTAssertEqual(stored.variants?["it"]?.lastError, ClaudeError.server(status: 500).userMessage)
        XCTAssertEqual(stored.updatedAt, run.updatedAt)
        let attempts = await stack.backfill.attemptCount(entryID: run.id, languageID: "it")
        XCTAssertEqual(attempts, 1)
        let next = await stack.backfill.nextAttempt(entryID: run.id, languageID: "it")
        XCTAssertEqual(next, stack.dates.now().addingTimeInterval(30))

        // У backoff — авто-прохід без ignoringBackoff нічого не надсилає.
        let early = await backfill(stack, ignoringBackoff: false)
        XCTAssertEqual(early.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        stack.dates.advance(by: 31)
        MockURLProtocol.setHandler(M7.batchEchoReply)
        let due = await backfill(stack, ignoringBackoff: false)
        XCTAssertEqual(due.requests, 1)
        XCTAssertEqual(try stack.entryOnDisk(run.id)?.variantState("it"), .ready)
    }

    func testRateLimitStopsRunAndMarksPending() async throws {
        let stack = try await makeStack(seed: englishEntries(16))
        MockURLProtocol.setReplies([ClaudeFixtures.http(429, headers: ["retry-after": "120"])])

        let report = await backfill(stack)

        XCTAssertEqual(MockURLProtocol.requestCount, 1, "second batch not sent")
        guard case .rateLimited = report.stoppedBy else { return XCTFail("expected rateLimited, got \(String(describing: report.stoppedBy))") }
        XCTAssertEqual(report.pending, 15)
        let states = try stack.entriesOnDisk().sorted { $0.createdAt < $1.createdAt }.map { $0.variantState("it") }
        XCTAssertEqual(states, Array(repeating: .pending, count: 15) + [.missing])
    }

    func testTruncatedBatchSplitsInsteadOfRepeating() async throws {
        let stack = try await makeStack(seed: englishEntries(15))
        MockURLProtocol.setHandler { request in
            M7.items(request).count == 15 ? Self.truncatedReply : M7.batchEchoReply(request)
        }

        let report = await backfill(stack)

        XCTAssertEqual(MockURLProtocol.requestCount, 3)
        XCTAssertEqual(report.requests, 3)
        let requests = MockURLProtocol.requests
        XCTAssertEqual(requests.map { M7.items($0).count }, [15, 8, 7])
        let texts = requests.map(M7.userText)
        XCTAssertNotEqual(texts[1], texts[0])
        XCTAssertNotEqual(texts[2], texts[0])
        XCTAssertNotEqual(texts[1], texts[2])
        XCTAssertEqual(M7.items(requests[1]).compactMap { $0["word"] as? String }, (0..<8).map { "word\($0)" })
        XCTAssertEqual(M7.items(requests[2]).compactMap { $0["word"] as? String }, (8..<15).map { "word\($0)" })
        XCTAssertEqual(report.ready, 15)
        XCTAssertNil(report.stoppedBy)
        XCTAssertTrue(try stack.entriesOnDisk().allSatisfy { $0.variantState("it") == .ready })
        // Обрізання не рахується як спроба.
        let ids = try stack.entriesOnDisk().map(\.id)
        for id in ids {
            let attempts = await stack.backfill.attemptCount(entryID: id, languageID: "it")
            XCTAssertEqual(attempts, 0)
        }
    }

    func testTruncatedSingleItemMarkedPendingNoRepeat() async throws {
        let run = M7.entry(word: "run")
        let stack = try await makeStack(seed: [run])
        MockURLProtocol.setReplies([Self.truncatedReply])

        let report = await backfill(stack)

        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(report.pending, 1)
        XCTAssertNil(report.stoppedBy)
        XCTAssertEqual(try stack.entryOnDisk(run.id)?.variantState("it"), .pending)
        let attempts = await stack.backfill.attemptCount(entryID: run.id, languageID: "it")
        XCTAssertEqual(attempts, 1)
    }

    func testInvalidResponseMarksBatchPendingAndContinues() async throws {
        let entries = englishEntries(16)
        let stack = try await makeStack(seed: entries)
        MockURLProtocol.setHandler { request in
            M7.items(request).count == 15 ? Self.notJSONReply : M7.batchEchoReply(request)
        }

        let report = await backfill(stack)

        XCTAssertEqual(MockURLProtocol.requestCount, 2)
        XCTAssertEqual(report.requests, 2)
        XCTAssertNil(report.stoppedBy)
        XCTAssertEqual(report.pending, 15)
        XCTAssertEqual(report.ready, 1)
        let attempts = await stack.backfill.attemptCount(entryID: entries[0].id, languageID: "it")
        XCTAssertEqual(attempts, 1)
        let lastAttempts = await stack.backfill.attemptCount(entryID: entries[15].id, languageID: "it")
        XCTAssertEqual(lastAttempts, 0)
        XCTAssertEqual(try stack.entryOnDisk(entries[15].id)?.variantState("it"), .ready)
    }

    func testPartiallyInvalidBatchKeepsValidItems() async throws {
        let entries = englishEntries(3)
        let stack = try await makeStack(seed: entries)
        var invalid = M7.batchElement(id: 2, word: "x")
        invalid["translations"] = []
        MockURLProtocol.setReplies([ClaudeFixtures.ok(M7.batchJSON([M7.batchElement(id: 1, word: "uno"), invalid]))])

        let report = await backfill(stack)

        XCTAssertEqual(MockURLProtocol.requestCount, 1, "partial success is not retried")
        XCTAssertEqual(report.ready, 1)
        XCTAssertEqual(report.pending, 2)
        let states = try stack.entriesOnDisk().sorted { $0.createdAt < $1.createdAt }.map { $0.variantState("it") }
        XCTAssertEqual(states, [.ready, .pending, .pending])
        XCTAssertEqual(try stack.entryOnDisk(entries[2].id)?.variants?["it"]?.lastError?.isEmpty, false)
    }

    func testBatchServiceDoesNotRetrySamePrompt() async throws {
        let harness = LookupHarness()
        let items = [VariantRequestItem(ref: 1, word: "run", kind: .word)]

        MockURLProtocol.setReplies([Self.notJSONReply])
        await XCTAssertThrowsClaudeError(
            try await harness.service.lookupVariants(items: items, language: .italian, pair: .englishUkrainian),
            .invalidResponse("відповідь не містить JSON-масиву")
        )
        XCTAssertEqual(MockURLProtocol.requestCount, 1)

        MockURLProtocol.setReplies([Self.truncatedReply])
        await XCTAssertThrowsClaudeError(
            try await harness.service.lookupVariants(items: items, language: .italian, pair: .englishUkrainian),
            .invalidResponse(LookupResponseParser.maxTokensReason)
        )
        XCTAssertEqual(MockURLProtocol.requestCount, 2)

        let refusal = MockURLProtocol.Reply.response(
            status: 200, headers: [:], body: ClaudeFixtures.messagesResponse(text: "", stopReason: "refusal")
        )
        MockURLProtocol.setReplies([refusal])
        await XCTAssertThrowsClaudeError(
            try await harness.service.lookupVariants(items: items, language: .italian, pair: .englishUkrainian),
            .refused
        )
        XCTAssertEqual(MockURLProtocol.requestCount, 3)

        // Порожній пакет — без запиту.
        let empty = try await harness.service.lookupVariants(items: [], language: .italian, pair: .englishUkrainian)
        XCTAssertEqual(empty, [:])
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
    }

    func testItemFailsAfterFiveAttempts() async throws {
        let run = M7.entry(word: "run")
        let stack = try await makeStack(seed: [run])
        MockURLProtocol.setReplies([Self.notJSONReply])

        for attempt in 1...5 {
            let report = await backfill(stack)
            XCTAssertEqual(report.requests, 1, "attempt \(attempt)")
            let expected: VariantState = attempt < 5 ? .pending : .failed
            XCTAssertEqual(try stack.entryOnDisk(run.id)?.variantState("it"), expected, "attempt \(attempt)")
        }
        XCTAssertEqual(MockURLProtocol.requestCount, 5)

        let after = await backfill(stack)
        XCTAssertEqual(after.requests, 0, "failed variant not auto-backfilled")
        XCTAssertEqual(MockURLProtocol.requestCount, 5)
    }

    func testFailedOnlyInBackfillAll() async throws {
        let failed = M7.entry(word: "run", variants: ["it": M7.unfilledVariant(.failed, sourceWord: "run")])
        let stack = try await makeStack(seed: [failed])
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let autoIDs = await stack.backfill.eligibleEntryIDs(pairID: "en-uk", languageID: "it", includeFailed: false)
        let allIDs = await stack.backfill.eligibleEntryIDs(pairID: "en-uk", languageID: "it", includeFailed: true)
        XCTAssertEqual(autoIDs, [])
        XCTAssertEqual(allIDs, [failed.id])

        let auto = await backfill(stack)
        XCTAssertEqual(auto.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)

        let manual = await stack.backfill.backfillAll(pairID: "en-uk", languageID: "it")
        XCTAssertEqual(manual.requests, 1)
        XCTAssertEqual(manual.ready, 1)
        XCTAssertEqual(try stack.entryOnDisk(failed.id)?.variants?["it"]?.word, "correre")
    }

    // MARK: - refresh

    func testRefreshMakesOneRequestOverwritesReady() async throws {
        let run = M7.entry(word: "run", updated: 5, variants: ["it": M7.readyVariant("vecchio", sourceWord: "run")])
        let stack = try await makeStack(seed: [run])
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let report = await stack.backfill.refresh(entryID: run.id, languageID: "it")

        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(report.ready, 1)
        let stored = try XCTUnwrap(stack.entryOnDisk(run.id))
        XCTAssertEqual(stored.variants?["it"]?.word, "correre")
        XCTAssertEqual(stored.updatedAt, run.updatedAt)
        XCTAssertNil(M7.items(MockURLProtocol.requests[0]).first?["keep"])
    }

    func testRefreshFailureKeepsReadyVariant() async throws {
        let run = M7.entry(word: "run", variants: ["it": M7.readyVariant("vecchio", sourceWord: "run")])
        let stack = try await makeStack(seed: [run])
        MockURLProtocol.setReplies([Self.notJSONReply])

        let report = await stack.backfill.refresh(entryID: run.id, languageID: "it")

        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(try stack.entryOnDisk(run.id), run, "ready variant not overwritten by failure")
    }

    func testRefreshItalianSourceKeepsSelectedWord() async throws {
        let house = M7.entry(word: "house", variants: ["it": M7.readyVariant("casa", sourceWord: "house")],
                             sourceLanguage: "it")
        let stack = try await makeStack(seed: [house])
        let reply = M7.batchJSON([M7.batchElement(id: 1, word: "abitazione", translations: ["житло"])])
        MockURLProtocol.setReplies([ClaudeFixtures.ok(reply)])

        // Автодоповнення таких записів не бере.
        let auto = await backfill(stack)
        XCTAssertEqual(auto.requests, 0)

        let report = await stack.backfill.refresh(entryID: house.id, languageID: "it")

        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(M7.items(MockURLProtocol.requests[0]).first?["keep"] as? String, "casa")
        let stored = try XCTUnwrap(stack.entryOnDisk(house.id))
        XCTAssertEqual(stored.variants?["it"]?.word, "casa")
        XCTAssertEqual(stored.variants?["it"]?.translations, ["житло"], "other fields from the response")
        XCTAssertEqual(stored.sourceLanguage, "it")
        XCTAssertEqual(stored.word, "house")
    }

    // MARK: - Scope & concurrency

    func testOnlyEntriesOfGivenPairBackfilled() async throws {
        let english = englishEntries(2)
        let foreign = englishEntries(2, pair: "xx-yy", offset: 10)
        let stack = try await makeStack(seed: english + foreign)
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let report = await backfill(stack)

        XCTAssertEqual(report.eligible, 2)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
        XCTAssertEqual(M7.items(MockURLProtocol.requests[0]).compactMap { $0["word"] as? String }, ["word0", "word1"])
        let foreignStored = try stack.entriesOnDisk().filter { $0.languagePair == "xx-yy" }
        XCTAssertTrue(foreignStored.allSatisfy { $0.variants == nil })

        let unknownPair = await stack.backfill.backfill(pairID: "xx-yy", languageID: "it", ignoringBackoff: true)
        XCTAssertEqual(unknownPair.requests, 0)
        let unknownLanguage = await stack.backfill.backfill(pairID: "en-uk", languageID: "de", ignoringBackoff: true)
        XCTAssertEqual(unknownLanguage.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testPairWithoutRenderingsNeverBackfilled() async throws {
        let stack = try await makeStack(seed: englishEntries(3),
                                        registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly]))
        MockURLProtocol.setHandler(M7.batchEchoReply)

        let report = await backfill(stack)
        XCTAssertEqual(report.requests, 0)
        XCTAssertEqual(MockURLProtocol.requestCount, 0)
    }

    func testEntryEditedDuringRequestVariantDiscarded() async throws {
        let gate = Gate()
        let run = M7.entry(word: "run")
        let harness = try await makeStub(seed: [run], lookup: StubVariantBatchLookupService(gate: gate))

        let task = Task { await harness.backfill.backfill(pairID: "en-uk", languageID: "it", ignoringBackoff: true) }
        await waitUntil { harness.lookup.callCount == 1 }
        var edited = run
        edited.word = "sprint"
        _ = try await harness.repository.update(edited)
        gate.open()
        let report = await task.value

        XCTAssertEqual(report.requests, 1)
        XCTAssertEqual(report.ready, 0, "variant for the old word discarded")
        let stored = await harness.repository.entry(id: run.id)
        XCTAssertEqual(stored?.word, "sprint")
        XCTAssertNil(stored?.variants)
        XCTAssertEqual(stored?.variantState("it"), .missing)
    }

    func testEntryDeletedDuringRequestIsSkipped() async throws {
        let gate = Gate()
        let run = M7.entry(word: "run")
        let dog = M7.entry(word: "dog", created: 10)
        let harness = try await makeStub(seed: [run, dog], lookup: StubVariantBatchLookupService(gate: gate))

        let task = Task { await harness.backfill.backfill(pairID: "en-uk", languageID: "it", ignoringBackoff: true) }
        await waitUntil { harness.lookup.callCount == 1 }
        try await harness.repository.delete(id: run.id)
        gate.open()
        let report = await task.value

        XCTAssertEqual(report.ready, 1)
        let all = await harness.repository.allEntries()
        XCTAssertEqual(all.map(\.id), [dog.id])
        XCTAssertEqual(all.first?.variantState("it"), .ready)
    }

    func testConcurrentCallReportsAlreadyRunning() async throws {
        let gate = Gate()
        let harness = try await makeStub(seed: englishEntries(3), lookup: StubVariantBatchLookupService(gate: gate))

        let task = Task { await harness.backfill.backfill(pairID: "en-uk", languageID: "it", ignoringBackoff: true) }
        await waitUntil { harness.lookup.callCount == 1 }
        let second = await harness.backfill.backfillAll(pairID: "en-uk", languageID: "it")
        let refresh = await harness.backfill.refresh(entryID: UUID(), languageID: "it")
        gate.open()
        let first = await task.value

        XCTAssertTrue(second.alreadyRunning)
        XCTAssertEqual(second.requests, 0)
        XCTAssertTrue(refresh.alreadyRunning)
        XCTAssertFalse(first.alreadyRunning)
        XCTAssertEqual(first.ready, 3)
        XCTAssertEqual(harness.lookup.callCount, 1)
    }

    // MARK: - Request shape & invariants

    func testBatchUsesMaxTokens8192AndFourBodyKeys() async throws {
        let stack = try await makeStack(seed: [M7.entry(word: "run")])
        stack.lookup.settings.model = "claude-test-model"
        MockURLProtocol.setHandler(M7.batchEchoReply)

        _ = await backfill(stack)

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        let body = M7.body(request)
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "system", "messages"])
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        XCTAssertEqual(ClaudeConfiguration.batchMaxTokens, 8192)
        XCTAssertEqual(body["model"] as? String, "claude-test-model")
        XCTAssertEqual(
            body["system"] as? String,
            RenderingLanguage.italian.prompt.batchSystem + "\n\n" + RenderingLanguage.italian.prompt.domainInstruction
        )
        XCTAssertEqual(request.request.value(forHTTPHeaderField: "x-api-key"), ClaudeFixtures.apiKey)
        XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains(ClaudeFixtures.apiKey))
        let item = try XCTUnwrap(M7.items(request).first)
        XCTAssertEqual(item["word"] as? String, "run")
        XCTAssertEqual(item["pos"] as? String, "noun")
        XCTAssertEqual(item["meaning"] as? [String], ["переклад-run"])
    }

    func testEntryUpdatedAtUnchangedByBackfill() async throws {
        let entries = englishEntries(3)
        let stack = try await makeStack(seed: entries)
        stack.dates.advance(by: 3600)
        MockURLProtocol.setHandler(M7.batchEchoReply)

        _ = await backfill(stack)

        let onDisk = try stack.entriesOnDisk()
        for entry in entries {
            let stored = try XCTUnwrap(onDisk.first { $0.id == entry.id })
            XCTAssertEqual(stored.updatedAt, entry.updatedAt)
            XCTAssertEqual(stored.createdAt, entry.createdAt)
            XCTAssertEqual(stored.variantState("it"), .ready)
        }
    }

    func testUpdateDoesNotOverwriteStoredVariants() async throws {
        let run = M7.entry(word: "run")
        let stack = try await makeStack(seed: [run])
        MockURLProtocol.setHandler(M7.batchEchoReply)
        _ = await backfill(stack)

        // Редактор тримає застарілу копію без варіантів і зберігає зміну перекладів.
        var staleCopy = run
        staleCopy.translations = ["мчати"]
        let saved = try await stack.repository.update(staleCopy)

        XCTAssertEqual(saved.translations, ["мчати"])
        XCTAssertEqual(saved.variants?["it"]?.word, "correre")
        XCTAssertEqual(try stack.entryOnDisk(run.id)?.variants?["it"]?.word, "correre")

        // Зміна слова робить варіант stale (а не видаляє його) → наступний прохід перезапитує.
        var renamed = saved
        renamed.word = "sprint"
        _ = try await stack.repository.update(renamed)
        XCTAssertEqual(try stack.entryOnDisk(run.id)?.variantState("it"), .stale)
        let again = await backfill(stack)
        XCTAssertEqual(again.requests, 1)
    }
}
