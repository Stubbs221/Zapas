# Zapas

Локальное приложение для macOS: понять давление памяти, найти подходящие вкладки Chrome и устройства Simulator, проверить результат выбранного действия. Проект не обещает универсальную «очистку RAM».

**Статус:** реализованы A, оболочка B и Chrome C: production-расширение, явная установка Native Messaging, GUI-сервис, ручной выбор/preview, отдельные discard и close с проверкой результата. Квалификация частичная: CPU открытого окна B/C — FAIL (замеры в отчёте); MenuBarExtra/latency, macOS 14, реальный sleep/wake, полный VoiceOver и login/relogin — NOT RUN. LLDB отложен; Charles не квалифицирован. D не начат.

## Документация

- [План проекта](docs/ProjectPlan.md) — требования, архитектура, этапы A–F и источники API.
- [Этап A](docs/StageA.md) — объём технической проверки и воспроизводимые сценарии.
- [Запуск проверок](docs/StageARunbook.md) — сборка, метрики, Chrome и ручные процедуры.
- [Отчёт этапа A](docs/StageAReport.md) — результаты, ограничения и архитектура B.
- [Поручение для этапа B](docs/StageBPrompt.md) — готовый переход к реализации оболочки.
- [Отчёт этапа B](docs/StageBReport.md) — сборка, фактические проверки, стоимость и оставшаяся квалификация.
- [CLI JSON v1](docs/CLI.md) — поля, единицы, nullable-значения, ошибки и совместимость.
- [Поручение для этапа C](docs/StageCPrompt.md) — исходный объём Chrome.
- [Отчёт этапа C](docs/StageCReport.md) — установка, lifecycle, действия, проверки и стоимость.
- [Поручение для этапа D](docs/StageDPrompt.md) — следующий этап, без автоматического запуска.
- [Инструкции проекта](AGENTS.md) — изоляция симуляторов и ограничения действий.

Исходный архив, скриншот OpenUsage и справочный shell-скрипт сохранены локально и исключены из Git. Референс задаёт компактное окно, вертикальные карточки и раскрываемую детализацию; личные показатели скриншота не публикуются.

## Разработка

Swift 6, macOS 14+, без внешних Swift-зависимостей. Сборке нужен Swift toolchain; упакованное приложение не вызывает Swift, Xcode, probe или расширение Chrome.

```sh
python3 tools/package_app.py
open .local/StageC/Zapas.app
.local/StageC/Zapas.app/Contents/MacOS/zapas status --json
.local/StageC/Zapas.app/Contents/MacOS/zapas processes --sort memory --limit 20 --json
```

Обычный запуск создаёт значок `memorychip` в строке меню; нажмите его для окна шириной 420 pt. В окне — система, график swap/компрессора за 15 минут, группы приложений с процессами, отложенные интеграции и настройки. ⌘R обновляет, ⌘, открывает настройки, ⌘Q выходит. Запуск при входе по умолчанию выключен; регистрация `SMAppService.mainApp` происходит только при переключении пользователем. Локальная ad-hoc подпись не является проверенной подписью распространения или notarization.

Один actor собирает систему и процессы вне main actor: 3 с при видимом окне, в фоне только систему раз в 30 с. Хранятся текущий inventory и до 600 системных точек за 900 с, только в памяти. Sleep/wake сбрасывают baseline и отбрасывают старый сбор. Недоступные значения, ошибки обновления и устаревшие снимки различаются; занятость RAM не определяет pressure. Footprint групп частичный, RSS показан отдельно, точная RAM вкладок неизвестна.

CLI рядом с GUI обращается к его приватному Unix socket и тому же SamplingCoordinator. Без GUI `status/processes` выполняют конечный разовый сбор; первый swap interval неизвестен. Chrome требует запущенного GUI и явного opt-in расширения. IPC v1 C отделён от экспериментального probe A; публичный диагностический JSON v1 сохранён. MCP не реализован.

Проверки:

```sh
swift build --scratch-path .local/build
swift test --scratch-path .local/test-build
node --test chrome-extension/policy.test.mjs
python3 tools/test_cli.py --binary .local/StageC/Zapas.app/Contents/MacOS/zapas
zapas_bin_dir="$(swift build --scratch-path .local/build --show-bin-path)"
python3 tools/test_ipc.py --bin-dir "$zapas_bin_dir"
"$zapas_bin_dir/zapas-probe" system --samples 3 --interval 2
```

`ZapasCore` читает Mach/sysctl/libproc и simctl JSON. `zapas-probe` выдаёт экспериментальный JSON/NDJSON с источниками, единицами и причинами недоступности. Точная память вкладок Stable неизвестна: альтернативный MVP — давность активности и наблюдаемый суммарный footprint Chrome. Сумма процессных показателей не равна уникальной физической RAM.

## Chrome C

Production-расширение находится в `chrome-production/` и в `Zapas.app/Contents/Resources/chrome-extension`. Прототип A в `chrome-extension/` сохранён отдельно. Установка не выполняется при запуске приложения.

1. В Zapas → Chrome → «Подключение и защита» нажмите «Установить Native Messaging» и явно выберите **Chrome user-data directory** (родитель `Default`/`Profile N`, не сам `Default`). Для проверки используйте только изолированный каталог в `.local/`.
2. Загрузите папку production-расширения через `chrome://extensions` → Developer mode → Load unpacked. Публикация Chrome Web Store не выполнена.
3. Откройте страницу расширения, задайте метку профиля, нажмите «Подключить». Этот opt-in сохраняется только в данном профиле; «Отключить» прекращает reconnect.
4. В Zapas раскройте профиль, найдите нужное окно, найдите вкладки по названию/домену и выберите их вручную. Нажмите «Выгрузить…» или «Закрыть…» для preview, проверьте перечень и подтвердите соответствующее действие. Фильтры «Все / Доступные / Защищённые / Выгруженные / Выбранные» меняют только список; скрытые выбранные вкладки учитываются в счётчике и preview. «Снять выбор» очищает набор без действия.

Установка через CLI также явная: `zapas native install --user-data-dir /absolute/path --apply --json`. Создаётся host manifest `com.zapas.chrome.json`, executable/config в приватном runtime Zapas; рабочие настройки Chrome, профиль и его вкладки не меняются. Конфликт с чужой установкой не перезаписывается. Для тестов runtime задаётся `ZAPAS_RUNTIME=/absolute/path/in/.local/run`, обычный — `~/Library/Application Support/Zapas/run`. Удалить интеграцию можно отключением/удалением расширения и удалением собственного host manifest; полный uninstall CLI не добавлен.

Порог защиты недавней активности **10 минут для обоих действий**, утверждён пользователем 01.10.2026. Active в каждом окне, pinned, audible, incognito, неизвестная/будущая активность, переход, split view и исключения доменов блокируют действия. По умолчанию защищены exact hostnames `meet.google.com`, `teams.microsoft.com`, `app.zoom.us`, `web.whatsapp.com`; список редактируется пользователем в GUI отдельно для каждого opaque profile ID. Защита не умеет надёжно обнаруживать формы и все звонки. Выгрузка и закрытие могут потерять состояние страницы.

RAM вкладок неизвестна; список упорядочен по давности активности. После действия показываются `confirmed/failed/unknown` и частичный наблюдаемый footprint всей группы Chrome до/после, RSS отдельно. Изменение включает другие профили и не доказывает эффект одной вкладки. Preview одноразовый, 30 с; command 20 с, snapshot fresh 10 с. Reconnect/навигация/замена вкладки требуют нового выбора. Полный URL остаётся только в оперативном tracker расширения, не передаётся в диагностику; контент/формы/трафик не читаются.

```sh
node --test chrome-production/policy.test.mjs
python3 tools/test_ipc_c.py --binary "$zapas_bin_dir/zapas-native-host"
python3 tools/test_chrome_c.py --app .local/StageC/Zapas.app --run
```

Живой opt-in harness создаёт два новых профиля, собственные localhost-страницы и приватные CDP pipes; ждёт production-порог 10 минут, не подменяет его фикстурными 60 с. Browser debug port не открыт; CDP не используется продуктом. Harness отказывает при уже работающем Zapas, не завершает его. После теста закрывает свои Chrome через Browser.close; GUI оставляет для видимой проверки и штатного выхода. Все evidence/профили — только `.local/`. Симуляторы для C не нужны.
Для ручной проверки той же view без открытия значка есть явный тестовый режим: `.local/StageC/Zapas.app/Contents/MacOS/ZapasApp --qualification-window`. Добавление `--demo unknown` показывает подписанные синтетические состояния и тестовые переключатели темы/контраста; это не живые данные. Не запускайте второй экземпляр рядом с уже работающим Zapas. Реальные снимки и измерения сохраняйте только в игнорируемой `.local/`; обычное приложение не пишет диагностику на диск.

## Лицензия

[MIT](LICENSE). Исходный план подготовлен Василием Масловым 01.10.2026; авторство сохранено.
