# STATUS

Дата: **2026-11-27**. Этап: Phase 1, этап 4 — компилятор модели → Mihomo (Clash) YAML (`clash`) и сборка Mihomo под Apple с адаптером `EngineMihomo` (`mihomoapple`), слиты в `main` 2026-11-27 (`67016bd`). Раньше: этап 3 (профиль `mobile`, `EngineXray`, мост Mihomo) и этап 3b (`tunready`, `mihomomem`).

Одной строкой: **оба моста (Xray и Mihomo, один C ABI) работают на Linux**; **компиляторы модели → Xray JSON и → Mihomo YAML** проверены настоящими ядрами (`xray run -test` 53/0/7, `mihomo -t` v1.19.34 58/0/7), их вывод прогнан в мостах на tun ядра Linux против штатного xray 26.11.9 (Mihomo: VLESS+REALITY+Vision, SS-2022, Trojan, Hysteria2 — TCP/UDP/DNS/IPv6, 0 утечек DNS); адаптеры `EngineXray` и `EngineMihomo` на общем `EngineBridge`, вывод компилятора Mihomo передаётся адаптеру (`MihomoCompiledConfiguration`); **Swift-пакет из девяти модулей — 589 тестов, 0 падений на Linux**. На раннере macOS CI **скомпилированы без подписи**: оба моста — по 10 срезов XCFramework (тест C ABI обоих выполнен на macOS arm64), **все 18 сборок `XrayOnly`/`MihomoOnly`/`Dual` × iOS (Debug, Release), iOS Simulator, macOS, tvOS, visionOS** с отдельным расширением на движок (ADR-0009) (§2.0). Память на Linux: профиль `mobile` — мост Xray RSS 48–49 МиБ (цель ≤ 45 не достигнута), мост Mihomo RssAnon 24–26, RSS ~57 МиБ (цель ~50 не достигнута). **Ничего не подписано, не установлено и не запущено на устройстве; туннель не поднимался.** Приложение пока не компилирует профиль и не передаёт его расширению ни для одного движка.

Доказательства разделены по источнику: **Linux** (сервер разработки и контейнер `swift:5.10`) — §2.1–2.8; **macOS CI** (компиляция без подписи, тесты пакета на macOS) — §2.0; **устройство** — ничего (§4).

Статусы:

- **сделано** — существует и проверено тем способом, который для этого вида работы возможен;
- **не проверено** — написано, но не собиралось и не запускалось;
- **заблокировано** — нельзя сделать без ресурса, которого нет.

Решение владельца: **движки проекта — Xray-core и Mihomo** (`Documentation/ADR/0007-second-engine-mihomo.md`, окончательно 2026-11-27; сравнительные замеры движков отменены владельцем). sing-box остаётся изученной альтернативой и не интегрируется. Сборки: `XrayOnly` (без GPL), `MihomoOnly`, `Dual`. Мост Mihomo, компилятор модели → Clash YAML и адаптер `EngineMihomo` есть; `MihomoOnly` и `Dual` компилируются на CI (ADR-0009: расширение на движок, приложение на вариант).

## 1. Что реализовано

| Часть | Где | Состояние |
|---|---|---|
| Мост Xray: Go-модуль, Xray-core v26.11.9 (`676eaf66f8f0`), Go 1.27.4; автомат состояний, C ABI v1 (14 функций `npb_*`), перезагрузка через stop/start с откатом, статистика в процессе, кольцо журнала, параметры памяти, пакетный ввод-вывод | `Cores/Bridge/` | Linux: собран и проверен (§2.2) |
| Профиль памяти `mobile`: мост (`memory.profile:"mobile"` — предел 40 МиБ, GOGC 25, `tun.outQueueBytes` 512 КиБ, новый `tun.maxFlows` 512, очередь журнала 128; отказ от geodata и `assetDir`), компилятор (`XrayCompileOptions.memoryProfile = .mobile`: `policy.levels.0` connIdle 30 с, handshake 10, uplinkOnly/downlinkOnly 1, bufferSize 4 КиБ; окна QUIC Hysteria2 512К/2М/1М/4М); стенд `burst`/`memcmp`/RssAnon | `Cores/Bridge/engine/`, `XrayConfigCompiler.swift`, `Documentation/Performance/memory-budget.md`, `Benchmarks/results/memory-2026-11-27/` | Linux: замерено (§2.5); цель RSS ≤ 45 МиБ не достигнута; на устройстве не проверено |
| Адаптер `EngineXray` (`XrayCore`: `NetworkCore` поверх C ABI моста; насос пакетов `NEPacketTunnelFlow`↔мост пачками с ограниченной очередью и обратным давлением; журнал, статистика, здоровье, нормализация ошибок) | `Packages/EngineXray/`, `Packages/EngineBridge/`, `Extensions/PacketTunnel/BridgeBinding.swift` | Linux: 18 тестов `EngineXray` + 25 `EngineBridge` против поддельного моста (§2.1; общий код вынесен в `EngineBridge` на этапе 4); macOS CI: тесты пакета и компиляция без подписи для 4 платформ (§2.0); на устройстве не запускалось, туннель не поднимался; привязка к настоящему мосту не вызывалась ни разу |
| ADR-0008: запрос запуска передаётся файлом в App Group (фиксирует существующий дизайн; ADR-0003 частично заменён); расширение удаляет устаревшие файлы передачи | `Documentation/ADR/0008-start-request-handoff-via-app-group.md` | документ + правка кода; проверки H-1…H-5 — на устройстве |
| Мост Mihomo: Mihomo v1.19.34 (`0455d0d`), Go 1.27.4, тот же C ABI v1 (14 `npb_*`, проверка формы против моста Xray), пакетный путь без fd utun (свой слушатель на стеке `mips`, входная очередь), stop = пустая конфигурация, переписывание опасных ключей YAML, правка Apple без `proc_pidinfo` через `-modfile` | `Cores/MihomoBridge/`, `Cores/BuildScripts/mihomo-*.sh` | Linux: собран и проверен (§2.6); Apple — XCFramework на macOS CI (§2.0), на устройстве не запускался |
| Готовность туннеля (`tunready`): общий источник адресов туннеля `TunnelAddressing` (198.18.0.1/30, fd66:6e70::1/126, резолверы .2/::2, MTU 1500, локальные диапазоны); компилятор (`XrayCompileOptions.tunnel`/`.packetTunnel`) выпускает TUN-inbound `tun-in`, перехват UDP/53 в `dns`-outbound, direct для адресов серверов и локальных сетей; план `XrayTunnelPlan` → `TunnelNetworkPlan.excludedRoutes` → `TunnelNetworkSettings`; адаптер передаёт только `memory.profile:"mobile"` (32 МиБ/GOGC 50 убраны); вырезание значений конфигурации из ошибок и журнала моста Xray (`engine/redact.go`) и из отчётов компилятора (`ConfigValueRedactor`) | `Packages/DomainModels/Sources/TunnelAddressing.swift`, `Packages/ConfigurationEngine/`, `Extensions/PacketTunnel/`, `Cores/Bridge/engine/redact.go`, `Benchmarks/results/tunready-2026-11-27/` | Linux: тесты + сквозной прогон в мосте (§2.7); macOS CI: компиляция без подписи (§2.0); на устройстве не запускалось, `excludedRoutes` в NE не проверены |
| Память моста Mihomo (`mihomomem`): `memory.profile:"mobile"` (предел 40 МиБ, GOGC 25, outQueue 512 КиБ, inQueue 1 МиБ, простой UDP 30 с / TCP 300 с обходчиком моста `engine/idle.go`, `tun.maxFlows` 512, очередь журнала 128), опции `tcpIdleTimeoutMs`/`udpIdleTimeoutMs`, счётчики `idleClosedTcp/Udp`, `flowsActive/Highest/Rejected`; стенд `cmd/npmlab` (`ENGINE=mihomo` в `bridge-tunlab.sh`) | `Cores/MihomoBridge/`, `Documentation/Performance/memory-budget.md` §10, `Benchmarks/results/mihomo-memory-2026-11-27/` | Linux: замерено (§2.8); цель ~50 МиБ RSS не достигнута; на устройстве не мерилось |
| Решение по utun: основной путь — `NEPacketTunnelFlow` пачками (`tun.mode="flow"`), режим fd — по выбору | `Documentation/Architecture/tun-integration.md`, ADR-0001 §4.1 | проверено на Linux; на Apple — нет |
| Стенд на tun ядра Linux (`nplab`, `bridge-tunlab.sh`), сводка замеров | `Cores/Bridge/cmd/nplab`, `Cores/BuildScripts/`, `Benchmarks/BridgeBench`, `Benchmarks/results/bridge-2026-11-27/` | прогнан потоком bridge |
| Компилятор модели → Xray JSON с `ConversionReport` | `Packages/ConfigurationEngine/Sources/Xray*.swift`, `ConversionReport.swift` | сделано (Linux + Xray 26.11.9) |
| Компилятор модели → Clash YAML (Mihomo) с `ConversionReport`: прокси VLESS/VMess/Trojan/SS (+obfs, v2ray-plugin)/SOCKS5/HTTP/Hysteria2/TUIC/WireGuard, транспорты ws/httpupgrade/grpc/h2/http/xhttp; группы 1:1 (select/url-test/fallback/load-balance, вложенные); правила из `RuleLowering` (непереводимое блокирует); DNS redir-host через выбранный маршрут, fake-ip выключен; tun `mips` из `TunnelAddressing`; свой `YAMLEmitter`; корпус `*.mihomo.yaml` + `Tests/Fixtures/Routing` | `Packages/ConfigurationEngine/Sources/Mihomo*.swift`, `YAMLEmitter.swift`, `Documentation/Architecture/mihomo-config.md`, `Benchmarks/results/mihomo-compiled-2026-11-27/` | Linux: `mihomo -t` 58/0/7; мост Mihomo (flow + tun ядра) против xray 26.11.9 — REALITY+Vision, SS-2022, Trojan, Hysteria2: TCP/UDP/DNS/IPv6, 0 утечек DNS (§2.9); на Apple не запускалось |
| Адаптер `EngineMihomo` (`MihomoCore`: YAML/JSON, без режима fd, `overridden` моста → предупреждения проверки, статистика total/connections) и `MihomoCompiledConfiguration` (вывод компилятора → `CoreConfiguration` + MTU + план туннеля + замечания отчёта; заблокированная компиляция до моста не доходит); общий модуль `EngineBridge` (C ABI, `BridgeEngineDriver`, насос, журнал) | `Packages/EngineMihomo/`, `Packages/EngineBridge/`, `Extensions/PacketTunnel/BridgeBinding.swift` | Linux: 14 тестов `EngineMihomo` против поддельного моста (§2.1); macOS CI: компиляция в расширениях `PacketTunnelMihomo_<p>` (§2.0); на устройстве не запускалось; приложение профиль ещё не компилирует |
| Мост Mihomo под Apple: `NP_BRIDGE_ENGINE=mihomo bridge-apple-xcframework.sh` → `NPMihomoBridge.xcframework` (10 срезов); правка Apple без `proc_pidinfo` и без системных вызовов `recvmsg_x`/`sendmsg_x` sing-tun (по номеру, `nm` их не видит); `mihomo-apple-check.sh` сканирует все исходники, компилируемые под Apple; `bridge-apple-verify.sh` — платформы объектов и закрытые символы обоих мостов | `Cores/BuildScripts/`, `Cores/MihomoBridge/apple/` | macOS CI: собран, проверка PASSED, тест C ABI PASSED на macOS arm64 (§2.0); на устройстве не запускался |
| ADR-0009: расширение на движок (`PacketTunnelXray_<p>`, `PacketTunnelMihomo_<p>`), приложение на вариант (`AppXrayOnly/AppMihomoOnly/AppDual_<p>`), выбор расширения через `TunnelEngineCatalog` + `providerBundleIdentifier`; отступление от ADR-0004 «без дублирования целей» | `Documentation/ADR/0009-*.md`, `Apps/project.yml`, `Tools/apple-build-flavour.sh`, `Extensions/PacketTunnel/Shared/TunnelEngineCatalog.swift` | 18 сборок скомпилированы на CI без подписи с проверками продукта (§2.0); переписывание `providerBundleIdentifier` системой — проверка E-3 на устройстве |
| Минимальный путь тестировщика (`importui`, ветка `byk/importui`): модуль `ProfileLibrary` — `ImportInput`/`ProfileImporter` (ссылка, адрес подписки, тело подписки plain/base64 через `ShareLinkImporter`/`SubscriptionDecoder`; замечания `ImportReport` без значений; уникальные теги), `ProfileStore` (`profiles.json` без секретов, секреты — в `SecretStore`, на Apple `KeychainSecretStore`), `TunnelStartCompiler` (Xray JSON / Mihomo YAML с опциями packet tunnel, секреты в конфиге inline); приложение — `ProfileLibraryModel` (загрузка подписки эфемерной сессией), список/импорт/детали профиля, Connect → `TunnelStartRequest(compiled:)` → `ConfigurationHandoff` (ADR-0008), экран диагностики (`NEVPNStatus`, отчёт движка, байты вверх/вниз через `.statistics`, `fetchLastDisconnectError`, вырезание `ConfigValueRedactor`) | `Packages/ProfileLibrary/`, `Apps/SharedApp/{ContentView,DiagnosticsView,ProfileLibraryModel,TunnelStartRequest+Compiled,TunnelController}.swift` | Linux: 12 тестов `ProfileLibraryTests` (импорт → хранилище → компиляция → файл передачи → чтение расширением), весь пакет 601/0; CI на ветке (`45eb116`): swift-package 46056045371 (macOS + Linux) и apple 46055850203 (оба моста, 18 сборок `XrayOnly`/`MihomoOnly`/`Dual` × iOS Debug/Release, Simulator, macOS, tvOS, visionOS без подписи, проверки продукта) — зелёные; **не запускалось**: Keychain, загрузка подписки, UI и туннель не проверены на устройстве |
| Форматы ссылок сверены с источниками; исправления импорта и экспорта | `Documentation/Protocols/share-link-formats.md`, `LinkParsers.swift`, `ShareLinkExporter.swift` | сделано |
| Корпус фикстур (39 ссылок, 16 interop, 5 профилей), проверка настоящим Xray | `Tests/Fixtures/`, `Tools/validate-fixtures.sh` | сделано |
| `RoutingEngine`: семантика выровнена с роутером Xray, понижение правил, индексы «якорей» и обязательного литерала регулярки | `Packages/RoutingEngine/`, `Documentation/Architecture/routing-parity.md` | сделано (Linux); управляющий слой, не путь данных |
| `RoutingBench` (release, 1k–1M правил) | `Benchmarks/RoutingBench/`, `Documentation/Performance/routing-benchmarks.md` | сделано (Linux) |
| `AdaptiveBalancer`: оценка качества, 7 стратегий, три уровня сервер/транспорт/движок, гистерезис, автомат защиты, цена смены движка, Wi-Fi/сотовая, испытательный срок и откат, объяснение решений | `Packages/AdaptiveBalancer/`, `Documentation/Architecture/adaptive-selection.md` | сделано (Linux); ни к чему не подключён |
| `CoreAbstraction`: тайм-ауты, отмена, `shutdown()`, системные события (сон/пробуждение/память), `CoreDeadline` | `Packages/CoreAbstraction/` | сделано (Linux) |
| `TunnelSession` (порядок старта, откат, стоп во время старта), типизированные ошибки IPC, ответ с дедлайном, передача конфигурации файлом в App Group (протокол IPC v2) | `Extensions/PacketTunnel/TunnelSession.swift`, `Extensions/PacketTunnel/Shared/` | логика проверена тестами `CoreAbstraction` (символические ссылки) на Linux и на macOS CI; в составе расширения скомпилировано на macOS CI без подписи; на устройстве не запускалось |
| Расширение, приложение, `project.yml` переписаны вокруг сессии (дедлайны, сон/пробуждение, давление памяти, App Group по платформам) | `Extensions/PacketTunnel/`, `Apps/` | скомпилировано на macOS CI без подписи для iOS/iPadOS, macOS, tvOS, visionOS (§2.0); **никогда не запускалось** |
| CI: Swift-пакет (macOS + Linux), мост Xray (Linux: vet/test/race/C ABI), мост Mihomo (Linux: vet/test/race с известными гонками ядра/C ABI/правка Apple/`mihomo -t` корпуса), Apple (XCFramework обоих мостов с проверкой, 18 сборок вариант × платформа с проверками продукта) | `.github/workflows/{swift-package,bridge-go,mihomo-bridge-go,apple}.yml` | работает, все задания зелёные (§2.0) |
| XcodeGen-проект: 4 платформы × приложения по вариантам + расширения по движкам, конфигурации `{Debug,Release}-{XrayOnly,MihomoOnly,Dual}` через xcconfig; расширение Xray линкует `NPXrayBridge.xcframework` + `EngineXray`, расширение Mihomo — `NPMihomoBridge.xcframework` + `EngineMihomo`; каждое регистрирует только свой движок и пишет в журнал версию ABI моста | `Apps/project.yml`, `Apps/Configurations/`, `Extensions/PacketTunnel/BridgeInfo.swift` | скомпилировано на CI (§2.0); старт не проверялся |
| Инструкции для Mac и план проверки на iPhone | `Documentation/Apple/BUILD_ON_MAC.md`, `DEVICE_TEST_PLAN.md` | документ; подписанная сборка и шаги на устройстве не выполнялись |
| Справочник современных транспортов Xray (ключи JSON, минимальные версии, HEAD против v26.11.9, покрытие `DomainModels`) | `Documentation/Protocols/xray-modern.md` | документ, по чтению исходников |
| Аудиты движков-кандидатов: shoes, mihomo, leaf, v2ray-core, dae, hysteria | `Documentation/Research/{shoes,mihomo-leaf,v2fly-dae-hysteria}.md`, `SOURCES-cores2.txt` | документ, по чтению исходников |
| Ревью ADR (30 замечаний) | `Documentation/ADR/REVIEW-2026-11-25.md` | документ |

Документы Phase 0 (аудиты, матрицы, ADR-0001…0006, модель угроз) — без изменений, кроме ADR-0001 §4.1/E-5 (решение по utun) и строки «частично заменён» в ADR-0003 (ADR-0008).

## 2. Что реально запускалось

### 2.0. Apple — сборка на CI (GitHub Actions, macOS 15, Xcode 16.4, 2026-11-27)

**Этап 4, слитый `main` (коммит `67016bd`, 2026-11-27; push, все четыре workflow запущены изменениями путей), все четыре зелёные:**

- `apple.yml` ([прогон](../../actions/runs/46049957457)): XCFramework обоих мостов (по 10 срезов, `bridge-apple-verify.sh` — PASSED; у Mihomo 0 `proc_pidinfo`/`recvmsg_x`/`sendmsg_x`; тест C ABI на macOS arm64 — PASSED); **18 сборок без подписи** — `XrayOnly`, `MihomoOnly`, `Dual` × iOS (Debug и Release), iOS Simulator, macOS, tvOS, visionOS — с проверками продукта `Tools/apple-build-flavour.sh` (встроены ровно расширения варианта; в расширении символы `npb_*`, своё ядро и адаптер и нет чужого; в приложении нет `npb_*`, Go и адаптеров; minos 17.0/14.0/17.0/1.0). Тест C ABI моста Xray на macOS arm64 — PASSED. Расширения iOS Release: Xray 34 МБ, Mihomo 50 МБ (было 48 в потоке mihomoapple: +2 МБ — `ConfigurationEngine` и `RoutingEngine`, которые теперь тянет `EngineMihomo`); приложение 1,6 МБ. Предупреждений в исходниках `Apps/`, `Extensions/`, `Packages/` — 0.
- `swift-package.yml` ([прогон](../../actions/runs/46049957459)): **589 тестов, 0 падений на macOS** (Xcode 16.4) и 589/0 на Linux-раннере (не Apple).
- `bridge-go.yml` ([прогон](../../actions/runs/46049957494)): gofmt, vet, тесты, `-race` остальных тестов — ok; C ABI — PASSED; «KNOWN FAILURE check»: `TestFlowThroughProxyWithDNS` — 2 отчёта, `TestProtocolsOverLoopback/VLESS+REALITY+Vision` — 2, все в Vision ядра Xray, кадров моста нет.
- `mihomo-bridge-go.yml` ([прогон](../../actions/runs/46049957528)): gofmt, vet, `xray run -test` корпуса 53/0/7 и `mihomo -t` 58/0/7, тесты со штатным xray, `-race` остальных — ok; C ABI — PASSED (40 Б: 153 нс/пакет при пачке 1, 59,8 нс при 64); правка Apple — PASSED; «KNOWN FAILURE check»: Vision — 5 отчётов, `TestStartStopCycles` — 2, все доступы в ядре Mihomo.

После правки `Tools/apple-build-flavour.sh` (срезы универсальных бинарников больше не идут в `grep` несуществующими путями) `apple.yml` повторён на `be08fe5` ([прогон](../../actions/runs/46051997698)) — все 8 заданий зелёные, 18 сборок, ошибок «No such file» в журнале 0 (было на `67016bd`), проверки продукта дали те же нули.

Потоки до слияния: clash — [swift-package](../../actions/runs/46043134367) 566/0 на macOS и Linux, [mihomo-bridge-go](../../actions/runs/46044123601) (с `mihomo -t` корпуса), [apple](../../actions/runs/46043143475); mihomoapple на `9ff6f90` — [apple](../../actions/runs/46047059128), [swift-package](../../actions/runs/46047063077) 552/0, [mihomo-bridge-go](../../actions/runs/46047066984), [bridge-go](../../actions/runs/46047071052); первая успешная сборка всех вариантов — [apple](../../actions/runs/46045764184). Размеры расширений iOS Release (поток mihomoapple): Xray 34 МБ, Mihomo 48 МБ; срезы C-архива Mihomo — 55–57 МБ. Тест C ABI моста Mihomo на macOS arm64: 167 нс на вызов при пачке 1, 111 нс/пакет при пачке 64.

**Этап 3b, слитый `main` (коммит `079355a`, 2026-11-27; push, workflow запущены изменениями путей), все четыре workflow зелёные:**

- `apple.yml` ([прогон](../../actions/runs/46037216559)): все 8 заданий — XCFramework моста Xray; `XrayOnly` без подписи для iOS (Debug и Release), iOS Simulator, macOS, tvOS, visionOS; отказ `MihomoOnly`/`Dual` фазой «Flavour guard» — как задумано. Предупреждений в исходниках `Apps/`, `Extensions/`, `Packages/` — 0 (есть только предупреждение настроек проекта об ориентациях экрана iOS).
- `swift-package.yml` ([прогон](../../actions/runs/46037216583)): **533 теста, 0 падений на macOS** (Xcode 16.4) и 533/0 на Linux-раннере (не Apple).
- `bridge-go.yml` ([прогон](../../actions/runs/46037216330)): gofmt, vet, тесты, `-race` остальных тестов — ok; C ABI — PASSED; «KNOWN FAILURE check»: `TestFlowThroughProxyWithDNS` — 2 отчёта, `TestProtocolsOverLoopback/VLESS+REALITY+Vision` — 3, все в Vision ядра, кадров моста нет.
- `mihomo-bridge-go.yml` ([прогон](../../actions/runs/46037216432)): gofmt, vet, тесты со штатным xray, `-race` остальных — ok; C ABI — PASSED; правка Apple — PASSED; «KNOWN FAILURE check»: Vision — 8 отчётов, `TestStartStopCycles` — 2, все доступы в ядре Mihomo.

Потоки до слияния (`workflow_dispatch`): tunready — [apple](../../actions/runs/46023996648) (все 8 заданий), [swift-package](../../actions/runs/46024002141) на `276689e`; [bridge-go](../../actions/runs/46022263817) на `be4df44`. Предупреждений в `Apps/`, `Extensions/`, `Packages/` — 0. Поток mihomomem на CI до слияния не гонялся.

**Этап 3, слитый `main` (коммит `4d1a2bd`, 2026-11-27), все четыре workflow зелёные:**

- `apple.yml` ([прогон](../../actions/runs/46012124873)): мост Xray — XCFramework; приложение + расширение `XrayOnly` с адаптером `EngineXray` скомпилированы без подписи для iOS (Debug и Release), iOS Simulator, macOS, tvOS, visionOS; отказ `MihomoOnly`/`Dual` фазой «Flavour guard» — как задумано. Предупреждений в `Extensions/` и `EngineXray` — 0 (первая сборка потока adapter дала 15 предупреждений о `NSLock` в async-функциях, исправлены). Расширение iOS Release — 32 МБ.
- `swift-package.yml` ([прогон](../../actions/runs/46012124605)): **515 тестов, 0 падений на macOS** (Xcode 16.4) и 515/0 на Linux-раннере (не Apple).
- `bridge-go.yml` ([прогон](../../actions/runs/46012124584)): как раньше; «KNOWN FAILURE check» — оба случая Vision упали с гонкой в ядре (по 2 отчёта), кадров моста нет.
- `mihomo-bridge-go.yml` (новый; [прогон](../../actions/runs/46013555915) на `dc0e4fa`): gofmt, vet, `go test` со штатным xray, `-race` для всех остальных тестов — ok; «KNOWN FAILURE check»: `TestProtocolsOverLoopback/VLESS+REALITY+Vision` — 7 отчётов о гонках, `TestStartStopCycles` — 2, все конфликтующие доступы в ядре Mihomo; тест C ABI — PASSED (40 Б: 159,5 нс/пакет при пачке 1, 60,0 нс при 64; 1400 Б при 64 — 32,2 нс); проверка правки Apple — PASSED (`proc_pidinfo`: 5 без правки, 0 с правкой). Первый прогон на `4d1a2bd` [упал](../../actions/runs/46012125018): `TestPrepareConfig` ожидал IPv6-адрес tun, а у раннера нет IPv6 (§3); тест исправлен в `dc0e4fa` и проверен на сервере разработки с IPv6 и без (`unshare -n`).

Поток adapter до слияния: [apple](../../actions/runs/45987643793), [swift-package](../../actions/runs/45987648310) — зелёные на `57fb85a`.

Неподписанная компиляция (`CODE_SIGNING_ALLOWED=NO`) доказывает только, что код компилируется и линкуется под платформу. Она **не** доказывает, что туннель работает, что права (entitlements) верны и что Go-рантайм запускается на устройстве. Linux-результаты (§2.1–2.4) к Apple не относятся.

Приложение + расширение Packet Tunnel (`.github/workflows/apple.yml`, XcodeGen 2.44.1, `Apps/project.yml`):

| Платформа | `XrayOnly` | `MihomoOnly` | `Dual` |
|---|---|---|---|
| iOS + iPadOS (одна цель, `TARGETED_DEVICE_FAMILY` 1,2), устройство arm64, Debug и Release | скомпилировано на CI, [прогон](../../actions/runs/46049957457) | скомпилировано на CI, тот же прогон | скомпилировано на CI (два расширения), тот же прогон |
| iOS Simulator (arm64 + x86_64) | скомпилировано на CI | скомпилировано на CI | скомпилировано на CI |
| macOS (arm64 + x86_64) | скомпилировано на CI | скомпилировано на CI | скомпилировано на CI |
| tvOS, устройство arm64 | скомпилировано на CI | скомпилировано на CI | скомпилировано на CI |
| visionOS, устройство arm64 | скомпилировано на CI | скомпилировано на CI | скомпилировано на CI |

До этапа 4 `MihomoOnly`/`Dual` намеренно останавливались фазой «Flavour guard» (нет артефакта Mihomo); теперь фаза проверяет только соответствие цели и конфигурации (ADR-0009). Проверки продукта этапа 3 (ниже) относились к единственному расширению `PacketTunnel.appex`.

Проверки продукта в каждом задании: `PacketTunnel.appex` встроен в `NetworkPlatform.app`; в бинарнике расширения (в Debug — в `PacketTunnel.debug.dylib`) есть символы моста `_npb_*`; `vtool` показывает нужную платформу и минимум ОС (iOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0); `CFBundleIdentifier` расширения берётся из xcconfig. Предупреждений в исходниках `Apps/` и `Extensions/` при `SWIFT_STRICT_CONCURRENCY=complete` — 0. Первая сборка дала 4 предупреждения: `NSLock` в async-функции `TunnelPendingReply` и не-Sendable результат `loadAllFromPreferences()`. Они исправлены. Размер: расширение iOS Release — 32 МБ (arm64).

Мост Xray для Apple (`Cores/BuildScripts/bridge-apple-xcframework.sh`, Go 1.27.4, Xray-core v26.11.9; [сборка срезов](../../actions/runs/45965441355)):

| Срез | Результат | Платформа в Mach-O |
|---|---|---|
| ios-arm64 | собран, 40,0 МБ | IOS (2) |
| ios-simulator-arm64 / x86_64 | собраны | IOSSIMULATOR (7) |
| macos-arm64 / x86_64 | собраны | MACOS (1) |
| tvos-arm64 | собран | TVOS (3) |
| tvos-simulator-arm64 / x86_64 | собраны | TVOSSIMULATOR (8) |
| xros-arm64 | собран | XROS (11) |
| xros-simulator-arm64 | собран | XROSSIMULATOR (12) |

tvOS и visionOS у Go официального порта нет. Срезы собраны портом `GOOS=ios` с `clang -target …-tvos17.0` / `…-xros1.0`: Go копирует платформу из cgo-объектов. Они собраны и слинкованы в расширения, но **Go-рантайм на tvOS и visionOS не запускался** — работоспособность не доказана.

Выполнено на macOS (не только скомпилировано): `cabi/ctest/abi_test.c` против среза macos-arm64 — **C ABI TEST PASSED** ([прогон](../../actions/runs/45967419430)). Переход C→Go: 127 нс/пакет при пачке 1, 15,7 нс при пачке 64 (40 Б). На устройствах iOS/tvOS/visionOS мост не запускался.

Этап 2. Swift-пакет на macOS (`swift-package.yml`, Xcode 16.4): **477 тестов, 0 падений** ([прогон](../../actions/runs/45967419340)). Тесты `CoreAbstraction` включают `TunnelSession.swift` и `Shared/` через символические ссылки. Тот же прогон на Linux (`swift:5.10`) — 477/0. Это отдельный результат, не Apple.

Go-мост на Linux (`bridge-go.yml`, [прогон](../../actions/runs/45967601248)): gofmt, vet, `go test` — ok; `-race` со штатным xray — ok для всего, кроме двух случаев с Vision; flow + DNS через Trojan+TLS под `-race` — ok; тест C ABI на linux/amd64 — ok. Известный провал (не скрыт, шаг «KNOWN FAILURE check»): `TestFlowThroughProxyWithDNS` **и** `TestProtocolsOverLoopback/VLESS+REALITY+Vision` падают под `-race` из-за гонки внутри Vision ядра (`proxy/proxy.go` 255/384). Шаг проходит, только если конфликтующие обращения лежат в ядре, и падает при любой другой причине. Второй случай на сервере разработки не воспроизводился — гонка недетерминирована.

Чего CI не может и что осталось за устройством и подписью: подпись и provisioning profile, применение entitlements, App Group (`$(TeamIdentifierPrefix)` на macOS без команды раскрывается в пустую строку — в неподписанной сборке группа `org.example.networkplatform`), установка, загрузка расширения системой, запуск Go на iOS/tvOS/visionOS, лимит памяти, всё из `Documentation/Apple/DEVICE_TEST_PLAN.md`.

### 2.1. Swift-пакет — интеграционный прогон этапа 4, 2026-11-27 (Linux)

`Tools/swift-docker.sh swift test -j 1` на `main` после слияния `stage4/clash` и `stage4/mihomoapple` и подключения `EngineMihomo` к компилятору, весь пакет одним прогоном: **589 тестов, 0 падений, 320,4 с**, предупреждений компилятора 0. Лог: `Logs/s4-full.log` (вне git).

| Модуль | Тестов | Упало | Этап 3b |
|---|---|---|---|
| `DomainModels` | 20 | 0 | 20 |
| `CoreAbstraction` (+ `TunnelEngineCatalogTests`) | 149 | 0 | — |
| `ConfigurationEngine` (+ компилятор Mihomo, корпус Mihomo, Routing-фикстуры) | 174 | 0 | — |
| `RoutingEngine` | 110 | 0 | 110 |
| `AdaptiveBalancer` | 79 | 0 | 79 |
| `EngineBridge` (общий код мостов, вынесен из `EngineXray`) | 25 | 0 | — |
| `EngineXray` | 18 | 0 | — |
| `EngineMihomo` (`MihomoCore` 10, `MihomoCompiledConfigurationTests` 4 — вывод компилятора → адаптер → поддельный мост) | 14 | 0 | — |

Интеграционный прогон этапа 3b, 2026-11-27 (Linux):

`Tools/swift-docker.sh swift test -j 1` на `main` после слияния `stage3b/tunready` и `stage3b/mihomomem`, весь пакет одним прогоном: **533 тестов, 0 падений, 325,6 с**, предупреждений компилятора 0. Лог: `Logs/stage3b-int-swift.log` (вне git). Прирост к этапу 3 (515) — тесты компилятора туннеля (`XrayTunnelCompilerTests`), `ConfigValueRedactorTests`, плана сети и адаптера.

Интеграционный прогон этапа 3 (до 3b):

`Tools/swift-docker.sh swift test -j 1` (Docker `swift:5.10`, Swift 5.10.1, Linux x86_64, отладочная сборка, 1300 МБ, 1,5 CPU) на `main` после слияния `stage3/memory`, `stage3/adapter`, `stage3/mihomo`, весь пакет одним прогоном: **515 тестов, 0 падений, 309,3 с**, предупреждений компилятора 0. Лог: `Logs/stage3-int-swift.log` (вне git). Этап 2 (до слияния этапа 3): 477/0.

| Модуль | Тестов | Упало | Этап 2 |
|---|---|---|---|
| `DomainModels` | 20 | 0 | 20 |
| `CoreAbstraction` (вкл. тесты `Extensions/PacketTunnel/Shared` и `TunnelSession.swift` через ссылки) | 143 | 0 | 143 |
| `ConfigurationEngine` (+2 теста профиля `mobile`) | 127 | 0 | 125 |
| `RoutingEngine` | 110 | 0 | 110 |
| `AdaptiveBalancer` | 79 | 0 | 79 |
| `EngineXray` (кадрирование и очередь 9, насос 10, `XrayCore` через `CoreLifecycle`/`CoreRegistry` 17; против поддельного моста) | 36 | 0 | — |

Поток adapter дополнительно гонял `EngineXrayTests` повторно: первая серия — 1 падение из 15 (гонка в самом тесте: счётчики проверялись раньше, чем насос их обновил; тест исправлен, проверка не ослаблена), затем 30/30 и 15/15.

Этап 2, интеграционный прогон (477/0, 322,5 с, `Logs/integrate-swift-test-01.log`): исправлен корневой `Package.swift`.

Потоки дополнительно прогоняли (логи — `Logs/stage2-<поток>/`, вне git): `AdaptiveBalancer` — свойства по 2500 шагов, 50/24/20 сидов; `CoreAbstraction` — 28 повторных прогонов без падений, сборка со `-strict-concurrency=complete` без предупреждений в исходниках.

### 2.2. Мост Xray — сервер разработки (linux/amd64, Go 1.27.4)

Интеграционный прогон этапа 4 на слитом рабочем дереве `main` (лог `Logs/s4-go.log`): gofmt — 0 файлов, `go vet` — чисто; штатный xray 26.11.9 собран из закреплённого ядра; `go test -count=1 ./...` с `NP_STOCK_XRAY` — **ok** (`engine`, 109,9 с). `-race` — на CI (§2.0).

Интеграционный прогон этапа 3b на слитом `main` (лог `Logs/stage3b-int-go.log`): gofmt — 0 файлов, `go vet` — чисто; `go test -count=1 ./...` со штатным xray 26.11.9 (`NP_STOCK_XRAY`) — **ok** (`engine`, 105,7 с; 32 теста верхнего уровня прошли, 1 пропущен по запросу), включая новые тесты вырезания значений (`TestConfigErrorsAreRedacted`, `TestParseErrorOfBrokenJSONIsRedacted`, `TestRedactorRules`, `TestCoreLogRecordsAreRedacted`). `-race` — на CI (§2.0).

Интеграционный прогон этапа 3 на слитом `main` (лог `Logs/stage3-int-go.log`): gofmt, `go vet` — чисто; штатный xray 26.11.9 собран из закреплённого ядра; `go test ./...` с `NP_STOCK_XRAY` — **ok** (`engine`, 106 с, включая 4 новых теста профиля `mobile`). `-race` на сервере разработки не повторялся — его выполняет CI (§2.0).

Интеграционный прогон этапа 2 (лог `Logs/integrate-go-01.log`):

- `go vet ./...` — чисто; `gofmt` — чисто.
- `go test ./...` — **ok** (`engine`, 43 с).
- `go test -race ./...` со штатным xray той же версии как сервером — **FAIL**: только `TestFlowThroughProxyWithDNS`, гонка внутри Vision ядра (`proxy/proxy.go` 255/384, `proxy/vless/outbound.go`), как и в отчёте потока. На CI та же гонка проявилась и в `TestProtocolsOverLoopback/VLESS+REALITY+Vision` (§2.0). Тот же тест под `-race` через Trojan+TLS (`NP_TEST_FLOW_PROXY=Trojan+TLS`) — **ok**.

Прогоны потока bridge (не повторялись при слиянии; логи — `Logs/stage2-bridge/`):

- 200 циклов start/stop: горутины 5→5, куча +448 Б/цикл.
- Шесть протоколов через SOCKS-inbound моста против штатного xray 26.11.9: VLESS+TCP, VLESS+REALITY+Vision, VLESS+XHTTP, Trojan+TLS, Shadowsocks-2022, VMess — TCP 512 КиБ + 8 UDP-датаграмм, все прошли. Счётчики inbound точны; outbound VLESS+TCP и VMess не учитывают UDP-полезную нагрузку (отклонение ядра).
- DNS через туннель (путь flow → `dns` outbound) — прошёл.
- Fuzz 30–60 с на цель (`FuzzPrepareConfig`, `FuzzParseOptions`, `FuzzTunWrite`) — без падений.
- C-архив + тест из C (`bridge-linux-cabi-test.sh`): переход 258–337 нс/пакет при пачке 1, 32–52 нс при 64.
- Режим fd против tun ядра Linux в netns: 8 МиБ TCP по IPv4 и IPv6.
- Стенд tun (`bridge-tunlab.sh`, два netns, VLESS+REALITY+Vision): TCP 16 МиБ v4/v6 при MTU 1280/1400/1500 (SHA-256 совпали), 64 МиБ в обе стороны, UDP 1–7500 Б с фрагментацией, DF, DNS 20/20, петли нет (с отрицательным контролем), ограниченные очереди.
- Замеры (7 прогонов, медиана): режим flow — 90–129 % пропускной способности штатного xray с той же конфигурацией; добавленная задержка ~+350–450 мкс p50, мост против штатного — в пределах шума; CPU на ГиБ не выше; RSS +3–4 МиБ. Профили оптимизации моста не оправдали.
- 30 минут (flow, REALITY, TCP+UDP со сменой соединений): 7,25 ГБ, 6918 соединений, 0 ошибок; плато памяти через ~10–12 мин: куча 52–53 МиБ, **RSS 165–180 МиБ**, ~3400 горутин (неактивные UDP-сессии ядра). С `connIdle` = 30 с (6 мин) — RSS ~59 МиБ. Штатный xray за 8 мин — RSS до 137 МиБ, ещё растёт. Прогон один, только Linux, 30 мин; отсутствие роста дольше 30 мин не проверено. Перепроверка критиком (`Benchmarks/results/bridge-2026-11-27/soak-*-samples.jsonl`).

### 2.3. Компилятор и Xray 26.11.9 — поток protocols

Xray v26.11.9 собран из тега на сервере разработки. `Tools/validate-fixtures.sh` (`xray run -test`): 53 из 53 скомпилированных конфигов приняты, 7 фикстур заблокированы компилятором с причиной (hysteria2-gecko, socks4a, ss-2022-bad-key, ss-plugin-obfs, tuic-v5, vless-plain-public, vmess-json-h2). `negative-mutations.py`: 27 мутаций отвергнуты бинарником, 3 контрольные приняты. `run-interop.sh` (под `unshare -n`): **16 из 16** конфигов клиент↔сервер Xray с настоящим трафиком (токен + 1 МиБ побайтно). При слиянии не повторялось.

### 2.4. RoutingEngine — поток routing

Дифференциальный тест против настоящего `app/router` Xray (Go): 14 таблиц, 578 правил, 3782 запроса — 3779 совпали, 3 известных различия (K1–K3), 0 неожиданных. Release-замер, медиана 3 прогонов: 1M смешанных правил — запрос 7,6 мкс (p99 32 мкс), 436 МБ (пик 476 МБ), перестройка 11–17 с; до индексов — 35,96 мс. При слиянии не повторялось.

### 2.5. Память моста Xray — поток memory (Linux/amd64, netns, 2026-11-27)

Стенд `bridge-tunlab.sh`/`nplab` (VLESS+REALITY+Vision, TCP+UDP со сменой соединений), отдельно RssAnon (приватная память) и RssFile (страницы бинарника). Данные — `Benchmarks/results/memory-2026-11-27/`, методика и источники Apple — `Documentation/Performance/memory-budget.md`. При слиянии не повторялось.

| Прогон | По умолчанию | `mobile` |
|---|---|---|
| 30 мин, плато RSS | 138–164 МиБ | **48,0–49,0 МиБ** |
| RssAnon / куча | 129–153 / 50–54 МиБ | **19,9–20,8** / 7,8–8,5 МиБ |
| Горутины | ~3400 (1052 неактивные UDP-сессии) | 180–393 |
| Трафик, ошибки | — | 7,26 ГБ, 0 ошибок |
| CPU на ГБ, циклы GC | 34,6 с, 67 | 39,2 с (+13 %), 2132 |
| Холодный старт RSS | 30,8 МиБ (anon 5,5, file 25) | то же |
| Всплеск 200 TCP + 200 UDP: пик RSS / RssAnon | 90 / 63 МиБ | 70 / 42 МиБ; на 23 % медленнее, CPU ×2,6, 178–1574 отброса в очереди 512 КиБ, 0 потерь UDP из 5000 |
| Скорость (5 раундов `memcmp`): TCP вниз / вверх / вниз 4 соединения | 189 / 1019 / 209 Мбит/с | 200 / 1009 / 200 Мбит/с (−4…+6 %) |
| Новое соединение, p50 | 7583 мкс | 7688 мкс |

Отдельные настройки: только connIdle 300→60 — RssAnon 46 МиБ; connIdle 30 — RssAnon 18–20 МиБ. Предел 28 МиБ с GOGC 50 ниже живого набора: GC непрерывно (18 618 циклов, CPU ×8) — прежний совет 24–32 МиБ из `Cores/Bridge/README.md` опровергнут. **Цель RSS ≤ 45 МиБ не достигнута**: из 48–49 МиБ 28 МиБ — RssFile (чистые страницы текста бинарника). Linux RSS не равен `phys_footprint` на iOS; на устройстве не мерилось.

### 2.6. Мост Mihomo — поток mihomo (Linux/amd64, сервер разработки, 2026-11-27)

Интеграционный прогон этапа 4 (`Logs/s4-go.log`): gofmt — 0 файлов, `go vet` — чисто; `go test -count=1 ./...` со штатным xray 26.11.9 — **ok** (`cabi` ok, `engine` 14,6 с, включая `TestCompiledFixturesNeedNoOverride`); `mihomo` v1.19.34 собран из закреплённого модуля через `-modfile`; `Tools/validate-fixtures.sh` — `mihomo -t`: **58 приняты, 0 отвергнуто, 7 заблокированы компилятором**.

Интеграционный прогон этапа 3b на слитом `main` (`Logs/stage3b-int-go.log`): gofmt — 0 файлов, `go vet` — чисто; `go test -count=1 ./...` со штатным xray 26.11.9 — **ok**: `cabi` ok, `engine` 9,5 с (13 тестов верхнего уровня прошли с учётом `cabi`, `TestSoakRSS` пропущен по запросу), включая новые `TestMobileProfileOptions`, `TestFlowMaxFlows`, `TestFlowTCPIdleTimeout`, `TestFlowUDPIdleTimeout`; `cmd/npmlab` собирается. Память — §2.8.

Интеграционный прогон этапа 3 на `main` (`Logs/stage3-int-go.log`): gofmt, `go vet` — чисто; `go test ./...` со штатным xray 26.11.9 — **ok**: `cabi` 1 тест (форма ABI совпадает с мостом Xray), `engine` 8 тестов прошли, `TestSoakRSS` пропущен (по запросу, `NP_SOAK`).

Прогоны потока (логи — `Logs/stage3-mihomo/`, вне git):

- Против штатного xray 26.11.9: VLESS+REALITY+Vision и SS-2022 через SOCKS-inbound и через пакетный путь — TCP 1 МиБ эхо + UDP до 3000 Б; DIRECT через пакетный путь — TCP 4 МиБ + UDP до 8000 Б.
- 50 циклов start/stop: горутины 12→12, куча +46 КиБ (~1 КиБ/цикл), RSS +0,6 МиБ.
- Тест C ABI из C (`mihomo-linux-cabi-test.sh`) — PASSED. Переход: 776 нс на вызов при пачке 1, 290–343 нс/пакет при пачке 64 (у моста Xray 32–52 нс). Первая версия (синхронная передача стеку) — ~48 мкс на вызов.
- Правка Apple (`mihomo-apple-check.sh`, без SDK) — PASSED: `./engine` компилируется для ios/arm64, darwin/arm64, darwin/amd64; `proc_pidinfo` в darwin/arm64-бинарнике: 5 вхождений без правки, 0 с правкой.
- RSS холостой: 31,4 МиБ → 37,6 МиБ после старта (+6,2 МиБ).
- 10 мин, VLESS+REALITY через пакетный путь: 11 142 соединения, 44,6 ГиБ, 0 ошибок; RSS процесса теста 126 МиБ (30 с) → ~238 МиБ (5–9 мин), пик 313 МиБ; heapLive 37 → 110 МиБ, плато нет. **Разобрано в §2.8: это тест, а не мост.**
- `go test -race` — падает на гонках внутри ядра Mihomo (§3).

### 2.7. Готовность туннеля — поток tunready (Linux, сервер разработки, 2026-11-27)

Сквозной прогон вывода компилятора в мосте Xray: ссылка VLESS+REALITY+Vision → экспорт из Swift (`testExportCompiledTunnelConfiguration`, `testExportPacketTunnelBridgeOptions`, `NP_EXPORT_DIR`) → `bridge-tunlab.sh compiled DIR` (netns, tun ядра, адреса tun из `plan.json`, опции адаптера через `nplab -options`), штатный xray 26.11.9 сервером. Данные — `Benchmarks/results/tunready-2026-11-27/` (ключи стенда заменены заглушками). При слиянии не повторялось.

- TCP-эхо v4/v6 — SHA-256 совпали; TCP вниз v4 106 Мбит/с, вверх v6 1127 Мбит/с.
- UDP v4/v6 до 4000 Б — прошёл.
- DNS к резолверам туннеля (v4, v6) — 10/10; DNS на чужие адреса (192.0.2.53, 2001:db8:ffff::53) перехвачен — 10/10.
- Локальная сеть мимо туннеля — работает. Пакетов на порт 53 вне туннеля — 0 (счётчик nft, без отрицательного контроля). Петель — 0.
- outQueue 512 КиБ — профиль `mobile` применён. UUID и ключ стенда в журналах не найдены.

### 2.8. Память моста Mihomo — поток mihomomem (Linux/amd64, отдельный процесс `npmlab`, 2026-11-27)

Методика и данные — `Documentation/Performance/memory-budget.md` §10, `Benchmarks/results/mihomo-memory-2026-11-27/`. Тот же стенд и та же нагрузка с темпом, что у моста Xray (§2.5). При слиянии не повторялось.

- **313 МиБ прежнего `TestSoakRSS` — тест, а не утечка моста**: 52 % кучи — запись клиента теста без темпа в собственный стек-«ОС» с растущими буферами, 17 % — журнал debug штатного xray в `bytes.Buffer` без предела (единственное, что росло неограниченно), 1138 из ~1450 горутин — TIME_WAIT клиента теста; путь моста — < 10 % кучи. Тест теперь хранит только хвост вывода xray (плато 182–193 МиБ процесса теста).
- Умолчания, 8 мин: плато с 2-й минуты, RSS 77–79 МиБ, RssAnon 44–45 (мост Xray с умолчаниями — 138–164).
- Профиль `mobile`, 30 мин: 7,24 ГБ, 6904 TCP, 0 ошибок, 0 потерь UDP; **RssAnon 24,4–26,1 МиБ без роста**, куча 11–12, 60–66 UDP-сессий. RSS в этом прогоне 40–43 МиБ только потому, что сервер вытеснил страницы бинарника (RssFile 14–19); предыдущий 30-мин. прогон с резидентным бинарником — RSS 56,4–58,2 МиБ. CPU на ГБ +9 %. **Цель ~50 МиБ RSS не достигнута** (бинарник 31–33 МиБ, на 5 МиБ больше, чем у Xray).
- Всплеск 200 TCP + 200 UDP (3 раунда): пик RssAnon 48,5 МиБ (умолчания — 96), RSS 79,6 (126,6), 0 ошибок, 0 потерь UDP, на 32 % медленнее, CPU ×2,5. Скорость mobile к умолчаниям: вниз 110 %, вверх 91 %, вниз 4 соединения 82–98 %.
- Простой TCP 300 с — выбран, не измерен (нагрузка не доходит до простоя TCP). inQueue 256–512 КиБ отвергнут: вверх −38…−54 %.

### 2.9. Компилятор Mihomo — поток clash (Linux, сервер разработки, 2026-11-27)

Данные — `Benchmarks/results/mihomo-compiled-2026-11-27/`, методика — `Documentation/Architecture/mihomo-config.md` §4. При слиянии повторён только `mihomo -t` (§2.6).

- `mihomo -t` v1.19.34: 58 приняты, 0 отвергнуто, 7 заблокированы компилятором с причиной (mKCP ×2, Hysteria2 gecko, SOCKS4a, плохой ключ SS-2022, две таблицы правил: inbound-tag и NOT). `xray run -test` на том же корпусе — 53/0/7, без изменений.
- Сквозной прогон: вывод компилятора (`testExportCompiledMihomoConfiguration`) → `npmlab` в режиме flow → tun ядра в netns → штатный xray 26.11.9. VLESS+REALITY+Vision, SS-2022, Trojan+TLS (пароль с `#`, `: `, `'`, `%` — кавычки YAML), Hysteria2 (самоподписанный сертификат с пином): TCP-эхо 8 МиБ и UDP-эхо 1…4000 Б по IPv4/IPv6, загрузка/отдача 32 МиБ, DNS A/AAAA на 198.18.0.2 и fd66:6e70::2, перехват DNS на посторонние адреса, локальная сеть мимо туннеля, **0 DNS-пакетов мимо туннеля**, значений конфигурации в журнале нет — **0 проваленных проверок из 16 на протокол**. Это Linux, не Apple.

## 3. Известные проблемы

- **Гонка в ядре Xray (Vision)** под `-race`: `TestFlowThroughProxyWithDNS` падает воспроизводимо, `TestProtocolsOverLoopback/VLESS+REALITY+Vision` — на CI; кадров моста в конфликтующих доступах нет. На CI вынесено в шаг «KNOWN FAILURE check». Не исправлять в ядре без решения — ядро — неизменённая зависимость.
- **Ограничения ядра** (одинаковы во flow, fd и у штатного xray): UDP через VLESS+REALITY+Vision больше ~7500 Б теряется; TCP half-close не передаётся; отдача упирается в ~200 Мбит/с при 800–1000 вверх (причина не найдена).
- **Память и iOS:** профиль `mobile` (мост `memory.profile`, компилятор `XrayMemoryProfile.mobile`: connIdle 30 с, bufferSize 4 КиБ, GOGC 25, предел 40 МиБ, maxFlows 512, без geodata). На Linux, 30 мин: плато RSS 48–49 МиБ (было 138–164), RssAnon 20 МиБ, скорость −4…+6 %, CPU +13 %; всплеск 400 потоков — RssAnon до 42–44 МиБ. **Цель RSS ≤ 45 МиБ не достигнута**: 28 МиБ — текст бинарника. Лимит расширения iOS (~50 МиБ [U], по таблице инженера Apple для iOS 16, «не менялся в iOS 26», зашивать его нельзя) **повысить нельзя**: entitlement increased-memory-limit документирован только для приложений, на app extensions не действует (DTS, форум 779756); единственный официальный путь — запрос в Feedback Assistant. На устройстве не проверено. Не измерены: окна Hysteria2 (в стенде нет сервера Hysteria2), влияние connIdle 30 с на долго молчащие TCP (мессенджеры, push; отдельного тайм-аута UDP в Xray нет); окна XHTTP-h3 не ограничены.
- **Туннель (tunready), ограничения:** перехват DNS — только UDP/53, TCP/53 идёт через прокси; ULA fc00::/7 не исключается (собственный префикс туннеля — ULA); поведение `excludedRoutes` в `NEPacketTunnelNetworkSettings` не проверено; сервер, заданный доменом, получает запись отчёта `untested` (его адрес не исключается из туннеля заранее). Вырезание значений пропускает значения короче 4 символов и общеупотребительные слова; в кольце журнала моста IP-литералы назначений не вырезаются (хост пишет их в журнал как private).
- `statistics()` адаптера без собственного дедлайна (хост оборачивает вызов в `CoreDeadline`).
- **Мост Mihomo, `-race`:** падает на гонках внутри ядра — 9 отчётов в Vision ядра (`transport/vless/vision`, `TestProtocolsOverLoopback/VLESS+REALITY+Vision`), 2 — `log.SetLevel` против `log.print` (`TestStartStopCycles`); кадры моста — только как вызывающий `ApplyConfig`. На CI — шаг «KNOWN FAILURE check» в `mihomo-bridge-go.yml`. Третья гонка (ядро переписывало IP-фильтры при живых слушателях) исправлена в мосте: слушатели закрываются первыми.
- **Мост Mihomo:** REALITY-клиент Mihomo по умолчанию не проходит рукопожатие с Xray 26.11.9 (ядро отбрасывает ключ X25519MLKEM768) — нужен `support-x25519mlkem768: true`; прежние 313 МиБ 10-мин. теста — тест, а не мост (§2.8); профиль `mobile` — RSS ~57 МиБ при резидентном бинарнике, цель ~50 не достигнута; остаток: UDP-сессии со своим REALITY-состоянием (~40 % кучи), TIME_WAIT стека mips (~115 горутин 60 с, константа без опции), буферы отправки стека (11–14 %), очереди моста 1,5 МиБ; тайм-аут UDP-сессий ядра (60 с) не задаётся конфигурацией, `tun.udp-timeout` стек mips игнорирует — простой закрывает обходчик моста; `tun.mode "fd"` не реализован; статистика только итоговая, без разбивки по inbound/outbound; под Apple собран (XCFramework на CI), но не запускался; ядро оставляет IPv6-адрес tun (и его DNS-перехват) только если у хоста в момент разбора конфига есть глобальный IPv6 (`config/utils.go` `verifyIP6`, обход — `SKIP_SYSTEM_IPV6_CHECK`): в расширении это будет зависеть от сети на момент старта — решить в адаптере Mihomo (найдено на CI: у раннеров GitHub нет IPv6, тест исправлен, не ослаблен); после stop до выхода процесса остаются init-горутины и пулы ядра, `cache.db`, глобальные настройки, загруженные geodata.
- **Компилятор Mihomo (этап 4):** без сквозного прогона (в отчёте `untested`): цепочки (`dialer-proxy`), fake-ip, TUIC, XHTTP, VLESS Encryption, ECH, плагины SS; сниффинг выключен; импорта Clash YAML нет; переключать `select` без перекомпиляции нельзя; кто выбирает сервер внутри движка (`url-test` или `AdaptiveBalancer`) — нужен ADR. `mihomo -v` бинарника, собранного `bridge-tunlab.sh build`, в одном из прогонов потока назвал себя «Meta 1.10.0» (версия из `-ldflags` не подставилась); бинарник CI и интеграционного прогона — v1.19.34.
- **Адаптер Mihomo и приложение (этап 4):** приложение не компилирует профиль ни для одного движка и не вызывает `MihomoCompiledConfiguration` — связь компилятор → адаптер проверена только тестом против поддельного моста. Проверка конфигурации при работающем движке отвергается мостом (`invalid_state` → `operationFailed(.validate)`). Выбор расширения переписыванием `providerBundleIdentifier` (ADR-0009) — не проверен (E-3). ADR-0009 отступает от правила ADR-0004 «без дублирования целей» (Xcode не умеет выбирать встраиваемые расширения по конфигурации).
- **sing-tun в Mihomo под Apple** вызывает `recvmsg_x`/`sendmsg_x` системным вызовом по номеру; правка Apple (`mihomo-apple-patch.sh`) заменяет их в копии sing-tun на `ENOSYS`. Пакетный путь моста Mihomo (flow) этими вызовами не пользуется, но поведение на устройстве не проверено.
- **Xray HEAD против тега:** HEAD `e17392a` и v26.11.9 имеют одинаковый номер версии, но разный формат Mux (`mux` против `settings.multiplex`) и freedom (`finalRules` против `firewall`). Компилятор обязан привязываться к закреплённому SHA ядра (сейчас тег). `allowInsecure` в Xray ≥ v26.7.11 — ошибка сборки конфига.
- **Противоречия ADR, требующие правки:** ADR-0003 §2 «пакеты не проходят через Swift» неточен для Xray (Swift передаёт пачки пакетов, не разбирая их; комментарий в `TunnelNetworkSettings.swift` исправлен). Передача конфигурации файлом в App Group закрыта ADR-0008; вариант системного расширения macOS им не покрыт. Подстановка TUN-inbound в профиль «как есть» противоречит «никто не переписывает конфиг» (ревью, 2.1).
- **ADR-0006 и README** говорят, что репозиторий не опубликован; `origin` — публичный GitHub, файла `LICENSE` нет (ревью, 6.1). Нужно решение владельца.
- `Shared/` и `TunnelSession.swift` компилируются в тесты `CoreAbstraction` через символические ссылки; правильно — модули `TunnelIPC`/`TunnelHost` (ADR-0004 §2.3).
- Формат снимка изменился (`last-start-request.bin`); старые JSON-снимки игнорируются.
- `RoutingEngine`: нет инкрементального обновления (только полная перестройка); geosite/geoip в модели нет; компилятор правил в Xray существует только как прототип в тесте паритета.
- Компилятор принимает только `XrayCompileOptions` (уровень журнала, локальный SOCKS-inbound, DNS); в модели нет маршрутизации и DNS; нет Mux, sockopt, XDRIVE, MASQUE (`xray-modern.md` §18).
- `AdaptiveBalancer`: нет зондировщика, исполнителя и хранения last-known-good; числа по умолчанию рассуждены, не измерены; кто владеет выбором внутри движка (этот слой или `leastLoad`/`urltest` движка) — нужен ADR.
- Interop означает Xray ↔ Xray 26.11.9 и клиент Mihomo (вывод нашего компилятора, мост Mihomo) ↔ сервер Xray 26.11.9; сторонние серверы, серверы Mihomo и sing-box не проверялись.
- Общий Go-кэш на сервере разработки после этапа 4 — 6,8 ГБ (рабочие места `clash` и `main` удалены, кэш не чистился). Раньше: был 5,2 ГБ; 2026-11-27 критик удалил `gocache` и старые копии рабочих мест (осталось 1,1 ГБ: кэш модулей, `bin/xray-stock`, `protocols-xray`). Кэш сборки общий для всех ключей `remote-go.sh`, а не личный.
- `go build ./...` в копии на сервере разработки (без `.git`) падает с «error obtaining VCS status»; `go test` и `go vet` проходят. Обход — `GOFLAGS=-buildvcs=false`.
- `apple.yml` скачивает XcodeGen 2.44.1 без проверки контрольной суммы.
- `RoutingEngine` на 1M правил держит ~440–480 МБ RSS: такой объём в расширение iOS не помещается; модуль — управляющий слой, но где он исполняется на iOS, не решено.
- Действия GitHub `checkout@v4`, `setup-go@v5`, `cache@v4`, `*-artifact@v4` работают на Node 20, который раннеры объявили устаревшим; на этапе 4 раннеры уже принудительно запускают их на Node 24 (предупреждение, не ошибка). Обновить, когда будут проверены новые мажорные версии.
- Срезы моста под tvOS и visionOS собраны неофициальным для Go способом (`GOOS=ios` + `clang -target`); исполнение на этих ОС не проверено.

## 4. Что требует Mac или устройства

| Ресурс | Что блокирует |
|---|---|
| **macOS + Xcode** | Закрыто CI (§2.0): пакет на macOS, `xcodegen generate`, компиляция `Extensions/` и `Apps/`, C-архив моста и XCFramework, ветки Darwin/CryptoKit, сигнатуры асинхронных переопределений. Остаётся для Mac с командой разработчика: раскрытие `$(TeamIdentifierPrefix)` в подписанной сборке, доступ к App Group из песочницы macOS. Пометку `UNVERIFIED` сохраняют 4 файла entitlements — в неподписанной сборке они не применяются |
| **Подпись Apple Developer** (Network Extension, App Group) | установка туннеля на устройство и на Mac; TestFlight |
| **macOS CI (можно без устройства)** | Закрыто этапом 4: XCFramework моста Mihomo, сборка `MihomoOnly`/`Dual` для всех платформ (§2.0) |
| **Физические устройства** | первый подъём туннеля через `EngineXray` и через `EngineMihomo` (Go-рантайм Mihomo в расширении, его `phys_footprint` против лимита — расширение Mihomo iOS Release 50 МБ против 34 у Xray), E-3 — два расширения в одном приложении и выбор через `providerBundleIdentifier` (`Dual`) (обработка указателей в привязке, поведение `NEPacketTunnelFlow`, размеры пачек, глубина насоса 2 и буферы 256 КиБ), `phys_footprint` профиля `mobile` против лимита (DEVICE_TEST_PLAN §6.5), проверки H-1…H-5 ADR-0008, Go на tvOS/visionOS, переход Swift↔Go на arm64 и его цена, размеры пачек `readPackets`/`writePackets`, режим fd на Darwin, исключение сокетов движка из туннеля и применение `excludedRoutes` плана (адреса серверов, локальные сети), перехват DNS на устройстве, `phys_footprint` расширения против лимита, `setTunnelNetworkSettings(nil)` при откате, реальные пределы старта/стопа, допустимость `exit()` после зависшего движка, все критерии производительности |
| **Лицензия** (ADR-0006, теперь и GPL-3.0 Mihomo по ADR-0007) | файл `LICENSE`, приём сторонних изменений, сборки `MihomoOnly`/`Dual` |

## 5. Что дальше

1. ~~Компилятор задаёт TUN-inbound; адаптер передаёт профиль `mobile`~~ — сделано (этап 3b, §2.7; Linux + компиляция на macOS CI).
2. Подписанная сборка и первый туннель на iPhone по `Documentation/Apple/DEVICE_TEST_PLAN.md` (E-1…E-9, §6.5 память, H-1…H-5): нужны учётная запись разработчика и устройство (`BUILD_ON_MAC.md`).
3. ~~XCFramework моста Mihomo на macOS CI, адаптер `EngineMihomo`, компилятор модели → Clash YAML~~ — сделано (этап 4; Linux + компиляция на macOS CI). Компиляция профиля в приложении и передача расширению для обоих движков — написано (`importui`, ветка `byk/importui`), на устройстве не запускалось. Дальше: обновление подписок, выбор DNS и маршрутизации в UI; сквозные прогоны цепочек, fake-ip, XHTTP, TUIC; ADR о выборе сервера внутри движка.
4. Правка ADR-0003 §2; модули `TunnelIPC`/`TunnelHost` вместо символических ссылок.
5. Подключить `AdaptiveBalancer` к зондировщику и исполнителю.

## 6. Журнал

| Дата | Событие |
|---|---|
| 2026-11-24 | Phase 0: аудиты, матрицы, ADR-0001…0006, четыре модуля пакета, черновик расширения и приложения. Первый прогон пакета: 251 тест, 0 падений. |
| 2026-11-25…27 | Этап 2, пять параллельных потоков: мост Xray (bridge), справочник Xray (xraymodern), компилятор и форматы ссылок (protocols), маршрутизация (routing), адаптивный выбор (multicore), аудит управляющего слоя (swiftaudit); исследование движков (research/cores). |
| 2026-11-27 | ADR-0007: второй движок — Mihomo. |
| 2026-11-27 | Слияние всех веток в `main`. Исправлен корневой `Package.swift`. Swift: 477 тестов, 0 падений. Go-мост: vet/gofmt чисто, unit — ok, `-race` — один известный провал из-за гонки Vision в ядре. |
| 2026-11-27 | CI на раннерах macOS/Linux: пакет 477/0 на macOS; мост — 10 срезов Apple, тест C ABI на macOS arm64; приложение + расширение `XrayOnly` скомпилированы без подписи для iOS/iPadOS, macOS, tvOS, visionOS; `MihomoOnly`/`Dual` объявлены, не собираются (нет артефакта Mihomo). Исправлены 4 предупреждения строгой конкурентности. |
| 2026-11-27 | Проверка полноты этапа 2 (критик): повторены на `main` a8910ab — gofmt/vet/build/`go test` моста — ok; `-race` воспроизводит гонку Vision в ядре, через Trojan+TLS — ok; `validate-fixtures.sh` — 53/53; `run-interop.sh` — 16/16; Swift `DomainModels`+`AdaptiveBalancer` в контейнере — 99/0. Уточнены README (сборка на CI, два случая гонки, публичность репозитория), STATUS (RSS в 30-мин. прогоне, TunnelSession скомпилирован на CI), THREAT_MODEL T-54. |
| 2026-11-27 | ADR-0007 окончательно: движки — Xray-core и Mihomo; сравнительные замеры отменены владельцем. |
| 2026-11-27 | Этап 4 слит в `main` (`67016bd`): clash (компилятор модели → Clash YAML с отчётом, корпус `*.mihomo.yaml`, `mihomo -t` 58/0/7, сквозной прогон 4 протоколов в мосте Mihomo) и mihomoapple (XCFramework моста Mihomo, `EngineBridge` + `EngineMihomo`, расширение на движок и приложение на вариант — ADR-0009, 18 сборок без подписи на CI); `EngineMihomo` подключён к компилятору (`MihomoCompiledConfiguration`). Swift 589/0 на Linux; Go-тесты обоих мостов — ok; CI — §2.0. |
| 2026-11-27 | Этап 3b слит в `main`: tunready (TUN-inbound, перехват DNS и исключения из общего `TunnelAddressing`; `memory.profile=mobile` из адаптера; вырезание значений конфигурации из ошибок/журнала моста и отчётов компилятора; сквозной прогон вывода компилятора в мосте) и mihomomem (313 МиБ — тест; профиль `mobile` моста Mihomo, RssAnon 24–26 МиБ за 30 мин; стенд `npmlab`). Swift 533/0 (Linux и macOS CI); Go-тесты обоих мостов — ok; все четыре workflow зелёные на `079355a`. |
| 2026-11-27 | Этап 3, три потока слиты в `main`: профиль памяти `mobile` (Linux: плато RSS 48–49 МиБ вместо 138–164, цель ≤ 45 МиБ не достигнута), адаптер `EngineXray` + ADR-0008, мост Mihomo (Linux). Swift 515/0 (Linux и macOS CI); Go-тесты обоих мостов — ok; новый CI `mihomo-bridge-go.yml`; все четыре workflow зелёные. Исправлен `TestPrepareConfig` моста Mihomo (зависел от IPv6 хоста). |
