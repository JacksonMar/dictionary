import Foundation

/// Результат читання словника.
public struct LoadResult: Equatable, Sendable {
    public var file: DictionaryFile
    /// Не `nil`, якщо зіпсований файл було перенесено в Backups і повернуто порожній словник.
    public var recoveredBackupURL: URL?

    public init(file: DictionaryFile, recoveredBackupURL: URL? = nil) {
        self.file = file
        self.recoveredBackupURL = recoveredBackupURL
    }
}
