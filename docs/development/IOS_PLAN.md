# IOS_PLAN — VocabApp для iPhone (план, на затвердження користувачем)

Статус: **план, без коду**. Мова — українська, ідентифікатори — англійською. Базовий документ — `ARCHITECTURE.md`
(усі D1–D40 і правила економії токенів M7/M8 діють і тут). Рішення цього плану — `DI1…`, відкриті питання — `iU1…`
(після затвердження переносяться в `PROGRESS.md`).

Запит користувача: той самий словник на iPhone + **голосове введення** («кажу слово — воно додається й перекладається»),
плюс «Поділитися», Siri/Shortcuts, віджет. Синхронізація з Mac — **вручну** через `dictionary.json` (схема v1).

---

## 1. Ключові рішення (коротко)

| # | Питання | Рішення |
|---|---|---|
| DI1 | Мінімальна iOS | **iOS 17** (`AVAudioApplication`, інтерактивні/Lock Screen віджети з `containerBackground`, зрілі App Intents). Потрібен iPhone XS/XR або новіший (iU12). Xcode **16+** (симулятор iPhone 16). |
| DI2 | Обліковий запис Apple | Проєктуємо під **безкоштовний Apple ID** (Personal Team): установка кабелем з Xcode, профіль діє 7 днів. Нічого не використовує iCloud/CloudKit/Push/Associated Domains/Siri-entitlement. Перехід на платний акаунт = лише зміна `DEVELOPMENT_TEAM` у локальному `Config/Local.xcconfig` (§6). |
| DI3 | Ядро | `VocabCore` лишається Foundation-only і Linux-тестованим; додається `.iOS(.v17)` у `Package.swift`. Зміни ядра — малі, адитивні, з тестами на Linux (§3). |
| DI4 | Спільний Apple-код | **Без переміщення файлів macOS.** iOS-таргет підключає за шляхом уже платформонезалежні файли з `App/Sources/Platform/`: `KeychainSecretStore.swift` (Security), `SpeechService.swift` (AVFoundation), `OSLogSink.swift` (os), `NetworkMonitor.swift` (Network). macOS-таргет не змінюється → нуль ризику регресії Mac. Перенесення в `Shared/` — можливе пізніше, окремим кроком. |
| DI5 | `AppModel` | macOS `AppModel` **не рефакторимо** (залежить від AppKit-панелей, LoginItem тощо). Для iOS — окремий `MobileAppModel` поверх тих самих use-case ядра. Логіку, яку хочеться спільною, виносимо в ядро, а не в спільний UI-шар. |
| DI6 | Де живе `dictionary.json` на iPhone | У **власному контейнері застосунку** (`Application Support/VocabApp/`, як на Mac) — не в App Group. Єдиний процес, що пише словник, — застосунок. Розширення в словник **не пишуть** (§4). |
| DI7 | Share Extension і Claude | Розширення **не викликає Claude** і не бачить API-ключ. Воно лише кладе слово в **inbox** (файл у App Group); застосунок забирає inbox при активації і обробляє через наявну чергу pending. Обґрунтування: ліміти пам'яті/часу розширення (система може вбити його після закриття листа «Поділитися» посеред HTTP), не потрібен Keychain access group, немає міжпроцесних записів у `dictionary.json`, той самий шлях «спершу зберегти як pending» гарантує, що слово не губиться. Ціна: переклад з'явиться, коли користувач відкриє застосунок (сповіщень немає — DI15). |
| DI8 | API-ключ | Keychain лише застосунку (наявний `KeychainSecretStore`, `service = "<bundle id застосунку>"`). **Keychain sharing / access groups не потрібні** (DI7). Intent-и виконуються в процесі застосунку і читають той самий елемент. |
| DI9 | Міжпроцесна безпека | Немає спільного файлу з кількома писачами: кожен елемент inbox — **окремий файл** з унікальним ім'ям, запис через тимчасовий файл + `rename` (атомарно), єдиний споживач — застосунок. `NSFileCoordinator` і блокування не потрібні. Обробка ідемпотентна: падіння між «додати» і «видалити файл» → при наступному проході запис виявиться дублем (0 запитів). |
| DI10 | Голос: жест | **Tap-to-talk з автозупинкою**: торкнутися мікрофона → слухає; зупинка повторним дотиком, після ~1,5 с тиші після останнього часткового результату або через 10 с. Причини: працює однією рукою і з VoiceOver; підходить для запуску з віджета/Siri (одразу слухає без утримання); у sheet немає конфлікту жестів. Hold-to-talk не робимо. |
| DI11 | Голос: підтвердження | Розпізнаний текст **завжди** показується в редагованому полі (+ до 3 альтернатив-«чипів» з `transcriptions`) і додається лише кнопкою «Додати». Автододавання — ні (помилки розпізнавання коштували б токени). |
| DI12 | Голос: розпізнавання | `SFSpeechRecognizer(locale: en-US | it-IT)` + `AVAudioEngine` + `SFSpeechAudioBufferRecognitionRequest`, `shouldReportPartialResults = true`, `requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition`. Якщо on-device недоступне — серверне розпізнавання Apple з позначкою «розпізнавання через Apple» під полем; офлайн без on-device → зрозуміла помилка й поле для ручного введення. Перемикач **EN \| IT** поруч з мікрофоном запам'ятовується (`UserDefaults`, ключ `voiceLanguage`, лише в iOS-застосунку). |
| DI13 | Мова мовлення як підказка Claude | **Так, передаємо** (`sourceLanguageHint`): мовлення однозначно задає мову, а без підказки неоднозначні слова (`come`, `pane`, `no`) за D25 стали б англійськими. Підказка — одне речення в **тому самому** system-промті (≈25 вхідних токенів), **кількість запитів не змінюється** (1 на нове слово, 0 для дубля). Текст підказки — у визначенні пари в ядрі (розширюваність). Підказка зберігається в pending-записі (`Entry.sourceLanguage`), тож переживає офлайн і повтори. Деталі — §3.2. |
| DI14 | Мова інтерфейсу на iOS | Той самий `L10n` (EN за замовчуванням / UK). Застосовується **миттєво**: iOS не дозволяє програмний перезапуск, тому корінь UI має `.id(interfaceLanguage)` і перебудовується. Системні рядки (`fileImporter`, лист «Поділитися», Info.plist-дозволи) — мовою системи / налаштування мови застосунку в iOS Settings (`CFBundleLocalizations = en, uk`). |
| DI15 | Сповіщення | У I1–I5 **немає** локальних сповіщень (усе показується в UI; без зайвого запиту дозволу). Фонова обробка inbox (`BGAppRefreshTask`) — поза планом, кандидат на майбутнє (iU10). |
| DI16 | Пагінація | На iOS — без сторінок: `List` по всьому результату `EntryQuery.apply` (лінива відрисовка). `Pagination` ядра не використовується. |
| DI17 | Локалізація поза `L10n` (виняток із D33) | Рядки, які читає **система**, а не наш код: `InfoPlist.strings` (дозволи мікрофона/мовлення, назва), фрази `AppShortcuts.strings`, `configurationDisplayName`/`description` віджета. Лише вони — у `en.lproj`/`uk.lproj`; увесь інший текст — ключі `L10n`. Siri українською не працює (iU7) — фрази `uk` все одно додаємо для Shortcuts. |
| DI18 | Фон і обрив запиту | Додавання/інжест обгортаються в `UIApplication.beginBackgroundTask` (протокол `BackgroundTaskRunning`). Якщо система все ж призупинить процес — запис уже `pending`, його добере тригер `.foreground`. |

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
                                   # use-cases, MobileAppModel; lazy, щоб працювати і з UI, і з App Intents
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
    Platform/ InboxLocation.swift (App Group URL із Info.plist-ключа VocabAppGroupID), ColorSchemeApplier.swift,
              BackgroundTaskRunner.swift, DocumentFiles.swift (FileDocument для .json, копія security-scoped URL)
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
docs/development/manual-tests/I1.md … I5.md
```

`project.yml`: нові таргети `VocabMobile` (application, iOS), `VocabShare` (app-extension), `VocabWidget`
(app-extension, WidgetKit), `VocabMobileTests` (bundle.unit-test, TEST_HOST = VocabMobile); схема `VocabMobile`.
`options.deploymentTarget` + `iOS: "17.0"`. iOS-таргети: `configFiles` → `Config/Signing.xcconfig`,
`CODE_SIGN_STYLE: Automatic`, `CODE_SIGN_IDENTITY` не задається (базове `"-"` перевизначається на рівні iOS-таргетів).
Наявні `VocabApp`/`VocabAppTests` не змінюються.

Bundle ID (усі з `$(VOCAB_BUNDLE_ID_PREFIX)` — ID глобально унікальні, `com.vocabapp.*` може бути зайнятий):
`<prefix>.VocabMobile`, `<prefix>.VocabMobile.Share`, `<prefix>.VocabMobile.Widget`; App Group `group.<prefix>.vocab`
(`$(VOCAB_APP_GROUP)` підставляється в entitlements і в Info.plist-ключ `VocabAppGroupID`, звідки його читає код).

Info.plist `VocabMobile`: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` (локалізовані в
`InfoPlist.strings`), `CFBundleURLTypes` зі схемою `vocabapp` (`vocabapp://voice?lang=en|it`, `vocabapp://add`),
`CFBundleDocumentTypes` для `public.json` (відкриття файлу з AirDrop/Files → діалог імпорту, I5),
`CFBundleLocalizations = [en, uk]`, `CFBundleDevelopmentRegion = en`. Share: `NSExtensionActivationRule` —
`NSExtensionActivationSupportsText = true` (+ `…WebPageWithMaxCount = 0`).

---

## 3. Зміни ядра (Linux-тести, Docker `swift:6.0-noble`)

### 3.1 Збірка під iOS
- `Package.swift`: `platforms: [.macOS(.v13), .iOS(.v17)]`.
- `AppPaths.standard`: `FileManager.homeDirectoryForCurrentUser` **недоступний на iOS** → fallback через
  `URL(fileURLWithPath: NSHomeDirectory())` (є на всіх платформах); поведінка на macOS не змінюється.
- `ProcessingTrigger`: + `.foreground` (повернення застосунку на передній план), `.inbox` (після інжесту inbox).
- Інші API ядра, які могли б не зібратися під iOS, не відомі; перевірка — збірка `VocabMobile` у I1 (iU13).

### 3.2 Підказка мови (DI13)
- `EntryDraft` + `public var sourceLanguage: String? = nil` (дефолт → наявні виклики компілюються).
- `AddWordUseCase.execute(rawText:sourceLanguageHint:)` (стара сигнатура делегує з `nil`). Підказка, якої нема в
  `pair.allowedSourceLanguages`, відкидається. Pending-запис отримує `sourceLanguage = hint`. Дедуплікація до запиту —
  як D26 (усі `dedupKeys`, 0 запитів).
- `WordLookupService` + `lookup(text:kind:pair:sourceLanguageHint:)` з default-реалізацією в extension, що викликає
  стару (тестові заглушки не ламаються); `ClaudeLookupService` реалізує нову. `EntryProcessor` передає
  `entry.sourceLanguage` як підказку **лише** для запису зі статусом `pending/failed` (ready не обробляється).
- `PromptBuilder.build(text:kind:pair:sourceLanguageHint:)`: якщо підказка `nil`, пара без `renderings` або
  `pair.prompt.sourceHintInstruction` порожній — промт **байт-у-байт як зараз**. Інакше в кінець system додається
  `sourceHintInstruction` з підставленими `{{LANGUAGE_CODE}}`/`{{LANGUAGE_NAME}}` (новий рядок у `PromptTemplate`,
  дефолт `""`, текст — у `EnglishUkrainian.swift`, ≤ 40 слів: «The user stated the text is {{LANGUAGE_NAME}};
  set source_language to "{{LANGUAGE_CODE}}" unless the text is clearly not {{LANGUAGE_NAME}}.»). Парсер не змінюється
  (відповідь моделі, як і раніше, визначає фінальну `sourceLanguage`).
- Наслідок D26 лишається: італійське `come` при наявному англійському `come` → дубль (0 запитів), фіксується в I2.md.

### 3.3 Inbox (`Sources/VocabCore/Inbox/`)
```swift
public struct InboxItem: Codable, Equatable, Sendable {   // файл <createdAtMs>-<uuid>.json, version = 1
  public var version: Int; public var id: UUID; public var text: String
  public var languageHint: String?; public var source: InboxSource; public var createdAt: Date
}
public enum InboxSource: String, Codable, Sendable { case share, shortcut }
public struct InboxStore: Sendable {                       // поверх FileSystem (ін'єкція збоїв у тестах)
  public init(directory: URL, fileSystem: FileSystem, maxPendingItems: Int = 200)
  public func enqueue(_ item: InboxItem) throws            // .<uuid>.tmp → replaceItem → <…>.json; > max → InboxError.full
  public func pendingItems() throws -> [InboxStoredItem]   // лише *.json, сортування за createdAt; биті → Rejected/
  public func remove(_ item: InboxStoredItem) throws
}
public struct InboxIngestReport: Equatable, Sendable { public var queued, duplicates, rejected, failed: Int }
public final class InboxIngestor: Sendable {
  public init(store: InboxStore, repository: DictionaryRepository, processor: PendingQueueProcessor, registry:, settings:)
  public func ingest() async -> InboxIngestReport          // кожен item → SelectionValidator → repository.add(pending,
                                                           // sourceLanguage: hint) → remove файл; storage-помилка → файл
                                                           // лишається, прохід зупиняється; потім ОДИН processAll(.inbox)
}
```
Текст розширення обрізається до 2000 символів ще до запису; валідація (≤ 120 символів, ≤ 8 слів) — при інжесті,
відхилені рахуються в `rejected` і показуються в банері.

### 3.4 Локалізація і гігієна
- Нові ключі `L10nKey` (групи `mobile.*`, `voice.*`, `share.*`, `intent.*`, `inbox.*`) у `L10nEnglish`/`L10nUkrainian`.
- `HardcodedStringsScanTests` сканує додатково `Mobile/Sources`, `Extensions/*/Sources`.
- Новий `RepositoryHygieneTests.testNoDevelopmentTeamCommitted`: у `project.yml` і закомічених `Config/*.xcconfig`
  (крім `Local.xcconfig`) `DEVELOPMENT_TEAM`/`VOCAB_DEVELOPMENT_TEAM` порожні або `$(…)`; `.gitignore` містить
  `Config/Local.xcconfig`.

---

## 4. Потоки й потоки виконання

- **Один процес-писач.** `DictionaryRepository` (actor) живе в `AppContainer.shared` процесу застосунку. UI, голос,
  App Intents (вони в таргеті застосунку → виконуються в його процесі, iU5) і інжест inbox користуються ним же.
  Share Extension і віджет у словник не пишуть і його не читають.
- **Старт / `scenePhase == .active`:** `repository.load()` (раз) → `InboxIngestor.ingest()` → `processAll(.foreground)`
  → автопрохід доповнення, якщо режим IT (як M7). Під тестами — тимчасовий каталог, `InMemorySecretStore`.
- **Голос:** `VoiceCaptureModel` → `SpeechRecognizing` (AsyncStream оновлень на головному акторі) → користувач
  підтверджує → `AddWordUseCase.execute(rawText:sourceLanguageHint:)` → результат-картка (`NotificationText.make`
  для заголовка/тексту) з кнопкою «Озвучити» (`SpeechService`, `it-IT`/`en-US`; перед озвученням
  `AudioSessionController` перемикає категорію на `.playback`).
- **Глибокі посилання:** `vocabapp://voice[?lang=it]` (віджет, Intent) → `Router` відкриває `AddWordSheet` у режимі
  голосу і **одразу починає слухати**, якщо дозволи вже надано (інакше — екран запиту дозволу).
- **Конкурентність** — як §11.1 (Swift 5 mode): `MobileAppModel`, `VoiceCaptureModel`, `Router`, views — `@MainActor`;
  колбеки `SFSpeechRecognitionTask` і tap `AVAudioEngine` приходять не на головному потоці → передаються в
  `AsyncStream.Continuation` (потокобезпечний), споживач — головний актор.

---

## 5. Екрани (SwiftUI, iOS 17)

- **Список** (`EntryListView`, `NavigationStack`): `.searchable`; у toolbar — сегментний `Picker` EN | IT (той самий
  `displayLanguageID`), меню сортування (`EntrySort`), «+», шестерня. Рядок: слово (жирне) + транскрипція,
  переклади, приклад (`lineLimit(2)`), бейджі «очікує»/«помилка»/«італійська версія очікує» (`EntryDisplay`).
  Свайпи: трейлінг — «Видалити» (підтвердження), «Редагувати»; лідинг — «Повторити» (pending/failed) або «Оновити
  італійський» (режим IT). `.refreshable` → `processAll(.retryAll)`. Внизу плаваюча кнопка мікрофона → голос.
  Порожній стан і банер інжесту («Додано з “Поділитися”: 3, дублі: 1»).
- **Додавання** (`AddWordSheet`): поле + «Додати через Claude», мікрофон з EN | IT поруч; посилання «Заповнити
  вручну» → `EntryEditView` (D14, статус ready).
- **Голос** (`VoiceCaptureView`): великий мікрофон з індикатором рівня, живий частковий текст, після зупинки —
  редаговане поле + чипи альтернатив, «Додати» / «Ще раз»; результат-картка.
- **Деталі** (`EntryDetailView`): усі поля відображення, озвучення слова й прикладу, редагування, повтор, видалення,
  «Оновити італійський переклад» (1 явний запит, як M7).
- **Налаштування** (`SettingsView`, `Form`): API-ключ (`SecureField`, зберегти/видалити, статус), модель (+ скидання),
  мова голосу за замовчуванням, мова інтерфейсу (миттєво, DI14), тема (`AppAppearance` → `overrideUserInterfaceStyle`
  вікон сцени, iU9), дані: «Експортувати» (`fileExporter`), «Поділитися файлом» (`ShareLink` на тимчасову копію —
  AirDrop на Mac), «Імпортувати» (`fileImporter` → діалог merge/replace, D1/§10), шлях даних і кількість бекапів.

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

Кожен етап закінчується **промтом для Mac** (користувач виконує й повертає вивід):
```
git pull && xcodegen generate
xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
xcodebuild test -project VocabApp.xcodeproj -scheme VocabMobile -destination 'platform=iOS Simulator,name=iPhone 16'
# пристрій: Xcode → схема VocabMobile → обраний iPhone → Run (або xcodebuild … -destination 'platform=iOS,name=<iPhone>'
#           -allowProvisioningUpdates build), далі ручний чекліст docs/development/manual-tests/I<N>.md
```
Linux: `docker run --rm -v "$PWD":/w -w /w swift:6.0-noble swift test` — після кожного етапу, 0 падінь.

### I1 — Каркас iOS, ядро на iOS, список, ручне додавання, Settings/Keychain
**Файли:** `Package.swift`, `AppPaths.swift`, `ProcessingTrigger.swift`, `L10n*`, `project.yml`, `Config/*`,
`.gitignore`, `Mobile/{Info.plist,VocabMobile.entitlements(порожній)}`, `Mobile/Sources/{VocabMobileApp,AppContainer,
MobileAppModel,Router}.swift`, `Views/{EntryListView,EntryRowView,AddWordSheet(без мікрофона),EntryDetailView,
EntryEditView,SettingsView}`, `Platform/{ColorSchemeApplier,BackgroundTaskRunner}`, `I1.md`.
| КП | Перевірка |
|---|---|
| I1.1 Ядро збирається під iOS, Linux-тести зелені | збірка `VocabMobile`; `ProcessingTriggerTests` (нові кейси), `LocalizationTests` (нові ключі), `HardcodedStringsScanTests` (нові каталоги), `RepositoryHygieneTests.testNoDevelopmentTeamCommitted` |
| I1.2 Список/пошук/сорт/EN\|IT, свайпи | `VocabMobileTests/MobileAppModelTests`: `testLoadsEntriesFromTemporaryDirectory`, `testSearchAndSortUseEntryQuery`, `testDisplayLanguagePersistsAndTriggersBackfill`, `testDeleteRemovesEntry`, `testRetryCallsProcessorOnce` |
| I1.3 Додавання через Claude = 1 запит, дубль = 0 | `testAddViaClaudeMakesOneRequest`, `testDuplicateMakesNoRequest` (MockURLProtocol-копія в `Mobile/Tests/Support`) |
| I1.4 Ключ у Keychain, не в UserDefaults | `KeychainMobileTests`: `testSaveReadDeleteKey` (унікальний `service`), `testKeyNeverInUserDefaults` |
| I1.5 Тема й мова миттєво | `testInterfaceLanguageSwitchChangesRootIdentity`, `testAppearanceMapsToUserInterfaceStyle` |
`I1.md`: установка на iPhone з Personal Team, ключ, ручне й Claude-додавання, перезапуск — дані на місці; macOS-регресія зелена.

### I2 — Голосове введення
**Файли:** ядро §3.2 (`EntryDraft`, `AddWordUseCase`, `WordLookupService`/`ClaudeLookupService`, `EntryProcessor`,
`PromptBuilder`, `PromptTemplate`, `EnglishUkrainian.swift`); `Mobile/Sources/Voice/*`, `VoiceCaptureView`,
`AddWordSheet`, Info.plist-дозволи, `InfoPlist.strings`, `I2.md`.
| КП | Перевірка (ядро — Linux) |
|---|---|
| I2.1 Підказка не змінює промт без підказки | `SourceLanguageHintTests`: `testPromptWithoutHintIsByteIdentical`, `testHintAppendedOnceForPairWithRenderings`, `testUnknownHintIgnored`, `testHintIgnoredForPairWithoutRenderings` |
| I2.2 Підказка переживає офлайн, кількість запитів 1/0 | `testUseCaseStoresHintOnPendingEntry`, `testProcessorPassesHintOnlyForPendingOrFailed`, `testRetryAfterOfflineKeepsHint`, `testHintedWordMakesExactlyOneRequest`, `testSpokenItalianDuplicateOfReadyVariantMakesNoRequest` |
| I2.3 Стан-машина голосу | `VoiceCaptureModelTests` (FakeSpeechRecognizer, ін'єктований годинник): `testPermissionDeniedShowsSettingsLink`, `testPartialThenFinalFillsEditableText`, `testAutoStopAfterSilence`, `testMaxDurationStops`, `testTapStopsListening`, `testAlternativesLimitedToThree`, `testSubmitCallsUseCaseOnceWithLanguageHint`, `testEmptyRecognitionDoesNotSubmit`, `testLanguageToggleRemembered`, `testCancelStopsEngine` |
| I2.4 On-device пріоритет | `RecognitionConfigTests.testOnDeviceRequiredWhenSupported`, `testServerFallbackFlagged`, `testOfflineWithoutOnDeviceShowsError` (чиста функція конфігурації) |
| I2.5 Дозволи в Info.plist | `InfoPlistMobileTests.testUsageDescriptionsPresentInBothLocalizations` |
`I2.md` (лише пристрій): `run`, `casa`, `perché`, `come` (EN і IT), фраза `take off`; тиша/шум; авіарежим з/без on-device;
відмова в дозволі; озвучення після запису (звук не «тихий» після запису — перевірка `AVAudioSession`).

### I3 — Share Extension + App Group + inbox
**Файли:** ядро `Inbox/*`; `Extensions/Share/*`, `Mobile/Sources/Platform/InboxLocation.swift`, entitlements
(App Groups у `VocabMobile` і `VocabShare`), `MobileAppModel` (інжест на `.active`), `InboxBanner`, `I3.md`.
| КП | Перевірка |
|---|---|
| I3.1 Атомарний inbox | `InboxStoreTests`: `testEnqueueWritesSingleJsonViaTempAndRename`, `testTempFilesIgnored`, `testItemsSortedByCreatedAt`, `testCorruptFileMovedToRejected`, `testFullInboxThrows`, `testTextTruncatedTo2000` |
| I3.2 Інжест: 1 запит на нове слово, 0 на дубль, ідемпотентність | `InboxIngestorTests`: `testNewWordsQueuedThenOneProcessAll`, `testDuplicateRemovedWithoutRequest`, `testRejectedCounted`, `testStorageFailureKeepsFile`, `testCrashBetweenAddAndRemoveIsIdempotent`, `testHintStoredOnPendingEntry` |
| I3.3 Вилучення тексту | `ShareTextExtractorTests` (чиста функція над кандидатами: `attributedContentText`, plain-text вкладення, URL ігнорується): `testPrefersSelectedText`, `testEmptyShareRejected` |
| I3.4 Інжест при активації | `MobileAppModelInboxTests.testActivePhaseIngestsAndShowsBanner`, `testNoAppGroupDisablesInboxGracefully` |
`I3.md`: Safari (виділення → Поділитися), Notes, Telegram, Chrome; застосунок закритий/відкритий; 3 слова поспіль; дубль;
авіарежим; перевірка, що App Group працює з Personal Team (iU1). **План Б, якщо App Group недоступний:** Share Extension
відкладається; замість неї — ярлик Shortcuts «Отримати текст із листа Поділитися → Add to Dictionary» (I4, без App Group).

### I4 — App Intents (Siri / Shortcuts) + віджет
**Файли:** `Mobile/Sources/Intents/*`, `AppShortcuts.strings`, `Extensions/Widget/*`, `Router` (`DeepLink.parse`), `I4.md`.
- `AddToDictionaryIntent`: `@Parameter text: String`, `@Parameter language: VoiceLanguageAppEnum?` (Auto/English/Italian),
  `openAppWhenRun = false`, `authenticationPolicy = .requiresAuthentication` (Keychain `WhenUnlocked`); `perform` →
  `AddWordUseCase.execute(rawText:sourceLanguageHint:)` → діалог із `NotificationText.make(for:)`. Довгий запит: через 8 с відповідає «Збережено,
  перекладається» (запис уже pending).
- `StartVoiceCaptureIntent`: `openAppWhenRun = true`, `perform` (`@MainActor`) → `Router.open(.voiceCapture(lang))`.
- `VocabShortcuts: AppShortcutsProvider` — фрази з `\(.applicationName)` (параметр-рядок у фразу не вбудовується; Siri
  перепитає «Яке слово?»).
- `VoiceCaptureWidget`: `StaticConfiguration`, `.systemSmall`, `.accessoryCircular`, `.accessoryRectangular`; одна
  timeline-entry `.never`; `widgetURL(vocabapp://voice)`. Віджет не пише звук і не має App Group.
| КП | Перевірка |
|---|---|
| I4.1 Intent додає слово рівно 1 запитом | `AddToDictionaryIntentTests`: `testPerformAddsWordWithOneRequest`, `testPerformDuplicateNoRequest`, `testEmptyTextRejectedDialog`, `testItalianParameterPassedAsHint`, `testSlowLookupReturnsQueuedDialog` |
| I4.2 Відкриття голосу | `StartVoiceCaptureIntentTests.testPerformRoutesToVoiceCapture`; `DeepLinkTests`: `testVoiceURL`, `testVoiceURLWithLanguage`, `testUnknownURLIgnored` |
| I4.3 URL-схема | `InfoPlistMobileTests.testURLSchemeRegistered` |
`I4.md`: Shortcuts-застосунок (обидві дії), Siri англійською, Action Button (якщо є), віджет на Home і Lock Screen →
одразу слухає; заблокований телефон; ярлик із листа «Поділитися» (План Б I3).

### I5 — Експорт/імпорт, полірування, README
**Файли:** `Platform/DocumentFiles.swift`, `SettingsView`, `ImportModeDialog`, `CFBundleDocumentTypes`, README (`## iPhone`
у `README.md` і `README.uk.md`: вимоги, Local.xcconfig, установка, 7 днів, синхронізація з Mac), `I5.md`.
| КП | Перевірка |
|---|---|
| I5.1 Експорт = та сама схема v1 | `MobileTransferTests.testExportRoundTripsThroughCoreImporter`, `testExportedFileImportsOnMacFixture` (байтове порівняння з фікстурою ядра) |
| I5.2 Імпорт merge/replace | `testImportCopiesSecurityScopedFileBeforeReading`, `testMergeReportShown`, `testReplaceMakesBackup`, `testImportedPendingProcessedOnce` |
| I5.3 Відкриття .json з AirDrop/Files | `testOpenURLWithJsonShowsImportDialog`, `InfoPlistMobileTests.testJsonDocumentTypeDeclared` |
`I5.md`: Mac → AirDrop → iPhone (merge, replace), iPhone → AirDrop/Files → Mac (імпорт у macOS-застосунку), конфлікти D1,
варіанти IT збережено, повторна установка через 7 днів — дані на місці.

---

## 8. Економія токенів (без змін правил)

Нове слово з будь-якого входу (голос, текст, Share, Intent) — **1** комбінований запит (EN+IT); дубль за будь-яким
`dedupKey` — **0**; підказка мови — без додаткових запитів; варіанти старих записів — лише пакетами в режимі IT або
явною дією; IT/QA-контекст (M8) — у тих самих промтах ядра. Перевірка — лічильник `MockURLProtocol` у тестах I1–I4.

---

## 9. Ризики

- **Без CI для iOS** (немає раннерів): кожен етап компілюється лише на Mac користувача → малі етапи, протоколи з фейками,
  максимум логіки в ядрі (Linux). Помилки компіляції повертаються як вивід `xcodebuild` в наступну ітерацію.
- **Personal Team:** 7-денний профіль, ліміти на кількість застосунків/App ID (iU2), можлива недоступність App Groups (iU1)
  → План Б для Share.
- **Розпізнавання мовлення:** якість для окремих слів без контексту, особливо італійських; on-device для `it-IT` може
  бути недоступним (iU4). Мітигація — обов'язкове підтвердження й альтернативи.
- **Siri не підтримує українську** — голосові фрази лише англійською (iU7).
- **Розходження з Mac** до ручної синхронізації: конфлікти розв'язує D1 (updatedAt); видалення не синхронізуються
  (merge не видаляє) — описати в README.
- **Регресія macOS:** зведена до мінімуму (macOS-файли не переміщуються; зміни ядра адитивні, наявні тести без змін).

---

## 10. Відкриті питання (→ `PROGRESS.md` після затвердження)

- **iU1** Чи дозволяє безкоштовний Personal Team capability **App Groups** (автоматичне створення групи Xcode) для
  застосунку й Share Extension. Очікую «так», але не впевнений; перевірка — I3.md. План Б — §7 I3.
- **iU2** Ліміти Personal Team: скільки застосунків з безкоштовним профілем може бути на пристрої одночасно (відомо про
  ліміт ~3) і чи рахуються розширення окремо; ліміт нових App ID (~10 за 7 днів) — не міняти префікс без потреби.
- **iU3** Чи потребують WidgetKit-розширення та App Intents/App Shortcuts якихось entitlements, недоступних Personal
  Team (очікую — ні; Siri-entitlement потрібен лише SiriKit, який не використовуємо).
- **iU4** Наявність on-device розпізнавання `it-IT`/`en-US` на iPhone користувача (`supportsOnDeviceRecognition`),
  чи можна завантажити модель мовлення в налаштуваннях, ліміти серверного розпізнавання.
- **iU5** Що App Intents з таргету застосунку (`openAppWhenRun = false`) виконуються **в процесі застосунку** (фоновий
  запуск) і чи встигає `AppContainer` завантажити словник; ліміт часу виконання intent-а для Siri.
- **iU6** Чи Safari/Notes/Telegram/Chrome віддають виділений текст як `public.plain-text` вкладення чи як
  `attributedContentText`; чи Telegram показує наше розширення.
- **iU7** Мова Siri користувача: Siri не підтримує українську; як Siri англійською розпізнає італійські слова в
  параметрі (ймовірно погано → для IT рекомендуємо in-app голос).
- **iU8** Симулятор: чи працює `xcodebuild test` для таргету з entitlement App Groups без команди (`DEVELOPMENT_TEAM`
  порожній); План Б — `CODE_SIGNING_ALLOWED=NO` для симулятора (тести не залежать від реальної групи).
- **iU9** Тема: `overrideUserInterfaceStyle` вікон сцени vs `preferredColorScheme` для sheet-ів і `fileImporter`.
- **iU10** Чи потрібна фонова обробка inbox (`BGAppRefreshTask`) — вирішить користувач після I3.
- **iU11** Чи декларування `public.json` у `CFBundleDocumentTypes` дає пункт «Відкрити в VocabMobile» для AirDrop-файлу
  з Mac без `LSSupportsOpeningDocumentsInPlace`.
- **iU12** Модель iPhone і версія iOS користувача (≥ 17?); версія Xcode на Mac (≥ 16?).
- **iU13** Чи немає в ядрі інших macOS-only API, крім `homeDirectoryForCurrentUser` (виявить збірка I1).
- **iU14** Взаємодія `AVAudioSession` (запис) з `AVSpeechSynthesizer` (озвучення одразу після запису) на пристрої.

## 11. Що потрібно від користувача для старту

1. Затвердити план (або змінити DI7/DI10/DI13/DI14). 2. Відповісти на iU12 (модель iPhone, iOS, Xcode) і чи є/буде
платний акаунт. 3. Підготувати Mac (Xcode 16+, xcodegen), iPhone (Developer Mode), Apple ID у Xcode, `Config/Local.xcconfig`.
