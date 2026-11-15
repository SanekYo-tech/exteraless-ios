import Foundation

public enum PillType: Int, CaseIterable, Codable, Sendable {
    case weather = 1, gram, btc, usd, cache, proxy, ghost, ram, cpu, networkSpeed, dcPing, gold, eth, eur, lastSeen
}

public struct PillDescriptor: Equatable, Sendable {
    public let id: Int
    public let title: String
    public let symbol: String
    public let interval: TimeInterval
    public let pair: PillRatePair?
    public init(id: Int, title: String, symbol: String, interval: TimeInterval, pair: PillRatePair? = nil) {
        self.id = id; self.title = title; self.symbol = symbol; self.interval = interval; self.pair = pair
    }
}

/// All original IDs remain executable, including legacy rates when migration has no free slots.
public enum PillRegistry {
    public static let builtInIds = PillType.allCases.map(\.rawValue)
    public static let legacyRates: [(id: Int, base: String, field: String)] = [
        (2, "TON", "gramTargetCurrency"), (3, "BTC", "btcTargetCurrency"), (4, "USD", "usdTargetCurrency"),
        (12, "XAU", "goldTargetCurrency"), (13, "ETH", "ethTargetCurrency"), (14, "EUR", "eurTargetCurrency")
    ]

    public static func descriptors(configuration: PillConfiguration, plugins: [PillDescriptor] = []) -> [PillDescriptor] {
        var result: [PillDescriptor] = [
            .init(id: 1, title: "Weather", symbol: "cloud.sun", interval: 900),
            .init(id: 5, title: "Cache", symbol: "internaldrive", interval: 180),
            .init(id: 6, title: "Proxy", symbol: "network", interval: 0),
            .init(id: 7, title: "Ghost mode", symbol: "eye.slash", interval: 0),
            .init(id: 8, title: "RAM", symbol: "memorychip", interval: 3),
            .init(id: 9, title: "App CPU", symbol: "cpu", interval: 3),
            .init(id: 10, title: "Account network", symbol: "arrow.up.arrow.down", interval: 2),
            .init(id: 11, title: "DC connection", symbol: "waveform.path.ecg", interval: 5),
            .init(id: 15, title: "Own last seen", symbol: "clock", interval: 60)
        ]
        for legacy in legacyRates {
            let pair = PillRatePair(base: legacy.base, target: configuration.string(legacy.field, fallback: "AUTO"))
            result.append(rateDescriptor(id: legacy.id, pair: pair))
        }
        result.sort { $0.id < $1.id }
        result += configuration.instances.map { rateDescriptor(id: $0.id, pair: $0.pair) }
        var ids = Set(result.map(\.id))
        result += plugins.filter { ids.insert($0.id).inserted }
        return result
    }

    public static func rateDescriptor(id: Int, pair: PillRatePair) -> PillDescriptor {
        let base = pair.base == "XAU" ? "Gold / troy oz" : pair.base == "TON" ? "GRAM (TON)" : pair.base
        let symbol = pair.base == "BTC" ? "bitcoinsign.circle" : pair.base == "EUR" ? "eurosign.circle" : "chart.line.uptrend.xyaxis"
        return .init(id: id, title: base + " → " + pair.target, symbol: symbol, interval: 300, pair: pair)
    }
}

public struct PillLayout: Equatable, Sendable {
    public var active: [Int]
    public var hidden: [Int]
    public var selected: Int
    public var loop: Bool
    public init(active: [Int] = [5, 6], hidden: [Int] = [], selected: Int = -1, loop: Bool = true) {
        self.active = Self.unique(active); self.hidden = Self.unique(hidden); self.selected = selected; self.loop = loop
    }
    public static func ids(_ raw: String) -> [Int] {
        unique(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }
    private static func unique(_ ids: [Int]) -> [Int] {
        var seen = Set<Int>()
        return ids.filter { seen.insert($0).inserted }
    }
    public func visible(available: Set<Int>) -> [Int] {
        active.filter { available.contains($0) && !hidden.contains($0) }
    }
    public func selection(available: Set<Int>) -> Int? {
        let ids = visible(available: available)
        return ids.contains(selected) ? selected : ids.first
    }
    public func next(current: Int?, available: Set<Int>, forward: Bool) -> Int? {
        let ids = visible(available: available)
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        let next = index + (forward ? 1 : -1)
        return ids.indices.contains(next) ? ids[next] : loop ? ids[(next + ids.count) % ids.count] : current
    }
    public mutating func setActive(_ id: Int, enabled: Bool) {
        active.removeAll { $0 == id }; hidden.removeAll { $0 == id }
        if enabled { active.append(id) } else { hidden.append(id) }
    }
    /// Unknown/dormant IDs retain their slots while the visible subset is reordered.
    public mutating func reorder(_ order: [Int], available: Set<Int>) throws {
        let visible = self.visible(available: available)
        guard order.count == visible.count, Set(order) == Set(visible) else { throw PillError.invalidConfiguration }
        var iterator = order.makeIterator()
        active = active.map { visible.contains($0) ? iterator.next()! : $0 }
    }
    public var patch: [String: ClientSettingValue] {
        ["chats.activePillsRaw": .string(active.map(String.init).joined(separator: ",")),
         "chats.hiddenPillsRaw": .string(hidden.map(String.init).joined(separator: ",")),
         "chats.lastActivePillId": .integer(Int64(selected)), "chats.infiniteScrolling": .bool(loop)]
    }
}
