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
    /// Текст для UI поточною мовою інтерфейсу (`L10n.current`).
    public var userMessage: String {
        userMessage(in: L10n.current)
    }

    /// Речення про причину + «Словник не змінено.».
    public func userMessage(in language: AppLanguage) -> String {
        let text: String
        switch self {
        case .emptyFile:
            text = L10n.text(.importEmptyFile, language: language)
        case .notJSON:
            text = L10n.text(.importNotJSON, language: language)
        case .missingSchemaVersion:
            text = L10n.text(.importMissingSchemaVersion, language: language)
        case .unsupportedSchemaVersion(let version):
            text = L10n.text(
                .importUnsupportedSchema,
                ["version": String(version), "supported": String(DictionaryFile.currentSchemaVersion)],
                language: language
            )
        case .missingEntries:
            text = L10n.text(.importMissingEntries, language: language)
        case .readFailed(let reason):
            text = L10n.text(.importReadFailed, ["reason": Self.clause(reason)], language: language)
        case .backupFailed(let reason):
            text = L10n.text(.importBackupFailed, ["reason": Self.clause(reason)], language: language)
        case .storage(let reason):
            text = L10n.text(.importStorage, ["reason": Self.clause(reason)], language: language)
        }
        return text + " " + L10n.text(.importUntouched, language: language)
    }

    /// Причина без крапки в кінці: інакше вийде «…file.. Словник не змінено.».
    private static func clause(_ reason: String) -> String {
        FileErrorText.trimmingTrailingPeriods(reason)
    }
}
