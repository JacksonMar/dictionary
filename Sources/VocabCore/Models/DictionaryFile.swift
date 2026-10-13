import Foundation

/// Кореневий об'єкт `dictionary.json` (і файлу експорту).
public struct DictionaryFile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Час останнього збереження/експорту (D4). При декодуванні необов'язковий.
    public var exportedAt: Date?
    public var entries: [Entry]

    public init(schemaVersion: Int = DictionaryFile.currentSchemaVersion, exportedAt: Date? = nil, entries: [Entry]) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.entries = entries
    }

    /// Порожній словник поточної версії схеми.
    public static var empty: DictionaryFile {
        DictionaryFile(schemaVersion: currentSchemaVersion, exportedAt: nil, entries: [])
    }
}
