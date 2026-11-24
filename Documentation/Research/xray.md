# Xray-core, libXray, OneXray — аудит по исходникам

Дата проверки: 2026-11-24. Исходники (shallow clone, только чтение) в `/root/.cache/np-research/`:

| Репозиторий | Коммит | Дата |
|---|---|---|
| XTLS/Xray-core | `e17392a96e1727a5fdb8101ecdd9245dc488fea4` | 2026-11-24 |
| XTLS/libXray | `6e33510350d18a9b906495ff81ae9eb572144ddd` | 2026-11-22 |
| YuanDevTeam/OneXray | `9ecde06d61f553708035717aca819e545a8ca866` | 2026-11-24 |
| SagerNet/sing-box (для сравнения зависимостей) | `6c65b2e6332769881d0c292718063a3c51d94f93` | 2026-11-24 |

Метки достоверности:

- **[V]** — VERIFIED: видел в исходнике, путь к файлу указан.
- **[U]** — UNVERIFIED: по памяти, по вторичному источнику или вывод, не подтверждённый сборкой.

Ограничение аудита: на хосте нет Go/Xcode, ничего не собиралось и не запускалось. Всё, что касается «соберётся ли» и «сколько займёт памяти», — **[U]** до эксперимента на macOS.

---

## 1. Короткие выводы

1. **У Xray-core есть собственный TUN-inbound, tun2socks не нужен.** `proxy/tun` читает пакеты прямо из utun-дескриптора, который NetworkExtension выдаёт расширению; дескриптор передаётся через ключ `xray.tun.fd`. TCP/IP-стек свой, облегчённый, без gVisor. [V]
2. **libXray — тонкая обёртка с одной точкой входа** `Invoke(requestJSON string) string` (JSON-RPC-подобный конверт, `apiVersion: 3`). На Apple собирается двумя способами: `gomobile bind` (без tvOS) или `go build -buildmode=c-archive` + ручной xcframework (iOS, macOS, tvOS). visionOS не собирается ни одним из двух. [V]
3. **OneXray — Flutter-приложение (Dart), туннель написан на Swift** (`NEPacketTunnelProvider`, 581 строка), ядро подключено как C-архив (`CGoInvoke`/`CGoFree`). Лицензия GPL-3.0 с исключением для VPN-провайдеров. Брать оттуда код в наш проект можно только на условиях GPL-3.0. [V]
4. **Два независимо собранных Go-фреймворка в одном процессе — нельзя.** Это прямо написано в README libXray со ссылками на issues Go. Единственный рабочий способ иметь оба ядра в одном процессе — один Go-модуль, одна сборка, один рантайм. [V — утверждение в README; сам отказ не воспроизводился]
5. **Единый бинарник Xray-core + sing-box технически возможен, но рискован.** Конфликтов по путям модулей у форков нет (quic-go, utls, gVisor, wireguard, gomobile у ядер разные модули, они просто лягут в бинарник дважды). Риски в другом: Xray-core требует `go 1.27`, а sing-box в CI собирается на Go 1.26.10 и держит 62 директивы `go:linkname`; MVS поднимет sing-box'у около 20 общих зависимостей; у обоих ядер есть процесс-глобальные настройки памяти и окружения. [V — факты; U — исход сборки]
6. **Рекомендация:** по умолчанию — два отдельных packet-tunnel-расширения (по одному ядру на процесс). Единый бинарник — отдельный эксперимент на macOS, а не предпосылка архитектуры.

---

## 2. Xray-core

### 2.1. Версия, язык, лицензия

- Версия в исходнике: `Version_x = 26`, `Version_y = 11`, `Version_z = 9` → 26.11.9 (`core/core.go`). [V]
- `go.mod`: `module github.com/xtls/xray-core`, `go 1.27`. Директивы `toolchain` нет. CI берёт версию Go из `go.mod` (`.github/workflows/release.yml`, `test.yml`: `go-version-file: go.mod`). [V]
- Лицензия: Mozilla Public License 2.0 (`LICENSE`). [V]
- Директив `replace`/`exclude` в `go.mod` нет. [V]

### 2.2. Что реально зарегистрировано в ядре

Реестр протоколов конфигурации — `infra/conf/xray.go`, строки 28–59. [V]

| Направление | Протоколы (ключ `protocol`) |
|---|---|
| Inbound | `tunnel`/`dokodemo-door`, `http`, `shadowsocks`, `mixed`/`socks`, `vless`, `vmess`, `trojan`, `wireguard`, `hysteria`, `masque`, `tun` |
| Outbound | `block`/`blackhole`, `loopback`, `direct`/`freedom`, `http`, `shadowsocks`, `socks`, `vless`, `vmess`, `trojan`, `hysteria`, `masque`, `dns`, `wireguard` |

Каталоги `proxy/`: `dns dokodemo freedom http hysteria loopback masque shadowsocks shadowsocks_2022 socks trojan tun vless vmess wireguard`. [V]

Замечание: `main/distro/all/all.go` явно импортирует не всё (нет `proxy/hysteria`, `proxy/tun`, `shadowsocks_2022`, `transport/internet/hysteria`). Они подтягиваются транзитивно через `infra/conf` (`infra/conf/tun.go` импортирует `proxy/tun` и т. д.). Для нас это значит: достаточно импортировать `main/distro/all`, как делает libXray (`xray/xray.go`). [V — импорты; U — что транзитивная регистрация покрывает абсолютно все пакеты, поимённо не проверял]

Транспорты — `infra/conf/transport_internet.go`, строки 18–43. [V]

| Значение `network` | Статус |
|---|---|
| `raw` / `tcp` | есть |
| `xhttp` / `splithttp` | есть |
| `kcp` / `mkcp` | есть |
| `grpc` | есть |
| `ws` / `websocket` | есть |
| `httpupgrade` | есть |
| `hysteria` | есть |
| `masque` | есть |
| `xdrive` | есть |
| `h2` / `h3` / `http` | **удалён**, ошибка с отсылкой на «XHTTP stream-one H2 & H3» (строка 36) |
| `quic` | **удалён**, отсылка на «XHTTP stream-one H3» (строка 38) |

Безопасность (`security`): `none`, `tls`, `reality`; `xtls` удалён с отсылкой на `xtls-rprx-vision` (строки 95–132). [V]

### 2.3. VLESS

`infra/conf/vless.go`. [V]

- Outbound: поля `address`, `port`, `id`, `flow`, `seed`, `encryption`, `multiplex`, `reverse`, `testpre`, `testseed`, старый формат `vnext` (строки 265–278).
- Шифрование VLESS: строка должна начинаться с `mlkem768x25519plus`, режимы `native` / `xorpub`, на клиенте `1rtt` / `0rtt` (строки 110–115, 364–378).
- `reverse` (обратный прокси внутри VLESS) — `VLessReverseConfig` (строки 218–220).
- Мультиплексор: `concurrency`, `xudpConcurrency`, `xudpProxyUDP443` (строки 240–243).

### 2.4. REALITY

`infra/conf/transport_security.go`, `REALITYConfig`. [V]

- Клиент: `fingerprint`, `serverName`, `password`, `publicKey`, `shortId`, `mldsa65Verify`, `spiderX`.
- Сервер: `target`/`dest`, `serverNames`, `privateKey`, `shortIds`, `mldsa65Seed`, `minClientVer`, `maxClientVer`, `maxTimeDiff`, `limitFallbackUpload`, `limitFallbackDownload`.
- Реализация — отдельный модуль `github.com/xtls/reality` (`go.mod`), uTLS — `github.com/refraction-networking/utls`.

TLS (`TLSConfig` там же): ECH (`echConfigList`, `echServerKeys`, `echSockopt`), пиннинг (`pinnedPeerCertSha256`, `verifyPeerCertByName`), `fingerprint`, `curvePreferences`, `useSystemCA`. [V]

### 2.5. XHTTP и раздельные upload/download

`infra/conf/transport_method.go`, `SplitHTTPConfig`. [V]

- Режимы: поле `mode`; при пустом/`auto` клиент выбирает `packet-up`, с REALITY — `stream-one`, а если задан `downloadSettings` — `stream-up` (`transport/internet/splithttp/dialer.go`, строки 334–343).
- **`downloadSettings`** — полноценный вложенный `StreamConfig` (свой адрес, порт, TLS/REALITY, sockopt). Несовместим со `stream-one` (ошибка `Can not use "downloadSettings" in "stream-one" mode.`, строки 510–516). В диалере для загрузки строится второй HTTP-клиент со своей версией HTTP: если для download выбран HTTP/3, сеть переключается на UDP (`dialer.go`, строки 352–375). То есть схема «вверх по одному пути, вниз по другому», включая разные L4, поддержана ядром.
- Управление формой трафика: `xPaddingBytes`, `xPaddingObfsMode`, `xPaddingKey`, `xPaddingHeader`, `xPaddingPlacement`, `xPaddingMethod`, `uplinkHTTPMethod`, `sessionIDPlacement`/`sessionIDKey`/`sessionIDTable`/`sessionIDLength`, `seqPlacement`/`seqKey`, `uplinkDataPlacement`/`uplinkDataKey`, `uplinkChunkSize`, `noGRPCHeader`, `noSSEHeader`, `scMaxEachPostBytes`, `scMinPostsIntervalMs`, `scMaxBufferedPosts`, `scStreamUpServerSecs`.
- `xmux`: `maxConcurrency`, `maxConnections`, `cMaxReuseTimes`, `hMaxRequestTimes`, `hMaxReusableSecs`, `hKeepAlivePeriod`.
- `extra` и `h2Params` — сырой JSON.
- Есть `browser_client.go` (browser dialer), `h1_conn.go`.

Следствие для нашей модели конфигурации: `downloadSettings` и `extra` нельзя свести к плоскому набору полей. Нужен либо проброс сырого JSON, либо рекурсивная модель StreamSettings.

### 2.6. mKCP

`infra/conf/transport_method.go`, `KCPConfig`. [V]

- Поля: `mtu`, `tti`, `uplinkCapacity`, `downlinkCapacity`, `cwndMultiplier`, `maxSendingWindow`, а также `header` и `seed`.
- `KCPConfig.Build()` поля `header` и `seed` **не читает** — в теле функции их нет. Маскировка заголовка и шифрование по seed перенесены в finalmask: UDP-маска `mkcp-legacy` с полями `header` (`dns`, `dtls`, `srtp`, `utp`, `wechat`, `wireguard`) и `value` (`infra/conf/transport_finalmask.go`, строки 764–797). При пустом `header` и непустом `value` включается `aes128gcm` с паролем.
- Практический вывод: ссылки и подписки со старым `kcpSettings.header`/`seed` на этой версии ядра молча теряют маскировку, если клиент не переложит их в `finalmask.udp`. [V — код Build; U — что нигде выше по стеку нет автоматической миграции, искал только в `infra/conf`]

### 2.7. finalmask

Ключ `streamSettings.finalmask` = `{ tcp: [Mask], udp: [Mask], quicParams }`, каждая маска `{ type, settings }` (`infra/conf/transport_finalmask.go`, строки 82–101, 1332–1336). [V]

| Слой | Типы масок |
|---|---|
| TCP | `filter`, `header-custom`, `proxy-protocol`, `fragment`, `sudoku`, `xmc` |
| UDP | `filter`, `header-custom`, `mkcp-legacy`, `noise`, `salamander`, `sudoku`, `xdns`, `xicmp`, `realm`, `udphop` |

- `fragment` — фрагментация (в т. ч. `packets: "tlshello"`), `noise` — шумовые датаграммы, есть Lua-скрипт (`script`; модуль `yuin/gopher-lua` в `go.mod`).
- `salamander` — обфускация Hysteria; `udphop` — port hopping (`intervallocal`, `intervalremote`, `perconnremote`).
- `xdns`, `xicmp`, `realm` (STUN/hole punching), `xmc` (маскировка под протокол Minecraft, судя по полям `yggdrasil`, `texturesValue`) — экзотические туннели. [V — наличие; U — трактовка назначения `xmc` и `realm` по именам полей]
- `quicParams`: `congestion` (`reno`, `bbr`, `brutal`, `force-brutal`), `bbrProfile`, `brutalUp`/`brutalDown`, окна приёма, `maxIdleTimeout`, `keepAlivePeriod`, `disablePathMTUDiscovery`, `disableChromeParrot`, `disableGSO` (строки 1357–1408).

`xicmp` требует сырых ICMP-сокетов; в песочнице iOS-расширения это, вероятно, не работает. [U]

### 2.8. Hysteria

- Proxy `hysteria` (inbound и outbound) и транспорт `hysteria`. Принимается только `version: 2` (`infra/conf/hysteria.go`, строки 20, 46). [V]
- Транспорт: `version`, `auth`, `udpIdleTimeout`, `masquerade` (`HysteriaConfig`). Salamander и port hopping вынесены в `finalmask.udp`. [V]
- QUIC — форк `github.com/apernet/quic-go` (`go.mod`). [V]

### 2.9. WireGuard, MASQUE, XDRIVE

- WireGuard: inbound и outbound; поля `secretKey`, `address`, `peers`, `mtu`, `reserved`, `remoteDNS`, `noKernelTun` (`infra/conf/wireguard.go`). На не-Linux ядро использует userspace-стек (`proxy/wireguard/tun_default.go`, `//go:build !linux`; `netstack.go` импортирует gVisor). Модули: `golang.zx2c4.com/wireguard`, `gvisor.dev/gvisor` (indirect). [V]
- MASQUE: proxy и транспорт, есть `warp` (`MasqueWarpConfig`) и `xmux` (`infra/conf/masque.go`, `transport_method.go`). [V]
- XDRIVE: транспорт через облачное хранилище (`service`, `remoteFolder`, `s3`, `template`; есть ветка `google-drive`) — `transport/internet/xdrive/`. [V]

### 2.10. TUN-inbound

`proxy/tun/`, документация `proxy/tun/README.md`, конфигурация `infra/conf/tun.go`. [V]

- Протокол inbound `tun`. Поля: `name`, `desc`, `guid`, `mtu` (по умолчанию 1500), `gateway`, `dns`, `userLevel`, `autoSystemRoutingTable`, `autoOutboundsInterface`, `autoSystemDnsToGateway`, `autoSystemWfpBlockLeak`.
- Стек: «Xray-core's own lightweight TCP/IP stack, which replaced gVisor» (README, со ссылкой на XTLS/Xray-core#7130); файлы `stack.go`, `tcp_lightweight.go`, `udp_fullcone.go`. Поддержка: IPv4/IPv6, TCP, UDP, ICMP Echo.
- **Darwin** (`tun_darwin.go`, `//go:build darwin`):
  - если задан `xray.tun.fd` — режим iOS: дескриптор дублируется (`F_DUPFD_CLOEXEC`), ставится non-blocking, `ownsFd: false`; оригинал остаётся за NetworkExtension;
  - иначе — режим macOS: ядро само открывает `utunN` через `com.apple.net.utun_control`, назначает адрес (по умолчанию `169.254.10.1/30`) и при `autoSystemRoutingTable` прописывает системные маршруты (нужен root);
  - ожидание чтения — через kqueue; комментарий в коде объясняет, что прежний busy-spin держал ядро CPU на 100 % и грел устройство (XTLS/Xray-core#6580).
- Собственные соединения ядра выводятся из туннеля привязкой сокета к интерфейсу: на macOS и iOS это `IP_BOUND_IF`/`IPV6_BOUND_IF` (README, раздел про `autoOutboundsInterface`).
- На macOS поле `dns` системный DNS не меняет (README).
- Ключ дескриптора — `platform.TunFdKey = "xray.tun.fd"` (`common/platform/platform.go:26`), альтернативное имя `XRAY_TUN_FD`. Значение читается из окружения процесса.
- Корневой объект `env` в JSON-конфигурации применяется через `os.Setenv` при сборке конфига (`infra/conf/xray.go:580–584`). Именно так libXray и OneXray передают дескриптор.

Чего в TUN-inbound нет по сравнению с sing-tun: выбора стека (system/gvisor/mixed), `strict_route`, собственных правил исключения по приложениям. Маршруты и DNS на Apple задаёт `NEPacketTunnelNetworkSettings`, то есть наш Swift-слой. [V — отсутствие полей в `Config`; U — сравнение с sing-tun по памяти]

### 2.11. Процесс-глобальное состояние ядра

Это важно и для запуска нескольких экземпляров, и для единого бинарника. [V]

- Системный диалер, DNS-клиент и outbound manager — пакетные переменные: `effectiveSystemDialer` (`transport/internet/system_dialer.go:20`), `obm` и `InitSystemDialer` (`transport/internet/dialer.go:84, 284`). Второй `core.Instance` в том же процессе перезаписывает их.
- Реестры транспортов, протоколов и загрузчиков конфигов заполняются в `init()` (`RegisterTransportDialer`, `RegisterProtocolConfigCreator`, `RegisterConfigLoader`).
- Переменные окружения процесса: `xray.location.asset`, `xray.location.cert`, `xray.buf.readv`, `xray.buf.splice`, `xray.ray.buffer.size`, `xray.browser.dialer`, `xray.tun.fd` и др. (`common/platform/platform.go`).
- `quicParams.debug` выставляет `HYSTERIA_BBR_DEBUG` и `HYSTERIA_BRUTAL_DEBUG` через `os.Setenv` (`infra/conf/transport_finalmask.go:1439`).
- `go:linkname` в рабочем коде — 8 мест (`crypto/tls`, `net/http`, `context`, `runtime.procyield`, `golang.org/x/net/icmp`).

### 2.12. Настройки памяти в самом ядре

Отдельного «мобильного» режима памяти в Xray-core нет. Есть `policy.levels.*.bufferSize` (`infra/conf/policy.go:15`) и переменная `xray.ray.buffer.size`. Тюнинг GC делает libXray, см. 3.4. [V]

---

## 3. libXray

### 3.1. Версия, лицензия, привязка к ядру

- `go.mod`: `module github.com/xtls/libxray`, `go 1.27.3`. [V]
- Лицензия: MIT (`LICENSE`, «Copyright (c) 2023-2025 XTLS»). [V]
- Xray-core закреплён псевдоверсией `v1.260327.1-0.20261109052709-676eaf66f8f0`; комментарий в `build/app/build.py` говорит, что это тег релиза `v26.11.9`. [V]
- README: стабильность API не гарантируется, совместимость только с последним релизом Xray-core, мало сопровождающих. [V]
- Версионирование CalVer (`v26.3.27`) с зеркальным SemVer-тегом для Go (`v1.260327.0`). [V]

### 3.2. Экспортируемый API

Единственная точка входа (`invoke.go`): [V]

```go
func Invoke(requestJSON string) string
```

C-экспорт для сборки через cgo (`cgo_bridge/main.go`): [V]

```c
char* CGoInvoke(char* requestJSON);
void  CGoFree(char* value);
```

Запрос: `{"apiVersion": 3, "method": "...", "payload": {...}}`. Ответ: `{"success": bool, "data": ..., "error": "..."}`. Принимается только `apiVersion: 3` (`LibXrayAPIVersion = 3`, `invoke_model.go`). Размер запроса и ответа ограничен 16 MiB (`maxInvokeJSONSizeMiB = 16`, `invoke.go`). [V]

Методы (`invoke_model.go`): [V]

| Метод | Назначение |
|---|---|
| `runXray` | запуск ядра; `payload.xrayJson` — текст конфигурации, не путь |
| `stopXray` | остановка |
| `getXrayState` | `{running: bool}` |
| `xrayVersion` | версия ядра |
| `testXray` | проверка конфигурации |
| `pingBatch` | пакетный замер задержки (`configs`, `timeout`, `url`, `warm`) |
| `convertShareLinksToXrayJson` | ссылки/подписка → Xray JSON (с опциональной расшифровкой age) |
| `convertXrayJsonToShareLinks` | обратное преобразование |
| `decodeSubscriptionText` | расшифровка текста подписки |
| `generateAgeKeyPair` | пара ключей age (`x25519` / `hybrid`) |
| `countGeoData` | подсчёт категорий в geo-файлах |
| `getFreePorts` | свободные TCP-порты на localhost |

Особенности: [V — README и код]

- В процессе допускается **один** управляемый экземпляр: `RunXray` возвращает `ErrAlreadyRunning`, если `coreServer != nil` (`xray/xray.go`).
- `pingBatch` и `testXray` отказываются работать при запущенном `runXray` — из-за процесс-глобального диалера (README, п. 7 Design notes). Следствие: замер задержки изнутри работающего расширения этим API не сделать.
- `SetTunFd` удалён; дескриптор пишется в `env["xray.tun.fd"]` корня конфигурации (README, п. 3).
- Разбор ссылок: VMess AEAD, VLESS, Hysteria2, Shadowsocks, SOCKS, Trojan. Clash/Mihomo-конфиги не поддерживаются. Для Hysteria2 `insecure=true` и `pinSHA256` отвергаются (README, раздел share).
- Потоков статистики, логов и событий в API нет. Трафик и состояние нужно брать средствами самого Xray: gRPC API, `metrics`, файлы логов. [V — отсутствие в списке методов]

### 3.3. Сборка под Apple

`build/main.py` → `build/app/apple_gomobile.py` либо `build/app/apple_go.py`. [V]

| | `apple gomobile` | `apple go` |
|---|---|---|
| Команда | `gomobile bind -target ios,iossimulator,macos,maccatalyst -iosversion 15.0` | `go build -trimpath -ldflags "-s -w -buildid=" -buildmode=c-archive ./cgo_bridge` на каждую пару SDK/арх., затем `lipo` и `xcodebuild -create-xcframework` |
| Платформы | iOS, iOS Simulator, macOS, Mac Catalyst | iOS, iOS Simulator, macOS, tvOS, tvOS Simulator |
| tvOS | нет (README: «does not support tvOS») | да: `GOOS=ios` + SDK `appletvos`/`appletvsimulator`, min 17.0 |
| visionOS | нет | нет (целей `xros` в скрипте нет) |
| Минимальные версии | iOS 15.0; для macOS задать нельзя (README) | iOS 15.0, macOS 12.0, tvOS 17.0 |
| Интерфейс | Objective-C-обёртка gomobile | C-заголовок `libXray.h`, `module.modulemap` с модулем `LibXray` |
| gomobile | `golang.org/x/mobile`, по умолчанию `latest`, переопределяется `LIBXRAY_GOMOBILE_VERSION` | не используется |

Для `apple go` выставляется `GOFLAGS=-tags=<platform>`, `CGO_ENABLED=1`, `CC=xcrun --sdk <sdk> clang`. [V]

Сборка по умолчанию каждый раз делает `go get xray-core@<версия>` и `go mod tidy`, затем восстанавливает `go.mod`/`go.sum` из снимка. Аргумент `local` подставляет `replace` на `../Xray-core`. [V]

Для нас: вариант `apple go` (C-архив) покрывает больше платформ и даёт простой C ABI, который напрямую импортируется в Swift. visionOS придётся добавлять самим; поддерживает ли Go цель visionOS — не проверено. [U]

### 3.4. Память

`memory/memory_ios.go` (`//go:build ios`): [V]

```go
debug.SetGCPercent(10)
debug.SetMemoryLimit(30 * 1024 * 1024) // 30 MiB
// плюс горутина: каждую секунду debug.FreeOSMemory()
```

- Включается один раз (`sync.Once`) при первом `RunXray` (`xray/xray.go`), назад не откатывается.
- Действует только при `GOOS=ios`. Так как tvOS-цели собираются с `GOOS=ios`, они тоже попадают под тюнинг. На macOS (`GOOS=darwin`) — заглушка (`memory/memory_other.go`). [V]
- Это настройки **всего Go-рантайма процесса**, а не экземпляра Xray.
- Лимит 30 MiB — мягкий (soft limit рантайма Go), а не гарантия. Системный предел памяти для packet tunnel на iOS в исходниках не фигурирует; распространённая оценка «около 50 МБ» — [U].

### 3.5. TUN

Своего кода TUN в libXray нет. Весь путь пакетов — в `proxy/tun` ядра; libXray только пробрасывает конфигурацию. tun2socks в зависимостях отсутствует (`go.mod`). [V]

### 3.6. Android-специфика (для полноты)

`controller/` — socket protect, подмена DNS-резолвера, поиск процесса по соединению. На Apple не используется. [V]

---

## 4. OneXray

### 4.1. Стек и структура

- Flutter/Dart: `pubspec.yaml` (`sdk: ">=3.14.0 <4.0.0"`, `flutter: ">=3.50.0"`), версия приложения `26.11.6+1`. [V]
- Слои Dart: `lib/pages → lib/service → lib/core` (`AGENTS.md`). Состояние — `flutter_bloc`, БД — `drift`/`sqlite3`, UI — `shadcn_ui`. [V]
- Мост Dart ↔ натив: Pigeon (`pigeon/message.dart`, `lib/core/pigeon/`, `swift/App/pigeon`), для десктопа FFI (`lib/core/ffi`, `c/include/libXray.h`). [V]
- Нативный код Apple в `swift/`: `All` (общее), `App`, `iOS`, `macOS`, `Tunnel`. Xcode-проекты: `ios/`, `macos/`, `macos_se/`. [V]
- Платформы: iPhone, iPad, Mac, Android, Windows, Linux (README). Проектов tvOS и visionOS нет. [V]
- Deployment target iOS: 16.0 (`ios/Runner.xcodeproj/project.pbxproj`). [V]

### 4.2. Варианты для Apple

| Вариант | Каталог | Entitlement расширения |
|---|---|---|
| iOS | `ios/tunnel` | `packet-tunnel-provider`, app group `group.net.yuandev.onexray` |
| macOS (App Store, sandbox) | `macos/tunnel` | `packet-tunnel-provider`, `app-sandbox`, `network.client`, `network.server`, app group с префиксом Team ID |
| macOS SE (вне App Store, Homebrew) | `macos_se/tunnel` | `packet-tunnel-provider-systemextension`, app group `group.net.yuandev.onexray.se` |

Приложение iOS (`ios/Runner/Runner.entitlements`): `networkextension: packet-tunnel-provider`, `networking.vpn.api: allow-vpn`, iCloud Documents, app group. [V]

Есть виджет/Control (`ios/widget`, `swift/iOS/AppleWidget*.swift`) и отдельный `ProxyHelper` для режима системного прокси на macOS (`swift/macOS/ProxyHelper`). [V]

### 4.3. Packet tunnel

`swift/Tunnel/PacketTunnelProvider.swift`. [V]

1. **Дескриптор utun** ищется перебором fd 0…1024: `getpeername` → `AF_SYSTEM` → сравнение `sc_id` с `ctl_id` для `com.apple.net.utun_control` (приём из WireGuardKit; структуры взяты из `swift/All/WireGuardKitC.h`, MIT, WireGuard LLC). Публичного API для получения fd у `NEPacketTunnelProvider` нет — это опора на недокументированное поведение. [V — код; U — оценка рисков ревью App Store]
2. **Сетевые настройки**: `NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.254.0.0"])`, маршрут по умолчанию; опционально IPv6 `fc00::1/64`; MTU 1500 (`TunMtu` в `swift/All/Constants.swift`); DNS — `NEDNSSettings` либо `NEDNSOverTLSSettings`; `excludedRoutes`; `tunnelRemoteAddress` = `127.0.0.1`.
3. **Запуск ядра**: в JSON конфигурации в корневой `env` дописывается `xray.tun.fd` (`xrayRuntimeEnvWithTunFd`, `swift/All/RuntimeEnv.swift`), затем `CGoInvoke` с методом `runXray`. Перед запуском вызывается `getXrayState`.
4. **Остановка**: `stopXray`; при ошибке — `exit(0)` через секунду (`killProcess`). То есть авторы не полагаются на чистую остановку ядра внутри живого процесса.
5. **Жизненный цикл**: `XrayRuntimeLifecycle` — счётчик поколений и последовательная очередь, чтобы запоздавший старт не пережил stop.
6. **System Extension**: geo-файлы передаются из приложения в расширение сообщениями (`handleAppMessage`: `listDat`, `putDat`, `commitDatFiles`, `startXray`), пути `xray.location.asset`/`xray.location.cert` подставляются в `env`.
7. tun2socks нет, локального SOCKS-прокси в туннельном режиме нет — пакеты идут из utun прямо в TUN-inbound ядра.

Вызовы libXray из расширения ограничены `getXrayState`, `runXray`, `stopXray`. [V]

### 4.4. Сборка ядра

- `build_scripts/app/builder.py`: для macOS и iOS вызывается `build/main.py apple go` — C-архив, не gomobile. [V]
- CI (`.github/workflows/build.yml`): libXray берётся с ветки `main` (`LIBXRAY_REF: main`), Go — `go-version: stable`, Xcode — `latest-stable`. Версии не закреплены, сборка невоспроизводима. [V]

### 4.5. Что стоит перенять и что нет

Перенять (идеи, не код):

- подключение ядра как C-архива с двумя функциями и JSON-конвертом;
- передачу fd через `env` конфигурации;
- счётчик поколений для гонок start/stop;
- разделение на вариант App Store (app extension) и вариант с System Extension.

Не перенимать:

- плавающие версии ядра и тулчейна;
- `exit(0)` как штатный способ остановки (для нас — только аварийный путь);
- отсутствие tvOS/visionOS.

---

## 5. Лицензии и App Store

| Компонент | Лицензия | Источник |
|---|---|---|
| Xray-core | MPL-2.0 | `Xray-core/LICENSE` [V] |
| libXray | MIT | `libXray/LICENSE` [V] |
| OneXray | GPL-3.0 + «VPN Provider Exception» v1.2 | `OneXray/LICENSE`, `LICENSE-EXCEPTION` [V] |
| sing-box | GPL-3.0-or-later + оговорка об имени | `sing-box/LICENSE` [V] |
| WireGuardKitC.h (в OneXray) | MIT | SPDX-заголовок файла [V] |
| xtls/reality, apernet/quic-go, refraction-networking/utls, gvisor, golang.org/x/* | не проверялись — исходников модулей на хосте нет | [U] |

Текст оговорки sing-box: «no derivative work may use the name or imply association with this application without prior consent». [V]

Исключение OneXray действует только для закрытых клиентов одного VPN-провайдера без импорта сторонних конфигураций и подписок. К универсальной открытой платформе оно неприменимо; для нас OneXray — GPL-3.0. [V — текст; U — юридический вывод]

Юридические выводы ниже — не заключение юриста. [U]

- **MPL-2.0 (Xray-core)** — копилефт на уровне файлов. Статическая линковка в приложение допустима; обязанность — открыть изменённые файлы самого Xray-core и сохранить уведомления. Ограничений на установку, конфликтующих с условиями App Store, MPL не содержит. Для открытого проекта это самый простой случай.
- **MIT (libXray)** — только сохранение уведомления об авторских правах.
- **GPL-3.0 (sing-box, OneXray)** — известный конфликт с условиями App Store (дополнительные ограничения на использование и распространение). Правообладатель может публиковать собственный код, как SagerNet делает со своим клиентом, но третьей стороне для публикации GPL-кода в App Store нужно разрешение правообладателей.
- **Совмещение в одном бинарнике**: MPL-2.0 допускает объединение с кодом под GPL (п. 3.3, «Secondary Licenses»), если файлы не помечены «Incompatible With Secondary Licenses». Результат в целом распространяется под GPL-3.0. То есть единый бинарник Xray + sing-box целиком попадает под GPL-3.0 и наследует проблему App Store от sing-box.
- **Следствие для архитектуры**: движок Xray можно поставлять в App Store без GPL-обременения, пока в том же бинарнике нет sing-box. Это довод в пользу раздельных артефактов по движкам.

Нужно проверить отдельно: файл с перечнем лицензий всех транзитивных Go-зависимостей (можно получить `go-licenses` на машине сборки); наличие в Xray-core файлов с пометкой о несовместимости с Secondary Licenses.

---

## 6. Xray-core и sing-box в одном бинарнике

### 6.1. Почему нельзя просто положить два фреймворка рядом

README libXray (раздел build, блок WARNING): Go не поддерживает загрузку нескольких независимо собранных рантаймов в один процесс; каждый артефакт libXray (cgo или gomobile) содержит свой рантайм; совместная загрузка с другой Go-библиотекой может упасть на сборке, линковке, загрузке или при инициализации рантайма. Ссылки: golang/go#18976, golang/go#15956, XTLS/libXray#116. Там же сказано, что перепаковка или слияние готовых фреймворков не помогает, а отдельные процессы ОС могут загружать по одному рантайму каждый. [V — текст README]

Механизм отказа: [U — по памяти, не воспроизводилось]

- два статических архива (C-архив libXray и статический фреймворк gomobile) содержат одинаковые символы рантайма Go и cgo-обвязки → ошибки duplicate symbol при линковке;
- если символы развести (динамические фреймворки, скрытая видимость), в процессе окажутся два планировщика, два сборщика мусора и два набора обработчиков сигналов → падения при старте или под нагрузкой.

Важно: правило действует на процесс. Основное приложение и расширение — разные процессы. Но если приложение линкует оба фреймворка, например ради проверки конфигураций, оно нарушает то же правило.

### 6.2. Единственный корректный вариант «в одном процессе»

Один Go-модуль-мост, который импортирует оба ядра, и одна сборка (`gomobile bind` с несколькими пакетами либо один `-buildmode=c-archive`). Ниже — что этому мешает.

### 6.3. Версия Go

| Модуль | Директива `go` | Чем собирается в CI |
|---|---|---|
| Xray-core | `go 1.27` | версия из `go.mod` |
| libXray | `go 1.27.3` | `stable` |
| sing-box | `go 1.25.5` | **1.26.10** (`.github/workflows/*.yml`) |

Общий модуль потребует тулчейн не ниже 1.27.3. sing-box на этом коммите в CI на 1.27 не собирается. При этом в sing-box 62 директивы `go:linkname`, сборка идёт с `-checklinkname=0` и тегом `badlinkname` (`cmd/internal/build_shared/flags.go`, `cmd/internal/build_libbox/main.go:66`) — то есть код завязан на внутренности рантайма и стандартной библиотеки конкретных версий. Соберётся ли и заработает ли sing-box на Go 1.27 — **главный неизвестный риск**. [V — факты; U — исход]

### 6.4. Форки: конфликтов по путям модулей нет

| Назначение | Xray-core / libXray | sing-box |
|---|---|---|
| QUIC | `github.com/apernet/quic-go` v0.63.1-0.2026… | `github.com/sagernet/quic-go` v0.61.0-sing-box-mod.15 |
| uTLS | `github.com/refraction-networking/utls` v1.8.3-0.2026… | `github.com/metacubex/utls` v1.9.0-alpha.1 |
| gVisor | `gvisor.dev/gvisor` (indirect) | `github.com/sagernet/gvisor` (indirect) |
| WireGuard | `golang.zx2c4.com/wireguard` | `github.com/sagernet/wireguard-go` |
| REALITY | `github.com/xtls/reality` | своя реализация внутри sing-box [U] |
| gomobile | `golang.org/x/mobile` | `github.com/sagernet/gomobile` (Makefile: v0.1.13; `go.mod`: v0.1.12) |
| age | `github.com/metacubex/age` | `filippo.io/age` |
| QPACK | `github.com/quic-go/qpack` v0.6.0 | тот же модуль, v0.6.0 |

Все версии — из `go.mod` трёх репозиториев. [V]

Пути модулей разные, поэтому Go считает их разными пакетами: MVS-конфликта и дублирования Go-символов не будет. Цена — два QUIC-стека, два uTLS, два gVisor и два WireGuard в одном бинарнике (размер и базовая память). Оценок в мегабайтах нет — нужна сборка. [U]

Отдельно: sing-box тянет `sagernet/cronet-go` (тег `with_naive_outbound`, предсобранные библиотеки Chromium для ios/tvos/darwin) и `sagernet/tailscale`. Это большой cgo-груз, попадающий в общий артефакт. [V — `go.mod` и теги сборки]

### 6.5. Общие модули: MVS поднимет версии для sing-box

Версия в объединённом графе — максимум из трёх `go.mod`. [V — версии; U — последствия]

| Модуль | sing-box | Xray-core | libXray | Итог |
|---|---|---|---|---|
| `golang.org/x/crypto` | v0.54.0 | v0.59.0 | v0.58.0 | v0.59.0 |
| `golang.org/x/net` | v0.57.0 | v0.63.0 | v0.62.0 | v0.63.0 |
| `golang.org/x/sys` | v0.47.0 | v0.50.0 | v0.49.0 | v0.50.0 |
| `golang.org/x/sync` | v0.22.0 | v0.25.0 | v0.24.0 | v0.25.0 |
| `golang.org/x/text` | v0.40.0 | v0.44.0 | v0.43.0 | v0.44.0 |
| `golang.org/x/exp` | 2026-04-10 | 2024-05-06 | 2026-11-06 | 2026-11-06 |
| `golang.org/x/mod` | v0.37.0 | — | v0.42.0 | v0.42.0 |
| `golang.org/x/tools` | v0.47.0 | v0.52.0 | v0.52.1-0.2026… | libXray |
| `golang.org/x/time` | v0.15.0 | — | v0.16.0 | v0.16.0 |
| `google.golang.org/grpc` | v1.79.1 | v1.85.0 | v1.85.0 | v1.85.0 |
| `google.golang.org/protobuf` | v1.36.11 | v1.36.12 | v1.36.12 | v1.36.12 |
| `github.com/miekg/dns` | v1.1.72 | v1.1.73 | v1.1.73 | v1.1.73 |
| `github.com/klauspost/compress` | v1.19.1 | v1.20.4 | v1.20.3 | v1.20.4 |
| `github.com/klauspost/cpuid/v2` | v2.3.0 | v2.4.2 | v2.4.2 | v2.4.2 |
| `github.com/pion/dtls/v3` | v3.1.5 | v3.1.5 | v3.1.15 | v3.1.15 |
| `github.com/pion/transport/v4` | v4.0.2 | v4.1.0 | v4.1.3 | v4.1.3 |
| `github.com/pires/go-proxyproto` | v0.8.1 | v0.16.0 | v0.16.0 | **v0.16.0** |
| `github.com/huin/goupnp` | v1.3.0 | v1.2.0 | v1.3.1 | v1.3.1 |
| `github.com/libp2p/go-netroute` | v0.2.1 | v0.2.1 | v0.4.0 | v0.4.0 |
| `github.com/koron/go-ssdp` | v0.0.4 | v0.0.4 | v0.9.2 | v0.9.2 |
| `lukechampine.com/blake3` | v1.3.0 | v1.5.1 | v1.4.1 | v1.5.1 |
| `golang.zx2c4.com/wireguard/windows` | v0.5.3 | v1.1.1 | v1.1.1 | v1.1.1 (к Apple не относится) |
| `go4.org/netipx` | 2023-11-29 | 2023-11-29 | 2026-08-23 | 2026-08-23 |

Самые подозрительные места:

- `go-proxyproto` v0.8.1 → v0.16.0: модуль до 1.0, восемь минорных версий, API мог измениться. В sing-box он indirect.
- `grpc` v1.79.1 → v1.85.0 и `golang.org/x/*`: форки `sagernet/tailscale`, `sagernet/quic-go`, `sagernet/gvisor` тестировались с версиями sing-box. gVisor исторически чувствителен к версиям `x/sys` и Go. [U]
- Директив `replace` нет ни в одном из трёх `go.mod`, так что скрытых подмен, которые потерялись бы при объединении, нет. [V]

Обойти MVS можно только директивами `replace`/`exclude` в модуле-мосте. Это означает собственное сопровождение пересечения зависимостей при каждом обновлении любого ядра.

### 6.6. Глобальное состояние при одном рантайме

Даже при успешной сборке ядра делят один процесс. [V — факты в коде; U — оценка последствий]

1. **Память и GC.** libXray на iOS при первом `RunXray` ставит `SetGCPercent(10)`, `SetMemoryLimit(30 MiB)` и ежесекундный `FreeOSMemory()` без отката (`memory/memory_ios.go`). libbox ставит свой лимит в `experimental/libbox/setup.go:106–111` (`debug.SetMemoryLimit(...)`, иначе `math.MaxInt64`) и использует тег `with_low_memory` для не-macOS. Настройки общие на рантайм: побеждает тот, кто вызвал последним, и тюнинг libXray останется действовать, когда работает sing-box. Решение — не использовать `xray.RunXray` из libXray, а вызывать `core.New`/`Start` напрямую и управлять памятью в мосте.
2. **Флаги линковщика.** sing-box требует `-X runtime.godebugDefault=multipathtcp=0,tlssha1=1` и `-checklinkname=0` (`cmd/internal/build_shared/flags.go`). В общем бинарнике они применятся и к Xray-core. `tlssha1=1` меняет поведение `crypto/tls` для всего процесса. Xray-core сам использует `go:linkname`, так что `-checklinkname=0` ему скорее на руку. [U]
3. **Теги сборки.** `with_quic`, `with_wireguard`, `with_utls`, `with_clash_api`, `with_tailscale`, `badlinkname`, `tfogo_checklinkname0` и др. (`build_libbox/main.go:66–69`) задаются на всю сборку. Пересечений имён тегов с Xray-core не видно. [U — полного перебора тегов Xray не делал]
4. **Окружение процесса.** Xray применяет корневой `env` через `os.Setenv` и читает из окружения `xray.tun.fd`, `xray.location.asset` и пр. После остановки Xray значения остаются. Имена с префиксом `xray.` с sing-box не пересекаются. [V]
5. **Реестр protobuf.** Свои `.proto` у sing-box: пакеты `experimental.v2rayapi`, `daemon`, `desktop`, `transport.v2raygrpc`; пути `experimental/…`, `daemon/…`, `transport/v2raygrpc/…`. У Xray-core 83 `.proto`, ни один не лежит под этими путями; пакеты начинаются с `xray.` (проверен `proxy/tun/config.proto`). Коллизий регистрации между собственными `.proto` двух репозиториев не найдено. Зависимости (tailscale и др.) не проверялись. [V / U]
6. **Диалер Xray** — процесс-глобальный (2.11), sing-box его не касается. Мешает только параллельным экземплярам Xray.
7. **`init()` обоих ядер** выполняются всегда, даже если движок в этой сессии не используется: реестры, таблицы, встроенные данные. Линковщик Go не выбрасывает пакеты с побочными эффектами в `init()`. Базовая память расширения вырастет. [U — величина]
8. **Остановка.** OneXray при сбое `stopXray` завершает процесс (`exit(0)`). Переключение движков «на горячую» внутри живого расширения поэтому ненадёжно; безопаснее перезапуск туннеля, а это и так новый процесс расширения. [V — код OneXray; U — вывод]

### 6.7. gomobile

- libXray: `golang.org/x/mobile`, цели `ios,iossimulator,macos,maccatalyst`, без tvOS.
- sing-box: `github.com/sagernet/gomobile`, цели `ios,iossimulator,tvos,tvossimulator,macos`, флаги `-libname=box`, `-tags-not-macos=with_low_memory`, `-iosversion=15.0`, `-macosversion=13.0`, `-tvosversion=17.0` (`build_libbox/main.go:191–210`). Флаги `-tags-not-macos`, `-macosversion`, `-tvosversion` есть только в форке. [V — аргументы; U — что их нет в апстриме]

Общая сборка через gomobile возможна только форком SagerNet: пакет `libbox` рассчитан на него, а API libXray — одна функция `Invoke(string) string`, её свяжет любой gomobile. Альтернатива — отказаться от gomobile для Xray и экспортировать C-функции из того же Go-модуля; смешение gobind-пакета и `//export` в одном артефакте не проверялось. [U]

visionOS: целей нет ни в скриптах libXray, ни в аргументах сборки libbox. [V]

### 6.8. Оценка

| Критерий | Единый бинарник | Два артефакта, два расширения |
|---|---|---|
| Сборка сегодня | не проверена; риск Go 1.27 для sing-box | каждый собирается штатным скриптом своего проекта |
| Обновление одного ядра | пересборка и повторная проверка совместимости всего графа | независимое |
| Память расширения | оба ядра и их дубликаты стеков в одном процессе | только активное ядро |
| Лицензия | целиком GPL-3.0 | Xray-расширение остаётся MPL/MIT |
| Изоляция сбоев | паника одного ядра роняет общий процесс | изолированы |
| Переключение движка | теоретически без перезапуска процесса | перезапуск туннеля с другим `providerBundleIdentifier` |
| Размер приложения | один большой фреймворк | два фреймворка (дубли Go-рантайма и общих модулей) |

Вывод: единый бинарник осуществим в принципе — жёстких конфликтов путей модулей или найденных коллизий глобальных реестров нет. Но он упирается в три неподтверждённых условия: sing-box на Go ≥ 1.27.3, sing-box с поднятыми общими зависимостями, приемлемая память при двух ядрах в одном расширении. И он ухудшает лицензионную позицию Xray-варианта. Без сборочного эксперимента закладывать его в архитектуру нельзя.

### 6.9. Рекомендуемая схема

1. **Один движок — один процесс.** Два packet-tunnel-расширения, каждое линкует один Go-артефакт. Swift control plane выбирает расширение через `NETunnelProviderProtocol.providerBundleIdentifier`. Допустимость двух packet-tunnel-расширений в одном iOS-приложении и поведение `NETunnelProviderManager` при этом — проверить на устройстве. [U]
2. **Основное приложение не линкует Go-ядра вообще** либо линкует не более одного. Проверку конфигурации и замеры задержки выполнять в расширении через `sendProviderMessage` либо реализовать в Swift. Иначе приложение само нарушит правило одного рантайма.
3. **Для Xray — собственный тонкий мост**, а не libXray как есть:
   - свой `go.mod` с закреплёнными версией Xray-core и тулчейном (libXray и OneXray их не закрепляют);
   - `-buildmode=c-archive`, цели iOS / macOS / tvOS по образцу `build/app/apple_go.py`; visionOS — отдельное исследование;
   - управление памятью — параметры, а не зашитые 30 MiB и GC 10 %;
   - потоки логов и статистики, которых нет в `Invoke`;
   - разбор ссылок (`share/`) можно переиспользовать: libXray под MIT.
4. **Абстракция движка в Swift** должна исходить из наименьшего общего: «запусти с конфигурацией и fd», «останови», «состояние», «статистика». Обе реализации принимают utun-дескриптор, tun2socks не нужен ни одной.
5. **Эксперимент с единым бинарником** — отдельная задача на macOS: модуль-мост, `go mod tidy`, сборка под `ios/arm64`, замер размера и RSS в расширении. До результата считать вариант недоступным.

---

## 7. Что осталось непроверенным

- Любая сборка и запуск: Go, gomobile, Xcode на хосте отсутствуют.
- Поддержка visionOS тулчейном Go и gomobile.
- Фактическое потребление памяти Xray-core в расширении iOS и системный лимит памяти для packet tunnel.
- Сборка sing-box (`6c65b2e`) на Go 1.27.x и с версиями зависимостей из раздела 6.5.
- Лицензии транзитивных зависимостей Xray-core.
- Отношение ревью App Store к поиску utun-дескриптора перебором fd. Косвенный довод: OneXray с этим приёмом опубликован в App Store — ссылка в README; сам факт публикации не проверялся. [U]
- Работа `xicmp`, `xdns`, `realm` и browser dialer в песочнице расширения.
- Автоматическая миграция `kcpSettings.header/seed` в `finalmask` где-либо вне `infra/conf`.
