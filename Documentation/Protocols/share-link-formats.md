# Форматы ссылок: проверенная грамматика и источники

Дата проверки: 2026-11-25. Документ описывает, что именно читают и пишут `ShareLinkImporter` и `ShareLinkExporter` (`Packages/ConfigurationEngine`), и на чём это основано.

Пометки: **[V]** — проверено по исходнику с закреплённым SHA или по странице спецификации, загруженной в день проверки; **[U]** — спецификации нет, реализация следует неформальному соглашению.

## 0. Источники

| Обозначение | Что это | Версия |
|---|---|---|
| X716 | Предложение стандарта ссылок VMessAEAD/VLESS, `github.com/XTLS/Xray-core/discussions/716` | страница на 2026-11-25 |
| libXray | `libXray/share/parse_share.go`, `stream.go`, `transport_build.go`, `hysteria2.go`, `generate_share.go` | `6e33510` (`Documentation/Research/SOURCES.txt`) |
| Xray conf | `Xray-core/infra/conf/*.go`, `proxy/shadowsocks_2022`, `transport/internet/tls` | читался `e17392a`; собран и запускался тег `v26.11.9` = `676eaf6` |
| HY2 | Официальная схема URI Hysteria 2, `v2.hysteria.network/docs/developers/URI-Scheme/` | страница на 2026-11-25 |
| SIP002 | `shadowsocks.org/doc/sip002.html` | страница на 2026-11-25 |
| SIP022 | `shadowsocks.org/doc/sip022.html` | страница на 2026-11-25 |
| v2rayN | Вики «Description of VMess share link» (`github.com/2dust/v2rayN/wiki/Description-of-VMess-share-link`) | страница на 2026-11-25 |
| dae182 | Предложение формата `tuic://`, `github.com/daeuniverse/dae/discussions/182` | страница на 2026-11-25 |
| mihomo | `mihomo/common/convert/converter.go` — как сторонний клиент читает те же ссылки | `0455d0d` (клон в `/root/.cache/np-research/mihomo`, в `SOURCES.txt` не записан) |

Что **не** является источником: sing-box и sing-box-for-apple ссылки не разбирают вовсе (поиск `vmess://` по обоим клонам пуст) **[V]**. libXray не разбирает `vmess://` в виде base64-JSON, `tuic://` и `wireguard://` (список схем — `shareSchemes` в `parse_share.go`) **[V]**.

## 1. Общие правила импортёра

- Вход ограничен: 65 536 байт на ссылку, 128 параметров, глубина JSON 16 (ограничения проекта, `ImportLimits`).
- Имена параметров чувствительны к регистру (X716) **[V]**.
- Повтор параметра: используется первое вхождение, остальные записываются как `duplicate`. X716 запрещает повторы; libXray берёт первое значение (`url.Values.Get`) **[V]**.
- Параметр, который не распознан, не выбрасывается: он попадает в `Outbound.unsupported` с причиной (`unknown`, `notApplicable`, `invalidValue`, `duplicate`, `engineSpecific`) и при экспорте записывается обратно.
- Неизвестный транспорт или вид защиты — фатальная ошибка, а не тихий откат к TCP.

## 2. `vless://` и URL-форма `vmess://` — X716 + libXray [V]

```
vless://<uuid>@<host>:<port>?<параметры>#<имя>
vmess://<uuid>@<host>:<port>?<параметры>#<имя>
```

IPv6 — в квадратных скобках. Порт обязателен (libXray: `strconv.Atoi(Port())` без значения по умолчанию).

| Параметр | Где действует | Значения | Источник |
|---|---|---|---|
| `type` | всегда | `tcp`/`raw`, `ws`, `grpc`, `httpupgrade`, `xhttp`/`splithttp`, `kcp`; по умолчанию `tcp` (libXray: `raw`) | X716, libXray |
| `encryption` | VLESS | `none` или строка VLESS Encryption (`mlkem768x25519plus.…`); по умолчанию `none` | X716, libXray |
| `encryption` | VMess | `auto`, `aes-128-gcm`, `chacha20-poly1305`, `none`; по умолчанию `auto` | X716 |
| `flow` | VLESS | `xtls-rprx-vision`, `xtls-rprx-vision-udp443` | X716, Xray conf `vless.go` |
| `security` | всегда | `none`, `tls`, `reality`; по умолчанию `none` | X716, libXray |
| `host`, `path` | `ws`, `httpupgrade`, `xhttp`; у `tcp` с `headerType=http` — списки через запятую | | X716, libXray |
| `headerType` | `tcp` (`none`, `http`); у `kcp` — исторический заголовок | libXray читает только для `tcp` | libXray |
| `seed`, `mtu`, `tti` | `kcp` | libXray читает только `mtu` и `tti`; `seed` есть в примерах X716 | X716, libXray |
| `serviceName`, `authority`, `mode` | `grpc`; `mode` = `gun` (по умолчанию) или `multi` | X716 упоминает ещё `guna` — libXray и Xray его не знают, импортёр записывает как `invalidValue` | X716, libXray |
| `mode` | `xhttp`: `auto`, `packet-up`, `stream-up`, `stream-one` | | Xray conf `SplitHTTPConfig.Build` |
| `extra` | `xhttp` — JSON, в том числе `downloadSettings` | хранится дословно в `EngineExtras["xray"]["xhttp.extra"]` | X716, libXray |
| `fm` | любой транспорт — JSON `finalmask` целиком | хранится дословно в `EngineExtras["xray"]["finalmask"]` | X716, libXray |
| `sni` | TLS/REALITY; по X716 по умолчанию равен адресу сервера | модель хранит то, что написано; значение по умолчанию подставляет компилятор | X716, libXray |
| `fp`, `alpn`, `ech`, `pcs`, `vcn` | TLS | `alpn` — список через запятую | X716, libXray |
| `pbk`, `sid`, `spx`, `pqv` | REALITY; `pbk` обязателен | | X716, libXray |
| `allowInsecure`, `insecure`, `allow_insecure` | TLS | **не входит в стандарт** (X716: «не принят, опция удалена из Xray-core»). Читается ради старых ссылок, в отчёт идёт предупреждение `insecureTLS` | X716, Xray conf `TLSConfig.Build` |
| `quicSecurity`, `key`, `type=quic`, `type=http`/`h2` | транспорты, удалённые из Xray | в X716 и libXray их нет; импортёр читает (v2rayN-наследие), компилятор Xray отказывает | Xray conf `TransportProtocol.Build` |
| `packetEncoding` | VLESS | расширение сторонних клиентов **[U]** | — |

Экспорт: порядок параметров фиксированный; `security` пишется всегда, как у libXray (`generate_share.go`).

## 3. `vmess://` base64-JSON — вики v2rayN [V]

`vmess://` + стандартный base64 от JSON-объекта. Поля: `v` (версия, «2»), `ps` (имя), `add`, `port`, `id`, `aid`, `scy` (по умолчанию `auto`), `net`, `type`, `host`, `path`, `tls`, `sni`, `alpn`, `fp`, `insecure`, `vcn`, `pcs`.

Смысл `type`, `host`, `path` зависит от `net`:

| `net` | `type` | `host` | `path` |
|---|---|---|---|
| `tcp` | `none` / `http` | хосты через запятую | пути |
| `kcp` | заголовок (`none`, `srtp`, `utp`, `wechat-video`, …) | — | seed |
| `ws`, `h2`, `httpupgrade` | — | Host | путь |
| `quic` | заголовок | вид шифрования | ключ |
| `grpc` | `gun` / `multi` | authority | serviceName |
| `xhttp` | режим | Host | путь |

Импортёр принимает числа и строки на месте скаляров (`"port": 443` и `"port": "443"`), стандартный и URL-алфавит base64, с дополнением и без. Отличие от mihomo: тот пропускает ссылку без `ps`, мы подставляем адрес сервера и пишем `defaultApplied`. Строки `net=grpc`/`xhttp`/`httpupgrade` на вики названы не все — это практика v2rayN и mihomo **[U]** для этих трёх строк таблицы.

Экспорт VMess — всегда в этот формат (версия 2, ключи отсортированы, base64 с дополнением), потому что URL-форму понимают не все клиенты.

## 4. `trojan://` — libXray [V]

```
trojan://<пароль>@<host>[:<port>]?<те же параметры транспорта и защиты>#<имя>
```

`security` по умолчанию `tls` (libXray: `none` заменяется на `tls` для `trojan`). libXray требует порт; импортёр при отсутствии порта подставляет 443 и пишет `defaultApplied`. Формальной спецификации у формата нет; X716 описывает только `vmess` и `vless`.

## 5. `ss://` — SIP002, SIP022 [V]

```
SS-URI   = "ss://" userinfo "@" hostname ":" port [ "/" ] [ "?" plugin ] [ "#" tag ]
userinfo = websafe-base64(method ":" password)      ; обычные и AEAD-шифры, дополнение необязательно
         | method ":" password                      ; каждая часть percent-encoded
```

- Для методов `2022-blake3-*` userinfo **не должен** кодироваться base64 (SIP002). Экспортёр пишет открытую форму; импортёр base64-форму читает, но ставит предупреждение `nonStandardFormat`.
- `plugin` — имя и параметры через `;`; перед `?` ставится `/`.
- Унаследованная форма `ss://BASE64(method:password@host:port)#tag` читается (её пишут старые клиенты; так же делает mihomo).
- Ключ SIP022 — base64 **стандартного** алфавита от ровно 16 байт (`2022-blake3-aes-128-gcm`) или 32 байт (остальные методы). Несколько ключей через `:` — identity-ключи (SIP023; так их разбирает `ParsePSKList` в Xray). Импортёр проверяет длину и предупреждает; компилятор Xray при неверной длине отказывает.
- Методы SIP022: обязательные `2022-blake3-aes-128-gcm`, `2022-blake3-aes-256-gcm`; необязательные `2022-blake3-chacha20-poly1305`, `…-chacha12-…`, `…-chacha8-…`.
- libXray дополнительно читает у `ss://` параметры транспорта (`type`, `security`, …) — это не SIP002; у нас они записываются как нераспознанные.

## 6. `hysteria2://`, `hy2://` — официальная схема [V]

```
hysteria2://[auth@]hostname[:port]/?[key=value]&...[#name]
```

- `auth` — percent-encoded; форма `user:password` допустима и читается целиком как строка аутентификации.
- Порт по умолчанию 443; на месте порта допустим список `123,5000-6000` (port hopping).
- Официальные параметры: `obfs` (`salamander`, `gecko`), `obfs-password`, `sni`, `insecure` (`1`/`0`), `pinSHA256`, `ech`.
- Спецификация прямо запрещает класть в ссылку режим клиента и **пропускную способность**.
- `hysteria2+realm://` — отдельная схема; импортёр её не принимает (`unsupportedScheme`).

Расширения, которых в спецификации нет, но которые читаются: `up`, `down` (libXray, mihomo), `mport`/`ports`, `hop-interval` (libXray), `alpn`, `fp`, `pcs`, `vcn` (расширения Xray). При чтении `up`/`down` в отчёт идёт `nonStandardFormat`; экспортёр пишет их с тем же предупреждением.

Семантика `pinSHA256` у движков разная: Hysteria проверяет отпечаток **вместе** с цепочкой сертификатов, Xray при совпадении отпечатка листового сертификата цепочку не проверяет (`transport/internet/tls/config.go`, `verifyPeerCert`). libXray по этой причине ссылки с `pinSHA256` и `insecure=1` отвергает. Мы импортируем оба параметра в модель, а компилятор Xray пишет `approximated` для отпечатка и `unsupported` для `insecure`.

## 7. `tuic://` — неформальное предложение [U]

```
tuic://<uuid>:<password>@<host>:<port>?congestion_control=…&alpn=…&sni=…&udp_relay_mode=…&disable_sni=…&allow_insecure=…#name
```

Источник — dae182 (примеры без формального описания) и его чтение в mihomo. Значения по умолчанию нигде не заданы. TUIC v4 (`tuic://token@host`) не поддержан: возвращается `missingField("password")`. Экспортёра нет.

## 8. `wireguard://`, `wg://` — спецификации нет [U]

Официальный формат WireGuard — файл `wg-quick`, URI не определён; ни один из изученных исходников такую ссылку не разбирает. Импортёр читает распространённую у клиентов форму

```
wireguard://<privatekey>@<host>:<port>?publickey=…&address=…&allowedips=…&presharedkey=…&reserved=a,b,c&mtu=…&keepalive=…#name
```

и всегда ставит предупреждение `nonStandardFormat`. Экспортёра нет. Статус формата — **не проверен**.

## 9. `socks://` — libXray [V]

`socks://BASE64(user:password)@host:port#name`; без учётных данных userinfo отсутствует. Импортёр дополнительно принимает открытую форму `user:password@` и схемы `socks5`, `socks4`, `socks4a`. Экспортёр пишет форму libXray (URL-алфавит base64 без дополнения — её `decodeBase64Text` читает).

## 10. Что исправлено по итогам проверки

| Было | Стало | Основание |
|---|---|---|
| `obfs=gecko` у Hysteria2 — фатальная ошибка | принимается в модель; компилятор Xray отказывает явно (нужен диапазон размеров пакета, которого в ссылке нет) | HY2 |
| `upmbps`/`downmbps` читались как пропускная способность Hysteria2 | не читаются (это имена Hysteria 1), остаются нераспознанными параметрами | HY2, libXray, mihomo |
| `up`/`down` читались молча | читаются с предупреждением `nonStandardFormat` | HY2 |
| `hop-interval` без списка портов — молча | предупреждение `suspiciousValue` | libXray |
| ключ Shadowsocks 2022 не проверялся | проверка длины и алфавита; base64-userinfo с 2022-методом — `nonStandardFormat` | SIP002, SIP022 |
| методы `2022-blake3-chacha12/8-poly1305` считались неизвестными | известны | SIP022 |
| нет экспортёров Hysteria2, VMess, SOCKS | добавлены, round-trip покрыт тестами | HY2, v2rayN, libXray |
| в комментариях к коду форматы VMess-JSON, legacy `ss`, `tuic` значились «по памяти» | сверены со страницами; `wireguard://` остаётся непроверенным | — |

Расхождений в разборе `vless://`, `trojan://`, SIP002 и VMess-JSON с источниками не найдено.

## 11. Компиляция в Xray и заметки о версиях

Компилятор: `XrayConfigCompiler` (`Packages/ConfigurationEngine/Sources/XrayConfigCompiler.swift`, `XrayStreamCompiler.swift`), отчёт — `ConversionReport` по ADR-0002 §6. Правила написаны по `infra/conf` Xray-core 26.11.9 и подтверждены настоящим бинарником (раздел 12).

Поведение Xray 26.11.9, из-за которого старые ссылки не переносятся «как есть» **[V]** — каждое подтверждено отказом бинарника в `Tests/Fixtures/negative-mutations.py`:

| Что в ссылке | Что делает Xray 26.11.9 | Что делает компилятор |
|---|---|---|
| `allowInsecure=1` | отказ: опция удалена, взамен `pcs`/`vcn` | не пишет, `unsupported` (warning): соединение пройдёт только с действительным или закреплённым сертификатом |
| `type=http`/`h2`, `type=quic` | отказ: транспорты удалены | узел исключается, `unsupported` (error) |
| mKCP `headerType`, `seed` | `kcpSettings.header`/`seed` молча не читаются | переносит в UDP-маску `mkcp-legacy`, `migrated` (warning) |
| VLESS или Trojan без TLS на публичный адрес | отказ | узел исключается |
| VMess `aid > 0`, `scy=none`/`zero` | `alterId` не существует, неизвестный шифр молча становится `auto` | `unsupported` / `approximated` (warning) |
| Shadowsocks `none`, `plain`, `aes-192-gcm`, плагины SIP003 | отказ / нет поддержки | узел исключается |
| SOCKS4/4a | неизвестные поля настроек игнорируются молча, исходящий всегда SOCKS5 | узел исключается |
| REALITY: ключ в стандартном base64 или с `=` | отказ (нужен base64url без дополнения) | нормализует ключ |
| REALITY с `ws`, `httpupgrade`, `kcp` | отказ | узел исключается |
| Hysteria2 `up=50` (число без единицы) | трактует как 50 бит/с → отказ (минимум 65 536 байт/с) | не пишет, `dropped` (warning): у других клиентов то же число значит Мбит/с |
| TUIC | протокола нет | узел исключается |

Другие сведения о версии:

- Xray 26.11.9 требует Go 1.27 (`go.mod`); со старым Go нужен `GOTOOLCHAIN=go1.27.0` — запись `go 1.27` без патч-версии автоматически не разрешается.
- Hysteria2 в Xray — исходящий `hysteria` с `version: 2` и транспортом `hysteria`; обфускация и port hopping — маски `salamander` и `udphop` в `finalmask.udp`, пропускная способность — `finalmask.quicParams` (`congestion: brutal`).
- Селекторы балансировщика Xray сравнивают теги **по префиксу**, поэтому компилятор выдаёт узлам собственные теги одинаковой длины (`proxy-0000`), а соответствие хранит в `ConversionReport.engineTags`.
- Исходящий `freedom` в 26.11.9 по умолчанию блокирует частные адреса назначения (`target blocked by a finalrule`). Компилятор добавляет `direct`, но трафик в него пока не направляет; при появлении маршрутизации «LAN напрямую» это надо учесть.
- WireGuard: компилятор всегда пишет `noKernelTun: true`. На платформах Apple ядерного пути у Xray нет (`proxy/wireguard/tun_default.go`), а на Linux под root без этого флага Xray создаёт сетевой интерфейс и правила маршрутизации; с флагом проверка на Linux идёт по тому же пользовательскому стеку, что и на устройстве.
- Группы: `urlTest` → балансировщик `leastPing` + `observatory`; `loadBalance` → `random`/`roundRobin`/`leastPing`/`leastLoad` (+ `burstObservatory`); `fallback` и `consistentHashing` приближаются с записью `approximated`; `selector` компилируется в текущий выбранный узел.
- В модели пока нет маршрутизации и DNS (`RoutingEngine` — отдельный модуль, от которого `ConfigurationEngine` не зависит). Компилятор принимает только `XrayCompileOptions`: уровень журнала, локальный SOCKS-inbound, список DNS-серверов.

## 12. Чем это проверено

- `Tests/Fixtures/ShareLinks/*.link` — ссылки на каждую схему (ключи сгенерированы для тестов), рядом ожидаемые модель, отчёты и конфиг Xray. `Tests/Fixtures/Profiles` — профили, которые ссылкой не выразить.
- `Tools/validate-fixtures.sh <xray>` — `xray run -test` на каждом скомпилированном конфиге; заблокированные компилятором перечисляются с причиной.
- `Tests/Fixtures/negative-mutations.py <xray>` — портит по одному полю в принятых конфигах и проверяет, что бинарник отказывает именно там, где отказывает компилятор.
- `Tests/Fixtures/Interop/run-interop.sh <xray>` — сервер и клиент Xray в отдельном безымянном сетевом пространстве имён (`unshare -n`, нужен root), через скомпилированные конфиги проходит настоящий трафик: токен и 1 МиБ случайных данных сверяются побайтно. Цель — адрес 192.0.2.1 на `lo` внутри пространства имён: WireGuard нельзя проверить на 127.0.0.1 (пользовательский стек клиента считает этот адрес своим), а исходящий `freedom` сервера без явного `finalRules` блокирует частные адреса.

Числа последнего прогона — в `STATUS.md`.
