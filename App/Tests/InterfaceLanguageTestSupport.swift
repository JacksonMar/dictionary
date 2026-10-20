import XCTest
import VocabCore

extension XCTestCase {
    /// M9 (D39): фіксує мову інтерфейсу для набору, що перевіряє тексти певною мовою (копія хелпера ядра
    /// з `Tests/VocabCoreTests/TestSupport.swift`). Викликати в `setUp`; після тесту мова повертається до `.en`
    /// (так її встановлює `InterfaceLanguageBootstrap` під XCTest).
    /// `AppModel.runningInterfaceLanguage` фіксує `L10n.current` на момент створення моделі, тож у таких наборах
    /// `interfaceLanguageNeedsRestart` може бути `true` — на ньому там не асертувати.
    func pinInterfaceLanguage(_ language: AppLanguage) {
        L10n.setCurrent(language)
        addTeardownBlock {
            L10n.setCurrent(.en)
        }
    }
}
