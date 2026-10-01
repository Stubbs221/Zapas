# Zapas CLI — стабильный read-only JSON v1

CLI `zapas` входит в локальную `Zapas.app`, использует те же модели диагностики и `SamplingCoordinator`, что GUI. Прототипы `zapas-probe` / `zapas-native-host` остаются экспериментальными инструментами A: их version=1 **не** является этим контрактом.

```sh
.local/StageB/Zapas.app/Contents/MacOS/zapas status --json
.local/StageB/Zapas.app/Contents/MacOS/zapas processes --sort memory --limit 20 --json
```

`status` читает систему. `processes` читает процессы текущего пользователя: footprint по убыванию, неизвестное после доступного, при одинаковом значении — PID по возрастанию. `--sort memory` необязателен; другого порядка v1 нет. Лимит по умолчанию 20, диапазон 1–10000. `--json` обязателен. Неизвестные, повторные и неполные аргументы отклоняются. `--help` / `help` и вызов без аргументов печатают текстовую справку.

## Envelope

Каждый диагностический вызов, включая ошибку аргументов, выдаёт **один JSON-объект и перевод строки в stdout**. Нет обычных логов или второго объекта в stdout/stderr. Ошибка записи stdout может не позволить доставить JSON.

| Поле | Тип / значение |
| --- | --- |
| `schemaVersion` | integer, всегда `1` |
| `command` | string, команда вызова |
| `generatedAt` | string, UTC ISO 8601 с `Z` |
| `status` | `available`, `partial`, `error` |
| `data` | payload либо явный `null` при полном отказе |
| `errors` | array `{code: string, message: string}`; пустой при отсутствии ошибок |

`available` — payload без зарегистрированных ошибок; `partial` — payload есть, но присутствуют неизвестные показатели / ошибки инвентаризации; `error` — payload нет. `partial` сам по себе не означает нехватку памяти. Сообщения ошибок предназначены для человека; ветвление делать по `code`, не по `message`. Ошибки в `errors` могут повторяться, если несколько показателей недоступны по одной причине.

## Метрика и payload

Каждая метрика имеет ровно эти обязательные поля v1: `value` (number/null), `unit` (string), `source` (string), `measuredAt` (UTC string), `status` (`available`/`unknown`), `error` (`{code,message}`/null). Отказ не заменяется нулём. Валидный ноль остаётся числом. `source` объясняет метод измерения, но не является закрытым enum; не использовать его как идентификатор команды.

Единицы машинного JSON: `bytes` и `bytes/second`. `intervalSeconds` — number/null в секундах. GUI переводит bytes в GiB (2³⁰), rates в MiB/с (2²⁰); единицы интерфейса не меняют контракт.

`status.data`: `measuredAt`, метрики `physical`, `wired`, `compressed` (физический compressor, не исходные страницы), `swapUsed`, `swapTotal`, `swapReadRate`, `swapWriteRate`, `intervalSeconds`, `pressure`. Давление: `state` (`unknown`/`normal`/`warning`/`critical`), `source`, `measuredAt` (string/null), `error` (object/null). Оно основано на наблюдаемых событиях DispatchSourceMemoryPressure, не на проценте занятой RAM.

Источники: `sysctl.hw.memsize`, `host_statistics64` × `host_page_size`, `sysctl.vm.swapusage`, swap counter deltas, `DispatchSourceMemoryPressure`. Первый вызов — разовый снимок: скорости `null` с `first_sample`; без события pressure — `unknown` с `no_pressure_event`. Не сравнивать даты разных метрик как гарантию одновременного измерения.

`processes.data`: `measuredAt`, `processes`, `failures`, `accounting`, `totalObserved`. Строка процесса: `identity` (`pid`, `startSeconds`, `startMicroseconds`), `uid`, `parentPID`, `name`, `executablePath` (string/null), отдельные метрики `footprint` и `rss`. Источник — `proc_pid_rusage.RUSAGE_INFO_V0`. Идентичность и UID перепроверяются после чтения памяти. `failures`: массив `{pid,issue:{code,message}}`; ошибки могут относиться к непрочитанным процессам другого владельца, их нельзя приписать приложению. Лимит ограничивает возвращённые строки, не ошибки. `totalObserved` — число успешно идентифицированных строк до лимита; текущее хранение ограничено 10000 строками.

Footprint и RSS не складываются. Групповая сумма footprint — наблюдаемый частичный учёт, не уникальная физическая RAM и не RAM вкладок. Путь процесса и `.app`-группировка — диагностическая эвристика, не проверка подписи и не основание для действия.

Устойчивые коды ошибок v1 включают `invalid_arguments`, `system_api`, `system_failed`, `vm_api`, `swap_api`, `counter_unavailable`, `first_sample`, `boot_changed`, `page_size_changed`, `invalid_interval`, `sampling_gap`, `counter_reset`, `no_pressure_event`, `process_list`, `process_api`, `process_disappeared`, `process_identity_changed`, `process_memory_unavailable`, `processes_failed`, `cli_failed`. Клиенты должны поддерживать неизвестные будущие коды. `demo_*` / `test_*` в живом CLI не выдаются.

## Выход, хранение и совместимость

Код 0 — доступный либо частичный снимок; 1 — полный отказ сбора / доставки; 2 — неверные аргументы. `processes` оценивает успех process payload отдельно от системного сбора. Пустая успешная инвентаризация отличается от её полного отказа.

Каждый вызов создаёт конечный coordinator и заканчивается после одного сбора. Он не подключается к GUI и не создаёт второй постоянный монитор. Production IPC lifecycle и Native Messaging installation относятся к C. История CLI не сохраняется; GUI хранит до 15 минут / 600 системных точек в памяти и только последний process inventory. Никаких URL и отправки данных наружу. JSON содержит имена, пути и PID — реальные снимки сохранять только в `.local/`.

В пределах v1 допустимы новые поля и коды ошибок; потребители игнорируют неизвестные поля. Значение существующих полей, их единицы и nullable-политика не изменяются без новой версии. Никаких команд действий, произвольного shell или MCP в CLI B нет.
