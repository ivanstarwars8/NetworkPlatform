# CoreAbstraction

Граница между control plane и сетевым ядром. Зависимостей нет, только Foundation.
Состояние на 2026-11-24: код написан без компиляции (на хосте нет Swift) и ни разу не запускался.

## Что внутри

| Файл | Содержимое |
|---|---|
| `CoreCapabilities.swift` | `CoreIdentifier`, `CoreProtocol`, `CoreTransport`, `CoreFeature`, `CoreCapabilities`, `CoreDescriptor` |
| `NetworkCore.swift` | протокол `NetworkCore`, `CoreConfiguration`, `CoreStartOptions`, отчёт валидации, `CoreStatistics`, `CoreHealth`, `CoreError` |
| `CoreRegistry.swift` | `CoreRegistry`, `CoreSelector`, `CoreSelection` |
| `CoreLifecycle.swift` | таблица переходов и актор `CoreLifecycle` |

Адаптеров sing-box и Xray здесь нет. В тестах используется `MockCore`, он лежит только в тестовой цели.

## Решения

- **Имена.** ADR-0001 §5 называет интерфейс `TunnelEngine` с пометкой «имена предварительные». Здесь он называется `NetworkCore`, как в постановке задачи. Соответствие: `EngineDescriptor` → `CoreDescriptor`, `EngineConfigBlob` → `CoreConfiguration`, `TunDescriptor` и `EngineLimits` → `CoreStartOptions`, `EngineSnapshot` → `CoreStatistics`. Потока событий (`events`) в протоколе нет: самопроизвольную остановку ядра сторож сообщает через `CoreLifecycle.reportUnexpectedExit`.
- **Открытые множества.** Протоколы, транспорты и возможности — строковые типы, а не `enum`: набор ядер и их возможности — данные сборки (ADR-0001 §3, ADR-0002 §5). Константы взяты из эскиза модели в ADR-0002 §3; таблицы возможностей конкретных версий ядер здесь нет.
- **`reload`.** Вызывается, только если ядро заявило `CoreFeature.hotReload`. Иначе `CoreLifecycle.reload` бросает `unsupportedFeature` и оставляет ядро работать; перезапуск — решение вызывающего.
- **Выбор ядра.** Пригодно ядро со всеми требуемыми возможностями; среди пригодных — первое по списку предпочтений, иначе с наименьшим идентификатором. Результат не зависит от порядка входа; `reasons` перечисляет ход решения.
- **Жизненный цикл.** `start`, `stop`, `reload` и `reportUnexpectedExit` выполняются строго по очереди в порядке вызова. Команда, недопустимая в состоянии на момент своей очереди, бросает `illegalTransition` и ничего не меняет. `stop`, вызванный во время медленного `start`, дожидается его и затем останавливает.

  | Состояние | Допустимо |
  |---|---|
  | `idle` | `start` |
  | `running` | `reload`, `stop`, самопроизвольная остановка |
  | `failed` | `start`, `stop` |
  | `starting`, `reloading`, `stopping` | только исход текущей операции |

- **Проверка конфигурации в `start`** — только структурная: документ для этого ядра, не пуст, не больше 8 МиБ. Предел 8 МиБ — константа этого проекта, не ограничение ядер. `validate` ядра вызывается отдельно.

## Чего нет

- Тайм-аутов. Ядро, у которого `start` или `stop` не возвращается, блокирует очередь. Отмена вызывающей задачи не прерывает операцию.
- Счётчика поколений из ADR-0001 §4: запоздавший старт после stop исключён самой очередью.
- Разбора версии ядра: `CoreDescriptor.version` — строка как есть.
