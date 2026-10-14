import Foundation

/// Підсумок проходу доповнення варіантів (§8.4).
public struct VariantBackfillReport: Equatable, Sendable {
    /// Скільки записів було придатних на початку проходу.
    public var eligible: Int
    /// Скільки HTTP-запитів (пакетів) надіслано.
    public var requests: Int
    /// Скільки варіантів стали `ready` / `pending` / `failed` (фактично збережені).
    public var ready: Int
    public var pending: Int
    public var failed: Int
    /// Помилка, що зупинила прохід (offline, ключ, 401/403, 429/5xx/timeout/transport, збій збереження).
    public var stoppedBy: ClaudeError?
    /// Інший прохід триває — нічого не зроблено.
    public var alreadyRunning: Bool

    public init(
        eligible: Int = 0,
        requests: Int = 0,
        ready: Int = 0,
        pending: Int = 0,
        failed: Int = 0,
        stoppedBy: ClaudeError? = nil,
        alreadyRunning: Bool = false
    ) {
        self.eligible = eligible
        self.requests = requests
        self.ready = ready
        self.pending = pending
        self.failed = failed
        self.stoppedBy = stoppedBy
        self.alreadyRunning = alreadyRunning
    }
}

/// Пакетне доповнення варіантів наявних записів (§8.4, D28, D29).
///
/// - Придатні (авто): запис пари `pairID` зі `status == .ready`, пара має мову `languageID`, стан варіанта
///   `missing`/`stale`/`pending` і (без `ignoringBackoff`) настав час спроби. Ready-варіант — ніколи (0 запитів).
///   `failed` — лише `backfillAll`/`refresh`.
/// - Порядок — `createdAt` за зростанням; пакети по `batchSize` → `ceil(n / batchSize)` запитів, послідовно.
///   Після кожного пакета — одразу `repository.setVariants` (один атомарний save на пакет).
/// - Стан спроб (`attempts`, `nextAttemptAt`) — у пам'яті, як у черзі (§8.2).
public actor VariantBackfillProcessor {
    public static let defaultBatchSize = 15

    /// Ключ стану спроб: запис + мова.
    private struct AttemptKey: Hashable {
        let entryID: UUID
        let languageID: String
    }

    /// Запис, підготовлений до запиту (знімок на момент формування пакета).
    private struct Candidate {
        let entryID: UUID
        let word: String
        let kind: SelectionKind
        let partOfSpeech: String?
        let meaning: [String]
        let keepWord: String?
        /// `key(entry.word)` на момент формування пакета (D23).
        let sourceKey: String
        /// Наявний ready-варіант (лише `refresh`): при невдачі його не затираємо.
        let hadReadyVariant: Bool
    }

    private let repository: DictionaryRepository
    private let lookup: VariantBatchLookupService
    private let registry: LanguagePairRegistry
    private let policy: RetryPolicy
    private let dateProvider: DateProvider
    private let batchSize: Int
    private let logger: RedactingLogger?

    private var attempts: [AttemptKey: Int] = [:]
    private var nextAttemptAt: [AttemptKey: Date] = [:]
    private var isRunning = false

    /// - Parameter logger: куди логувати збої збереження (повідомлення редагуються); `nil` — не логувати.
    public init(
        repository: DictionaryRepository,
        lookup: VariantBatchLookupService,
        registry: LanguagePairRegistry,
        policy: RetryPolicy = RetryPolicy(),
        dateProvider: DateProvider,
        batchSize: Int = VariantBackfillProcessor.defaultBatchSize,
        logger: RedactingLogger? = nil
    ) {
        self.repository = repository
        self.lookup = lookup
        self.registry = registry
        self.policy = policy
        self.dateProvider = dateProvider
        self.batchSize = max(1, batchSize)
        self.logger = logger
    }

    // MARK: - Public API

    /// Придатні записи (без урахування backoff) у порядку обробки. `includeFailed` — разом з `failed`
    /// (лічильник кнопки «Доповнити італійською (N)»).
    public func eligibleEntryIDs(pairID: String, languageID: String, includeFailed: Bool) async -> [UUID] {
        guard let pair = registry.pair(id: pairID), pair.rendering(id: languageID) != nil else { return [] }
        return eligibleEntries(
            await repository.allEntries(),
            pair: pair,
            languageID: languageID,
            includeFailed: includeFailed,
            ignoringBackoff: true
        ).map(\.id)
    }

    /// Автодоповнення (перемикання на мову варіанта, старт у цьому режимі, мережа, ключ).
    public func backfill(pairID: String, languageID: String, ignoringBackoff: Bool) async -> VariantBackfillReport {
        await run(pairID: pairID, languageID: languageID, includeFailed: false, ignoringBackoff: ignoringBackoff)
    }

    /// «Доповнити італійською»: разом з `failed`, без backoff; лічильники спроб придатних записів скидаються.
    public func backfillAll(pairID: String, languageID: String) async -> VariantBackfillReport {
        await run(pairID: pairID, languageID: languageID, includeFailed: true, ignoringBackoff: true)
    }

    /// «Оновити італійський переклад»: рівно 1 запит для одного ready-запису, перезаписує навіть ready-варіант.
    /// Для запису, виділеного цією мовою (`sourceLanguage == languageID`), слово користувача зберігається.
    public func refresh(entryID: UUID, languageID: String) async -> VariantBackfillReport {
        guard !isRunning else { return VariantBackfillReport(alreadyRunning: true) }
        isRunning = true
        defer { isRunning = false }

        guard let entry = await repository.entry(id: entryID),
              entry.status == .ready,
              let pair = registry.pair(id: entry.languagePair),
              let language = pair.rendering(id: languageID) else {
            return VariantBackfillReport()
        }
        attempts[AttemptKey(entryID: entryID, languageID: languageID)] = nil
        nextAttemptAt[AttemptKey(entryID: entryID, languageID: languageID)] = nil
        let candidate = Self.candidate(for: entry, languageID: languageID)
        var report = VariantBackfillReport(eligible: 1)
        await processBatches([[candidate]], language: language, pair: pair, report: &report)
        return report
    }

    /// Кількість зарахованих невдалих спроб варіанта (діагностика й тести).
    public func attemptCount(entryID: UUID, languageID: String) -> Int {
        attempts[AttemptKey(entryID: entryID, languageID: languageID)] ?? 0
    }

    /// Час наступної авто-спроби варіанта, якщо він у backoff.
    public func nextAttempt(entryID: UUID, languageID: String) -> Date? {
        nextAttemptAt[AttemptKey(entryID: entryID, languageID: languageID)]
    }

    /// Чи придатний запис для доповнення мовою `languageID` (без урахування backoff). Для лічильників в UI.
    public static func isEligible(_ entry: Entry, pair: LanguagePair, languageID: String, includeFailed: Bool) -> Bool {
        guard entry.languagePair == pair.id,
              entry.status == .ready,
              pair.rendering(id: languageID) != nil else {
            return false
        }
        switch entry.variantState(languageID) {
        case .missing, .stale, .pending:
            return true
        case .failed:
            return includeFailed
        case .ready:
            return false
        }
    }

    // MARK: - Private

    private func run(
        pairID: String,
        languageID: String,
        includeFailed: Bool,
        ignoringBackoff: Bool
    ) async -> VariantBackfillReport {
        guard !isRunning else { return VariantBackfillReport(alreadyRunning: true) }
        isRunning = true
        defer { isRunning = false }

        guard let pair = registry.pair(id: pairID), let language = pair.rendering(id: languageID) else {
            return VariantBackfillReport()
        }
        let entries = eligibleEntries(
            await repository.allEntries(),
            pair: pair,
            languageID: languageID,
            includeFailed: includeFailed,
            ignoringBackoff: ignoringBackoff
        )
        var report = VariantBackfillReport(eligible: entries.count)
        guard !entries.isEmpty else { return report }

        if includeFailed {
            // Ручний запуск — як «Повторити»: лічильники спроб скидаються.
            for entry in entries {
                let key = AttemptKey(entryID: entry.id, languageID: languageID)
                attempts[key] = nil
                nextAttemptAt[key] = nil
            }
        }
        let candidates = entries.map { Self.candidate(for: $0, languageID: languageID) }
        var batches: [[Candidate]] = []
        var start = 0
        while start < candidates.count {
            let end = min(start + batchSize, candidates.count)
            batches.append(Array(candidates[start..<end]))
            start = end
        }
        await processBatches(batches, language: language, pair: pair, report: &report)
        return report
    }

    private func eligibleEntries(
        _ entries: [Entry],
        pair: LanguagePair,
        languageID: String,
        includeFailed: Bool,
        ignoringBackoff: Bool
    ) -> [Entry] {
        let now = dateProvider.now()
        return entries
            .filter { entry in
                guard Self.isEligible(entry, pair: pair, languageID: languageID, includeFailed: includeFailed) else {
                    return false
                }
                if !ignoringBackoff,
                   let due = nextAttemptAt[AttemptKey(entryID: entry.id, languageID: languageID)],
                   due > now {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func candidate(for entry: Entry, languageID: String) -> Candidate {
        let cleanedWord = TextNormalizer.clean(entry.word)
        let keepWord = entry.sourceLanguage == languageID ? entry.variants?[languageID]?.word : nil
        return Candidate(
            entryID: entry.id,
            word: cleanedWord,
            kind: SelectionValidator.kind(of: cleanedWord),
            partOfSpeech: entry.partOfSpeech,
            meaning: Array(entry.translations.prefix(VariantRequestItem.maxMeaningCount)),
            keepWord: keepWord,
            sourceKey: TextNormalizer.key(entry.word),
            hadReadyVariant: entry.variantState(languageID) == .ready
        )
    }

    /// Пакети по черзі; обрізаний пакет ділиться навпіл і половини йдуть одразу (D29).
    private func processBatches(
        _ initial: [[Candidate]],
        language: RenderingLanguage,
        pair: LanguagePair,
        report: inout VariantBackfillReport
    ) async {
        var queue = initial
        while !queue.isEmpty {
            let batch = queue.removeFirst()
            guard !batch.isEmpty else { continue }
            let items = batch.enumerated().map { offset, candidate in
                VariantRequestItem(
                    ref: offset + 1,
                    word: candidate.word,
                    kind: candidate.kind,
                    partOfSpeech: candidate.partOfSpeech,
                    meaning: candidate.meaning,
                    keepWord: candidate.keepWord
                )
            }
            report.requests += 1

            let outcomes: [Int: VariantItemOutcome]
            do {
                outcomes = try await lookup.lookupVariants(items: items, language: language, pair: pair)
            } catch {
                let claudeError = ClaudeError.from(transportError: error)
                switch claudeError {
                case .offline, .missingAPIKey, .unauthorized, .forbidden:
                    // Без змін, спроба не рахується; решта пакетів не надсилається.
                    report.stoppedBy = claudeError
                    return
                case .timeout, .rateLimited, .server, .transport:
                    let updates = failureUpdates(batch, language: language, error: claudeError)
                    guard await save(updates, report: &report) else { return }
                    report.stoppedBy = claudeError
                    return
                case .invalidResponse(let reason) where reason == LookupResponseParser.maxTokensReason:
                    if batch.count > 1 {
                        // Спроба не рахується; той самий промт не повторюється — дві половини (ceil/floor).
                        let firstCount = (batch.count + 1) / 2
                        queue.insert(contentsOf: [Array(batch[..<firstCount]), Array(batch[firstCount...])], at: 0)
                        continue
                    }
                    let updates = failureUpdates(batch, language: language, error: claudeError)
                    guard await save(updates, report: &report) else { return }
                    continue
                case .invalidResponse, .refused, .badRequest:
                    let updates = failureUpdates(batch, language: language, error: claudeError)
                    guard await save(updates, report: &report) else { return }
                    continue
                case .storage:
                    report.stoppedBy = claudeError
                    return
                }
            }

            var updates: [VariantUpdate] = []
            for (offset, candidate) in batch.enumerated() {
                switch outcomes[offset + 1] ?? .missing {
                case .ready(let result):
                    var variant = EntryVariant(result: result, sourceKey: candidate.sourceKey)
                    if let keepWord = candidate.keepWord {
                        variant.word = keepWord
                    }
                    let key = AttemptKey(entryID: candidate.entryID, languageID: language.id)
                    attempts[key] = nil
                    nextAttemptAt[key] = nil
                    updates.append(VariantUpdate(entryID: candidate.entryID, languageID: language.id, variant: variant))
                case .invalid(let reason):
                    let message = ClaudeError.invalidResponse(reason).userMessage
                    if let update = failureUpdate(candidate, language: language, error: .invalidResponse(reason), message: message) {
                        updates.append(update)
                    }
                case .missing:
                    let error = ClaudeError.invalidResponse(Self.missingItemReason)
                    if let update = failureUpdate(candidate, language: language, error: error, message: error.userMessage) {
                        updates.append(update)
                    }
                }
            }
            guard await save(updates, report: &report) else { return }
        }
    }

    /// Причина для елемента, якого немає у відповіді.
    static let missingItemReason = "немає елемента у відповіді"

    private func failureUpdates(_ batch: [Candidate], language: RenderingLanguage, error: ClaudeError) -> [VariantUpdate] {
        batch.compactMap { failureUpdate($0, language: language, error: error, message: error.userMessage) }
    }

    /// +1 спроба з backoff; після `maxAttempts` — `failed`. Наявний ready-варіант (`refresh`) не затирається.
    private func failureUpdate(
        _ candidate: Candidate,
        language: RenderingLanguage,
        error: ClaudeError,
        message: String
    ) -> VariantUpdate? {
        let key = AttemptKey(entryID: candidate.entryID, languageID: language.id)
        let count = (attempts[key] ?? 0) + 1
        attempts[key] = count
        nextAttemptAt[key] = dateProvider.now().addingTimeInterval(policy.delay(forAttempt: count, error: error))
        guard !candidate.hadReadyVariant else { return nil }
        let status: EntryStatus = count >= policy.maxAttempts ? .failed : .pending
        let lastError = logger?.redact(message) ?? RedactingLogger.redactAPIKeyPattern(message)
        let variant = EntryVariant.unfilled(status: status, sourceKey: candidate.sourceKey, lastError: lastError)
        return VariantUpdate(entryID: candidate.entryID, languageID: language.id, variant: variant)
    }

    /// Один атомарний save; лічильники звіту — за фактично застосованими оновленнями (`setVariants` пропускає
    /// записи, відредаговані чи видалені під час запиту). Збій збереження → `stoppedBy = .storage`, лог `error`,
    /// `false` (прохід зупиняється).
    private func save(_ updates: [VariantUpdate], report: inout VariantBackfillReport) async -> Bool {
        guard !updates.isEmpty else { return true }
        let applied: [Entry]
        do {
            applied = try await repository.setVariants(updates)
        } catch {
            let reason = (error as? RepositoryError)?.userMessage ?? error.localizedDescription
            let text = "не вдалося зберегти варіанти: \(reason)"
            let message = logger?.redact(text) ?? RedactingLogger.redactAPIKeyPattern(text)
            logger?.error("Variant save failed: count=\(updates.count) error=\(message)")
            report.stoppedBy = .storage(message)
            return false
        }
        let appliedIDs = Set(applied.map(\.id))
        for update in updates where appliedIDs.contains(update.entryID) {
            switch update.variant.status {
            case .ready:
                report.ready += 1
            case .pending:
                report.pending += 1
            case .failed:
                report.failed += 1
            }
        }
        return true
    }
}
