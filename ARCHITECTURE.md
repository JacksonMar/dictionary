# ARCHITECTURE — VocabApp (EN → UK словник для macOS)

Документ визначає структуру, типи, формати, модель помилок, потоки виконання та план етапів M1–M7 (M6 — фідбек з ручного тестування на Mac; M7 — перемикач EN | IT з італійською версією записів, §3.2, §7.7, §8.4).
Мова — українська, ідентифікатори коду — англійською. Джерело вимог: `docs/REQUIREMENTS.md`.

---

## 1. Принципи

1. **Ядро `VocabCore`** — лише Foundation, без AppKit/SwiftUI/Security/Combine/os. Збирається й тестується на Linux
   (`swift:6.0-noble`, Swift 5 language mode) і на macOS. Мережа на Linux — через
   `#if canImport(FoundationNetworking) import FoundationNetworking #endif`.
2. **Застосунок `VocabApp`** — лише macOS-специфічне: SwiftUI, AppKit (Services, панелі), Security (Keychain),
   UserNotifications, ServiceManagement, AVFoundation, Network. Кожен такий сервіс — за протоколом, оголошеним у ядрі
   (якщо ядру потрібна залежність) або в app-таргеті (якщо використовує лише UI).
3. **Все, що можна протестувати, — в ядрі**: валідація виділення, дедуплікація, промти, HTTP-логіка, парсинг,
   черга pending, імпорт/експорт, тексти сповіщень, пошук/сортування.
4. **Без сторонніх залежностей.** Без force unwrap (виняток — літерали URL у константах з коментарем).
5. **API-ключ** існує лише в `SecretStore` (Keychain у застосунку) і в заголовку `x-api-key` одного `URLRequest`.
   Ніколи не потрапляє в лог, JSON словника, `UserDefaults`, повідомлення про помилки.
6. **Нова мовна пара** (`it-uk`) = новий файл з `LanguagePair`-визначенням + реєстрація; код ядра не змінюється.
   **Нова мова відображення** (M7, напр. `de` поряд з `it`) = новий файл з `RenderingLanguage` + додавання в
   `renderings` пари; код ядра теж не змінюється (§3.2).
7. **Економія токенів (M7)**: жодних повторних запитів за даними, що вже є у файлі; нове слово — один запит на всі
   мови; доповнення старих записів — пакетами (§7.7, §8.4).

---

## 2. Структура репозиторію

```
Package.swift                      # swift-tools-version:5.9, VocabCore + VocabCoreTests
project.yml                        # XcodeGen → VocabApp.xcodeproj (не комітиться, .gitignore)
Sources/VocabCore/
  Models/        Entry.swift, Example.swift, EntryStatus.swift, EntryDraft.swift, DictionaryFile.swift,
                 EntryVariant.swift (M7)
  Languages/     LanguagePair.swift, LanguagePairRegistry.swift, EnglishUkrainian.swift,
                 RenderingLanguage.swift, Italian.swift (M7)
  Text/          TextNormalizer.swift, SelectionValidator.swift
  Support/       DateProvider.swift, AppPaths.swift, JSONCoding.swift, FileErrorText.swift (україномовні тексти файлових помилок)
  Storage/       FileSystem.swift, FileDictionaryStore.swift, BackupManager.swift,
                 StorageError.swift, LoadResult.swift
  Repository/    DictionaryRepository.swift, RepositoryError.swift, EntryQuery.swift (EntryQuery + EntrySort),
                 Pagination.swift (Pagination + EntryPage, M6), EntryDisplay.swift (M7)
  Claude/        HTTPTransport.swift, ClaudeConfiguration.swift,
                 ClaudeRequestBuilder.swift, ClaudeAPIClient.swift, ClaudeError.swift,
                 PromptBuilder.swift, LookupResponseParser.swift, ClaudeLookupService.swift,
                 VariantBatchLookup.swift, VariantPromptBuilder.swift, VariantBatchResponseParser.swift (M7)
  Processing/    ErrorDisposition.swift, RetryPolicy.swift, EntryProcessor.swift, PendingQueueProcessor.swift,
                 ProcessingTrigger.swift (+ QueueLog, M6), VariantBackfillProcessor.swift (M7)
  UseCases/      AddWordUseCase.swift (+ AddWordOutcome), ServiceRequestHandler.swift (+ ServiceResponse),
                 NotificationText.swift (+ NotificationContent)
  Transfer/      DictionaryExporter.swift, DictionaryImporter.swift, ImportMerger.swift,
                 ImportReport.swift, ImportError.swift, DictionaryTransferService.swift, VariantMerge.swift (M7)
  Security/      SecretStore.swift (+ SecretKey, SecretStoreError), InMemorySecretStore.swift, RedactingLogger.swift
  Settings/      SettingsStore.swift, AppAppearance.swift (M6)
Tests/VocabCoreTests/              # усі тести ядра (Linux + macOS), Fixtures/*.json як рядкові константи у коді
App/
  Info.plist
  Sources/
    VocabApp.swift                 # @main App: MenuBarExtra + Window("dictionary") + Window("settings")
    AppDelegate.swift              # композиційний корінь, Services, старт черги
    AppModel.swift                 # @MainActor ObservableObject, міст між repository та UI
    AppEnvironment.swift           # isRunningTests, шляхи
    Views/   MenuBarContentView.swift, DictionaryWindowView.swift, EntryTableView.swift (M6, замінює EntryRowView), PaginationBar.swift (M6),
             EntryEditorView.swift, AddEntryView.swift, SettingsView.swift, ImportModeDialog.swift
    Platform/ ServicesProvider.swift, KeychainSecretStore.swift, UserNotifier.swift (протокол),
             NotificationService.swift (UserNotifier через UNUserNotificationCenter),
             LoginItemService.swift (LoginItemManaging), SpeechService.swift (SpeechSpeaking), FilePanels.swift, NetworkMonitor.swift, OSLogSink.swift,
             AppearanceController.swift (AppearanceApplying, M6)
  Tests/                           # VocabAppTests (лише macOS)
docs/manual-tests/M1.md … M7.md
README.md                          # M5
```

### 2.1 Package.swift (обов'язкові параметри)

- `// swift-tools-version:5.9`; `name: "VocabCore"`; `platforms: [.macOS(.v13)]`.
- `products: [.library(name: "VocabCore", targets: ["VocabCore"])]`.
- `targets: [.target(name: "VocabCore"), .testTarget(name: "VocabCoreTests", dependencies: ["VocabCore"])]`.
- `swiftLanguageVersions: [.v5]`. Жодних `unsafeFlags`, жодних залежностей.

### 2.2 project.yml (XcodeGen)

```yaml
name: VocabApp
options:
  bundleIdPrefix: com.vocabapp
  deploymentTarget: { macOS: "13.0" }
settings:
  base:
    SWIFT_VERSION: "5.0"
    MACOSX_DEPLOYMENT_TARGET: "13.0"
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    DEVELOPMENT_TEAM: ""
    ENABLE_HARDENED_RUNTIME: NO
packages:
  VocabCore: { path: . }
targets:
  VocabApp:
    type: application
    platform: macOS
    sources: [App/Sources]
    settings:
      base:
        PRODUCT_NAME: VocabApp
        PRODUCT_BUNDLE_IDENTIFIER: com.vocabapp.VocabApp
        INFOPLIST_FILE: App/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        ENABLE_APP_SANDBOX: NO
    dependencies:
      - package: VocabCore
        product: VocabCore
  VocabAppTests:
    type: bundle.unit-test
    platform: macOS
    sources: [App/Tests]
    settings:
      base: { GENERATE_INFOPLIST_FILE: YES, PRODUCT_BUNDLE_IDENTIFIER: com.vocabapp.VocabAppTests }
    dependencies:
      - target: VocabApp          # hosted tests: TEST_HOST = VocabApp.app
schemes:
  VocabApp:
    build:
      targets: { VocabApp: all, VocabAppTests: [test] }
    test:
      config: Debug
      targets: [VocabAppTests]
```

- **Sandbox вимкнено**: інакше `~/Library/Application Support` вказує в контейнер, а Services/Keychain ускладнюються.
  Entitlements-файл не потрібен.
- `VocabAppTests` імпортує `VocabCore` без окремого лінкування (модуль у `BUILT_PRODUCTS_DIR`, символи — з host app).
  Якщо CI дасть `No such module 'VocabCore'` — додати `- package: VocabCore` у залежності тест-таргета (див. §11, U10).

### 2.3 Info.plist (App/Info.plist, закомічений вручну)

Ключі: `CFBundleIdentifier=$(PRODUCT_BUNDLE_IDENTIFIER)`, `CFBundleName=VocabApp`, `CFBundleDisplayName=VocabApp`,
`CFBundleExecutable=$(EXECUTABLE_NAME)`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString=1.0`,
`CFBundleVersion=1`, `LSMinimumSystemVersion=13.0`, `LSUIElement=true`, `NSPrincipalClass=NSApplication`, та:

```xml
<key>NSServices</key>
<array>
  <dict>
    <key>NSMenuItem</key>
    <dict><key>default</key><string>Додати в словник</string></dict>
    <key>NSMessage</key><string>addToDictionary</string>
    <key>NSPortName</key><string>VocabApp</string>
    <key>NSSendTypes</key>
    <array>
      <string>NSStringPboardType</string>
      <string>public.utf8-plain-text</string>
    </array>
    <key>NSRequiredContext</key><dict/>
  </dict>
</array>
```

Пояснення та невизначеності:
- `NSMessage` = ім'я селектора **без** аргументів; AppKit викликає `addToDictionary:userData:error:`.
  Тому в Swift метод оголошується з явним ObjC-ім'ям: `@objc(addToDictionary:userData:error:)`.
- `NSPortName` має збігатися з іменем, під яким застосунок реєструє порт сервісів; для Cocoa-застосунків це, за
  документацією Services Implementation Guide, ім'я застосунку. Беремо `VocabApp` = `CFBundleName` = `PRODUCT_NAME`.
  **Перевірити на Mac** (U1).
- `NSRequiredContext` з порожнім словником — щоб сервіс був увімкнений за замовчуванням. Чи достатньо цього для
  показу без ручного вмикання в System Settings — **перевірити** (U2); чекліст M3 містить крок ручного вмикання.
- `NSReturnTypes` не задаємо (сервіс нічого не повертає), `NSKeyEquivalent` не задаємо (уникаємо конфліктів).
- `NSStringPboardType` — застарілий тип, мапиться на `public.utf8-plain-text`; лишаємо обидва за вимогою.

---

## 3. Модель даних (VocabCore/Models, Languages)

```swift
public enum EntryStatus: String, Codable, Sendable, CaseIterable { case ready, pending, failed }

public struct Example: Codable, Equatable, Sendable { public var source: String; public var translation: String }

public struct Entry: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var languagePair: String          // id пари, напр. "en-uk"
  public var word: String                  // як показуємо (див. рішення D5)
  public var lemma: String?
  public var partOfSpeech: String?         // "phrase" для фраз
  public var transcription: String?
  public var translations: [String]        // порожній для pending/failed
  public var example: Example?
  public var status: EntryStatus
  public var lastError: String?            // розширення схеми, лише для failed/pending; без секретів
  public var createdAt: Date
  public var updatedAt: Date
}

public struct DictionaryFile: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1
  public var schemaVersion: Int
  public var exportedAt: Date?             // при декодуванні необов'язковий
  public var entries: [Entry]
}

public struct EntryDraft: Equatable, Sendable { word, languagePair, lemma?, partOfSpeech?, transcription?,
                                                translations, example?, status }
```

- Ключі JSON — точно як у вимогах (camelCase). Опційні поля пишуться `encodeIfPresent` (відсутні, якщо `nil`).
  Невідомі ключі при читанні ігноруються.
- `JSONCoding` (Support): `makeEncoder()` → `.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`, дати ISO8601
  без дробових секунд (`2026-10-13T10:00:00Z`, UTC). `makeDecoder()` → кастомна стратегія дат: приймає ISO8601
  **з** і **без** дробових секунд (через два `ISO8601DateFormatter`), інакше `DecodingError`.
- Усі дати створюються через `DateProvider.now()`, який **обрізає до цілих секунд** — щоб round-trip був точним і
  порівняння `updatedAt` при merge було стабільним.

```swift
public protocol DateProvider: Sendable { func now() -> Date }
public struct SystemDateProvider: DateProvider { … floor(timeIntervalSince1970) }
public final class FixedDateProvider: DateProvider, @unchecked Sendable { var current: Date; func advance(by:) } // для тестів (публічний у ядрі)
```

### 3.1 LanguagePair (розширюваність)

```swift
public struct LanguagePair: Hashable, Sendable {
  public let id: String                    // "en-uk"
  public let sourceLanguageName: String    // "English"
  public let targetLanguageName: String    // "Ukrainian"
  public let speechLanguageCode: String    // "en-US" для AVSpeechSynthesizer
  public let prompt: PromptTemplate
}
public struct PromptTemplate: Hashable, Sendable {
  public let system: String                // містить JSON-схему, правила, мову перекладу
  public let userWord: String              // шаблон з плейсхолдером {{TEXT}}
  public let userPhrase: String
}
public final class LanguagePairRegistry: @unchecked Sendable {   // внутрішній NSLock
  public static let shared: LanguagePairRegistry   // з вбудованою .englishUkrainian
  public init(pairs: [LanguagePair])
  public func register(_ pair: LanguagePair)
  public func pair(id: String) -> LanguagePair?
  public var all: [LanguagePair]
  public static let defaultPairID = "en-uk"
}
extension LanguagePair { public static let englishUkrainian: LanguagePair }  // EnglishUkrainian.swift
```

Додавання `it-uk`: файл `ItalianUkrainian.swift` з `static let italianUkrainian` і `registry.register(...)` у
композиційному корені. `Entry.languagePair` — рядок, тож записи з невідомою парою зберігаються/імпортуються без втрат.

### 3.2 Варіанти відображення (M7: перемикач EN | IT)

**Що це.** Запис = **поняття** з кількома відображеннями. Італійська — не окремий словник і не окрема `LanguagePair`,
а паралельне відображення того самого запису: для `run` зберігається італійський відповідник `correre` з власними
леммою, частиною мови, IPA, українськими перекладами (того самого значення — модель повертає переклади саме італійського
слова, тож вони можуть трохи відрізнятися) і прикладом італійською + переклад українською.
- **Первинне відображення** (`en`) — це наявні поля `Entry` (`word`, `lemma`, `partOfSpeech`, `transcription`,
  `translations`, `example`). Так старі файли (лише en) — валідні записи без змін.
- **Додаткові відображення** — `Entry.variants["it"]`.
- **Мова виділення визначається автоматично** (D25): у Services можна виділити англійське **або** італійське слово;
  один запит до Claude визначає мову (`source_language`) і повертає обидва відображення. Визначена мова зберігається в
  `Entry.sourceLanguage` (`nil` = мова джерела пари, тобто всі старі записи = `en`). Для італійського виділення
  `Entry.word` після відповіді = англійський відповідник від моделі, а виділене слово — у `variants["it"].word`.
- **Дедуплікація** — за ключами **всіх** відображень у межах пари (D26): `key(word)` і `key(variants[x].word)` для
  ready-варіантів.

```swift
// Languages/RenderingLanguage.swift
public struct RenderingLanguage: Hashable, Sendable {
  public let id: String                    // "it" — ключ у Entry.variants; стабільний, пишеться у файл
  public let shortTitle: String            // "IT" — підпис сегмента перемикача
  public let languageName: String          // "Italian" — підставляється в промти
  public let speechLanguageCode: String    // "it-IT"
  public let prompt: RenderingPromptTemplate
}
public struct RenderingPromptTemplate: Hashable, Sendable {
  public let combinedInstruction: String   // додається до system-промту пари в комбінованому запиті (§7.7)
  public let batchSystem: String           // system-промт пакетного доповнення (§7.7)
  public let batchUser: String             // шаблон user-повідомлення з плейсхолдером {{ITEMS}}
  // Плейсхолдери в усіх трьох: {{SOURCE_LANGUAGE}}, {{TARGET_LANGUAGE}} (з LanguagePair), {{LANGUAGE}} (languageName),
  // {{ID}} (id). Тож одна RenderingLanguage працює з будь-якою парою.
}
extension RenderingLanguage { public static let italian: RenderingLanguage }   // Languages/Italian.swift

// Languages/LanguagePair.swift — два нові поля з дефолтами в init (наявні виклики init компілюються без змін):
public struct LanguagePair {
  …
  public let sourceLanguageCode: String    // "en"; default — id до першого "-"; значення source_language для первинного
  public let sourceShortTitle: String      // "EN"; default — sourceLanguageCode.uppercased()
  public let renderings: [RenderingLanguage]   // default []; .englishUkrainian = [.italian]
  public func rendering(id: String) -> RenderingLanguage?
}

// Models/EntryVariant.swift
public struct EntryVariant: Codable, Equatable, Sendable {
  public var word: String?                 // nil для pending/failed
  public var lemma: String?
  public var partOfSpeech: String?         // "phrase" для фраз
  public var transcription: String?        // IPA мови варіанта, напр. "/korˈrere/"
  public var translations: [String]        // українські; порожній для pending/failed
  public var example: Example?             // source — речення мовою варіанта, translation — українською
  public var status: EntryStatus           // ready | pending | failed (той самий enum)
  public var lastError: String?
  public var sourceKey: String             // TextNormalizer.key(entry.word) на момент генерації (D23)
  public var updatedAt: Date               // власний час варіанта; Entry.updatedAt НЕ змінює (D24)
}
public enum VariantState: Equatable, Sendable { case missing, stale, pending, failed, ready }
extension Entry {
  public var variants: [String: EntryVariant]?           // нове опційне поле Entry; nil/порожній → ключ у JSON відсутній
  public var sourceLanguage: String?                     // нове опційне поле: "it" для італійського виділення; nil = мова пари
  public func variantState(_ languageID: String) -> VariantState    // stale = sourceKey != key(word); варіант мови
                                                                    //   sourceLanguage ніколи не stale (це слово користувача)
  public func dedupKeys() -> Set<String>   // key(word) ∪ key(v.word) для readyVariant; для pending — лише key(word)
  public func readyVariant(_ languageID: String) -> EntryVariant?   // лише ready і не stale
}
```

- **JSON**: `"variants": {"it": {"word": "correre", "lemma": "correre", "partOfSpeech": "verb",
  "transcription": "/korˈrere/", "translations": ["бігти"], "example": {"source": "Lei corre ogni mattina.",
  "translation": "Вона бігає щоранку."}, "status": "ready", "sourceKey": "run", "updatedAt": "2026-10-14T10:00:00Z"}}`.
  Ключі camelCase, `encodeIfPresent`, той самий `JSONCoding`. Порожній словник нормалізується в `nil` (не пишеться),
  тож файл без італійських даних **байт-у-байт** такий самий, як у M6.
- **schemaVersion лишається 1** (D21): поле адитивне й опційне; M1–M6 використовують синтезований `Codable`, який
  ігнорує невідомі ключі, тож старі версії застосунку читають новий файл (але при наступному збереженні втратять
  `variants`/`sourceLanguage` — прийнятно для en-записів: це кеш, відновлюється доповненням; для записів з італійського
  виділення англійські поля лишаються валідними). Нові версії читають старі файли без міграції. `sourceLanguage`
  пишеться лише якщо відрізняється від мови джерела пари (тобто зараз лише `"it"`).
- **Стійке декодування** (D22): `Entry` отримує власний `init(from:)`, у якому `variants` декодується поелементно —
  некоректний варіант (не той тип, невідомий `status`, відсутній `sourceKey`/`updatedAt`) **відкидається**, а не ламає
  запис. Інакше один зіпсований варіант перетворив би весь `dictionary.json` на «corrupted» (§5). Решта полів
  декодується як раніше (суворо). `encode(to:)` — синтезований еквівалент (ручна реалізація, якщо компілятор вимагатиме).
- **Інваріант**: `variants` змінюються лише через `DictionaryRepository.setVariants`, `update(_:replacingVariants: true)`
  (лише `EntryProcessor`) та імпорт (`mergeImported`/`replaceAll`, §10); звичайний `update(_:)` їх зберігає (§6).
- **Зв'язок з `it-uk`**: `LanguagePair` описує **мову джерела** (з якої мови додаються слова через Services, ключ
  дедуплікації, черга). `it-uk` у майбутньому — окрема пара для італійських виділень зі своїми записами
  (`Entry.languagePair = "it-uk"`). `RenderingLanguage` описує **додаткову мову показу** записів уже існуючої пари.
  Вони незалежні: пара `it-uk` може мати `renderings: []` або, напр., `[.english]`; додавання `it-uk` не торкається
  `variants` записів `en-uk`. Ідентифікатори варіантів (`"it"`) — коди мов, не пар. Автовизначення мови працює в
  межах **однієї пари**: допустимі `source_language` = `[pair.sourceLanguageCode] + pair.renderings.map(\.id)`; усі
  записи мають `languagePair = "en-uk"` незалежно від мови виділення. Settings `languagePairID` не змінюється.
  Пара без `renderings` поводиться точно як у M2 (без детекції, промт без додатків).

---

## 4. Нормалізація та валідація виділення (Text)

`TextNormalizer` (чисті функції):
- `clean(_:)` → заміна `’ ‘ ʼ` на `'`; заміна будь-яких пробільних символів і переносів на пробіл; згортання
  повторів пробілів; trim; зняття **крайніх** символів з набору `.,;:!?"“”«»()[]{}…` (повторно, поки є).
  Апостроф і дефіс усередині лишаються (`don't`, `well-known`).
- `key(_:)` = `clean(_:).lowercased()` — ключ дедуплікації (D8).

`SelectionValidator.validate(_ raw: String?) -> SelectionValidation`:
```swift
public enum SelectionKind: String, Sendable { case word, phrase }
public struct CleanedSelection: Equatable, Sendable { text: String; key: String; kind: SelectionKind }
public enum SelectionRejection: Equatable, Sendable { case empty, tooLong(max: Int), tooManyWords(max: Int), noLetters }
public enum SelectionValidation: Equatable, Sendable { case valid(CleanedSelection), rejected(SelectionRejection) }
```
Правила (D3): після `clean` — порожньо → `.empty`; > 120 символів → `.tooLong(120)`; > 8 слів → `.tooManyWords(8)`;
немає жодної літери (`CharacterSet.letters`) → `.noLetters`; є пробіл → `.phrase`, інакше `.word`.

---

## 5. Зберігання (Storage)

```swift
public protocol FileSystem: Sendable {
  func fileExists(at: URL) -> Bool
  func readData(at: URL) throws -> Data
  func writeData(_: Data, to: URL) throws               // звичайний запис (у тимчасовий файл)
  func replaceItem(at target: URL, withItemAt temp: URL) throws   // атомарна заміна
  func moveItem(at: URL, to: URL) throws
  func copyItem(at: URL, to: URL) throws
  func removeItem(at: URL) throws
  func createDirectory(at: URL) throws                  // withIntermediateDirectories: true
  func contentsOfDirectory(at: URL) throws -> [URL]
}
public struct LocalFileSystem: FileSystem { … FileManager.default }

public protocol DictionaryStoring: Sendable {
  var fileURL: URL { get }
  func load() throws -> LoadResult                   // { file: DictionaryFile; recoveredBackupURL: URL? }
  func save(_ file: DictionaryFile) throws           // атомарно, оновлює exportedAt
}
public struct LoadResult: Equatable, Sendable { public var file: DictionaryFile; public var recoveredBackupURL: URL? } // Storage/LoadResult.swift
public enum StorageError: Error, Equatable { … }                                  // Storage/StorageError.swift, див. нижче
public final class FileDictionaryStore: DictionaryStoring {   // immutable → Sendable
  public init(fileURL: URL, fileSystem: FileSystem = LocalFileSystem(), dateProvider: DateProvider = SystemDateProvider(),
              backups: BackupManager)
}
```

**Атомарний запис** `save`: encode → `writeData` у `<dir>/.dictionary.json.<UUID>.tmp` (той самий каталог, той самий
том) → якщо цільовий існує: `replaceItem` (`FileManager.replaceItemAt`), інакше `moveItem`. При будь-якій помилці
після запису тимчасового файлу — `removeItem(temp)` (ігноруючи помилку) і `throw StorageError.writeFailed`.
Оригінал лишається незмінним. Якщо `replaceItemAt` на Linux поводиться некоректно, допустима заміна реалізації
`LocalFileSystem.replaceItem` на `rename(2)` (Glibc/Darwin) — це зміна лише в `LocalFileSystem`.

**Читання** `load`:
- файлу нема → `DictionaryFile(schemaVersion: 1, exportedAt: nil, entries: [])`;
- `schemaVersion > 1` → `throw StorageError.unsupportedSchemaVersion(n)`; файл **не чіпаємо**, репозиторій не
  стартує, UI показує помилку (захист від даунгрейду);
- невалідний JSON / помилка декодування → файл переміщується в `Backups/dictionary-corrupted-<stamp>.json`,
  повертається `LoadResult(file: порожній, recoveredBackupURL: <шлях бекапу>)`; UI показує попередження.

`StorageError`: `.readFailed(String)`, `.writeFailed(String)`, `.unsupportedSchemaVersion(Int)`, `.backupFailed(String)`.

`AppPaths` (ядро, Foundation): `applicationSupportDirectory` = `FileManager.urls(for: .applicationSupportDirectory)`
+ `VocabApp/`; `dictionaryURL` = `…/VocabApp/dictionary.json`; `backupsDirectory` = `…/VocabApp/Backups/`.
Усі — ін'єктуються; тести працюють у `FileManager.default.temporaryDirectory/<UUID>`.

`BackupManager` (D2): `makeBackup(of: URL, reason: .replaceImport | .corrupted) throws -> URL`, ім'я
`dictionary-backup-yyyyMMdd-HHmmss.json` / `dictionary-corrupted-yyyyMMdd-HHmmss.json` (UTC, `DateProvider`), при
колізії суфікс `-2`, `-3`…; після створення зберігає **10 останніх** файлів кожного виду (сортування за іменем).

---

## 6. Репозиторій (Repository)

```swift
public actor DictionaryRepository {
  public init(store: DictionaryStoring, dateProvider: DateProvider)
  public func load() throws -> LoadResult           // викликається один раз на старті
  public func allEntries() -> [Entry]
  public func entry(id: UUID) -> Entry?
  public func findDuplicate(of word: String, languagePair: String, excluding: UUID? = nil) -> Entry?
  public func add(_ draft: EntryDraft) throws -> Entry          // RepositoryError.duplicate(Entry)
  public func update(_ entry: Entry) throws -> Entry            // ставить updatedAt = now; дубль → .duplicate
  public func delete(id: UUID) throws                           // .notFound
  public func replaceAll(_ entries: [Entry]) throws             // для імпорту
  public func changes() -> AsyncStream<[Entry]>                 // одразу шле поточний знімок, далі — після кожної зміни
}
public enum RepositoryError: Error, Equatable { case duplicate(Entry), notFound(UUID), notLoaded, storage(String) }
```

- Кожна мутація: змінити копію → `store.save` → лише після успіху замінити стан і розіслати знімок у всі
  continuation-и. Невдалий save = стан не змінюється, помилка нагору.
- Перевірка дубля й вставка відбуваються в одному виклику actor-а → два паралельні Services-виклики з тим самим
  словом не створять двох записів.
- `EntryQuery` (M5): `struct EntryQuery { var searchText: String; var sort: EntrySort }`,
  `enum EntrySort: String, CaseIterable { case dateNewest, dateOldest, alphabetical }`, `func apply(to: [Entry]) -> [Entry]`,
  `func matches(_ entry: Entry) -> Bool`. Пошуковий текст попередньо trim-иться; порожній → усі записи.
  Пошук: `range(of:options:[.caseInsensitive, .diacriticInsensitive])` по `word`, `lemma`, кожному `translations`.
  Алфавіт: за `TextNormalizer.key(word)`, тай-брейк за `createdAt`.
- `Pagination` / `EntryPage` (M6, `Repository/Pagination.swift`, чиста логіка, сторінки нумеруються з 1):
  ```swift
  public struct Pagination: Equatable, Sendable {
    public static let pageSizeOptions = [20, 25, 30]
    public static let defaultPageSize = 25
    public let pageSize: Int                                   // не з pageSizeOptions → defaultPageSize
    public init(pageSize: Int = Pagination.defaultPageSize)
    public func pageCount(totalCount: Int) -> Int              // max(1, ceil(total / pageSize)); 0 записів → 1
    public func clamp(_ page: Int, totalCount: Int) -> Int     // у межах 1...pageCount (≤ 0 → 1)
    public func page(_ number: Int, of entries: [Entry]) -> EntryPage   // number спершу clamp-иться
  }
  public struct EntryPage: Equatable, Sendable {
    public let entries: [Entry]; public let number: Int; public let pageCount: Int; public let totalCount: Int
    public var hasPrevious: Bool { number > 1 }; public var hasNext: Bool { number < pageCount }
    public var label: String                                   // «Сторінка 2 з 5»
  }
  ```
  Порядок: `query.apply(to:)` → `pagination.page(_:of:)`. Пошук і сортування — по всьому словнику, не по сторінці.
- **M7 — дедуплікація за всіма відображеннями** (D26): `findDuplicate(of:languagePair:excluding:)` повертає запис тієї
  ж пари, у якого `dedupKeys()` містить `key(word)`. Те саме правило — в `add`, `update`, `setVariants`
  (варіант, чий `key(word)` збігається з ключем **іншого** запису, все одно зберігається — показ не блокуємо, — але
  `findDuplicate` поверне перший за `createdAt`). Додатково:
  `public func findDuplicate(keys: Set<String>, languagePair: String, excluding: UUID?) -> Entry?` — для перевірки
  після відповіді Claude (§8.3). Merge імпорту (D1) — і далі лише за англійським ключем.
- **M7 — варіанти в репозиторії:**
  ```swift
  public struct VariantUpdate: Equatable, Sendable { public var entryID: UUID; public var languageID: String; public var variant: EntryVariant }
  extension DictionaryRepository {
    // Один атомарний save на весь пакет. Entry.updatedAt НЕ змінюється. Оновлення пропускається (не помилка), якщо
    // запису вже нема або variant.sourceKey != key(поточного word) (запис відредаговано під час запиту).
    // Повертає фактично оновлені записи; якщо нічого не застосовано — save не викликається.
    public func setVariants(_ updates: [VariantUpdate]) throws -> [Entry]
    // update(_:) з M1 тепер ЗБЕРІГАЄ збережені variants і ігнорує variants аргументу (редактор/AppModel тримають
    // можливо застарілу копію — не можна затерти щойно доповнений варіант). Явна заміна — лише для EntryProcessor:
    public func update(_ entry: Entry, replacingVariants: Bool) throws -> Entry   // update(_:) == replacingVariants: false
  }
  ```
- **M7 — відображення й пошук в активній мові** (`Repository/EntryDisplay.swift`, чиста логіка, Linux-тести):
  ```swift
  public struct EntryDisplay: Equatable, Sendable {
    public let entry: Entry
    public let languageID: String?          // nil = мова джерела пари
    public let word: String                 // ready-варіант → variant.word; інакше entry.word (fallback)
    public let lemma: String?, partOfSpeech: String?, transcription: String?
    public let translations: [String]; public let example: Example?
    public let isFallback: Bool             // показуємо англійські дані, бо варіант не ready
    public let state: VariantState?         // nil у режимі джерела; інакше entry.variantState(languageID)
    public static func make(_ entry: Entry, languageID: String?) -> EntryDisplay
  }
  ```
  У режимі варіанта для запису без ready-варіанта (missing/stale/pending/failed) `isFallback = true`, поля
  `transcription/translations/example` — порожні (`nil`/`[]`), `word` — англійське слово (UI показує його приглушеним з
  бейджем «італійська версія очікує» / «помилка», §11). `EntryQuery` отримує `public var languageID: String? = nil`;
  `matches`/`apply` працюють по `EntryDisplay.make(entry, languageID:)`: пошук — по `word`, `lemma`, `translations`
  відображення (для fallback-рядків — по англійських `word`/`lemma`/`translations`, щоб запис не «зникав»);
  алфавіт — за `TextNormalizer.key(display.word)`, тай-брейк `createdAt`; дати — як було. Дедуплікація не змінюється.

---

## 7. Claude API (Claude)

### 7.1 Транспорт і конфігурація

```swift
public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }
public struct URLSessionTransport: HTTPTransport { public init(session: URLSession) }
```
Реалізація через `withCheckedThrowingContinuation` + `session.dataTask(with:completionHandler:)` — працює однаково
на Linux і macOS (не покладаємось на наявність `data(for:)` у FoundationNetworking). Тести — `MockURLProtocol`
у `URLSessionConfiguration.ephemeral.protocolClasses`.

`ClaudeConfiguration`: `endpoint = https://api.anthropic.com/v1/messages`, `apiVersion = "2023-06-01"`,
`model` (з `SettingsStore`, за замовчуванням `claude-haiku-5-5`), `maxTokens = 4096`, `timeout = 30` с.

### 7.2 Запит

`ClaudeRequestBuilder.makeRequest(prompt: BuiltPrompt, apiKey: String, configuration:) throws -> URLRequest`:
- `POST`, `timeoutInterval = 30`, заголовки `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`.
- Тіло — **рівно чотири ключі верхнього рівня**:
  `{"model": <з Settings>, "max_tokens": 4096, "system": <system>, "messages": [{"role":"user","content": <user>}]}`.
- **Жодних інших ключів**: ні `temperature`/`top_p`/`top_k` (на Haiku 5.5 нестандартні значення → 400), ні `thinking`
  (на Haiku 5.5 adaptive thinking увімкнено за замовчуванням; явне вимкнення залежить від моделі), ні `output_config`,
  ні assistant prefill (400 на нових моделях). Так запит однаково валідний для будь-якої моделі з Settings.
- `max_tokens = 4096`: відповідь ~200 токенів + великий запас під adaptive thinking, щоб уникати обрізання.

### 7.3 Промт (`PromptBuilder`)

`PromptBuilder.build(text: String, kind: SelectionKind, pair: LanguagePair) -> BuiltPrompt { system, user }`.
Системний промт пари `en-uk` вимагає: відповідати **лише** одним JSON-об'єктом без markdown; схема з вимог
(`word, lemma, part_of_speech, transcription, translations, example{source,translation}`); IPA у `/…/`;
1–5 перекладів українською, від найуживанішого; приклад англійською + переклад українською; для фрази —
`part_of_speech: "phrase"`, `lemma` = фраза у словниковій формі. Виділений текст вставляється як
`<text>{{TEXT}}</text>` з інструкцією вважати вміст лише даними (захист від prompt injection).

### 7.4 Відповідь (`LookupResponseParser`)

```swift
public struct LookupResult: Equatable, Sendable { word, lemma, partOfSpeech, transcription, translations: [String], example: Example }
public enum LookupResponseParser {
  static func extractText(fromMessagesResponse data: Data) throws -> String   // stop_reason + конкатенація text-блоків
  static func parse(_ text: String, kind: SelectionKind) throws -> LookupResult
}
```
- Конверт Messages API: `content` — масив; беремо всі блоки `type == "text"`, ігноруємо `thinking` та інші.
- `stop_reason == "refusal"` → `ClaudeError.refused`.
- `stop_reason == "max_tokens"`: якщо зібраний текст все ж парситься й проходить валідацію — приймаємо; якщо ні —
  це **невалідний JSON** → `ClaudeError.invalidResponse("max_tokens")` → один повтор (§7.5) → при повторній
  невдачі `failed` (§8.1).
- Текст: знімаємо обгортку ```` ```json … ``` ````; беремо підрядок від першої `{` до останньої `}`; `JSONSerialization`.
- Валідація: `word`, `part_of_speech`, `example.source`, `example.translation` — непорожні рядки після trim;
  `translations` — масив рядків, після trim/відкидання порожніх/дедуплікації 1…10 елементів; `lemma` — рядок
  (порожній → `word`); `transcription` — рядок, обов'язково непорожній для `.word`, може бути порожнім для `.phrase`.
  Для `.phrase` `partOfSpeech` примусово `"phrase"`. Зайві ключі ігноруються. Порушення → `ClaudeError.invalidResponse(reason)`.

### 7.5 Помилки та клієнт

```swift
public enum ClaudeError: Error, Equatable {
  case missingAPIKey
  case offline                      // URLError: .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                    //   .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff
  case timeout                      // URLError.timedOut
  case unauthorized                 // 401
  case forbidden                    // 403 (і 402 billing)
  case rateLimited(retryAfter: TimeInterval?)   // 429, заголовок retry-after (секунди)
  case server(status: Int)          // 500…599, включно з 529 overloaded
  case badRequest(status: Int, message: String) // 400, 404 (невідома модель), 413, інші 4xx
  case invalidResponse(String)      // невалідний JSON / схема / max_tokens
  case refused
  case transport(String)            // інші URLError (крім cancelled → теж .transport("cancelled"))
  case storage(String)              // збій збереження запису на диск під час обробки (не мережа);
                                    //   userMessage — сам опис («Не вдалося зберегти запис…»), без префікса «Помилка мережі»
}
public protocol WordLookupService: Sendable {
  func lookup(text: String, kind: SelectionKind, pair: LanguagePair) async throws -> LookupResult
}
public final class ClaudeLookupService: WordLookupService {
  public init(transport: HTTPTransport, secrets: SecretStore, settings: SettingsStore, logger: RedactingLogger)
}
```
- `message` для `badRequest` береться з тіла `{"type":"error","error":{"type","message"}}`, обрізається до 200 символів.
- Ключ читається з `SecretStore` на кожен виклик; `nil`/порожній → `.missingAPIKey` **без** HTTP-запиту.
- **Повтор лише при `.invalidResponse`**: рівно один повторний запит (той самий промт + у кінці user-повідомлення
  рядок «Попередня відповідь була невалідною. Поверни лише JSON.»). Друга невдача → `.invalidResponse`.
  HTTP/мережеві помилки клієнт **не** повторює — це робота черги (§8).
- Логування: лише `model`, статус, тривалість, тип помилки. Ні заголовків, ні тіла запиту.

### 7.6 Секрети, логер, налаштування

```swift
public protocol SecretStore: Sendable {
  func readSecret(for key: SecretKey) throws -> String?
  func writeSecret(_ value: String, for key: SecretKey) throws
  func deleteSecret(for key: SecretKey) throws
}
public enum SecretKey: String, Sendable { case anthropicAPIKey = "anthropic-api-key" }
public enum SecretStoreError: Error, Equatable { case keychain(status: Int32), encoding }   // Int32 = OSStatus; без значення секрету
public final class InMemorySecretStore: SecretStore, @unchecked Sendable { /* NSLock */ }

public enum LogLevel: String, Sendable { case debug, info, error }
public protocol LogSink: Sendable { func write(level: LogLevel, message: String) }
public final class RedactingLogger: Sendable {
  public init(sink: LogSink, secretsProvider: @escaping @Sendable () -> [String])
  public func debug/info/error(_ message: @autoclosure () -> String)
}
```
`RedactingLogger` перед записом: (1) замінює кожне входження кожного рядка з `secretsProvider()` довжиною ≥ 8 на `[REDACTED]`;
(2) regex `sk-ant-[A-Za-z0-9_\-]+` → `sk-ant-[REDACTED]`. `secretsProvider` у застосунку читає поточний ключ з
кешу `AppModel` (не Keychain на кожен лог). `CapturingLogSink` (у тестах) і `PrintLogSink` (ядро) — реалізації.

`SettingsStore` (протокол + `UserDefaultsSettingsStore(defaults: UserDefaults)`): `model: String`
(ключ `claudeModel`, default `"claude-haiku-5-5"`; порожній рядок → default), `languagePairID` (default `en-uk`);
M6: `appearance: AppAppearance` (ключ `appearance`, rawValue; відсутнє/невідоме → `.system`) і `pageSize: Int`
(ключ `entriesPageSize`; значення поза `Pagination.pageSizeOptions` → `Pagination.defaultPageSize` = 25).
`public enum AppAppearance: String, CaseIterable, Sendable { case system, light, dark }` (`Settings/AppAppearance.swift`,
`var title`: «Як у системі» / «Світла» / «Темна»). Обидві реалізації (`UserDefaults…`, `InMemory…`) підтримують нові поля.
Автозапуск не зберігається — істина в `SMAppService.mainApp.status`.
M7: `displayLanguageID: String?` (ключ `displayLanguage`; `nil`/порожній/невідомий для поточної пари → `nil` = режим
мови джерела, «EN»). Перевірка «невідомий» — у `AppModel` через `pair.rendering(id:)`, сховище лише зберігає рядок.

### 7.7 M7: комбінований запит з автовизначенням мови і пакетне доповнення

**Комбінований запит (нове слово, рівно 1 HTTP-запит).** `PromptBuilder.build(text:kind:pair:)` для пари з непорожнім
`renderings`: `system = pair.prompt.system + "\n\n" + інструкція детекції + кожен rendering.prompt.combinedInstruction`
(плейсхолдери підставлені); `user` — як раніше (`<text>{{TEXT}}</text>`), але формулювання шаблонів en-uk стає
мовно-нейтральним («Translate this word…» без «English»). Для пари без `renderings` — **рівно** як у M2 (наявні тести
`PromptBuilderTests` не змінюються). Текст system-промту `EnglishUkrainian.swift` змінюється з «exactly this shape» на
«this shape, plus the extra keys requested below» і «the word or phrase» замість «the English word»; верхній рівень
відповіді — **завжди англійське** відображення. Очікувана відповідь:

```json
{ "source_language": "it",
  "word": "house", "lemma": "house", "part_of_speech": "noun", "transcription": "/haʊs/",
  "translations": ["будинок", "дім"], "example": {"source": "…", "translation": "…"},
  "variants": { "it": { "word": "casa", "lemma": "casa", "part_of_speech": "noun", "transcription": "/ˈkaːza/",
                        "translations": ["дім", "будинок", "оселя"], "example": {"source": "…", "translation": "…"} } } }
```

Правила промту: `source_language` — мова виділеного тексту, одне з допустимих кодів (`en`, `it`); якщо текст — валідне
слово обох мов (`come`, `no`, `pane`) — **обирати `en`** (D25); якщо текст не англійський і не італійський — усе одно
`en`-переклад за найкращою здогадкою (поведінка M2). Верхній рівень — англійське відображення (для італійського
виділення — англійський відповідник того самого значення); `variants.<id>` — та сама схема для кожної мови варіанта.

`LookupResult` (§7.4) розширюється: `public var sourceLanguage: String?` і `public var variants: [String: LookupResult]`
(default `[:]`, у вкладених — порожні). `LookupResponseParser.parse(_:kind:pair:)` (стара `parse(_:kind:)` = пара без
renderings):
1. Верхній рівень валідується **як у §7.4**; невалідний → `.invalidResponse` → один повтор (§7.5).
2. `source_language`: якщо в допустимому наборі — береться; інакше/відсутній → виводиться: `key(variants[x].word) ==
   key(selection)` при `key(word) != key(selection)` → `x`, інакше код пари. Тому `parse` отримує й `selectionKey`.
3. Кожен `variants.<id>` для `id` з `pair.renderings` валідується тими ж правилами (kind — той самий; для фрази
   `partOfSpeech = "phrase"`). Невалідний/відсутній **не** ламає відповідь — просто не потрапляє в `variants`
   (запис отримає варіант `pending`, доповниться пакетно; повтор не робимо — економія). **Виняток:** якщо
   `source_language` = id варіанта (виділення італійське), а цей варіант невалідний → уся відповідь `.invalidResponse`
   (без нього нема виділеного слова).
4. Невідомі id у `variants` ігноруються.
`max_tokens` для комбінованого запиту лишається **4096** (D10): відповідь ~350–450 токенів замість ~200 — запас достатній.

**Пакетне доповнення (backfill).** Протокол і типи — `Claude/VariantBatchLookup.swift`:
```swift
public struct VariantRequestItem: Equatable, Sendable {
  public var ref: Int                  // 1…n у межах пакета (не UUID — економія токенів)
  public var word: String              // англійське entry.word
  public var kind: SelectionKind       // SelectionValidator.kind(of: word)
  public var partOfSpeech: String?
  public var meaning: [String]         // до 3 перших translations — щоб модель взяла те саме значення
}
public enum VariantItemOutcome: Equatable, Sendable { case ready(LookupResult), invalid(String), missing }
public protocol VariantBatchLookupService: Sendable {
  func lookupVariants(items: [VariantRequestItem], language: RenderingLanguage, pair: LanguagePair) async throws
      -> [Int: VariantItemOutcome]     // ключ — ref; кожен запитаний ref присутній у результаті
}
extension ClaudeLookupService: VariantBatchLookupService   // той самий ключ/модель/логер/клієнт
```
- `VariantPromptBuilder.buildBatch(items:language:pair:) -> BuiltPrompt`: system = `language.prompt.batchSystem`,
  user = `batchUser` з `{{ITEMS}}` = JSON-масив `[{"id":1,"word":"run","pos":"verb","meaning":["бігти","керувати"]}]`,
  закодований `JSONEncoder` (`.sortedKeys`, без `prettyPrinted` — менше токенів) і обгорнутий у `<items>…</items>` з
  інструкцією вважати вміст лише даними. Відповідь — **один JSON-масив**:
  `[{"id":1,"word":"correre","lemma":"correre","part_of_speech":"verb","transcription":"/korˈrere/","translations":["бігти"],"example":{"source":"…","translation":"…"}}]`.
- `VariantBatchResponseParser.parse(_ text: String, items: [VariantRequestItem]) throws -> [Int: VariantItemOutcome]`:
  знімає code fence; підрядок від першої `[` до останньої `]`; не масив / не JSON → `.invalidResponse`. Кожен елемент:
  `id` — ціле (або рядок-число) з запитаного набору, інакше ігнорується; дубль id — перший виграє; поля валідуються
  як у §7.4 з `kind` елемента → `.ready` або `.invalid(reason)`; запитаний id без елемента → `.missing`.
  Пакет з частково невалідними елементами — **успішна** відповідь (часткова).
- Конверт/`stop_reason` — як §7.4 (`refusal` → `.refused`; `max_tokens` з непарсним текстом → `.invalidResponse`).
  Повтор при `.invalidResponse` рівня відповіді — один, як §7.5; при частково невалідних елементах повтору нема.
- `max_tokens` для пакета — `ClaudeConfiguration.batchMaxTokens = 8192` (15 × ~180 токенів ≈ 2700 + запас під adaptive
  thinking). Тіло — ті самі 4 ключі (§7.2). `ClaudeRequestBuilder` бере `configuration.maxTokens`; сервіс підставляє
  8192 лише для пакета. Чи приймає обрана модель 8192 — U15.

---

## 8. Обробка записів і черга pending (Processing)

### 8.1 ErrorDisposition (D6)

| `ClaudeError` | Статус запису | Лічильник спроб | Авто-повтор |
|---|---|---|---|
| `.offline` | `pending` | не збільшується | при відновленні мережі / старті / таймері |
| `.missingAPIKey` | `pending` | не збільшується | після збереження ключа в Settings |
| `.timeout`, `.rateLimited`, `.server` | `pending` | +1 | за `RetryPolicy`; після 5-ї невдалої — `failed` |
| `.transport`, `.storage` | `pending` | +1 | як вище (на 5-й спробі — `failed`) |
| `.unauthorized`, `.forbidden`, `.badRequest`, `.invalidResponse`, `.refused` | `failed` | — | лише кнопка «Повторити» |

`ErrorDisposition.for(_ error: ClaudeError, attempts: Int) -> (status: EntryStatus, countsAttempt: Bool)`.
`lastError` — україномовний опис (`ClaudeError.userMessage`), без секретів.

*Уточнення до рішення оркестратора «offline → pending, решта → failed»*: тимчасові серверні помилки (429/5xx/timeout)
теж спершу йдуть у `pending` з обмеженою кількістю спроб, бо вони самі минають; постійні помилки — одразу `failed`.

### 8.2 RetryPolicy (D7)

`delay(forAttempt n) = min(30 * 2^(n-1), 900)` секунд (30 с, 1 хв, 2 хв, 4 хв, 8 хв); для `.rateLimited` —
`max(retryAfter ?? 0, delay)`; `maxAttempts = 5`. Стан спроб (`attempts`, `nextAttemptAt`) — **у пам'яті**
`PendingQueueProcessor` (не в JSON); після перезапуску застосунку відлік починається заново.

### 8.3 EntryProcessor і PendingQueueProcessor

```swift
public final class EntryProcessor: Sendable {          // обробляє ОДИН запис
  init(repository: DictionaryRepository, lookup: WordLookupService, registry: LanguagePairRegistry, dateProvider:)
  func process(entryID: UUID, attempts: Int) async -> ProcessingResult
}
public enum ProcessingResult: Equatable, Sendable {
  case ready(Entry)
  case pending(Entry, ClaudeError)
  case failed(Entry, ClaudeError)
  case skipped(Entry)        // запис уже обробляється (в inFlight) або вже не pending/failed — нічого не зроблено
  case notFound(UUID)        // запис видалено
}
public actor PendingQueueProcessor {
  init(repository:, processor: EntryProcessor, policy: RetryPolicy, dateProvider:)
  func processDue() async -> [ProcessingResult]          // pending-записи, у яких nextAttemptAt <= now; послідовно
  func processAll(ignoringBackoff: Bool) async -> [ProcessingResult]  // старт, мережа, новий ключ
  func retry(entryID: UUID) async -> ProcessingResult    // кнопка «Повторити»: pending або failed, скидає attempts
}
```
- `retry(entryID:)` для запису, що **вже в обробці** (`inFlight`, напр. під час `processAll`), — no-op: повертає
  `.skipped(entry)` без другого HTTP-запиту; результат тієї обробки прийде в UI через `repository.changes()`.
- Записи обробляються **послідовно** (без паралельних запитів). Повторний виклик під час обробки не запускає
  другий прохід: actor тримає `isRunning`; запис, що вже в обробці (`inFlight: Set<UUID>`), пропускається.
- Успіх: `word` оновлюється за D5, заповнюються поля, `status = .ready`, `lastError = nil`.
- Невідома пара (`registry.pair(id:) == nil`) → `failed` з повідомленням «Невідома мовна пара».
- Тригери в застосунку: старт, `NetworkMonitor` → `.satisfied`, збереження ключа/моделі,
  `Timer` кожні 60 с (`processDue`) лише поки існують pending-записи, кнопки «Повторити» / «Повторити всі».
- M6, `Processing/ProcessingTrigger.swift`: `public enum ProcessingTrigger: String, CaseIterable, Sendable { case manual,
  retryAll, startup, network, keySaved, modelChanged, imported, due }` і
  `public enum QueueLog { static func started(_ trigger:, entryID: UUID?) -> String; static func finished(_ trigger:, results: [ProcessingResult]) -> String }`.
  Формат: `Queue run started: trigger=network` / `Queue run finished: trigger=manual id=<UUID> ready=1 pending=0 failed=0 skipped=0 notFound=0`.
  Лише тригер, UUID і лічильники — без слова, тексту помилки, ключа. Сигнатури `PendingQueueProcessor` не змінюються:
  логує `AppModel` (через `claude.logger`) навколо кожного виклику черги.
- **M7 — `EntryProcessor.applySuccess` з варіантами й детекцією мови** (один lookup = один комбінований запит):
  1. `result.sourceLanguage == pair.sourceLanguageCode` (або `nil`): як D5 — `entry.word = result.word`, якщо ключі
     збігаються з виділенням, інакше лишається виділення; `entry.sourceLanguage = nil`.
  2. `result.sourceLanguage == "it"` (будь-який id варіанта): `entry.word = result.word` (англійський відповідник, без
     D5-перевірки); `variants["it"].word` = `result.variants["it"].word`, якщо його ключ = ключ виділення, інакше
     очищене виділення (D5 для мови виділення); `entry.sourceLanguage = "it"`.
  3. Для кожного `pair.renderings`: є валідний `result.variants[id]` → `EntryVariant(status: .ready, sourceKey:
     key(entry.word), updatedAt: now)`; нема → `EntryVariant(status: .pending, …порожні поля…, lastError: nil)`.
  4. **Перевірка дубля після відповіді** (D27): `keys = {key(entry.word)} ∪ {key(v.word) для ready-варіантів}`;
     `repository.findDuplicate(keys:languagePair:excluding: entry.id)`. Знайдено `X` → поточний pending-запис
     **видаляється**; якщо `key(X.word) == key(entry.word)` (те саме поняття), то варіанти, яких у `X` немає в стані
     `ready`, заповнюються з цієї ж відповіді через `setVariants` (токени не пропадають); результат —
     `ProcessingResult.duplicate(existing: X, removedID: entry.id)` (новий case). Інакше →
     `repository.update(entry, replacingVariants: true)` → `.ready`.
  `AddWordUseCase`: `.duplicate(existing, _)` → `AddWordOutcome.duplicate(existing)` («Вже є в словнику»).
  `QueueLog.finished` додає лічильник `duplicate=N` (формат з M6 інакше не змінюється). Помилки lookup — §8.1 без змін
  (варіанти не чіпаються).

### 8.4 M7: пакетне доповнення варіантів (`Processing/VariantBackfillProcessor.swift`)

```swift
public struct VariantBackfillReport: Equatable, Sendable {
  public var eligible: Int, requests: Int, ready: Int, pending: Int, failed: Int
  public var stoppedBy: ClaudeError?          // помилка, що зупинила прохід (offline, ключ, 429…)
  public var alreadyRunning: Bool             // інший прохід триває — нічого не зроблено
}
public actor VariantBackfillProcessor {
  public static let defaultBatchSize = 15
  public init(repository: DictionaryRepository, lookup: VariantBatchLookupService, registry: LanguagePairRegistry,
              policy: RetryPolicy, dateProvider: DateProvider, batchSize: Int = VariantBackfillProcessor.defaultBatchSize)
  public func eligibleEntryIDs(languageID: String, includeFailed: Bool) async -> [UUID]
  public func backfill(languageID: String, ignoringBackoff: Bool) async -> VariantBackfillReport  // авто
  public func backfillAll(languageID: String) async -> VariantBackfillReport   // кнопка «Доповнити італійською»: + failed, без backoff
  public func refresh(entryID: UUID, languageID: String) async -> VariantBackfillReport  // «Оновити італійський переклад»: 1 запит, перезаписує навіть ready
}
```
- **Придатні** (авто): `entry.status == .ready`, пара має rendering `languageID`, `variantState ∈ {missing, stale,
  pending}` і (якщо `!ignoringBackoff`) `nextAttemptAt <= now`. `ready` (не stale) — **ніколи** (D28: 0 запитів).
  `failed` — лише `backfillAll`/`refresh`. Записи з `status != .ready` не доповнюються: їх заповнить комбінований
  запит черги.
- Групування за `languagePair` (промт залежить від пари), порядок — `createdAt` за зростанням, пакети по
  `batchSize` → `ceil(n / 15)` запитів, **послідовно**. Після кожного пакета — **одразу** `repository.setVariants` (один
  атомарний save на пакет; часткові успіхи зберігаються навіть якщо наступний пакет впаде).
- Результати елементів: `.ready` → варіант `ready`, `sourceKey = key(entry.word)` на момент формування пакета (якщо
  запис змінився — `setVariants` відкине, §6); `.invalid`/`.missing` → `pending` з `lastError`, лічильник спроб елемента
  +1 (у пам'яті, як §8.2), після `maxAttempts` (5) → `failed`.
- Помилки пакета (`ClaudeError`), D29:
  | Помилка | Варіанти пакета | Прохід |
  |---|---|---|
  | `.offline`, `.missingAPIKey`, `.unauthorized`, `.forbidden` | без змін, спроба не рахується | **зупинити** (решта пакетів не надсилається) |
  | `.timeout`, `.rateLimited`, `.server`, `.transport` | `pending`, +1 спроба, backoff за `RetryPolicy` | зупинити |
  | `.invalidResponse` (після 1 повтору), `.refused`, `.badRequest` | `failed` з `lastError` | продовжити з наступним пакетом |
  | `.storage` (save не вдався) | у файлі без змін | зупинити, лог `error` |
- `isRunning`: паралельний виклик → `alreadyRunning = true`, 0 запитів. Черга (§8.3) і доповнення можуть іти
  одночасно: множини записів не перетинаються (черга — не-ready, доповнення — ready), а `update(_:)` не перезаписує
  варіанти (§6).
- **Коли запускається (лише в режимі варіанта — лінивість, D28):** перше й кожне наступне перемикання на IT
  (якщо придатних 0 — 0 запитів, тож після одного повного проходу повторних запитів нема), старт застосунку зі
  збереженим режимом IT, `NetworkMonitor`/збереження ключа — якщо режим IT і є придатні. **Не** за таймером і **не** в
  режимі EN. Ручні дії — кнопка «Доповнити італійською (N)» (видима, коли є pending/failed/missing) і пункт контекстного
  меню «Оновити італійський переклад».
- Логування: `QueueLog.variantStarted(trigger:languageID:eligible:)` / `variantFinished(trigger:report:)` →
  `Variant backfill started: trigger=displaySwitch language=it eligible=37` /
  `Variant backfill finished: trigger=displaySwitch language=it requests=3 ready=36 pending=1 failed=0`. Без слів.
  `ProcessingTrigger` (M6) отримує нові case-и `displaySwitch`, `variantBackfill`, `variantRefresh`.

---

## 9. Use-cases (UseCases)

```swift
public enum AddWordOutcome: Equatable, Sendable {
  case added(Entry)                 // status ready
  case duplicate(Entry)             // уже є (будь-який статус)
  case queued(Entry, ClaudeError?)  // збережено як pending; nil = вже обробляється (ProcessingResult.skipped)
  case failed(Entry, ClaudeError)   // збережено як failed
  case rejected(SelectionRejection) // нічого не збережено
  case storageError(String)
}
public final class AddWordUseCase: Sendable {
  init(repository:, processor: PendingQueueProcessor, settings: SettingsStore, registry:)
  func execute(rawText: String?) async -> AddWordOutcome
}
public final class ServiceRequestHandler: Sendable {   // точка входу для Services і ручного «Додати через Claude»
  init(useCase: AddWordUseCase)
  func handle(text: String?) async -> ServiceResponse  // { outcome, notification: NotificationContent }
}
public struct ServiceResponse: Equatable, Sendable { outcome: AddWordOutcome; notification: NotificationContent } // ServiceRequestHandler.swift
public struct NotificationContent: Equatable, Sendable { title: String; body: String }
public enum NotificationText { static func make(for: AddWordOutcome) -> NotificationContent }
```

Алгоритм `execute`: `SelectionValidator` → `.rejected` | `repository.add(draft{word: cleaned.text, status: .pending})`
(дубль → `.duplicate`) → `processor.retry(entryID:)` → мапінг `ProcessingResult` → outcome:
`.ready` → `.added`; `.pending(e, err)` → `.queued(e, err)`; `.failed(e, err)` → `.failed(e, err)`;
`.skipped(e)` → `e.status == .ready ? .added(e) : .queued(e, nil)` (запис щойно підхопив паралельний `processAll`; див. D17); `.notFound` → `.storageError`.
Запис зберігається як `pending` **до** запиту — тож падіння застосунку чи офлайн не губить слово.

Тексти (`NotificationText`):
- `.added` → title «Додано», body «Додано: run — бігти, керувати» (до 3 перекладів через «, »);
- `.duplicate` → «Вже є в словнику», body «run — бігти» (або «run — очікує обробки» для pending/failed);
- `.queued(.offline)` → «Збережено в чергу», body «run: немає мережі, переклад буде додано пізніше»;
  `.queued(.missingAPIKey)` → «…: додайте API-ключ у налаштуваннях»; `.queued(.storage)` → «run: не вдалося зберегти запис, повторимо пізніше»; інші `.queued(_, error)` → «…: повторимо пізніше»;
  `.queued(_, nil)` (skipped) → title «Обробляється», body «Обробляється: run»;
- `.failed` → «Не вдалося додати», body «run: <userMessage>»;
- `.rejected(.empty)` → «Нічого не виділено»; `.tooLong` → «Виділено забагато тексту (макс. 120 символів)»;
  `.tooManyWords` → «… (макс. 8 слів)»; `.noLetters` → «Виділений текст не містить слів».
- **M7:** слово й переклади в тексті сповіщення беруться з відображення **мови виділення**:
  `EntryDisplay.make(entry, languageID: entry.sourceLanguage)` → «Додано: casa — дім, будинок»; для en — як раніше.
  `.duplicate` за італійським ключем — «Вже є в словнику», body з італійського відображення («casa — дім»).
  `SelectionValidator`/`TextNormalizer` не змінюються (італійські `l'acqua`, `perché` вже коректні: апостроф усередині
  лишається, `CharacterSet.letters` містить літери з діакритикою).

---

## 10. Імпорт / експорт (Transfer)

```swift
public enum ImportMode: Sendable { case merge, replace }
public struct ImportReport: Equatable, Sendable { added: Int; updated: Int; skipped: Int; skippedReasons: [String]
  var summary: String  // "Додано X, оновлено Y, пропущено Z" }
public enum ImportError: Error, Equatable { case emptyFile, notJSON, missingSchemaVersion,
  unsupportedSchemaVersion(Int), missingEntries, readFailed(String), backupFailed(String), storage(String)
  var userMessage: String }   // україномовні тексти
public struct ParsedImport: Equatable, Sendable { entries: [Entry]; skippedReasons: [String] }
public enum DictionaryImporter { static func parse(_ data: Data) throws -> ParsedImport }
public enum ImportMerger {
  static func collapseDuplicates(_ imported: [Entry]) -> (entries: [Entry], skippedReasons: [String])
  static func merge(local: [Entry], imported: [Entry]) -> (entries: [Entry], report: ImportReport)
}
public enum DictionaryExporter { static func exportData(entries: [Entry], now: Date) throws -> Data }
public final class DictionaryTransferService: Sendable {
  init(repository:, store: DictionaryStoring, backups: BackupManager, fileSystem:, dateProvider:)
  @discardableResult
  func exportDictionary(to url: URL) async throws -> Int            // атомарний запис; повертає кількість записів
  func importDictionary(from url: URL, mode: ImportMode) async throws -> ImportReport
}
// Методи DictionaryRepository (§6), що обслуговують перенесення:
extension DictionaryRepository {
  func loadedEntries() throws -> [Entry]                       // для експорту; до load() → RepositoryError.notLoaded
  func mergeImported(_ imported: [Entry]) throws -> ImportReport   // ImportMerger.merge + один commit в одному виклику актора
  func replaceAll(_ entries: [Entry], beforeSave: @Sendable () throws -> Void) throws  // бекап у тому ж виклику
}
```
Помилка читання файлу (`fileSystem.readData`) → `ImportError.readFailed(reason)`; `RepositoryError` → `ImportError.storage`.
Експорт бере записи через `loadedEntries()`, щоб не експортувати порожній незавантажений словник.

Валідація (`parse`): 0 байтів або лише пробіли → `.emptyFile`; не JSON-об'єкт → `.notJSON`; немає `schemaVersion`
(або не ціле) → `.missingSchemaVersion`; `schemaVersion != 1` → `.unsupportedSchemaVersion(n)`; `entries` відсутній
або не масив → `.missingEntries`. Далі кожен елемент декодується окремо (`JSONSerialization` → `Data` → `Entry`);
запис з відсутнім обов'язковим полем (`id` як UUID, `languagePair`, непорожній `word`, `status` ∈ enum,
`createdAt`, `updatedAt`, `translations` — масив, для `ready` непорожній) → пропускається з причиною
«Запис #N: відсутнє поле word». Помилка рівня файлу → словник не змінюється взагалі.
Очищення прийнятих записів: `word` → `TextNormalizer.clean`; кожен переклад — згортання пробілів + trim, порожні
відкидаються (крайня пунктуація перекладів **не** знімається, напр. «бігти (швидко)»); `ready` без жодного
непорожнього перекладу після очищення → пропуск. Тексти файлових помилок — `FileErrorText.describe(_:)`.

Merge (D1): дублікати всередині файлу згортаються першими (лишається новіший `updatedAt`, інші — `skipped`).
Для кожного імпортованого: шукаємо локальний **за `id`**, якщо не знайдено — **за (`languagePair`, `key(word)`)**.
- немає збігу → додати (`added`);
- збіг і `imported.updatedAt > local.updatedAt` → імпортований запис замінює локальний **цілком** (включно з його
  `createdAt` і `updatedAt`), але **з `id` локального** (`updated`); винятки (`skipped`): імпортований `pending/failed`
  не перезаписує локальний `ready`; заміна, що дала б дубль іншого локального запису за ключем D8;
- інакше (старіший або рівний) → `skipped`.
Виконується `repository.mergeImported(parsed.entries)`: злиття з поточним станом і один атомарний запис в одному
виклику актора (паралельні зміни черги/Services не губляться); якщо `added == 0 && updated == 0` — запису на диск нема.
До `skipped` звіту сервіс додає невалідні записи з `ParsedImport` (D13).

Replace: `ImportMerger.collapseDuplicates(parsed.entries)` → `repository.replaceAll(collapsed, beforeSave:)`, де
`beforeSave` (якщо поточний файл існує) робить `BackupManager.makeBackup(.replaceImport)` у тому ж виклику актора
безпосередньо перед записом; помилка бекапу → `ImportError.backupFailed`, нічого не записується.
Звіт: `added` = кількість записів після згортання, `updated = 0`, `skipped` = невалідні + дублікати у файлі. Підтвердження —
в UI (`ImportModeDialog`: «Замінити словник? Поточний буде збережено в Backups.»).

Експорт: `DictionaryFile(schemaVersion: 1, exportedAt: now, entries)`, ті самі налаштування енкодера. Імпортовані
`pending` записи після імпорту обробляються чергою (`processAll`).

**M7 — варіанти при імпорті/merge.** `schemaVersion` лишається 1; експорт пише `variants`/`sourceLanguage` як є.
- `DictionaryImporter.parse`: некоректні варіанти відкидаються стійким декодуванням `Entry` (§3.2) — запис **не**
  пропускається й у звіт не потрапляє (варіант доповниться пакетно). `normalized` додатково для кожного варіанта:
  `word` → `TextNormalizer.clean`, переклади — як для запису; `ready` з порожнім `word` або без перекладів → варіант
  відкидається. `sourceLanguage` не з `[pair.sourceLanguageCode] + renderings` (для відомої пари) → `nil`.
- `VariantMerge.combine(winner: Entry, other: Entry) -> [String: EntryVariant]?` (`Transfer/VariantMerge.swift`):
  кандидати — варіанти обох записів, у яких `sourceKey == key(winner.word)` (варіант мови `winner.sourceLanguage`
  завжди лишається від winner); на кожну мову: `ready` перемагає не-ready; обидва ready → строго новіший
  `variant.updatedAt`, рівність → winner; жоден не ready → winner-ів, якщо є, інакше other.
- `ImportMerger.merge` (D1 без змін щодо основних полів і ключа збігу — англійський `key(word)` або `id`): після
  вибору переможця `variants = VariantMerge.combine(...)`. Якщо основні поля лишаються локальними (`skipped` за D1),
  але `combine` змінив варіанти локального (напр., імпортований файл з іншого Mac уже має італійські дані) — запис
  рахується як `updated` (D30: економія — дані з файлу замість нових запитів). `collapseDuplicates` — те саме правило.

---

## 11. Застосунок (macOS-таргет)

- `VocabApp: App` — `@NSApplicationDelegateAdaptor(AppDelegate.self)`; сцени:
  `MenuBarExtra("Словник", systemImage: "character.book.closed")` зі стилем `.menu` (пункти: «Відкрити словник»,
  «Повторити очікувані (N)», «Налаштування…», «Вийти»); `Window("Словник", id: "dictionary")`;
  `Window("Налаштування", id: "settings")` (окреме вікно замість `Settings`-сцени, щоб на macOS 13 відкривати його
  через `openWindow` без приватного селектора `showSettingsWindow:`). Після `openWindow` —
  `NSApp.activate(ignoringOtherApps: true)` (LSUIElement-застосунок не активується сам).
  Головне вікно при запуску **не відкривається**: лише через `openWindow` з `MenuBarExtra` (мітигація для macOS 13 — U12).
- `AppDelegate` (композиційний корінь): створює `FileDictionaryStore`, `DictionaryRepository`,
  `KeychainSecretStore`, `ClaudeLookupService(URLSessionTransport(session: URLSession(configuration: .ephemeral)))`, процесори,
  `AppModel`. У `applicationDidFinishLaunching`, **якщо не `AppEnvironment.isRunningTests`**
  (`ProcessInfo.environment["XCTestConfigurationFilePath"] != nil`): `NSApp.servicesProvider = servicesProvider`;
  `NSUpdateDynamicServices()`; запит дозволу сповіщень; старт `NetworkMonitor`; `repository.load()`; `processAll`.
  Під тестами `AppModel` працює з тимчасовим каталогом і `InMemorySecretStore`.
- `AppModel: ObservableObject` (`@MainActor`), init: `repository:`, `languagePairID:`, `claude:`, `transfer:`,
  `filePanels:`, `loginItems: LoginItemManaging?`, `speech: SpeechSpeaking?`, `registry: LanguagePairRegistry`
  (`nil` → відповідна функція недоступна); `@Published entries`, `query`, `loadError`, `lastReport`, `lastServiceMessage: String?` (текст останнього результату Services — показується в меню, якщо сповіщення заборонені), `hasAPIKey`; підписка
  на `repository.changes()` у `Task`; методи `addManual`, `addViaClaude`, `update`, `delete`, `retry`,
  `retryAll`, `export(to:)`, `import(from:mode:)`, `saveAPIKey`, `setModel`.
  **M6:** init `AppModel(..., settings: SettingsStore? = nil, appearanceApplier: AppearanceApplying? = nil)`; сховище
  визначається **лише** правилом `self.settings = settings ?? claude?.settings ?? InMemorySettingsStore()` — окремого
  сховища поряд із Claude немає. `AppDelegate` параметр `settings:` не передає (бере `claude.settings`, той самий
  `UserDefaultsSettingsStore`); явний `settings:` — лише для тестів/конфігурації без Claude.
  `@Published pageNumber: Int = 1`, `@Published private(set) pageSize: Int`, `@Published private(set) appearance: AppAppearance`;
  `var currentPage: EntryPage` = `Pagination(pageSize:).page(pageNumber, of: query.apply(to: entries))`;
  `nextPage()`, `previousPage()`, `setPageSize(_:)` (значення поза `Pagination.pageSizeOptions` ігнорується; інакше зберігає й `pageNumber = 1`), `setAppearance(_:)` (зберігає + `applier.apply`).
  `query` має `didSet`: якщо змінився `searchText` або `sort` → `pageNumber = 1`. Після кожного `apply(entries)` (зміни
  репозиторію, видалення, імпорт) → `pageNumber = pagination.clamp(pageNumber, totalCount: відфільтрованих)`.
  Тригери черги: `retry(id:)` → `.manual`, `retryAll()` → `.retryAll`, `processDue()` → `.due`,
  `processPending(trigger:)` (старт → `.startup`, `NetworkMonitor` → `.network`, ключ → `.keySaved`, модель → `.modelChanged`,
  імпорт → `.imported`); кожен виклик логується `QueueLog.started/finished` рівнем `info`.
- **Головне вікно (M6)** — `DictionaryWindowView`: `.searchable` і `Picker` сортування (як у M5) у toolbar; під ними
  `EntryTableView` — SwiftUI `Table(model.currentPage.entries, selection: $selection)` (`Set<Entry.ID>`), колонки
  `TableColumn("Слово")` (`word`, жирним), «Транскрипція» (`transcription ?? ""`), «Переклад» (`translations.joined(", ")`),
  «Приклад» (`example.source`, `.help("source — translation")`), вузька колонка без заголовка `.width(70–90)`:
  бейдж «очікує»/«помилка» (`.help(lastError)`), кнопка «Повторити» (лише pending/failed, `ProgressView` під час retry),
  кнопка озвучення (лише ready, якщо `speech != nil`). Текст у клітинках — `lineLimit(1)` + `.help(повний текст)`.
  Дії над рядком — `.contextMenu(forSelectionType: Entry.ID.self, menu:, primaryAction:)` (macOS 13+): «Редагувати»
  (і подвійний клік = primaryAction → `EntryEditorView` sheet), «Повторити», «Озвучити», «Видалити» (з підтвердженням, як у M5).
  **Сортування — лише Picker** (`EntrySort` у `EntryQuery`); `Table` без `sortOrder:` (заголовки не клікабельні). Причина:
  `dateNewest/dateOldest` сортують за `createdAt`, якого немає серед колонок; `KeyPathComparator` дав би друге джерело
  істини для порядку й не зберігав би ключ `TextNormalizer.key` для алфавіту.
  Знизу `PaginationBar`: «‹ Попередня  Сторінка N з M  Наступна ›» (`currentPage.label`; кнопки `disabled` за
  `hasPrevious/hasNext`); прихована, якщо `pageCount == 1`. Зміна сторінки скидає `selection`. Порожній стан — як у M5.
- **Налаштування (M6)** — `SettingsView`: секція «Вигляд»: `Picker("Тема", …)` з `AppAppearance.allCases`
  (`.pickerStyle(.radioGroup)`) і `Picker("Записів на сторінці", …)` з `Pagination.pageSizeOptions`.
- **Тема (M6)** — `@MainActor protocol AppearanceApplying: AnyObject { func apply(_ appearance: AppAppearance) }`
  (`Platform/AppearanceController.swift`), реалізація `AppearanceController` (`@MainActor`): `NSApp.appearance =`
  `nil` (`.system`) / `NSAppearance(named: .aqua)` / `NSAppearance(named: .darkAqua)`. Обрано `NSApp.appearance`, а не
  `preferredColorScheme`: воно наслідується всіма вікнами застосунку (обидві `Window`-сцени, sheet-и, алерти,
  `NSOpenPanel/NSSavePanel`), тоді як `preferredColorScheme` діє на одну сцену й має відомі проблеми з поверненням до
  системної теми (`nil`). `AppDelegate` застосовує збережену тему в `applicationDidFinishLaunching` (і під тестами — ні).
  Чи підхоплює меню `MenuBarExtra` (стиль `.menu`, це `NSMenu` від status item) тему застосунку — U14.
- `ServicesProvider: NSObject` (`@MainActor`):
  ```swift
  @objc(addToDictionary:userData:error:)
  func addToDictionary(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)
  ```
  Читає `pboard.string(forType: .string)` (= `public.utf8-plain-text`), при `nil` — пробує
  `NSPasteboard.PasteboardType("NSStringPboardType")`. Порожньо → `error.pointee = "Не вдалося отримати текст"`
  і сповіщення «Нічого не виділено». Інакше одразу повертає керування, а в `Task` викликає
  `ServiceRequestHandler.handle` і `UserNotifier.post(content)`. Залежності (`handler`, `notifier`) — через init.
  `Task` захоплює `self` **сильно** (провайдер живе весь час роботи застосунку в `AppDelegate`), тому гілки
  «Services недоступні» немає.
  Точний бриджинг типу параметра `error` (`NSString?` vs `NSString`) — **перевірити компіляцією в CI** (U3).
- `KeychainSecretStore: SecretStore` — `kSecClassGenericPassword`, `kSecAttrService = "com.vocabapp.VocabApp"`
  (ін'єктується; тести — унікальний), `kSecAttrAccount = SecretKey.rawValue`; `SecItemCopyMatching`/`Add`/`Update`/
  `Delete`; `errSecItemNotFound` → `nil`. `OSStatus` помилки → `SecretStoreError.keychain(status:)` (оголошено в ядрі, `Security/SecretStore.swift`; без значення секрету).
- `UserNotifier` (протокол, `App/Sources/Platform/UserNotifier.swift`: `func requestAuthorization() async -> Bool`, `func post(_ content: NotificationContent) async`) / `NotificationService` — `UNUserNotificationCenter`; якщо дозволу нема —
  логуємо й показуємо останній результат у меню (`AppModel.lastServiceMessage`). Дозвіл запитується **лише на старті**
  (`AppDelegate`); `post` сам не запитує, а чекає на результат того самого запиту.
- `LoginItemService: LoginItemManaging` (`state`, `setEnabled(_:) throws`, `openSystemSettings()`; чиста
  `static func state(for: SMAppService.Status) -> LoginItemState`) — `SMAppService.mainApp.register()/unregister()/status`; `.requiresApproval` → кнопка
  «Відкрити Login Items» (`SMAppService.openSystemSettingsLoginItems()`).
- `SpeechService: SpeechSpeaking` (`speak(_:languageCode:)`, `stop()`, `makeUtterance(text:languageCode:)`) — `AVSpeechSynthesizer`, `AVSpeechUtterance(string:)`, `voice = AVSpeechSynthesisVoice(language: pair.speechLanguageCode)`.
- `FilePanels` — `NSSavePanel` (`nameFieldStringValue = "dictionary.json"`, `allowedContentTypes = [.json]`),
  `NSOpenPanel` (`allowedContentTypes = [.json]`, один файл).
- `NetworkMonitor` — `NWPathMonitor` на власній черзі; при переході в `.satisfied` → `Task { @MainActor in await model.processPending(trigger: .network) }` (M6; усередині — `processAll(ignoringBackoff: true)`).
- `OSLogSink: LogSink` — `os.Logger(subsystem: "com.vocabapp.VocabApp", category:)`, повідомлення з `privacy: .public`
  (вони вже відредаговані `RedactingLogger`). Категорії (M6): `claude` (HTTP, черга, ключ) і `notifications`
  (`NotificationService` отримує окремий `RedactingLogger(sink: OSLogSink(category: "notifications"), secretsProvider: keyCache.secrets)`). Ім'я `RedactingLogger` обрано, щоб не конфліктувати з `os.Logger` в app-таргеті.
- **M7 — перемикач мови відображення.** `DictionaryWindowView`: `ToolbarItem(placement: .principal)` з
  `Picker("Мова", selection: $model.displayLanguageSelection)` `.pickerStyle(.segmented)`, сегменти
  `pair.sourceShortTitle` («EN», tag `nil`) + `pair.renderings.map(\.shortTitle)` («IT», tag `"it"`); прихований, якщо
  `renderings` порожні. Розміщення `.principal` на macOS 13 — U16 (план Б: `.navigation` / `.automatic`).
  Поруч — кнопка «Доповнити італійською (N)» (`N` = придатні з failed; видима лише в режимі IT і `N > 0`;
  `ProgressView` під час проходу) і, під час автопроходу, текст «Доповнення італійською…».
- `AppModel` (M7): init отримує `variantBackfill: VariantBackfillProcessor? = nil`; `@Published private(set)
  displayLanguageID: String?` (з `settings.displayLanguageID`, перевірений `pair.rendering(id:)`), `isBackfilling`,
  `lastBackfillReport`. `setDisplayLanguage(_ id: String?)`: зберігає в Settings, `pageNumber = 1`, `query.languageID = id`,
  скидає виділення; якщо `id != nil` → `runBackfill(trigger: .displaySwitch)` (`backfill(languageID:ignoringBackoff: true)`).
  `backfillAll()` → `.variantBackfill`; `refreshVariant(id:)` → `.variantRefresh`. Старт (`processPending(.startup)`),
  `.network`, `.keySaved` — після черги викликають автопрохід, **лише** якщо `displayLanguageID != nil`.
  `var displayedPage` — сторінка з `EntryDisplay` (`currentPage.entries.map { EntryDisplay.make($0, languageID:) }`).
- `EntryTableView` у режимі IT рендерить `EntryDisplay`: «Слово» — `display.word` (fallback-рядок — приглушеним
  `.secondary`), «Транскрипція», «Переклад», «Приклад» — поля варіанта; статусна колонка — бейдж за
  `display.state`: `missing/stale/pending` → «італійська версія очікує» (`.help(lastError ?? "Буде доповнено при
  наступному запуску доповнення")`), `failed` → «помилка» (`.help(lastError)`) + кнопка «Повторити» (`refreshVariant`);
  англійський `pending/failed` запису — як у M6. Озвучення — `display.word` з `rendering.speechLanguageCode`
  (`it-IT`), лише для ready-варіанта (U17). Контекстне меню додає «Оновити італійський переклад» (явна дія, 1 запит).
- `EntryEditorView` у режимі IT редагує поля варіанта (слово, транскрипція, переклади, приклад) і зберігає через
  `repository.setVariants` (`status: .ready`, `sourceKey = key(entry.word)`, `updatedAt = now`; `Entry.updatedAt` не
  змінюється). У режимі EN — як раніше. `AddEntryView` (ручне) — лише англійські поля; варіант доповниться пакетно.

### 11.1 Конкурентність (Swift 5 mode, macOS 13)

- Ядро: `DictionaryRepository` і `PendingQueueProcessor` — `actor`; решта сервісів — `final class`/`struct` без
  змінюваного стану (`Sendable`). Моделі — `Sendable` value types. Класи з локом — `@unchecked Sendable` з `NSLock`.
- UI: `AppModel`, `ServicesProvider`, views — `@MainActor`. Перехід у actor — `await`; оновлення `@Published` — лише
  на головному акторі (у `Task { @MainActor in … }`).
- Не використовуємо `Task.detached`, `DispatchQueue.main.sync`, `@preconcurrency` без коментаря.
  Строгу перевірку конкурентності не вмикаємо (Swift 5 mode); попередження Sendable — не помилки.

---

## 12. Рішення щодо неоднозначностей

| # | Питання | Рішення |
|---|---|---|
| D1 | Ідентичність конфлікту при merge | Спершу збіг за `id`; якщо нема — за (`languagePair`, `TextNormalizer.key(word)`). Перемагає строго пізніший `updatedAt`; рівність → лишається локальний. При заміні зберігається локальний `id`. Імпортований `pending/failed` не перезаписує локальний `ready`. |
| D2 | Бекап | `~/Library/Application Support/VocabApp/Backups/dictionary-backup-yyyyMMdd-HHmmss.json` (UTC), зіпсований файл — `dictionary-corrupted-…json`; зберігаємо 10 останніх кожного виду. |
| D3 | Макс. довжина виділення | 120 символів після `clean` і ≤ 8 слів; інакше `rejected` + сповіщення. |
| D4 | `exportedAt` у файлі на диску | Час останнього збереження (оновлюється при кожному `save`). При читанні — необов'язкове поле. |
| D5 | Яке `word` зберігати | До відповіді — очищене виділення (`clean`, регістр як виділено). Після відповіді — `word` від моделі, **якщо** `key(model.word) == key(selection)`; інакше лишається виділення (лема від моделі йде в `lemma`). |
| D6 | `failed` vs `pending` | Таблиця §8.1: offline/немає ключа → pending без лічильника; timeout/429/5xx/transport → pending з ≤5 спробами; 400/401/403/404/невалідний JSON після повтору/refusal → failed. |
| D7 | Політика повторів | Експоненційна: 30 с × 2^(n-1), максимум 15 хв, 5 спроб; `retry-after` має пріоритет; ручний «Повторити» ігнорує backoff і скидає лічильник. Стан спроб лише в пам'яті. |
| D8 | Ключ дедуплікації (слова і фрази) | (`languagePair`, `key(word)`), де `key` = clean + lowercase + згорнуті пробіли + нормалізований апостроф. Однаково для слів і фраз. За `lemma` не дедуплікуємо (`runs` ≠ `run`). |
| D9 | Модель за замовчуванням | `claude-haiku-5-5`; змінюється в Settings (текстове поле + скидання до default). |
| D10 | `max_tokens` | 4096; тіло запиту — лише `model`, `max_tokens`, `system`, `messages` (без `output_config`/`thinking`/sampling). `stop_reason: max_tokens` з непарсним текстом = невалідний JSON → 1 повтор → `failed`. |
| D11 | Таймаут | `URLRequest.timeoutInterval = 30` с на запит; з одним повтором при невалідному JSON — до ~60 с. |
| D12 | Зіпсований `dictionary.json` | Переносимо в Backups як `corrupted`, стартуємо з порожнього, показуємо попередження. `schemaVersion > 1` — не чіпаємо, показуємо помилку. |
| D13 | Невалідні окремі записи при імпорті | Пропускаються й рахуються в «пропущено»; помилки рівня файлу відхиляють імпорт цілком. |
| D14 | Ручне додавання | M1: форма з усіма полями, статус `ready`, перевірка дубля. M2+: додатково кнопка «Заповнити через Claude» (той самий `AddWordUseCase`). |
| D15 | Sandbox | Вимкнено (ad-hoc, поза App Store). |
| D16 | Поле `lastError` | Додаткове опційне поле запису (не ламає схему; ігнорується іншими читачами). |
| D17 | Services-виклик під час обробки черги | Якщо запис уже обробляється паралельним `processAll` (`.skipped`), сповіщення — «Обробляється: word» (або «Додано», якщо запис уже `ready`). Остаточний результат окремим сповіщенням не надсилається — він видний лише у вікні словника / меню (`lastServiceMessage`, статус запису). |
| D18 | Розмір сторінки (M6) | 25 за замовчуванням; Settings: 20 / 25 / 30. Скидання на 1 при зміні пошуку, сортування, розміру сторінки; clamp після видалення/імпорту. |
| D19 | Сортування таблиці (M6) | Лише `Picker` (`EntrySort`); заголовки колонок не сортують (див. §11). |
| D20 | Тема (M6) | `NSApp.appearance` на рівні застосунку; ключ `appearance`, default «Як у системі». |
| D21 | `schemaVersion` для M7 | Лишається **1**: `variants`/`sourceLanguage` — адитивні опційні поля; старі файли читаються без міграції; M1–M6 ігнорують нові ключі (при їх збереженні варіанти губляться — це кеш). Підвищення до 2 відхилили б і M6-читач (D12), і M6-імпортер (`!= 1`) — без вигоди. |
| D22 | Зіпсований варіант | Стійке декодування: варіант відкидається, запис і файл — ні (інакше весь файл став би `corrupted`). |
| D23 | Застарілий варіант | `sourceKey` = `key(entry.word)` при генерації; не збігається → `stale` (показ як «очікує», доповнюється). Варіант мови `sourceLanguage` ніколи не stale. |
| D24 | `updatedAt` варіанта | Власний; доповнення/редагування варіанта не змінює `Entry.updatedAt` (merge англійських полів не страждає). |
| D25 | Автовизначення мови виділення | У тому ж єдиному запиті (`source_language`); неоднозначне слово обох мов → `en`. `Entry.word` завжди англійський після відповіді; італійське виділення — у `variants.it`, `sourceLanguage = "it"`. Ручного вибору мови виділення в M7 немає (кандидат на M8). |
| D26 | Дублікати між мовами | Ключ дубля — будь-який з `dedupKeys()` (en + ready-варіанти) у межах пари. Наслідок: англійське й італійське слово з однаковим написанням (`come`) вважаються дублем — прийнятно, зафіксовано в M7.md. Merge імпорту — лише за англійським ключем/`id`. |
| D27 | Дубль, виявлений після відповіді | Pending-запис видаляється, `.duplicate(existing)`; відсутні ready-варіанти існуючого (того ж англійського ключа) заповнюються з цієї ж відповіді. |
| D28 | Коли витрачати токени на італійську | Нове слово — 1 комбінований запит (обидві мови). Старі записи — лише в режимі IT (перемикання/старт у IT/мережа/ключ) або вручну; пакети по 15, `ceil(n/15)` запитів; ready-варіант не запитується ніколи, крім явного «Оновити італійський переклад». Невалідний варіант у комбінованій відповіді не повторюється — йде в пакет. |
| D29 | Помилки пакета | Таблиця §8.4: offline/ключ/401/403 — зупинка без змін; тимчасові — pending + backoff, зупинка; невалідна відповідь/refusal/400 — failed, далі наступний пакет. |
| D30 | Варіанти при merge | `VariantMerge.combine`: ready > не-ready, новіший `updatedAt`, рівність → переможець D1; зміна лише варіантів рахується як `updated`. |

---

## 13. Невизначеності щодо macOS API (перенести в PROGRESS.md)

- **U1** `NSPortName`: чи має збігатися з `CFBundleName` і чи коректно працює для LSUIElement-застосунку.
- **U2** Чи з'являється сервіс у контекстному меню без ручного вмикання (System Settings → Keyboard → Keyboard
  Shortcuts → Services → Text) при порожньому `NSRequiredContext`.
- **U3** Бриджинг сигнатури `addToDictionary(_:userData:error:)` у Swift (`String?`, `AutoreleasingUnsafeMutablePointer<NSString?>`); перевірка — компіляція + `responds(to:)` у тесті.
- **U4** Виявлення сервісу `pbs` лише для застосунків у `/Applications` або `~/Applications` після першого запуску;
  чи вистачає `NSUpdateDynamicServices()` чи потрібен `/System/Library/CoreServices/pbs -update` / перелогін.
- **U5** Запуск LSUIElement-застосунку системою при виклику сервісу, коли він не запущений; чи встигає
  `servicesProvider`, виставлений у `applicationDidFinishLaunching`, прийняти запит.
- **U6** Chrome: підтримка Services для виділеного тексту (очікується так); PDF у Preview/Safari.
- **U7** `UNUserNotificationCenter` для ad-hoc підписаного застосунку: чи з'являється запит дозволу, чи доставляються
  сповіщення; поведінка після перепідпису (новий cdhash).
- **U8** `SMAppService.mainApp` для застосунку поза `/Applications` і з ad-hoc підписом; ймовірний статус
  `.requiresApproval`.
- **U9** Keychain з ad-hoc підписом: після кожної перезбірки змінюється підпис → можливі запити доступу до елемента
  Keychain. CI: GitHub macOS-раннери мають розблокований login keychain, тому `KeychainSecretStoreTests` пишуть у
  нього з унікальним `service` на прогін і прибирають у `tearDown`. **План Б**, якщо CI покаже
  `errSecInteractionNotAllowed`: окремий крок у `ci.yml` перед `xcodebuild test` —
  `security create-keychain -p ci build.keychain && security unlock-keychain -p ci build.keychain &&
  security set-keychain-settings build.keychain && security list-keychains -d user -s build.keychain login.keychain &&
  security default-keychain -s build.keychain`. `XCTSkip` не використовуємо.
- **U10** XcodeGen-локальний пакет з `path: .` (пакет у корені поруч із `.xcodeproj`) і імпорт `VocabCore` у
  hosted-тестах без явного лінкування.
- **U11** `AVSpeechSynthesisVoice(language: "en-US")` може повернути `nil` на CI-раннері (немає голосів).
- **U12** `MenuBarExtra` + `openWindow` на macOS 13: активація вікна для LSUIElement-застосунку, і чи **не
  відкривається** перша `Window`-сцена автоматично при запуску (`defaultLaunchBehavior(.suppressed)` є лише з
  macOS 15, тому недоступний). План: головне вікно відкривається лише через `openWindow(id: "dictionary")` з
  `MenuBarExtra`. Мітигація (перевірити на macOS 13): якщо система все ж відкриває вікно при старті, `AppDelegate`
  у `applicationDidFinishLaunching` закриває всі `NSApp.windows` з `identifier?.rawValue` що містить `"dictionary"`
  або `"settings"` (лише при першому запуску, не при відкритті через Services). Формат `NSWindow.identifier`
  для SwiftUI-сцен на macOS 13 не задокументований — **перевірити на Mac**. Запасний варіант: закривати всі
  `NSApp.windows`, крім вікна `MenuBarExtra` (і панелей), або фільтрувати за `title` («Словник», «Налаштування»).
- **U14** (M6) `NSApp.appearance` для LSUIElement-застосунку: чи миттєво перемальовуються вже відкриті вікна й `Table`;
  чи меню `MenuBarExtra(.menu)` слідує темі застосунку чи темі menu bar/системи (очікування: системі — прийнятно,
  зафіксувати в M6.md); чи повернення до `nil` відновлює системну тему без перезапуску. План Б: додатково
  `.preferredColorScheme` на корені кожної `Window`-сцени.
- **U15** (M7) Чи приймає модель з Settings (`claude-haiku-5-5` за замовчуванням) `max_tokens = 8192` і чи вистачає
  його з adaptive thinking на 15 елементів. Перевірка: M7.md B (у логах нема `max_tokens`/400). План Б: зменшити
  `defaultBatchSize` до 10 (константа), `batchMaxTokens` лишити 8192 або 4096.
- **U16** (M7) `ToolbarItem(placement: .principal)` з `.segmented` `Picker` у `Window`-сцені на macOS 13: чи
  показується по центру toolbar і разом із `.searchable`. План Б: `.navigation` або `.automatic`.
- **U17** (M7) Наявність голосу `it-IT` (`AVSpeechSynthesisVoice(language: "it-IT")` може бути `nil` без завантаженого
  голосу) — як U11; кнопка озвучення лишається, `nil`-голос = системний за замовчуванням.
- **U18** (M7, не macOS API, а якість моделі) Точність `source_language` для коротких слів, що існують в обох мовах,
  і якість італійської IPA. Фіксується в M7.md D.

---

## 14. Тестова інфраструктура

- Ядро (`Tests/VocabCoreTests`): `MockURLProtocol` (статичний обробник під `NSLock`, лічильник запитів, запис
  останніх запитів; тіло — з `httpBody` або `httpBodyStream`), `TestFixtures` (рядки JSON),
  `TemporaryDirectory` (створення/видалення), `FailingFileSystem` (обгортка над `LocalFileSystem` з ін'єкцією збою
  на `replaceItem`/`writeData`/`copyItem`), `StubLookupService` (сценарій результатів), `CapturingLogSink`.
- M7: `StubVariantBatchLookupService` (сценарій відповідей по викликах, лічильник викликів, записані `items`);
  фікстури Messages-конвертів з комбінованою відповіддю (en-джерело, it-джерело, невалідний варіант) і пакетною
  (усі валідні, частково невалідні, обрізана `max_tokens`); фікстура `dictionary.json` формату M6 для байтового
  порівняння. Кількість HTTP-запитів перевіряється лічильником `MockURLProtocol`.
- Застосунок (`App/Tests`): `SpyUserNotifier`, унікальний `NSPasteboard(name: .init("VocabAppTests-\(UUID())"))`
  з `releaseGlobally()` у `tearDown`.
- Жодного реального мережевого запиту в тестах. Жодних `XCTSkip`.

---

## 15. План етапів

Формат: файли → критерії приймання (КП) → тести (файл: імена) → ручний чекліст.

### M1 — Каркас і зберігання

**Файли:** `Package.swift`, `project.yml`, `App/Info.plist` (вже з `LSUIElement`, без `NSServices`),
`Models/*`, `Languages/*`, `Text/TextNormalizer.swift`, `Support/*`, `Storage/*`, `Repository/DictionaryRepository.swift`,
`Repository/RepositoryError.swift`, `Security/RedactingLogger.swift` (база); App: `VocabApp.swift`, `AppDelegate.swift`,
`AppModel.swift`, `AppEnvironment.swift`, `Views/DictionaryWindowView.swift`, `EntryRowView.swift`,
`EntryEditorView.swift`, `AddEntryView.swift`, `MenuBarContentView.swift` (мінімальний: «Відкрити словник», «Вийти»),
`App/Tests/AppModelTests.swift`, `docs/manual-tests/M1.md`.

| КП | Перевірка |
|---|---|
| M1.1 `swift build`/`swift test` на Linux і macOS; `xcodegen generate && xcodebuild build/test` у CI | CI jobs `linux-core`, `macos-app` (включає `swift test` на macOS) |
| M1.2 Серіалізація/десеріалізація за схемою | `EntryCodingTests`: `testRoundTrip`, `testEncodedKeysMatchSchema`, `testDecodesRequirementsExample`, `testDecodesFractionalSecondDates`, `testOptionalFieldsOmittedWhenNil`, `testUnknownStatusFailsDecoding`, `testDatesEncodedAsISO8601UTC` |
| M1.3 Атомарний запис | `FileDictionaryStoreTests`: `testLoadMissingFileReturnsEmpty`, `testSaveThenLoad`, `testSaveCreatesDirectory`, `testSaveLeavesNoTemporaryFiles`, `testFailedReplaceKeepsOriginalAndRemovesTemp`, `testSaveUpdatesExportedAt`, `testCorruptedFileMovedToBackups`, `testNewerSchemaVersionThrowsAndKeepsFile` |
| M1.4 Нормалізація | `TextNormalizerTests`: `testTrims`, `testLowercasesKey`, `testCollapsesWhitespace`, `testStripsSurroundingPunctuation`, `testKeepsInnerApostropheAndHyphen`, `testNormalizesCurlyApostrophe` |
| M1.5 Дублікати в межах пари | `DictionaryRepositoryTests`: `testAddPersists`, `testDuplicateSamePairRejected` (`"Run "` vs `"run"`), `testSameWordOtherPairAllowed`, `testUpdateSetsUpdatedAt`, `testUpdateToDuplicateRejected`, `testDeleteRemoves`, `testChangesStreamEmits`, `testFailedSaveDoesNotChangeState` |
| M1.6 Розширюваність пар | `LanguagePairRegistryTests`: `testEnUkRegisteredByDefault`, `testRegisterItUkWithoutCoreChanges`, `testUnknownPairReturnsNil` |
| M1.7 Головне вікно: список, ручне додавання/редагування/видалення | `AppModelTests`: `testManualAddAppears`, `testEditUpdatesEntry`, `testDeleteRemovesEntry`, `testDuplicateManualAddShowsError` (тимчасовий каталог) + ручний `M1.md` |

`M1.md`: запуск зібраного `.app`, іконка в menu bar, відкриття вікна, додати/редагувати/видалити, перезапуск —
дані збережено, `dictionary.json` відповідає схемі (перевірити `cat`), дубль показує помилку.

### M2 — Claude API, Keychain, Settings, черга

**Файли:** `Claude/*`, `Processing/*`, `Security/SecretStore.swift`, `InMemorySecretStore.swift`, `RedactingLogger.swift`
(повний), `Settings/SettingsStore.swift`, `UseCases/AddWordUseCase.swift`, `Text/SelectionValidator.swift`;
App: `Platform/KeychainSecretStore.swift`, `OSLogSink.swift`, `NetworkMonitor.swift`, `Views/SettingsView.swift`
(ключ — `SecureField`, показ лише «Ключ збережено»; модель; кнопка «Перевірити» не обов'язкова),
статус-бейджі `pending/failed` і «Повторити» в `EntryRowView`, «Заповнити через Claude» в `AddEntryView`;
`App/Tests/KeychainSecretStoreTests.swift`; `docs/manual-tests/M2.md`.

| КП | Перевірка |
|---|---|
| M2.1 Коректний запит (endpoint, заголовки, тіло, модель з Settings) | `ClaudeRequestBuilderTests`: `testURLMethodAndHeaders`, `testBodyContainsModelMaxTokensSystemMessages`, `testBodyContainsOnlyMinimalKeys` (множина ключів рівно `{model, max_tokens, system, messages}`; немає `temperature`/`top_p`/`thinking`/`output_config`), `testMaxTokensIs4096`, `testTimeoutInterval` |
| M2.2 Промт залежить від пари, фрази → phrase | `PromptBuilderTests`: `testWordPromptContainsSchemaAndText`, `testPhrasePromptRequiresPhrase`, `testSelectionWrappedInTextTags`, `testCustomPairTemplateUsed` |
| M2.3 Парсинг валідних/невалідних відповідей | `LookupResponseParserTests`: `testParsesValid`, `testParsesInsideCodeFence`, `testIgnoresThinkingBlocks`, `testMissingTranslationsInvalid`, `testEmptyTranslationsInvalid`, `testNonJSONInvalid`, `testMissingExampleInvalid`, `testPhraseForcesPhrasePOS`, `testExtraKeysIgnored`, `testMaxTokensStopReasonWithTruncatedJSONInvalid`, `testMaxTokensStopReasonWithCompleteJSONAccepted`, `testRefusalStopReason` |
| M2.4 Один повтор при невалідному JSON | `ClaudeLookupServiceTests`: `testInvalidJSONRetriedOnceThenSucceeds` (2 запити), `testInvalidJSONTwiceFails` (рівно 2), `testMaxTokensTruncationRetriedOnceThenFails` (рівно 2), `testHTTPErrorsNotRetried` (1 запит) |
| M2.5 HTTP-помилки через мок `URLProtocol` | `ClaudeLookupServiceTests`: `test401Unauthorized`, `test403Forbidden`, `test429RateLimitedWithRetryAfter`, `test500Server`, `test529Overloaded`, `test400BadRequestMessageExtracted`, `testTimeout`, `testOffline`, `testMissingKeyNoRequest` |
| M2.6 Ключ ніколи не в логах / JSON | `RedactingLoggerTests`: `testRedactsKnownSecret`, `testRedactsSkAntPattern`, `testLookupFlowNeverLogsKey` (успіх, 401, 500, offline), `testDictionaryFileNeverContainsKey` |
| M2.7 Черга pending | `ErrorDispositionTests`: `testDispositionTable`; `RetryPolicyTests`: `testExponentialDelays`, `testCappedAt15Minutes`, `testRetryAfterHonored`; `PendingQueueProcessorTests`: `testPendingBecomesReady`, `testOfflineStaysPendingWithoutAttempt`, `testUnauthorizedBecomesFailed`, `testServerErrorFailsAfterFiveAttempts`, `testBackoffSkipsNotDueEntries`, `testManualRetryOfFailed`, `testRetryOfInFlightEntryIsSkipped`, `testConcurrentProcessAllDoesNotDoubleProcess`, `testWordReplacedByModelWordWhenKeysMatch` |
| M2.8 Налаштування | `SettingsStoreTests`: `testDefaultModelIsHaiku55`, `testPersistsModel`, `testEmptyModelFallsBackToDefault`; `InMemorySecretStoreTests`: `testWriteReadDelete` |
| M2.9 Keychain (macOS) | `KeychainSecretStoreTests`: `testWriteReadDelete`, `testOverwrite`, `testReadMissingReturnsNil` (унікальний `service = "com.vocabapp.tests.<UUID>"` на кожен прогін, `deleteSecret` у `tearDown`) |

`M2.md`: ввести реальний ключ, додати слово через «Заповнити через Claude», вимкнути Wi-Fi → `pending`, увімкнути →
стає `ready` автоматично; невірний ключ → `failed` + «Повторити»; Console.app — ключа немає в логах;
`security find-generic-password -s com.vocabapp.VocabApp` — ключ є лише там; `grep sk-ant dictionary.json` — порожньо.

### M3 — Services

**Файли:** `UseCases/ServiceRequestHandler.swift`, `UseCases/NotificationText.swift`; App:
`Platform/ServicesProvider.swift`, `Platform/NotificationService.swift`, `NSServices` в `App/Info.plist`,
реєстрація в `AppDelegate`; `App/Tests/ServicesProviderTests.swift`, `App/Tests/InfoPlistServicesTests.swift`;
`docs/manual-tests/M3.md`.

| КП | Перевірка |
|---|---|
| M3.1 Валідація виділення, слово/фраза | `SelectionValidatorTests`: `testEmptyRejected`, `testWhitespaceOnlyRejected`, `testTooLongRejected`, `testTooManyWordsRejected`, `testNoLettersRejected`, `testSingleWordIsWord`, `testHyphenatedIsWord`, `testMultiWordIsPhrase`, `testMultilineCollapsed`, `testTrailingPunctuationStripped` |
| M3.2 Use-case: додавання, дубль, офлайн, помилка | `ServiceRequestHandlerTests`: `testNewWordAddedReady`, `testDuplicateNoLookupCall`, `testDuplicateOfPendingReported`, `testOfflineQueued`, `testMissingKeyQueued`, `testUnauthorizedFailed`, `testRejectedCreatesNoEntry`, `testConcurrentSameWordAddedOnce`, `testAddDuringProcessAllReportsOutcome` (stub lookup блокується; паралельний `processAll` підхоплює запис → outcome `.added(entry)`, якщо на момент `.skipped` запис уже `ready`, інакше `.queued(entry, nil)`; рівно 1 lookup, без дубля запису) |
| M3.3 Тексти сповіщень | `NotificationTextTests`: `testAdded`, `testAddedLimitsToThreeTranslations`, `testDuplicate`, `testQueuedOffline`, `testQueuedMissingKey`, `testQueuedInFlight` («Обробляється: run»), `testFailed`, `testRejectedVariants` |
| M3.4 Обробник Services з тестовим pasteboard | `ServicesProviderTests`: `testReadsPublicUTF8PlainText`, `testReadsLegacyStringType`, `testEmptyPasteboardSetsError`, `testPostsNotificationFromOutcome` |
| M3.5 Info.plist і селектор | `InfoPlistServicesTests`: `testNSServicesEntry` (NSMessage, NSPortName, обидва NSSendTypes, NSMenuItem.default, NSRequiredContext), `testProviderRespondsToServiceSelector`, `testLSUIElementTrue` |
| M3.6 Пункт «Додати в словник» у Safari, Chrome, TextEdit; сповіщення | ⏳ manual `M3.md` |

`M3.md`: копіювати `VocabApp.app` у `/Applications`; перший запуск (дозвіл сповіщень); `/System/Library/CoreServices/pbs -update`
(за потреби — перелогін); увімкнути сервіс у System Settings → Keyboard → Keyboard Shortcuts → Services → Text;
перевірити Safari, Chrome, TextEdit (+ PDF у Preview, Notes): слово, фраза, дубль, офлайн, понад 120 символів;
виклик сервісу, коли застосунок не запущений; результати записати по кожній програмі з версією macOS.

### M4 — Експорт / імпорт

**Файли:** `Transfer/*`, `Storage/BackupManager.swift` (ротація); App: `Platform/FilePanels.swift`,
`Views/ImportModeDialog.swift`, розділ «Перенесення» у `SettingsView`, алерт зі звітом;
`App/Tests/AppModelTransferTests.swift`; `docs/manual-tests/M4.md`.

| КП | Перевірка |
|---|---|
| M4.1 Валідація: порожній, не JSON, інший schemaVersion, відсутні поля | `DictionaryImporterTests`: `testValidFileParsed`, `testEmptyFileRejected`, `testWhitespaceFileRejected`, `testNotJSONRejected`, `testArrayTopLevelRejected`, `testMissingSchemaVersionRejected`, `testSchemaVersion2Rejected`, `testSchemaVersion0Rejected`, `testEntriesNotArrayRejected`, `testEntryMissingWordSkipped`, `testInvalidUUIDSkipped`, `testReadyWithoutTranslationsSkipped`, `testErrorMessagesUkrainian` |
| M4.2 Merge з конфліктами за `updatedAt` | `ImportMergerTests`: `testNewEntriesAdded`, `testSameIdNewerWins`, `testSameIdOlderSkipped`, `testSameIdEqualKeepsLocal`, `testSameNormalizedWordNewerWinsKeepsLocalId`, `testOtherPairIsNotConflict`, `testImportedPendingDoesNotOverwriteReady`, `testDuplicatesInsideFileCollapsed`, `testReportCounts` |
| M4.3 Replace з бекапом | `DictionaryTransferServiceTests`: `testReplaceCreatesBackupThenReplaces`, `testBackupFileNaming`, `testBackupRetentionKeepsTen`, `testBackupFailureLeavesDictionaryUntouched`, `testInvalidFileLeavesDictionaryUntouched` (обидва режими), `testMergePersistsAtomically` |
| M4.4 Експорт | `DictionaryExporterTests`: `testExportSetsExportedAt`, `testExportImportRoundTrip`, `testExportWritesAtomically` |
| M4.5 Звіт | `ImportReportTests`: `testSummaryText` («Додано 2, оновлено 1, пропущено 3») |
| M4.6 UI-інтеграція | `AppModelTransferTests`: `testImportMergeUpdatesEntriesAndReport`, `testImportInvalidSetsError` + ⏳ `M4.md` |

`M4.md`: експорт через NSSavePanel; імпорт merge і replace (діалог підтвердження, файл у `Backups/`); імпорт
порожнього/битого файлу — зрозуміла помилка, словник не змінився; перенесення на інший Mac (або інший
користувач): експорт → імпорт → кількість записів збігається.

### M5 — Полірування

**Файли:** `Repository/EntryQuery.swift`; App: `Platform/LoginItemService.swift`, `Platform/SpeechService.swift`,
повний `MenuBarContentView` (лічильник pending, «Повторити очікувані»), пошук (`.searchable`) і сортування
(`Picker`) у `DictionaryWindowView`, кнопка озвучення в `EntryRowView`, тумблер автозапуску в `SettingsView`;
`App/Tests/SpeechServiceTests.swift`, `App/Tests/LoginItemServiceTests.swift`; `README.md`; `docs/manual-tests/M5.md`.

| КП | Перевірка |
|---|---|
| M5.1 Пошук за словом і перекладом | `EntryQueryTests`: `testSearchByWord`, `testSearchByTranslation`, `testSearchCaseAndDiacriticInsensitive`, `testEmptySearchReturnsAll` |
| M5.2 Сортування дата/алфавіт | `EntryQueryTests`: `testSortNewestFirst`, `testSortOldestFirst`, `testSortAlphabeticalByKey` |
| M5.3 Озвучення англійським голосом | `SpeechServiceTests`: `testUtteranceUsesPairSpeechLanguage` (перевіряє запитаний код мови й `speechString`, без відтворення; голос може бути `nil` — U11) + ⏳ manual |
| M5.4 Автозапуск | `LoginItemServiceTests`: `testStatusMapping` (мапінг `SMAppService.Status` → `LoginItemState` через чисту функцію, без реєстрації) + ⏳ manual |
| M5.5 Menu bar | ⏳ manual |
| M5.6 README: збірка, встановлення, активація Services, перенесення словника | Judge перевіряє наявність розділів у `README.md` |

`M5.md`: при запуску на macOS 13 (і 14/15) **жодне вікно не відкривається** — лише іконка в menu bar (U12); меню в menu bar (усі пункти); автозапуск увімкнути → перелогін → застосунок запущено; статус
`requiresApproval` веде в Login Items; озвучення слова й фрази; пошук «біг» знаходить `run`; сортування;
README-інструкції відтворювані на чистому користувачі.


### M6 — Фідбек з ручного тестування

Джерело: `docs/reports/2026-10-14-mac-test-report.md` (§6 P1–P5, §7 UX-побажання). Модель даних і формат файлу не змінюються.

**Файли.** Ядро: `Repository/Pagination.swift` (§6), `Settings/AppAppearance.swift` + нові поля в `Settings/SettingsStore.swift` (§7.6),
`Processing/ProcessingTrigger.swift` (§8.3). App: `Views/EntryTableView.swift` (новий; `EntryRowView.swift` видалити — XcodeGen збирає джерела з каталогу `App/Sources`, тож після `xcodegen generate` файл зникає з проєкту автоматично, правити `project.yml` не треба),
`Views/PaginationBar.swift`, `Views/DictionaryWindowView.swift`, `Views/SettingsView.swift`, `Platform/AppearanceController.swift`,
`AppModel.swift`, `AppDelegate.swift` (тема на старті, логер `notifications`, тригери). Документи: `README.md`,
`docs/manual-tests/M3.md`, `docs/manual-tests/M6.md`. Тести: `Tests/VocabCoreTests/PaginationTests.swift`,
`ProcessingTriggerTests.swift`, доповнення `SettingsStoreTests.swift`; `App/Tests/AppModelM6Tests.swift`,
`App/Tests/AppearanceControllerTests.swift` (`SpyAppearanceApplier` — у файлі тестів M6).

| КП | Перевірка |
|---|---|
| M6.1 Таблиця: колонки Слово / Транскрипція / Переклад / Приклад + статус/дії; контекстне меню й подвійний клік | ⏳ manual (M6.md A) + збірка CI |
| M6.2 Пагінація (чиста логіка) | `PaginationTests`: `testDefaultPageSizeIs25`, `testInvalidPageSizeFallsBackToDefault`, `testPageCountRoundsUp`, `testEmptyListHasOnePage`, `testFirstPageSlice`, `testLastPartialPage`, `testClampBelowOneAndAboveLast`, `testPageClampsRequestedNumber`, `testHasPreviousAndHasNext`, `testLabelText` |
| M6.3 Стан сторінки в `AppModel` | `AppModelM6Tests`: `testCurrentPageUsesPageSize`, `testNextAndPreviousPage`, `testSearchChangeResetsPageToOne`, `testSortChangeResetsPageToOne`, `testPageSizeChangeResetsPageAndPersists`, `testDeleteOnLastPageClampsPage`, `testRepositoryChangeClampsPage` (зміна з `repository.changes()`, не через `delete`), `testSetPageSizeIgnoresUnsupportedValue` (напр. 50 → лишається поточний, нічого не зберігається), `testSearchAppliesToWholeDictionaryNotPage`, `testAppModelUsesSameSettingsStoreAsClaude` (без явного `settings:` зміна теми/розміру видна в `claude.settings`) |
| M6.4 Тема: default, збереження, застосування | `SettingsStoreTests`: `testAppearanceDefaultsToSystem`, `testAppearancePersistsInUserDefaults`, `testUnknownAppearanceFallsBackToSystem`, `testPageSizeDefaultAndPersist`, `testInvalidPageSizeFallsBackToDefault`, `testInMemoryStoreAppearanceAndPageSize`; `AppModelM6Tests`: `testAppearanceLoadedFromSettings`, `testSetAppearancePersistsAndApplies` (spy); `AppearanceControllerTests`: `testApplySetsNSAppAppearance` (light → `.aqua`, dark → `.darkAqua`, system → `nil`; `tearDown` повертає `nil`) + ⏳ manual (U14) |
| M6.5 Тригер повтору в логах без секретів (P5) | `ProcessingTriggerTests`: `testStartedMessageContainsTrigger`, `testFinishedMessageCountsResults`, `testMessagesContainNoWordOrErrorText`; `AppModelM6Tests`: `testRetryLogsManualTrigger`, `testRetryAllLogsRetryAllTrigger` (лог через `RecordingLogSink` з `App/Tests/APIKeyCacheTests.swift`) |
| M6.6 Окрема log category `notifications` (P4) | Рев'ю коду `AppDelegate` + ⏳ manual: `log show --predicate 'subsystem == "com.vocabapp.VocabApp" AND category == "notifications"'` |
| M6.7 Документація (P1–P3) | Judge: README — кількість тестів застосунку з поясненням, як її отримано (`xcodebuild test` → рядок `Executed N tests`; або `grep -rh "func test" App/Tests \| wc -l`), M5 = 69; **Developer після M6 оновлює число в README** на фактичне `Executed N tests` з CI/Mac; примітка: `swift test` на macOS потребує повного Xcode.app (`xcode-select -p` → `/Applications/Xcode.app/...`), з Command Line Tools XCTest недоступний; README і `M3.md`: шукати сервіс через `pbs -dump \| grep -A8 VocabApp` — кирилиця в дампі екранована (`\U0414…`), тож `grep "Додати в словник"` нічого не знаходить |

`M6.md` (реальний Mac, записати `sw_vers`): **A. Таблиця** — 4 колонки + статус, ширина колонок змінюється, довгий
переклад обрізано з підказкою, бейджі pending/failed, «Повторити», озвучення, контекстне меню, подвійний клік → редактор,
видалення. **B. Пагінація** — ≥ 60 записів (імпорт тестового файлу): 25 на сторінці, «Сторінка 1 з 3», крайні кнопки
вимкнено; пошук/сортування → сторінка 1; видалити єдиний запис останньої сторінки → перехід на попередню;
20/30 у Settings діють одразу й зберігаються після перезапуску. **C. Тема** — Світла/Темна/Як у системі при відкритих
вікнах «Словник» і «Налаштування» (перемальовуються без перезапуску), sheet редактора, панелі імпорту/експорту, меню
в menu bar (записати фактичну поведінку — U14); тема зберігається після перезапуску; «Як у системі» слідує зміні
системної теми. **D. Логи** — «Повторити» → `trigger=manual`, «Повторити очікувані» → `trigger=retryAll`, вимкнути/
увімкнути Wi-Fi → `trigger=network`; у логах немає ключа; сповіщення — у category `notifications`. VoiceOver не перевіряється.

### M7 — Перемикач EN | IT, автовизначення мови, економія токенів

Джерело: запит користувача 2026-10-14 («переключалка на італійську вгорі…; 2 переклади зберігались у файл, а не
кожного разу запит») + уточнення (виділене слово може бути англійським або італійським; дублікати — в обох мовах;
доповнення старих записів — один раз, пакетами). Дизайн: §3.2, §6 (M7), §7.7, §8.3 (M7), §8.4, §9 (M7), §10 (M7), §11 (M7), D21–D30.

**Файли.** Ядро: нові `Models/EntryVariant.swift`, `Languages/RenderingLanguage.swift`, `Languages/Italian.swift`,
`Repository/EntryDisplay.swift`, `Claude/VariantBatchLookup.swift`, `Claude/VariantPromptBuilder.swift`,
`Claude/VariantBatchResponseParser.swift`, `Processing/VariantBackfillProcessor.swift`, `Transfer/VariantMerge.swift`;
змінені `Models/Entry.swift` (`variants`, `sourceLanguage`, стійкий `init(from:)`, `dedupKeys`, `variantState`),
`Languages/LanguagePair.swift`, `Languages/EnglishUkrainian.swift` (`renderings: [.italian]`, промт), `Claude/PromptBuilder.swift`,
`Claude/LookupResponseParser.swift`, `Claude/ClaudeLookupService.swift`, `Claude/ClaudeConfiguration.swift` (`batchMaxTokens`),
`Repository/DictionaryRepository.swift`, `Repository/EntryQuery.swift`, `Processing/EntryProcessor.swift`,
`Processing/ProcessingTrigger.swift`, `UseCases/AddWordUseCase.swift`, `UseCases/NotificationText.swift`,
`Transfer/DictionaryImporter.swift`, `Transfer/ImportMerger.swift`, `Settings/SettingsStore.swift`.
App: `AppModel.swift`, `AppDelegate.swift` (створення `VariantBackfillProcessor` з тим самим `ClaudeLookupService`),
`Views/DictionaryWindowView.swift`, `Views/EntryTableView.swift`, `Views/EntryEditorView.swift`.
Тести ядра (`Tests/VocabCoreTests/`): `EntryVariantCodingTests.swift`, `CombinedLookupParserTests.swift`,
`VariantBatchParserTests.swift`, `VariantPromptBuilderTests.swift`, `TokenEconomyTests.swift`,
`VariantBackfillProcessorTests.swift`, `CrossLanguageDedupTests.swift`, `EntryDisplayTests.swift`,
`VariantImportMergeTests.swift`, доповнення `SettingsStoreTests.swift`, `PromptBuilderTests.swift`,
`NotificationTextTests.swift`, `ProcessingTriggerTests.swift`. App: `App/Tests/AppModelM7Tests.swift`.
Документи: `docs/manual-tests/M7.md`, `README.md` (розділ «Італійська»).

Умови для тестів кількості запитів: `ClaudeLookupService` + `MockURLProtocol` (лічильник запитів, §14) — реальний
HTTP-шар, а не стаб; `FixedDateProvider`; тимчасовий каталог.

| КП | Перевірка |
|---|---|
| M7.1 Сумісність формату: старий файл читається, без варіантів пише байт-у-байт як M6; `schemaVersion` = 1 | `EntryVariantCodingTests`: `testM6FileDecodesWithoutVariants`, `testEntryWithoutVariantsEncodesIdenticallyToM6` (порівняння байтів з фікстурою M6), `testVariantRoundTrip`, `testVariantKeysCamelCase`, `testEmptyVariantsNotEncoded`, `testSourceLanguageOmittedForPrimary`, `testMalformedVariantDroppedEntryKept`, `testUnknownVariantStatusDropped`, `testSchemaVersionStaysOne`, `testStoreLoadWithMalformedVariantIsNotCorrupted` (файл не переміщується в Backups) |
| M7.2 Комбінований промт і розбір (en/it, детекція мови) | `PromptBuilderTests`: `testPairWithoutRenderingsPromptUnchanged`, `testCombinedPromptContainsItalianSchemaAndDetection`, `testCombinedPromptPlaceholdersFilled`; `CombinedLookupParserTests`: `testEnglishSourceWithItalianVariant`, `testItalianSourceDetected`, `testMissingSourceLanguageInferredFromKeys`, `testUnknownSourceLanguageFallsBackToPrimary`, `testInvalidVariantDroppedWhenSourceIsEnglish`, `testInvalidVariantInvalidatesResponseWhenSourceIsItalian`, `testPhraseForcesPhraseInVariant`, `testUnknownVariantIdsIgnored`, `testOldShapeStillParses` |
| M7.3 Рівно 1 запит на нове слово; обидві мови збережено | `TokenEconomyTests`: `testNewEnglishWordOneRequestBothRenderings` (через `AddWordUseCase`; 1 запит; `variants["it"].status == .ready`; дані у файлі після перезавантаження стору), `testNewItalianWordOneRequestStoresSourceLanguage` («casa» → `word = "house"`, `variants.it.word = "casa"`, `sourceLanguage = "it"`), `testInvalidVariantNotRetriedMarkedPending` (1 запит, варіант `pending`), `testMaxTokensForSingleLookupStays4096` |
| M7.4 Дедуплікація в обох мовах | `CrossLanguageDedupTests`: `testItalianSelectionMatchesExistingItalianVariant` (0 запитів, `.duplicate`), `testEnglishSelectionMatchesExisting`, `testPendingVariantNotUsedForDedup`, `testStaleVariantNotUsedForDedup`, `testPostResponseDuplicateRemovesPendingAndReturnsExisting` (`ProcessingResult.duplicate`), `testPostResponseDuplicateFillsMissingVariantOfExisting` (0 додаткових запитів), `testConcurrentSameItalianWordAddedOnce` |
| M7.5 Пакетний промт і розбір з частково невалідними елементами | `VariantPromptBuilderTests`: `testItemsEncodedCompactWithRefs`, `testItemsWrappedInTags`, `testMeaningLimitedToThree`; `VariantBatchParserTests`: `testAllValid`, `testPartialInvalidKeepsValid`, `testMissingIdsReportedMissing`, `testUnknownIdsIgnored`, `testDuplicateIdFirstWins`, `testStringNumericIdAccepted`, `testNotArrayInvalid`, `testCodeFenceStripped` |
| M7.6 Пакетне доповнення: `ceil(n/15)` запитів, 0 для кешованих, часткові успіхи збережено | `VariantBackfillProcessorTests`: `testBackfill37EntriesMakesThreeRequests`, `testBackfillPersistsAfterEachBatch` (2-й пакет падає 500 → результати 1-го у файлі), `testSecondBackfillMakesZeroRequests`, `testReadyVariantsNeverRequested`, `testStaleVariantReRequested`, `testNonReadyEntriesSkipped`, `testOfflineStopsRunAfterOneRequestNoAttemptCounted`, `testUnauthorizedStopsRunVariantsUnchanged`, `testServerErrorMarksPendingWithBackoff`, `testInvalidResponseMarksBatchFailedAndContinues`, `testItemFailsAfterFiveAttempts`, `testFailedOnlyInBackfillAll`, `testRefreshMakesOneRequestOverwritesReady`, `testEntryEditedDuringRequestVariantDiscarded`, `testConcurrentCallReportsAlreadyRunning`, `testBatchUsesMaxTokens8192AndFourBodyKeys`, `testEntryUpdatedAtUnchangedByBackfill`, `testUpdateDoesNotOverwriteStoredVariants` |
| M7.7 Відображення/пошук/сортування в активній мові | `EntryDisplayTests`: `testPrimaryModeShowsEnglish`, `testItalianModeShowsVariant`, `testMissingVariantFallback`, `testStaleVariantFallback`; `EntryQueryTests` (доповнення): `testSearchItalianWordInItalianMode`, `testSearchFallbackRowsByEnglish`, `testAlphabeticalByItalianKey` |
| M7.8 Імпорт/merge з варіантами | `VariantImportMergeTests`: `testImporterDropsInvalidVariantKeepsEntry`, `testImporterDropsReadyVariantWithoutTranslations`, `testMergeAdoptsImportedVariantCountsUpdated`, `testMergeKeepsLocalReadyOverImportedPending`, `testMergeNewerVariantWins`, `testMergeDropsVariantsWithForeignSourceKey`, `testExportImportRoundTripWithVariants`, `testM6ExportImportsUnchanged` |
| M7.9 Налаштування, тригери, тексти | `SettingsStoreTests`: `testDisplayLanguageDefaultsToNil`, `testDisplayLanguagePersists`, `testInMemoryDisplayLanguage`; `ProcessingTriggerTests`: `testVariantMessagesContainNoWords`; `NotificationTextTests`: `testAddedItalianUsesItalianRendering`, `testDuplicateItalian` |
| M7.10 Застосунок: перемикач, збереження режиму, рендер, одноразове доповнення | `AppModelM7Tests` (стаб `VariantBatchLookupService` з лічильником): `testDisplayLanguagePersistsAcrossModelInstances`, `testUnknownStoredLanguageFallsBackToPrimary`, `testSwitchToItalianTriggersBackfillOnce` (перше перемикання — 1 прохід, друге — 0 викликів lookup), `testSwitchToEnglishDoesNotBackfill`, `testStartupInItalianModeBackfills`, `testSwitchResetsPageToOne`, `testDisplayedPageUsesItalianFields`, `testBackfillAllIncludesFailed`, `testRefreshVariantCallsLookupOnce`, `testEditVariantInItalianModeKeepsEntryUpdatedAt` + ⏳ manual |
| M7.11 Документація | Judge: `README.md` розділ «Італійська» (перемикач, автовизначення, коли витрачаються токени: 1 запит/слово, `ceil(n/15)` для доповнення, «Оновити італійський переклад» — лише вручну); `M7.md` |

`M7.md` (реальний Mac, `sw_vers`, реальний ключ): **A. Перемикач** — сегменти EN | IT у toolbar (записати
розміщення — U16); режим зберігається після перезапуску; сторінка → 1. **B. Доповнення** — словник з ≥ 20 en-записів
без італійських даних: перше перемикання на IT → у Console `Variant backfill finished … requests=2`; повторне
перемикання і перезапуск → нових `requests` немає; `dictionary.json` містить `variants.it` (перевірити `cat`/`jq`).
**C. Нові слова через Services** — англійське слово (Safari) і італійське (`casa`, `perché`, `l'acqua`) — у Console рівно
один `Claude request` на слово, в обох режимах таблиці є дані; `sourceLanguage: "it"` у файлі для італійських.
**D. Дублікати** — повторно виділити `casa` і англійське `house` → «Вже є в словнику», запитів 0; неоднозначне `come`
(записати, як визначено). **E. Офлайн** — вимкнути Wi-Fi, перемкнути на IT → рядки «італійська версія очікує», 1 запит
спроби максимум; увімкнути мережу → доповнено. **F. Явне оновлення** — «Оновити італійський переклад» → 1 запит.
**G. Озвучення** — італійське слово голосом `it-IT` (записати наявність голосу — U17). **H. Сумісність** — імпорт
експорту M6 і експорт з варіантами на інший профіль; перевірка `schemaVersion: 1`.

---

## 16. Правила для Developer / Tester

- Developer реалізує лише файли поточного етапу; публічні сигнатури — як тут. Відхилення — у звіті.
- Перевірка ядра на Linux: `docker run --rm -v /home/user/dictionary:/w -w /w swift:6.0-noble swift test`.
- Тести ядра не використовують AppKit/Security; тести застосунку не роблять мережевих запитів і не змінюють
  реальний `~/Library/Application Support/VocabApp` (під тестами — тимчасовий каталог).
- Нові невизначеності щодо macOS API — у `PROGRESS.md`, розділ «Відкриті питання».
