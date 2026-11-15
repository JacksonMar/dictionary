import SwiftUI
import VocabCore

/// Точка входу iOS-застосунку (IOS_PLAN §2). Композиція — `AppContainer.shared`; мова інтерфейсу — з налаштувань
/// на старті (миттєве перемикання з `.id(interfaceLanguage)` — I1b, DI14).
/// Явний `@MainActor`: `init()` звертається до `AppContainer.shared` і створює `@MainActor`-моделі синхронно
/// (не покладаємося на те, чи анотовано протокол `App` у конкретному SDK).
@main
@MainActor
struct VocabMobileApp: App {
    @StateObject private var model: MobileAppModel
    @StateObject private var router: Router

    init() {
        let container = AppContainer.shared
        L10n.setCurrent(container.settings.interfaceLanguage)
        _model = StateObject(wrappedValue: MobileAppModel(container: container))
        _router = StateObject(wrappedValue: Router())
    }

    var body: some Scene {
        WindowGroup {
            EntryListView(model: model)
                .environmentObject(router)
                .onOpenURL { (url: URL) in
                    // I1a: маршрут лише запам'ятовується (аркуші — I1b/I2b); невідомий URL ігнорується.
                    _ = router.open(url: url)
                }
        }
    }
}
