import Foundation
import VocabCore
#if canImport(SwiftUI) && canImport(UniformTypeIdentifiers)
import SwiftUI
import UniformTypeIdentifiers
#endif

// Експорт/імпорт словника через системні Files (IOS_PLAN §5, I5). Не-UI частина (ім'я файлу, тип, копіювання
// security-scoped файлу) тайпчекається й тестується на Linux; `FileDocument` (SwiftUI/UniformTypeIdentifiers) —
// окремим блоком `#if canImport(SwiftUI)` нижче.
//
// AirDrop: `fileExporter` зберігає файл у Files; надіслати його на Mac можна з Files → «Поділитися» → AirDrop
// (зауваження Judge до плану). На Mac отриманий файл імпортується з Downloads.

/// Параметри файлу експорту — ті самі, що на macOS (`AppModel.defaultExportFileName`, `NSSavePanel` з `.json`).
enum DictionaryFileFormat {
    /// Ім'я файлу за замовчуванням (як на macOS) — `dictionary.json`.
    static let defaultFileName = "dictionary.json"
    /// UTI вмісту (`UTType.json`): схема v1 (`DictionaryFile`, ARCHITECTURE §10).
    static let contentTypeIdentifier = "public.json"
}

/// Підготовлений експорт: байти схеми v1 (`DictionaryExporter`) і кількість записів того самого знімка.
struct PreparedExport: Equatable, Sendable {
    let data: Data
    let entryCount: Int
    let fileName: String

    init(data: Data, entryCount: Int, fileName: String = DictionaryFileFormat.defaultFileName) {
        self.data = data
        self.entryCount = entryCount
        self.fileName = fileName
    }
}

/// Доступ до security-scoped URL (файл, вибраний у `fileImporter`, лежить поза пісочницею застосунку).
/// Протокол — щоб тести перевіряли, що копіювання відбувається всередині `start…`/`stop…`.
protocol SecurityScopedAccessing: Sendable {
    /// `true` — доступ відкрито (тоді обов'язково `stopAccessing`); `false` — файл і так доступний (напр. у
    /// пісочниці) або доступу немає: читання все одно пробуємо, помилку дасть саме копіювання.
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// Справжній доступ: `URL.startAccessingSecurityScopedResource()` (Apple-платформи). На Linux таких API немає —
/// `false` (харнес тестів).
struct URLSecurityScopedAccess: SecurityScopedAccessing {
    init() {}

    func startAccessing(_ url: URL) -> Bool {
        #if canImport(Darwin)
        return url.startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }

    func stopAccessing(_ url: URL) {
        #if canImport(Darwin)
        url.stopAccessingSecurityScopedResource()
        #endif
    }
}

/// Копіює вибраний файл імпорту в тимчасовий каталог застосунку, перш ніж його читати (I5.2): доступ до
/// security-scoped URL відкривається лише на час копіювання, а ядро (`DictionaryTransferService`) читає вже
/// локальну копію — без залежності від File Provider і часу життя доступу (діалог вибору режиму може висіти довго).
struct ImportFileStager: Sendable {
    let access: SecurityScopedAccessing
    let fileSystem: FileSystem
    /// Каталог тимчасових копій (створюється за потреби).
    let directory: URL

    init(access: SecurityScopedAccessing, fileSystem: FileSystem, directory: URL) {
        self.access = access
        self.fileSystem = fileSystem
        self.directory = directory
    }

    /// Каталог за замовчуванням: `<tmp>/VocabImport`.
    static func defaultDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VocabImport", isDirectory: true)
    }

    /// Копія `source` у `directory` під унікальним ім'ям. Помилка → `ImportError.readFailed` (текст мовою
    /// інтерфейсу, без шляхів), словник не змінюється.
    func stage(_ source: URL) throws -> URL {
        let started = access.startAccessing(source)
        defer {
            if started {
                access.stopAccessing(source)
            }
        }
        let destination = directory.appendingPathComponent("import-\(UUID().uuidString).json", isDirectory: false)
        do {
            try fileSystem.createDirectory(at: directory)
            try fileSystem.copyItem(at: source, to: destination)
        } catch {
            throw ImportError.readFailed(FileErrorText.describe(error))
        }
        return destination
    }

    /// Видаляє тимчасову копію (після імпорту або скасування). Лише файли всередині `directory`; помилка
    /// ігнорується (тимчасовий каталог чистить система).
    func discard(_ stagedURL: URL) {
        guard stagedURL.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
        else { return }
        try? fileSystem.removeItem(at: stagedURL)
    }
}

/// Результат вибору файлу без SwiftUI-типів: скасування системного вікна не є помилкою (повідомлення не показується).
enum DocumentPickerError {
    /// `CocoaError.userCancelled` (код 3072) — користувач скасував вікно Files.
    static func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.Code.userCancelled.rawValue
    }
}

#if canImport(SwiftUI) && canImport(UniformTypeIdentifiers)
/// Документ для `fileExporter`: готові байти експорту (схема v1). Читання (`init(configuration:)`) потрібне протоколу,
/// але імпорт іде через `fileImporter` + `ImportFileStager`, а не через цей тип.
struct DictionaryJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(_ prepared: PreparedExport) {
        self.data = prepared.data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension DictionaryFileFormat {
    /// `UTType` для `fileExporter`/`fileImporter` (той самий, що `contentTypeIdentifier`).
    static var contentType: UTType { .json }
}
#endif
