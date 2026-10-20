import Foundation

/// Помилки сховища словника. Повідомлення не містять вмісту файлу чи секретів.
public enum StorageError: Error, Equatable {
    case readFailed(String)
    case writeFailed(String)
    case unsupportedSchemaVersion(Int)
    case backupFailed(String)
}

extension StorageError {
    /// Опис для UI поточною мовою інтерфейсу (`L10n.current`).
    public var userMessage: String {
        userMessage(in: L10n.current)
    }

    public func userMessage(in language: AppLanguage) -> String {
        switch self {
        case .readFailed(let reason):
            return L10n.text(.storageReadFailed, ["reason": reason], language: language)
        case .writeFailed(let reason):
            return L10n.text(.storageWriteFailed, ["reason": reason], language: language)
        case .unsupportedSchemaVersion(let version):
            return L10n.text(.storageUnsupportedSchema, ["version": String(version)], language: language)
        case .backupFailed(let reason):
            return L10n.text(.storageBackupFailed, ["reason": reason], language: language)
        }
    }
}
