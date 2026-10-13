# PROGRESS

| Етап | Статус | Ітерації | Вердикт Judge |
|------|--------|----------|---------------|
| Bootstrap (агенти, CI) | done | – | – (CI на macos-15 працює) |
| Architecture | done | 2 | PASS (ітерація 2) |
| M1 — Каркас і зберігання | done | 1 | PASS (ітерація 1) |
| M2 — Claude API | done | 1 | PASS (ітерація 1) |
| M3 — Services | in progress | 1 | – |
| M4 — Експорт/імпорт | pending | – | – |
| M5 — Полірування | pending | – | – |

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

## Рішення, прийняті без підтвердження користувача

Користувач дозволив не чекати підтвердження. Рішення D1–D17 зафіксовані в `ARCHITECTURE.md` («Рішення щодо неоднозначностей»).
Найважливіше: 429/5xx/таймаут теж ідуть у `pending` (до 5 спроб), 401/400 — одразу `failed`; конфлікт при merge — за `id` або за мовною парою + нормалізованим словом.
