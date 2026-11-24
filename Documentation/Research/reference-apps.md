# Аудит референс-клиентов: Karing и hiddify-app

Дата проверки: 2026-11-24. Источники (shallow-клоны, только чтение):

| Репозиторий | Коммит | Путь |
|---|---|---|
| KaringX/karing | `d75fd4ec125e33b04477e23f6df8818c7fe3a350` (2026-11-19) | `/root/.cache/np-research/karing` |
| hiddify/hiddify-app | `66c17f83a55233ef4a1c80a4606df811227cc210` (2026-11-22) | `/root/.cache/np-research/hiddify-app` |
| hiddify/hiddify-core (сабмодуль hiddify-app, в клоне не развёрнут) | `b736fe9926bea6680b429e0900f040eed2aeee45` | скачаны только `go.mod`, `Makefile`, `LICENSE.md`, `README.md` с raw.githubusercontent.com по этому SHA |

Пометки: **[V]** = VERIFIED (видел в исходниках, путь указан), **[U]** = UNVERIFIED (по памяти / вторичный источник / вывод без запуска).

Оговорки:

- Ничего не собиралось и не запускалось (на хосте нет Flutter/Go/Xcode). Всё про поведение в рантайме — чтение кода.
- Исходники ядра hiddify (`hiddify-core`, вложенный `hiddify-sing-box`) целиком не читались: только `go.mod` и `Makefile`. Что именно делает ядро внутри (парсер, сборка конфига, keep-top) — известно по комментариям и gRPC-схеме в hiddify-app, то есть **[U]** на уровне реализации.
- Значительная часть Karing в репозитории отсутствует (см. 1.2), поэтому его логика импорта и сборки конфига описана только по вызовам из открытого кода.

---

## 0. Сводка для принятия решений

1. **Karing фактически не open source.** В публичном репозитории нет 65 Dart-файлов, которые импортирует открытый код (весь `lib/app/utils/`, включая сборщик sing-box-конфига, парсеры подписок, клиент Clash API), нет Flutter-плагина `vpn_service`, нет Swift-фреймворка `LibVpnCore` с реализацией packet tunnel. Собрать приложение из репозитория нельзя. Как «открытый референс» годится только UI, модели настроек и схема tvOS. **[V]**
2. **hiddify-app открыт, но лицензия непригодна для заимствования кода**: GPLv3 + дополнительные условия (только некоммерческое использование, обязательный GitHub-форк, запрет похожего UI/названия в сторах). Читать и перенимать идеи можно, копировать код в наш проект нельзя. **[V]** (`LICENSE.md`)
3. **Оба — Flutter + одно Go-ядро на базе sing-box.** Ни один не даёт «сменных движков»: Karing использует свой форк sing-box; hiddify — монолитное ядро `hiddify-core`, куда одновременно вкомпилированы форк sing-box, xray-core, libXray, Psiphon, WARP, AmneziaWG, Tor и др. **[V]** (`go.mod` hiddify-core)
4. **Модели IPC разные и обе поучительны.** Karing: локальный Clash API (HTTP/WebSocket + secret) внутри расширения + закрытый плагин. hiddify: gRPC-сервер ядра на `127.0.0.1` с mTLS, причём на iOS ядро запущено дважды — в процессе приложения и в расширении. **[V]**
5. **Ни один не поддерживает visionOS.** tvOS есть только у Karing, и там это отдельное нативное SwiftUI-приложение, а не Flutter. **[V]**
6. Главный вывод для нас: собственный Swift control plane с типизированной моделью профиля и узким интерфейсом движка — это то, чего нет ни у одного из них; оба расплачиваются за его отсутствие (см. разделы 4 и 5).

---

## 1. Karing

### 1.1. Архитектура

- UI: Flutter (`pubspec.yaml`: `sdk: ">=3.12.2 <4.0.0"`, `flutter: ">=3.44.0"`, версия приложения `1.2.26+2934`). Состояние — `provider` плюс статические синглтоны-менеджеры (`lib/app/modules/server_manager.dart`, `setting_manager.dart`) с ручными списками колбэков. **[V]**
- Ядро: модифицированный sing-box. README ссылается на форк `KaringX/sing-box` (репозиторий публично доступен — проверено `git ls-remote`, 2026-11-24). В коде зашита версия ядра `kCoreVersion = "1.14.0"` (`lib/app/modules/setting_manager.dart`). **[V]**
- Apple-библиотека ядра — `Libbox.xcframework`, ожидается по пути `bind/apple/Libbox.xcframework`; путь в `.gitignore`, в репозитории его нет (`ios/Runner.xcodeproj/project.pbxproj`, `.gitignore`). **[V]**
- Целевые платформы Apple: iOS 15.0, macOS 12.0, tvOS 17.0 (`ios/Podfile`, `macos/Podfile`, `tvos/Podfile`, `pbxproj`). visionOS-таргета нет. **[V]**
- Объём открытого Dart-кода: около 56 тыс. строк, из них основное — экраны (`lib/screens/`), где отдельные файлы по 2–3,7 тыс. строк (`group_helper.dart` 3761, `settings_screen.dart` 3257, `home_screen.dart` 3019). **[V]**

### 1.2. Что НЕ открыто (главная находка)

Проверка: для каждого `import 'package:karing/...'` в `lib/` проверено существование файла.

| Отсутствует | Что это | Доказательство |
|---|---|---|
| `lib/app/utils/*` — 61 файл | Вся бизнес-логика: `singbox_config_builder.dart`, `singbox_outbound.dart`, `singbox_dns.dart`, `proxy_conf_utils.dart` (типы и парсинг подписок), `clash_api.dart`, `convert_utils.dart`, `diversion_custom_utils.dart`, `backup_and_sync_utils.dart`, `icloud_utils.dart`, `http_utils.dart`, `did.dart` (идентификатор устройства), `sentry_utils.dart` и др. | импортируются десятки раз, в `git ls-files lib/app` каталога `utils` нет **[V]** |
| `lib/app/local_services/vpn_service.dart` | Обёртка `VPNService` (start/stop/reload/setCurrent/getState…) | импортируется 22 раза, файла нет **[V]** |
| `lib/app/private/*` | `app_url_utils_private.dart`, `sentry_utils_private.dart` | каталог явно в `.gitignore` (`/lib/app/private`) **[V]** |
| Flutter-плагин `vpn_service` | Нативный мост к NetworkExtension (`FlutterVpnService.*`) | `pubspec.yaml`: `vpn_service: path: ../vpn-service/`; `github.com/KaringX/vpn-service` — «Repository not found» (2026-11-24) **[V]** |
| `bind/apple/LibVpnCore/` | Swift-фреймворк с `ExtensionProvider.swift`, `ExtensionPlatformInterface.swift`, `Extension+RunBlocking.swift`, `LibVpnCore.swift` | на файлы ссылается `pbxproj`, в репозитории под `bind/` есть только `bind/windows` **[V]** |
| `VpnServiceHandler.swift`, `VpnServiceConfig` | Используются в tvOS-приложении | `.gitignore`: `ios/karingWidget/VpnServiceHandler.swift`; в `tvos/Runner/` нет **[V]** |
| `macos/karingServiceSE/` | Таргет system extension | `pbxproj` ссылается на `karingServiceSE/karingServiceSE.entitlements`, каталога нет **[V]** |

Следствие: всё, что касается реальной реализации packet tunnel у Karing (настройки `NEPacketTunnelNetworkSettings`, получение fd, обработка смены сети, лимиты памяти), по этому репозиторию **не проверяемо**. Имена файлов `ExtensionProvider.swift` / `ExtensionPlatformInterface.swift` / `Extension+RunBlocking.swift` совпадают с файлами sing-box-for-apple, то есть реализация, вероятно, производна от него **[U]**.

Бинарные блобы в git: только Windows-рантаймы (`bind/windows/**`: `ucrtbase.dll`, `msvcp140.dll`, `icu.dll` и т. п.) и ассеты (rule-set `.srs`: 1984 файла geosite, 278 geoip; встроенный веб-дашборд `assets/zashboard/`). Ядро в git не лежит. CI-конфигураций сборки в `.github/` нет (только шаблоны issue). **[V]**

### 1.3. Packet tunnel и IPC на Apple (что видно)

- Весь открытый код расширения — 4 строки: `class PacketTunnelProvider: ExtensionProvider {}` с `import LibVpnCore` (`ios|macos|tvos/karingService/PacketTunnelProvider.swift`). **[V]**
- Entitlements (`ios/karingService/karingService.entitlements`, `ios/Runner/Runner.entitlements`): `packet-tunnel-provider`, App Group `group.com.nebula.karing`, `wifi-info`, iCloud (`CloudDocuments`, контейнер `iCloud.com.nebula.karing`), keychain access group. macOS-приложение дополнительно: `packet-tunnel-provider-systemextension`, `system-extension.install`, sandbox, и `temporary-exception.mach-register.global-name = com.apple.screencapture.interactive` (для сканирования QR с экрана). **[V]**
- IPC, судя по вызовам из открытого кода:
  - управление жизненным циклом — через закрытый плагин (`VPNService.start/stop/reload/getState`, `FlutterVpnService.setAlwaysOn/isServiceAuthorized/authorizeService/getAppGroupDirectory`); **[V]** (вызовы), реализация **[U]**
  - данные рантайма — через **Clash API ядра** в расширении: `ClashApi.getDelay`, `getConnectionsUrl` (WebSocket), `getLogsUrl`, `dnsQuery`, `outboundQuery`, `getRemoteRulesetsStates`, `resetNetwork`, `resetOutboundConnections`, `updateUrltestCheck`. Часть этих методов (DNS-запрос, «какой outbound получит этот адрес», состояние удалённых rule-set) в апстримном Clash API sing-box отсутствует — это расширения форка **[U]** (вывод по именам; код `clash_api.dart` закрыт);
  - конфигурация — файлами в App Group (`service.json`, `service_core.json`, `service_core.log`, `service_error.log` в `Library/Caches` контейнера; видно в `tvos/Runner/DashboardView.swift`). **[V]**
- Тестирование задержек работает только при запущенном VPN: `ServerManager.schedulerTestLatency()` первым делом проверяет `VPNService.getStarted()` и очищает очередь, если туннель не поднят (`lib/app/modules/server_manager.dart`). **[V]**

### 1.4. tvOS: отдельное нативное приложение

- `tvos/Runner/` — чистый SwiftUI (`Application.swift`, `DashboardView.swift`, 578 строк), без Flutter. SwiftPM-зависимости: `Swifter` (HTTP-сервер), `QRCode`, `KeychainSwift` (`Package.resolved`). **[V]**
- Схема «телефон как пульт»: TV поднимает HTTP-сервер на порту 4040 и показывает QR `karing://tvos?ips=…&port=…&uuid=…&cport=…&secret=…`; телефон (Flutter, `lib/screens/home_tvos_screen.dart`) собирает готовый sing-box JSON (`SingboxExportType.tvos`) и шлёт `POST /sync-upload?uuid=…&type=json`; дальше ходит напрямую в Clash API ядра на TV (`http://host:cport/`, `ws://…/connections/?token=secret`). **[V]**
- Дефекты этой схемы, видимые в коде `DashboardView.swift`: **[V]**
  - обмен по открытому HTTP в локальной сети, включая secret Clash API и весь конфиг с учётными данными узлов;
  - `uuid` проверяется только в `/sync-upload`; `/delete-core-config` и `/get-file-content` его не проверяют;
  - `/get-file-content?filename=` подставляет имя в путь без нормализации (чтение произвольного файла контейнера, `../`);
  - зашит особый URL (`https://novaclash.com/sub/…/singbox`), при вводе которого подставляется конфиг из бандла — обходной путь для демонстрации/ревью;
  - всё состояние экрана — статические поля и `@State` в одном View, ошибки печатаются через `print`.

### 1.5. Модель конфигурации и импорт

- Модель «группа подписки → серверы»: `ServerConfig.items: [ServerConfigGroupItem]`, у группы тип `SubscriptionLinkType` (значения, встречающиеся в открытом коде: `clash`, `singbox`, `v2ray`, `ss`, `wireguard`, `unknown`). Определение enum и парсеры — в закрытом `proxy_conf_utils.dart`. **[V]** (использование), полнота списка **[U]**
- README заявляет совместимость с Clash («full clash, partial clash.meta»), V2ray/V2fly, sing-box, Shadowsocks, Sub, GitHub-подписками. Проверить глубину поддержки нельзя — код закрыт. **[U]**
- Способы добавления (по экранам): ссылка или вставленный текст, файл, QR с камеры, QR со снимка экрана, слияние и переупорядочивание профилей (`add_profile_by_*_screen.dart`, `my_profiles_merge_screen.dart`). **[V]**
- Подмена User-Agent при загрузке подписки, чтобы панель отдала нужный формат: список `kUserAgentList` (`mihomo/1.19.28`, `clash-verge`, `FLClash`, `ClashMeta`, `v2ray`, `sing-box 1.14.0`, `NekoBox/…`, `HiddifyNext`) с таблицей миграции старых значений. **[V]**
- Итоговый конфиг ядра собирается на стороне Dart (`SingboxConfigBuilder.inbounds/outbounds/dns/route/ntp/endpoints`) — то есть приложение генерирует sing-box JSON само, ядро конфиг не строит. **[V]** (вызовы)
- Синхронизация и резервные копии: iCloud Documents, WebDAV, синхронизация по LAN, ZIP-экспорт/импорт, автобэкап (экраны `backup_and_sync_*`). **[V]**

### 1.6. Маршрутизация, DNS, автовыбор

- Маршрутизация — «группы разведения» (diversion groups): упорядоченный список правил, у каждого набор встроенных rule-set (`geosite:…`, `geoip:…`, `acl:…`), опционально Android-пакеты, целевой outbound (`direct` / `block` / `currentSelected` / конкретный сервер / urltest-группа) и выключатель. Региональные пресеты лежат как данные: `assets/datas/preset/{default,cn,ir,ru}.json` (в `ru.json` 23 правила). **[V]**
- Встроенные rule-set поставляются в бинарном формате `.srs` прямо в ассетах; обновляемые — из `KaringX/karing-ruleset`. **[V]**
- DNS (`SettingConfigItemDNS`): четыре роли резолверов (`DNSType`: resolver / outbound / direct / proxy), режим разрешения для прокси (`proxy` / `direct` / `fakeip`), до 10 серверов на роль, встроенный каталог публичных резолверов (UDP/DoT/DoH/DoH3), экран автоподбора DNS по задержке (`dns_auto_setup_screen.dart`), стратегия IP (`ipv4_only … ipv6_only`). **[V]**
- TUN (`SettingConfigItemTUN`): MTU по умолчанию 4064, флаги, зеркалящие настройки NetworkExtension — `includeAllNetworks`, `excludeLocalNetworks`, `excludeCellularServices`, `excludeApns`, `excludeDeviceCommunication`, `enforceRoutes`, а также `autoRouteUseSubRangesByDefault` (помечен «ios/macos») и `appendHttpProxy` (комментарий: «some apps skip tun route»). **[V]**
- Автовыбор (`SettingConfigItemAutoSelect`): интервал urltest по умолчанию 8 ч, допуск 0 мс, приоритет избранного, ограничение числа узлов (`limitedNum = 2000`), отдельный интервал health-check выбранного узла, перетест при смене сети, пользовательские urltest-группы (`urltest_group_custom_screen.dart`). **[V]**

### 1.7. Диагностика

- `net_check_screen.dart` — пошаговая проверка: связность → удалённые rule-set → DNS для outbound → задержка outbound → DNS мимо outbound → DNS домена → связность с хостом → таблица маршрутов (последний шаг отключён на iOS). **[V]**
- `diversion_rule_detect_screen.dart` — «какое правило и какой outbound сработают для этого домена/IP» (через расширенный Clash API). **[V]**
- `net_connections_screen.dart` — живые соединения (WebSocket Clash API), встроенный веб-дашборд zashboard (`assets/zashboard/`). **[V]**
- Телеметрия: Sentry (`sentry_flutter`), удалённый конфиг с `dot.karing.app` (`RemoteConfig`: уведомления, каналы, автообновление, `outpost`, `statistics`, поле `ispPanelJs`), проверка раз в 30 минут на десктопе и при каждом возврате в приложение / подключении VPN (`remote_config_manager.dart`). Реклама «провайдеров-партнёров» встроена в README и в продукт (`board_provider_*`, `remote_isp_config*`). **[V]**

### 1.8. Лицензия

`LICENSE.md`: GPLv3-or-later («either version 3 of the License, or (at your option) any later version»), © 2024 nebula, плюс условие: «no derivative work may use the name or imply association with this application without prior consent». **[V]**

Практически: открытая часть — GPLv3 (несовместима с нашим проектом, если он не GPLv3-совместим), а закрытая часть недоступна вовсе. Соответствие самого Karing лицензии GPLv3 ядра sing-box при закрытых компонентах, линкуемых в одно приложение, — вопрос к ним; для нас это сигнал не считать проект источником кода. **[U]** (юридическая оценка)

---

## 2. hiddify-app

### 2.1. Архитектура

- UI: Flutter (`pubspec.yaml`: `sdk: ^3.10.4`, `flutter: ^3.38.5`, версия `5.9.15+50915`), Riverpod + hooks, `freezed`/`dart_mappable`, `fpdart` (Either/TaskEither), БД `drift`/sqlite, навигация `go_router`. Структура feature-first (`lib/features/<feature>/{data,model,notifier,overview,widget}`), около 69 тыс. строк Dart. **[V]**
- Ядро: `hiddify-core` — git-сабмодуль (`.gitmodules`: `ssh://git@github.com/hiddify/hiddify-core`, ветка `v3`), версия закреплена в `dependencies.properties` (`core.version=5.9.15`). Приложение ядро **не собирает**, а скачивает готовые артефакты с GitHub Releases ядра (`Makefile`: `CORE_URL=https://github.com/hiddify/hiddify-core/releases/download/v$(core.version)`, цели `ios-libs`, `macos-libs`). **[V]**
- Состав ядра (`go.mod` hiddify-core на закреплённом SHA): **[V]**
  - `github.com/sagernet/sing-box v1.13.0`, заменён на локальный форк `./hiddify-sing-box`; также заменены на локальные копии `sing`, `sing-tun`, `sing-mux`, `sing-vmess`, `gvisor`, `wireguard-go`, `tailscale`, `amneziawg-go`;
  - `github.com/xtls/xray-core` и `github.com/xtls/libxray` — Xray встроен в тот же бинарь (в UI типы `xVLESS`, `xVMess`, `xTrojan`, `xFragment`, `xShadowsocks`, `xSocks` — `lib/singbox/model/singbox_proxy_type.dart`);
  - `github.com/hiddify/ray2sing` (конвертер ссылок/Xray → sing-box), `github.com/xmdhs/clash2singbox` (Clash → sing-box);
  - `bepass-org/warp-plus` (форк hiddify), Psiphon (`psiphon-tunnel-core`, форк), `enfein/mieru`, `cretz/bine` (Tor), `showwin/speedtest-go`, gRPC, `filippo.io/age` (шифрование диагностики).
  - Теги сборки (`Makefile` ядра): `with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,…` + `with_embedded_tor,with_openvpn,with_openconnect,with_masque,with_kcp,…`; для iOS добавляются `with_dhcp,with_low_memory`.
- Apple-сборка ядра: `gomobile bind` (sagernet/gomobile v0.1.11–v0.1.12) пакетов `sing-box/experimental/libbox` + `./platform/mobile` → `HiddifyCore.xcframework` (iOS) и `HiddifyTunnelCore.xcframework` (macOS, `-macosversion 12.0`). **[V]**
- Платформы Apple: iOS/iPadOS 15.5 (`ios/Podfile`, `TARGETED_DEVICE_FAMILY = "1,2"`), macOS 12.0. Каталогов/таргетов tvOS и visionOS нет. **[V]**
- CI: `.github/workflows/build-ios.yml` (runner `macos-26`, `make ios-validate`, smoke-тест в симуляторе, подписанный IPA → TestFlight), `build-macos.yml` (Developer ID dmg/pkg + Mac App Store). В `Makefile` цели `ios-libs` и `ios-release` при этом помечены `#not tested`. **[V]**

### 2.2. Packet tunnel на iOS

Файлы: `ios/HiddifyPacketTunnel/SingBox/{ExtensionProvider,ExtensionPlatformInterface,Extension+RunBlocking}.swift`, `ios/HiddifyPacketTunnel/PacketTunnelProvider.swift`, `ios/Runner/VPN/VPNManager.swift`.

- Каркас прямо заявлен как производный от sing-box-for-apple (комментарий в `ExtensionProvider.swift`: «following sing-box-for-apple's Library/Network/ExtensionProvider.swift, adapted to Hiddify's model»). **[V]**
- Ключевое отличие модели: расширение **не запускает ядро по конфигу**, а только поднимает в себе hiddify-core с gRPC-сервером (`MobileSetup(setupOptions, platformInterface, …)`, `listen = "127.0.0.1:<port>"`, порт по умолчанию 17079) и ждёт, пока приложение даст команду `start` по gRPC. **[V]**
- Запуск системой (On-Demand, тумблер в Настройках): `options == nil` → `MobileStart("", "", …)`, ядро стартует «с последнего запроса приложения». **[V]**
- Остановка ядра «само по себе» (неудачный start/reload): `MobileSetCoreStoppedListener` → `cancelTunnelWithError`. Комментарий фиксирует прежний баг: при закрытом приложении туннель оставался поднятым без ядра и забирал весь трафик устройства. **[V]**
- Память: `LibboxSetMemoryLimit(true)` включается всегда («iOS ends a packet tunnel that outgrows its memory budget»), плюс тег `with_low_memory`. При этом приложение всё ещё передаёт в опциях `DisableMemoryLimit` (`VPNManager.connect`) — параметр расширением игнорируется. **[V]**
- `sleep()` пустой («pausing broke reconnecting after wake»), `wake()` → `MobileWake()`. **[V]**
- Сетевые настройки (`ExtensionPlatformInterface.openTun`): `NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "::1")`, MTU и маршруты из опций ядра, `NEDNSSettings` с `matchDomains = [""]`, `NEProxySettings` при системном прокси; файловый дескриптор TUN берётся через KVC `tunnel.packetFlow.value(forKeyPath: "socket.fileDescriptor")` — приватный путь, тот же приём, что в sing-box-for-apple. Смена сети — `NWPathMonitor`. **[V]**
- `VPNManager`: одна конфигурация `NETunnelProviderManager` (`serverAddress = "localhost"`), «Always-on» реализован как `NEOnDemandRuleConnect` (`interfaceTypeMatch = .any`), включается только при connect и снимается при disconnect, чтобы система не подняла туннель после ручной остановки. **[V]**
- Entitlements: `packet-tunnel-provider`, App Group `group.$(BASE_BUNDLE_IDENTIFIER)`, `com.apple.developer.networking.vpn.api = allow-vpn`. Есть `PrivacyInfo.xcprivacy` (FileTimestamp C617.1, SystemBootTime 35F9.1). **[V]**
- Мёртвый код: `PacketTunnelProvider.handleAppMessage("stats")` всегда отдаёт `0,0` (чтение трафика закомментировано), а приложение раз в секунду шлёт этот запрос таймером (`VPNManager.updateStats`); `SingBox.setupConfig` — целиком закомментированное тело; `ios/Shared/CommandClient.swift` — старый клиент libbox command server. **[V]**

### 2.3. IPC приложение ↔ ядро

- Единый протокол — **gRPC поверх loopback TCP** (`lib/hiddifycore/`, proto в `android/app/src/main/protos/v2/**`). Сервис `Core`: `setup`, `start`, `startService`, `stop`, `restart`, `hotReload`, `parse`, `changeHiddifySettings`, `selectOutbound`, `urlTest`, `urlTestActive`, `uploadTest`/`downloadTest`, `generateWarpConfig`, `fetchUrl`, `startDeepSearch`, `exportDiagnostics`, `listCrashReports`; стримы `coreInfoListener`, `outboundsInfo`, `mainOutboundsInfo`, `getSystemInfoStream`, `logListener`. **[V]**
- На iOS **два экземпляра ядра**: «foreground» в процессе приложения (порт 17078, поднимается через method channel `setup` → `MobileSetup(opts, nil, …)`; используется для парсинга, загрузки и т. п.) и «background» в расширении (порт 17079). (`core_interface_mobile.dart`: `portFront = 17078`, `portBack = 17079`; `MethodHandler.swift`). **[V]**
- Защита канала: режимы `SetupMode` — `GRPC_NORMAL`/`GRPC_BACKGROUND` (mTLS) и `*_INSECURE`. Клиентский сертификат создаётся один раз и кладётся в общий каталог (`grpc/client.crt` в App Group); наличие файла служит для расширения переключателем «включить mTLS». Поле `secret` передаётся пустым. (`grpc_client_identity.dart`, `ExtensionProvider.swift`). **[V]**
- Состояние VPN на мобильных берётся из платформы (`NEVPNStatus` → EventChannel), а не из ядра: комментарий «Platform VPN/service status is the source of truth on mobile (survives app relaunch)». **[V]**
- Комментарий в `core_interface_mobile.dart` фиксирует утечку: каждый resume создавал новые gRPC-каналы к расширению, старые жили до idle-таймаута — «which has a tight memory cap on iOS». **[V]**
- В проект включены сгенерированные Dart-файлы protobuf (57 файлов в `lib/hiddifycore/generated/`), хотя `AGENTS.md` требует не коммитить сгенерированное. **[V]**

### 2.4. macOS: три варианта доставки туннеля

`macos/Runner/Configs/*.xcconfig`, `macos/Runner/*.entitlements`, `core_interface_macos.dart`: **[V]**

| Сборка | Туннель | Entitlement | Sandbox |
|---|---|---|---|
| Mac App Store | app extension (`HiddifyPacketTunnelAppex`) | `packet-tunnel-provider` | да |
| Developer ID (dmg/pkg) | system extension (`HiddifyPacketTunnel`, `main.swift` → `NEProvider.startSystemExtensionMode()`, активация через `OSSystemExtensionRequest` в `SystemExtensionController.swift`) | `packet-tunnel-provider-systemextension` + `system-extension.install` | нет (hardened runtime) |
| Без Developer ID | NetworkExtension нет; полный core как root-демон launchd (`macos/AdminBgService/install-admin-bgservice.sh`, `Hiddify --tunnel run`) | — | нет |

- На macOS расширение читает конфигурацию из сохранённого `providerConfiguration`, а не из опций старта — с явным обоснованием: on-demand должен работать при закрытом приложении. На iOS та же задача решена иначе («последний запрос»). **[V]**
- Go-вызовы сериализованы на отдельной очереди (`engineQueue`), потому что Go синхронно ждёт колбэк применения сетевых настроек. **[V]**
- В App Store-сборке системный прокси выставляет туннель, потому что приложению в sandbox это недоступно (`_proxyThroughTunnel`). **[V]**

### 2.5. Модель конфигурации и импорт

- Приложение **не строит sing-box-конфиг**. Оно хранит профиль как файл + набор опций (`SingboxConfigOption`, `lib/singbox/model/singbox_config_option.dart`) и передаёт ядру путь к файлу (`StartRequest.config_path`) и опции (`changeHiddifySettings`). Разбор формата и сборку итогового конфига делает ядро (`parse`, ошибки `ERROR_PARSING_CONFIG` / `ERROR_BUILDING_CONFIG`). Опция `executeConfigAsIs` / `StartRequest.enable_raw_config` — запуск конфига без переработки. **[V]**
- Форматы: sing-box JSON, Clash/Clash.Meta YAML (через `clash2singbox`), Xray JSON и URI-ссылки (через `ray2sing`), подписки base64 — список выведен из зависимостей ядра и README; сам парсер не читался. **[U]** на уровне деталей.
- Deep-link схемы: `hiddify`, `v2ray`, `v2rayn`, `v2rayng`, `clash`, `clashmeta`, `sing-box` (`lib/utils/link_parsers.dart`; форма `hiddify://install-config?url=<uri>#<name>`). **[V]**
- Подписка (`lib/features/profile/data/profile_parser.dart`): **[V]**
  - имя профиля: пользовательское → заголовок `profile-title` → `content-disposition` → фрагмент URL → имя файла → запасное;
  - учитываемые заголовки: `subscription-userinfo`, `profile-update-interval`, `support-url`, `profile-web-page-url`, `ipinfo-url`, `extra-security`, `fragment`, `keep-top`;
  - подписка может **переопределять настройки приложения** (`allowedOverrideConfigs`: `ipv6-mode`, `connection-test-url`, `direct-dns-address`, `remote-dns-address`, `tls-tricks`, `chain-status`, `extra-security`, `keep-top*`, `keep-tags`);
  - `total=0` в `subscription-userinfo` трактуется как безлимит через «магический» порог `infiniteTrafficThreshold` — в комментарии описан баг, когда порог оказался ниже проверки в UI (issue #1974);
  - загрузка идёт через ядро (`fetchUrl`), 2 попытки, повтор только для временных ошибок.
- Типы узлов в UI (`singbox_proxy_type.dart`): SOCKS, HTTP, Shadowsocks, ShadowsocksR, VMess, VLESS, Trojan, Naive, WireGuard, AWG, Hysteria, Hysteria2, TUIC, Tor, SSH, ShadowTLS, Mieru, WARP, Selector, URLTest, Balancer и Xray-варианты с префиксом `x`. **[V]**

### 2.6. Маршрутизация, DNS, автовыбор

- Опции (`SingboxConfigOption`): регион, `ipv6Mode`, раздельные «remote DNS» и «direct DNS» с собственной `DomainStrategy`, `enableFakeDns`, `independentDnsCache`, `resolveDestination`, порты mixed/tproxy/redirect/direct, `tunImplementation` (`sing15`/`mixed`/`system`/`gvisor`), `mtu`, `strictRoute`, `connectionTestUrl`, `urlTestInterval`, `balancerStrategy` (`round-robin`/`consistent-hashing`/`sticky-sessions`), LAN-шаринг с паролем, `tlsTricks` (фрагментация, смешанный регистр SNI, padding). **[V]**
- Правила маршрутизации описаны protobuf-схемой (`protos/v2/config/route_rule.proto`): цель `proxy` / `direct` / `direct_with_fragment` / `block`, сеть `tcp`/`udp`, сниффинг протокола (`tls`, `http`, `quic`, `stun`, `dns`, `bittorrent`); UI — `lib/features/route_rules/`. Раздельное туннелирование по приложениям — `features/app_based_routing` (Android). **[V]**
- Режимы работы (`ServiceMode`): `proxy`, `system-proxy`, `vpn`, `router`. **[V]**
- Автовыбор: группы `urltest`/`balancer`; «keep top» — ядро оставляет работающими только N самых быстрых узлов большой подписки, остальные приостанавливает (значение из пользовательской настройки → заголовка `keep-top` → значения по умолчанию; `-1` — все, `-2` — все ответившие). Логика в ядре (`hiddify-core v2/hcore/keep_top.go`, по комментарию в `lib/features/proxy/keep_top/keep_top.dart`). **[V]** (описание), реализация **[U]**
- «Цепочки» (`features/chain`, `ChainStatus`: `off` / `extra_security` / `unblocker`): узел профиля комбинируется с WARP (`warp`, `warp_awg`, `warp_masque`), Psiphon или другим профилем. **[V]**

### 2.7. Диагностика

- `exportDiagnostics` (`lib/features/crash_report/data/diagnostics_exporter.dart`): zip собирает ядро — crash/OOM-отчёты, stderr, логи, снимки горутин предыдущего запуска, санированный конфиг; чувствительная часть шифруется ключом, вшитым в ядро («only the Hiddify team opens it»), с опцией выгрузки без шифрования для самого пользователя; общий размер держится ниже 4 МБ (лимит gRPC-сообщения). **[V]**
- Отправка — отдельным HTTP-клиентом в Sentry как вложение события, с явной проверкой ответа; работает и при выключенной аналитике (`diagnostics_sender.dart`). Запасные каналы — email/Telegram. **[V]**
- «Trace session»: временное включение уровня trace с автоматическим возвратом, срок хранится в настройках и сообщается ядру, чтобы уровень вернулся даже без приложения (`trace_session_notifier.dart`). **[V]**
- Логи: стрим `logListener` с типами `CORE`/`SERVICE`/`CONFIG`; `getSystemInfoStream` отдаёт память, число горутин, входящие/исходящие соединения, трафик. **[V]**
- Передача файла с устройства без share sheet: одноразовый LAN-HTTP-сервер со случайным портом, случайным секретным путём, проверкой `Host` (защита от DNS rebinding) и обслуживанием только локальных адресов (`lib/features/log/data/lan_file_server.dart`). **[V]**
- Скорость: `uploadTest`/`downloadTest` в ядре (`speedtest-go`); информация об IP узла (`ipinfo`) приходит в `OutboundInfo`. **[V]**
- Расширение пишет собственный журнал старта в файл (`network_extension_error.log` в рабочем каталоге) параллельно с `os.Logger`. **[V]**

### 2.8. Что не открыто и бинарные блобы

- Исходники открыты полностью, включая ядро (`hiddify/hiddify-core`, `hiddify/hiddify-sing-box` доступны публично — проверено `git ls-remote`). **[V]**
- Но: приложение по умолчанию линкуется с **готовыми бинарями** из Releases ядра; воспроизводимость сборки ядра не проверялась. **[U]**
- В git лежит `ios/Frameworks/Libcore.xcframework.zip` — 51,8 МБ, внутри статические библиотеки (ios-arm64: 58,1 МБ; simulator: 111,7 МБ). Судя по заголовку `Mobile.objc.h` в архиве (`MobileSetup(baseDir, workingDir, tempDir, mode, listen, secret, debug, …)`), это устаревший API: текущий Swift-код использует `MobileSetupOptions` и модуль `HiddifyCore`, а `ios/Local Packages/Package.swift` ссылается на `../Frameworks/HiddifyCore.xcframework`. Строка `Libcore` не встречается ни в `ios/Runner.xcodeproj/project.pbxproj`, ни в `ios/Podfile`, ни в `Makefile` (там везде `HiddifyCore.xcframework`). То есть блоб — исторический мусор, не используемый сборкой. **[V]**
- Ключ шифрования диагностики встроен в ядро; расшифровать отчёт может только команда Hiddify. **[V]** (по комментарию)
- Sentry DSN подставляется при сборке (`Environment.sentryDSN`). **[V]**

### 2.9. Лицензия

`LICENSE.md` hiddify-app — «Hiddify Extended GNU General Public License v3»: GPLv3 плюс 7 дополнительных условий «in accordance with GPL v3 Section 7»: **[V]**

1. исходники обязаны быть опубликованы на GitHub **как форк** hiddify-app и поддерживаться актуальными;
2. все релизы — только через GitHub Actions;
3. атрибуция и описание изменений в README;
4. запрет вредоносного кода;
5. запрет публикации в сторах с названием или интерфейсом, похожим на Hiddify;
6. **NonCommercial**: никакого коммерческого использования, включая продажу и рекламу, без письменного согласия;
7. ShareAlike: производные — под той же лицензией и как форк.

У hiddify-core аналогичный текст (`LICENSE.md`: форк с GitHub, запрет оригинального названия/дизайна в сторах, NonCommercial «You can not even include ads in it»). **[V]**

Оценка: условия 1, 2, 6 выходят за перечень допустимых дополнительных условий §7 GPLv3 и по букве GPL являются «further restrictions», которые получатель вправе снять; но опираться на это — значит идти на конфликт с правообладателем, который прямо грозит жалобами в сторы. **[U]** (не юридическое заключение). Решение для нас: код hiddify не копировать и не линковать.

---

## 3. Сравнение

| | Karing | hiddify-app |
|---|---|---|
| UI | Flutter, `provider` + статические менеджеры | Flutter, Riverpod, feature-first |
| Ядро | форк sing-box (`KaringX/sing-box`), версия в коде 1.14.0 | `hiddify-core`: форк sing-box 1.13.0 + xray-core + libXray + Psiphon + WARP + Tor… в одном бинаре |
| Кто строит конфиг ядра | приложение (Dart, код закрыт) | ядро (Go) по файлу профиля + опциям |
| IPC | Clash API ядра (HTTP/WS + secret) + закрытый плагин | gRPC на loopback, mTLS; на iOS два экземпляра ядра |
| iOS-туннель | закрыт (`LibVpnCore`) | открыт, производен от sing-box-for-apple |
| macOS | appex + system extension (код закрыт) | appex (MAS) / system extension (Developer ID) / root-демон (без подписи) |
| tvOS | да, отдельное SwiftUI-приложение, конфиг с телефона по LAN | нет |
| visionOS | нет | нет |
| Импорт | Clash, V2Ray, sing-box, SS, WireGuard (по README; парсеры закрыты) | sing-box, Clash, Xray, URI, подписки (парсеры в ядре) |
| Маршрутизация | группы правил на rule-set + региональные пресеты JSON | protobuf-правила + регион; «цепочки» |
| Диагностика | пошаговый net-check, «какое правило сработает», соединения | шифрованный диагностический zip, trace-сессии, системные метрики ядра |
| Сборка из исходников | невозможна | возможна (ядро — готовые бинари по умолчанию) |
| Лицензия | GPLv3+ и запрет имени | GPLv3 + NonCommercial + обязательный форк |

---

## 4. Что стоит перенять (идеи, не код)

1. **Статус туннеля — от системы, не от движка.** `NEVPNStatus` как источник истины, переживающий перезапуск приложения (hiddify). Наш control plane должен сводить два независимых состояния: «туннель NE» и «движок внутри него».
2. **Сторож «движок умер — туннель снять».** Колбэк остановки ядра → `cancelTunnelWithError` (hiddify, после реального бага с туннелем без ядра). Обязательно для обоих движков.
3. **Конфигурация для холодного старта системой.** Расширение должно уметь стартовать без приложения (On-Demand, тумблер в Настройках). Вариант macOS hiddify — читать из `providerConfiguration` / App Group — чище, чем «последний запрос» в памяти ядра.
4. **On-Demand включать только при connect и снимать при disconnect**, иначе система поднимет туннель после ручной остановки (hiddify `applyOnDemand`).
5. **Сериализовать вызовы движка на выделенной очереди**: Go синхронно ждёт колбэк `setTunnelNetworkSettings` (hiddify macOS `engineQueue`). Для Swift concurrency это означает отдельный actor/executor, а не `MainActor`.
6. **Лимит памяти в расширении включён всегда и не настраивается пользователем**; настройка «отключить лимит» у hiddify осталась рудиментом.
7. **Диагностический пакет одним действием** с санированием конфига, ограничением размера и возможностью посмотреть содержимое до отправки (hiddify). Плюс **временный trace с автоотключением**.
8. **Пошаговая проверка сети** (Karing `net_check`): связность → DNS прямой → DNS через прокси → задержка узла → целевой хост, с понятным пользователю указанием шага, на котором сломалось. И инструмент «какое правило сработает для этого адреса».
9. **Региональные пресеты маршрутизации как данные** (Karing `assets/datas/preset/*.json`), а не как код; rule-set в бинарном формате в бандле + обновляемые.
10. **Заголовки подписки как контракт** (hiddify): `profile-title`, `subscription-userinfo`, `profile-update-interval`, `support-url`, `profile-web-page-url` — де-факто стандарт, поддерживать нужно. Иерархию определения имени профиля стоит повторить.
11. **Выбор User-Agent при загрузке подписки** (Karing): панели отдают разный формат в зависимости от UA; нужен явный, тестируемый параметр.
12. **tvOS как «ведомое» устройство** (Karing): ввод с пульта непригоден, конфигурацию удобнее передавать с телефона. Идея верная, транспорт — нет (см. 5.6).
13. **Три канала доставки macOS** (MAS appex / Developer ID system extension) стоит заложить в схему таргетов и xcconfig сразу; вариант с root-демоном нам не нужен.
14. **Правило из `AGENTS.md` hiddify: «не прятать баг ядра в приложении»** — никаких ретраев и задержек, маскирующих сбой движка. Для адаптеров движков это должно быть архитектурным принципом.
15. **Обратная передача файла через одноразовый LAN-сервер** с секретным путём и проверкой `Host` (hiddify `LanFileServer`) — пример того, как делать 5.6 правильно, если LAN-транспорт всё же нужен.

---

## 5. Чего избегать

1. **Монолитное «всё-в-одном» ядро.** hiddify-core: 58 МБ статической библиотеки на arm64 (по старому блобу в git), десятки `replace` на локальные форки (`sing`, `sing-tun`, `gvisor`, `wireguard-go`…), Xray и sing-box в одном процессе. Это прямой конфликт с бюджетом памяти NE и делает обновление апстрима дорогим. Наш путь — один движок на сессию, апстримные версии, минимум патчей. Фактический резидентный объём памяти не измерялся **[U]**.
2. **Два экземпляра Go-рантайма на iOS** (в приложении и в расширении) ради парсинга и тестов. Разбор профилей, валидация и модель должны жить в Swift; движок — только в расширении.
3. **Сборка конфига внутри движка.** У hiddify приложение не знает итогового конфига — отсюда невозможность показать/проверить его в UI и привязка к одному ядру. У Karing сборка в приложении, но закрыта. Нам нужен открытый, тестируемый компилятор «типизированная модель → конфиг движка» на Swift с отдельным бэкендом под sing-box и Xray.
4. **TCP-сокет на loopback как IPC.** И Clash API, и gRPC слушают `127.0.0.1` — порт доступен любому процессу на устройстве; отсюда secret у Karing и mTLS с файлами сертификатов у hiddify, фиксированные порты (17078/17079/17080) и специальные оговорки про конфликт iOS-on-Mac. На Apple есть `NETunnelProviderSession.sendProviderMessage`, App Group и Darwin-уведомления (а на macOS — XPC); сетевой сокет стоит оставлять только там, где его требует сам движок, и не публиковать наружу.
5. **«Наличие файла = режим безопасности».** У hiddify mTLS включается, если в общем каталоге лежит `client.crt`. Режим защиты должен задаваться явно и проверяться, а не выводиться из побочного состояния файловой системы.
6. **Незащищённый LAN-протокол для tvOS** (Karing): HTTP без шифрования, secret и конфиг в открытом виде, эндпоинты без проверки токена, чтение файла по непроверенному имени. Для нас: iCloud/CloudKit или парный обмен с аутентификацией и шифрованием; любые локальные серверы — только на время сопряжения.
7. **Обходные пути для ревью в продакшен-коде** (зашитый URL у Karing, подменяющий конфиг). Риск удаления из стора и потери доверия.
8. **Настройки приложения, переопределяемые подпиской без явного согласия.** У hiddify подписка может менять DNS, IPv6-режим, TLS-трюки. Допустимо только как «рекомендации провайдера» с видимым пользователю источником и возможностью отказаться.
9. **Магические значения вместо типов** (безлимит как «очень большое число», баг #1974 hiddify). В Swift — `enum Quota { case unlimited, limited(bytes) }`.
10. **Мёртвые и дублирующие пути IPC**: ежесекундный опрос `stats`, который всегда возвращает нули; параметр `DisableMemoryLimit`, который никто не читает; закомментированные обработчики. Каждый канал связи с расширением стоит памяти и батареи.
11. **Утечка соединений к расширению при каждом resume** (исправленный баг hiddify): жизненным циклом клиентских каналов должен владеть один объект.
12. **Тестирование задержек только при поднятом VPN** (Karing). Нужна возможность проверить узел до подключения — и при этом без второго экземпляра движка в приложении (см. п. 2); вероятное решение — кратковременный запуск расширения в режиме «проверка» либо нативный TCP/TLS-пробник на Swift. Требует отдельного исследования **[U]**.
13. **Гигантские экраны и статические синглтоны** (Karing: файлы по 3 тыс. строк, ручные словари колбэков по `hashCode`). Для SwiftUI — `@Observable`-модели по фичам и внедрение зависимостей.
14. **Бинарные блобы и сгенерированный код в git** (51,8 МБ устаревшего xcframework у hiddify; сгенерированные protobuf-файлы вопреки собственным правилам). xcframework — только как артефакт релиза с контрольной суммой (SwiftPM `binaryTarget` с `checksum`), собранный воспроизводимым CI.
15. **Закрытые компоненты в «открытом» проекте** (Karing). Для нас критерий: клон репозитория + документированные шаги = собираемое приложение; всё, что не может быть открыто (ключи, DSN), подставляется конфигурацией, а не отсутствующими исходниками.
16. **Удалённый конфиг, меняющий поведение приложения, реклама провайдеров, удалённый JS** (Karing `RemoteConfig`, `ispPanelJs`). Несовместимо с позиционированием «профессиональная открытая платформа»; телеметрия — только opt-in.
17. **Приватный KVC `packetFlow → socket.fileDescriptor`** используется hiddify (и sing-box-for-apple). Это неизбежная на сегодня зависимость для Go-движков со своим TUN-стеком, но её нужно изолировать в одном месте адаптера и покрыть проверкой на старте с понятной ошибкой. Альтернативы и риски ревью — см. `singbox.md`.

---

## 6. Ограничения по использованию материалов

| Источник | Можно | Нельзя |
|---|---|---|
| Karing (открытая часть) | изучать UI-паттерны, модели настроек, формат пресетов | копировать код (GPLv3+), использовать название; рассчитывать на него как на референс туннеля — его там нет |
| hiddify-app / hiddify-core | изучать архитектуру, gRPC-схему, решения в расширении, сценарии диагностики | копировать или линковать код (GPLv3 + NonCommercial + обязательный форк), повторять интерфейс/название |
| sing-box-for-apple (первоисточник каркаса расширения у обоих) | см. `singbox.md` | — |

Форматы и протоколы совместимости (заголовки подписок, deep-link схемы, структура Clash/sing-box/Xray-конфигов) не являются чьим-то кодом и реализуются заново.

## 7. Что осталось непроверенным

- Реальное потребление памяти расширениями обоих приложений и поведение при превышении лимита — нужен прогон на устройстве. **[U]**
- Внутренности парсеров и сборщика конфига hiddify-core (`ray2sing`, `v2/config`), алгоритм keep-top — исходники ядра не читались. **[U]**
- Реализация `LibVpnCore` и плагина `vpn_service` Karing — недоступна. **[U]**
- Соответствие версий: в приложении Karing зашито `1.14.0`, фактическая версия форка в релизных сборках не проверялась. **[U]**
