# Компилятор модели → Clash YAML (Mihomo)

Статус: **написано и проверено на Linux** (2026-11-27, поток `stage4/clash`): компилятор, эмиттер YAML, корпус
фикстур, проверка настоящим `mihomo -t`, прогон вывода компилятора в мосте Mihomo на tun ядра Linux против
штатного xray 26.11.9. На устройстве Apple не запускалось (адаптера Mihomo и XCFramework моста Mihomo ещё нет).
Основание: ADR-0002 (конфиг движка — результат компиляции модели, потери не молчаливы), ADR-0007 (второй движок —
Mihomo). Мост, который исполняет результат, — `Cores/MihomoBridge` (Mihomo v1.19.34, `0455d0d`).

## 1. Место в системе

```
DomainModels (профиль, серверы, группы) + RoutingEngine (таблица правил)
   └─ ConfigurationEngine
        ├─ XrayConfigCompiler   → Xray JSON
        └─ MihomoConfigCompiler → YAMLNode → YAMLEmitter → Clash YAML + ConversionReport
                                   └─ расширение MihomoOnly/Dual → npb_start(yaml, options) моста Mihomo
```

Файлы: `Packages/ConfigurationEngine/Sources/MihomoConfigCompiler.swift` (профиль, группы, DNS, tun),
`MihomoProxyCompiler.swift` (`proxies[]`), `MihomoRuleCompiler.swift` (правила), `YAMLEmitter.swift`.
`ConfigurationEngine` теперь зависит и от `RoutingEngine` (листовой модуль, без адаптеров движков). Swift не
линкует Go (ADR-0001): компилятор выдаёт текст; проверка движком — на стенде и в CI.

Входы: `Profile` и `MihomoCompileOptions` (уровень журнала, `socks-port` для стенда, DNS-серверы, `fakeIP`,
профиль памяти, `TunnelAddressing`, `RoutingTable`). Для расширения — `MihomoCompileOptions.packetTunnel(…)`
(tun с общими адресами, профиль `mobile`). Выход: `MihomoCompilation` — документ, `ConversionReport` (движок
`mihomo`, версия `1.19.34`) и план туннеля (`XrayTunnelPlan` — тот же тип, что у Xray: настройки интерфейса от
движка не зависят).

## 2. Что мост ожидает от документа и что выводит компилятор

Требования — из `Cores/MihomoBridge/engine/config.go` (`prepareConfig`) [V]. Тест моста
`TestCompiledFixturesNeedNoOverride` (`engine/compiled_test.go`) прогоняет **каждый** `*.mihomo.yaml` корпуса через
`prepareConfig` в режиме flow и требует пустой `ConfigSummary.overridden`, MTU 1500, tun-адрес 198.18.0.1/30,
резолверы 198.18.0.2 и fd66:6e70::2 в числе адресов перехвата и перехват порта 53 любого адреса.

| Ключ | Вывод компилятора | Почему |
|---|---|---|
| `tun` | `enable`, `stack: mips`, `mtu` из `TunnelAddressing`, `dns-hijack: ["any:53", "tcp://any:53"]`, `inet6-address` (или `[]` без IPv6), `auto-route: false`, `auto-detect-interface: false`; без `device`, `file-descriptor`, `recvmsgx` | форма для `tun.mode: "flow"`; неуказанный адрес в перехвате совпадает с любым адресом на порту 53 (`listener/sing_tun/dns.go`) [V] |
| IPv4 tun | `dns.fake-ip-range: "<ipv4Address>/<prefix>"` | ядро берёт IPv4-адрес tun из `fake-ip-range` (адрес префикса, длина /30; `config.go` `parseTun`) [V]; мост добавляет перехват адреса «следующий за адресом tun» — это и есть резолвер .2 / ::2 |
| `find-process-mode` | `off` | мост всё равно ставит `off` |
| `profile` | `store-selected: false`, `store-fake-ip: false` | выбор групп хранит управляющий слой, `cache.db` не пишется |
| `external-controller*`, `secret`, `iptables`, `redir/tproxy-port`, `listeners` | не выводятся | мост отвергает или обнуляет |
| `socks-port` | только при `localSOCKSPort` (стенд, рабочий стол), с `bind-address: 127.0.0.1` | ADR-0003: расширение портов не открывает |
| прочее | `mode: rule`, `ipv6` = есть ли IPv6 у туннеля, `allow-lan: false`, `tcp-concurrent: false`, `geo-auto-update: false`, `unified-delay: true` | |

## 3. Отображение модели

### 3.1. Прокси

Имена в движке — `proxy-NNNN` (по индексу в профиле), группы — `group-NNNN`, звенья цепочек — `chain-NNNN-K`:
теги модели могут содержать запятые и скобки, которые ломают синтаксис правил. Соответствие тег → имя — в
`report.engineTags`. Ключи сверены с тегами `proxy:"…"` в `adapter/outbound/*.go` v1.19.34 [V].

| Модель | Mihomo | Потери (в отчёт) |
|---|---|---|
| VLESS (+Vision, VLESS Encryption) | `type: vless`, `uuid`, `flow`, `encryption`, `packet-encoding: xudp` (как у Xray), `udp: true` | `vision-udp443` → обычный Vision (warning); Encryption — `untested` |
| VMess | `type: vmess`, `uuid`, `alterId`, `cipher` | неизвестный шифр → `auto` |
| Trojan | `type: trojan`, `password`, `sni` | Trojan без TLS — error (ядро всегда включает TLS) |
| Shadowsocks (AEAD, 2022) | `type: ss`, `cipher`, `password`; плагины `obfs` (simple-obfs) и `v2ray-plugin` (websocket) | ключ 2022 проверяется по длине; прочие плагины, транспорты, потоковые шифры — error |
| SOCKS5 / HTTP | `type: socks5` / `http`, `username`, `password`, `tls`, `sni` (HTTP) | SOCKS4/4a — error; SNI у SOCKS5 не задаётся (warning) |
| Hysteria2 | `type: hysteria2`, `password`, `ports` + `hop-interval`, `up`/`down`, `obfs: salamander`, `sni`, пин | gecko — error; полоса без единицы — ядро читает как Мбит/с (warning) |
| TUIC v5 | `type: tuic`, `uuid`, `password`, `congestion-controller`, `udp-relay-mode`, `alpn: [h3]` по умолчанию | `untested` (у Xray нет сервера TUIC) |
| WireGuard | `type: wireguard`, ключи, `ip`/`ipv6`, `allowed-ips`, `reserved`, `mtu`, `persistent-keepalive` | второй адрес семейства отбрасывается |
| TLS | `tls`, `servername`/`sni`, `alpn`, `client-fingerprint`, `skip-cert-verify`, `ech-opts`, `fingerprint` (пин SHA-256), `name-cert-verify` | `disableSNI` нельзя (кроме TUIC); пинов и имён — по одному |
| REALITY | `servername`, `client-fingerprint` (по умолчанию `chrome`), `reality-opts.public-key`, `short-id` и **всегда `support-x25519mlkem768: true`** | `spiderX` — info (у клиента Mihomo нет паука), `mldsa65Verify` — warning (подпись ML-DSA-65 не проверяется) |
| Транспорты | raw, `http` (HTTP-маскировка raw), `ws`, HTTPUpgrade → `ws` + `v2ray-http-upgrade: true`, `grpc`, `h2`, `xhttp` с `download-settings` (только VLESS) | gRPC `authority` и `multiMode` — warning; QUIC и mKCP — error |
| `EngineExtras` | не применяются | Xray-ключи (`finalmask`, `xhttp.extra`) — warning |

`support-x25519mlkem768: true`: по умолчанию ядро вырезает долю ключа X25519MLKEM768 из Client Hello, а сервер
REALITY Xray 26.11.9 (`xtls/reality` `4bb46b2afd8b`, `tls.go`) такой Client Hello отвергает [V, тест моста и
прогон §4.3].

### 3.2. Группы

Mihomo умеет вложенные группы, поэтому группы модели переносятся один к одному (у Xray они сплющиваются).

| Модель | Mihomo |
|---|---|
| `selector` | `select`; член по умолчанию ставится первым (селектор начинает с первого члена) — info |
| `urlTest` | `url-test` (`url`, `interval`, `timeout`, `tolerance`) |
| `fallback` | `fallback` — точно (у Xray — приближение) |
| `loadBalance` | `roundRobin` → `load-balance`/`round-robin`, `consistentHashing` → `consistent-hashing`; `random` → `round-robin` (warning); `leastPing`, `leastLoad` → `url-test` (warning) |

Без проверки здоровья: URL ядра по умолчанию, интервал 300 с (в профиле `mobile` — 600 с), всегда `lazy: true`.
Группа без единого скомпилированного члена не выводится (warning); если её выбрали или на неё ссылается
правило — компиляция блокируется.

Выбор: `profile.selectedTag` (иначе первый сервер) — цель `MATCH` без таблицы правил и маршрут запросов
резолвера. Кто переключает `select` внутри движка (сейчас — перекомпиляция) и кто выбирает — `url-test` движка
или `AdaptiveBalancer`, — по-прежнему открытый вопрос (§5).

### 3.3. Правила

Таблица `RoutingEngine` понижается (`RuleLowering.lower`) до плоских правил «И полей, ИЛИ значений»:

- одно поле → по правилу Mihomo на значение (тот же результат при «первом совпадении»): `DOMAIN`,
  `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `DOMAIN-REGEX`, `IP-CIDR`/`IP-CIDR6`, `DST-PORT`, `NETWORK`, `SRC-IP-CIDR`,
  `SRC-PORT`; пустое поле → `MATCH`;
- несколько полей → `AND,((…),(…))`, поле с несколькими значениями — `OR,(…)`; порты — `a/b/c-d`, не больше
  28 диапазонов в одном условии (`common/utils/ranges.go`), больше — несколько условий;
- `ipNotIn` → `AND,((OR,((IP-CIDR,0.0.0.0/0),(IP-CIDR6,::/0))),(NOT,((…))))`: одно `NOT` совпало бы и с
  соединением без адреса;
- `domainStrategy`: `asIs` — `no-resolve` у адресных условий; `ipOnDemand` — без него; `ipIfNonMatch` — все
  правила с `no-resolve`, затем адресные правила ещё раз без него, затем `MATCH`;
- действия: `direct` → `DIRECT`, `reject` → `REJECT`, `proxy`/`group` → имя в движке, `chain([a, b, …])` →
  копии звеньев со 2-го с `dialer-proxy` на предыдущее (первое звено может быть группой, остальные — только
  серверы) — `untested`.

Перед правилами пользователя стоят исключения туннеля (IP серверов и локальные сети → `DIRECT`, `no-resolve`) —
тот же список, что `excludedRoutes` плана.

**Блокируют компиляцию** (error): проблемы понижения (`not`, конъюнкция одного поля, слишком много вариантов),
условия по `inboundTag`, `user`, `sniffedProtocol` (у Mihomo нет имён входов Xray и правила по протоколу),
регулярка со скобками внутри логического правила (парсер `rules/logic` режет по скобкам), неизвестная цель.
Частичный список правил маршрутизировал бы иначе, чем показывает симулятор.

Отличия в отчёте (info): адресные правила видят один адрес (в туннеле — адрес соединения, даже если домен
известен по DNS); доменные правила срабатывают по отображению «адрес → домен» резолвера туннеля
(`redir-host`) — приложение со своим DoH ходит по адресу, сниффинг выключен. Регулярки: RE2 модели против
`regexp2` ядра — в общем подмножестве совпадают [U].

### 3.4. DNS и защита от утечек

```yaml
dns:
  enable: true
  ipv6: <есть IPv6 у туннеля>
  use-system-hosts: false
  enhanced-mode: redir-host        # fake-ip — только по options.fakeIP (по умолчанию выключен)
  fake-ip-range: 198.18.0.1/30     # он же IPv4-адрес tun; при fake-ip — /16 (пул ядра начинается с .4)
  default-nameserver: [<IP-резолверы>#<главная цель>]
  nameserver: [<резолверы>#<главная цель>]
  proxy-server-nameserver: [<IP-резолверы>]   # только если какой-то сервер задан доменом
```

- Все запросы резолвера, включая разрешение имён DoH/DoT, идут через главную цель (суффикс `#имя` в
  `config.go` `parseNameServer` [V]). Без серверов в опциях — `1.1.1.1`, `8.8.8.8` (как у Xray).
- `localhost`, схемы `+local`, `fakedns` и прочие без аналога — error (запрос ушёл бы мимо туннеля).
- `proxy-server-nameserver` — единственное исключение: имя сервера прокси нельзя разрешить через сам прокси;
  отмечается в отчёте (info).
- Перехват: любой UDP/TCP на порт 53 любого адреса отвечает резолвер ядра; прогон §4.3 считает пакеты на 53-й
  порт мимо туннеля — 0.

### 3.5. Профиль памяти `mobile`

В документе: окна приёма QUIC Hysteria2 те же, что у компилятора Xray (`XrayConfigCompiler.mobileQUICWindows`:
512 КиБ / 2 МиБ на поток, 1 / 4 МиБ на соединение), ленивые проверки групп раз в 600 с, без параллельного
набора TCP и без загрузки geodata. Числа самого моста (предел памяти, GOGC, очереди, `maxFlows`, простой UDP/TCP)
живут только в Go-константах `Mobile*`: расширение передаёт мосту `{"memory":{"profile":"mobile"},"tun":{"mode":"flow"}}`.

## 4. Проверка

### 4.1. Swift (контейнер `swift:5.10`)

`YAMLEmitterTests` (кавычки: слова YAML 1.1/1.2 `yes/no/on/off/null/~`, числа, IP, индикаторы, управляющие
символы, `﻿`/` `; раскладка блоков), `MihomoConfigCompilerTests` (протоколы, tun/DNS, группы, правила,
цепочки, блокировки, детерминизм, вырезание значений из отчёта), `MihomoFixtureCorpusTests` (корпус).

### 4.2. Корпус и `mihomo -t`

Те же ссылки и профили, что у корпуса Xray (`Tests/Fixtures/{ShareLinks,Interop,Profiles}`), плюс
`Tests/Fixtures/Routing` (таблицы `RoutingEngine` над общим профилем: `as-is`, `ip-on-demand`,
`ip-if-non-match`, две заведомо блокируемые). Опции — `MihomoCompileOptions.packetTunnel()`. Рядом с каждым
`<name>.link` — `<name>.mihomo.yaml` (нет, если заблокировано) и `<name>.mihomo-report.json`.
`Tools/validate-fixtures.sh <xray> <mihomo>` скармливает каждый YAML настоящему `mihomo -t` закреплённой версии
(сервер разработки 2026-11-27: **58 приняты, 0 отвергнуто, 7 заблокированы компилятором** — mKCP ×2, gecko,
SOCKS4a, плохой ключ SS-2022, две таблицы правил). То же — шаг CI в `mihomo-bridge-go.yml`.
Сырьё: `Benchmarks/results/mihomo-compiled-2026-11-27/validate-fixtures.txt`.

Оговорка: `mihomo -t` строит все прокси, группы и правила, но неизвестные ключи прокси ядро молча
пропускает — ключи поэтому сверены с исходником, а сквозной прогон проверяет смысл.

### 4.3. Сквозной прогон: вывод компилятора → мост Mihomo (flow) → tun ядра → штатный xray

`Cores/BuildScripts/bridge-tunlab.sh` с `ENGINE=mihomo` (сервер разработки, namespaces с префиксом стенда):

1. `compiled-link` — ключи стенда и четыре ссылки (VLESS+REALITY+Vision, SS-2022 aes-128, Trojan+TLS с
   пином, Hysteria2 с пином); пароль Trojan содержит `#`, `: `, `'`, `%` — проверяет кавычки YAML на деле;
2. `MihomoConfigCompilerTests.testExportCompiledMihomoConfiguration` (`NP_EXPORT_DIR`, `NP_EXPORT_LINK`,
   `NP_EXPORT_DNS`) — `config.yaml`, `plan.json`, `report.json`, `bridge-options.json` на каждую ссылку;
3. `compiled DIR` — интерфейс настраивается по плану, `npmlab bridge -options bridge-options.json` исполняет YAML.

Результат 2026-11-27 (все четыре протокола, вердикт компилятора `exact`): TCP-эхо 8 МиБ IPv4 и IPv6, загрузка
и отдача 32 МиБ, UDP-эхо 1…4000 байт IPv4/IPv6, DNS A/AAAA на 198.18.0.2 и fd66:6e70::2, перехват DNS на
посторонние адреса IPv4/IPv6, локальная сеть мимо туннеля, **0 пакетов DNS мимо туннеля**, значения конфигурации
в журнале не найдены — **0 проваленных проверок из 16** на каждый протокол.
Сырьё: `Benchmarks/results/mihomo-compiled-2026-11-27/compiled-mihomo-*.jsonl`. Это Linux, не Apple.

## 5. Открытые вопросы и ограничения

- Кто владеет выбором сервера внутри движка (`url-test` против `AdaptiveBalancer`) и как переключать `select`
  без перекомпиляции — нужен ADR и вызов моста.
- Цепочки (`dialer-proxy`), fake-ip, TUIC, XHTTP, VLESS Encryption, ECH, плагины SS — выводятся, принимаются
  `mihomo -t`, но сквозным прогоном не проверены (`untested` в отчёте).
- Сниффинг выключен; доменные правила для приложений со своим DoH не срабатывают.
- geosite/geoip и провайдеры правил: в модели нет; при появлении — файлы в `homeDir`, без загрузки в расширении.
- Импорт подписок Clash (YAML → модель) не реализован.
- Версионирование: ключи привязаны к v1.19.34; при обновлении ядра — сверка ключей и повтор §4.2–4.3.
