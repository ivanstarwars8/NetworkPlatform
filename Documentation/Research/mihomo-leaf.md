# mihomo и leaf — аудит по исходникам как кандидатов в дополнительные движки

Дата проверки: 2026-11-25. Источники (shallow-клоны, только чтение; SHA — `Documentation/Research/SOURCES-cores2.txt`):

| Репозиторий | Коммит | Ветка | Путь |
|---|---|---|---|
| MetaCubeX/mihomo | `0455d0d28c4526937380505153e65a843d8612e8` (2026-11-11) | `Meta` | `/root/.cache/np-research/mihomo` |
| eycorsican/leaf | `5e8d94759ce983eb8ac226c315024b55ff2bb7b0` (2026-09-10) | `master` | `/root/.cache/np-research/leaf` |
| metacubex/sing-tun | тег `v0.4.29` (версия из `mihomo/go.mod`) | — | клонирован во временный каталог, прочитан, в репозиторий не добавлен |
| eycorsican/netstack-lwip | `49434359ed59cae05092c1055396289ba2297389` (rev `4943435` из `leaf/Cargo.toml`) | — | то же |
| meh/rust-tun | тег `v0.7.21` (leaf требует `tun = "0.7"`) | — | отдельные файлы через `gh api` |
| KaringX/clashmi (Clash Mi) | HEAD на 2026-11-25 | — | отдельные файлы через `gh api` |

Пометки: **[V]** — видно в исходнике или официальном документе, путь или URL указан; **[U]** — не подтверждено (вторичный источник, вывод из чтения кода без сборки, по памяти).

Оговорки:

- Ничего не собиралось и не запускалось. Всё о скорости, памяти, размере и поведении на устройстве — только план измерений (раздел 5). Утверждений о производительности в документе нет.
- Внутренности `metacubex/mipstack` (TCP/IP-стек mihomo по умолчанию) и крейтов `reality-rs`, `netstack-smoltcp` не читались — только их метаданные и места подключения.
- Вопрос документа — годятся ли движки третьим/четвёртым за тем же Swift-слоем, что Xray-core и sing-box (ADR-0001: один движок на процесс расширения, приложение не линкует движок).

---

## 0. Короткие выводы

1. **Оба движка в штатном виде читают utun по файловому дескриптору.** Публичного API NetworkExtension для получения этого дескриптора нет, поэтому любой клиент на штатном TUN-входе mihomo или leaf использует тот же недокументированный приём, что sing-box и Xray (перебор fd или KVC `packetFlow.socket.fileDescriptor`). Новых рисков относительно R-08 они не добавляют, но и не снимают его. [V — код; раздел 1.3, 2.3]
2. **У обоих путь через `NEPacketTunnelFlow.readPackets/writePackets` архитектурно возможен, но только правкой движка.** В mihomo стек `mips` работает с любым `tun.Tun` (`io.ReadWriter`), а создание устройства зашито в одну функцию; в leaf стек lwIP сам является `Sink/Stream` пакетов и fd не требует, но TUN-вход привязан к `tun::AsyncDevice`. Ни то ни другое не собрано и не проверено. [V — структура; U — работоспособность]
3. **mihomo — GPL-3.0** (полный текст GPLv3 в `LICENSE` ветки `Meta`). Метка «MIT» в GitHub API относится к ветке `main` с посторонним содержимым и к коду движка не относится. Лицензионно mihomo стоит рядом с sing-box, а не с Xray. [V]
4. **mihomo по протоколам — надмножество большей части того, что есть у пары Xray + sing-box**, включая VLESS+REALITY+Vision и XHTTP с раздельным download. Уникальное — прокси-провайдеры и rule-провайдеры формата Clash, группы `load-balance`/`fallback`/`url-test`, Clash YAML как формат, несколько редких протоколов. [V — раздел 1.1, 1.6]
5. **leaf по протоколам — узкое подмножество**: SOCKS5, Shadowsocks (4 AEAD-шифра, без 2022), Trojan, VMess, VLESS (TCP всегда с Vision), REALITY, TLS, WebSocket, собственные QUIC/AMux/MPTP. Нет Hysteria/Hysteria2, TUIC, WireGuard, XHTTP, gRPC, SSH, Snell. [V — раздел 2.1]
6. **leaf — проект одного автора** (17 из 17 коммитов за полгода), две его ключевые зависимости (`netstack-lwip`, `reality-rs`) лежат в репозиториях без файла лицензии. [V — раздел 2.6, 2.7]
7. Вердикты — раздел 4.

---

## 1. mihomo

### 1.1. Протоколы и транспорты (клиентская сторона)

Типы исходящих — `adapter/parser.go` (ветки `case "<type>"`) и `constant/adapters.go`: [V]

`ss`, `ssr`, `socks5`, `http`, `vmess`, `vless`, `snell`, `trojan`, `hysteria`, `hysteria2`, `wireguard`, `tuic`, `shadowquic`, `gost-relay`, `ssh`, `mieru`, `anytls`, `sudoku`, `masque`, `trusttunnel`, `openvpn`, `tailscale`, `zerotier`, `easytier`, служебные `direct`, `dns`, `reject`, `rematch`.

| Что | Состояние | Где видно |
|---|---|---|
| VLESS | есть; поля `flow`, `encryption`, `packet-addr`, `xudp`, `packet-encoding` | `adapter/outbound/vless.go:60–90` [V] |
| XTLS Vision | есть | `transport/vless/vision/` [V] |
| VLESS encryption | есть отдельный пакет | `transport/vless/encryption/` [V] |
| REALITY (клиент) | есть; `reality-opts` у VLESS и Trojan | `adapter/outbound/reality.go`, `vless.go:77`, `trojan.go:64` [V] |
| XHTTP | есть: `mode`, параметры `x-padding-*`, `sc-max-each-post-bytes`, `reuse-settings` (в коде помечено «aka XMUX»), `download-settings` с отдельными сервером/портом/TLS/REALITY | `adapter/outbound/vless.go:94–150`, `transport/xhttp/` [V] |
| Транспорты VLESS/VMess/Trojan | `http-opts`, `h2-opts`, `grpc-opts`, `ws-opts`, `xhttp-opts` | `vless.go:78–82`, `transport/gun/`, `transport/vmess/` [V] |
| VMess | есть | `adapter/outbound/vmess.go`, `transport/vmess/` [V] |
| Trojan | есть; `ss-opts` (trojan-go), REALITY, gRPC, WS | `adapter/outbound/trojan.go:47–75` [V] |
| Shadowsocks | есть; плагины `obfs`, `v2ray-plugin`, `gost-plugin`, `shadow-tls`, `restls`, `jls`, `kcptun` | `adapter/outbound/shadowsocks.go:321–454` [V] |
| Shadowsocks 2022 | через `github.com/metacubex/sing-shadowsocks2` | `go.mod` [V]; набор методов не перечислялся [U] |
| SSR | есть | `adapter/outbound/shadowsocksr.go`, `transport/ssr/` [V] |
| Snell | есть; в коде константы версий до `Version6`, UDP с версии, проверяемой в `snell.go:263` | `adapter/outbound/snell.go` [V] |
| Hysteria (v1) | есть | `adapter/outbound/hysteria.go`, `transport/hysteria/` [V] |
| Hysteria2 | есть; port hopping (`ports`, `hop-interval`), `obfs`, `bbr-profile`, `realm-opts` | `adapter/outbound/hysteria2.go:41–88` [V] |
| TUIC | есть; v4 и v5 | `adapter/outbound/tuic.go`, `transport/tuic/v4`, `v5` [V] |
| WireGuard | есть; `amnezia-wg-option` (поля `jc`, `jmin`, `jmax`, `s1…s4`, `h1…h4`, `i1…i5`) | `adapter/outbound/wireguard.go:75–131` [V] |
| MASQUE | есть | `adapter/outbound/masque.go`, `transport/masque/` [V] |
| SSH | есть | `adapter/outbound/ssh.go` [V] |
| AnyTLS | есть | `adapter/outbound/anytls.go`, `transport/anytls/` [V] |
| ShadowTLS | как плагин SS и как `shadow-tls-opts` у VLESS/Trojan | `shadowsocks.go:396`, `vless.go:74` [V] |
| Naive | **нет** — ни типа, ни упоминания в `*.go` | `adapter/parser.go`; `grep -ri naive` = 0 файлов [V] |
| Мультиплексирование | `smux` (опция `sing-mux`): `protocol`, `max-connections`, `min-streams`, `max-streams`, `padding`, `brutal-opts`; XUDP у VLESS; XMUX у XHTTP | `adapter/outbound/singmux.go:24–38` [V] |
| UDP | флаг `udp` у большинства исходящих; `udp-over-stream` у TUIC | поля `proxy:"udp"` [V]; фактическое поведение по протоколам не проверялось [U] |
| Цепочки | `dialer-proxy` у любого исходящего; группа `relay` | `adapter/outbound/base.go:199`, `adapter/outboundgroup/parser.go:216` [V] |
| TFO, MPTCP | опции `tfo`, `mptcp` | `adapter/outbound/base.go:194–195` [V] |
| uTLS-отпечаток | `client-fingerprint`, `global-client-fingerprint`; модуль `github.com/metacubex/utls v1.9.0-alpha.1` | `go.mod`, `config/config.go:445` [V] |
| ECH | `ech-opts` | `adapter/outbound/ech.go` [V] |

Особенность реализации: mihomo держит `go 1.20` в `go.mod` и для этого использует собственные форки частей стандартной библиотеки и криптографии (`metacubex/tls`, `metacubex/http`, `metacubex/mlkem`, `metacubex/hpke`, `metacubex/chacha` и др.) плюс форки `quic-go`, `utls`, `gvisor`, `wireguard-go`, `tailscale`. [V — `go.mod`]

### 1.2. Маршрутизация, DNS, группы, перезагрузка, API

- **Правила** (`rules/parser.go`): `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `DOMAIN-REGEX`, `DOMAIN-WILDCARD`, `GEOSITE`, `GEOIP`, `SRC-GEOIP`, `IP-ASN`, `SRC-IP-ASN`, `IP-CIDR`/`IP-CIDR6`, `SRC-IP-CIDR`, `IP-SUFFIX`, `SRC-IP-SUFFIX`, `SRC-PORT`, `DST-PORT`, `IN-PORT`, `DSCP`, `PROCESS-NAME`/`PROCESS-PATH` и их `-REGEX`/`-WILDCARD`, `NETWORK`, `UID`, `IN-TYPE`, `IN-USER`, `IN-NAME`, `REMATCH-NAME`, `SUB-RULE`, `AND`/`OR`/`NOT`, `RULE-SET`, `MATCH`. [V]
- **Rule-providers** (`rules/provider/`): источники `file`, `http`, `inline`; поведения `domain`, `ipcidr`, `classical` (по именам файлов `*_strategy.go`); есть собственный бинарный формат (`mrs_reader.go`, `mrs_converter.go`). Обновление файла отслеживается через `fswatch` (`component/resource/fetcher.go:215`). [V]
- **Proxy-providers** (`adapter/provider/`): подписки с health-check и `override`. [V]
- **Группы** (`adapter/outboundgroup/parser.go:188–216`): `select`, `url-test`, `fallback`, `load-balance`, `relay`. [V]
- **DNS** (`dns/util.go:121–135`, файлы `dns/`): схемы `tls` (DoT), `https` (DoH), `quic` (DoQ), `dhcp`, `system`, `rcode`, `tailscale`, `easytier`, плюс обычный UDP/TCP; `nameserver-policy`, `proxy-server-nameserver`, `direct-nameserver`, EDNS client subnet. [V]
- **fake-ip**: `enhanced-mode`, `fake-ip-range`, `fake-ip-range6`, `fake-ip-filter`, `fake-ip-filter-mode`, `fake-ip-ttl`; пул сохраняется (`store-fake-ip`). `config/config.go:235–240, 365`, `component/fakeip/`. [V]
- **Sniffing**: HTTP, TLS, QUIC — `component/sniffer/`. [V]
- **Горячая перезагрузка**: `hub/executor.ApplyConfig` применяет новый конфиг к живому процессу (прокси, правила, DNS, слушатели, TUN); вызывается из `PUT /configs`, `PATCH /configs` и по `SIGHUP` (`main.go`). [V]
- **API** (`hub/route/server.go:123–141`): `/logs`, `/traffic`, `/memory`, `/version`, `/configs`, `/proxies`, `/group`, `/rules`, `/connections`, `/providers/proxies`, `/providers/rules`, `/cache`, `/dns`, `/storage`, `/restart`, `/upgrade`, `/debug`. Транспорт — TCP, TLS, Unix-сокет или Windows pipe (`external-controller*`). [V]
- **Статистика** — процесс-глобальный `statistic.DefaultManager` (`tunnel/statistic/manager.go`): `Now()`, `Total()`, `Snapshot()`, `Memory()`. Доступна из Go без HTTP. [V]

### 1.3. TUN и TCP/IP-стек

**Стек.** `listener/sing_tun/server.go` использует форк `github.com/metacubex/sing-tun`. Варианты (`constant/tun.go`, `sing-tun/stack.go`): `mips` (**по умолчанию**: `config/config.go:548`, а в `NewStack` пустая строка тоже даёт `mips`), `gvisor`, `mixed`, `system`. [V]

- `mips` — `github.com/metacubex/mipstack`: «small, pure-Go userspace IP stack developed for mihomo», MPL-2.0, репозиторий создан 2026-08-03 (README и метаданные репозитория, https://github.com/metacubex/mipstack). Контроль перегрузки — файлы `congestion_cubic.go`, `congestion_bbr.go`, `congestion_bbr3.go`, `congestion_reno.go`. [V] Стеку на момент аудита менее четырёх месяцев. [V — дата; выводы о зрелости — U]
- `gvisor` и `mixed` требуют тега `with_gvisor` (`sing-tun/stack_gvisor_stub.go`); штатные сборки mihomo его ставят (`Makefile`, `.github/workflows/build.yml:245`). [V]
- `system` поднимает локальные `net.Listener` и переписывает адреса (`sing-tun/stack_system.go:123–136`). [V]

**Как пакеты попадают в стек на Darwin.** `sing-tun/tun_darwin.go`:

- Опция `file-descriptor` (`config/config.go:319`) → `tun.Options.FileDescriptor`. Если она задана, `tun.New` берёт дескриптор как есть, ставит `O_NONBLOCK` и оборачивает в `os.NewFile`; **дублирования (`dup`) нет**, `Close()` закрывает сам дескриптор. Системный DNS в этом режиме не трогается (комментарий: «Supplied descriptors are configured by their owner (e.g. NetworkExtension)»). [V — `tun_darwin.go:103–160, 475–480`]
- Без дескриптора ядро само открывает `utunN` через `com.apple.net.utun_control`, назначает адреса, маршруты и запускает `dscacheutil -flushcache` — путь macOS с root, к NetworkExtension неприменим. [V]
- Имя интерфейса для переданного fd — `getsockopt(SYSPROTO_CONTROL, UTUN_OPT_IFNAME)` (`listener/sing_tun/tun_name_darwin.go`). [V]

**Нужен ли «сырой» fd?** В штатном коде — да: `listener/sing_tun/server_notwindows.go` содержит единственную функцию `tunNew`, вызывающую `tun.New(options)`. [V] Но сам стек `mips` принимает любой `tun.Tun` — интерфейс из `io.ReadWriter` и `Close()` (`sing-tun/tun.go`), а для устройства, не являющегося `DarwinTUN`, читает через `device.Read(buffer)` без 4-байтового заголовка и пишет через `s.tun.Write(packet)` (`stack_mipstack.go:158–176, 500–506`). [V] Значит, реализация `tun.Tun`, наполняемая из колбэков `readPackets` и отдающая пакеты в `writePackets`, возможна ценой правки одной функции в mihomo (форк). Это не собиралось. [U]

**Существующие Apple-клиенты на mihomo.**

- **Clash Mi** (KaringX/clashmi, GPL-3.0, README заявляет App Store `id6744321968` и TestFlight). Расширение импортирует gomobile-фреймворк `Libclash` и реализует `LibclashPlatformInterfaceProtocol.openTun`. Дескриптор берётся так: сначала **приватный KVC** `tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor")`, при неудаче — перебор fd `0…1024` с `getsockopt(fd, 2, 2, …)` и проверкой префикса `utun`, и в конце снова KVC. `readPackets`/`writePackets` не используются. [V — `bind/apple/LibVpnCore/ExtensionPlatformInterface.swift:196–227`] Исходник Go-обёртки `Libclash` в дереве clashmi не найден; есть форк KaringX/mihomo, в нём каталогов с именами `libclash`/`mobile`/`bind` поиском не обнаружено. [V — поиск по дереву; U — где лежит обёртка]
- В upstream mihomo **нет** ни `import "C"` (кроме `android_tz.go`), ни каталога для gomobile, ни цели `c-archive`, ни iOS в матрице CI (`.github/workflows/build.yml`: только `darwin/amd64`, `darwin/arm64` как CLI). CI уведомляет лишь ClashMetaForAndroid (`trigger-cmfa-update.yml`). [V]
- Сторонний пример сборки: `gibaragibara/mihomo-ios-core-builder` — обёртка `Start/Stop/Reload/Health` над `hub.Parse` и `executor.Shutdown`, `gomobile bind -target=ios,iossimulator` на Go 1.26.x с `mihomo v1.19.27`; последний запуск workflow — `success` (2026-06-11). Репозиторий без звёзд; это свидетельство того, что сборка под iOS проходит, а не того, что туннель работает. [V — https://github.com/gibaragibara/mihomo-ios-core-builder; U — работоспособность]

**Недокументированные приёмы в самом движке (важно для App Store).**

1. `recvmsgx: true` **по умолчанию** (`config/config.go:553`): чтение utun идёт прямым системным вызовом `SYS_RECVMSG_X` (`sing-tun/internal/rawfile_darwin/rawfile.go:94`). `recvmsg_x`/`sendmsg_x` не входят в публичный SDK. Отключается опцией `recvmsgx: false`; тогда используется обычный `read`. `sendmsgx` по умолчанию выключен с комментарием в коде: «if enabled, the kernel may freeze during multi-thread downloads». [V — код; U — отношение ревью App Store]
2. `component/memory/memory_darwin.go:48` импортирует `proc_pidinfo` из `libSystem` и вызывает его из менеджера статистики (`tunnel/statistic/manager.go:99`). Заголовок `libproc.h` в iOS SDK отсутствует. Код компилируется для любого `GOOS` из семейства Darwin; опцией не отключается — нужна правка. [V — код; U — отсутствие в iOS SDK по памяти и реакция ревью]
3. `component/process/process_darwin.go` читает `sysctl net.inet.tcp.pcblist_n` для поиска процесса; отключается `find-process-mode: off`. [V — код; U — поведение в песочнице iOS]

**Копирования на пути пакета** (по чтению `sing-tun`, стек `mips`, дескриптор передан):

| Этап | Копирований | Основание |
|---|---|---|
| ядро → буфер из пула (`recvmsg_x`, пачкой до `512 КиБ / MTU + 1` пакетов) либо `read` в один переиспользуемый буфер | 1 (ядро → пользователь) | `tun_darwin.go:103, 404–440`; `stack_mipstack.go:167–171` [V] |
| буфер → `mipstack.Stack.Write` | 0 в sing-tun (комментарий «without copying received packets») | `stack_mipstack.go:229–246` [V]; внутри mipstack — не читалось [U] |
| `mipstack.Stack.Read` → заранее выделенные буферы с запасом 4 байта под заголовок | не менее 1 внутри стека | `stack_mipstack.go:384–393` [V — буферы]; [U — число копий внутри] |
| буфер → utun (`write`, заголовок семейства пишется в запас) | 1 (пользователь → ядро), без промежуточной копии | `stack_mipstack.go:483–498` [V] |

Итого на границе TUN — по одной копии ядро↔пользователь в каждую сторону без дополнительных копий в sing-tun; число копий внутри mipstack и между стеком и исходящим соединением не установлено. Вариант с колбэками NE добавит как минимум одну копию в каждую сторону (`Data` ↔ `[]byte` через границу Swift/Go). [U]

### 1.4. Встраивание

- **Готового C ABI или gomobile-пакета нет** (раздел 1.3). Нужна собственная обёртка — как мост Xray в ADR-0001 §4. Точки входа: `hub.Parse(configBytes, options...)`, `executor.ParseWithBytes`, `executor.ApplyConfig`, `executor.Shutdown`, `statistic.DefaultManager`. [V]
- **Глобальное состояние.** Туннель — набор пакетных переменных (`tunnel/tunnel.go:40–70`: `proxies`, `rules`, `listeners`, `natTable`, `status`, `mode`), `var Tunnel = tunnel{}`; так же устроены резолвер, статистика, `dialer.DefaultSocketHook`, `dialer.DefaultInterfaceFinder`. Двух экземпляров в процессе быть не может. [V]
- **Повторный запуск в одном процессе.** Модель mihomo — один долгоживущий процесс с повторным `ApplyConfig`. `executor.Shutdown()` делает только `listener.Cleanup()` (закрывает TUN-слушатель), `tproxy.CleanupTProxyIPTables()` и сохраняет пул fake-ip — прокси, провайдеры, DNS-клиенты и горутины health-check при этом не останавливаются. [V — `hub/executor/executor.go:532–538`, `listener/listener.go`] Полной остановки движка без завершения процесса в коде не видно; «остановить» означает применить конфиг без TUN и без прокси. Утечки при серии старт/стоп не измерялись. [U]
- **Сигналы и выход.** `main.go` подменяет `net.DefaultResolver.Dial` функцией, вызывающей `os.Exit(2)`; это код `main`, в библиотечную обёртку он не попадёт, но показывает, что случайное обращение к системному резолверу считается ошибкой. `log.Fatalln` в пакетах движка — не проверялось. [V / U]
- **Память.** Тег `with_low_memory` уменьшает буферы реле: TCP 32 → 16 КиБ, UDP 16 → 8 КиБ (`common/pool/buffer_low_memory.go`). `SetMemoryLimit`/`SetGCPercent` движок не вызывает (поиск по `*.go`); единственный вызов `debug.FreeOSMemory()` — в `PUT /debug/gc`. `ApplyConfig` вызывает `runtime.GC()`. `processors-per-channel: 1` по умолчанию с комментарием о памяти. Теги `no_tailscale`, `no_zerotier`, `no_easytier`, `no_fake_tcp` убирают тяжёлые подсистемы (`constant/features/`). Лимит памяти и GC придётся выставлять в обёртке. [V]
- **Версия Go.** `go.mod`: `go 1.20`. CI собирает на 1.26 из собственного патченого тулчейна `MetaCubeX/go` (патчи ради Windows 7 и macOS 10.13). Директив `go:linkname` в репозитории 10 (подсчёт `grep`), флаг `-checklinkname=0` в сборке не используется. [V]
- **Цели Apple.** Go имеет `GOOS=ios`; tvOS и visionOS — не отдельные `GOOS`. Положение такое же, как у моста Xray: `c-archive` под SDK `appletvos`/`xros` — предмет экспериментов E-1 и E-6 из ADR-0001. Для mihomo это не проверялось никем из найденных клиентов. [U]

### 1.5. Совместимость с Xray-core и sing-box в одном Go-бинарнике

Сравнение `go.mod` трёх клонов (версии — [V], последствия — [U]).

**Форки — пути модулей у mihomo свои, конфликта импортов нет:**

| Назначение | mihomo | sing-box | Xray-core |
|---|---|---|---|
| QUIC | `metacubex/quic-go` v0.61.1-0.2026…, плюс `metacubex/jls-quic-go` | `sagernet/quic-go` | `apernet/quic-go` |
| uTLS | `metacubex/utls` v1.9.0-alpha.1 | **тот же модуль, та же версия** | `refraction-networking/utls` |
| gVisor | `metacubex/gvisor` (indirect) | `sagernet/gvisor` | `gvisor.dev/gvisor` |
| WireGuard | `metacubex/wireguard-go`, `metacubex/amneziawg-go`, `metacubex/sing-wireguard` | `sagernet/wireguard-go` | `golang.zx2c4.com/wireguard` |
| sing-* | `metacubex/sing`, `sing-tun`, `sing-mux`, `sing-quic`, `sing-vmess`, `sing-shadowsocks`, `sing-shadowsocks2` | `sagernet/sing*` | — |
| Tailscale | `metacubex/tailscale` | `sagernet/tailscale` | — |
| TLS / HTTP | `metacubex/tls`, `metacubex/http` (форки stdlib) | stdlib | stdlib + `xtls/reality` |

Следствие: в общем бинарнике окажутся **третий** QUIC-стек, третий gVisor, третий WireGuard и второй полный набор `sing-*`, а также копии `crypto/tls` и `net/http`. Единственный действительно общий модуль из «тяжёлых» — `metacubex/utls`, и версии совпадают.

**Общие модули (MVS).** С sing-box пересекаются 50 модулей, с Xray-core — 17. mihomo держит старые версии ради Go 1.20 (блок «lastest version compatible with golang1.20» в `go.mod`), поэтому в общем графе именно его зависимости поднимутся сильнее всех:

| Модуль | mihomo | sing-box | Xray-core |
|---|---|---|---|
| `golang.org/x/crypto` | v0.33.0 | v0.54.0 | v0.59.0 |
| `golang.org/x/net` | v0.35.0 | v0.57.0 | v0.63.0 |
| `golang.org/x/sys` | v0.30.0 | v0.47.0 | v0.50.0 |
| `google.golang.org/protobuf` | v1.34.2 (с `replace`, см. ниже) | v1.36.11 | v1.36.12 |
| `github.com/miekg/dns` | v1.1.63 | v1.1.72 | v1.1.73 |
| `github.com/klauspost/compress` | v1.17.9 | v1.19.1 | v1.20.4 |
| `github.com/pires/go-proxyproto` | v0.8.0 | v0.8.1 | v0.16.0 |
| `github.com/insomniacslk/dhcp` | 2025-01-09 | 2026-02-20 | — |
| `github.com/mdlayher/netlink` | v1.7.2 | v1.11.2 | — |

**Конкретные точки конфликта:**

1. `replace google.golang.org/protobuf => github.com/metacubex/protobuf-go` в `go.mod` mihomo (комментарий ссылается на golang/protobuf#1704, «Method dead code elimination is disabled…»). Директивы `replace` действуют только в главном модуле: в мосте замена либо потеряется, либо, будучи скопированной, подменит protobuf и для Xray-core, у которого 83 `.proto`. [V — директива; U — последствия]
2. Версия Go: mihomo объявляет 1.20 и проверяется CI на 1.20–1.26; Xray требует 1.27; sing-box собирается на 1.26.10. Собирается ли mihomo на 1.27 — неизвестно. [V — версии; U — исход]
3. Реестр protobuf: у mihomo два `.proto` — `transport/vless/config.proto` (пакет `mihomo.transport.vless`) и `component/geodata/router/config.proto`. Имена файлов и пакетов с Xray (`xray.*`, `proxy/vless/encoding/addons.proto`) не совпадают. [V]
4. Все пункты ADR-0001 «против варианта A» (общий рантайм, `init()` всех ядер, общий лимит памяти, паника роняет всё) применимы без изменений; у mihomo к ним добавляется глобальный туннель без полной остановки (раздел 1.4).

Вывод по совместимости: правило ADR-0001 «один движок на процесс» для mihomo обязательно в той же мере. Третий движок — это третье расширение или отдельный вариант сборки, не добавка в существующий мост.

### 1.6. Чего нет ни у Xray-core, ни у sing-box

Проверка — список каталогов `sing-box/protocol/` и `Xray-core/proxy/` плюс подсчёт файлов `*.go` (без тестов) с упоминанием слова в трёх клонах. Подсчёт упоминаний — эвристика, не доказательство реализации. [V — подсчёты; U — полнота]

| Возможность mihomo | Файлов с упоминанием: mihomo / sing-box / Xray | Замечание |
|---|---|---|
| Mieru | 11 / 0 / 0 | |
| TrustTunnel | 16 / 0 / 0 | |
| ShadowQUIC | 20 / 0 / 0 | |
| Restls | 37 / 0 / 0 | |
| TLSMirror | 20 / 0 / 0 | |
| kcptun (плагин SS) | 12 / 0 / 0 | |
| ZeroTier | 10 / 0 / 0 | отключается тегом `no_zerotier` |
| EasyTier | 16 / 0 / 0 | отключается тегом `no_easytier` |
| JLS | 49 / 6 / 0 | в sing-box каталога протокола нет |
| SSR | 4 / 8 / 1 | каталога `shadowsocksr` в `sing-box/protocol/` нет; статус в sing-box не выяснялся [U] |
| Sudoku | 44 / 0 / 9 | в Xray упоминается; чем именно — не выяснялось [U] |
| AmneziaWG-параметры | 4 / 0 / 1 | |
| Proxy-providers (подписка как объект конфигурации) | 7 / 1 / 0 | |
| Группа `load-balance` | есть / нет каталога / балансировщики есть в Xray | у sing-box — `selector` и `urltest` (каталог `protocol/group`) |

Главное отличие не в редких протоколах, а в модели конфигурации: **Clash YAML, proxy-providers, rule-providers и группы** — формат, в котором распространяется большая часть подписок. Сейчас по ADR-0002 такие профили должны компилироваться Swift-слоем в конфиг Xray или sing-box; mihomo исполняет их как есть.

Чего у mihomo нет, а у других есть: Naive (есть в sing-box), mKCP/finalmask и XDRIVE (Xray, см. `xray.md` §2.6–2.9; в mihomo есть каталог `transport/mkcp`, его применимость к клиенту не выяснялась [U]).

### 1.7. Зрелость

- Релизы: `v1.19.28` (2026-07-08) … `v1.19.34` (2026-11-11), семь стабильных за четыре месяца. [V — `gh api repos/MetaCubeX/mihomo/releases`]
- Активность: 76 коммитов в ветке `Alpha` с 2026-08-25, из них 51 — `wwqgtxx`, следующий автор — 5. Проект фактически ведёт один человек. [V — `gh api …/commits?sha=Alpha&since=2026-08-25`]
- Тесты: 129 файлов `*_test.go` в основном модуле; отдельный модуль `test/` с интеграционными тестами на Docker (`test/README.md`, `docker_test.go`); CI запускает `go test ./... -tags with_gvisor` только на `linux/amd64` (`build.yml:227`). На Darwin тесты в CI не выполняются. [V]
- 36 077 звёзд, 686 открытых issues (метаданные репозитория, 2026-11-25). [V]
- Ловушка: ветка по умолчанию `main` содержит посторонний Python-проект под MIT; GitHub API показывает для репозитория `license: MIT` и авторов `KT-Yeh`, `seriaati`. Рабочие ветки — `Meta` (релизы) и `Alpha` (разработка). Автоматические сканеры лицензий по GitHub API дадут неверный ответ. [V — `gh api repos/MetaCubeX/mihomo`, `…/contents/README.md?ref=main`]

### 1.8. Лицензии

- **mihomo: GPL-3.0.** `LICENSE` в ветке `Meta` — полный текст GNU GPL v3 (md5 `1ebbd3e34237af26da5dc08a4e440464`, 674 строки); `README.md:99`: «This software is released under the GPL-3.0 license». Заголовков SPDX и формулировки «or later» в исходниках нет — вариант «only» или «or-later» текстом проекта не определён. [V]
- `metacubex/sing-tun`: GPL-3.0-or-later (шапка `LICENSE`: «either version 3 of the License, or (at your option) any later version», Copyright nekohasekai). [V]
- `metacubex/mipstack`: MPL-2.0 (метаданные GitHub). [V]
- Остальные форки `metacubex/*` (quic-go, utls, gvisor, wireguard-go, tailscale, sing-*) наследуют лицензии оригиналов; поштучно не проверялись. [U]
- **Следствия для App Store** те же, что для sing-box (`LICENSE_AUDIT.md` §4–5): бинарник с mihomo — производная работа под GPLv3; вариант сборки без GPL-кода mihomo не содержит. Clash Mi (GPL-3.0) находится в App Store — факт наличия, не правовая оценка. [V — факт; U — оценка]
- Дополнительных условий (как у sing-box) в `LICENSE` mihomo нет. [V]

---

## 2. leaf

### 2.1. Протоколы и транспорты

Источник — features в `leaf/Cargo.toml`, каталоги `leaf/src/proxy/`, схема `leaf/src/config/internal/config.proto`, таблица в `README.md`. [V]

| Что | Состояние | Где видно |
|---|---|---|
| SOCKS5 | вход и выход, UDP | `proxy/socks/` |
| Shadowsocks | вход и выход, UDP; шифры `chacha20-poly1305`, `chacha20-ietf-poly1305`, `aes-256-gcm`, `aes-128-gcm`. **2022 нет**, потоковых шифров нет | `common/crypto.rs:52–55, 222–225` |
| Trojan | вход и выход, UDP | `proxy/trojan/` |
| VMess | только выход; поля `uuid`, `security` | `proxy/vmess/`, `config.proto:201–206` |
| VLESS | только выход; поля — адрес, порт, `uuid`. Для TCP заголовок **всегда** несёт flow `xtls-rprx-vision` — выбора flow в схеме нет | `proxy/vless/stream.rs:1–17`, `config.proto:208–212` |
| REALITY | только выход; `server_name`, `public_key`, `short_id` | `proxy/reality/`, `config.proto:214–218` |
| TLS | вход и выход; ALPN, ECH | `proxy/tls/`, `config.proto:156–165` |
| WebSocket | вход и выход | `proxy/ws/` |
| QUIC | собственный транспорт leaf (потоки QUIC на `quinn`), не Hysteria и не TUIC | `proxy/quic/`, README |
| AMux | собственное мультиплексирование leaf | `proxy/amux/` |
| MPTP | собственная агрегация нескольких путей | `proxy/mptp/`, `docs/mptp_architecture.md` |
| obfs | `http`, `tls` (simple-obfs) | `proxy/obfs/` |
| Группы | `failover` (с health-check), `tryall`, `static`, `select`; `chain` — цепочки | `proxy/failover/`, `tryall/`, `static/`, `select/`, `chain/` |
| HTTP | только вход | README |

`outbound-select` в наборе `all-endpoints` **закомментирован** (`leaf/Cargo.toml`), то есть в штатной сборке ручного выбора сервера нет. [V]

Отсутствуют (поиск по `leaf/src`, 0 файлов): Hysteria, Hysteria2, TUIC, WireGuard, Snell, XHTTP, gRPC; SSH, SSR, AnyTLS, ShadowTLS, Naive — нет ни features, ни каталогов. [V]

### 2.2. Маршрутизация, DNS, перезагрузка, статистика

- **Правила** (`config.proto:290–320`): домен (`PLAIN`, `DOMAIN`, `FULL`), `ip_cidrs`, `mmdbs` (GeoIP по MaxMind), `port_ranges`, `networks`, `inbound_tags`, `process_names`. В формате `.conf` есть ещё `EXTERNAL` (внешние файлы; `config/external_rule.rs`, `geosite.proto`). Логических правил и rule-providers с автообновлением нет. [V]
- **DNS** (`config.proto:5–12`, `app/dns/`): список серверов и статические `hosts`; в клиенте есть ветка DoH (`app/dns/client/types.rs:14–23`, `client.rs:141–190`). DoT и DoQ — не найдены. [V — наличие DoH; U — полнота поиска]
- **fake-ip** — свойство TUN-входа: списки `fake_dns_include`/`fake_dns_exclude`, ответы генерируются на запросы к порту 53 (`proxy/tun/inbound.rs`, `app/fake_dns.rs`). [V]
- **Sniffing** TLS/HTTP/DNS — переключатели в переменных окружения (`option/mod.rs:117–160`). [V]
- **Перезагрузка**: `leaf_reload(rt_id)` перечитывает **файл** конфигурации и заменяет роутер, DNS и исходящие; входы и FakeDns не перезагружаются (TODO в коде). При запуске из строки (`leaf_run_with_config_string`) перезагрузка возвращает `ERR_NO_CONFIG_FILE`. Автоперезагрузка по изменению файла — feature `auto-reload` (`notify`), включена в `leaf-ffi` по умолчанию. [V — `leaf/src/lib.rs:218–240`]
- **Статистика**: `app/stat_manager.rs` считает байты и состояние по соединениям. Наружу отдаётся **только** через HTTP API (`app/api/api_server.rs:378–410`: `/api/v1/runtime/stat/json`, `/api/v1/runtime/reload`, `/api/v1/runtime/shutdown`, `/api/v1/app/outbound/select*` и др.), который слушает TCP-адрес из переменной `API_LISTEN`. Функции FFI для счётчиков трафика нет. [V]

### 2.3. TUN и TCP/IP-стек

**Стеки** (`leaf/Cargo.toml`, feature `inbound-tun`): `netstack-lwip` (по умолчанию) и `netstack-smoltcp`; выбор — поле `tun2socks` (`"smoltcp"` либо всё остальное → lwIP). [V — `proxy/tun/inbound.rs:616–629`]

- `netstack-lwip` — обёртка автора leaf над lwIP на C (`eycorsican/netstack-lwip`, git-зависимость по ревизии `4943435`). lwIP в этой конфигурации — **процесс-глобальный синглтон**: «Only one NetStack may exist at a time», флаг `NETSTACK_ALIVE` сбрасывается в `Drop`. [V — `netstack-lwip/src/stack.rs:20–26`]
- Размеры под iOS зашиты на этапе компиляции (`src/lwip/custom/lwipopts.h`, ветка `TARGET_OS_IPHONE`): `MEMP_NUM_TCP_PCB 512`, `MEMP_NUM_TCP_SEG 4096`, `TCP_WND 16×MSS`, `TCP_SND_BUF 8×MSS`, `MEM_SIZE 1 МиБ`. Комментарий: iOS рассчитан примерно на 512 одновременных TCP-соединений, чтобы уложиться в бюджет Network Extension. [V] Это жёсткий предел на число TCP-соединений через туннель. [U — поведение при исчерпании; комментарий говорит об ERR_MEM для сегментов, не для pcb]
- MTU интерфейса lwIP зашит: `(*netif_list).mtu = 1500` (`stack.rs:117`). [V]
- `netstack-smoltcp` — форк `cavivie/netstack-smoltcp` (Apache-2.0), подключён по ветке `pr-16-initialize-unfilled`, без закреплённой ревизии. [V]

**Как пакеты попадают в стек.** `proxy/tun/inbound.rs:new`: [V]

- `settings.fd >= 0` → `tun::Configuration::raw_fd(fd)`; иначе создание устройства по имени (десктоп).
- Крейт `tun` 0.7 на iOS/tvOS (`src/platform/ios/device.rs`) без `raw_fd` возвращает `Error::InvalidConfig` — то есть **на iOS дескриптор обязателен**. [V]
- Дальше `tun::create_as_async` → `into_framed()` → два цикла: устройство → `stack_sink`, `stack_stream` → устройство.

**Сам стек fd не требует**: `NetStack` реализует `Sink<Vec<u8>>` и `Stream<Item = io::Result<Vec<u8>>>` — принимает и отдаёт готовые IP-пакеты (`netstack-lwip/src/stack.rs:154–250`). [V] Вход, принимающий пакеты из колбэков `NEPacketTunnelFlow`, технически сводится к замене `tun::AsyncDevice` парой каналов, но такого входа в leaf нет: нужен новый тип inbound и новые функции FFI (форк). [U — не написано и не проверено]

**Как получают дескриптор существующие iOS-приложения.** В репозитории leaf нет ни одного Swift-файла и нет указаний, откуда брать fd; публичного iOS-клиента автора по адресу `eycorsican/ileaf` на момент проверки нет (HTTP 404). [V] Пример стороннего клиента (`smkafilive/vpn`, `ios/Shared/LeafAdapter.swift:85–90`, найден поиском кода по `leaf_run_with_options`): перебор fd с `getsockopt(fd, 2, 2, …)` и проверкой префикса `utun`, запасной путь — KVC `packetFlow.value(forKey: "socket.fileDescriptor")`; затем `leaf_run_with_options(id, path, true, true, true, 8, 1024*32)`. [V — один пример; U — что так делают все]

Ответ на вопрос о публичных API: **штатный TUN-вход leaf на iOS работает только с дескриптором utun, а получить его можно лишь недокументированным способом** — перебором дескрипторов процесса (системные вызовы публичные, но расчёт на внутреннее устройство NetworkExtension) либо приватным KVC. `readPackets`/`writePackets` в найденных клиентах не используются.

**Копирования на пути пакета** (lwIP, дескриптор передан; по чтению `leaf`, `rust-tun` v0.7.21, `netstack-lwip`):

Входящий пакет, TCP:

| № | Этап | Что происходит | Основание |
|---|---|---|---|
| 1 | ядро → `BytesMut` | `read` из utun | `rust-tun/src/async/` [V]; при включённом packet information возможна ещё одна промежуточная копия в `posix/split.rs` [U] |
| 2 | декодер | `pkt.freeze().to_vec()` — новая аллокация и копия на каждый пакет | `rust-tun/src/async/codec.rs` [V] |
| 3 | `Sink::start_send` | `pbuf_alloc(PBUF_RAM)` + `pbuf_take` — копия в кучу lwIP | `netstack-lwip/src/stack.rs:198–226` [V] |
| 4 | колбэк приёма TCP | `Vec::with_capacity` + `pbuf_copy_partial` — аллокация и копия, затем неограниченный канал | `netstack-lwip/src/tcp_stream.rs:66–75, 149` [V] |
| 5 | `poll_read` | копия из `Vec` в буфер читателя; остаток — в `read_overflow` | `tcp_stream.rs:255–262` [V] |

Исходящий пакет, TCP: `tcp_write(..., TCP_WRITE_FLAG_COPY)` — копия в lwIP (`tcp_stream.rs:357–361`); `output()` — `Vec::with_capacity` + `pbuf_copy_partial`, затем канал с отбрасыванием при переполнении (`output.rs:14–32`); кодировщик `dst.put(bytes)` — копия в `BytesMut` (`codec.rs`); `write` в utun. [V]

Итого по коду: во входящем направлении **четыре копии в пользовательском пространстве и две аллокации на пакет** сверх копии из ядра; в исходящем — три копии и одна аллокация сверх копии в ядро. Это подсчёт по исходникам, а не измерение; влияние на пропускную способность и нагрев неизвестно. [V — подсчёт; U — эффект]

Отдельно: при переполнении канала вывода пакет молча отбрасывается с расчётом на ретрансляцию TCP (`output.rs:28–31`); размер канала — `NETSTACK_OUTPUT_CHANNEL_SIZE`, по умолчанию 512 (`option/mod.rs:223`). [V]

### 2.4. FFI (`leaf-ffi`)

`leaf-ffi/Cargo.toml`: `crate-type = ["staticlib", "dylib"]`, имя библиотеки `leaf`; заголовок генерирует `cbindgen` (`cbindgen.toml`: `language = "C"`). Все функции — `leaf-ffi/src/lib.rs`. [V]

| Функция | Что делает |
|---|---|
| `i32 leaf_run_with_options(u16 rt_id, const char *config_path, bool auto_reload, bool multi_thread, bool auto_threads, i32 threads, i32 stack_size)` | Запуск из файла. **Блокирует вызывающий поток** до остановки. Комментарий в коде: «This is not a stable API, parameters will change from time to time» |
| `i32 leaf_run(u16 rt_id, const char *config_path)` | Запуск из файла на однопоточном рантайме; блокирует |
| `i32 leaf_run_with_config_string(u16 rt_id, const char *config)` | Запуск из строки конфигурации, однопоточный рантайм; блокирует |
| `i32 leaf_reload(u16 rt_id)` | Перечитывает файл: DNS, исходящие, правила |
| `bool leaf_shutdown(u16 rt_id)` | Сигнал остановки |
| `i32 leaf_test_config(const char *config_path)` | Проверка синтаксиса |
| `i32 leaf_test_outbounds(const char *config, u32 concurrency, u32 timeout_sec, void *context, void (*callback)(const char *tag, i32 tcp_ms, i32 udp_ms, void *context))` | Замер задержки всех исходящих **без запущенного экземпляра**; создаёт свой рантайм |
| `i32 leaf_health_check(u16 rt_id, const char *outbound_tag, u64 timeout_ms)` | Активная проверка одного исходящего |
| `i32 leaf_get_last_active(u16 rt_id, const char *outbound_tag, u32 *timestamp_s)` | Время последней активности исходящего |
| `i32 leaf_get_since_last_active(u16 rt_id, const char *outbound_tag, u32 *since_s)` | То же в секундах от текущего момента |

Коды ошибок: `ERR_OK 0`, `ERR_CONFIG_PATH 1`, `ERR_CONFIG 2`, `ERR_IO 3`, `ERR_WATCHER 4`, `ERR_ASYNC_CHANNEL_SEND 5`, `ERR_SYNC_CHANNEL_RECV 6`, `ERR_RUNTIME_MANAGER 7`, `ERR_NO_CONFIG_FILE 8`, `ERR_NO_DATA 9`. [V]

Чего в FFI нет: счётчиков трафика, списка соединений, колбэка логов, колбэка состояния, передачи fd отдельным аргументом (fd идёт внутри конфига: `tun-fd` в `.conf`, `settings.fd` в JSON), настройки лимитов. Для интерфейса `TunnelEngine` из ADR-0001 §5 (`snapshot()`, `events`) FFI придётся дополнять. [V — состав; U — объём работы]

### 2.5. Жизненный цикл, глобальное состояние, память

- **Экземпляры** хранятся в `RUNTIME_MANAGER: Mutex<HashMap<RuntimeId, Arc<RuntimeManager>>>` (`lib.rs:350`); API допускает несколько `rt_id`, но TUN-вход с lwIP — один на процесс (раздел 2.3). [V]
- **Запуск** строит собственный рантайм tokio, блокируется на `select_all`; по сигналу остановки удаляет запись и вызывает `rt.shutdown_background()` — задачи не дожидаются (`lib.rs:433–640`). В `lib.rs` есть тест с последовательным запуском и `shutdown(0)`. Повторный запуск в одном процессе конструктивно предусмотрен; на iOS под нагрузкой не проверялся. [V — код; U — поведение]
- **Настройки — через переменные окружения**, читаются один раз в `lazy_static` (`option/mod.rs`): `ENDPOINT_TCP_CONCURRENCY`, `DNS_CACHE_SIZE`, `LINK_BUFFER_SIZE`, `NETSTACK_OUTPUT_CHANNEL_SIZE`, `UDP_SESSION_TIMEOUT`, `OUTBOUND_INTERFACE`, `API_LISTEN`, `ASSET_LOCATION`, `ENABLE_IPV6` и др. После первого обращения значение на процесс зафиксировано: между перезапусками в одном процессе поменять нельзя. Для `target_os = "ios"` заданы отдельные меньшие значения по умолчанию (`ENDPOINT_TCP_CONCURRENCY` 45 против 1024, `DIRECT_TCP_CONCURRENCY` 64 против 1024, `DNS_CACHE_SIZE` 64 против 512). [V — `option/mod.rs:51–86`]
- `ENABLE_IPV6` по умолчанию `false`. [V — `option/mod.rs`]
- **Память**: сборщика мусора нет; управление — названные переменные и константы lwIP времени компиляции. Профиль release: `opt-level = 3`, `lto = true`, `panic = "abort"`, `strip = "symbols"` (`Cargo.toml`). `panic = "abort"` означает, что любая паника завершает процесс расширения. [V] В `leaf/src` 84 вхождения `unsafe`, плюс C-код lwIP. [V — подсчёт]
- **Журнал** на Apple идёт через `asl_log` (`mobile/wrapper.h` подключает `<asl.h>`, `mobile/logger.rs:9–21`) — устаревший Apple System Log. [V — использование; U — статус API по памяти]

### 2.6. Сборка и цели Apple

- Скрипты `scripts/apple_common.sh`, `build_ios_xcframework.sh`, `build_apple_xcframework.sh`: `cargo build -p leaf-ffi --release --no-default-features --features default-aws-lc` для `aarch64-apple-ios`, `x86_64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-darwin`, `aarch64-apple-darwin`; `lipo`; `cbindgen`; `xcodebuild -create-xcframework`. `IPHONEOS_DEPLOYMENT_TARGET=10.0`, `MACOSX_DEPLOYMENT_TARGET=10.12`. [V]
- CI (`.github/workflows/ci.yml`, задание `build-lib-apple`) собирает `leaf.xcframework` на `macos-latest` — сборка под iOS и macOS проверяется автоматически. Тесты (`cargo test -p leaf`) запускаются на настольных ОС. [V]
- **tvOS и visionOS в leaf не предусмотрены**: слов `tvos`/`visionos` в репозитории нет; модуль `mobile` и вывод журнала включены только для `target_os = "ios" | "macos" | "android"` (`lib.rs:38`, `app/logger.rs:136–164`); `build.rs` настраивает bindgen только для `aarch64` + `ios`; скрипты целей tvOS/visionOS не содержат. [V]
- Крейт `tun` v0.7.21 включает платформенный модуль для `ios` и `tvos`, но не для `visionos` (`src/platform/mod.rs:37`). [V]
- Тулчейн Rust (документация nightly, прочитана 2026-11-25): `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`, `aarch64-apple-tvos`, `aarch64-apple-tvos-sim`, `aarch64-apple-visionos`, `aarch64-apple-visionos-sim` — Tier 2 без host tools, ставятся через `rustup target add`; `x86_64-apple-tvos` — Tier 3. [V — https://doc.rust-lang.org/nightly/rustc/platform-support.html, …/platform-support/apple-tvos.html, …/apple-visionos.html]
- Итог: язык tvOS и visionOS поддерживает, leaf — нет. Понадобятся правки `cfg` в leaf, проверка сборки `aws-lc-rs`/`ring` и C-кода lwIP под SDK `appletvos`/`xros`, для visionOS — ещё и патч или замена крейта `tun`. [U — объём и исход]
- **`Cargo.lock` в репозиторий не входит** (`.gitignore`), три зависимости подключены из git: `reality` — без ревизии, `reality-rustls` и `netstack-smoltcp` — по веткам, `netstack-lwip` — по ревизии. Сборка невоспроизводима без собственного lock-файла. [V]
- `outbound-reality` включает `reality-rustls` с features `ring`, а набор по умолчанию — `aws-lc-rs`: в бинарнике окажутся оба криптобэкенда и две копии `rustls` (штатная 0.23 и форк). [V — `Cargo.toml`; U — размер]

### 2.7. Зрелость

- Релизы: `v0.11.0` (2024-06-01), `v0.12.0` (2025-11-05), `v0.13.0` (2026-02-05), `v0.14.0`–`v0.14.2` (2026-02-22…25). Версия крейта в `leaf/Cargo.toml` — `0.1.2`, `leaf-ffi` — `0.1.0`: с тегами релизов не совпадает. [V]
- Активность: 107 коммитов за 52 недели, 11 за последние 13 недель; с 2026-05-25 — 17 коммитов, все от `eycorsican`. Всего у автора 524 коммита, у следующего участника — 14. **Bus factor = 1.** [V — `gh api …/stats/participation`, `…/contributors`, `…/commits`]
- 2 845 звёзд, 9 открытых issues. [V]
- Тесты: 108 функций с `#[test]`/`#[tokio::test]`; интеграционные в `leaf/tests/` покрывают Trojan, Shadowsocks, SOCKS, цепочки, failover, AMux, MPTP, QUIC. Тестов VLESS, REALITY, VMess и TUN в `leaf/tests/` нет. [V — список файлов]
- REALITY: крейт `eycorsican/reality-rs` создан 2026-02-21, один день истории пушей; работает на форке `rustls` 0.23.36 того же автора. [V — метаданные] Совместимость с актуальным сервером Xray не проверялась. [U]

### 2.8. Лицензии

- **leaf: Apache-2.0** (`LICENSE`, README; поля `license` в `Cargo.toml` крейтов нет). [V]
- `netstack-lwip`: **файла лицензии в репозитории нет**, поля `license` в `Cargo.toml` нет; вложенный lwIP несёт BSD-заголовки в файлах (`src/lwip/core/tcp.c`). Обёртка на Rust формально без лицензии. [V]
- `reality-rs`: **файла лицензии нет** (в корне только `.gitignore`, `Cargo.toml`, `src`), поля `license` нет. [V]
- `reality-rustls`: форк rustls, `Apache-2.0 OR ISC OR MIT`. [V]
- `netstack-smoltcp`: Apache-2.0. `tun`: WTFPL. `aws-lc-rs`: `ISC AND (Apache-2.0 OR ISC)`; `aws-lc-sys` — составная лицензия с BSD-3-Clause и MIT. [V — `Cargo.toml` соответствующих репозиториев]
- Полного дерева зависимостей нет (нет `Cargo.lock`, `cargo` на хосте не запускался) — аудит транзитивных лицензий (`cargo deny`) остаётся на сборочной машине. [U]
- **Для App Store** копилефта в leaf нет — в этом он ближе к Xray, чем к sing-box и mihomo. Но код без лицензии (`netstack-lwip`, `reality-rs`) по умолчанию «все права защищены»: распространять бинарник с ним без разрешения автора — юридический риск, подпадающий под правило `CLAUDE.md` «новая зависимость — только с проверенной лицензией». Автор leaf и автор обоих крейтов — одно лицо, вопрос решается запросом к нему. [V — факты; U — оценка]

---

## 3. Сводная таблица

| Критерий | mihomo | leaf |
|---|---|---|
| Язык, рантайм | Go, сборщик мусора | Rust + C (lwIP), tokio |
| Лицензия | GPL-3.0 | Apache-2.0; две зависимости без лицензии |
| VLESS / REALITY / Vision | есть / есть / есть | есть / есть / Vision всегда включён |
| XHTTP | есть, с раздельным download | нет |
| Hysteria2, TUIC, WireGuard | есть | нет |
| Shadowsocks 2022 | есть (модуль) | нет |
| Группы | select, url-test, fallback, load-balance, relay | failover, tryall, static; select выключен в сборке |
| DNS | UDP/TCP, DoT, DoH, DoQ, fake-ip, политики | UDP, DoH, fake-ip во входе TUN |
| Rule-/proxy-providers | есть | нет |
| TUN-стек | mips (свой, новый), gVisor, system, mixed | lwIP (C), smoltcp |
| Вход пакетов штатно | fd utun | fd utun |
| Вход через колбэки NE | правка одной функции + своя реализация `tun.Tun` [U] | новый inbound + новые FFI-функции [U] |
| Готовый C ABI | нет | есть, 10 функций; без статистики и логов |
| Сборка под iOS в CI upstream | нет | есть (xcframework) |
| tvOS / visionOS | как у остальных Go-движков, не проверено | в коде не предусмотрены |
| Несколько запусков в процессе | через повторный `ApplyConfig`; полной остановки нет | предусмотрено (`leaf_shutdown`), не проверено под нагрузкой |
| Управление памятью | теги сборки; GC-лимиты выставляет обёртка | переменные окружения до первого запуска + константы lwIP |
| Статистика | Go API и REST | только HTTP на TCP-порту |
| Bus factor | около 1 (51 из 76 коммитов) | 1 (17 из 17) |

---

## 4. Вердикты

**mihomo — условно пригоден, но не как «ещё один движок рядом», а как альтернатива sing-box в GPL-линейке.**

- За: самый широкий набор протоколов из четырёх движков, включая XHTTP с раздельными направлениями; исполняет Clash-профили и провайдеры без компиляции Swift-слоем; есть работающий аналог в App Store (Clash Mi).
- Против: GPL-3.0 (в `XrayOnly` не попадает); нет готового моста — писать свой, как для Xray; нет полной остановки без завершения процесса; два обращения к непубличным API в самом ядре (`recvmsg_x` по умолчанию, `proc_pidinfo` всегда) — первое выключается опцией, второе требует правки; TCP/IP-стек по умолчанию создан три с половиной месяца назад; в одном бинарнике с Xray или sing-box добавляет третий комплект QUIC/gVisor/WireGuard и теряет свой `replace` protobuf.
- Блокеры до решения: (1) согласие владельца на второй GPL-движок; (2) сборка моста под `ios/arm64` на Go ≥ 1.26 и подъём туннеля; (3) замер памяти расширения — без него неизвестно, укладывается ли mihomo в бюджет.

**leaf — не рекомендуется как движок платформы сейчас; представляет интерес как источник архитектурного приёма.**

- За: единственный из четырёх без копилефта и без Go-рантайма; готовый C ABI и скрипты XCFramework; стек lwIP принимает пакеты, а не дескриптор — самая короткая дорога к варианту на документированных `readPackets`/`writePackets`.
- Против: набор протоколов не покрывает требования (нет XHTTP, Hysteria2, TUIC, WireGuard, SS-2022; VLESS без выбора flow); один автор; `netstack-lwip` и `reality-rs` без лицензии; нет `Cargo.lock`; tvOS и visionOS не предусмотрены в коде; жёсткий предел 512 TCP-соединений на iOS; статистика только через TCP-листенер, что противоречит ADR-0003; `panic = "abort"`.
- Блокеры: лицензии двух зависимостей; отсутствие нужных протоколов (это не правка, а разработка); доработка FFI под `TunnelEngine`.

**По вопросу TUN и публичных API** — для обоих одинаково: штатный путь требует дескриптор utun, а значит недокументированный приём; оба допускают переход на колбэки `NEPacketTunnelFlow` ценой форка; ни один существующий клиент, найденный при аудите, этим путём не идёт.

---

## 5. Что можно узнать только сборкой и измерением

Ни одного числа ниже нет — это план. Условия сравнения: одно устройство (самый старый поддерживаемый iPhone и Apple TV), один сервер, один протокол (VLESS+REALITY+Vision — единственный общий для Xray, sing-box, mihomo и leaf), одинаковые MTU и маршруты.

| № | Что измерить | Как | Зачем |
|---|---|---|---|
| M-1 | Собирается ли мост mihomo: `c-archive` под `ios/arm64`, симулятор, `darwin`, затем SDK `appletvos` и `xros`; на Go 1.26 и на 1.27 | своя обёртка над `hub.Parse`; теги `with_low_memory no_tailscale no_zerotier no_easytier no_fake_tcp`, с `with_gvisor` и без | сам факт сборки и размер артефакта |
| M-2 | Собирается ли leaf под `aarch64-apple-tvos` и `aarch64-apple-visionos` | правки `cfg`, сборка `aws-lc-rs`, `ring`, lwIP под соответствующие SDK | есть ли у leaf путь к двум платформам из пяти |
| M-3 | Размер бинарника расширения | `size`, размер `.appex` после strip, для каждого движка и набора тегов/features | бюджет загрузки и памяти |
| M-4 | Память расширения в покое и под нагрузкой | `phys_footprint` (Instruments, `task_info`): после старта, при 1/50/300 соединениях, при загрузке на полной скорости 5 минут, после 100 циклов `ApplyConfig`/reload | главный критерий выживания расширения на iOS (E-4 из ADR-0001) |
| M-5 | Пропускная способность TCP вниз и вверх | iperf3 через туннель, локальный сервер, Wi-Fi и сотовая сеть; медиана из 5 прогонов | скорость; у leaf — цена четырёх копий на пакет, у mihomo — стека `mips` против `gvisor` и `system` |
| M-6 | UDP: потери и задержка | iperf3 `-u` на нескольких скоростях; QUIC-видео | у leaf пакеты отбрасываются при переполнении канала вывода |
| M-7 | CPU и энергия | Instruments (Time Profiler, Energy Log) при фиксированной скорости 50 Мбит/с в течение 10 минут; температура корпуса | «стабильность на устройстве» включает нагрев; у mihomo сравнить `recvmsgx: true` и `false` |
| M-8 | Время установления соединения | от `startTunnel` до первого байта; холодный и тёплый старт | у mihomo инициализация провайдеров и geo-баз |
| M-9 | Предел соединений leaf на iOS | открыть 600 одновременных TCP через туннель | что происходит на 513-м: отказ, зависание или паника с завершением процесса |
| M-10 | Серия старт/стоп без завершения процесса | 200 циклов; следить за числом потоков, fd, памятью | у mihomo нет полной остановки; у leaf `shutdown_background` не ждёт задач |
| M-11 | Вариант на `readPackets`/`writePackets` | прототип: `tun.Tun` на каналах для mihomo, новый inbound для leaf; те же M-4, M-5, M-7 рядом с вариантом на fd | цена ухода от недокументированного fd |
| M-12 | Смена сети | Wi-Fi ↔ сотовая, режим полёта, сон и пробуждение; 50 повторов | на NE у mihomo отключены его мониторы интерфейсов (`auto-detect-interface: false`), у leaf привязка идёт через `OUTBOUND_INTERFACE`, читаемый один раз |
| M-13 | Интероперабельность REALITY/Vision у leaf | против текущего сервера Xray-core, 24 часа | `reality-rs` и форк rustls не имеют тестов в `leaf/tests/` |
| M-14 | Реакция App Store на `recvmsg_x` и `proc_pidinfo` | статический анализ бинарника (`nm`, `otool -L`), затем загрузка сборки в TestFlight | можно ли выпускать mihomo без правок ядра |
| M-15 | Дерево лицензий leaf | `cargo generate-lockfile`, `cargo deny check licenses` | транзитивные зависимости не проверены |
| M-16 | Работает ли mihomo на NE с опцией `file-descriptor` в upstream-виде | TCP, UDP, DNS, fake-ip на iPhone | Clash Mi использует собственную обёртку с `openTun`; чистый upstream на NE никем из найденных не подтверждён |

---

## 6. Что осталось непроверенным

- Внутреннее устройство `mipstack`: число копий, поведение под потерями, расход памяти на соединение.
- Где лежит исходник Go-обёртки `Libclash` у Clash Mi и какие правки mihomo она требует.
- Собирается ли mihomo на Go 1.27 и под SDK tvOS/visionOS.
- Наличие `proc_pidinfo` и `recvmsg_x` в списке символов, на которые реагирует проверка App Store.
- Набор методов Shadowsocks 2022 в mihomo; фактическая поддержка UDP по каждому протоколу в обоих движках.
- Значение packet information по умолчанию в крейте `tun` на iOS и число копий на этом шаге.
- Поведение leaf при исчерпании пула `tcp_pcb`.
- Лицензии форков `metacubex/*` поштучно и полное дерево зависимостей leaf.
- Статус SSR и Sudoku в sing-box и Xray (подсчёт упоминаний — эвристика).
- Все оценки «объёма правки» для варианта с колбэками NE: код не писался.
