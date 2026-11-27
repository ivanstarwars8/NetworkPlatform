# CLAUDE.md — постоянный контекст для кодовых агентов

Читать этот файл и `STATUS.md` в начале каждой сессии. Весь репозиторий перечитывать не нужно.

## Что это

Открытая сетевая платформа (прокси/VPN-клиент) для iOS, iPadOS, macOS, tvOS, visionOS. Xray-core и Mihomo — сменные движки за собственным управляющим слоем на Swift (второй движок — Mihomo по ADR-0007; sing-box изучен и не интегрируется).

Состояние: Phase 1, этап 3b. Мост Xray (`Cores/Bridge`) и мост Mihomo (`Cores/MihomoBridge`, тот же C ABI) собраны и проверены на Linux. Адаптер `EngineXray` (Swift поверх C ABI, насос пакетов) проверен на Linux против поддельного моста и зарегистрирован в `XrayOnly`. Компилятор выпускает TUN-inbound/перехват DNS/исключения из `TunnelAddressing`; вывод компилятора прогнан в мосте на tun ядра Linux. Swift-пакет проходит тесты на Linux и на macOS (CI). На раннере macOS CI без подписи собраны мост (XCFramework, 10 срезов) и приложение с расширением `XrayOnly` для iOS/iPadOS, macOS, tvOS, visionOS. Ничего не подписано и не запущено на устройстве, туннель не поднимался. Точное состояние — в `STATUS.md` §2.0.

Мастер-спецификация владельца в репозиторий не добавлена. Её разделы 31–33 пересказаны ниже; остальное отражено в ADR и `ROADMAP.md`.

## Структура

```
Package.swift                 один корневой манифест (ADR-0004)
Packages/<Name>/Sources       код модуля
Packages/<Name>/Tests         тесты модуля (XCTest)
Extensions/PacketTunnel/      NEPacketTunnelProvider; Shared/ — типы, общие с приложением
Apps/SharedApp/               оболочка приложения на SwiftUI
Apps/project.yml              спецификация XcodeGen (iOS/iPadOS, macOS, tvOS, visionOS)
Apps/Configurations/          xcconfig вариантов сборки: XrayOnly, MihomoOnly, Dual; Local.xcconfig — вне git
Cores/Bridge/                 мост Xray: Go-модуль (engine/, cabi/ — C ABI v1, cmd/nplab — стенд Linux)
Cores/MihomoBridge/           мост Mihomo: Go-модуль с тем же C ABI v1 (cmd/npmlab — стенд Linux); apple/patch — правка ядра для Apple
Cores/BuildScripts/           мосты: XCFramework обоих мостов для Apple и их проверка; проверки на Linux (C ABI, netns, стенд tun, правка Apple для Mihomo)
Benchmarks/                   RoutingBench, RoutingParity (Go), BridgeBench, results/
Tests/Fixtures/               корпус ссылок, interop-конфигов и профилей; проверка настоящим Xray
Tools/                        swift-docker.sh, remote-go.sh, validate-fixtures.sh, apple-build-flavour.sh
Documentation/ADR/            решения 0001–0009, REVIEW-2026-11-25.md
Documentation/Architecture/   tun, жизненный цикл, паритет маршрутизации, адаптивный выбор
Documentation/Performance/    методика и результаты замеров
Documentation/Protocols/      форматы ссылок, справочник современных транспортов Xray
Documentation/Research/       первичные аудиты; SOURCES.txt — SHA изученных репозиториев
Documentation/Security/       модель угроз
.github/workflows/            swift-package (macOS+Linux), bridge-go и mihomo-bridge-go (Linux), apple (XCFramework, xcodebuild)
Documentation/Apple/          BUILD_ON_MAC.md, DEVICE_TEST_PLAN.md
```

Модули пакета сейчас: `DomainModels`, `CoreAbstraction`, `ConfigurationEngine` (зависит от `DomainModels`), `RoutingEngine`, `AdaptiveBalancer`, `EngineBridge` (общий для обоих мостов C ABI, драйвер жизненного цикла, насос пакетов; `EngineBridgeTestSupport` — подделки моста для тестов, без продукта), `EngineXray` и `EngineMihomo` (адаптеры: только различия движков; чистый Swift, Go не линкуют; вызовы `npb_*` — в `Extensions/PacketTunnel/BridgeBinding.swift`); исполняемая цель `RoutingBench`. Приложение `Engine*` не линкует — только расширения. `Extensions/PacketTunnel/Shared` и `TunnelSession.swift` подключены к тестам `CoreAbstraction` символическими ссылками — временно, до модулей `TunnelIPC`/`TunnelHost`. Карта будущих модулей — ADR-0004 §2.3; это карта намерений, а не список к созданию.

Расхождение, о котором надо знать: ADR-0004 §2.5 называет каталог движков `Engines/`, в репозитории создан `Cores/`. До решения не создавать второй каталог.

## Команды

```sh
Tools/swift-docker.sh swift build -j 1
Tools/swift-docker.sh swift test -j 1                              # весь пакет, ~6 мин в контейнере
Tools/swift-docker.sh swift test -j 1 --filter RoutingEngineTests   # один модуль
NP_REMOTE=<сервер> NP_KEY=<рабочее место> Tools/remote-go.sh 'cd Cores/Bridge && go vet ./... && go test ./...'
```

Заметки о сборке:

- `Package.swift`: список целей собирается по одному оператору `+=`. Одна цепочка `lib(...) + lib(...)` из шести слагаемых не проходит проверку типов Swift 5.10 за отведённое время — не возвращать.
- Не-Swift-файлы внутри каталога цели исключать в манифесте (`exclude:`), иначе SwiftPM предупреждает.
- Go-мост собирается только на сервере разработки через `Tools/remote-go.sh` (синхронизирует рабочую копию, общий lock, свои Go-кэши); Go-версия берётся из `go.mod` (`GOTOOLCHAIN=auto`). Тесты с сетью — только на 127.0.0.1 или в отдельном netns; созданные процессы и namespace удалять.
- Мост Mihomo: `go test -race ./engine` падает на гонках внутри ядра Mihomo — `TestProtocolsOverLoopback/VLESS+REALITY+Vision` (Vision ядра) и `TestStartStopCycles` (`log.SetLevel` против `log.print`); на CI (`mihomo-bridge-go.yml`) — шаг «KNOWN FAILURE check», который требует, чтобы самый внутренний кадр каждого конфликтующего доступа был в `github.com/metacubex/mihomo`. Интеграционные тесты моста Mihomo используют штатный xray, собранный из ядра, закреплённого `Cores/Bridge/go.mod`. Mihomo-клиенту REALITY против Xray 26.11.9 нужен `support-x25519mlkem768: true`.
- Ядро Mihomo оставляет IPv6-адрес tun, только если у хоста есть глобальный IPv6 (`verifyIP6`); у раннеров GitHub его нет — тесты не должны от этого зависеть.
- Правка Apple для Mihomo — через `-modfile` (`Cores/BuildScripts/mihomo-apple-patch.sh`): `go -overlay` в GOMODCACHE запрещён.
- Память: профиль `mobile` (`memory.profile` обоих мостов, `XrayMemoryProfile.mobile` компилятора) — см. `Documentation/Performance/memory-budget.md` (§10 — Mihomo). Адаптер передаёт мосту только `memory:{"profile":"mobile"}`; числа профиля живут только в Go-константах `Mobile*` — не дублировать их в Swift. Mihomo: тайм-аут UDP-сессий ядра конфигурацией не задаётся (`tun.udp-timeout` стек mips игнорирует) — простой закрывает обходчик моста `engine/idle.go`; не писать в переменные ядра через `go:linkname` (гонка). `TestSoakRSS` моста Mihomo — функциональный прогон, не цифра памяти моста: мерить через `ENGINE=mihomo` в `bridge-tunlab.sh` (`npmlab`). Совет «предел 24–32 МиБ» опровергнут замером: предел ниже живого набора гоняет GC непрерывно. Лимит памяти расширения iOS (~50 МиБ [U]) повысить нельзя: entitlement increased-memory-limit на app extensions не действует.
- Адреса туннеля (198.18.0.1/30, fd66:6e70::1/126, резолверы, MTU, локальные диапазоны) — только в `DomainModels/TunnelAddressing.swift`; компилятор, план сети и стенд берут их оттуда. Экспорт вывода компилятора для стенда: тесты `testExportCompiledTunnelConfiguration`/`testExportPacketTunnelBridgeOptions` с `NP_EXPORT_DIR` → `bridge-tunlab.sh compiled DIR`.
- Сообщения об ошибках моста Xray и отчёты компилятора проходят вырезание значений конфигурации (`engine/redact.go`, `ConfigValueRedactor`); новые пути ошибок пропускать через них.
- `go test -race ./engine` моста Xray со штатным xray (`NP_STOCK_XRAY`) сейчас падает в `TestFlowThroughProxyWithDNS` (на CI — и в `TestProtocolsOverLoopback/VLESS+REALITY+Vision`) из-за гонки Vision внутри ядра; на CI это отдельный шаг «KNOWN FAILURE check»; через `NP_TEST_FLOW_PROXY=Trojan+TLS` тест проходит. Это известный провал, не скрывать его.

Приложение и расширение: только на Mac или на CI (`Documentation/Apple/BUILD_ON_MAC.md`): `Cores/BuildScripts/bridge-apple-xcframework.sh`, затем `cd Apps && xcodegen generate`, затем `xcodebuild … -configuration Debug-XrayOnly`. С этого хоста код под Apple проверяется только через CI: коммит в `main` → `gh run watch` / `gh run view --log-failed`. Задания с фильтрами путей, лишние прогоны отменяются группой concurrency.

- Расширения — по движку (`PacketTunnelXray_<p>`, `PacketTunnelMihomo_<p>`), приложения — по варианту (`AppXrayOnly_<p>`, `AppMihomoOnly_<p>`, `AppDual_<p>`), схемы `NetworkPlatform-<вариант>-<платформа>` (ADR-0009). Фаза «Flavour guard» проверяет соответствие цели и конфигурации; не выключать её. Расширение компилируется с одним условием движка (`NP_ENGINE_CONDITIONS`), даже в `Dual`. Сборка и проверки продукта (встроенные расширения, «своё ядро — да, чужое — нет», в приложении Go нет) — `Tools/apple-build-flavour.sh`.
- Мост Mihomo под Apple: `NP_BRIDGE_ENGINE=mihomo Cores/BuildScripts/bridge-apple-xcframework.sh` (всегда с правкой Apple: без `proc_pidinfo` и без системных вызовов `SYS_RECVMSG_X`/`SYS_SENDMSG_X` sing-tun); `bridge-apple-verify.sh` — платформы объектов и закрытые символы.
- Неподписанная сборка CI — не работающий туннель и не проверенные entitlements. Linux-результат не выдавать за Apple-результат.

## Ограничения этого хоста

Разработка сейчас идёт на небольшом **боевом** Linux-сервере (2 vCPU, около 1 ГБ свободной памяти, около 9 ГБ диска). На нём нет macOS, Xcode, Go и Swift.

- Не устанавливать тулчейны на хост.
- Не собирать Go-ядра.
- Не запускать сетевые листенеры.
- Не трогать ничего вне каталога репозитория и своего временного каталога.
- Не клонировать репозитории крупнее примерно 50 МБ.
- Клоны референсов лежат в `/root/.cache/np-research/` и используются только для чтения.

Следствие: Swift-пакет собирается и тестируется здесь только в контейнере `swift:5.10` с лимитами (`docker run --rm --network none --memory=1300m --memory-swap=1300m --cpus=1.5 -v $PWD:/work -w /work swift:5.10 swift test -j 1`). Всё, что требует Xcode (`Apps/`, `Extensions/`), и Go-движки здесь собрать нельзя — этот код непроверенный, пока его не собрали на Mac. Для Go-моста есть отдельный сервер разработки (Go установлен); его адрес в репозиторий не записывается.

## Правила работы (спецификация, §31)

- Работать самостоятельно; обратимые архитектурные решения принимать самому и записывать в ADR.
- Обращаться к владельцу только при: необратимых изменениях; денежных расходах; доступе к секретам; существенном юридическом или лицензионном риске; публикации приложения; удалении важных данных; отсутствии обязательных технических ресурсов.
- До изменения существующего кода изучить его структуру и состояние.
- Не удалять рабочие реализации без необходимости.
- Не создавать заглушки, выдаваемые за рабочие функции.
- Не скрывать ошибки сборки и тестов.
- Не отмечать задачу завершённой, если она не проверена.

## Экономия контекста (спецификация, §32)

- `CLAUDE.md` и `STATUS.md` — постоянный источник контекста. `STATUS.md` обновлять после каждого значимого этапа.
- Результаты исследований хранить в `Documentation/`. Выполненные исследования не повторять: сначала прочитать `RESEARCH.md`.
- Длинные логи не выводить в чат: полный лог — в файл (`Logs/` исключён из git), в отчёте — существенное.
- В отчёте указывать: что сделано; какие файлы изменены; какие тесты пройдены; какие проблемы остались; какие решения приняты; что дальше.

## Definition of Done (спецификация, §33)

Функция завершена, только если она:

1. реализована без фиктивных заглушек;
2. проходит сборку;
3. имеет необходимые тесты;
4. проверена в реальном сценарии;
5. не ухудшает критические показатели производительности без обоснования;
6. не нарушает безопасность;
7. документирована;
8. имеет описанные известные ограничения;
9. соответствует возможностям целевой платформы.

На этом хосте пункты 2 и 4 невыполнимы. Поэтому здесь ничего не получает статус «готово» — только «написано, не проверено» в `STATUS.md`.

## Правила, вытекающие из ADR

- **Один движок на процесс расширения. Приложение не линкует Go** (ADR-0001). Модули, которые линкует приложение, не зависят от адаптеров движков.
- **Типы движков не поднимаются выше адаптера**: никаких `Libbox*`, имён полей JSON движка, конверта `Invoke` в общих модулях (ADR-0001 §5).
- **Конфиг движка — результат компиляции модели**; каждая компиляция и каждый импорт возвращают отчёт; потери не бывают молчаливыми (ADR-0002).
- **Swift не разбирает пакеты.** Для Xray расширение передаёт пакеты пачками между `NEPacketTunnelFlow` и мостом, не разбирая их (ADR-0001 §4.1; формулировка ADR-0003 §2 «пакеты не проходят через Swift» устарела и ждёт правки). Приложение и расширение общаются через `sendProviderMessage`; сетевые сокеты для этого не используются (ADR-0003). Запрос запуска передаётся файлом в App Group (ADR-0008; ADR-0003 частично заменён).
- **Секреты** — в Keychain; расширение их оттуда не читает, а получает в составе конфига. Конфиг, ключи и адреса серверов не пишутся в журнал (ADR-0003 §4).
- **Модуль появляется вместе с кодом и тестом.** Пустых модулей, каталогов и файлов-заполнителей нет. Манифест перечисляет только существующие модули (ADR-0004).
- **XCFramework и собранные бинарники в git не хранятся** (ADR-0004 §2.4).
- **Минимумы ОС**: iOS/iPadOS 17.0, macOS 14.0, tvOS 17.0, visionOS 1.0 (ADR-0005).

## Лицензионные правила до решения владельца (ADR-0006 §5)

- Код из sing-box, sing-box-for-apple, OneXray, Karing не копировать — ни фрагментами, ни «близко к тексту». Идеи и форматы реализовывать заново.
- Код hiddify-app и hiddify-core не копировать и не линковать.
- Заимствовать можно из libXray и WireGuardKit (оба MIT), с записью в `THIRD_PARTY_NOTICES.md`.
- Код, обращающийся к libbox, — только в будущем модуле `EngineSingBox` (sing-box не интегрируется, ADR-0007).
- Mihomo — GPL-3.0: сборки с ним считаются GPL целиком, `XrayOnly` остаётся без GPL (ADR-0007).
- Файл `LICENSE` не добавлять.
- Имена «sing-box», «Xray», «Hiddify», «Karing» не использовать в названии продукта, идентификаторах бандлов и текстах для стора.
- Новая зависимость — только с проверенной лицензией.

## Соглашения

- Документы — на русском. Код, идентификаторы, комментарии в коде — на английском.
- Каждое утверждение в исследованиях помечено: **[V]** — видно в исходнике или официальном документе, путь указан; **[U]** — по памяти, из вторичного источника или не подтверждено сборкой; **[C]** — пост инженера Apple на форуме. Не выдумывать номера версий, лимиты и имена API.
- README не источник: читать `go.mod`, скрипты сборки, entitlements, `LICENSE`.
- Файл, написанный без компиляции, начинается с комментария `UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode` и перечислен в `STATUS.md`. После компиляции на CI пометка заменяется на `compiled on macOS CI, never run` со ссылкой на прогон. Слово «проверено» — только после запуска.
- Ограничения, введённые проектом (размер сообщения, размер конфигурации), в коде названы ограничениями проекта, а не платформы.
- `git commit` выполняется по указанию владельца или оркестратора.

## Где что искать

| Вопрос | Документ |
|---|---|
| Что известно о движках и что не проверено | `RESEARCH.md` §2 и §4 |
| sing-box, libbox | `Documentation/Research/singbox.md` |
| Xray-core, libXray, OneXray | `Documentation/Research/xray.md` |
| Karing, hiddify | `Documentation/Research/reference-apps.md` |
| Ограничения платформ Apple, entitlements, правила ревью | `PLATFORM_MATRIX.md` |
| Протоколы и транспорты по движкам | `PROTOCOL_MATRIX.md` |
| Лицензии | `LICENSE_AUDIT.md`, ADR-0006 |
| Риски | `TECHNICAL_RISKS.md` |
| Что надо доказать на Mac | ADR-0001 §7 (E-1…E-9), ADR-0003 §7 |
| Сборка движков, мост Xray | `Cores/BuildScripts/README.md`, `Cores/Bridge/README.md` |
| Путь пакетов, utun | `Documentation/Architecture/tun-integration.md` |
| Ключи JSON и версии Xray | `Documentation/Protocols/xray-modern.md` |
| Второй движок | ADR-0007, `Documentation/Research/mihomo-leaf.md`, `Cores/MihomoBridge/README.md`, `Documentation/Architecture/mihomo-config.md` |
| Память расширения, профиль `mobile` | `Documentation/Performance/memory-budget.md` |
| Адреса туннеля, TUN-inbound, перехват DNS | `Documentation/Architecture/tun-integration.md` §11, `TunnelAddressing.swift` |
| Угрозы | `Documentation/Security/THREAT_MODEL.md` |
