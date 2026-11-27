# Сырые результаты стенда моста, 2026-11-27

Методика и выводы — `Documentation/Performance/bridge-benchmarks.md`. Стенд — `Cores/BuildScripts/bridge-tunlab.sh`,
инструмент — `Cores/Bridge/cmd/nplab`. Сервер разработки linux/amd64, 5 vCPU, общий с рабочими сервисами
(load average 3,5–4,5); Go 1.27.4; Xray-core v26.11.9 (`676eaf66f8f0`) в мосте и в штатном `xray`.
Release-сборки (`-trimpath -ldflags='-s -w'`). Все адреса — из документационных диапазонов внутри
одноразовых сетевых пространств имён.

Одна JSON-строка на тест: `label`, `test`, `ok`, `values` (результат теста), `proc` (CPU и RSS процесса
клиента), `bridge` (разность двух снимков рантайма моста; только режим `flow`).

| Файл | Что | Подкоманда |
|---|---|---|
| `e2e.jsonl` | функциональная матрица (release-сборка) | `e2e` |
| `bench.jsonl`, `bench-summary.md` | 7 раундов: напрямую, штатный xray, мост `flow`, мост `fd`; REALITY и SS 2022 | `bench 7`, `summarize.py` |
| `batch.jsonl`, `batch-summary.md` | размер пачки `TunWrite` 1/4/16/64, по 5 прогонов | `batch 5` |
| `diag.jsonl` | проверка гипотез о потолке загрузки (quickack, cubic+pfifo) | `diag` |
| `profile.jsonl`, `profiles/*.txt` | выжимки `go tool pprof -top`: CPU 20 с, куча, аллокации, горутины | `profile` |
| `soak-flow-30min*.{jsonl,txt}` | мост `flow`, 30 минут, снимки каждые 30 с, дамп горутин в конце | `soak 30` |
| `soak-stock*.jsonl` | штатный xray, 8 минут, RSS и потоки | `soak 8 stock` |
| `soak-flow-idle30*.jsonl` | мост `flow`, `connIdle` = 30 с, 6 минут | `CONNIDLE=30 soak 6 flow` |

Двоичные профили pprof в git не положены (в них путь к бинарнику на сервере сборки); они воспроизводятся
подкомандой `profile`.
