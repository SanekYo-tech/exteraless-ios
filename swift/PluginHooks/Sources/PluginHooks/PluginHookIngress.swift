import Foundation

public struct PluginHookIngressLimits: Sendable {
    public let count: Int
    public let bytes: Int
    public init(count: Int = 256, bytes: Int = 32 * 1024 * 1024) {
        self.count = min(256, max(1, count))
        self.bytes = min(32 * 1024 * 1024, max(1, bytes))
    }
}

public enum PluginHookIngressError: Error, Sendable { case queueFull }

public struct PluginHookIngressSnapshot: Sendable {
    public let count: Int
    public let bytes: Int
    public let dropped: Int
}

/// Runtime-only metadata. It is deliberately absent from CodingKeys/equality;
/// copies of the same wire payload retain the same ingress credit.
struct PluginHookPayloadLifetime: Equatable, Sendable {
    var credit: PluginHookIngressCredit? = nil
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

final class PluginHookIngressCredit: @unchecked Sendable {
    private let budget: PluginHookIngressBudget
    private let lock = NSLock()
    private var bytes: Int
    private var deliveryClaimed = false
    init(budget: PluginHookIngressBudget, bytes: Int) { self.budget = budget; self.bytes = bytes }
    func addRawBytes(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard budget.grow(count) else { return false }
        bytes += count
        return true
    }
    func reserveDeliveryBytes(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !deliveryClaimed, budget.grow(count) else { return false }
        deliveryClaimed = true
        bytes += count
        return true
    }
    deinit { budget.release(bytes) }
}

/// Shared across registrations and both observation/send ingress. Detaching an
/// adapter does not reset credits still retained by a main/host/terminal handoff.
final class PluginHookIngressBudget: @unchecked Sendable {
    static let shared = PluginHookIngressBudget()
    private let lock = NSLock()
    private var limits = PluginHookIngressLimits()
    private var count = 0
    private var bytes = 0
    private var dropped = 0
    func configure(_ limits: PluginHookIngressLimits) { lock.lock(); self.limits = limits; lock.unlock() }
    func reserve(bytes: Int = 256) -> PluginHookIngressCredit? {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, bytes <= 16 * 1024 * 1024, count < limits.count,
              bytes <= limits.bytes - self.bytes else { dropped += 1; return nil }
        count += 1
        self.bytes += bytes
        return PluginHookIngressCredit(budget: self, bytes: bytes)
    }
    func grow(_ bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, bytes <= 16 * 1024 * 1024, bytes <= limits.bytes - self.bytes else {
            dropped += 1; return false
        }
        self.bytes += bytes
        return true
    }
    func release(_ bytes: Int) { lock.lock(); count -= 1; self.bytes -= bytes; lock.unlock() }
    var snapshot: PluginHookIngressSnapshot {
        lock.lock(); defer { lock.unlock() }
        return PluginHookIngressSnapshot(count: count, bytes: bytes, dropped: dropped)
    }
}

final class PluginHookSendExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var permitted = true
    var isPermitted: Bool { lock.lock(); defer { lock.unlock() }; return permitted }
    func revoke() { lock.lock(); permitted = false; lock.unlock() }
}
