import Foundation

/// Серіалізація словника для експорту (§10): `DictionaryFile(schemaVersion: 1, exportedAt: now, entries)`,
/// ті самі налаштування енкодера, що й для `dictionary.json`.
public enum DictionaryExporter {
    /// Помилка кодування → `StorageError.writeFailed`.
    public static func exportData(entries: [Entry], now: Date) throws -> Data {
        let file = DictionaryFile(
            schemaVersion: DictionaryFile.currentSchemaVersion,
            exportedAt: now,
            entries: entries
        )
        do {
            return try JSONCoding.makeEncoder().encode(file)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
    }
}
