# COMPETITOR_MATRIX — матрица конкурентов (Apple-платформы)

Дата проверки: 2026-11-24.

## Как читать

- **[V-src]** — проверено по исходникам в `/root/.cache/np-research` (путь указан или см. `Documentation/Research/*.md`).
- **[V-web]** — проверено в день проверки на официальной странице (App Store US, сайт/документация разработчика). Страницы читались через автоматическое извлечение текста, а не глазами: формулировки пересказаны, возможны потери. Перед публичным использованием цифр — перепроверить вручную.
- **[U]** — по памяти или вторичным источникам; использовать только как гипотезу.
- **не подтверждено** — официального подтверждения не найдено; ячейка намеренно оставлена пустой по существу.

Оговорки ко всем строкам:

- «Apple Vision: visionOS 1.0+» в App Store означает лишь, что приложение доступно на Vision Pro (в том числе как совместимое iPad-приложение). Нативность не подтверждена ни для кого. Для sing-box-for-apple и OneXray в `project.pbxproj` упоминаний `xros`/`visionOS` нет (0 совпадений) — у них это совместимый iPad-режим. **[V-src]**
- «Mac … with Apple M1 chip or later» + «Designed for iPad» означает iPad-приложение на Apple Silicon, а не нативное Mac-приложение. **[V-web]** (формулировка страницы), трактовка — **[U]**
- Цены — App Store US, без региональных отличий.

Источники [V-web]: страницы App Store `id932747118` (Shadowrocket), `id1442620678` (Surge), `id1596063349` (Stash), `id1443988620` (Quantumult X), `id1373567447` (Loon), `id6785326793` (sing-box MT), `id6472431552` (Karing), `id6596777532` (Hiddify), `id6745748773` (OneXray), `id6450534064` (Streisand), `id6446814690` (V2Box); `stash.wiki/en/proxy-protocols/proxy-types`; `nsloon.app/docs/Node/`, `nsloon.app/docs/Plugin/`, `nsloon.app/docs/intro`; `manual.nssurge.com/` (оглавление); `nssurge.com/buy_now`; `raw.githubusercontent.com/crossutility/Quantumult-X/master/sample.conf`.

---

## 1. Платформы, модель, цена

| Продукт | Продавец | iOS/iPadOS | macOS | tvOS | visionOS (в сторе) | Исходники | Цена |
|---|---|---|---|---|---|---|---|
| Shadowrocket | Shadow Launch Technology Limited | 13.0+ | 10.15+ | 17.0+ | 1.0+ | закрыт | $2.99 разово, IAP на странице нет [V-web] |
| Surge (в сторе «Surge 6») | Surge Networks Inc. | 17.0+ | iPad-сборка на M1+ (macOS 14+); отдельный Surge Mac продаётся на сайте | 17.0+ | 1.0+ | закрыт | iOS: бесплатно + IAP «Feature Subscription» $14.99 и «Surge Pro» $49.99; Mac: $49.99 / $69.99 / $99.99 за 1/3/5 Mac, год обновлений, лицензия Mac не открывает iOS [V-web]. Периодичность «Feature Subscription» — не подтверждено |
| Stash | Stash Networks Limited | 16.0+ | iPad-сборка на M1+ (macOS 13+); отдельная Mac-версия — не подтверждено | 17.0+ | 1.0+ | закрыт | $5.99 разово [V-web] |
| Quantumult X | Cross Utility Ltd | 15.0+ | 12.0+ | 17.0+ | 1.0+ | закрыт | $9.99 разово [V-web] |
| Loon | Loon Lab Limited | 15.0+ | iPad-сборка на M1+ (macOS 12+) | 17.0+ | 1.0+ | закрыт | $7.99 разово [V-web] |
| sing-box (SFI/SFT/SFM, в сторе «sing-box MT») | Metamerism LLC, © nekohasekai | 15.0+ | в App Store нет; standalone SFM (Homebrew cask `sfm`, GitHub Releases), macOS 13+ | 17.0+ | 1.0+ | открыт, GPL-3.0-or-later [V-src] | бесплатно; TestFlight только спонсорам [V-src `sing-box/docs/clients/apple/index.md`] |
| Karing | Supernova Nebula LLC | 15.0+ | 12.0+ | 17.0+ (отдельное SwiftUI-приложение [V-src]) | 1.0+ | частично: публичный репозиторий не собирается, туннель и сборщик конфига закрыты [V-src `reference-apps.md`] | бесплатно [V-web]; реклама провайдеров-партнёров в README и продукте [V-src] |
| Hiddify | Holistic Resilience | 15.5+ | 12.0+ (App Store, DMG, PKG) | нет | 1.0+ | открыт, GPLv3 + NonCommercial и др. условия [V-src] | бесплатно, без рекламы [V-web] |
| OneXray | Yuan Dev LLC | 16.0+ | 13.0+ (App Store) + OneXraySE с System Extension (Homebrew) | нет | 1.0+ | открыт, GPL-3.0 + исключение для VPN-провайдеров [V-src] | бесплатно, без рекламы и аналитики [V-web] |
| Streisand | ARCADIA ODYSSEY INC. | 15.0+ | iPad-сборка на M1+ (macOS 12+) | нет | 1.0+ | закрыт; ядро — не подтверждено (в заметках к версии 1.7.1: «core updated to v26.11.09» — совпадает со схемой версий Xray-core [U]) | бесплатно [V-web] |
| V2Box | techlaim (© Hexa Software) | 15.0+ | 12.0+ | нет | 1.0+ | закрыт; ядро — не подтверждено | бесплатно, «Contains Advertising», трекинг в privacy-метках [V-web] |

Версии на дату проверки (App Store, год на странице не показан): Shadowrocket 2.2.93, Surge 6.0.1, Stash 5.0.0, Quantumult X 1.8.1, Loon 3.5.3, sing-box MT 1.14.8, Karing 1.2.25.2802, Hiddify 5.6.0 (в заметках упомянута 5.9 — страница противоречива), OneXray 26.11.5, Streisand 1.7.1, V2Box 10.2.0. **[V-web]**

---

## 2. Протоколы

| Продукт | Протоколы и транспорты | Дост. |
|---|---|---|
| Shadowrocket | В описании App Store конкретные протоколы не перечислены; названы плагины kcptun, cloak, gost, v2ray и «multi-level forward proxy». Полный список (SS/SSR/VMess/VLESS/Trojan/Hysteria2/TUIC/WireGuard/Snell и т.д.) — **не подтверждено** | [V-web] для плагинов; остальное [U] |
| Surge | HTTP/HTTPS, SOCKS5 (в т.ч. TLS), HTTP/2 CONNECT, TrustTunnel, Shadowsocks, Snell, Trojan, Hysteria 2, AnyTLS, SSH; клиент WireGuard и Tailscale как политика. В оглавлении руководства также страницы VMess, TUIC, MASQUE, VLESS, external | [V-web] (описание стора + оглавление; содержимое страниц протоколов не читалось) |
| Stash | ss (вкл. 2022), ssr, socks5, http, vmess, snell, trojan, anytls, trusttunnel, hysteria, hysteria2, vless, tuic, juicity, mieru, masque, wireguard, tailscale, ssh. VLESS: tcp/ws/h2/http/grpc/xhttp, Reality, Vision, VLESS Encryption; XHTTP с отдельным download-соединением | [V-web] `stash.wiki` |
| Quantumult X | shadowsocks (+SSR-параметры), vmess, vless, trojan, http, socks5, anytls; obfs http/tls/over-tls/ws/wss; Reality; `vless-flow=xtls-rprx-vision`. Hysteria2/TUIC/WireGuard — не подтверждено | [V-web] `sample.conf` |
| Loon | Shadowsocks, ShadowsocksR, HTTP, HTTPS, SOCKS5, VMess, VLESS, Trojan, WireGuard, Tailscale, Hysteria 2, AnyTLS, Snell (v4/v5), Mieru, пользовательский протокол на JavaScript; транспорты ws/http/XHTTP, Reality, ShadowTLS, Vision, VLESS Encryption | [V-web] `nsloon.app/docs/Node/` |
| sing-box | outbound: anytls, http, hysteria, hysteria2, naive, shadowsocks, shadowtls, snell, socks, ssh, tor, trojan, tuic, vless, vmess, wireguard (+ direct/block/dns/selector/urltest/bridge/tailcat); endpoint: wireguard, tailscale, masque, openvpn, openconnect. XHTTP — нет в `docs/configuration` | [V-src] `sing-box/docs/configuration/{outbound,endpoint}` |
| Karing | форк sing-box; заявлены Clash, V2Ray/V2Fly, sing-box, Shadowsocks, подписки. Точный набор протоколов форка — не подтверждено | [V-src] README; остальное не подтверждено |
| Hiddify | «все протоколы sing-box» + XHTTP, Mieru, Naive, WireGuard; VLESS (Reality, Vision), VMess, Trojan, Shadowsocks, Hysteria2, TUIC, SSH, ShadowTLS. Ядро hiddify-core: форк sing-box + xray-core + Psiphon + WARP + Tor и др. | [V-web] стор; [V-src] `reference-apps.md` |
| OneXray | VLESS, VMess, Trojan, Shadowsocks, SOCKS, HTTP, Hysteria2 (описание стора). В Xray-core есть каталоги `proxy/{vless,vmess,trojan,shadowsocks,shadowsocks_2022,socks,http,hysteria,masque,wireguard,tun,…}` и транспорты `splithttp` (XHTTP), `grpc`, `websocket`, `httpupgrade`, `kcp`, `reality`, `xdrive`, `finalmask` | [V-web] + [V-src] `Xray-core/proxy`, `transport/internet` |
| Streisand | VLESS (Reality), VMess, Trojan, Shadowsocks, Socks, SSH, Hysteria (v2), WireGuard; TUIC удалён в 1.7.1 | [V-web] |
| V2Box | Shadowsocks, VMess, Trojan, VLESS, SSH, SOCKS, Ping Tunnel, Hysteria2, DNSTT, WireGuard; Reality, Vision, uTLS | [V-web] |

---

## 3. Маршрутизация, DNS, MITM, скрипты/модули

| Продукт | Маршрутизация | DNS | MITM / перезапись HTTP | Скрипты / модули | Дост. |
|---|---|---|---|---|---|
| Shadowrocket | правила: domain, domain-suffix, domain-keyword, IP-CIDR, GeoIP; импорт правил по URL и из iCloud Drive | локальное сопоставление DNS; DoH, DoT, DoQ | расшифровка HTTPS, URL rewrite | «script filtering»; модули упомянуты только в истории версий (автообновление модулей) | [V-web] |
| Surge | домен, IP, GeoIP, ASN, протокол, порт, логические комбинации, rule-set; в оглавлении руководства также process- и script-правила; группы: select, url-test, fallback, load-balance, smart, subnet | DoH, DoH3, DoQ, DoT, параллельные запросы, локальное сопоставление с wildcard и серверами на домен | MITM; URL/header/body rewrite, map local | JavaScript: HTTP request/response, rule, DNS, event, cron, generic; модули (страница `profile/module.html` — содержимое не прочитано, 404 при попытке по старому пути) | [V-web] |
| Stash | модель Clash: domain, IP-CIDR, User-Agent, Rule Set; SSID-группы политик; on-demand | DNS over TCP/TLS/HTTPS, встроенный DNS-сервер, сопоставление хостов; fake-ip — не подтверждено | MITM, HTTP rewrite, URL rewrite | JavaScript для перезаписи HTTP(S); «override» — частичная замена настроек конфига | [V-web] |
| Quantumult X | user-agent, host/host-keyword/host-suffix/host-wildcard, ip-cidr, ip6-cidr, geoip, ip-asn, final; политики static, available, round-robin, dest-hash, url-latency-benchmark, ssid | серверы на домен, DoH, DoQ, `prefer-doh3`, локальные записи и alias, фильтрация ответов, привязка к SSID | MITM; rewrite: reject-варианты, 302/307, правка заголовков и тел, jq для JSON | `script-request-header/body`, `script-response-header/body`, `script-echo-response`; задачи cron, `event-network`, `event-interaction`; `http_backend` (локальный HTTP-сервер на JS). Модулей в терминах Surge нет — удалённые секции `*_remote` | [V-web] `sample.conf` |
| Loon | по домену, URL, IP, протоколу, порту, HTTP-заголовкам, SSID; группы политик | полный IPv6, асинхронные запросы, DoH, DoQ, DoH3, запись ответов DNS | MITM (в т.ч. HTTP/2), запись заголовков и тел, rewrite | JavaScript; **плагины** — переиспользуемая подконфигурация с секциями General, IP Rewrite, Rule, Rewrite, Script, Host, MitM и `[Argument]` для пользовательских параметров | [V-web] |
| sing-box | `route.rule` + rule-set (бинарный `.srs`, source, AdGuard-формат), sniff, действия правил, geoip/geosite, selector/urltest | серверы: udp, tcp, tls, quic, https, http3, dhcp, fakeip, hosts, local, mdns, resolved, tailscale, openvpn, openconnect; DNS-правила с действиями | нет: слово `mitm` в `docs/configuration` не встречается | нет скриптов и модулей; в клиенте — профили (локальные/удалённые) | [V-src] `sing-box/docs/configuration/{route,rule-set,dns/server}` |
| Karing | «группы разведения» на rule-set (geosite/geoip/ACL), региональные пресеты (в т.ч. `ru.json`), пользовательские urltest-группы | 4 роли резолверов, fakeip, UDP/DoT/DoH/DoH3, автоподбор по задержке | не подтверждено (в открытой части не найдено) | не подтверждено; есть удалённый конфиг с полем `ispPanelJs` | [V-src] `reference-apps.md` §1.6–1.7 |
| Hiddify | правила + регион, «цепочки», балансировка (round-robin, consistent-hashing, sticky-sessions), автовыбор по пингу | раздельные remote/direct DNS, fake DNS, независимый кэш | пользовательской функции MITM нет — не подтверждено | нет — не подтверждено; есть «TLS tricks» (фрагментация, padding) | [V-src] `reference-apps.md` §2; [V-web] |
| OneXray | «Smart» и пользовательская маршрутизация по доменам, IP, GeoData; цепочки прокси, несколько входных серверов, автовыбор; raw JSON Xray | настраивается через конфиг Xray (`app/dns`); UI-возможности — см. `xray.md` | пользовательской функции нет — не подтверждено (в Xray-core слово `mitm` встречается в `proxy/freedom`, `proxy/dokodemo`, `transport/internet/tcp/dialer.go` — это механика ядра, не продуктовая функция [V-src]) | нет — не подтверждено | [V-web] + [V-src] |
| Streisand | «Rule-based Proxy Setup» | «Custom DNS Support» | не подтверждено | не подтверждено | [V-web] |
| V2Box | «custom flexible routing» | DoU, DoH, DoT | не подтверждено | не подтверждено | [V-web] |

---

## 4. Диагностика и прочее (только подтверждённое)

| Продукт | Что заявлено | Дост. |
|---|---|---|
| Shadowrocket | запись HTTP/HTTPS/DNS-запросов; измерение трафика и скорости по Wi-Fi/сотовой/direct/proxy | [V-web] |
| Surge | запись запросов с просмотрщиками JSON/текста/изображений/видео; захват L3-пакетов; Remote Dashboard для Mac; Surge Ponte; расширение Safari; виджеты; синхронизация профилей iCloud Drive/Dropbox; режим шлюза, DHCP, проброс портов (оглавление руководства) | [V-web] |
| Stash | нативная панель HTTP/HTTPS/TCP-запросов; совместимость с конфигом Clash Premium | [V-web] |
| Quantumult X | журнал HTTP с телами запросов и ответов | [V-web] |
| Loon | запись заголовков и тел HTTP/HTTPS; учёт трафика; веб-инструменты (сертификаты, конвертер плагинов, редактор rewrite и скриптов) | [V-web] |
| sing-box | Clash API (`with_clash_api` в Apple-тегах), виджет, расширения Share/Intents/FileProvider (каталоги `sing-box-for-apple/*Extension`) | [V-src] |
| Karing | пошаговый net-check, «какое правило сработает», живые соединения, встроенный zashboard; синхронизация iCloud/WebDAV/LAN; Sentry | [V-src] |
| Hiddify | шифрованный диагностический архив, trace-сессии, информация о расходе подписки | [V-src] / [V-web] |
| OneXray | скорость/трафик, тесты задержки, экспорт логов; виджеты и Control Center, on-demand VPN, меню-бар на Mac, резервные копии в iCloud; конфигурации провайдера Remnawave | [V-web] |
| Streisand | не подтверждено | — |
| V2Box | «Network Combiner» (Wi-Fi + сотовая), раздача через локальный SOCKS5/HTTP | [V-web] |

---

## 5. Наблюдения для позиционирования

1. **Рынок делится на два лагеря.** Платные закрытые «сетевые комбайны» (Surge, Loon, Quantumult X, Stash, Shadowrocket) дают MITM, перезапись HTTP, JavaScript и модули/плагины. Бесплатные открытые клиенты на готовых ядрах (sing-box, Karing, Hiddify, OneXray) дают современные протоколы, но без MITM и скриптов. Открытого продукта с модульностью уровня Surge/Loon в этой выборке нет. **[V-web]/[V-src] по строкам таблиц; вывод — [U]**
2. **Сменных движков нет ни у кого из открытых**: sing-box и OneXray — одно ядро; Hiddify — монолит из нескольких ядер в одном бинарнике; Karing — форк sing-box. **[V-src]**
3. **XHTTP/Reality/Vision перестали быть уникальностью Xray-клиентов**: по официальной документации они есть у Stash и Loon, Reality и Vision — у Quantumult X. В upstream sing-box XHTTP в документации нет. **[V-web]/[V-src]**
4. **tvOS** есть у всех платных и у sing-box/Karing; у Hiddify, OneXray, Streisand, V2Box — нет. **Нативный visionOS не подтверждён ни у кого.** **[V-web]**
5. **Ценовой коридор платных**: $2.99–$9.99 разово; Surge — отдельная модель (бесплатная загрузка + IAP $14.99 / $49.99; Mac от $49.99). Все открытые — бесплатны; монетизация вокруг них — спонсорский TestFlight (sing-box), реклама провайдеров (Karing), коммерческое исключение из лицензии (OneXray). **[V-web]/[V-src]**
6. **Нативный Swift-UI среди открытых** — только sing-box-for-apple; Karing, Hiddify и OneXray написаны на Flutter (у Karing нативное только tvOS-приложение). **[V-src]**

## 6. Что не удалось подтвердить

- Список протоколов Shadowrocket и состав его модулей (официальной документации не найдено).
- Содержимое страниц руководства Surge по модулям, протоколам и MITM (прочитано только оглавление); периодичность «Feature Subscription».
- Ядра Streisand и V2Box, их MITM/скрипты, соблюдение лицензий открытых ядер.
- Наличие отдельной нативной Mac-версии Stash и Loon.
- Реальное поведение любого из продуктов: ни одно приложение не запускалось, всё взято из описаний и исходников.
