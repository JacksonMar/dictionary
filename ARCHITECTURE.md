# ARCHITECTURE — VocabApp (EN → UK словник для macOS)

Документ визначає структуру, типи, формати, модель помилок, потоки виконання та план етапів M1–M5.
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

---

## 2. Структура репозиторію

```
Package.swift                      # swift-tools-version:5.9, VocabCore + VocabCoreTests
project.yml                        # XcodeGen → VocabApp.xcodeproj (не комітиться, .gitignore)
Sources/VocabCore/
  Models/        Entry.swift, Example.swift, EntryStatus.swift, EntryDraft.swift, DictionaryFile.swift
  Languages/     LanguagePair.swift, LanguagePairRegistry.swift, EnglishUkrainian.swift
  Text/          TextNormalizer.swift, SelectionValidator.swift
  Support/       DateProvider.swift, AppPaths.swift, JSONCoding.swift
  Storage/       FileSystem.swift, FileDictionaryStore.swift, BackupManager.swift,
                 StorageError.swift, LoadResult.swift
  Repository/    DictionaryRepository.swift, RepositoryError.swift, EntryQuery.swift
  Claude/        HTTPTransport.swift, ClaudeConfiguration.swift,
                 ClaudeRequestBuilder.swift, ClaudeAPIClient.swift, ClaudeError.swift,
                 PromptBuilder.swift, LookupResponseParser.swift, ClaudeLookupService.swift
  Processing/    ErrorDisposition.swift, RetryPolicy.swift, EntryProcessor.swift, PendingQueueProcessor.swift
  UseCases/      AddWordUseCase.swift (+ AddWordOutcome), ServiceRequestHandler.swift (+ ServiceResponse),
                 NotificationText.swift (+ NotificationContent)
  Transfer/      DictionaryExporter.swift, DictionaryImporter.swift, ImportMerger.swift,
                 ImportReport.swift, ImportError.swift, DictionaryTransferService.swift
  Security/      SecretStore.swift (+ SecretKey, SecretStoreError), InMemorySecretStore.swift, RedactingLogger.swift
  Settings/      SettingsStore.swift
Tests/VocabCoreTests/              # усі тести ядра (Linux + macOS), Fixtures/*.json як рядкові константи у коді
App/
  Info.plist
  Sources/
    VocabApp.swift                 # @main App: MenuBarExtra + Window("dictionary") + Window("settings")
    AppDelegate.swift              # композиційний корінь, Services, старт черги
    AppModel.swift                 # @MainActor ObservableObject, міст між repository та UI
    AppEnvironment.swift           # isRunningTests, шляхи
    Views/   MenuBarContentView.swift, DictionaryWindowView.swift, EntryRowView.swift,
             EntryEditorView.swift, AddEntryView.swift, SettingsView.swift, ImportModeDialog.swift
    Platform/ ServicesProvider.swift, KeychainSecretStore.swift, UserNotifier.swift (протокол),
             NotificationService.swift (UserNotifier через UNUserNotificationCenter),
             LoginItemService.swift, SpeechService.swift, FilePanels.swift, NetworkMonitor.swift, OSLogSink.swift
  Tests/                           # VocabAppTests (лише macOS)
docs/manual-tests/M1.md … M5.md
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
  `enum EntrySort { case dateNewest, dateOldest, alphabetical }`, `func apply(to: [Entry]) -> [Entry]`.
  Пошук: `range(of:options:[.caseInsensitive, .diacriticInsensitive])` по `word`, `lemma`, кожному `translations`.
  Алфавіт: за `TextNormalizer.key(word)`, тай-брейк за `createdAt`.

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
(ключ `claudeModel`, default `"claude-haiku-5-5"`; порожній рядок → default), `languagePairID` (default `en-uk`).
Автозапуск не зберігається — істина в `SMAppService.mainApp.status`.

---

## 8. Обробка записів і черга pending (Processing)

### 8.1 ErrorDisposition (D6)

| `ClaudeError` | Статус запису | Лічильник спроб | Авто-повтор |
|---|---|---|---|
| `.offline` | `pending` | не збільшується | при відновленні мережі / старті / таймері |
| `.missingAPIKey` | `pending` | не збільшується | після збереження ключа в Settings |
| `.timeout`, `.rateLimited`, `.server` | `pending` | +1 | за `RetryPolicy`; після 5-ї невдалої — `failed` |
| `.transport` | `pending` | +1 | як вище |
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
`.skipped(e)` → `.queued(e, nil)` (запис щойно підхопив паралельний `processAll`); `.notFound` → `.storageError`.
Запис зберігається як `pending` **до** запиту — тож падіння застосунку чи офлайн не губить слово.

Тексти (`NotificationText`):
- `.added` → title «Додано», body «Додано: run — бігти, керувати» (до 3 перекладів через «, »);
- `.duplicate` → «Вже є в словнику», body «run — бігти» (або «run — очікує обробки» для pending/failed);
- `.queued(.offline)` → «Збережено в чергу», body «run: немає мережі, переклад буде додано пізніше»;
  `.queued(.missingAPIKey)` → «…: додайте API-ключ у налаштуваннях»; інші `.queued(_, error)` → «…: повторимо пізніше»;
  `.queued(_, nil)` (skipped) → title «Обробляється», body «Обробляється: run»;
- `.failed` → «Не вдалося додати», body «run: <userMessage>»;
- `.rejected(.empty)` → «Нічого не виділено»; `.tooLong` → «Виділено забагато тексту (макс. 120 символів)»;
  `.tooManyWords` → «… (макс. 8 слів)»; `.noLetters` → «Виділений текст не містить слів».

---

## 10. Імпорт / експорт (Transfer)

```swift
public enum ImportMode: Sendable { case merge, replace }
public struct ImportReport: Equatable, Sendable { added: Int; updated: Int; skipped: Int; skippedReasons: [String]
  var summary: String  // "Додано X, оновлено Y, пропущено Z" }
public enum ImportError: Error, Equatable { case emptyFile, notJSON, missingSchemaVersion,
  unsupportedSchemaVersion(Int), missingEntries, backupFailed(String), storage(String)
  var userMessage: String }   // україномовні тексти
public struct ParsedImport: Equatable, Sendable { entries: [Entry]; skippedReasons: [String] }
public enum DictionaryImporter { static func parse(_ data: Data) throws -> ParsedImport }
public enum ImportMerger { static func merge(local: [Entry], imported: [Entry]) -> (entries: [Entry], report: ImportReport) }
public enum DictionaryExporter { static func exportData(entries: [Entry], now: Date) throws -> Data }
public final class DictionaryTransferService: Sendable {
  init(repository:, store: DictionaryStoring, backups: BackupManager, fileSystem:, dateProvider:)
  func exportDictionary(to url: URL) async throws                   // атомарний запис тим самим механізмом
  func importDictionary(from url: URL, mode: ImportMode) async throws -> ImportReport
}
```

Валідація (`parse`): 0 байтів або лише пробіли → `.emptyFile`; не JSON-об'єкт → `.notJSON`; немає `schemaVersion`
(або не ціле) → `.missingSchemaVersion`; `schemaVersion != 1` → `.unsupportedSchemaVersion(n)`; `entries` відсутній
або не масив → `.missingEntries`. Далі кожен елемент декодується окремо (`JSONSerialization` → `Data` → `Entry`);
запис з відсутнім обов'язковим полем (`id` як UUID, `languagePair`, непорожній `word`, `status` ∈ enum,
`createdAt`, `updatedAt`, `translations` — масив, для `ready` непорожній) → пропускається з причиною
«Запис #N: відсутнє поле word». Помилка рівня файлу → словник не змінюється взагалі.

Merge (D1): дублікати всередині файлу згортаються першими (лишається новіший `updatedAt`, інші — `skipped`).
Для кожного імпортованого: шукаємо локальний **за `id`**, якщо не знайдено — **за (`languagePair`, `key(word)`)**.
- немає збігу → додати (`added`);
- збіг і `imported.updatedAt > local.updatedAt` → замінити вміст імпортованим, **зберігши `id` локального**
  (`updated`); виняток: імпортований `pending/failed` не перезаписує локальний `ready` (`skipped`);
- інакше (старіший або рівний) → `skipped`.
Результат зберігається одним `repository.replaceAll` (один атомарний запис).

Replace: (1) якщо поточний файл існує — `BackupManager.makeBackup(.replaceImport)`; помилка бекапу →
`ImportError.backupFailed`, нічого не змінюється; (2) `repository.replaceAll(parsed.entries)` (усередині файлу
дублі згортаються так само). Звіт: `added = count`, `updated = 0`, `skipped = пропущені`. Підтвердження —
в UI (`ImportModeDialog`: «Замінити словник? Поточний буде збережено в Backups.»).

Експорт: `DictionaryFile(schemaVersion: 1, exportedAt: now, entries)`, ті самі налаштування енкодера. Імпортовані
`pending` записи після імпорту обробляються чергою (`processAll`).

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
- `AppModel: ObservableObject` (`@MainActor`): `@Published entries`, `query`, `loadError`, `lastReport`, `lastServiceMessage: String?` (текст останнього результату Services — показується в меню, якщо сповіщення заборонені), `hasAPIKey`; підписка
  на `repository.changes()` у `Task`; методи `addManual`, `addViaClaude`, `update`, `delete`, `retry`,
  `retryAll`, `export(to:)`, `import(from:mode:)`, `saveAPIKey`, `setModel`.
- `ServicesProvider: NSObject` (`@MainActor`):
  ```swift
  @objc(addToDictionary:userData:error:)
  func addToDictionary(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>)
  ```
  Читає `pboard.string(forType: .string)` (= `public.utf8-plain-text`), при `nil` — пробує
  `NSPasteboard.PasteboardType("NSStringPboardType")`. Порожньо → `error.pointee = "Не вдалося отримати текст"`
  і сповіщення «Нічого не виділено». Інакше одразу повертає керування, а в `Task` викликає
  `ServiceRequestHandler.handle` і `UserNotifier.post(content)`. Залежності (`handler`, `notifier`) — через init.
  Точний бриджинг типу параметра `error` (`NSString?` vs `NSString`) — **перевірити компіляцією в CI** (U3).
- `KeychainSecretStore: SecretStore` — `kSecClassGenericPassword`, `kSecAttrService = "com.vocabapp.VocabApp"`
  (ін'єктується; тести — унікальний), `kSecAttrAccount = SecretKey.rawValue`; `SecItemCopyMatching`/`Add`/`Update`/
  `Delete`; `errSecItemNotFound` → `nil`. `OSStatus` помилки → `SecretStoreError.keychain(status:)` (оголошено в ядрі, `Security/SecretStore.swift`; без значення секрету).
- `UserNotifier` (протокол, `App/Sources/Platform/UserNotifier.swift`: `func requestAuthorization() async -> Bool`, `func post(_ content: NotificationContent) async`) / `NotificationService` — `UNUserNotificationCenter`; якщо дозволу нема —
  логуємо й показуємо останній результат у меню (`AppModel.lastServiceMessage`).
- `LoginItemService` — `SMAppService.mainApp.register()/unregister()/status`; `.requiresApproval` → кнопка
  «Відкрити Login Items» (`SMAppService.openSystemSettingsLoginItems()`).
- `SpeechService` — `AVSpeechSynthesizer`, `AVSpeechUtterance(string:)`, `voice = AVSpeechSynthesisVoice(language: pair.speechLanguageCode)`.
- `FilePanels` — `NSSavePanel` (`nameFieldStringValue = "dictionary.json"`, `allowedContentTypes = [.json]`),
  `NSOpenPanel` (`allowedContentTypes = [.json]`, один файл).
- `NetworkMonitor` — `NWPathMonitor` на власній черзі; при переході в `.satisfied` → `Task { await processor.processAll(ignoringBackoff: true) }`.
- `OSLogSink: LogSink` — `os.Logger(subsystem: "com.vocabapp.VocabApp", category:)`, повідомлення з `privacy: .public`
  (вони вже відредаговані `RedactingLogger`). Ім'я `RedactingLogger` обрано, щоб не конфліктувати з `os.Logger` в app-таргеті.

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
  або `"settings"` (лише при першому запуску, не при відкритті через Services).

---

## 14. Тестова інфраструктура

- Ядро (`Tests/VocabCoreTests`): `MockURLProtocol` (статичний обробник під `NSLock`, лічильник запитів, запис
  останніх запитів; тіло — з `httpBody` або `httpBodyStream`), `TestFixtures` (рядки JSON),
  `TemporaryDirectory` (створення/видалення), `FailingFileSystem` (обгортка над `LocalFileSystem` з ін'єкцією збою
  на `replaceItem`/`writeData`/`copyItem`), `StubLookupService` (сценарій результатів), `CapturingLogSink`.
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
| M1.1 `swift build`/`swift test` на Linux і macOS; `xcodegen generate && xcodebuild build/test` у CI | CI jobs `linux-core`, `macos` |
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
| M3.2 Use-case: додавання, дубль, офлайн, помилка | `ServiceRequestHandlerTests`: `testNewWordAddedReady`, `testDuplicateNoLookupCall`, `testDuplicateOfPendingReported`, `testOfflineQueued`, `testMissingKeyQueued`, `testUnauthorizedFailed`, `testRejectedCreatesNoEntry`, `testConcurrentSameWordAddedOnce`, `testAddDuringProcessAllReportsOutcome` (stub lookup блокується; паралельний `processAll` підхоплює запис → outcome `.queued(entry, nil)` або `.added`, але не дубль запиту; рівно 1 lookup) |
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

---

## 16. Правила для Developer / Tester

- Developer реалізує лише файли поточного етапу; публічні сигнатури — як тут. Відхилення — у звіті.
- Перевірка ядра на Linux: `docker run --rm -v /home/user/dictionary:/w -w /w swift:6.0-noble swift test`.
- Тести ядра не використовують AppKit/Security; тести застосунку не роблять мережевих запитів і не змінюють
  реальний `~/Library/Application Support/VocabApp` (під тестами — тимчасовий каталог).
- Нові невизначеності щодо macOS API — у `PROGRESS.md`, розділ «Відкриті питання».
