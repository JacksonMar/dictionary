# VocabApp — англо-український словник у menu bar macOS

VocabApp — застосунок для macOS, що живе в рядку меню (menu bar) і збирає ваш особистий словник.
Виділіть англійське слово чи фразу в будь-якій програмі (Safari, Chrome, TextEdit, Notes, PDF…), натисніть
праву кнопку миші → **Services (Служби) → «Додати в словник»** — і VocabApp:

1. отримає виділений текст;
2. запитає Claude API: переклад українською, транскрипцію (IPA), частину мови, приклад речення;
3. збереже запис у словник (`~/Library/Application Support/VocabApp/dictionary.json`);
4. покаже системне сповіщення «Додано: run — бігти, керувати» (або «Вже є в словнику»).

Також є головне вікно зі списком, пошуком, сортуванням, ручним додаванням, редагуванням, видаленням і озвученням
слів; черга «очікує обробки» для слів, доданих без мережі; експорт/імпорт словника; автозапуск при вході в систему.

## Вимоги

- macOS 13 Ventura або новіша;
- Xcode 15 або новіший (Swift 5.9+), Command Line Tools;
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — генерує `VocabApp.xcodeproj` з `project.yml`;
- API-ключ Anthropic (Claude) — https://console.anthropic.com/.

Сторонніх залежностей немає.

## Збірка

```sh
brew install xcodegen          # один раз
git clone <url-репозиторію> dictionary && cd dictionary
xcodegen generate              # створює VocabApp.xcodeproj (у git не зберігається)
xcodebuild -scheme VocabApp -configuration Release -derivedDataPath build build
```

Результат: `build/Build/Products/Release/VocabApp.app`.

**Підпис.** Застосунок підписується локально, ad-hoc (`CODE_SIGN_IDENTITY = "-"` у `project.yml`); облікового
запису розробника Apple і App Store не потрібно. Наслідки ad-hoc підпису:

- після кожної перезбірки змінюється підпис, тому macOS може один раз запитати доступ до елемента Keychain з
  API-ключем — натисніть «Завжди дозволяти» (або просто введіть ключ ще раз у Налаштуваннях);
- якщо `.app` скопійовано з іншого комп'ютера (завантажено, передано через AirDrop), Gatekeeper може заблокувати
  запуск: ПКМ на застосунку → «Відкрити», або `xattr -dr com.apple.quarantine /Applications/VocabApp.app`.

## Встановлення

```sh
# вийдіть з VocabApp, якщо він запущений (menu bar → «Вийти»)
rm -rf /Applications/VocabApp.app
cp -R build/Build/Products/Release/VocabApp.app /Applications/
open /Applications/VocabApp.app
```

Встановлюйте саме в `/Applications` (або `~/Applications`): система шукає Services і login items у
встановлених застосунках; запуск прямо з `build/` може не зареєструвати сервіс і автозапуск.

## Перший запуск

1. Запустіть `/Applications/VocabApp.app`. У menu bar з'явиться іконка книжки; іконки в Dock і вікон немає —
   це нормально (застосунок працює як menu bar app).
2. Дозвольте сповіщення в системному діалозі (запит з'являється один раз, при першому запуску). Якщо
   відмовили — результат останнього додавання все одно видно в меню VocabApp; увімкнути сповіщення можна в
   System Settings → Notifications → VocabApp.
3. Menu bar → **«Налаштування…»** → введіть API-ключ Anthropic → «Зберегти ключ». Ключ зберігається лише в
   Keychain (див. «Приватність»). Там само можна змінити модель Claude (за замовчуванням `claude-haiku-5-5`).

## Активація пункту «Додати в словник» у Services

1. Після першого запуску з `/Applications` оновіть реєстр сервісів:

   ```sh
   /System/Library/CoreServices/pbs -update
   ```

2. Відкрийте **System Settings → Keyboard → Keyboard Shortcuts… → Services → Text** і переконайтеся, що
   пункт **«Додати в словник»** увімкнений (галочка). За бажанням призначте йому сполучення клавіш.
3. Виділіть слово в Safari / TextEdit → ПКМ → **Services → «Додати в словник»**
   (у деяких програмах пункт є лише в меню програми: *Назва програми → Services*).

### Якщо пункту немає

- Переконайтеся, що застосунок лежить у `/Applications` і був запущений хоча б раз.
- Скиньте й оновіть кеш сервісів, потім перезапустіть програму, у якій виділяєте текст:

  ```sh
  /System/Library/CoreServices/pbs -flush
  /System/Library/CoreServices/pbs -update
  ```

- Перевірте, що сервіс зареєстровано: `/System/Library/CoreServices/pbs -dump | grep -A8 VocabApp`.
- Якщо після цього пункт усе ще відсутній — вийдіть з облікового запису macOS і увійдіть знову.
- Пункт показується лише коли виділено текст; для PDF і деяких браузерів спробуйте меню програми → Services.
- Сповіщення не з'являються — перевірте System Settings → Notifications → VocabApp; останній результат
  видно в меню VocabApp у menu bar.
- Логи: `log show --last 30m --predicate 'subsystem == "com.vocabapp.VocabApp"' --info`
  (API-ключ у логи ніколи не потрапляє).

## Використання

- **Додавання через Services** — як описано вище. Слово (до 8 слів і 120 символів; фраза обробляється як фраза)
  спершу зберігається зі статусом «очікує обробки», потім заповнюється відповіддю Claude. Повторне додавання
  того самого слова дає сповіщення «Вже є в словнику».
- **Menu bar**: останній результат додавання, «Відкрити словник», «Повторити очікувані (N)» (якщо є слова,
  що чекають обробки або з помилкою), «Налаштування…», «Вийти».
- **Головне вікно** («Відкрити словник»):
  - список: слово, транскрипція, частина мови, переклади, приклад;
  - **пошук** у полі пошуку на панелі інструментів — за словом, лемою і перекладами, без урахування регістру
    й діакритики (наприклад, «біг» знайде `run — бігти`);
  - **сортування** — меню на панелі: «Спершу нові», «Спершу старі», «За алфавітом»;
  - **озвучення** — кнопка з динаміком біля слова (англійський голос системи; у контекстному меню рядка також
    «Озвучити приклад»). Якщо англійського голосу немає, додайте його: System Settings → Accessibility →
    Spoken Content → System Voice → Manage Voices;
  - «+» — ручне додавання (усі поля вручну або «Заповнити через Claude»), олівець — редагування, кошик — видалення;
  - позначки «очікує обробки» / «помилка» і кнопка «Повторити»; «Повторити всі» на панелі інструментів.
- **Без мережі** слово потрапляє в чергу й обробляється автоматично, щойно мережа з'явиться (або кнопкою
  «Повторити»). Тимчасові помилки (429, 5xx, таймаут) повторюються до 5 разів; невірний ключ (401) чи
  невалідна відповідь — одразу «помилка» з кнопкою «Повторити».
- **Автозапуск**: Налаштування → «Запускати при вході в систему». Якщо macOS вимагає підтвердження, з'явиться
  кнопка «Відкрити Login Items» — дозвольте VocabApp у System Settings → General → Login Items.
  Автозапуск надійно працює лише для застосунку в `/Applications`.

## Перенесення словника на інший Mac

**Експорт / імпорт (рекомендовано):**

1. На старому Mac: Налаштування → «Перенесення» → **«Експортувати…»** → збережіть `dictionary.json`.
2. Перенесіть файл (AirDrop, флешка, хмара).
3. На новому Mac (після встановлення VocabApp): Налаштування → **«Імпортувати…»** → виберіть файл → режим:
   - **«Об'єднати»** (за замовчуванням): нові записи додаються; якщо слово вже є (той самий `id` або те саме
     слово в тій самій мовній парі), перемагає запис з пізнішою датою зміни (`updatedAt`);
   - **«Замінити…»**: поточний словник повністю замінюється вмістом файлу — після підтвердження; перед заміною
     поточний словник автоматично зберігається в
     `~/Library/Application Support/VocabApp/Backups/dictionary-backup-<дата>-<час>.json`
     (зберігаються 10 останніх копій).
4. Після імпорту з'явиться звіт «Додано X, оновлено Y, пропущено Z» з причинами пропуску. Невалідний файл
   (не JSON, інша `schemaVersion`, немає `entries`) словник не змінює.

**Копіювання файлу вручну:** вийдіть з VocabApp на обох комп'ютерах і скопіюйте
`~/Library/Application Support/VocabApp/dictionary.json` у той самий каталог на новому Mac (наявний файл там
буде замінено).

**API-ключ не переноситься** (він не потрапляє ні в експорт, ні в `dictionary.json`): введіть його в
Налаштуваннях на новому Mac ще раз. Слова зі статусом «очікує обробки» оброблятимуться після цього автоматично.

## Тести

### Швидка перевірка на Mac (з нуля)

Склонувати гілку, згенерувати проєкт і прогнати всі тести застосунку:

```sh
git clone -b claude/macos-dictionary-en-uk-context-obp1i3 https://github.com/JacksonMar/dictionary.git
cd dictionary
brew install xcodegen
xcodegen generate
xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
```

Очікуваний результат у кінці виводу: `Executed 71 tests, with 0 failures` і `** TEST SUCCEEDED **`.

### Окремо ядро і застосунок

```sh
# Ядро (VocabCore): macOS або Linux (Docker)
swift test
docker run --rm -v "$PWD":/w -w /w swift:6.0-noble swift test

# Застосунок (VocabAppTests, лише macOS)
xcodegen generate
xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=-
```

Тести не роблять мережевих запитів і не чіпають ваш справжній словник (працюють у тимчасовому каталозі).
Те, що можна перевірити лише на реальному Mac (Services у браузерах, сповіщення, автозапуск, озвучення),
описано в ручних чеклістах [`docs/manual-tests/`](docs/manual-tests/). CI: `.github/workflows/ci.yml`.

## Приватність

- API-ключ зберігається **лише** в Keychain (служба `com.vocabapp.VocabApp`); його немає в коді, логах,
  `UserDefaults`, `dictionary.json` і файлах експорту. Перевірити:
  `security find-generic-password -s com.vocabapp.VocabApp` (ключ є лише там),
  `grep -c sk-ant ~/Library/Application\ Support/VocabApp/dictionary.json` → `0`.
- На сервер Anthropic надсилається лише виділений текст (слово/фраза) і промт.
- Словник зберігається локально у `~/Library/Application Support/VocabApp/`.

## Структура проєкту

```
Package.swift            Swift-пакет VocabCore (ядро, лише Foundation; збирається на macOS і Linux)
project.yml              опис Xcode-проєкту для XcodeGen
Sources/VocabCore/       модель даних, мовні пари, нормалізація, сховище (атомарний запис, бекапи),
                         репозиторій, пошук/сортування (EntryQuery), Claude API, черга pending,
                         use-case Services і тексти сповіщень, експорт/імпорт
Tests/VocabCoreTests/    тести ядра
App/Info.plist           Info.plist застосунку (LSUIElement, NSServices)
App/Sources/             SwiftUI/AppKit: menu bar, вікна, Settings, Services-провайдер, Keychain,
                         сповіщення, автозапуск (SMAppService), озвучення (AVSpeechSynthesizer), мережа
App/Tests/               тести застосунку (лише macOS)
docs/                    вимоги і ручні чеклісти
```

## Документація

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — архітектура, формати, модель помилок, рішення, план етапів;
- [`PROGRESS.md`](PROGRESS.md) — стан етапів, відкриті питання щодо macOS API;
- [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md) — вимоги;
- [`docs/manual-tests/`](docs/manual-tests/) — ручні перевірки M1–M5.
