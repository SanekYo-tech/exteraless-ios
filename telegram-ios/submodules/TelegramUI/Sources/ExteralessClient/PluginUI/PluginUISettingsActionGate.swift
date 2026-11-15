import Foundation

/// Account identity is not its numeric SDK slot. A new opaque lifetime is issued
/// for A -> B -> A and for a replacement AccountContext with the same record id.
struct PluginUISettingsAccountToken: Equatable, Sendable {
    let lifetime: UUID
    let recordId: Int64
    let index: Int32
}

final class PluginUISettingsAccountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PluginUISettingsAccountToken?

    var snapshot: PluginUISettingsAccountToken? {
        self.lock.lock(); defer { self.lock.unlock() }; return self.value
    }

    func replace(recordId: Int64, index: Int32) {
        self.lock.lock(); defer { self.lock.unlock() }
        self.value = PluginUISettingsAccountToken(lifetime: UUID(), recordId: recordId, index: index)
    }

    func clear() { self.lock.lock(); self.value = nil; self.lock.unlock() }

    func permits(_ token: PluginUISettingsAccountToken) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }; return self.value == token
    }
}

/// The worker reads only these locked values, never a controller or MainActor
/// closure. A revoked revision is never reissued, even when the page reappears.
final class PluginUISettingsPageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = UUID()
    private var readRevision = UUID()
    private var visible = false
    private var readAllowed = false
    private var ready = false
    private var closed = false

    func publish() {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.closed else { return }
        self.revision = UUID()
        self.ready = true
    }

    func invalidate() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.revision = UUID()
        self.readRevision = UUID()
        self.ready = false
    }

    /// Applying a successful read replaces controls, not that read's lifetime.
    /// Its already-valid batch effects must not be cancelled by normal rendering.
    func invalidateActions() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.revision = UUID()
        self.ready = false
    }

    func beginAppearance() {
        self.lock.lock(); defer { self.lock.unlock() }
        guard !self.closed else { return }
        if !self.readAllowed { self.readRevision = UUID() }
        self.readAllowed = true
    }

    func setVisible(_ value: Bool) {
        self.lock.lock(); defer { self.lock.unlock() }
        if !value { self.revision = UUID(); self.readRevision = UUID() }
        self.visible = value && !self.closed
        self.readAllowed = value && !self.closed
    }

    func close() {
        self.lock.lock(); defer { self.lock.unlock() }
        self.closed = true
        self.ready = false
        self.visible = false
        self.readAllowed = false
        self.revision = UUID()
        self.readRevision = UUID()
    }

    func capture() throws -> PluginUISettingsActionPermit {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.ready, self.visible, !self.closed else {
            throw PluginUIFailure.invalidHandle("Settings action has no current rendered page revision")
        }
        return PluginUISettingsActionPermit(page: self, revision: self.revision)
    }

    fileprivate func permits(_ revision: UUID) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.ready && self.visible && !self.closed && self.revision == revision
    }

    func captureRead() throws -> PluginUISettingsReadPermit {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.readAllowed, !self.closed else { throw PluginUIFailure.invalidHandle("Settings read belongs to a hidden or closed page") }
        self.readRevision = UUID()
        return PluginUISettingsReadPermit(page: self, revision: self.readRevision)
    }

    fileprivate func permitsRead(_ revision: UUID) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.readAllowed && !self.closed && self.readRevision == revision
    }
}

final class PluginUISettingsActionPermit: @unchecked Sendable {
    private let page: PluginUISettingsPageGate
    private let revision: UUID
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(page: PluginUISettingsPageGate, revision: UUID) {
        self.page = page
        self.revision = revision
    }

    var isCurrent: Bool {
        self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
        return !cancelled && self.page.permits(self.revision)
    }

    func cancel() { self.lock.lock(); self.cancelled = true; self.lock.unlock() }
}

final class PluginUISettingsReadPermit: @unchecked Sendable {
    private let page: PluginUISettingsPageGate
    private let revision: UUID
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(page: PluginUISettingsPageGate, revision: UUID) { self.page = page; self.revision = revision }

    var isCurrent: Bool {
        self.lock.lock(); let cancelled = self.cancelled; self.lock.unlock()
        return !cancelled && self.page.permitsRead(self.revision)
    }

    func cancel() { self.lock.lock(); self.cancelled = true; self.lock.unlock() }
}
