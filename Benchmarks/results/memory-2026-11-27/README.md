# Память моста: сырьё замеров 2026-11-27

Описание и выводы — `Documentation/Performance/memory-budget.md`. Стенд — `Cores/BuildScripts/bridge-tunlab.sh`
(Linux/amd64, адреса стенда из документационных диапазонов).

| файл | что |
|---|---|
| `soak-samples-flow.jsonl`, `soak-flow.jsonl` | 30 мин, умолчания (§3) |
| `soak-samples-flow-mobile.jsonl`, `soak-flow-mobile.jsonl` | 30 мин, профиль `mobile` (§6.1) |
| `soak-*-mobile-cfgonly*` | 8 мин, только уровень политики, `connIdle` 60 (§4) |
| `soak-*-mobile-l28gc50*` | 8 мин, `connIdle` 60, предел 28 МиБ, GOGC 50 — непрерывный GC (§4) |
| `soak-*-mobile-gc50l40*`, `soak-*-mobile-gc25l40*` | 6 мин, `connIdle` 60, предел 40 МиБ, GOGC 50 / 25 (§4) |
| `soak-*-mobile-idle30-gc25l40*` | 6 мин, `connIdle` 30, предел 40 МиБ, GOGC 25 (§4) |
| `memcmp.jsonl` | 5 раундов default ↔ mobile: холодный старт, TCP, 100 соединений, всплеск 200 TCP + 200 UDP (§6.2) |
| `*-heap-*top*.txt`, `*-goroutine*.txt` | выжимки `go tool pprof -top` и дампы горутин |

Каждая строка `soak-samples-*.jsonl` — снимок раз в 30 с: `rssBytes`, `rssAnonBytes`, `rssFileBytes` из
`/proc`, `bridge` — ответ `/sample` моста (память рантайма, счётчики tun и потоков). Таблицы:
`python3 Benchmarks/BridgeBench/soak_table.py <файл> [каждый N-й] [плато с минуты]`.
