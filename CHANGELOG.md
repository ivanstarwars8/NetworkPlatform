# CHANGELOG

Выпусков нет. Версия не присвоена.

Формат: раздел на выпуск, внутри — «Добавлено», «Изменено», «Исправлено», «Удалено». Запись появляется вместе с изменением. Непроверенное сборкой помечается явно.

## Не выпущено

### Добавлено

- Исследование Phase 0: `RESEARCH.md`, `Documentation/Research/`, `PROTOCOL_MATRIX.md`, `PLATFORM_MATRIX.md`, `COMPETITOR_MATRIX.md`, `LICENSE_AUDIT.md`, `TECHNICAL_RISKS.md`.
- Архитектурные решения ADR-0001…0006.
- Swift-пакет: модули `DomainModels`, `CoreAbstraction`, `ConfigurationEngine`, `RoutingEngine` с тестами. Запись о прогоне `swift test` отсутствует.
- Расширение Packet Tunnel (`Extensions/PacketTunnel/`), оболочка приложения (`Apps/SharedApp/`), спецификация XcodeGen (`Apps/project.yml`). **Не компилировалось.**
- CI: `swift build` и `swift test` на macOS и в Linux-контейнере (`.github/workflows/ci.yml`). **Не запускался.**
- Документы репозитория: `README.md`, `CLAUDE.md`, `AGENTS.md`, `ROADMAP.md`, `STATUS.md`, `SECURITY.md`, `PRIVACY.md`, `CONTRIBUTING.md`, `THIRD_PARTY_NOTICES.md`, `Documentation/Security/THREAT_MODEL.md`, `Cores/BuildScripts/README.md`.
