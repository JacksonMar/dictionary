# I1a — ядро на iOS, каркас застосунку, список (лише читання)

Джерело: `IOS_PLAN.md` §3.1, §4, §5 «Список», §7 «I1a». Код спайка I0 у застосунку замінено; Share Extension і віджет
ще спайкові (замінюються в I3/I4) — вони мають лише збиратися й встановлюватися, як в I0.

Кожен рядок «Результат» заповнити: ✅ / ❌ + що саме побачили. Помилки Xcode/`xcodebuild` — **дослівно** (перед
вставкою замінити Team ID на `<TEAM_ID>`, Apple ID — на `<APPLE_ID>`, як в I0.md).

Що в I1a **немає** (не баг): додавання/редагування/видалення, «+», шестерня, налаштування, свайпи, Claude, голос,
імпорт. Дані на iPhone потраплять лише через імпорт (I5); для перевірки списку зараз словник копіюється в контейнер
симулятора вручну (розділ 3).

## 1. Збірка й тести

```
git pull && xcodegen generate
xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' CODE_SIGN_IDENTITY=-
xcodebuild test -project VocabApp.xcodeproj -scheme VocabMobile -destination 'platform=iOS Simulator,name=iPhone 16'
# якщо в I0 симулятор потребував План Б (iU8) — додати: DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO
```

| # | Крок | Очікуваний результат | Результат |
|---|---|---|---|
| T1 | macOS-регресія (`-scheme VocabApp`) | `** TEST SUCCEEDED **`, кількість тестів як до I1a (ядро змінилося: `.iOS(.v17)`, `AppPaths`, `ProcessingTrigger` + `foreground`/`inbox`) | |
| T2 | Симулятор (`-scheme VocabMobile`) | `** TEST SUCCEEDED **`: `AppLaunchTests`, `MobileAppModelTests`, `AppContainerTests`. Якщо ❌ — помилку дослівно; окремо записати, якщо є `No such module 'VocabCore'` у `VocabMobileTests` (тоді в `project.yml` додати `- package: VocabCore` у залежності тест-таргета, як сказано в коментарі там) | |
| T3 | Попередження збірки `VocabMobile` (Xcode → Report navigator): чи є «linked as a static library by … This will result in duplication of library code» або попередження про `@MainActor`/`Sendable` у `Mobile/Sources` | Немає (записати дослівно, якщо є) | |
| T4 | Чи зібралося ядро під iOS без інших правок (iU13) | Так; якщо ❌ — файл і рядок помилки в `Sources/VocabCore` дослівно | |

## 2. Симулятор: порожній стан і каркас

Xcode → схема `VocabMobile` → симулятор «iPhone 16» → Run.

| # | Крок | Очікуваний результат | Результат |
|---|---|---|---|
| S1 | Перший запуск | Короткий індикатор «Loading the dictionary…» (може промайнути непомітно), далі екран «Dictionary»: по центру «No Words Yet» / «Words you add or import will appear here.» | |
| S2 | Верхня панель | Посередині сегменти **EN \| IT** (EN вибрано), праворуч іконка сортування (↑↓). Поле пошуку «Word or translation» — під заголовком (потягнути список вниз, якщо сховане) | |
| S3 | Тапнути IT, закрити застосунок (свайп у перемикачі застосунків), запустити знову | Лишився вибраний **IT** (зберігається в налаштуваннях) | |
| S4 | Терміналом: `xcrun simctl openurl booted "vocabapp://voice?lang=it"` | Застосунок відкривається на тому самому списку, без падіння (голосовий екран з'явиться в I2b) | |
| S5 | Де лежать дані: `APP=$(xcrun simctl get_app_container booted <prefix>.VocabMobile data); echo "$APP"; ls "$APP/Library/Application Support"` (`<prefix>` — ваш `VOCAB_BUNDLE_ID_PREFIX`) | Шлях усередині контейнера застосунку (`…/Containers/Data/Application/<UUID>`). Каталогу `VocabApp` ще може не бути — порожній словник на диск не пишеться, доки нічого не змінено (це нормально) | |

## 3. Симулятор: список на реальному словнику

Скопіювати словник з Mac у контейнер симулятора (застосунок спершу хоча б раз запустити — S1):

```
BUNDLE=<prefix>.VocabMobile
APP=$(xcrun simctl get_app_container booted "$BUNDLE" data)
mkdir -p "$APP/Library/Application Support/VocabApp"
cp "$HOME/Library/Application Support/VocabApp/dictionary.json" "$APP/Library/Application Support/VocabApp/dictionary.json"
xcrun simctl terminate booted "$BUNDLE"; xcrun simctl launch booted "$BUNDLE"
```
(Якщо на Mac словника немає — експортувати з macOS-застосунку будь-який `dictionary.json` або взяти невеликий
тестовий файл схеми v1.)

| # | Крок | Очікуваний результат | Результат |
|---|---|---|---|
| L1 | Запуск після копіювання | Список усіх записів; найновіші зверху. Рядок: слово жирним + транскрипція сірим, під ним переклади через кому, далі приклад курсивом «приклад — переклад» не довше 2 рядків | |
| L2 | Записи `pending`/`failed` (якщо є у файлі) | Праворуч бейдж «pending» (помаранчевий) / «error» (червоний) | |
| L3 | Пошук: ввести частину англійського слова, потім частину українського перекладу, потім слово з діакритикою без неї (напр. `cafe` для `café`) | Список фільтрується в усіх трьох випадках; регістр не важливий | |
| L4 | Пошук без збігів (напр. `qqqzzz`) | «No Results» / «Nothing found for “qqqzzz”.» | |
| L5 | Сортування (↑↓): «Alphabetical», «Oldest first», «Newest first» | Порядок змінюється відповідно; пошук при цьому зберігається | |
| L6 | **IT** | Записи з готовим італійським варіантом показують італійське слово, його транскрипцію, переклади й приклад; записи без варіанта — англійське слово сірим з бейджем «Italian version pending» (або «error» для невдалого варіанта) | |
| L7 | У режимі IT пошук за італійським словом | Знаходить записи за італійським словом | |
| L8 | Повернути **EN** | Знову англійські слова | |
| L9 | Прокрутка великого словника (якщо > 200 записів) | Плавна, без затримок при вводі в пошук (запишіть, якщо помітно гальмує) | |

## 4. Симулятор: помилки й мова інтерфейсу

| # | Крок | Очікуваний результат | Результат |
|---|---|---|---|
| E1 | Зіпсувати файл: `echo 'not json' > "$APP/Library/Application Support/VocabApp/dictionary.json"`, перезапустити (`terminate` + `launch`) | Порожній список, зверху банер «The dictionary file was corrupted. It was moved to …/Backups/…» з кнопкою «Close»; «Close» ховає банер | |
| E2 | Новіша схема: `echo '{"schemaVersion": 99, "entries": []}' > "$APP/Library/Application Support/VocabApp/dictionary.json"`, перезапустити | Екран «Could Not Open the Dictionary» з текстом про новішу версію схеми; сегменти й сортування неактивні; файл не змінено | |
| E3 | Відновити нормальний словник (команди розділу 3) | Список знову на місці | |
| E4 | Українська мова інтерфейсу (перемикача в UI ще немає — I1b): `xcrun simctl spawn booted defaults write "$BUNDLE" interfaceLanguage uk`, перезапустити | Заголовок «Словник», пошук «Слово або переклад», сортування й бейджі українською; порожній стан/помилки — українською. Повернути: `… defaults write "$BUNDLE" interfaceLanguage en`. Якщо `defaults write` не вплинув на застосунок — записати (тоді перевірка мови переноситься в I1b, де з'явиться перемикач) | |

## 5. iPhone (Personal Team)

| # | Крок | Очікуваний результат | Результат |
|---|---|---|---|
| D1 | iPhone кабелем → Xcode → схема `VocabMobile` → ваш iPhone → Run | Установка успішна (разом із Share і віджетом, як в I0). Якщо ❌ — дослівно | |
| D2 | Запуск | Порожній стан «No Words Yet» (дані з Mac з'являться лише після імпорту в I5) | |
| D3 | Перемикач EN \| IT, меню сортування, поле пошуку | Працюють без падінь на порожньому словнику | |
| D4 | Темна тема iOS (Control Center) | Екран коректно перемальовується (тема лише системна, DI19) | |
| D5 | (Необов'язково) реальні дані на пристрої до I5: Xcode → Window → Devices and Simulators → iPhone → застосунок VocabMobile → ⚙ → **Download Container…**, у пакеті `AppData/Library/Application Support/VocabApp/` покласти `dictionary.json`, далі ⚙ → **Replace Container…**, перезапустити застосунок | Список із записами, як L1–L8 | |
| D6 | Віджет і «Поділитися» (спайкові, з I0) | Як і раніше встановлюються; «Поділитися» більше нічого не показує в застосунку (екран пробних файлів прибрано) — очікувано до I3 | |
