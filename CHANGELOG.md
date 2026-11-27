# CHANGELOG

Выпусков нет. Версия не присвоена.

Формат: раздел на выпуск, внутри — «Добавлено», «Изменено», «Исправлено», «Удалено». Запись появляется вместе с изменением. Непроверенное сборкой помечается явно.

## Не выпущено

### Добавлено (TestFlight, 2026-11-27)

- `.github/workflows/testflight.yml`: подписанная сборка `Release-XrayOnly` для iPhone/iPad с наложением `Apps/Configurations/Byk.xcconfig` (приложение `com.gbnconnect.app`, расширение `com.gbnconnect.app.tun`, группа `group.com.gbnconnect.app`, имя «Бык»), Xcode 26+, временная связка ключей, загрузка только во внутреннее тестирование TestFlight; `CFBundleVersion = 404 + номер запуска`. `Tools/asc.py` (preflight, профили App Store, ожидание `VALID`, внутренняя группа), `Tools/verify-ipa.sh`, `Tools/make-placeholder-icon.py`, `Documentation/Apple/TESTFLIGHT.md`. Переменные `NP_XRAY_EXTENSION_BUNDLE_ID`, `NP_DISPLAY_NAME`, `NP_APP_PROFILE_SPECIFIER`, `NP_XRAY_EXTENSION_PROFILE_SPECIFIER` в `Base.xcconfig` (умолчания не меняют неподписанные сборки).
- Загружены 0.1.0 (409) — оболочка, прогон 46055561063 — и 0.1.0 (410) — с путём тестировщика, прогон 46060225098; обе `VALID`. Экспортный контроль не отвечен (решение владельца). На устройстве не устанавливались.

### Исправлено (слияние `importui`, 2026-11-27)

- Выбор расширения приложением: `TunnelEngineCatalog` строил идентификатор как `<app>.PacketTunnelXray`, а в сборке Byk расширение — `com.gbnconnect.app.tun`, и Connect указал бы конфигурацию VPN на несуществующий провайдер. Приложение берёт идентификатор из Info.plist (`NPXrayExtensionBundleIdentifier = $(NP_XRAY_EXTENSION_BUNDLE_ID)`), правило суффикса остаётся по умолчанию; `verify-ipa.sh` сверяет его со встроенным расширением; тест `testExplicitExtensionIdentifierWinsOverTheSuffix`. Linux 602/0.

### Добавлено (`importui`, ветка `byk/importui`, слита в `main` 2026-11-27)

- Модуль `ProfileLibrary` (линкуется приложением, адаптеров движков нет): импорт ссылки / адреса подписки / тела подписки с отчётом, хранилище профилей `profiles.json` с секретами в Keychain (`KeychainSecretStore`), компиляция выбранного профиля для packet tunnel под Xray или Mihomo. 12 тестов на Linux.
- Приложение: список профилей с выбором, добавление вставкой, выбор сервера внутри профиля, Connect/Disconnect со статусом, передача скомпилированного конфига расширению файлом в App Group (ADR-0008), экран диагностики (состояние туннеля, отчёт движка, байты вверх/вниз, последняя ошибка с вырезанием значений). Не запускалось на устройстве.

### Добавлено (этап 4, 2026-11-27)

- `stage4/clash`: компилятор Mihomo — `Profile` + `RoutingTable` → Clash YAML с отчётом о потерях (`MihomoConfigCompiler`, `MihomoProxyCompiler`, `MihomoRuleCompiler`, `EngineID.mihomo`); свой `YAMLEmitter`; корпус `*.mihomo.yaml`/`*.mihomo-report.json` и фикстуры `Tests/Fixtures/Routing`; `Tools/validate-fixtures.sh <xray> <mihomo>` прогоняет `mihomo -t` (и на CI); тест моста `TestCompiledFixturesNeedNoOverride`; `npmlab -options`; стенд `ENGINE=mihomo bridge-tunlab.sh` — сервера Trojan+TLS и Hysteria2, `compiled-link`/`compiled DIR` для 4 протоколов. Linux: `mihomo -t` 58/0/7; REALITY+Vision, SS-2022, Trojan, Hysteria2 через мост и tun ядра — 0 провалов из 16 проверок на протокол.
- `stage4/mihomoapple`: `NP_BRIDGE_ENGINE=mihomo Cores/BuildScripts/bridge-apple-xcframework.sh` → `NPMihomoBridge.xcframework` (10 срезов); `bridge-apple-verify.sh` (платформы объектов, закрытые символы); модуль `EngineBridge` (C ABI, `BridgeEngineDriver`, насос, журнал; подделки — `EngineBridgeTestSupport`); адаптер `EngineMihomo`; ADR-0009 — расширение на движок (`PacketTunnelXray_<p>`, `PacketTunnelMihomo_<p>`), приложение на вариант, `TunnelEngineCatalog`; `Tools/apple-build-flavour.sh`. macOS CI: 18 сборок `XrayOnly`/`MihomoOnly`/`Dual` × 5 платформ без подписи, тест C ABI Mihomo на macOS arm64 — PASSED.
- `MihomoCompiledConfiguration` (`EngineMihomo`, зависит от `ConfigurationEngine`): вывод компилятора Mihomo → `CoreConfiguration` (YAML без изменений) + `startOptions` с MTU плана + замечания отчёта как замечания проверки; заблокированная компиляция → `CoreError.invalidConfiguration`, отчёт другого движка → `configurationMismatch`; 4 теста против поддельного моста.

### Изменено (этап 4)

- `ConfigurationEngine` зависит от `RoutingEngine`; `EngineXray` сокращён до кода Xray (общее — в `EngineBridge`); `XrayBridgeBinding.swift` → `BridgeBinding.swift` (одна привязка, условный импорт), `XrayBridgeInfo.swift` → `BridgeInfo.swift`.
- Идентификаторы бандлов расширений: `.PacketTunnelXray`, `.PacketTunnelMihomo`; фаза «Flavour guard» проверяет соответствие цели и конфигурации, а не отсутствие Mihomo.
- `mihomo-apple-patch.sh` заменяет системные вызовы `recvmsg_x`/`sendmsg_x` sing-tun на `ENOSYS`; `mihomo-apple-check.sh` сканирует все исходники, компилируемые под Apple (0 вхождений с правкой, 8 без).
- `Tools/swift-docker.sh` передаёт `NP_UPDATE_FIXTURES`.

### Исправлено (этап 4)

- `Tools/apple-build-flavour.sh`: строки `file` для срезов универсального бинарника («path (for architecture x)») уходили в `grep` как несуществующие пути (шум в журнале, на счёт не влияли); теперь сворачиваются в путь.
- Тест моста Mihomo на скомпилированных фикстурах зависел от IPv6-адреса tun (у раннеров его нет) и оставлял прокси финализатору, который гонялся с `log.SetLevel` следующего теста под `-race`.

### Проверено (этап 4)

- 2026-11-27, `main` после слияния этапа 4: `swift test -j 1` в `swift:5.10` — 589 тестов, 0 падений. Мост Xray: gofmt/vet чисто, `go test ./...` со штатным xray ok. Мост Mihomo: gofmt/vet чисто, `go test ./...` ok, `mihomo -t` корпуса 58/0/7. CI на `67016bd`: apple (8 заданий, 18 сборок, оба моста), swift-package (589/0 на macOS и Linux), bridge-go, mihomo-bridge-go — зелёные (`STATUS.md` §2.0).

### Добавлено (этап 3b, 2026-11-27)

- `stage3b/tunready`: `DomainModels/TunnelAddressing.swift` (`TunnelAddressing`, `TunnelRoute`) — единый источник адресов туннеля, резолверов, MTU и локальных диапазонов; компилятор `XrayCompileOptions.tunnel`/`.packetTunnel(...)` выпускает TUN-inbound `tun-in`, перехват UDP/53 в `dns`-outbound, direct для адресов серверов и локальных сетей, `XrayCompilation.tunnel` (`XrayTunnelPlan`); `TunnelNetworkPlan.excludedRoutes` применяется в `TunnelNetworkSettings`. Сквозной прогон вывода компилятора в мосте (flow, netns, tun ядра): TCP/UDP/DNS/IPv6, 0 утечек DNS, 0 петель (`Benchmarks/results/tunready-2026-11-27/`). Linux + компиляция на macOS CI; на устройстве не запускалось.
- Вырезание значений конфигурации: мост Xray `engine/redact.go` (ошибки разбора/сборки, `core.New`, `Start`, `lastError`, паники; кольцо журнала — кроме IP назначений), Swift `ConfigValueRedactor` для отчётов компилятора; тесты Go и Swift.
- Мост Mihomo: `memory.profile:"mobile"` (40 МиБ, GOGC 25, outQueue 512 КиБ, простой UDP 30 с / TCP 300 с, `tun.maxFlows` 512, очередь журнала 128), опции `tcpIdleTimeoutMs`/`udpIdleTimeoutMs` (обходчик моста `engine/idle.go`), `tun.maxFlows`, счётчики `idleClosedTcp/Udp`, `flowsActive/Highest/Rejected`; стенд `cmd/npmlab` (`ENGINE=mihomo` в `bridge-tunlab.sh`); `memory-budget.md` §10, `Benchmarks/results/mihomo-memory-2026-11-27/`. Linux: 30 мин — RssAnon 24–26 МиБ, RSS ~57 МиБ (цель ~50 не достигнута).

### Изменено (этап 3b)

- Адаптер передаёт мосту Xray только `memory:{"profile":"mobile"}` (при старте и проверке); 32 МиБ / GOGC 50 в `PacketTunnelProvider` удалены.
- `DomainModels` — зависимость приложения, расширения и тестовых целей `CoreAbstraction`/`EngineXray`.
- `Tools/swift-docker.sh` передаёт `NP_EXPORT_*` в контейнер.

### Исправлено (этап 3b)

- `TestSoakRSS` моста Mihomo копил журнал debug штатного xray в буфере без предела (часть прежних 313 МиБ); теперь хранится хвост 256–512 КиБ, профили по `NP_SOAK_PROF`.

### Проверено (этап 3b)

- 2026-11-27, `main` после слияния этапа 3b: `swift test -j 1` в `swift:5.10` — 533 тестов, 0 падений. Мост Xray: gofmt/vet чисто, `go test ./...` со штатным xray ok. Мост Mihomo: gofmt/vet чисто, `go test ./...` со штатным xray ok. CI на `079355a`: apple (8 заданий), swift-package (533/0 на macOS и Linux), bridge-go, mihomo-bridge-go — зелёные (`STATUS.md` §2.0).

### Добавлено (этап 3, 2026-11-27)

- Профиль памяти `mobile`: мост Xray (`memory.profile:"mobile"` заполняет незаданные опции — предел 40 МиБ, GOGC 25, `tun.outQueueBytes` 512 КиБ, `tun.maxFlows` 512, очередь журнала 128; отказ от `assetDir` и geodata), новый `tun.maxFlows` со счётчиками `flowsActive`/`flowsHighest`/`flowsRejected`; компилятор `XrayCompileOptions.memoryProfile` (`.standard`/`.mobile`: `policy.levels.0` connIdle 30, handshake 10, uplinkOnly/downlinkOnly 1, bufferSize 4 КиБ; окна QUIC Hysteria2). Стенд: RssAnon/RssFile, холодный старт, `burst`, `memcmp`, `MOBILE=1`; `Benchmarks/BridgeBench/soak_table.py`, `Benchmarks/results/memory-2026-11-27/`, `Documentation/Performance/memory-budget.md`. Linux: плато RSS 48–49 МиБ против 138–164; цель ≤ 45 МиБ не достигнута; на устройстве не проверено.
- Модуль `EngineXray` (чистый Swift): `XrayBridgeABI`, адаптер `XrayCore` (`NetworkCore`), `PacketPump` (`NEPacketTunnelFlow`↔мост пачками, ограниченная очередь, обратное давление), `XrayLogReader`; 36 тестов против поддельного моста. `Extensions/PacketTunnel/XrayBridgeBinding.swift`; адаптер зарегистрирован в `XrayOnly`. Скомпилировано на macOS CI без подписи; **не запускалось**.
- ADR-0008: передача запроса запуска файлом в App Group; ADR-0003 помечен как частично заменённый.
- Мост Mihomo `Cores/MihomoBridge` (Mihomo v1.19.34, Go 1.27.4): тот же C ABI v1, пакетный путь без fd utun на стеке `mips`, stop через пустую конфигурацию, переписывание опасных ключей; `Cores/BuildScripts/mihomo-linux-cabi-test.sh`, `mihomo-apple-patch.sh`, `mihomo-apple-check.sh`; `Documentation/Architecture/mihomo-config.md` (записка, без кода). Проверено на Linux; под Apple не собиралось.
- CI `.github/workflows/mihomo-bridge-go.yml` (Linux): gofmt, vet, тесты со штатным xray, `-race` с известными гонками ядра Mihomo отдельным шагом, тест C ABI, проверка правки Apple.

### Изменено (этап 3)

- Расширение удаляет устаревшие файлы передачи запроса запуска после чтения (ADR-0008).
- Исправлен комментарий «пакеты не проходят через Swift» в `TunnelNetworkSettings.swift`.
- `Cores/Bridge/README.md`: совет «предел 24–32 МиБ» заменён ссылкой на замер (предел ниже живого набора гоняет GC непрерывно).

### Исправлено (этап 3)

- `TestPrepareConfig` моста Mihomo зависел от наличия IPv6 у хоста (ядро отбрасывает IPv6-адрес tun без глобального IPv6, `verifyIP6`) и падал на раннерах GitHub; теперь ожидание строится по адресам tun и проверяется каждый элемент.

### Проверено (этап 3)

- 2026-11-27, `main` после слияния этапа 3: `swift test -j 1` в `swift:5.10` — 515 тестов, 0 падений. Мост Xray: gofmt/vet чисто, `go test ./...` ok. Мост Mihomo: gofmt/vet чисто, `go test ./...` со штатным xray 26.11.9 ok. `-race` обоих мостов — известные гонки внутри ядер (шаги «KNOWN FAILURE check» на CI). CI на слитом `main`: apple, swift-package (515/0 на macOS и Linux), bridge-go, mihomo-bridge-go — зелёные.

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
