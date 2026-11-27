# Сквозной прогон: вывод компилятора Swift в мосте, режим flow (2026-11-27)

Сервер разработки, Linux/amd64, Go 1.27.4, Xray-core v26.11.9; два netns (`np-s3b-tr-c`, `np-s3b-tr-s`), tun ядра
Linux, насос `nplab` вместо `NEPacketTunnelFlow`, сервер — штатный xray (VLESS+REALITY+Vision).

Порядок: `bridge-tunlab.sh compiled-link` (ключи стенда, ссылка) → `testExportCompiledTunnelConfiguration` и
`testExportPacketTunnelBridgeOptions` в контейнере `swift:5.10` (`NP_EXPORT_DIR`, `NP_EXPORT_LINK`,
`NP_EXPORT_DNS=198.18.0.53`) → `bridge-tunlab.sh compiled DIR`. Интерфейс tun настроен по `plan.json`, мост
получил `config.json` и `bridge-options.json` без правок.

Файлы: `config.json` (UUID и открытый ключ одноразового стенда заменены метками), `plan.json`,
`bridge-options.json`, `report.json` (отчёт компиляции: `exact`), `compiled.jsonl` (результаты).

| Проверка | Результат |
|---|---|
| План: адреса tun, MTU, исключённые маршруты | 198.18.0.1/30, fd66:6e70::1/126, 1500; 9 из 9 маршрутов приняты |
| TCP эхо 8 МиБ IPv4 / IPv6 (SHA-256) | совпало / совпало |
| TCP вниз IPv4 / вверх IPv6, 32 МиБ | 106 / 1127 Мбит/с |
| UDP эхо IPv4 1–4000 Б, IPv6 1–4000 Б (с фрагментацией) | все прошли |
| DNS на резолвер туннеля 198.18.0.2 (A, AAAA) и fd66:6e70::2 (AAAA) | 10/10 каждый |
| DNS на чужие адреса 192.0.2.53 и 2001:db8:ffff::53 (перехват) | 10/10 каждый |
| Локальная сеть 10.200.0.2 мимо туннеля | эхо 1 МиБ, совпало |
| Пакеты на порт 53 мимо туннеля (счётчик nft на veth) | 0 |
| Пакеты на адрес сервера внутри tun (петля) | 0 |
| Профиль `mobile` применён мостом | `tun.outQueueBytes` = 524288 |
| UUID и ключ в журнале ядра и журнале клиента | не найдены |

Не проверено этим прогоном: `NEPacketTunnelFlow`, стек TCP/IP iOS, поведение `excludedRoutes` в NetworkExtension,
сервер с доменным именем. Счётчик утечек без отрицательного контроля.
