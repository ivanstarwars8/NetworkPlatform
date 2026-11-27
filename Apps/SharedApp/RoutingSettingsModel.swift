// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46077240856 (workflow apple.yml)
//
// The app's side of routing and DNS (main actor): the settings file (`RoutingSettingsStore`), downloads of
// lists by address, and the compiler the next connection uses. Settings apply at the next connection; the
// running tunnel is not touched. Nothing polls: lists are downloaded when added and when the user asks.
// The logic below the UI (validation, list parsing and compaction, table, simulator) is in
// Packages/RoutingPolicy and is unit-tested on Linux.
//
// Nothing here logs: list addresses may carry tokens.

import ConfigurationEngine
import DomainModels
import Foundation
import RoutingPolicy
import SwiftUI

@MainActor
final class RoutingSettingsModel: ObservableObject {
    @Published private(set) var settings = RoutingSettings()
    /// Entry counts of the cached lists, by id (the entries themselves stay in the store).
    @Published private(set) var cachedEntryCounts: [UUID: Int] = [:]
    /// Lists being downloaded now.
    @Published private(set) var downloading: Set<UUID> = []
    @Published private(set) var lastError: String?

    private var store: RoutingSettingsStore?
    let limits = RuleSetLimits.standard

    init() {
        do {
            store = try RoutingSettingsStore(directory: try RoutingSettingsModel.storeDirectory())
        } catch let error as RoutingStoreError {
            lastError = "Настройки маршрутов не открылись: \(error.message). Используются значения по умолчанию."
        } catch {
            lastError = "Настройки маршрутов не открылись (\(type(of: error)))."
        }
        publish()
    }

    /// Next to the profiles: Application Support, caches on tvOS (no persistent local storage there).
    private static func storeDirectory() throws -> URL {
        #if os(tvOS)
        let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #else
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #endif
        return base.appendingPathComponent("Routing", isDirectory: true)
    }

    private func publish() {
        guard let store = store else { return }
        settings = store.settings
        cachedEntryCounts = store.ruleSets.mapValues(\.entryCount)
    }

    /// The compiler for the next connection and for the route simulator.
    var compiler: RoutingPolicyCompiler {
        store?.compiler(limits: limits) ?? RoutingPolicyCompiler(settings: settings, ruleSets: [:], limits: limits)
    }

    // MARK: Changes

    /// Applies a change to the settings and saves it. On a write error the previous settings stay.
    func update(_ change: (inout RoutingSettings) -> Void) {
        guard let store = store else {
            lastError = "Настройки маршрутов не сохраняются: файл настроек не открылся."
            return
        }
        var next = store.settings
        change(&next)
        guard next != store.settings else { return }
        do {
            try store.save(next)
            lastError = nil
        } catch let error as RoutingStoreError {
            lastError = "Изменение не сохранилось: \(error.message)."
        } catch {
            lastError = "Изменение не сохранилось (\(type(of: error)))."
        }
        publish()
    }

    func setPreset(_ preset: RoutingPreset) {
        update { $0.preset = preset }
    }

    func saveRule(_ rule: CustomRule) {
        update { settings in
            if let index = settings.customRules.firstIndex(where: { $0.id == rule.id }) {
                settings.customRules[index] = rule
            } else {
                settings.customRules.append(rule)
            }
        }
    }

    func setRuleEnabled(_ id: UUID, _ enabled: Bool) {
        update { settings in
            if let index = settings.customRules.firstIndex(where: { $0.id == id }) {
                settings.customRules[index].isEnabled = enabled
            }
        }
    }

    func moveRules(from source: IndexSet, to destination: Int) {
        update { $0.customRules.move(fromOffsets: source, toOffset: destination) }
    }

    func deleteRules(at offsets: IndexSet) {
        update { $0.customRules.remove(atOffsets: offsets) }
    }

    func deleteRule(_ id: UUID) {
        update { $0.customRules.removeAll { $0.id == id } }
    }

    func deleteList(_ id: UUID) {
        update { $0.remoteRuleSets.removeAll { $0.id == id } }
    }

    func setListEnabled(_ id: UUID, _ enabled: Bool) {
        update { settings in
            if let index = settings.remoteRuleSets.firstIndex(where: { $0.id == id }) {
                settings.remoteRuleSets[index].isEnabled = enabled
            }
        }
    }

    func moveLists(from source: IndexSet, to destination: Int) {
        update { $0.remoteRuleSets.move(fromOffsets: source, toOffset: destination) }
    }

    func deleteLists(at offsets: IndexSet) {
        update { $0.remoteRuleSets.remove(atOffsets: offsets) }
    }

    /// Adds a list and downloads it.
    func addList(_ list: RemoteRuleSet) async {
        update { $0.remoteRuleSets.append(list) }
        await download(list.id)
    }

    // MARK: DNS

    func setDNS(_ change: (inout DNSSettings) -> Void) {
        update { change(&$0.dns) }
    }

    // MARK: Downloads

    private struct DownloadError: Error {
        let message: String
    }

    /// Downloads, parses and caches one list. A failed download keeps the previous entries and records why.
    func download(_ id: UUID) async {
        guard let list = settings.remoteRuleSets.first(where: { $0.id == id }), !downloading.contains(id) else { return }
        downloading.insert(id)
        defer { downloading.remove(id) }
        let limits = self.limits
        do {
            guard case .success(let url) = RemoteRuleSet.validateURL(list.url) else {
                throw DownloadError(message: "адрес списка неверный")
            }
            let text = try await RoutingSettingsModel.fetch(url, maximumBytes: limits.maximumBytes)
            // Parsing up to the size limit takes a moment; keep it off the main actor.
            let parsed = await Task.detached(priority: .userInitiated) { RuleSetParser.parse(text, limits: limits) }.value
            switch parsed {
            case .success(let result):
                guard let store = store else { throw DownloadError(message: "файл настроек не открылся") }
                var next = store.settings
                guard let index = next.remoteRuleSets.firstIndex(where: { $0.id == id }) else { return }
                next.remoteRuleSets[index].updatedAt = Date()
                next.remoteRuleSets[index].domainCount = result.content.domainCount
                next.remoteRuleSets[index].addressCount = result.content.cidrs.count
                next.remoteRuleSets[index].lastError = nil
                do {
                    try store.storeRuleSet(result.content, for: id, updating: next)
                } catch {
                    throw DownloadError(message: "список не сохранился")
                }
                publish()
            case .failure(let error):
                throw DownloadError(message: error.message)
            }
        } catch let error as DownloadError {
            recordListError(id, error.message)
        } catch {
            recordListError(id, "\(type(of: error))")
        }
    }

    func downloadAll() async {
        for list in settings.remoteRuleSets {
            await download(list.id)
        }
    }

    private func recordListError(_ id: UUID, _ message: String) {
        update { settings in
            if let index = settings.remoteRuleSets.firstIndex(where: { $0.id == id }) {
                settings.remoteRuleSets[index].lastError = message
            }
        }
    }

    /// Ephemeral session (no cookies, no cache). Stops reading past `maximumBytes`. Errors name the status
    /// or the error code, never the address.
    private static func fetch(_ url: URL, maximumBytes: Int) async throws -> String {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw DownloadError(message: "ошибка сети \(error.code.rawValue), проверьте адрес и подключение")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError(message: "сервер ответил HTTP \(http.statusCode)")
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw DownloadError(message: "список больше \(maximumBytes / 1024) КБ")
        }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maximumBytes {
                    throw DownloadError(message: "список больше \(maximumBytes / 1024) КБ")
                }
            }
        } catch let error as URLError {
            throw DownloadError(message: "загрузка прервалась (ошибка сети \(error.code.rawValue))")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw DownloadError(message: "ответ не текст UTF-8")
        }
        return text
    }
}
