import Foundation

enum PluginUIRequest {
    static let runtime = "exteraless.ios.Runtime"
    static let members: Set<String> = [
        "uiPresent", "uiUpdate", "uiDismiss", "uiState", "uiActiveFragment", "uiNavigate", "uiRefreshSettings",
        "menuRegister", "menuRemove", "addToClipboard", "openURL"
    ]

    static func claimed(_ json: String) throws -> [String: PluginUIJSON]? {
        // Identify the operation before applying UI-specific bounds. Otherwise a
        // valid large TL request owned by the next provider would fail our 512 KiB
        // budget or widget nesting limit even though this provider does not own it.
        guard let header = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              header["fqcn"] as? String == self.runtime,
              let member = header["member"] as? String, self.members.contains(member) else { return nil }
        guard let request = try PluginUIJSON.decode(json).object else { throw PluginUIFailure.malformed("Expected a UI request object") }
        try request.uiFields(["op", "fqcn", "member", "args", "kwargs", "instance", "value", "pluginId", "ownerToken"], name: "UI request")
        return request
    }
}

/// Opaque C-origin epoch. Compare exactly: no UUID normalization, case folding or
/// fallback to whichever interpreter now owns the same plugin id.
struct PluginUIRequestOrigin: Equatable, Sendable {
    let token: String

    init(_ request: [String: PluginUIJSON]) throws {
        guard let value = request["ownerToken"]?.string, !value.isEmpty,
              value.utf8.count <= 256, !value.contains("\0") else {
            throw PluginUIFailure.permission("UI operation requires the originating native ownerToken")
        }
        self.token = value
    }

    func validate(currentToken: String?) throws {
        guard currentToken == self.token else {
            throw PluginUIFailure.permission("UI request belongs to an expired interpreter owner")
        }
    }
}
