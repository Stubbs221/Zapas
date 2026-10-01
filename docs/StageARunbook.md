# Этап A: воспроизводимые проверки

Все команды выполняются из корня репозитория на macOS. Нужны Swift 6 с Swift Testing, Python 3; для расширения — Node.js с `node:test` и Chrome Stable. Зависимости Swift Package внешние пакеты не используют. Сырой JSON может содержать имена, пути, PID и идентификаторы среды: сохранять его только в игнорируемой `.local/`, не в issue или коммит.

## Сборка и автоматические тесты

```sh
mkdir -p .local/results
chmod 700 .local
swift build --scratch-path .local/build
swift test --scratch-path .local/test-build
node --test chrome-extension/policy.test.mjs
zapas_bin_dir="$(swift build --scratch-path .local/build --show-bin-path)"
python3 tools/test_ipc.py --bin-dir "$zapas_bin_dir"
```

`--show-bin-path` нужен: расположение executable зависит от версии SwiftPM. Ограничение доступа к compiler cache в среде агента устранялось запуском сборки вне его sandbox; root для метрик не использовался.

Swift Testing проверяет арифметику страниц, переполнение, первый интервал, смену boot/page size, сброс счётчиков, разрыв времени и имитацию сна, недоступные значения, живой собственный процесс и защиту от PID reuse, симуляторные fixtures и протокол. Имитация не заменяет проверку физического сна/пробуждения.

Node проверяет свежие исключения непосредственно перед `discard(id)`, навигацию и nonce тестовой страницы, исчезновение, изменившееся состояние, замену ID и подтверждение результата. IPC-тесты запускают реальные конечные broker/host, проверяют фрейминг, ограничение размера/времени чтения, version/origin, EOF, недоступный broker, несколько клиентов и изоляцию host-сессий. Чужие процессы они не используют.

## Метрики и сравнение

```sh
"$zapas_bin_dir/zapas-probe" system --samples 5 --interval 2 > .local/results/system.ndjson
"$zapas_bin_dir/zapas-probe" processes --limit 10000 > .local/results/processes.json
"$zapas_bin_dir/zapas-probe" chrome-memory > .local/results/chrome-memory.json
"$zapas_bin_dir/zapas-probe" benchmark --iterations 30 > .local/results/benchmark.json
vm_stat > .local/results/vm-stat.txt
sysctl vm.swapusage > .local/results/swapusage.txt
top -l 1 -stats pid,command,mem > .local/results/top.txt
```

Сохранять время каждой команды. У `vm_stat` размер страницы в заголовке: wired = `Pages wired down × page size`, compressed = `Pages occupied by compressor × page size`. Это физический размер компрессора, не исходный объём сжатых страниц. Swap used/total — байты sysctl. `swapins/swapouts` — накопительные страницы; скорости — разность страниц × размер страницы / монотонный интервал бодрствования. Первый замер скорости неизвестен. Нулевой валидный delta допустим; ошибка API не становится нулём.

Для процессов сопоставлять живой PID и время старта. В `top` привести суффиксы K/M/G к байтам; не сравнивать RSS с MEM/footprint как одну величину. Последовательные снимки имеют дрейф, округление и исчезнувшие процессы. Сумма footprint наблюдаемых процессов Chrome — частичный групповой показатель, а не уникальная физическая RAM и не память вкладок; отдельно показаны пропуски и не классифицированные ошибки инвентаризации. Классификация Chrome по компоненту пути `Google Chrome.app` экспериментальная, не проверка подписи.

В Activity Monitor открыть «Память», сверить Physical Memory/Swap Used, затем в спокойной тестовой сессии сравнить несколько живых процессов с быстрым снимком probe. Сохранить локально время и выбранные идентичности. Если PID уже исчез, записать NOT RUN вместо сравнения с похожим именем.

Физический сон/пробуждение проверять отдельно в удобный пользователю момент: интервальный probe до сна и после него должен выдавать неизвестную скорость для несопоставимого интервала и восстановить расчёт на следующей паре. Для короткого сна эвристика времени может не обнаружить событие; этап B должен сбрасывать baseline по уведомлениям workspace. События memory pressure не вызывать искусственным истощением рабочей памяти; до события состояние `unknown`.

## Chrome Stable: автоматическая живая проверка

```sh
python3 tools/test_chrome.py --bin-dir "$zapas_bin_dir" --run
```

Команда создаёт новый приватный профиль в `.local/chrome-automated/`, без sync, профильный Native Messaging manifest и конечный broker. Для установки собственного расширения использует приватный CDP pipe, не сетевой порт. Флаг `--enable-unsafe-extension-debugging` применяется только в этом opt-in тесте. Рабочий Chrome остаётся отдельным. Тест создаёт вкладки только своего расширения, слышимый тихий тестовый звук, два тестовых окна и явно выбирает fixture ID; ждёт экспериментальную паузу 60 секунд, выполняет одну выгрузку, проверяет nonce/новый ID, восстановление при фокусировке окна, новый JavaScript heap и reconnect. После проверки закрывает только запущенные им процессы. Профиль/отчёт остаются локальными.

Результат: `.local/results/chrome-smoke.json`; stderr Chrome: `.local/results/chrome-automated.log`. Сохранение поля браузером регистрируется как наблюдение, не гарантия сохранения состояния приложения. Не запускать одновременно два экземпляра harness: существующий socket не заменяется. Incognito не включается (`incognito: not_allowed`). Сценарии принудительной остановки service worker, реального выключения расширения и нескольких живых профилей требуют отдельной проверки.

### Ручная альтернатива без CDP

```sh
python3 tools/prepare_chrome.py
```

Из `.local/chrome-test-config.json` выполнить массивы `brokerCommand` и `chromeCommand` без изменения `user-data-dir`. В окне этого профиля открыть `chrome://extensions`, включить Developer mode, Load unpacked → `chrome-extension/`. Проверить профиль на `chrome://version`. Открыть `controlURL`, нажать «Подключить Native Messaging» и «Создать тестовую вкладку». Загрузка расширения в рабочий профиль не требуется.

Получить сессию и ID через `zapas-probe tabs --socket …`. Из неё выбрать только `isTestFixture=true`; перед действием вывести из active/pinned/audible, дождаться свежего снимка и паузы. Единственная команда действия:

```text
zapas-probe discard-test-tab --socket <local-socket> --session <current-session> --id <selected-fixture-id> --apply
zapas-probe result --socket <local-socket> --action <returned-action-id>
```

Без `--apply` команда отказывает. `queued`/`delivered` не означают успех. Успех — `confirmed` после API и повторного чтения; после отправки без подтверждения результат `unknown`. На выбранной вкладке могут измениться ID и heap. После перезапуска worker старые fixtures теряют принадлежность и не могут выгружаться: создать новые. JSON версии 1 экспериментальный, не публичный CLI-контракт.

## Simulator и ручная сессия LLDB

```sh
xcrun simctl list devices -j > .local/results/devices-before.json
"$zapas_bin_dir/zapas-probe" simulators --assignment .local/simulator-assignment.json > .local/results/simulators-live.json
"$zapas_bin_dir/zapas-probe" simulators --assignment .local/simulator-assignment.json --processes > .local/results/simulator-processes.json
"$zapas_bin_dir/zapas-probe" debuggers > .local/results/lldb-before.json
```

Назначение хранится локально: `{"project":"Zapas","udids":["<dedicated-UDID>"]}`. На машине проверки уже создан **Zapas Stage A**; не создавать ещё один без полной инвентаризации. Нельзя выбирать чужой `Booted`. До любых действий повторно проверить полный список, доступность/runtime и явное назначение; всего устройств ≤8. Эти инструкции не дают права удалять другие устройства.

Пользователь запускает свою отдельную тестовую сессию Xcode на назначенном устройстве. Снять `debuggers` в отдельные локальные файлы: до Run, при остановке на breakpoint, после Stop, после закрытия только тестовой Xcode-сессии. Сопоставлять PID + start time, UID, PPID, путь и footprint; записать наблюдения в отчёт без идентификаторов среды. Не завершать LLDB автоматически. PPID=1 — кандидат, не доказательство отсутствия активной отладки. При неизвестной принадлежности процесса к устройству так и записать; общий `Simulator.app` не указывает UDID. CLI PID не подтверждает видимый запуск: нужна соответствующая Simulator/Device Hub UI. В этой проверке видимый запуск пока не выполнялся.

Чтение simctl при отсутствии Xcode должно давать `simctl_unavailable`, не пустой успешный список; можно проверить с `DEVELOPER_DIR`, указывающим на специально созданный пустой локальный каталог. Тест не меняет `xcode-select`.

## Charles: ручной сценарий этапа F

Документированный Web Interface позволяет контролировать recording и экспортировать/скачивать сессию, но это не проверенная интеграция Zapas. На машине этапа A Charles не обнаружен; операции требуют проверки.

1. Пользователь открывает отдельную тестовую сессию Charles, без рабочего трафика, и создаёт несколько безопасных тестовых запросов.
2. Через штатный Save Session As сохраняет `.chls` в `.local/charles/`; фиксирует число записей и время. Проверяет непустой файл и вручную открывает копию для сверки записей/содержимого.
3. Для исследования Web Interface пользователь сам включает его и проверяет доступ/аутентификацию согласно документации. Экспорт/скачивание записывает в новую локальную копию и также открывает её для сверки.
4. Проверяет отмену сохранения/недоступное место: отсутствие проверенного файла не считать успехом. Новую сессию начинать вручную только после успешного открытия копии.

Не менять proxy/SSL, не устанавливать CA и не закрывать Charles автоматически. Доказательства не должны содержать рабочие URL, заголовки или тела запросов. До прохождения сценария сохранение и управление имеют статус «требует проверки».

Источники: [Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [CDP loadUnpacked](https://chromedevtools.github.io/devtools-protocol/tot/Extensions/#method-loadUnpacked), [Charles Web Interface](https://www.charlesproxy.com/documentation/using-charles/web-interface/).
