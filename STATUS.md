# STATUS

Дата: **2026-11-27**. Этап: Phase 1 — слияние потоков этапа 2 и сборка под Apple на CI (раннеры macOS GitHub Actions).

Одной строкой: **мост Xray (Go) работает на Linux** — трафик через настоящий tun ядра, шесть протоколов против штатного xray; **компилятор модели → Xray JSON** проверен настоящим Xray 26.11.9; **Swift-пакет из пяти модулей — 477 тестов, 0 падений на Linux**. На раннере macOS CI **скомпилированы без подписи**: пакет (477 тестов, 0 падений), мост — 10 срезов C-архива для iOS/симулятора/macOS/tvOS/visionOS в XCFramework (тест C ABI выполнен на macOS arm64), приложение + расширение `XrayOnly` для iOS/iPadOS, macOS, tvOS, visionOS (§2.0). **Ничего не подписано, не установлено и не запущено на устройстве; туннель не поднимался.** `MihomoOnly` и `Dual` не собираются: нет артефакта Mihomo.

Статусы:

- **сделано** — существует и проверено тем способом, который для этого вида работы возможен;
- **не проверено** — написано, но не собиралось и не запускалось;
- **заблокировано** — нельзя сделать без ресурса, которого нет.

Решение владельца после ветвления потоков: **второй движок — Mihomo, а не sing-box** (`Documentation/ADR/0007-second-engine-mihomo.md`, принято как направление 2026-11-27, подтверждение — после сравнительных замеров). sing-box остаётся изученной альтернативой и не интегрируется. Сборки: `XrayOnly` (без GPL), `MihomoOnly`, `Dual`. Моста Mihomo и компилятора в Clash YAML пока нет.

## 1. Что реализовано

| Часть | Где | Состояние |
|---|---|---|
| Мост Xray: Go-модуль, Xray-core v26.11.9 (`676eaf66f8f0`), Go 1.27.4; автомат состояний, C ABI v1 (14 функций `npb_*`), перезагрузка через stop/start с откатом, статистика в процессе, кольцо журнала, параметры памяти, пакетный ввод-вывод | `Cores/Bridge/` | Linux: собран и проверен (§2.2) |
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
| CI: Swift-пакет (macOS + Linux), Go-мост (Linux: vet/test/race/C ABI), Apple (XCFramework моста, приложение по платформам, отказ `MihomoOnly`/`Dual`) | `.github/workflows/{swift-package,bridge-go,apple}.yml` | работает, все задания зелёные (§2.0) |
| XcodeGen-проект: 4 платформы × приложение + расширение, конфигурации `{Debug,Release}-{XrayOnly,MihomoOnly,Dual}` через xcconfig, расширение линкует `NPXrayBridge.xcframework` и при старте пишет в журнал версию ABI моста | `Apps/project.yml`, `Apps/Configurations/`, `Extensions/PacketTunnel/XrayBridgeInfo.swift` | скомпилировано на CI; адаптера движка нет — реестр пуст, старт отказывает `core_not_registered` |
| Инструкции для Mac и план проверки на iPhone | `Documentation/Apple/BUILD_ON_MAC.md`, `DEVICE_TEST_PLAN.md` | документ; подписанная сборка и шаги на устройстве не выполнялись |
| Справочник современных транспортов Xray (ключи JSON, минимальные версии, HEAD против v26.11.9, покрытие `DomainModels`) | `Documentation/Protocols/xray-modern.md` | документ, по чтению исходников |
| Аудиты движков-кандидатов: shoes, mihomo, leaf, v2ray-core, dae, hysteria | `Documentation/Research/{shoes,mihomo-leaf,v2fly-dae-hysteria}.md`, `SOURCES-cores2.txt` | документ, по чтению исходников |
| Ревью ADR (30 замечаний) | `Documentation/ADR/REVIEW-2026-11-25.md` | документ |

Документы Phase 0 (аудиты, матрицы, ADR-0001…0006, модель угроз) — без изменений, кроме ADR-0001 §4.1/E-5 (решение по utun).

## 2. Что реально запускалось

### 2.0. Apple — сборка на CI (GitHub Actions, macOS 15, Xcode 16.4, 2026-11-27)

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

Swift-пакет на macOS (`swift-package.yml`, Xcode 16.4): **477 тестов, 0 падений** ([прогон](../../actions/runs/45967419340)). Тесты `CoreAbstraction` включают `TunnelSession.swift` и `Shared/` через символические ссылки. Тот же прогон на Linux (`swift:5.10`) — 477/0. Это отдельный результат, не Apple.

Go-мост на Linux (`bridge-go.yml`, [прогон](../../actions/runs/45967601248)): gofmt, vet, `go test` — ok; `-race` со штатным xray — ok для всего, кроме двух случаев с Vision; flow + DNS через Trojan+TLS под `-race` — ok; тест C ABI на linux/amd64 — ok. Известный провал (не скрыт, шаг «KNOWN FAILURE check»): `TestFlowThroughProxyWithDNS` **и** `TestProtocolsOverLoopback/VLESS+REALITY+Vision` падают под `-race` из-за гонки внутри Vision ядра (`proxy/proxy.go` 255/384). Шаг проходит, только если конфликтующие обращения лежат в ядре, и падает при любой другой причине. Второй случай на сервере разработки не воспроизводился — гонка недетерминирована.

Чего CI не может и что осталось за устройством и подписью: подпись и provisioning profile, применение entitlements, App Group (`$(TeamIdentifierPrefix)` на macOS без команды раскрывается в пустую строку — в неподписанной сборке группа `org.example.networkplatform`), установка, загрузка расширения системой, запуск Go на iOS/tvOS/visionOS, лимит памяти, всё из `Documentation/Apple/DEVICE_TEST_PLAN.md`.

### 2.1. Swift-пакет — интеграционный прогон 2026-11-27 (Linux)

`Tools/swift-docker.sh swift test -j 1` (Docker `swift:5.10`, Swift 5.10.1, Linux x86_64, отладочная сборка, 1300 МБ, 1,5 CPU), после слияния всех веток, весь пакет одним прогоном: **477 тестов, 0 падений, 0 пропусков, 322,5 с**. Лог: `Logs/integrate-swift-test-01.log` (вне git).

| Модуль | Тестов | Упало | Было на 2026-11-24 |
|---|---|---|---|
| `DomainModels` | 20 | 0 | 20 |
| `CoreAbstraction` (вкл. тесты `Extensions/PacketTunnel/Shared` и `TunnelSession.swift` через ссылки) | 143 | 0 | 50 |
| `ConfigurationEngine` | 125 | 0 | 87 |
| `RoutingEngine` | 110 | 0 | 94 |
| `AdaptiveBalancer` | 79 | 0 | — |

Исправление при слиянии: корневой `Package.swift` не проходил проверку типов в `swift:5.10` («unable to type-check this expression in reasonable time» на цепочке `lib(...) + lib(...)`; все потоки работали через временные манифесты). Список целей теперь собирается по одному оператору `+=`; у `RoutingBench` исключён `run-all.sh` (предупреждение о необработанном файле). Тесты не менялись.

Потоки дополнительно прогоняли (логи — `Logs/stage2-<поток>/`, вне git): `AdaptiveBalancer` — свойства по 2500 шагов, 50/24/20 сидов; `CoreAbstraction` — 28 повторных прогонов без падений, сборка со `-strict-concurrency=complete` без предупреждений в исходниках.

### 2.2. Мост Xray — сервер разработки (linux/amd64, Go 1.27.4)

Интеграционный прогон 2026-11-27 на слитом `main` (лог `Logs/integrate-go-01.log`):

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

## 3. Известные проблемы

- **Гонка в ядре Xray (Vision)** под `-race`: `TestFlowThroughProxyWithDNS` падает воспроизводимо, `TestProtocolsOverLoopback/VLESS+REALITY+Vision` — на CI; кадров моста в конфликтующих доступах нет. На CI вынесено в шаг «KNOWN FAILURE check». Не исправлять в ядре без решения — ядро — неизменённая зависимость.
- **Ограничения ядра** (одинаковы во flow, fd и у штатного xray): UDP через VLESS+REALITY+Vision больше ~7500 Б теряется; TCP half-close не передаётся; отдача упирается в ~200 Мбит/с при 800–1000 вверх (причина не найдена).
- **Память и iOS:** ядро держит неактивные UDP-сессии ~2×`connIdle` (~73 КиБ на сессию; на прогоне — ~1059 сессий, куча 52 МиБ, **RSS процесса 165–180 МиБ**). С `connIdle` 30 с куча ~10 МиБ, но **RSS ~59 МиБ** — тоже выше ориентира. Лимит расширения iOS — порядка 50 МиБ [U]; RSS на Linux не равен `phys_footprint` на iOS, но запаса нет даже на холостом старте (RSS ~31–34 МиБ). Нужны меньший `connIdle`, `GOMEMLIMIT`/`debug.SetMemoryLimit` и замер на устройстве — открытый вопрос, критерий «память под контролем на iOS» не выполнен.
- **Xray HEAD против тега:** HEAD `e17392a` и v26.11.9 имеют одинаковый номер версии, но разный формат Mux (`mux` против `settings.multiplex`) и freedom (`finalRules` против `firewall`). Компилятор обязан привязываться к закреплённому SHA ядра (сейчас тег). `allowInsecure` в Xray ≥ v26.7.11 — ошибка сборки конфига.
- **Противоречия ADR, требующие правки:** ADR-0003 §2 и правило `CLAUDE.md` «пакеты не проходят через Swift» неточны для Xray (Swift передаёт пачки пакетов, не разбирая их); передача конфигурации файлом в App Group противоречит ADR-0003 §3.1/§3.3 и ADR-0005 «system extension first» — нужен новый ADR. Подстановка TUN-inbound в профиль «как есть» противоречит «никто не переписывает конфиг» (ревью, 2.1).
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
| **Физические устройства** | переход Swift↔Go на arm64 и его цена, размеры пачек `readPackets`/`writePackets`, режим fd на Darwin, исключение сокетов движка из туннеля, `phys_footprint` расширения против лимита, `setTunnelNetworkSettings(nil)` при откате, реальные пределы старта/стопа, допустимость `exit()` после зависшего движка, все критерии производительности |
| **Лицензия** (ADR-0006, теперь и GPL-3.0 Mihomo по ADR-0007) | файл `LICENSE`, приём сторонних изменений, сборки `MihomoOnly`/`Dual` |

## 5. Что дальше

1. Новый ADR по передаче конфигурации и правка ADR-0003 §2 / правила «пакеты не проходят через Swift».
2. Модули `TunnelIPC`/`TunnelHost` вместо символических ссылок.
3. Адаптер `EngineXray` на Swift поверх C ABI моста; компилятор задаёт `connIdle` и TUN-inbound.
4. Подписанная сборка и первый туннель на iPhone по `Documentation/Apple/DEVICE_TEST_PLAN.md` (E-1…E-9): нужны учётная запись разработчика и устройство (`BUILD_ON_MAC.md`).
5. Мост Mihomo и компилятор модели → Clash YAML (ADR-0007); сравнительные замеры Xray/Mihomo/sing-box.
6. Подключить `AdaptiveBalancer` к зондировщику и исполнителю.

## 6. Журнал

| Дата | Событие |
|---|---|
| 2026-11-24 | Phase 0: аудиты, матрицы, ADR-0001…0006, четыре модуля пакета, черновик расширения и приложения. Первый прогон пакета: 251 тест, 0 падений. |
| 2026-11-25…27 | Этап 2, пять параллельных потоков: мост Xray (bridge), справочник Xray (xraymodern), компилятор и форматы ссылок (protocols), маршрутизация (routing), адаптивный выбор (multicore), аудит управляющего слоя (swiftaudit); исследование движков (research/cores). |
| 2026-11-27 | ADR-0007: второй движок — Mihomo. |
| 2026-11-27 | Слияние всех веток в `main`. Исправлен корневой `Package.swift`. Swift: 477 тестов, 0 падений. Go-мост: vet/gofmt чисто, unit — ok, `-race` — один известный провал из-за гонки Vision в ядре. |
| 2026-11-27 | CI на раннерах macOS/Linux: пакет 477/0 на macOS; мост — 10 срезов Apple, тест C ABI на macOS arm64; приложение + расширение `XrayOnly` скомпилированы без подписи для iOS/iPadOS, macOS, tvOS, visionOS; `MihomoOnly`/`Dual` объявлены, не собираются (нет артефакта Mihomo). Исправлены 4 предупреждения строгой конкурентности. |
| 2026-11-27 | Проверка полноты этапа 2 (критик): повторены на `main` a8910ab — gofmt/vet/build/`go test` моста — ok; `-race` воспроизводит гонку Vision в ядре, через Trojan+TLS — ok; `validate-fixtures.sh` — 53/53; `run-interop.sh` — 16/16; Swift `DomainModels`+`AdaptiveBalancer` в контейнере — 99/0. Уточнены README (сборка на CI, два случая гонки, публичность репозитория), STATUS (RSS в 30-мин. прогоне, TunnelSession скомпилирован на CI), THREAT_MODEL T-54. |
