import Foundation
import VocabCore

/// Міст між `DictionaryRepository` та SwiftUI. Усі `@Published` змінюються лише на головному акторі.
@MainActor
final class AppModel: ObservableObject {
    /// Записи для показу (найновіші зверху).
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoaded = false
    /// Фатальна помилка завантаження (напр. новіша версія схеми) — словник недоступний.
    @Published var loadError: String?
    /// Попередження після завантаження (напр. зіпсований файл перенесено в Backups).
    @Published var loadWarning: String?
    /// Помилка останньої операції користувача (додавання/редагування/видалення).
    @Published var operationError: String?

    let languagePairID: String
    private let repository: DictionaryRepository
    private var changesTask: Task<Void, Never>?

    init(repository: DictionaryRepository, languagePairID: String = LanguagePairRegistry.defaultPairID) {
        self.repository = repository
        self.languagePairID = languagePairID
    }

    /// Завантажує словник і підписується на зміни репозиторію.
    func load() async {
        do {
            let result = try await repository.load()
            loadError = nil
            if let backupURL = result.recoveredBackupURL {
                loadWarning = "Файл словника був пошкоджений. Його перенесено в \(backupURL.path), "
                    + "розпочато порожній словник."
            }
            isLoaded = true
            apply(await repository.allEntries())
            subscribeToChanges()
        } catch let error as StorageError {
            loadError = error.userMessage
        } catch {
            loadError = "Не вдалося завантажити словник: \(error.localizedDescription)"
        }
    }

    /// Ручне додавання (D14, M1): запис зі статусом із чернетки (`ready` у формі), перевірка дубля.
    /// Повертає створений запис або `nil` (тоді `operationError` містить причину).
    @discardableResult
    func addManual(_ draft: EntryDraft) async -> Entry? {
        var cleaned = draft
        cleaned.word = TextNormalizer.clean(draft.word)
        if let message = Self.validationError(word: cleaned.word, status: cleaned.status, translations: cleaned.translations) {
            operationError = message
            return nil
        }
        do {
            let entry = try await repository.add(cleaned)
            operationError = nil
            apply(await repository.allEntries())
            return entry
        } catch {
            operationError = Self.message(for: error)
            return nil
        }
    }

    /// Редагування. Повертає оновлений запис або `nil` (тоді `operationError` містить причину).
    @discardableResult
    func update(_ entry: Entry) async -> Entry? {
        var cleaned = entry
        cleaned.word = TextNormalizer.clean(entry.word)
        if let message = Self.validationError(word: cleaned.word, status: cleaned.status, translations: cleaned.translations) {
            operationError = message
            return nil
        }
        do {
            let updated = try await repository.update(cleaned)
            operationError = nil
            apply(await repository.allEntries())
            return updated
        } catch {
            operationError = Self.message(for: error)
            return nil
        }
    }

    /// Видалення. Повертає `true` при успіху.
    @discardableResult
    func delete(id: UUID) async -> Bool {
        do {
            try await repository.delete(id: id)
            operationError = nil
            apply(await repository.allEntries())
            return true
        } catch {
            operationError = Self.message(for: error)
            return false
        }
    }

    // MARK: - Private

    private func subscribeToChanges() {
        changesTask?.cancel()
        let repository = self.repository
        changesTask = Task { @MainActor [weak self] in
            let stream = await repository.changes()
            for await snapshot in stream {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: [Entry]) {
        entries = snapshot.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.word.localizedCaseInsensitiveCompare(rhs.word) == .orderedAscending
        }
    }

    static func validationError(word: String, status: EntryStatus, translations: [String]) -> String? {
        if word.isEmpty {
            return "Введіть слово або фразу"
        }
        // `ready` без перекладів не пройде валідацію імпорту (§10), тому не дозволяємо створити такий запис.
        if status == .ready && translations.isEmpty {
            return "Додайте хоча б один переклад"
        }
        return nil
    }

    static func message(for error: Error) -> String {
        if let repositoryError = error as? RepositoryError {
            return repositoryError.userMessage
        }
        if let storageError = error as? StorageError {
            return storageError.userMessage
        }
        return error.localizedDescription
    }
}
