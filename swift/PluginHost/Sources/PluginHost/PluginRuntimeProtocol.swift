import Foundation

/// The JSON boundary shared with python/exteraless_runtime. Payloads are always
/// decoded as JSON by Python; JSON booleans/null are never pasted as Python code.
enum PluginRuntimeScript {
    static func quote(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try! encoder.encode(text), as: UTF8.self)
    }

    static func call(_ method: String, _ arguments: [String]) -> String {
        "_exteraless_runtime.\(method)(" + arguments.map(quote).joined(separator: ", ") + ")"
    }

    static func jsonValue(_ source: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed])
        } catch {
            throw PluginHostError.runtimeFailure("Plugin runtime returned invalid JSON: \(error)")
        }
    }

    static func encodeJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func metadata(_ source: String) throws -> Plugin {
        guard let envelope = try jsonValue(source) as? [String: Any] else {
            throw PluginHostError.invalidPlugin("metadata must be a JSON object")
        }
        if let ok = envelope["ok"] as? Bool, !ok {
            throw PluginHostError.invalidPlugin(String(describing: envelope["error"] ?? "metadata failed"))
        }
        let raw = envelope["metadata"] ?? envelope["meta"] ?? envelope
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = try JSONSerialization.data(withJSONObject: raw)
        let plugin = try decoder.decode(Plugin.self, from: data)
        guard Plugin.isValidID(plugin.id), plugin.engine == "python" else {
            throw PluginHostError.invalidPlugin("unsupported plugin id or engine")
        }
        return plugin
    }

    static func applyLoadResult(_ source: String, to installed: Plugin) throws -> Plugin {
        guard let result = try jsonValue(source) as? [String: Any],
              let metadata = result["metadata"] as? [String: Any],
              let id = metadata["id"] as? String, id == installed.id,
              let handles = result["handles"] as? [String: Bool],
              let hasSettings = result["has_settings"] as? Bool else {
            throw PluginHostError.runtimeFailure("Invalid plugin load result or mismatched plugin id")
        }
        var plugin = installed
        plugin.loaded = true
        plugin.loadError = nil
        plugin.loadDebug = nil
        plugin.notResponding = false
        plugin.hasSettings = hasSettings
        plugin.handlesAppEvent = handles["app_event"] ?? false
        plugin.handlesPreRequest = handles["pre_request"] ?? false
        plugin.handlesPostRequest = handles["post_request"] ?? false
        plugin.handlesUpdate = handles["update"] ?? false
        plugin.handlesUpdates = handles["updates"] ?? false
        plugin.handlesSendMessage = handles["send_message"] ?? false
        return plugin
    }

    static func sendResult(_ source: String) throws -> PluginSendMessageResult {
        guard let result = try jsonValue(source) as? [String: Any],
              let value = result["strategy"] as? String,
              let strategy = HookStrategy(rawValue: value) else {
            throw PluginHostError.runtimeFailure("Invalid send-message hook result")
        }
        let params = result["params"]
        let replacement = try params.flatMap { value -> String? in
            if value is NSNull { return nil }
            return try encodeJSON(value)
        }
        if (strategy == .modify || strategy == .modifyFinal) && replacement == nil {
            throw PluginHostError.runtimeFailure("MODIFY hook omitted its replacement params")
        }
        return PluginSendMessageResult(strategy: strategy, paramsJSON: replacement)
    }

    static func applyingSendResult(_ source: String, to originalParams: String) throws -> PluginSendMessageResult {
        var result = try sendResult(source)
        if result.strategy == .modify || result.strategy == .modifyFinal {
            guard let replacement = result.paramsJSON,
                  let patch = try jsonValue(replacement) as? [String: Any],
                  var params = try jsonValue(originalParams) as? [String: Any] else {
                throw PluginHostError.runtimeFailure("Send-message params and MODIFY patch must be objects")
            }
            // Core accepts sparse patches. The following plugin still needs the
            // complete snapshot, including peer/account identity and earlier edits.
            for (key, value) in patch { params[key] = value }
            result.paramsJSON = try encodeJSON(params)
        }
        return result
    }
}
