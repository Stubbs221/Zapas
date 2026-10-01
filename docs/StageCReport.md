# Этап C — Chrome

Дата: 01–02.10.2026 (Asia/Almaty). База B: `1b1191f6a9293f9ca3ba92e5f992d27033ec8b35`. Реализован только C; D не запускался. Реализация и квалификация учитываются отдельно: остаются CPU FAIL и перечисленные NOT RUN. Исходные A-прототипы сохранены, рабочие Chrome-профили/вкладки не изменялись. Симуляторы не использовались.

## Реализация

- Отдельное production Manifest V3 расширение `chrome-production/` (0.3.0). A `chrome-extension/` остаётся экспериментальным. Permissions: tabs, nativeMessaging, storage (profile ID/consent/label), alarms (reconnect после остановки worker). Нет content scripts, host permissions, сбора форм/сетевого трафика или CDP в продукте. Incognito запрещён manifest и фильтруется; policy повторно защищает его.
- Установка Native Messaging явная: GUI с NSOpenPanel или `zapas native install --user-data-dir ABS --apply --json`. Выбирается корень Chrome user-data, не Default. Installer подготавливает приватный executable/config, затем публикует `NativeMessagingHosts/com.zapas.chrome.json`. Exact allowed_origin выведен из bundled extension key; foreign manifest/unsafe paths не заменяются. Не меняет Chrome preferences и не загружает расширение. Само подключение — отдельная кнопка расширения, consent хранится только в этом профиле. Полный uninstall CLI не реализован; отключение/удаление расширения и собственного manifest описаны в README.
- Host включён в `.app`; native origin проверяется до stdio loop. Version/request UUID/schema/1 MiB frames проверяются. Native host назначает неизменяемую session UUID, не принимает смену profile ID и разрешает только hello/publish/poll/result/disconnect. Extension channel не может ставить действия или диагностические команды в очередь. Session/service ID меняются при reconnect; profile ID сохраняется в storage.local. GUI различает профили, даже если tab ID совпадает; показывает отдельные window IDs и active-защиту каждого окна.
- `GUIService` actor и listener с отдельной serial utility queue для блокирующего I/O. Runtime 0700, socket 0600, same-UID peer; advisory lease исключает второй сервис. Restart восстанавливает только собственный private socket с ECONNREFUSED под lease; live socket, regular file и symlink не удаляются. Частичный frame ограничен общим deadline 3 с. Oversized reply выдаёт correlated structured error. Эта граница не изолирует от вредоносных программ того же UID.
- Один SamplingCoordinator B остаётся владельцем pressure, baseline, расписания, history и сбора. CLI при существующем GUI socket обращается к нему; без socket status/processes выполняют только один конечный сбор. При существующем неисправном socket не обходят отказ отдельным sampler. GUI работает без расширения; отсутствие host/extension не ломает системные метрики. Sleep сбрасывает Chrome sessions/plans и делает pending results unknown; реальные sleep/wake ещё NOT RUN.
- GUI: поиск по названию/домену, пять фильтров (только отображение, без изменения выбранного набора), счётчик скрытых выбранных вкладок, снятие выбора без действий, раскрываемые профили, группировка по window ID, название/домен, состояние, давность активности, ручной выбор, exact-domain исключения, separate preview и confirmation discard/close, отмена, фактический result. Выбор generation-scoped, исчезнувшие/сменившие session/token объекты снимаются. Изменение исключений инвалидирует preview; правила загружаются до первого handshake. Исключения — пользовательские настройки, история/URL на диск не пишутся.
- Порог недавней активности **600 с для обоих действий** явно утверждён пользователем в этом этапе. Исследовательские 60 с A не используются. Защищены active каждого окна, pinned, audible, incognito, pending navigation/split view, неизвестная/будущая активность, неизвестный domain и exact-domain exceptions. По умолчанию защищены meet.google.com, teams.microsoft.com, app.zoom.us, web.whatsapp.com; пользователь может редактировать их. Forms/calls полностью обнаружить нельзя, риск потери состояния показан в preview.
- Preview: 1...100 явно выбранных уникальных `{profileID,sessionID,tabID,token}`, exact expected snapshot, одноразовая UUID, срок 30 с; свежесть snapshot 10 с. Core проверяет перед apply и delivery, extension заново читает tab непосредственно перед explicit ID API и проверяет deadline/connection identity. Command lease 20 с. Ни расширение, ни broker не расширяют выбранный набор и не повторяют отправленную команду после reconnect.
- `confirmed` определяется состоянием: discard response + повторный tabs.get, full in-memory URL/window identity, onReplaced lineage при новом ID и discarded=true; close API + onRemoved generation + фактическое отсутствие ID. До вызова отказ — failed; после отправки без достоверного подтверждения — unknown. EOF/session replacement/timeout не превращаются в успех или гарантированное «ничего не произошло». Result immutable. Замена ID/навигация обнуляет прежний выбор; восстановление страницы наблюдается отдельно.
- Полный URL остаётся только в volatile tracker расширения для identity checks; в диагностику уходят domain/санитизированный title и state. URL в title маскируется; result.issue содержит только коды. Forms/private traffic не читаются. Точная RAM вкладок неизвестна; сортировка только по давности активности. Partial group footprint Chrome до/после получают через тот же coordinator, RSS отдельно; группа включает все профили, delta не является атрибуцией эффекта выбранной вкладке. Неизвестные метрики/coverage не подменяются нулём. Серия замеров эффекта/рекомендации E не добавлены.
- Bounds: 32 profiles × 2000 tabs, 64 previews, 256 commands, 128 batches × 100 targets; result retention 900 с. Frames также ограничивают размер. Последний inventory и история системы сохраняют лимиты B (10000 processes, 600 points/900 с), только память. Exponential reconnect до 30 с + alarm, остановка reconnect при explicit disconnect. Снимок, превышающий 1 MiB, — ошибка, не успешное пустое состояние.

## UI skills

По явному поручению пользователя применены `emil-design-eng`, `apple-design`, `write-swift` из [emilkowalski/skills](https://github.com/emilkowalski/skills). `emil-design-eng` установлен через skill-installer; repo main при загрузке: `d16ebe60d09a5ba2afcb7054ede9d0a10c9f6128`. Skills — инструкции разработки, не runtime dependency, в приложение не встраиваются.

| Before | After | Why |
| --- | --- | --- |
| Длинный плоский список | Поиск title/domain, фильтры, группы окон | Найти конкретную вкладку без автоматического выбора |
| Доменные настройки занимают список | Disclosure исключений и подключения | Главный сценарий остаётся видимым |
| Выбор не объясняет скрытые строки | Счётчик скрытых выбранных + точный preview | Фильтр не скрывает состав действия |
| Длинные строки и всегда видимые пояснения | Компактные строки, бейджи защиты/связи, панель выбора и две разные кнопки preview | Набор действий понятен и помещается в компактное окно |
| Однородная HTML инструкция | Карточки подключения, focus-visible, системные light/dark цвета, responsive layout | Явная установка и доступность |
| Int conversion большого timestamp | Nullable проверенная давность без Int trap | Повреждённая/будущая активность остаётся неизвестной |

SwiftUI сохраняет нативный feedback/keyboard, без декоративной анимации периодических замеров. Extension control button press ограничен transform 140 мс, отключён при reduced motion. Полная OS accessibility-квалификация остаётся NOT RUN.

Отдельный final smoke harness проверяет bundled control page, маскирование custom URL схем в profile label/title, собственный IPv6 hostname как unknown (не отказ всего profile snapshot) и системную диагностику через тот же GUI. Unicode label ограничен 200 UTF-8 bytes без разрыва surrogate pairs. Неподдерживаемые non-DNS hostnames не разрешают действия.

## Воспроизведение

```sh
swift build --scratch-path .local/build
swift test --scratch-path .local/test-build
node --test chrome-extension/policy.test.mjs chrome-production/policy.test.mjs
python3 tools/package_app.py
zapas_bin_dir="$(swift build --scratch-path .local/build --show-bin-path)"
python3 tools/test_ipc.py --bin-dir "$zapas_bin_dir"
python3 tools/test_ipc_c.py --binary .local/StageC/Zapas.app/Contents/MacOS/zapas-native-host
python3 tools/test_cli.py --binary .local/StageC/Zapas.app/Contents/MacOS/zapas
python3 tools/test_chrome_c.py --app .local/StageC/Zapas.app --run
python3 tools/test_chrome_c_ui.py --app .local/StageC/Zapas.app --run
```

SwiftPM в agent sandbox не смог запустить manifest compiler; сборки/IPC выполнены с разрешённым escalated запуском, compiler artifacts в `.local/`. macOS/UI checks также требуют нормального пользовательского контекста, не root. Нет внешних Swift/JS/Python dependencies. `--output` внутри `.local/` позволяет не заменять работающую сборку: компактный UI и его стоимость проверены на `.local/StageC-polish/Zapas.app`; окончательный пакет `.local/StageC/Zapas.app` повторно прошёл IPC, CLI, privacy smoke и видимую проверку без расширения. Ad-hoc codesign, Developer ID/notarization/распространение через Chrome Web Store не квалифицированы.

Live harness создают fresh user-data-dir в `.local/`, собственные localhost pages и приватный CDP pipe. Сетевого debug port нет; флаг unsafe-extension-debugging нужен только для загрузки собственного unpacked. Основная проверка ждёт фактические production 600 с, тестирует два профиля/окна и exact-selected действия, закрывает только собственные Chrome через Browser.close. UI harness ждёт реальной давности вкладок, требует ручных GUI actions и нормального Exit для service restart. Загрузка control page проверяется по фактическому URL, complete и доступности extension API; один readyState пустой страницы недостаточен. `test_chrome_c_smoke.py --app .local/StageC/Zapas.app --runtime <собственный .local runtime>/run --run` требует уже запущенного тестового GUI и не выполняет действий с вкладками. Offline CLI fixture использует отдельный временный runtime, чтобы работающий GUI не менял исходный baseline теста. Нет kill, принудительного browser restart, управления Simulator/LLDB/Charles. GUI остаётся для видимой проверки и штатного выхода; перед запуском action harness отказывается от второго Zapas.

## Проверки

Среда: arm64, macOS 27.0.1 (26A434), Apple Swift 6.4 language mode 6, deployment macOS 14; Chrome Stable 154.0.8037.92, Node 24.1.0, Python 3.13.4. App/extension 0.3.0, app build 3. Реальное выполнение на macOS 14 не проверено.

| Проверка | Статус | Методика / предел |
| --- | --- | --- |
| Swift debug build/test | PASS | 57 Swift Testing functions: 34 A/B + 23 C; policy, boundary 600 с, state/session/token/window/activity changes, preview-only/single-use, fresh delivery, immutable results, unknown timeout/EOF/sleep, startup exclusions, exact selection, privacy, bounds/errors, same coordinator, group null/RSS, exclusive/stale socket and unsafe-file preservation, install conflict, dangling symlink preservation для manifest/binary/config, oversized reply |
| Release package / strict local codesign | PASS | Окончательный пакет 0.3.0: GUI, CLI, host и production extension в .app; установка проверяет regular-file/current-UID до замены native файлов |
| JS A + C / syntax | PASS | 25 A + 30 C; fresh flags/navigation/reused ID, connection/expiry, exact single ID, replacement lineage, state confirmation, close absence, private fields/redacted errors |
| IPC A | PASS | 13 прежних real-process checks на C, без изменения A scope |
| Production Native host IPC C | PASS | 4 real-process checks: origin, запрещённое enqueue, immutable profile/native session stamping, разные host sessions, EOF, wrong version/UUID, unavailable service |
| Offline CLI JSON v1 | PASS | 7 проверок, прежние mandatory null/units/sources/errors/exit codes и явная новая справка |
| CLI рядом с GUI | PASS | Реальные status/processes через приватный C socket, limit 3, schemaVersion=1, partial ошибки сохранены; coordinator trace. Unit test подтверждает injected owner без отдельного sampler |
| Живой Chrome, два fresh profiles/окна | PASS | 17 checks: missing host error, explicit install/reinstall, sessions, active каждого окна, pinned/recent, changed preview, selected discard/close actual state, unselected other profile, reload heap, worker stop/reconnect, old session refusal, uninstall/load and explicit disconnect/reconnect |
| Uninstall/load | PASS с пределом | Реальная выгрузка extension/host connection и reload; новая регистрация после полного uninstall не выдаётся за сохранённый opt-in. Остановка worker и disconnect/reconnect отдельно подтверждены |
| Видимый native UI и exceptions | PASS | Screenshot + AX, реальные профили/window IDs, protected controls, own domain add/remove. Не вывод по PID |
| GUI selection/preview/cancel/confirm и normal service restart | PASS | Повторено с компактным UI: ручные native controls, фактические discarded/absence, service/session сменились после обычного Exit, прежний выбор отвергнут. Поиск/скрытый выбор проверены в предыдущем прогоне той же модели; exact-domain add/remove проверены в компактном UI |
| Final packaged extension/privacy smoke | PASS | 5 live checks на собственной IPv6 странице в третьем fresh profile, без действий с вкладками |
| Окончательный UI без расширения | PASS | Видимое окно + AX + screenshot: «Нет связи», системные метрики и история доступны; тестовый GUI закрыт кнопкой «Выход», отсутствие процесса проверено |
| Live incognito/audio production C | NOT RUN / unit PASS | Incognito запрещён и фильтруется; audible/unknown/pinned/fresh protection проверены C units. Живой audio A не переносится в production C PASS |
| macOS 14 / Intel / физический sleep-wake / pressure event | NOT RUN | Swift target и injected reset не заменяют реальную ОС |
| Полный VoiceOver / OS contrast/motion / login-relogin | NOT RUN | Native labels/disabled controls и новые context menus наблюдались; полноценные пользовательские сессии и регистрация не выполнялись |
| Именно MenuBarExtra / latency ~200 мс | NOT RUN | Qualification window той же view не заменяет status-item click-to-visible |
| LLDB / Charles | NOT RUN | LLDB отложен пользователем; Charles не квалифицирован, control не добавлен |

Сырые данные, профили, trace, screenshots и sample — только `.local/`. В публичном отчёте нет actual profile/session/tab IDs, PID или адресов пользовательских вкладок. Работающий Zapas B закрыт штатным Exit после явного разрешения пользователя. После Exit собственный тестовый C был автоматически перезапущен UI-инструментом при последующем чтении состояния, что лишило инструмент видимого окна; пользователь закрыл его штатно. После повторного auto-launch пользователь прямо поручил агенту закрыть свой экземпляр самостоятельно: отправлен обычный macOS Quit через NSRunningApplication.terminate, с повторной libproc PID/start/UUID/path проверкой. Это локальный test-only helper в .local, не API продукта, без сигналов/forceTerminate. Дополнительный постоянный монитор не запускался, процессы не завершались принудительно. В последней проверке после Exit не читать closed app UI, чтобы не воспроизвести auto-launch.

## Стоимость и оставшаяся приёмка

`tools/measure_app.py`: proc_pid_rusage.RUSAGE_INFO_V0, PID/start/UUID identity, footprint/RSS отдельно, выборка раз в 5 с, CPU delta Mach ticks × timebase / wall duration, процент одного ядра. B sample указывал на SwiftUI diff/layout; в C stale clock сокращён с 1 до 3 с. C sample также показывает SwiftUI layout/render. Это statistical sample, не строгая атрибуция причин CPU.

Первое прогретое открытое qualification window C с двумя профилями и UI взаимодействиями: 300,005 с, footprint 35,915–42,747 decimal MB, CPU 1,07296% — **PASS footprint, FAIL CPU <1%**. B 1,386% остаётся историческим FAIL и не превращается в PASS. Первоначальный финальный cost interval включил автоматическое открытие qualification window, поэтому не используется как доказательство чистых пяти минут фона.

Чистый скрытый фон C с подключённым расширением: 300,010 с, footprint 39,962–40,715 decimal MB, CPU 0,23358% — PASS для этого режима. Trace подтверждает visible=false/detailed=false на всём интервале; process inventory не обновляется. Открытый GUI с ручными preview/discard/close: 60,002 с, footprint 54,003–56,084 decimal MB, CPU 1,73633% — PASS footprint, FAIL CPU. Эти значения относятся к сборке до финальной доработки UI; повторная стоимость финальной сборки приводится отдельно. MenuBarExtra/latency, минимальная ОС, физический sleep/wake, VoiceOver и login/relogin не выполнены; Charles/LLDB зависимости не квалифицированы. C не объявляется полностью принятым, даже при пройденных независимых Chrome/IPC checks.

После первой доработки поиск/группировка: pure background 300,009 с, footprint 18,023–18,187 MB, CPU 0,27585% — PASS; открытая карточка с поиском 120,002 с, footprint 43,140–45,598 MB, CPU 1,21510% — FAIL CPU. Окончательная компактная карточка: чистый скрытый фон 300,006 с, footprint 51,103–52,102 MB, CPU 0,23250% — PASS. Открытый прогретый UI с профилем/поиском 120,003 с, footprint 51,398–54,429 MB, CPU 1,15238% — PASS footprint, FAIL CPU. Trace на всём фоне detailed=false и process inventory неизменен. Исторические FAIL не удаляются.

## Передача

Следующий этап — D, [StageDPrompt.md](StageDPrompt.md). Он не начат автоматически. Его независимые UI/contracts/tests разрешено реализовывать после отдельного поручения; зависимые действия Simulator/LLDB требуют свежего назначения/identity/evidence и соблюдения открытых критериев, не эвристического переноса NOT RUN в PASS.

API сверены при реализации: [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [tabs](https://developer.chrome.com/docs/extensions/reference/api/tabs), [worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle). Продукт не использует Chrome processes Dev-channel API для оценки вкладочной RAM.
