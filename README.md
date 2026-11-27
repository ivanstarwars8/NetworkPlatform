# NetworkPlatform

Открытая сетевая платформа (прокси/VPN-клиент) для iOS, iPadOS, macOS, tvOS и visionOS. Движки подключаются как сменные: первый — Xray-core, второй — Mihomo (ADR-0007; sing-box изучен как альтернатива и не интегрируется); профили, маршрутизация, конфигурация и управление туннелем — собственный код на Swift.

Рабочее название. Имя продукта не выбрано; имена движков в нём использоваться не будут (ADR-0006, правило 7).

## Состояние на 2026-11-27

**Phase 1. Рабочего приложения нет; на устройствах Apple не собиралось и не запускалось ничего.**

- Мост Xray (`Cores/Bridge`, Go, Xray-core v26.11.9) собран и проверен на Linux: шесть протоколов против штатного xray, трафик через настоящий tun ядра в netns, пропускная способность 90–129 % от штатного xray. Под детектором гонок падает один тест из-за гонки внутри ядра (Vision).
- Компилятор модели → Xray JSON проверен настоящим Xray 26.11.9: 53 конфига приняты, 16 из 16 interop-конфигов передали трафик (Xray ↔ Xray, Linux).
- Swift-пакет из пяти модулей (`DomainModels`, `CoreAbstraction`, `ConfigurationEngine`, `RoutingEngine`, `AdaptiveBalancer`) — 477 тестов, 0 падений на Linux (Swift 5.10.1).
- Код расширения Packet Tunnel и приложения **ни разу не компилировался**; туннель на устройстве не поднимался. Для этого нужны Mac с Xcode, аккаунт Apple Developer с Network Extension и устройство.
- Второй движок — Mihomo (ADR-0007, направление до сравнительных замеров); моста Mihomo пока нет.

Подробно, с разделением на «сделано / не проверено / заблокировано»: [`STATUS.md`](STATUS.md).

Этот файл не перечисляет функций продукта: их пока нет. План — в [`ROADMAP.md`](ROADMAP.md).

## Что есть в репозитории

| Путь | Содержимое | Проверено сборкой |
|---|---|---|
| `Package.swift`, `Packages/` | модули `DomainModels`, `CoreAbstraction`, `ConfigurationEngine`, `RoutingEngine`, `AdaptiveBalancer` с тестами XCTest | Linux, Swift 5.10.1: 477 тестов, 0 падений; Apple — нет |
| `Cores/Bridge/` | мост Xray на Go с C ABI | Linux — да; Apple — нет |
| `Extensions/PacketTunnel/` | минимальный `NEPacketTunnelProvider`: сетевые настройки, старт и стоп, сообщения приложения, контроль памяти | нет |
| `Apps/` | оболочка приложения на SwiftUI и спецификация XcodeGen для iOS и macOS | нет |
| `Cores/BuildScripts/` | скрипты проверки моста на Linux (C ABI, netns, стенд tun) | Linux — да |
| `Benchmarks/` | замеры моста и маршрутизации, тест паритета с роутером Xray | Linux — да |
| `Tests/Fixtures/`, `Tools/` | корпус ссылок и конфигов, проверка настоящим Xray, обёртки сборки | Linux — да |
| `RESEARCH.md`, `Documentation/Research/` | результаты аудита движков, референс-клиентов и платформ | — |
| `PROTOCOL_MATRIX.md`, `PLATFORM_MATRIX.md`, `COMPETITOR_MATRIX.md`, `LICENSE_AUDIT.md` | матрицы и аудит лицензий | — |
| `TECHNICAL_RISKS.md` | реестр рисков R-01…R-22 | — |
| `Documentation/ADR/` | архитектурные решения 0001–0007, ревью ADR | — |
| `Documentation/Architecture/`, `Documentation/Performance/`, `Documentation/Protocols/` | архитектура, замеры, форматы и справочник Xray | — |
| `Documentation/Security/THREAT_MODEL.md` | модель угроз, первая версия | — |

Исходников движков в репозитории нет: мост подключает Xray-core как Go-зависимость (`Cores/Bridge/go.mod`). Собранные библиотеки в git не хранятся.

## Сборка и тесты

Чистые Swift-модули не зависят от движков и от Xcode-проекта:

```sh
swift build
swift test
```

Нужен Swift 5.9 или новее (`// swift-tools-version:5.9` в `Package.swift`); проверено на 5.10.1. Внешних зависимостей у пакета нет.

Те же две команды выполняет CI (`.github/workflows/ci.yml`) на macOS и в Linux-контейнере. Workflow написан; успешных запусков не зафиксировано.

Приложение и расширение этой командой не собираются. Для них намечен путь `cd Apps && xcodegen generate` на Mac; он не проверен — см. заголовки файлов в `Apps/` и `Extensions/`.

## Архитектура в пяти строках

1. Один движок на процесс Packet Tunnel; каждый движок — отдельный артефакт в отдельном расширении (ADR-0001).
2. Приложение не линкует Go: разбор профилей и компиляция конфигурации — на Swift (ADR-0001, ADR-0002).
3. Источник истины — собственная типизированная модель; конфиг движка — результат компиляции с отчётом о потерях (ADR-0002).
4. Swift не разбирает пакеты: для Xray он передаёт их пачками между `NEPacketTunnelFlow` и мостом (ADR-0001 §4.1; ADR-0003 §2 требует правки); приложение и расширение общаются через `sendProviderMessage`, без сетевых сокетов (ADR-0003).
5. Минимальные версии: iOS/iPadOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0; visionOS — экспериментальный уровень (ADR-0005).

Все пять решений приняты по чтению исходников и документации и условны до проверки на Mac (ADR-0001 §7).

## Лицензия

**Лицензия не выбрана. Файла `LICENSE` в репозитории нет намеренно.**

Решение отложено до ответа владельца проекта: варианты, временные правила и вопросы — в [`Documentation/ADR/0006-licence-decision-deferred.md`](Documentation/ADR/0006-licence-decision-deferred.md), основание — в [`LICENSE_AUDIT.md`](LICENSE_AUDIT.md). До решения все права на код сохранены за автором, репозиторий не публикуется, сторонние изменения не принимаются.

## Документы

- [`STATUS.md`](STATUS.md) — текущее состояние.
- [`ROADMAP.md`](ROADMAP.md) — этапы 0–10 и критерии выхода.
- [`CLAUDE.md`](CLAUDE.md) — постоянный контекст для кодовых агентов.
- [`SECURITY.md`](SECURITY.md), [`PRIVACY.md`](PRIVACY.md), [`CONTRIBUTING.md`](CONTRIBUTING.md), [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), [`CHANGELOG.md`](CHANGELOG.md).
