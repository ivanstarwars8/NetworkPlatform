# PROTOCOL_MATRIX — протоколы и транспорты по движкам

Дата проверки: **2026-11-24**; раздел 0 (наш статус по уровням, включая столбец Mihomo) — **2026-11-27**.

Источники: sing-box `6c65b2e` (ветка `testing`, 1.15.0-alpha.13), Xray-core `e17392a` (26.11.9). Пути указаны относительно корня соответствующего клона в `/root/.cache/np-research/`.

## Как читать

Статус в столбцах движков:

- **VERIFIED-in-source** — регистрация или поле конфигурации видны в исходнике на указанном коммите.
- **not present** — в реестре протоколов или транспортов нет, либо поиск по исходникам пуст. Способ проверки указан.
- **unverified** — в исходнике не найдено подтверждения ни наличия, ни отсутствия, либо реализация лежит в зависимости, которую не читали.

Чего эта матрица **не** утверждает:

- «VERIFIED-in-source» означает «код есть в репозитории». Это не значит, что протокол собирается под Apple, работает в песочнице расширения или совместим с серверами.
- Аудит sing-box сделан по альфа-ветке. Для стабильной 1.14.x состав не сверялся.
- Столбец **«Наш статус»** в разделах 1–5 у всех строк одинаков: **не заявлено (нет interop-теста)** — это продуктовое заявление, и оно не меняется, пока нет проверки на устройстве (раздел 7). Достигнутый уровень проверки нашего кода — в разделе 0.
- Второй движок по ADR-0007 — Mihomo. Уровни проверки нашего кода для Mihomo — столбец «Mihomo» раздела 0; в разделах 1–5 (наличие в исходниках) столбца Mihomo нет, его состав протоколов — в `Documentation/Research/mihomo-leaf.md`. Столбец sing-box оставлен как справка.

Столбец «Apple-сборка sing-box» показывает, попадает ли протокол в upstream-сборку libbox по тегам из `cmd/internal/build_libbox/main.go`. У Xray-core тегов сборки для протоколов нет: libXray импортирует `main/distro/all`.

## 0. Наш статус по уровням проверки (Xray и Mihomo, 2026-11-27)

Уровни (каждый следующий включает предыдущие, если не сказано иное):

- **Implemented** — код есть в репозитории.
- **Compiled** — собран.
- **Unit tested** — проверен модульными тестами нашего кода.
- **Integration tested** — результат нашего кода принят настоящим движком закреплённой версии (`xray run -test`) или прошёл через наш мост без внешнего эталона.
- **Interoperability tested** — настоящий трафик между клиентом с нашим кодом и эталонным сервером закреплённой версии.
- **Verified on Apple device** — то же на устройстве Apple.

Основания: поток protocols (компилятор Swift → Xray JSON; `xray run -test`; `run-interop.sh` — клиент и сервер Xray v26.11.9 с настоящим трафиком, Linux), поток bridge (наш Go-мост с конфигом, написанным в тесте, против штатного xray v26.11.9 через loopback и через tun ядра Linux в netns). Основания столбца «Mihomo» (этап 4, поток clash): компилятор Swift → Clash YAML; `Tools/validate-fixtures.sh` с `mihomo -t` закреплённой v1.19.34 — 58 приняты, 0 отвергнуто, 7 заблокированы компилятором (на сервере разработки и на CI); сквозной прогон вывода компилятора в мосте Mihomo (`npmlab`, пакетный путь, tun ядра Linux в netns) против штатного xray 26.11.9 — VLESS+REALITY+Vision, SS-2022, Trojan+TLS, Hysteria2: TCP и UDP по IPv4/IPv6, DNS A/AAAA, перехват DNS, 0 DNS-пакетов мимо туннеля, 0 проваленных проверок из 16 на протокол (`Benchmarks/results/mihomo-compiled-2026-11-27/`). «Integration tested» для Mihomo — только `mihomo -t`, без трафика. Все прогоны — на Linux. **Verified on Apple device — нет ни для одной строки, ни для одного движка.** sing-box: уровней нет (не интегрируется).

| Протокол / транспорт | Компилятор конфигурации (Swift) | Мост (Go, Linux) | Итоговый уровень | Mihomo (компилятор YAML + мост Mihomo, Linux) |
|---|---|---|---|---|
| VLESS tcp / ws / grpc / httpupgrade / xhttp (+`downloadSettings`) / kcp, TLS + vision | Interoperability tested | VLESS+TCP, VLESS+XHTTP: Interoperability tested (loopback, TCP + UDP) | Interoperability tested | Integration tested: tcp, ws, grpc, httpupgrade (ws + `v2ray-http-upgrade`), xhttp (+download) приняты `mihomo -t`; трафиком не проверено (XHTTP — `untested` в отчёте); kcp — блокируется компилятором (в Mihomo нет mKCP для VLESS) |
| VLESS REALITY (tcp vision, grpc, xhttp) | Integration tested (трафиком не проверено) | REALITY+Vision: Interoperability tested (loopback; tun ядра: TCP/UDP, IPv4/IPv6, DNS, MTU, 30-мин. прогон); UDP > ~7500 Б теряется, half-close не передаётся (ограничение ядра); под `-race` — гонка в ядре | Interoperability tested (мост); компилятор — Integration tested | REALITY+Vision (tcp): Interoperability tested — вывод компилятора через мост и tun ядра против xray 26.11.9 (TCP/UDP, IPv4/IPv6, DNS, 0 утечек DNS); нужен `support-x25519mlkem768: true` (выдаётся всегда); grpc, xhttp — Integration tested; под `-race` — гонка Vision в ядре Mihomo |
| VMess tcp | Interoperability tested | Interoperability tested (loopback) | Interoperability tested | Integration tested |
| VMess ws / grpc / httpupgrade | Integration tested | — | Integration tested | Integration tested (и h2: `mihomo -t` принимает, у Xray транспорт удалён) |
| Trojan TLS tcp | Interoperability tested | Interoperability tested (loopback; ядро помечает Trojan без flow устаревшим) | Interoperability tested | Interoperability tested (вывод компилятора через мост и tun ядра; пароль со спецсимволами YAML) |
| Trojan ws / grpc | Integration tested | — | Integration tested | Integration tested |
| Shadowsocks AEAD, 2022-blake3-aes-128-gcm | Interoperability tested | SS-2022: Interoperability tested (loopback; TCP через tun ядра, замеры) | Interoperability tested | SS-2022: Interoperability tested (вывод компилятора через мост и tun ядра); AEAD — Integration tested |
| Shadowsocks 2022 aes-256 + identity keys, chacha20 | Integration tested | — | Integration tested | Integration tested |
| SOCKS5 | Interoperability tested | — | Interoperability tested | Integration tested |
| HTTP proxy | Integration tested | — | Integration tested | Integration tested |
| WireGuard (пользовательский стек, `noKernelTun`) | Interoperability tested | — | Interoperability tested | Integration tested |
| Hysteria2 (outbound `hysteria` v2, salamander, закреплённый сертификат) | Interoperability tested | — | Interoperability tested | Interoperability tested (вывод компилятора через мост и tun ядра; самоподписанный сертификат с пином) |
| Hysteria2 port hopping, bandwidth | Integration tested | — | Integration tested | Integration tested |
| Группы selector / urlTest / leastLoad | Integration tested | — | Integration tested | select / url-test / fallback / load-balance, вложенные — Integration tested; leastLoad — приближение (warning в отчёте) |
| TUIC, SOCKS4/4a, плагины SIP003, транспорты h2/quic, Hysteria2 gecko | только импорт; компилятор выдаёт явное «не поддерживается» — Unit tested | — | Unit tested | TUIC v5, плагины SS obfs/v2ray-plugin, h2 — Integration tested (`mihomo -t`, сервера в стенде нет); SOCKS4a, Hysteria2 gecko — блокируются компилятором (Unit tested) |
| XDRIVE, MASQUE, finalmask-маски кроме salamander/udphop, VLESS Encryption, Mux | нет | — | не реализовано | VLESS Encryption — выводится, теста нет (`untested`); XDRIVE, MASQUE, Mux — нет |

Примечания к Xray 26.11.9 (по исходникам, `Documentation/Protocols/xray-modern.md`, `share-link-formats.md`):

- `allowInsecure` удалён: с v26.7.11 это ошибка сборки конфига (в ссылках взамен — параметры `pcs`/`vcn`, см. `share-link-formats.md`).
- `kcp` `header`/`seed` не читаются → UDP-маска `mkcp-legacy`.
- `freedom` по умолчанию блокирует частные адреса назначения (`finalRules`); в HEAD — `firewall`.
- Mux: формат зависит от SHA ядра — в теге `mux` на уровне outbound, в HEAD `settings.multiplex` (только VLESS/VMess). Компилятор привязан к тегу.
- VLESS/Trojan без TLS/REALITY (и без VLESS Encryption) на публичный адрес отвергаются при сборке конфига.
- Hysteria — только версия 2, TLS обязателен; Hysteria2 = outbound `hysteria` + finalmask (`salamander`, `udphop`, `quicParams`); `quicParams` с `brutal` в XHTTP/3 вызывает panic в дилере.
- XHTTP `extra` заменяет весь объект настроек, кроме host/path/mode: верхнеуровневые `downloadSettings`/`xmux` молча теряются, если `extra` тоже выдаётся.
- Есть: XDRIVE (с v26.9.30, только VLESS + encryption + Mux), MASQUE (с v26.9.30), UDP-маски `xdns`, `xicmp`, `realm`, `xmc`, `sudoku`, `udphop`, `filter`; TCP-маска `proxy-protocol` — только в HEAD.
- Нет в Xray (по реестру `infra/conf/xray.go`): TUIC, SSH, AnyTLS, ShadowTLS, Snell, Naive, Tor, AmneziaWG.

## 1. Протоколы прокси (outbound)

| Протокол | sing-box | Apple-сборка sing-box | Xray-core | Наш статус |
|---|---|---|---|---|
| VLESS | VERIFIED-in-source (`protocol/vless`, `include/registry.go`) | да, без тега | VERIFIED-in-source (`infra/conf/xray.go:28–59`, `infra/conf/vless.go`) | не заявлено (нет interop-теста) |
| VLESS, flow `xtls-rprx-vision` | unverified: поле `flow` есть (`option/vless.go`), значение описано в `docs/configuration/outbound/vless.md`, но реализация в зависимости `sagernet/sing-vmess` не читалась | — | VERIFIED-in-source (`proxy/vless/vless.go:18`) | не заявлено (нет interop-теста) |
| VLESS Encryption (`mlkem768x25519plus`) | not present (в `option/vless.go` поля шифрования нет) | — | VERIFIED-in-source (`infra/conf/vless.go:110–115, 364–378`) | не заявлено (нет interop-теста) |
| VLESS reverse | unverified | — | VERIFIED-in-source (`infra/conf/vless.go:218–220`) | не заявлено (нет interop-теста) |
| VMess | VERIFIED-in-source (`protocol/vmess`) | да | VERIFIED-in-source (`infra/conf/xray.go`) | не заявлено (нет interop-теста) |
| Trojan | VERIFIED-in-source (`protocol/trojan`) | да | VERIFIED-in-source | не заявлено (нет interop-теста) |
| Shadowsocks (включая 2022) | VERIFIED-in-source (`protocol/shadowsocks`; методы `2022-blake3-*` в `docs/configuration/outbound/shadowsocks.md`) | да | VERIFIED-in-source (`infra/conf/shadowsocks.go:56–57`, `proxy/shadowsocks_2022`) | не заявлено (нет interop-теста) |
| ShadowsocksR | not present (заглушка «удалён в 1.6.0», `include/registry.go`) | — | not present (нет в реестре `infra/conf/xray.go`) | не заявлено (нет interop-теста) |
| SOCKS | VERIFIED-in-source | да | VERIFIED-in-source | не заявлено (нет interop-теста) |
| HTTP | VERIFIED-in-source | да | VERIFIED-in-source | не заявлено (нет interop-теста) |
| Hysteria (v1) | VERIFIED-in-source (`protocol/hysteria`, `include/quic.go`) | да, `with_quic` | not present (`infra/conf/hysteria.go`: `version != 2` → ошибка) | не заявлено (нет interop-теста) |
| Hysteria2 | VERIFIED-in-source (`protocol/hysteria2`) | да, `with_quic` | VERIFIED-in-source (`infra/conf/hysteria.go`) | не заявлено (нет interop-теста) |
| TUIC | VERIFIED-in-source (`protocol/tuic`) | да, `with_quic` | not present (нет в реестре; grep `tuic` по `infra/conf`, `proxy` пуст) | не заявлено (нет interop-теста) |
| WireGuard | VERIFIED-in-source (endpoint, `include/wireguard.go`; outbound удалён в 1.13.0) | да, `with_wireguard` | VERIFIED-in-source (`infra/conf/wireguard.go`) | не заявлено (нет interop-теста) |
| AmneziaWG | unverified (grep `amnezia` по `*.go` пуст; зависимости не читались) | — | unverified (grep `amnezia` по `infra/conf`, `proxy` пуст) | не заявлено (нет interop-теста) |
| MASQUE | VERIFIED-in-source (endpoint, без тега) | да | VERIFIED-in-source (`infra/conf/masque.go`) | не заявлено (нет interop-теста) |
| ShadowTLS | VERIFIED-in-source (`protocol/shadowtls`) | да | not present (нет в реестре) | не заявлено (нет interop-теста) |
| AnyTLS | VERIFIED-in-source (`protocol/anytls`) | да | not present (нет в реестре) | не заявлено (нет interop-теста) |
| Snell | VERIFIED-in-source (`protocol/snell`) | да | not present (нет в реестре) | не заявлено (нет interop-теста) |
| Naive | VERIFIED-in-source (`include/naive_outbound.go`, cronet, CGO) | да, `with_naive_outbound` | not present (нет в реестре) | не заявлено (нет interop-теста) |
| SSH | VERIFIED-in-source (`protocol/ssh`) | да | not present (нет в реестре) | не заявлено (нет interop-теста) |
| Tor | VERIFIED-in-source (`protocol/tor`); встроенный Tor (`with_embedded_tor`) в Apple-сборку не входит | да, без встроенного | not present (нет в реестре) | не заявлено (нет interop-теста) |
| Tailscale | VERIFIED-in-source (`include/tailscale.go`) | да, `with_tailscale` | not present (нет в реестре) | не заявлено (нет interop-теста) |
| OpenVPN | VERIFIED-in-source (`include/openvpn.go`) | да, `with_openvpn` | not present (нет в реестре) | не заявлено (нет interop-теста) |
| OpenConnect | VERIFIED-in-source (`include/openconnect.go`) | да, `with_openconnect` | not present (нет в реестре) | не заявлено (нет interop-теста) |

## 2. Транспорты

| Транспорт | sing-box | Xray-core | Наш статус |
|---|---|---|---|
| TCP без обёртки (`raw`) | VERIFIED-in-source | VERIFIED-in-source (`infra/conf/transport_internet.go:18–43`) | не заявлено (нет interop-теста) |
| WebSocket | VERIFIED-in-source (`constant/v2ray.go`, `transport/v2raywebsocket`) | VERIFIED-in-source | не заявлено (нет interop-теста) |
| HTTPUpgrade | VERIFIED-in-source (`transport/v2rayhttpupgrade`) | VERIFIED-in-source | не заявлено (нет interop-теста) |
| gRPC | VERIFIED-in-source; в Apple-сборке — облегчённая реализация `transport/v2ray/grpc_lite.go` (тега `with_grpc` нет) | VERIFIED-in-source | не заявлено (нет interop-теста) |
| HTTP (h2) как V2Ray-транспорт | VERIFIED-in-source (`transport/v2rayhttp`) | not present (удалён, `transport_internet.go:36`, отсылка на XHTTP stream-one) | не заявлено (нет interop-теста) |
| QUIC как V2Ray-транспорт | VERIFIED-in-source (`transport/v2rayquic`, `with_quic`) | not present (удалён, `transport_internet.go:38`) | не заявлено (нет interop-теста) |
| XHTTP / SplitHTTP | not present (grep `xhttp\|splithttp` по `*.go` пуст) | VERIFIED-in-source (`infra/conf/transport_method.go`, `transport/internet/splithttp`) | не заявлено (нет interop-теста) |
| XHTTP с раздельными up/down (`downloadSettings`) | not present | VERIFIED-in-source (`splithttp/dialer.go:334–375`; несовместим со `stream-one`) | не заявлено (нет interop-теста) |
| mKCP | not present (нет в `constant/v2ray.go`) | VERIFIED-in-source; поля `header`/`seed` в `KCPConfig.Build()` не читаются — маскировка перенесена в UDP-маску `mkcp-legacy` | не заявлено (нет interop-теста) |
| Транспорт `hysteria` | not present как транспорт (Hysteria — отдельный протокол) | VERIFIED-in-source | не заявлено (нет interop-теста) |
| Транспорт `masque` | not present как V2Ray-транспорт (MASQUE — endpoint, `transport/masque`) | VERIFIED-in-source | не заявлено (нет interop-теста) |
| XDRIVE | not present (grep `xdrive` по `*.go` пуст) | VERIFIED-in-source (`transport/internet/xdrive`) | не заявлено (нет interop-теста) |

## 3. Безопасность транспорта

| Возможность | sing-box | Xray-core | Наш статус |
|---|---|---|---|
| TLS | VERIFIED-in-source (`common/tls`, `option/tls.go`) | VERIFIED-in-source (`infra/conf/transport_security.go`) | не заявлено (нет interop-теста) |
| uTLS-отпечаток | VERIFIED-in-source (`common/tls/utls_client.go`, тег `with_utls`, модуль `metacubex/utls`) | VERIFIED-in-source (поле `fingerprint`, модуль `refraction-networking/utls`) | не заявлено (нет interop-теста) |
| REALITY, клиент | VERIFIED-in-source (`common/tls/reality_client.go`, `with_utls`) | VERIFIED-in-source (`REALITYConfig`, модуль `xtls/reality`) | не заявлено (нет interop-теста) |
| REALITY, проверка ML-DSA-65 (`mldsa65Verify`) | unverified (grep `mldsa` по `*.go` пуст; зависимости не читались) | VERIFIED-in-source | не заявлено (нет interop-теста) |
| ECH | VERIFIED-in-source (`common/tls/ech.go`, `option/tls.go`; реализация на stdlib) | VERIFIED-in-source (`echConfigList`) | не заявлено (нет interop-теста) |
| Кривая X25519MLKEM768 | VERIFIED-in-source (`option/tls.go:164`) | unverified (поле `curvePreferences` есть, конкретное значение не проверялось) | не заявлено (нет interop-теста) |
| Фрагментация ClientHello | VERIFIED-in-source (`option/tls.go:127–129`: `fragment`, `record_fragment`; действие правила `tls_fragment`) | VERIFIED-in-source (TCP-маска `fragment` в finalmask) | не заявлено (нет interop-теста) |
| Пиннинг сертификата | unverified (есть `common/tls/pinned_certificate_test.go`, поля не читались) | VERIFIED-in-source (`pinnedPeerCertSha256`) | не заявлено (нет interop-теста) |

## 4. Маскировка и мультиплексирование

| Возможность | sing-box | Xray-core | Наш статус |
|---|---|---|---|
| finalmask, TCP-маски (`filter`, `header-custom`, `proxy-protocol`, `fragment`, `sudoku`, `xmc`) | not present как механизм (grep `finalmask` по `*.go` пуст) | VERIFIED-in-source (`infra/conf/transport_finalmask.go`) | не заявлено (нет interop-теста) |
| finalmask, UDP-маски (`mkcp-legacy`, `noise`, `salamander`, `sudoku`, `xdns`, `xicmp`, `realm`, `udphop`, `filter`, `header-custom`) | not present как механизм | VERIFIED-in-source; работа `xicmp`, `xdns`, `realm` в песочнице расширения — unverified | не заявлено (нет interop-теста) |
| Salamander для Hysteria2 | VERIFIED-in-source (`option/hysteria2.go`, `constant/hysteria2.go`) | VERIFIED-in-source (UDP-маска `salamander`) | не заявлено (нет interop-теста) |
| Port hopping для Hysteria2 | VERIFIED-in-source (`option/hysteria2.go:210`, `server_ports`) | VERIFIED-in-source (UDP-маска `udphop`) | не заявлено (нет interop-теста) |
| Параметры QUIC (`bbr`, `brutal`) | unverified | VERIFIED-in-source (`quicParams`, `transport_finalmask.go:1357–1408`) | не заявлено (нет interop-теста) |
| Мультиплексор | VERIFIED-in-source (`option/multiplex.go`: `h2mux`, `smux`, `yamux`) | VERIFIED-in-source (`settings.multiplex` у VLESS и VMess; корневой `mux` игнорируется, `infra/conf/xray.go:364`) | не заявлено (нет interop-теста) |
| XUDP / packetaddr | VERIFIED-in-source (`protocol/vless/outbound.go:84–90`) | VERIFIED-in-source (`xudpConcurrency`, `xudpProxyUDP443`) | не заявлено (нет interop-теста) |

Мультиплексоры двух движков — разные протоколы. Совместимость между ними не проверялась и не предполагается.

## 5. Функции ядра, от которых зависит control plane

| Функция | sing-box | Xray-core | Наш статус |
|---|---|---|---|
| TUN-inbound с fd от хоста | VERIFIED-in-source (`experimental/libbox/service.go`, `OpenInterface`) | VERIFIED-in-source (`proxy/tun/tun_darwin.go`, `common/platform/platform.go:26`) | не заявлено (нет interop-теста) |
| Группы выбора узла | VERIFIED-in-source (`selector`, `urltest`) | unverified в деталях: есть `observatory`, `burstObservatory` (`infra/conf/xray.go:455–456`), балансировщики не читались | не заявлено (нет interop-теста) |
| Статистика трафика | VERIFIED-in-source (`StatusMessage`, `experimental/libbox/command_types.go`) | VERIFIED-in-source в ядре (`app/stats`, `app/metrics`); в API libXray отсутствует | не заявлено (нет interop-теста) |
| Поток соединений | VERIFIED-in-source (`ConnectionEvents`) | unverified | не заявлено (нет interop-теста) |
| Правила по SSID | VERIFIED-in-source (`wifi_ssid`, только iOS по документации клиента) | unverified | не заявлено (нет interop-теста) |
| MITM, скрипты | not present (`mitm` в `docs/configuration` не встречается) | not present как продуктовая функция | не заявлено (нет interop-теста) |

## 6. Следствия для модели конфигурации

Подробно — в ADR-0002. Здесь только то, что прямо следует из таблиц.

1. Пересечение движков: VLESS, VMess, Trojan, Shadowsocks, SOCKS, HTTP, Hysteria2, WireGuard, MASQUE поверх TCP, WebSocket, HTTPUpgrade, gRPC с TLS или REALITY. Только эти сочетания могут быть переносимы между движками, и то после interop-теста.
2. Только Xray: XHTTP (включая раздельные up/down), mKCP, XDRIVE, finalmask, VLESS Encryption.
3. Только sing-box: TUIC, Hysteria v1, ShadowTLS, AnyTLS, Snell, Naive, SSH, Tor, Tailscale, OpenVPN, OpenConnect, V2Ray-транспорты `http` и `quic`.
4. Одноимённые возможности с разной моделью: фрагментация ClientHello, Salamander, port hopping, мультиплексор, WireGuard (endpoint против outbound). Компилятор обязан переводить их явно и сообщать, если перевод неточен.
5. Старые ссылки mKCP с `header`/`seed` на Xray 26.11.9 молча теряют маскировку, если клиент не переложит их в `finalmask.udp`. Импортёр должен делать это сам и писать в отчёт.

## 7. Как строка выходит из статуса «не заявлено»

1. Движок с этим протоколом собран нашей сборочной цепочкой под целевую платформу.
2. Есть interop-тест: эталонный сервер закреплённой версии, клиент — наш адаптер в расширении на реальном устройстве, проверяются TCP, UDP и DNS.
3. Тест проходит на каждой платформе, для которой заявляется поддержка.
4. Версия движка и версия сервера записаны рядом со статусом.
