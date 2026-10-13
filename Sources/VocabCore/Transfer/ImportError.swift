import Foundation

/// Помилки імпорту рівня файлу або збереження. Будь-яка з них означає, що словник **не змінено**.
public enum ImportError: Error, Equatable {
    /// 0 байтів або лише пробільні символи.
    case emptyFile
    /// Не JSON або верхній рівень — не об'єкт.
    case notJSON
    /// Немає `schemaVersion` або це не ціле число.
    case missingSchemaVersion
    /// `schemaVersion` не підтримується (підтримується лише `DictionaryFile.currentSchemaVersion`).
    case unsupportedSchemaVersion(Int)
    /// Немає `entries` або це не масив.
    case missingEntries
    /// Не вдалося прочитати вибраний файл.
    case readFailed(String)
    /// Не вдалося створити резервну копію перед заміною.
    case backupFailed(String)
    /// Не вдалося зберегти словник (або словник ще не завантажено).
    case storage(String)
}

extension ImportError {
    private static let untouched = "Словник не змінено."

    /// Україномовний текст для UI.
    public var userMessage: String {
        switch self {
        case .emptyFile:
            return "Файл порожній. \(Self.untouched)"
        case .notJSON:
            return "Файл не є словником у форматі JSON. \(Self.untouched)"
        case .missingSchemaVersion:
            return "У файлі немає коректного поля schemaVersion — це не файл словника. \(Self.untouched)"
        case .unsupportedSchemaVersion(let version):
            return "Непідтримувана версія схеми файлу (\(version)); підтримується версія "
                + "\(DictionaryFile.currentSchemaVersion). \(Self.untouched)"
        case .missingEntries:
            return "У файлі немає списку записів (entries). \(Self.untouched)"
        case .readFailed(let reason):
            return "Не вдалося прочитати файл: \(reason). \(Self.untouched)"
        case .backupFailed(let reason):
            return "Не вдалося створити резервну копію поточного словника (\(reason)). \(Self.untouched)"
        case .storage(let reason):
            return "\(reason). \(Self.untouched)"
        }
    }
}
