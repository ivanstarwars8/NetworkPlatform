# NetworkPlatform

Открытая сетевая платформа (прокси/VPN-клиент) для iOS, iPadOS, macOS, tvOS и visionOS. Движки подключаются как сменные: первый — Xray-core, второй — Mihomo (ADR-0007; sing-box изучен как альтернатива и не интегрируется); профили, маршрутизация, конфигурация и управление туннелем — собственный код на Swift.

Рабочее название. Имя продукта не выбрано; имена движков в нём использоваться не будут (ADR-0006, правило 7).

## Состояние на 2026-11-27

**Phase 1. Рабочего приложения нет.** На раннерах macOS CI код для Apple скомпилирован без подписи; ничего не подписано, не установлено и не запущено на устройствах Apple, туннель не поднимался.

- Мост Xray (`Cores/Bridge`, Go, Xray-core v26.11.9) собран и проверен на Linux: шесть протоколов против штатного xray, трафик через настоящий tun ядра в netns, пропускная способность 90–129 % от штатного xray на стенде Linux. Под детектором гонок падают случаи с VLESS+REALITY+Vision (`TestFlowThroughProxyWithDNS`, на CI также `TestProtocolsOverLoopback/VLESS+REALITY+Vision`) из-за гонки внутри ядра.
- Компилятор модели → Xray JSON проверен настоящим Xray 26.11.9: 53 конфига приняты, 16 из 16 interop-конфигов передали трафик (Xray ↔ Xray, Linux).
- Профиль памяти `mobile` моста Xray: на Linux плато RSS 48–49 МиБ вместо 138–164 при той же скорости (±6 %); ориентир iOS (≤ 45 МиБ при лимите расширения ~50 МиБ) не достигнут, на устройстве не мерилось.
- Swift-пакет из шести модулей (`DomainModels`, `CoreAbstraction`, `ConfigurationEngine`, `RoutingEngine`, `AdaptiveBalancer`, `EngineXray`) — 515 тестов, 0 падений на Linux (Swift 5.10.1) и на macOS CI (Xcode 16.4).
- Приложение и расширение Packet Tunnel (`XrayOnly`) с адаптером `EngineXray` **скомпилированы на macOS CI без подписи** для iOS/iPadOS, симулятора iOS, macOS, tvOS, visionOS; мост — XCFramework из 10 срезов. **Ни разу не запускались**; компилятор ещё не задаёт TUN-inbound, без него старт будет отвергнут. Для запуска нужны аккаунт Apple Developer с Network Extension и устройство.
- Движки — Xray-core и Mihomo (ADR-0007, окончательно). Мост Mihomo (`Cores/MihomoBridge`, Mihomo v1.19.34, тот же C ABI) собран и проверен на Linux против штатного xray; под Apple не собирался, адаптера и компилятора Clash YAML нет.

Подробно, с разделением на «сделано / не проверено / заблокировано»: [`STATUS.md`](STATUS.md).

Этот файл не перечисляет функций продукта: их пока нет. План — в [`ROADMAP.md`](ROADMAP.md).

## Что есть в репозитории

| Путь | Содержимое | Проверено сборкой |
|---|---|---|
| `Package.swift`, `Packages/` | модули `DomainModels`, `CoreAbstraction`, `ConfigurationEngine`, `RoutingEngine`, `AdaptiveBalancer`, `EngineXray` с тестами XCTest | Linux (Swift 5.10.1) и macOS CI (Xcode 16.4): 515 тестов, 0 падений |
| `Cores/Bridge/` | мост Xray на Go с C ABI | Linux — тесты и стенд; Apple — 10 срезов собраны на CI, тест C ABI выполнен на macOS arm64; на iOS/tvOS/visionOS не запускался |
| `Cores/MihomoBridge/` | мост Mihomo на Go с тем же C ABI | Linux — тесты против штатного xray, C ABI; под Apple — только компиляция `GOOS=ios/darwin` на Linux |
| `Extensions/PacketTunnel/` | `NEPacketTunnelProvider`: сетевые настройки, старт и стоп, сообщения приложения, контроль памяти, привязка адаптера `EngineXray` к мосту | скомпилировано на macOS CI без подписи; не запускалось |
| `Apps/` | оболочка приложения на SwiftUI и спецификация XcodeGen для iOS/iPadOS, macOS, tvOS, visionOS | скомпилировано на macOS CI без подписи; не запускалось |
| `Cores/BuildScripts/` | сборка XCFramework моста; скрипты проверки моста на Linux (C ABI, netns, стенд tun) | Linux — да; XCFramework — на macOS CI |
| `Benchmarks/` | замеры моста и маршрутизации, тест паритета с роутером Xray | Linux — да |
| `Tests/Fixtures/`, `Tools/` | корпус ссылок и конфигов, проверка настоящим Xray, обёртки сборки | Linux — да |
| `RESEARCH.md`, `Documentation/Research/` | результаты аудита движков, референс-клиентов и платформ | — |
| `PROTOCOL_MATRIX.md`, `PLATFORM_MATRIX.md`, `COMPETITOR_MATRIX.md`, `LICENSE_AUDIT.md` | матрицы и аудит лицензий | — |
| `TECHNICAL_RISKS.md` | реестр рисков R-01…R-22 | — |
| `Documentation/ADR/` | архитектурные решения 0001–0008, ревью ADR | — |
| `Documentation/Architecture/`, `Documentation/Performance/`, `Documentation/Protocols/` | архитектура, замеры, форматы и справочник Xray | — |
| `Documentation/Security/THREAT_MODEL.md` | модель угроз, первая версия | — |

Исходников движков в репозитории нет: мосты подключают Xray-core и Mihomo как Go-зависимости (`Cores/Bridge/go.mod`, `Cores/MihomoBridge/go.mod`). Собранные библиотеки в git не хранятся.

## Сборка и тесты

Чистые Swift-модули не зависят от движков и от Xcode-проекта:

```sh
swift build
swift test
```

Нужен Swift 5.9 или новее (`// swift-tools-version:5.9` в `Package.swift`); проверено на 5.10.1. Внешних зависимостей у пакета нет.

Те же две команды выполняет CI (`.github/workflows/swift-package.yml`) на macOS и в Linux-контейнере; мосты на Linux проверяют `bridge-go.yml` и `mihomo-bridge-go.yml`, сборку для Apple — `apple.yml`. Все четыре зелёные на 2026-11-27 (`STATUS.md` §2.0).

Приложение и расширение этой командой не собираются: `Cores/BuildScripts/bridge-apple-xcframework.sh`, затем `cd Apps && xcodegen generate`, затем `xcodebuild … -configuration Debug-XrayOnly` — см. [`Documentation/Apple/BUILD_ON_MAC.md`](Documentation/Apple/BUILD_ON_MAC.md). Неподписанная сборка проверена на CI; подписанная и установка на устройство — нет.

## Архитектура в пяти строках

1. Один движок на процесс Packet Tunnel; каждый движок — отдельный артефакт в отдельном расширении (ADR-0001).
2. Приложение не линкует Go: разбор профилей и компиляция конфигурации — на Swift (ADR-0001, ADR-0002).
3. Источник истины — собственная типизированная модель; конфиг движка — результат компиляции с отчётом о потерях (ADR-0002).
4. Swift не разбирает пакеты: для Xray он передаёт их пачками между `NEPacketTunnelFlow` и мостом (ADR-0001 §4.1; ADR-0003 §2 требует правки); приложение и расширение общаются через `sendProviderMessage`, без сетевых сокетов (ADR-0003).
5. Минимальные версии: iOS/iPadOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0; visionOS — экспериментальный уровень (ADR-0005).

Все пять решений приняты по чтению исходников и документации и условны до проверки на Mac (ADR-0001 §7).

## Лицензия

**Лицензия не выбрана. Файла `LICENSE` в репозитории нет намеренно.**

Решение отложено до ответа владельца проекта: варианты, временные правила и вопросы — в [`Documentation/ADR/0006-licence-decision-deferred.md`](Documentation/ADR/0006-licence-decision-deferred.md), основание — в [`LICENSE_AUDIT.md`](LICENSE_AUDIT.md). До решения все права на код сохранены за автором, сторонние изменения не принимаются. ADR-0006 предполагал, что репозиторий не публикуется, но `origin` фактически — публичный репозиторий GitHub; это расхождение ждёт решения владельца (`STATUS.md` §3).

## Документы

- [`STATUS.md`](STATUS.md) — текущее состояние.
- [`ROADMAP.md`](ROADMAP.md) — этапы 0–10 и критерии выхода.
- [`CLAUDE.md`](CLAUDE.md) — постоянный контекст для кодовых агентов.
- [`SECURITY.md`](SECURITY.md), [`PRIVACY.md`](PRIVACY.md), [`CONTRIBUTING.md`](CONTRIBUTING.md), [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), [`CHANGELOG.md`](CHANGELOG.md).
