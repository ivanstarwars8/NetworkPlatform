# shoes (cfal/shoes) — аудит по исходникам

Дата проверки: 2026-11-25. Источник (клон только для чтения):

| Репозиторий | Коммит | Версия | Путь |
|---|---|---|---|
| cfal/shoes | `7680938b96a245a21d9e481ad009205b956e4436` (2026-11-16) | `0.3.8` (`Cargo.toml`) | `/root/.cache/np-research/shoes` |

Пометки: **[V]** — видно в исходнике или официальном документе, путь или URL указан; **[U]** — по памяти, из вторичного источника или не подтверждено сборкой.

Оговорка: ничего не собиралось и не запускалось (на хосте нет Rust, Xcode, macOS). Всё о размере, памяти, скорости и поведении на устройстве — только план измерений (раздел 10). Утверждений «Rust быстрее или экономнее Go» в документе нет: чисел нет.

Вопрос аудита: годится ли shoes как третий независимый движок платформы или как замена sing-box. Критерий — скорость и стабильность на устройствах Apple; сборки для App Store используют только публичные API.

---

## 1. Короткие выводы

1. **Это настоящая библиотека с C ABI, а не только бинарник.** `crate-type = ["rlib", "cdylib", "staticlib"]`, заголовок `include/shoes.h`, CI собирает `libshoes.a` под `aarch64-apple-ios` и `aarch64-apple-ios-sim`. [V] XCFramework, Swift-обёртки и примера приложения в репозитории нет — README это прямо говорит. [V]
2. **C ABI минимален: шесть функций.** Старт из YAML, стоп, «работает ли», версия, уровень лога, путь файла лога. Нет: проверки конфига, статистики, колбэка лога, текста последней ошибки, колбэка «движок остановился». [V] Запросы на статистику и last-error в FFI (#134, #135) закрыты без слияния. [V]
3. **TUN есть, стек — smoltcp (форк автора), вход — только файловый дескриптор.** Пакеты читаются `read()` и пишутся `write()/writev()` в отдельном потоке с `poll()`. Колбэчного входа пакетов нет. [V]
4. **Сам shoes fd не добывает** — ни KVC, ни перебора дескрипторов в коде нет; fd приходит в YAML полем `device_fd`. Но комментарии в исходнике рекомендуют хосту именно недокументированный KVC `packetFlow.value(forKeyPath: "socket.fileDescriptor")`. [V] То есть по utun fd shoes стоит ровно там же, где Xray и sing-box (риск R-08).
5. **Публичный путь возможен без правки движка, но с ценой.** Стек работает с любым датаграммным fd; документация прямо упоминает «header-less FD, including one bridged from the packet-flow API» с `packet_information: false`. [V] Значит, мост `readPackets`/`writePackets` ↔ `socketpair` реализуем целиком на публичных API. Цена — два лишних копирования и два лишних системных вызова на пакет в каждую сторону и код хоста в тракте данных (противоречит ADR-0003 «пакеты не проходят через Swift»). Скорость такого моста неизвестна. [U]
6. **Apple-поддержка в коде — только `target_os = "ios"`.** FFI-экспорты, запрет jemalloc, MTU 4064, отказ от системного DNS — всё под `cfg(target_os = "ios")`. Под macOS, tvOS, visionOS C-функции не экспортируются (компилируется заглушка). Нужен патч/форк. Крейт `tun 0.8.14` знает `ios` и `tvos`, но не `visionos`. [V]
7. **Клиентских протоколов много, и они покрывают основное из Xray-линейки:** VLESS (+Vision, +собственное шифрование VLESS), REALITY (с X25519MLKEM768 и ML-DSA-65), XHTTP (три режима, H1/H2/H3), VMess AEAD, Trojan, Shadowsocks/2022, Snell v3, Hysteria2, TUIC v5, AnyTLS, ShadowTLS v3, NaiveProxy, WireGuard, SOCKS5, HTTP. [V] Чего нет: uTLS-подобной имитации ClientHello браузера (TLS — rustls), ECH, gRPC, HTTPUpgrade, mKCP, Mux.Cool, раздельного download у XHTTP, Brutal у Hysteria2. [V]
8. **Лицензия MIT; GPL/LGPL/AGPL в зависимостях нет.** Единственный файловый копилефт — GotaTun (MPL-2.0), он линкуется на всех Unix безусловно. Необычное: `tun` под WTFPL. [V]
9. **Зрелость низкая для роли основного движка.** Один автор (492 из ~500 коммитов), девять релизов 0.3.x за шесть недель, клиенты Hysteria2 и TUIC появились в v0.3.7 (2026-11-08), в журнале изменений — ломающие правки формата конфига, пять поддерживаемых автором форков зависимостей (rustls, smoltcp, h3, hickory-dns, BLAKE3). Фаззинга нет. Тестов много (≈3500), есть interop с Xray и sing-box. [V]
10. **Вердикт.** Как **третий движок** — технически осуществимо, отдельным расширением по правилу ADR-0001, но только после сборочного и измерительного эксперимента и с собственным патчем/обёрткой. Как **замена sing-box** — нет: не покрывает его функций (группы в FFI-режиме, Clash API в FFI-режиме, uTLS, gRPC, ECH), моложе и держится на одном человеке. Единственное, чем shoes уже сейчас лучше sing-box для нас, — лицензия (MIT против GPL-3.0).

---

## 2. Что это за проект

- Язык Rust, edition 2024, `rust-version = "1.99.1"`, версия пакета `0.3.8`, `license = "MIT"`, `publish = false` (на crates.io не публикуется, потому что Cargo выбрасывает `[patch]` из опубликованных пакетов). [V — `Cargo.toml`]
- Описание в манифесте — «A multi-protocol proxy server». Изначально это серверный прокси; клиентская часть — «upstream proxy chaining» и TUN. [V — `Cargo.toml`, `README.md`]
- Объём: ≈220 тыс. строк Rust в `src/`. [V — `wc -l`]
- Формат конфигурации — **YAML собственной схемы** (список документов: серверы, TUN, группы клиентов, группы правил, DNS-группы, `global_settings`). Не совместим ни с JSON Xray, ни с JSON sing-box, ни с YAML Clash. [V — `examples/*.yaml`, `src/config/types/`]
- Обязательные патчи зависимостей в `[patch.crates-io]`: [V — `Cargo.toml`, `DEPENDENCIES.md`]

  | Крейт | Источник | Зачем |
  |---|---|---|
  | `rustls` =0.23.46 | `cfal/rustls` | REALITY поверх rustls |
  | `smoltcp` 0.14.0 | `cfal/smoltcp` | порядок ACK при ретрансмиссии в TUN и WireGuard |
  | `h3`, `h3-quinn` | `cfal/h3` | пустые DATA-кадры (нужны XHTTP), ограничение буферов |
  | `hickory-*` 0.26.3 | `cfal/hickory-dns` | восстановление транспорта DNS |
  | `blake3` 1.8.7 | `cfal/BLAKE3` | контексты для шифрования VLESS |
  | `nix` 0.31.3 | upstream-коммит | совместимость сокетов с iOS (nix#2821) |

---

## 3. Протоколы и транспорты

Источник истины — перечисления `ClientProxyConfig` (`src/config/types/client.rs:430`) и `ServerProxyConfig` (`src/config/types/server.rs:~733`). Клиентская сторона — то, что можно поставить в цепочку исходящего соединения (outbound).

### 3.1. Сводная таблица

| Протокол / транспорт | Клиент (outbound) | Сервер (inbound) | Примечание |
|---|---|---|---|
| VLESS | да | да | клиент: `vision`, `udp_enabled`, `h2mux`, `encryption` (собственное шифрование VLESS с возобновлением) [V — `client.rs:475`] |
| XTLS Vision | да | да | поле `vision` у VLESS и у REALITY; «legacy Vision over XHTTP» не поддержан [V — `client.rs`, `docs/.../protocols/xhttp.md:235`] |
| REALITY | да | да | клиент: `public_key`, `short_id`, `sni_hostname`, `cipher_suites`, `mldsa65_verify`; X25519MLKEM768 с откатом на X25519 [V — `client.rs:505`, `docs/.../protocols/reality.md`] |
| XHTTP / SplitHTTP | да | да | режимы `auto`, `packet-up`, `stream-up`, `stream-one`; версии `auto`, `h1`, `h2`, `h3` [V — `src/config/types/xhttp.rs:14–32`] |
| VMess (AEAD) | да | да | шифры `aes-128-gcm`, `chacha20-poly1305`, `none` [V — `README.md`, `client.rs:549`] |
| Trojan | да | да | **исходящий UDP не реализован** [V — `docs/.../protocols/wireguard.md:141`] |
| Shadowsocks, Shadowsocks 2022 | да | да | AEAD и `2022-blake3-*`; UDP; UDP-over-TCP (SagerNet UoT) [V — `README.md`, `tests/cases/integration/shadowsocks_*`] |
| Snell v3 | да | да | v2 не реализован [V — `README.md`] |
| Hysteria2 | да (с v0.3.7) | да | клиент: TCP, UDP, Salamander, port hopping; **Brutal нет**, `up_mbps`/`down_mbps`/0-RTT отвергаются; только на хопе 0 цепочки [V — `docs/.../protocols/hysteria2.md:30–60`, `CHANGELOG.md` v0.3.7] |
| TUIC v5 | да (с v0.3.7) | да | клиентский 0-RTT не поддержан [V — `docs/.../protocols/tuic.md:43`] |
| AnyTLS | да | да | пул сессий, UoT; часть кода взята из anytls-rs (MIT) [V — `client.rs`, `THIRD_PARTY_NOTICES.md`] |
| ShadowTLS v3 | да | да | обёртка над внутренним протоколом [V — `client.rs:535`] |
| NaiveProxy | да | да | HTTP/2 CONNECT с padding; собственная реализация, не Chromium-стек [V — `src/naiveproxy/`, `client.rs`] |
| WireGuard | да | да | userspace на GotaTun, только Unix; не может стоять не на нулевом хопе [V — `Cargo.toml`, `docs/.../protocols/wireguard.md`] |
| SOCKS5 | да | да | **исходящий — только CONNECT** (без UDP); входящий — с UDP ASSOCIATE [V — `wireguard.md:141`, `README.md`] |
| HTTP CONNECT | да (H1, H2) | да | [V — `client.rs:439`] |
| Mixed (HTTP+SOCKS) | — | да | [V — `server.rs:869`] |
| TLS | да | да | закрепление сертификата по отпечатку (`server_fingerprints`), клиентские сертификаты [V — `client.rs:201, 653`] |
| WebSocket | да | да | early data [V — `client.rs`, `CHANGELOG.md`] |
| Sudoku mask | да | да | совместим с FinalMask из Xray [V — `README.md`, `src/sudoku_mask/`] |
| QUIC как транспорт | да | да | quinn [V — `Cargo.toml`] |

### 3.2. Чего нет (проверено поиском по `src/` и документации)

- **Имитации отпечатка ClientHello (аналог uTLS)** — поиск `utls|chrome|safari|firefox|grease` в `src/config/types/tls.rs`, `client.rs`, `src/reality/`, `src/rustls_config_util*` совпадений не дал; слово fingerprint встречается только в значении «отпечаток сертификата сервера». [V — отрицательный результат поиска] Следствие: ClientHello будет отпечатком rustls. Насколько это заметно для фильтрации — не измерялось. [U]
- **ECH** — открытый запрос #24 с 2024 года. [V — issue tracker]
- **gRPC, HTTPUpgrade, mKCP** — в `src/` нет (KCP — открытый PR #126). [V]
- **Mux.Cool (Xray), smux, yamux** — нет; мультиплексирование только H2MUX (совместим с sing-box) и XUDP. [V — `docs/.../protocols/h2mux.md`, `xudp.md`]
- **XHTTP:** раздельный download, полный XMUX, расширенная обфускация placement/padding, собственные session ID — не поддержаны; неподдерживаемые опции отвергаются, а не игнорируются. [V — `docs/.../protocols/xhttp.md:234–236`]
- **QUIC BBR** — открытый запрос #107; у Hysteria2 используется CUBIC из quinn. [V]

### 3.3. UDP

- VLESS и VMess: XUDP включается автоматически при `udp_enabled: true`. [V — `xudp.md`]
- Shadowsocks, SOCKS5 (входящий), AnyTLS, NaiveProxy: UDP-over-TCP в формате SagerNet. [V — `README.md`]
- Hysteria2, TUIC: нативный UDP. [V]
- Trojan (исходящий) и SOCKS5 (исходящий) UDP не несут — не могут быть последним UDP-хопом. [V]
- В TUN маршрут UDP выбирается один раз на поток/назначение; очереди ограничены (128 пакетов на стадию), при переполнении пакеты отбрасываются. [V — `docs/.../config/tun.md:66–74`, `docs/.../routing/rules.md`]

### 3.4. Маршрутизация

- Правила «первое совпадение». Предикаты: `domain`, `domain_suffix`, `subdomains`, `domain_pattern`, `domain_keyword`, `domain_regex`, `ip_cidr`, `destination_port`, `destination_port_range`, `network` (tcp/udp), `protocol` (stun/dtls), `any_destination`; комбинаторы `all`, `any`, `not`. [V — `docs/.../routing/rules.md:269–296`]
- Сниффинг TLS SNI и HTTP Host для TCP (`sniff: true`). [V — `rules.md`, `src/sniff/`]
- Наборы правил: локальные и удалённые; в `src/rule_set/` есть разборщики `srs.rs`, `singbox.rs`, `mrs.rs`, `mihomo.rs`, `geodata.rs`, `json.rs`, `yaml.rs`, `binary.rs`. [V — список файлов; полнота совместимости форматов не проверялась — U]
- **В FFI-режиме удалённые наборы правил запрещены** («remote rule refresh requires the process runtime and is not supported by FFI»). [V — `src/ffi/common.rs:228–244`]

### 3.5. Цепочки и группы

- Многохоповые цепочки (`client_chain`), пулы на хопе, round-robin между цепочками. [V — `rules.md:176–215`]
- Типы групп: `round-robin`, `selector`, `url-test`. Тип `fallback` и `health_check` удалены (ломающее изменение). [V — `CHANGELOG.md`]
- **В FFI-режиме `url-test` запрещён** («url-test groups require the process runtime and are not supported by FFI»). [V — `src/config/validate.rs:60–69`]
- `selector` переключается через Clash-контроллер, а **Clash-контроллер в FFI-режиме запрещён** («Clash controller and cache configuration are not supported by the FFI lifecycle»). [V — `src/config/types/clash_api.rs:175–183`] Следствие: во встроенном режиме ручного выбора узла на лету нет — смена узла означает перезапуск с новым YAML.

### 3.6. DNS

- Апстримы: `system`, `udp://`, `tcp://`, `tls://`, `https://`, `h3://`; DNS через цепочку прокси; bootstrap; стратегия семейств адресов; статические `hosts`. [V — `docs/.../dns/configuration.md`]
- Fake-IP (по умолчанию выключен), перехват DNS на порту 53 в TUN (`dns_hijack`). [V — `docs/.../dns/fake.md`, `src/config/types/tun.rs`]
- **На iOS системный DNS не определяется намеренно**: «mobile host must supply underlying DNS via dns.servers; VPN system discovery is unsafe». Хост обязан передать серверы в конфиге. [V — `src/dns/system.rs:217–223`]

### 3.7. Горячая перезагрузка

В CLI — есть (наблюдение за файлами, SIGHUP, пятисекундный debounce). **Во встроенном режиме полного цикла перезагрузки нет**: «Embedded/FFI instances … have no full config reload loop». [V — `docs/.../operations/reload.md:20–23`]

### 3.8. Статистика

- Внутри есть учёт потоков и счётчики (`src/control/flows.rs`: `upload`, `download`, `totals`, `snapshot`), наружу они выходят через Clash API. [V]
- Через FFI наружу не выходит ничего. Трейт `PlatformCallbacks` с `on_started`, `on_stopped`, `on_traffic_update` объявлен в `src/tun/platform.rs`, но за пределами этого файла не используется нигде — мёртвая заготовка. [V — поиск по `src/`]

---

## 4. TUN и стек TCP/IP

### 4.1. Устройство

- TUN-вход есть: `src/tun/`. Стек — **smoltcp 0.14.0** (форк `cfal/smoltcp`), CUBIC, Nagle выключен, delayed ACK выключен, keepalive 28 с. [V — `Cargo.toml`, `src/ip_stack/mod.rs:37–49`]
- Стек крутится в **отдельном потоке ОС**, не в tokio: неблокирующие `libc::read`/`libc::write`/`libc::writev` по fd и ожидание через `poll()` на fd устройства и на «будильнике» (пара `UnixStream`). [V — `src/tun/tcp_stack_direct.rs:1–4, 480–750, 1003–1050`, `src/ip_stack/wake.rs`]
- TCP: `any_ip`, для каждого SYN создаётся сокет smoltcp. UDP и ICMP: UDP-пакеты из потока стека уходят в tokio через канал, ICMP echo обслуживает smoltcp. [V — `tcp_stack_direct.rs:500–600`]
- Пакетная обработка: до 64 пакетов за проход. [V — `MAX_PACKET_BATCH`]
- Сегментационный offload — только для устройства, созданного самим shoes на Linux; для переданного fd отключён. [V — `src/tun/tun_server.rs:136–150`]
- MTU по умолчанию на iOS — 4064 (комментарий ссылается на опыт sing-box: 4096 минус 32 байта `UTUN_IF_HEADROOM_SIZE`). [V — `src/config/types/tun.rs:186–199`]
- Отказ записи с `ENOSPC` на Apple (переполнена входная очередь utun) трактуется как потеря пакета, а не как фатальная ошибка. [V — `tcp_stack_direct.rs:1096–1100`]

### 4.2. Как входят пакеты: только fd

- В мобильном режиме `device_fd` обязателен: «TUN config missing device_fd - must be injected by caller» (`src/ffi/common.rs`), «TUN on iOS requires 'device_fd' from NEPacketTunnelProvider.packetFlow» (`src/config/validate.rs:2608–2615`). [V]
- fd проверяется `fcntl(F_GETFD)`, затем дублируется (`try_clone_to_owned`), владение исходным остаётся у хоста (`close_fd_on_drop = false` в FFI-пути). [V — `src/tun/mod.rs:137–150`, `src/ffi/common.rs:367`]
- На iOS и macOS для переданного fd по умолчанию ожидается 4-байтовый заголовок utun (`AF_INET`/`AF_INET6` big-endian); при чтении он проверяется, при записи добавляется через `writev`. Отключается `packet_information: false`. [V — `src/tun/mod.rs:493–512`, `tcp_stack_direct.rs:980–1035`]
- **Колбэчного интерфейса «дай пакет / возьми пакет» в TUN-входе нет.** Единственная реализация `smoltcp::phy::Device` для TUN — `DirectDevice` поверх fd. [V — `tcp_stack_direct.rs:277–415`]
- В `src/ip_stack/driver.rs` есть `QueueDevice` — устройство smoltcp поверх очередей в памяти. Оно обслуживает WireGuard (стек в роли инициатора соединений), а не TUN-вход. Это показывает, что вход без fd в принципе укладывается в архитектуру, но готового такого входа нет. [V]

### 4.3. Откуда берётся fd: точный ответ

- **В коде shoes нет ни одного приёма добычи fd.** Поиск по всему дереву (`utun`, `forKeyPath`, `valueForKeyPath`, `fileDescriptor`, `com.apple.net`, `getpeername`) находит только комментарии, документацию и обработку `ENOSPC`. Swift-, Objective-C- и Kotlin-файлов в репозитории нет. [V]
- **Комментарии в исходнике рекомендуют хосту недокументированный KVC:**
  - `src/tun/tun_server.rs:26` — `let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as! Int32`;
  - `src/tun/tun_server.rs:187` — `[[packetFlow valueForKeyPath:@"socket.fileDescriptor"] intValue]`. [V]
- Перебора дескрипторов с `getpeername`/`com.apple.net.utun_control` (приём WireGuardKit) в shoes нет — ни в коде, ни в комментариях. [V]
- Итог: штатный путь shoes на iOS **зависит от недокументированного получения fd на стороне хоста**, как и у Xray с sing-box. Преимущества перед ними по риску R-08 в штатной конфигурации нет.

### 4.4. Можно ли кормить пакетами через публичный API

Да, двумя способами; ни один не проверен запуском.

**Способ A — мост через `socketpair`, без правки движка.**

- Основание: стеку всё равно, что за fd, — тесты самого shoes гоняют его поверх `UnixDatagram::pair()` (`src/tun/tcp_stack_direct/tests.rs`, `src/tun/offload.rs:129`), а CI на macOS называет этот шаг «Run raw-FD and packet tests without a TUN device» (`.github/workflows/test.yml:219`). [V]
- Документация прямо предусматривает этот случай: «If an iOS or macOS app supplies a header-less FD, including one bridged from the packet-flow API, explicitly set `packet_information: false`». [V — `docs/src/content/docs/config/tun.md:83–87`]
- Схема: хост создаёт `socketpair(AF_UNIX, SOCK_DGRAM)`, один конец отдаёт в `device_fd`; цикл `packetFlow.readPackets` пишет каждый пакет в свой конец; второй цикл читает свой конец и вызывает `packetFlow.writePackets`. Все вызовы публичные. [U — схема не собиралась]
- Цена: см. 4.5. Плюс код хоста оказывается в тракте данных — это отступление от ADR-0003. Поведение при заполнении буфера сокета (у shoes запись с `EWOULDBLOCK`/`ENOBUFS` — тихая потеря пакета, `tcp_stack_direct.rs:1101–1107` [V]) и нужные размеры `SO_SNDBUF`/`SO_RCVBUF` на Darwin неизвестны. [U]

**Способ B — собственное устройство smoltcp с колбэками, патч движка.**

- Нужно: новая реализация `Device` (по образцу `QueueDevice`), замена ожидания `wake_rx.wait(device.fd, …)` на ожидание очереди, два новых экспорта C ABI (подать пакет; колбэк выдачи пакета). Оценка — несколько сотен строк в приватных модулях. [U — оценка по чтению `tcp_stack_direct.rs`, не по опыту]
- Экономит системные вызовы сокетной пары, но копирование из `NSData` во владение Rust остаётся.
- Это форк с сопровождением: модули `ip_stack` и внутренности `tun` приватные (`pub(crate)`), upstream меняется быстро.

### 4.5. Число копирований (по чтению кода, не по профилю)

Считаются копирования полезной нагрузки в пользовательском пространстве; копирование ядро↔пользователь в системном вызове указано отдельно.

**TCP, приложение → прокси (прямой fd):**

| № | Где | Что |
|---|---|---|
| с/в | `read()` → `PacketBuffer` из пула | ядро → пользователь (`tcp_stack_direct.rs:308–325`) |
| 1 | smoltcp ingress | полезная нагрузка сегмента → кольцевой буфер приёма сокета smoltcp |
| 2 | `pump_tcp`: `socket.recv` → `enqueue_recv_data` | буфер smoltcp → `recv_buffer` соединения (`src/ip_stack/mod.rs:86–90`, `tcp_conn.rs:99–102`) |
| 3 | `poll_read`: `dequeue_slice` | `recv_buffer` → буфер читателя tokio (`tcp_conn.rs:211–226`) |

Дальше — шифрование/кадрирование исходящего протокола и `write()` в сокет; это вне TUN-тракта и зависит от протокола.

**TCP, прокси → приложение (прямой fd):**

| № | Где | Что |
|---|---|---|
| 1 | `poll_write`: `enqueue_slice` | буфер писателя → `send_buffer` соединения (`tcp_conn.rs:254–268`) |
| 2 | `pump_tcp`: `socket.send` ← `dequeue_send_data` | `send_buffer` → буфер передачи smoltcp |
| 3 | `TxToken::consume` | буфер smoltcp → `tx_buffer` (сборка IP-пакета, `tcp_stack_direct.rs:448–455`) |
| с/в | `write()`/`writev()` | пользователь → ядро; заголовок utun добавляется через `writev` без копирования |

Итого **три пользовательских копирования на направление плюс одно в системном вызове**, и передача между двумя потоками (поток стека ↔ рабочие потоки tokio) под `parking_lot::Mutex` на каждое соединение. [V — по коду; фактическая цена не измерялась]

**UDP:** пакет передаётся из потока стека в tokio перемещением `PacketBuffer` через канал; `into_payload` копирует, если хранилище больше полезной нагрузки более чем вдвое или запрошено уплотнение. То есть ноль или одно копирование до протокольного слоя. [V — `src/ip_stack/packet.rs:58–68`, `src/tun/udp_manager.rs:90`]

**Надбавка способа A (мост через `socketpair`)** на каждое направление: `readPackets` отдаёт `NSData` (внутреннее копирование NE — [U]), затем `write()` в сокет (копирование в ядро) и `read()` движком (копирование из ядра) — **плюс два копирования и два системных вызова на пакет**, не считая того, что делает сам NetworkExtension. [U — по схеме, не измерено]

### 4.6. Память TUN-стека

- На каждый TCP-поток — четыре буфера по `tcp_buffer_size`; значение по умолчанию 128 КиБ, то есть **512 КиБ на соединение**; лимитов по умолчанию нет («Unlimited»). [V — `docs/.../config/tun.md:40–56`, `src/config/types/tun.rs:64–75`]
- Буферы выделяются сразу при создании сокета (`vec![0; buffer_size]`), а не по мере надобности. [V — `src/ip_stack/mod.rs:38–41`, `tcp_conn.rs:62–68`] Сколько из этого станет резидентной памятью (страницы нулей до первой записи) — зависит от аллокатора и не измерялось. [U]
- Для бюджета расширения около 50 МиБ это означает обязательную настройку: `tcp_buffer_size: 32768` и `tcp_memory_bytes` или `max_tcp_connections`. При исчерпании лимита новые SYN молча отбрасываются. [V — `tcp_stack_direct.rs:606–612`]

---

## 5. FFI и поддержка Apple

### 5.1. Что экспортируется

`include/shoes.h` (генерируется cbindgen 0.29.4, CI сверяет заголовок с кодом): [V]

```c
typedef bool (*ProtectSocketCallback)(int fd);
int   shoes_init(const char *log_level);
long  shoes_start(const char *config_yaml, ProtectSocketCallback protect_callback);
void  shoes_stop(long _handle);
bool  shoes_is_running(void);
const char *shoes_get_version(void);
int   shoes_set_log_file(const char *path);
```

Свойства, видимые в `src/ffi/ios.rs` и `src/ffi/common.rs`: [V]

- Один экземпляр на процесс: состояние в глобальных `static` (`TUN_SERVICE`, `INITIALIZED`, `LOG_FILE`); `shoes_start` при живом сервисе возвращает `-1`; «handle» всегда `1` и не используется.
- `shoes_start` возвращается сразу после создания рантайма; ошибки разбора конфига и запуска уходят только в лог. Узнать о них хост может лишь опросом `shoes_is_running()` и чтением файла лога.
- `shoes_stop` синхронный: сигнал, ожидание задачи до 5 с, затем `shutdown_timeout` рантайма до 5 с. Повторный старт после стопа предусмотрен (логгер переживает перезапуск).
- Лог — только в файл (на iOS stderr отключён). Колбэка нет.
- Конфиг обязан содержать ровно один TUN с `device_fd`; дополнительные локальные серверы (например, mixed) допускаются.
- `ProtectSocketCallback` вызывается для каждого исходящего сокета (`src/socket_util.rs:36, 88, 207`); на iOS хосту достаточно вернуть `true`. Привязка сокета к интерфейсу (`bind_interface`) на Apple не реализована — только Linux/Android. [V — `socket_util.rs:60–75`] Достаточно ли на iOS того, что сокеты процесса расширения идут мимо туннеля, — для shoes не проверялось. [U]

### 5.2. Чего не хватает для нашей границы адаптера (ADR-0001 §5)

| Нужно `TunnelEngine` | Есть в shoes | Что потребуется |
|---|---|---|
| `start(config, tun, limits)` с ошибкой | старт без результата | экспорт с синхронной валидацией или колбэком готовности/ошибки |
| `stop()` | есть | — |
| валидация конфига без запуска | только в CLI (`shoes check`); функции `load_config_str`, `compile_configs` существуют внутри | новый экспорт; учесть, что приложение у нас движок не линкует (ADR-0001), значит проверка возможна только в расширении |
| `snapshot()` — трафик, соединения, память | счётчики есть в `src/control/flows.rs`, наружу не выведены | новый экспорт поверх `control` |
| `events` — строки лога | только файл | колбэк или чтение файла хостом |
| `events` — фатальная остановка | нет | колбэк; сейчас — опрос `shoes_is_running()` |
| лимиты памяти | YAML: `resource_limits`, `global_settings` | передавать через конфиг |

Все дополнения лежат в приватных модулях крейта (`mod control`, `mod ffi::common`), поэтому делаются **только патчем внутри дерева shoes** — отдельным крейтом-обёрткой поверх `rlib` их не достать. Запрос «Usage as a library» (#116) и PR с открытием API (#160) открыты и не приняты. [V — `src/lib.rs`, issue tracker]

### 5.3. Целевые платформы в коде shoes

Все мобильные ветки завязаны на `target_os = "ios"`: [V — поиск `target_os` по `src/`, `Cargo.toml`]

- `src/ffi/mod.rs:42–53` — модуль `ios` (C-экспорты) компилируется только при `target_os = "ios"`; на остальных не-Android платформах подставляется `stub.rs` без экспортов. **Под macOS, tvOS и visionOS библиотека соберётся без C ABI.**
- `Cargo.toml:228` — jemalloc исключён только для `ios`/`android`/`msvc`; под tvOS и visionOS `tikv-jemallocator` попадёт в зависимости. Соберётся ли `tikv-jemalloc-sys` под эти цели — неизвестно. [U] (Глобальным аллокатором jemalloc назначается только в `src/main.rs`, то есть в бинарнике; библиотека использует системный аллокатор. [V])
- `Cargo.toml:224` — `hickory-resolver/system-config` включён для всего, кроме `ios`/`android`.
- `src/dns/system.rs:211–223`, `src/config/types/tun.rs:192`, `src/tun/tun_server.rs:102` — DNS и MTU.
- Крейт `tun 0.8.14`: модуль платформы есть для `ios` и `tvos` (`cfg(any(target_os = "ios", target_os = "tvos"))`), для `macos`, но **не для `visionos`**. [V — `meh/rust-tun` тег `v0.8.14`, `src/platform/mod.rs`] Под visionOS крейт, вероятно, не скомпилируется без патча. [U]

Вывод: для macOS, tvOS и visionOS нужен патч cfg-условий (по смыслу — заменить `target_os = "ios"` на `target_vendor = "apple"` там, где речь о встраивании) и, для visionOS, патч или исключение крейта `tun`. Объём небольшой, но это форк. [U — объём оценён по списку мест, сборка не проверялась]

CI upstream собирает только `aarch64-apple-ios` и `aarch64-apple-ios-sim` с `IPHONEOS_DEPLOYMENT_TARGET=16.0`; бинарники CLI — под `aarch64-apple-darwin` и `x86_64-apple-darwin`. Запуска на устройстве или симуляторе в CI нет — проверяется лишь, что `libshoes.a` не пуст. [V — `.github/workflows/mobile.yml`, `build.yml`]

### 5.4. Уровни поддержки целей в rustc

По странице «Platform Support» документации rustc (stable и nightly, прочитаны 2026-11-25): [V — https://doc.rust-lang.org/stable/rustc/platform-support.html, https://doc.rust-lang.org/nightly/rustc/platform-support.html]

| Цель | Уровень | std |
|---|---|---|
| `aarch64-apple-darwin` | Tier 1 with Host Tools | да |
| `x86_64-apple-darwin` | Tier 2 with Host Tools | да |
| `aarch64-apple-ios` | Tier 2 without Host Tools | ✓ |
| `aarch64-apple-ios-sim` | Tier 2 without Host Tools | ✓ |
| `x86_64-apple-ios` (симулятор Intel) | Tier 2 without Host Tools | ✓ |
| `aarch64-apple-tvos` | Tier 2 without Host Tools | ✓ |
| `aarch64-apple-tvos-sim` | Tier 2 without Host Tools | ✓ |
| `aarch64-apple-visionos` | Tier 2 without Host Tools | ✓ |
| `aarch64-apple-visionos-sim` | Tier 2 without Host Tools | ✓ |
| `x86_64-apple-tvos` | Tier 3 | ✓ |

- Tier 2 означает: цель ставится через `rustup target add`, сборка гарантирована, прохождение тестов — нет. [V — та же страница]
- Страница tvOS оговаривает: минимальная версия tvOS 10.0; `std::process::Command` ограничен `posix_spawn`; цели «новые и мало проверенные». [V — https://doc.rust-lang.org/nightly/rustc/platform-support/apple-tvos.html]
- Уровень rustc ничего не говорит о зависимостях с C-кодом: `aws-lc-sys` (собирается через `cc`/`cmake`) и `ring` под tvOS и visionOS не проверялись. [U] В `Cargo.lock` нет `bindgen`, то есть `aws-lc-sys` рассчитывает на готовые привязки; есть ли они для tvOS/visionOS — неизвестно. [V — отсутствие в lock; U — следствие]

### 5.5. XCFramework

- Готового нет: «This repository does not ship Kotlin wrappers, AARs, or XCFrameworks. Applications own their platform glue and packaging». [V — `README.md`]
- Сборка описана для двух целей: `cargo build --release --lib --locked --target aarch64-apple-ios` и `…-ios-sim`, результат — `target/<target>/release/libshoes.a` плюс `include/shoes.h`. [V — `README.md`, `mobile.yml`]
- XCFramework из набора `.a` и заголовка собирается `xcodebuild -create-xcframework` — штатный приём, для shoes не проверялся. [U]
- Профиль release: `opt-level = 3`, `lto = "fat"`, `strip = true`; стратегия паники не задана, то есть раскрутка стека (unwind). [V — `Cargo.toml`] Паника в потоке стека перехватывается `catch_unwind` (`tcp_stack_direct.rs:180`). [V] Что произойдёт при панике в задаче tokio, пересекающей границу FFI, — не проверялось. [U]
- Размер `libshoes.a` и вклад в размер расширения неизвестны. Для ориентира: статический CLI под MIPS — около 32 МиБ по README; это другая цель и другой состав, переносить число на iOS нельзя. [V — число; U — применимость]

### 5.6. Рантайм, потоки, аллокатор

- **tokio, многопоточный планировщик**, в FFI — жёстко `worker_threads(2)` (`src/ffi/ios.rs:149–153`). [V]
- Дополнительные потоки: поток стека smoltcp; поток записи файла лога (`src/logging/file.rs:85`); поток стека WireGuard, если используется (`src/ip_stack/driver.rs:162`); пул блокирующих задач tokio — создаётся по требованию (`spawn_blocking` в разборе конфига, DNS, fake-IP). [V] Верхняя граница блокирующего пула не переопределена, действует значение tokio по умолчанию (512 — [U], по памяти).
- Аллокатор в библиотеке — системный (jemalloc подключается только в `main.rs`). [V]
- Сборщика мусора нет; это свойство языка, а не измеренное преимущество.

### 5.7. TLS, криптография, QUIC

- **TLS — rustls 0.23.46, форк `cfal/rustls`** с правками под REALITY. Версия закреплена точно (`=0.23.46`); обновление rustls требует перебазирования форка. [V — `Cargo.toml`, `DEPENDENCIES.md`]
- **Криптопровайдер — aws-lc-rs 1.19.0 / aws-lc-sys 0.47.0** (C и ассемблер, сборка через `cc`/`cmake`). [V — `Cargo.toml`, `Cargo.lock`] По журналу изменений внутри — AWS-LC 5.12.0. [V — `CHANGELOG.md`]
- **ring 0.17.14 тоже в графе** — его тянут `hickory-proto`, `quinn-proto`, `rustls-webpki`. Две криптобиблиотеки в одном бинарнике. [V — `Cargo.lock`]
- BoringSSL и OpenSSL как отдельных зависимостей нет (`openssl-sys`, `boring` в lock отсутствуют). [V]
- Корневые сертификаты — встроенный набор `webpki-roots`; системное хранилище Apple для проверки серверов прокси не используется (в lock есть `rustls-platform-verifier` и `security-framework`, но их тянет `hyper-rustls`, а не код shoes). [V — `Cargo.toml`, `Cargo.lock`] Следствие: обновление корней = обновление движка.
- Постквантовое: `ml-kem 0.3.4` (X25519MLKEM768 для REALITY), ML-DSA-65. [V]
- **QUIC — quinn 0.11.12 / quinn-proto 0.11.19 / quinn-udp 0.5.16; HTTP/3 — h3 0.0.8 (форк).** [V]
- **WireGuard — gotatun 0.10.3** (Mullvad, наследник BoringTun от Cloudflare). [V]
- Экспортное регулирование: движок содержит нестандартную криптографию (REALITY, шифрование VLESS, Sudoku) — как и Xray. Последствия для декларации шифрования в App Store Connect здесь не оцениваются. [U]

---

## 6. Rust staticlib и Go c-archive в одном процессе

Правило проекта: один движок на процесс расширения (ADR-0001). Вопрос — что было бы, если бы shoes и Go-движок слинковали вместе.

| Аспект | Что известно | Пометка |
|---|---|---|
| Символы криптографии | в графе shoes два C-ядра (aws-lc, ring); оба, по документации своих проектов, префиксуют символы версией; в Go c-archive C-криптографии нет | [U] — не проверялось `nm` |
| Символы рантайма Rust | один Rust staticlib несёт свою копию std; конфликтуют два Rust staticlib между собой, а не Rust с Go | [U] |
| Имена экспортов | у shoes — `shoes_*`; пересечение с нашим мостом Xray исключается выбором имён | [V — `include/shoes.h`] |
| Обработчики сигналов | в FFI-пути shoes сигналы не трогает: `tokio::signal` используется только в `src/process.rs` (CLI). Go-рантайм в режиме c-archive ставит свои обработчики на процесс | [V] — про shoes; [U] — про Go |
| Потоки и планировщики | два независимых планировщика (tokio 2 потока + потоки shoes; горутины Go на GOMAXPROCS потоков) в процессе с малым числом ядер | [U] — эффект не измерялся |
| Память | две кучи без общего учёта: `SetMemoryLimit`/GC Go не видит выделений Rust, лимиты shoes (`resource_limits`) не видят кучу Go; бюджет расширения один | [V — структура; U — мегабайты] |
| TLS (thread-local) | модели совместимы на уровне ОС; конфликтов не известно | [U] |
| utun | оба движка хотят единолично читать один и тот же fd | [V] — следует из устройства обоих |

Вывод: формальных препятствий линковке в исходниках не видно, но совместный запуск бессмыслен (один utun, один бюджет памяти) и ничем не проверен. Ситуация принципиально отличается от пары «два Go-рантайма» (ADR-0001, вариант B — явно неподдерживаемый): здесь нет известного запрета, есть только отсутствие пользы. **Правило «один движок на расширение» применяется к shoes без изменений** — он становится третьим расширением (или третьим вариантом сборки), а Go в его процессе не будет вовсе.

Побочное следствие для сборки: Mac-сборщику понадобится третий тулчейн (Rust ≥ 1.99.1 с целями iOS/tvOS/visionOS, cmake для aws-lc-sys) рядом с двумя версиями Go.

---

## 7. Зрелость

| Показатель | Значение | Источник |
|---|---|---|
| Репозиторий создан | 2022-01-29 | [V — `gh api repos/cfal/shoes`] |
| Звёзды / форки | 1328 / 139 | [V — там же, 2026-11-25] |
| Коммитов всего | ≈501 | [V — заголовок `Link` API] |
| Авторы | `cfal` — 492 коммита; у остальных шести — по 1–2 | [V — `contributors`] |
| Релизы | 0.1.0 (2023-02) … 0.2.7 (2026-01-22) … пауза … 0.3.0 (2026-10-05) … 0.3.8 (2026-11-16): **девять релизов за шесть недель** | [V — `releases`] |
| Открытые issue и PR | 42 (из них 9 PR); закрытых issue — 67 | [V] |
| Тесты | ≈3548 атрибутов `#[test]`/`#[tokio::test]` в `src/` и `tests/` | [V — `grep`] |
| Interop в CI | REALITY против Xray v26.10.31; XHTTP; шифрование VLESS; H2MUX против sing-box; AnyTLS против эталонного узла; WireGuard против ядра Linux и независимых узлов | [V — `.github/workflows/`, `tests/`] |
| Фаззинг | каталога `fuzz/` нет, `cargo-fuzz`/`libfuzzer`/`afl` не упоминаются; есть «bounded rule property corpus» (`tests/rule_properties.rs`) | [V] |
| Тесты на Apple | macOS-раннер: TUN поверх сокетной пары, FFI, WireGuard, наблюдение за файлами. **На iOS — только компиляция** | [V — `test.yml:201–254`, `mobile.yml`] |
| Бенчмарки | внутренние замеры кодека Sudoku, селектора, перезагрузки; сквозной пропускной способности и TUN — нет | [V — `benches/README.md`] |

Сигналы из трекера: [V]

- #116 «Usage as a library» и PR #160 «expose client chain and server startup for library embedding» — открыты, не приняты: встраивание за пределами готового FFI не в приоритете автора.
- #134 «Add traffic stats callback to FFI», #135 «Add last-error reporting to FFI» — закрыты без слияния (у #127 «mobile build artifacts» слияние есть, 2026-04-26).
- #237 «更新太猛了吧» («слишком бурные обновления») — жалоба пользователя на темп.
- #288 — массовые ошибки TUIC (2026-11-09), через день после появления клиента TUIC.
- #149 — открытый PR «security: harden protocol parsing and resource limits» с 2026-06.
- #35 — `serde_yaml` устарел (в lock — `0.9.34+deprecated`). [V — `Cargo.lock`]

Стабильность конфигурации: в журнале изменений 0.3.x — несколько правок с пометкой «Breaking» (удалён тип группы `fallback` и `health_check`; `rule_group` → `rule_source_group`; смысл `client_chain: [a, b]` в DNS изменён с «альтернативы» на «последовательные хопы»; отвергнуты маски `*.x`; `global_limits` → `global_settings`). [V — `CHANGELOG.md`] Для нас это означает: компилятор конфигурации (ADR-0002) привязывается к конкретной версии shoes, и каждое обновление движка — проверка схемы.

Фактор автобуса: один. Пять форков зависимостей ведёт тот же человек; `DEPENDENCIES.md` описывает процедуру их перебазирования на несколько экранов. [V]

Качество инженерной дисциплины при этом высокое: точные закрепления, сверка заголовка cbindgen в CI, проверка лицензионных уведомлений в CI, attestations сборок, подробная документация ограничений («unsupported options are rejected rather than silently ignored»). [V]

---

## 8. Лицензии

### 8.1. Сам проект

MIT, © 2021–2023 Alex Lau. [V — `LICENSE`, `Cargo.toml`]

Заимствования внутри дерева: константы из Go `math/rand` (BSD-3-Clause, для Sudoku); части `src/anytls/` из anytls-rs (MIT). Оба с уведомлениями. [V — `THIRD_PARTY_NOTICES.md`]

### 8.2. Зависимости

`Cargo.lock` — 400 пакетов (все платформы, включая Windows и Android). Сводка по `licenses/dependencies.txt` (генерируется cargo-about 0.9.3, CI проверяет актуальность): [V]

| Лицензия | Пакетов | Примечание |
|---|---|---|
| Apache-2.0 (в основном выбор из «MIT OR Apache-2.0») | 275 | |
| MIT | 60 | |
| Unicode-3.0 | 19 | данные ICU |
| ISC | 9 | aws-lc-rs, aws-lc-sys, ring, rustls-webpki, untrusted, libloading, inotify |
| BSD-3-Clause | 4 | aws-lc-sys, subtle, curve25519-dalek, x25519-dalek |
| BSD-2-Clause | 4 | ip_network, ip_network_table, hyper-tungstenite, tikv-jemalloc-sys |
| 0BSD | 2 | smoltcp, managed |
| **MPL-2.0** | 1 | **gotatun 0.10.3** |
| **WTFPL** | 1 | **tun 0.8.14** |
| CC0-1.0 | 1 | notify |
| CDLA-Permissive-2.0 | 1 | webpki-roots (данные корневых сертификатов) |
| Zlib | 1 | foldhash |

Список допустимых лицензий в `about.toml` включает также `OpenSSL` и `Unlicense`, но пакетов под ними в сгенерированном списке нет. [V]

**GPL, LGPL, AGPL — нет.** [V — `about.toml` (список `accepted`), `licenses/dependencies.txt`] Упоминание GPL-3.0 с исключением GCC в `THIRD_PARTY_NOTICES.md` относится только к статическому бинарнику под MIPS и к Apple-сборкам не применимо. [V]

Значимые зависимости поимённо:

| Зависимость | Версия | Лицензия | Замечание |
|---|---|---|---|
| tokio | 1.54.1 | MIT | |
| rustls (форк) | 0.23.46 | Apache-2.0 / ISC / MIT | форк наследует лицензию upstream [V — `about.toml`: «Both patched crates use the license at their repository root»] |
| aws-lc-rs / aws-lc-sys | 1.19.0 / 0.47.0 | ISC, Apache-2.0, MIT, BSD-3-Clause (составная) | C-код AWS-LC |
| ring | 0.17.14 | Apache-2.0 AND ISC AND MIT | |
| quinn / quinn-proto | 0.11.12 / 0.11.19 | MIT OR Apache-2.0 | |
| h3 (форк) | 0.0.8 | MIT | |
| smoltcp (форк) | 0.14.0 | 0BSD | |
| hickory-* (форк) | 0.26.3 | MIT OR Apache-2.0 | |
| gotatun | 0.10.3 | **MPL-2.0** | |
| tun | 0.8.14 | **WTFPL** | |
| webpki-roots | 1.0.12 | CDLA-Permissive-2.0 | |
| blake3 (форк) | 1.8.7 | CC0-1.0 OR Apache-2.0 | [U — лицензия upstream по памяти; в сводке попал в Apache-2.0] |

### 8.3. Флаги

- **MPL-2.0 (gotatun).** Подключён безусловно для `cfg(unix)` — без feature-флага, отключить без патча нельзя, даже если WireGuard не нужен. [V — `Cargo.toml`: `[target.'cfg(unix)'.dependencies]`] MPL — копилефт на уровне файлов: обязанность — сохранить уведомления и дать доступ к исходникам MPL-файлов (shoes их не меняет, ссылка на архив upstream есть в `THIRD_PARTY_NOTICES.md`). На лицензию остального бинарника не распространяется. С условиями App Store MPL-2.0, в отличие от GPL, обычно считается совместимой. [U — юридическая оценка, не проверена юристом] Сверить с `LICENSE_AUDIT.md`: там уже есть позиция по MPL у зависимостей Go-движков.
- **WTFPL (tun).** Разрешительная, но нестандартная и не одобрена OSI; некоторые корпоративные политики её не принимают. Крейт нужен shoes только для создания устройства на десктопе — в FFI-пути с переданным fd `tun::create` не вызывается (`src/tun/mod.rs:137–150`). [V] При форке его можно исключить из Apple-сборки.
- **CDLA-Permissive-2.0 (webpki-roots).** Лицензия на данные; разрешительная.
- **Обязанность уведомлений.** README и `THIRD_PARTY_NOTICES.md` требуют от встраивающих приложений распространять пакет уведомлений (`licenses/dependencies.txt`, GotaTun, anytls-rs, COPYRIGHT стандартной библиотеки Rust). [V] Это запись в наш `THIRD_PARTY_NOTICES.md` и экран лицензий в приложении.

### 8.4. Следствия для App Store

- Движок под MIT без GPL в графе — по лицензии shoes подходит для варианта сборки «без GPL» так же, как Xray, и лучше, чем sing-box. [V — состав; U — итоговая юридическая оценка]
- Правила проекта о заимствовании (CLAUDE.md, раздел о лицензиях) перечисляют libXray и WireGuardKit как разрешённые источники; shoes туда не внесён. Новая зависимость допускается «только с проверенной лицензией» — этот раздел и есть первичная проверка; решение о включении остаётся за владельцем.
- Лицензия не решает вопрос API: штатный путь получения fd у shoes такой же недокументированный, как у остальных (раздел 4.3).

---

## 9. Оценка по двум ролям

### 9.1. Третий независимый движок

За:

- независимая реализация тех же протоколов на другом стеке (rustls, smoltcp, quinn) — сбой или блокируемый отпечаток одного движка не обязательно повторяется в другом; [V — состав; U — практическая польза]
- готовый C ABI и статическая библиотека под iOS без gomobile; [V]
- MIT без GPL; [V]
- единственный из трёх движков, чей TUN-вход уже сейчас работает с произвольным датаграммным fd и чья документация описывает мост от packet-flow API — то есть вариант «только публичные API» достижим без правки ядра; [V — возможность; U — пригодность по скорости]
- явные лимиты ресурсов в конфиге (`resource_limits`, `global_settings`). [V]

Против:

- FFI слишком беден для нашей границы адаптера; дополнять можно только патчем в приватных модулях быстро меняющегося upstream (раздел 5.2);
- macOS, tvOS, visionOS требуют патча cfg; visionOS — ещё и крейта `tun` (раздел 5.3);
- во встроенном режиме недоступны `url-test`, Clash-контроллер, удалённые наборы правил, горячая перезагрузка (разделы 3.4, 3.5, 3.7);
- нет имитации ClientHello — для сценариев, где важен отпечаток TLS (REALITY с `fingerprint` в терминах Xray), поведение отличается от Xray; [V — отсутствие; U — последствия]
- ещё один формат конфигурации для компилятора модели (ADR-0002) и ещё один тулчейн на сборщике;
- один автор, темп релизов и ломающие изменения (раздел 7);
- 512 КиБ на TCP-соединение по умолчанию — без настройки не укладывается в бюджет расширения (раздел 4.6).

Оценка: **осуществимо, но не раньше, чем после эксперимента** (раздел 10). По ADR-0001 это отдельное расширение / отдельный вариант сборки; правило «один движок на процесс» сохраняется.

### 9.2. Замена sing-box

Против sing-box shoes проигрывает по функциям, существенным для клиента: группы с автоматическим выбором и ручным переключением на лету (во встроенном режиме недоступны), командный канал и статистика через libbox, uTLS, ECH, gRPC, HTTPUpgrade, зрелая Apple-интеграция с `PlatformInterface`, подтверждённая эксплуатация на iOS/tvOS. [V — про shoes; про sing-box см. `Documentation/Research/singbox.md`]

Выигрывает по лицензии (MIT против GPL-3.0) и по наличию XHTTP, Vision и REALITY с постквантовым обменом — но это территория Xray, который у нас уже первый движок. [V]

Оценка: **как замена sing-box не годится.** Имеет смысл рассматривать shoes не «вместо sing-box», а как возможный **второй движок без GPL** рядом с Xray — если измерения покажут выигрыш и если владелец готов сопровождать форк.

---

## 10. Что нельзя узнать без сборки и измерений

Ничто из перечисленного не известно. Сравнение с Go-движками допустимо только на одном устройстве, одном сервере, одном протоколе и одном сценарии.

### 10.1. Сборочные эксперименты (до любых замеров)

| № | Эксперимент | Критерий |
|---|---|---|
| S-1 | `libshoes.a` под `aarch64-apple-ios` и `-ios-sim` из закреплённого коммита, Rust ≥ 1.99.1 | собирается; XCFramework линкуется в расширение |
| S-2 | То же под `aarch64-apple-darwin`, `aarch64-apple-tvos(-sim)`, `aarch64-apple-visionos(-sim)` | выяснить, что ломается: cfg FFI, `tun`, `tikv-jemalloc-sys`, `aws-lc-sys`, `ring`, `notify` |
| S-3 | Размер `libshoes.a` и прирост размера расширения после линковки и strip | число в МиБ рядом с мостом Xray и libbox |
| S-4 | `nm` на пересечение символов с Go c-archive (только как справка; совместная линковка не планируется) | список коллизий или их отсутствие |
| S-5 | Минимальная версия ОС: запуск на iOS 17.0 / tvOS 17.0 (ADR-0005) | старт без ошибок динамической линковки |
| S-6 | Патч FFI: синхронная ошибка старта, снимок статистики, колбэк лога и остановки | объём патча в строках; переносимость на следующий релиз upstream |

### 10.2. План измерений

| № | Что | Как | Зачем |
|---|---|---|---|
| M-1 | Память в покое | `phys_footprint` расширения после старта без трафика | базовая цена рантайма, rustls, двух криптобиблиотек, наборов правил |
| M-2 | Память под нагрузкой | пик `phys_footprint` при 50, 200, 500 одновременных TCP-потоках с `tcp_buffer_size` 128 КиБ и 32 КиБ; с лимитом `tcp_memory_bytes` и без | проверить расчёт «4 × буфер на поток» и резидентность заранее выделенных буферов |
| M-3 | Время старта | от `shoes_start` до первого прошедшего пакета; отдельно — разбор YAML с большим набором правил | сравнение с Xray/sing-box; бюджет времени `startTunnel` |
| M-4 | Пропускная способность TCP | загрузка и отдача через VLESS+REALITY+Vision, XHTTP (H2, H3), Hysteria2; Wi-Fi и сотовая сеть | основной критерий выбора |
| M-5 | То же через мост `socketpair` (способ A) | те же сценарии, `packet_information: false` | цена публичного API: насколько падает скорость и растёт CPU |
| M-6 | Пропускная способность и потери UDP | поток QUIC (HTTP/3 внутри туннеля), видеозвонок (STUN/DTLS), пакетный всплеск | очереди на 128 пакетов и тихие потери при переполнении |
| M-7 | Поведение при потерях и задержке | Network Link Conditioner: 1 %, 3 %, 5 % потерь; 100 и 300 мс RTT | качество TCP в smoltcp (CUBIC, форк с правкой ACK) против gVisor/системного стека у Go-движков |
| M-8 | MTU | 1500, 4064 и промежуточные | проверить унаследованное от sing-box значение 4064 для стека smoltcp |
| M-9 | Энергия и CPU | Instruments (Energy Log, Time Profiler): простой с поддержанием соединений, 30 минут видео, фоновый режим | пробуждения потока стека на `poll()`, таймеры keepalive (28 с на сокет) |
| M-10 | Смена сети | Wi-Fi ↔ сотовая, режим полёта, сон и пробуждение | переживают ли исходящие сокеты и QUIC-соединения; нужен ли перезапуск движка |
| M-11 | Остановка и перезапуск | серия быстрых start/stop; стоп под нагрузкой | укладывается ли `shoes_stop` (до 5 + 5 с) в бюджет `stopTunnel`; утечки fd и потоков |
| M-12 | Отказ | паника в задаче tokio, ошибка записи в utun, закрытие fd хостом | снимается ли туннель; видит ли хост остановку без колбэка |
| M-13 | Исчерпание лимитов | превышение `max_tcp_connections` | как ведут себя приложения при молчаливом отбрасывании SYN |
| M-14 | Отпечаток TLS | снять ClientHello shoes (TLS, REALITY) и сравнить с Xray/uTLS | оценить заметность для фильтрации; проверка с двух точек в целевой сети |
| M-15 | Совместимость | REALITY, Vision, XHTTP, Hysteria2 против наших действующих серверов Xray | interop в CI upstream сделан на Xray 26.10.x; наши версии и настройки могут отличаться |
| M-16 | Длительная стабильность | 24–72 часа на устройстве с обычным использованием | рост памяти, зависшие потоки, деградация после смен сети |

### 10.3. Что остаётся неизвестным даже после замеров

- Допустимость третьего packet-tunnel-расширения в одном приложении (эксперимент E-3 из ADR-0001 покрывает только два). [U]
- Реакция App Review на мост `readPackets`/`writePackets` против прямого fd — предмета спора здесь нет (мост публичен), но это не проверялось отправкой. [U]
- Долгосрочная судьба проекта при одном авторе. [U]

---

## 11. Что осталось непроверенным

1. Ничего не собрано: все утверждения о сборке под Apple, кроме факта наличия шагов в CI upstream, — [U].
2. Не проверено, что FFI-путь shoes реально работает на устройстве: CI upstream проверяет только непустоту `libshoes.a`.
3. Не проверено наличие готовых привязок `aws-lc-sys` для tvOS и visionOS и сборка `ring`, `tikv-jemalloc-sys`, `notify` под них.
4. Префиксы символов aws-lc и ring, поведение обработчиков сигналов Go в c-archive, предел блокирующего пула tokio — по памяти.
5. Совместимость разборщиков наборов правил (`srs`, `mrs`, geodata) с актуальными форматами sing-box и mihomo не проверялась.
6. Поведение XHTTP, REALITY и Hysteria2 против конкретных версий серверов, кроме закреплённых в CI upstream, не проверялось.
7. Юридическая оценка MPL-2.0 и WTFPL для App Store — без юриста.
8. Аудит сделан по одному коммиту ветки `master` (v0.3.8). При темпе девять релизов за шесть недель сведения устаревают быстро; перед любым решением сверить журнал изменений.
