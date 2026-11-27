# Память моста Mihomo: сырьё замеров 2026-11-27

Описание и выводы — `Documentation/Performance/memory-budget.md` §10. Стенд — `Cores/BuildScripts/bridge-tunlab.sh`
с `ENGINE=mihomo` (мост — `Cores/MihomoBridge/cmd/npmlab`; Linux/amd64, адреса стенда из документационных
диапазонов). Нагрузка `soak` — 4 воркера, по 1 МиБ вниз и вверх на новом TCP-соединении (~1 МиБ/с) и новый
UDP-сокет с 5 обменами за раунд.

| файл | что |
|---|---|
| `soak-samples-mihomo-flow-default.jsonl`, `soak-mihomo-flow-default.jsonl` | 8 мин, умолчания (§10.2) |
| `soak-*-gc25l40*` | 6 мин, предел 40 МиБ + GOGC 25, без профиля (§10.3) |
| `soak-*-mobile.jsonl`, `soak-*-mobile-udp60*`, `soak-*-mobile-gc50*` | 6 мин, профиль `mobile` первой версии: UDP-тайм-аут ядра через `go:linkname` (30 с / 60 с), входная очередь 256 КиБ, GOGC 25 / 50 (§10.3) |
| `soak-*-mobile-sweep5s*` | 30 мин, обходчик простоя раз в 5 с, входная очередь 256 КиБ (§10.4) |
| `soak-*-mobile-final*` | 30 мин, итоговый профиль `mobile` (§10.4) |
| `memcmp.jsonl` | 3 раунда default ↔ mobile, итоговый код: холодный старт, TCP, 100 соединений, всплеск 200 TCP + 200 UDP (§10.4) |
| `memcmp-inq{256k,512k,1m}-sweep5s.jsonl` | то же с входной очередью mobile 256 КиБ / 512 КиБ / 1 МиБ (§10.3) |
| `*-heap-loaded-top.txt`, `*-goroutine-loaded.txt` | `go tool pprof -top` кучи и дампы горутин в конце нагрузки |
| `inprocess-soak-{3m-before,5m-after}-fix.txt` | сэмплы `TestSoakRSS` до и после ограничения буфера вывода xray (§10.1) |

Строка `soak-samples-*.jsonl` — снимок раз в 30 с: `rssBytes`, `rssAnonBytes`, `rssFileBytes` из `/proc` и
`bridge` — ответ `/sample` моста (память рантайма, счётчики tun, `connections`, `idleClosedTcpUdp`). Таблицы:
`python3 Benchmarks/BridgeBench/soak_table.py <файл> [каждый N-й] [плато с минуты]`.
