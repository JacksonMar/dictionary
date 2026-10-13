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
    /// Україномовний опис для UI.
    public var userMessage: String {
        switch self {
        case .duplicate(let entry):
            return "«\(entry.word)» вже є в словнику"
        case .notFound:
            return "Запис не знайдено"
        case .notLoaded:
            return "Словник ще не завантажено"
        case .storage(let reason):
            return reason
        }
    }
}
