import Foundation

public enum PrivacyNotificationAuthorization: String, Codable, Sendable {
    case unknown, notDetermined, denied, authorized, provisional, ephemeral
}

public enum PrivacyNotificationTransport: String, Codable, Sendable { case apns, voip }

public struct PrivacyNotificationIdentity: Hashable, Sendable {
    public let accountId: Int64
    public let peerId: Int64
    public let namespace: Int32
    public let messageId: Int32
    public init(accountId: Int64, peerId: Int64, namespace: Int32, messageId: Int32) {
        self.accountId = accountId; self.peerId = peerId; self.namespace = namespace; self.messageId = messageId
    }
    public func isCleared(by mark: PrivacyNotificationIdentity, exact: Bool) -> Bool {
        accountId == mark.accountId && peerId == mark.peerId && namespace == mark.namespace && (exact ? messageId == mark.messageId : messageId <= mark.messageId)
    }
}
public enum PrivacyNotificationRegistrationState: Equatable, Sendable {
    case notAttempted, registering, registered, unregistered, invalidated
    case failed(code: Int32)
}

/// Intentionally accepts no token, payload, encryption key, device name or error text.
public final class PrivacyNotificationDiagnostics: @unchecked Sendable {
    public static let shared = PrivacyNotificationDiagnostics()
    public struct Snapshot: Sendable {
        public let authorization: PrivacyNotificationAuthorization
        public let tokenReceived: Bool
        public let tokenErrorCode: Int?
        public let apnsRegistration: PrivacyNotificationRegistrationState
        public let voipRegistration: PrivacyNotificationRegistrationState
        public let sandbox: Bool?
    }
    public struct ExtensionReport: Codable, Equatable, Sendable {
        public enum Stage: String, Codable, Sendable { case received, displayed, redacted, suppressed, expired, invalidPayload, accountUnavailable }
        public let stage: Stage
        public let accountId: Int64?
        public let timestamp: TimeInterval
        public init(stage: Stage, accountId: Int64?, timestamp: TimeInterval = Date().timeIntervalSince1970) {
            self.stage = stage; self.accountId = accountId; self.timestamp = timestamp
        }
    }
    private struct Registration {
        var states: [PrivacyNotificationTransport: PrivacyNotificationRegistrationState] = [:]
        var sandbox: Bool?
    }
    private let lock = NSLock()
    private var authorization: PrivacyNotificationAuthorization = .unknown
    private var tokenReceived = false
    private var tokenErrorCode: Int?
    private var registrations: [Int64: Registration] = [:]

    public init() {}
    public func recordAuthorization(_ value: PrivacyNotificationAuthorization) {
        lock.lock(); authorization = value; lock.unlock()
    }
    public func recordTokenReceived() {
        lock.lock(); tokenReceived = true; tokenErrorCode = nil; lock.unlock()
    }
    public func recordTokenFailure(code: Int) {
        lock.lock(); tokenReceived = false; tokenErrorCode = code; lock.unlock()
    }
    public func recordRegistration(accountId: Int64, transport: PrivacyNotificationTransport, state: PrivacyNotificationRegistrationState, sandbox: Bool? = nil) {
        lock.lock()
        var registration = registrations[accountId] ?? Registration()
        registration.states[transport] = state
        if let sandbox { registration.sandbox = sandbox }
        registrations[accountId] = registration
        lock.unlock()
    }
    public func snapshot(accountId: Int64) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let value = registrations[accountId]
        return Snapshot(authorization: authorization, tokenReceived: tokenReceived, tokenErrorCode: tokenErrorCode, apnsRegistration: value?.states[.apns] ?? .notAttempted, voipRegistration: value?.states[.voip] ?? .notAttempted, sandbox: value?.sandbox)
    }
    public func removeAccount(_ id: Int64) {
        lock.lock(); registrations.removeValue(forKey: id); lock.unlock()
    }

    private static func reportURL(root: URL) -> URL { root.appendingPathComponent("exteraless/notification-extension-status.json") }
    public static func writeExtensionReport(_ report: ExtensionReport, root: URL) throws {
        let url = reportURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(report)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    public static func extensionReport(root: URL, accountId: Int64) -> ExtensionReport? {
        guard let data = try? Data(contentsOf: reportURL(root: root)), data.count <= 4096,
              let report = try? JSONDecoder().decode(ExtensionReport.self, from: data), report.accountId == accountId else { return nil }
        return report
    }
}
