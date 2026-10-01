# Этап B — оболочка и диагностика

Дата: 01.10.2026. Реализован только B, C не запускался. Реализация есть; полная приёмка зависит от оставшейся квалификации ниже. Исходные A-прототипы сохранены, без новых действий Chrome/LLDB/Charles/Simulator, MCP, рекомендаций или автоматических правил. Симуляторы не использовались.

## Реализация

- SwiftPM products `ZapasApp` и `zapas`, Swift 6, минимум macOS 14, без внешних Swift-зависимостей. `tools/package_app.py` воспроизводимо собирает release `.local/StageB/Zapas.app`, вкладывает CLI, Info.plist, About.txt и проверяет локальную ad-hoc подпись. GUI executable называется `ZapasApp`: `Zapas`/`zapas` конфликтуют на case-insensitive файловой системе.
- SwiftUI `MenuBarExtra(.window)`, нейтральный `memorychip`, необязательная подпись pressure. Русское окно 420 pt, высота до 660 pt с ограничением экраном и прокруткой. Вертикальные карточки по локальному OpenUsage: система, история, приложения, отложенные интеграции, настройки. Референс и личные данные не включены в Git.
- Система: pressure, physical RAM, wired, физический compressor, swap used/total, read/write rates. Unknown pressure не выводится из занятости RAM. Группы по внешнему `.app` executable path, остальные процессы отдельно; сортировка footprint, unknown последними. Детали содержат coverage, PID, footprint и RSS отдельно. Неатрибутируемые ошибки inventory показаны отдельно; сумма footprint не является уникальной физической RAM или памятью вкладок.
- График swap/compressor за 15 минут, GiB, подписи осей и легенда, swap пунктиром, текстовая accessibility-сводка. Unknown, пропуски и reset разрывают линии. График рисует небольшой AppKit view через NSBezierPath без Swift Charts/Canvas. Строки процессов создаются только при раскрытии группы.
- `SamplingCoordinator` actor владеет observer, baseline, кадром, расписанием, историей и единственным in-flight сбором. Системные API/libproc и группировка вне main actor; UI получает Sendable-кадр и bufferingNewest(1). Фактическое AppKit window visibility/occlusion задаёт режим: система+процессы 3 с, фон только система 30 с. Повторные refresh объединяются, detailed-запрос во время фонового сбора получает один последовательный follow-up. История только в памяти, максимум 600 точек и 900 с; inventory текущий, до 10000 строк. URL не собираются оболочкой.
- Workspace sleep/wake останавливает расписание, сбрасывает baseline и epoch, старый результат отбрасывается; первый wake interval неизвестен. Полный отказ обновления сохраняет последний успешный снимок с временем и отдельной ошибкой. Unknown-поле остаётся unknown. System stale после двух интервалов режима, processes после 6 с.
- Настройки подписи и `SMAppService.mainApp`; регистрация только по переключению пользователя. Новый запуск при входе выключен. Ошибка регистрации и `requiresApproval` показаны явно. ⌘R/⌘,/⌘Q, системные шрифты/semantic colors, accessibility labels и текст вместо цветового единственного сигнала; нет переходов, зависящих от motion.
- Отдельный CLI JSON v1: `status --json`, `processes --sort memory --limit N --json` (20, 1–10000), конечный разовый coordinator, первый interval неизвестен. Envelope/метрики/nullable/error codes/единицы описаны в [CLI.md](CLI.md). Коды 0/1/2; публичный контракт не закрепляет экспериментальную схему probe. Постоянный GUI IPC lifecycle — C.

## Воспроизведение

```sh
python3 tools/package_app.py
open .local/StageB/Zapas.app
.local/StageB/Zapas.app/Contents/MacOS/zapas status --json
.local/StageB/Zapas.app/Contents/MacOS/zapas processes --sort memory --limit 20 --json
swift build --scratch-path .local/build
swift test --scratch-path .local/test-build
node --test chrome-extension/policy.test.mjs
python3 tools/test_cli.py
zapas_bin_dir="$(swift build --scratch-path .local/test-build --show-bin-path)"
python3 tools/test_ipc.py --bin-dir "$zapas_bin_dir"
```

Обычный runtime не вызывает Swift, Xcode, probe, shell или расширение. `otool -L` содержит только Apple frameworks и `/usr/lib` библиотеки. CLI успешно работает с пустым PATH, несуществующим DEVELOPER_DIR и отсутствующим socket. Установленное окружение не изменялось; физический Mac без установленного Xcode отдельно не проверялся. Developer ID, hardened distribution, notarization, перенос на другой Mac и Intel-сборка не квалифицированы. Скрипт ad-hoc упаковки не является установщиком и не регистрирует login item.

Для UI-инструмента использован явный `--qualification-window`: AppKit окно с той же DiagnosticsView; обычный запуск по-прежнему только MenuBarExtra. `--demo unknown` открывает явно подписанные синтетические unknown/empty/error/stale и локальные переключатели темы/контраста. Demo не запускает live coordinator, не используется CLI; его статические снимки естественно стареют. `--qualification-output /.../.local/...` — opt-in локальная запись времён/режима без process names; обычный запуск не пишет диагностику на диск и не устанавливает input monitor. Не запускать одновременно несколько экземпляров для этих проверок.

## Проверки

Среда: arm64, macOS 27.0.1 (26A434), Apple Swift 6.4 (swiftlang-6.4.0.34.1), language mode Swift 6, deployment macOS 14.0; app 0.2.0 build 2. Это не проверка на macOS 14.

| Проверка | Результат | Доказательство / предел |
| --- | --- | --- |
| Swift debug build/test | PASS | 34 Swift Testing: 21 A + 13 B; controlled clock/sources, cadence, coalescing/no overlap, cancellation, sleep/wake epoch, obsolete result, history bounds, error recovery, stale, grouping/null/graph gaps |
| Release packaging / strict ad-hoc codesign | PASS | Полная .app и отдельный CLI, без runtime toolchain linkage |
| JS A | PASS | 25 проверок policy; живые Chrome-действия B не запускались |
| IPC A | PASS | 13 тестов на новой сборке; sandbox bind ограничение обойдено разрешённым запуском теста вне sandbox, не изменением разрешений socket |
| CLI реальные вызовы | PASS | 7 тестов: JSON, units/sources/null, первый interval, default/limit/sort/identity/RSS, 10 неверных наборов аргументов, exit 0/2 и exit 1 при read-only stdout и закрытом pipe, независимость PATH/Chrome/socket |
| Полный отказ реальных системных API в CLI | NOT RUN | Не менялись системные API ради отказа; отказ coordinator и envelope проверены управляемыми источниками |
| Видимое native окно общей view | PASS | Непосредственный screenshot + AX, не вывод по PID; русский UI, прокрутка, детали процессов, settings, ⌘, и toggle подписи с восстановлением |
| Demo empty/error/unknown/stale | PASS | Явный banner, реальные native UI-переключения, screenshot/AX; unknown не заменён нулём |
| Светлая/тёмная тема; контраст графика | PASS | Светлая live view и dark demo, явно усиленные линии/сетка, текстовая сводка |
| Полная VoiceOver-сессия / OS Increase Contrast / OS Reduce Motion | NOT RUN | Labels/summary проверены через AX, системные режимы и весь keyboard focus order отдельно не квалифицированы |
| Значок и именно MenuBarExtra; открытие около 200 мс | NOT RUN | Инструмент не получил native status item; пользователь выбрал продолжить без ручного клика. Общая view не заменяет эту проверку |
| Реальный login/relogin, успешная registration/approval | NOT RUN | Toggle по умолчанию off подтверждён; локально SMAppService сообщает notFound, состояние показано. Регистрация не выполнялась |
| macOS 14, физический sleep/wake, живое событие pressure | NOT RUN | Только инъекции времени/источников для reset; нельзя объявлять квалификацию реальной ОС |
| LLDB / Charles | NOT RUN | LLDB отложен пользователем; Charles и сохранение сессий не квалифицированы |
| Живой Chrome A в ходе B | NOT RUN | Сохранена прежняя база 12 PASS из StageAReport; намеренно не повторялся в B |

Исправлен найденный пользователем дефект: Timeline timestamp мог быть раньше нового снимка и вызывать ложный stale при каждом обновлении. Проверка возраста теперь использует текущий wall time; строка статуса процессов занимает постоянные 18 pt и не сдвигает список при stale/fresh. Часы обновляют только индикаторы возраста, не всю view каждую секунду. Новое предупреждение всё ещё правильно появляется при действительно просроченном снимке.

В ходе квалификации UI-инструмент автоматически перезапустил закрытый Zapas при последующем чтении его AX; это создало лишние тестовые экземпляры. Доступная копия закрыта штатным Exit; два оставшихся собственных тестовых PID завершены только после явного разрешения пользователя и повторной проверки executable/start identity. В продукте команд завершения процессов нет; после очистки проверялся один экземпляр.

## Стоимость

Измерения release через `tools/measure_app.py`: `proc_pid_rusage.RUSAGE_INFO_V0`, footprint и RSS раздельно, стабильный PID/start/UUID, выборка раз в 5 с. CPU = delta(user+system Mach ticks) × mach_timebase / wall duration; на этой arm64-машине timebase 125/3. Процент относится к одному ядру, не ко всей машине. Сырые исходные снимки и промежуточные профили — только `.local/results/stage-b/`. Графический qualification window отличается chrome окна от MenuBarExtra: стоимость самого popover и opening latency не квалифицированы.

Первый фон до открытия GUI: 300,005 с, footprint 17,73–17,99 MB, CPU 0,0435% одного ядра — PASS для измеренного режима. Первые варианты графика были FAIL по footprint: Swift Charts 280–284 MB, Canvas 271–272 MB. `vmmap` показал 216,8 MiB owned unmapped graphics; после перехода на AppKit отрисовку и отложенные process rows GUI укладывается в 100 MB. Это расследование конкретной сборки/ОС, не доказательство универсальной причины. GUI на общем секундном таймере был 36,57–36,85 MB и CPU 1,73% — FAIL CPU; `sample` показал SwiftUI diff/layout, поэтому секундный clock ограничен метками stale. Итоговые замеры приведены ниже.

| Итоговый режим | Длительность | Footprint, decimal MB | CPU одного ядра | Результат |
| --- | --- | --- | --- | --- |
| Прогретое открытое qualification window | 60,004 с | 35,13–36,78 | 1,386% | PASS footprint; FAIL CPU <1% |
| Фон после скрытия прогретого окна | 300,006 с | 39,19–40,47 | 0,0610% | PASS footprint <100 MB и CPU <1% |
| Именно MenuBarExtra / latency открытия | — | — | — | NOT RUN |

Фоновая trace подтверждает `visible=false`, `detailed=false`, cadence около 30–32 с и неизменный `processMeasuredAt` на протяжении пяти минут. Используется реальное AppKit скрытие окна, а не вручную подставленный режим coordinator. Фоновый замер проводился после GUI, при оставшемся одном собственном экземпляре; это существенно отличается от начального холодного фона. Последние изменения ограничивают setter кадра внутри core, корректируют малый экран и CLI SIGPIPE; измеренная GUI-логика и высота 660 pt в этой среде те же.

CPU открытого окна остаётся незакрытым критерием B. Снятый `sample` указывает на SwiftUI diff/layout и меньшую долю libproc/группировки; это статистический профиль, не строгая атрибуция CPU. Убраны общий секундный redraw и дорогой графический renderer, но 1,386% не переименован в PASS. Следующая оптимизация/квалификация должна измерить именно MenuBarExtra и повторить open/background бюджеты; результат окна проверки нельзя автоматически переносить на popover. Открытие около 200 мс не измерено: click-to-visible записи нет.

## Передача

B не объявлен полностью квалифицированным: перечисленные NOT RUN и фактические FAIL остаются открытыми критериями приёмки. Независимые контракты и lifecycle C можно реализовывать, сохраняя ограничения; зависимые действия не строить на неподтверждённых сигналах. Готовое поручение — [StageCPrompt.md](StageCPrompt.md). C автоматически не начинать.
