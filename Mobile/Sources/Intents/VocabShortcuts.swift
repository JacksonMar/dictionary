#if canImport(AppIntents)
import AppIntents

/// Готові команди Siri / Швидких команд / Spotlight (IOS_PLAN §7 I4). Кожна фраза містить `\(.applicationName)`
/// (вимога App Shortcuts). Рядковий параметр (`text`) у фразу не вбудовується — Siri перепитає «Which word?»
/// (`requestValueDialog`). Фрази локалізує `Mobile/Resources/{en,uk}.lproj/AppShortcuts.strings` (DI17; Siri
/// українською не працює — iU7, українські фрази видно в Швидких командах). `shortTitle` — `Localizable.strings`.
struct VocabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToDictionaryIntent(),
            phrases: [
                "Add a word to \(.applicationName)",
                "Add to \(.applicationName)",
                "Translate with \(.applicationName)",
            ],
            shortTitle: "Add to Dictionary",
            systemImageName: "text.badge.plus"
        )
        AppShortcut(
            intent: StartVoiceCaptureIntent(),
            phrases: [
                "Add a word by voice to \(.applicationName)",
                "Listen with \(.applicationName)",
                "Start \(.applicationName) voice input",
            ],
            shortTitle: "Add by Voice",
            systemImageName: "mic.fill"
        )
    }
}
#endif
