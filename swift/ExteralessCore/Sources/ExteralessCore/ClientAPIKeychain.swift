import Foundation
#if canImport(Security)
import Security
#endif

/// insertIfAbsent must be atomic across processes. It returns the winning stored
/// value, including when another process inserted first. Tests inject this seam.
public protocol ClientAPISecureStorage: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data?, key: String) throws
    func insertIfAbsent(_ data: Data, key: String) throws -> Data
}

public enum ClientAPIKeychain {
    public static func storage(accessGroup: String? = nil) -> any ClientAPISecureStorage {
        #if canImport(Security)
        return ClientAPISystemStorage(accessGroup: accessGroup)
        #else
        return ClientAPIUnavailableStorage()
        #endif
    }
}

#if canImport(Security)
private final class ClientAPISystemStorage: ClientAPISecureStorage, Sendable {
    private let backend: ClientKeychainSecretStore
    private let accessGroup: String?
    private let service = "exteraless.client-api"

    init(accessGroup: String?) {
        self.accessGroup = accessGroup
        self.backend = ClientKeychainSecretStore(service: "exteraless.client-api", accessGroup: accessGroup)
    }

    func read(_ key: String) throws -> Data? {
        do { return try backend.data(for: key) }
        catch { throw ClientAPIError.secureStorageUnavailable }
    }

    func write(_ data: Data?, key: String) throws {
        do { try backend.set(data, for: key) }
        catch { throw ClientAPIError.secureStorageUnavailable }
    }

    func insertIfAbsent(_ data: Data, key: String) throws -> Data {
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        if let accessGroup { item[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecSuccess { return data }
        guard status == errSecDuplicateItem, let stored = try read(key) else {
            throw ClientAPIError.secureStorageUnavailable
        }
        return stored
    }
}
#else
private struct ClientAPIUnavailableStorage: ClientAPISecureStorage {
    func read(_ key: String) throws -> Data? { throw ClientAPIError.secureStorageUnavailable }
    func write(_ data: Data?, key: String) throws { throw ClientAPIError.secureStorageUnavailable }
    func insertIfAbsent(_ data: Data, key: String) throws -> Data { throw ClientAPIError.secureStorageUnavailable }
}
#endif

public final class ClientAPIVault: Sendable {
    private let storage: any ClientAPISecureStorage

    public init(storage: any ClientAPISecureStorage = ClientAPIKeychain.storage()) { self.storage = storage }

    func pin(for scope: ClientAPIAccountScope) throws -> ClientAPICredentials? {
        guard let bytes = try storage.read(pinKey(scope)) else { return nil }
        return try decodePin(bytes)
    }

    func pin(_ credentials: ClientAPICredentials, for scope: ClientAPIAccountScope) throws -> ClientAPICredentials {
        let bytes = try JSONEncoder().encode(ClientAPIStoredCredential(credentials))
        return try decodePin(storage.insertIfAbsent(bytes, key: pinKey(scope)))
    }

    func pending(_ environment: ClientAPIEnvironment) throws -> ClientAPIPendingDraft? {
        guard let bytes = try storage.read(pendingKey(environment)) else { return nil }
        guard bytes.count <= 4_096, let draft = try? JSONDecoder().decode(ClientAPIPendingDraft.self, from: bytes),
              draft.version == 1, draft.apiId >= 0,
              draft.replacementHash.map(ClientAPICredentials.validHash) ?? true else {
            throw ClientAPIError.invalidSecureRecord
        }
        return draft
    }

    func setPending(_ draft: ClientAPIPendingDraft?, environment: ClientAPIEnvironment) throws {
        try storage.write(try draft.map { try JSONEncoder().encode($0) }, key: pendingKey(environment))
    }

    private func pinKey(_ scope: ClientAPIAccountScope) -> String { "pin.v1.\(scope.environment.rawValue).\(scope.recordId)" }
    private func pendingKey(_ environment: ClientAPIEnvironment) -> String { "pending.v1.\(environment.rawValue)" }

    private func decodePin(_ bytes: Data) throws -> ClientAPICredentials {
        guard bytes.count <= 4_096, let value = try? JSONDecoder().decode(ClientAPIStoredCredential.self, from: bytes),
              let credentials = try? value.credentials() else { throw ClientAPIError.invalidSecureRecord }
        return credentials
    }
}
