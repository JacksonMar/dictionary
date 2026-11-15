import Foundation
#if canImport(Combine)
import Combine
#endif

/// Екран/аркуш, який треба показати (IOS_PLAN §2, §4). I1a показує лише список; `addSheet` — I1b,
/// `voiceCapture` — I2b (зараз маршрут лише запам'ятовується).
enum AppRoute: Equatable, Sendable {
    case list
    case addSheet
    /// `languageID`: `"en"` / `"it"` або `nil` (остання вибрана мова голосу).
    case voiceCapture(languageID: String?)
}

/// Розбір глибоких посилань `vocabapp://…` (віджет, intent-и). Мінімальна версія; повна — I4 (`DeepLinkTests`).
enum DeepLink {
    static let scheme = "vocabapp"
    /// Мови голосового введення, які приймає параметр `lang`.
    static let voiceLanguageIDs: Set<String> = ["en", "it"]

    /// `vocabapp://voice[?lang=en|it]` → `.voiceCapture`; `vocabapp://add` → `.addSheet`; решта → `nil`.
    static func parse(_ url: URL) -> AppRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              let host = components.host?.lowercased() else {
            return nil
        }
        switch host {
        case "voice":
            let rawLanguage = components.queryItems?.first { $0.name == "lang" }?.value?.lowercased()
            let languageID = rawLanguage.flatMap { voiceLanguageIDs.contains($0) ? $0 : nil }
            return .voiceCapture(languageID: languageID)
        case "add":
            return .addSheet
        default:
            return nil
        }
    }
}

/// Поточний маршрут застосунку (головний актор). Views реагують на `route`; закриття аркуша → `.list`.
@MainActor
final class Router: ObservableObject {
    @Published var route: AppRoute = .list

    init() {}

    func open(_ route: AppRoute) {
        self.route = route
    }

    /// Відкриває маршрут із глибокого посилання; невідомий URL ігнорується. Повертає `true`, якщо URL розпізнано.
    @discardableResult
    func open(url: URL) -> Bool {
        guard let parsed = DeepLink.parse(url) else { return false }
        route = parsed
        return true
    }

    func dismiss() {
        route = .list
    }
}
