# CHANGELOG

Выпусков нет. Версия не присвоена.

Формат: раздел на выпуск, внутри — «Добавлено», «Изменено», «Исправлено», «Удалено». Запись появляется вместе с изменением. Непроверенное сборкой помечается явно.

## Не выпущено

### Добавлено (сборка под Apple на CI, 2026-11-27)

- `.github/workflows/swift-package.yml` (macOS + Linux), `bridge-go.yml` (Linux: gofmt, vet, test, `-race` со штатным xray, известный провал Vision отдельным шагом, тест C ABI), `apple.yml` (XCFramework моста, приложение + расширение по платформам без подписи, проверка отказа `MihomoOnly`/`Dual`). Заменяют `ci.yml`.
- `Cores/BuildScripts/bridge-apple-xcframework.sh`: 10 срезов C-архива (iOS, симулятор iOS, macOS, tvOS, симулятор tvOS, visionOS, симулятор visionOS) → `NPXrayBridge.xcframework`. Собрано на CI; на устройствах не запускалось.
- `Apps/project.yml`: цели для iOS/iPadOS, macOS, tvOS, visionOS; конфигурации `{Debug,Release}-{XrayOnly,MihomoOnly,Dual}` через `Apps/Configurations/*.xcconfig`; расширение линкует мост. `XrayBridgeInfo.swift` пишет версию ABI моста в журнал при старте.
- `Documentation/Apple/BUILD_ON_MAC.md`, `Documentation/Apple/DEVICE_TEST_PLAN.md`.

### Исправлено (сборка под Apple)

- `TunnelPendingReply.wait`: `NSLock` брался прямо в async-функции (в режиме Swift 6 это ошибка).
- `TunnelController`: `@preconcurrency import NetworkExtension` (не-Sendable результат `loadAllFromPreferences()`).

### Добавлено (этап 2, 2026-11-25…27)

- Мост Xray `Cores/Bridge` (Go, Xray-core v26.11.9, Go 1.27.4): движок с автоматом состояний, C ABI v1 (`npb_*`), пакетный ввод-вывод, статистика, журнал, параметры памяти; тесты, fuzz, тест ABI из C, режим fd в netns. Проверено на Linux; под Apple не собиралось.
- Стенд на tun ядра Linux (`Cores/Bridge/cmd/nplab`, `Cores/BuildScripts/bridge-tunlab.sh`), сводка `Benchmarks/BridgeBench`, результаты `Benchmarks/results/bridge-2026-11-27/`, `Documentation/Performance/bridge-benchmarks.md`.
- Решение по utun: `Documentation/Architecture/tun-integration.md`, правка ADR-0001 §4.1 и E-5.
- Компилятор модели → Xray JSON с `ConversionReport` (`ConfigurationEngine`); экспорт Hysteria2, VMess, SOCKS; корпус фикстур `Tests/Fixtures/`, проверка настоящим Xray (`Tools/validate-fixtures.sh`, `negative-mutations.py`, `run-interop.sh`); `Documentation/Protocols/share-link-formats.md`.
- `Documentation/Protocols/xray-modern.md` — справочник современных транспортов и расширений Xray-core.
- `RoutingEngine`: семантика роутера Xray, понижение правил, индексы якорей и обязательного литерала; дифференциальный тест `Benchmarks/RoutingParity`; `RoutingBench` и `Documentation/Performance/routing-benchmarks.md`, `Documentation/Architecture/routing-parity.md`.
- Модуль `AdaptiveBalancer` (выбор сервера, транспорта и движка) и `Documentation/Architecture/adaptive-selection.md`.
- `CoreAbstraction`: тайм-ауты, отмена, `shutdown()`, системные события, `CoreDeadline`. `Extensions/PacketTunnel/TunnelSession.swift`, `Shared/TunnelPendingReply.swift`, `Shared/ConfigurationHandoff.swift`, `Apps/SharedApp/Info.plist`; `Documentation/Architecture/control-plane-lifecycle.md`. Код под `Extensions/` и `Apps/` **не компилировался**.
- `Documentation/ADR/REVIEW-2026-11-25.md` — ревью ADR.
- ADR-0007: второй движок — Mihomo. Исследования `Documentation/Research/shoes.md`, `mihomo-leaf.md`, `v2fly-dae-hysteria.md`.

### Изменено

- Протокол IPC приложение↔расширение: версия 1 → 2; запрос запуска передаётся файлом в App Group, в options — ссылка с длиной и SHA-256. Формат снимка — `last-start-request.bin`; старые JSON-снимки игнорируются.
- Импорт: Hysteria2 gecko принимается, `upmbps`/`downmbps` не читаются, проверка ключей SS2022, методы chacha12/8.

### Исправлено

- Корневой `Package.swift` не проходил проверку типов в Swift 5.10: список целей собирается через `+=`; из цели `RoutingBench` исключён `run-all.sh`.
- `CoreLifecycle.submit`: уже отменённый вызывающий мог дойти до движка.

### Проверено

- 2026-11-27, `main` после слияния: `swift test -j 1` в `swift:5.10` (Swift 5.10.1, Linux) — 477 тестов, 0 падений. Go-мост: `go vet`, `gofmt` чисто, `go test ./...` ok; `go test -race ./...` — FAIL в `TestFlowThroughProxyWithDNS` из-за гонки Vision внутри Xray-core.

### Добавлено (Phase 0)

- Исследование Phase 0: `RESEARCH.md`, `Documentation/Research/`, `PROTOCOL_MATRIX.md`, `PLATFORM_MATRIX.md`, `COMPETITOR_MATRIX.md`, `LICENSE_AUDIT.md`, `TECHNICAL_RISKS.md`.
- Архитектурные решения ADR-0001…0006.
- Swift-пакет: модули `DomainModels`, `CoreAbstraction`, `ConfigurationEngine`, `RoutingEngine` с тестами. Первый прогон 2026-11-24: 251 тест, 0 падений (Linux).
- Расширение Packet Tunnel (`Extensions/PacketTunnel/`), оболочка приложения (`Apps/SharedApp/`), спецификация XcodeGen (`Apps/project.yml`). **Не компилировалось.**
- CI: `swift build` и `swift test` на macOS и в Linux-контейнере (`.github/workflows/ci.yml`). **Не запускался.**
- Документы репозитория: `README.md`, `CLAUDE.md`, `AGENTS.md`, `ROADMAP.md`, `STATUS.md`, `SECURITY.md`, `PRIVACY.md`, `CONTRIBUTING.md`, `THIRD_PARTY_NOTICES.md`, `Documentation/Security/THREAT_MODEL.md`, `Cores/BuildScripts/README.md`.
