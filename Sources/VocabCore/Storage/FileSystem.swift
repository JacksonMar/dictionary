import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Абстракція файлової системи (для ін'єкції збоїв у тестах).
public protocol FileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
    /// Звичайний (не атомарний) запис — використовується для тимчасового файлу.
    func writeData(_ data: Data, to url: URL) throws
    /// Атомарна заміна `target` вмістом `temp` (той самий том). Якщо `target` не існує — `temp` просто
    /// перейменовується в `target`.
    func replaceItem(at target: URL, withItemAt temp: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    /// Створює каталог разом з проміжними.
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
}

/// Реальна файлова система через `FileManager.default`.
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    /// Атомарна заміна через `rename(2)`: однаково на macOS і Linux, гарантовано атомарна в межах одного тому
    /// (дозволена §5 альтернатива `FileManager.replaceItemAt`). Відсутня ціль — не помилка: `rename(2)`
    /// створює її (POSIX), тож окрема гілка `moveItem` не потрібна.
    public func replaceItem(at target: URL, withItemAt temp: URL) throws {
        let result = temp.withUnsafeFileSystemRepresentation { tempPath -> Int32 in
            target.withUnsafeFileSystemRepresentation { targetPath -> Int32 in
                guard let tempPath, let targetPath else { return -1 }
                return rename(tempPath, targetPath)
            }
        }
        if result != 0 {
            let code = errno
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "rename failed: \(String(cString: strerror(code)))",
            ])
        }
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}
