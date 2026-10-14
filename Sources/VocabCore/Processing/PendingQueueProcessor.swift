import Foundation

/// Черга pending-записів (§8.2–8.3). Записи обробляються послідовно; стан спроб (`attempts`, `nextAttemptAt`)
/// лише в пам'яті. Повторний прохід під час обробки не запускається (`isRunning`); запис у `inFlight`
/// не обробляється вдруге.
public actor PendingQueueProcessor {
    private let repository: DictionaryRepository
    private let processor: EntryProcessor
    private let policy: RetryPolicy
    private let dateProvider: DateProvider

    private var attempts: [UUID: Int] = [:]
    private var nextAttemptAt: [UUID: Date] = [:]
    private var inFlight: Set<UUID> = []
    /// Записи, що вичерпали `maxAttempts`, але лишилися `pending`, бо статус `failed` не вдалося зберегти
    /// (помилка запису на диск). Авто-повтори для них зупинено до ручного «Повторити» або перезапуску.
    private var exhausted: Set<UUID> = []
    private var isRunning = false

    public init(
        repository: DictionaryRepository,
        processor: EntryProcessor,
        policy: RetryPolicy = RetryPolicy(),
        dateProvider: DateProvider
    ) {
        self.repository = repository
        self.processor = processor
        self.policy = policy
        self.dateProvider = dateProvider
    }

    /// Pending-записи, у яких настав час наступної спроби (таймер).
    @discardableResult
    public func processDue() async -> [ProcessingResult] {
        await processAll(ignoringBackoff: false)
    }

    /// Усі pending-записи (старт, мережа, новий ключ/модель); `ignoringBackoff` — не чекати `nextAttemptAt`.
    /// Лічильник спроб не скидається. Якщо прохід уже йде — повертає `[]`.
    @discardableResult
    public func processAll(ignoringBackoff: Bool) async -> [ProcessingResult] {
        guard !isRunning else { return [] }
        isRunning = true
        defer { isRunning = false }

        let candidates = await repository.allEntries()
            .filter { $0.status == .pending }
            .map(\.id)
        var results: [ProcessingResult] = []
        for id in candidates {
            if exhausted.contains(id) {
                continue
            }
            if !ignoringBackoff, let due = nextAttemptAt[id], due > dateProvider.now() {
                continue
            }
            // Стан міг змінитися, поки оброблялися попередні записи. Запис у `inFlight` перевіряється
            // атомарно в `processOne` (без `await` між перевіркою і вставкою) → `.skipped`.
            guard let current = await repository.entry(id: id), current.status == .pending else {
                continue
            }
            if let result = await processOne(id, resetAttempts: false) {
                results.append(result)
            }
        }
        return results
    }

    /// Кнопка «Повторити»: `pending` або `failed`, ігнорує backoff і скидає лічильник спроб.
    /// Запис, що вже в обробці, — `.skipped` без другого запиту.
    public func retry(entryID: UUID) async -> ProcessingResult {
        guard let entry = await repository.entry(id: entryID) else {
            return .notFound(entryID)
        }
        if entry.status == .ready {
            return .skipped(entry)
        }
        return await processOne(entryID, resetAttempts: true) ?? .notFound(entryID)
    }

    /// Кількість зарахованих невдалих спроб (для діагностики й тестів).
    public func attemptCount(for entryID: UUID) -> Int {
        attempts[entryID] ?? 0
    }

    /// Час наступної авто-спроби, якщо запис у backoff.
    public func nextAttempt(for entryID: UUID) -> Date? {
        nextAttemptAt[entryID]
    }

    // MARK: - Private

    /// Обробляє запис, якщо він ще не в обробці. Перевірка й вставка в `inFlight` — без `await` між ними
    /// (атомарно в межах актора), тож паралельні `processAll`/`retry` не запустять другий запит.
    /// Запис, що вже в обробці, → `.skipped(поточний)` (або `nil`, якщо його вже видалено).
    /// `resetAttempts` (ручний «Повторити») скидає лічильник/backoff лише тоді, коли обробку справді почато.
    private func processOne(_ id: UUID, resetAttempts: Bool) async -> ProcessingResult? {
        guard !inFlight.contains(id) else {
            return await repository.entry(id: id).map { .skipped($0) }
        }
        inFlight.insert(id)
        // Видаляємо лише те, що вставив цей виклик (вище гарантовано, що до вставки запису не було).
        defer { inFlight.remove(id) }

        if resetAttempts {
            attempts[id] = nil
            nextAttemptAt[id] = nil
            exhausted.remove(id)
        }

        let previous = attempts[id] ?? 0
        let result = await processor.process(entryID: id, attempts: previous, maxAttempts: policy.maxAttempts)
        switch result {
        case .pending(_, let error):
            let disposition = ErrorDisposition.for(error, attempts: previous, maxAttempts: policy.maxAttempts)
            if disposition.countsAttempt {
                let count = previous + 1
                attempts[id] = count
                nextAttemptAt[id] = dateProvider.now().addingTimeInterval(policy.delay(forAttempt: count, error: error))
                if count >= policy.maxAttempts {
                    // Ліміт вичерпано, а запис досі pending (не вдалося зберегти `failed`) — більше не повторюємо.
                    exhausted.insert(id)
                }
            } else {
                // offline / немає ключа: без лічильника, наступна спроба — за першим тригером.
                nextAttemptAt[id] = nil
            }
        case .ready, .failed, .notFound:
            attempts[id] = nil
            nextAttemptAt[id] = nil
            exhausted.remove(id)
        case .duplicate(_, let removedID):
            // M7 (D27): запис видалено як дубль — стан спроб більше не потрібен (`inFlight` чистить `defer`).
            attempts[removedID] = nil
            nextAttemptAt[removedID] = nil
            exhausted.remove(removedID)
        case .skipped:
            break
        }
        return result
    }
}
