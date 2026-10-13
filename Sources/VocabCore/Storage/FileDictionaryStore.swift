import Foundation

/// Читання/запис словника.
public protocol DictionaryStoring: Sendable {
    var fileURL: URL { get }
    /// Читання; відсутній файл → порожній словник; зіпсований → перенесення в Backups і порожній словник;
    /// `schemaVersion` новіша за підтримувану → `StorageError.unsupportedSchemaVersion` (файл не змінюється).
    func load() throws -> LoadResult
    /// Атомарний запис; `exportedAt` встановлюється в поточний час.
    func save(_ file: DictionaryFile) throws
}

/// Сховище `dictionary.json` на диску з атомарним записом (тимчасовий файл у тому ж каталозі → заміна).
public final class FileDictionaryStore: DictionaryStoring, Sendable {
    public let fileURL: URL
    private let fileSystem: FileSystem
    private let dateProvider: DateProvider
    private let backups: BackupManager

    public init(
        fileURL: URL,
        fileSystem: FileSystem = LocalFileSystem(),
        dateProvider: DateProvider = SystemDateProvider(),
        backups: BackupManager
    ) {
        self.fileURL = fileURL
        self.fileSystem = fileSystem
        self.dateProvider = dateProvider
        self.backups = backups
    }

    public func load() throws -> LoadResult {
        guard fileSystem.fileExists(at: fileURL) else {
            return LoadResult(file: .empty, recoveredBackupURL: nil)
        }

        let data: Data
        do {
            data = try fileSystem.readData(at: fileURL)
        } catch {
            throw StorageError.readFailed(error.localizedDescription)
        }

        let decoder = JSONCoding.makeDecoder()
        // Спершу лише версія схеми: новіший формат не можна вважати зіпсованим (захист від даунгрейду).
        if let probe = try? decoder.decode(SchemaVersionProbe.self, from: data),
           probe.schemaVersion > DictionaryFile.currentSchemaVersion {
            throw StorageError.unsupportedSchemaVersion(probe.schemaVersion)
        }

        do {
            let file = try decoder.decode(DictionaryFile.self, from: data)
            return LoadResult(file: file, recoveredBackupURL: nil)
        } catch {
            // `makeBackup` кидає вже `StorageError.backupFailed`.
            let backupURL = try backups.makeBackup(of: fileURL, reason: .corrupted)
            return LoadResult(file: .empty, recoveredBackupURL: backupURL)
        }
    }

    public func save(_ file: DictionaryFile) throws {
        var stamped = file
        stamped.exportedAt = dateProvider.now()

        let data: Data
        do {
            data = try JSONCoding.makeEncoder().encode(stamped)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }
        try AtomicFileWriter.write(data, to: fileURL, fileSystem: fileSystem)
    }
}

/// Атомарний запис довільних даних: `<dir>/.<name>.<UUID>.tmp` → `replaceItem` (rename(2); ціль може не існувати).
/// При помилці тимчасовий файл видаляється, оригінал лишається незмінним, кидається `StorageError.writeFailed`.
public enum AtomicFileWriter {
    public static func write(_ data: Data, to target: URL, fileSystem: FileSystem) throws {
        let directory = target.deletingLastPathComponent()
        do {
            try fileSystem.createDirectory(at: directory)
        } catch {
            throw StorageError.writeFailed(error.localizedDescription)
        }

        let tempURL = directory.appendingPathComponent(
            ".\(target.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try fileSystem.writeData(data, to: tempURL)
        } catch {
            try? fileSystem.removeItem(at: tempURL)
            throw StorageError.writeFailed(error.localizedDescription)
        }

        // Завжди `replaceItem` (rename(2)): атомарно і коли ціль існує, і коли її ще нема —
        // без гонки check-then-act між `fileExists` і `moveItem`.
        do {
            try fileSystem.replaceItem(at: target, withItemAt: tempURL)
        } catch {
            try? fileSystem.removeItem(at: tempURL)
            throw StorageError.writeFailed(error.localizedDescription)
        }
    }
}

/// Мінімальний декодер для перевірки версії схеми.
struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int
}
