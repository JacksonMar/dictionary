# IOS_ALL — звіт про першу збірку iOS (I0–I5) і macOS-регресію, 2026-11-16

Гілка: `claude/nifty-turing-s5jq8o` (`5c782b1`). Промпт: `IOS_ALL.md` §1, кроки 0–7.

## Підсумок

- macOS-регресія: **113 тестів, 0 падінь**, як і очікувалося.
- iOS: усі таргети (`VocabMobile`, `VocabShare`, `VocabWidget`) збираються.
- iOS-тести: **129 тестів**, 127 пройшли. 2 Keychain-тести впали з -34018 (`errSecMissingEntitlement`), бо збірка була без підпису. `IOS_ALL.md` §1 крок 3 передбачає таке падіння.
- Помилок компіляції немає. Код не змінено. Запасний план для `Undefined symbols` (§3) не знадобився.

## Версії

| Компонент | Версія |
|---|---|
| macOS | 27.2.1 (26B131) |
| Xcode | 27.2 (27B52) |
| xcodegen | 2.46.0 |
| iOS Simulator runtime | iOS 27.2 (24B8117) |
| Симулятор | iPhone 18 Pro (iPhone 16 немає, це найновіший) |

## Результати за кроками

| Крок | Команда | Результат |
|---|---|---|
| 0 | `sw_vers`, `xcodebuild -version`, `xcodegen --version`, `simctl list` | Спочатку iOS runtime не було, тому його встановили через `xcodebuild -downloadPlatform iOS`. `Config/Local.xcconfig` немає, тому iOS-кроки йшли з `DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO` |
| 1 | `git pull && xcodegen generate` | Already up to date. xcodegen створив проєкт |
| 2 | `xcodebuild test -project VocabApp.xcodeproj -scheme VocabApp -destination 'platform=macOS' CODE_SIGN_IDENTITY=-` | `** TEST SUCCEEDED **`, `Executed 113 tests, with 0 failures` |
| 3 | `xcodebuild test -project VocabApp.xcodeproj -scheme VocabMobile -destination 'platform=iOS Simulator,name=iPhone 18 Pro' DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO` | `** TEST FAILED **`, `Executed 129 tests, with 16 failures (7 unexpected)` |
| 4 | `xcodebuild build -project VocabApp.xcodeproj -scheme VocabMobile -destination 'generic/platform=iOS Simulator' DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO` | `** BUILD SUCCEEDED **` |
| 5 | `ls` бандла, `plutil -p Info.plist` | Усі потрібні файли є (деталі нижче) |
| 6 | `git grep -nE 'DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' …` | `no team id` |
| 7 | — | Помилок компіляції немає, тому виправляти нічого не треба було |

Деталі кроку 5 (`VocabMobile.app`):

- `Metadata.appintents` містить файли `extract.actionsdata`, `root.ssu.yaml`, `version.json`.
- `PlugIns` містить `VocabShare.appex` і `VocabWidget.appex`.
- `en.lproj` і `uk.lproj` містять файли `AppShortcuts.strings`, `InfoPlist.strings`, `Localizable.strings`, `nlu.appintents`.
- `CFBundleURLTypes` містить схему `vocabapp`. Значення `CFBundleURLName` дорівнює `com.example.vocab.VocabMobile`, бо `Local.xcconfig` немає.

## Помилки й попередження дослівно

### `Mobile/Tests/KeychainMobileTests.swift` (крок 3)

Усі 16 падінь сталися у 2 тестах: `testSaveReadDeleteKey` і `testKeyNeverInUserDefaults`.

```
KeychainMobileTests.swift:49: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertNil failed: threw error "keychain(status: -34018)"
KeychainMobileTests.swift:56: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertTrue failed - Could not save the key: Keychain error (code -34018)
KeychainMobileTests.swift:57: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertNil failed: "Could not save the key: Keychain error (code -34018)"
KeychainMobileTests.swift:58: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertTrue failed
KeychainMobileTests.swift:59: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertEqual failed: threw error "keychain(status: -34018)" - stored trimmed in the Keychain
KeychainMobileTests.swift:60: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertTrue failed - known to the log redactor
KeychainMobileTests.swift:64: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertEqual failed: threw error "keychain(status: -34018)"
KeychainMobileTests.swift:67: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertTrue failed
KeychainMobileTests.swift:71: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertTrue failed
KeychainMobileTests.swift:72: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertEqual failed: threw error "keychain(status: -34018)"
KeychainMobileTests.swift:77: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertEqual failed: threw error "keychain(status: -34018)"
KeychainMobileTests.swift:80: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertTrue failed
KeychainMobileTests.swift:82: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertNil failed: threw error "keychain(status: -34018)"
KeychainMobileTests.swift:83: error: -[VocabMobileTests.KeychainMobileTests testSaveReadDeleteKey] : XCTAssertTrue failed - deleting a missing key is not an error
KeychainMobileTests.swift:95: error: -[VocabMobileTests.KeychainMobileTests testKeyNeverInUserDefaults] : XCTAssertTrue failed - Could not save the key: Keychain error (code -34018)
KeychainMobileTests.swift:102: error: -[VocabMobileTests.KeychainMobileTests testKeyNeverInUserDefaults] : XCTAssertEqual failed: threw error "keychain(status: -34018)"
```

Код -34018 означає `errSecMissingEntitlement`. Без підпису застосунок не отримує Keychain entitlement, тому тести падають через середовище, а не через код.

### `VocabApp.xcodeproj` — VocabAppTests (крок 2)

```
VocabAppTests: ld: warning: building for macOS-13.0, but linking with dylib '@rpath/XCTest.framework/Versions/A/XCTest' which was built for newer version 14.0
VocabAppTests: ld: warning: building for macOS-13.0, but linking with dylib '@rpath/libXCTestSwiftSupport.dylib' which was built for newer version 14.0
```

### appintentsmetadataprocessor (кроки 2, 3, 4)

На iOS це попередження стосується таргета `VocabShare`. На macOS воно з'явилося 2 рази.

```
warning: Metadata extraction skipped, no AppIntents.framework dependency found
```

Розширення VocabShare не використовує App Intents, тому попередження очікуване.

### Логи середовища (не помилки коду)

- Під час macOS-тестів: `[Connection] Unable to get remoteObjectProxy … com.apple.linkd.autoShortcut` (3 рядки).
- Після iOS-тестів, коли xcodebuild збирав діагностику: `xcrun: error: unable to find utility "simctl", not a developer tool or in PATH`. Причина: `xcode-select` вказує на Command Line Tools.

## Порівняння з `IOS_ALL.md` §2

| Набір | Очікування | Факт | Висновок |
|---|---|---|---|
| macOS `VocabApp` | SUCCEEDED, N = 113, 0 падінь | SUCCEEDED, 113, 0 падінь | ✅ Збігається |
| iOS `VocabMobile` | SUCCEEDED, 129, 0 падінь | 129 тестів, 127 пройшли, 2 впали через Keychain -34018 | ⚠️ Кількість збігається. Без підпису `IOS_ALL.md` §1 крок 3 передбачає падіння Keychain-тестів |

## Примітки

- **xcode-select.** `xcode-select` вказує на `/Library/Developer/CommandLineTools`. Тому всі команди запускалися з `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **Наступний крок.** Щоб Keychain-тести пройшли і щоб установити застосунок на iPhone, потрібен `Config/Local.xcconfig` (Team ID і префікс bundle ID). Після цього треба повторити крок 3 з підписом.
