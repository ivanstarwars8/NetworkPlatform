# Xray-core: современные транспорты и расширения — справочник по исходникам

Дата: 2026-11-25. Источник — только исходный код Xray-core и история его репозитория.

| Что | Значение |
|---|---|
| Изученный коммит (HEAD клона) | `e17392a96e1727a5fdb8101ecdd9245dc488fea4`, 2026-11-24 |
| Версия в коде HEAD | `26.11.9` (`core/core.go`: `Version_x/y/z = 26/11/9`) |
| Последний тег | `v26.11.9` → `676eaf66f8f05d4d558ee7a74b4736623d3feeb9` (всего тегов 136; `git ls-remote --tags`) |
| HEAD относительно тега | +36 коммитов, 218 файлов; **номер версии в коде не менялся** |
| Что собирает libXray | `go.mod` libXray закрепляет `xray-core …-676eaf66f8f0`, то есть **ровно тег v26.11.9, не HEAD** |

Метки: **[V]** — прочитано в исходнике (путь указан) или получено командой git; **[U]** — вывод или оценка, не подтверждённые запуском. Ничего из описанного здесь не собиралось и не запускалось: все утверждения о поведении — чтение кода. Оценки «память / UDP / батарея» — **[U]**, кроме прямо названных констант.

Теги существуют в двух записях одного и того же коммита: `v1.YYMMDD.0` и `vYY.M.D` (проверено: `v1.260206.0` = `v26.2.6`, `v1.260123.0` = `v26.1.23`). Ниже используется короткая форма. «Минимальная версия» — первый тег, содержащий коммит, где появился каталог или ключ (`git log --diff-filter=A` / `git log -S`); для ключей это оценка «не позднее», ключ мог раньше жить в другом файле.

Пути исходников — относительно корня Xray-core. Ключи JSON — из `infra/conf`. Модель — `Packages/DomainModels/Sources`.

---

## 0. Главное для компилятора конфигурации

1. **HEAD и тег несовместимы по мультиплексору.** В v26.11.9 Mux задаётся объектом `mux` на уровне outbound (`enabled`, `concurrency`, `xudpConcurrency`, `xudpProxyUDP443`). В HEAD этот объект **игнорируется с предупреждением**, а Mux включается через `settings.multiplex` и только у VLESS и VMess. Номер версии при этом одинаковый (26.11.9) — различить по `Version()` нельзя. [V] `infra/conf/xray.go:210, 369–371`, diff `v26.11.9..HEAD`.
2. **`allowInsecure: true` — ошибка сборки конфига** начиная с v26.7.11: «removed feature», взамен `pinnedPeerCertSha256` и `verifyPeerCertByName`. В `TLSSettings` модели поле `allowInsecure` есть. [V] `infra/conf/transport_security.go:362–364`.
3. **`extra` в XHTTP заменяет весь объект настроек**, кроме `host`, `path`, `mode`. Если выдать одновременно `extra` и `downloadSettings`/`xmux` на верхнем уровне — верхние будут молча отброшены. [V] `infra/conf/transport_method.go:318–328`.
4. **VLESS без TLS/REALITY и без `encryption` на публичный адрес запрещён** («vless without TLS or other encryption is prohibited unless the server address is a private IP or domain»); то же для Trojan. [V] `infra/conf/xray.go:226–246`.
5. `kcpSettings.header`/`seed`, `freedom.fragment`/`noises`, `freedom.proxyProtocol`, outbound `proxySettings`, корневые `transport` и `reverse`, транспорты `h2`/`http`/`quic`, `security: "xtls"`, `flow` у Trojan — удалены или устарели; замены перечислены в §16.

---

## 1. XHTTP

**Исходники.** `transport/internet/splithttp/` (`dialer.go`, `client.go`, `hub.go`, `mux.go`, `xpadding.go`, `upload_queue.go`, `browser_client.go`, `h1_conn.go`); конфиг — `infra/conf/transport_method.go`, `SplitHTTPConfig` (строки 266–298), сборка 317–521. [V]

**Включение.** `streamSettings.network`: `"xhttp"` или `"splithttp"`; объект `xhttpSettings` (псевдоним `splithttpSettings`). [V] `infra/conf/transport_internet.go`.

**Минимальная версия.** Каталог `splithttp` — v1.8.15; `xmux` и `downloadSettings` — тег v25.3.6; `xpadding.go` (режимы и размещение паддинга) — v26.2.6. [V git]

### 1.1. Режимы

`mode`: `""`→`"auto"`, `"auto"`, `"packet-up"`, `"stream-up"`, `"stream-one"`; иное — ошибка `unsupported mode`. [V] `transport_method.go:330–336`

Что выбирает клиент при `auto` (`splithttp/dialer.go`, функция `Dial`): [V]

| Условие | Режим |
|---|---|
| без REALITY | `packet-up` |
| REALITY | `stream-one` |
| REALITY + `downloadSettings` | `stream-up` |

Версия HTTP (`decideHTTPVersion`): REALITY → всегда `2`; без TLS → `1.1`; TLS и `alpn` ровно из одного элемента `http/1.1` → `1.1`, ровно `h3` → `3` (сеть переключается на UDP); всё остальное → `2`. [V]

- `stream-one` — один запрос, тело запроса вверх, тело ответа вниз.
- `stream-up` — отдельный GET вниз и один потоковый запрос вверх.
- `packet-up` — отдельный GET вниз, вверх — серия запросов с порядковыми номерами; пачки собираются из буферизованной трубы; размер пачки `scMaxEachPostBytes` (по умолчанию 1 000 000), пауза `scMinPostsIntervalMs` (по умолчанию 30). [V] `dialer.go`, `config.go:140–160`

### 1.2. Раздельные upload и download

`xhttpSettings.downloadSettings` — полный `StreamConfig` (тот же тип, что `streamSettings`), плюс поля адреса, которые есть только у него по смыслу: [V] `transport_internet.go`, `StreamConfig`

```json
"xhttpSettings": {
  "path": "/up", "mode": "stream-up",
  "downloadSettings": {
    "address": "example.org", "port": 443,
    "network": "xhttp", "security": "tls",
    "tlsSettings": { "serverName": "example.org", "alpn": ["h2"] },
    "xhttpSettings": { "path": "/down" },
    "sockopt": { }
  }
}
```

- Несовместимо со `stream-one`: `Can not use "downloadSettings" in "stream-one" mode.` [V] `transport_method.go:508–512`
- Для download строится второй HTTP-клиент со своей версией HTTP, своим `host`/`path`, своим XMUX; при `h3` его сеть — UDP. То есть вверх и вниз могут идти по разным адресам и разным L4. [V] `dialer.go` (блок `if transportConfiguration.DownloadSettings != nil`)
- `sockopt` основного потока наследуется в download только при `sockopt.penetrate: true`. [V] там же
- `ProtocolSettings` у download приводится к `*splithttp.Config` без проверки, адрес разыменовывается с комментарием `// just panic`: download **обязан** быть XHTTP и иметь `address`. [V] там же

### 1.3. Ключи `xhttpSettings`

[V] `transport_method.go:266–298`; значения по умолчанию — `splithttp/config.go`, `xpadding.go`.

| Ключ | Тип | По умолчанию / допустимое |
|---|---|---|
| `host`, `path` | строка | приоритет Host у клиента: `host` > `serverName` > адрес; запрос можно дописать в `path` после `?` |
| `mode` | строка | см. 1.1 |
| `headers` | объект | `host` внутри запрещён |
| `xPaddingBytes` | диапазон | 100–1000; отключить нельзя |
| `xPaddingObfsMode` | bool | `false`: паддинг всегда `queryInHeader`, ключ `x_padding`; остальные `xPadding*` действуют только при `true` |
| `xPaddingKey` / `xPaddingHeader` | строка | `x_padding` / `X-Padding` |
| `xPaddingPlacement` | строка | `queryInHeader` (умолч.), `cookie`, `header`, `query` |
| `xPaddingMethod` | строка | `repeat-x` (умолч.), `tokenish` |
| `uplinkHTTPMethod` | строка | `POST`; `GET` только в `packet-up` |
| `sessionIDPlacement`, `seqPlacement` | строка | `path` (умолч.), `cookie`, `header`, `query` |
| `sessionIDKey`, `seqKey` | строка | `x_session`/`X-Session`, `x_seq`/`X-Seq` |
| `sessionIDTable`, `sessionIDLength` | строка, диапазон | таблица символов или имя (`hex`, `HEX`, `base36`, `BASE36`, `Base62`, `alphabet`, `ALPHABET`, `Alphabet`, `number`); без таблицы — UUID; пространство не меньше 2³¹ |
| `uplinkDataPlacement` | строка | `auto` (умолч.), `body`; `cookie` и `header` — только в `packet-up` |
| `uplinkDataKey`, `uplinkChunkSize` | строка, диапазон | `X-Data` / `x_data`; куски 2–3 КиБ (cookie), 3–4 КБ (header) |
| `noGRPCHeader`, `noSSEHeader` | bool | |
| `scMaxEachPostBytes` | диапазон | 1 000 000 |
| `scMinPostsIntervalMs` | диапазон | 30 |
| `scMaxBufferedPosts` | число | 30 (сервер) |
| `scStreamUpServerSecs` | диапазон | 20–80 (сервер) |
| `serverMaxHeaderBytes` | число | 8192 (сервер) |
| `xmux` | объект | см. §5 |
| `downloadSettings` | объект | см. 1.2 |
| `h2Params` | сырой JSON | читается только сервером (`hub.go:560`) |
| `extra` | сырой JSON | тот же набор ключей; **заменяет объект целиком**, кроме `host`/`path`/`mode` |

QUIC для XHTTP/3 настраивается в `finalmask.quicParams` (§7.3). `congestion: "brutal"` для XHTTP/3 в диалере не обработан и приводит к `panic` (ветка `default`); допустимы `reno`, `bbr`, `force-brutal`. [V] `dialer.go:236–244`; комментарий в `xdrive/client_test.go:771` подтверждает то же про XHTTP и DoH.

**Требования к клиенту.** uTLS-отпечаток при TLS (пустой `fingerprint` = Chrome); при REALITY — только HTTP/2; `xmux` и паддинг должны быть согласованы с сервером (`xPaddingBytes` проверяется сервером). Browser dialer (`xray.browser.dialer`) с REALITY не применяется. [V] `dialer.go`

**Мобильная значимость.** [U], константы — [V]:
- по умолчанию XMUX держит 3 соединения (`maxConnections` 3–3), каждое живёт 1800–3000 с и 600–900 запросов;
- HTTP/2 шлёт keepalive-пинг каждые 45 с (`ChromeH2KeepAlivePeriod`), HTTP/3 — каждые 10 с (`QuicgoH3KeepAlivePeriod`); простаивающее соединение закрывается через 300 с (`ConnIdleTimeout`) — `common/net/net.go:14–20`. На сотовой сети пинги будят радиомодуль; период меняется `xmux.hKeepAlivePeriod` (отрицательное значение отключает пинг H2);
- `packet-up` буферизует до `scMaxEachPostBytes` на соединение; при многих потоках это заметная память в расширении с лимитом;
- при `h3` (в том числе только для download) нужен рабочий UDP до сервера.

**DomainModels.** `XHTTPSettings { path, host, mode, download: XHTTPDownload { server, stream } }`; `Transport.xhttp` — `indirect`, вложенный `StreamSettings` рекурсивен. Представимо типизированно: `path`, `host`, `mode`, раздельный download с собственными транспортом и безопасностью. Не представимо типизированно: `headers`, весь паддинг, `sc*`, `xmux`, размещение session/seq/данных — только сырым JSON в `EngineExtras` под ключом `xhttp.extra`. Пробелы:
- у вложенного download нет своего `EngineExtras` — его `sockopt`, `finalmask`, `extra` положить некуда;
- при одновременном наличии `download` и `xhttp.extra` компилятор обязан либо вложить `downloadSettings` внутрь `extra`, либо развернуть `extra` в плоские ключи (см. §0, п. 3).

---

## 2. REALITY

**Исходники.** `transport/internet/reality/reality.go`, `config.go`; конфиг — `infra/conf/transport_security.go`, `REALITYConfig` (строки 27–52). Сама реализация протокола — внешний модуль `github.com/xtls/reality`, uTLS — `github.com/refraction-networking/utls`. [V]

**Минимальная версия.** Каталог — v1.8.0; `mldsa65Verify` — v25.7.26. [V git]

**Ключи клиента** (`security: "reality"`, объект `realitySettings`): [V] `transport_security.go:45–51, 185–240`

| Ключ | Требование |
|---|---|
| `fingerprint` | обязателен по смыслу: `unsafe` и `hellogolang` — ошибка, неизвестный — ошибка; пустой = Chrome |
| `serverName` | строка; пустой — берётся адрес назначения; `serverNames` у клиента — ошибка |
| `password` | открытый ключ сервера X25519, base64 RawURL, 32 байта; псевдоним `publicKey` (перекрывается `password`) |
| `shortId` | hex, не длиннее 16 символов; `shortIds` у клиента — ошибка |
| `mldsa65Verify` | открытый ключ ML-DSA-65, base64 RawURL, ровно 1952 байта |
| `spiderX` | путь, начинается с `/`, по умолчанию `/` |
| `show`, `masterKeyLog` | отладка |

Серверные: `target` (псевдоним `dest`), `type`, `xver`, `serverNames`, `privateKey`, `shortIds`, `mldsa65Seed`, `minClientVer`, `maxClientVer`, `maxTimeDiff`, `limitFallbackUpload`, `limitFallbackDownload`. [V]

**Ограничение по транспорту.** REALITY допустим только с RAW (`tcp`), XHTTP и gRPC: `REALITY only supports RAW, XHTTP and gRPC for now.` [V] `transport_internet.go`

**Версия клиента видна серверу.** Клиент кладёт `Version_x.y.z` в первые три байта Session ID ClientHello, затем время и `shortId`; сервер может отсечь по `minClientVer`/`maxClientVer`. Значит, версия собранного ядра — часть сетевого протокола. [V] `reality.go` (`hello.SessionId[0..2]`)

**Постквантовое.** [V]
- Обмен ключами: если отпечаток не даёт обычную долю X25519, берётся `KeyShareKeys.MlkemEcdhe` (гибрид X25519MLKEM768) — `reality.go:181–184`. Отдельного ключа конфигурации для этого нет: определяется отпечатком.
- Комментарий в `transport/internet/tls/tls.go:273`: «All of them must have X25519MLKEM768 before optional X25519, otherwise REALITY servers (since v26.9.9) will reject them». Список таких «современных» отпечатков: `hellofirefox_148`, `hellochrome_131`, `hellochrome_133`, `hellochrome_155`, `hellosafari_26_3`; `random` выбирается из них.
- Подпись: `mldsa65Verify` — дополнительная проверка сертификата подписью ML-DSA-65 (`reality.go:113–118`).
- Генерация ключей: команды `xray x25519`, `xray mldsa65`, `xray mlkem768` (`main/commands/all/`).

**Мобильная значимость.** [U] Ключ ML-DSA-65 — 1952 байта в конфиге; гибридный ClientHello длиннее классического (важно при фрагментации и на путях с малым MTU). Вычислительная цена разовая, на рукопожатие.

**DomainModels.** `RealitySettings { serverName, fingerprint, publicKey, shortID, spiderX, mldsa65Verify }` — клиентская часть покрыта полностью. При компиляции выдавать ключ как `password` (сообщения об ошибках ядра называют его так) либо `publicKey` — оба принимаются. Длины (32 / 1952 байта, `shortId` ≤ 16 hex) модель не проверяет.

### 2.1. TLS (для полноты)

`tlsSettings`: `serverName`, `alpn`, `fingerprint`, `certificates`, `enableSessionResumption`, `disableSystemRoot`, `minVersion`, `maxVersion`, `cipherSuites`, `rejectUnknownSni`, `curvePreferences`, `masterKeyLog`, `pinnedPeerCertSha256`, `verifyPeerCertByName`, `echServerKeys`, `echConfigList`, `echSockopt`, `useSystemCA`, `allowInsecure` (**только `false`**). [V] `transport_security.go:300–320`

- `curvePreferences` принимает в том числе `x25519mlkem768`, `secp256r1mlkem768`, `secp384r1mlkem1024` (`transport/internet/tls/config.go:534–536`).
- `pinnedPeerCertSha256` — список через запятую, hex SHA-256, двоеточия допускаются; `verifyPeerCertByName` — список через запятую.
- ECH: `echConfigList`, `echSockopt` — с v25.7.26.

**DomainModels.** `TLSSettings` покрывает `serverName`, `alpn`, `fingerprint`, `echConfigList`, `pinnedPeerCertificateSHA256`, `verifyPeerCertificateByName`. `allowInsecure = true` для Xray некомпилируемо (нужна диагностика, а не молчаливый сброс). Поля `disableSNI` в `TLSConfig` ядра нет. Не представлены: `curvePreferences`, `minVersion`/`maxVersion`, `echSockopt`, `useSystemCA`.

---

## 3. Vision (`flow`)

**Исходники.** `proxy/vless/outbound/outbound.go` (строки 283–345), `proxy/proxy.go` (`NewVisionReader` и др.), константа `vless.XRV = "xtls-rprx-vision"` в `proxy/vless/vless.go:18`. [V]

**Ключ.** `settings.flow` у VLESS outbound: `""`, `"xtls-rprx-vision"`, `"xtls-rprx-vision-udp443"`; иное — ошибка. [V] `infra/conf/vless.go:354–358`

**Правила.** [V] `outbound.go`
- Внешний слой обязан быть TLS 1.3: иначе `failed to use xtls-rprx-vision, found outer tls version …`.
- Нижнее соединение должно быть напрямую TLS/uTLS/REALITY либо слоем шифрования VLESS (§4); иначе `XTLS only supports TLS and REALITY directly for now.` То есть Vision не сочетается с XHTTP/WS/gRPC без VLESS-шифрования.
- UDP на порт 443 отклоняется (`XTLS rejected UDP/443 traffic`), если не выбран вариант `-udp443`.
- С транспортом XDRIVE `flow` запрещён (`infra/conf/xray.go`, `validateXDrive`).
- `flow` у Trojan удалён (`infra/conf/trojan.go:74`).

**Мобильная значимость.** [U] Vision снимает двойное шифрование после рукопожатия — меньше CPU на байт; сплайс (`CanSpliceCopy`) актуален для Linux, на Darwin выигрыш только в отсутствии второго слоя AEAD.

**DomainModels.** `VLESSSettings.flow: String?` — представимо; допустимые значения не проверяются.

---

## 4. Шифрование VLESS (ML-KEM-768 + X25519)

**Исходники.** `proxy/vless/encryption/` (`client.go`, `server.go`, `common.go`, `xor.go`); разбор строки — `infra/conf/vless.go:360–398`; генерация — `xray vlessenc` (`main/commands/all/vlessenc.go`). [V]

**Минимальная версия.** v25.9.5. [V git]

**Ключ.** `settings.encryption` у VLESS outbound (у inbound — `decryption`). Либо `"none"`, либо строка из частей через точку: [V]

```
mlkem768x25519plus.<native|xorpub|random>.<1rtt|0rtt>[.<паддинг>…].<ключ>[.<ключ>…]
```

- вторая часть: `native`, `xorpub` (XorMode 1), `random` (XorMode 2);
- третья: `1rtt` или `0rtt`;
- далее части короче 20 символов считаются параметрами паддинга, длинные — ключами в base64 RawURL длиной 32 байта (X25519) или 1184 байта (ключ инкапсуляции ML-KEM-768); другая длина — ошибка;
- пустая строка — ошибка `please add/set "encryption":"none" for every user`.

Наличие `encryption` (не `none`) снимает требование TLS/REALITY из §0, п. 4 и обязательно для XDRIVE.

**Мобильная значимость.** [U] Ключ ML-KEM-768 в строке — около 1,6 КБ в base64; `0rtt` экономит круг рукопожатия при переподключениях (частых при смене сети).

**DomainModels.** `VLESSSettings.encryption: String` (по умолчанию `"none"`) — представимо как непрозрачная строка. Структура не разбирается и не проверяется. `VLESSSettings.packetEncoding` в конфиге Xray соответствия не имеет: такого ключа в `VLessOutboundConfig` нет, XUDP включается автоматически (§5.2).

---

## 5. Мультиплексирование: Mux, XUDP, XMUX

Три разных механизма; путать нельзя.

### 5.1. Mux (mux.cool)

| | Тег v26.11.9 | HEAD `e17392a` |
|---|---|---|
| Код | `common/mux/` | `proxy/vless/multiplex/` (каталог `common/mux` удалён) |
| Где в JSON | `outbounds[].mux` | `outbounds[].settings.multiplex` |
| Ключи | `enabled`, `concurrency`, `xudpConcurrency`, `xudpProxyUDP443` | `concurrency`, `xudpConcurrency`, `xudpProxyUDP443` |
| Протоколы | любой outbound через `proxyman` | только VLESS и VMess (`infra/conf/vless.go`, `vmess.go`) |
| Включение | `enabled: true` | `concurrency > 0` или `xudpConcurrency > 0` |
| Отрицательные значения | `concurrency < 0` отключает | ошибка `must be non-negative` |
| Старый ключ | работает | игнорируется, предупреждение `The legacy "mux" setting is ignored…` |

[V] diff `v26.11.9..HEAD` по `infra/conf/xray.go`, `vless.go`, `vmess.go`; `proxy/vless/multiplex/client.go:20–33`.

`xudpProxyUDP443`: `reject` (умолч.), `allow`, `skip`. В HEAD для XDRIVE `concurrency` поднимается минимум до 128 (`client.go:47–50`). JSON-декодер неизвестные поля не отклоняет (в `infra/` нет `DisallowUnknownFields`), поэтому конфиг «не той» версии загрузится, а Mux просто не включится: в теге `settings.multiplex` будет проигнорирован молча, в HEAD `mux` — с предупреждением. [V — отсутствие строгого режима; U — «молча» для тега, вывод из устройства декодера]

### 5.2. XUDP

**Исходники.** `common/xudp/xudp.go`; в HEAD ещё `proxy/vless/multiplex/xudp.go`. Каталог — с v1.3.0. [V]

- Отдельного ключа включения нет. VLESS outbound сам заворачивает UDP в XUDP (команда Mux) при `flow = xtls-rprx-vision`, а без Vision — для всех портов, кроме 53 и 443 (`outbound.go:349`). [V]
- Full Cone: глобальный идентификатор сессии вычисляется (BLAKE3 с ключом процесса) от адреса источника, только если inbound — `dokodemo-door`, `socks`, `shadowsocks` или **`tun`** (`xudp.go`, `GetGlobalID`). То есть через TUN-inbound Full Cone работает. [V]
- Переменные окружения: `xray.xudp.show`, `xray.xudp.basekey` (`common/platform/platform.go:23–24`). [V]
- `xudpConcurrency` и `xudpProxyUDP443` — в объекте Mux (5.1).

### 5.3. XMUX

Пул HTTP-соединений транспорта, к mux.cool отношения не имеет. **Исходники:** `transport/internet/splithttp/mux.go`; используется XHTTP, MASQUE и XDRIVE. С v25.3.6. [V]

Ключи `xmux` (все диапазоны, кроме последнего): `maxConcurrency`, `maxConnections`, `cMaxReuseTimes`, `hMaxRequestTimes`, `hMaxReusableSecs`, `hKeepAlivePeriod` (число, секунды). `maxConnections` и `maxConcurrency` одновременно — ошибка. [V] `transport_method.go:300–307, 479–481`

Значения по умолчанию, если объект пуст: [V]

| Транспорт | `maxConnections` | `hMaxRequestTimes` | `hMaxReusableSecs` |
|---|---|---|---|
| XHTTP | 3 | 600–900 | 1800–3000 |
| MASQUE | 1 | — | 1800–3000 |
| XDRIVE | 1 (4 для Google Drive по h2) | — | 1800–3000 |

**Мобильная значимость.** [U] Mux сокращает число соединений и рукопожатий (экономия при частых коротких запросах), но одно потерянное TCP-соединение роняет все потоки разом; для VLESS+Vision обычно отключён. XUDP нужен для UDP поверх TCP-транспорта и для QUIC-приложений; `xudpProxyUDP443: "reject"` заставляет приложения откатываться с HTTP/3 на TCP — меньше UDP-нагрузки на туннель.

**DomainModels.** Mux не представлен вообще: ни поля в `Outbound`, ни ключа в `EngineExtras`. XMUX — только внутри `xhttp.extra`. Рекомендуется типизированное поле мультиплексора (`concurrency`, `xudpConcurrency`, `xudpProxyUDP443`), а форму вывода выбирать по возможностям собранного ядра — не по номеру версии.

---

## 6. Транспорты и протоколы: реестр

[V] `infra/conf/transport_internet.go` (значения `network`), `infra/conf/xray.go` (загрузчики протоколов).

| `network` | Каталог | Замечание |
|---|---|---|
| `raw` / `tcp` | `transport/internet/tcp` | `rawSettings` / `tcpSettings` |
| `xhttp` / `splithttp` | `…/splithttp` | §1 |
| `kcp` / `mkcp` | `…/kcp` | `header` и `seed` не читаются, см. §7.2 |
| `grpc` | `…/grpc` | `authority`, `serviceName`, `multiMode`, `idle_timeout`, `health_check_timeout`, `permit_without_stream`, `initial_windows_size`, `user_agent` |
| `ws` / `websocket` | `…/websocket` | `host`, `path`, `headers`, `heartbeatPeriod` |
| `httpupgrade` | `…/httpupgrade` | `host`, `path`, `headers` |
| `hysteria` | `…/hysteria` | §8 |
| `masque` | `…/masque` | §10; только с outbound `masque` |
| `xdrive` | `…/xdrive` | §9 |
| `h2`, `h3`, `http`, `quic` | — | удалены, ошибка с отсылкой на XHTTP |

Outbound-протоколы: `block`/`blackhole` (в HEAD — обёртка над freedom), `loopback`, `direct`/`freedom`, `http`, `shadowsocks`, `socks`, `vless`, `vmess`, `trojan`, `hysteria`, `masque`, `dns`, `wireguard`. Inbound: `tunnel`/`dokodemo-door`, `http`, `shadowsocks`, `mixed`/`socks`, `vless`, `vmess`, `trojan`, `wireguard`, `hysteria`, `masque`, `tun`. Протоколов TUIC, SSH, AnyTLS, ShadowTLS, Snell, Naive, Tor в исходниках Xray-core нет. [V]

---

## 7. finalmask

**Исходники.** `transport/internet/finalmask/` (`finalmask.go` и подкаталоги); конфиг — `infra/conf/transport_finalmask.go`. Каталог — с v26.1.23, ключ `finalmask` — с v26.2.6. [V git]

**Ключ.** `streamSettings.finalmask = { "tcp": [Mask], "udp": [Mask], "quicParams": {…} }`, `Mask = { "type", "settings" }`. [V] `transport_finalmask.go:1332–1336, 1463–1467`

Маски применяются на уровне сокета всеми транспортами (RAW, WS, HTTPUpgrade, gRPC, XHTTP TCP и H3, mKCP, Hysteria, MASQUE, XDRIVE) и outbound WireGuard — везде, где в коде есть `FinalMask.DialTCP`/`DialUDP`. [V] grep по `transport/internet`, `proxy/wireguard/client.go:149`

### 7.1. TCP-маски

| `type` | Каталог | Ключи `settings` | С версии |
|---|---|---|---|
| `fragment` | `fragment/` | `packets` (`"tlshello"`, `""`, диапазон `"1-3"`), `length`, `delay`, `lengths[]`, `delays[]`, `maxSplit` | v26.3.27 |
| `header-custom` | `header/custom` | `clients`, `servers`, `errors` — массивы шагов: `delay`, `rand`, `randRange`, `capture`, `type`, `reuse`, `transform`, `packet` | v26.2.6 |
| `sudoku` | `sudoku/` | `password`, `ascii`, `customTable`, `customTables`, `paddingMin`, `paddingMax` (есть старые имена со `_`) | v26.3.27 |
| `xmc` | `xmc/` | `hostname`, `profiles[]` (`username`, `uuid`, `texturesValue`, `texturesSignature`), `password`, `paddings[]`, `yggdrasil`, `noPadding` | v26.7.11 |
| `filter` | `filter/` | `blockedSourceIPs`, `allowedSourceIPs` (серверная) | v26.10.21 |
| `proxy-protocol` | `proxyprotocol/` | `version` (1 или 2, умолч. 2) | **только HEAD** |

### 7.2. UDP-маски

| `type` | Каталог | Ключи `settings` | С версии |
|---|---|---|---|
| `noise` | `noise/` | `reset`, `noise[]` (`rand`, `randRange`, `type`, `packet`, `delay`), либо `script` (Lua; вместе с `noise` нельзя) | v26.3.27 |
| `salamander` | `salamander/` | `password`, `packetSize` (если задан — вариант «gecko», 1…2048) | v26.1.23 |
| `udphop` | `udphop/` | `mode` (через запятую: `intervallocal`, `intervalremote`, `perconnremote`), `interval` (умолч. 30, минимум 5), `remoteIPs`, `remotePorts` | v26.9.9 |
| `mkcp-legacy` | `mkcp/` | `header` (`dns`, `dtls`, `srtp`, `utp`, `wechat`, `wireguard`), `value` (домен для `dns` либо пароль AES-128-GCM при пустом `header`) | v26.2.6 |
| `header-custom` | `header/custom` | `mode`, `client[]`, `server[]` | v26.2.6 |
| `sudoku` | `sudoku/` | как у TCP | v26.3.27 |
| `xdns` | `xdns/` | §7.4 | v26.2.6 |
| `xicmp` | `xicmp/` | `dgram`, `ips[]` | v26.2.6 |
| `realm` | `realm/` | `url` (`realm://токен@хост/id` или `realm+http://`), `stunServers[]` (обязателен), `tlsConfig`, `ipMode`, `portMapping` | v26.6.1 |
| `filter` | `filter/` | как у TCP | v26.10.21 |

`noise.type`: `array` (умолч.), `str`, `hex`, `base64`, `exp`. Для `exp` пакет — строка из сегментов `<b hex>`, `<r N|A-B>`, `<rc …>`, `<rd …>`, `<t>`, `<c>`, `<n>` (байты, случайные, случайные ASCII, случайные цифры, метка времени, счётчик, nonce). [V] `transport_finalmask.go:354–512`

### 7.3. `quicParams`

Ключи: `congestion` (`reno`, `bbr`, `brutal`, `force-brutal`), `debug`, `bbrProfile` (`conservative`/`standard`/`aggressive` — по именам констант `bbr.Profile*`), `brutalUp`, `brutalDown`, `brutalDisableLossCompensation`, `initStreamReceiveWindow`, `maxStreamReceiveWindow`, `initConnectionReceiveWindow`, `maxConnectionReceiveWindow` (не меньше 16384), `maxIdleTimeout` (4…120 с), `keepAlivePeriod` (2…60 с), `disablePathMTUDiscovery`, `disableChromeParrot`, `disableGSO`, `maxIncomingStreams` (≥ 8), `disableStatelessReset`. `force-brutal` требует `brutalUp`; `brutalUp`/`brutalDown` — не меньше 65536 байт/с. С v26.3.27. [V] `transport_finalmask.go:1358–1461`

`debug: true` выставляет переменные окружения процесса `HYSTERIA_BBR_DEBUG`/`HYSTERIA_BRUTAL_DEBUG`. [V]

Единицы `brutalUp`/`brutalDown` (тип `Bandwidth`, суффиксы до `t`/`tb`/`tbps`, результат делится на 8): в теге v26.11.9 множитель 1024, **в HEAD — 1000**. [V] diff `infra/conf/transport_method.go`

### 7.4. XDNS

**Найден.** Это UDP-маска finalmask типа `xdns` (не отдельный транспорт): `transport/internet/finalmask/xdns/` — `client.go`, `server.go`, `domain.go`, `frag.go`, `resolver.go`, `resolver_udp.go`, `resolver_tcp.go`, `resolver_doh.go`, `resp.go`. С v26.2.6. [V]

Ключи: [V] `transport_finalmask.go:864–965`
- `domains[]`: `names[]`, `lenLimit` (умолч. 255), `labelLimit` (умолч. 63), `types[]`, `edns0`, `alphabet` (**только HEAD**);
- `resolvers[]`: `addrs[]` (`udp://`, `tcp://`, `https://`; без схемы — UDP, порт по умолчанию 53), `worker` (умолч. 32), `tlsConfig`, `quicConfig`;
- `extraPoll` (0…3).

Клиент опрашивает резолверы: начальная задержка 500 мс, множитель 2, максимум 10 с, до 16 параллельных опросов (`xdns/client.go`, константы). [V]

**Мобильная значимость.** [U] Постоянный опрос DNS с периодом до 10 с и до 32 воркеров на резолвер — заметный расход батареи и крайне низкая пропускная способность; пригодно как аварийный канал, не как основной.

### 7.5. Прочее

- `xicmp`: клиент открывает ICMP-сокеты; при `dgram: true` — датаграммные (`icmp.ListenPacket("udp4", …)`), иначе сырые (`"ip4:icmp"`). [V] `xicmp/client.go:54–62`. Работают ли датаграммные ICMP-сокеты в песочнице расширения iOS — [U], не проверялось; сырые требуют привилегий.
- `realm`: обмен адресами через HTTP-сервис и STUN, пробивка NAT (`realm/punch.go`, `stun.go`, `portmap.go`). [V — состав; U — пригодность на сотовых NAT]
- `noise` со `script` тянет интерпретатор Lua (`common/lua`, `github.com/yuin/gopher-lua`); тот же механизм — у `routing.script` и `dns.script` (§12). [V]

**Мобильная значимость finalmask в целом.** [U] `fragment` с задержками увеличивает время установления каждого соединения; `noise` и `udphop` добавляют UDP-пакеты и таймеры (`udphop` — не чаще раза в 5 с); `salamander` — XOR на каждый пакет, цена мала.

**DomainModels.** Типизированной модели масок нет. Весь объект `finalmask` хранится сырым JSON в `EngineExtras` под ключом `finalmask` на уровне `Outbound`. Следствия:
- пароли `salamander`, `sudoku`, `xmc`, `mkcp-legacy.value` лежат открытым текстом в сыром JSON, мимо `SecretValue`/`SecretSlot` — `inlineSecretSlots` их не видит;
- у вложенного download XHTTP своего `finalmask` быть не может (нет `EngineExtras` на `StreamSettings`);
- `KCPSettings.seed`/`headerType` и `Hysteria2Settings.obfuscation`/`serverPorts` есть в модели как смысловые поля, но для Xray должны компилироваться в маски `mkcp-legacy`, `salamander`, `udphop` (ADR-0002 это предусматривает; компилятора пока нет).

---

## 8. Hysteria 2

**Исходники.** Протокол — `proxy/hysteria/`; транспорт — `transport/internet/hysteria/` (`dialer.go`, `hub.go`, `congestion/`); конфиг — `infra/conf/hysteria.go`, `HysteriaConfig` в `transport_method.go:764–769`. QUIC — форк `github.com/apernet/quic-go`. С v26.1.23. [V]

**Ключи.** [V]

```json
{
  "protocol": "hysteria",
  "settings": { "version": 2, "address": "example.org", "port": 443 },
  "streamSettings": {
    "network": "hysteria", "security": "tls",
    "tlsSettings": { "serverName": "example.org", "alpn": ["h3"] },
    "hysteriaSettings": { "version": 2, "auth": "пароль", "udpIdleTimeout": 60 },
    "finalmask": {
      "udp": [ { "type": "salamander", "settings": { "password": "…" } } ],
      "quicParams": { "congestion": "brutal", "brutalUp": "20 mbps", "brutalDown": "100 mbps" }
    }
  }
}
```

- `version` обязан быть `2` и в `settings`, и в `hysteriaSettings` (`version != 2` — ошибка). Hysteria 1 не поддерживается.
- `hysteriaSettings`: `version`, `auth`, `udpIdleTimeout` (2…600 с, умолч. 60), `masquerade` (серверный: `type`, `dir`, `url`, `rewriteHost`, `xForwarded`, `insecure`, `content`, `headers`, `statusCode`).
- TLS обязателен: `tls config is nil` (`transport/internet/hysteria/dialer.go:333`).
- Управление перегрузкой у клиента (`dialer.go:205–221`): `""`/`brutal` — Brutal при `brutalUp > 0` (ограничивается значением, объявленным сервером), иначе BBR; `bbr`; `reno`; `force-brutal`.
- Обфускация и смена портов — масками `salamander` и `udphop` (§7.2), отдельных ключей в `hysteriaSettings` нет.
- UDP поверх Hysteria реализован (`udpSessionManager` в `dialer.go`).

**Мобильная значимость.** [U] Только UDP — не работает в сетях, режущих UDP. Brutal игнорирует потери — на сотовой сети с переменной полосой даёт перерасход трафика и батареи, если `brutalUp` завышен. Окна приёма QUIC (`max*ReceiveWindow`) прямо определяют потребление памяти на соединение.

**DomainModels.** `ProtocolSettings.hysteria2(Hysteria2Settings { obfuscation, serverPorts, hopIntervalSeconds, uploadBandwidth, downloadBandwidth })`, пароль — в `Credentials.password`. Представимо; правило компиляции в Xray: `auth` ← пароль; `obfuscation` → `finalmask.udp[salamander]`; `serverPorts`+`hopIntervalSeconds` → `finalmask.udp[udphop]`; полосы → `quicParams.brutalUp/Down`. Соответствие семантики `udphop` смене портов Hysteria 2 — [U] (прочитан только разбор конфига). Не представлены: `udpIdleTimeout`, выбор `congestion`, `bbrProfile`, окна QUIC. В `Transport` нет случая для `hysteria` — используется `.native`.

---

## 9. XDRIVE

**Исходники.** `transport/internet/xdrive/` (`client.go`, `conn.go`, `drive.go`, `s3.go`, `template.go`, `local.go`, `storage.go`, `slots.go`, `wal.go`, `params.go`, `jsonpath.go`); конфиг — `XDriveConfig`, `transport_method.go:989–1088`; проверка — `validateXDrive` в `infra/conf/xray.go`. С v26.9.30. [V git]

Транспорт через объектное хранилище: стороны обмениваются сегментами-файлами в общей папке.

**Ключи** (`network: "xdrive"`, объект `xdriveSettings`): [V]

| Ключ | Значение |
|---|---|
| `service` | `"google-drive"` (старое `"Google Drive"` — с предупреждением), `"s3"`, `"template"`, `"local"` |
| `remoteFolder` | папка |
| `secrets[]` | для Google Drive ровно три: ClientID, ClientSecret, RefreshToken |
| `s3` | `endpoint`, `region`, `bucket`, `pathStyle` (умолч. `true`) |
| `template` | произвольный JSON-шаблон HTTP-API (обязателен для `service: "template"`) |
| `segmentBytes` | умолч. 512 КиБ, максимум 16 МиБ |
| `flushIntervalMs` | умолч. 20 |
| `pollIntervalMs` / `maxPollIntervalMs` | умолч. 50 / 500 |
| `sessionTtlSeconds` | умолч. 300 |
| `concurrency` | умолч. 8 (64 для хранилищ со слотами), максимум 256 |
| `eagerWindowMs`, `holeTimeoutMs` | умолч. 2000, 30000 |
| `xmux` | §5.3 |

**Требования к клиенту.** [V] `validateXDrive`
- только VLESS;
- `encryption` обязателен (не `none`);
- `flow` запрещён; `testpre` запрещён;
- Mux обязателен: в HEAD — `settings.multiplex.concurrency > 0` и не `xudpProxyUDP443: "skip"`; в теге — `mux.enabled`;
- при `alpn: ["h3"]` к Google Drive из UDP-масок допустима только `noise`; `brutal`/`force-brutal` запрещены.

**Мобильная значимость.** [U] Опрос хранилища каждые 50–500 мс всё время жизни сессии — постоянная активность радиомодуля; сегменты до 512 КиБ × `concurrency` в памяти; задержка сотни миллисекунд. Режим аварийной связности, не повседневный. Учётные данные хранилища (`secrets`) — долгоживущие секреты в конфиге.

**DomainModels.** Не представим: в `Transport` нет случая `xdrive`, в `EngineExtras` нет соответствующего ключа; `secrets` потребовали бы новых `SecretSlot`.

---

## 10. MASQUE

**Исходники.** `proxy/masque/`, `transport/internet/masque/`; конфиг — `infra/conf/masque.go`, `MasqueConfig` в `transport_method.go:806–814`. С v26.9.30. [V git]

- Outbound `settings`: `address`, `port`, `remoteDNS[]`. Транспорт `masqueSettings`: `host`, `path` (шаблон только с переменными `{target}` и `{ipproto}`), `user`, `pass`, `headers`, `warp` (`privateKey` — ECDSA P-256 в PEM или base64, `publicKey`, `address[]` — не более одного IPv4 и одного IPv6), `xmux`. `user`/`pass` вместе с `warp` нельзя. [V]
- Транспорт `masque` допустим только с outbound `masque` (`the masque transport can only be used by the masque outbound`). [V] `infra/conf/xray.go`

**DomainModels.** `ProxyProtocolKind.masque` есть, но настроек нет — только `ProtocolSettings.other(.masque)`. Не представим.

---

## 11. WireGuard

**Исходники.** `proxy/wireguard/` (`client.go`, `server.go`, `bind.go`, `tun_default.go` для не-Linux, `netstack.go`/gVisor); конфиг — `infra/conf/wireguard.go`. С v1.6.5. [V]

**Ключи outbound `settings`:** `secretKey`, `address[]`, `peers[]` (`publicKey`, `preSharedKey`, `endpoint`, `keepAlive`, `allowedIPs[]`), `mtu`, `reserved` (массив байтов), `remoteDNS[]`, `noKernelTun`. [V] `wireguard.go:17–69`

- На не-Linux используется пользовательский стек (`tun_default.go`, `//go:build !linux`). [V]
- Outbound WireGuard применяет UDP-маски finalmask к сокету пира (`client.go:149`) — так подключается, например, `noise`. [V]
- Для точки подключения берётся `Peers[0].Endpoint` (`client.go`, `bind.listenFunc`). [V]

**Мобильная значимость.** [U] Вложенный пользовательский сетевой стек (gVisor) внутри расширения, где уже есть TUN-inbound, — второй стек в памяти. `keepAlive` определяет частоту пробуждений.

**DomainModels.** `WireGuardSettings { peerPublicKey, localAddresses, allowedIPs, reserved, mtu, persistentKeepaliveSeconds }` + `Credentials.privateKey`/`preSharedKey` — один пир представим полностью. Не представлены: несколько пиров, `remoteDNS`, `noKernelTun` (на Apple не нужен). AmneziaWG (`amneziawg` в `ProxyProtocolKind`) в исходниках Xray-core отсутствует.

---

## 12. freedom: `fragment`, `noises`, `firewall`

**Исходники.** `proxy/freedom/freedom.go`; конфиг — `infra/conf/freedom.go`. [V]

**Ключи `settings`:** `targetStrategy` (псевдоним `domainStrategy`; `AsIs`, `UseIP[v4|v6|v4v6|v6v4]`, `ForceIP[…]`), `redirect`, `userLevel`, `fragment`, `noises`, `proxyProtocol`, `firewall`, `finalRules`, `ipsBlocked`. [V] `freedom.go:20–32`

| Ключ | Состояние в HEAD |
|---|---|
| `fragment` { `packets`, `length`, `interval`, `maxSplit` } | работает, но **устарел**: предупреждение, замена — TCP-маска `fragment` в `streamSettings.finalmask`. `length` и `interval` обязательны |
| `noises[]` { `type`: `rand`/`str`/`hex`/`base64`, `packet`, `delay`, `applyTo`: `ip`/`ipv4`/`ipv6` } | работает, **устарел**: замена — UDP-маска `noise` |
| `noise` (объект) | **удалён**, ошибка |
| `proxyProtocol` (1, 2) | устарел; в HEAD автоматически превращается в TCP-маску `proxy-protocol` |
| `firewall[]` { `action`: `allow`/`block`, `network`, `port`, `ip`, `delay`, `logLevel`, `reply` { `type`: `none`/`http`/`custom`, `customResponseData` } } | **только HEAD**; в теге это `finalRules` без `reply` |
| `finalRules` | в HEAD — устаревший псевдоним `firewall` |
| `ipsBlocked` | удалён, только предупреждение |
| `blockDelay` в правиле | устарел, замена `delay` |

Различие имён: в `freedom.fragment` задержка называется `interval`, в маске `fragment` — `delay`; в маске есть ещё `lengths[]`/`delays[]`. [V]

В HEAD outbound `blackhole`/`block` строит `freedom.Config` с одним блокирующим правилом и печатает предупреждение об устаревании; каталог `proxy/blackhole` удалён. [V] `infra/conf/blackhole.go`, diff

**Мобильная значимость.** [U] Фрагментация ClientHello на стороне клиента — основное применение на мобильных; цена — задержка на каждое новое соединение. Писать её следует маской finalmask на том outbound, который реально открывает сокет (в цепочке через `dialerProxy` — на последнем).

**DomainModels.** Outbound `freedom`/`direct` в модели отсутствует (`ProxyProtocolKind` его не содержит), фрагментация как смысловое поле не заведена. Через `EngineExtras["finalmask"]` маску `fragment` можно приложить к прокси-outbound; прямой outbound с фрагментацией выразить нечем.

---

## 13. TUN-inbound

Подробный разбор — `Documentation/Research/xray.md`, §2.10; здесь только ключи и отличия HEAD.

**Исходники.** `proxy/tun/` (`handler.go`, `stack.go`, `tcp_lightweight.go`, `udp_fullcone.go`, `tun_darwin.go`, `README.md`); конфиг — `infra/conf/tun.go`. Каталог — с v26.1.23, собственный облегчённый стек (`tcp_lightweight.go`) — с v26.10.21. [V git]

**Ключи `settings`:** `name`, `desc`, `guid` (**только HEAD**, только Windows), `mtu` (умолч. 1500), `gateway[]`, `dns[]`, `userLevel`, `autoSystemRoutingTable[]`, `autoOutboundsInterface`, `autoSystemDnsToGateway` (Linux/FreeBSD), `autoSystemWfpBlockLeak[]` (Windows). [V] `tun.go:17–29`

Дескриптор utun на iOS передаётся переменной окружения `xray.tun.fd` (`common/platform/platform.go:26`), её можно задать корневым объектом `env` конфига. [V]

В HEAD дополнительно: при закрытии inbound завершаются UDP-потоки и отменяются диспетчеризации (коммит `1c5a1fb`, `proxy/tun/udp_fullcone.go`, `handler.go`). Для расширения это влияет на корректность остановки туннеля. [V — наличие правки; U — эффект]

**Мобильная значимость.** [V/U] Свой стек без gVisor — меньше памяти, чем у tun2socks-схем [U]; ожидание через kqueue вместо busy-spin на Darwin [V, `tun_darwin.go`]; UDP Full Cone через XUDP [V, §5.2].

**DomainModels.** Inbound'ов в модели нет вовсе; параметры TUN (MTU, адреса, DNS) — зона туннельных настроек и компилятора, не `Profile`. Это не пробел модели узлов, но место для этих параметров пока не определено.

---

## 14. observatory, burstObservatory, балансировщики

**Исходники.** `app/observatory/` (`observer.go`), `app/observatory/burst/` (`healthping.go` и др.), `app/router/balancing.go`, `strategy_random.go`, `strategy_leastping.go`, `strategy_leastload.go`; конфиг — `infra/conf/observatory.go`, `router_strategy.go`, `router.go`. observatory и leastPing — с v1.5.1; burst и leastLoad — с v1.8.8. [V git]

**Ключи.** [V]

```json
"observatory": {
  "subjectSelector": ["proxy-"], "probeURL": "https://…", "probeInterval": "10s", "enableConcurrency": false
},
"burstObservatory": {
  "subjectSelector": ["proxy-"],
  "pingConfig": { "destination": "https://…", "connectivity": "", "interval": "1m",
                  "sampling": 10, "timeout": "5s", "httpMethod": "HEAD" }
},
"routing": { "balancers": [ {
  "tag": "auto", "selector": ["proxy-"], "fallbackTag": "direct",
  "strategy": { "type": "leastLoad",
    "settings": { "costs": [], "baselines": ["1s"], "expected": 1, "maxRTT": "0s", "tolerance": 0.0 } }
} ] }
```

- `strategy.type`: `random`, `roundRobin`, `leastPing`, `leastLoad` — других нет. Настройки есть только у `leastLoad`. [V] `router_strategy.go:14–26`
- `selector` и `subjectSelector` — **префиксы тегов** (`strings.HasPrefix`), не точные имена. [V] `app/proxyman/outbound/outbound.go:177`
- `observatory`: по умолчанию проба `https://www.google.com/generate_204`, интервал **10 с**, таймаут фиксированный 5 с. [V] `observer.go:76–79, 164–179`
- `burstObservatory`: `pingConfig` обязателен; по умолчанию `https://connectivitycheck.gstatic.com/generate_204`, интервал 1 мин (значения меньше 10 с поднимаются до 10 с), таймаут 5 с, метод `HEAD`. [V] `burst/healthping.go:64–78`
- `leastPing` и `leastLoad` требуют наблюдателя; `random` и `roundRobin` используют его, только если задан `fallbackTag`. [V] `strategy_leastping.go:24`, `strategy_random.go:23`, `balancing.go:34`
- Наблюдатель один на конфиг (корневые ключи), не на балансировщик.
- Ручной выбор узла в балансировщике — только через API: `RoutingService.OverrideBalancerTarget` (§15).

**Мобильная значимость.** [U], константа [V]: `observatory` с интервалом по умолчанию 10 с опрашивает каждый подходящий outbound каждые 10 секунд — это постоянные рукопожатия и пробуждения радиомодуля. Для мобильного клиента нужен `burstObservatory` с большим `interval` или внешнее управление пробами из Swift.

**DomainModels.** `OutboundGroup { kind: selector | urlTest | fallback | loadBalance, members, defaultMemberTag, healthCheck { url, intervalSeconds, timeoutMilliseconds, toleranceMilliseconds }, strategy }`. Соответствие неполное:

| Модель | Xray | Статус |
|---|---|---|
| `loadBalance` + `random` / `roundRobin` / `leastPing` / `leastLoad` | `strategy.type` | представимо |
| `consistentHashing` | — | в Xray нет |
| `urlTest` | `leastPing` + наблюдатель | приблизительно |
| `selector` | нет типа; только `OverrideBalancerTarget` во время работы либо генерация правила на конкретный тег | не представимо балансировщиком |
| `fallback` | нет типа; `fallbackTag` срабатывает только когда живых нет | не представимо напрямую |
| `members` (точные теги) | `selector` — префиксы | компилятор должен гарантировать, что тег не является префиксом чужого тега |
| `healthCheck` на группу | один наблюдатель на конфиг | разные URL/интервалы у групп невыразимы |
| `toleranceMilliseconds` | `leastLoad.tolerance` — доля отказов 0…1 | **другая семантика**, прямое копирование ошибочно |
| `timeoutMilliseconds` | только `burstObservatory.pingConfig.timeout` | у `observatory` не настраивается |
| — | `leastLoad`: `costs`, `baselines`, `expected`, `maxRTT` | полей нет |

---

## 15. API: stats, metrics, commander

**Исходники.** `app/commander/`, `app/stats/` (+`command/`), `app/metrics/`, `app/router/command/`, `app/proxyman/command/`, `app/observatory/command/`, `app/log/command/`; конфиг — `infra/conf/api.go`, `metrics.go`, `policy.go`. commander и stats — с v1.0.0; metrics — с v1.5.5. [V git]

**Ключи.** [V]
- `api`: `tag` (обязателен), `listen`, `services[]` — `ReflectionService`, `HandlerService`, `LoggerService`, `StatsService`, `ObservatoryService`, `RoutingService` (регистр не важен; неизвестное имя молча пропускается).
- `stats`: `{}` — включает счётчики.
- `policy.levels.<n>`: `handshake`, `connIdle`, `uplinkOnly`, `downlinkOnly`, `statsUserUplink`, `statsUserDownlink`, `statsUserOnline`, `bufferSize`.
- `policy.system`: `statsInboundUplink`, `statsInboundDownlink`, `statsOutboundUplink`, `statsOutboundDownlink`.
- `metrics`: `tag` и/или `listen` (хотя бы одно).

**gRPC-методы** (`*.proto`): [V]

| Сервис | Методы |
|---|---|
| `StatsService` | `GetStats`, `GetStatsOnline`, `QueryStats`, `GetSysStats`, `GetStatsOnlineIpList`, `GetAllOnlineUsers`, `GetUsersStats` |
| `RoutingService` | `SubscribeRoutingStats`, `TestRoute`, `GetBalancerInfo`, `OverrideBalancerTarget`, `AddRule`, `RemoveRule`, `ListRule` |
| `HandlerService` | `AddInbound`, `RemoveInbound`, `AlterInbound`, `ListInbounds`, `GetInboundUsers`, `GetInboundUsersCount`, `AddOutbound`, `RemoveOutbound`, `AlterOutbound`, `ListOutbounds` |
| `ObservatoryService` | `GetOutboundStatus` |
| `LoggerService` | `RestartLogger` |

**metrics** — HTTP: `/debug/vars` (expvar), `/debug/pprof/*` (`app/metrics/metrics.go:145–150`). В HEAD при остановке экземпляра закрываются HTTP-соединения metrics (коммит `e184d77`). [V]

**Требования к клиенту.** gRPC слушает TCP (`api.listen`) либо выводится через inbound с тегом `api`. В расширении iOS это означает листенер на loopback внутри процесса расширения и gRPC-клиент на стороне Swift — либо доступ к тем же данным через мост в процессе (у libXray такого вызова нет, см. `xray.md` §3.2). pprof наружу не открывать.

**Мобильная значимость.** [U] Счётчики трафика дёшевы; `statsUserOnline` и подписка `SubscribeRoutingStats` держат дополнительное состояние. Опрос статистики таймером из приложения будит расширение — интервал выбирать с учётом батареи.

**DomainModels.** Вне модели профиля (это свойства запуска ядра, не узла). Возможностям соответствует слой `CoreAbstraction`; полей не требуется.

---

## 16. Прочее, найденное в исходниках

| Возможность | Где | Ключи / суть | С версии |
|---|---|---|---|
| VLESS Reverse | `proxy/vless/reverse/` (HEAD), в теге — `app/reverse/` | `settings.reverse { tag, sniffing }` у VLESS outbound; корневой `reverse` в HEAD — ошибка «removed feature» | v25.9.11; перенос — HEAD |
| `testpre`, `testseed` | `infra/conf/vless.go`, `outbound.go:194` | предварительные соединения VLESS | v25.12.8 |
| `sockopt` | `infra/conf/transport_sockopt.go`, `transport/internet/sockopt_darwin.go` | `dialerProxy`, `domainStrategy`, `interface`, `tcpFastOpen`, `tcpKeepAliveInterval`/`Idle`, `tcpMptcp`, `tcpCongestion`, `tcpWindowClamp`, `tcpMaxSeg`, `tcpUserTimeout`, `mark`, `tproxy`, `penetrate`, `v6only`, `customSockopt[]`, `addressPortStrategy`, `happyEyeballs { tryDelayMs, prioritizeIPv6, interleave, maxConcurrentTry }`, `trustedXForwardedFor` | `happyEyeballs` — v25.6.8 |
| Цепочки | `sockopt.dialerProxy` | `proxySettings` на outbound удалён (ошибка) | — |
| `sendThrough`, `targetStrategy` | `infra/conf/xray.go:204–212` | на уровне outbound; `sendThrough` принимает адрес, CIDR, `origin`, `srcip` | — |
| Сценарии Lua | `common/lua/`, `app/router`, `app/dns` | `routing.script` (несовместим с `rules` и `domainStrategy`), `dns.script`, `finalmask.udp[noise].script`; команда `xray lua` | `routing.script` — v26.10.21 |
| Geodata | `app/geodata/`, `infra/conf/geodata.go` | корневой `geodata { cron, outbound, assets[{ url, file }] }` — обновление баз самим ядром | v26.4.25 |
| Webhook в правилах | `app/router/webhook.go` | `rules[].webhook { url, deduplication, headers }` | v26.3.27 |
| Поля правил | `infra/conf/router.go:141–160` | `domain`, `ip`, `port`, `network`, `sourceIP`, `sourcePort`, `user`, `vlessRoute`, `inboundTag`, `protocol`, `attrs`, `localIP`, `localPort`, `process`, `localOS`, `webhook`, `ruleTag`, `balancerTag`, `outboundTag` | — |
| DNS | `app/dns/`, `infra/conf/dns.go` | серверы: `localhost`, `https://`, `h2c://`, `tcp://`, `udp://`, `udp+local://`, `fakedns` (и др. в `nameserver.go`); `serveStale`, `serveExpiredTTL`, `enableParallelQuery`, `useSystemHosts`, `disableFallbackIfMatch`, `finalQuery`, `unexpectedIPs` | `udp://`, `udp+local://` — HEAD |
| DNS outbound | `proxy/dns`, `infra/conf/dns_proxy.go` | `rules[{ action, qType, domain, rCode }]`, `rewriteNetwork/Address/Port`; `nonIPQuery`, `blockTypes` устарели | — |
| FakeDNS | `infra/conf/fakedns.go` | `ipPool`, `poolSize` | — |
| loopback | `proxy/loopback` | `inboundTag`, `sniffing` | v1.5.1 |
| Sniffing | `infra/conf/xray.go:63–70` | `enabled`, `destOverride`, `domainsExcluded`, `ipsExcluded`, `metadataOnly`, `routeOnly` | — |
| Browser dialer | `transport/internet/browser_dialer/` | переменная `xray.browser.dialer`; для XHTTP и WS без REALITY | v1.8.17 |
| Проверка версии | `infra/conf/version.go` | корневой `version { min, max }` | — |
| Строгий JSON | `infra/conf/serial/builder.go` | переменная `xray.json.strict=true` — без вырезания комментариев | — |
| Shadowsocks 2022 | `proxy/shadowsocks_2022/` | `method`, `password`, `address`, `port` | v1.5.6 |

Отпечатки uTLS (`fingerprint`): рекомендуемые `chrome`, `firefox`, `safari`, `ios`, `android`, `edge`, `360`, `qq`, `random`, `randomized`, `randomizednoalpn`, `unsafe` (только TLS); плюс поимённые `hello…`. [V] `transport/internet/tls/tls.go:254–268`

Удалено или устарело на HEAD (ошибка либо предупреждение при загрузке): [V] grep `PrintRemovedFeatureError`/`PrintDeprecatedFeatureWarning`

| Что | Реакция | Замена |
|---|---|---|
| `tlsSettings.allowInsecure: true` | ошибка | `pinnedPeerCertSha256`, `verifyPeerCertByName` |
| `network`: `h2`/`h3`/`http` | ошибка | XHTTP `stream-one` H2/H3 |
| `network: "quic"` | ошибка | XHTTP `stream-one` H3 |
| `security: "xtls"` | ошибка | `xtls-rprx-vision` |
| `flow` у Trojan | ошибка | — |
| outbound `proxySettings` | ошибка | `sockopt.dialerProxy` |
| корневой `transport` | ошибка | `streamSettings` |
| корневой `reverse` (HEAD) | ошибка | VLESS Reverse |
| `freedom.noise` (объект) | ошибка | `noises[]` / маска `noise` |
| outbound `mux` (HEAD) | предупреждение, игнор | `settings.multiplex` |
| `freedom.fragment`, `noises`, `proxyProtocol`, `finalRules` | предупреждение | маски finalmask, `firewall` |
| outbound `blackhole` (HEAD) | предупреждение | freedom с правилом `block` |
| `kcpSettings.header`/`seed` | молча не читаются | маска `mkcp-legacy` |

---

## 17. Что есть в HEAD, но не в теге v26.11.9

Получено `git log v26.11.9..e17392a` (36 коммитов) и diff по `infra/conf`, `proxy`, `app`, `transport`. [V]

**Меняют формат конфигурации:**

1. `settings.multiplex` у VLESS/VMess; outbound `mux` игнорируется; `common/mux` удалён, код в `proxy/vless/multiplex` (`e17392a`, #7364).
2. Обратный прокси перенесён в VLESS: `app/reverse` удалён, корневой `reverse` → ошибка (`e17392a`).
3. freedom: `finalRules` → `firewall`, новое `reply`; `blackhole` слит с freedom; `proxyProtocol` → TCP-маска `proxy-protocol` (`7daa8e4`, #7281).
4. Новая TCP-маска `proxy-protocol` (`transport/internet/finalmask/proxyprotocol/`).
5. XDNS: `domains[].alphabet` (`15b2499`, #7457); воркеры для TCP-резолвера (`14df073`, #7354).
6. XMC: `paddings[]` (`direction`, `length`, `delay`), `yggdrasil`, `noPadding`; переход на «native frame padding» помечен в сообщении коммита как **breaking** — маска XMC HEAD несовместима с XMC тега (`f781c68`, `5d17b87`, `5225121`, `a32023b`, `82b5b76`).
7. TUN: `guid` для Wintun (`d9131d3`).
8. DNS: схемы `udp+local://` и `udp://` (`381e450`).
9. Единицы `Bandwidth` (`brutalUp`/`brutalDown`): 1024 → 1000 (`f082058`, «Hysteria transport: Proper Brutal behavior»).
10. Удалена переменная окружения `xray.cone.disabled` (`ce074ce`).

**Меняют поведение без изменения формата:**

- uTLS: `random` выбирается только из отпечатков с X25519MLKEM768 (`b1dfdf2`).
- TUN: завершение UDP-потоков и отмена диспетчеризаций при закрытии inbound (`1c5a1fb`).
- Outbounds: защита от циклической зависимости со встроенным DNS (`8f0bb9f`).
- XHTTP/3-клиент: закрытие UDP-сокета при неудачном QUIC-наборе (`8e07407`); HTTPUpgrade-клиент: закрытие соединения при неудачном апгрейде (`3dee851`).
- Mux для XDRIVE: `maxConcurrency` до 128 (`36cc9ff`); `MutexWriter` → `BufferedWriter` (`c43ee98`).
- DNS: блокировка в TCP-обработчике DNS outbound (`8c7447f`), кэш не мутируется при очистке (`febc082`).
- Metrics: закрытие HTTP-соединений при остановке (`e184d77`).
- Darwin: настоящая ошибка ioctl из `OriginalDst` (`09b1b07`).
- gRPC: буфер стандартного размера (`f73471e`); UDP-диспетчер: устранена гонка (`b190508`).
- Сборка: чистка build-тегов (`c456141`); обновления зависимостей (`x/net`, `blake3`, `klauspost/compress`).

**Вывод для проекта.** Мост сейчас логично собирать на теге v26.11.9 (его же закрепляет libXray). Тогда компилятор конфигурации должен выдавать `mux` на уровне outbound и `finalRules`, а не `settings.multiplex` и `firewall`. Поскольку HEAD и тег отдают одинаковый номер версии, форму конфига надо привязывать к закреплённому SHA ядра в сборке (возможность движка в `CoreCapabilities`), а не к строке версии.

---

## 18. Сводка по DomainModels

| Возможность | Представимость |
|---|---|
| XHTTP: `path`, `host`, `mode`, раздельный download | типизированно |
| XHTTP: паддинг, `xmux`, `sc*`, `headers`, размещение | только сырой `xhttp.extra` |
| REALITY (клиент), включая `mldsa65Verify` | типизированно, полностью |
| TLS: SNI, ALPN, отпечаток, ECH, пиннинг | типизированно |
| TLS `allowInsecure` | есть в модели, **в Xray запрещено** |
| Vision `flow` | строка, без проверки |
| VLESS `encryption` | строка, без проверки |
| Mux (`mux` / `settings.multiplex`) | **нет** |
| XUDP | ключей нет (автоматически); `packetEncoding` модели к Xray не относится |
| finalmask (все маски, `quicParams`) | только сырой JSON на уровне outbound; секреты мимо `SecretValue` |
| Hysteria 2 | типизированно; нужна компиляция в маски и `quicParams` |
| WireGuard, один пир | типизированно |
| XDRIVE | **нет** |
| MASQUE | **нет** (только имя протокола) |
| freedom / `fragment` / `firewall` | **нет** (нет прямого outbound) |
| TUN-inbound | вне модели профиля |
| Балансировщики | частично; `selector`, `fallback`, `consistentHashing` в Xray нет; `tolerance` — другая семантика |
| observatory | один на конфиг; `HealthCheck` на группу шире, чем умеет ядро |
| stats / metrics / API | вне модели профиля |
| `sockopt` (включая `dialerProxy`, `happyEyeballs`) | **нет** |

Предлагаемые изменения модели (решение — за владельцем модуля, здесь только перечень):

1. Типизированный мультиплексор на `Outbound`.
2. `EngineExtras` (или эквивалент) на `StreamSettings`, чтобы вложенный download XHTTP мог нести `sockopt`/`finalmask`.
3. Диагностика компиляции для `allowInsecure` и для Vision поверх не-RAW транспорта без шифрования VLESS.
4. Слоты секретов для паролей масок finalmask либо типизация хотя бы `salamander`.
5. Уточнить `HealthCheck.toleranceMilliseconds` и запретить его прямой перенос в `leastLoad.tolerance`.

---

## 19. Не проверено

- Ничего не собиралось и не запускалось; все утверждения о поведении — чтение кода на `e17392a`.
- Минимальные версии ключей получены `git log -S` по одному файлу; ключ мог существовать раньше под другим путём — читать как «не позднее».
- Поведение тега v26.11.9 выведено из diff с HEAD, полные файлы тега не читались, кроме изменённых мест.
- Работа `xicmp` (в том числе `dgram`), `realm`, `xdns`, `xmc` в песочнице расширения iOS.
- Соответствие маски `udphop` смене портов Hysteria 2 на стороне реальных серверов.
- Все оценки памяти, батареи и пригодности для мобильных сетей.
- Что в теге неизвестный ключ `settings.multiplex` игнорируется без предупреждения.
