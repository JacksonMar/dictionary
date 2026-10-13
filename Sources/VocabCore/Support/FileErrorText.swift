import Foundation

/// Україномовний короткий опис помилки файлової системи (для `StorageError`/`ImportError`), замість
/// англомовного системного `localizedDescription`. Без шляхів до файлів і без крапки в кінці — текст
/// вставляється в більше речення («Не вдалося прочитати файл: файл не знайдено. Словник не змінено.»).
public enum FileErrorText {
    public static func describe(_ error: Error) -> String {
        if let storage = error as? StorageError {
            return trimmingTrailingPeriods(storage.userMessage)
        }
        let nsError = error as NSError
        if let text = knownText(domain: nsError.domain, code: nsError.code) {
            return text
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           let text = knownText(domain: underlying.domain, code: underlying.code) {
            return text
        }
        return "системна помилка (\(nsError.domain), код \(nsError.code))"
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

    private static func knownText(domain: String, code: Int) -> String? {
        if domain == NSCocoaErrorDomain {
            return cocoaText(code)
        }
        if domain == NSPOSIXErrorDomain {
            return posixText(code)
        }
        return nil
    }

    private static func cocoaText(_ code: Int) -> String? {
        switch code {
        case CocoaError.Code.fileNoSuchFile.rawValue, CocoaError.Code.fileReadNoSuchFile.rawValue:
            return "файл не знайдено"
        case CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue:
            return "немає доступу до файлу"
        case CocoaError.Code.fileWriteOutOfSpace.rawValue:
            return "недостатньо місця на диску"
        case CocoaError.Code.fileWriteVolumeReadOnly.rawValue:
            return "диск доступний лише для читання"
        case CocoaError.Code.fileReadCorruptFile.rawValue:
            return "файл пошкоджений або має невідоме кодування"
        case CocoaError.Code.fileReadTooLarge.rawValue:
            return "файл завеликий"
        case CocoaError.Code.fileReadInvalidFileName.rawValue, CocoaError.Code.fileWriteInvalidFileName.rawValue:
            return "некоректне ім'я файлу"
        case CocoaError.Code.fileWriteFileExists.rawValue:
            return "файл уже існує"
        case CocoaError.Code.fileLocking.rawValue:
            return "файл заблоковано"
        default:
            return nil
        }
    }

    private static func posixText(_ code: Int) -> String? {
        switch code {
        case Int(POSIXErrorCode.ENOENT.rawValue), Int(POSIXErrorCode.ENOTDIR.rawValue):
            return "файл не знайдено"
        case Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue):
            return "немає доступу до файлу"
        case Int(POSIXErrorCode.ENOSPC.rawValue), Int(POSIXErrorCode.EDQUOT.rawValue):
            return "недостатньо місця на диску"
        case Int(POSIXErrorCode.EROFS.rawValue):
            return "диск доступний лише для читання"
        case Int(POSIXErrorCode.EISDIR.rawValue):
            return "вказано каталог, а не файл"
        case Int(POSIXErrorCode.EEXIST.rawValue):
            return "файл уже існує"
        default:
            return nil
        }
    }
}
