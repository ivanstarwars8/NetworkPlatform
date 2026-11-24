# PLATFORM_MATRIX — ограничения платформ Apple для NetworkPlatform

Дата проверки: **2026-11-24**. Хост проверки — Linux без Xcode: ничего не собиралось и не запускалось на устройствах; все выводы сделаны по официальной документации Apple и по исходникам референсных проектов.

## 0. Как читать документ

| Метка | Значение |
|---|---|
| **VERIFIED-DOC** | Прочитано в этот день в официальном источнике Apple (JSON документации `developer.apple.com/tutorials/data/documentation/<path>.json`, technote, App Review Guidelines, лицензионное соглашение). |
| **VERIFIED-DOC\*** | Официальная страница Apple, но прочитана через инструмент-суммаризатор (WebFetch), а не сырой текст. Перед юридически значимыми решениями перечитать вручную. |
| **VERIFIED-SRC** | Видно в исходниках референсного проекта (путь указан относительно `/root/.cache/np-research/`, SHA — в `Documentation/Research/SOURCES.txt`). Это доказывает «так делает работающее приложение», а не «так гарантирует Apple». |
| **COMMUNITY** | Наблюдение сообщества или инженера Apple DTS на форуме. Не является документацией и может измениться без объявления. |
| **UNVERIFIED** | Из памяти или вторичного источника, не подтверждено в этой проверке. Не закладывать в архитектуру без проверки на устройстве. |

Основные источники:

- TN3134 «Network Extension provider deployment» (ред. 2025-08-19) — `technotes/tn3134-network-extension-provider-deployment`
- TN3120 «Expected use cases for Network Extension packet tunnel providers» (ред. 2025-07-22)
- TN3179 «Understanding local network privacy»
- TN3111 «iOS Wi-Fi API overview» (ред. 2025-08-29)
- App Review Guidelines, `developer.apple.com/app-store/review/guidelines/`, на странице указано «Last Updated: October 16, 2026»
- Apple Developer Program License Agreement (далее DPLA), `developer.apple.com/support/terms/apple-developer-program-license-agreement/`, в тексте маркер `LYL262`
- Страницы символов NetworkExtension / Network / AppIntents / WidgetKit / ActivityKit / BundleResources (поле `metadata.platforms`)

Важная оговорка про версии: поле `platforms` в документации показывает, с какой версии символ **есть в SDK**. Оно не говорит, работает ли функция на неуправляемом устройстве — это описывает только TN3134.

---

## 1. Сводная матрица возможностей

Обозначения: ✅ доступно обычному пользователю; 🏢 только управляемые (MDM) или supervised-устройства; ❌ нет на платформе; «—» неприменимо.

| Возможность | iOS / iPadOS | macOS, app extension (только Mac App Store) | macOS, system extension (App Store и Developer ID) | tvOS | visionOS |
|---|---|---|---|---|---|
| `NEPacketTunnelProvider` | ✅ с 9.0 | ✅ с 10.11 | ✅ с 10.15 | ✅ с **17.0** | ✅ с 1.0 |
| Per-app VPN (packet tunnel, source-app mode) | 🏢 managed | не указано в TN3134 | не указано в TN3134 | ❌ «not supported» | ❌ в 1.0; 🏢 с 1.1 |
| `NEAppProxyProvider` | 🏢 с 9.0 | ✅ с 10.11 | ✅ с 10.15 | ❌ | 🏢 с 1.1 |
| `NETransparentProxyProvider` | ❌ | ✅ с 10.15 | ✅ с 10.15 (улучшен в 11.0) | ❌ | ❌ |
| `NEDNSProxyProvider` | 🏢 supervised с 11.0; per-app managed с 16.0 | ❌ (только sysext) | ✅ с 10.15 | ❌ | 🏢 per-app 1.1; supervised 2.0 |
| `NEFilterDataProvider` / content filter | 🏢 supervised с 9.0; Screen Time с 15.0; per-app managed с 16.0 | ❌ (только sysext) | ✅ с 10.15 | ❌ | 🏢 1.1 / 2.0 |
| `NEFilterPacketProvider` | ❌ | ❌ | ✅ с 10.15 | ❌ | ❌ |
| `NEURLFilterManager` (URL filter) | ✅ с 26.0 | ✅ с 26.0 | — | ❌ | ❌ |
| `NEDNSSettingsManager` (системный DoH/DoT) | ✅ с 14.0 | ✅ с 11.0 | ✅ | ❌ | ✅ с 1.0 |
| `NERelayManager` | ✅ с 17.0 | ✅ с 14.0 | ✅ | ✅ с 17.0 | ✅ с 1.0 |
| On-demand правила (`NEOnDemandRule*`) | ✅ с 8.0 | ✅ с 10.11 | ✅ | ✅ с 17.0 | ✅ с 1.0 |
| `includeAllNetworks` | ✅ с 14.0 | ✅ с 10.15 | ✅ | ❌ | ✅ с 1.0 |
| `excludeLocalNetworks` | ✅ с 14.2 | ✅ с 10.15 | ✅ | ❌ | ✅ с 1.0 |
| `enforceRoutes` | ✅ с 14.2 | ✅ с 11.0 | ✅ | ✅ с 17.0 | ✅ с 1.0 |
| `excludeAPNs`, `excludeCellularServices` | ✅ с 16.4 | ✅ с 13.3 | ✅ | ❌ | ✅ с 1.0 |
| `excludeDeviceCommunication` | ✅ с 17.4 | ✅ с 14.4 | ✅ | ❌ | ✅ с 1.1 |
| Local Network privacy (запрос доступа) | есть, с 14 | есть, с macOS 15 | есть, с macOS 15 | нет | есть, с 1.0 |
| SSID текущей сети | `NEHotspotNetwork.fetchCurrent` с 14.0 | CoreWLAN `CWInterface.ssid()` | CoreWLAN | ❌ API нет | `fetchCurrent` с 1.0 |
| App Groups | ✅ (`group.*`) | ✅ (`group.*` или `<TeamID>.*`) | ✅ | ✅ с 9.0 | ✅ (см. §8) |
| Keychain access groups | ✅ | ✅ (data protection keychain) | ⚠ см. §8 | ✅ с 9.0 | ✅ с 1.0 |
| Network.framework (`NWConnection` и др.) | ✅ с 12.0 | ✅ с 10.14 | ✅ | ✅ с 12.0 | ✅ с 1.0 |
| App Intents / Shortcuts | ✅ с 16.0 | ✅ с 13.0 | ✅ | ✅ с 16.0 | ✅ |
| WidgetKit | ✅ с 14.0 | ✅ с 11.0 | ✅ | ❌ | ✅ с **26.0** |
| Controls (`ControlWidget`) | ✅ с 18.0 | ✅ с 26.0 | ✅ | ❌ | ❌ |
| Live Activities (`ActivityKit`) | ✅ с 16.1 | 27.3 beta | 27.3 beta | ❌ | ❌ |

Все строки таблицы — **VERIFIED-DOC** (TN3134 для строк о провайдерах и ограничениях развёртывания; `metadata.platforms` страниц символов для остального), кроме помеченных ⚠.

Пояснения к таблице:

- Столбец «macOS, app extension»: по TN3134 packet tunnel, app proxy и transparent proxy в виде app extension имеют ограничение «App Store only». Для распространения по Developer ID остаётся **только system extension**. **VERIFIED-DOC**
- Per-app режим на macOS в TN3134 никак не ограничен в таблицах (пометка про managed стоит только у iOS и visionOS). Это отсутствие ограничения в тексте, а не явное разрешение — проверить на устройстве. `NEAppRule` и `copyAppRules()` на macOS есть с 10.11, на tvOS отсутствуют. **VERIFIED-DOC**
- ActivityKit: в документации на дату проверки у `Activity` указано «macOS 27.3+ beta», tvOS и visionOS в списке платформ нет. **VERIFIED-DOC**
- Mac Catalyst и «iOS Apps on Mac» в TN3134 — отдельные строки (app extension, App Store only). Нам они не нужны: у нас нативная цель macOS.

---

## 2. Packet tunnel: что считается поддерживаемым сценарием (TN3120)

TN3120 — самый важный для архитектуры документ. **VERIFIED-DOC**

Рекомендованные сценарии: доступ к изолированной сети и «full tunnel VPN», отправляющий трафик на удалённый сервер.

Явно **неподдерживаемые** сценарии (дословные формулировки в technote):

1. «Do not use a packet tunnel provider to implement a network content filter» — пакеты из `NEPacketTunnelFlow` не должны отбрасываться или возвращаться в систему.
2. «Do not use a packet tunnel provider to intercept all DNS traffic on the system» — вместо этого `NEDNSProxyProvider` или DNS settings.
3. «Do not use a packet tunnel provider to selectively claim traffic for the packet tunnel and proxy all other traffic elsewhere» — на macOS рекомендуют `NETransparentProxyProvider`.
4. «Do not use a packet tunnel provider to host a network listener or proxy server».

Что это значит для нас:

- Типовая схема всех референсов (TUN → userspace-стек в расширении → правила direct/proxy/reject, локальный SOCKS/HTTP inbound, fake-DNS) попадает сразу под пункты 1–4. При этом sing-box-for-apple, OneXray, Karing и Hiddify используют именно `packet-tunnel-provider` (**VERIFIED-SRC**: `sing-box-for-apple/Extension/Extension.entitlements`, `OneXray/ios/tunnel/tunnel.entitlements`, `karing/ios/karingService/karingService.entitlements`, `hiddify-app/ios/HiddifyPacketTunnel/HiddifyPacketTunnel.entitlements`).
- TN3120 — это позиция поддержки («unsupported», «edge cases and bugs»), а не пункт Review Guidelines. Юридически запрета нет, но рассчитывать на помощь DTS и стабильность поведения между версиями ОС в этих сценариях нельзя.
- Альтернатив для обычных пользователей на iOS/tvOS/visionOS нет: app proxy, DNS proxy и content filter там доступны только на управляемых устройствах (§1). Значит, packet tunnel остаётся единственным вариантом, а риск фиксируется как осознанный.
- На macOS стоит оставить в абстракции место для `NETransparentProxyProvider` (поточный режим, без userspace TCP/IP-стека). Это рекомендованный Apple путь для раздельной маршрутизации.

Жизненный цикл провайдера по документации: система сама запускает расширение, создаёт подкласс провайдера и начинает отдавать пакеты; обязательны `startTunnel(options:completionHandler:)` и `stopTunnel(with:completionHandler:)`; точка расширения `com.apple.networkextension.packet-tunnel`. **VERIFIED-DOC**

При активной VPN-конфигурации соединения идут через VPN, а не через iCloud Private Relay; сами провайдеры Private Relay не используют. **VERIFIED-DOC**

`NWTCPConnection`, `NWUDPSession` и `createTCPConnectionThroughTunnel` помечены deprecated с iOS 18 / macOS 15 / tvOS 18 / visionOS 2 — в новом коде использовать Network.framework. **VERIFIED-DOC**

---

## 3. Лимиты памяти расширения

**Официальной документации с числами нет.** Среди прочитанных страниц (NEPacketTunnelProvider, TN3134, TN3120, NEProvider) лимиты не упоминаются.

| Что | Значение | Статус |
|---|---|---|
| iOS 16.0, packet tunnel | 50 MiB | COMMUNITY: пост Quinn «The Eskimo!» (Apple DTS), форум Apple, тред 73148; прочитано через суммаризатор |
| iOS 16.0, app proxy / DNS proxy | 15 MiB | там же |
| iOS 16.0, filter control / filter data | 50 MiB / 50 MiB | там же |
| iOS 16.0, app push | 24 MiB | там же |
| iOS 26 | «AFAICT the limits are unchanged on iOS 26» (Quinn, октябрь 2025) | COMMUNITY |
| iOS 14 и раньше | 15 MiB для packet tunnel | COMMUNITY (вторичные пересказы) |
| tvOS, visionOS | неизвестно | UNVERIFIED — измерять на устройстве |
| macOS (app и system extension) | жёсткого jetsam-лимита, по сообщениям, нет | UNVERIFIED |

Оговорка самого автора поста: измерено на новом устройстве, на старых лимит может быть ниже; значения менялись и могут меняться; зашивать их в код нельзя.

Как с этим живут референсы (**VERIFIED-SRC**):

- sing-box: `sing-box/service/oomkiller/policy.go` — `DefaultAppleNetworkExtensionMemoryLimit = 50 * 1024 * 1024`, `DefaultAppleNetworkExtensionGCPercent = 50`; применяется в `sing-box/experimental/libbox/setup.go` через `debug.SetMemoryLimit` и `debug.SetGCPercent`.
- sing-box-for-apple: настройка `oomMemoryLimitMB` с умолчанием 50 (`Library/Database/SharedPreferences.swift:61`). В jailbreak-сборке лимит снимается через `memorystatus_control` (`JailbreakDaemon/main.swift`) — то есть лимит реальный и системный.
- libXray: `libXray/memory/memory_ios.go` — `maxMemory = 30 * 1024 * 1024`, `debug.SetGCPercent(10)`, принудительный `debug.FreeOSMemory()` раз в секунду.
- Hiddify: `LibboxSetMemoryLimit(true)` в `hiddify-app/ios/HiddifyPacketTunnel/SingBox/ExtensionProvider.swift:92`.

Следствия для нас:

- Бюджет расширения на iOS считать равным ~50 MiB на всё: Go-рантайм ядра, userspace-стек, Swift-обвязка, логирование, скриптовый движок.
- Два Go-ядра одновременно в одном расширении не помещаются. «Заменяемые движки» означает один движок на сессию туннеля. Два Go-рантайма в одном процессе — отдельный технический риск (**UNVERIFIED**, проверять сборкой).
- JavaScriptCore внутри расширения конкурирует за те же 50 MiB (§10).
- Entitlement `com.apple.developer.kernel.increased-memory-limit` (iOS 15+, visionOS 2.5+) описан для приложений («default app memory limit»). Действует ли он на NE-расширения — **UNVERIFIED**; референсы его не используют.
- Нужна собственная телеметрия `phys_footprint` в расширении и тест на старом устройстве для каждой поддерживаемой версии ОС.

---

## 4. Фоновое поведение и on-demand

- Расширение-провайдер запускается системой и живёт независимо от контейнерного приложения. **VERIFIED-DOC** (обзор packet tunnel provider)
- На macOS app extension работает в контексте пользователя и завершается при выходе из сеанса; system extension работает глобально, независимо от вошедшего пользователя. **VERIFIED-DOC** (TN3134)
- `NEProvider.sleep(completionHandler:)` и `wake()` вызываются при засыпании и пробуждении устройства; есть на всех пяти платформах (tvOS с 17.0). `disconnectOnSleep` тоже доступен везде. **VERIFIED-DOC**
- On-demand: `isOnDemandEnabled`, `onDemandRules`, `NEOnDemandRuleConnect/Disconnect/Ignore/EvaluateConnection`, `ssidMatch`, `interfaceTypeMatch` — iOS 8+, macOS 10.11+, tvOS 17+, visionOS 1+. Правила проверяются по порядку, срабатывает первое совпавшее. **VERIFIED-DOC**
- `ssidMatch` обрабатывает система, поэтому сопоставление по SSID в on-demand **не требует** от приложения права читать SSID. Это логическое следствие из документации, на tvOS проверить на устройстве. **UNVERIFIED**
- Связь приложение ↔ расширение: `sendProviderMessage` / `handleAppMessage` есть на всех платформах. **VERIFIED-DOC**
- `fetchLastDisconnectError` — iOS 16+, macOS 13+, tvOS 17+. **VERIFIED-DOC**
- Контейнерное приложение в фоне подчиняется обычным правилам. Guideline 2.5.4: фоновые сервисы только по назначению. BackgroundTasks есть на iOS 13+, tvOS 13+, visionOS 1+; для macOS в списке платформ фреймворка только Mac Catalyst. **VERIFIED-DOC**
- Сколько живёт расширение после `stopTunnel`, как быстро его убивают при простое, поведение при смене сети — в прочитанной документации не описано. **UNVERIFIED**

---

## 5. Local Network (TN3179)

Всё в разделе — **VERIFIED-DOC**.

- Поддержка: iOS 14, iPadOS 14, macOS 15, visionOS 1. На tvOS и watchOS механизма нет.
- Ключевая фраза: «Network Extension packet tunnel provider, app proxy provider, and DNS proxy provider app extensions have local network access regardless of the Local Network privilege state of their container app».
- Остальные расширения наследуют состояние контейнерного приложения. `NSLocalNetworkUsageDescription` и `NSBonjourServices` добавляются в Info.plist **приложения**, не расширения.
- Исходящий TCP и UDP на локальный адрес требуют разрешения; прослушивание и приём входящих TCP — нет.
- Multicast и broadcast на iOS дополнительно требуют entitlement `com.apple.developer.networking.multicast`, который выдаётся по запросу. На macOS он не нужен.
- macOS: демоны `launchd` и процессы от root получают доступ автоматически. Распространяется ли это на NE system extension — в technote прямо не сказано. **UNVERIFIED**
- Известные ошибки, названные в technote: iOS 18 до 18.6 — рассинхронизация состояния; macOS 15.0 — ряд ошибок, исправлены в 15.1.

Для нас: туннелю разрешение не нужно. Оно понадобится приложению, если оно само ходит в локальную сеть: импорт профиля с соседнего устройства, проверка задержки до локальных узлов, обнаружение по Bonjour. sing-box-for-apple на tvOS импортирует профиль с iPhone (`sing-box/docs/clients/apple/features.md`) и держит entitlement multicast в расширениях (`Extension/Extension.entitlements`, `TVExtension/TVExtension.entitlements`). **VERIFIED-SRC**

---

## 6. Доступ к SSID Wi-Fi

| Платформа | API | Требования | Статус |
|---|---|---|---|
| iOS / iPadOS 14+ | `NEHotspotNetwork.fetchCurrent(completionHandler:)` | Entitlement `com.apple.developer.networking.wifi-info` **и** хотя бы одно из: разрешение на точную геолокацию; сеть настроена через `NEHotspotConfiguration`; **у приложения установлены активные VPN-конфигурации**; активная конфигурация `NEDNSSettingsManager` | VERIFIED-DOC |
| visionOS 1.0+ | тот же API, тот же entitlement | те же условия | VERIFIED-DOC (платформы) |
| macOS | CoreWLAN: `CWWiFiClient.shared().interface()?.ssid()` | На странице API требований не указано. По сообщениям, с macOS 14 нужен доступ к геолокации | UNVERIFIED (требование геолокации) |
| tvOS | — | `NEHotspotNetwork` и entitlement wifi-info в списках платформ отсутствуют | VERIFIED-DOC |

- Для VPN-приложения на iOS условие «active VPN configurations installed» выполняется само, запрашивать геолокацию не нужно. Entitlement wifi-info всё равно обязателен.
- DPLA 3.3.3(G): для Access Wi-Fi Information нужно запросить entitlement у Apple, использовать только для функции, прямо относящейся к приложению. **VERIFIED-DOC**
- Косвенное подтверждение требования геолокации на macOS: sing-box-for-apple держит `com.apple.security.personal-information.location` и `NSLocationWhenInUseUsageDescription` с текстом про «WIFI SSID and BSSID rules» в `SFM/Info.plist` и `SFM.System/Info.plist`, а в варианте system extension читает Wi-Fi через пользовательский помощник (`Library/Network/ExtensionPlatformInterface.swift`, `readWIFIState`, ветка `Variant.useSystemExtension`). На tvOS та же функция возвращает `nil`. **VERIFIED-SRC**
- Вывод: правила по SSID внутри движка возможны на iOS, iPadOS, visionOS и macOS (на macOS — с запросом геолокации и обходным путём для system extension). На tvOS — только системные on-demand правила.

---

## 7. Entitlements

Значения `com.apple.developer.networking.networkextension` (**VERIFIED-DOC**, страница entitlement; доступен на iOS 9+, macOS 10.11+, tvOS 17+, visionOS 1+):

`packet-tunnel-provider`, `app-proxy-provider`, `content-filter-provider`, `dns-proxy`, `dns-settings`, `app-push-provider`, `relay`, `url-filter-provider`, а также варианты для подписи Developer ID: `packet-tunnel-provider-systemextension`, `app-proxy-provider-systemextension`, `content-filter-provider-systemextension`, `dns-proxy-systemextension`.

Для macOS вне Mac App Store: включить capability Network Extension для Developer ID-приложения на сайте разработчика, сгенерировать provisioning profile, включить ручную подпись. **VERIFIED-DOC**

Минимальный набор по целям:

| Цель | Entitlements | Основание |
|---|---|---|
| iOS / iPadOS / visionOS — приложение | `networkextension = [packet-tunnel-provider]`, `com.apple.security.application-groups`, по необходимости `keychain-access-groups`, `com.apple.developer.networking.wifi-info` | VERIFIED-DOC + VERIFIED-SRC (`sing-box-for-apple/SFI/SFI.entitlements`) |
| iOS / iPadOS / visionOS — расширение | `networkextension = [packet-tunnel-provider]`, app group, `wifi-info` (SSID читает расширение) | VERIFIED-SRC (`Extension/Extension.entitlements`) |
| tvOS — приложение и расширение | `networkextension = [packet-tunnel-provider]`, app group | VERIFIED-SRC (`SFT/SFT.entitlements`, `TVExtension/TVExtension.entitlements`, `karing/tvos/karingService/karingService.entitlements`) |
| macOS App Store — приложение и app extension | `packet-tunnel-provider`, `com.apple.security.app-sandbox`, app group, `com.apple.security.network.client`, `com.apple.security.network.server` | VERIFIED-SRC (`SFM/SFM.entitlements`, `OneXray/macos/tunnel/tunnel.entitlements`); песочница обязательна по Guideline 2.4.5(i) |
| macOS Developer ID — приложение | `packet-tunnel-provider-systemextension`, `com.apple.developer.system-extension.install`, app group вида `$(TeamIdentifierPrefix)…` | VERIFIED-SRC (`SFM.System/SFM.entitlements`) |
| macOS Developer ID — system extension | `packet-tunnel-provider-systemextension`, `app-sandbox`, app group; в Info.plist ключ `NEMachServiceName` | VERIFIED-SRC (`SystemExtension/SystemExtension.entitlements`, `SystemExtension/Info.plist`, `OneXray/macos_se/tunnel/Info.plist`) |
| Виджеты, App Intents extension | только app group (плюс песочница на macOS) | VERIFIED-SRC (`WidgetExtension/WidgetExtension.entitlements`, `IntentsExtension/IntentsExtension.entitlements`) |

Дополнительно:

- `com.apple.developer.networking.vpn.api = [allow-vpn]` (Personal VPN) нужен для `NEVPNManager` со встроенными протоколами. Для `NETunnelProviderManager` с собственным провайдером sing-box-for-apple его не использует; OneXray добавляет (`OneXray/macos_se/Runner/Release.entitlements`). Entitlement не заявлен для tvOS. **VERIFIED-DOC / VERIFIED-SRC**
- `com.apple.developer.networking.multicast` — по запросу у Apple; iOS 14+, visionOS 1+. **VERIFIED-DOC**
- System extension: лежит в `Contents/Library/SystemExtensions`, приложение должно находиться в каталоге `Applications`, активация через `OSSystemExtensionRequest` (macOS 10.15+), при удалении приложения расширение удаляется системой. **VERIFIED-DOC**
- Одобрение system extension пользователем в System Settings и обязательная нотаризация для Developer ID — **UNVERIFIED** (в этой проверке не перечитывалось).
- Hiddify для сборки вне App Store отключает песочницу и включает `com.apple.security.cs.allow-jit` (`hiddify-app/macos/Runner/Developer.entitlements`) — пример другого пути, без Network Extension. **VERIFIED-SRC**

---

## 8. App Groups и Keychain

**VERIFIED-DOC** (страницы «App Groups Entitlement», «Configuring app groups», «Sharing access to keychain items among a collection of apps»):

- Формат `group.<name>`, регистрируется в аккаунте разработчика; регистрация обязательна для iOS, iPadOS, tvOS, visionOS, watchOS.
- На macOS дополнительно допустим формат `<Team ID>.<name>` без регистрации; система сверяет Team ID подписи.
- Через группу доступны: общий контейнер (`containerURL(forSecurityApplicationGroupIdentifier:)`, tvOS 9+), общий `UserDefaults(suiteName:)`, IPC — Mach/XPC, POSIX-семафоры и shared memory, UNIX-сокеты (сокет должен лежать в контейнере группы, длина имени ограничена `SOCK_MAXADDRLEN`).
- Группы с префиксом `group.` одновременно работают как keychain access group — отдельный `keychain-access-groups` для них не нужен.
- На macOS общий доступ к элементам связки по access group работает только для data protection keychain (`kSecUseDataProtectionKeychain`, macOS 10.15+) или синхронизируемых элементов.
- Страница «App Groups Entitlement» не перечисляет visionOS в платформах, хотя «Configuring app groups» требует регистрировать группы для visionOS. Расхождение в документации; на практике считать, что группы на visionOS есть. **UNVERIFIED** в части точной версии.

Риски и наблюдения:

- **System extension на macOS** работает вне пользовательского сеанса (TN3134). Доступен ли ему пользовательский data protection keychain и пользовательский контейнер группы — документация не говорит. sing-box-for-apple для этого варианта использует группу `$(TeamIdentifierPrefix)$(BASE_PACKAGE_IDENTIFIER)` и отдельный Mach-сервис. Секреты для system extension лучше передавать через `providerConfiguration` или XPC, а не читать из связки. **UNVERIFIED** — проверить на устройстве.
- **tvOS**: sing-box-for-apple передаёт расширению `commandServerPort` и `commandServerSecret`, то есть общается по TCP с секретом, а не через сокет в контейнере группы (`Library/Network/ExtensionProvider.swift`, блок `#if os(tvOS)`). Причина в коде не объяснена; вероятно, ограничения на хранение и IPC в tvOS. **VERIFIED-SRC** (факт), **UNVERIFIED** (причина).
- Постоянное хранилище на tvOS ограничено (система может очищать локальные данные приложения) — **UNVERIFIED**, проверить перед проектированием хранения профилей.

---

## 9. Network.framework, App Intents, виджеты

Network.framework (**VERIFIED-DOC**, `metadata.platforms`):

| Возможность | iOS / iPadOS | macOS | tvOS | visionOS |
|---|---|---|---|---|
| `NWConnection`, `NWListener`, `NWPathMonitor`, `NWInterface`, `requiredInterfaceType`, `prohibitedInterfaceTypes`, `preferNoProxies`, `allowFastOpen` | 12.0 | 10.14 | 12.0 | 1.0 |
| `NWBrowser`, `NWProtocolWebSocket` | 13.0 | 10.15 | 13.0 | 1.0 |
| `NWConnectionGroup`, `NWParameters.PrivacyContext` | 14.0 | 11.0 | 14.0 | 1.0 |
| `NWProtocolQUIC` | 15.0 | 12.0 | 15.0 | 1.0 |
| `ProxyConfiguration` (relay, Oblivious HTTP, HTTP CONNECT, SOCKSv5) | 17.0 | 14.0 | 17.0 | 1.0 |
| Новый Swift API `NetworkConnection`, `NetworkListener`, `QUIC` | 26.0 | 26.0 | 26.0 | 26.0 |
| `allowUltraConstrainedPaths`, `NWPath.isUltraConstrained` | 26.0 | 26.0 | 26.0 | 26.0 |
| `NWEthernetChannel` | — | 10.15 | — | — |

Практический смысл для нас: Network.framework нужен Swift-слою (наблюдение за путём, привязка исходящих соединений ядра к физическому интерфейсу, проверки связности, локальный IPC). Сам трафик идёт через сокеты Go-ядер. `NWListener` внутри packet tunnel — это «network listener», прямо названный в TN3120 неподдерживаемым сценарием.

App Intents (**VERIFIED-DOC**): `AppIntent` и `AppShortcutsProvider` — iOS 16, macOS 13, tvOS 16, watchOS 9, visionOS (версия в метаданных не указана; у фреймворка — 1.0). `SetValueIntent` — iOS 18, macOS 15, tvOS 18, visionOS 2. `openAppWhenRun` deprecated с версии 26. Guideline 2.5.11: интенты только по заявленной функциональности, без рекламы.

Референс: sing-box-for-apple реализует Start/Stop/Restart/Toggle, GetServiceStatus, GetCurrentProfile, UpdateProfile в отдельном `AppIntentsExtension` (`IntentsExtension/Intents.swift`). **VERIFIED-SRC**

Виджеты и Live Activities (**VERIFIED-DOC**):

- WidgetKit: iOS 14, macOS 11, visionOS 26, watchOS 9. tvOS нет.
- `ControlWidget`: iOS 18, macOS 26, watchOS 26. `ControlConfigurationIntent` — iOS 18, macOS 26.
- ActivityKit: iOS и iPadOS 16.1; `LiveActivityIntent` — iOS 17. macOS 27.3 beta. tvOS и visionOS нет.
- Интерактивные виджеты с кнопками на App Intents с iOS 17 / macOS 14 — **UNVERIFIED** (в этой проверке не перечитывалось).
- Обновлять Live Activity из NE-расширения без push-уведомлений, возможно, нельзя; нужен ли вообще такой сценарий — решить отдельно. **UNVERIFIED**
- Guideline 4.4: расширения не содержат рекламы и покупок; приложение с расширениями должно иметь собственную функциональность.

Референс: `sing-box-for-apple/WidgetExtension/ServiceToggleControl.swift` — переключатель `ControlWidgetToggle`; `OneXray/ios/widget/`. **VERIFIED-SRC**

---

## 10. App Store Review Guidelines и DPLA

### 10.1. Guideline 5.4 «VPN Apps» (VERIFIED-DOC, дословно)

> Apps offering VPN services must utilize the NEVPNManager API and may only be offered by developers enrolled as an organization. You must make a clear declaration of what user data will be collected and how it will be used on an app screen prior to any user action to purchase or otherwise use the service. Apps offering VPN services may not sell, use, or disclose to third parties any data for any purpose, and must commit to this in their privacy policy. VPN apps must not violate local laws, and if you choose to make your VPN app available in a territory that requires a VPN license, you must provide your license information in the App Review Notes field. Parental control, content blocking, and security apps, among others, from approved providers may also use the NEVPNManager API. Apps that do not comply with this guideline will be removed from the App Store and blocked from installing via alternative distribution and you may be removed from the Apple Developer Program.

Следствия:

1. **Аккаунт-организация обязателен.** Индивидуальный аккаунт для VPN-приложения не подходит. Open-source проекту нужно юрлицо и D-U-N-S.
2. Экран раскрытия данных должен показываться **до** любого действия по использованию сервиса. Это первый экран онбординга, а не ссылка в настройках.
3. В политике приватности — прямое обязательство не продавать, не использовать и не передавать данные третьим лицам.
4. Территории с лицензированием VPN: либо лицензия в App Review Notes, либо исключить территорию из доступности. Перечня территорий в guideline нет. Список конкретных стран — **UNVERIFIED**, требует юридической проверки.
5. Санкция распространяется и на альтернативную дистрибуцию.

### 10.2. DPLA 3.3.3(G) «Network Extension Framework» (VERIFIED-DOC)

- Доступ к фреймворку только для приложений, «primarily designed for providing networking capabilities», с entitlement от Apple.
- Обязательно раскрывать, как используется сетевая информация и, если применимо, фильтрация.
- Запрещено «divert an end user's network data or information through any undisclosed, improper, or misleading processes, e.g., to filter it through a website to obtain advertising revenue or spoof a website».
- Данные фреймворка нельзя использовать ни для чего, кроме сетевой функции (реклама, профилирование запрещены).
- Apple может отозвать entitlement в любой момент.

### 10.3. Исполняемый код: Guideline 2.5.2, 4.7 и DPLA 3.3.1(B) (VERIFIED-DOC)

Guideline 2.5.2, дословно:

> Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app, including other apps. Educational apps designed to teach, develop, or allow students to test executable code may, in limited circumstances, download code provided that such code is not used for other purposes. Such apps must make the source code provided by the app completely viewable and editable by the user.

DPLA 3.3.1(B), дословно:

> Except as set forth in the next paragraph, an Application may not download or install executable code. Interpreted code may be downloaded to an Application but only so long as such code: (a) does not change the primary purpose of the Application by providing features or functionality that are inconsistent with the intended and advertised purpose of the Application (b) does not bypass signing, sandbox, or other security features of the OS; and (c) for Applications distributed on the App Store, does not create a store or storefront for other Applications.

Guideline 4.7 разрешает «plug-ins», не встроенные в бинарник, при условиях 4.7.1–4.7.5. Важные: 4.7.2 — нельзя «extend or expose native platform APIs or technologies to the software without prior permission from Apple»; 4.7.3 — не передавать данные и разрешения без явного согласия; 4.7.4 — индекс предлагаемого ПО с universal links.

Смежное: 2.5.1 (только публичные API), 2.5.19 (никаких скрытых и недокументированных функций; обфускация — основание для удаления), 2.3.1(a) (все функции описывать в Notes for Review), 2.5.5 (работа в IPv6-only сетях).

**Что это значит для движка модулей и скриптов:**

| Решение | Оценка |
|---|---|
| Загрузка нативного кода (dylib, Go-плагины, новые версии ядер) | Запрещено 2.5.2 и DPLA 3.3.1(B); технически блокируется подписью кода. Ядра только внутри бандла; обновление ядра = обновление приложения. |
| Пользовательские JavaScript-скрипты (переписывание запросов и ответов, генерация конфигурации) | Допустимо как interpreted code при условиях (a)–(c). Функция должна быть заявлена в описании и в Notes for Review. |
| Декларативные модули (правила, rewrite, наборы хостов) | Данные, а не код. Самый безопасный вариант; делать основным. |
| Встроенный каталог или магазин модулей | Риск по условию (c) «store or storefront» и по 4.7.4. В App Store-сборке — только установка по URL, введённому пользователем, без витрины. |
| API, доступные скриптам | Узкий собственный API (HTTP-объекты, хранилище ключ-значение, уведомления). Не пробрасывать системные API: риск по 4.7.2 и по условию (b). |
| Прозрачность | Исходник скрипта показывать и давать редактировать — по духу 2.5.2; снижает риск претензий по 2.5.19. |
| Автообновление скриптов с удалённого URL | Допустимо как interpreted code, но меняет поведение после ревью. Показывать источник, дату и возможность отключить. Трактовка ревью — **UNVERIFIED**. |

Технически: JavaScriptCore (`JSContext`) есть на iOS, macOS, tvOS 9+, visionOS 1+ (**VERIFIED-DOC**). `WKWebView` на tvOS отсутствует (**VERIFIED-DOC**) — на нём строить движок нельзя. JIT для JavaScriptCore вне WebKit в сторонних приложениях недоступен, скрипты работают в интерпретаторе — **UNVERIFIED**. В расширении скриптовый контекст делит лимит памяти с ядром (§3): создавать его лениво и освобождать после использования.

### 10.4. HTTPS-инспекция (MITM) и корневые сертификаты

В App Review Guidelines нет пункта про корневые сертификаты или MITM: поиск по тексту на «certificate», «root», «proxy» не даёт релевантных совпадений. **VERIFIED-DOC** (отсутствие явного запрета; это не означает разрешения).

Что применимо:

- DPLA 3.3.3(G): раскрытие фильтрации и запрет «spoof a website» / нераскрытого перенаправления. MITM с подменой сертификата формально является подменой сайта для пользователя, поэтому допустим только как явно включённая и объяснённая функция. **VERIFIED-DOC** (текст), трактовка — оценка.
- DPLA 3.3.5(A): «Configuration Profiles cannot be delivered to consumers other than for the purposes of configuration of Wi-Fi, APN, VPN, or MDM settings, or as otherwise expressly permitted by Apple». Профиль с одним только CA-сертификатом в этот список не входит — **серая зона**. **VERIFIED-DOC** (текст). То, что приложения этого класса устанавливают CA через профиль и проходят ревью, — **UNVERIFIED**.
- Guideline 2.4.4: нельзя побуждать пользователя «disable security features». Инструкция по включению доверия к CA может быть истолкована так. Трактовка — **UNVERIFIED**.
- Guideline 5.1.1 и 5.4: содержимое расшифрованного трафика не должно покидать устройство.

Механика доверия:

| Платформа | Как установить доверие | Статус |
|---|---|---|
| iOS, iPadOS, visionOS | Вручную установленный сертификат не доверен для TLS автоматически. Пользователь включает доверие: Settings → General → About → Certificate Trust Settings → «Enable full trust for root certificates». Сертификаты из MDM и Apple Configurator доверены автоматически. | VERIFIED-DOC\* (support.apple.com/102390, «Trust manually installed certificate profiles in iOS, iPadOS, and visionOS») |
| macOS | `SecTrustSettingsSetTrustSettings` (только macOS и Mac Catalyst) либо вручную через Keychain Access. Запрос пароля администратора и ограничения в песочнице — не перечитывались. | VERIFIED-DOC (наличие API), UNVERIFIED (детали) |
| tvOS | `SecTrustSettings*` и `WKWebView` нет. Пользовательский путь установки CA (профиль через настройки) не подтверждён. | UNVERIFIED — считать, что MITM на tvOS **не поддерживается** |

Ограничения, не зависящие от нас: приложения с certificate pinning через MITM не работают; для QUIC/HTTP3 нужен либо отдельный перехват, либо блокировка UDP 443 — **UNVERIFIED**, зависит от движка.

Рекомендации по HTTPS-инспекции:

1. Выключена по умолчанию; включается явно, списком хостов, а не «для всего».
2. CA генерируется на устройстве. Закрытый ключ хранится в связке без синхронизации, в access group, общей для приложения и расширения. Ключ не экспортируется и не одинаков у разных установок.
3. Отдельный экран раскрытия: что расшифровывается, где обрабатывается, как отключить и удалить CA.
4. Модуль собирается под compile-time флагом, чтобы App Store-сборку можно было выпустить без него, если ревью возразит. Для Developer ID-сборки macOS ограничений Review Guidelines нет, но DPLA действует.
5. На tvOS функцию не предлагать.
6. Описать функцию в Notes for Review (2.3.1(a), 2.5.19).

### 10.5. Mac App Store против Developer ID

- Mac App Store: песочница обязательна (2.4.5(i)); упаковка средствами Xcode, один самодостаточный бандл, без сторонних установщиков (2.4.5(ii)). **VERIFIED-DOC**
- NE в виде app extension — только Mac App Store; system extension — оба канала. **VERIFIED-DOC** (TN3134)
- Для Developer ID значения entitlement имеют суффикс `-systemextension`. **VERIFIED-DOC**
- `process_name`, `process_path`, `user`-правила в sing-box доступны «only in the macOS standalone and iOS jailbreak versions» (`sing-box/docs/clients/apple/features.md`). То есть маршрутизация по процессам требует сборки вне App Store. **VERIFIED-SRC**
- sing-box-for-apple поддерживает оба варианта macOS: `SFM` (app extension) и `SFM.System` (system extension). OneXray — каталоги `macos/` и `macos_se/`. **VERIFIED-SRC**

### 10.6. Требования к загрузке в App Store Connect (VERIFIED-DOC\*, developer.apple.com/news/upcoming-requirements)

- С 28.04.2026 загружаемые приложения должны быть собраны Xcode 26 или новее с SDK iOS 26 / iPadOS 26 / tvOS 26 / visionOS 26 / watchOS 26.
- Статус trader обязателен для распространения в ЕС (DSA).
- Это требования к SDK сборки, а не к минимальной версии ОС (deployment target).

---

## 11. Рекомендуемые минимальные версии ОС

Справочно — что выбрали референсы (**VERIFIED-SRC**, `project.pbxproj` и документация):

| Проект | iOS | macOS | tvOS |
|---|---|---|---|
| sing-box-for-apple | 15.0 (часть целей 16.0, одна 18.0) | 13.0 | 17.0 |
| OneXray | 16.0 | 13.0 | — |
| Karing | 15.0 | 12.0 | 17.0 |
| Hiddify | 15.5 | 12.0 | — |

Текущий `Package.swift` репозитория: iOS 16, macOS 13, tvOS 17, visionOS 1.

Доля версий по данным Apple (**VERIFIED-DOC\***, developer.apple.com/support/app-store, замер 07.06.2026): iOS 26 — 79 % всех iPhone и 86 % выпущенных за последние четыре года; iPadOS 26 — 68 % и 79 %. Доли iOS 17 и 18 на странице не приведены.

### Рекомендация

| Платформа | Минимум | Причины |
|---|---|---|
| iOS / iPadOS | **17.0** | Единая базовая линия с tvOS 17 (один набор API без веток); `ProxyConfiguration` в Network.framework (17.0) и `NERelay` (17.0); `LiveActivityIntent` (17.0); `fetchLastDisconnectError` (16.0) и `excludeAPNs` / `excludeCellularServices` (16.4) доступны без проверок; лимит 50 MiB действует с iOS 15, то есть ниже 15 опускаться нельзя в любом случае. `excludeDeviceCommunication` (17.4), Controls (18.0), новый Network API (26.0) — под `#available`. |
| macOS | **14.0** | Пара к iOS 17: `ProxyConfiguration` и `NERelay` (14.0); `excludeAPNs` (13.3) без проверок; `SMAppService` (13.0). `excludeDeviceCommunication` (14.4), local network privacy (15), Controls (26.0) — под `#available`. System extension и transparent proxy доступны давно (10.15 / 11.0). |
| tvOS | **17.0** | Жёсткая нижняя граница: NetworkExtension, `NEPacketTunnelProvider`, on-demand и entitlement появились в tvOS 17.0. Ниже невозможно. |
| visionOS | **1.1** (допустимо 1.0) | Packet tunnel есть с 1.0. В 1.1 появились per-app режим для managed-устройств, app proxy, DNS proxy, `excludeDeviceCommunication`. Если per-app и MDM не нужны — 1.0 достаточно. Виджеты только с 26.0 — под `#available`. |

Альтернатива: оставить iOS 16 / macOS 13, как сейчас в `Package.swift` и как у OneXray. Цена — ветки `#available` для `ProxyConfiguration`, `NERelay`, `LiveActivityIntent`, `excludeAPNs` (16.4 / 13.3) и одна дополнительная мажорная версия в матрице тестирования на каждой платформе. Выигрыш в охвате по данным Apple оценить нельзя: доля iOS 16 не опубликована. Опускаться до iOS 15 / macOS 12, как Karing и sing-box-for-apple, смысла нет: App Intents требуют iOS 16 / macOS 13.

Что в рекомендации **не** проверено:

- Минимальные версии ОС, поддерживаемые тулчейном Go для ядер. В `go.mod`: sing-box — `go 1.25.5`, Xray-core — `go 1.27`, libXray — `go 1.27.3` (**VERIFIED-SRC**). Какую минимальную версию macOS и iOS требует Go 1.27 — **UNVERIFIED**; проверить по release notes Go до фиксации минимумов. Это может поднять минимум macOS.
- Реальные лимиты памяти на tvOS и visionOS (§3).
- Поведение per-app режима на неуправляемом macOS (§1).

---

## 12. Сводка решений и рисков для архитектуры

1. **Единственный универсальный провайдер — `NEPacketTunnelProvider`.** App proxy, DNS proxy, content filter на iOS, tvOS, visionOS недоступны обычным пользователям. Абстракция ядра должна допускать второй бэкенд на macOS (`NETransparentProxyProvider`).
2. **Три варианта упаковки туннеля:** app extension (iOS, iPadOS, tvOS, visionOS, Mac App Store) и system extension (macOS Developer ID, по желанию и App Store). Различия: entitlement с суффиксом, `NEMachServiceName`, формат app group, доступ к связке и SSID.
3. **Per-app VPN для обычных пользователей iOS недоступен** — только managed. Раздельное туннелирование по приложениям в потребительской сборке iOS, tvOS, visionOS невозможно; на macOS — через system extension или transparent proxy.
4. **Бюджет памяти ~50 MiB на iOS — не документирован**, но подтверждён инженером Apple и константами в sing-box. Один движок на сессию, собственный контроль footprint, ограничения на скриптовый движок в расширении.
5. **tvOS — самая урезанная платформа:** нет `includeAllNetworks`, `excludeLocalNetworks`, `excludeAPNs`, per-app, SSID, виджетов, Live Activities, `WKWebView`, `NEDNSSettingsManager`; MITM считать неподдерживаемым. Модель возможностей должна быть декларативной по платформам, а не через `#if` по всему коду.
6. **Guideline 5.4 требует аккаунт-организацию** и экран раскрытия данных до первого использования — организационная предпосылка проекта, не техническая.
7. **Модули — в первую очередь декларативные;** скрипты — только интерпретируемый JavaScript с узким API, видимым исходником и без встроенной витрины.
8. **HTTPS-инспекция — опциональный, отключаемый на этапе сборки модуль** с CA на устройстве; серая зона по DPLA 3.3.5(A) и 3.3.3(G).
9. **TN3120 объявляет неподдерживаемыми** локальные прокси-листенеры, перехват всего DNS и фильтрацию в packet tunnel. Отрасль делает это повсеместно, но это принятый риск: возможны поломки между версиями ОС без помощи DTS.

## 13. Что проверить на устройствах в первую очередь

- Фактический лимит памяти packet tunnel на tvOS 17/18/26, visionOS 1/2/26 и на старом iPhone с минимальной поддерживаемой iOS.
- Доступ system extension на macOS к data protection keychain и контейнеру app group.
- `CWInterface.ssid()` на macOS 14+ без геолокации и с ней; из app extension и из system extension.
- Per-app правила (`NEAppRule`) на неуправляемом macOS.
- Сопоставление on-demand `ssidMatch` на tvOS.
- Установка и доверие пользовательского CA на tvOS.
- Два Go-рантайма (sing-box и Xray) в одном процессе расширения — возможность сборки и потребление памяти.
- Минимальные версии ОС, требуемые Go 1.27 для darwin и ios.
