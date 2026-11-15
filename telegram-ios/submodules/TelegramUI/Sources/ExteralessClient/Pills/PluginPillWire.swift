import ExteralessCore
import Foundation
import PluginHost

struct PluginPillDescriptor: Sendable {
    let androidId: Int32
    let title: String
    let symbol: String
    let refreshIntervalMs: Int64
    init(_ value: PluginJSONValue) throws {
        let object = try NativeServiceWire.object(value, name: "Pill descriptor", keys: ["androidId", "title", "symbol", "refreshIntervalMs"])
        let id = try NativeServiceWire.integer(object["androidId"], name: "androidId", range: Int64(Int32.min)...Int64(Int32.max))
        guard !(1...15).contains(id), id != -1 else { throw BridgeFailure.malformed("Built-in IDs and the empty-selection sentinel cannot be registered by plugins") }
        self.androidId = Int32(id)
        self.title = try NativeServiceWire.string(object["title"], name: "title", maximum: 512)
        guard self.title.count <= 128 else { throw BridgeFailure.malformed("Pill title exceeds 128 characters") }
        self.symbol = try NativeServiceWire.string(object["symbol"] ?? .string("circle"), name: "symbol", maximum: 128)
        let interval = try NativeServiceWire.integer(object["refreshIntervalMs"] ?? .integer(300_000), name: "refreshIntervalMs", range: 0...3_600_000)
        self.refreshIntervalMs = interval == 0 ? 0 : max(5000, interval)
    }
    func native(id: Int) -> PillDescriptor {
        // Core's registry bounds its timer to >=5s; the bridge suppresses automatic callbacks for 0.
        PillDescriptor(id: id, title: self.title, symbol: self.symbol, interval: self.refreshIntervalMs == 0 ? 3600 : Double(self.refreshIntervalMs) / 1000)
    }
}

enum PluginPillWire {
    static let members: Set<String> = ["pillRegister", "pillUpdate", "pillUnregister", "pillGetLayout", "pillSaveLayout"]
    static let callbackNames: Set<String> = ["start", "update", "tap", "longPress", "stop"]

    static func callbacks(_ value: PluginJSONValue) throws -> [String: Int64] {
        let object = try NativeServiceWire.object(value, name: "Pill callbacks", keys: callbackNames)
        guard object["update"] != nil else { throw BridgeFailure.malformed("Pill update callback is required") }
        var result: [String: Int64] = [:]; var seen = Set<Int64>()
        for name in object.keys.sorted() {
            let handle = try NativeServiceWire.callbackHandle(object[name]!)
            guard seen.insert(handle).inserted else { throw BridgeFailure.invalidHandle("Each pill callback needs a distinct wrapper lease") }
            result[name] = handle
        }
        return result
    }

    static func uuid(_ value: PluginJSONValue?, name: String) throws -> UUID {
        guard let result = UUID(uuidString: try NativeServiceWire.string(value, name: name, maximum: 64)) else { throw BridgeFailure.invalidHandle("Expected a native pill UUID") }
        return result
    }

    static func model(_ value: PluginJSONValue, nativeId: Int, descriptor: PluginPillDescriptor, pluginId: String) throws -> (UUID, PillModel) {
        var object = try NativeServiceWire.object(value, name: "Pill model", keys: ["selection", "title", "value", "detail", "source", "phase", "updatedAtMs", "progress", "isHighlighted"])
        let selection = try uuid(object.removeValue(forKey: "selection"), name: "selection")
        object["id"] = .integer(Int64(nativeId))
        object["title"] = object["title"] ?? .string(descriptor.title)
        object["source"] = object["source"] ?? .string("Plugin " + pluginId)
        guard object["value"] != nil else { throw BridgeFailure.malformed("Pill value is required") }
        if let timestamp = object["updatedAtMs"], timestamp != .null {
            _ = try NativeServiceWire.integer(timestamp, name: "updatedAtMs", range: 1...Int64.max)
        }
        let data = try JSONEncoder().encode(PluginJSONValue.object(object))
        let model: PillModel
        do { model = try JSONDecoder().decode(PillModel.self, from: data); try model.validate() }
        catch { throw BridgeFailure.malformed("Pill reading violates its bounded DTO schema") }
        return (selection, model)
    }

    static func ids(_ value: PluginJSONValue?, name: String) throws -> [Int] {
        guard case let .array(values)? = value, values.count <= 4096 else { throw BridgeFailure.malformed("Pill layout lists are bounded to 4096 IDs") }
        var seen = Set<Int>()
        return try values.map {
            let raw = try NativeServiceWire.integer($0, name: name)
            guard let id = Int(exactly: raw), seen.insert(id).inserted else { throw BridgeFailure.malformed("Pill layout contains duplicate or invalid IDs") }
            return id
        }
    }

    /// Restores only omitted dormant IDs. Registered IDs can be explicitly hidden/removed.
    static func preservingDormant(_ incoming: PillLayout, previous: PillLayout, available: Set<Int>) -> PillLayout {
        var result = incoming
        var mentioned = Set(result.active + result.hidden)
        for (index, id) in previous.active.enumerated() where !available.contains(id) && mentioned.insert(id).inserted {
            result.active.insert(id, at: min(index, result.active.count))
        }
        for id in previous.hidden where !available.contains(id) && mentioned.insert(id).inserted { result.hidden.append(id) }
        return result
    }

    static func layout(_ layout: PillLayout, revision: UUID, identities: [PluginPillIdentityArchive.Identity]) -> PluginJSONValue {
        .object([
            "revision": .string(revision.uuidString), "idSpace": .string("native"),
            "active": .array(layout.active.map { .integer(Int64($0)) }),
            "hidden": .array(layout.hidden.map { .integer(Int64($0)) }),
            "selected": .integer(Int64(layout.selected)), "infiniteScrolling": .bool(layout.loop), "mappingVersion": .integer(1),
            "mappings": .array(identities.map { .object(["androidId": .integer(Int64($0.androidId)), "nativeId": .integer(Int64($0.nativeId))]) })
        ])
    }
}
