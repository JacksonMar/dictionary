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
    /// M7 (D27): після відповіді Claude виявилось, що поняття вже є в словнику (`existing`); оброблюваний
    /// pending-запис `removedID` видалено.
    case duplicate(existing: Entry, removedID: UUID)
}

/// Обробляє ОДИН запис: lookup → оновлення запису в репозиторії (§8.3).
/// Не тримає стану; лічильник спроб і backoff — у `PendingQueueProcessor`.
public final class EntryProcessor: Sendable {
    public static let unknownPairMessage = "Невідома мовна пара"

    private let repository: DictionaryRepository
    private let lookup: WordLookupService
    private let registry: LanguagePairRegistry
    private let dateProvider: DateProvider
    private let logger: RedactingLogger?

    /// - Parameter logger: куди логувати невдалі збереження (повідомлення редагуються); `nil` — не логувати.
    public init(
        repository: DictionaryRepository,
        lookup: WordLookupService,
        registry: LanguagePairRegistry,
        dateProvider: DateProvider,
        logger: RedactingLogger? = nil
    ) {
        self.repository = repository
        self.lookup = lookup
        self.registry = registry
        self.dateProvider = dateProvider
        self.logger = logger
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
            return await persist(entry, error: error, status: .failed, lastError: Self.unknownPairMessage)
        }

        let text = TextNormalizer.clean(entry.word)
        let kind = SelectionValidator.kind(of: text)
        do {
            let result = try await lookup.lookup(text: text, kind: kind, pair: pair)
            return await applySuccess(result, entryID: entryID, pair: pair)
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
            return await persist(current, error: claudeError, status: disposition.status, lastError: claudeError.userMessage)
        }
    }

    // MARK: - Private

    private func applySuccess(_ result: LookupResult, entryID: UUID, pair: LanguagePair) async -> ProcessingResult {
        // Запис міг бути видалений або заповнений вручну, поки йшов запит.
        guard var entry = await repository.entry(id: entryID) else {
            return .notFound(entryID)
        }
        guard entry.status != .ready else {
            return .skipped(entry)
        }
        // До відповіді `word` — очищене виділення.
        let selectionText = TextNormalizer.clean(entry.word)
        let selectionKey = TextNormalizer.key(entry.word)

        // M7 (§8.3): мова виділення — мова відображення (напр. італійська)?
        var selectedVariantWord: String?
        if let detected = result.sourceLanguage,
           detected != pair.sourceLanguageCode,
           pair.rendering(id: detected) != nil,
           let selected = result.variants[detected] {
            // Верхній рівень — англійський відповідник (без D5-перевірки); виділене слово — у варіанті (D5 для
            // мови виділення: слово моделі, якщо ключі збігаються, інакше виділення).
            entry.word = result.word
            entry.sourceLanguage = detected
            selectedVariantWord = TextNormalizer.key(selected.word) == selectionKey ? selected.word : selectionText
        } else {
            // D5: `word` від моделі — лише якщо ключі збігаються; інакше лишається виділення.
            if TextNormalizer.key(result.word) == selectionKey {
                entry.word = result.word
            }
            entry.sourceLanguage = nil
        }
        entry.lemma = result.lemma
        entry.partOfSpeech = result.partOfSpeech
        entry.transcription = result.transcription.isEmpty ? nil : result.transcription
        entry.translations = result.translations
        entry.example = result.example
        entry.status = .ready
        entry.lastError = nil

        // Пара без renderings — як у M2: варіанти не чіпаються.
        let hasRenderings = !pair.renderings.isEmpty
        if hasRenderings {
            entry.variants = Self.variants(
                from: result,
                pair: pair,
                sourceKey: TextNormalizer.key(entry.word),
                sourceLanguage: entry.sourceLanguage,
                selectedWord: selectedVariantWord
            )
        }

        // D27: перевірка дубля після відповіді — за всіма ключами нового запису.
        if let existing = await repository.findDuplicate(
            keys: entry.dedupKeys(),
            languagePair: entry.languagePair,
            excluding: entry.id
        ) {
            return await resolveDuplicate(entry, existing: existing, pair: pair)
        }

        do {
            return .ready(try await repository.update(entry, replacingVariants: hasRenderings))
        } catch {
            // Не вдалося зберегти (диск/дубль): у репозиторії лишився попередній стан запису.
            let message = saveFailureMessage(error)
            logger?.error("Entry save failed: id=\(entryID.uuidString) status=ready error=\(message)")
            guard let current = await repository.entry(id: entryID) else {
                return .notFound(entryID)
            }
            return resultForUnsavedEntry(current, message: message)
        }
    }

    /// Варіанти з комбінованої відповіді: валідний → `ready`, відсутній/невалідний → `pending` (доповниться
    /// пакетно, повтору нема — D28). Варіант мови виділення отримує `selectedWord`.
    static func variants(
        from result: LookupResult,
        pair: LanguagePair,
        sourceKey: String,
        sourceLanguage: String?,
        selectedWord: String?
    ) -> [String: EntryVariant]? {
        var variants: [String: EntryVariant] = [:]
        for rendering in pair.renderings {
            if let variantResult = result.variants[rendering.id] {
                var variant = EntryVariant(result: variantResult, sourceKey: sourceKey)
                if rendering.id == sourceLanguage, let selectedWord {
                    variant.word = selectedWord
                }
                variants[rendering.id] = variant
            } else {
                variants[rendering.id] = .unfilled(status: .pending, sourceKey: sourceKey)
            }
        }
        return variants.isEmpty ? nil : variants
    }

    /// D27: поточний pending-запис видаляється; якщо `existing` — те саме поняття (той самий англійський ключ),
    /// його не-ready варіанти заповнюються з цієї ж відповіді (без нових запитів).
    private func resolveDuplicate(_ entry: Entry, existing: Entry, pair: LanguagePair) async -> ProcessingResult {
        do {
            try await repository.delete(id: entry.id)
        } catch RepositoryError.notFound {
            // Уже видалено паралельно — результат той самий.
        } catch {
            let message = saveFailureMessage(error)
            logger?.error("Duplicate entry removal failed: id=\(entry.id.uuidString) error=\(message)")
            guard let current = await repository.entry(id: entry.id) else {
                return .notFound(entry.id)
            }
            return resultForUnsavedEntry(current, message: message)
        }

        var resolved = existing
        let existingKey = TextNormalizer.key(existing.word)
        if existingKey == TextNormalizer.key(entry.word) {
            var updates: [VariantUpdate] = []
            for rendering in pair.renderings {
                guard rendering.id != existing.sourceLanguage,
                      existing.readyVariant(rendering.id) == nil,
                      entry.readyVariant(rendering.id) != nil,
                      var variant = entry.variants?[rendering.id] else {
                    continue
                }
                variant.sourceKey = existingKey
                updates.append(VariantUpdate(entryID: existing.id, languageID: rendering.id, variant: variant))
            }
            if !updates.isEmpty {
                do {
                    if let updated = try await repository.setVariants(updates).first(where: { $0.id == existing.id }) {
                        resolved = updated
                    }
                } catch {
                    let message = saveFailureMessage(error)
                    logger?.error("Variant save failed: id=\(existing.id.uuidString) error=\(message)")
                }
            }
        }
        if let current = await repository.entry(id: existing.id) {
            resolved = current
        }
        return .duplicate(existing: resolved, removedID: entry.id)
    }

    /// Зберігає статус і `lastError` і повертає результат, що відповідає **збереженому** стану.
    /// Якщо збереження не вдалося:
    /// - збережений `failed` (повтор failed-запису) → `.failed(збережений, .storage(…))`;
    /// - збережений `ready` (заповнено паралельно) → `.skipped(збережений)`;
    /// - збережений `pending` і бажаний `pending` (втрачено лише `lastError`) → `.pending(збережений, error)`
    ///   з початковою помилкою, тож лічильник спроб поводиться як завжди;
    /// - збережений `pending`, а бажаний `failed` → `.pending(збережений, .storage(…))`: черга рахує спробу
    ///   з backoff і після `maxAttempts` перестає авто-повторювати запис (див. `PendingQueueProcessor`).
    private func persist(_ entry: Entry, error: ClaudeError, status: EntryStatus, lastError: String) async -> ProcessingResult {
        var updated = entry
        updated.status = status
        updated.lastError = lastError
        do {
            let saved = try await repository.update(updated)
            switch saved.status {
            case .failed:
                return .failed(saved, error)
            case .pending, .ready:
                return .pending(saved, error)
            }
        } catch let saveError {
            let message = saveFailureMessage(saveError)
            logger?.error(
                "Entry save failed: id=\(entry.id.uuidString) status=\(status.rawValue) error=\(message)"
            )
            guard let current = await repository.entry(id: entry.id) else {
                return .notFound(entry.id)
            }
            if current.status == .pending && status == .pending {
                return .pending(current, error)
            }
            return resultForUnsavedEntry(current, message: message)
        }
    }

    /// Результат за збереженим станом запису, коли нові дані записати не вдалося.
    private func resultForUnsavedEntry(_ current: Entry, message: String) -> ProcessingResult {
        // Помилка диска, не мережі: `.storage` (диспозиція — як у `.transport`, §8.1).
        let error = ClaudeError.storage(message)
        switch current.status {
        case .ready:
            return .skipped(current)
        case .failed:
            return .failed(current, error)
        case .pending:
            return .pending(current, error)
        }
    }

    private func saveFailureMessage(_ error: Error) -> String {
        let message = (error as? RepositoryError)?.userMessage ?? error.localizedDescription
        let text = "не вдалося зберегти запис: \(message)"
        // Текст іде в результат/UI — та сама редакція, що й у логах (відомі секрети + шаблон `sk-ant-`).
        return logger?.redact(text) ?? RedactingLogger.redactAPIKeyPattern(text)
    }
}
