# Zapas CLI — диагностический JSON v1 и явные Chrome-действия

CLI `zapas` входит в локальную `Zapas.app`, использует те же модели диагностики и `SamplingCoordinator`, что GUI. `zapas-probe` и канал A Native Messaging остаются экспериментальными: их version=1 **не** является этим контрактом. Production host C имеет отдельный `ServiceRequest/ServiceReply` v1; публичные команды используют прежний `DiagnosticEnvelope` schemaVersion=1.

```sh
.local/StageC/Zapas.app/Contents/MacOS/zapas status --json
.local/StageC/Zapas.app/Contents/MacOS/zapas processes --sort memory --limit 20 --json
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

Источники: `sysctl.hw.memsize`, `host_statistics64` × `host_page_size`, `sysctl.vm.swapusage`, swap counter deltas, `DispatchSourceMemoryPressure`. Без работающего GUI первый вызов — разовый снимок: скорости `null` с `first_sample`; без события pressure — `unknown` с `no_pressure_event`. Не сравнивать даты разных метрик как гарантию одновременного измерения.

`processes.data`: `measuredAt`, `processes`, `failures`, `accounting`, `totalObserved`. Строка процесса: `identity` (`pid`, `startSeconds`, `startMicroseconds`), `uid`, `parentPID`, `name`, `executablePath` (string/null), отдельные метрики `footprint` и `rss`. Источник — `proc_pid_rusage.RUSAGE_INFO_V0`. Идентичность и UID перепроверяются после чтения памяти. `failures`: массив `{pid,issue:{code,message}}`; ошибки могут относиться к непрочитанным процессам другого владельца, их нельзя приписать приложению. Лимит ограничивает возвращённые строки, не ошибки. `totalObserved` — число успешно идентифицированных строк до лимита; текущее хранение ограничено 10000 строками.

Footprint и RSS не складываются. Групповая сумма footprint — наблюдаемый частичный учёт, не уникальная физическая RAM и не RAM вкладок. Путь процесса и `.app`-группировка — диагностическая эвристика, не проверка подписи и не основание для действия.

Устойчивые коды ошибок v1 включают `invalid_arguments`, `system_api`, `system_failed`, `vm_api`, `swap_api`, `counter_unavailable`, `first_sample`, `boot_changed`, `page_size_changed`, `invalid_interval`, `sampling_gap`, `counter_reset`, `no_pressure_event`, `process_list`, `process_api`, `process_disappeared`, `process_identity_changed`, `process_memory_unavailable`, `processes_failed`, `cli_failed`. Клиенты должны поддерживать неизвестные будущие коды. `demo_*` / `test_*` в живом CLI не выдаются.

## Выход, хранение и совместимость

Код 0 — доступный либо частичный снимок; 1 — полный отказ сбора / доставки; 2 — неверные аргументы. `processes` оценивает успех process payload отдельно от системного сбора. Пустая успешная инвентаризация отличается от её полного отказа.

При наличии GUI socket CLI обращается к его единственному coordinator: существующий interval/pressure могут быть доступны. Без GUI `status/processes` создают конечный coordinator для одного сбора. При существующем, но недоступном socket возвращается IPC error, обход отдельным монитором не выполняется. История CLI не сохраняется; GUI хранит до 15 минут / 600 системных точек в памяти и только последний process inventory. Никаких URL и отправки данных наружу. JSON содержит имена, пути и PID — реальные снимки сохранять только в `.local/`.

В пределах v1 допустимы новые поля и коды ошибок; потребители игнорируют неизвестные поля. Значение существующих полей, их единицы и nullable-политика не изменяются без новой версии. В B действия отсутствовали. C добавляет только явные Chrome-команды ниже; произвольного shell, MCP, Simulator/LLDB/Charles-действий нет.


## Добавления C

```text
zapas tabs list --json
zapas tabs preview --type discard|close --selection JSON --json
zapas tabs apply --plan UUID --apply --json
zapas tabs result --plan UUID --json
zapas native install --user-data-dir /absolute/path --apply --json
```

`list.data.profiles` содержит opaque `id`, Native Messaging `sessionID`, пользовательскую `label`, `measuredAt`, `stale`, `policy.excludedDomains` и `tabs`. У вкладки: `id`, `token` (generation UUID), `windowID`, название/домен, active/pinned/audible/incognito/discarded/pending/splitView, nullable `lastAccessedMilliseconds` (Unix ms). Полный URL, формы и трафик отсутствуют. RAM отдельной вкладки не предлагается. Инкогнито запрещён manifest и дополнительно фильтруется.

`--selection` — JSON-массив 1...100 уникальных объектов `{profileID,sessionID,tabID,token}`, скопированных из **свежего** списка; пример синтетический:

```json
[{"profileID":"11111111-1111-4111-8111-111111111111","sessionID":"22222222-2222-4222-8222-222222222222","tabID":7,"token":"33333333-3333-4333-8333-333333333333"}]
```

Preview возвращает `data.plan`: UUID `id`, `kind`, createdAt/expiresAt, точные `targets` с selection и expected-состоянием. Preview не действует на Chrome. Проверить каждый target; `apply` принимает только этот одноразовый plan и явный `--apply`, без диалогов и автоматического расширения набора. Истечение 30 с, reconnect, навигация, смена flags/активности или исключений требуют нового preview. Проверка повторяется при apply, доставке команды и непосредственно перед Chrome API. Выгрузка и закрытие никогда не подменяют друг друга.

`apply.data.batch` — план и результаты в том же порядке. `unknown/awaiting_confirmation` после постановки в очередь не означает успеха. `result.data.batch.results` содержит command UUID, `status` (`confirmed`, `failed`, `unknown`), optional resultingTabID/issue и measuredAt. Confirmed discard требует повторного чтения discarded и проверенной замены ID; confirmed close требует успешного API, removal-события и отсутствия ID. Потеря связи/истечение command lease 20 с остаётся unknown, повторная команда автоматически не отправляется. Результат immutable, хранится только в GUI-памяти до 15 минут; restart его теряет.

Batch `before/after` содержит наблюдаемые групповые `footprint` и `rss` в прежнем формате метрики, времена и coverage. Это partial path-classified сумма **всех** Chrome-профилей, не unique physical RAM, не RAM вкладки и не атрибуция изменения действию. Недоступность — structured error/null. Финальный `result` запрашивает один замер после фактического результата через тот же coordinator. Это не серия оценки эффекта этапа E.

Защита активности 600 с утверждена для обоих действий. Snapshot stale после 10 с; отключённые profiles удаляются по EOF/disconnect, потерявшие heartbeat становятся stale и удаляются через 300 с. Ограничения в памяти: 32 профиля × 2000 вкладок, 64 preview, 256 command, 128 batch × 100 target; история системы остаётся 600 точек/900 с. Exclusions exact-domain и consent — настройки, не диагностическая история.

Новые ошибки включают `ipc_unavailable`, `ipc_disconnected`, `ipc_reply_mismatch`, `service_already_running`, `session_stale`, `session_replaced`, `tab_identity_changed`, `tab_state_changed`, `tab_excluded`, `selection_required`, `preview_expired_or_used`, `result_unknown`, `install_conflict`, `install_directory`, `install_binary`. Неизвестные будущие коды допустимы. Код 1 — IPC/политика/установка; код 2 — аргументы; код 0 — полученный payload, **не подтверждение действия**. Для failed/unknown смотреть result.status. Отсутствующий optional C-параметр отличается от обязательных null полей метрик JSON v1.

Обычный socket — `~/Library/Application Support/Zapas/run/gui.sock`, runtime 0700, socket 0600, peer того же UID. Advisory lease предотвращает второй GUI и позволяет восстанавливать только proven-stale собственный socket. Другие программы того же пользователя находятся в этой локальной границе доверия; IPC не является защитой от вредоносного кода того же UID. `ZAPAS_RUNTIME` — явный override для изолированных тестов. Installer требует absolute user-data-dir и `--apply`; не загружает расширение и не изменяет рабочие Chrome preferences.
