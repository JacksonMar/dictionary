import Foundation

/// Короткий опис помилки файлової системи мовою інтерфейсу (для `StorageError`/`ImportError`), замість
/// системного `localizedDescription`. Без шляхів до файлів і без крапки в кінці — текст
/// вставляється в більше речення («Не вдалося прочитати файл: файл не знайдено. Словник не змінено.»).
public enum FileErrorText {
    public static func describe(_ error: Error, language: AppLanguage = L10n.current) -> String {
        if let storage = error as? StorageError {
            return trimmingTrailingPeriods(storage.userMessage(in: language))
        }
        let nsError = error as NSError
        if let key = knownKey(domain: nsError.domain, code: nsError.code) {
            return L10n.text(key, language: language)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let key = knownKey(domain: underlying.domain, code: underlying.code) {
            return L10n.text(key, language: language)
        }
        return L10n.text(
            .fileSystemError,
            ["domain": nsError.domain, "code": String(nsError.code)],
            language: language
        )
    }

    /// Знімає крайні пробіли і крапки в кінці (щоб після вставки в речення не було «..»).
    public static func trimmingTrailingPeriods(_ text: String) -> String {
        var result = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = result.last, last == "." || last == " " {
            result = result.dropLast()
        }
        return String(result)
    }

    // MARK: - Private

    private static func knownKey(domain: String, code: Int) -> L10nKey? {
        if domain == NSCocoaErrorDomain {
            return cocoaKey(code)
        }
        if domain == NSPOSIXErrorDomain {
            return posixKey(code)
        }
        return nil
    }

    private static func cocoaKey(_ code: Int) -> L10nKey? {
        switch code {
        case CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue:
            return .fileNotFound
        case CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue:
            return .fileNoPermission
        case CocoaError.Code.fileWriteOutOfSpace.rawValue:
            return .fileOutOfSpace
        case CocoaError.Code.fileWriteVolumeReadOnly.rawValue:
            return .fileReadOnlyVolume
        case CocoaError.Code.fileReadCorruptFile.rawValue:
            return .fileCorrupt
        case CocoaError.Code.fileReadTooLarge.rawValue:
            return .fileTooLarge
        case CocoaError.Code.fileReadInvalidFileName.rawValue, CocoaError.Code.fileWriteInvalidFileName.rawValue:
            return .fileInvalidName
        case CocoaError.Code.fileWriteFileExists.rawValue:
            return .fileExists
        case CocoaError.Code.fileLocking.rawValue:
            return .fileLocked
        default:
            return nil
        }
    }

    private static func posixKey(_ code: Int) -> L10nKey? {
        switch code {
        case Int(POSIXErrorCode.ENOENT.rawValue), Int(POSIXErrorCode.ENOTDIR.rawValue):
            return .fileNotFound
        case Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue):
            return .fileNoPermission
        case Int(POSIXErrorCode.ENOSPC.rawValue), Int(POSIXErrorCode.EDQUOT.rawValue):
            return .fileOutOfSpace
        case Int(POSIXErrorCode.EROFS.rawValue):
            return .fileReadOnlyVolume
        case Int(POSIXErrorCode.EISDIR.rawValue):
            return .fileIsDirectory
        case Int(POSIXErrorCode.EEXIST.rawValue):
            return .fileExists
        default:
            return nil
        }
    }
}
