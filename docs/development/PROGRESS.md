# PROGRESS

| Етап | Статус | Ітерації | Вердикт Judge |
|------|--------|----------|---------------|
| Bootstrap (агенти, CI) | done | – | – (CI на macos-15 працює) |
| Architecture | done | 2 | PASS (ітерація 2) |
| M1 — Каркас і зберігання | done | 1 | PASS (ітерація 1) |
| M2 — Claude API | done | 1 | PASS (ітерація 1) |
| M3 — Services | done | 1 | PASS (ітерація 1) |
| M4 — Експорт/імпорт | done | 1 | PASS (ітерація 1) |
| M5 — Полірування | done | 2 | PASS (ітерація 2, перевірка на реальному Mac) |
| M6 — Фідбек з ручного тестування | done (⏳ Mac) | 1 | PASS умовний — рев'ю коду + Linux; macOS-збірку/тести підтвердить користувач |
| M7 — Італійська версія (EN \| IT) | done (⏳ Mac) | 1 | PASS умовний — план з ітерації 2; код: Linux 498 тестів, рев'ю; macOS — користувач |
| M8 — IT/QA-контекст перекладів | done | 1 | PASS — лише промпти; Linux 508 тестів; App/ без змін |
| M9 — Інтерфейс EN/UK | done (⏳ Mac) | 1 | PASS умовний — Linux 542 тести; macOS: 113 App-тестів очікується |
| M10 — Підготовка до публікації | done (⏳ Mac) | 1 | FAIL лише через відсутність macOS-збірки; зміст README/LICENSE/гігієна ✅ |
| iOS-план (`IOS_PLAN.md`) | approved | 2 | PASS (ітерація 2) + затвердження користувача |
| I0 — Спайк підпису й можливостей | done (⏳ Mac) | 2 | PASS умовний (ітерація 2) — Linux 552 тести; iOS-збірка й пристрій — користувач (відкладено) |
| I1a — Ядро на iOS + каркас + список | done (⏳ Mac) | 1 | PASS умовний — Linux 552 + 21 мобільний тест у харнесі; iOS-збірка — Mac |
| I1b — CRUD, Claude, Settings/Keychain | done (⏳ Mac) | 1 | PASS умовний — Linux 552 + 41 мобільний тест; iOS-збірка й Keychain — Mac |
| I2a — Підказка мови в ядрі | done | 1 | PASS — Linux 574 тести (+22 LanguageHintTests); macOS-регресія — у Mac-промпт I2b |
| I2b — Голосове введення (UI) | done (⏳ Mac) | 1 | PASS умовний — Linux 576 + 72 мобільні тести; Speech/AVFoundation/SwiftUI — Mac |
| I3 — Share Extension + inbox | done (⏳ Mac) | 1 | PASS умовний — Linux 590 + 86 мобільних; розширення й App Group — Mac |
| I4 — App Intents + віджет | done (⏳ Mac) | 1 | PASS умовний — Linux 596 + 106 мобільних; AppIntents/WidgetKit — Mac |
| I5 — Експорт/імпорт, полірування, README | done (⏳ Mac) | 1 | PASS умовний — Linux 596 + 124 мобільних; iOS 129 очікується на Mac |

## Середовище перевірки

- Розробка ведеться в Linux-контейнері (немає Xcode). Ядро (`VocabCore`, лише Foundation) збирається й тестується локально: Docker-образ `swift:6.0-noble`, `swift test`.
- macOS-збірка й тести (`xcodegen` → `xcodebuild build` → `xcodebuild test`) запускаються в GitHub Actions (`.github/workflows/ci.yml`, раннер `macos-15`). Judge спирається на результат CI.
- Ручні перевірки (Services у Safari/Chrome/TextEdit, сповіщення, автозапуск, озвучення) можливі лише на реальному Mac: див. `docs/development/manual-tests/`.

## Вердикти Judge

### Architecture — ітерація 1: FAIL
- зайвий `output_config.effort` у тілі запиту; `max_tokens` 2048 замало; `Logger` конфліктує з `os.Logger`;
  не визначено `.skipped` → сповіщення; неповна прив'язка типів до файлів; немає плану Б для Keychain на CI;
  не враховано автовідкриття `Window` на macOS 13.

### Architecture — ітерація 2: PASS
- Усі 7 зауважень виправлено. Неблокуючі нотатки (мапінг `.skipped`→`.added` для ready, D17, формат ідентифікаторів вікон) внесено в план.

### M1 — ітерація 1: PASS
- Linux: 71 тест ядра, 0 падінь. macOS CI (run 38423702609): `swift test` ✅, `xcodegen` + `xcodebuild build` ✅, `xcodebuild test` ✅ (8 тестів застосунку).
- Неблокуючі зауваження: гонка check-then-act у `AtomicFileWriter` при першому записі (виправити в M2); CI-кроки з `if: hashFiles` (прибрано); назви CI jobs в ARCHITECTURE.md (виправлено); ручний чекліст `docs/development/manual-tests/M1.md` — ⏳ виконати на Mac.

### M2 — ітерація 1: PASS
- Linux: 178 тестів ядра, 0 падінь. macOS CI (run 38426913778): `xcodebuild build` ✅, `xcodebuild test` ✅ (15 тестів, зокрема Keychain на реальному Keychain раннера).
- Відхилення, прийняті Judge: ручне додавання — форма (`ready`) + окрема кнопка «Заповнити через Claude» (D14); невідома мовна пара → `failed` з «Невідома мовна пара»; відсутня `lemma` → `word`.
- Неблокуючі зауваження (виправити в M3): редагування збереженого ключа в тексті серверної помилки (не лише шаблон `sk-ant-`); `APIKeyCache` замінює старий ключ; `EntryProcessor.store` ковтає помилку запису; немає кнопки «Повторити всі»; помилка запису рахує спробу, але запис ніколи не стає `failed`.
- ⏳ `docs/development/manual-tests/M2.md` — виконати на Mac зі справжнім ключем.

### M3 — ітерація 1: PASS
- Tester виявив гонку подвійної обробки запису (`processAll` vs `retry`) → Developer виправив (атомарні check+insert у `processOne`) до рев'ю Judge.
- Linux: 223 тести, 0 падінь (QueueConcurrencyTests стабільний у 8 прогонах). macOS CI (run 38430377167): `xcodebuild build` ✅, `xcodebuild test` ✅ (33 тести, зокрема ServicesProviderTests 9, InfoPlistServicesTests 4), `swift test` на macOS ✅.
- U3 (бриджинг сигнатури Services-методу) закрито: селектор компілюється, `responds(to:)` = true.
- Неблокуючі зауваження (на M5): дубльований запит дозволу на сповіщення; `NotificationService` без анотацій конкурентності; текст «Services недоступні» поза §9; помилка запису показується як «Помилка мережі»; якщо холодний старт через Services не спрацює (U5) — реєструвати провайдер у `applicationWillFinishLaunching`.
- ⏳ `docs/development/manual-tests/M3.md` — перевірка в Safari/Chrome/TextEdit на реальному Mac.

### M4 — ітерація 1: PASS
- Linux: 317 тестів, 0 падінь. macOS CI (run 38434434649): `xcodebuild build` ✅, `xcodebuild test` ✅ (50 тестів, зокрема AppModelTransferTests 17), `swift test` на macOS ✅.
- Неблокуючі зауваження (на M5): «..» і англомовна системна причина в `readFailed`/`storage`; імпортоване слово не очищається; ready-запис з `[""]` приймається; кількість записів у повідомленні експорту з окремого знімка; синхронізувати §10 ARCHITECTURE з новими API.
- ⏳ `docs/development/manual-tests/M4.md` — перевірка панелей на Mac.

### M5 — ітерація 1: FAIL (інфраструктура, не код)
- Linux: 354 тести, 0 падінь. Увесь виробничий код M5 зібрано й протестовано на macOS у run 38436944130 (коміт df958a1): `xcodebuild build` ✅, `xcodebuild test` ✅.
- Коміт 91a651c додав лише тести (19 нових тестів застосунку: AppModelM5Tests 13, LoginItemServiceTests 1, SpeechServiceTests 5). Run 38468460084 не отримав жодного раннера (runner_id 0, жодного кроку, навіть для Linux-job); повторний запуск через інтеграцію → 403. Найімовірніше, вичерпано ліміт хвилин / spending limit GitHub Actions (macOS-хвилини рахуються з множником).
- Judge: блокуючих дефектів у коді немає; усі відкладені зауваження M2–M4 виправлено; README повний. Для PASS потрібен зелений macOS CI з новими тестами.
- Що зробити: відновити GitHub Actions (Settings → Billing / spending limit) і перезапустити CI (Actions → CI → Re-run) або локально на Mac: `xcodegen generate && xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`.
- ⏳ `docs/development/manual-tests/M5.md` — menu bar, автозапуск, озвучення на реальному Mac.
- 2026-10-14: користувач відновив ліміт, але перезапуск через інтеграцію заборонений (403 на rerun і workflow_dispatch). Рішення користувача: чекати оновлення ліміту. CI оптимізовано для економії macOS-хвилин: `macos-core` злито в `macos-app` (один macOS-раннер), зміни лише в `*.md`/`docs/`/`.claude/` не запускають CI, `concurrency` скасовує застарілі прогони.

### M5 — ітерація 2: PASS
- Користувач прогнав усе на реальному Mac (macOS 27.0.1, Apple M1, Xcode 27.0).
  `xcodebuild test`: 69 тестів, 0 падінь; `swift test`: 354, 0 падінь; Release-збірка без попереджень.
- Ручно підтверджено: без вікон при запуску, menu bar, Keychain, 401 → failed → «Повторити» → ready, ключа немає у файлі/логах, Services у Safari (додавання + дубль), сповіщення, автозапуск з /Applications.
- Невизначеності на macOS 27: U1–U4 ✅, U7 ✅, U8 (з /Applications без requiresApproval) ✅, U10 ✅, U12 ✅. Не перевірено: U5 (холодний запуск через Services), U6 (Chrome не підтверджено логами, PDF), U9 після перезбірки, U11 вручну, U13.
- P5 (два 401 за 1,2 с) — не дефект: два послідовні тригери користувача («Повторити» + «Повторити очікувані»); подвійна паралельна обробка неможлива.
- Неблокуючі зауваження → етап M6: кількість тестів у README (71 → 69), примітка про повний Xcode для `swift test`, пошук сервісу через `grep VocabApp`, окрема log category для сповіщень, тригер повтору в логах.

### M6 — ітерація 1: PASS (умовний)
- Linux: 374 тести, 0 падінь. GitHub Actions без раннерів (ліміт) — macOS-збірка й 17 нових тестів застосунку не запускались; Judge перевірив код проти API macOS 13, ризиків компіляції, що блокують, не знайшов.
- Очікувано на Mac: `Executed 86 tests, with 0 failures`. Якщо збірка/тести впадуть — вердикт переглядається.
- Дрібне: `EntryTableView.swift:107` явно `Color.secondary : Color.primary` (виправити в M7); виділення не скидається при пошуку на сторінці 1.
- Рішення оркестратора: не блокувати M7 очікуванням Mac — перевірка M6 і M7 на Mac одним промптом наприкінці M7.

### M7 — PASS (умовний)
- План: ітерація 1 FAIL (дедуплікація в update, повтор обрізаного пакета, неповний список файлів) → ітерація 2 PASS.
- Код: Linux 498 тестів, 0 падінь. Токен-економія підтверджена тестами з лічильником HTTP-запитів: 1 запит на нове слово (EN або IT, автовизначення), повтор слова іншою мовою — 0 запитів, доповнення 37 записів — 3 запити, повторно — 0, обрізаний пакет ділиться навпіл.
- Після рев'ю виправлено: мова сповіщення про дубль іде за виділенням («casa — дім»), екранування `</items>` у пакетному промпті, парсер пакета спершу пробує весь текст як масив.
- ⏳ На Mac: `Executed 97 tests, with 0 failures`; чеклісти M6.md і M7.md; U14–U18.
- 2026-10-14, Mac (macOS 27.0.1, Xcode 27.0): BUILD FAILED на b16b839 — `AppModel.swift:476-477` `Task<()?, Never>` не приводиться до `Task<Void, Never>` (замикання `await self?.runBackfill(...)` без контексту типу). Виправлено явним `Task<Void, Never>`; інші `Task { … self?… }` мають контекст типу і компілювались раніше. Статичне рев'ю Judge цю помилку пропустило — без macOS-компілятора такі помилки вилазять лише на Mac.

### M8 — PASS
- Запит користувача: переклад і приклад у контексті IT/QA. Рішення користувача: завжди IT/QA (без налаштування); наявний словник НЕ перекладати (спершу обрав «перекласти все», потім скасував — план скорочено до D31).
- Інструкція (≤70 слів) додається в system-промпт: одиночний, комбінований EN+IT (один раз), пакетне доповнення італійською. JSON-схеми, кількість запитів і тіло запиту без змін. App/ не змінювався — перезбірка на Mac не потрібна для перевірки компіляції, лише для якості відповідей (U19, `docs/development/manual-tests/M8.md`).
- Linux: 508 тестів, 0 падінь.

### M9 — PASS (умовний)
- Інтерфейс англійською (за замовчуванням) та українською через чисту Swift-таблицю `L10n` у ядрі; вибір у Налаштуваннях, застосування після перезапуску (обмежений цикл очікування + `open`).
- Services: ключ `NSMenuItem.default` лишився «Додати в словник» (не скидає увімкнення/шорткат), англійська назва через `en.lproj/ServicesMenu.strings`; назва йде за мовою системи.
- Linux: 542 тести, 0 падінь; скан кириличних літералів поза таблицями локалізації.
- Дрібне (виправити в M10): `-ge` → `-gt` у скрипті перезапуску; англійський текст про ліміт слів; «Restart Now» за HIG.

### M10 — репозиторій до публікації
- README.md (EN) + README.uk.md (UK): вимоги, встановлення й оновлення командами, налаштування, використання, дані й приватність, перенесення, видалення, усунення проблем, розробка. LICENSE (MIT). Внутрішні документи — у `docs/development/`.
- Перевірка гігієни: справжніх ключів і персональних даних немає (усі `sk-ant-*` — фейкові тестові), автор усіх комітів `Claude <noreply@anthropic.com>`.
- Judge: FAIL лише тому, що зміну в `AppRelauncher.swift` (`-gt`) і команди README з `-configuration Release` не зібрано на macOS (CI без раннерів). Перевірити на Mac.
- Історія містить WIP-коміти — за бажанням злити гілку в `main` через squash.

## iOS (IOS_PLAN.md)

### Рішення користувача (2026-11-15)
- Безкоштовний Apple ID (Personal Team); синхронізація з Mac — вручну (експорт/імпорт `dictionary.json`).
- Голос: перемикач EN/IT біля мікрофона; розпізнане слово **завжди** підтверджується кнопкою «Додати» (**iU15 = (а) підтвердження**; КП I2b.4 не застосовується).
- Точки входу: «Поділитися», Siri/Швидкі команди, віджет.
- Економія токенів: 1 запит на нове слово, 0 на дубль.
- Team ID ніколи не комітиться — лише `Config/Local.xcconfig` (gitignored).
- Перевірка iOS/macOS-збірок — на Mac користувача (GitHub Actions без раннерів): після кожного етапу оркестратор дає промпт для Claude Code на Mac.

### Неблокуючі зауваження Judge до плану (врахувати під час реалізації)
- I2a: у промпт для Mac додати macOS-регресію `xcodebuild test -scheme VocabApp`.
- I2a: описати, як `languageHint` впливає на `Equatable`/merge; тест `testHintDoesNotCreateSpuriousConflict`.
- I5: AirDrop — через Files → «Поділитися».

### Етапи iOS
_(вердикти Judge — нижче по етапах)_

#### I0 — ітерація 1: FAIL
- Помилка компіляції `VocabMobileApp.swift:68`: `Result<URL, Status>`, а `Status` не `Error`. Tester її пропустив (рев'ю без компіляції). Дрібне: суперечність імені App Group у `IOS_PLAN.md` §2/§6.

#### I0 — ітерація 2: PASS (умовний)
- Виправлено (`enum Status: Error, Equatable`); App Group = `group.<prefix>` (§6). Linux: 552 тести, 0 падінь (зокрема 10 тестів гігієни Team ID; Tester мутаційно перевірив 20 варіантів витоку).
- Новий прийом проти «помилок, видимих лише на Mac»: не-UI iOS-код (probe, ShareViewController, SpikeTests) тайпчекається на Linux із заглушками UIKit/`containerURL` (`swiftc -swift-version 5 -typecheck`). SwiftUI-екрани й віджет — лише рев'ю.
- Неблокуюче: порожній слот AppIcon 1024 (попередження actool).
- ⏳ Mac: `manual-tests/I0.md` — T1 (macOS-регресія), T2/T2a/T3 (iU8), пристрій D/S/W/L (iU1, iU2, iU3), рішення за Планом Б → сюди.
- 2026-11-15: **користувач відклав перевірку I0 на Mac** («роби далі»). Продовжуємо I1a з припущенням «усе працює → план без змін»; ризик — накопичення помилок компіляції iOS до першої Mac-збірки. Мітигація: максимум логіки тайпчекається на Linux проти справжнього VocabCore.

#### I1a — ітерація 1: PASS (умовний)
- Ядро: `.iOS(.v17)`, `AppPaths` fallback `NSHomeDirectory()` поза macOS/Linux, `ProcessingTrigger` + `.foreground`, `.inbox`; скан кирилиці охоплює `Mobile/Sources`, `Extensions/*/Sources`.
- `AppContainer` (single-flight `ensureLoaded`), `MobileAppModel`, `Router`/`DeepLink`, `EntryListView`/`EntryRowView`.
- Linux: 552 тести ядра; мобільні тести (21 із 22, без hosted `AppLaunchTests`) компілюються й проходять у Linux-харнесі проти справжнього VocabCore (scratchpad, не в репо).
- Прийняті відхилення: `VocabMobileTests` без прямого лінкування VocabCore (як macOS `VocabAppTests`; запасний план у `project.yml`); `EntryRowContent` у `MobileAppModel.swift`.
- Перенесено в I1b: `loadOutcome` присвоювати всередині `Task` (усі викликачі бачать `isLoaded` одразу після `await`) + тест; винести `EntryRowContent` в окремий файл; `hasNoSearchResults` прибрати або задіяти.
- ⏳ Mac: `manual-tests/I1a.md` (разом з I0.md).

#### I1b — ітерація 1: PASS (умовний)
- Додавання (Claude / вручну D14), редагування (варіанти зберігаються), видалення, «Повторити», `.refreshable` → retryAll, доповнення IT лише в режимі IT + «Оновити італійський» (1 запит), Settings (ключ у Keychain з service = bundle id iOS-застосунку, модель, мова інтерфейсу миттєво через `.id`), озвучення.
- Tester знайшов гонку `MobileAppModel.start()` (миготіння порожнього стану на старті) → виправлено single-flight до рев'ю Judge.
- Linux: ядро 552; мобільний харнес 41/0 (на iOS очікується 44: + AppLaunch, 2 Keychain).
- Свідомі відхилення від плану на iOS: немає 60-с таймера pending і `NetworkMonitor` (pending добирають `.foreground` і pull-to-refresh), немає кнопки «Fill Italian (N)» (автодоповнення в режимі IT + дія на записі), OSLog subsystem спільний з macOS (`com.vocabapp.VocabApp`), `AppRoute.settings`, `RenderingLanguageTexts.swift` спільний за шляхом, `APIKeyCache`/`EntryForm` — копії (DI5).
- Після помилки завантаження повтор лише перезапуском застосунку (як macOS, §4).
- Після рев'ю: `.foreground` поважає backoff (зауваження Judge щодо токенів), прибрано невикористаний ключ L10n.
- ⏳ Mac: `manual-tests/I1b.md`.

#### I2a — ітерація 1: PASS
- `Entry.languageHint` (адитивне, `encodeIfPresent`; запис без підказки — байт-у-байт як раніше), `AddWordUseCase.execute(rawText:sourceLanguageHint:)` (поза `allowedSourceLanguages` — відкидається), `WordLookupService`/`PromptBuilder` з підказкою (без підказки промт байт-у-байт як раніше), очищення на ready.
- Equatable/merge: синтезований `Entry ==` включає поле, але `ImportMerger` його не використовує (збіг за id/ключем, переможець за `updatedAt`) → записи, що відрізняються лише підказкою, не дають конфлікту (`testHintDoesNotCreateSpuriousConflict`). Описано в IOS_PLAN §3.2.
- Відхилення: змінено `DictionaryRepository.swift` (add копіює підказку; update її зберігає; збереження як ready очищує — зокрема ручне заповнення). Два еквівалентні мутанти (надлишкові guard-и в `PromptBuilder` і `EntryProcessor`) — прийнято як захист у глибину.
- Токени: слово з підказкою — 1 запит; італійський дубль ready-варіанта — 0.
- Обов'язково в Mac-промпті I2b: macOS-регресія `xcodebuild test -scheme VocabApp`.

#### I2b — ітерація 1: PASS (умовний)
- `VoiceCaptureModel` (tap-to-talk, автостоп 1,5 с тиші / 10 с, підтвердження кнопкою «Додати» — iU15), `SpeechRecognitionService` (on-device за наявності, інакше серверне з позначкою, офлайн без on-device → помилка + ручне поле), перемикач EN|IT (`voiceLanguage`), підказка мови → 1 запит / дубль 0, `vocabapp://voice[?lang=it]` слухає одразу лише з дозволами.
- Tester: аудіосесія не вимикалась після «Озвучити» (музика лишалась приглушеною) і можливе вічне «Завершення розпізнавання…» → виправлено до Judge (деактивація після озвучення/закриття, finalize timeout 3 с).
- Відхилення: `VoiceSupport.swift`, `VoiceSpeechService.swift` (iOS-адаптер), `cancel()` у `SpeechRecognizing`, `VoiceWordSubmitting`, мова з глибокого посилання — лише на сеанс, глибоке посилання без запитаного дозволу → idle («торкніться мікрофона», системний запит при дотику) замість окремого екрана дозволу; плаваюча кнопка мікрофона в списку.
- Перенесено в I3: `AddWordSheet.swift:68` `.onDisappear { voice.cancel() }` на Form спрацьовує і при переході «Заповнити вручну» → перенести на рівень аркуша.
- ⏳ Mac: `manual-tests/I2b.md` (§0 — промпт з macOS-регресією; пристрій: повторний старт двигуна S7/D3, музика A4/A5). На iOS очікується 76 тестів.

#### I3 — ітерація 1: PASS (умовний)
- Ядро `Inbox/` (`InboxStore`: tmp + `moveItem`, ліміт 200, биті → `Rejected/`; `InboxIngestor`: single-flight, 1 `processAll` на прохід, дубль — 0 запитів), Share Extension (не викликає Claude/Keychain, пише лише в `<App Group>/Inbox`), інжест на `.active` у порядку ensureLoaded → ingest → processAll(.foreground), банер звіту.
- Tester: 19/19 мутантів убито; функціональних багів немає.
- Відхилення: `scan()`/`InboxScanResult`, logger в ingestor, тригер `.inbox` лише в логах (`processAll(ignoringBackoff: false)`), `ShareInboxWriter.swift`, plain-text має пріоритет над `attributedContentText` (до спостереження iU6), мова розширення — з `Locale.preferredLanguages`.
- Ризик Mac: `VocabMobileTests` компілює файли розширення за шляхом без лінкування VocabCore → можливі `Undefined symbols` при dead-strip. Якщо станеться — **не** додавати `- package: VocabCore` у тести (дві копії стану L10n), а змусити застосунок посилатися на символи.
- Перенесено (бажано, I5): тайм-аут ~5 с у `ShareViewController.loadCandidates` (лист може зависнути в «Збереження…»); банер недораховує при storage-помилці (failed = 1 при кількох залишених файлах).
- ⏳ Mac: `manual-tests/I3.md`; на iOS очікується 90 тестів.

#### I4 — ітерація 1: PASS (умовний)
- `AddToDictionaryIntent` (у процесі застосунку, `AppContainer.shared`, 1 запит / дубль 0; через 8 с — «Збережено, перекладається», задача додавання не скасовується), `StartVoiceCaptureIntent` (спільний `AppContainer.router`), `VocabShortcuts` (фрази з `\(.applicationName)`, en/uk `AppShortcuts.strings`), віджет `VoiceCaptureWidget` (Home + Lock Screen, `vocabapp://voice`, без App Group), тайм-аут 5 с у Share Extension (перенесено з I3).
- Tester: 22/22 мутанти вбито; багів немає.
- Відхилення: DI17 розширено — `Mobile/Resources/*.lproj/Localizable.strings` для метаданих App Intents (без нього Shortcuts англійською на українському iPhone); `AddToDictionaryRunner.swift`; валідація тексту до завантаження словника; власний діалог порожнього тексту; без параметра мови у фразах Siri. Kind віджета змінено → спайк-віджет на телефоні треба видалити й додати новий.
- Після рев'ю (оркестратор): `static let description: IntentDescription?` (тип як у вимозі протоколу, щоб не підставлявся дефолт `nil`); у I4.md T4 перевірка опису в `extract.actionsdata`.
- Відомо: якщо Siri скасує дію, `perform` може тривати до 8 с (очікування не реагує на скасування) — на токени/дані не впливає.
- ⏳ Mac: `manual-tests/I4.md`; на iOS очікується 111 тестів.

#### I5 — ітерація 1: PASS (умовний)
- Експорт через `fileExporter` (`dictionary.json`, схема v1; AirDrop — через Files → «Поділитися»), імпорт через `fileImporter`: копія security-scoped файлу до читання, merge/replace (бекап перед replace), звіт D1, імпортовані pending — один прохід (1 запит/слово, повтор — 0). README: розділ `## iPhone` (EN/UK).
- Tester: 18 тестів, 5/6 мутантів убито (шостий — подвійний захист ядра; без обох — убито).
- Відхилення: експорт напряму через `DictionaryExporter` (не `exportDictionary(to:)`); ім'я як на macOS; копіювання до діалогу режиму.
- Не зроблено (відомо): банер inbox недораховує при storage-помилці (зміна торкнулася б тесту ядра); `copyItem` без `NSFileCoordinator` (iCloud-файли, що не завантажені → можливий readFailed — перевірити на Mac).
- Після рев'ю (оркестратор): `IOS_ALL.md` — без Local.xcconfig не вигадувати Team ID, гігієна без фікстур, очікувана кількість macOS-тестів; `README.uk.md` — українські мітки Mac.

### Підсумок iOS
- Усі етапи I0–I5 пройшли Developer → Tester → Judge (FAIL лише I0 ітерація 1). Linux: ядро 596, мобільний харнес 124.
- 2026-11-16, **перший прогін на Mac** (macOS 27.2.1, Xcode 27.2, симулятор iPhone 18 Pro / iOS 27.2; звіт — `manual-tests/IOS_ALL-report-2026-11-16.md`):
  - macOS-регресія: **113 тестів, 0 падінь** ✅.
  - iOS: усі таргети (застосунок, VocabShare, VocabWidget, метадані App Intents) зібрались **без помилок компіляції**; `Undefined symbols` не виникло (запасний план не знадобився).
  - iOS-тести: **129**, 127 ✅; 2 Keychain-тести впали з -34018 — збірка без підпису (`CODE_SIGNING_ALLOWED=NO`, немає `Local.xcconfig`), очікувано за `IOS_ALL.md` (iU8: без команди симулятор вимагає План Б).
  - Попередження: `ld … macOS-13.0 … XCTest built for 14.0` (macOS-тести, давнє, не від iOS-етапів); `Metadata extraction skipped` для VocabShare (очікувано).
  - Умовні PASS I0–I5 підтверджено щодо компіляції й автотестів. Лишається: `Config/Local.xcconfig` → підписаний прогін (Keychain-тести) і ручні чеклісти на iPhone (I0.md … I5.md).

## Відкриті питання / невизначеності щодо macOS API

Повний перелік і план перевірки — `ARCHITECTURE.md`, розділ «Невизначеності щодо macOS API» (U1–U12). Коротко:
- U1 `NSPortName` vs `CFBundleName` для LSUIElement-застосунку.
- U2 Чи з'являється сервіс без ручного вмикання в System Settings → Keyboard Shortcuts → Services.
- U3 Бриджинг сигнатури `addToDictionary(_:userData:error:)` у Swift.
- U4 Виявлення сервісу лише з `/Applications` / після `pbs -update`.
- U5 Чи запускає система LSUIElement-застосунок при виклику сервісу.
- U6 Підтримка Services у Chrome і для PDF.
- U7 Сповіщення для ad-hoc підписаного застосунку.
- U8 `SMAppService.mainApp` поза `/Applications` / з ad-hoc підписом.
- U9 Keychain при зміні ad-hoc підпису; Keychain на CI.
- U10 XcodeGen локальний пакет у корені.
- U11 Наявність англійського голосу на CI.
- U12 `MenuBarExtra` + `openWindow` на macOS 13, автовідкриття `Window`, формат ідентифікаторів вікон.
- U14 (M6) `NSApp.appearance`: перемальовування відкритих вікон, тема меню `MenuBarExtra(.menu)`, повернення до системної теми.
- U13 (M4) Послідовний показ `confirmationDialog` (вибір режиму імпорту) → `alert` (підтвердження «Замінити») у вікні налаштувань на macOS 13: чи з'являється другий діалог одразу після закриття першого; `.keyboardShortcut(.defaultAction)` для «Об'єднати» в `confirmationDialog`. Перевірити вручну (M4.md).

## Рішення, прийняті без підтвердження користувача

Користувач дозволив не чекати підтвердження. Рішення D1–D17 зафіксовані в `ARCHITECTURE.md` («Рішення щодо неоднозначностей»).
Найважливіше: 429/5xx/таймаут теж ідуть у `pending` (до 5 спроб), 401/400 — одразу `failed`; конфлікт при merge — за `id` або за мовною парою + нормалізованим словом.
