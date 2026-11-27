import DomainModels
import Foundation
#if canImport(Security)
import Security
#endif

/// Where the secrets of stored profiles live (ADR-0003 §4: secrets in the Keychain, the profile file holds
/// only references). The extension never reads this store: it receives the secrets inline in the compiled
/// configuration.
public protocol SecretStore: AnyObject {
    func setSecret(_ value: String, for reference: SecretReference) throws
    func secret(for reference: SecretReference) -> String?
    func removeSecret(for reference: SecretReference)
}

/// A secret-store failure. Carries the platform status only, never the account or the value.
public struct SecretStoreError: Error, Equatable, Sendable {
    public var status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

#if canImport(Security)
/// Generic-password items of the app's own Keychain access group, one per secret reference. Readable after
/// the first unlock of the device, never migrated to another device.
///
/// compiled on macOS CI (swift-package.yml run 46056045371, apple.yml run 46055850203) only; not exercised by the unit tests (they use an in-memory
/// store), never run on a device.
public final class KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func query(_ reference: SecretReference) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.identifier,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public func setSecret(_ value: String, for reference: SecretReference) throws {
        let data = Data(value.utf8)
        let base = query(reference)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError(status: status) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError(status: added) }
    }

    public func secret(for reference: SecretReference) -> String? {
        var lookup = query(reference)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func removeSecret(for reference: SecretReference) {
        _ = SecItemDelete(query(reference) as CFDictionary)
    }
}
#endif
