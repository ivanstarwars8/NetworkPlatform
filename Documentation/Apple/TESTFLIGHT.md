# TestFlight: подписанная сборка «Бык» для внутреннего тестирования

Дата: 2026-11-27.

Что проверено [V]: прогон `testflight.yml` [46055561063](https://github.com/ivanstarwars8/NetworkPlatform/actions/runs/46055561063) собрал `XrayOnly` для iOS/iPadOS (Xcode 26.3, iOS 26.2 SDK), подписал приложение и расширение дистрибутивным сертификатом команды, `altool --validate-app` и `--upload-app` прошли, сборка 0.1.0 (409) в App Store Connect дошла до `processingState = VALID`, внутренняя группа «oz» получает все сборки автоматически (`hasAccessToAllBuilds = true`).

Сборки: **0.1.0 (409)** — прогон 46055561063, коммит `4925dcc`, оболочка без импорта профилей; **0.1.0 (410)** — прогон [46060225098](https://github.com/ivanstarwars8/NetworkPlatform/actions/runs/46060225098), коммит `a83c593`, с путём тестировщика (импорт ссылки/подписки, профили, Connect, диагностика) и исправленным выбором расширения (`NPXrayExtensionBundleIdentifier` в Info.plist приложения = `com.gbnconnect.app.tun`, проверяется `verify-ipa.sh`). Обе `VALID`, обе без ответа об экспортном контроле. Номера 405–408 сожжены при отладке и не загружались.

Что не проверено: установка из TestFlight и запуск туннеля на устройстве. Сборка не даёт работающего туннеля (см. `BUILD_ON_MAC.md`, `DEVICE_TEST_PLAN.md`).

## 1. Что и куда

| | |
|---|---|
| Запись App Store Connect | «Бык VPS», app id 6833782634 |
| Приложение | `com.gbnconnect.app`, имя на экране «Бык», iPhone + iPad (`TARGETED_DEVICE_FAMILY = 1,2`) |
| Расширения | `PacketTunnelXray.appex` — `com.gbnconnect.app.tun`; `PacketTunnelMihomo.appex` — `com.gbnconnect.app.mihomo` (с ветки `byk/dual`); оба `packet-tunnel-provider` |
| App Group | `group.com.gbnconnect.app` |
| Вариант сборки | параметр `flavour`: `Dual` (по умолчанию) — `Release-Dual`, схема `NetworkPlatform-Dual-iOS` (оба движка; сборка целиком GPL-3.0, ADR-0007); `XrayOnly` — `Release-XrayOnly`, только расширение Xray: идентификатор, профиль и мост Mihomo не нужны. `Dual` ждёт ручного шага в портале (App Group для `com.gbnconnect.app.mihomo`, §6), до него загружается `XrayOnly`. Сборки 409 и 410 были `XrayOnly` |
| Номер сборки | `CFBundleVersion = 404 + GITHUB_RUN_NUMBER` (растёт с каждым запуском; 401–403 в записи — чужие сборки, их не трогать) |
| Версия | `CFBundleShortVersionString` — параметр запуска `marketing_version` (по умолчанию 0.1.0) |
| Куда | только внутреннее тестирование TestFlight: экспорт с `testFlightInternalTestingOnly = true`, группа «oz» |

Чего конвейер не делает никогда: отправка на ревью, внешние тестировщики и группы, метаданные, цены, страница в сторе, ответ на вопрос об экспортном контроле.

## 2. Идентичность «Byk» без изменения неподписанных сборок

`Apps/Configurations/Byk.xcconfig` — не конфигурация сборки, а наложение: `xcodebuild -xcconfig Apps/Configurations/Byk.xcconfig` поверх `Release-Dual`. Оно задаёт `NP_BUNDLE_ID_PREFIX`, `NP_XRAY_EXTENSION_BUNDLE_ID`, `NP_MIHOMO_EXTENSION_BUNDLE_ID`, `NP_APP_GROUP`, `NP_DISPLAY_NAME`, имя иконки и ориентации iPad. Значения по умолчанию этих переменных (`Base.xcconfig`) дают прежние идентификаторы `org.example.networkplatform.*`, поэтому `apple.yml` и `Tools/apple-build-flavour.sh` собирают то же, что раньше (прогон 46053730842 зелёный).

Профили задаются по цели: `PROVISIONING_PROFILE_SPECIFIER = $(NP_APP_PROFILE_SPECIFIER)` у приложения, `$(NP_XRAY_EXTENSION_PROFILE_SPECIFIER)` у `PacketTunnelXray` и `$(NP_MIHOMO_EXTENSION_PROFILE_SPECIFIER)` у `PacketTunnelMihomo`; по умолчанию пусто. Команда, способ подписи (`Manual`, `Apple Distribution`), профили, версия и номер сборки передаются в командной строке workflow.

Иконка — дуга рогов из элемента подключения, бронза на сланце (`Documentation/Design/DESIGN.md` §7). Генерируется кодом `Tools/make-app-icon.py` из той же геометрии, что и `HornGeometry.swift` (только стандартная библиотека Python, без исходных изображений): iOS — 1024×1024 RGB без альфа-канала, macOS — набор 16…1024 с полями. Каталоги `Apps/Branding/<платформа>/Assets.xcassets` подключены к целям приложения; `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` задан в `project.yml` для iOS и macOS (и в `Byk.xcconfig`). Для tvOS и visionOS (многослойные иконки) иконки пока нет.

## 3. Шаги workflow

`.github/workflows/testflight.yml`, раннер `macos-15`, одно задание:

1. Версия и номер сборки.
2. Секреты → `$RUNNER_TEMP/np-secrets`: ключ ASC (.p8), временная связка ключей со случайным паролем, в неё — сертификат Apple WWDR G3 и `.p12`; проверяется наличие действительной идентичности Apple Distribution.
3. `Tools/asc.py preflight` (только чтение): bundle id записи, версии App Store и поезда TestFlight, существующие номера сборок; отказ, если номер уже занят или версия не выше одобренной.
3a. `Tools/asc.py register-bundle-id`: идентификатор `com.gbnconnect.app.mihomo` создаётся, если его нет, и получает возможности `NETWORK_EXTENSIONS` и `APP_GROUPS` (единственная запись в App ID; ничего не удаляет). Привязать App Group к идентификатору App Store Connect API не умеет: это один раз делает владелец в портале (Identifiers → `com.gbnconnect.app.mihomo` → App Groups → `group.com.gbnconnect.app`). Шаг профилей проверяет App Group в каждом профиле и при отсутствии останавливается с этой инструкцией.
4. `Tools/asc.py profiles` (для приложения и обоих расширений): сертификат ищется в списке команды по серийному номеру; для каждого bundle id берётся действующий профиль `IOS_APP_STORE` с именем `NetworkPlatform CI AppStore <bundle id> …`, содержащий этот сертификат, иначе создаётся новый (единственная запись в ASC на этом шаге). Профили ставятся в оба каталога Xcode; в журнал выводятся их entitlements.
5. XCFramework обоих мостов: кэши с теми же ключами, что в `apple.yml`; при промахе — сборка; затем `bridge-apple-verify.sh` для каждого.
6. Выбор Xcode 26+ (App Store Connect с 2026 г. принимает iOS-сборки только с iOS 26 SDK; сборка с Xcode 16.4 / iOS 18.5 SDK отклонена с ошибкой 409 в прогоне 46054899462).
7. `xcodegen generate`, `xcodebuild archive` с наложением `Byk.xcconfig` и ручной подписью.
8. `xcodebuild -exportArchive`: `method = app-store-connect` (новое имя `app-store`), `signingStyle = manual`, `testFlightInternalTestingOnly = true`, `uploadSymbols = true`.
9. `Tools/verify-ipa.sh <ipa> <app> <group> <build> <version> PacketTunnelXray=<id> PacketTunnelMihomo=<id>`: встроены ровно перечисленные расширения, ключи `NP*ExtensionBundleIdentifier` в Info.plist приложения совпадают с ними; для приложения и каждого расширения — `codesign --verify --strict`, подписант Apple Distribution, bundle id, версии, подписанные entitlements (`packet-tunnel-provider`, App Group, нет `get-task-allow`), встроенный профиль (без списка устройств, `beta-reports-active`, тот же NE-тип и App Group, нужный application-identifier); у приложения — имя «Бык», иконка и отсутствие `ITSAppUsesNonExemptEncryption`.
10. `xcrun altool --validate-app`, затем `--upload-app` с ключом API (если `upload = true`).
11. `Tools/asc.py wait-build`: опрос `GET /v1/builds?filter[app]=…&filter[version]=…` до `VALID` (до 60 мин).
12. `Tools/asc.py beta-group`: группа «oz» должна быть внутренней; если она не получает все сборки автоматически, сборка добавляется в неё. Внешние группы скрипт отвергает.
13. `always()`: удаление связки ключей, профилей, ключа API, архива и IPA.

## 4. Запуск

```sh
gh workflow run testflight.yml -f marketing_version=0.1.0            # сборка и загрузка
gh workflow run testflight.yml -f upload=false                        # только сборка, подпись и проверка
gh workflow run testflight.yml -f flavour=XrayOnly                   # без расширения Mihomo
git tag testflight-0.1.0 && git push origin testflight-0.1.0          # то же по тегу (версия по умолчанию)
gh run watch <id>; gh run view <id> --log-failed
```

Повторный запуск того же прогона (re-run) использует тот же номер сборки и остановится на preflight — запускать заново через `gh workflow run`.

## 5. Безопасность

- Workflow выполняется только в `ivanstarwars8/NetworkPlatform`, только от владельца репозитория (`github.actor == github.repository_owner`) и только по `workflow_dispatch` или тегу `testflight-*`; событий `pull_request` нет, форки секретов не получают.
- Секреты: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_BASE64`, `DISTRIBUTION_P12_BASE64`, `P12_PASSWORD`, `APPLE_TEAM_ID`. Они и всё производное (ключ, `.p12`, профили, связка ключей, серийный номер сертификата — маскируется) не печатаются, не загружаются как артефакты и не коммитятся. Журналы xcodebuild остаются на раннере (в них есть идентификатор команды); артефактов у workflow нет.
- `Tools/asc.py` выводит только метаданные: версии, номера сборок, состояния, имена профилей и групп.

## 6. Что остаётся владельцу

- **Экспортный контроль.** Ключ `ITSAppUsesNonExemptEncryption` не задан намеренно: это юридическое заявление. Пока владелец не ответит в App Store Connect (TestFlight → сборка → Missing Compliance), сборка помечена «Missing Compliance» и тестировщикам недоступна.
- **App Group для расширения Mihomo** (нужен для `flavour=Dual`). Идентификатор `com.gbnconnect.app.mihomo` workflow регистрирует сам, а привязать к нему App Group API App Store Connect не умеет: Developer portal → Identifiers → `com.gbnconnect.app.mihomo` → App Groups → `group.com.gbnconnect.app` → Save. Проверка 2026-11-28 (прогон 46090070167, `upload=false`) ещё остановилась на этом шаге.
- Предупреждение 90725: с апреля 2027 г. потребуется iOS 27 SDK (Xcode 27) — шаг выбора Xcode возьмёт новейший Xcode 2x на образе.
- Профили `NetworkPlatform CI AppStore …` созданы конвейером в аккаунте разработчика; профили и сборки прежнего приложения не трогаются.
