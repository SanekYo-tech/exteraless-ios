import Foundation

public struct PillRatePair: Codable, Equatable, Hashable, Sendable {
    public let base: String
    public let target: String
    public init(base: String, target: String) {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.base = base == "GRAM" ? "TON" : base == "GOLD" ? "XAU" : base
        self.target = target.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    public func validate() throws {
        guard PillCurrencies.bases.contains(base), PillCurrencies.targets.contains(target) else { throw PillError.invalidConfiguration }
    }
}

public struct PillRateInstance: Equatable, Sendable {
    public let id: Int
    public let pair: PillRatePair
    public init(id: Int, pair: PillRatePair) { self.id = id; self.pair = pair }
    public static let firstId = 100
    public static let maximumCount = 12

    public static func parse(_ raw: String) throws -> [PillRateInstance] {
        guard raw.utf8.count <= 8192 else { throw PillError.invalidConfiguration }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        var result: [PillRateInstance] = []
        var ids = Set<Int>()
        for entry in raw.split(separator: ";", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let id = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  id >= firstId, id <= Int(Int32.max), ids.insert(id).inserted else { throw PillError.invalidConfiguration }
            let codes = parts[1].split(separator: ">", omittingEmptySubsequences: false)
            guard codes.count == 2 else { throw PillError.invalidConfiguration }
            let pair = PillRatePair(base: String(codes[0]), target: String(codes[1]))
            try pair.validate()
            result.append(.init(id: id, pair: pair))
        }
        guard result.count <= maximumCount else { throw PillError.capacity }
        return result
    }
    public static func serialize(_ instances: [PillRateInstance]) -> String {
        instances.map { "\($0.id):\($0.pair.base)>\($0.pair.target)" }.joined(separator: ";")
    }
}

public struct PillCoordinate: Equatable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw PillError.invalidConfiguration }
        self.latitude = latitude; self.longitude = longitude
    }
    public var cacheKey: String { "\(latitude),\(longitude)" }
}

public struct PillConfiguration: Sendable {
    public let values: [String: ClientSettingValue]
    public let instances: [PillRateInstance]
    public init(values: [String: ClientSettingValue]) throws {
        self.values = values
        let raw: String
        if case let .string(value)? = values["chats.rateInstancesRaw"] { raw = value } else { raw = "" }
        instances = try PillRateInstance.parse(raw)
    }
    public func string(_ field: String, fallback: String = "") -> String {
        if case let .string(value)? = values["chats." + field] { return value }
        return fallback
    }
    public var layout: PillLayout {
        let selected: Int
        if case let .integer(value)? = values["chats.lastActivePillId"] { selected = Int(exactly: value) ?? -1 } else { selected = -1 }
        return PillLayout(active: PillLayout.ids(string("activePillsRaw", fallback: "5,6")), hidden: PillLayout.ids(string("hiddenPillsRaw")), selected: selected, loop: values["chats.infiniteScrolling"] != .bool(false))
    }
    public var usesCurrentLocation: Bool { values["chats.weatherUseCurrentLocation"] != .bool(false) }
    public var coordinate: PillCoordinate? {
        guard let lat = Double(string("weatherLatitude")), let lon = Double(string("weatherLongitude")) else { return nil }
        return try? PillCoordinate(latitude: lat, longitude: lon)
    }
}

/// Call from a utility queue. Each operation is one file commit and one observer generation.
public final class PillSettingsStore: Sendable {
    public let settings: ClientSettings
    public init(settings: ClientSettings) { self.settings = settings }

    public func migrateLegacyRates() throws {
        let before = settings.readSnapshot()
        guard before.values["chats.rateInstancesMigrated"] != .bool(true) else { return }
        let config = try PillConfiguration(values: before.values)
        var instances = config.instances
        var layout = config.layout
        var occupied = Set(instances.map(\.id) + layout.active + layout.hidden)
        for legacy in PillRegistry.legacyRates where layout.active.contains(legacy.id) || layout.hidden.contains(legacy.id) {
            guard instances.count < PillRateInstance.maximumCount else { continue } // Legacy ID still has a real provider.
            var id = PillRateInstance.firstId
            while occupied.contains(id) { id += 1 }
            occupied.insert(id)
            let pair = PillRatePair(base: legacy.base, target: config.string(legacy.field, fallback: "AUTO"))
            try pair.validate()
            instances.append(.init(id: id, pair: pair))
            layout.active = layout.active.map { $0 == legacy.id ? id : $0 }
            layout.hidden = layout.hidden.map { $0 == legacy.id ? id : $0 }
            if layout.selected == legacy.id { layout.selected = id }
        }
        var patch = layout.patch
        patch["chats.rateInstancesRaw"] = .string(PillRateInstance.serialize(instances))
        patch["chats.rateInstancesMigrated"] = .bool(true)
        // Include read dependencies in CAS, so a concurrent legacy target edit cannot be lost.
        for legacy in PillRegistry.legacyRates { patch["chats." + legacy.field] = before.values["chats." + legacy.field] ?? .string("AUTO") }
        try settings.applyPublic(patch, expected: before)
    }

    @discardableResult public func addRate(pair: PillRatePair, reservedIds: Set<Int> = []) throws -> Int {
        try pair.validate()
        let before = settings.readSnapshot()
        let config = try PillConfiguration(values: before.values)
        var instances = config.instances
        guard instances.count < PillRateInstance.maximumCount else { throw PillError.capacity }
        var layout = config.layout
        let occupied = Set(instances.map(\.id) + layout.active + layout.hidden).union(reservedIds)
        var id = PillRateInstance.firstId
        while occupied.contains(id) { id += 1 }
        instances.append(.init(id: id, pair: pair)); layout.setActive(id, enabled: true)
        var patch = layout.patch
        patch["chats.rateInstancesRaw"] = .string(PillRateInstance.serialize(instances))
        try settings.applyPublic(patch, expected: before)
        return id
    }

    public func setPair(id: Int, pair: PillRatePair, expectedPair: PillRatePair? = nil) throws {
        try pair.validate()
        let before = settings.readSnapshot()
        let config = try PillConfiguration(values: before.values)
        var instances = config.instances
        if let index = instances.firstIndex(where: { $0.id == id }) {
            if let expectedPair, instances[index].pair != expectedPair { throw ClientSettingsError.concurrentModification }
            instances[index] = .init(id: id, pair: pair)
            try settings.applyPublic(["chats.rateInstancesRaw": .string(PillRateInstance.serialize(instances))], expected: before)
        } else if let legacy = PillRegistry.legacyRates.first(where: { $0.id == id }), legacy.base == pair.base {
            if let expectedPair, expectedPair != PillRatePair(base: legacy.base, target: config.string(legacy.field, fallback: "AUTO")) { throw ClientSettingsError.concurrentModification }
            try settings.applyPublic(["chats." + legacy.field: .string(pair.target)], expected: before)
        } else { throw PillError.invalidConfiguration }
    }

    public func removeRate(id: Int) throws {
        let before = settings.readSnapshot()
        let config = try PillConfiguration(values: before.values)
        guard config.instances.contains(where: { $0.id == id }) else { throw PillError.invalidConfiguration }
        var layout = config.layout
        layout.active.removeAll { $0 == id }; layout.hidden.removeAll { $0 == id }
        if layout.selected == id { layout.selected = -1 }
        var patch = layout.patch
        patch["chats.rateInstancesRaw"] = .string(PillRateInstance.serialize(config.instances.filter { $0.id != id }))
        try settings.applyPublic(patch, expected: before)
    }

    public func setWeather(coordinate: PillCoordinate, address: String) throws {
        guard address.count <= 256 else { throw PillError.invalidConfiguration }
        let before = settings.readSnapshot()
        try settings.applyPublic([
            "chats.weatherLatitude": .string(String(coordinate.latitude)), "chats.weatherLongitude": .string(String(coordinate.longitude)),
            "chats.weatherAddress": .string(address), "chats.weatherUseCurrentLocation": .bool(false)
        ], expected: before)
    }
}
