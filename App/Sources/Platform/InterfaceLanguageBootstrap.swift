import Foundation
import VocabCore

/// Застосування мови інтерфейсу на старті (M9, D36): до побудови сцен і `AppModel`.
/// Ідемпотентне — викликається з `VocabApp.init()` і ще раз з `AppDelegate.init()` (порядок їх створення
/// SwiftUI не гарантує).
enum InterfaceLanguageBootstrap {
    /// `L10n.setCurrent(settings.interfaceLanguage)` і синхронізація `AppleLanguages = [code]` у домені
    /// застосунку, якщо значення відрізняється. Під XCTest — `.en` і без запису.
    @discardableResult
    static func apply(
        settings: SettingsStore,
        writer: PreferredLanguagesWriting?,
        isRunningTests: Bool = AppEnvironment.isRunningTests
    ) -> AppLanguage {
        guard !isRunningTests else {
            L10n.setCurrent(.en)
            return .en
        }
        let language = settings.interfaceLanguage
        L10n.setCurrent(language)
        let codes = [language.rawValue]
        if let writer, writer.appleLanguages != codes {
            writer.setAppleLanguages(codes)
        }
        return language
    }

    /// Старт застосунку з реальними `UserDefaults` (під XCTest — без читання й запису).
    static func applyAtLaunch() {
        guard !AppEnvironment.isRunningTests else {
            L10n.setCurrent(.en)
            return
        }
        apply(
            settings: UserDefaultsSettingsStore(defaults: .standard),
            writer: UserDefaultsPreferredLanguagesWriter(),
            isRunningTests: false
        )
    }
}
