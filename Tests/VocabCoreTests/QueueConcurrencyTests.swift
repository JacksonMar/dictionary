import Foundation
import XCTest
@testable import VocabCore

/// Сховище, чий наступний `save` блокує актор репозиторію на заданий час (щоб вибудувати чергу викликів
/// до репозиторію в потрібному порядку).
final class SlowSaveStore: DictionaryStoring, @unchecked Sendable {
    let base: FileDictionaryStore
    private let lock = NSLock()
    private var delay: TimeInterval = 0
    private var entered = false

    init(base: FileDictionaryStore) {
        self.base = base
    }

    var fileURL: URL { base.fileURL }

    func slowNextSave(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        delay = seconds
        entered = false
    }

    var didEnterSlowSave: Bool {
        lock.lock(); defer { lock.unlock() }
        return entered
    }

    func load() throws -> LoadResult {
        try base.load()
    }

    func save(_ file: DictionaryFile) throws {
        lock.lock()
        let seconds = delay
        delay = 0
        if seconds > 0 { entered = true }
        lock.unlock()
        if seconds > 0 {
            Thread.sleep(forTimeInterval: seconds)
        }
        try base.save(file)
    }
}

/// §8.3 / D17: «Повторити» (або Services → `AddWordUseCase` → `retry`) паралельно з `processAll` не повинен
/// надсилати другий запит для того самого запису.
final class QueueConcurrencyTests: XCTestCase {
    /// Вибудовує порядок: `processAll` пройшов перевірку `inFlight` і чекає `repository.entry(id:)`, а `retry`
    /// у цей час отримує актор черги, не бачить запис в `inFlight` і починає обробку. Далі `processAll`
    /// продовжує і обробляє той самий запис удруге.
    func testRetryDuringProcessAllCandidateCheckDoesNotDoubleProcess() async throws {
        for iteration in 0..<5 {
            let fixture = try StoreFixture()
            defer { fixture.directory.remove() }
            let store = SlowSaveStore(base: fixture.store)
            let repository = DictionaryRepository(store: store, dateProvider: fixture.dateProvider)
            _ = try await repository.load()
            let lookup = StubLookupService([.success(ClaudeFixtures.expectedRunResult)])
            let processor = EntryProcessor(
                repository: repository,
                lookup: lookup,
                registry: LanguagePairRegistry(pairs: [.englishUkrainianSourceOnly]),
                dateProvider: fixture.dateProvider
            )
            let queue = PendingQueueProcessor(repository: repository, processor: processor,
                                              dateProvider: fixture.dateProvider)
            let run = try await repository.add(EntryDraft(word: "run", languagePair: "en-uk", status: .pending))
            var other = try await repository.add(TestFixtures.draft(word: "walk"))

            // Блокуємо актор репозиторію на 300 мс незалежною зміною іншого (ready) запису.
            store.slowNextSave(0.3)
            other.translations = ["ходити"]
            let blocker = Task { try await repository.update(other) }
            await waitUntil { store.didEnterSlowSave }
            // Поки репозиторій зайнятий: спершу `processAll` ставить у чергу `allEntries()`, потім `retry` — `entry(id:)`.
            let processAll = Task { await queue.processAll(ignoringBackoff: true) }
            try await Task.sleep(nanoseconds: 50_000_000)
            let retry = Task { await queue.retry(entryID: run.id) }
            _ = try await blocker.value
            let processAllResults = await processAll.value
            let retryResult = await retry.value

            XCTAssertEqual(lookup.callCount, 1,
                           "iteration \(iteration): entry looked up \(lookup.callCount) times; "
                               + "processAll=\(processAllResults.map(Self.describe)) retry=\(Self.describe(retryResult))")
            let stored = await repository.entry(id: run.id)
            XCTAssertEqual(stored?.status, .ready)
        }
    }

    private static func describe(_ result: ProcessingResult) -> String {
        switch result {
        case .ready: return "ready"
        case .pending: return "pending"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .notFound: return "notFound"
        case .duplicate: return "duplicate"
        }
    }
}
