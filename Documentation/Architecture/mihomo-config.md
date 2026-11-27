# Компилятор модели → Clash YAML (Mihomo): проектная записка

Статус: **проект, кода нет.** Реализация — следующий этап. Основание: ADR-0002 (конфиг движка — результат
компиляции модели, потери не молчаливы), ADR-0007 (второй движок — Mihomo). Мост, который исполняет
результат, — `Cores/MihomoBridge` (Mihomo v1.19.34).

## 1. Место в системе

```
DomainModels (профиль, серверы, правила)
   └─ ConfigurationEngine
        ├─ XrayCompiler      → Xray JSON          (есть, Packages/ConfigurationEngine/Sources/Xray*.swift)
        └─ MihomoCompiler    → Clash YAML + ConversionReport   (этот документ)
                                   └─ расширение MihomoOnly/Dual → npb_start(yaml, options) моста Mihomo
```

Компилятор живёт в `ConfigurationEngine` рядом с компилятором Xray и возвращает тот же `ConversionReport`.
Swift не линкует Go (ADR-0001): компилятор выдаёт текст, проверка движком (`npb_validate`) выполняется в
расширении или на стенде, не в приложении.

## 2. Что мост ожидает от документа

Требования вытекают из `Cores/MihomoBridge/engine/config.go` (`prepareConfig`) [V]:

| Ключ | Что делает компилятор | Почему |
|---|---|---|
| `tun` | `enable: true`, `stack: mips`, `mtu` = MTU туннеля, `dns-hijack` по модели; без `auto-route`, `device`, `file-descriptor` | мост запускает стек `mips` на пакетах `NEPacketTunnelFlow` (`tun.mode: "flow"`); `system`/`gvisor`/`mixed` и fd отвергаются (`config_unsupported`) |
| `tun.recvmsgx` / `sendmsgx` | не выводить | мост принудительно выключает (непубличные `recvmsg_x`/`sendmsg_x`) |
| `find-process-mode` | `off` | мост принудительно ставит `off`; правила `PROCESS-*` в модели не поддерживаются на iOS — компилятор их отбрасывает с записью в отчёт |
| `external-controller*`, `external-ui`, `secret` | не выводить | мост игнорирует и сообщает об этом в `overridden` |
| `iptables`, `redir-port`, `tproxy-port`, `listeners` типа `tun`/`redir`/`tproxy` | не выводить | отвергаются или обнуляются мостом |
| `socks-port`/`mixed-port` | только для отладки на стенде | в расширении входящие порты не нужны (ADR-0003: никаких сокетов между приложением и расширением) |
| `profile.store-selected`, `store-fake-ip` | по решению: выбор группы хранит управляющий слой, поэтому `false` | иначе ядро пишет `cache.db` в `homeDir` и восстанавливает выбор в обход модели |
| `log-level` | из модели; уровень может переопределить опция моста `logLevel` | |

Отчёт моста (`ConfigSummary.overridden`) сравнивается в тестах с отчётом компилятора: всё, что мост
переписал, компилятор должен был не выводить. Расхождение — ошибка компилятора.

## 3. Отображение модели

| Модель (`DomainModels`) | Clash YAML | Потери/замечания |
|---|---|---|
| сервер VLESS (+ flow, REALITY, XHTTP, gRPC, WS, H2) | `proxies[]` `type: vless`, `reality-opts`, `xhttp-opts`, `grpc-opts`, `ws-opts`, `h2-opts`, `client-fingerprint` | ключи по `adapter/outbound/vless.go` закреплённого тега; поля Xray без аналога (`finalmask`, XDRIVE, sockopt) — в отчёт. **`reality-opts.support-x25519mlkem768: true` выводить всегда**: по умолчанию ядро вырезает ключ X25519MLKEM768 из Client Hello, а сервер REALITY Xray 26.11.9 (`xtls/reality` `4bb46b2afd8b`, `tls.go`) такой Client Hello отвергает — проверено тестом моста [V] |
| VMess, Trojan, Shadowsocks (вкл. 2022), Hysteria2, TUIC, WireGuard | соответствующие `type` | набор методов SS-2022 сверить с `sing-shadowsocks2`; проверено связкой с Xray только `2022-blake3-aes-128-gcm` |
| группа выбора / автовыбор / резерв | `proxy-groups` `select` / `url-test` / `fallback` | кто выбирает — `AdaptiveBalancer` или `url-test` движка — открытый вопрос (STATUS §3); по умолчанию компилятор выводит `select`, управляемый слоем |
| правила домена/IP/порта | `rules` (`DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `DOMAIN-REGEX`, `IP-CIDR(6)`, `DST-PORT`, `NETWORK`, `MATCH`) | семантика — по `routing-parity.md`; регулярки Go RE2 против `regexp2` в ядре — проверить |
| geosite/geoip | `GEOSITE`/`GEOIP` или `RULE-SET` | в модели нет (STATUS §3); при появлении — файлы в `homeDir`, без загрузки в расширении |
| DNS | `dns` (`nameserver`, `fallback`, `nameserver-policy`, `enhanced-mode`) | fake-ip согласовать с `tun.dns-hijack`; DoH/DoT/DoQ — по `dns/util.go` |
| импорт подписки Clash | обратное направление: YAML → модель с отчётом | proxy-providers/rule-providers без модели — либо разворачиваются при импорте, либо отказ с причиной |

## 4. Проверка (план)

1. Golden-тесты компилятора на Linux (Swift, контейнер).
2. Каждый скомпилированный документ — через `npb_validate` моста Mihomo на сервере разработки (как
   `Tools/validate-fixtures.sh` для Xray).
3. Interop: клиент Mihomo (мост) ↔ сервер Xray 26.11.9 по корпусу `Tests/Fixtures/interop`; сейчас мостом
   проверены только VLESS+REALITY+Vision и SS-2022 (`engine/protocols_test.go`).
4. Сравнение `ConfigSummary.overridden` с отчётом компилятора (п. 2).

## 5. Открытые вопросы

- Кто владеет выбором сервера внутри движка (`url-test` против `AdaptiveBalancer`) — нужен ADR.
- Где хранить geodata и провайдеры на iOS (App Group, размер, обновление вне расширения).
- Версионирование: ключи YAML привязаны к тегу ядра (сейчас v1.19.34); при обновлении ядра — сверка
  ключей, как в `xray-modern.md` для Xray.
