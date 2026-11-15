import Foundation

/// Результат додавання слова через Claude (Services або «Заповнити через Claude»).
public enum AddWordOutcome: Equatable, Sendable {
    /// Запис `ready`.
    case added(Entry)
    /// Уже є (будь-який статус).
    case duplicate(Entry)
    /// Збережено як `pending`; `nil` — запис уже обробляється (`ProcessingResult.skipped`).
    case queued(Entry, ClaudeError?)
    /// Збережено як `failed`.
    case failed(Entry, ClaudeError)
    /// Нічого не збережено.
    case rejected(SelectionRejection)
    case storageError(String)
}

/// Валідація → збереження як `pending` (до запиту, щоб нічого не загубити) → обробка через чергу (§9).
public final class AddWordUseCase: Sendable {
    private let repository: DictionaryRepository
    private let processor: PendingQueueProcessor
    private let settings: SettingsStore
    private let registry: LanguagePairRegistry

    public init(
        repository: DictionaryRepository,
        processor: PendingQueueProcessor,
        settings: SettingsStore,
        registry: LanguagePairRegistry
    ) {
        self.repository = repository
        self.processor = processor
        self.settings = settings
        self.registry = registry
    }

    public func execute(rawText: String?) async -> AddWordOutcome {
        await execute(rawText: rawText, sourceLanguageHint: nil)
    }

    /// I2a (DI13): `sourceLanguageHint` — мова, яку вказав користувач (напр. мова мовлення). Код поза
    /// `pair.allowedSourceLanguages` відкидається; інакше зберігається в `Entry.languageHint` pending-запису
    /// і передається Claude однією фразою в тому самому промті. Дедуплікація до запиту — без змін (D26).
    public func execute(rawText: String?, sourceLanguageHint: String?) async -> AddWordOutcome {
        let cleaned: CleanedSelection
        switch SelectionValidator.validate(rawText) {
        case .rejected(let rejection):
            return .rejected(rejection)
        case .valid(let selection):
            cleaned = selection
        }

        // Невідома (незареєстрована) пара в налаштуваннях → пара за замовчуванням.
        let configuredPair = settings.languagePairID
        let pairID = registry.pair(id: configuredPair) != nil ? configuredPair : LanguagePairRegistry.defaultPairID

        let hint = Self.acceptedHint(sourceLanguageHint, pair: registry.pair(id: pairID))

        let entry: Entry
        do {
            entry = try await repository.add(
                EntryDraft(word: cleaned.text, languagePair: pairID, status: .pending, languageHint: hint)
            )
        } catch RepositoryError.duplicate(let existing) {
            return .duplicate(existing)
        } catch let error as RepositoryError {
            return .storageError(error.userMessage)
        } catch {
            return .storageError(error.localizedDescription)
        }

        switch await processor.retry(entryID: entry.id) {
        case .ready(let ready):
            return .added(ready)
        case .pending(let pending, let error):
            return .queued(pending, error)
        case .failed(let failed, let error):
            return .failed(failed, error)
        case .skipped(let current):
            // D17: запис щойно підхопив паралельний `processAll`.
            return current.status == .ready ? .added(current) : .queued(current, nil)
        case .notFound:
            return .storageError(RepositoryError.notFound(entry.id).userMessage)
        case .duplicate(let existing, _):
            // M7 (D27): дубль виявлено після відповіді (напр. італійське виділення = наявний запис).
            return .duplicate(existing)
        }
    }

    /// Підказка, якщо вона (після trim) — один із `pair.allowedSourceLanguages`; інакше `nil`.
    static func acceptedHint(_ hint: String?, pair: LanguagePair?) -> String? {
        guard let pair,
              let code = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              pair.allowedSourceLanguages.contains(code) else {
            return nil
        }
        return code
    }
}
