# STATUS

Дата: **2026-11-27**. Этап: Phase 1 — слияние пяти потоков этапа 2 (мост Xray, компилятор конфигурации, маршрутизация, адаптивный выбор, аудит управляющего слоя) и исследований движков.

Одной строкой: **мост Xray (Go) работает на Linux** — трафик через настоящий tun ядра, шесть протоколов против штатного xray; **компилятор модели → Xray JSON** проверен настоящим Xray 26.11.9; **Swift-пакет из пяти модулей — 477 тестов, 0 падений на Linux**. На платформах Apple **не собиралось ничего**: ни пакет, ни мост, ни расширение, ни приложение; туннель на устройстве не поднимался.

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
| `TunnelSession` (порядок старта, откат, стоп во время старта), типизированные ошибки IPC, ответ с дедлайном, передача конфигурации файлом в App Group (протокол IPC v2) | `Extensions/PacketTunnel/TunnelSession.swift`, `Extensions/PacketTunnel/Shared/` | логика проверена на Linux через символические ссылки в тестах `CoreAbstraction`; под Apple не компилировалось |
| Расширение, приложение, `project.yml` переписаны вокруг сессии (дедлайны, сон/пробуждение, давление памяти, App Group по платформам) | `Extensions/PacketTunnel/`, `Apps/` | **не проверено** (никогда не компилировалось) |
| Справочник современных транспортов Xray (ключи JSON, минимальные версии, HEAD против v26.11.9, покрытие `DomainModels`) | `Documentation/Protocols/xray-modern.md` | документ, по чтению исходников |
| Аудиты движков-кандидатов: shoes, mihomo, leaf, v2ray-core, dae, hysteria | `Documentation/Research/{shoes,mihomo-leaf,v2fly-dae-hysteria}.md`, `SOURCES-cores2.txt` | документ, по чтению исходников |
| Ревью ADR (30 замечаний) | `Documentation/ADR/REVIEW-2026-11-25.md` | документ |

Документы Phase 0 (аудиты, матрицы, ADR-0001…0006, модель угроз) — без изменений, кроме ADR-0001 §4.1/E-5 (решение по utun).

## 2. Что реально запускалось

### 2.1. Swift-пакет — интеграционный прогон 2026-11-27

`Tools/swift-docker.sh swift test -j 1` (Docker `swift:5.10`, Swift 5.10.1, Linux x86_64, отладочная сборка, 1300 МБ, 1,5 CPU), после слияния всех веток, весь пакет одним прогоном: **477 тестов, 0 падений, 0 пропусков, 322,5 с**. Лог: `Logs/integrate-swift-test-01.log` (вне git).

| Модуль | Тестов | Упало | Было на 2026-11-24 |
|---|---|---|---|
| `DomainModels` | 20 | 0 | 20 |
| `CoreAbstraction` (вкл. тесты `Extensions/PacketTunnel/Shared` и `TunnelSession.swift` через ссылки) | 143 | 0 | 50 |
| `ConfigurationEngine` | 125 | 0 | 87 |
| `RoutingEngine` | 110 | 0 | 94 |
| `AdaptiveBalancer` | 79 | 0 | — |

Исправление при слиянии: корневой `Package.swift` не проходил проверку типов в `swift:5.10` («unable to type-check this expression in reasonable time» на цепочке `lib(...) + lib(...)`; все потоки работали через временные манифесты). Список целей теперь собирается по одному оператору `+=`; у `RoutingBench` исключён `run-all.sh` (предупреждение о необработанном файле). Тесты не менялись.

Потоки дополнительно прогоняли (их логи в своих рабочих копиях): `AdaptiveBalancer` — свойства по 2500 шагов, 50/24/20 сидов; `CoreAbstraction` — 28 повторных прогонов без падений, сборка со `-strict-concurrency=complete` без предупреждений в исходниках.

### 2.2. Мост Xray — сервер разработки (linux/amd64, Go 1.27.4)

Интеграционный прогон 2026-11-27 на слитом `main` (лог `Logs/integrate-go-01.log`):

- `go vet ./...` — чисто; `gofmt` — чисто.
- `go test ./...` — **ok** (`engine`, 43 с).
- `go test -race ./...` со штатным xray той же версии как сервером — **FAIL**: только `TestFlowThroughProxyWithDNS`, гонка внутри Vision ядра (`proxy/proxy.go` 255/384, `proxy/vless/outbound.go`), как и в отчёте потока. Тот же тест под `-race` через Trojan+TLS (`NP_TEST_FLOW_PROXY=Trojan+TLS`) — **ok**.

Прогоны потока bridge (не повторялись при слиянии; логи в рабочей копии потока):

- 200 циклов start/stop: горутины 5→5, куча +448 Б/цикл.
- Шесть протоколов через SOCKS-inbound моста против штатного xray 26.11.9: VLESS+TCP, VLESS+REALITY+Vision, VLESS+XHTTP, Trojan+TLS, Shadowsocks-2022, VMess — TCP 512 КиБ + 8 UDP-датаграмм, все прошли. Счётчики inbound точны; outbound VLESS+TCP и VMess не учитывают UDP-полезную нагрузку (отклонение ядра).
- DNS через туннель (путь flow → `dns` outbound) — прошёл.
- Fuzz 30–60 с на цель (`FuzzPrepareConfig`, `FuzzParseOptions`, `FuzzTunWrite`) — без падений.
- C-архив + тест из C (`bridge-linux-cabi-test.sh`): переход 258–337 нс/пакет при пачке 1, 32–52 нс при 64.
- Режим fd против tun ядра Linux в netns: 8 МиБ TCP по IPv4 и IPv6.
- Стенд tun (`bridge-tunlab.sh`, два netns, VLESS+REALITY+Vision): TCP 16 МиБ v4/v6 при MTU 1280/1400/1500 (SHA-256 совпали), 64 МиБ в обе стороны, UDP 1–7500 Б с фрагментацией, DF, DNS 20/20, петли нет (с отрицательным контролем), ограниченные очереди.
- Замеры (7 прогонов, медиана): режим flow — 90–129 % пропускной способности штатного xray с той же конфигурацией; добавленная задержка ~+350–450 мкс p50, мост против штатного — в пределах шума; CPU на ГиБ не выше; RSS +3–4 МиБ. Профили оптимизации моста не оправдали.
- 30 минут (flow, REALITY, TCP+UDP со сменой соединений): 7,25 ГБ, 6918 соединений, 0 ошибок; плато памяти через ~10 мин (куча 52–53 МиБ).

### 2.3. Компилятор и Xray 26.11.9 — поток protocols

Xray v26.11.9 собран из тега на сервере разработки. `Tools/validate-fixtures.sh` (`xray run -test`): 53 из 53 скомпилированных конфигов приняты, 7 фикстур заблокированы компилятором с причиной (hysteria2-gecko, socks4a, ss-2022-bad-key, ss-plugin-obfs, tuic-v5, vless-plain-public, vmess-json-h2). `negative-mutations.py`: 27 мутаций отвергнуты бинарником, 3 контрольные приняты. `run-interop.sh` (под `unshare -n`): **16 из 16** конфигов клиент↔сервер Xray с настоящим трафиком (токен + 1 МиБ побайтно). При слиянии не повторялось.

### 2.4. RoutingEngine — поток routing

Дифференциальный тест против настоящего `app/router` Xray (Go): 14 таблиц, 578 правил, 3782 запроса — 3779 совпали, 3 известных различия (K1–K3), 0 неожиданных. Release-замер, медиана 3 прогонов: 1M смешанных правил — запрос 7,6 мкс (p99 32 мкс), 436 МБ (пик 476 МБ), перестройка 11–17 с; до индексов — 35,96 мс. При слиянии не повторялось.

## 3. Известные проблемы

- **Гонка в ядре Xray (Vision)** под `-race`: `TestFlowThroughProxyWithDNS` падает воспроизводимо; кадров моста в доступах нет. Не исправлять в ядре без решения — ядро — неизменённая зависимость.
- **Ограничения ядра** (одинаковы во flow, fd и у штатного xray): UDP через VLESS+REALITY+Vision больше ~7500 Б теряется; TCP half-close не передаётся; отдача упирается в ~200 Мбит/с при 800–1000 вверх (причина не найдена).
- **Память и iOS:** ядро держит неактивные UDP-сессии ~2×`connIdle` (~73 КиБ на сессию; на прогоне — ~1059 сессий, куча 52 МиБ). С `connIdle` 30 с плато ~10 МиБ. Лимит расширения iOS — порядка 50 МиБ; компилятору нужно задавать меньший `connIdle` — открытый вопрос.
- **Xray HEAD против тега:** HEAD `e17392a` и v26.11.9 имеют одинаковый номер версии, но разный формат Mux (`mux` против `settings.multiplex`) и freedom (`finalRules` против `firewall`). Компилятор обязан привязываться к закреплённому SHA ядра (сейчас тег). `allowInsecure` в Xray ≥ v26.7.11 — ошибка сборки конфига.
- **Противоречия ADR, требующие правки:** ADR-0003 §2 и правило `CLAUDE.md` «пакеты не проходят через Swift» неточны для Xray (Swift передаёт пачки пакетов, не разбирая их); передача конфигурации файлом в App Group противоречит ADR-0003 §3.1/§3.3 и ADR-0005 «system extension first» — нужен новый ADR. Подстановка TUN-inbound в профиль «как есть» противоречит «никто не переписывает конфиг» (ревью, 2.1).
- **ADR-0006 и README** говорят, что репозиторий не опубликован; `origin` — публичный GitHub, файла `LICENSE` нет (ревью, 6.1). Нужно решение владельца.
- `Shared/` и `TunnelSession.swift` компилируются в тесты `CoreAbstraction` через символические ссылки; правильно — модули `TunnelIPC`/`TunnelHost` (ADR-0004 §2.3).
- Формат снимка изменился (`last-start-request.bin`); старые JSON-снимки игнорируются.
- `RoutingEngine`: нет инкрементального обновления (только полная перестройка); geosite/geoip в модели нет; компилятор правил в Xray существует только как прототип в тесте паритета.
- Компилятор принимает только `XrayCompileOptions` (уровень журнала, локальный SOCKS-inbound, DNS); в модели нет маршрутизации и DNS; нет Mux, sockopt, XDRIVE, MASQUE (`xray-modern.md` §18).
- `AdaptiveBalancer`: нет зондировщика, исполнителя и хранения last-known-good; числа по умолчанию рассуждены, не измерены; кто владеет выбором внутри движка (этот слой или `leastLoad`/`urltest` движка) — нужен ADR.
- Interop означает только Xray ↔ Xray 26.11.9; сторонние серверы, sing-box и Mihomo не проверялись.
- Общий Go-кэш на сервере разработки 5,2 ГБ (выше ориентира 4 ГБ), общий для всех рабочих мест.
- CI (`.github/workflows/ci.yml`) не запускался.

## 4. Что требует Mac или устройства

| Ресурс | Что блокирует |
|---|---|
| **macOS + Xcode** | сборка пакета под Apple (Foundation на Darwin), `xcodegen generate`, компиляция `Extensions/` и `Apps/` (18 файлов с пометкой `UNVERIFIED`), C-архив моста под iOS/macOS/tvOS, XCFramework, ветки Darwin/CryptoKit в `ConfigurationHandoff`, сигнатуры асинхронных переопределений (`startTunnel`, `stopTunnel`, `sleep()`), раскрытие `$(TeamIdentifierPrefix)` в Info.plist, доступ к App Group из песочницы macOS |
| **Подпись Apple Developer** (Network Extension, App Group) | установка туннеля на устройство и на Mac; TestFlight |
| **Физические устройства** | переход Swift↔Go на arm64 и его цена, размеры пачек `readPackets`/`writePackets`, режим fd на Darwin, исключение сокетов движка из туннеля, `phys_footprint` расширения против лимита, `setTunnelNetworkSettings(nil)` при откате, реальные пределы старта/стопа, допустимость `exit()` после зависшего движка, все критерии производительности |
| **Лицензия** (ADR-0006, теперь и GPL-3.0 Mihomo по ADR-0007) | файл `LICENSE`, приём сторонних изменений, сборки `MihomoOnly`/`Dual` |

## 5. Что дальше

1. Новый ADR по передаче конфигурации и правка ADR-0003 §2 / правила «пакеты не проходят через Swift».
2. Модули `TunnelIPC`/`TunnelHost` вместо символических ссылок.
3. Адаптер `EngineXray` на Swift поверх C ABI моста; компилятор задаёт `connIdle` и TUN-inbound.
4. На Mac: пакет, расширение, приложение, C-архив моста, первый туннель на iPhone (E-1…E-9).
5. Мост Mihomo и компилятор модели → Clash YAML (ADR-0007); сравнительные замеры Xray/Mihomo/sing-box.
6. Подключить `AdaptiveBalancer` к зондировщику и исполнителю.

## 6. Журнал

| Дата | Событие |
|---|---|
| 2026-11-24 | Phase 0: аудиты, матрицы, ADR-0001…0006, четыре модуля пакета, черновик расширения и приложения. Первый прогон пакета: 251 тест, 0 падений. |
| 2026-11-25…27 | Этап 2, пять параллельных потоков: мост Xray (bridge), справочник Xray (xraymodern), компилятор и форматы ссылок (protocols), маршрутизация (routing), адаптивный выбор (multicore), аудит управляющего слоя (swiftaudit); исследование движков (research/cores). |
| 2026-11-27 | ADR-0007: второй движок — Mihomo. |
| 2026-11-27 | Слияние всех веток в `main`. Исправлен корневой `Package.swift`. Swift: 477 тестов, 0 падений. Go-мост: vet/gofmt чисто, unit — ok, `-race` — один известный провал из-за гонки Vision в ядре. |
