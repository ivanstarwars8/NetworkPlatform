# STATUS

Дата: **2026-11-27**. Этап: Phase 1, этап 3 — профиль памяти `mobile`, адаптер `EngineXray`, мост Mihomo (слиты в `main` 2026-11-27).

Одной строкой: **мост Xray (Go) работает на Linux** — трафик через настоящий tun ядра, шесть протоколов против штатного xray; **мост Mihomo (Go, тот же C ABI) работает на Linux** — VLESS+REALITY+Vision и SS-2022 против штатного xray; **компилятор модели → Xray JSON** проверен настоящим Xray 26.11.9; **Swift-пакет из шести модулей (с адаптером `EngineXray`) — 515 тестов, 0 падений на Linux**; профиль памяти `mobile` снизил плато RSS моста Xray на Linux со 138–164 до 48–49 МиБ (цель ≤ 45 МиБ не достигнута). На раннере macOS CI **скомпилированы без подписи**: пакет, мост — 10 срезов C-архива для iOS/симулятора/macOS/tvOS/visionOS в XCFramework (тест C ABI выполнен на macOS arm64), приложение + расширение `XrayOnly` с зарегистрированным адаптером для iOS/iPadOS, macOS, tvOS, visionOS (§2.0). **Ничего не подписано, не установлено и не запущено на устройстве; туннель не поднимался.** `MihomoOnly` и `Dual` не собираются: мост Mihomo под Apple ещё не собирается (нет XCFramework).

Доказательства разделены по источнику: **Linux** (сервер разработки и контейнер `swift:5.10`) — §2.1–2.6; **macOS CI** (компиляция без подписи, тесты пакета на macOS) — §2.0; **устройство** — ничего (§4).

Статусы:

- **сделано** — существует и проверено тем способом, который для этого вида работы возможен;
- **не проверено** — написано, но не собиралось и не запускалось;
- **заблокировано** — нельзя сделать без ресурса, которого нет.

Решение владельца: **движки проекта — Xray-core и Mihomo** (`Documentation/ADR/0007-second-engine-mihomo.md`, окончательно 2026-11-27; сравнительные замеры движков отменены владельцем). sing-box остаётся изученной альтернативой и не интегрируется. Сборки: `XrayOnly` (без GPL), `MihomoOnly`, `Dual`. Мост Mihomo есть (Linux); компилятора модели → Clash YAML нет (только записка `Documentation/Architecture/mihomo-config.md`).

## 1. Что реализовано

| Часть | Где | Состояние |
|---|---|---|
| Мост Xray: Go-модуль, Xray-core v26.11.9 (`676eaf66f8f0`), Go 1.27.4; автомат состояний, C ABI v1 (14 функций `npb_*`), перезагрузка через stop/start с откатом, статистика в процессе, кольцо журнала, параметры памяти, пакетный ввод-вывод | `Cores/Bridge/` | Linux: собран и проверен (§2.2) |
| Профиль памяти `mobile`: мост (`memory.profile:"mobile"` — предел 40 МиБ, GOGC 25, `tun.outQueueBytes` 512 КиБ, новый `tun.maxFlows` 512, очередь журнала 128; отказ от geodata и `assetDir`), компилятор (`XrayCompileOptions.memoryProfile = .mobile`: `policy.levels.0` connIdle 30 с, handshake 10, uplinkOnly/downlinkOnly 1, bufferSize 4 КиБ; окна QUIC Hysteria2 512К/2М/1М/4М); стенд `burst`/`memcmp`/RssAnon | `Cores/Bridge/engine/`, `XrayConfigCompiler.swift`, `Documentation/Performance/memory-budget.md`, `Benchmarks/results/memory-2026-11-27/` | Linux: замерено (§2.5); цель RSS ≤ 45 МиБ не достигнута; на устройстве не проверено |
| Адаптер `EngineXray` (`XrayCore`: `NetworkCore` поверх C ABI моста; насос пакетов `NEPacketTunnelFlow`↔мост пачками с ограниченной очередью и обратным давлением; журнал, статистика, здоровье, нормализация ошибок) | `Packages/EngineXray/`, `Extensions/PacketTunnel/XrayBridgeBinding.swift` | Linux: 36 тестов против поддельного моста (§2.1); macOS CI: тесты пакета и компиляция без подписи для 4 платформ (§2.0); на устройстве не запускалось, туннель не поднимался; привязка к настоящему мосту не вызывалась ни разу |
| ADR-0008: запрос запуска передаётся файлом в App Group (фиксирует существующий дизайн; ADR-0003 частично заменён); расширение удаляет устаревшие файлы передачи | `Documentation/ADR/0008-start-request-handoff-via-app-group.md` | документ + правка кода; проверки H-1…H-5 — на устройстве |
| Мост Mihomo: Mihomo v1.19.34 (`0455d0d`), Go 1.27.4, тот же C ABI v1 (14 `npb_*`, проверка формы против моста Xray), пакетный путь без fd utun (свой слушатель на стеке `mips`, входная очередь), stop = пустая конфигурация, переписывание опасных ключей YAML, правка Apple без `proc_pidinfo` через `-modfile` | `Cores/MihomoBridge/`, `Cores/BuildScripts/mihomo-*.sh` | Linux: собран и проверен (§2.6); под Apple — только компиляция `GOOS=ios/darwin` на Linux без SDK; XCFramework нет |
| Решение по utun: основной путь — `NEPacketTunnelFlow` пачками (`tun.mode="flow"`), режим fd — по выбору | `Documentation/Architecture/tun-integration.md`, ADR-0001 §4.1 | проверено на Linux; на Apple — нет |
| Стенд на tun ядра Linux (`nplab`, `bridge-tunlab.sh`), сводка замеров | `Cores/Bridge/cmd/nplab`, `Cores/BuildScripts/`, `Benchmarks/BridgeBench`, `Benchmarks/results/bridge-2026-11-27/` | прогнан потоком bridge |
| Компилятор модели → Xray JSON с `ConversionReport` | `Packages/ConfigurationEngine/Sources/Xray*.swift`, `ConversionReport.swift` | сделано (Linux + Xray 26.11.9) |
| Форматы ссылок сверены с источниками; исправления импорта и экспорта | `Documentation/Protocols/share-link-formats.md`, `LinkParsers.swift`, `ShareLinkExporter.swift` | сделано |
| Корпус фикстур (39 ссылок, 16 interop, 5 профилей), проверка настоящим Xray | `Tests/Fixtures/`, `Tools/validate-fixtures.sh` | сделано |
| `RoutingEngine`: семантика выровнена с роутером Xray, понижение правил, индексы «якорей» и обязательного литерала регулярки | `Packages/RoutingEngine/`, `Documentation/Architecture/routing-parity.md` | сделано (Linux); управляющий слой, не путь данных |
| `RoutingBench` (release, 1k–1M правил) | `Benchmarks/RoutingBench/`, `Documentation/Performance/routing-benchmarks.md` | сделано (Linux) |
| `AdaptiveBalancer`: оценка качества, 7 стратегий, три уровня сервер/транспорт/движок, гистерезис, автомат защиты, цена смены движка, Wi-Fi/сотовая, испытательный срок и откат, объяснение решений | `Packages/AdaptiveBalancer/`, `Documentation/Architecture/adaptive-selection.md` | сделано (Linux); ни к чему не подключён |
| `CoreAbstraction`: тайм-ауты, отмена, `shutdown()`, системные события (сон/пробуждение/память), `CoreDeadline` | `Packages/CoreAbstraction/` | сделано (Linux) |
| `TunnelSession` (порядок старта, откат, стоп во время старта), типизированные ошибки IPC, ответ с дедлайном, передача конфигурации файлом в App Group (протокол IPC v2) | `Extensions/PacketTunnel/TunnelSession.swift`, `Extensions/PacketTunnel/Shared/` | логика проверена тестами `CoreAbstraction` (символические ссылки) на Linux и на macOS CI; в составе расширения скомпилировано на macOS CI без подписи; на устройстве не запускалось |
| Расширение, приложение, `project.yml` переписаны вокруг сессии (дедлайны, сон/пробуждение, давление памяти, App Group по платформам) | `Extensions/PacketTunnel/`, `Apps/` | скомпилировано на macOS CI без подписи для iOS/iPadOS, macOS, tvOS, visionOS (§2.0); **никогда не запускалось** |
| CI: Swift-пакет (macOS + Linux), мост Xray (Linux: vet/test/race/C ABI), мост Mihomo (Linux: vet/test/race с известными гонками ядра/C ABI/правка Apple), Apple (XCFramework моста Xray, приложение по платформам, отказ `MihomoOnly`/`Dual`) | `.github/workflows/{swift-package,bridge-go,mihomo-bridge-go,apple}.yml` | работает, все задания зелёные (§2.0) |
| XcodeGen-проект: 4 платформы × приложение + расширение, конфигурации `{Debug,Release}-{XrayOnly,MihomoOnly,Dual}` через xcconfig, расширение линкует `NPXrayBridge.xcframework` и продукт `EngineXray`, при старте пишет в журнал версию ABI моста | `Apps/project.yml`, `Apps/Configurations/`, `Extensions/PacketTunnel/XrayBridgeInfo.swift` | скомпилировано на CI; адаптер зарегистрирован в `XrayOnly`, реестр больше не пуст; старт не проверялся |
| Инструкции для Mac и план проверки на iPhone | `Documentation/Apple/BUILD_ON_MAC.md`, `DEVICE_TEST_PLAN.md` | документ; подписанная сборка и шаги на устройстве не выполнялись |
| Справочник современных транспортов Xray (ключи JSON, минимальные версии, HEAD против v26.11.9, покрытие `DomainModels`) | `Documentation/Protocols/xray-modern.md` | документ, по чтению исходников |
| Аудиты движков-кандидатов: shoes, mihomo, leaf, v2ray-core, dae, hysteria | `Documentation/Research/{shoes,mihomo-leaf,v2fly-dae-hysteria}.md`, `SOURCES-cores2.txt` | документ, по чтению исходников |
| Ревью ADR (30 замечаний) | `Documentation/ADR/REVIEW-2026-11-25.md` | документ |

Документы Phase 0 (аудиты, матрицы, ADR-0001…0006, модель угроз) — без изменений, кроме ADR-0001 §4.1/E-5 (решение по utun) и строки «частично заменён» в ADR-0003 (ADR-0008).

## 2. Что реально запускалось

### 2.0. Apple — сборка на CI (GitHub Actions, macOS 15, Xcode 16.4, 2026-11-27)

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
| iOS + iPadOS (одна цель, `TARGETED_DEVICE_FAMILY` 1,2), устройство arm64, Debug и Release | скомпилировано на CI, [прогон](../../actions/runs/45967419430) | не собирается: нет `NPMihomoBridge.xcframework` и цели расширения Mihomo; фаза «Flavour guard» останавливает сборку с этой причиной ([проверка отказа](../../actions/runs/45967419430)) | не собирается: нужны артефакт Mihomo и второе расширение; та же фаза ([проверка отказа](../../actions/runs/45967419430)) |
| iOS Simulator (arm64 + x86_64) | скомпилировано на CI, [прогон](../../actions/runs/45967419430) | не собирается (та же причина) | не собирается (та же причина) |
| macOS (arm64 + x86_64) | скомпилировано на CI, [прогон](../../actions/runs/45967419430) | не собирается (та же причина) | не собирается (та же причина) |
| tvOS, устройство arm64 | скомпилировано на CI, [прогон](../../actions/runs/45967419430) | не собирается (та же причина) | не собирается (та же причина) |
| visionOS, устройство arm64 | скомпилировано на CI, [прогон](../../actions/runs/45967419430) | не собирается (та же причина) | не собирается (та же причина) |

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

### 2.1. Swift-пакет — интеграционный прогон этапа 3, 2026-11-27 (Linux)

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

Интеграционный прогон этапа 3 на `main` (`Logs/stage3-int-go.log`): gofmt, `go vet` — чисто; `go test ./...` со штатным xray 26.11.9 — **ok**: `cabi` 1 тест (форма ABI совпадает с мостом Xray), `engine` 8 тестов прошли, `TestSoakRSS` пропущен (по запросу, `NP_SOAK`).

Прогоны потока (логи — `Logs/stage3-mihomo/`, вне git):

- Против штатного xray 26.11.9: VLESS+REALITY+Vision и SS-2022 через SOCKS-inbound и через пакетный путь — TCP 1 МиБ эхо + UDP до 3000 Б; DIRECT через пакетный путь — TCP 4 МиБ + UDP до 8000 Б.
- 50 циклов start/stop: горутины 12→12, куча +46 КиБ (~1 КиБ/цикл), RSS +0,6 МиБ.
- Тест C ABI из C (`mihomo-linux-cabi-test.sh`) — PASSED. Переход: 776 нс на вызов при пачке 1, 290–343 нс/пакет при пачке 64 (у моста Xray 32–52 нс). Первая версия (синхронная передача стеку) — ~48 мкс на вызов.
- Правка Apple (`mihomo-apple-check.sh`, без SDK) — PASSED: `./engine` компилируется для ios/arm64, darwin/arm64, darwin/amd64; `proc_pidinfo` в darwin/arm64-бинарнике: 5 вхождений без правки, 0 с правкой.
- RSS холостой: 31,4 МиБ → 37,6 МиБ после старта (+6,2 МиБ).
- 10 мин, VLESS+REALITY через пакетный путь: 11 142 соединения, 44,6 ГиБ, 0 ошибок; RSS процесса теста 126 МиБ (30 с) → ~238 МиБ (5–9 мин), пик 313 МиБ; heapLive 37 → 110 МиБ, **плато нет**. В RSS входят собственный стек и клиент теста; доля моста не выделена; с прогоном Xray (§2.5) не сравнимо. Прогон один.
- `go test -race` — падает на гонках внутри ядра Mihomo (§3).

## 3. Известные проблемы

- **Гонка в ядре Xray (Vision)** под `-race`: `TestFlowThroughProxyWithDNS` падает воспроизводимо, `TestProtocolsOverLoopback/VLESS+REALITY+Vision` — на CI; кадров моста в конфликтующих доступах нет. На CI вынесено в шаг «KNOWN FAILURE check». Не исправлять в ядре без решения — ядро — неизменённая зависимость.
- **Ограничения ядра** (одинаковы во flow, fd и у штатного xray): UDP через VLESS+REALITY+Vision больше ~7500 Б теряется; TCP half-close не передаётся; отдача упирается в ~200 Мбит/с при 800–1000 вверх (причина не найдена).
- **Память и iOS:** профиль `mobile` (мост `memory.profile`, компилятор `XrayMemoryProfile.mobile`: connIdle 30 с, bufferSize 4 КиБ, GOGC 25, предел 40 МиБ, maxFlows 512, без geodata). На Linux, 30 мин: плато RSS 48–49 МиБ (было 138–164), RssAnon 20 МиБ, скорость −4…+6 %, CPU +13 %; всплеск 400 потоков — RssAnon до 42–44 МиБ. **Цель RSS ≤ 45 МиБ не достигнута**: 28 МиБ — текст бинарника. Лимит расширения iOS (~50 МиБ [U], по таблице инженера Apple для iOS 16, «не менялся в iOS 26», зашивать его нельзя) **повысить нельзя**: entitlement increased-memory-limit документирован только для приложений, на app extensions не действует (DTS, форум 779756); единственный официальный путь — запрос в Feedback Assistant. На устройстве не проверено. Не измерены: окна Hysteria2 (в стенде нет сервера Hysteria2), влияние connIdle 30 с на долго молчащие TCP (мессенджеры, push; отдельного тайм-аута UDP в Xray нет); окна XHTTP-h3 не ограничены.
- **Адаптер ещё не передаёт параметры памяти**: `TunnelSession` передаёт `memoryLimitBytes = nil`; расширение по умолчанию задаёт 32 МиБ и GOGC 50 — по старому совету README, который замер §2.5 опроверг (ниже живого набора). Согласовать с профилем `mobile` до первого запуска на устройстве.
- **Компилятор ещё не задаёт TUN-inbound** (connIdle — только в профиле `mobile`): старт в режиме flow будет отвергнут мостом (`config_unsupported`).
- Сообщения ошибок сборки конфига Xray от моста пишутся в журнал расширения как `.public` и могут цитировать значения конфига — открытый риск по ADR-0003 §4, проверить на утечку.
- `statistics()` адаптера без собственного дедлайна (хост оборачивает вызов в `CoreDeadline`).
- **Мост Mihomo, `-race`:** падает на гонках внутри ядра — 9 отчётов в Vision ядра (`transport/vless/vision`, `TestProtocolsOverLoopback/VLESS+REALITY+Vision`), 2 — `log.SetLevel` против `log.print` (`TestStartStopCycles`); кадры моста — только как вызывающий `ApplyConfig`. На CI — шаг «KNOWN FAILURE check» в `mihomo-bridge-go.yml`. Третья гонка (ядро переписывало IP-фильтры при живых слушателях) исправлена в мосте: слушатели закрываются первыми.
- **Мост Mihomo:** REALITY-клиент Mihomo по умолчанию не проходит рукопожатие с Xray 26.11.9 (ядро отбрасывает ключ X25519MLKEM768) — нужен `support-x25519mlkem768: true`; 10-мин. прогон — RSS процесса теста до 313 МиБ, плато нет (§2.6); `tun.mode "fd"` не реализован; статистика только итоговая, без разбивки по inbound/outbound; не собирался под Apple, скрипта XCFramework нет; ядро оставляет IPv6-адрес tun (и его DNS-перехват) только если у хоста в момент разбора конфига есть глобальный IPv6 (`config/utils.go` `verifyIP6`, обход — `SKIP_SYSTEM_IPV6_CHECK`): в расширении это будет зависеть от сети на момент старта — решить в адаптере Mihomo (найдено на CI: у раннеров GitHub нет IPv6, тест исправлен, не ослаблен); после stop до выхода процесса остаются init-горутины и пулы ядра, `cache.db`, глобальные настройки, загруженные geodata.
- **Xray HEAD против тега:** HEAD `e17392a` и v26.11.9 имеют одинаковый номер версии, но разный формат Mux (`mux` против `settings.multiplex`) и freedom (`finalRules` против `firewall`). Компилятор обязан привязываться к закреплённому SHA ядра (сейчас тег). `allowInsecure` в Xray ≥ v26.7.11 — ошибка сборки конфига.
- **Противоречия ADR, требующие правки:** ADR-0003 §2 «пакеты не проходят через Swift» неточен для Xray (Swift передаёт пачки пакетов, не разбирая их; комментарий в `TunnelNetworkSettings.swift` исправлен). Передача конфигурации файлом в App Group закрыта ADR-0008; вариант системного расширения macOS им не покрыт. Подстановка TUN-inbound в профиль «как есть» противоречит «никто не переписывает конфиг» (ревью, 2.1).
- **ADR-0006 и README** говорят, что репозиторий не опубликован; `origin` — публичный GitHub, файла `LICENSE` нет (ревью, 6.1). Нужно решение владельца.
- `Shared/` и `TunnelSession.swift` компилируются в тесты `CoreAbstraction` через символические ссылки; правильно — модули `TunnelIPC`/`TunnelHost` (ADR-0004 §2.3).
- Формат снимка изменился (`last-start-request.bin`); старые JSON-снимки игнорируются.
- `RoutingEngine`: нет инкрементального обновления (только полная перестройка); geosite/geoip в модели нет; компилятор правил в Xray существует только как прототип в тесте паритета.
- Компилятор принимает только `XrayCompileOptions` (уровень журнала, локальный SOCKS-inbound, DNS); в модели нет маршрутизации и DNS; нет Mux, sockopt, XDRIVE, MASQUE (`xray-modern.md` §18).
- `AdaptiveBalancer`: нет зондировщика, исполнителя и хранения last-known-good; числа по умолчанию рассуждены, не измерены; кто владеет выбором внутри движка (этот слой или `leastLoad`/`urltest` движка) — нужен ADR.
- Interop означает только Xray ↔ Xray 26.11.9; сторонние серверы, sing-box и Mihomo не проверялись.
- Общий Go-кэш на сервере разработки был 5,2 ГБ; 2026-11-27 критик удалил `gocache` и старые копии рабочих мест (осталось 1,1 ГБ: кэш модулей, `bin/xray-stock`, `protocols-xray`). Кэш сборки общий для всех ключей `remote-go.sh`, а не личный.
- `go build ./...` в копии на сервере разработки (без `.git`) падает с «error obtaining VCS status»; `go test` и `go vet` проходят. Обход — `GOFLAGS=-buildvcs=false`.
- `apple.yml` скачивает XcodeGen 2.44.1 без проверки контрольной суммы.
- `RoutingEngine` на 1M правил держит ~440–480 МБ RSS: такой объём в расширение iOS не помещается; модуль — управляющий слой, но где он исполняется на iOS, не решено.
- Действия GitHub `checkout@v4`, `setup-go@v5`, `cache@v4`, `*-artifact@v4` работают на Node 20, который раннеры объявили устаревшим (предупреждение, не ошибка). Обновить, когда будут проверены новые мажорные версии.
- Срезы моста под tvOS и visionOS собраны неофициальным для Go способом (`GOOS=ios` + `clang -target`); исполнение на этих ОС не проверено.

## 4. Что требует Mac или устройства

| Ресурс | Что блокирует |
|---|---|
| **macOS + Xcode** | Закрыто CI (§2.0): пакет на macOS, `xcodegen generate`, компиляция `Extensions/` и `Apps/`, C-архив моста и XCFramework, ветки Darwin/CryptoKit, сигнатуры асинхронных переопределений. Остаётся для Mac с командой разработчика: раскрытие `$(TeamIdentifierPrefix)` в подписанной сборке, доступ к App Group из песочницы macOS. Пометку `UNVERIFIED` сохраняют 4 файла entitlements — в неподписанной сборке они не применяются |
| **Подпись Apple Developer** (Network Extension, App Group) | установка туннеля на устройство и на Mac; TestFlight |
| **macOS CI (можно без устройства)** | XCFramework моста Mihomo (`mihomo-apple-patch.sh` + c-archive против SDK), снятие «Flavour guard» для `MihomoOnly` |
| **Физические устройства** | первый подъём туннеля через `EngineXray` (обработка указателей в привязке, поведение `NEPacketTunnelFlow`, размеры пачек, глубина насоса 2 и буферы 256 КиБ), `phys_footprint` профиля `mobile` против лимита (DEVICE_TEST_PLAN §6.5), проверки H-1…H-5 ADR-0008, Go на tvOS/visionOS, переход Swift↔Go на arm64 и его цена, размеры пачек `readPackets`/`writePackets`, режим fd на Darwin, исключение сокетов движка из туннеля, `phys_footprint` расширения против лимита, `setTunnelNetworkSettings(nil)` при откате, реальные пределы старта/стопа, допустимость `exit()` после зависшего движка, все критерии производительности |
| **Лицензия** (ADR-0006, теперь и GPL-3.0 Mihomo по ADR-0007) | файл `LICENSE`, приём сторонних изменений, сборки `MihomoOnly`/`Dual` |

## 5. Что дальше

1. Компилятор задаёт TUN-inbound; адаптер передаёт профиль `mobile` в опции моста (вместо 32 МиБ/GOGC 50) — без этого первый старт на устройстве отвергнется.
2. Подписанная сборка и первый туннель на iPhone по `Documentation/Apple/DEVICE_TEST_PLAN.md` (E-1…E-9, §6.5 память, H-1…H-5): нужны учётная запись разработчика и устройство (`BUILD_ON_MAC.md`).
3. XCFramework моста Mihomo на macOS CI, адаптер `EngineMihomo`, компилятор модели → Clash YAML (`Documentation/Architecture/mihomo-config.md`).
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
| 2026-11-27 | Этап 3, три потока слиты в `main`: профиль памяти `mobile` (Linux: плато RSS 48–49 МиБ вместо 138–164, цель ≤ 45 МиБ не достигнута), адаптер `EngineXray` + ADR-0008, мост Mihomo (Linux). Swift 515/0 (Linux и macOS CI); Go-тесты обоих мостов — ok; новый CI `mihomo-bridge-go.yml`; все четыре workflow зелёные. Исправлен `TestPrepareConfig` моста Mihomo (зависел от IPv6 хоста). |
