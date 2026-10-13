import Foundation

/// Єдине джерело істини для записів словника. Кожна мутація: змінити копію → `store.save` →
/// лише після успіху замінити стан і розіслати знімок підписникам.
public actor DictionaryRepository {
    private let store: DictionaryStoring
    private let dateProvider: DateProvider
    private var entries: [Entry] = []
    private var isLoaded = false
    private var continuations: [UUID: AsyncStream<[Entry]>.Continuation] = [:]

    public init(store: DictionaryStoring, dateProvider: DateProvider) {
        self.store = store
        self.dateProvider = dateProvider
    }

    /// Читає словник зі сховища (на старті). Помилки сховища (`StorageError`) передаються нагору.
    public func load() throws -> LoadResult {
        let result = try store.load()
        entries = result.file.entries
        isLoaded = true
        broadcast()
        return result
    }

    public func allEntries() -> [Entry] {
        entries
    }

    public func entry(id: UUID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Запис з тим самим ключем дедуплікації в тій самій мовній парі (D8).
    public func findDuplicate(of word: String, languagePair: String, excluding: UUID? = nil) -> Entry? {
        let key = TextNormalizer.key(word)
        return entries.first { entry in
            entry.id != excluding
                && entry.languagePair == languagePair
                && TextNormalizer.key(entry.word) == key
        }
    }

    /// Додає запис. Перевірка дубля і вставка — в одному виклику актора.
    @discardableResult
    public func add(_ draft: EntryDraft) throws -> Entry {
        try ensureLoaded()
        if let existing = findDuplicate(of: draft.word, languagePair: draft.languagePair) {
            throw RepositoryError.duplicate(existing)
        }
        let now = dateProvider.now()
        let entry = Entry(
            id: UUID(),
            languagePair: draft.languagePair,
            word: draft.word,
            lemma: draft.lemma,
            partOfSpeech: draft.partOfSpeech,
            transcription: draft.transcription,
            translations: draft.translations,
            example: draft.example,
            status: draft.status,
            lastError: nil,
            createdAt: now,
            updatedAt: now
        )
        try commit(entries + [entry])
        return entry
    }

    /// Оновлює запис за `id`; `updatedAt` = зараз, `createdAt` зберігається з поточного стану.
    @discardableResult
    public func update(_ entry: Entry) throws -> Entry {
        try ensureLoaded()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw RepositoryError.notFound(entry.id)
        }
        if let existing = findDuplicate(of: entry.word, languagePair: entry.languagePair, excluding: entry.id) {
            throw RepositoryError.duplicate(existing)
        }
        var updated = entry
        updated.createdAt = entries[index].createdAt
        updated.updatedAt = dateProvider.now()
        var newEntries = entries
        newEntries[index] = updated
        try commit(newEntries)
        return updated
    }

    public func delete(id: UUID) throws {
        try ensureLoaded()
        guard entries.contains(where: { $0.id == id }) else {
            throw RepositoryError.notFound(id)
        }
        try commit(entries.filter { $0.id != id })
    }

    /// Повна заміна вмісту (імпорт). Один атомарний запис.
    public func replaceAll(_ newEntries: [Entry]) throws {
        try ensureLoaded()
        try commit(newEntries)
    }

    /// Знімок записів для експорту; до успішного `load()` → `RepositoryError.notLoaded`
    /// (щоб не експортувати порожній словник замість незавантаженого).
    public func loadedEntries() throws -> [Entry] {
        try ensureLoaded()
        return entries
    }

    /// Імпорт у режимі «Об'єднати» (§10, D1): `ImportMerger.merge` з поточним станом і **один** атомарний запис —
    /// в одному виклику актора, тож паралельні зміни (черга, Services) не губляться між читанням і записом.
    /// Якщо нічого не додано й не оновлено — запису на диск нема.
    public func mergeImported(_ imported: [Entry]) throws -> ImportReport {
        try ensureLoaded()
        let merged = ImportMerger.merge(local: entries, imported: imported)
        if merged.report.added > 0 || merged.report.updated > 0 {
            try commit(merged.entries)
        }
        return merged.report
    }

    /// Повна заміна вмісту з підготовчим кроком (імпорт «Замінити»): `beforeSave` (бекап поточного файлу)
    /// виконується в тому ж виклику актора безпосередньо перед записом. Помилка `beforeSave` передається
    /// нагору без змін, і нічого не записується.
    public func replaceAll(_ newEntries: [Entry], beforeSave: @Sendable () throws -> Void) throws {
        try ensureLoaded()
        try beforeSave()
        try commit(newEntries)
    }

    /// Потік знімків: одразу поточний стан, далі — після кожної успішної зміни.
    /// Буферизується лише найновіший знімок.
    public func changes() -> AsyncStream<[Entry]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(entries)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    // MARK: - Private

    private func ensureLoaded() throws {
        guard isLoaded else { throw RepositoryError.notLoaded }
    }

    private func commit(_ newEntries: [Entry]) throws {
        let file = DictionaryFile(
            schemaVersion: DictionaryFile.currentSchemaVersion,
            exportedAt: nil,
            entries: newEntries
        )
        do {
            try store.save(file)
        } catch let error as StorageError {
            throw RepositoryError.storage(error.userMessage)
        } catch {
            throw RepositoryError.storage(error.localizedDescription)
        }
        entries = newEntries
        broadcast()
    }

    private func broadcast() {
        for continuation in continuations.values {
            continuation.yield(entries)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}
