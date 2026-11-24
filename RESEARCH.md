# RESEARCH — сводка исследований NetworkPlatform

Дата проверки: **2026-11-24**. Документ сводит пять независимых аудитов и фиксирует, где они расходятся.

Первичные документы:

| Документ | О чём |
|---|---|
| `Documentation/Research/singbox.md` | sing-box, libbox, sing-box-for-apple |
| `Documentation/Research/xray.md` | Xray-core, libXray, OneXray, единый бинарник |
| `Documentation/Research/reference-apps.md` | Karing, hiddify-app |
| `PLATFORM_MATRIX.md` | ограничения платформ Apple, Review Guidelines, DPLA |
| `LICENSE_AUDIT.md`, `COMPETITOR_MATRIX.md` | лицензии и конкуренты |

Производные документы этой сводки: `PROTOCOL_MATRIX.md`, `TECHNICAL_RISKS.md`, `Documentation/ADR/0001…0006`.

## 0. Как читать

- **[V]** — VERIFIED: видно в исходнике (путь указан в первичном документе) либо в официальном документе Apple, прочитанном в день проверки.
- **[U]** — UNVERIFIED: по памяти, по вторичному источнику, либо вывод, не подтверждённый сборкой или запуском.
- **[C]** — COMMUNITY: пост инженера Apple DTS на форуме; не документация.

**Главное ограничение всех пяти аудитов:** на хосте нет Go, Xcode, Swift и устройств. Ничего не собиралось и не запускалось. Всё, что относится к «соберётся ли», «сколько памяти займёт», «пройдёт ли ревью», — [U] до проверки на Mac.

## 1. Источники: версии и SHA

| Репозиторий | SHA | Дата коммита | Версия в исходнике | Лицензия |
|---|---|---|---|---|
| SagerNet/sing-box | `6c65b2e6332769881d0c292718063a3c51d94f93` | 2026-11-24 | ветка `testing`, **1.15.0-alpha.13** (`docs/changelog.md`); `go 1.25.5` | GPL-3.0-or-later + условие об имени |
| SagerNet/sing-box-for-apple | `a4b34aed38f61af85fa37f7e197f659969e4783f` | 2026-11-24 | `MARKETING_VERSION = 1.15.0-alpha.13` | GPL-3.0-or-later |
| sagernet/gomobile (форк) | `4386c41e5b15c25836f4515cc589b3ab4edb75a9` (HEAD) | 2026-11-03 | `go.mod` sing-box: v0.1.12; `make lib_install`: v0.1.13 | BSD-3-Clause |
| XTLS/Xray-core | `e17392a96e1727a5fdb8101ecdd9245dc488fea4` | 2026-11-24 | **26.11.9** (`core/core.go`); `go 1.27` | MPL-2.0 |
| XTLS/libXray | `6e33510350d18a9b906495ff81ae9eb572144ddd` | 2026-11-22 | `go 1.27.3`; закрепляет Xray-core `v1.260327.1-0.20261109052709-676eaf66f8f0` | MIT |
| YuanDevTeam/OneXray | `9ecde06d61f553708035717aca819e545a8ca866` | 2026-11-24 | `26.11.6+1` (`pubspec.yaml`) | GPL-3.0 + исключение для VPN-провайдеров |
| KaringX/karing | `d75fd4ec125e33b04477e23f6df8818c7fe3a350` | 2026-11-19 | `1.2.26+2934`; `kCoreVersion = "1.14.0"` | GPL-3.0-or-later + условие об имени |
| hiddify/hiddify-app | `66c17f83a55233ef4a1c80a4606df811227cc210` | 2026-11-22 | `5.9.15+50915` | «Hiddify Extended GPLv3» (NonCommercial и др.) |
| hiddify/hiddify-core | `b736fe9926bea6680b429e0900f040eed2aeee45` | — | прочитаны только `go.mod`, `Makefile`, `LICENSE.md`, `README.md` | GPLv3 + доп. условия |

Все SHA — из `Documentation/Research/SOURCES.txt` и первичных документов. [V]

Документы Apple, прочитанные 2026-11-24: TN3134 (ред. 2025-08-19), TN3120 (ред. 2025-07-22), TN3179, TN3111 (ред. 2025-08-29), App Review Guidelines («Last Updated: October 16, 2026»), DPLA (маркер `LYL262`), около 165 страниц символов. [V]

Замечания к версиям:

- Аудит sing-box сделан по **альфа-ветке**. Стабильная линия — 1.14.x. Состав протоколов и API libbox в 1.14.x не сверялись. [U]
- HEAD Xray-core (`e17392a`) и коммит, который закрепляет libXray (`676eaf66f8f0`), — разные коммиты. Оба несут версию 26.11.9, но разницу между ними никто не смотрел. [U]

## 2. Ключевые факты

### 2.1. Движки

| Тема | sing-box (libbox) | Xray-core (libXray) |
|---|---|---|
| Сборка под Apple | `gomobile bind` форком SagerNet → `Libbox.xcframework`; цели ios, iossimulator, tvos, tvossimulator, macos [V] | `gomobile bind` (без tvOS) либо `go build -buildmode=c-archive` + xcframework (iOS, macOS, tvOS) [V] |
| Минимальные версии в скриптах сборки | iOS 15.0, macOS 13.0, tvOS 17.0 [V] | c-archive: iOS 15.0, macOS 12.0, tvOS 17.0 [V] |
| visionOS | цели нет [V] | цели нет [V] |
| Go | `go 1.25.5`, CI на 1.26.10 [V] | `go 1.27` / libXray `go 1.27.3` [V] |
| Зависимость от внутренностей Go | 62 `go:linkname`, `-checklinkname=0`, теги `badlinkname`, `tfogo_checklinkname0`, патч `internal/cpu` для iOS/tvOS [V] | 8 `go:linkname` [V] |
| API для хоста | `LibboxSetup` → `LibboxNewCommandServer(handler, platformInterface)` → `startOrReloadService(configJSON, options)`; `PlatformInterface` около 30 методов [V] | одна функция `Invoke(requestJSON) string`, `apiVersion: 3`, 12 методов; C-экспорт `CGoInvoke`/`CGoFree` [V] |
| Статистика и логи | есть: gRPC command server, `StatusMessage`, поток соединений, группы [V] | в API libXray нет; в ядре есть `app/stats`, `app/metrics`, gRPC `StatsService` [V] |
| TUN | fd от хоста через `OpenTun`; Go делает `dup`; свой стек sing-tun; MTU под NE 4064 [V] | свой TUN-inbound `proxy/tun`, fd через `env["xray.tun.fd"]`, `dup`; свой облегчённый стек; MTU по умолчанию 1500 [V] |
| tun2socks | не нужен [V] | не нужен [V] |
| Экземпляров на процесс | один, состояние в пакетных переменных [V] | один: `ErrAlreadyRunning`; диалер и DNS процесс-глобальные [V] |
| Память на iOS | лимит 50 МиБ зашит, GC 50 %, мягкий лимит Go 40 МиБ, oom-killer по memory pressure [V] | libXray: GC 10 %, мягкий лимит 30 МиБ, `FreeOSMemory()` каждую секунду, без отката [V] |
| XHTTP | **нет** (grep по `*.go` пуст) [V] | есть, включая раздельные up/down через `downloadSettings` [V] |
| MITM, скрипты | нет [V] | продуктовой функции нет [V] |

Полная таблица протоколов и транспортов — в `PROTOCOL_MATRIX.md`.

### 2.2. Два Go-ядра

- Два независимо собранных Go-фреймворка в одном процессе недопустимы: прямое предупреждение в README libXray со ссылками на golang/go#18976, #15956 и XTLS/libXray#116. [V — текст; сам отказ не воспроизводился]
- Единый Go-модуль с обоими ядрами в принципе возможен: путей модулей, конфликтующих между форками, не найдено; коллизий собственных `.proto` не найдено. [V]
- Ему мешают три непроверенных условия: sing-box на Go ≥ 1.27.3; sing-box с поднятыми MVS общими модулями (около 20, в том числе grpc 1.79.1 → 1.85.0, go-proxyproto 0.8.1 → 0.16.0); память при двух ядрах, чьи `init()` выполняются всегда. [U]
- Единый бинарник целиком становится GPL-3.0 (MPL §3.3). [V — текст, U — вывод]

### 2.3. Платформы Apple

- `NEPacketTunnelProvider` — единственный провайдер, доступный обычным пользователям на всех пяти платформах: iOS 9.0, macOS 10.11 (app extension) / 10.15 (system extension), tvOS 17.0, visionOS 1.0. [V]
- macOS: app extension — только Mac App Store; Developer ID требует system extension. [V]
- Per-app VPN на iOS, tvOS, visionOS потребителю недоступен. [V]
- TN3120 называет неподдерживаемыми для packet tunnel: фильтрацию контента, перехват всего DNS, выборочный захват трафика, локальный прокси-листенер. Все референсы делают именно это. Это позиция поддержки, не правило ревью. [V]
- Лимит памяти расширения официально не документирован. 50 МиБ для packet tunnel — пост DTS [C] и константы в sing-box [V]. Лимиты tvOS и visionOS неизвестны. [U]
- tvOS — самая урезанная платформа: нет `includeAllNetworks`, `excludeLocalNetworks`, `excludeAPNs`, SSID, WidgetKit, `WKWebView`, `NEDNSSettingsManager`. [V]
- Guideline 5.4: VPN-приложения — только от аккаунта-организации; экран раскрытия данных до первого использования. [V]
- Guideline 2.5.2 и DPLA 3.3.1(B): нативный код не загружается; интерпретируемый — с условиями. Ядра обновляются только вместе с приложением. [V]
- С 2026-04-28 загрузка в App Store Connect требует Xcode 26 и SDK 26 (требование к SDK, не к deployment target). [V — через суммаризатор]

### 2.4. Референс-клиенты

- sing-box-for-apple — единственный нативный Swift-клиент среди открытых; один xcodeproj без SwiftPM; Libbox линкуется в общий `Library.framework`, поэтому Go-рантайм живёт и в приложении. [V]
- OneXray — Flutter, туннель на Swift, ядро как C-архив; три варианта: iOS, macOS sandbox, macOS system extension. [V]
- Karing из публичного репозитория не собирается: 65 Dart-файлов, плагин `vpn_service` и фреймворк `LibVpnCore` отсутствуют. Референсом туннеля не является. [V]
- hiddify — монолитное ядро (форк sing-box + xray-core + ещё шесть компонентов); на iOS два экземпляра ядра; gRPC на loopback. [V]
- Сменных движков нет ни у одного открытого клиента. Нативный visionOS не подтверждён ни у кого. [V]

### 2.5. Лицензии

- sing-box и все библиотеки `sing-*` — GPL-3.0-or-later; ядро нельзя «вычистить» до не-GPL. [V]
- Xray-core — MPL-2.0, libXray — MIT; пометки «Incompatible With Secondary Licenses» нет. [V]
- Ни в одном прочитанном `LICENSE` нет исключения для App Store; CLA и письменных разрешений SagerNet третьим лицам в клонах нет. [V]
- Код hiddify брать нельзя; sing-box-for-apple, OneXray и открытую часть Karing — только под GPLv3; libXray и фрагменты WireGuardKit — можно (MIT). [V — тексты, U — выводы]
- Лицензии около 100 транзитивных Go-модулей каждого ядра не аудировались. [U]

## 3. Расхождения между документами

Расхождения перечислены как есть. Там, где удалось разрешить по исходникам, указано, чем.

| № | Тема | Позиция A | Позиция B | Статус |
|---|---|---|---|---|
| 1 | Два расширения в одном приложении и лицензия | `xray.md` §6.9: два packet-tunnel-расширения в одном приложении, Xray-вариант остаётся без GPL | `LICENSE_AUDIT.md` §5: отдельный процесс внутри одного `.app` — ненадёжная граница; надёжен только отдельный артефакт | **Не разрешено.** Техническая и лицензионная границы не совпадают. ADR-0001 разводит их: изоляция по процессам — техническое решение, «чистота» Xray-линейки — свойство варианта сборки без sing-box |
| 2 | Сколько расширений | `singbox.md` §8: «один движок на процесс расширения, смена = перезапуск туннеля» (подразумевает одно расширение) | `xray.md` §6.9: два расширения, выбор через `providerBundleIdentifier` | Не противоречат по сути, но допустимость двух packet-tunnel-расширений в одном iOS-приложении никто не проверял [U] |
| 3 | VLESS Vision в sing-box | `singbox.md` §1.4: строки `xtls-rprx-vision` в `*.go` нет, поддержка [U] | `COMPETITOR_MATRIX.md`: Hiddify (форк sing-box) заявляет Vision | Частично разрешено дополнительной проверкой: `docs/configuration/outbound/vless.md` перечисляет `xtls-rprx-vision`; `option/vless.go` имеет поле `flow`; `protocol/vless/outbound.go:96` передаёт его в `vless.NewClient` из `sagernet/sing-vmess`. Реализация в зависимости не читалась → в матрице «unverified» |
| 4 | REALITY в sing-box | `xray.md` §6.4: «своя реализация внутри sing-box [U]» | `singbox.md` §1.3: `common/tls/reality_client.go`, `reality_server.go` [V] | Разрешено в пользу `singbox.md` |
| 5 | Стабильная версия sing-box | `singbox.md`: стабильная рядом с альфой — 1.14.4 (`docs/changelog.md`) | `COMPETITOR_MATRIX.md`: в App Store «sing-box MT» версии 1.14.8 | **Не разрешено.** Клон мелкий, тегов нет. Перед закреплением версии сверить по тегам upstream |
| 6 | Минимальные версии ОС | `PLATFORM_MATRIX.md` §11: iOS 17.0, macOS 14.0 | `Package.swift`: iOS 16, macOS 13; движки собираются под iOS 15 / macOS 13 (libbox) и macOS 12 (libXray) | Разрешено решением в ADR-0005. Неизвестным остаётся минимум ОС для Go 1.27 [U] |
| 7 | Лимит памяти | sing-box зашивает 50 МиБ и мягкий лимит 40 МиБ | libXray ставит мягкий лимит 30 МиБ; `xray.md` считает «около 50 МБ» [U]; Apple чисел не публикует | Согласны в том, что официального числа нет. Бюджеты движков разные — см. риск R-03 |
| 8 | macOS App Store | `singbox.md` §4.3: upstream ушёл из Mac App Store из-за «entitlement restrictions» | `reference-apps.md` §2.4 и `xray.md` §4.2: hiddify и OneXray публикуют MAS-вариант с app extension; TN3134 его разрешает | **Не разрешено.** Какой именно entitlement помешал SagerNet — неизвестно [U] |
| 9 | Формат App Group для MAS-сборки macOS | sing-box-for-apple `SFM`: `group.<id>` | OneXray `macos/tunnel`: префикс Team ID | Оба формата допустимы по документации Apple [V]; выбор за нами |
| 10 | Go-рантайм в приложении | sing-box-for-apple вызывает `LibboxCheckConfig` из приложения; hiddify держит второе ядро в приложении | `xray.md` §6.9 и `reference-apps.md` §5.2: приложение не должно линковать Go | Разрешено в ADR-0001 в пользу «без Go в приложении». Цена: проверка конфигурации движком и замер задержки до подключения — открытый вопрос |
| 11 | IPC | `singbox.md` §8.3: повторить три транспорта upstream (unix-сокет, TCP + секрет на tvOS, XPC) либо свой канал на `sendProviderMessage` | `reference-apps.md` §5.4: loopback TCP как IPC — избегать | Разрешено в ADR-0003. Почему upstream на tvOS использует TCP, а не сокет в App Group, — неизвестно [U] |
| 12 | visionOS у референсов | `COMPETITOR_MATRIX.md`: в App Store у sing-box MT и OneXray указано «Apple Vision 1.0+» | `singbox.md` §2: у расширений `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD = NO` | **Не разрешено.** Работает ли туннель на Vision Pro в режиме совместимости — неизвестно [U] |
| 13 | Получение utun fd | sing-box-for-apple и hiddify: сначала приватный KVC `socket.fileDescriptor`, запасной путь — перебор fd | OneXray: только перебор fd 0…1024 | Оба приёма недокументированы; Guideline 2.5.1 требует публичных API. Решение — в ADR-0001 |
| 14 | MTU туннеля | sing-box под NE: 4064 | Xray и OneXray: 1500 | Не конфликт, а параметр адаптера; в общей модели MTU — рекомендация, не константа |
| 15 | Hysteria | sing-box: v1 и v2 | Xray: только `version: 2` | Источник потерь при конвертации — см. ADR-0002 |
| 16 | V2Ray-транспорты `http` (h2) и `quic` | в sing-box есть | в Xray удалены с отсылкой на XHTTP | То же |
| 17 | TN3120 и практика | Apple: локальные листенеры, перехват DNS, раздельная маршрутизация в packet tunnel не поддерживаются | все четыре референса делают это и находятся в App Store | Принятый риск R-10 |
| 18 | Версии приложений | `pubspec.yaml`: OneXray 26.11.6, Karing 1.2.26, Hiddify 5.9.15 | App Store: 26.11.5, 1.2.25, 5.6.0 | Несущественно: репозитории опережают стор |

## 4. Что не проверено никем

Сведено из разделов «не проверено» всех документов. Закрывается только на Mac или устройстве.

1. Любая сборка: libbox, мост Xray, единый бинарник.
2. Размеры XCFramework по срезам и вклад каждого тега.
3. Потребление памяти каждым движком в расширении; фактические лимиты на tvOS, visionOS, старых iPhone.
4. Сборка Go-кода под visionOS и работа packet tunnel там.
5. Два packet-tunnel-расширения в одном iOS-приложении.
6. sing-box на Go 1.27.x и с версиями зависимостей Xray.
7. Минимальные версии ОС, которые требует Go 1.27 для darwin и ios.
8. Доступ system extension на macOS к data protection keychain и контейнеру App Group.
9. SSID через CoreWLAN на macOS с геолокацией и без.
10. `ssidMatch` в on-demand и пользовательский CA на tvOS.
11. Отношение ревью App Store к перебору fd и к KVC.
12. Лицензии транзитивных Go-зависимостей под реальные теги сборки; лицензии geo-данных.
13. Юридическая оценка GPLv3 в App Store для третьих лиц.
14. Отличия API libbox 1.14.x от 1.15-alpha.
15. Способ замера задержки до подключения без второго экземпляра движка.
16. Работа unix-сокета в контейнере App Group на tvOS.

## 5. Принятые решения

| ADR | Решение одной строкой |
|---|---|
| 0001 | Один движок на процесс Packet Tunnel; каждый движок — отдельный артефакт в отдельном расширении; приложение Go не линкует. Единый мост и два фреймворка в одном процессе отклонены |
| 0002 | Собственная типизированная модель конфигурации; компиляторы под движки возвращают конфиг и отчёт о потерях |
| 0003 | Четыре плоскости; пакеты не проходят через Swift; IPC начинается с `sendProviderMessage`, сетевые сокеты наружу не публикуются |
| 0004 | Один корневой `Package.swift`, цели в `Packages/<Name>/{Sources,Tests}`, модуль появляется вместе с кодом |
| 0005 | iOS/iPadOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0; visionOS — экспериментальный уровень |
| 0006 | Лицензия не выбрана; перечислены варианты, временные правила и вопросы владельцу |

Первым движком в вертикальном срезе идёт Xray через собственный C-мост: у него нет GPL, нет зависимости от форка gomobile и есть цель tvOS. Это обратимый выбор порядка работ, а не приоритет движка.
