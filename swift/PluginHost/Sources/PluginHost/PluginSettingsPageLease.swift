import Foundation

/// An opaque SDK settings snapshot, not a Python/C handle or a UIKit model.
/// Closing revokes queued work synchronously and releases its Python registry on
/// the captured interpreter's FIFO. That cleanup never resolves a replacement ID.
public final class PluginSettingsPageLease: @unchecked Sendable {
    public let id = UUID().uuidString.lowercased()
    public let owner: PluginHost.CallbackOwner
    public let account: Int32
    private let lock = NSLock()
    private var open = true
    private var claimed = false
    private var cleanup: (@Sendable () -> Void)?

    public init(owner: PluginHost.CallbackOwner, account: Int32) {
        self.owner = owner
        self.account = account
    }

    public var isOpen: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.open }
    public var wasRead: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.claimed }

    func claimRead(owner: PluginHost.CallbackOwner, account: Int32, cleanup: @escaping @Sendable () -> Void) throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.open, !self.claimed, self.owner == owner, self.account == account, account >= 0 else {
            throw PluginHostError.superseded("Settings page/read owner is expired or already used")
        }
        self.claimed = true
        self.cleanup = cleanup
    }

    func check(owner: PluginHost.CallbackOwner?, account: Int32?) throws {
        guard self.isOpen, self.wasRead, owner == self.owner, account == self.account else {
            throw PluginHostError.superseded("Settings action does not own this page/read snapshot")
        }
    }

    public func close() {
        self.lock.lock()
        self.open = false
        let cleanup = self.cleanup
        self.cleanup = nil
        self.lock.unlock()
        cleanup?()
    }

    deinit { self.close() }
}

/// Carries native page authority through the existing ManagerActions closures.
/// The optional event is bounded JSON, never executable Python. Normal legacy
/// callers retain their existing SDK callback arity when no page is supplied.
public enum PluginSettingsPageExecution {
    @TaskLocal public static var current: PluginSettingsPageLease?
    @TaskLocal public static var widgetEventJSON: String?
}
