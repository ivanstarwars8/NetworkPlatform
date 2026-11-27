# Мост Mihomo

Go-модуль `networkplatform/mihomobridge`: ядро Mihomo за тем же C ABI, что и мост Xray (`Cores/Bridge`).
Решения — ADR-0001 §4/§4.1, ADR-0007. Лицензия ядра — GPL-3.0: всё, что линкует этот модуль, — GPL
(сборки `MihomoOnly`/`Dual`), `XrayOnly` его не содержит.

Состояние: собран и проверен на Linux/amd64 (сервер разработки). Под Apple: на раннере macOS CI собран
`NPMihomoBridge.xcframework` (10 срезов, как у моста Xray), проверены платформы объектов и отсутствие
`proc_pidinfo`/`recvmsg_x`/`sendmsg_x` (`bridge-apple-verify.sh`), тест C ABI выполнен на macOS arm64; расширение
`PacketTunnelMihomo` скомпилировано без подписи (ссылки на прогоны — в `STATUS.md`). **На устройстве не запускался.**

## Закреплённые версии

| Что | Версия |
|---|---|
| Mihomo | тег `v1.19.34` (ветка `Meta`, последний релиз на 2026-11-27), коммит `0455d0d28c4526937380505153e65a843d8612e8` |
| sing-tun (форк metacubex) | `v0.4.29` — из `go.mod` ядра |
| mipstack | `v0.0.0-20261019124225-9a80a07eaeb9` (MPL-2.0) |
| Go | 1.27.4 (`toolchain`), как у моста Xray; ядро объявляет `go 1.20` и на 1.27.4 собирается |

`replace google.golang.org/protobuf => github.com/metacubex/protobuf-go …` повторён из `go.mod` ядра:
`replace` действует только в главном модуле. Исходники ядра не изменены и не скопированы.

## Состав

| Путь | Что |
|---|---|
| `engine/` | жизненный цикл, подготовка YAML, журнал, статистика, память, пакетный интерфейс |
| `engine/{errors,memory,packetqueue,stats}.go` | копии одноимённых файлов `Cores/Bridge/engine` (общий пакет потребовал бы линковать оба ядра) — менять синхронно |
| `cabi/main.go` | экспорт `npb_*` для `-buildmode=c-archive` |
| `cabi/shape_test.go` | проверяет, что имена и сигнатуры экспорта совпадают с `Cores/Bridge/cabi/main.go` |
| `cabi/ctest/abi_test.c` | проверка ABI из C и цена перехода (`Cores/BuildScripts/mihomo-linux-cabi-test.sh`) |
| `apple/patch/` | правка ядра для сборок Apple (ниже) |

## C ABI

Те же функции `npb_*`, те же сигнатуры, конверт `{"code","error","data"}`, коды ошибок и формат пачек
(uint16 LE длина + пакет), что у моста Xray (версия ABI 1). Одинаковые имена символов делают ошибкой линковки
попытку собрать оба движка в один бинарник (ADR-0001). Отличается по движку:

- конфигурация — Clash/Mihomo YAML (или JSON), не больше 4 МиБ (ограничение проекта);
- опции: `startTimeoutMs`, `stopTimeoutMs`, `homeDir`, `logLevel`, `logQueueSize`, `tcpIdleTimeoutMs`,
  `udpIdleTimeoutMs`, `memory{profile, limitBytes, gcPercent, freeOSMemoryIntervalMs}`,
  `tun{mode: ""|"flow", mtu, outQueueBytes, inQueueBytes, maxFlows}`; `memory.profile: "mobile"` заполняет
  незаданные: предел 40 МиБ, GOGC 25, `outQueueBytes` 512 КиБ, `maxFlows` 512 (только TCP), очередь журнала
  128, простой TCP 300 с, UDP 30 с (`Documentation/Performance/memory-budget.md`, §10); поля моста Xray (`assetDir`, `accessLog`, `disableStats`,
  `tun.fd`) отвергаются как неизвестные, `tun.mode: "fd"` не реализован;
- `npb_version` → `{"abi":1,"engine":"mihomo","core":"v1.19.34","go":…}`;
- `npb_validate` → `ConfigSummary` (`depth` всегда `"parse"`, список `overridden` — что мост переписал);
  при активном движке отказ `invalid_state` (разбор временно применяет секцию general к работающему ядру);
- `npb_stats` → `uptimeMs`, `total{uplink,downlink}`, `connections`, `idleClosedTcp`/`idleClosedUdp`, `tun`
  (с `flowsActive`/`flowsHighest`/`flowsRejected`) — ядро считает по соединениям, без разбивки по
  inbound/outbound;
- `npb_connections(limit)` → `total` и до `limit` (1…200) самых новых соединений трекера ядра
  (`engine/connections.go`: `id`, `network`, `destination` — имя или IP с портом, `rule`, `chain` в порядке
  прохождения, `upload`/`download`, `startMs`); только чтение состояния в процессе. У моста Xray та же
  функция всегда отвечает кодом 5 — ядро Xray списка не ведёт;
- простои: у ядра нет таймаута простоя TCP, а таймаут UDP-сессии (60 с, `tunnel.udpTimeout`) не задаётся
  конфигурацией (`tun.udp-timeout` стек `mips` не читает). Мост раз в 0,25–1 с обходит соединения ядра
  (`statistic.DefaultManager`) и закрывает те, у которых счётчики не менялись дольше `tcpIdleTimeoutMs` /
  `udpIdleTimeoutMs` (`engine/idle.go`) — для всех входов, не только пакетного;
- `npb_tun_write` копирует пакеты во входную очередь моста и возвращается; буфер не меняется. Опция
  `tun.inQueueBytes` (1 МиБ) — размер этой очереди, у моста Xray её нет.

## Что мост переписывает в конфигурации

`engine/config.go`; каждое изменение попадает в `ConfigSummary.overridden`, кроме двух безусловных:

- `tun.recvmsgx`/`sendmsgx` → `false` всегда (непубличные `recvmsg_x`/`sendmsg_x` Darwin; у ядра
  `recvmsgx: true` по умолчанию);
- секция `tun` никогда не попадает в TUN-слушатель ядра (он открыл бы системное устройство) — см. ниже;
- `find-process-mode` → `off`; `external-controller*`/`external-ui` — игнорируются; `iptables.enable`,
  `ntp.write-to-system` → `false`; `redir-port`/`tproxy-port` → 0;
- отказ (`config_unsupported`): `tun.enable` без `tun.mode: "flow"`, `tun.stack` не `mips`,
  `tun.file-descriptor`, `listeners` типа `tun`/`redir`/`tproxy`.

## Путь пакетов без дескриптора utun

По исходникам sing-tun v0.4.29 (`stack_mipstack.go`) [V]: `Mipstack` принимает любой `tun.Tun`
(`io.ReadWriter` + `Close`). Для устройства, которое не `LinuxTUN`/`WinTun`/`DarwinTUN`, его `readLoop`
вызывает `Read` по одному пакету (буфер = MTU, без 4-байтового заголовка семейства), `writeLoop` —
`Write` по одному пакету. Пакетные интерфейсы не используются намеренно: `LinuxTUN` с запасом в начале
буфера заставляет `writeLoop` держать 64 × 64 КиБ под GRO (4 МиБ), `DarwinTUN` включает пакетное чтение
только при `recvmsgx`.

Мост не трогает TUN-слушатель ядра (`listener/sing_tun.New`, где создание устройства зашито в `tunNew`),
а запускает свой (`engine/flowtun.go`): тот же обработчик `sing_tun.ListenerHandler` (перехват DNS, политика
ICMP, `IN-NAME` = `DEFAULT-TUN`), тот же стек `mips`, но на `flowDevice` и без маршрутов, мониторов
интерфейсов и auto-redirect. Наложение на ядро для этого не нужно.

`flowDevice`: по ограниченной очереди `packetQueue` в каждую сторону. `npb_tun_write` проверяет кадры и
копирует пакеты во входную очередь; читающая горутина стека забирает по одному пакету. Переполнение —
отбрасывание (`rxDropped`), как и в исходящей очереди. Первая версия передавала пачку горутине стека
синхронно (без очереди, с естественным противодавлением); через C ABI это стоило ~48 мкс на вызов при любом
размере пачки — поток вызывающего засыпал и просыпался на каждой пачке, — поэтому заменена.

## Остановка и глобальное состояние

Полной остановки без завершения процесса у ядра нет (`executor.Shutdown` закрывает только TUN-слушатель).
`Stop`: приостанавливает туннель ядра → закрывает стек и устройство моста → закрывает все соединения
(`statistic.DefaultManager`) → закрывает провайдеры прокси и правил → применяет пустую конфигурацию
(`mode: direct`, без прокси, правил, слушателей, DNS, tun) → снова приостанавливает туннель → возвращает
настройки памяти Go. Неосвобождаемое до конца процесса: горутины пакетов ядра, запущенные в `init()` и при
первом использовании (тикер статистики, журнал, пулы обработчиков TCP/UDP туннеля), подписчик журнала моста,
открытый `cache.db` в `homeDir`, процесс-глобальные настройки (домашний каталог, параметры диалера и
keep-alive) и загруженные geodata. `Reload` = stop + start с откатом, как у моста Xray (хотя ядро умеет
`ApplyConfig` на ходу — ради одного контракта для обоих движков).

## Правка ядра для Apple

`Cores/BuildScripts/mihomo-apple-patch.sh` копирует закреплённое ядро из кэша модулей во временный каталог,
заменяет там `component/memory/memory_darwin.go` (импорт `proc_pidinfo` из libSystem для RSS в статистике
ядра) на `apple/patch/memory_darwin.go` («не реализовано», как на прочих платформах), удаляет ассемблерные
трамплины `memory_darwin_{amd64,arm64}.s` и печатает флаг `-modfile=…/apple.mod` — копию `go.mod` с
`replace` на эту копию ядра (`go.mod` моста не меняется). `go build -overlay` не подошёл: Go отказывается
накладывать файлы из `GOMODCACHE` («Files beneath GOMODCACHE must not be replaced»). Скрипт падает, если в
новой версии ядра этого вызова нет. Любая сборка под `GOOS=darwin`/`ios` обязана передавать этот флаг;
`NP_BRIDGE_ENGINE=mihomo Cores/BuildScripts/bridge-apple-xcframework.sh` передаёт его всегда. `component/process/process_darwin.go` (sysctl `pcblist_n`)
остаётся в бинарнике, но недостижим при `find-process-mode: off`. `recvmsg_x`/`sendmsg_x` вызываются в sing-tun
(`internal/rawfile_darwin`) системным вызовом по номеру (`unix.RawSyscall6(SYS_RECVMSG_X…)`), и эти функции
линкуются в darwin-бинарник (проверено `go tool nm`), хотя в путь моста не попадают (системный utun не
открывается, `recvmsgx`/`sendmsgx` выключены). Поэтому правка Apple заменяет оба вызова в копии sing-tun результатом
`ENOSYS` (правку делает скрипт `sed`-ом, исходников sing-tun в репозитории нет), а `mihomo-apple-check.sh`
проверяет все компилируемые для Apple файлы нестандартных пакетов: 0 ссылок с правкой, 8 без неё (darwin/arm64).
Номер системного вызова не виден в таблице символов, поэтому проверка `nm` на macOS (`bridge-apple-verify.sh`) это
не заменяет.

## Проверка

На сервере разработки, из `Cores/MihomoBridge`:

```sh
go vet ./... && go test ./...
NP_STOCK_XRAY=/path/to/xray go test -race ./engine     # сервер — штатный xray 26.11.9
NP_STOCK_XRAY=/path/to/xray NP_SOAK=10m go test -run TestSoakRSS -v ./engine
../BuildScripts/mihomo-linux-cabi-test.sh
../BuildScripts/mihomo-apple-check.sh
```

## Результаты на сервере разработки (linux/amd64, Go 1.27.4, 2026-11-27)

Логи — `Logs/mihomo/` (вне git).

- `gofmt`, `go vet ./...` — чисто; `go test ./cabi` (совпадение экспорта с мостом Xray: 14 функций) — ok.
- `go test ./engine` со штатным xray 26.11.9 как сервером — ok, все тесты:
  VLESS+REALITY+Vision и Shadowsocks-2022 (`2022-blake3-aes-128-gcm`): через SOCKS-inbound ядра TCP 1 МиБ эхо
  (23–40 мс) и через пакетный путь TCP 1 МиБ (30–67 мс) + UDP 1/512/1400/3000 Б; прямой пакетный путь (DIRECT)
  TCP 4 МиБ + UDP до 8000 Б с фрагментацией — пачки до 64 пакетов, 0 потерь в очередях.
- 50 циклов start/stop (SOCKS + стек + группа + по соединению через оба входа, соединения не закрыты перед
  Stop): горутины 12 → 12, куча после GC +46 КиБ за 49 циклов (~1 КиБ/цикл), RSS +0,6 МиБ.
- C ABI из C (`mihomo-linux-cabi-test.sh`) — **C ABI TEST PASSED**; `npb_tun_write` 776 нс/вызов при пачке 1,
  290–343 нс/пакет при пачке 64 (у моста Xray 258–337 и 32–52 нс: там стек отбрасывает пакет синхронно в
  вызывающем потоке, здесь — копия в очередь и передача горутине стека).
- `mihomo-apple-check.sh` — **APPLE PATCH CHECK PASSED**: `./engine` компилируется для ios/arm64,
  darwin/arm64, darwin/amd64 с правкой; `proc_pidinfo` в Mach-O проверочной программы: 5 вхождений без
  правки, 0 с ней. Бинарник одного `engine` без правки тоже не содержит `proc_pidinfo` (линкер выбрасывает
  неиспользуемую статистику памяти ядра) — правка страхует от случайного вызова.
- **Память моста — отдельным процессом на стенде** (`cmd/npmlab`, `bridge-tunlab.sh` с `ENGINE=mihomo`):
  см. `Documentation/Performance/memory-budget.md` §10. Абзац ниже — про процесс теста, а не про мост: рост до
  313 МиБ дали сам тест (неограниченный буфер журнала xray, буферы отправки и TIME_WAIT стека-«ОС» при
  непрерывной нагрузке ~75 МБ/с), а не утечка моста.
- Холостой RSS и 10-минутный прогон (`TestSoakRSS`, `NP_SOAK=10m`): пакетный путь → VLESS+REALITY+Vision →
  штатный xray, 4 потока непрерывно открывают и закрывают TCP-соединения (по 2 МиБ эхо) плюс UDP-датаграмма на
  каждое 20-е. Процесс теста до старта — 31,4 МиБ RSS, после старта в покое — 37,6 МиБ (+6,2 МиБ; куча 2 МиБ,
  28 горутин). Под нагрузкой: 11 142 соединения, 44,6 ГиБ, 0 ошибок, 0 потерь в очередях; RSS 126 МиБ на 30 с,
  196–207 МиБ на 1,5–4,5 мин, 232–239 МиБ на 5–9 мин, пик 313 МиБ на 9,5 мин; `heapLive` 37 → 110 МиБ,
  ~1400–1500 горутин. **Плато за 10 минут не достигнуто.** RSS включает стек-«ОС» теста (второй mipstack с
  TIME_WAIT всех 11 тыс. соединений), клиент и эхо — доля моста не выделена. С мостом Xray напрямую не
  сравнимо: там мост мерился отдельным процессом на tun ядра (RSS 165–180 МиБ, плато через 10–12 мин,
  `Benchmarks/results/bridge-2026-11-27/`), холостой RSS 31–34 МиБ. Прогон один, `connIdle`/`udp-timeout` по
  умолчанию (UDP 5 мин), без лимита памяти Go.
- `go test -race ./engine` — **FAIL, гонки внутри ядра** (кадров моста в конфликтующих доступах нет, кроме
  вызова `ApplyConfig`): 9 отчётов в собственной реализации Vision ядра (`transport/vless/vision.(*Conn)`:
  `FilterTLS`/`WriteBuffer`/`ReadBuffer`/`Upstream`) в тесте VLESS+REALITY+Vision — та же картина, что у Xray;
  2 отчёта `log.SetLevel` (запись в `ApplyConfig`) против `log.print` (чтение в любой горутине ядра) в
  тесте циклов. Третья гонка — `ApplyConfig` переписывает фильтры IP входящих при живых слушателях — снята:
  `Stop` закрывает слушатели до пустой конфигурации. Остальные тесты под `-race` проходят.

## Известные ограничения

- Под Apple собран и слинкован (CI), но не запускался ни на одном устройстве; срезы tvOS/visionOS — порт `GOOS=ios` с `clang -target`, как у моста Xray, Go-рантайм на этих системах не запускался.
- `tun.mode: "fd"` не реализован.
- Статистика без разбивки по inbound/outbound; закрытые соединения учитываются только в `total`.
- Ошибки `ApplyConfig` ядро только пишет в журнал; мост проверяет открытие `socks-port`/`mixed-port`/`port`,
  остальное (провайдеры, DNS-сервер, `listeners`) видно лишь в журнале.
- Разбор конфигурации может скачать geodata в `homeDir`, если правила используют `GEOIP`/`GEOSITE`.
- RX-контрольные суммы проверяются стеком (offload не заявлен), каждый пакет — отдельный вызов `stack.Write`.
