import Foundation

/// Тексти інтерфейсу (M9, D32). Поточна мова встановлюється один раз на старті застосунку
/// (`InterfaceLanguageBootstrap`) і далі не змінюється до перезапуску; тести можуть перемикати її явно.
public enum L10n {
    /// Поточна мова під `NSLock`: читається з фонових черг (обробка, імпорт).
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var language: AppLanguage = .default

        func get() -> AppLanguage {
            lock.lock()
            defer { lock.unlock() }
            return language
        }

        func set(_ newValue: AppLanguage) {
            lock.lock()
            defer { lock.unlock() }
            language = newValue
        }
    }

    private static let state = State()

    /// Поточна мова інтерфейсу; до `setCurrent` — `AppLanguage.default` (`.en`).
    public static var current: AppLanguage {
        state.get()
    }

    public static func setCurrent(_ language: AppLanguage) {
        state.set(language)
    }

    /// Текст ключа мовою `language` з підстановкою іменованих плейсхолдерів `{name}` з `args`.
    public static func text(_ key: L10nKey, _ args: [String: String] = [:], language: AppLanguage = L10n.current) -> String {
        let template: String
        switch language {
        case .en:
            template = L10nEnglish.text(key)
        case .uk:
            template = L10nUkrainian.text(key)
        }
        return format(template, args)
    }

    /// Підстановка `{name}` за один прохід: вставлені значення повторно не скануються (тож `{x}` у слові
    /// користувача лишається як є); плейсхолдер без аргументу лишається токеном `{name}`.
    public static func format(_ template: String, _ args: [String: String]) -> String {
        guard !args.isEmpty, template.contains("{") else { return template }
        var result = ""
        result.reserveCapacity(template.count)
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            guard character == "{",
                  let close = template[index...].firstIndex(of: "}") else {
                result.append(character)
                index = template.index(after: index)
                continue
            }
            let name = String(template[template.index(after: index)..<close])
            if isPlaceholderName(name), let value = args[name] {
                result += value
                index = template.index(after: close)
            } else {
                // Не плейсхолдер або немає аргументу: «{» лишається, сканування триває з наступного символу.
                result.append(character)
                index = template.index(after: index)
            }
        }
        return result
    }

    private static func isPlaceholderName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
