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

    /// `~/Library/Application Support/VocabApp/` (на macOS); на iOS — `<контейнер застосунку>/Library/Application
    /// Support/VocabApp/` (IOS_PLAN DI6: власний контейнер, не App Group).
    public static func standard(fileManager: FileManager = .default) -> AppPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectory(fileManager: fileManager)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return AppPaths(applicationSupportDirectory: base.appendingPathComponent(folderName, isDirectory: true))
    }

    /// Домашній каталог для запасного шляху. `homeDirectoryForCurrentUser` недоступний на iOS (IOS_PLAN §3.1);
    /// там `NSHomeDirectory()` — корінь контейнера застосунку. На macOS поведінка без змін.
    private static func homeDirectory(fileManager: FileManager) -> URL {
        #if os(macOS) || os(Linux)
        return fileManager.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }
}
