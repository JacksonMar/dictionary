# IOS_PLAN — VocabApp для iPhone (план, на затвердження користувачем)

Статус: **план, без коду**. Мова — українська, ідентифікатори — англійською. Базовий документ — `ARCHITECTURE.md`
(усі D1–D40 і правила економії токенів M7/M8 діють і тут). Рішення цього плану — `DI1…`, відкриті питання — `iU1…`
(після затвердження переносяться в `PROGRESS.md`).

Запит користувача: той самий словник на iPhone + **голосове введення** («кажу слово — воно додається й перекладається»),
плюс «Поділитися», Siri/Shortcuts, віджет. Синхронізація з Mac — **вручну** через `dictionary.json` (схема v1).

**Зміни після Judge (ітерація 1 → 2):** додано спайк **I0** (підпис Personal Team, App Group, ліміти, План Б); I1 поділено
на **I1a/I1b**; підказка мови — окремий Linux-етап **I2a** і окреме поле `Entry.languageHint` (не `sourceLanguage`),
описано поведінку Mac; виправлено твердження про незмінність тестів (`ProcessingTriggerTests`); inbox пише через
tmp + `moveItem`; описано single-flight для `ingest()` і завантаження; обов'язкове підтвердження голосу → питання
користувачу **iU15**; вирізано: власну тему (лише системна), дубль «Поділитися файлом», `CFBundleDocumentTypes`,
байтове порівняння з фікстурою Mac; чипи альтернатив — опційні.

---

## 1. Ключові рішення (коротко)

| # | Питання | Рішення |
|---|---|---|
| DI1 | Мінімальна iOS | **iOS 17** (`AVAudioApplication`, Lock Screen віджети з `containerBackground`, зрілі App Intents). Потрібен iPhone XS/XR або новіший (iU12). Xcode **16+** (симулятор iPhone 16). |
| DI2 | Обліковий запис Apple | Проєктуємо під **безкоштовний Apple ID** (Personal Team): установка кабелем з Xcode, профіль діє 7 днів. Нічого не використовує iCloud/CloudKit/Push/Associated Domains/Siri-entitlement. Перехід на платний акаунт = лише зміна team ID у локальному `Config/Local.xcconfig` (§6). Що реально працює з Personal Team — перевіряє спайк **I0** до початку роботи. |
| DI3 | Ядро | `VocabCore` лишається Foundation-only і Linux-тестованим; додається `.iOS(.v17)` у `Package.swift`. Зміни ядра — малі, адитивні, з тестами на Linux (§3). |
| DI4 | Спільний Apple-код | **Без переміщення файлів macOS.** iOS-таргет підключає за шляхом уже платформонезалежні файли з `App/Sources/Platform/`: `KeychainSecretStore.swift` (Security), `SpeechService.swift` (AVFoundation), `OSLogSink.swift` (os), `NetworkMonitor.swift` (Network). macOS-таргет не змінюється. Перенесення в `Shared/` — можливе пізніше, окремим кроком. |
| DI5 | `AppModel` | macOS `AppModel` **не рефакторимо** (AppKit-панелі, LoginItem тощо). Для iOS — окремий `MobileAppModel` поверх тих самих use-case ядра. Спільну логіку виносимо в ядро, а не в спільний UI-шар. |
| DI6 | Де живе `dictionary.json` на iPhone | У **власному контейнері застосунку** (`Application Support/VocabApp/`, як на Mac) — не в App Group. Єдиний процес, що пише словник, — застосунок. Розширення в словник **не пишуть** (§4). |
| DI7 | Share Extension і Claude | Розширення **не викликає Claude** і не бачить API-ключ. Воно лише кладе слово в **inbox** (файл у App Group); застосунок забирає inbox при активації і обробляє через наявну чергу pending. Обґрунтування: ліміти пам'яті/часу розширення (система може вбити його посеред HTTP після закриття листа «Поділитися»), не потрібен Keychain access group, немає міжпроцесних записів у `dictionary.json`, «спершу зберегти як pending» гарантує, що слово не губиться. Ціна: переклад з'явиться, коли користувач відкриє застосунок (сповіщень немає — DI15). |
| DI8 | API-ключ | Keychain лише застосунку (наявний `KeychainSecretStore`, `service = "<bundle id застосунку>"`). **Keychain sharing / access groups не потрібні** (DI7). Intent-и виконуються в процесі застосунку й читають той самий елемент. |
| DI9 | Міжпроцесна безпека | Немає спільного файлу з кількома писачами: кожен елемент inbox — **окремий файл** з унікальним ім'ям (tmp + `moveItem`, §3.3), єдиний споживач — застосунок. `NSFileCoordinator` і блокування не потрібні. Обробка ідемпотентна: падіння між «додати» і «видалити файл» → при наступному проході запис виявиться дублем (0 запитів). Усередині процесу — single-flight (§4). |
| DI10 | Голос: жест | **Tap-to-talk з автозупинкою**: дотик → слухає; зупинка повторним дотиком, після ~1,5 с тиші після останнього часткового результату або через 10 с. Причини: одна рука і VoiceOver; запуск з віджета/Siri одразу слухає без утримання; у sheet немає конфлікту жестів. Hold-to-talk не робимо. |
| DI11 | Голос: підтвердження | **За замовчуванням у плані — підтвердження**: розпізнаний текст у редагованому полі, додається кнопкою «Додати». Остаточний вибір — за користувачем (**iU15**): (а) завжди підтверджувати; (б) автододавання, коли впевненість розпізнавання висока і текст — одне слово/фраза (≤ 8 слів), з банером «Скасувати» (Undo видаляє запис; якщо запит уже пішов — токени витрачено). Варіант (б) — перемикач у Settings, якщо користувач його обере. |
| DI12 | Голос: розпізнавання | `SFSpeechRecognizer(locale: en-US \| it-IT)` + `AVAudioEngine` + `SFSpeechAudioBufferRecognitionRequest`, `shouldReportPartialResults = true`, `requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition`. Без on-device — серверне розпізнавання Apple з позначкою під полем; офлайн без on-device → зрозуміла помилка й поле для ручного введення. Перемикач **EN \| IT** поруч з мікрофоном запам'ятовується (`UserDefaults`, ключ `voiceLanguage`, лише iOS-застосунок). Чипи альтернатив з `transcriptions` — **опційно** (не критерій приймання). |
| DI13 | Мова мовлення як підказка Claude | **Так, передаємо**: мовлення однозначно задає мову, а без підказки неоднозначні слова (`come`, `pane`, `no`) за D25 стали б англійськими. Одне речення в **тому самому** system-промті (≈25 вхідних токенів), **кількість запитів не змінюється** (1 на нове слово, 0 для дубля). Текст — у визначенні пари в ядрі. Зберігається в **окремому** опційному полі `Entry.languageHint` (лише pending/failed; очищується, коли запис стає ready), бо `Entry.sourceLanguage` означає мову, визначену моделлю. Деталі — §3.2, етап I2a. |
| DI14 | Мова інтерфейсу на iOS | Той самий `L10n` (EN за замовчуванням / UK). Застосовується **миттєво**: iOS не дозволяє програмний перезапуск, тому корінь UI має `.id(interfaceLanguage)` і перебудовується. Системні рядки (`fileImporter`, лист «Поділитися», дозволи) — мовою системи / мови застосунку в iOS Settings (`CFBundleLocalizations = en, uk`). |
| DI15 | Сповіщення | **Немає** локальних сповіщень (усе в UI; без зайвого запиту дозволу). Фонова обробка inbox (`BGAppRefreshTask`) — поза планом (iU10). |
| DI16 | Пагінація | Без сторінок: `List` по всьому результату `EntryQuery.apply` (лінива відрисовка). `Pagination` ядра не використовується. |
| DI17 | Локалізація поза `L10n` (виняток із D33) | Лише рядки, які читає **система**: `InfoPlist.strings` (дозволи мікрофона/мовлення, назва), фрази `AppShortcuts.strings`, `configurationDisplayName`/`description` віджета — у `en.lproj`/`uk.lproj`. Увесь інший текст — ключі `L10n`. Siri українською не працює (iU7) — фрази `uk` додаємо для Shortcuts. |
| DI18 | Фон і обрив запиту | Додавання/інжест обгортаються в `UIApplication.beginBackgroundTask` (протокол `BackgroundTaskRunning`). Якщо процес усе ж призупинено — запис уже `pending`, його добере тригер `.foreground`. |
| DI19 | Тема | **Лише системна** (світла/темна за налаштуванням iOS). Перемикача теми на iOS немає; `AppAppearance` не використовується. |

---

## 2. Структура (нові каталоги; macOS-частина без змін)

```
Package.swift                      # + .iOS(.v17)
Sources/VocabCore/                 # + Inbox/, зміни §3
Mobile/
  Info.plist  VocabMobile.entitlements
  Sources/
    VocabMobileApp.swift           # @main, WindowGroup, .onOpenURL, scenePhase → foreground/inbox
    AppContainer.swift             # @MainActor singleton-композиція: store, repository, Keychain, Claude, процесори,
                                   # use-cases, MobileAppModel; lazy + single-flight load (§4) — для UI і App Intents
    MobileAppModel.swift           # @MainActor ObservableObject: entries, query, displayLanguageID, add/edit/delete/retry,
                                   # backfill, transfer, inbox report, interfaceLanguage
    Router.swift                   # enum AppRoute { case list, addSheet, voiceCapture(languageID: String?) } + DeepLink.parse(URL)
    Views/  EntryListView, EntryRowView, AddWordSheet, VoiceCaptureView, EntryDetailView, EntryEditView,
            SettingsView, ImportModeDialog, InboxBanner
    Voice/  VoiceCaptureModel.swift    # @MainActor стан-машина (idle/requestingPermission/listening/recognized/
                                       # submitting/result/error), тестується з FakeSpeechRecognizer
            SpeechRecognizing.swift    # протокол: authorize(), start(locale:onDevice:) -> AsyncStream<RecognitionUpdate>, stop()
            SpeechRecognitionService.swift  # SFSpeechRecognizer + AVAudioEngine
            AudioSessionController.swift    # .record/.measurement ↔ .playback для озвучення
            VoiceSupport.swift              # (I2b) VoiceLanguageStoring, VoiceTimerScheduling, VoiceWordSubmitting,
                                            # AudioSessionControlling, SpeechCompletionReporting
            VoiceSpeechService.swift        # (I2b) iOS-адаптер озвучення з колбеком завершення (macOS SpeechService не змінюється)
    Platform/ InboxLocation.swift (App Group URL із Info.plist-ключа VocabAppGroupID), BackgroundTaskRunner.swift,
              DocumentFiles.swift (FileDocument для .json, копія security-scoped URL)
    Intents/  AddToDictionaryIntent.swift, StartVoiceCaptureIntent.swift, VoiceLanguageAppEnum.swift, VocabShortcuts.swift
  Resources/ Assets.xcassets, en.lproj/{InfoPlist,AppShortcuts}.strings, uk.lproj/{…}
  Tests/     VocabMobileTests (hosted, симулятор)
Extensions/
  Share/   Info.plist, VocabShare.entitlements, Sources/{ShareViewController,ShareView,ShareTextExtractor}.swift
  Widget/  Info.plist, Sources/{VocabWidgetBundle,VoiceCaptureWidget}.swift, Resources/{en,uk}.lproj/Localizable.strings
Config/
  Signing.xcconfig                 # комітиться: дефолти + #include? "Local.xcconfig"
  Local.example.xcconfig           # комітиться: шаблон
  Local.xcconfig                   # НЕ комітиться (.gitignore)
docs/development/manual-tests/I0.md … I5.md
```

`project.yml`: нові таргети `VocabMobile` (application, iOS), `VocabShare` (app-extension), `VocabWidget`
(app-extension, WidgetKit), `VocabMobileTests` (bundle.unit-test, TEST_HOST = VocabMobile); схема `VocabMobile`.
`options.deploymentTarget` + `iOS: "17.0"`. iOS-таргети: `configFiles` → `Config/Signing.xcconfig`,
`CODE_SIGN_STYLE: Automatic`, `CODE_SIGN_IDENTITY` перевизначається на рівні iOS-таргетів (базове `"-"` — для macOS).
Наявні `VocabApp`/`VocabAppTests` не змінюються. Набір таргетів може скоротитися за рішенням I0 (План Б).

Bundle ID (усі з `$(VOCAB_BUNDLE_ID_PREFIX)` — ID глобально унікальні, `com.vocabapp.*` може бути зайнятий):
`<prefix>.VocabMobile`, `<prefix>.VocabMobile.Share`, `<prefix>.VocabMobile.Widget`; App Group `group.<prefix>`
(`$(VOCAB_APP_GROUP)` підставляється в entitlements і в Info.plist-ключ `VocabAppGroupID`, звідки його читає код).

Info.plist `VocabMobile`: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` (локалізовані в
`InfoPlist.strings`), `CFBundleURLTypes` зі схемою `vocabapp` (`vocabapp://voice?lang=en|it`, `vocabapp://add`),
`CFBundleLocalizations = [en, uk]`, `CFBundleDevelopmentRegion = en`. `CFBundleDocumentTypes` («Відкрити в…» для
`.json`) — **відкладено** (поза планом). Share: `NSExtensionActivationRule` — `NSExtensionActivationSupportsText = true`.

---

## 3. Зміни ядра (Linux-тести, Docker `swift:6.0-noble`)

### 3.1 Збірка під iOS (етап I1a)
- `Package.swift`: `platforms: [.macOS(.v13), .iOS(.v17)]`.
- `AppPaths.standard`: `FileManager.homeDirectoryForCurrentUser` **недоступний на iOS** → fallback через
  `URL(fileURLWithPath: NSHomeDirectory())` (є на всіх платформах); поведінка на macOS не змінюється.
- `ProcessingTrigger`: + `.foreground` (повернення на передній план), `.inbox` (після інжесту). **Наслідок:**
  `ProcessingTriggerTests` (явний список `allCases.map(\.rawValue)`) оновлюється — додаються два значення в кінець.
- Інші API ядра, що могли б не зібратися під iOS, не відомі; перевірка — збірка `VocabMobile` у I1a (iU13).

### 3.2 Підказка мови (DI13, етап I2a — лише Linux)
- **Модель.** `Entry` + `public var languageHint: String?` (адитивне опційне поле, схема лишається v1, як D16/D21;
  `encodeIfPresent`; при декодуванні порожнє/нерядкове → `nil`, невідомий код зберігається, але ігнорується при
  використанні). `EntryDraft` + `languageHint: String? = nil`; `Entry.init` + `languageHint: nil` за замовчуванням
  (наявні виклики компілюються). `Entry.sourceLanguage` **не** чіпається — це мова, визначена моделлю (D25).
- **Життєвий цикл.** `AddWordUseCase.execute(rawText:sourceLanguageHint:)` (стара сигнатура делегує з `nil`);
  підказка поза `pair.allowedSourceLanguages` відкидається; pending-запис отримує `languageHint`. Дедуплікація до
  запиту — як D26 (0 запитів). `EntryProcessor` при успіху (`ready`) ставить `languageHint = nil`; pending/failed —
  зберігає (офлайн, повтори, ручний «Повторити»). Редагування (`update`) поле не змінює, крім збереження як ready — тоді підказка очищується.
- **Запит.** `WordLookupService` + `lookup(text:kind:pair:sourceLanguageHint:)` з default-реалізацією в extension,
  що викликає стару (тестові заглушки не ламаються); `ClaudeLookupService` реалізує нову; `EntryProcessor` передає
  `entry.languageHint`. `PromptBuilder.build(text:kind:pair:sourceLanguageHint:)`: якщо підказка `nil`/невідома, пара
  без `renderings` або `pair.prompt.sourceHintInstruction` порожній — промт **байт-у-байт як зараз**. Інакше в кінець
  system додається `sourceHintInstruction` (новий рядок `PromptTemplate`, дефолт `""`, текст у `EnglishUkrainian.swift`,
  ≤ 40 слів: «The user stated the text is {{LANGUAGE_NAME}}; set source_language to "{{LANGUAGE_CODE}}" unless the
  text is clearly not {{LANGUAGE_NAME}}.»). Парсер не змінюється: фінальну `sourceLanguage` визначає відповідь моделі.
- **Transfer.** Експорт пише поле, якщо є; імпорт/merge (D1) переносить його разом із записом-переможцем.
- **`Equatable`/merge (рішення I2a).** Синтезований `Entry ==` поле **враховує** (round-trip у тестах, `Entry`
  ідентичний збереженому). `ImportMerger` `Entry ==` не використовує: збіг — за `id` або (`languagePair`, `key(word)`),
  переможець — строго новіший `updatedAt` + правило «pending/failed не перезаписує ready», «змінилось» — лише
  `sameVariants`. Тому записи, що різняться **лише** `languageHint` (Mac-копія без підказки й iPhone-копія з нею;
  підказку очищено після `ready`), не дають ні конфлікту, ні `updated`: при рівному `updatedAt` — `skipped`, при
  новішому — звичайна заміна D1. Переможець несе власну підказку (заміна — імпортованого, пропуск — локального).
  `DictionaryRepository.update` без `replacingVariants` зберігає збережену підказку (як `variants`), а будь-яке
  збереження як `ready` її очищує (у т. ч. пара без `renderings` і ручне заповнення). Тест —
  `testHintDoesNotCreateSpuriousConflict`.
- **Mac.** Поле ніде не показується. Mac-збірка з новим ядром використовує підказку при обробці імпортованого
  pending-запису (той самий `EntryProcessor`). Старі Mac-збірки (M9/M10) ігнорують невідомий ключ, обробляють запис
  за D25 (без підказки) і при збереженні поле губиться — прийнятно (як варіанти в D21).
- Наслідок D26 лишається: італійське `come` при наявному англійському `come` → дубль (0 запитів), фіксується в I2b.md.

### 3.3 Inbox (`Sources/VocabCore/Inbox/`, етап I3)
```swift
public struct InboxItem: Codable, Equatable, Sendable {   // файл <createdAtMs>-<uuid>.json, version = 1
  public var version: Int; public var id: UUID; public var text: String
  public var languageHint: String?; public var source: InboxSource; public var createdAt: Date
}
public enum InboxSource: String, Codable, Sendable { case share }
public struct InboxStore: Sendable {                       // поверх FileSystem (ін'єкція збоїв у тестах)
  public init(directory: URL, fileSystem: FileSystem, maxPendingItems: Int = 200)
  public func enqueue(_ item: InboxItem) throws            // writeData → .<uuid>.tmp; moveItem → <createdAtMs>-<uuid>.json
                                                           // (ім'я унікальне, ціль не існує → rename атомарний у межах
                                                           // каталогу); > max → InboxError.full; збій → tmp видаляється
  public func pendingItems() throws -> [InboxStoredItem]   // лише *.json (не dot-файли), сортування за createdAt;
                                                           // биті → Rejected/
  public func remove(_ item: InboxStoredItem) throws
}
public struct InboxIngestReport: Equatable, Sendable { public var queued, duplicates, rejected, failed: Int }
public actor InboxIngestor {
  public init(store: InboxStore, repository: DictionaryRepository, processor: PendingQueueProcessor, registry:, settings:)
  public func ingest() async -> InboxIngestReport          // single-flight (§4); кожен item → SelectionValidator →
                                                           // repository.add(pending, languageHint) → remove файл;
                                                           // storage-помилка → файл лишається, прохід зупиняється;
                                                           // потім ОДИН processAll(.inbox), якщо queued > 0
}
```
Текст обрізається до 2000 символів ще в розширенні; валідація (≤ 120 символів, ≤ 8 слів) — при інжесті, відхилені
рахуються в `rejected` і показуються в банері.

### 3.4 Локалізація і гігієна
- Нові ключі `L10nKey` (групи `mobile.*`, `voice.*`, `share.*`, `intent.*`, `inbox.*`) — з тим етапом, що їх вводить.
- `HardcodedStringsScanTests` сканує додатково `Mobile/Sources`, `Extensions/*/Sources` (I1a).
- Новий `RepositoryHygieneTests.testNoDevelopmentTeamCommitted`: у `project.yml` і закомічених `Config/*.xcconfig`
  (крім `Local.xcconfig`) `DEVELOPMENT_TEAM`/`VOCAB_DEVELOPMENT_TEAM` порожні або `$(…)`; `.gitignore` містить
  `Config/Local.xcconfig` (I0).

---

## 4. Потоки й потоки виконання

- **Один процес-писач.** `DictionaryRepository` (actor) живе в `AppContainer.shared` процесу застосунку. UI, голос,
  App Intents (у таргеті застосунку → у його процесі, iU5) і інжест inbox користуються ним же. Share Extension і віджет
  словник не читають і не пишуть.
- **Single-flight.**
  - `AppContainer.ensureLoaded() async`: перший виклик створює й кешує `Task` з `repository.load()`; наступні (UI,
    intent, повторний `.active`) чекають на той самий `Task`. Помилка завантаження кешується як `loadError` (як macOS).
  - `InboxIngestor.ingest()`: actor тримає `private var current: Task<InboxIngestReport, Never>?`; якщо прохід уже
    йде — новий виклик **чекає на нього й повертає той самий звіт** (не запускає другий); після завершення `current = nil`.
    Повторні `.active` (напр. закрили Control Center) не дублюють роботу. Новий файл, що з'явився під час проходу,
    підхопить наступна активація.
  - Паралельно з intent-ами: intent додає слово напряму через `AddWordUseCase` (не через inbox); перевірка дубля +
    вставка атомарні в actor-і репозиторію (§6 ARCHITECTURE), подвійну обробку запису блокує наявний
    `PendingQueueProcessor` (атомарний check+insert, M3; `.skipped` → D17). Тому одночасні `ingest` + intent +
    `processAll(.foreground)` дають не більше 1 запиту на слово.
- **Старт / `scenePhase == .active`:** `ensureLoaded()` → `ingest()` → `processAll(.foreground)` → автопрохід
  доповнення, якщо режим IT (як M7). Під тестами — тимчасовий каталог, `InMemorySecretStore`.
- **Голос:** `VoiceCaptureModel` → `SpeechRecognizing` → підтвердження (DI11/iU15) →
  `AddWordUseCase.execute(rawText:sourceLanguageHint:)` → результат-картка (`NotificationText.make`) з «Озвучити»
  (`SpeechService`, `it-IT`/`en-US`; перед озвученням `AudioSessionController` перемикає категорію на `.playback`).
- **Глибокі посилання:** `vocabapp://voice[?lang=it]` (віджет, intent) → `Router` відкриває `AddWordSheet` у режимі
  голосу і **одразу слухає**, якщо дозволи вже є (інакше — екран запиту дозволу).
- **Конкурентність** — як §11.1 ARCHITECTURE (Swift 5 mode): `MobileAppModel`, `VoiceCaptureModel`, `Router`, views —
  `@MainActor`; колбеки `SFSpeechRecognitionTask` і tap `AVAudioEngine` (не головний потік) → `AsyncStream.Continuation`,
  споживач — головний актор.

---

## 5. Екрани (SwiftUI, iOS 17)

- **Список** (`EntryListView`, `NavigationStack`): `.searchable`; toolbar — сегментний `Picker` EN | IT
  (`displayLanguageID`), меню сортування (`EntrySort`), «+», шестерня. Рядок: слово (жирне) + транскрипція, переклади,
  приклад (`lineLimit(2)`), бейджі «очікує»/«помилка»/«італійська версія очікує» (`EntryDisplay`). Свайпи: трейлінг —
  «Видалити» (підтвердження), «Редагувати»; лідинг — «Повторити» (pending/failed) або «Оновити італійський» (режим IT).
  `.refreshable` → `processAll(.retryAll)`. Плаваюча кнопка мікрофона. Порожній стан; банер інжесту.
- **Додавання** (`AddWordSheet`): поле + «Додати через Claude», мікрофон з EN | IT; «Заповнити вручну» →
  `EntryEditView` (D14, статус ready).
- **Голос** (`VoiceCaptureView`): мікрофон з індикатором рівня, живий частковий текст, після зупинки — редаговане поле,
  «Додати» / «Ще раз»; результат-картка. (Опційно — чипи альтернатив.)
- **Деталі** (`EntryDetailView`): усі поля, озвучення слова й прикладу, редагування, повтор, видалення, «Оновити
  італійський переклад» (1 явний запит, як M7).
- **Налаштування** (`SettingsView`, `Form`): API-ключ (`SecureField`, зберегти/видалити, статус), модель (+ скидання),
  мова голосу за замовчуванням, мова інтерфейсу (миттєво, DI14), дані: «Експортувати» (`fileExporter` — через нього ж
  доступні Files і AirDrop), «Імпортувати» (`fileImporter` → merge/replace, D1/§10), шлях даних і кількість бекапів.
  Теми немає (DI19).

---

## 6. Підпис і локальна конфігурація (team ID не потрапляє в публічний репо)

- `Config/Signing.xcconfig` (комітиться):
  `VOCAB_DEVELOPMENT_TEAM =` · `VOCAB_BUNDLE_ID_PREFIX = com.example.vocab` · `#include? "Local.xcconfig"` ·
  `DEVELOPMENT_TEAM = $(VOCAB_DEVELOPMENT_TEAM)` · `VOCAB_APP_GROUP = group.$(VOCAB_BUNDLE_ID_PREFIX)`.
- `Config/Local.example.xcconfig` (комітиться) — шаблон з коментарями; користувач копіює в `Config/Local.xcconfig`
  (у `.gitignore`) і вписує свій Team ID та унікальний префікс (напр. `com.<нік>.vocab`).
- Як дізнатися Team ID: Xcode → Settings → Accounts → додати Apple ID → «Personal Team»; відкрити проєкт → таргет
  `VocabMobile` → Signing & Capabilities → обрати команду → Build Settings → `DEVELOPMENT_TEAM` (10 символів) —
  скопіювати в `Local.xcconfig` (ручний вибір у Xcode зникає при `xcodegen generate`, файл — ні).
- Перехід на платний акаунт: змінити `VOCAB_DEVELOPMENT_TEAM` (і за бажання префікс) → `xcodegen generate` → Run.
  Код і `project.yml` не змінюються.
- Що користувач має зробити: Mac з Xcode 16+, `brew install xcodegen`; iPhone на iOS 17+; кабель; на iPhone —
  Settings → Privacy & Security → **Developer Mode** (перезавантаження); після першої установки — Settings → General
  → VPN & Device Management → довірити сертифікат розробника; кожні 7 днів — повторний Run з Xcode (дані
  зберігаються, якщо застосунок не видаляти; перед цим бажано зробити експорт).

---

## 7. Етапи

Кожен етап (крім I2a) закінчується **промтом для Mac** (користувач виконує й повертає вивід):
```
git pull && xcodegen generate
xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
xcodebuild test -project VocabApp.xcodeproj -scheme VocabMobile -destination 'platform=iOS Simulator,name=iPhone 16'
# пристрій: Xcode → схема VocabMobile → обраний iPhone → Run (або xcodebuild … -destination 'platform=iOS,name=<iPhone>'
#           -allowProvisioningUpdates build), далі ручний чекліст docs/development/manual-tests/I<N>.md
```
Linux: `docker run --rm -v "$PWD":/w -w /w swift:6.0-noble swift test` — після кожного етапу, 0 падінь.

### I0 — Спайк підпису й можливостей (~1 день)
Мета — до справжньої роботи закрити iU1/iU2/iU3/iU8 на iPhone користувача з Personal Team і вирішити План Б.
**Файли:** `project.yml` (iOS-таргети), `Config/{Signing,Local.example}.xcconfig`, `.gitignore`,
`RepositoryHygieneTests.swift`, мінімальні `Mobile/Sources/VocabMobileApp.swift` (екран: «App Group: OK/недоступний» —
`containerURL(forSecurityApplicationGroupIdentifier:)` + запис/читання пробного файлу; список пробних файлів від
розширення), `Extensions/Share/Sources/ShareViewController.swift` (пише пробний файл у App Group і закривається),
`Extensions/Widget/Sources/VocabWidgetBundle.swift` (статичний віджет з `widgetURL(vocabapp://voice)`),
entitlements, `Mobile/Tests/SpikeTests.swift` (`testAppLaunches`), `I0.md`. Без залежності від `VocabCore` (ізолюємо
питання підпису). Код спайка замінюється в I1a; `project.yml`/`Config` лишаються.
| КП | Перевірка |
|---|---|
| I0.1 Team ID не в репо | `RepositoryHygieneTests.testNoDevelopmentTeamCommitted` (Linux) |
| I0.2 Симулятор | `xcodebuild test` схеми `VocabMobile` проходить (якщо ні — повторити з `CODE_SIGNING_ALLOWED=NO`, зафіксувати як iU8) |
| I0.3 Пристрій | `I0.md`: установка всіх трьох таргетів з Personal Team; «App Group: OK» у застосунку; «Поділитися» з Safari → пробний файл видно в застосунку; віджет на Home і Lock Screen відкриває застосунок; скільки безкоштовних застосунків уже на телефоні і чи рахуються розширення (iU2); помилки Xcode — дослівно |
**Рішення за результатом (фіксується в `PROGRESS.md`):**
- App Group не працює → **Share Extension прибирається**; замість неї — ярлик Shortcuts «Отримати текст із листа
  Поділитися → Add to Dictionary» (intent з I4, App Group не потрібен). I3 скорочується до ядра `Inbox/` — або
  `Inbox/` теж відкладається.
- Ліміт застосунків/App ID заважає → зменшуємо кількість таргетів: спершу прибираємо віджет (його замінює ярлик
  Shortcuts на Home Screen / Action Button з `StartVoiceCaptureIntent`), далі — Share (як вище).
- Усе працює → план без змін.

### I1a — Ядро на iOS + каркас + список (лише читання)
**Файли:** `Package.swift`, `AppPaths.swift`, `ProcessingTrigger.swift`, `ProcessingTriggerTests.swift`,
`HardcodedStringsScanTests.swift`, `L10n*` (`mobile.*` базові), `Mobile/Sources/{VocabMobileApp,AppContainer,
MobileAppModel,Router}.swift`, `Views/{EntryListView,EntryRowView}`, `I1a.md`.
| КП | Перевірка |
|---|---|
| I1a.1 Ядро збирається під iOS, Linux зелений | збірка `VocabMobile`; `ProcessingTriggerTests` (оновлений список з `foreground`, `inbox`), `LocalizationTests`, `HardcodedStringsScanTests` (нові каталоги) |
| I1a.2 Завантаження й список | `MobileAppModelTests`: `testLoadsEntriesFromTemporaryDirectory`, `testSearchAndSortUseEntryQuery`, `testDisplayLanguageSwitchShowsVariants`, `testEmptyStateWhenNoFile` |
| I1a.3 Single-flight завантаження | `AppContainerTests.testConcurrentEnsureLoadedLoadsOnce`, `testLoadErrorSurfaced` |
`I1a.md`: установка на iPhone, запуск, порожній стан (дані з Mac на пристрій потраплять лише через імпорт I5).

### I1b — CRUD, Claude, Settings/Keychain
**Файли:** `MobileAppModel`, `Views/{AddWordSheet(без мікрофона),EntryDetailView,EntryEditView,SettingsView}`,
`Platform/BackgroundTaskRunner`, `L10n*`, `I1b.md`. Тема — системна (DI19).
| КП | Перевірка |
|---|---|
| I1b.1 CRUD і свайпи | `testManualAddReady`, `testEditKeepsVariants`, `testDeleteRemovesEntry`, `testRetryCallsProcessorOnce`, `testBackfillOnlyInItalianMode` |
| I1b.2 Claude: 1 запит / дубль 0 | `testAddViaClaudeMakesOneRequest`, `testDuplicateMakesNoRequest` (копія `MockURLProtocol` у `Mobile/Tests/Support`) |
| I1b.3 Ключ у Keychain | `KeychainMobileTests`: `testSaveReadDeleteKey` (унікальний `service`), `testKeyNeverInUserDefaults` |
| I1b.4 Мова миттєво | `testInterfaceLanguageSwitchChangesRootIdentity`, `testInterfaceLanguagePersisted` |
`I1b.md`: ключ, ручне й Claude-додавання, редагування/видалення, перезапуск — дані на місці; macOS-регресія зелена.

### I2a — Підказка мови в ядрі (лише Linux, без iOS-коду)
**Файли:** `Models/{Entry,EntryDraft}.swift`, `UseCases/AddWordUseCase.swift`, `Claude/{ClaudeLookupService,
PromptBuilder}.swift`, `Languages/{LanguagePair,EnglishUkrainian}.swift`, `Processing/EntryProcessor.swift`,
`Transfer/ImportMerger.swift` (перенесення поля), `Repository/DictionaryRepository.swift` (копіювання з draft, збереження при update, очищення на ready). Тести — нові `LanguageHintTests.swift`.
| КП | Перевірка (Linux) |
|---|---|
| I2a.1 Промт без підказки незмінний | `testPromptWithoutHintIsByteIdentical`, `testHintAppendedOnceForPairWithRenderings`, `testUnknownHintIgnored`, `testHintIgnoredForPairWithoutRenderings` |
| I2a.2 Модель і формат | `testEntryWithoutHintEncodesUnchanged` (байти як до I2a), `testHintRoundTrips`, `testEmptyHintDecodesNil`, `testSourceLanguageUntouchedByHint` |
| I2a.3 Життєвий цикл | `testUseCaseStoresHintOnPendingEntry`, `testHintClearedWhenReady`, `testHintKeptOnFailedAndOffline`, `testManualRetryUsesHint`, `testImportCarriesHint` |
| I2a.4 Токени | `testHintedWordMakesExactlyOneRequest`, `testSpokenItalianDuplicateOfReadyVariantMakesNoRequest` (лічильник `MockURLProtocol`) |
Наявні тести ядра не змінюються (нові параметри мають дефолти).

### I2b — Голосове введення (UI)
**Файли:** `Mobile/Sources/Voice/*`, `VoiceCaptureView`, `AddWordSheet`, Info.plist-дозволи, `InfoPlist.strings`,
`L10n*` (`voice.*`), `I2b.md`.
| КП | Перевірка |
|---|---|
| I2b.1 Стан-машина | `VoiceCaptureModelTests` (FakeSpeechRecognizer, ін'єктований годинник): `testPermissionDeniedShowsSettingsLink`, `testPartialThenFinalFillsEditableText`, `testAutoStopAfterSilence`, `testMaxDurationStops`, `testTapStopsListening`, `testSubmitCallsUseCaseOnceWithLanguageHint`, `testEmptyRecognitionDoesNotSubmit`, `testLanguageToggleRemembered`, `testCancelStopsEngine` |
| I2b.2 On-device пріоритет | `RecognitionConfigTests`: `testOnDeviceRequiredWhenSupported`, `testServerFallbackFlagged`, `testOfflineWithoutOnDeviceShowsError` |
| I2b.3 Дозволи | `InfoPlistMobileTests.testUsageDescriptionsPresentInBothLocalizations` |
| I2b.4 (лише якщо iU15 = автододавання) | `testAutoAddOnlyForHighConfidenceSingleItem`, `testUndoDeletesAddedEntry` |
`I2b.md` (пристрій): `run`, `casa`, `perché`, `come` (EN і IT), `take off`; тиша/шум; авіарежим з/без on-device; відмова
в дозволі; озвучення одразу після запису (iU14).

### I3 — Share Extension + inbox (якщо I0 підтвердив App Group)
**Файли:** ядро `Inbox/*`; `Extensions/Share/*`, `Platform/InboxLocation.swift`, `MobileAppModel` (інжест на `.active`),
`InboxBanner`, `L10n*` (`share.*`, `inbox.*`), `I3.md`.
| КП | Перевірка |
|---|---|
| I3.1 Атомарний inbox (Linux) | `InboxStoreTests`: `testEnqueueWritesTempThenMovesToUniqueName`, `testTempAndDotFilesIgnored`, `testFailedMoveRemovesTemp`, `testItemsSortedByCreatedAt`, `testCorruptFileMovedToRejected`, `testFullInboxThrows` |
| I3.2 Інжест (Linux) | `InboxIngestorTests`: `testNewWordsQueuedThenOneProcessAll`, `testDuplicateRemovedWithoutRequest`, `testRejectedCounted`, `testStorageFailureKeepsFile`, `testCrashBetweenAddAndRemoveIsIdempotent`, `testHintStoredAsLanguageHint`, `testConcurrentIngestCallsShareOneRun`, `testIngestConcurrentWithAddWordMakesOneRequestPerWord` |
| I3.3 Вилучення тексту | `ShareTextExtractorTests` (чиста функція над кандидатами: `attributedContentText`, plain-text, URL ігнорується): `testPrefersSelectedText`, `testTruncatesTo2000`, `testEmptyShareRejected` |
| I3.4 Інжест при активації | `MobileAppModelInboxTests`: `testActivePhaseIngestsAndShowsBanner`, `testRepeatedActiveDoesNotDuplicate`, `testNoAppGroupDisablesInboxGracefully` |
`I3.md`: Safari (виділення → Поділитися), Notes, Telegram, Chrome; застосунок закритий/відкритий; 3 слова поспіль; дубль;
авіарежим.

### I4 — App Intents (Siri / Shortcuts) + віджет
**Файли:** `Mobile/Sources/Intents/*`, `AppShortcuts.strings`, `Extensions/Widget/*`, `Router` (`DeepLink.parse`), `I4.md`.
- `AddToDictionaryIntent`: `@Parameter text: String`, `@Parameter language: VoiceLanguageAppEnum?` (Auto/English/Italian),
  `openAppWhenRun = false`, `authenticationPolicy = .requiresAuthentication` (Keychain `WhenUnlocked`); `perform` →
  `ensureLoaded()` → `AddWordUseCase.execute(rawText:sourceLanguageHint:)` → діалог із `NotificationText.make(for:)`.
  Довгий запит: через 8 с відповідає «Збережено, перекладається» (запис уже pending).
- `StartVoiceCaptureIntent`: `openAppWhenRun = true`, `perform` (`@MainActor`) → `Router.open(.voiceCapture(lang))`.
- `VocabShortcuts: AppShortcutsProvider` — фрази з `\(.applicationName)` (рядок-параметр у фразу не вбудовується; Siri
  перепитає «Яке слово?»).
- `VoiceCaptureWidget`: `StaticConfiguration`, `.systemSmall`, `.accessoryCircular`, `.accessoryRectangular`; одна
  timeline-entry `.never`; `widgetURL(vocabapp://voice)`. Віджет не пише звук і не має App Group.
| КП | Перевірка |
|---|---|
| I4.1 Intent: 1 запит | `AddToDictionaryIntentTests`: `testPerformAddsWordWithOneRequest`, `testPerformDuplicateNoRequest`, `testEmptyTextRejectedDialog`, `testItalianParameterPassedAsHint`, `testSlowLookupReturnsQueuedDialog` |
| I4.2 Відкриття голосу | `StartVoiceCaptureIntentTests.testPerformRoutesToVoiceCapture`; `DeepLinkTests`: `testVoiceURL`, `testVoiceURLWithLanguage`, `testUnknownURLIgnored` |
| I4.3 URL-схема | `InfoPlistMobileTests.testURLSchemeRegistered` |
`I4.md`: Shortcuts (обидві дії), Siri англійською, Action Button (якщо є), віджет на Home і Lock Screen → одразу слухає;
заблокований телефон; ярлик із листа «Поділитися» (обов'язково, якщо I0 прибрав Share Extension).

### I5 — Експорт/імпорт, полірування, README
**Файли:** `Platform/DocumentFiles.swift`, `SettingsView`, `ImportModeDialog`, README (`## iPhone` у `README.md` і
`README.uk.md`: вимоги, `Local.xcconfig`, установка, 7 днів, синхронізація з Mac, видалення не синхронізуються), `I5.md`.
| КП | Перевірка |
|---|---|
| I5.1 Експорт = схема v1 | `MobileTransferTests.testExportRoundTripsThroughCoreImporter` (семантичне порівняння: ті самі записи, поля, варіанти, `languageHint`; не байти), `testExportFileNameAndContentType` |
| I5.2 Імпорт merge/replace | `testImportCopiesSecurityScopedFileBeforeReading`, `testMergeReportShown`, `testReplaceMakesBackup`, `testImportedPendingProcessedOnce` |
`I5.md`: Mac → AirDrop/Files → iPhone (merge, replace), iPhone → `fileExporter` (Files/AirDrop) → Mac (імпорт у
macOS-застосунку), конфлікти D1, варіанти IT збережено, повторна установка через 7 днів — дані на місці.

---

## 8. Економія токенів (без змін правил)

Нове слово з будь-якого входу (голос, текст, Share, Intent) — **1** комбінований запит (EN+IT); дубль за будь-яким
`dedupKey` — **0**; підказка мови — без додаткових запитів; варіанти старих записів — лише пакетами в режимі IT або
явною дією; IT/QA-контекст (M8) — у тих самих промтах ядра. Перевірка — лічильник `MockURLProtocol` (I1b, I2a, I3, I4).

---

## 9. Ризики

- **Без CI для iOS:** кожен етап компілюється лише на Mac користувача → малі етапи, протоколи з фейками, максимум логіки
  в ядрі (Linux). Помилки компіляції повертаються як вивід `xcodebuild` у наступну ітерацію.
- **Personal Team:** 7-денний профіль, ліміти застосунків/App ID (iU2), можлива недоступність App Groups (iU1) — усе
  перевіряє I0 до основної роботи; План Б — там само.
- **Розпізнавання мовлення:** якість окремих слів без контексту, особливо італійських; on-device для `it-IT` може бути
  недоступним (iU4). Мітигація — підтвердження (DI11) і редаговане поле.
- **Siri не підтримує українську** — голосові фрази лише англійською (iU7).
- **Розходження з Mac** до ручної синхронізації: конфлікти — D1 (updatedAt); видалення не синхронізуються — у README.
- **Регресія macOS:** macOS-файли не переміщуються й не змінюються; зміни ядра адитивні. Наявні тести ядра змінюються
  **лише** там, де вони перелічують значення: `ProcessingTriggerTests` (список `allCases` + `.foreground`, `.inbox`) і
  `HardcodedStringsScanTests` (нові каталоги). Решта — без змін; нові параметри мають дефолти, кодування запису без
  `languageHint` байт-у-байт як раніше.

---

## 10. Відкриті питання (→ `PROGRESS.md` після затвердження)

- **iU1** Чи дозволяє Personal Team capability **App Groups** для застосунку й Share Extension. Очікую «так», не
  впевнений. Закриває I0.
- **iU2** Ліміти Personal Team: скільки застосунків з безкоштовним профілем одночасно на пристрої (відомо про ~3) і чи
  рахуються розширення; ліміт нових App ID (~10 за 7 днів) — не міняти префікс без потреби. Закриває I0.
- **iU3** Чи потребують WidgetKit та App Intents/App Shortcuts entitlements, недоступних Personal Team (очікую — ні;
  Siri-entitlement потрібен лише SiriKit, який не використовуємо). Віджет — I0, intents — I4.
- **iU4** On-device розпізнавання `it-IT`/`en-US` на iPhone користувача (`supportsOnDeviceRecognition`), чи можна
  завантажити модель мовлення, ліміти серверного розпізнавання.
- **iU5** Що App Intents з таргету застосунку (`openAppWhenRun = false`) виконуються **в процесі застосунку** (фоновий
  запуск) і чи встигає `ensureLoaded()`; ліміт часу intent-а для Siri.
- **iU6** Як Safari/Notes/Telegram/Chrome віддають виділений текст (`public.plain-text` чи `attributedContentText`);
  чи Telegram показує наше розширення.
- **iU7** Siri не підтримує українську; як Siri англійською розпізнає італійські слова (ймовірно погано → для IT —
  in-app голос).
- **iU8** Симулятор: чи проходить `xcodebuild test` з entitlement App Groups без команди; План Б —
  `CODE_SIGNING_ALLOWED=NO`. Закриває I0.
- **iU10** Чи потрібна фонова обробка inbox (`BGAppRefreshTask`) — вирішить користувач після I3.
- **iU12** Модель iPhone і версія iOS користувача (≥ 17?); версія Xcode на Mac (≥ 16?).
- **iU13** Чи немає в ядрі інших macOS-only API, крім `homeDirectoryForCurrentUser` (виявить збірка I1a).
- **iU14** `AVAudioSession` (запис) і `AVSpeechSynthesizer` (озвучення одразу після запису) на пристрої.
- **iU15 (питання користувачу)** Голос: (а) завжди підтверджувати розпізнане перед додаванням, чи (б) додавати одразу,
  коли розпізнавання впевнене і це одне слово/фраза, з банером «Скасувати»? У плані за замовчуванням — (а).

(iU9 і iU11 зняті разом із темою та `CFBundleDocumentTypes`.)

## 11. Що потрібно від користувача для старту

1. Затвердити план (або змінити DI7/DI10/DI13/DI14) і відповісти на **iU15**. 2. Відповісти на iU12 (модель iPhone,
iOS, Xcode) і чи є/буде платний акаунт. 3. Підготувати Mac (Xcode 16+, xcodegen), iPhone (Developer Mode), Apple ID у
Xcode, `Config/Local.xcconfig` — і виконати спайк I0.
