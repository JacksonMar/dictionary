import AppKit
import VocabCore

/// Застосування теми до всього застосунку (§11, D20, M6). Протокол — щоб `AppModel` тестувався зі spy.
@MainActor
protocol AppearanceApplying: AnyObject {
    func apply(_ appearance: AppAppearance)
}

/// Тема через `NSApp.appearance`: успадковується всіма вікнами (обидві `Window`-сцени, sheet-и, алерти,
/// `NSOpenPanel`/`NSSavePanel`). `nil` — слідувати системній темі.
@MainActor
final class AppearanceController: AppearanceApplying {
    init() {}

    func apply(_ appearance: AppAppearance) {
        NSApp.appearance = Self.nsAppearance(for: appearance)
    }

    /// `.system` → `nil`, `.light` → `.aqua`, `.dark` → `.darkAqua`.
    static func nsAppearance(for appearance: AppAppearance) -> NSAppearance? {
        switch appearance {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}
