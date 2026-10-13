import Foundation

/// Помилки сховища словника. Повідомлення не містять вмісту файлу чи секретів.
public enum StorageError: Error, Equatable {
    case readFailed(String)
    case writeFailed(String)
    case unsupportedSchemaVersion(Int)
    case backupFailed(String)
}

extension StorageError {
    /// Україномовний опис для UI.
    public var userMessage: String {
        switch self {
        case .readFailed(let reason):
            return "Не вдалося прочитати словник: \(reason)"
        case .writeFailed(let reason):
            return "Не вдалося зберегти словник: \(reason)"
        case .unsupportedSchemaVersion(let version):
            return "Файл словника має новішу версію схеми (\(version)), ніж підтримує застосунок. "
                + "Оновіть застосунок; файл не змінено."
        case .backupFailed(let reason):
            return "Не вдалося створити резервну копію: \(reason)"
        }
    }
}
