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

## Середовище перевірки

- Розробка ведеться в Linux-контейнері (немає Xcode). Ядро (`VocabCore`, лише Foundation) збирається й тестується локально: Docker-образ `swift:6.0-noble`, `swift test`.
- macOS-збірка й тести (`xcodegen` → `xcodebuild build` → `xcodebuild test`) запускаються в GitHub Actions (`.github/workflows/ci.yml`, раннер `macos-15`). Judge спирається на результат CI.
- Ручні перевірки (Services у Safari/Chrome/TextEdit, сповіщення, автозапуск, озвучення) можливі лише на реальному Mac: див. `docs/manual-tests/`.

## Вердикти Judge

### Architecture — ітерація 1: FAIL
- зайвий `output_config.effort` у тілі запиту; `max_tokens` 2048 замало; `Logger` конфліктує з `os.Logger`;
  не визначено `.skipped` → сповіщення; неповна прив'язка типів до файлів; немає плану Б для Keychain на CI;
  не враховано автовідкриття `Window` на macOS 13.

### Architecture — ітерація 2: PASS
- Усі 7 зауважень виправлено. Неблокуючі нотатки (мапінг `.skipped`→`.added` для ready, D17, формат ідентифікаторів вікон) внесено в план.

### M1 — ітерація 1: PASS
- Linux: 71 тест ядра, 0 падінь. macOS CI (run 38423702609): `swift test` ✅, `xcodegen` + `xcodebuild build` ✅, `xcodebuild test` ✅ (8 тестів застосунку).
- Неблокуючі зауваження: гонка check-then-act у `AtomicFileWriter` при першому записі (виправити в M2); CI-кроки з `if: hashFiles` (прибрано); назви CI jobs в ARCHITECTURE.md (виправлено); ручний чекліст `docs/manual-tests/M1.md` — ⏳ виконати на Mac.

### M2 — ітерація 1: PASS
- Linux: 178 тестів ядра, 0 падінь. macOS CI (run 38426913778): `xcodebuild build` ✅, `xcodebuild test` ✅ (15 тестів, зокрема Keychain на реальному Keychain раннера).
- Відхилення, прийняті Judge: ручне додавання — форма (`ready`) + окрема кнопка «Заповнити через Claude» (D14); невідома мовна пара → `failed` з «Невідома мовна пара»; відсутня `lemma` → `word`.
- Неблокуючі зауваження (виправити в M3): редагування збереженого ключа в тексті серверної помилки (не лише шаблон `sk-ant-`); `APIKeyCache` замінює старий ключ; `EntryProcessor.store` ковтає помилку запису; немає кнопки «Повторити всі»; помилка запису рахує спробу, але запис ніколи не стає `failed`.
- ⏳ `docs/manual-tests/M2.md` — виконати на Mac зі справжнім ключем.

### M3 — ітерація 1: PASS
- Tester виявив гонку подвійної обробки запису (`processAll` vs `retry`) → Developer виправив (атомарні check+insert у `processOne`) до рев'ю Judge.
- Linux: 223 тести, 0 падінь (QueueConcurrencyTests стабільний у 8 прогонах). macOS CI (run 38430377167): `xcodebuild build` ✅, `xcodebuild test` ✅ (33 тести, зокрема ServicesProviderTests 9, InfoPlistServicesTests 4), `swift test` на macOS ✅.
- U3 (бриджинг сигнатури Services-методу) закрито: селектор компілюється, `responds(to:)` = true.
- Неблокуючі зауваження (на M5): дубльований запит дозволу на сповіщення; `NotificationService` без анотацій конкурентності; текст «Services недоступні» поза §9; помилка запису показується як «Помилка мережі»; якщо холодний старт через Services не спрацює (U5) — реєструвати провайдер у `applicationWillFinishLaunching`.
- ⏳ `docs/manual-tests/M3.md` — перевірка в Safari/Chrome/TextEdit на реальному Mac.

### M4 — ітерація 1: PASS
- Linux: 317 тестів, 0 падінь. macOS CI (run 38434434649): `xcodebuild build` ✅, `xcodebuild test` ✅ (50 тестів, зокрема AppModelTransferTests 17), `swift test` на macOS ✅.
- Неблокуючі зауваження (на M5): «..» і англомовна системна причина в `readFailed`/`storage`; імпортоване слово не очищається; ready-запис з `[""]` приймається; кількість записів у повідомленні експорту з окремого знімка; синхронізувати §10 ARCHITECTURE з новими API.
- ⏳ `docs/manual-tests/M4.md` — перевірка панелей на Mac.

### M5 — ітерація 1: FAIL (інфраструктура, не код)
- Linux: 354 тести, 0 падінь. Увесь виробничий код M5 зібрано й протестовано на macOS у run 38436944130 (коміт df958a1): `xcodebuild build` ✅, `xcodebuild test` ✅.
- Коміт 91a651c додав лише тести (19 нових тестів застосунку: AppModelM5Tests 13, LoginItemServiceTests 1, SpeechServiceTests 5). Run 38468460084 не отримав жодного раннера (runner_id 0, жодного кроку, навіть для Linux-job); повторний запуск через інтеграцію → 403. Найімовірніше, вичерпано ліміт хвилин / spending limit GitHub Actions (macOS-хвилини рахуються з множником).
- Judge: блокуючих дефектів у коді немає; усі відкладені зауваження M2–M4 виправлено; README повний. Для PASS потрібен зелений macOS CI з новими тестами.
- Що зробити: відновити GitHub Actions (Settings → Billing / spending limit) і перезапустити CI (Actions → CI → Re-run) або локально на Mac: `xcodegen generate && xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`.
- ⏳ `docs/manual-tests/M5.md` — menu bar, автозапуск, озвучення на реальному Mac.
- 2026-10-14: користувач відновив ліміт, але перезапуск через інтеграцію заборонений (403 на rerun і workflow_dispatch). Рішення користувача: чекати оновлення ліміту. CI оптимізовано для економії macOS-хвилин: `macos-core` злито в `macos-app` (один macOS-раннер), зміни лише в `*.md`/`docs/`/`.claude/` не запускають CI, `concurrency` скасовує застарілі прогони.

### M5 — ітерація 2: PASS
- Користувач прогнав усе на реальному Mac (macOS 27.0.1, Apple M1, Xcode 27.0), звіт: `docs/reports/2026-10-14-mac-test-report.md`.
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
