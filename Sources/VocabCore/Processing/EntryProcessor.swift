import Foundation

/// Результат обробки одного запису.
public enum ProcessingResult: Equatable, Sendable {
    case ready(Entry)
    case pending(Entry, ClaudeError)
    case failed(Entry, ClaudeError)
    /// Запис уже обробляється (`inFlight`) або вже не `pending`/`failed` — нічого не зроблено.
    case skipped(Entry)
    /// Запис видалено.
    case notFound(UUID)
}

/// Обробляє ОДИН запис: lookup → оновлення запису в репозиторії (§8.3).
/// Не тримає стану; лічильник спроб і backoff — у `PendingQueueProcessor`.
public final class EntryProcessor: Sendable {
    public static let unknownPairMessage = "Невідома мовна пара"

    private let repository: DictionaryRepository
    private let lookup: WordLookupService
    private let registry: LanguagePairRegistry
    private let dateProvider: DateProvider

    public init(
        repository: DictionaryRepository,
        lookup: WordLookupService,
        registry: LanguagePairRegistry,
        dateProvider: DateProvider
    ) {
        self.repository = repository
        self.lookup = lookup
        self.registry = registry
        self.dateProvider = dateProvider
    }

    /// - Parameters:
    ///   - attempts: кількість попередніх зарахованих невдалих спроб (для `ErrorDisposition`).
    ///   - maxAttempts: ліміт спроб `RetryPolicy`.
    public func process(
        entryID: UUID,
        attempts: Int,
        maxAttempts: Int = RetryPolicy.defaultMaxAttempts
    ) async -> ProcessingResult {
        guard let entry = await repository.entry(id: entryID) else {
            return .notFound(entryID)
        }
        guard entry.status != .ready else {
            return .skipped(entry)
        }

        guard let pair = registry.pair(id: entry.languagePair) else {
            // Окремого випадку в `ClaudeError` нема; постійна помилка → `failed`, текст — «Невідома мовна пара».
            let error = ClaudeError.badRequest(status: 0, message: Self.unknownPairMessage)
            let updated = await store(entry, status: .failed, lastError: Self.unknownPairMessage)
            return .failed(updated, error)
        }

        let text = TextNormalizer.clean(entry.word)
        let kind = SelectionValidator.kind(of: text)
        do {
            let result = try await lookup.lookup(text: text, kind: kind, pair: pair)
            return await applySuccess(result, entryID: entryID)
        } catch {
            let claudeError = ClaudeError.from(transportError: error)
            let disposition = ErrorDisposition.for(claudeError, attempts: attempts, maxAttempts: maxAttempts)
            // Запис міг змінитися під час запиту — беремо поточну версію.
            guard let current = await repository.entry(id: entryID) else {
                return .notFound(entryID)
            }
            guard current.status != .ready else {
                return .skipped(current)
            }
            let updated = await store(current, status: disposition.status, lastError: claudeError.userMessage)
            switch disposition.status {
            case .failed:
                return .failed(updated, claudeError)
            case .pending, .ready:
                return .pending(updated, claudeError)
            }
        }
    }

    // MARK: - Private

    private func applySuccess(_ result: LookupResult, entryID: UUID) async -> ProcessingResult {
        // Запис міг бути видалений або заповнений вручну, поки йшов запит.
        guard var entry = await repository.entry(id: entryID) else {
            return .notFound(entryID)
        }
        guard entry.status != .ready else {
            return .skipped(entry)
        }
        // D5: `word` від моделі — лише якщо ключі збігаються; інакше лишається виділення.
        if TextNormalizer.key(result.word) == TextNormalizer.key(entry.word) {
            entry.word = result.word
        }
        entry.lemma = result.lemma
        entry.partOfSpeech = result.partOfSpeech
        entry.transcription = result.transcription.isEmpty ? nil : result.transcription
        entry.translations = result.translations
        entry.example = result.example
        entry.status = .ready
        entry.lastError = nil
        do {
            return .ready(try await repository.update(entry))
        } catch {
            // Не вдалося зберегти (диск/дубль) — запис лишається pending, наступна спроба пізніше.
            let message = (error as? RepositoryError)?.userMessage ?? error.localizedDescription
            let current = await repository.entry(id: entryID) ?? entry
            return .pending(current, .transport(message))
        }
    }

    /// Зберігає статус і `lastError`; при помилці збереження повертає запис без змін.
    private func store(_ entry: Entry, status: EntryStatus, lastError: String) async -> Entry {
        var updated = entry
        updated.status = status
        updated.lastError = lastError
        do {
            return try await repository.update(updated)
        } catch {
            return entry
        }
    }
}
