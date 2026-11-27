# v2fly/v2ray-core, dae, Hysteria (официальная реализация) — аудит по исходникам

Дата проверки: 2026-11-25. Исходники (shallow clone, только чтение) в `/root/.cache/np-research/`:

| Репозиторий | Коммит | Дата коммита | Версия в исходнике |
|---|---|---|---|
| v2fly/v2ray-core | `ec5ce8ba78e8a70167b5b1f003287f1340ecc19a` | 2026-11-04 | 5.56.0 (`core.go:22`) |
| daeuniverse/dae | `0d85246c7aec30ca02bf82fcae213587f162de5c` | 2026-11-21 | последний релиз v2.1.3 (GitHub API) |
| HyNetworks/hysteria (модули `github.com/apernet/hysteria/{core,extras,app}/v2`) | `7040c16752192e1ba72ee251005809a6bd9c9fd6` | 2026-11-18 | последний релиз app/v2.14.0 (GitHub API) |
| XTLS/Xray-core (для сравнения) | `e17392a96e1727a5fdb8101ecdd9245dc488fea4` | 2026-11-24 | 26.11.9 |
| SagerNet/sing-box (для сравнения) | `6c65b2e6332769881d0c292718063a3c51d94f93` | 2026-11-24 | 1.15.0-alpha |

Метки достоверности (как в `xray.md` и `singbox.md`):

- **[V]** — VERIFIED: видел в исходнике (путь указан) либо получил из GitHub API (`gh api`, указано).
- **[U]** — UNVERIFIED: вывод, не подтверждённый сборкой или запуском; либо сведения, которых нет в клонах.

Ограничение аудита: на хосте нет Go и Xcode. Ничего не собиралось и не запускалось. Утверждений о скорости, памяти и стабильности в документе нет — они вынесены в раздел 6 как план измерений.

---

## 1. Короткие выводы

| Проект | Вердикт | Главная причина |
|---|---|---|
| v2fly/v2ray-core v5 | **не кандидат в движки; источник знаний о формате** для импортёра | TUN на Apple не работает напрямую с utun; нет REALITY, Vision, XHTTP; всё массовое уже покрыто Xray-core |
| dae | **неприменим как движок; источник идей** (без копирования кода) | Плоскость данных — eBPF в ядре Linux; `main.go` собирается только под Linux; AGPL-3.0 |
| Hysteria (официальная) | **не нужен отдельным движком; эталон протокола** для interop-тестов | Xray-core и sing-box уже содержат Hysteria2 с тем же набором функций; TUN официального клиента — на GPL-библиотеке sing-tun и без целей Apple |

1. Ни один из трёх проектов не добавляет третьего движка, оправданного критерием «скорость и стабильность на устройствах Apple». Это вывод по исходникам; измерений нет. [U]
2. v2fly важен другим: его JSON (v4 и v5) — формат, который импортёр конфигураций встретит в реальных файлах. Отличия от Xray JSON перечислены в 2.5.
3. У dae стоит заимствовать идеи: DSL маршрутизации, двухфазную маршрутизацию DNS, проверки связности по четырём классам сети, политики групп. Код под AGPL-3.0 — не копировать.
4. Официальный клиент Hysteria как библиотека (`core/client`) устроен чисто и встраивается легко, но это дало бы только Hysteria2 без остального. Xray-core включает его управление перегрузкой практически дословно (2 файла сверены `diff`).

---

## 2. v2fly/v2ray-core v5

### 2.1. Версия, лицензия, активность

- `go.mod`: `module github.com/v2fly/v2ray-core/v5`, `go 1.26.10`, `toolchain go1.27.3`. [V]
- Лицензия MIT (`LICENSE`, © 2015–2025 V2Fly Community). [V]
- Активность: 22 коммита в `master` с 2026-08-25 по дату проверки; за тот же период у Xray-core и sing-box не меньше 100 (предел страницы API). Источник — `gh api repos/<repo>/commits?since=2026-08-25`. [V]
- Четыре последних релиза (v5.54.1 … v5.56.0, последний 2026-11-01) помечены на GitHub как pre-release. [V — `gh api repos/v2fly/v2ray-core/releases`]
- Репозиторий не архивирован, последний push 2026-11-20. [V — GitHub API]

Проект живой, но темп ниже, чем у Xray-core. Качество изменений по числу коммитов не оценивается.

### 2.2. Что зарегистрировано

Источник — `main/distro/all/all.go` и короткие имена в `.proto` (`short_name`). [V]

| Категория | Состав |
|---|---|
| Proxy (v5, короткие имена) | inbound: `dokodemo-door`, `http`, `hysteria2`, `shadowsocks`, `socks`, `trojan`, `vless`, `vliteu`, `vmess`; outbound: `blackhole`, `dns`, `freedom`, `http`, `hysteria2`, `loopback`, `shadowsocks`, `shadowsocks2022`, `socks`, `trojan`, `vless`, `vliteu`, `vmess`, `wireguard` |
| Транспорты (v5) | `tcp`, `ws`, `grpc`, `h2`, `quic`, `kcp`, `httpupgrade`, `domainsocket`, `hysteria2`, `dtls`, `meek`, `mekya`, `request`, `gdocsviewer`, `rrpit`, `tlsmirror` |
| Безопасность | `tls`, `utls` (отдельный тип безопасности, `transport/internet/tls/utls`) |
| Сервисы | `router`, `dns`, `fakeDns`, `fakeDnsMulti`, `policy`, `stats`, `reverse`, `tun`, `backgroundObservatory`, `burstObservatory`, `multiobservatory`, `browser`, `commander`, `webcommander`, `restfulapi`, `instman`, `subscription`, `filesystemstorage`, `webrtc`, `log` |
| Балансировщики | `random`, `leastping`, `leastload` |

WireGuard: только outbound, комментарий в коде — «WireGuard Outbound is unreleased» (`main/distro/all/wireguard.go`). [V]

### 2.3. Сравнение с Xray-core

Проверено поиском по `*.go` обоих клонов и реестрами `infra/conf`. [V]

| Возможность | v2fly v5 | Xray-core |
|---|---|---|
| REALITY | нет (`grep -i reality` по `*.go` пуст) | есть |
| VLESS `flow` / `xtls-rprx-vision` | нет (grep пуст; в `infra/conf/v4/vless.go` поля `flow` нет) | есть |
| XHTTP / SplitHTTP | нет (grep пуст) | есть |
| finalmask (salamander, gecko, udphop, fragment, noise и др.) | нет | есть (`transport/internet/finalmask/`) |
| MASQUE, XDRIVE | нет | есть |
| Hysteria2 | proxy и транспорт через форк `github.com/v2fly/hysteria/core/v2` (последний push форка 2026-02-20 — GitHub API); полей obfs и port hopping в `transport/internet/hysteria2/config.proto` нет | собственный proxy и транспорт, obfs и hopping через finalmask |
| WireGuard | только outbound | inbound и outbound |
| TUN | сервис `tun` на gVisor; нативное устройство только Linux amd64/arm64 (см. 2.4) | inbound `tun` со своим стеком, поддержка darwin и готового fd |
| Транспорты `quic`, `h2` | есть | удалены (см. `xray.md` §2.2) |
| `domainsocket` | есть | в реестре транспортов отсутствует (`xray.md` §2.2) |
| Экспериментальные транспорты `meek`, `mekya`, `tlsmirror`, `dtls`, `rrpit`, `request` | есть, в `all.go` под заголовком «Developer preview transports» | нет |
| VLite (`vliteu`) | есть («Developer preview proxies») | нет |
| Менеджер экземпляров `instman`, менеджер подписок, REST API | есть («Developer preview») | нет аналогов в таком виде [U — в Xray поимённо не искал] |
| Отдельный формат конфигурации v5 | есть | нет, один JSON |

Следствие: v2fly не даёт ничего из того, на чём сегодня строятся массовые серверные конфигурации (VLESS + REALITY + Vision, XHTTP). То, что есть только у него, помечено самим проектом как preview.

### 2.4. TUN и платформы Apple

- Сервис `tun` (`app/tun/`) построен на gVisor (`app/tun/stack.go` импортирует `gvisor.dev/gvisor/pkg/tcpip/...`). [V]
- Нативное TUN-устройство реализовано только в `app/tun/device/gvisor/gvisor_linux.go` (`//go:build linux && (amd64 || arm64)`). Для всех остальных ОС `gvisor_others.go` возвращает ошибку `not supported`. [V]
- Поле `preopened_fd` в `app/tun/config.proto` существует, но обслуживается только Linux-реализацией; вариант `udp_bridge` готовый дескриптор прямо отвергает (`app/tun/device/udpbridge/udpbridge.go:55`). [V]
- Единственный путь для не-Linux — `udp_bridge`: пара UDP-портов на loopback, по одному IP-пакету в датаграмме. Комментарий в коде: «exchange raw IP packets with an external packet-tunnel provider» (`udpbridge.go`). Очередь по умолчанию 512 пакетов, максимум 4096. [V]

Что это значит для нас:

- Каждый пакет шёл бы `packetFlow` → Swift → UDP loopback → Go и обратно. Это противоречит правилу «пакеты не проходят через Swift» (ADR-0003) и добавляет два копирования и системный вызов на пакет. Цена в процентах не измерялась. [U]
- gVisor в процессе расширения — дополнительная память; Xray-core от gVisor в TUN ушёл на собственный стек (`xray.md` §2.10). Разница в мегабайтах не измерялась. [U]

Сборка и цели:

- CI собирает `darwin` (amd64, arm64) как обычный исполняемый файл (`.github/workflows/release.yml`, `release/friendly-filenames.json`). Целей iOS, tvOS, visionOS нет. [V]
- Скриптов `gomobile bind` или `-buildmode=c-archive` в репозитории нет (grep по дереву; единственное упоминание — `tool golang.org/x/mobile/cmd/gobind` в `go.mod`). [V]
- Есть пакет `main/v2binding`: глобальная переменная `binding`, служебный экземпляр с gRPC-командером на `127.0.0.1:10999`, загрузка `config.json` из каталога в формате `jsonv5`. [V] Это локальный листенер внутри расширения — нам не подходит.

Встраиваемость:

- API библиотеки тот же, что у Xray: `core.New(config)`, `Instance.Start()`, `Instance.Close()`, `core.StartInstance(format, bytes)` (`v2ray.go`, `functions.go`). [V]
- Глобальное состояние того же рода: `effectiveSystemDialer`, `effectiveListener` (`transport/internet/system_dialer.go:12`, `system_listener.go:18`); 279 функций `init()` в не-тестовом коде. [V]
- Повторный запуск и остановка в одном процессе — поведение не проверялось. [U]

### 2.5. Форматы конфигурации и требования к импортёру

У v2fly два формата, оба регистрируются в `main/distro/all/all.go`. [V]

**v4 JSON** (`infra/conf/v4/`, загрузчик `main/formats/formats.go`; поддерживает также TOML и YAML через `infra/conf/mergers`). Это исторический формат V2Ray, от которого произошёл Xray JSON.

**v5 JSON, `jsonv5`** (`infra/conf/v5cfg/`; расширения `.v5.json`, `.v5.jsonc` — `v5cfg/init.go`). Структура другая.

Корневые ключи: [V — теги `json:` в `infra/conf/v4/v2ray.go`, `infra/conf/v5cfg/skeleton.go`, `Xray-core/infra/conf/xray.go`]

| Формат | Корневые ключи |
|---|---|
| Xray | `log`, `routing`, `dns`, `inbounds`, `outbounds`, `policy`, `api`, `metrics`, `stats`, `reverse`, `fakeDns`, `observatory`, `burstObservatory`, `transport`, `env`, `version`, `geodata` |
| v2fly v4 | `log`, `routing`, `dns`, `inbounds`, `outbounds`, `inboundDetour`, `outboundDetour`, `inbound`, `outbound`, `transport`, `policy`, `api`, `stats`, `reverse`, `fakeDns`, `browserForwarder`, `observatory`, `burstObservatory`, `multiObservatory`, `services` |
| v2fly v5 | `log`, `dns`, `router`, `inbounds`, `outbounds`, `services`, `extension` |

Что должен уметь импортёр.

1. **Различать три формата до разбора.** Признаки v5: корневой ключ `router` вместо `routing`; в `streamSettings` ключи `transport`, `transportSettings`, `security`, `securitySettings`, `socketSettings` (`v5cfg/skeleton.go`) вместо `network` и `<имя>Settings`; всё, что в v4 было корневым (`policy`, `stats`, `reverse`, `fakeDns`, обсерватории, `tun`), лежит в `services` под коротким именем. [V]
2. **v5: «упрощённые» настройки протоколов.** Например, outbound `vless` в v5 — плоские `address`, `port`, `uuid` (`proxy/vless/outbound/config.proto`, `SimplifiedConfig`), без `vnext`/`users`. В v4 — `vnext[].users[]`. [V] Xray принимает `vnext`, но требует ровно один элемент и одного пользователя (`Xray-core/infra/conf/vless.go:298–306`), а также плоскую форму с `address`, `port`, `id` на верхнем уровне настроек. [V — поля в структуре; U — точные правила плоской формы не разбирал]
3. **Ключи потока, которых нет в Xray.** v4: `httpSettings` (транспорт `h2`/`http`), `dsSettings` (`ds`/`domainsocket`), `quicSettings` (`quic`), `gunSettings` (синоним gRPC, сеть `gun`), `hy2Settings` (сеть `hy2`/`hysteria2`) — `infra/conf/v4/transport_internet.go:300–314`. Xray транспорты `h2`, `http`, `quic` удалил и возвращает ошибку. Импортёр обязан сообщить о невозможности переноса на Xray, а не отбрасывать молча (ADR-0002). [V]
4. **Ключи потока, которых нет в v2fly.** `realitySettings`, `xhttpSettings`/`splithttpSettings`, `rawSettings`, `httpupgradeSettings` (в v4; в v5 транспорт `httpupgrade` есть), `hysteriaSettings`, `masqueSettings`, `xdriveSettings`, `finalmask`. Файл с ними — Xray JSON. [V]
5. **Hysteria2 описан по-разному.** v2fly v4: протокол `hysteria2` плюс сеть `hy2` с `hy2Settings` (`password`, `congestion` с `type`, `up_mbps`, `down_mbps`, `use_udp_extension`, `ignore_client_bandwidth`). Xray: протокол `hysteria` с `version: 2`, транспорт `hysteria` с `hysteriaSettings`, остальное в `finalmask`. Перевод не механический. [V]
6. **TLS.** v2fly: `pinnedPeerCertificateChainSha256`, `echConfig`, `echDohServer`, `verifyClientCertificate`, `certificate`/`key` как отдельные поля (`infra/conf/cfgcommon/tlscfg/tls.go`). Xray: `fingerprint`, `pinnedPeerCertSha256`, `verifyPeerCertByName`, `echConfigList`, `echServerKeys`, `curvePreferences`, `minVersion`/`maxVersion` (`Xray-core/infra/conf/transport_security.go:300–345`). Имена полей закрепления сертификата различаются; совпадает ли их семантика (цепочка или лист, кодировка) — не проверено. [V — имена; U — семантика]
7. **uTLS.** В Xray это поле `fingerprint` внутри `tlsSettings`/`realitySettings`. В v2fly v5 — отдельный тип безопасности `utls`. В v2fly v4 `security` принимает только `tls` (`transport_internet.go`, сравнение `EqualFold(c.Security, "tls")`); поиск `fingerprint` по `infra/conf/v4` и `tlscfg` пуст. [V]
8. **sockopt.** v2fly: `bindToDevice`, `rxBufSize`, `txBufSize`, `forceBufSize`, `mptcp`, `tcpFastOpenQueueLength` (`cfgcommon/socketcfg/socket.go`). Xray: `interface`, `dialerProxy`, `domainStrategy`, `tcpMptcp`, `tcpCongestion`, `happyEyeballs`, `customSockopt` и др. (`transport_sockopt.go`). Пересечение по именам — `mark`, `tcpFastOpen`, `tproxy`, `acceptProxyProtocol`, `tcpKeepAliveIdle`, `tcpKeepAliveInterval`. [V]
9. **Маршрутизация.** Общие поля правила: `domain`, `domains`, `ip`, `port`, `network`, `source`, `sourcePort`, `user`, `inboundTag`, `protocol`, `attrs`. Только v2fly: `domainMatcher` и стратегии балансировщика с настройками `leastload` (`baselines`, `costs`, `expected`, `maxRTT`, `tolerance`) — `infra/conf/synthetic/router/`. Только Xray: `ruleTag`, `sourceIP`, `localIP`, `localPort`, `process`, `vlessRoute`, `webhook`, `headers`, `url`, `deduplication`. [V]
10. **DNS.** Только v2fly: `cacheStrategy`, `fallbackStrategy`, `domainMatcher`, вложенный `fakedns`, `expectIps`. Только Xray: `enableParallelQuery`, `serveStale`, `serveExpiredTTL`, `useSystemHosts`, `unexpectedIPs`, `finalQuery`, `timeoutMs`; ожидаемые адреса — `expectedIPs` с синонимом `expectIPs`. Регистр ключа (`expectIps` против `expectIPs`) разный; чувствителен ли к нему разбор в каждом ядре — не проверено. [V — имена; U — регистр]
11. **Сниффинг.** Общее: `enabled`, `destOverride`, `metadataOnly`. Только Xray: `routeOnly`, `domainsExcluded`, `ipsExcluded`. [V]
12. **Устаревшие корневые ключи v4**: `inbound`, `outbound`, `inboundDetour`, `outboundDetour`, а также `allocate` и `domainOverride` во inbound. В Xray их нет. Встречаются в старых файлах. [V]
13. **Только v2fly**: `packetEncoding` у shadowsocks, trojan, hysteria2; `ota`, `ivCheck` у shadowsocks; `alterId`, `disableInsecureEncryption` у vmess (в структуре Xray `vmess.go` этих полей нет). [V]
14. **TOML и YAML.** v2fly принимает конфигурацию v4 в этих форматах; Xray — тоже через свои загрузчики. [V — v2fly; U — Xray, в этом аудите не проверял]

Практический вывод для `ConfigurationEngine`: нужен отдельный распознаватель «V2Ray v4», «V2Ray v5», «Xray», общий разбор для пересекающейся части v4/Xray и явный отчёт о непереносимых элементах в обе стороны. Разбор v5 — отдельная ветка: общего с v4 у него только имена протоколов.

### 2.6. Имеет ли смысл как отдельный движок

Нет. Основания, все по исходникам:

- на Apple его TUN требует моста через UDP loopback (2.4);
- нет REALITY, Vision, XHTTP (2.3);
- те же глобальные переменные и ограничения процесса, что у Xray, без компенсирующей пользы;
- его уникальные транспорты помечены как preview.

Сценарий, при котором вывод изменится: если понадобится совместимость с серверами на `meek`/`mekya`/`tlsmirror` или VLite. Тогда оценивать заново.

### 2.7. Лицензии зависимостей

Сам проект MIT. По `go.mod` прямых зависимостей под GPL/AGPL не видно: `gvisor.dev/gvisor`, `pion/*`, `quic-go/quic-go`, `apernet/quic-go`, `golang.zx2c4.com/wireguard`, `go.starlark.net`, `refraction-networking/utls`. [V — состав; U — лицензии каждого модуля в этом аудите не открывались, кроме `apernet/quic-go` и `v2fly/hysteria` — MIT по GitHub API]

Препятствий для App Store со стороны лицензии нет. [U — до полной сверки транзитивных зависимостей на машине сборки]

---

## 3. dae

### 3.1. Архитектура

- `go.mod`: `module github.com/daeuniverse/dae`, `go 1.27.0`; зависимости `github.com/cilium/ebpf`, `github.com/vishvananda/netlink`, `github.com/vishvananda/netns`, `github.com/safchain/ethtool`. [V]
- Плоскость данных — программа eBPF на C: `control/kern/tproxy.c` (4508 строк). Секции `tc/lan_egress_*`, `tc/lan_ingress_*`, `tc/wan_ingress_*` и карты BPF (`routing_map`, `domain_routing_map`, `conn_state_map`, `cookie_pid_map` и др.). [V]
- Принцип (`docs/en/how-it-works.md`): программа вешается на хук tc ядра Linux и делит трафик до входа в сетевой стек; имя процесса берётся на хуке cgroupv2; домен связывается с IP через перехваченный DNS. [V]
- Требования (`docs/en/README.md`): ядро не ниже 5.17 (из-за `bpf_loop`), опции `CONFIG_BPF`, `CONFIG_BPF_SYSCALL`, `CONFIG_BPF_JIT`, `CONFIG_CGROUPS`, `CONFIG_KPROBES`, `CONFIG_NET_CLS_BPF`, `CONFIG_DEBUG_INFO_BTF` и др. [V]
- `main.go` начинается с `//go:build linux`; `Makefile` экспортирует `GOOS=linux`; сборка требует clang для компиляции eBPF. [V]
- Пользовательская часть (`control/`, `component/`) — разбор конфигурации, DNS, группы узлов, проверки связности, исходящие протоколы через `github.com/daeuniverse/outbound` (в `go.mod` заменён директивой `replace` на `github.com/olicesx/outbound`). [V]

### 3.2. Может ли что-то работать на Apple

- eBPF, tc, cgroupv2, netlink, netns на Darwin отсутствуют. Плоскость данных не переносится. [V — зависимости и теги сборки; общеизвестный факт о платформе]
- Есть тег `dae_stub_ebpf` (`control/bpf_stub.go`), но это заглушка для сборки без скомпилированных объектов eBPF, с ошибкой «eBPF objects are unavailable in this build». Режимом работы без ядра она не является. [V]
- В `control/` есть файлы `*_other.go` рядом с `*_linux.go` (`tcp_copy_other.go`, `raw_udp_other.go`, `tcp_offload_other.go`). Это запасные ветки внутри Linux-программы, а не поддержка других ОС: точка входа всё равно `linux`. [V — теги; U — соберутся ли отдельные пакеты `component/*` под darwin]
- Библиотека протоколов `daeuniverse/outbound` в клоны не входит; её переносимость не проверялась. Лицензия AGPL-3.0 (GitHub API). [V — лицензия; U — переносимость]

Вывод: как движок неприменим ни целиком, ни частями.

### 3.3. Лицензия

- AGPL-3.0 (`LICENSE`; заголовки файлов `SPDX-License-Identifier: AGPL-3.0-only`). [V]
- Программа eBPF объявляет ядру `Dual BSD/GPL` (`tproxy.c:4427`), при этом заголовок файла — AGPL-3.0-only. [V]
- Для нас: код dae нельзя ни копировать, ни линковать — AGPL строже GPL-3.0, а даже GPL-3.0 для App Store остаётся открытым вопросом (`LICENSE_AUDIT.md` §4). Идеи и форматы лицензией не охраняются; реализовывать заново, не «близко к тексту».

### 3.4. Что стоит перенять (идеи, не код)

**Язык правил маршрутизации.** Файлы: `example.dae`, `docs/en/configuration/routing.md`, `pkg/config_parser/`, `common/consts/routing.go`. [V]

- Правило — булево выражение из функций со стрелкой на цель: `dip(geoip:cn) && dport(80) -> direct`, отрицание `!domain(...)`, итог `fallback: my_group`.
- Функции: `domain` (с ключами `full`, `suffix`, `keyword`, `regex`, `geosite:`), `dip`, `sip`, `dport`, `sport`, `l4proto`, `ipversion`, `mac`, `pname`, `dscp`.
- Перед исполнением правила проходят оптимизаторы: подстановка псевдонимов, слияние и сортировка, удаление дублей, раскрытие geo-файлов (`component/routing/optimizer.go`: `AliasOptimizer`, `MergeAndSortRulesOptimizer`, `DeduplicateParamsOptimizer`, `DatReaderOptimizer`).
- Польза для нас: компактное человекочитаемое представление правил в интерфейсе и экспорте и идея нормализующего прохода перед компиляцией в конфиг движка. На Apple `mac`, `pname`, `dscp` недоступны расширению — их в модель не вносить.

**DNS в две фазы.** Файлы: `docs/en/configuration/dns.md`, `component/dns/request_routing.go`, `component/dns/response_routing.go`, `component/dns/upstream.go`. [V]

- Фаза запроса: `qname(geosite:cn) -> alidns`, `fallback: googledns`. Функции `qname`, `qtype`.
- Фаза ответа: `upstream(googledns) -> accept`, `ip(geoip:private) && !qname(geosite:cn) -> googledns` — подозрительный ответ переспрашивается у доверенного сервера. Функции `qname`, `qtype`, `upstream`, `ip`; встроенные цели `accept`, `reject`.
- Схема адреса сервера задаёт транспорт: `udp://`, `tcp+udp://`, DoH3 и др. (`ParseRawUpstream`).
- Маршрутизация по домену строится на связке «домен ↔ IP из ответа DNS» без fake-IP; документ сам перечисляет ограничения подхода (`how-it-works.md`).
- Польза: модель «правила запроса + правила ответа» выразительнее одного списка серверов и ложится на `expectedIPs` Xray и правила DNS sing-box. Соответствие надо проектировать — прямого отображения нет. [U]

**Проверки связности.** Файлы: `component/outbound/dialer/connectivity_check.go`, `latencies_n.go`, `alive_dialer_set.go`; опции в `example.dae`. [V]

- Состояние «жив» и задержка ведутся раздельно по классам сети: `NetworkType{L4Proto, IpVersion, IsDns, UdpHealthDomain}` — то есть TCP/UDP × IPv4/IPv6 отдельно. Узел, у которого сломан только UDP или только IPv6, не выпадает целиком.
- Две пробы: `tcp_check_url` (HTTP, метод задаётся `tcp_check_http_method`) и `udp_check_dns` (DNS-запрос через узел). В URL можно дописать адреса, чтобы проба не зависела от DNS: `'http://cp.cloudflare.com,1.1.1.1,2606:4700:4700::1111'`.
- `check_interval` и `check_tolerance`: переключение только если новая задержка лучше старой на величину допуска (комментарий в `example.dae`). Это гасит «дребезг» выбора.
- Старт проверок разносится по времени (`initialConnectivityCheckJitterWindow`), работа идёт в общем пуле (`getConnectivityCheckPool`).
- Польза: раздельный учёт TCP/UDP и v4/v6 и гистерезис — прямо применимо к нашему тесту серверов и автовыбору. В расширении с лимитом памяти число параллельных проб надо ограничивать; значения подбираются измерением.

**Политики групп.** Файлы: `common/consts/dialer.go`, `component/outbound/dialer_selection_policy.go`, `example.dae`. [V]

- Политики: `random`, `fixed`, `min` (последняя задержка), `min_avg10` (среднее по 10 проверкам), `min_moving_avg` (скользящее среднее), `select` (ручной выбор с переключением на лету).
- Фильтры состава группы: `filter: name(HK_node)`, `filter: subtag(my_sub) && !name(keyword: 'ExpireAt:')` — отбор по имени и по подписке, с исключением служебных записей.
- Поправка к задержке на узел: `[add_latency: -500ms]` — ручной приоритет без отдельной политики.
- Переопределение параметров проверки на уровне группы (`tcp_check_url`, `check_interval`, `check_tolerance`).
- Цепочки в описании узла: `'tuic://LINK -> vmess://LINK'`.
- Польза: набор политик шире, чем `urltest`/`selector` sing-box и `leastPing`/`leastLoad` Xray. Группа и её политика должны жить в нашей модели (ADR-0002), а в движок компилироваться в то, что он умеет; чего движок не умеет — выполнять в control plane перезаписью конфигурации. Реализуемость второго пути без разрыва соединений не проверена. [U]

**Чего не перенимать:** привязку маршрутизации к имени процесса и MAC, `tproxy`, всё, что предполагает роль шлюза локальной сети.

---

## 4. Hysteria — официальная реализация

### 4.1. Структура и лицензии

- Три Go-модуля в одном workspace (`go.work`): `core`, `extras`, `app`; `go 1.26.0`. [V]
- Лицензия MIT (`LICENSE.md`, © 2023 Toby; отдельные `LICENSE.md` в каждом модуле). [V]
- `core/go.mod`: единственная содержательная зависимость — `github.com/apernet/quic-go v0.65.1-0.20261109005002-2895f039137a` (форк quic-go, MIT по GitHub API). [V]
- `extras/go.mod`: `tfo-go`, `expr-lang/expr`, `miekg/dns`, `pion/stun`, `libp2p/go-nat`, `txthinking/socks5`. [V — состав; U — лицензии не открывались]
- `app/go.mod`: `github.com/sagernet/sing` и `github.com/sagernet/sing-tun` — обе **GPL-3.0-or-later** (текст `LICENSE` получен через GitHub API; совпадает с `LICENSE_AUDIT.md`, строка 62). Плюс `certmagic`, `libdns/*`, `cobra`, `viper`, `zap`. [V]

Следствие: модули `core` и `extras` чистые (MIT). Модуль `app` линкует GPL-код, и его TUN-режим без этого кода не существует.

### 4.2. Клиент как библиотека (`core/client`)

Публичный API (`core/client/client.go`, `config.go`, `reconnect.go`): [V]

```go
func NewClient(config *Config) (Client, *HandshakeInfo, error)
func NewReconnectableClient(configFunc func() (*Config, error),
    connectedFunc func(Client, *HandshakeInfo, int), lazy bool) (Client, error)

type Client interface {
    TCP(addr string) (net.Conn, error)
    UDP() (HyUDPConn, error)
    Close() error
}
type HyUDPConn interface {
    Receive() ([]byte, string, error)
    Send([]byte, string) error
    Close() error
}
```

- `Config`: `ConnFactory` (подмена `net.PacketConn` — сюда вставляются obfs и port hopping), `ServerAddr`, `Auth`, `TLSConfig`, `QUICConfig`, `CongestionConfig`, `BandwidthConfig`, `FastOpen`. [V]
- Глобального состояния почти нет: функций `init()` в `core` нет, пакетные переменные неизменяемые. Исключение — чтение переменных окружения `HYSTERIA_BBR_DEBUG`, `HYSTERIA_BRUTAL_DEBUG`, `HYSTERIA_UDPHOP_DEBUG`. [V — grep по `core` и `extras`]
- `Close()` закрывает QUIC-соединение, `quic.Transport` и сокет (`client.go:240`). Несколько клиентов в одном процессе конструктивно допустимы. [V — код; U — утечки при многократном цикле не измерялись; тесты с `goleak` есть в `core/internal/integration_tests/stress_test.go` и `core/server/udp_test.go`]
- Пакеты протокола лежат в `core/internal/` и извне не импортируются. v2fly ради этого держит форк с каталогом `international` вместо `internal` (импорты `github.com/v2fly/hysteria/core/v2/international/protocol` в v2ray-core). [V]

Библиотека даёт только «открыть TCP-поток / UDP-сессию через сервер». Маршрутизации, DNS, TUN, статистики в ней нет.

### 4.3. QUIC и риск конфликта в одном бинарнике

| Проект | Модуль QUIC | Версия | Источник |
|---|---|---|---|
| Hysteria `core` | `github.com/apernet/quic-go` | v0.65.1-0.20261109005002-2895f039137a | `core/go.mod` |
| Xray-core | `github.com/apernet/quic-go` | v0.63.1-0.20261004180939-a10df75c260c | `go.mod` |
| v2fly | `github.com/apernet/quic-go` и `github.com/quic-go/quic-go` | v0.59.1-0.20260217092621-db4786c77a22; v0.64.1 | `go.mod` |
| sing-box | `github.com/sagernet/quic-go` | v0.61.0-sing-box-mod.15 | `go.mod` |
| dae | `github.com/olicesx/quic-go` (+ `daeuniverse/quic-go` у библиотеки outbound) | псевдоверсии | `go.mod`; `olicesx/outbound/go.mod` через GitHub API |

Все строки — [V].

- **Hysteria + Xray-core в одном Go-модуле**: путь модуля один, MVS выберет старшую версию, v0.65.1-0.20261109. Xray-core окажется собран с форком новее того, с которым его тестировали. Клиент Hysteria использует нестандартные поля форка — `ChromeParrot`, `DisablePathManager`, `OmitMaxDatagramFrameSize`, `quic.ZeroLengthConnectionIDGenerator`, `Conn.SetCongestionControl` (`core/client/client.go`); Xray использует те же `ChromeParrot` и интерфейс `congestion` (`transport/internet/hysteria/dialer.go:95`). Соберётся ли Xray на v0.65.1 и не изменится ли поведение — неизвестно. [V — версии и поля; U — исход]
- **Hysteria + sing-box**: пути модулей разные, конфликта версий нет; в бинарнике окажутся два QUIC-стека. Размер и базовая память не измерялись. [V — пути; U — цена]
- При архитектуре ADR-0001 (один движок на процесс) вопрос возникает только если Hysteria линковать *внутрь* моста Xray. Делать это незачем — см. 4.7.

### 4.4. Управление перегрузкой, UDP, hopping, obfs

- **Выбор алгоритма** (`core/client/client.go:150–167`): если сервер просит автоопределение (`RxAuto`) или скорость отдачи неизвестна — настроенный алгоритм (`bbr` по умолчанию или `reno`); иначе Brutal со скоростью `min(serverRx, clientTx)`. [V]
- **BBR**: профили `conservative`, `standard`, `aggressive` (`core/internal/congestion/bbr/bbr_sender.go:100–102`). [V]
- **Brutal**: окно выборки 5 секунд, минимальный учитываемый ack rate 0.8, множитель окна 2; `DisableLossCompensation` (`brutal/brutal.go:15–20`). [V]
- **UDP**: поверх QUIC-датаграмм, `MaxDatagramFrameSize = 1200`, `MaxUDPSize = 4096`, собственная фрагментация (`core/internal/frag`), очередь приёма на сессию `udpMessageChanSize = 1024` сообщений (`core/client/udp.go`, `core/internal/protocol/proxy.go`). [V]
- **Port hopping** (`extras/transport/udphop/conn.go`): интервал по умолчанию 30 с, диапазон `Min`/`Max`, очередь 1024 пакета, буфер 2048 байт. [V]
- **Obfs** (`extras/obfs/`): `salamander` (соль 8 байт, ключ BLAKE2b-256, PSK не короче 4 байт) и `gecko` — надстройка над Salamander, дробящая long-header пакеты QUIC на куски случайного размера (по умолчанию 512–1200 байт). [V]
- **PMTUD** включён на linux, windows, darwin (`core/internal/pmtud/avail.go`). Отнесёт ли Go iOS и tvOS к ветке `darwin` — да, по правилам тегов сборки Go `ios` подразумевает `darwin`; работает ли там установка DF-бита — не проверено. [U]
- **Realm** (`extras/realm/`) — пробивание NAT через STUN и сервер-посредник. [V]
- **Mimic** (`app/internal/mimic/`) — маскировка UDP под TCP отдельным процессом с eBPF; только Linux (`mimic_other.go` возвращает ошибку). [V]

### 4.5. TUN в официальном клиенте

- `app/internal/tun/server.go`: TUN построен на `github.com/sagernet/sing-tun`, стек — `tun.NewSystem` («system» стек sing-tun), `GSO: true`, устройство создаётся через `tun.New` по имени интерфейса. [V]
- Готовый файловый дескриптор не передаётся: поиск `FileDescriptor` по модулю `app` пуст. В NetworkExtension интерфейс создаёт система, и расширение получает только дескриптор — значит, код в нынешнем виде в расширении не запустится. [V — отсутствие параметра; U — поведение на iOS]
- Цели сборки (`platforms.txt`): windows, darwin (amd64, arm64 — исполняемый файл для macOS), linux, android, freebsd. iOS, tvOS, visionOS отсутствуют. Сценариев `gomobile`/`c-archive` для Apple в `hyperbole.py` нет (есть только Android NDK). [V]

### 4.6. Значения по умолчанию, важные для расширения с лимитом памяти

| Параметр | Hysteria `core` | Xray-core | sing-box |
|---|---|---|---|
| Окно приёма потока (начальное и максимальное) | 8 388 608 байт (`core/client/config.go`) | 8 388 608 (`transport/internet/hysteria/dialer.go:101–105`) | `hysteria.DefaultStreamReceiveWindow` из sing-quic — значение не открывал [U] |
| Окно приёма соединения | 20 971 520 байт (8 МиБ × 5/2) | то же (`dialer.go:107–111`) | `hysteria.DefaultConnReceiveWindow` [U] |
| Idle timeout | 30 с | 30 с | [U] |
| Keep-alive | 10 с | по умолчанию не задаётся (строки закомментированы, `dialer.go:116`) | [U] |

Строки Hysteria и Xray — [V].

Окно соединения 20 МиБ при бюджете расширения около 50 МиБ (`ADR-0001` §1) — потенциальный риск: это предел объёма непрочитанных данных, который QUIC согласится буферизовать. Реальное потребление зависит от того, как быстро потребитель читает, и по исходникам не оценивается. Значение одинаково у официального клиента и у Xray-core, поэтому выбор реализации этот риск не меняет; меняет настройка окон (`initStreamReceiveWindow` и соседние поля в `finalmask.quicParams` Xray). [V — значения; U — поведение]

Другие ограниченные буферы официального клиента: очередь UDP-сессии 1024 сообщения; очередь hopping 1024 × 2048 байт; пересборка gecko — до 4096 записей, TTL 8 с (`extras/obfs/gecko.go`). [V]

### 4.7. Как к официальной реализации относятся Xray-core и sing-box

**Xray-core** — пакеты `apernet/hysteria` не импортирует (в `go.mod` только `apernet/quic-go`). Реализация собственная: `proxy/hysteria/`, `transport/internet/hysteria/` (около 2500 строк без управления перегрузкой). [V]

Но управление перегрузкой перенесено из официального кода: [V — `diff`]

- `congestion/brutal/brutal.go` совпадает с `hysteria/core/internal/congestion/brutal/brutal.go` полностью, если не считать пути импорта (0 строк различий из 193);
- `congestion/bbr/bbr_sender.go` — 4 строки вывода `diff` на 1088 строк;
- `finalmask/salamander/gecko.go` — заметно переработан (413 строк вывода `diff`).

Набор функций в Xray: Brutal и BBR с `bbrProfile`, `brutalUp`/`brutalDown`, `brutalDisableLossCompensation`, окна QUIC, `disableChromeParrot`, `disableGSO` (`infra/conf/transport_finalmask.go`, `QuicParamsConfig`); salamander и gecko; `udphop`; `realm` (`transport/internet/finalmask/{salamander,udphop,realm}`). [V]

**sing-box** — тоже не импортирует `apernet/*`. Реализация в `github.com/sagernet/sing-quic` (пакеты `hysteria`, `hysteria2`, `hysteria2/realm`) поверх `github.com/sagernet/quic-go`; лицензия sing-quic — GPL-3.0-or-later (GitHub API). [V]

Набор опций (`option/hysteria2.go`): `up_mbps`, `down_mbps`, `obfs` с типами `salamander` и `gecko`, `server_ports`, `hop_interval`, `hop_interval_max`, `bbr_profile` (`standard`, `conservative`, `aggressive`), `disable_chrome_parrot`, `realm`. Кроме того, sing-box поддерживает Hysteria первой версии (`sing-quic/hysteria`), которой в официальном репозитории v2 нет. [V]

**v2fly** — импортирует форк `github.com/v2fly/hysteria/core/v2` (push форка 2026-02-20); obfs и hopping в конфигурации транспорта не выведены. [V]

**Что официальный клиент дал бы сверх этого.** По списку опций клиента (`app/cmd/client.go`): `mimic` (только Linux), режимы `tcpTProxy`, `udpTProxy`, `tcpRedirect` (Linux), `sockopts.fdControlUnixSocket` (Android). Ничего применимого на Apple, чего нет в Xray-core или sing-box, не найдено. [V — сопоставление списков опций; U — совпадение поведения на проводе, это проверяется interop-тестом]

### 4.8. Вердикт

Отдельным движком не делать. Причины:

- функциональный паритет с Hysteria2 в Xray-core и sing-box на уровне опций (4.7);
- алгоритмы перегрузки в Xray-core — тот же код;
- TUN-режим официального клиента привязан к GPL-библиотеке и не принимает готовый дескриптор (4.5);
- третий Go-рантайм и третье расширение ради одного протокола.

Полезное применение: официальный сервер и клиент — **эталон** для interop-тестов наших конфигураций Hysteria2 (в лаборатории, не в продукте), а `PROTOCOL.md` в корне репозитория — первичное описание протокола.

Условие пересмотра: если измерение (раздел 6, M-H1) покажет, что Hysteria2 в Xray-core заметно уступает официальному клиенту на том же канале, разбираться в причине и чинить её в настройках либо в upstream — а не добавлять движок.

---

## 5. Сводка: лицензия, встраиваемость, цели Apple

| | v2fly/v2ray-core | dae | Hysteria |
|---|---|---|---|
| Лицензия проекта | MIT [V] | AGPL-3.0 [V] | MIT [V] |
| Копилефт в зависимостях | не найден по `go.mod` [U — до полной сверки] | `daeuniverse/outbound` AGPL-3.0; косвенно `sagernet/sing` [V] | `core`, `extras` — нет; `app` — `sing`, `sing-tun` GPL-3.0-or-later [V] |
| App Store | препятствий не видно [U] | несовместимо с нашими правилами (ADR-0006) | `core`+`extras` — препятствий не видно; `app` — как GPL |
| c-archive / gomobile в репозитории | нет скриптов; есть `main/v2binding` с глобальным экземпляром и локальным gRPC-портом [V] | нет; `main` только Linux [V] | нет для Apple; Android через NDK [V] |
| Глобальное состояние | системный диалер и листенер — пакетные переменные; 279 `init()` [V] | не оценивалось — неприменим | практически нет; три debug-переменные окружения [V] |
| Повторный start/stop | [U] | — | конструктивно допустим [U — без измерения] |
| TUN с готовым utun fd | нет: вне Linux только UDP-мост [V] | — | нет: параметр не передаётся [V] |
| Цели iOS / tvOS / visionOS в CI | нет [V] | нет [V] | нет [V] |

---

## 6. Что можно узнать только сборкой и измерением

Ни одно из чисел ниже не известно. До измерения утверждать что-либо о скорости нельзя. Измерять на Mac-сборщике и реальных устройствах; на этом хосте — ничего.

**Hysteria2 в уже выбранных движках (нужно в любом случае)**

- M-H1. Пропускная способность и джиттер Hysteria2 через мост Xray и через libbox на одном и том же сервере и канале: загрузка и отдача, Brutal с заданными `up`/`down` и BBR в трёх профилях. Эталон сравнения — официальный клиент на macOS с тем же сервером. Результат: Мбит/с, потери, загрузка CPU.
- M-H2. Пиковый `phys_footprint` расширения под нагрузкой Hysteria2 при окнах по умолчанию (8 МиБ / 20 МиБ) и при уменьшенных (ряд значений, например 1/2/4 МиБ на поток). Результат: зависимость «окно → память → скорость»; значение по умолчанию для iOS.
- M-H3. Медленный потребитель: один поток, приложение не читает данные. Растёт ли память расширения до размера окна соединения и завершает ли система расширение.
- M-H4. UDP через Hysteria2 (QUIC внутри QUIC, голос, игры): потери и задержка при MTU туннеля 1500 и 4064; поведение фрагментации при `MaxDatagramFrameSize = 1200`.
- M-H5. Port hopping: обрывы и время восстановления при смене порта с интервалом 30 с и короче; расход батареи за час простоя с keep-alive.
- M-H6. Salamander и gecko: цена в CPU и пропускной способности относительно чистого QUIC.
- M-H7. Смена сети Wi-Fi ↔ сотовая: время восстановления соединения в Xray и в sing-box. В официальном клиенте `DisablePathManager: true` — миграция пути выключена, ожидается переподключение.
- M-H8. PMTUD на iOS и tvOS: реально ли выставляется DF и растёт ли размер пакета.
- M-H9. Interop: наш скомпилированный конфиг Xray и sing-box против официального сервера `app/v2.14.0` со всеми сочетаниями obfs × hopping × алгоритм перегрузки.

**Только если решение об отдельном движке будет пересмотрено**

- M-X1. Собирается ли Xray-core с `apernet/quic-go` v0.65.1-0.20261109 (версия, которую навяжет MVS при линковке `hysteria/core`), проходят ли его тесты Hysteria.
- M-X2. Размер XCFramework и базовая память процесса с `hysteria/core`+`extras` в виде c-archive: отдельно и внутри моста Xray.
- M-X3. Цикл `NewClient`/`Close` 1000 раз: число горутин и память до и после.

**v2fly (только при появлении потребности в его уникальных транспортах)**

- M-V1. Собирается ли `v2ray-core/v5` как c-archive под `ios/arm64`; размер; базовая память с gVisor.
- M-V2. Пропускная способность TUN через `udp_bridge` (Swift ↔ loopback UDP ↔ Go) против прямого чтения utun в Xray.
- M-V3. Допускает ли система loopback-UDP-сокеты в расширении на tvOS.

**Импортёр (проверяется без устройств, тестами)**

- M-I1. Корпус реальных файлов v4, v5 и Xray: доля распознанных форматов, список непереносимых ключей; сверка с пунктами 2.5.
- M-I2. Чувствительность разбора к регистру ключей (`expectIps` / `expectIPs`) в каждом ядре — запуском ядра с тестовым конфигом на машине разработки.
- M-I3. Семантика закрепления сертификата: `pinnedPeerCertificateChainSha256` (v2fly) против `pinnedPeerCertSha256` (Xray) на одном сертификате.

**Идеи dae (после реализации у нас)**

- M-D1. Раздельные проверки TCP/UDP × v4/v6: трафик и время на цикл при 50, 200, 1000 узлах; допустимое число параллельных проб в расширении по памяти.
- M-D2. Гистерезис `check_tolerance`: частота переключений узла при разных допусках на реальных подписках.

---

## 7. Что осталось непроверенным

- Лицензии большинства транзитивных зависимостей v2fly и модуля `extras` Hysteria — открывались только отдельные модули (перечислены в тексте).
- Значения окон и тайм-аутов Hysteria2 в `sagernet/sing-quic` — файл с константами не открывался.
- Точные правила «плоской» формы настроек outbound в Xray и её соответствие упрощённым настройкам v5.
- Переносимость `daeuniverse/outbound` и отдельных пакетов `component/*` dae на darwin — не имеет практического значения при AGPL.
- История коммитов глубже одного: клоны shallow, активность оценена через GitHub API по числу коммитов, без анализа их содержания.
- Всё, что перечислено в разделе 6.
