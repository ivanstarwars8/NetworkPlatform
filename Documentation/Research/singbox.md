# Аудит sing-box и sing-box-for-apple

Дата проверки: 2026-11-24. Источники (shallow-клоны, только чтение):

| Репозиторий | Коммит | Ветка | Путь |
|---|---|---|---|
| SagerNet/sing-box | `6c65b2e6332769881d0c292718063a3c51d94f93` (2026-11-24) | `testing` (HEAD по умолчанию) | `/root/.cache/np-research/sing-box` |
| SagerNet/sing-box-for-apple | `a4b34aed38f61af85fa37f7e197f659969e4783f` (2026-11-24) | — | `/root/.cache/np-research/sing-box-for-apple` |
| sagernet/gomobile (форк) | `4386c41e5b15c25836f4515cc589b3ab4edb75a9` (2026-11-03), HEAD | — | клонирован временно, удалён после проверки |

Пометки: **[V]** = VERIFIED (видел в исходниках / официальной документации внутри репозитория, путь указан), **[U]** = UNVERIFIED (по памяти или из вторичных источников; требует проверки на macOS).

Важная оговорка: ничего не собиралось (на хосте нет Go/Xcode). Всё, что касается реального размера бинарей, поведения в рантайме и лимитов Apple, проверено только по коду, а не запуском.

Важно про версию: клон — ветка `testing`, то есть линия **1.15.0-alpha** (`docs/changelog.md`: верхняя запись `1.15.0-alpha.13`, стабильная рядом — `1.14.4`; `MARKETING_VERSION = "1.15.0-alpha.13"` в `sing-box.xcodeproj/project.pbxproj`). **[V]** Набор протоколов и API libbox в стабильной 1.14.x может отличаться — перед фиксацией версии движка сверять по тегу.

---

## 1. Что реально компилируется в Apple-библиотеку

### 1.1. Скрипт сборки

Apple-библиотека собирается не Makefile-ом напрямую, а Go-программой `cmd/internal/build_libbox/main.go`, которую вызывает `make lib_apple` (`Makefile`: `go run ./cmd/internal/build_libbox -target apple`). **[V]**

Фактическая команда (функция `buildApple()`): **[V]**

```
gomobile bind -v \
  -target ios,iossimulator,tvos,tvossimulator,macos \
  -libname=box \
  -tags-not-macos=with_low_memory \
  -iosversion=15.0 -macosversion=13.0 -tvosversion=17.0 \
  -trimpath -buildvcs=false \
  -ldflags "-X github.com/sagernet/sing-box/constant.Version=<tag> -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid=" \
  -tags <см. ниже> \
  ./experimental/libbox
```

Результат — `Libbox.xcframework`, который скрипт переносит в `../sing-box-for-apple/Libbox.xcframework` (в git не хранится: `/Libbox.xcframework/` в `.gitignore` клиента). **[V]**

В CI (`.github/workflows/build.yml`, job `build_apple_library`) библиотека собирается по одной платформе за раз (`-platform ios/arm64`, `tvos/arm64`, `macos/arm64`, `macos/amd64`), затем срезы склеиваются утилитой `cmd/internal/merge_apple_xcframework`. **[V]** Симуляторные срезы в CI-матрице отсутствуют. **[V]**

### 1.2. Build tags Apple-сборки

Из `cmd/internal/build_libbox/main.go` (`sharedTags` + `darwinTags`): **[V]**

```
with_quic, with_wireguard, with_utls, with_naive_outbound, with_clash_api,
with_usbip, with_openvpn, with_openconnect, badlinkname, tfogo_checklinkname0,
with_tailscale, ts_omit_logtail, ts_omit_ssh, ts_omit_drive, ts_omit_taildrop,
ts_omit_webclient, ts_omit_doctor, ts_omit_capture, ts_omit_kube, ts_omit_aws,
ts_omit_synology, ts_omit_bird,
with_dhcp, grpcnotrace            (только darwin)
with_low_memory                   (только НЕ-macOS: iOS, tvOS — флаг -tags-not-macos)
debug                             (только при -debug)
```

Чего в Apple-сборке **нет** по сравнению с десктопным набором `release/DEFAULT_BUILD_TAGS`: `with_acme`, `with_ccm`, `with_ocm`, `with_cloudflared`. Также нет `with_grpc`, `with_v2ray_api`, `with_gvisor`, `with_embedded_tor`. **[V]** (сравнение `build_libbox/main.go` и `release/DEFAULT_BUILD_TAGS`).

`with_low_memory` в самом sing-box не используется — тег обрабатывается в зависимостях (в локальном модульном кэше хоста найден в `github.com/sagernet/sing@v0.5.1/common/low_memory.go` и `common/buf/buffer_low_memory.go`; это старая версия, не та, что закреплена в `go.mod`). **[V] для факта наличия тега в sagernet/sing, [U] для точного эффекта в закреплённой версии.**

### 1.3. Протоколы (регистрация в `include/registry.go` + файлы с тегами в `include/`)

Всегда включены (без тегов): **[V]**

- Inbound: `tun`, `redirect`, `tproxy`, `direct`, `socks`, `http`, `mixed`, `shadowsocks`, `snell`, `vmess`, `trojan`, `naive`, `shadowtls`, `vless`, `anytls`.
- Outbound: `direct`, `bridge`, `block`, `selector`, `urltest`, `socks`, `http`, `shadowsocks`, `snell`, `vmess`, `trojan`, `tor`, `ssh`, `shadowtls`, `vless`, `anytls`.
- Endpoint: `masque` (без тега).
- DNS-транспорты: TCP, UDP, TLS (DoT), HTTPS (DoH), hosts, local, mdns, fakeip, resolved.
- Сервисы: `api`, `resolved`, `ssm-api`, `oom-killer`, DERP (через tailscale-файл).

Включены тегами Apple-сборки: **[V]**

| Тег | Что добавляет | Файл |
|---|---|---|
| `with_quic` | `hysteria`, `hysteria2`, `tuic` (in/out), QUIC-вариант naive, V2Ray-транспорт `quic`, DNS over QUIC и HTTP/3, сервис `hysteria-realm` | `include/quic.go` |
| `with_wireguard` | endpoint `wireguard` | `include/wireguard.go` |
| `with_utls` | uTLS-клиент и **REALITY** (клиент и сервер) | `common/tls/utls_client.go`, `common/tls/reality_client.go`, `reality_server.go` |
| `with_naive_outbound` | outbound `naive` через cronet (CGO, статические библиотеки cronet) | `include/naive_outbound.go`, `go.mod` (`github.com/sagernet/cronet-go/lib/ios_arm64`, `tvos_arm64`, `darwin_arm64`, `darwin_amd64`, симуляторы) |
| `with_clash_api` | Clash API | `include/clashapi.go` |
| `with_tailscale` | endpoint `tailscale`, DNS-транспорт, cert provider, `tailcat` | `include/tailscale.go` |
| `with_openvpn` | endpoints `openvpn-client` / `openvpn-server` | `include/openvpn.go` |
| `with_openconnect` | endpoint `openconnect` | `include/openconnect.go` |
| `with_usbip` | `usbip-server` / `usbip-client` (условие `linux || (darwin && cgo) || windows`) | `include/usbip.go` |
| `with_dhcp` | DNS-транспорт DHCP | `include/dhcp.go` |

Удалённые заглушки: `shadowsocksr` (удалён в 1.6.0), outbound `wireguard` (удалён в 1.13.0, вместо него endpoint). **[V]** (`include/registry.go`).

ECH: отдельный тег `with_ech` упразднён, реализация перенесена на stdlib (`common/tls/ech_tag_stub.go`). **[V]**

Apple-специфичный TLS-клиент через системные API: `common/tls/apple_client.go` (`darwin && cgo`). **[V]**

### 1.4. V2Ray-транспорты

Константы в `constant/v2ray.go`: `http`, `ws`, `quic`, `grpc`, `httpupgrade`. **[V]**

- gRPC: поскольку тега `with_grpc` нет, используется облегчённая реализация `transport/v2ray/grpc_lite.go` (`//go:build !with_grpc`), а не стандартная `google.golang.org/grpc`. **[V]**
- **XHTTP / SplitHTTP в sing-box нет.** Поиск `xhttp|splithttp` (без учёта регистра) по всем `*.go` не дал ни одного файла. **[V]** Следствие для платформы: всё, что зависит от XHTTP (в т.ч. схемы с раздельными up/down), покрывается только движком Xray-core.
- VLESS Vision / REALITY на клиенте — есть (`with_utls`). **[V]** для REALITY; строка `xtls-rprx-vision` в `*.go` самого репозитория sing-box не встречается (grep пуст) — если Vision поддерживается, то в зависимости (`sagernet/sing-vmess`), что здесь не проверено. **[U]**

### 1.5. TUN-стек

- Под NetworkExtension MTU по умолчанию принудительно 4064 (комментарий в коде: выше 4064 производительность utun резко падает). `protocol/tun/inbound.go:120`. **[V]**
- Тега `with_gvisor` в Apple-сборке нет; по `docs/configuration/inbound/tun.md` опция `stack` помечена deprecated (удаление в 1.17.0), начиная с 1.15.0 sing-tun использует собственный TCP/IP-стек. **[V]** (документация в репозитории).
- Ограничения TUN под NE (`docs/clients/apple/features.md`): не реализованы `strict_route`, `gso`, `include_interface`/`exclude_interface`, `include_uid`/`exclude_uid`; `interface_name` управляется системой. **[V]**
- Правила `process_name` / `process_path` / `user` работают только в macOS standalone (system extension + root helper) и в jailbreak-сборке iOS; `wifi_ssid` / `wifi_bssid` — только iOS (по документации). **[V]**

---

## 2. Go, gomobile и патчи тулчейна

| Параметр | Значение | Источник |
|---|---|---|
| `go` директива | `go 1.25.5` | `go.mod:3` **[V]** |
| Go в CI | `1.26.10` (во всех job, включая `build_apple_library`) | `.github/workflows/build.yml` **[V]** |
| Раннер CI для Apple | `xcode-27` | `.github/workflows/build.yml:1244` **[V]** (что именно за версия Xcode стоит за меткой — **[U]**) |
| gomobile | форк `github.com/sagernet/gomobile` | `go.mod:42`, `Makefile` **[V]** |
| Версия gomobile | **расхождение**: `go.mod` — `v0.1.12`; `make lib_install` ставит `gomobile@v0.1.13` и `gobind@v0.1.13` | `go.mod`, `Makefile` **[V]** |
| Android NDK (не нужен нам) | `28.0.13004108` | `cmd/internal/build_shared/sdk.go` **[V]** |

Почему обязателен именно форк gomobile: **[V]** (по исходникам форка, HEAD `4386c41`)

- цели `tvos`, `tvossimulator` (`cmd/gomobile/env.go`: `applePlatforms = ios, iossimulator, macos, maccatalyst, tvos, tvossimulator`);
- флаги `-tvosversion`, `-macosversion`, `-tags-macos`, `-tags-not-macos` (`cmd/gomobile/build.go`);
- для tvOS выставляются теги `ios` + `tvos` (на этом построены `constant/os_tvos.go` с `//go:build ios && tvos`).

**visionOS:** в форке gomobile целей `visionos`/`xros` нет (grep по `cmd/gomobile/*.go` пуст). **[V]** В `go.mod` нет cronet-библиотек под visionOS. **[V]** В проекте клиента у расширений `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = NO`. **[V]** То есть upstream visionOS не поддерживает никак; для нашей платформы это отдельная инженерная задача (собственная сборка Go под xros либо запуск iPad-бинаря в режиме совместимости) — осуществимость **[U]**.

Патч Go для iOS/tvOS: `.github/patch_go_for_ios.sh` + `.github/go_ios_cpu_features.patch` правят `GOROOT/src/internal/cpu`, потому что на `GOOS=ios` Go не определяет ARM64-расширения и AES/AES-GCM/SHA-256 идут по generic-реализации (ссылка в скрипте на issue SagerNet/sing-box#4486). CI применяет патч перед сборкой iOS и tvOS срезов. **[V]** Без этого патча библиотека собирается, но криптография медленнее — для нашей сборочной цепочки патч стоит воспроизвести.

Линкер-флаги из `release/LDFLAGS` обязательны: `-X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0`. **[V]** Вместе с тегами `badlinkname`, `tfogo_checklinkname0` это означает зависимость от `//go:linkname` во внутренности рантайма (см. также `experimental/libbox/signal_handler_darwin.go` — linkname на `runtime.fwdSig`, `runtime.handlingSig`). **[V]** Риск: поломки при обновлении Go.

---

## 3. libbox — gomobile API (`experimental/libbox`)

Пакет ~9.7 тыс. строк, экспортируется в Swift/ObjC с префиксом `Libbox`. Ниже — то, что нужно control plane.

### 3.1. Жизненный цикл

Последовательность, как её вызывает клиент (`Library/Network/ExtensionProvider.swift`): **[V]**

1. `LibboxPrepareCrashSignalHandlers()` → установка PLCrashReporter → `LibboxReinstallCrashSignalHandlers()` — в `init()` провайдера, до первого прочего вызова Go (логика цепочки обработчиков описана в `signal_handler_darwin.go`).
2. `LibboxSetup(LibboxSetupOptions)` — глобальная настройка (`setup.go`). Поля `SetupOptions`: `BasePath`, `WorkingPath`, `TempPath`, `FixAndroidStack`, `CommandServerListenPort`, `CommandServerSecret`, `LogMaxLines`, `Debug`, `CrashReportSource`, `AppVersion`, `AppMarketingVersion`, `OomKillerEnabled`, `OomKillerDisabled`, `OomMemoryLimit`, `PowerReportEnabled`, `PlatformMetadata`. `Setup` также перенаправляет stderr в `<WorkingPath>/CrashReport-<source>.log`.
3. `LibboxNewCommandServer(handler, platformInterface)` → `commandServer.start()` — поднимает gRPC-сервер управления.
4. `commandServer.startOrReloadService(configContent, options: LibboxOverrideOptions)` — запуск/перезапуск ядра с JSON-конфигом строкой. Этот же вызов используется для reload.
5. `commandServer.closeService()` → `commandServer.close()` при остановке.

Дополнительно на `CommandServer`: `Pause()`, `Wake()`, `WakeNow()`, `RecordScreenState(on)`, `ResetNetwork()`, `UpdateWIFIState()`, `NeedWIFIState()`, `NeedFindProcess()`, `WriteMessage(level, message)`, `SetError(message)` (`command_server.go`). **[V]**

Состояние глобальное (пакетные переменные `sBasePath`, `sCommandServerListenPort` и т.д. в `setup.go`) — **один экземпляр libbox на процесс**; параллельные независимые экземпляры в одном процессе API не предусматривает. **[V]**

Утилиты без запуска сервиса: `LibboxCheckConfig(content)`, `LibboxFormatConfig`, `LibboxGenerateConfigSchema`, `LibboxHasTunInbound`, `LibboxVersion()`, `LibboxGoVersion()`, `LibboxAvailablePort`, `LibboxRandomHex`, `LibboxNewHTTPClient()` (HTTP-клиент для загрузки подписок), импорт/экспорт профилей (`profile_import.go`, `remote_profile.go`). **[V]** `CheckConfig` создаёт полноценный `box.New(...)` и сразу закрывает — в клиенте вызывается и из основного приложения (`Library/Database/Profile+Update.swift`, `MacLibrary/ProfileEditorWrapperView.swift`), то есть Go-рантайм живёт и в app-процессе. **[V]**

### 3.2. PlatformInterface (`platform.go`)

Интерфейс, который обязан реализовать хост (Swift). Полный список методов: **[V]**

```
LocalDNSTransport() LocalDNSTransport
UsePlatformAutoDetectInterfaceControl() bool
AutoDetectInterfaceControl(fd int32) error
OpenTun(options TunOptions) (int32, error)
FindConnectionOwner(ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort) (*ConnectionOwner, error)
StartDefaultInterfaceMonitor(listener InterfaceUpdateListener) error
CloseDefaultInterfaceMonitor(listener InterfaceUpdateListener) error
GetInterfaces() (NetworkInterfaceIterator, error)
UnderNetworkExtension() bool
IncludeAllNetworks() bool
ReadWIFIState() *WIFIState
ClearDNSCache()
SendNotification(notification *Notification) error
CancelNotification(identifier string, typeID int32) error
StartNeighborMonitor / CloseNeighborMonitor(listener NeighborUpdateListener) error
RegisterMyInterface(name string)
UsePlatformShell() bool; CheckPlatformShell() error; OpenShellSession(...)
LookupUser(username) ; LookupSFTPServer() ; ReadSystemSSHHostKey()
TailscaleHostname() string
UsePlatformBridge() bool; CreateBridge(options *BridgeOptions)
UsePlatformAutoRedirect() bool; CreateAutoRedirect(options []byte, handler AutoRedirectHandler)
```

Интерфейс широкий и растёт вместе с фичами upstream (Tailscale SSH, USB/IP, bridge, auto-redirect). Для нашего адаптера большинство методов — заглушки, но сигнатура — часть ABI: при обновлении sing-box Swift-реализация `LibboxPlatformInterfaceProtocol` перестаёт компилироваться, пока не добавлены новые методы. **[V] по коду; вывод о частоте изменений — [U].**

Как реализовано в клиенте (`Library/Network/ExtensionPlatformInterface.swift`): **[V]**

- `underNetworkExtension()` → `true`; `includeAllNetworks()` → из настроек (на tvOS всегда `false`).
- `usePlatformAutoDetectControl()` → `false`.
- `localDNSTransport()` → `nil` (используется встроенный local-транспорт ядра).
- Мониторинг сети — `NWPathMonitor`; первый колбэк ожидается синхронно через семафор.
- `clearDNSCache()` — переустановка `setTunnelNetworkSettings(nil)` → прежние настройки под флагом `reasserting`.
- `readWIFIState()` — iOS: `NEHotspotNetwork.fetchCurrent()`; macOS: `CWWiFiClient`; tvOS: нет.
- `findConnectionOwner` — только macOS system extension (через root helper по XPC) и jailbreak; иначе «Not implemented».

### 3.3. TUN: получение файлового дескриптора

Поток: ядро вызывает `PlatformInterface.OpenTun(TunOptions)` → Swift строит `NEPacketTunnelNetworkSettings` из итераторов `TunOptions` (адреса, маршруты, исключения, DNS, MTU, HTTP-прокси) → `setTunnelNetworkSettings` → возвращает fd utun. **[V]**

Получение fd в Swift (`ExtensionPlatformInterface.openTun0`): **[V]**

1. Сначала приватный KVC: `tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32`.
2. Запасной путь: `LibboxGetTunnelFileDescriptor()` (`experimental/libbox/tun_darwin.go`) — перебор fd `0..1023`, `getpeername` + сравнение с control id `com.apple.net.utun_control` (в коде помечено как заимствованное из wireguard-apple).

На стороне Go (`service.go`, `OpenInterface`): имя интерфейса берётся через `getsockopt(SYSPROTO_CONTROL, UTUN_OPT_IFNAME)` (`tun_name_darwin.go`), fd **дублируется** (`dup`) и передаётся в `tun.New`. Опции `include_uid`/`exclude_uid`/`include_android_user` отклоняются ошибкой. **[V]**

Замечания для нашей архитектуры:

- `NEPacketTunnelFlow.readPackets/writePackets` не используется вообще — ядро само читает utun. Это общий приём (тот же, что у WireGuard), но KVC-путь `socket.fileDescriptor` — приватный API. **[V] факт использования; [U] оценка риска ревью App Store** (приложение с этим кодом находится в App Store согласно `docs/clients/apple/index.md`).
- `tunnelRemoteAddress` = `"127.0.0.1"`. **[V]**
- Если нет маршрута по умолчанию, DNS-настройкам ставится `matchDomains = [""]`, `matchDomainsNoSearch = true`. **[V]**
- Пользовательские переключатели, реализованные в Swift поверх опций ядра: `excludeDefaultRoute` (исключение `0.0.0.0/31` и `::/127`), `autoRouteUseSubRangesByDefault` (8 поддиапазонов вместо default route), `excludeAPNsRoute` (исключение `17.0.0.0/8` и `push.apple.com`). **[V]**

### 3.4. Command server / client

Сервер (`command_server.go`): **[V]**

- gRPC (`google.golang.org/grpc`) с двумя сервисами из `daemon/`: `StartedService` и `ManagedService`, плюс health-сервис.
- Транспорт: если `CommandServerListenPort == 0` — unix-сокет `<BasePath>/command.sock`; иначе TCP `127.0.0.1:<port>`.
- Аутентификация: если задан `CommandServerSecret`, проверяется метаданное `x-command-secret` (unary + stream interceptors).
- `CommandServerHandler` (реализует хост): `ServiceStop`, `ServiceReload`, `GetSystemProxyStatus`, `SetSystemProxyEnabled`, `TriggerNativeCrash`, `WriteDebugMessage`, `ConnectSSHAgent`.

Клиент (`command_client.go`): **[V]**

- `LibboxNewCommandClient(handler, options)` с подписками `CommandLog`, `CommandStatus`, `CommandGroup`, `CommandClashMode`, `CommandConnections`, `CommandOutbounds` (`command.go`); `LibboxNewStandaloneCommandClient()` — для разовых вызовов.
- `CommandClientHandler`: `Connected`, `Disconnected`, `SetDefaultLogLevel`, `ClearLogs`, `WriteLogs`, `WriteStatus`, `WriteGroups`, `WriteOutbounds`, `InitializeClashMode`, `UpdateClashMode`, `WriteConnectionEvents`.
- Операции: `SelectOutbound`, `URLTest`, `SetClashMode`, `CloseConnection(s)`, `ServiceReload`, `ServiceClose`, `ClearLogs`, `Get/SetSystemProxy…`, `GetStartedAt`, `GetAPIVersion`, `GetDeprecatedNotes`, `SetGroupExpand`, `StartNetworkQualityTest`, `StartSTUNTest`, а также большой блок Tailscale / Taildrop / OpenVPN / OpenConnect / USB-IP.
- Подключение: 10 попыток, задержка 100 мс + 50 мс × номер попытки.
- Три способа дозвона (`dialTarget`): XPC-диалер (`LibboxSetXPCDialer`, возвращает fd), unix-сокет в `BasePath`, TCP на loopback.

Как это разложено по платформам в клиенте: **[V]**

| Платформа | Канал app ↔ extension |
|---|---|
| iOS | unix-сокет `command.sock` в App Group контейнере (`FilePath.sharedDirectory`) |
| macOS (App Extension, цель `SFM`) | то же, App Group `group.<bundle>` |
| macOS (System Extension, цель `SFM.System`) | расширение держит сокет в своём home (root), приложение ходит через `NSXPCListener(machServiceName:)` → `CommandXPCService`, который отдаёт fd; на стороне приложения `LibboxSetXPCDialer(CommandXPCDialer.shared)` (`SFM.System/StandaloneApplicationDelegate.swift`) |
| tvOS | TCP `127.0.0.1:<port>` + секрет; порт и секрет приложение генерирует и передаёт в `startVPNTunnel(options:)` (`SFT/ApplicationDelegate.swift`, `ExtensionProvider.swift`) |

Причина TCP на tvOS в коде не прокомментирована. **[U]** (вероятно, ограничения общего контейнера на tvOS: `FilePath` для tvOS использует только `Library/Caches` внутри группы — это **[V]**).

Имя mach-сервиса system extension включает версию: `$(APP_GROUP_IDENTIFIER).system.$(MARKETING_VERSION)` (`SystemExtension/Info.plist`, комментарий в `Library/Shared/AppConfiguration.swift`: после замены расширения launchd продолжает держать endpoint старой версии). **[V]** Полезная для нас находка.

### 3.5. Статистика

`StatusMessage` (`command_types.go`): `Memory`, `Goroutines`, `ConnectionsIn`, `ConnectionsOut`, `TrafficAvailable`, `Uplink`, `Downlink`, `UplinkTotal`, `DownlinkTotal`. Интервал задаётся `CommandClientOptions.StatusInterval`. **[V]**

Соединения — потоком событий (`ConnectionEvents` + локальная модель `Connections` с `ApplyEvents`, фильтрами и сортировками). Группы/outbound-ы — `OutboundGroup`, `OutboundGroupItem` (с задержкой URL-теста). **[V]**

Отдельно от libbox доступны Clash API (`with_clash_api`) — HTTP-интерфейс внутри ядра; V2Ray API stats в Apple-сборке **не** включён (нет `with_v2ray_api`). **[V]**

### 3.6. Память

`setup.go` → `ReloadSetupOptions`: **[V]**

- если `OomKillerEnabled` и лимит не задан и `C.IsIos` → лимит = `oomkiller.DefaultAppleNetworkExtensionMemoryLimit` = **50 × 1024 × 1024** байт, `debug.SetGCPercent(50)` (`service/oomkiller/policy.go`);
- `debug.SetMemoryLimit(RuntimeMemoryLimit(limit))`, где `RuntimeMemoryLimit` = лимит − 2 × `defaultSafetyMargin` (5 МиБ) → при 50 МиБ мягкий лимит Go = **40 МиБ** (`service/oomkiller/timer.go`: `computeLimitThresholds`: trigger = limit − 5 МиБ, armed = limit − 10 МиБ, resume = limit − 20 МиБ);
- иначе `SetMemoryLimit(math.MaxInt64)`.

Клиент: на iOS и tvOS `options.oomKillerEnabled = true` безусловно; на macOS — из пользовательских настроек (`oomKillerEnabled`, `oomMemoryLimitMB`, `oomKillerKillConnections`). **[V]** (`ExtensionProvider.swift`).

Сервис `oom-killer` (`service/oomkiller`): **[V]**

- режимы политики: `memory_limit`, `available`, `network_extension` (последний выбирается, когда `C.IsIos && UnderNetworkExtension()`);
- на darwin+cgo подписка на `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` / `DISPATCH_MEMORYPRESSURE_CRITICAL` (`service_darwin.go`);
- реакция — закрытие соединений; есть рекордер OOM-отчётов (`oom_report.go`: черновик с метаданными, списком соединений, логом и профилями; `LibboxPromoteOOMDraft()` вызывается при следующем старте).
- TUN-стек получает колбэк `MemoryPressure` от oom-killer (`protocol/tun/inbound.go:496`).

Кроме того: тег `with_low_memory` на iOS/tvOS; `LogMaxLines = 3000` (в клиенте); на iOS `Pause()` при `sleep()` закрывает простаивающие соединения и ставит ядро на паузу, выход из паузы — по событию экрана (`ScreenStateObserver`: darwin-notify `com.apple.iokit.hid.displayStatus` → `WakeNow()`), потому что, по комментарию в коде, iOS будит расширение на каждый push. **[V]**

Константа 50 МиБ — это допущение авторов sing-box о лимите памяти NE на iOS, зашитое в код. **[V]** Фактический лимит jetsam для packet tunnel на конкретных версиях iOS/tvOS в исходниках не документирован и должен быть измерен. **[U]**

### 3.7. Как всё это живёт в `NEPacketTunnelProvider`

`Extension/PacketTunnelProvider.swift` — пустой подкласс `ExtensionProvider` (`Library/Network/ExtensionProvider.swift`), вся логика в общей библиотеке. **[V]**

- `startTunnel(options:)`: читает конфиг **из `options["configContent"]`** (приложение кладёт JSON целиком в стартовые опции — `ExtensionProfile.swift:250`), сохраняет опции на диск (снапшот в `BasePath`) и при старте без опций (On-Demand / Always-On, запуск системой) восстанавливает их оттуда. **[V]**
- Блокирующий мост: `OpenTun` вызывается из Go синхронно, Swift оборачивает async-вызовы в `runBlocking` (`Library/Network/Extension+RunBlocking.swift`). **[V]**
- `handleAppMessage`: приложение присылает новые стартовые опции → `reloadService()` под `reasserting = true`. **[V]**
- `sleep()` → `commandServer.pause()`, `wake()` → `commandServer.wake()` (на iOS wake игнорируется в Go — `command_server.go`, `Wake()` действует только на Android). **[V]**
- `stopTunnel`: `closeService()`, пауза 100 мс, `server.close()`. **[V]**
- Конфигурация VPN: `NETunnelProviderManager` + `NETunnelProviderProtocol`, `serverAddress = "sing-box"`, `providerBundleIdentifier` = `<bundle>.extension` либо `<bundle>.system`; выставляются `includeAllNetworks`, `excludeLocalNetworks`, `enforceRoutes`, On-Demand правила (`ExtensionProfile.swift`). **[V]**

---

## 4. Структура sing-box-for-apple

Один Xcode-проект `sing-box.xcodeproj`, SwiftPM-манифеста верхнего уровня нет (единственный `Package.swift` — вендоренный `Frameworks/TreeSitterJSON5`). `SWIFT_VERSION = 5.0`. **[V]**

### 4.1. Цели (из `project.pbxproj`, конфигурация Release)

| Цель | Тип | Платформа | Bundle ID | Min OS |
|---|---|---|---|---|
| `SFI` | application | iOS / iPadOS | `$(BASE)` (= `io.nekohasekai.sfamt`) | iOS 15.0 |
| `SFM` | application | macOS (App Extension-вариант) | `$(BASE)` | macOS 13.0 |
| `SFM.System` | application | macOS standalone | `$(BASE).standalone` | macOS 13.0 |
| `SFT` | application | tvOS | `$(BASE)` | tvOS 17.0 |
| `Extension` | app-extension (packet tunnel) | iOS + macOS | `$(BASE).extension` | iOS 15.0 (проектный уровень) / macOS 13.0 |
| `TVExtension` | app-extension (packet tunnel) | tvOS | `$(BASE).extension` | tvOS 17.0 |
| `SystemExtension` | system-extension | macOS | `$(BASE).system` | macOS 13.0 |
| `RootHelper` (`HelperService/`) | tool, LaunchDaemon | macOS | `$(BASE).helper` | macOS 13.0 |
| `Library` | framework | iOS + macOS + tvOS | `$(BASE).library` | 15.0 / 13.0 / 17.0 |
| `ApplicationLibrary` | framework (общий SwiftUI) | iOS + macOS + tvOS | `$(BASE).application` | 15.0 / 13.0 / 17.0 |
| `MacLibrary` | framework | macOS | `$(BASE).macapp` | 13.0 |
| `IntentsExtension` | ExtensionKit extension (App Intents) | iOS + macOS | `$(BASE).intents` | iOS 16.0 / macOS 13.0 |
| `WidgetExtension` | app-extension | iOS | `$(BASE).widget` | iOS 18.0 |
| `FileProviderExtension` | app-extension | iOS | `$(BASE).fileprovider` | iOS 16.0 |
| `ShareExtension` / `ActionExtension` | app-extension | iOS (+macOS для Share) | `.share` / `.action` | iOS 16.0 |
| `ShareExtension.System` | app-extension | macOS standalone | `$(BASE).standalone.share` | 13.0 |
| `JailbreakDaemon` | tool | iOS (jailbreak) | `$(BASE).helper` | 15.0 |
| `SFIUITests` / `SFMUITests` / `SFTUITests` | UI-тесты | — | — | 26.2 |

Все значения — **[V]** (разбор `sing-box.xcodeproj/project.pbxproj`). `BASE_PACKAGE_IDENTIFIER = io.nekohasekai.sfamt`.

Итоговые минимальные версии: **iOS 15.0, macOS 13.0, tvOS 17.0** — совпадает и с флагами gomobile (`-iosversion=15.0 -macosversion=13.0 -tvosversion=17.0`), и с `docs/clients/apple/index.md` («iOS 15.0+ / macOS 13.0+ / Apple tvOS 17.0+»), и с `pkgbuild --min-os-version 13.0`. **[V]**

### 4.2. Слои

- `Libbox.xcframework` линкуется **только** в `Library.framework` (одна запись `Libbox.xcframework in Frameworks` в pbxproj); туда же `libresolv.tbd` и `NetworkExtension.framework`. **[V]**
- `Library.framework` встраивается в приложения (`Embed Frameworks`) и используется расширением. В нём: БД (GRDB), профили, `ExtensionProvider`, `ExtensionPlatformInterface`, `CommandClient`, XPC, отчёты о крашах/OOM. **[V]**
- `ApplicationLibrary` — общий UI, `MacLibrary` — macOS-специфика (строка меню, редактор). **[V]**
- Различия платформ — через `#if os(...)` и флаг `Variant.useSystemExtension` (выставляется в `SystemExtension/main.swift`, там же `NEProvider.startSystemExtensionMode()`). **[V]**

Тип слайса gomobile (статическая библиотека внутри framework) — **[U]**, не проверено без собранного артефакта.

### 4.3. macOS: два варианта

1. **`SFM`** — sandbox-приложение + App Extension (`packet-tunnel-provider`), App Group `group.$(BASE)`. По `docs/changelog.md` (запись 1.14.0): «Due to entitlement restrictions, SFM is no longer offered on the macOS App Store; use the standalone version». **[V]** — то есть цель существует, но в Mac App Store upstream её сейчас не публикует; причина сформулирована только как «entitlement restrictions».
2. **`SFM.System`** (standalone) — Developer ID, system extension `packet-tunnel-provider-systemextension`, `com.apple.developer.system-extension.install`, App Group вида `$(TeamIdentifierPrefix)$(BASE)`, установка через `OSSystemExtensionRequest` (`Library/Network/SystemExtension.swift`), root-helper через `SMAppService.daemon` (`Library/Network/HelperServiceManager.swift`, plist `HelperService/LaunchDaemons/io.nekohasekai.sfamt.helper.plist`), распространение DMG/PKG с нотаризацией (`Makefile` клиента: `create-dmg`, `pkgbuild`, `productbuild`, `notarytool`), Homebrew cask `sfm`. Сборки arm64 / x86_64 / universal. **[V]**

### 4.4. Каналы распространения upstream

- iOS и tvOS — App Store, приложение называется «sing-box MT» (`https://apps.apple.com/app/sing-box-mt/id6785326793`), TestFlight — только спонсорам (`docs/clients/apple/index.md`). **[V]**
- По `docs/changelog.md`: клиенты переехали на новый Apple developer account; предыдущая версия называлась «sing-box VT», данные не наследуются. **[V]** Обстоятельства смены аккаунта в репозитории не описаны. **[U]**
- Jailbreak-сборка iOS (`.deb`, rootless/roothide) — отдельные цели `JailbreakDaemon`, `Jailbreak/package.sh`. **[V]** Нам не нужна.

### 4.5. Сторонние Swift-зависимости (SPM, из pbxproj)

GRDB.swift ≥ 7.11.1, dagronf/qrcode ≥ 28.1.0, swift-markdown-ui ≥ 2.4.1, microsoft/plcrashreporter ≥ 1.12.2, BinaryCodable ≥ 4.0.0 и LegacyBinaryCodable ≥ 2.0.3, Lakr233/libghostty-spm, DeviceKit ≥ 5.8.0, nekohasekai/CodeEditSourceEditor (ветка `main`). **[V]**

---

## 5. Entitlements

Все значения — из `*.entitlements` в репозитории клиента. **[V]**

| Цель | Entitlements |
|---|---|
| `SFI` (iOS app) | `networking.networkextension: [packet-tunnel-provider]`; App Group `$(APP_GROUP_IDENTIFIER)`; iCloud: `icloud-container-identifiers`, `icloud-services: [CloudDocuments]`, `ubiquity-container-identifiers` |
| `Extension` (iOS/macOS NE) | `networkextension: [packet-tunnel-provider]`; `networking.multicast`; `networking.wifi-info`; `app-sandbox`; App Group; `network.client`; `network.server`; `personal-information.location` |
| `SFM` (macOS app, sandbox) | `networkextension: [packet-tunnel-provider]`; `app-sandbox`; App Group; iCloud (как у SFI); `files.user-selected.read-write`; `network.client`; `network.server`; `device.camera`; `device.usb` |
| `SFM.System` (standalone app) | `networkextension: [packet-tunnel-provider-systemextension]`; `system-extension.install`; App Group `$(TeamIdentifierPrefix)$(BASE)`; iCloud; `device.usb`; `networking.wifi-info`; `personal-information.location` (без `app-sandbox`) |
| `SystemExtension` | `networkextension: [packet-tunnel-provider-systemextension]`; `networking.multicast`; `app-sandbox`; App Group `$(TeamIdentifierPrefix)$(BASE)` |
| `SFT` (tvOS app) | `networkextension: [packet-tunnel-provider]`; App Group |
| `TVExtension` | `networkextension: [packet-tunnel-provider]`; `networking.multicast`; App Group |
| `RootHelper` (macOS) | `app-sandbox = false`; App Group `$(TeamIdentifierPrefix)$(BASE)` |
| Widget / FileProvider | только App Group |
| Share / Action | `app-sandbox`, App Group, `files.user-selected.read-only` |
| Intents | App Group, iCloud, `app-sandbox`, `network.client` |
| `JailbreakDaemon` | приватные (`platform-application`, `com.apple.private.security.no-sandbox`, …) — нерелевантно |

Замечания:

- `com.apple.developer.networking.multicast` — управляемый entitlement, требующий отдельного запроса у Apple. **[U]** (факт наличия в файлах — **[V]**).
- Формат App Group отличается: `group.<id>` для App Store-целей и `<TeamID>.<id>` для standalone macOS (настройка `APP_GROUP_IDENTIFIER` в pbxproj). **[V]**
- Hardened Runtime включён у macOS-целей (`ENABLE_HARDENED_RUNTIME = YES`). **[V]**
- Info.plist: `ITSAppUsesNonExemptEncryption = false`; описания использования локальной сети, камеры (QR) и геолокации (для SSID/BSSID-правил); `UIBackgroundModes`: `fetch`, `processing` на iOS, `fetch` на tvOS; `BGTaskSchedulerPermittedIdentifiers: <bundle>.update_profiles` (`SFI/Info.plist`, `SFT/Info.plist`, `SFM.System/Info.plist`). **[V]**

---

## 6. Размер бинарей

Собранных артефактов в клонах нет, сборка запрещена — **точных чисел нет**. Любые цифры размеров `Libbox.xcframework`, `.ipa` и памяти процесса — **[U]** и в этот документ намеренно не внесены.

Что можно утверждать по исходникам (**[V]**) — факторы, увеличивающие размер Apple-сборки upstream:

- `with_naive_outbound` тянет статические библиотеки cronet (Chromium net stack) под каждый срез: `cronet-go/lib/ios_arm64`, `tvos_arm64`, `darwin_arm64`, `darwin_amd64` + симуляторы (`go.mod`, строки 147–169). Вероятно, это крупнейший отдельный вклад (**[U]** по величине).
- `with_tailscale` (форк `github.com/sagernet/tailscale`), смягчён набором `ts_omit_*`.
- `with_openvpn`, `with_openconnect`, `with_usbip`, `with_quic` (форк quic-go), `with_wireguard`, `with_utls`.
- Полноценный `google.golang.org/grpc` для command server (отдельно от «lite»-gRPC транспорта V2Ray).
- Косвенные зависимости из `go.mod`, попадающие в бинарь при соответствующих импортах: `anthropic-sdk-go`, `openai-go` (нужны для `with_ccm`/`with_ocm`, в Apple-сборке эти теги выключены), `certmagic` (только `with_acme`, выключен).
- Уменьшающие факторы: `-s -w -buildid= -trimpath`, `DEAD_CODE_STRIPPING = YES`.

Рекомендация: собственная сборка libbox под нашу платформу должна иметь **сокращённый список тегов** (кандидаты на исключение: `with_naive_outbound`, `with_tailscale`, `with_usbip`, `with_openvpn`, `with_openconnect`) — это и размер, и память расширения. Исключение тегов технически штатно: у каждого есть `*_stub.go` в `include/`. **[V]** Android legacy-вариант upstream уже собирается без `with_naive_outbound` (`buildAndroid`, `filterTags`). **[V]** Реальный выигрыш измерить на macOS-сборщике. **[U]**

Go-рантайм присутствует и в приложении, и в расширении (оба грузят `Library.framework` с Libbox) — память приложения это тоже затрагивает. **[V]** по структуре линковки.

---

## 7. Лицензия

### 7.1. sing-box

Файл `/root/.cache/np-research/sing-box/LICENSE` (17 строк) — это не полный текст GPL, а уведомление + дополнительное условие. Дословно: **[V]**

```
Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.

In addition, no derivative work may use the name or imply association
with this application without prior consent.
```

То же условие повторено в `README.md:29` и `docs/index.md:29`. **[V]**

Итого: **GPL-3.0-or-later + условие об имени**: производная работа не может использовать название «sing-box» или подразумевать связь с приложением без предварительного согласия.

### 7.2. sing-box-for-apple

`/root/.cache/np-research/sing-box-for-apple/LICENSE` (13 строк) — то же уведомление GPL-3.0-or-later, **без** дополнительного абзаца об имени. **[V]** Но клиент статически включает libbox (sing-box), так что условие ядра на итоговый продукт распространяется в любом случае.

### 7.3. Отдельных условий про App Store в текстах лицензий нет

Ни в одном из двух LICENSE нет исключения/разрешения для App Store (в отличие, например, от проектов с явным «App Store exception»). **[V]** — проверено чтением обоих файлов целиком.

### 7.4. Следствия для нашей платформы

- Наш продукт, линкующий libbox, становится производной работой под GPL-3.0-or-later: весь связанный код (Swift control plane в том же бинаре/процессе) должен распространяться на совместимых условиях с исходниками. Для open-source проекта это приемлемо, но **лицензия всей платформы де-факто определяется GPLv3**, если sing-box линкуется в процесс. **[U]** — юридическая оценка, не заключение юриста.
- Имя: в названии продукта, bundle display name, метаданных App Store нельзя использовать «sing-box» и нельзя создавать впечатление аффилированности без согласия автора. Упоминание в формате «движок: sing-box» в разделе лицензий/«О программе» — зона, требующая осторожности; при сомнениях запросить согласие. **[U]** в части трактовки.
- Совместимость GPLv3 с условиями App Store — известный спорный вопрос; сам правообладатель sing-box публикует своё приложение в App Store (он вправе как автор), для третьих лиц это разрешением не является. **[U]** — требуется юридическая проверка до публикации.
- Зависимости имеют собственные лицензии (форк gomobile — BSD, как у Go: `LICENSE` форка **[V]**; cronet/Chromium, tailscale, quic-go, wireguard-go и др. — не аудировались здесь **[U]**).
- Xray-core как второй движок лицензирован отдельно (см. соответствующий документ); совместная линковка двух движков в один бинарь требует проверки совместимости лицензий. **[U]**

---

## 8. Выводы для архитектуры NetworkPlatform

1. **Граница адаптера движка совпадает с парой `PlatformInterface` + `CommandServer/CommandClient`.** Наш Swift control plane должен иметь собственный протокол движка, а реализация для sing-box — тонкая обёртка над `LibboxSetup` → `LibboxNewCommandServer` → `startOrReloadService`. Типы `Libbox*` не должны утекать выше адаптера: интерфейс upstream широкий и привязан к их фичам (Tailscale, USB/IP, OpenVPN).
2. **Один движок на процесс расширения**: состояние libbox глобальное. Смена движка = перезапуск туннеля, а не горячее переключение.
3. **Канал app ↔ extension у upstream — gRPC по unix-сокету в App Group** (TCP+секрет на tvOS, XPC+fd для system extension). Нам нужен единый абстрактный канал статистики/управления с этими тремя транспортами под капотом, либо свой канал поверх `sendProviderMessage` для базовых команд.
4. **Конфиг передаётся строкой JSON в стартовых опциях и кешируется на диске** для запусков системой (On-Demand). Схему стоит повторить, но секреты в снапшоте на диске — предмет нашего отдельного решения по безопасности.
5. **Память**: ориентир upstream — 50 МиБ на iOS NE с мягким лимитом Go 40 МиБ, GC 50 %, `with_low_memory`, OOM-killer по memory pressure, пауза при сне. Для нашей сборки — сокращать теги и измерять.
6. **Тулчейн**: Go 1.26.x (в CI 1.26.10; минимум по `go.mod` 1.25.5) + форк `sagernet/gomobile` (v0.1.12/v0.1.13 — расхождение между `go.mod` и `Makefile`, фиксировать осознанно) + патч `internal/cpu` для iOS/tvOS + обязательные `-ldflags` из `release/LDFLAGS`. Нужен macOS-сборщик с Xcode; на этом Linux-хосте библиотеку не собрать.
7. **visionOS upstream не поддерживает** (нет цели в gomobile-форке, нет cronet-срезов, XR-совместимость расширений отключена). Это самый крупный пробел относительно наших целевых платформ.
8. **XHTTP отсутствует в sing-box** — подтверждает необходимость Xray-core как второго движка.
9. **macOS**: для App Store-варианта upstream сам отказался от публикации («entitlement restrictions»); рабочий у них путь — Developer ID + system extension + root helper. Планировать macOS сразу в двух вариантах или начать со standalone.
10. **Получение utun fd через KVC `socket.fileDescriptor`** — приватный путь с запасным перебором дескрипторов; закладывать оба и покрыть тестом на каждой новой версии ОС.

## 9. Что осталось непроверенным (требует macOS-сборщика или внешних источников)

- Реальные размеры `Libbox.xcframework` по срезам и вклад каждого тега.
- Фактические jetsam-лимиты NE на iOS 15–26 / tvOS 17+ и потребление памяти ядра под нагрузкой.
- Собирается ли libbox под visionOS (GOOS=ios + xros SDK) и работает ли packet tunnel там.
- Какая версия Xcode стоит за меткой раннера `xcode-27`; минимальная версия Xcode для проекта.
- Содержимое тега `v0.1.13` форка gomobile (проверен только HEAD `4386c41`).
- Отличия API libbox между стабильной 1.14.x и исследованной 1.15.0-alpha.13.
- Юридическая оценка GPLv3 + условия об имени применительно к App Store.
