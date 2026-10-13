# PROGRESS

| Етап | Статус | Ітерації | Вердикт Judge |
|------|--------|----------|---------------|
| Bootstrap (агенти, CI) | in progress | – | – |
| Architecture | pending | – | – |
| M1 — Каркас і зберігання | pending | – | – |
| M2 — Claude API | pending | – | – |
| M3 — Services | pending | – | – |
| M4 — Експорт/імпорт | pending | – | – |
| M5 — Полірування | pending | – | – |

## Середовище перевірки

- Розробка ведеться в Linux-контейнері (немає Xcode). Ядро (`VocabCore`, лише Foundation) збирається й тестується локально: Docker-образ `swift:6.0-noble`, `swift test`.
- macOS-збірка й тести (`xcodegen` → `xcodebuild build` → `xcodebuild test`) запускаються в GitHub Actions (`.github/workflows/ci.yml`, раннер `macos-15`). Judge спирається на результат CI.
- Ручні перевірки (Services у Safari/Chrome/TextEdit, сповіщення, автозапуск, озвучення) можливі лише на реальному Mac: див. `docs/manual-tests/`.

## Вердикти Judge

_(заповнюється по ходу)_

## Відкриті питання / невизначеності щодо macOS API

_(заповнюється по ходу)_
