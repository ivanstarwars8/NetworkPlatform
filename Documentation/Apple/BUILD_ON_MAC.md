# Сборка на Mac: от чистого клона до подписанной сборки на устройстве

Дата: 2026-11-27.

Что проверено. Шаги 1–4 и 6 (без подписи) выполняет CI на раннере macOS: `.github/workflows/apple.yml` и `swift-package.yml`, ссылки на прогоны — в `STATUS.md`. Подписанная сборка, установка на устройство и запуск туннеля **не выполнялись ни разу**: у проекта нет учётной записи разработчика и устройства. Шаг 5 и всё после него помечены [U].

Подписанная сборка не даёт работающего туннеля. Адаптера движка в расширении нет, поэтому любой старт заканчивается отказом `core_not_registered`. Что можно проверить сейчас, сказано в `DEVICE_TEST_PLAN.md` §1.

## 1. Инструменты

| Что | Версия, с которой собирает CI | Как поставить |
|---|---|---|
| macOS | 15 (раннер `macos-15`) | — |
| Xcode | 16.4 (16F6), SDK iOS 18.5, macOS 15.5, tvOS 18.5, visionOS 2.5 | App Store или developer.apple.com. Платформы tvOS и visionOS доставить в Xcode → Settings → Components |
| Go | 1.27.4 (`toolchain` в `Cores/Bridge/go.mod`) | `brew install go`. Более старый Go сам скачает нужную версию (`GOTOOLCHAIN=auto` по умолчанию) |
| XcodeGen | 2.44.1 | `brew install xcodegen` |

```sh
xcode-select -p                      # должен указывать на Xcode.app, не на CommandLineTools
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -version
xcodebuild -showsdks | grep -E 'iphoneos|macosx|appletvos|xros'
go version
xcodegen --version
```

## 2. Клон и Swift-пакет

```sh
git clone https://github.com/ivanstarwars8/NetworkPlatform.git
cd NetworkPlatform
swift build --build-tests
swift test --skip-build              # на CI: 477 тестов, 0 падений
```

## 3. Мост Xray для Apple (XCFramework)

```sh
Cores/BuildScripts/bridge-apple-xcframework.sh
```

Скрипт собирает 10 срезов C-архива (`go build -buildmode=c-archive ./cabi`), склеивает архитектуры через `lipo` и пакует всё в `Cores/Bridge/build/apple/NPXrayBridge.xcframework` (каталог не в git). Отчёт по срезам — `Cores/Bridge/build/apple/build.tsv`, версии инструментов — `versions.txt`. На раннере CI (`macos-15`, arm64) все 10 срезов собираются примерно за 3,5 мин, без учёта загрузки модулей. Каждый срез весит 37–40 МБ.

Если нужны только срезы для своей машины и устройства:

```sh
NP_REQUIRED_SLICES="ios-arm64 macos-arm64" \
  Cores/BuildScripts/bridge-apple-xcframework.sh ios-arm64 ios-simulator-arm64 macos-arm64
```

Имена срезов: `ios-arm64`, `ios-simulator-arm64`, `ios-simulator-x86_64`, `macos-arm64`, `macos-x86_64`, `tvos-arm64`, `tvos-simulator-arm64`, `tvos-simulator-x86_64`, `xros-arm64`, `xros-simulator-arm64`.

Проверка моста на самом Mac. Это тот же тест C ABI, что CI выполняет на arm64:

```sh
d=Cores/Bridge/build/apple/slices/macos-arm64
clang -O2 -Wall -I"$d" -o /tmp/abi_test Cores/Bridge/cabi/ctest/abi_test.c "$d/libnpbridge.a" \
  -lresolv -framework CoreFoundation -framework Security
/tmp/abi_test                        # последняя строка: C ABI TEST PASSED
```

## 4. Проект Xcode

```sh
cd Apps
xcodegen generate                    # создаёт Apps/NetworkPlatform.xcodeproj (не в git)
open NetworkPlatform.xcodeproj
```

Схемы: `NetworkPlatform-iOS` (iPhone и iPad, одна цель), `NetworkPlatform-macOS`, `NetworkPlatform-tvOS`, `NetworkPlatform-visionOS`.

Конфигурации — это вариант сборки × Debug/Release: `Debug-XrayOnly`, `Release-XrayOnly`, `Debug-MihomoOnly`, `Release-MihomoOnly`, `Debug-Dual`, `Release-Dual`.

Собирается **только `XrayOnly`**. `MihomoOnly` и `Dual` объявлены, но фаза «Flavour guard» расширения останавливает их сообщением `flavour … is declared but not buildable yet`. Моста Mihomo и второго расширения нет (ADR-0007).

После каждого изменения `project.yml` или после добавления файлов повторять `xcodegen generate`.

## 5. Подпись [U]

Нужна платная учётная запись Apple Developer: Network Extension на бесплатной учётной записи недоступен [U].

5.1. Создать `Apps/Configurations/Local.xcconfig` (в `.gitignore`, не коммитить):

```
NP_BUNDLE_ID_PREFIX = com.<ваш-домен>.networkplatform
DEVELOPMENT_TEAM = <TEAMID из developer.apple.com → Membership>
```

5.2. Идентификаторы, которые должны существовать в учётной записи. Автоматическая подпись Xcode создаёт их сама при `-allowProvisioningUpdates` или по кнопке в Signing & Capabilities [U]:

| Что | Значение |
|---|---|
| App ID приложения | `$(NP_BUNDLE_ID_PREFIX)`, capabilities: Network Extensions, App Groups |
| App ID расширения | `$(NP_BUNDLE_ID_PREFIX).PacketTunnel`, те же capabilities |
| App Group для iOS, tvOS, visionOS | `group.$(NP_BUNDLE_ID_PREFIX)` |
| App Group для macOS | `<TEAMID>.$(NP_BUNDLE_ID_PREFIX)` (`$(TeamIdentifierPrefix)` в `project.yml`) |

Права перечислены в `Apps/SharedApp/App-*.entitlements` и `Extensions/PacketTunnel/PacketTunnel-*.entitlements`: `packet-tunnel-provider`, группа приложений, на macOS — песочница. В неподписанных сборках CI эти файлы не применялись.

5.3. Устройство: подключить iPhone кабелем, «Доверять этому компьютеру», включить Developer Mode (Настройки → Конфиденциальность и безопасность → Режим разработчика, перезагрузка).

```sh
xcrun devicectl list devices         # UDID устройства
```

## 6. Сборка

Без подписи. Это ровно то, что делает CI, и так проверяется, что всё компилируется:

```sh
xcodebuild -project Apps/NetworkPlatform.xcodeproj -scheme NetworkPlatform-iOS \
  -configuration Debug-XrayOnly -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
```

Для других платформ заменить схему и `-destination`: `generic/platform=iOS Simulator`, `generic/platform=macOS`, `generic/platform=tvOS`, `generic/platform=visionOS`.

Подписанная сборка для устройства [U]:

```sh
xcodebuild -project Apps/NetworkPlatform.xcodeproj -scheme NetworkPlatform-iOS \
  -configuration Debug-XrayOnly -destination "id=<UDID>" \
  -derivedDataPath build/dd -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> \
  build/dd/Build/Products/Debug-XrayOnly-iphoneos/NetworkPlatform.app
```

Без `Local.xcconfig` те же значения передаются в командной строке: `DEVELOPMENT_TEAM=<TEAMID> NP_BUNDLE_ID_PREFIX=com.<…>.networkplatform`.

То же из Xcode: схема `NetworkPlatform-iOS`, Product → Scheme → Edit Scheme → Run → Build Configuration `Debug-XrayOnly`, выбрать устройство, Run.

Проверка подписи после сборки [U]:

```sh
app=build/dd/Build/Products/Debug-XrayOnly-iphoneos/NetworkPlatform.app
codesign -dv --verbose=2 "$app/PlugIns/PacketTunnel.appex"
codesign -d --entitlements :- "$app/PlugIns/PacketTunnel.appex"   # packet-tunnel-provider, group.<id>
```

macOS [U]. Схема `NetworkPlatform-macOS`, `-destination 'platform=macOS'`. Приложение запускать из `/Applications`: расширения Network Extension система загружает из приложения в стандартном месте [U]. Вариант с системным расширением (Developer ID) в проекте не описан (ADR-0005 §3).

## 7. Что смотреть после установки

Журнал расширения: Console.app, устройство, фильтр `subsystem:<NP_BUNDLE_ID_PREFIX>.PacketTunnel`. При нажатии Connect ожидаются две строки:

- `xray bridge linked, abi 1, {"code":0,"data":{"abi":1,"core":"26.11.9","go":"go1.27.4"}}`
- `start failed: …` — ожидаемый отказ, движка нет.

Дальше — `DEVICE_TEST_PLAN.md`.

## 8. Известное

- В Debug Xcode 16 кладёт код расширения в `PacketTunnel.debug.dylib` рядом с маленьким исполняемым файлом (`ENABLE_DEBUG_DYLIB`). Символы `npb_*` моста лежат там же. В Release — в самом `PacketTunnel`. В Release компоновщик выбрасывает функции моста, которые Swift не вызывает.
- Размер: расширение в Release около 32 МБ (arm64, iOS, CI). Почти весь объём — Go-рантайм и Xray-core.
- Срезы tvOS и visionOS собраны штатным портом Go `GOOS=ios`; платформу задаёт `clang -target`. Собраны и слинкованы, но Go-рантайм на этих системах **не запускался**.
- `SWIFT_STRICT_CONCURRENCY=complete`: на CI 0 предупреждений в исходниках `Apps/` и `Extensions/`.
