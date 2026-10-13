import Foundation

/// Експорт та імпорт словника (§10). Без змінюваного стану → `Sendable`.
public final class DictionaryTransferService: Sendable {
    private let repository: DictionaryRepository
    private let store: DictionaryStoring
    private let backups: BackupManager
    private let fileSystem: FileSystem
    private let dateProvider: DateProvider

    public init(
        repository: DictionaryRepository,
        store: DictionaryStoring,
        backups: BackupManager,
        fileSystem: FileSystem = LocalFileSystem(),
        dateProvider: DateProvider = SystemDateProvider()
    ) {
        self.repository = repository
        self.store = store
        self.backups = backups
        self.fileSystem = fileSystem
        self.dateProvider = dateProvider
    }

    /// Записує поточний словник (`exportedAt` = зараз) атомарно (`AtomicFileWriter`) у `url`.
    /// Помилки: `RepositoryError.notLoaded`, `StorageError.writeFailed`.
    /// - Returns: кількість записів у **записаному** файлі (той самий знімок, що й експортовано).
    @discardableResult
    public func exportDictionary(to url: URL) async throws -> Int {
        let entries = try await repository.loadedEntries()
        let data = try DictionaryExporter.exportData(entries: entries, now: dateProvider.now())
        try AtomicFileWriter.write(data, to: url, fileSystem: fileSystem)
        return entries.count
    }

    /// Імпорт з `url`. Будь-яка помилка (`ImportError`) означає, що словник не змінено.
    /// - merge: одне атомарне збереження результату `ImportMerger.merge`;
    /// - replace: бекап поточного файлу (`BackupReason.replaceImport`, якщо файл існує), далі повна заміна
    ///   записами файлу (дублікати згортаються). Звіт: `added` = кількість записів, `updated` = 0.
    /// `skipped` у звіті включає невалідні записи файлу (D13).
    public func importDictionary(from url: URL, mode: ImportMode) async throws -> ImportReport {
        let data: Data
        do {
            data = try fileSystem.readData(at: url)
        } catch {
            throw ImportError.readFailed(FileErrorText.describe(error))
        }
        let parsed = try DictionaryImporter.parse(data)

        do {
            switch mode {
            case .merge:
                var report = try await repository.mergeImported(parsed.entries)
                report.skipped += parsed.skippedReasons.count
                report.skippedReasons.insert(contentsOf: parsed.skippedReasons, at: 0)
                return report

            case .replace:
                let collapsed = ImportMerger.collapseDuplicates(parsed.entries)
                let backups = self.backups
                let fileSystem = self.fileSystem
                let fileURL = store.fileURL
                try await repository.replaceAll(collapsed.entries) {
                    guard fileSystem.fileExists(at: fileURL) else { return }
                    do {
                        try backups.makeBackup(of: fileURL, reason: .replaceImport)
                    } catch let error as StorageError {
                        throw ImportError.backupFailed(Self.reason(of: error))
                    } catch {
                        throw ImportError.backupFailed(FileErrorText.describe(error))
                    }
                }
                var report = ImportReport(added: collapsed.entries.count)
                report.addSkipped(parsed.skippedReasons + collapsed.skippedReasons)
                return report
            }
        } catch let error as ImportError {
            throw error
        } catch let error as RepositoryError {
            throw ImportError.storage(error.userMessage)
        } catch {
            throw ImportError.storage(FileErrorText.describe(error))
        }
    }

    /// Причина без префікса «Не вдалося створити резервну копію: » (його додає `ImportError.userMessage`).
    private static func reason(of error: StorageError) -> String {
        switch error {
        case .backupFailed(let reason), .readFailed(let reason), .writeFailed(let reason):
            return reason
        case .unsupportedSchemaVersion:
            return error.userMessage
        }
    }
}
