# Сборка движков: намеченная процедура

Дата: 2026-11-24.

**В этом каталоге нет скриптов.** Ни одна команда ниже нами не выполнялась: на хосте разработки нет macOS, Xcode и Go. Документ описывает, что предстоит сделать на Mac и что должно быть доказано раньше, чем появится первый скрипт. Скрипт добавляется сюда только после того, как он отработал, вместе с журналом сборки.

Пометки: **[V]** — видно в исходнике (путь указан, SHA — в `Documentation/Research/SOURCES.txt`); **[U]** — не проверено.

О пути: спецификация владельца называет каталог `Cores/`, ADR-0004 §2.5 — `Engines/XrayBridge/` и `Engines/SingBox/`. Расхождение не разрешено (`STATUS.md`).

## 1. Что собираем первым и почему

Первым — **мост Xray как C-архив в XCFramework** (ADR-0001 §4 и §6): нет GPL-кода, не нужен форк gomobile, есть путь к tvOS.

Мост — собственный Go-модуль, которого ещё нет. libXray зависимостью не берётся (ADR-0001 §4): в его API нет потоков статистики и журнала, настройки памяти зашиты и не откатываются [V: `libXray/invoke_model.go`, `libXray/memory/memory_ios.go`]. Образец процедуры сборки — `libXray/build/app/apple_go.py` [V]; лицензия libXray — MIT, заимствование допустимо с записью в `THIRD_PARTY_NOTICES.md`.

## 2. Что должно быть доказано до написания скриптов

| № | Что | Почему раньше всего | Связь |
|---|---|---|---|
| P-1 | Версия Go закреплена и доступна на сборщике | `go.mod` Xray-core объявляет `go 1.27` [V: `Xray-core/go.mod`]; libXray — `go 1.27.3` [V]. Какая минимальная macOS и iOS нужна бинарникам этой версии Go — неизвестно [U] | E-8, R-20 |
| P-2 | Закреплён коммит Xray-core | HEAD клона (`e17392a`) и коммит, закреплённый libXray (`676eaf66f8f0`), — разные; разницу никто не смотрел [U] | `RESEARCH.md` §1 |
| P-3 | Пустой мост (один экспорт, возвращающий версию ядра) собирается под `iphoneos/arm64` и линкуется в расширение | отделяет проблемы тулчейна от проблем моста | E-1 |
| P-4 | Расширение с этим архивом проходит подпись и запускается на iPhone | размер и требования линковки неизвестны [U] | R-21 |
| P-5 | utun fd находится перебором дескрипторов на устройстве | без fd движку нечего читать; ядро берёт его из окружения по ключу `xray.tun.fd` [V: `Xray-core/common/platform/platform.go`, `Xray-core/proxy/tun/tun_darwin.go`] | E-5, R-08 |
| P-6 | Измерен `phys_footprint` расширения с запущенным ядром | лимит не документирован; параметры GC должен задавать мост | E-4, R-03 |
| P-7 | Отчёт по лицензиям транзитивных модулей под фактические `GOOS` и теги | одна GPL-зависимость разрушает вывод о составе Xray-сборки | R-18 |
| P-8 | Go собирает под SDK visionOS | в скриптах libXray целей `xros` нет [V]; поддержка в Go не проверялась [U] | E-6, R-06 |

P-1…P-5 — условия первого туннеля. P-8 не блокирует остальные платформы.

## 3. Требования к сборщику

- Mac с Xcode и SDK: `iphoneos`, `iphonesimulator`, `macosx`, `appletvos`, `appletvsimulator`. Для App Store нужен Xcode 26 с SDK 26 (`PLATFORM_MATRIX.md` §10.6).
- Go закреплённой версии (P-1). Для sing-box позже понадобится **другая** версия Go — та, которой собирает upstream; обе стоят рядом (ADR-0001 §6).
- `gomobile` для моста Xray не нужен.

## 4. Процедура для моста Xray

Повторяет `libXray/build/app/apple_go.py` [V] с нашими минимальными версиями ОС (ADR-0005) и нашим пакетом вместо `./cgo_bridge`.

### 4.1. Срезы

| Срез | `GOOS` | `GOARCH` | SDK | `-arch` | Минимум у libXray [V] | Наш минимум (ADR-0005) |
|---|---|---|---|---|---|---|
| iOS, устройство | `ios` | `arm64` | `iphoneos` | `arm64` | 15.0 | 17.0 |
| iOS, симулятор | `ios` | `amd64` | `iphonesimulator` | `x86_64` | 15.0 | 17.0 |
| iOS, симулятор | `ios` | `arm64` | `iphonesimulator` | `arm64` | 15.0 | 17.0 |
| macOS | `darwin` | `amd64` | `macosx` | `x86_64` | 12.0 | 14.0 |
| macOS | `darwin` | `arm64` | `macosx` | `arm64` | 12.0 | 14.0 |
| tvOS, устройство | `ios` | `arm64` | `appletvos` | `arm64` | 17.0 | 17.0 |
| tvOS, симулятор | `ios` | `amd64` | `appletvsimulator` | `x86_64` | 17.0 | 17.0 |
| tvOS, симулятор | `ios` | `arm64` | `appletvsimulator` | `arm64` | 17.0 | 17.0 |

tvOS собирается с `GOOS=ios` и SDK tvOS [V]. Следствие: код под `//go:build ios` выполняется и на tvOS.

Нужны ли срезы `x86_64` для симуляторов и macOS — решить по тому, на чём идёт разработка и что поддерживаем; ADR этого не фиксирует.

### 4.2. Сборка одного среза

Окружение, которое выставляет скрипт libXray [V]:

```sh
SDK=iphoneos ARCH=arm64 MIN=17.0              # значения среза
SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
FLAGS="-isysroot $SDK_PATH -m${SDK}-version-min=$MIN -arch $ARCH"

export GOOS=ios GOARCH=arm64
export GOFLAGS="-tags=$GOOS"
export CGO_ENABLED=1
export CC="xcrun --sdk $SDK --toolchain $SDK clang"
export CXX="xcrun --sdk $SDK --toolchain $SDK clang++"
export CGO_CFLAGS="$FLAGS" CGO_CXXFLAGS="$FLAGS"
export CGO_LDFLAGS="$FLAGS -Wl,-Bsymbolic-functions"
export DARWIN_SDK="$SDK"

go build -trimpath -ldflags "-s -w -buildid=" \
  -buildmode=c-archive -o "out/$SDK-$ARCH/libBridge.a" ./<пакет моста>
```

Это запись того, что делает чужой скрипт, а не проверенная нами команда. Имя `libBridge.a` и путь пакета — условные: модуля моста ещё нет.

`go build -buildmode=c-archive` кладёт рядом с архивом C-заголовок с экспортированными функциями [V: скрипт libXray копирует `libXray.h` из каталога среза].

Чего в процедуре libXray делать **не** будем:

- `go get xray-core@<версия>` и `go mod tidy` при каждой сборке [V: `Documentation/Research/xray.md` §3.3]. У нас версии закреплены в `go.mod` и `go.sum` моста, сборка идёт с `-mod=readonly` или из вендоренного дерева.
- Go версии `stable` и libXray с ветки `main`, как в CI OneXray [V: `Documentation/Research/xray.md` §4.4].

### 4.3. Объединение архитектур

Срезы одной платформы с разными архитектурами объединяются `lipo` [V]:

```sh
lipo -create \
  -arch x86_64 out/iphonesimulator-x86_64/libBridge.a \
  -arch arm64  out/iphonesimulator-arm64/libBridge.a \
  -output out/iphonesimulator-x86_64-arm64/libBridge.a
```

То же для `macosx` и `appletvsimulator`. Срезы устройств (`iphoneos`, `appletvos`) остаются как есть.

### 4.4. Заголовки и карта модуля

Каталог `include/` с заголовком, который сгенерировал `go build`, и `module.modulemap`. У libXray карта такая [V: `libXray/build/template/module.modulemap`]:

```
module LibXray {
  umbrella header "libXray.h"
  export *
  module * { export * }
}
```

Наша будет называть свой модуль и свой заголовок.

### 4.5. XCFramework

```sh
xcodebuild -create-xcframework \
  -library out/iphoneos-arm64/libBridge.a               -headers out/include \
  -library out/iphonesimulator-x86_64-arm64/libBridge.a -headers out/include \
  -library out/macosx-x86_64-arm64/libBridge.a          -headers out/include \
  -library out/appletvos-arm64/libBridge.a              -headers out/include \
  -library out/appletvsimulator-x86_64-arm64/libBridge.a -headers out/include \
  -output XrayBridge.xcframework
```

Состав аргументов — как у libXray [V]. XCFramework в git не добавляется (`.gitignore`, ADR-0004 §2.4); в пакет подключается как `binaryTarget`, условно — только если артефакт есть на диске. Работает ли условное подключение в Xcode — не проверено (ADR-0004 §4).

### 4.6. Что записывает каждая сборка

- SHA Xray-core, версию Go, версию Xcode и SDK;
- контрольные суммы архивов и XCFramework;
- размеры срезов (R-21);
- отчёт по лицензиям Go-модулей (P-7);
- полный журнал — в файл, не в чат.

Сборка считается воспроизводимой, когда две независимые сборки из одного набора дают совпадающие контрольные суммы либо причины расхождения задокументированы (R-19).

## 5. Что должен уметь мост

Из ADR-0001 §4; C ABI ещё не спроектирован, имён функций нет.

- запуск с конфигом и utun fd; fd мост сам кладёт в окружение под `xray.tun.fd`, JSON ради этого не правится;
- остановка;
- состояние;
- снимок статистики;
- колбэк журнала;
- параметры памяти (GC, мягкий лимит) — от хоста, а не зашитые.

Ограничение ядра: один экземпляр на процесс [V: `Documentation/Research/xray.md` §3.2].

Разбор ссылок в мост не переносится: импорт делает Swift (R-12).

## 6. sing-box (libbox) — позже, Phase 5

Собирается только цепочкой upstream, без собственных изобретений (R-07). Что известно по исходникам [V: `Documentation/Research/singbox.md` §1–2]:

- сборку выполняет `cmd/internal/build_libbox/main.go` (`make lib_apple`), команда — `gomobile bind` с целями `ios,iossimulator,tvos,tvossimulator,macos`;
- нужен форк `github.com/sagernet/gomobile`; версии в `go.mod` (v0.1.12) и в `make lib_install` (v0.1.13) расходятся;
- обязательны `-ldflags` с `-checklinkname=0` и `-X runtime.godebugDefault=multipathtcp=0,tlssha1=1`, теги `badlinkname`, `tfogo_checklinkname0`;
- CI upstream перед срезами iOS и tvOS применяет патч к `GOROOT/src/internal/cpu`;
- `go.mod` объявляет `go 1.25.5`, CI собирает на 1.26.10.

До сборки должно быть решено: какую линию закрепляем (аудит сделан по альфа-ветке 1.15, сведения о стабильной версии расходятся — `RESEARCH.md` §3, п. 5); сокращённый набор тегов (ADR-0001 §4); и — владельцем — будет ли сборка с sing-box вообще распространяться и где (ADR-0006 §6, вопрос 5).

## 7. Чего здесь не будет

- Сборки обоих ядер в один бинарник и двух Go-фреймворков в одном процессе: отклонено ADR-0001.
- Скачивания готовых бинарников ядер.
- Скриптов, которые не запускались.
