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
            if inFlight.contains(id) {
                if let entry = await repository.entry(id: id) {
                    results.append(.skipped(entry))
                }
                continue
            }
            // Стан міг змінитися, поки оброблялися попередні записи.
            guard let current = await repository.entry(id: id), current.status == .pending else {
                continue
            }
            results.append(await processOne(id))
        }
        return results
    }

    /// Кнопка «Повторити»: `pending` або `failed`, ігнорує backoff і скидає лічильник спроб.
    /// Запис, що вже в обробці, — `.skipped` без другого запиту.
    public func retry(entryID: UUID) async -> ProcessingResult {
        guard let entry = await repository.entry(id: entryID) else {
            return .notFound(entryID)
        }
        if inFlight.contains(entryID) || entry.status == .ready {
            return .skipped(entry)
        }
        attempts[entryID] = nil
        nextAttemptAt[entryID] = nil
        exhausted.remove(entryID)
        return await processOne(entryID)
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

    private func processOne(_ id: UUID) async -> ProcessingResult {
        inFlight.insert(id)
        defer { inFlight.remove(id) }

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
        case .skipped:
            break
        }
        return result
    }
}
