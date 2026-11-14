import Foundation
#if canImport(Security)
import Security
#endif

/// An injected persistent secret backend. Implementations must be thread-safe,
/// must not call back into ClientSettings, and must not log key/value payloads.
/// A nil write deletes the value. Tests should supply an isolated fake.
public protocol ClientSecretStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data?, for key: String) throws
}

public enum ClientSecrets {
    public static func systemStore() -> any ClientSecretStore {
        #if canImport(Security)
        return ClientKeychainSecretStore()
        #else
        return UnavailableClientSecretStore()
        #endif
    }
}

#if canImport(Security)
/// Uses only an explicitly supplied, already-entitled access group, if any.
/// The service is stable across app-container moves and settings-file migration.
public final class ClientKeychainSecretStore: ClientSecretStore, Sendable {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "exteraless.client-settings", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func data(for key: String) throws -> Data? {
        var query = self.query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClientSettingsError.secretStorageFailure(status: status)
        }
        return data
    }

    public func set(_ data: Data?, for key: String) throws {
        let query = self.query(key)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ClientSettingsError.secretStorageFailure(status: status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            for (key, value) in attributes { addition[key] = value }
            status = SecItemAdd(addition as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw ClientSettingsError.secretStorageFailure(status: status)
        }
    }

    private func query(_ key: String) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false
        ]
        if let accessGroup = self.accessGroup {
            result[kSecAttrAccessGroup as String] = accessGroup
        }
        return result
    }
}
#else
private struct UnavailableClientSecretStore: ClientSecretStore {
    func data(for key: String) throws -> Data? {
        // There is no persistent backend to read. Schema registration and
        // ordinary settings still work; every secret write/delete fails below.
        return nil
    }

    func set(_ data: Data?, for key: String) throws {
        throw ClientSettingsError.secretStorageUnavailable
    }
}
#endif
