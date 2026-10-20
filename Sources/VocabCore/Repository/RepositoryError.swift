import Foundation

/// Помилки репозиторію словника.
public enum RepositoryError: Error, Equatable {
    /// Запис з тим самим ключем (`languagePair`, `TextNormalizer.key(word)`) уже існує.
    case duplicate(Entry)
    case notFound(UUID)
    /// Мутація до успішного `load()`.
    case notLoaded
    /// Невдалий запис на диск; стан репозиторію не змінено.
    case storage(String)
}

extension RepositoryError {
    /// Опис для UI поточною мовою інтерфейсу (`L10n.current`).
    public var userMessage: String {
        userMessage(in: L10n.current)
    }

    public func userMessage(in language: AppLanguage) -> String {
        switch self {
        case .duplicate(let entry):
            return L10n.text(.repositoryDuplicate, ["word": entry.word], language: language)
        case .notFound:
            return L10n.text(.repositoryNotFound, language: language)
        case .notLoaded:
            return L10n.text(.repositoryNotLoaded, language: language)
        case .storage(let reason):
            return reason
        }
    }
}
