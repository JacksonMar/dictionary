# IOS_ALL — зведена перевірка всіх iOS-етапів (I0–I5) на Mac і iPhone

Користувач відклав перевірку кожного етапу на Mac («роби далі», `PROGRESS.md` → iOS → I0), тож перша справжня
iOS-збірка відбудеться після I5. Цей файл — **один** промпт для Claude Code на Mac і порядок ручних чеклістів.
Деталі кроків — у `I0.md` … `I5.md` (рядки «Результат» заповнювати там). Помилки Xcode/`xcodebuild` — **дослівно**
(перед вставкою замінити Team ID на `<TEAM_ID>`, Apple ID — на `<APPLE_ID>`). **API-ключ ніколи не вставляти.**

## 1. Промпт для Claude Code на Mac (один раз)

```
Ти на Mac користувача (репозиторій VocabApp, гілка з iOS-етапами I0–I5). Нічого не комітити.
Мета: зібрати й протестувати macOS-застосунок (регресія) та iOS-застосунок у симуляторі, повернути вивід дослівно.

0. Передумови: `sw_vers`, `xcodebuild -version`, `xcodegen --version`, `xcrun simctl list devices available | grep iPhone`.
   Якщо симулятора «iPhone 16» немає — підставити наявний iPhone в усі команди нижче.
   Перевірити, що існує Config/Local.xcconfig (gitignored; Team ID і префікс — від користувача, у звіт НЕ вставляти)
   і що `git status --porcelain Config/` його не показує.
   Якщо Config/Local.xcconfig немає — НЕ створювати його й не вигадувати Team ID: спитати користувача
   (Team ID — Xcode → Settings → Accounts → Personal Team; префікс — напр. com.<нік>.vocab). Поки відповіді немає —
   симуляторні кроки 3–5 виконувати з `DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO`, а установку на iPhone відкласти.
1. git pull && xcodegen generate
2. macOS-регресія (ядро змінювалось в I1a, I2a, I3, I4, I5):
   xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
3. iOS-тести в симуляторі:
   xcodebuild test -project VocabApp.xcodeproj -scheme VocabMobile -destination 'platform=iOS Simulator,name=iPhone 16'
   Якщо падає на підписі (iU8) — повторити з: DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO
   (тоді Keychain-тести можуть падати з -34018 errSecMissingEntitlement — це середовище, записати).
4. Збірка всіх iOS-таргетів (застосунок + VocabShare + VocabWidget, метадані App Intents):
   xcodebuild build -project VocabApp.xcodeproj -scheme VocabMobile -destination 'generic/platform=iOS Simulator' 2>&1 \
     | grep -E 'error|warning: .*(Mobile/Sources|Extensions/|VocabCore|appintents|Metadata|AppShortcuts|Localizable)|duplication of library code|not safe for use in application extensions'
5. Метадані й ресурси бандла (як `I4.md` §0):
   APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/VocabApp-*/Build/Products/Debug-iphonesimulator/VocabMobile.app | head -1)
   ls "$APP/Metadata.appintents" "$APP/PlugIns" "$APP/en.lproj" "$APP/uk.lproj"
   plutil -p "$APP/Info.plist" | grep -A4 CFBundleURLTypes
6. Гігієна (тестові фікстури з фейковим ABCDE12345 виключено):
   git grep -nE 'DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' -- . ':!Tests/VocabCoreTests/RepositoryHygiene*' || echo "no team id"
7. Якщо будь-який крок дає помилки компіляції — НЕ виправляти самостійно: повернути всі помилки дослівно
   (файл:рядок:повідомлення), згруповані за файлами, і зупинитися.
   Виняток — відомий запасний план для `Undefined symbols` у VocabMobileTests (розділ 3 нижче): його можна
   застосувати й повідомити, що саме змінено.
Звіт: для кожного кроку — команда, `** TEST SUCCEEDED/FAILED **` / `** BUILD … **`, кількість тестів
(`Executed N tests, with M failures`), усі помилки й попередження дослівно.
```

## 2. Очікувані результати автотестів

| Набір | Очікування |
|---|---|
| Linux (довідково, вже перевірено) | ядро `swift test` — **599** (I6: +3 `InboxIngestorTests`), 0 падінь; мобільний харнес — **131** (106 + 18 `MobileTransferTests` + 7 `ImportCoordinationTests`), 0 падінь |
| macOS `-scheme VocabApp` | `** TEST SUCCEEDED **`, 0 падінь; кількість — записати N; macOS-файли не змінювались, ядро — лише адитивно, тож N має дорівнювати останньому macOS-прогону до iOS-етапів (за PROGRESS: 113 після M9; якщо інше — пояснити різницю) |
| iOS `-scheme VocabMobile` | `** TEST SUCCEEDED **`, 0 падінь; **137** = 111 (до I5) + 18 `MobileTransferTests` + 8 `ImportCoordinationTests` (I6: 7 як у Linux-харнесі + `testLiveCoordinatorCopiesLocalFile` — лише Darwin, справжній `NSFileCoordinator`); 18 `MobileTransferTests` (план — 6: `testExportRoundTripsThroughCoreImporter`, `testExportFileNameAndContentType`, `testImportCopiesSecurityScopedFileBeforeReading`, `testMergeReportShown`, `testReplaceMakesBackup`, `testImportedPendingProcessedOnce`; додатково 12: скасування, помилки файлу, блокування паралельного перенесення, звіт UK/обрізання причин, ready → 0 запитів, недоступність до завантаження). Лише на iOS (не в Linux-харнесі): hosted `AppLaunchTests`, Keychain-тести, `InfoPlistMobileTests` з бандла |

## 3. Відомий запасний план: `Undefined symbols` у `VocabMobileTests`

`VocabMobileTests` **не** лінкує VocabCore (символи — з host-застосунку, `project.yml`, коментар біля тест-таргета) і
компілює файли розширення `ShareTextExtractor.swift`, `ShareInboxWriter.swift` за шляхом. Якщо лінкування тестів
падає з `Undefined symbols for architecture …` для символів `VocabCore` (напр. `InboxStore.enqueue`,
`AppLanguage.init(preferredLanguages:)`, `DictionaryImporter.parse`) — їх викидає dead-strip, бо застосунок їх не
викликає:
- **не** додавати `- package: VocabCore` у залежності `VocabMobileTests` (дві копії стану `L10n` і метаданих типів у
  одному процесі — тести мовчки бачитимуть іншу копію);
- натомість змусити **застосунок** посилатися на символи: напр. у `Mobile/Sources` додати
  `enum TestSymbolAnchors { static let all: [Any] = [ … ] }` з посиланнями на потрібні типи/функції, викликане з
  `AppContainer.makeLive` (або вимкнути `DEAD_CODE_STRIPPING` лише для Debug таргета `VocabMobile`) — і повідомити,
  що змінено. `No such module 'VocabCore'` — інша проблема: тоді див. коментар у `project.yml`.

## 4. Порядок ручних перевірок (симулятор, потім iPhone)

Перший запуск на iPhone — за `README.md` → «iPhone» (Developer Mode, довіра сертифіката, `Config/Local.xcconfig`).
Статуси I0–I4 спершу збирати в симуляторі, далі на пристрої. Розділи «1. Збірка й тести» всіх файлів закриває
промпт вище — їх не повторювати, лише перенести числа.

| Крок | Файл | Що робити | Примітки |
|---|---|---|---|
| 1 | `I0.md` | §0 (передумови P1), §2 D1/D2 (установка, довіра), §5 (ліміти iU2), §6 (підсумок: iU1, iU2, iU3, iU8, iU12) | Спайк-екран I0 («App Group: OK», «Share extension probe files», «Last opened URL») замінено справжнім застосунком: iU1 (App Group) перевіряє `I3.md` §2, iU3 (віджет) — `I4.md` §5. §1 T2 (4 `SpikeTests`) більше не існує |
| 2 | `I1a.md` | §2–§5: список, порожній стан, пошук/сортування, EN \| IT, помилки, мова | |
| 3 | `I1b.md` | §0 лічильник запитів (Console), §2–§7: ключ API, додавання, редагування, режим IT, мова, перезапуск | §8 (macOS-регресія) — разом із кроком 8 цього списку |
| 4 | `I2b.md` | §2–§9: дозволи, голос EN/IT з підтвердженням, тиша, офлайн, озвучення, `vocabapp://voice` | Лише на пристрої (мікрофон) |
| 5 | `I3.md` | §2–§8: «Поділитися» з Safari/Notes/…, банер, авіарежим, мова листа, без App Group | Якщо App Group недоступна — запасний шлях: `I4.md` §7 (ярлик Shortcuts із листа «Поділитися») |
| 6 | `I4.md` | §2–§8: Shortcuts, Siri англійською, кнопка дії, віджет Home/Lock, паралельність із «Поділитися» | Спайк-віджет I0 прибрати перед §5 |
| 7 | `I5.md` | §1 T4–T8 (симулятор), §2–§9: експорт/імпорт, AirDrop через «Файли» → «Поділитися», merge/replace, D1, IT-варіанти, `languageHint`, 7 днів | §8 (7 днів) — через тиждень після першої установки |
| 8 | macOS | Ручна регресія Mac: Services «Add to Dictionary», імпорт/експорт (`M4.md`), режим IT (`M7.md`) | macOS-файли не змінювались — короткий прохід |

## 5. Що повернути оркестратору

- Вивід промпта (розділ 1) дослівно.
- Заповнені таблиці `I0.md` … `I5.md` (або перелік ❌ із точним описом) і підсумок iU1, iU2, iU3, iU5, iU6, iU7, iU8.
- Рішення за Планом Б (`I0.md` §7), якщо App Group / ліміти / віджет не працюють.
