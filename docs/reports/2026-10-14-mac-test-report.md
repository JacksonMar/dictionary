# VocabApp — звіт тестування (коміт 5813411, 2026-10-14)

## 1. Середовище
- macOS 27.0.1 (26A434), Apple M1 (arm64)
- Xcode 27.0 (27A266a), Swift 6.4, XcodeGen 2.46.0
- Safari 27.0.1, Chrome 155.0.8059.79

## 2. Автотести
| Набір | Результат |
|---|---|
| `xcodebuild test` (VocabAppTests) | ✅ **Executed 69 tests, with 0 failures**, `** TEST SUCCEEDED **` |
| `swift test` (VocabCoreTests) | ✅ **Executed 354 tests, with 0 failures** |

- Падінь немає.
- Очікувалось 71 тест застосунку, виконано 69. У `App/Tests` оголошено рівно 69 тестів (P1).
- Тести не створили і не змінили `~/Library/Application Support/VocabApp` ✅.
- Лише з Command Line Tools (без Xcode) `swift test` не компілюється (P2).

## 3. Збірка / встановлення
| Крок | Результат |
|---|---|
| `xcodegen generate` | ✅ |
| Release-збірка | ✅ BUILD SUCCEEDED, без помилок і попереджень у коді |
| Info.plist: NSServices (`Додати в словник`, `addToDictionary`, `NSPortName=VocabApp`, `NSStringPboardType` + `public.utf8-plain-text`), `LSUIElement=true` | ✅ |
| Підпис | ad-hoc |
| /Applications → запуск → `pbs -update` | ✅ |
| `pbs -dump`: сервіс зареєстровано | ✅ `NSBundlePath=/Applications/VocabApp.app`, `NSPortName=VocabApp` (див. P3 про пошук grep) |

## 4. Ручні перевірки
| Чекліст | Пункт | Результат | Що сталося |
|---|---|---|---|
| M5 A1 / M1 #13 / M3 A4 | Запуск без вікон | ✅ | Лише іконка в menu bar, без Dock, вікна не відкриваються |
| M3 A5 | Запит на сповіщення (ad-hoc) | ✅ | Системний запит показано; після дозволу банери доставляються. У лозі `Notification authorization request failed` — наслідок відмови в першому запиті (`didGrant: 0`); дозвіл увімкнули вручну о 18:26:47 |
| M5 A2 | Меню | ✅ | «<останній результат>», «Відкрити словник ⌘D», «Повторити очікувані (1)» (failed-запис), «Налаштування… ⌘,», «Вийти ⌘Q» |
| M1 #3 | Вікно «Словник» | ✅ | Відкривається; є сортування, оновлення, «+», пошук |
| M2 #2 | Збереження ключа | ✅ | Поле очищається, «Ключ збережено», ключ не показується |
| M2 #5 | Ключ у Keychain | ✅ | `security find-generic-password -s com.vocabapp.VocabApp -a anthropic-api-key` знаходить запис |
| M2 #13 / M3 C4 | Невірний ключ → 401 | ✅ | `failed`, «Невірний API-ключ (401)»; меню «Не вдалося додати: created: Невірний API-ключ (401)». Перший ключ тестувальника був недійсний (прямий `curl` теж повертав 401) |
| M2 #14 | Правильний ключ + «Повторити» | ✅ | `created` → ready: `/kriˈeɪtɪd/`, verb, 3 переклади, приклад; `status=200 duration=1.83s` |
| M2 #16 / #18 | Ключ у dictionary.json і логах | ✅ | `sk-ant`: 0 у файлі, 0 у логах за 60 хв; рядки логу — лише модель, статус, тривалість |
| M3 B1 Safari | Пункт у контекстному меню | ✅ | Є |
| M3 B2 Safari | Нове слово | ✅ | Банер «Додано»; `ubiquitous` ready, `/juːˈbɪkwɪtəs/`, adjective, 3 переклади, запит 1.17 с |
| M3 B4 Safari | Дубль `Ubiquitous` | ✅ | «Вже є в словнику»; дубля немає; нового `Claude request` немає |
| M3 B1–B3 Chrome | Виклик із Chrome | ⚠️ не підтверджено | Тестувальник сказав «працює», але в логах VocabApp після 18:56:53 немає жодного виклику Services (читання pasteboard), нових записів немає |
| M4 B3/B7 | Експорт | ✅ частково | Валідний JSON, `schemaVersion: 1`, `exportedAt`, `sk-ant` → 0 |
| M5 B1 | Тумблер автозапуску з /Applications | ✅ частково | Увімкнувся без вимоги підтвердження (`SMAppService status: 1`); перелогін не перевірено |
| Решта M2 (#6–12, 15, 17, 19–20), M3 (B5–B8, C1–C11, TextEdit, PDF), M4 (імпорт Об'єднати / Замінити + бекап, F, G), M5 (A3–A10, B2–B6, C, D, E) | — | не перевірено | Тестування зупинено на прохання тестувальника |

## 5. Невизначеності U1–U13 (macOS 27.0.1)
| # | Результат |
|---|---|
| U1 NSPortName=VocabApp | ✅ працює |
| U2 без ручного вмикання | ✅ пункт з'явився без вмикання в Keyboard Shortcuts |
| U3 сигнатура методу | ✅ виклик доходить, текст читається з pasteboard |
| U4 /Applications + `pbs -update` | ✅ достатньо, перелогін не потрібен |
| U5 холодний запуск через Services | не перевірено |
| U6 Chrome / PDF | Chrome — у логах виклику немає, не підтверджено; PDF — не перевірено |
| U7 сповіщення з ad-hoc | ✅ запит показується, після дозволу банери доставляються |
| U8 SMAppService | з /Applications вмикається без `requiresApproval` (status 1); перелогін і запуск поза /Applications — не перевірено |
| U9 Keychain з ad-hoc | збереження й читання працюють; після перезбірки не перевірено |
| U10 XcodeGen, пакет у корені | ✅ |
| U11 англійський голос | вручну не перевірено (`SpeechServiceTests` зелені) |
| U12 автовідкриття вікон | ✅ на macOS 27 не відкриваються; macOS 13 недоступна |
| U13 confirmationDialog → alert | не перевірено |

## 6. Проблеми
**P1. Кількість тестів у документації не збігається** (документація)
→ `xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' CODE_SIGN_IDENTITY=-`
→ Очікувано (README): `Executed 71 tests`
→ Фактично: `Executed 69 tests, with 0 failures`; у `App/Tests` 69 тестів. PROGRESS.md (M5): «21 новий тест застосунку», фактично 19 (AppModelM5Tests 13 + LoginItemServiceTests 1 + SpeechServiceTests 5).

**P2. `swift test` не працює лише з Command Line Tools** (документація)
→ Mac без Xcode.app, `xcode-select -p` = `/Library/Developer/CommandLineTools`; `swift test`
→ Очікувано: README згадує, що для `swift test` на macOS потрібен повний Xcode (XCTest)
→ Фактично:
```
ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found
error: Tests/VocabCoreTests/AddWordUseCaseTests.swift:2:8 unable to resolve module dependency: 'XCTest'
error: Build failed
```

**P3. `pbs -dump | grep "Додати в словник"` нічого не знаходить** (документація, низький)
→ Сервіс зареєстровано; `pbs -dump | grep -i "Додати в словник"`
→ Очікувано: знайдено
→ Фактично: порожньо, бо в дампі кирилиця екранована (`"\U0414\U043e\U0434\U0430\U0442\U0438 …"`). Пошук `grep VocabApp` з README працює.

**P4. Логи сповіщень пишуться в category `claude`** (низький)
→ `log show --predicate 'subsystem == "com.vocabapp.VocabApp"'`
→ Очікувано: окрема category для сповіщень
→ Фактично: `[com.vocabapp.VocabApp:claude] Notification authorization request failed: …`

**P5. Два запити до Claude за 1,2 с для одного запису** (спостереження, уточнити)
→ Запис `created` у `failed`; зберегти ключ (18:35:16), потім повторити
→ Очікувано: один запит на одну дію
→ Фактично: `18:35:25 … status=401` і `18:35:26 … status=401`, обидва для одного запису, без виклику Services. Чи це дві дії користувача («Повторити» і «Повторити очікувані»), чи подвійна обробка, з логів визначити неможливо (застосунок не логує тригер повтору).

## 7. UX-побажання тестувальника
1. **Таблиця.** Один рядок на слово, колонки: Слово | Транскрипція | Переклад | Приклад.
2. **Пагінація.** 20–30 слів на сторінку.
3. **Перемикач теми в застосунку.** Світла / Темна / Як у системі.
