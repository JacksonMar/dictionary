import Foundation

/// Вид резервної копії (D2).
public enum BackupReason: String, Sendable, CaseIterable {
    /// Копія поточного словника перед імпортом у режимі «Замінити». Оригінал лишається на місці.
    case replaceImport
    /// Зіпсований `dictionary.json` **переноситься** в Backups.
    case corrupted

    /// Префікс імені файлу: `dictionary-backup-` / `dictionary-corrupted-`.
    public var filePrefix: String {
        switch self {
        case .replaceImport: return "dictionary-backup-"
        case .corrupted: return "dictionary-corrupted-"
        }
    }
}

/// Створює резервні копії у `Backups/` з іменами `dictionary-<kind>-yyyyMMdd-HHmmss[-N].json` (UTC)
/// і зберігає `retainCount` найновіших файлів кожного виду.
public struct BackupManager: Sendable {
    public static let defaultRetainCount = 10

    public let directory: URL
    public let retainCount: Int
    private let fileSystem: FileSystem
    private let dateProvider: DateProvider

    public init(
        directory: URL,
        fileSystem: FileSystem = LocalFileSystem(),
        dateProvider: DateProvider = SystemDateProvider(),
        retainCount: Int = BackupManager.defaultRetainCount
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.dateProvider = dateProvider
        self.retainCount = max(1, retainCount)
    }

    /// `.replaceImport` копіює файл, `.corrupted` переносить. Повертає URL створеної копії.
    /// Помилки → `StorageError.backupFailed`.
    @discardableResult
    public func makeBackup(of source: URL, reason: BackupReason) throws -> URL {
        do {
            try fileSystem.createDirectory(at: directory)
        } catch {
            throw StorageError.backupFailed(describe(error))
        }

        let destination = nextAvailableURL(reason: reason)
        do {
            switch reason {
            case .replaceImport:
                try fileSystem.copyItem(at: source, to: destination)
            case .corrupted:
                try fileSystem.moveItem(at: source, to: destination)
            }
        } catch {
            throw StorageError.backupFailed(describe(error))
        }

        // Ротація не повинна зірвати вже створену копію.
        try? pruneBackups(reason: reason)
        return destination
    }

    /// Видаляє найстаріші копії виду `reason`, лишаючи `retainCount`.
    public func pruneBackups(reason: BackupReason) throws {
        let files = try fileSystem.contentsOfDirectory(at: directory)
            .compactMap { url -> (url: URL, key: BackupSortKey)? in
                guard let key = BackupSortKey(fileName: url.lastPathComponent, prefix: reason.filePrefix) else {
                    return nil
                }
                return (url, key)
            }
            .sorted { $0.key < $1.key }
        guard files.count > retainCount else { return }
        for item in files.prefix(files.count - retainCount) {
            try? fileSystem.removeItem(at: item.url)
        }
    }

    private func nextAvailableURL(reason: BackupReason) -> URL {
        let stamp = Self.timestamp(for: dateProvider.now())
        let base = reason.filePrefix + stamp
        // Новий файл завжди отримує номер, більший за наявні з тим самим штампом, щоб після ротації
        // «звільнене» базове ім'я не зробило найновішу копію найстарішою.
        let existingMax = ((try? fileSystem.contentsOfDirectory(at: directory)) ?? [])
            .compactMap { BackupSortKey(fileName: $0.lastPathComponent, prefix: reason.filePrefix) }
            .filter { $0.stamp == stamp }
            .map(\.sequence)
            .max()
        var suffix = (existingMax ?? 0) + 1
        var candidate = suffix == 1
            ? directory.appendingPathComponent(base + ".json", isDirectory: false)
            : directory.appendingPathComponent("\(base)-\(suffix).json", isDirectory: false)
        while fileSystem.fileExists(at: candidate) {
            suffix += 1
            candidate = directory.appendingPathComponent("\(base)-\(suffix).json", isDirectory: false)
        }
        return candidate
    }

    /// `yyyyMMdd-HHmmss` у UTC.
    static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private func describe(_ error: Error) -> String {
        if let storage = error as? StorageError {
            return storage.userMessage
        }
        return FileErrorText.describe(error)
    }
}

/// Порядок копій: за штампом часу, далі за числовим суфіксом колізії (без суфікса = 1).
struct BackupSortKey: Comparable {
    let stamp: String
    let sequence: Int

    init?(fileName: String, prefix: String) {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".json") else { return nil }
        let body = fileName.dropFirst(prefix.count).dropLast(".json".count)
        // body: yyyyMMdd-HHmmss або yyyyMMdd-HHmmss-N
        let parts = body.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts[0].count == 8, parts[1].count == 6,
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber) else {
            return nil
        }
        if parts.count == 3 {
            guard let sequence = Int(parts[2]) else { return nil }
            self.sequence = sequence
        } else {
            self.sequence = 1
        }
        self.stamp = parts[0] + "-" + parts[1]
    }

    static func < (lhs: BackupSortKey, rhs: BackupSortKey) -> Bool {
        if lhs.stamp != rhs.stamp {
            return lhs.stamp < rhs.stamp
        }
        return lhs.sequence < rhs.sequence
    }
}
