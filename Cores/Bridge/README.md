# Мост Xray-core

Go-модуль `networkplatform/bridge`: один экземпляр Xray-core за узким C ABI. Решения — ADR-0001 §4 и §4.1;
путь пакетов — `Documentation/Architecture/tun-integration.md`.

Состояние на 2026-11-27: собран и проверен на Linux/amd64. Под Apple собран на macOS CI (`Cores/BuildScripts/bridge-apple-xcframework.sh`, 10 срезов `NPXrayBridge.xcframework`, проверка `bridge-apple-verify.sh`), тест C ABI выполнен на macOS arm64; слинкован в расширения `PacketTunnelXray_<p>` (`STATUS.md` §2.0). **На устройствах Apple не запускался.**

## Закреплённые версии

| Что | Версия |
|---|---|
| Xray-core | тег v26.11.9, коммит `676eaf66f8f05d4d558ee7a74b4736623d3feeb9` (`go.mod`: `v1.260327.1-0.20261109052709-676eaf66f8f0`) |
| Go | 1.27.4 (`toolchain` в `go.mod`; ядро требует `go 1.27`) |

Лицензия ядра — MPL-2.0; исходники ядра не изменены и не скопированы, модуль подключён зависимостью.

## Состав

| Путь | Что |
|---|---|
| `engine/` | вся логика: жизненный цикл, подготовка конфигурации, журнал, статистика, память, пакетный интерфейс. Обычный Go-пакет, тестируется на Linux |
| `cabi/main.go` | экспорт `npb_*` для `-buildmode=c-archive`; тонкая обёртка над `engine` |
| `cabi/ctest/abi_test.c` | проверка ABI из C и замер стоимости перехода |
| `cmd/nplab` | лабораторный инструмент (только Linux, в приложение не входит): мост на настоящем tun ядра с насосом вместо `NEPacketTunnelFlow`, цели, генератор трафика и замеры для `Cores/BuildScripts/bridge-tunlab.sh` |

## C ABI (версия 1)

Управление: JSON на входе, JSON `{"code","error","data"}` на выходе, строку освобождает `npb_free`.
Данные (журнал, пакеты): буферы вызывающего, целочисленный результат (отрицательный — код ошибки).
Все функции потокобезопасны. Один процесс — один движок.

| Функция | Назначение |
|---|---|
| `npb_abi_version`, `npb_version` | версия ABI, ядра, Go |
| `npb_validate(config, options)` | проверка без запуска. Если движок в процессе не активен — ядро дополнительно конструирует экземпляр (`depth: "instance"`), иначе только сборка конфигурации (`depth: "build"`) |
| `npb_start(config, options)` | запуск; возвращается, когда ядро работает, упало или истёк `startTimeoutMs` |
| `npb_stop(timeoutMs)` | остановка; идемпотентна; прерывает идущий запуск |
| `npb_reload(config)` | см. ниже |
| `npb_state`, `npb_health` | состояние автомата, последняя ошибка, счётчики очередей |
| `npb_stats` | трафик по inbound/outbound и счётчики пакетного интерфейса |
| `npb_observe` | балансировщики конфигурации и замеры обсерватории ядра по их участникам (`engine/observe.go`); только состояние в процессе, без проб |
| `npb_select` | закрепить участника балансировщика для новых соединений (`SetOverrideTarget` роутера ядра) или вернуть выбор стратегии (пустой участник); без перезапуска |
| `npb_memory` | снимок памяти Go-рантайма (`runtime/metrics`) |
| `npb_log_read(buf, cap, timeoutMs)` | записи журнала строками JSON |
| `npb_tun_write`, `npb_tun_read` | пачки IP-пакетов, режим `flow` |

Коды ошибок (`engine/errors.go`, номера — часть ABI): 0 ok, 1 invalid_argument, 2 invalid_state, 3 config_parse,
4 config_build, 5 config_unsupported, 6 start_failed, 7 timeout, 8 cancelled, 9 stop_failed, 10 internal,
11 not_running, 12 buffer_too_small, 13 closed.

Опции запуска (`engine/options.go`): `startTimeoutMs` (15000), `stopTimeoutMs` (5000), `assetDir`, `logLevel`,
`accessLog`, `logQueueSize` (512), `disableStats`, `memory{profile, limitBytes, gcPercent, freeOSMemoryIntervalMs}`,
`tun{mode: ""|"flow"|"fd", fd, mtu, outQueueBytes (2 МиБ), maxFlows (0 — без предела)}`. Неизвестные поля отвергаются.
`memory.profile: "mobile"` заполняет незаданные `limitBytes` (40 МиБ), `gcPercent` (25), `tun.outQueueBytes`
(512 КиБ), `tun.maxFlows` (512), `logQueueSize` (128) и отвергает `assetDir` и ссылки на geodata
(`geosite:`/`geoip:`/`ext:`) в `routing`/`dns`. Политику (`connIdle`, `bufferSize`) и окна QUIC мост не
переписывает — их выпускает компилятор (`XrayMemoryProfile.mobile`). Замеры —
`Documentation/Performance/memory-budget.md`.

## Поведение, о котором надо знать

- **Автомат состояний**: `idle → starting → running → stopping → idle`. Запуск, который истёк по тайм-ауту
  или был отменён, не оставляет полузапущенного ядра: движок остаётся в `starting`/`stopping`, пока фоновая
  горутина не разберёт созданное, и только потом становится `idle`.
- **Reload.** `core.Instance` не умеет менять конфигурацию на ходу. `npb_reload` = проверить новую
  конфигурацию (при ошибке ничего не меняется) → stop → start. Если новая не стартовала, поднимается
  прежняя, а в ошибке сказано `previous config restored`. Соединения перезагрузку не переживают; в режиме
  `flow` устройство пересоздаётся, `npb_tun_read` один раз вернёт `closed`/`not_running`.
- **Остановка рвёт установленные соединения.** `Instance.Close()` ядра закрывает слушатели, но оставляет
  уже принятые сессии до их тайм-аутов; мост создаёт экземпляр с отменяемым контекстом и отменяет его.
- **Конфигурация.** Строгий JSON (без комментариев), не больше 4 МиБ (ограничение проекта). Секции `env`,
  `api`, `metrics` отвергаются: окружение задают опции моста, сетевой API статистики не нужен. Журнал ядра
  всегда уходит в очередь моста — пути к файлам и stdout из конфигурации игнорируются. Stats-фича и счётчики
  inbound/outbound включаются мостом, если не задано `disableStats`.
- **Журнал.** Кольцо фиксированной ёмкости; производитель никогда не блокируется; при переполнении
  затирается самая старая запись, потери видны по `logDropped` и по разрывам `seq`. Запись обрезается до
  2048 байт. Адреса назначения в записях ядра есть — хост решает, что с ними делать (ADR-0003 §4);
  `log.maskAddress` в конфигурации работает.
- **Значения конфигурации не выходят из моста** (`engine/redact.go`). Ядро цитирует отвергнутое значение
  (`invalid UUID: …`, `invalid "password": …`, `invalid "shortId": …`, `unsupported "encryption": …`), а хост
  пишет сообщения ошибок в журнал публично. Поэтому каждое сообщение ошибки (разбор, сборка, создание и запуск
  экземпляра, `lastError` в `npb_health`) проходит через редактор, построенный из той же конфигурации: все
  строковые значения, кроме структурных ключей (`protocol`, `network`, `security`, теги, `flow`, `fingerprint`,
  `method`…), заменяются на `[redacted]` без учёта регистра (значения ключей учётных данных и адресов — от 4
  символов, остальных — от 6), плюс любые UUID и IP-литералы. Записи журнала ядра проходят тот же редактор без
  общего правила для IP: адреса назначения остаются (хост пишет их как private). Те же правила — у компилятора
  (`ConfigValueRedactor.swift`). Тесты: `TestConfigErrorsAreRedacted` (каждый случай сначала проверяет, что
  ядро действительно цитирует значение), `TestParseErrorOfBrokenJSONIsRedacted`, `TestRedactorRules`,
  `TestCoreLogRecordsAreRedacted`. Ограничение: пароль короче 4 символов и значения из `commonWords`
  (`none`, `auto`, `tcp`…) не вырезаются.
- **Статистика.** Счётчики inbound равны байтам, которыми ядро обменялось с приложением, — проверено
  побайтно для SOCKS и tun. Счётчики outbound считает ядро на транспортном соединении outbound (с
  заголовками протокола, под TLS/REALITY); у VLESS поверх raw TCP и у VMess в uplink не попадает полезная
  нагрузка UDP — поведение закреплённого ядра, зафиксировано в тесте строкой `CORE DEVIATION`.
- **Память.** Мост сам ничего не настраивает: нулевые опции оставляют рантайм как есть, заданные —
  применяются при запуске и возвращаются при остановке. Замер (Linux/amd64, 8 потоков через
  VLESS+REALITY+Vision, путь `flow`): живая куча под нагрузкой 8–10 МиБ; `limitBytes` 24–40 МиБ с
  `gcPercent` 50 держат память рантайма в 22–27 МиБ без потери скорости (≈800 Мбит/с); профиль libXray
  (30 МиБ, GC 10 %, `FreeOSMemory` каждую секунду) даёт ещё −4 МиБ ценой пятикратного числа циклов GC и
  −7 % скорости. Исходная рекомендация для iOS была `limitBytes` 24–32 МиБ, `gcPercent` 50; долгий прогон
  с короткими UDP-сессиями её опроверг: при 28 МиБ живая память рантайма (куча + стеки) упирается в предел и
  GC работает непрерывно (18 600 циклов за 8 минут, CPU ×8). Значения профиля `mobile` выбраны по замеру в
  `Documentation/Performance/memory-budget.md`. На устройстве не проверено (E-4).

## Проверка

Всё выполняется на машине с Go; из `Cores/Bridge`:

```sh
go vet ./...
go test ./engine                                    # сервер тестов — экземпляр ядра в том же процессе
NP_STOCK_XRAY=/path/to/xray go test -race ./engine  # сервер — отдельный процесс штатного xray той же версии
go test ./engine -run '^$' -fuzz '^FuzzPrepareConfig$' -fuzztime 60s   # также FuzzParseOptions, FuzzTunWrite
../BuildScripts/bridge-linux-cabi-test.sh           # C-архив + тест ABI из C
../BuildScripts/bridge-linux-netns-test.sh          # режим fd против ядра Linux, нужен root
../BuildScripts/bridge-tunlab.sh build && ../BuildScripts/bridge-tunlab.sh e2e   # tun ядра в netns, нужен root
```

Стенд `bridge-tunlab.sh` (сквозной путь через tun ядра Linux, сравнение со штатным xray, замеры, долгий
прогон) и его результаты: `Documentation/Performance/bridge-benchmarks.md`.

Штатный `xray` для `NP_STOCK_XRAY` собирается из того же закреплённого модуля:
`go build -o xray github.com/xtls/xray-core/main`.

## Известные ограничения

- C-архив под Apple собирается только на Mac или на macOS CI (нужен SDK); на Linux под `GOOS=ios` без SDK
  пакет не собирается. Срезы macOS импортируют `proc_pidinfo` (Xray-core `common/net/find_process_darwin.go`,
  `darwin && !ios`; libproc — публичный API macOS): `bridge-apple-verify.sh` допускает его только в срезах
  macOS моста Xray и пишет в `verify.tsv`.
- Под детектором гонок тесты с `flow: xtls-rprx-vision` иногда сообщают гонку **внутри ядра**
  (`proxy/proxy.go`: `XtlsFilterTls` против `VisionReader.ReadMultiBuffer`, общий `TrafficState` читающей и
  пишущей половин outbound). `TestFlowThroughProxyWithDNS` под `-race` из-за этого падает воспроизводимо
  (2 прогона из 2); в стеках гонки мост присутствует только как создатель горутины. Тот же тест под `-race`
  через протокол без Vision проходит: `NP_TEST_FLOW_PROXY='Trojan+TLS'` или `'VLESS+XHTTP'`. Остальные тесты
  под `-race` проходят.
- С REALITY первое соединение к тестовому серверу занимает около 5 с: серверная библиотека ждёт пробу
  post-handshake-записей цели (`xtls/reality` `record_detect.go`), локальная цель их не шлёт. Следующие — миллисекунды.
- `core.New`, вернувший ошибку, не отдаёт частично созданный экземпляр — закрыть его нечем.
- `Validate` с конструированием экземпляра меняет процесс-глобальное состояние ядра (системный диалер,
  обработчик журнала), поэтому при работающем движке выполняется только сборка конфигурации.
- Ограничения ядра, найденные стендом на tun ядра (у штатного xray те же): UDP-датаграмма больше ~7500 байт
  через VLESS+REALITY+Vision теряется; TCP half-close через прокси не передаётся (через ~1 с соединение
  закрывается политикой `downlinkOnly`); UDP-сессии стека живут `connIdle` (300 с по умолчанию) после
  последнего пакета; загрузка на стенде упирается в ~200 Мбит/с. Подробности — `bridge-benchmarks.md` §2, §6.
- Активной проверки доступности сервера («health» в смысле пробы) нет: `npb_health` сообщает состояние
  моста и ядра, а не сети.
