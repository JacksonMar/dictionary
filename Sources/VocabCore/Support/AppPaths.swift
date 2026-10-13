import Foundation

/// Шляхи до даних застосунку. Усі ін'єктуються; тести використовують тимчасовий каталог.
public struct AppPaths: Equatable, Sendable {
    public static let folderName = "VocabApp"

    /// `…/Application Support/VocabApp/`.
    public let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    /// `…/VocabApp/dictionary.json`.
    public var dictionaryURL: URL {
        applicationSupportDirectory.appendingPathComponent("dictionary.json", isDirectory: false)
    }

    /// `…/VocabApp/Backups/`.
    public var backupsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Backups", isDirectory: true)
    }

    /// `~/Library/Application Support/VocabApp/` (на macOS).
    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return AppPaths(applicationSupportDirectory: base.appendingPathComponent(folderName, isDirectory: true))
    }
}
