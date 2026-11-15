import SwiftUI
import VocabCore

/// Точка входу iOS-застосунку (IOS_PLAN §2, §4). Композиція — `AppContainer.shared`; мова інтерфейсу — з налаштувань
/// на старті й миттєво після зміни (DI14: `L10n.setCurrent` у моделі + `.id(interfaceLanguage)` на корені, тож усе
/// дерево перебудовується з новими текстами; відкритий аркуш Налаштувань відновлюється з `Router`).
/// `scenePhase == .active` (зокрема перший запуск) → `MobileAppModel.becameActive()`: завантаження → інжест inbox
/// «Поділитися» (I3) → `processAll(.foreground)` → автодоповнення в режимі IT.
/// Явний `@MainActor`: `init()` звертається до `AppContainer.shared` і створює `@MainActor`-моделі синхронно
/// (не покладаємося на те, чи анотовано протокол `App` у конкретному SDK).
@main
@MainActor
struct VocabMobileApp: App {
    @StateObject private var model: MobileAppModel
    @StateObject private var router: Router
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container = AppContainer.shared
        L10n.setCurrent(container.settings.interfaceLanguage)
        _model = StateObject(wrappedValue: MobileAppModel(container: container))
        _router = StateObject(wrappedValue: Router())
    }

    var body: some Scene {
        WindowGroup {
            EntryListView(model: model)
                .id(model.interfaceLanguage)
                .environmentObject(router)
                .onOpenURL { (url: URL) in
                    // Невідомий URL ігнорується; `voice` відкриває аркуш додавання в режимі голосу (I2b).
                    _ = router.open(url: url)
                }
        }
        .onChange(of: scenePhase, initial: true) { (_: ScenePhase, newPhase: ScenePhase) in
            guard newPhase == .active else { return }
            let model = self.model
            Task<Void, Never> { @MainActor in
                await model.becameActive()
            }
        }
    }
}
