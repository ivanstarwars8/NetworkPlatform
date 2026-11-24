# STATUS

Дата: **2026-11-24**. Этап: Phase 0 завершена по документам, Phase 1 начата.

Одной строкой: написаны документы, четыре модуля логики на Swift и черновик расширения с приложением. **Swift-пакет собран и его тесты пройдены на Linux (Swift 5.10.1, 251 тест, 0 падений)**; на платформах Apple пакет не собирался; расширение и приложение **не собирались вообще, на устройство ничего не установлено**.

Статусы:

- **сделано** — существует и проверено тем способом, который для этого вида работы возможен;
- **не проверено** — написано, но не собиралось и не запускалось;
- **заблокировано** — нельзя сделать без ресурса, которого нет.

## 1. Сделано

Документы. Проверка для них — чтение исходников с закреплёнными SHA (`Documentation/Research/SOURCES.txt`); сборкой не подтверждено ничего.

| Что | Где |
|---|---|
| Аудит sing-box, libbox, sing-box-for-apple | `Documentation/Research/singbox.md` |
| Аудит Xray-core, libXray, OneXray | `Documentation/Research/xray.md` |
| Аудит Karing, hiddify | `Documentation/Research/reference-apps.md` |
| Сводка, расхождения между аудитами, список непроверенного | `RESEARCH.md` |
| Матрицы протоколов, платформ, конкурентов | `PROTOCOL_MATRIX.md`, `PLATFORM_MATRIX.md`, `COMPETITOR_MATRIX.md` |
| Аудит лицензий | `LICENSE_AUDIT.md` |
| Реестр рисков R-01…R-22 | `TECHNICAL_RISKS.md` |
| Решения | `Documentation/ADR/0001…0006` |
| Модель угроз, первая версия | `Documentation/Security/THREAT_MODEL.md` |
| Описание намеченной сборки моста | `Cores/BuildScripts/README.md` |

## 2. Не проверено

### 2.1. Swift-пакет — собран и протестирован на Linux, на Apple не проверен

**Прогон 2026-11-24.** Docker-образ `swift:5.10` (вариант `-slim` не годится: в нём только рантайм, компилятора нет). `swift --version`: `Swift version 5.10.1 (swift-5.10.1-RELEASE)`, `Target: x86_64-unknown-linux-gnu`. Контейнер: `--memory=1300m --memory-swap=1300m --cpus=1.5`, без сети. Отладочная сборка, `-j 1`. OOM не было, сборка по одной цели не понадобилась.

| Команда | Результат | Лог (`Logs/`, вне git) |
|---|---|---|
| `swift build -j 1` | 1-й прогон: 1 ошибка компиляции (см. ниже); после исправления — успех, 0 предупреждений | `build-01.log`, `build-02.log` |
| `swift build --build-tests -j 1` | успех, 0 предупреждений | `buildtests-01.log` |
| `swift test -j 1` (всё сразу, последовательно) | **251 тест, 0 падений, 0 пропущенных**, 16,8 с | `test-02-all.log` |
| `swift test -j 1 --filter '^<Модуль>Tests\.'` по модулям | те же числа, что в таблице ниже | `test-01-*.log` |

| Модуль | Что в нём | Тестов запущено | Прошло | Упало |
|---|---|---|---|---|
| `DomainModels` | профиль, узел, настройки протоколов и транспортов, группы, ссылки на секреты, непереводимый остаток | 20 | 20 | 0 |
| `CoreAbstraction` | протокол `NetworkCore`, автомат жизненного цикла `CoreLifecycle`, реестр и выбор движка, возможности | 50 | 50 | 0 |
| `ConfigurationEngine` | импорт и экспорт ссылок (`vless`, `vmess`, `trojan`, `ss`, `hysteria2`, `tuic`, `socks`, `wireguard`), разбор подписки, отчёт импорта | 87 | 87 | 0 |
| `RoutingEngine` | модель правил, индексы, сопоставление, симулятор маршрутов, поиск конфликтов | 94 | 94 | 0 |

Единственное исправление в исходниках: `Packages/CoreAbstraction/Sources/CoreLifecycle.swift`, `stateUpdates()` — в `onTermination` вложенный `Task` ссылался на слабый `self` внешнего замыкания (`error: reference to captured var 'self' in concurrently-executing code`); добавлен собственный список захвата `Task { [weak self] in … }`. Поведение не изменилось. Ни один тест не правился, не удалялся и не пропускался.

Перф-тесты `RouterPerformanceTests` (отладочная сборка, 1,5 vCPU нагруженного боевого сервера — числа ориентировочные, не эталон):

| Показатель | Отдельный прогон модуля | Полный прогон |
|---|---|---|
| компиляция 100 000 суффиксных правил | 1,18 с | 1,47 с |
| узлов доменного trie | 107 009 | 107 009 |
| 20 000 запросов по индексу | 0,109 с | 0,388 с |
| один запрос по индексу (среднее по 200 повторам выборки) | 3,55 мкс | 3,56 мкс |
| один запрос линейным эталоном | 70,4 мс | 159,8 мс |
| отношение линейный/индексный (порог теста — 20×) | ≈ 19 800× | ≈ 44 900× |
| 20 000 запросов: 1 000 правил / 100 000 правил | 0,071 с / 0,137 с | 0,274 с / 0,277 с |

Что этим прогоном **не проверено**:

- сборка и тесты пакета на macOS/iOS/tvOS/visionOS (Foundation на Darwin отличается от swift-corelibs-foundation: `JSONDecoder`, `NSLock`, порядок ключей и т. п.);
- release-сборка (`-c release`), режим языка Swift 6 и `-strict-concurrency=complete`;
- Swift 5.9 — версия, названная в `Package.swift` (`swift-tools-version:5.9`) и в `.github/workflows/ci.yml` (`swift:5.9`); прогон был на 5.10.1;
- параллельный запуск тестов (`--parallel`);
- соответствие импортёров реальным ссылкам из живых подписок и поведению движков: тесты проверяют код против собственных фикстур, а форматы `vmess` base64-JSON, legacy `ss`, `tuic://`, `wireguard://` по-прежнему записаны по памяти (UNVERIFIED);
- производительность в release и на целевых устройствах.

19 Swift-файлов `RoutingEngine` и `CoreAbstraction` всё ещё начинаются с комментария `UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode`. Для них он теперь неточен (собраны и запущены на Linux, но не на macOS). Пометки не тронуты: нужно решение — снять или заменить формулировкой «проверено на Linux, не на Apple».

Чего в пакете нет: компиляторов модели в конфиг движка, адаптеров движков, хранения, Keychain.

Известные несоответствия:

- `Package.swift` объявляет `platforms` iOS 16 / macOS 13; ADR-0005 требует 17 / 14. Манифест не исправлен.
- ADR-0001 §5 описывает интерфейс движка эскизом `TunnelEngine`; в коде он называется `NetworkCore` и отличается составом методов. ADR не обновлён.
- `CLAUDE.md` («Ограничения этого хоста») утверждает, что здесь ничего нельзя собрать; пакет собирается в контейнере с ограничением памяти. Файл не правился.

### 2.2. Файлы с пометкой UNVERIFIED

Написаны на Linux, **ни разу не компилировались и не запускались**. Каждый начинается с комментария `UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode`.

| Файл | Назначение |
|---|---|
| `Extensions/PacketTunnel/PacketTunnelProvider.swift` | `NEPacketTunnelProvider`: старт, стоп, сторож движка, ответы на сообщения приложения |
| `Extensions/PacketTunnel/TunnelNetworkSettings.swift` | сборка `NEPacketTunnelNetworkSettings` из плана |
| `Extensions/PacketTunnel/ConfigurationSnapshotStore.swift` | снимок последнего запроса запуска в контейнере расширения |
| `Extensions/PacketTunnel/MemoryPressureMonitor.swift` | события давления памяти и `phys_footprint` |
| `Extensions/PacketTunnel/Shared/TunnelMessages.swift` | запрос запуска и конверт сообщений; общий с приложением |
| `Extensions/PacketTunnel/Info.plist` | точка расширения `com.apple.networkextension.packet-tunnel` |
| `Extensions/PacketTunnel/PacketTunnel-iOS.entitlements` | Network Extension, App Group |
| `Extensions/PacketTunnel/PacketTunnel-macOS.entitlements` | то же и песочница, вариант app extension |
| `Apps/SharedApp/NetworkPlatformApp.swift` | точка входа SwiftUI |
| `Apps/SharedApp/ContentView.swift` | экран: состояние, установка, подключение |
| `Apps/SharedApp/TunnelController.swift` | `NETunnelProviderManager`, статус, запрос к расширению |
| `Apps/SharedApp/App-iOS.entitlements`, `Apps/SharedApp/App-macOS.entitlements` | entitlements приложения |
| `Apps/project.yml` | спецификация XcodeGen: приложение и расширение для iOS и macOS |

Также не запускался `.github/workflows/ci.yml`: репозиторий не опубликован.

Что этот код **не делает**, даже если соберётся:

- **Туннель не поднимется.** В репозитории нет ни одного адаптера движка; реестр движков в расширении пуст, и запуск завершается ошибкой `core_not_registered` либо `no_configuration`. Это намеренное поведение: туннель без движка подниматься не должен.
- utun fd не ищется (R-08): движку нечего было бы читать.
- Приложение не компилирует конфигурацию и не отправляет запрос запуска.
- Нет тайм-аута на зависший старт или стоп и аварийного завершения процесса (ADR-0001 §4).
- Нет реакции на смену сети, сон и пробуждение; нет On-Demand.
- Нет экрана раскрытия данных, которого требует Guideline 5.4.
- Нет целей tvOS и visionOS, нет варианта macOS с system extension.
- Событие давления памяти только записывается: у `NetworkCore` нет способа попросить движок освободить память.

Отступления от ADR, сделанные сознательно:

- Типы сообщений лежат в `Extensions/PacketTunnel/Shared/`, а не в модуле пакета `TunnelIPC` (ADR-0004 §2.3): модуль пакета должен появляться с тестами, а этот код ещё не собирался. Перенести после первой сборки.
- Entitlements содержат App Group как минимальный набор из `PLATFORM_MATRIX.md` §7, но код группой не пользуется: по ADR-0003 связь идёт через `sendProviderMessage`, снимок лежит в контейнере расширения. Если группа так и не понадобится — убрать.
- Каталог `Cores/` создан по спецификации владельца; ADR-0004 §2.5 называет его `Engines/`. Нужно решение.

Непроверенные допущения в этих файлах (все — про поведение инструментов, которое негде было проверить):

- XcodeGen принимает локальный пакет по пути `..` и источники вне каталога спецификации.
- Комментарии XML в `.entitlements` и `Info.plist` не мешают подписи.
- `GENERATE_INFOPLIST_FILE` достаточно для приложения на обеих платформах.
- Асинхронные переопределения `startTunnel(options:)`, `stopTunnel(with:)`, `handleAppMessage(_:)` доступны в SDK в том виде, в каком написаны.

### 2.3. Замечания по чтению `Extensions/` и `Apps/` (не проверено компиляцией)

Файлы прочитаны 2026-11-24 и сверены с публичным API `Packages/CoreAbstraction` (который теперь собран). Это заметки ревью, а не результат сборки; всё про API Apple — по памяти **[U]**.

Сверка с `CoreAbstraction` — расхождений не найдено: `CoreRegistry.makeCore(_:)`, `CoreIdentifier(_:)`, `CoreLifecycle(core:)`, `start(_:options:)`, `stop()`, `statistics()`, `stateUpdates()`, `state`, `lastError`, `CoreConfiguration(coreID:format:payload:)`, `CoreStartOptions(tunnelFileDescriptor:mtu:memoryLimitBytes:)`, `CoreStatistics.traffic.uplinkBytes/downlinkBytes`, `CoreError.code`, `.description`, `.unexpectedExit(message:)`, `CoreError.normalise(_:during:)` существуют, публичны и имеют те сигнатуры, которые использует `PacketTunnelProvider.swift`. `stateUpdates()` сразу отдаёт текущее состояние, поэтому сторож, подключённый после `start`, не пропустит уже случившийся отказ.

Возможные проблемы:

1. `TunnelController.queryEngine()` — `withCheckedThrowingContinuation` вокруг `sendProviderMessage` без тайм-аута: если расширение не вызовет обработчик ответа, задача зависнет навсегда, а continuation утечёт.
2. `TunnelController.adopt(_:)` — замыкание наблюдателя захватывает `connection` (`NEVPNConnection`, не `Sendable`) внутрь `Task { @MainActor in … }`; `PacketTunnelProvider.makeWatchdog` захватывает слабый `self` провайдера в `Task`. В режиме Swift 5 это в худшем случае предупреждения, в режиме Swift 6 / strict concurrency — вероятные ошибки. В `project.yml` стоит `SWIFT_VERSION: "5.0"`.
3. `TunnelStartRequest.startOptions()` кладёт весь конфиг движка (до 8 МиБ по пределу проекта, в JSON как base64) в `startVPNTunnel(options:)`. Допустимый размер options не документирован и не измерен; ограничение `TunnelIPC.maximumMessageBytes` (64 КиБ) на этот путь не действует.
4. App Group на macOS: идентификатор `group.$(NP_BUNDLE_ID_PREFIX)` общий для iOS и macOS. На macOS исторически требовался префикс Team ID; принимает ли подпись `group.`-идентификатор для расширения в песочнице — проверять на Mac. Кодом группа не используется.
5. `PacketTunnelProvider.start` — если `lifecycle.start` бросит после `setTunnelNetworkSettings`, настройки интерфейса уже применены; рассчитано на то, что ошибка из `startTunnel` снимает туннель. Явного отката нет.
6. `MemoryPressureMonitor` — `[weak newSource]` для значения типа-протокола `DispatchSourceMemoryPressure` и арифметика `task_vm_info_data_t`/`TASK_VM_INFO` выглядят стандартно, но требуют Darwin; `import Darwin` явно не указан (ожидается через Foundation).
7. `Apps/project.yml` — цели приложения не объявляют `sdk: NetworkExtension.framework` (расчёт на автолинковку) и получают расширение только через `dependencies: - target:`; встраивание `.appex` полагается на поведение XcodeGen по умолчанию. `INFOPLIST_FILE` задан настройкой сборки, а не ключом `info:`.
8. Сигнатуры `override func startTunnel(options: [String: NSObject]?) async throws`, `stopTunnel(with:) async`, `handleAppMessage(_:) async -> Data?` и `NETunnelProviderManager.loadAllFromPreferences() async throws` совпадают с тем, что помнится о SDK, но не сверены с заголовками.

Явных ошибок в именах API SwiftUI, Foundation и NetworkExtension при чтении не найдено.

## 3. Заблокировано

| Чего нет | Что блокирует |
|---|---|
| **macOS и Xcode** | любая сборка приложения, расширения и XCFramework; эксперименты E-1…E-9 (ADR-0001 §7); снятие пометки UNVERIFIED |
| **Подпись Apple Developer** (платный аккаунт, возможность Network Extension, App Group) | установка туннеля на устройство и на Mac; TestFlight. Для публикации в App Store нужен аккаунт-организация (Guideline 5.4, R-02) |
| **Физические устройства** (iPhone, Apple TV, Vision Pro) | проверка туннеля, памяти расширения, utun fd, On-Demand; все критерии производительности |
| **Лицензия не выбрана** (ADR-0006) | публикация репозитория, приём сторонних изменений, файл `LICENSE` |

Дополнительно на хосте разработки нет Go и Swift, и ставить их туда нельзя: это небольшой боевой сервер (`CLAUDE.md`). Swift-пакет можно собирать в Docker-образе `swift:5.10` с ограничением памяти (§2.1); образ (3,5 ГБ) оставлен на хосте, свободно 5,7 ГБ. Тестового сервера для interop-тестов тоже нет.

## 4. Вопросы владельцу

1. Лицензия и связанные вопросы — ADR-0006 §6 (первые четыре блокируют публикацию).
2. Mac-сборщик, аккаунт разработчика, устройства — без них Phase 1 не продвигается дальше написания кода.
3. `Cores/` или `Engines/` как каталог движков.

## 5. Что дальше

В порядке, в котором снимаются блокировки:

1. ~~Прогнать `swift build` и `swift test`~~ — сделано на Linux (§2.1). Осталось повторить на macOS и в release, решить судьбу пометок UNVERIFIED в файлах пакета.
2. Привести `platforms` в `Package.swift` к ADR-0005.
3. На Mac: `xcodegen generate`, собрать приложение и расширение, исправить то, что не собралось, снять пометки UNVERIFIED с проверенных файлов.
4. Мост Xray и XCFramework по `Cores/BuildScripts/README.md` (E-1).
5. Поиск utun fd и первый туннель на iPhone.

## 6. Журнал

| Дата | Событие |
|---|---|
| 2026-11-24 | Phase 0: аудиты, матрицы, ADR-0001…0006. Написаны четыре модуля пакета, черновик расширения и приложения, документы репозитория. Сборок и запусков не было. |
| 2026-11-24 | Первый прогон пакета: Docker `swift:5.10` (Swift 5.10.1, Linux x86_64), `swift build -j 1` и `swift test -j 1` под лимитом 1300 МБ. Одна ошибка компиляции исправлена (`CoreLifecycle.stateUpdates`). 251 тест, 0 падений, 0 пропусков. Расширение и приложение только прочитаны (§2.3). |
