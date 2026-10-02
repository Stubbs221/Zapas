# Отчёт этапа D — Simulator и LLDB

Дата: **02.10.2026**, Asia/Almaty. База `main` C: `70998aee014c8751c4844c02cebc0b20cdd75980`; исходное дерево чистое. Реализованы Simulator discovery/ручной preview/apply/result, GUI/CLI и read-only LLDB evidence/защитный контракт. **Живое завершение LLDB не реализовано как доступное действие:** backend намеренно заблокирован до отдельно разрешённой квалификации и получения надёжного evidence источника. D не объявляется полностью принятым. E не начат.

## Среда и методика

macOS 27.0.1 (26A434), arm64; Xcode 27.1 (27A9269); Apple Swift 6.4 (swiftlang-6.4.0.34.1), language mode Swift 6, deployment macOS 14. Node 24.1.0, Python 3.13.4. App 0.4.0/build 4, bundled production Chrome extension C остаётся 0.3.0. Реальное выполнение на macOS 14/Intel — NOT RUN. Ad-hoc codesign с strict verify, не Developer ID/notarization.

SwiftPM manifest compiler и CoreSimulatorService в agent sandbox были недоступны; build/test, IPC и живые read/action проверки выполнялись с разрешённой эскалацией, без root. Это не маскируется нулевыми значениями. `DEVELOPER_DIR` на пустой локальный каталог проверяет Xcode-unavailable, не меняет xcode-select. Установленный Chrome Stable 154.0.8037.92 проверен чтением Info.plist без открытия рабочих профилей. Источники simctl сверены по установленному `xcrun simctl help shutdown`; аргументы fixed, JSON читается для всех runtimes, `all`/`booted` не используются в shutdown.

Все реальные назначения, inventory, PID/start identity, trace, измерения и harness evidence — только игнорируемая `.local/results/stage-d/` и `.local/simulator-assignment.json`. Публичные документы не содержат actual UDID/PID, пути CoreSimulator, имена чужих устройств, browser IDs или рабочий трафик. UI наблюдался через native AX и изображения инструмента; screenshots в Git не сохранялись. В инструментах тестирования есть только синтетические идентификаторы; обычный продукт не пишет diagnostics/history на диск.

## Реализация и ограничения

- `ZapasCore/SimulatorActions.swift`: весь inventory с name/runtime/UDID/state/availability/явным assignment. Принадлежность по имени и Booted не выводится. Legacy A `{project,udids}` читается, но не разрешает действие: D требует `bindings` udid/runtime/dataPath/incarnation. Incarnation — lstat dev/inode/birthtime каталога устройства с nanoseconds и владельцем текущего пользователя. Это локальный trust boundary, не криптографическая подпись и не гарантия против одновременной внешней модификации между последней проверкой и запуском simctl. UDID/runtime/path/назначение проверяются заново, переиспользование каталога иной incarnation блокируется. Продукт не создаёт/удаляет/erase/boot устройства и не переназначает их. Для теста существующее назначение A было дополнено pinned binding после полной инвентаризации; backup A сохранён только локально.
- `SimulatorDiagnostics.associate`: executable только внутри конкретного dataPath, с границей пути и нормализацией `..`. Неоднозначность и generic CoreSimulator/Simulator helpers остаются неизвестными. Current-user inventory частичный; процессы из runtime вне dataPath не приписываются даже единственному Booted-устройству. Пустая группа не доказывает отсутствия apps/debugging. Сохраняются process failures, timestamps, footprint и RSS отдельно; нет суммы «уникальная физическая RAM».
- `DevelopmentActions`: один actor для on-demand discovery и одноразовых plans/results, без второго sampling loop. Перед командой fresh полный inventory + assignment/identity/runtime/state; backend повторяет проверку и expiry непосредственно перед fixed `xcrun simctl shutdown <UUID>`. До доставки отказ — failed; после возможной доставки timeout/ошибка/исчезновение/смена identity — unknown, без replay. После успешной доставки проверяется именно выбранное устройство: Shutdown с той же identity — confirmed; Booted — failed; переход/неизвестность — unknown. Уже Shutdown — отдельное confirmed с `device_already_shutdown`, команд нет. Apply требует explicit flag и matching action kind. План потребляется до исполнения, живёт 30 с; до 64 планов и 128 результатов/900 с только в памяти. Sleep/смена выбранного файла назначения инвалидируют планы; параллельное действие блокируется. Нельзя расширить набор на helpers или другое устройство.
- `DebuggerDiagnostics`: объяснимые libproc PID/start/UID, observed parent/children и причины неизвестности. PPID=1 — candidate; name/footprint не превращают его в proven orphan. Live activity всегда unknown/qualified=false, включая отсутствие Xcode в наблюдаемом списке. Partial inventory не является отрицательным доказательством отсутствия отладки. Клиент передаёт только selected process.identity, не trusted proof. Preview/apply повторно проверяют PID/start/current UID, свежесть ≤2 с и inactive/proven/qualified evidence, но live backend **не отправляет сигналов**. Trusted sources доступны только внутренним injected tests. Для включения завершения нужны отдельное явное разрешение пользователя, test Run/breakpoint/Stop/exit данные, надёжный источник доказательств и завершённый безопасный backend. Свежая libproc проверка сама по себе не устраняет race между проверкой PID и сигналом; этот вопрос не закрыт фикстурами.
- `GUIService` передаёт D тот же `SamplingCoordinator`. `ServiceRequest/Reply` и публичный envelope/metrics v1 расширены optional D полями; Chrome C policy/session/profile/tab identity и leases не менялись. Native extension channel по-прежнему не может enqueue действия D. Socket read deadline только D discovery/apply — 45 с для конечных операций; C deadlines прежние. Simctl list timeout 5 с, shutdown 10 с. CLI рядом с GUI только его сервис, без fallback monitor при недоступном существующем socket. Без GUI list — один конечный сбор; preview/apply/result требуют живого GUI.
- `DevelopmentModel/View`: раскрываемая компактная карточка, обновление только по запросу, без simctl polling и D background timers. Ручной выбор одного доступного pinned Zapas iOS-устройства; чужие/unknown/unavailable/tvOS disabled. Preview показывает точные runtime/UDID/state, возможную потерю состояния и неизвестность debugger/helpers. Отмена не действует. Список — снимок со временем; «Обновить список» заново читает фактическое состояние. После apply GUI разово обновляет список, сохраняя результат; регулярный D-монитор не запускается. LLDB неизвестность блокирует GUI кнопку; shared core независимо закрывает действие.

Сохранены Swift 6/macOS 14+, core без default main-actor isolation, единственный SamplingCoordinator, bounded system history 600 точек/900 с в памяти, процессы до 10000, Unix socket/peer UID boundary и JSON v1 mandatory null. Системные метрики независимы от Xcode/Chrome. Production Chrome C не менялся: ручной выбор, preview/apply, activity 600 с для discard и close, exclusions и identity. Рабочие вкладки/профили не использовались. Charles control, рекомендации, автоматические правила, MCP и E/F не добавлены.

## UI skills

Применены установленные `emil-design-eng`, `apple-design`, `write-swift`: native controls/feedback, явная близость выбора и действия, доступные labels, platform colors, без декоративной анимации sampling/keyboard. Skills не являются runtime зависимостями.

| Before | After | Why |
| --- | --- | --- |
| «Simulator и LLDB отложены» | Раскрываемая on-demand карточка | Сохраняет компактность и стоимость фона |
| Устройство определяется UDID из A | Показ runtime/UDID/state/availability + pinned assignment | Booted/имя не дают права действовать |
| Общие helpers могли казаться группой устройства | Отдельный unknown список | Честная граница доказательств dataPath |
| Нет воздействия/результата | Exact selection, preview/cancel/explicit apply, confirmed/failed/unknown | Пользователь видит объект и риск перед действием |
| PPID=1 только краткий кандидат | Развёрнутые evidence и disabled действие | Неизвестная отладка остаётся защищённой |
| Английское пояснение в первой D preview | Русское пояснение частичной группировки/неизвестности | Убрано противоречие в already-Shutdown preview |

## Проверки

| Проверка | Статус | Доказательства / предел |
| --- | --- | --- |
| Swift debug build / Swift Testing | PASS | 73 функции: прежние 57 A–C + 16 D, включая параметризованные device/debugger сценарии; final rebuild/retest после русских пояснений |
| D safety tests | PASS | Runtime/dataPath/incarnation reuse, foreign/unknown assignment, unavailable/tvOS/state changes, исчезновение, no-command Shutdown, single-use, wrong-kind/explicit apply, expiry, suspend, 900 с retention, missing Xcode, path boundary/traversal, active/unknown debug, fresh identity/owner, post-action confirmed/failed/unknown/PID reuse; proof только injected fixtures |
| Release package / codesign strict | PASS | Final 0.4.0, GUI/CLI/host + неизменное C extension |
| JS A/C | PASS | 55 tests (25 A + 30 C); safety/privacy/state/session policies; JS файлы не менялись |
| IPC A / host C | PASS | 13 real-process A и 5 C/D; C повторён packaged host, дополнительный D test подтверждает отказ extension channel читать/вызывать development operations |
| CLI v1/C regression | PASS | 7 offline contract checks, повторены final bundled CLI; обязательные null/units/errors/exit codes сохранены |
| CLI D fixture peer | PASS | 5 real-process tests: GUI wire, group list, explicit apply/UUID, wrong-kind binding, selected start identity, invalid/repeated/shell options; final bundled CLI повторён |
| CLI рядом с GUI | PASS | status/processes(limit 3)/debuggers и Simulator через собственный runtime/socket; v1 data, partial failures и service coordinator trace сохранены |
| Xcode unavailable / system independent | PASS | Empty local DEVELOPER_DIR → `simctl_unavailable`/null, status v1 продолжает отдавать system payload; Chrome extension не подключён |
| Полная инвентаризация / assignment | PASS | Всего 7 ≤8 до/после. Existing assigned Zapas iOS, bindings совпадают; новые устройства/удаления не выполнялись |
| Already Shutdown через D CLI | PASS | Preview только exact selected object, missing --apply и wrong-kind refused, confirmed/already_shutdown без command, result immutable, reuse refused; 7 live checks; повтор final package |
| Booted → Shutdown через GUI | PASS | Свежий full inventory до boot только своего устройства; native selected-device preview/explicit button apply → confirmed; независимый simctl после → Shutdown. Последние expiry/refresh правки повторены в exact StageD-verified GUI: automatic refresh → Shutdown. Остальные 6 устройств неизменны |
| Booted → Shutdown через CLI | PASS | Opt-in `test_simulator_d.py`, existing own selected UDID, full inventory before/after, preview/apply/result/replay refusal; 7 live checks. Harness сам не boot/install/launch/erase устройства |
| Видимый финальный GUI | PASS с пределом | Exact StageD path через LaunchServices, AX/изображения: foreign selection disabled, assigned Booted selectable, русская preview, confirmed, updated Shutdown и Chrome disconnected/system available. Qualification window, не MenuBarExtra latency |
| Живое дерево приложений device/dataPath | NOT RUN | Fixture path grouping PASS. Устройство booted без установки тестового iOS app; многие runtime helpers корректно остались unknown. Полную живую атрибуцию apps/debugging не заявляем |
| Live device disappearance/runtime/ownership mutation | NOT RUN | Защитные injected tests PASS; реальные удаления/переназначения и чужие устройства не используются |
| Live LLDB Run/breakpoint/Stop/exit и завершение | NOT RUN — отложено пользователем | Тестовая Xcode-сессия не запускалась, доказательства inactive/proven не получены, termination backend отключён. Contract fixture PASS не квалификация live |
| Live Chrome actions повтор в D | NOT RUN | C historical live PASS сохранён; D повторяет JS/Swift/IPC/CLI C, рабочие вкладки не трогает |
| MenuBarExtra / ~200 мс latency | NOT RUN | Qualification window не доказывает status-item click-to-visible |
| macOS 14 / Intel / реальный sleep-wake / pressure events | NOT RUN | Target и injected suspend/reset не заменяют реальные ОС события |
| Полный VoiceOver / OS contrast-motion / login-relogin | NOT RUN | Native AX/labels/disabled states не полная accessibility/login сессия |
| Charles | NOT RUN | Не квалифицирован, control не добавлен |

Первое чтение UI после прямого запуска финальной GUI-копии привело к timeouts/автоматическому запуску без qualification args. Обращение по display name дополнительно запустило старую локальную qualification-копию; сценарий отброшен, его данные не используются как стоимость/видимый final UI. Guard при cleanup отказал на несовпадающем path, никаких сигналов на этом шаге не отправлено. Затем только вызванная этим UI-инструментом старая локальная копия завершена одним SIGTERM после свежего exact executable/PID/start/UUID/UID check; force kill и другие приложения не использовались. Это local test cleanup, не API продукта. Надёжные запуски exact StageD и последней StageD-verified копии выполнены через LaunchServices с exact .local/StageD path и explicit runtime/assignment/qualification args; UI подтверждён отдельно. Hidden GUI Quit через UI-инструмент также завершился timeout. Только собственный измеренный тестовый PID StageD был убран одним SIGTERM после сверки с сохранёнными cost start/UUID, exact path и UID; без force kill. Последнюю исправленную копию запускают только после отсутствия первого процесса. Последняя скрытая StageD-verified test-копия после фонового замера завершена таким же identity-checked SIGTERM, поскольку UI-инструмент не умеет вернуть скрытое qualification window для штатного Quit. Это cleanup собственных qualification процессов, не публичная функция. После выхода не читать closed app UI, чтобы не вызвать auto-launch.

## Стоимость и открытая приёмка

`tools/measure_app.py`: proc_pid_rusage.RUSAGE_INFO_V0, стабильные PID/start/UUID, выборка 5 с, Mach CPU ticks × timebase 125/3 / wall duration, процент одного ядра. Footprint и RSS в raw snapshots раздельны; RSS к footprint не прибавляется. Decimal MB, не MiB. Первое открытое qualification window измерено 300 с при независимых D UI/CLI действиях и boot/shutdown только своего устройства, без Chrome extension/Xcode. После последних expiry/refresh правок повторены open GUI 120 с и прогретый скрытый фон 300 с на exact StageD-verified build; open interval также включает native D действия. Это стоимость этих сценариев, не steady-state idle popover и не атрибуция CPU только D.

| Режим | Время | Footprint, MB | CPU одного ядра | Статус |
| --- | --- | --- | --- | --- |
| GUI до последних expiry/refresh правок с квалификацией D | 300,003 с | 36,832–49,153 | 2,07258% | PASS <100 MB; FAIL <1% |
| Прогретый скрытый фон до последних правок | 300,004 с | 47,433–48,072 | 0,09910% | PASS footprint/CPU, detailed=false |
| Исправленный final GUI с повторной квалификацией D | 120,005 с | 35,587–49,792 | 3,34733% | PASS <100 MB; FAIL <1% |
| Исправленный final прогретый скрытый фон | 300,009 с | 48,891–49,989 | 0,10800% | PASS footprint <100 MB / CPU <1%; trace detailed=false |
| Именно MenuBarExtra / latency | — | — | — | NOT RUN |

Первичный холодный фон до русских пояснений: 300,003 с, CPU 0,10896%, maximum footprint 18,023 MB; interval включал startup и не является проверкой прогретой финальной сборки. Последний исправленный final background квалифицируется отдельно с реальным Hide и trace detailed=false/processMeasuredAt неизменен, без CLI запросов/чтения UI в интервале.

**Открытые исторические критерии сохраняются:** B открытый UI CPU 1,386% — FAIL; C финальный открытый UI CPU 1,15238% — FAIL. Новый D замер не закрывает B/C. MenuBarExtra/latency, macOS 14, физический sleep/wake, полный VoiceOver и login/relogin — NOT RUN. LLDB отложен; Charles не квалифицирован. Производительный фон не превращает CPU открытого окна или минимальную ОС в PASS. Дальнейшая квалификация должна измерять именно нужный режим и фиксировать новые доказательства; UI стоимость остаётся blocker полной приёмки.

## Воспроизведение и передача

```sh
swift build --scratch-path .local/build
swift test --scratch-path .local/test-build
node --test chrome-extension/policy.test.mjs chrome-production/policy.test.mjs
python3 tools/package_app.py
zapas_bin_dir="$(swift build --scratch-path .local/build --show-bin-path)"
python3 tools/test_ipc.py --bin-dir "$zapas_bin_dir"
python3 tools/test_ipc_c.py --binary .local/StageD/Zapas.app/Contents/MacOS/zapas-native-host
python3 tools/test_cli.py --binary .local/StageD/Zapas.app/Contents/MacOS/zapas
python3 tools/test_cli_d.py --binary .local/StageD/Zapas.app/Contents/MacOS/zapas
```

После финального review добавлены lease check после последнего backend discovery и одноразовый refresh GUI списка после apply; build/test и реальная GUI-сессия повторены на `.local/StageD-verified/Zapas.app`. Измерения прежней D-копии не заменяют новые final интервалы.

GUI/action tests требуют своего уже работающего Zapas с runtime в `.local/`, existing pinned assignment, full inventory и ручного выбора; не запускать второй монитор. Для инструментальной квалификации запускайте exact app path через LaunchServices, например `open -a /absolute/path/.local/StageD/Zapas.app --env ZAPAS_RUNTIME=/absolute/path/.local/run --env ZAPAS_EPHEMERAL=1 --env ZAPAS_SIMULATOR_ASSIGNMENT=/absolute/path/.local/simulator-assignment.json --args --qualification-window-after 5 --qualification-output /absolute/path/.local/trace.ndjson`. Перед этим проверить отсутствие Zapas; `-n` не использовать рядом с существующим экземпляром. Новые real evidence только `.local/`. `test_simulator_d.py --app … --runtime … --udid <вручную выбранный assigned UDID> --output <.local/file.json> --run` выключает только этот device; boot/preparation отдельны и тоже требуют полного inventory. Никакой LLDB Run/Stop квалификации без отдельного явного разрешения.

Следующий этап по плану — **E, рекомендации и эффект**. Независимые effect/history/contracts/UI допускаются после отдельного поручения, но не опираются на unqualified LLDB/Charles и не расширяют Simulator/Chrome права. Нужно сначала перепроверить FAIL/NOT RUN B/C/D до зависимой квалификации. Подготовка поручения E не является запуском E и не закрывает D blockers. Финальная передача содержит проверенный опубликованный GitHub SHA и полный copy-ready prompt только для E.

Финальный diff/check-ignore/privacy scan — PASS: actual simulator IDs и dataPaths отсутствуют в публикуемых Sources/Tests/docs/tools, `.local/` не tracked. Исходные референсы и существующие B/C отчёты сохранены. Публикация — один русский коммит в main без force push; точный SHA проверяется в remote и приводится в финальной передаче (самоссылка SHA в этом же коммите невозможна).
