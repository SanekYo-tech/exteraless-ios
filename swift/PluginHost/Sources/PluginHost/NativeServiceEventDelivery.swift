import Foundation

/// Provider-side event buffering, above the existing Host dispatcher. There is
/// one outstanding invocation per owner; Python execution and releases still use
/// PluginCallbackDispatcher's FIFO. No state/network polling is performed.
public final class NativeServiceEventDelivery<Owner: Hashable & Sendable>: @unchecked Sendable {
    private final class Packet: @unchecked Sendable {
        let id = UUID()
        let lease: NativeServiceCallbackLease<Owner>
        let json: String
        let key: String?
        let valid: @Sendable () -> Bool
        let retire: @Sendable () -> Void
        let control: NativeServiceCallbackControl
        var timer: DispatchSourceTimer?
        init(lease: NativeServiceCallbackLease<Owner>, json: String, key: String?,
             valid: @escaping @Sendable () -> Bool, retire: @escaping @Sendable () -> Void) {
            self.lease = lease
            self.json = json
            self.key = key
            self.valid = valid
            self.retire = retire
            self.control = NativeServiceCallbackControl(deadlineNanoseconds: DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
        }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Exteraless.NativeEvents", qos: .userInitiated)
    private let maximumPerOwner: Int
    private let maximumBytes: Int
    private var pending: [Owner: [Packet]] = [:]
    private var active: [Owner: Packet] = [:]
    private var scheduled: Set<Owner> = []
    private var bytes = 0

    public init(maximumPerOwner: Int = 256, maximumBytes: Int = 33_554_432) {
        self.maximumPerOwner = max(1, min(256, maximumPerOwner))
        self.maximumBytes = max(1, min(33_554_432, maximumBytes))
    }

    @discardableResult
    public func enqueue(lease: NativeServiceCallbackLease<Owner>, argumentsJSON: String, coalescingKey: String?,
                        valid: @escaping @Sendable () -> Bool, retire: @escaping @Sendable () -> Void) -> Bool {
        guard valid(), lease.isOpen, argumentsJSON.utf8.count <= NativeServiceWire.maximumRequestBytes else { return false }
        let packet = Packet(lease: lease, json: argumentsJSON, key: coalescingKey.map { lease.id + ":" + $0 }, valid: valid, retire: retire)
        lock.lock()
        var items = pending[lease.owner] ?? []
        // Replace status only in the trailing status segment. Never cross a
        // message/file-terminal event (and thus never reorder applied updates).
        var replacement: Int?
        if let key = packet.key {
            for index in items.indices.reversed() {
                guard items[index].key != nil else { break }
                if items[index].key == key { replacement = index; break }
            }
        }
        let oldBytes = replacement.map { items[$0].json.utf8.count } ?? 0
        let count = items.count + (active[lease.owner] == nil ? 0 : 1) + (replacement == nil ? 1 : 0)
        guard count <= maximumPerOwner, bytes - oldBytes + argumentsJSON.utf8.count <= maximumBytes else {
            lock.unlock()
            retire()
            return false
        }
        if let replacement { items.remove(at: replacement) }
        items.append(packet)
        pending[lease.owner] = items
        bytes = bytes - oldBytes + argumentsJSON.utf8.count
        let owner = lease.owner
        let wake = active[owner] == nil && scheduled.insert(owner).inserted
        lock.unlock()
        if wake { queue.async { [weak self] in self?.pump(owner) } }
        return true
    }

    private func pump(_ owner: Owner) {
        lock.lock()
        scheduled.remove(owner)
        guard active[owner] == nil, var items = pending[owner], !items.isEmpty else { lock.unlock(); return }
        let packet = items.removeFirst()
        if items.isEmpty { pending.removeValue(forKey: owner) } else { pending[owner] = items }
        active[owner] = packet
        lock.unlock()
        guard packet.valid(), packet.lease.isOpen else {
            packet.retire()
            finish(owner, id: packet.id)
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: packet.control.deadlineNanoseconds))
        timer.setEventHandler { [weak self] in
            packet.control.cancel()
            packet.retire()
            self?.finish(owner, id: packet.id)
        }
        packet.timer = timer
        timer.resume()
        let accepted = packet.lease.request(argumentsJSON: packet.json, control: packet.control) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                if case .failure = result { packet.retire() }
                self.finish(owner, id: packet.id)
            }
        }
        if !accepted {
            packet.retire()
            finish(owner, id: packet.id)
        }
    }

    private func finish(_ owner: Owner, id: UUID) {
        lock.lock()
        guard let packet = active[owner], packet.id == id else { lock.unlock(); return }
        active.removeValue(forKey: owner)
        bytes -= packet.json.utf8.count
        let wake = pending[owner]?.isEmpty == false && scheduled.insert(owner).inserted
        lock.unlock()
        packet.timer?.setEventHandler {}
        packet.timer?.cancel()
        packet.timer = nil
        packet.control.cancel()
        if wake { queue.async { [weak self] in self?.pump(owner) } }
    }

    /// Native account/plugin/subscription teardown. A queued result invocation is
    /// cancelled too; the original owner lease pins its release until admission.
    public func remove(subscriptionId: String? = nil, pluginId: String? = nil) {
        queue.async { [self] in
            func matches(_ packet: Packet) -> Bool {
                (subscriptionId == nil || packet.lease.id == subscriptionId) && (pluginId == nil || packet.lease.pluginId == pluginId)
            }
            lock.lock()
            for owner in Array(pending.keys) {
                let removed = pending[owner, default: []].filter(matches)
                bytes -= removed.reduce(0) { $0 + $1.json.utf8.count }
                pending[owner]?.removeAll(where: matches)
                if pending[owner]?.isEmpty == true { pending.removeValue(forKey: owner) }
            }
            let running = active.filter { matches($0.value) }
            lock.unlock()
            for (owner, packet) in running {
                packet.control.cancel()
                finish(owner, id: packet.id)
            }
        }
    }

    public var retainedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    public func count(owner: Owner) -> Int {
        lock.lock(); defer { lock.unlock() }
        return (pending[owner]?.count ?? 0) + (active[owner] == nil ? 0 : 1)
    }

    deinit {
        for packet in active.values {
            packet.timer?.setEventHandler {}
            packet.timer?.cancel()
            packet.timer = nil
            packet.control.cancel()
        }
    }
}
