import Foundation

public enum PillError: Error, Equatable, LocalizedError, Sendable {
    case invalidConfiguration, invalidData, unsupportedCurrency, capacity, unavailable, cancelled, timeout, network
    case http(Int)
    case rateLimited(retryAt: Date?)
    case throttled(retryAt: Date)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Check the pill's configuration."
        case .invalidData: return "The source returned an invalid reading."
        case .unsupportedCurrency: return "The source has no rate for this currency pair."
        case .capacity: return "You can configure up to 12 rate pairs."
        case .unavailable: return "This reading is not available."
        case .cancelled: return "The request was cancelled."
        case .timeout: return "The source did not respond in time."
        case .network: return "Couldn't reach the source."
        case let .http(code): return "The source returned HTTP \(code)."
        case .rateLimited: return "The source asked to retry later. Its last HTTP response is shown in provider usage."
        case .throttled: return "Refresh is available again in a few seconds."
        }
    }
    public var retryDate: Date? {
        switch self {
        case let .rateLimited(date): return date
        case let .throttled(date): return date
        default: return nil
        }
    }
}

public enum PillPhase: String, Codable, Sendable {
    case idle, loading, ready, stale, failed, unavailable
}

/// A portable render snapshot. No Android views, native pointers or Python calls are used in rendering.
public struct PillModel: Codable, Equatable, Sendable {
    public var id: Int
    public var title: String
    public var value: String
    public var detail: String
    public var source: String
    public var phase: PillPhase
    public var updatedAt: Date?
    public var progress: Double?
    public var isHighlighted: Bool

    public init(id: Int, title: String, value: String, detail: String = "", source: String,
                phase: PillPhase = .ready, updatedAt: Date? = nil, progress: Double? = nil, isHighlighted: Bool = false) {
        self.id = id; self.title = title; self.value = value; self.detail = detail; self.source = source
        self.phase = phase; self.updatedAt = updatedAt; self.progress = progress; self.isHighlighted = isHighlighted
    }

    private enum CodingKeys: String, CodingKey { case id, title, value, detail, source, phase, updatedAtMs, progress, isHighlighted }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp: Date?
        if let milliseconds = try values.decodeIfPresent(Int64.self, forKey: .updatedAtMs) {
            guard let date = PillFreshness.date(milliseconds: milliseconds) else { throw PillError.invalidData }
            timestamp = date
        } else { timestamp = nil }
        self.init(id: try values.decode(Int.self, forKey: .id), title: try values.decode(String.self, forKey: .title),
                  value: try values.decode(String.self, forKey: .value), detail: try values.decodeIfPresent(String.self, forKey: .detail) ?? "",
                  source: try values.decode(String.self, forKey: .source), phase: try values.decodeIfPresent(PillPhase.self, forKey: .phase) ?? .ready,
                  updatedAt: timestamp, progress: try values.decodeIfPresent(Double.self, forKey: .progress),
                  isHighlighted: try values.decodeIfPresent(Bool.self, forKey: .isHighlighted) ?? false)
        try self.validate()
    }
    public func encode(to encoder: Encoder) throws {
        try self.validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(title, forKey: .title); try values.encode(value, forKey: .value)
        try values.encode(detail, forKey: .detail); try values.encode(source, forKey: .source); try values.encode(phase, forKey: .phase)
        if let updatedAt { try values.encode(PillFreshness.milliseconds(updatedAt), forKey: .updatedAtMs) }
        try values.encodeIfPresent(progress, forKey: .progress); try values.encode(isHighlighted, forKey: .isHighlighted)
    }

    public func validate() throws {
        guard id > 0, id <= Int(Int32.max), title.count <= 128, !title.isEmpty, value.count <= 256, detail.count <= 2048,
              source.count <= 256, !source.isEmpty,
              updatedAt.map({ $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 > 0 }) ?? true,
              progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true else { throw PillError.invalidData }
    }

    public var displayText: String {
        title + " · " + value + (phase == .stale ? " · Stale" : "")
    }
}

public struct PillAccountScope: Hashable, Sendable {
    public let accountId: Int64
    public let generation: UUID
    public init(accountId: Int64, generation: UUID = UUID()) { self.accountId = accountId; self.generation = generation }
}

/// Gates both late callbacks and queued durable writes at the account-generation boundary.
public final class PillAccountLease: @unchecked Sendable {
    public let scope: PillAccountScope
    private let lock = NSRecursiveLock()
    private var valid = true
    public init(scope: PillAccountScope) { self.scope = scope }
    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    public func invalidate() { lock.lock(); valid = false; lock.unlock() }
    public func withCurrent<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw PillError.cancelled }
        return try body()
    }
}

public enum PillFreshness {
    public static func isFresh(_ timestamp: Date?, now: Date, ttl: TimeInterval) -> Bool {
        guard let timestamp, ttl.isFinite, ttl > 0 else { return false }
        let age = now.timeIntervalSince(timestamp)
        return age.isFinite && timestamp.timeIntervalSince1970 > 0 && age >= 0 && age < ttl
    }

    public static func date(milliseconds: Int64) -> Date? {
        guard milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    public static func milliseconds(_ date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970 * 1000
        guard value.isFinite, value > 0, value < Double(Int64.max) else { throw PillError.invalidData }
        return Int64(value.rounded(.down))
    }
}
