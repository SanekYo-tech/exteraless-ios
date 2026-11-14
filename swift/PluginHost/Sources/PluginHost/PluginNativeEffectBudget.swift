import Foundation

/// Bounds native main-queue effects while the UI is busy. Tickets are unique;
/// completing a cancelled lifetime cannot decrement a newer generation's budget.
public final class PluginNativeEffectBudget: @unchecked Sendable {
    public final class Ticket: @unchecked Sendable {
        public let id: UUID
        private let budget: PluginNativeEffectBudget

        fileprivate init(id: UUID, budget: PluginNativeEffectBudget) {
            self.id = id
            self.budget = budget
        }
        public var isActive: Bool { budget.contains(id) }
        public func finish() { budget.remove(id) }
        deinit { budget.remove(id) }
    }

    private struct Entry {
        let pluginId: String
        let bytes: Int
    }
    private let lock = NSLock()
    private let maximumPerPlugin: Int
    private let maximumTotal: Int
    private let maximumBytes: Int
    private var entries: [UUID: Entry] = [:]
    private var counts: [String: Int] = [:]
    private var bytes = 0

    public init(maximumPerPlugin: Int = 256, maximumTotal: Int = 1024, maximumBytes: Int = 33_554_432) {
        self.maximumPerPlugin = max(1, maximumPerPlugin)
        self.maximumTotal = max(1, maximumTotal)
        self.maximumBytes = max(1, maximumBytes)
    }

    public func reserve(pluginId: String, bytes: Int) throws -> Ticket {
        try PluginServiceStorage.validatePluginId(pluginId)
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, bytes <= maximumBytes, self.bytes <= maximumBytes - bytes,
              entries.count < maximumTotal, counts[pluginId, default: 0] < maximumPerPlugin else {
            throw BridgeFailure.unavailable("Native effect queue capacity exceeded")
        }
        let id = UUID()
        entries[id] = Entry(pluginId: pluginId, bytes: bytes)
        counts[pluginId, default: 0] += 1
        self.bytes += bytes
        return Ticket(id: id, budget: self)
    }

    public func cancel(pluginId: String) {
        lock.lock(); defer { lock.unlock() }
        for id in entries.keys.filter({ entries[$0]?.pluginId == pluginId }) { removeLocked(id) }
    }

    public func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        counts.removeAll()
        bytes = 0
    }

    private func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries[id] != nil
    }

    private func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        removeLocked(id)
    }

    private func removeLocked(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        bytes -= entry.bytes
        let count = counts[entry.pluginId, default: 0] - 1
        if count == 0 { counts.removeValue(forKey: entry.pluginId) }
        else { counts[entry.pluginId] = count }
    }
}
