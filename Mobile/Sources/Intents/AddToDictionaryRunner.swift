import Foundation
import VocabCore

// Логіка дії «Додати до словника» (Siri / Швидкі команди, IOS_PLAN §7 I4) без `AppIntents`: тайпчекається й
// тестується на Linux; `AddToDictionaryIntent` — тонка обгортка над `AddToDictionaryRunner`.

/// Очікування для тайм-ауту відповіді. Живе — `TaskIntentSleeper` (`Task.sleep`); тести підставляють керований
/// годинник. Скасування задачі, що чекає, має завершувати `sleep` достроково (живе — так і робить).
protocol IntentSleeping: Sendable {
    func sleep(seconds: TimeInterval) async
}

/// `Task.sleep`; скасування → повертається одразу.
struct TaskIntentSleeper: IntentSleeping {
    init() {}

    func sleep(seconds: TimeInterval) async {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        // Скасування (`CancellationError`) — штатне дострокове завершення, помилки тут немає.
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// Чим закінчилась дія (для діалогу й тестів).
enum AddToDictionaryResult: Equatable, Sendable {
    /// `AddWordUseCase` завершився до тайм-ауту (додано / дубль / у черзі / помилка / відхилено).
    case completed(AddWordOutcome)
    /// Переклад триває довше за тайм-аут: запис уже збережено як `pending`, задача продовжується у фоні (DI18).
    case translating(word: String)
    /// Словник не завантажився (напр. новіша схема) — нічого не збережено.
    case loadFailed(message: String)
}

/// Відповідь дії: результат і текст діалогу Siri / Швидких команд мовою інтерфейсу застосунку.
struct AddToDictionaryResponse: Equatable, Sendable {
    let result: AddToDictionaryResult
    let dialog: String
}

/// Виконує «Додати до словника» в процесі застосунку (iU5) над `AppContainer.shared` (DI8: той самий Keychain):
/// валідація → `ensureLoaded()` (single-flight, §4) → `AddWordUseCase.execute(rawText:sourceLanguageHint:)` у фоновій
/// задачі (DI18) → діалог із `NotificationText.make`.
///
/// Токени (§8): нове слово — 1 запит, дубль — 0 (перевірка до запиту в `AddWordUseCase`), порожній/невалідний текст —
/// 0 і без завантаження словника. Паралельно з інжестом inbox і `processAll(.foreground)` — не більше 1 запиту на
/// слово (атомарний check+insert у `DictionaryRepository`, `.skipped` у черзі, §4).
///
/// Довгий запит: якщо за `timeout` (8 с) відповіді немає, дія відповідає «Збережено, перекладається» — запис уже
/// `pending`. Задача додавання **не скасовується**: вона неструктурована (не успадковує скасування `perform`) і
/// триває у фоновій задачі; якщо систему все ж призупинить процес, запис добере тригер `.foreground`.
@MainActor
final class AddToDictionaryRunner {
    /// Через скільки секунд відповідати «Збережено, перекладається».
    nonisolated static let slowLookupTimeout: TimeInterval = 8
    /// Ім'я фонової задачі (DI18).
    nonisolated static let backgroundTaskName = "VocabIntentAddWord"

    private let container: AppContainer
    private let sleeper: IntentSleeping
    private let timeout: TimeInterval

    /// Остання запущена задача додавання (тести чекають на неї після відповіді «перекладається»).
    private(set) var lastAddTask: Task<AddWordOutcome, Never>?

    init(
        container: AppContainer,
        sleeper: IntentSleeping = TaskIntentSleeper(),
        timeout: TimeInterval = AddToDictionaryRunner.slowLookupTimeout
    ) {
        self.container = container
        self.sleeper = sleeper
        self.timeout = timeout
    }

    /// - Parameters:
    ///   - text: слово або фраза з параметра intent-а.
    ///   - language: параметр «Мова»; `nil` / `.auto` — без підказки.
    func run(text: String?, language: VoiceLanguageAppEnum?) async -> AddToDictionaryResponse {
        let interfaceLanguage = container.settings.interfaceLanguage

        // Порожнє / задовге / без літер — одразу відмова (без завантаження словника й без запиту).
        let cleaned: CleanedSelection
        switch SelectionValidator.validate(text) {
        case .rejected(let rejection):
            return response(.completed(.rejected(rejection)), selection: text, language: interfaceLanguage)
        case .valid(let selection):
            cleaned = selection
        }

        if case .failed(let message) = await container.ensureLoaded() {
            return response(.loadFailed(message: message), selection: text, language: interfaceLanguage)
        }

        let addWord = container.addWord
        let backgroundTasks = container.backgroundTasks
        let hint = VoiceLanguageAppEnum.voiceLanguage(for: language)?.languageHint
        let rawText = text
        let addTask = Task<AddWordOutcome, Never> { @MainActor in
            await backgroundTasks.run(named: Self.backgroundTaskName) {
                await addWord.execute(rawText: rawText, sourceLanguageHint: hint)
            }
        }
        lastAddTask = addTask

        let race = FirstResult<AddToDictionaryResult>()
        let sleeper = self.sleeper
        let timeout = self.timeout
        let word = cleaned.text
        let timer = Task<Void, Never> { @MainActor in
            await sleeper.sleep(seconds: timeout)
            guard !Task.isCancelled else { return }
            race.offer(.translating(word: word))
        }
        Task<Void, Never> { @MainActor in
            race.offer(.completed(await addTask.value))
        }
        let result = await race.value()
        // Відповідь уже є: таймер більше не потрібен. `addTask` не скасовується ніколи.
        timer.cancel()
        return response(result, selection: text, language: interfaceLanguage)
    }

    private func response(
        _ result: AddToDictionaryResult,
        selection: String?,
        language: AppLanguage
    ) -> AddToDictionaryResponse {
        AddToDictionaryResponse(
            result: result,
            dialog: Self.dialogText(for: result, selection: selection, language: language)
        )
    }

    /// Текст діалогу: результат — `NotificationText.make(...).singleLine` (як картка голосу і сповіщення macOS);
    /// порожній текст — власний рядок `intent.add.empty`.
    static func dialogText(for result: AddToDictionaryResult, selection: String?, language: AppLanguage) -> String {
        switch result {
        case .completed(.rejected(.empty)):
            // Порожній параметр (напр. порожня змінна в Швидких командах): «Nothing is selected» з macOS тут не пасує.
            return L10n.text(.intentAddEmpty, language: language)
        case .completed(let outcome):
            return NotificationText.make(for: outcome, selection: selection, language: language).singleLine
        case .translating(let word):
            return L10n.text(.intentAddTranslating, ["word": word], language: language)
        case .loadFailed(let message):
            return L10n.text(.intentAddLoadFailed, ["reason": message], language: language)
        }
    }
}

/// Перший запропонований результат перегонів (додавання vs тайм-аут); решта ігнорується. Потокобезпечний, працює
/// за будь-якого порядку `offer` / `value()`.
private final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Value?
    private var continuation: CheckedContinuation<Value, Never>?

    func offer(_ value: Value) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func value() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
