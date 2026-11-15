import Foundation

/// A chat-owned return path, not an account-wide message-ID cache. Native callers
/// store EngineMessage.Index values and replace the owner on a peer/thread switch.
public struct DialogHistoryStack<Value: Equatable> {
    private var values: [Value] = []

    public init() {}

    public var isEmpty: Bool { values.isEmpty }

    public mutating func add(_ value: Value, rememberAll: Bool) {
        if !rememberAll { values.removeAll(keepingCapacity: true) }
        if values.last != value { values.append(value) }
    }

    public mutating func pop(rememberAll: Bool) -> Value? {
        let result = values.popLast()
        if !rememberAll { values.removeAll(keepingCapacity: true) }
        return result
    }

    public mutating func removeAll() { values.removeAll(keepingCapacity: true) }

    public mutating func prune(rememberAll: Bool, where shouldRemove: (Value) -> Bool) {
        // Android's all-replies stack survives ordinary scrolling. Only a return
        // action pops it, and the explicit long-press clears it.
        if !rememberAll { values.removeAll(where: shouldRemove) }
    }
}
