# Zapas CLI — диагностический JSON v1 и явные Chrome/Simulator-действия

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

В пределах v1 допустимы новые поля и коды ошибок; потребители игнорируют неизвестные поля. Значение существующих полей, их единицы и nullable-политика не изменяются без новой версии. В B действия отсутствовали. C добавляет явные Chrome-команды ниже; D расширяет контракт конкретными Simulator/LLDB-командами. Произвольного shell, универсального kill/shutdown, MCP или Charles control нет.


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


## Добавления D

```text
zapas simulators list --json
zapas simulators preview --selection JSON --json
zapas simulators apply --plan UUID --apply --json
zapas simulators result --plan UUID --json
zapas debuggers list --json
zapas debuggers preview --selection JSON --json
zapas debuggers apply --plan UUID --apply --json
zapas debuggers result --plan UUID --json
```

Envelope и метрики v1/C неизменны. `simulators list.data` — `measuredAt`, `totalDeviceCount` полного simctl devices всех runtimes, `devices`, `assignmentIssue`, `processes`, `unassignedProcesses`, `processIssue`, `processFailures`, `processMeasuredAt`. Каждый devices entry: `device` (name, udid, runtime, state, isAvailable, dataPath?, assignment, isIOS), `incarnation?`, `assignmentVerified`. `assignment` — только явное project из `.local/simulator-assignment.json` для перечисленных UDID либо `unknown_or_other_project`; имя не доказывает принадлежность. Legacy A assignment остаётся читаемым, без `bindings` действия не разрешены. Каждый binding совпадает с udid/runtime/dataPath/incarnation; смена runtime, каталога устройства или назначения блокирует действие. incarnation берётся через lstat каталога устройства: dev/inode/birthtime с nanoseconds. Не доверять полям request: core повторно читает локальное назначение и весь simctl inventory.

`processes` — группы `{udid,processes:[DiagnosticProcess]}` по executable внутри конкретного dataPath. `unassignedProcesses` — наблюдаемые generic CoreSimulator/Simulator helpers без однозначного пути; это не полный набор системных helpers. Empty group не доказывает отсутствия приложений/отладки. Process failures и unknown/null memory сохраняются, footprint/RSS отдельно; частичный executable inventory, не unique physical RAM. Ошибка simctl возвращает error/null; отсутствие назначения даёт partial inventory, действия закрыты. Без GUI list — конечный read-only сбор; при наличии socket только GUI сервис и его coordinator, без fallback при отказе.

Simulator `--selection` — **один полный объект из `data.devices`**, выбранный вручную. Preview требует exact identity, availability, Zapas assignment/binding и iOS; не принимает `all`, `booted` или только UDID. State должен быть Booted либо Shutdown. `data.developmentPlan`: id/kind/createdAt/expiresAt, simulator?, debugger?, affectedProcesses, impact, impactIssue?. Перечень процессов частичный; preview предупреждает о завершении всех apps/debugging конкретного устройства даже при пустой группе. Preview не действует. План одноразовый, 30 с, максимум 64; смена назначения/sleep инвалидирует планы. Apply требует `--apply`, правильный kind и план этого GUI; потребляется до проверки/отправки и никогда не повторяется. Apply/result содержат `data.developmentOutcome` с plan и result `{status:confirmed|failed|unknown,issue?,measuredAt}`. GUI команды отправляют тот же explicit apply.

Перед действием повторно читаются полный inventory, runtime/state, lstat incarnation и файл назначения, затем backend повторяет проверку и expiry непосредственно перед fixed `/usr/bin/xcrun simctl shutdown <UUID>`. Уже Shutdown: confirmed с `device_already_shutdown`, без команды. После доставки повторно читается фактическое состояние: та же identity и Shutdown — confirmed; Booted — failed; переход/исчезновение/смена identity/отказ чтения или доставки — unknown. До доставки изменение/чужая принадлежность — failed. Никаких helper kills, runtime delete, erase, boot или tvOS действий в продукте. Socket read deadline только D discovery/apply увеличен до 45 с для конечных simctl операций; прежние C leases и wire framing сохранены. Simctl list bounded 5 с, shutdown 10 с; deadline ошибки не подтверждают отсутствие воздействия. Результаты immutable после завершения, до 128/900 с, только в GUI-памяти; result не запускает новую команду. Timeout CLI не означает, что действие не состоялось: запрашивайте тот же result, не новый apply.

`debuggers list.data`: measuredAt, debuggers, failures, qualification=`not_run_user_deferred`. Каждый debugger: process в v1 формате, activity=`active|inactive|unknown`, orphanhood=`proven|candidate|unknown`, evidence `{code,explanation,relatedIdentity?}`, measuredAt, qualified. Живой источник D выдаёт только unknown activity и qualified=false; PPID=1 только candidate. Parent/children — объяснимые наблюдения, не отрицательное доказательство активности. Partial inventory не подтверждает отсутствие target или Xcode. `--selection` для LLDB preview — только process.identity `{pid,startSeconds,startMicroseconds}`; клиент не передаёт trusted proof. Действие блокируется с `debugger_activity_unproven` до отдельной live qualification; имя/PPID/большая память не дают разрешения. Контракт свежей проверки владельца/current UID, PID/start identity, absence of active debug и confirmed/failed/unknown проверен injected tests. Live terminate backend намеренно отключён и не отправляет сигналов. Это blocker D, не PASS живого завершения; для включения нужна новая квалификация/реализация backend.

Код 0 означает доставленный payload, включая failed/unknown результат действия; для успеха смотреть result.status. Код 1 — IPC/политика/сбор, 2 — аргументы. D errors включают `assignment_path`, `assignment_unavailable`, `assignment_schema`, `simctl_unavailable`, `device_inventory_invalid`, `device_not_authorized`, `device_identity_or_state_changed`, `device_disappeared`, `device_already_shutdown`, `device_still_booted`, `device_state_unknown`, `device_identity_or_assignment_changed`, `apply_required`, `action_in_progress`, `action_limit`, `service_suspended`, `debugger_evidence_stale`, `debugger_owner_changed`, `debugger_identity_unknown`, `debugger_activity_unproven`, `debugger_qualification_required`. Все новые поля/коды additive; optional D поля не изменяют mandatory null полей метрик v1.
