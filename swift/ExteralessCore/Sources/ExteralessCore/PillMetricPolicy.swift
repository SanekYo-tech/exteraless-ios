import Foundation

public struct PillCPUCounters: Sendable {
    public let uptime: Double
    public let processSeconds: Double
    public init(uptime: Double, processSeconds: Double) { self.uptime = uptime; self.processSeconds = processSeconds }
}

public struct PillNetworkCounters: Sendable {
    public let uptime: Double
    public let received: UInt64
    public let sent: UInt64
    public let resetIdentity: String
    public init(uptime: Double, received: UInt64, sent: UInt64, resetIdentity: String) {
        self.uptime = uptime; self.received = received; self.sent = sent; self.resetIdentity = resetIdentity
    }
}

public enum PillMetricPolicy {
    /// Percent of one logical CPU, so a multithreaded process may legitimately exceed 100%.
    public static func processCPU(previous: PillCPUCounters?, current: PillCPUCounters, processors: Int) -> Double? {
        guard let previous, processors > 0, current.processSeconds.isFinite, previous.processSeconds.isFinite,
              current.processSeconds >= previous.processSeconds, previous.processSeconds >= 0,
              let elapsed = interval(previous.uptime, current.uptime) else { return nil }
        let result = (current.processSeconds - previous.processSeconds) * 100 / elapsed
        guard result.isFinite, result >= 0, result <= Double(processors) * 100 else { return nil }
        return result
    }
    /// Account MTProto byte counters, not link capacity or whole-device traffic.
    public static func networkSpeed(previous: PillNetworkCounters?, current: PillNetworkCounters) -> (received: Double, sent: Double)? {
        guard let previous, previous.resetIdentity == current.resetIdentity,
              current.received >= previous.received, current.sent >= previous.sent,
              let elapsed = interval(previous.uptime, current.uptime) else { return nil }
        let received = Double(current.received - previous.received) / elapsed
        let sent = Double(current.sent - previous.sent) / elapsed
        guard received.isFinite, sent.isFinite else { return nil }
        return (received, sent)
    }
    private static func interval(_ from: Double, _ to: Double) -> Double? {
        let elapsed = to - from
        guard from.isFinite, to.isFinite, from >= 0, elapsed >= 0.1, elapsed <= 30 else { return nil }
        return elapsed
    }
    public static func freeMemory(bytes: UInt64?, total: UInt64) -> UInt64? {
        guard total > 0, let bytes, bytes <= total else { return nil }
        return bytes
    }
    public static func occupiedFraction(total: Int64, free: Int64) -> Double? {
        guard total > 0, free >= 0, free <= total else { return nil }
        return Double(total - free) / Double(total)
    }
    public static func sumBytes(_ values: [Int64]) -> UInt64? {
        var result: UInt64 = 0
        for value in values {
            guard value >= 0 else { return nil }
            let sum = result.addingReportingOverflow(UInt64(value))
            guard !sum.overflow else { return nil }
            result = sum.partialValue
        }
        return result
    }
}
