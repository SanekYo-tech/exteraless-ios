import Foundation

struct PluginUIInsets: Equatable, Sendable {
    let top: Double
    let left: Double
    let bottom: Double
    let right: Double

    static let zero = PluginUIInsets(top: 0, left: 0, bottom: 0, right: 0)
    static let widget = PluginUIInsets(top: 10, left: 12, bottom: 10, right: 12)

    static func parse(_ value: PluginUIJSON?, default fallback: PluginUIInsets, name: String) throws -> PluginUIInsets {
        guard let value, value != .null else { return fallback }
        let object: [String: PluginUIJSON]
        if let array = value.array, array.count == 4 {
            object = ["left": array[0], "top": array[1], "right": array[2], "bottom": array[3]]
        } else if let fields = value.object { object = fields }
        else { throw PluginUIFailure.malformed("\(name) requires {left,top,right,bottom} or [left,top,right,bottom]") }
        try object.uiFields(["left", "top", "right", "bottom"], name: name)
        return try PluginUIInsets(top: object.uiNumber("top", default: 0, range: 0...512),
            left: object.uiNumber("left", default: 0, range: 0...512),
            bottom: object.uiNumber("bottom", default: 0, range: 0...512),
            right: object.uiNumber("right", default: 0, range: 0...512))
    }

    /// Preserve the requested ratio when a narrow viewport cannot fit both
    /// insets. No negative content width or broken required constraint is emitted.
    func fitting(width: Double) -> PluginUIInsets {
        let horizontal = self.left + self.right
        let available = max(0, width - 1)
        let scale = horizontal > available && horizontal > 0 ? available / horizontal : 1
        return PluginUIInsets(top: self.top, left: self.left * scale, bottom: self.bottom, right: self.right * scale)
    }
}

enum PluginUIDimension: Equatable, Sendable {
    case fill, wrap, points(Double)

    static func parse(_ value: PluginUIJSON?, default fallback: PluginUIDimension, name: String) throws -> PluginUIDimension {
        guard let value, value != .null else { return fallback }
        if value == .string("fill") || value == .integer(-1) { return .fill }
        if value == .string("wrap") || value == .integer(-2) { return .wrap }
        guard let points = value.number, points.isFinite, (0...8192).contains(points) else {
            throw PluginUIFailure.malformed("\(name) must be fill, wrap or 0...8192 native points")
        }
        return .points(points)
    }
}

struct PluginUIWidgetLayout: Equatable, Sendable {
    let width: PluginUIDimension
    let height: PluginUIDimension
    let margins: PluginUIInsets
    let alignment: String
    let weight: Double

    init(_ value: PluginUIJSON?) throws {
        let object: [String: PluginUIJSON]
        if value == nil || value == .null { object = [:] }
        else if let fields = value?.object { object = fields }
        else { throw PluginUIFailure.malformed("layout requires a portable layout object") }
        try object.uiFields(["width", "height", "margins", "alignment", "weight"], name: "layout")
        self.width = try PluginUIDimension.parse(object["width"], default: .fill, name: "layout.width")
        self.height = try PluginUIDimension.parse(object["height"], default: .wrap, name: "layout.height")
        self.margins = try PluginUIInsets.parse(object["margins"], default: .zero, name: "layout.margins")
        self.alignment = try object.uiString("alignment", default: "fill", limit: 16) ?? "fill"
        guard ["fill", "start", "center", "end"].contains(self.alignment) else { throw PluginUIFailure.malformed("Unsupported native layout alignment") }
        self.weight = try object.uiNumber("weight", default: 0, range: 0...1000)
    }

    func minimumColumnWidth() -> Double {
        if case let .points(value) = self.width, value > 0 { return value + self.margins.left + self.margins.right }
        return 148 + self.margins.left + self.margins.right
    }
}

struct PluginUIFontSpec: Equatable, Hashable, Sendable {
    let name: String
    let size: Double?
    let weight: String

    init(_ value: PluginUIJSON) throws {
        let object: [String: PluginUIJSON]
        if let name = value.string { object = ["name": .string(name)] }
        else if let fields = value.object { object = fields }
        else { throw PluginUIFailure.malformed("font requires a name or {name,size,weight}") }
        try object.uiFields(["name", "size", "weight"], name: "font")
        self.name = try object.uiString("name", default: "system", limit: 128) ?? "system"
        guard !self.name.isEmpty else { throw PluginUIFailure.resource("Font name is empty") }
        if object["size"] != nil && object["size"] != .null { self.size = try object.uiNumber("size", default: 17, range: 1...128) }
        else { self.size = nil }
        self.weight = try object.uiString("weight", default: "regular", limit: 32) ?? "regular"
        guard ["ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"].contains(self.weight) else {
            throw PluginUIFailure.resource("Unavailable font weight: \(self.weight)")
        }
        if self.name != "system" && self.name != "monospace" && self.weight != "regular" {
            throw PluginUIFailure.resource("Use an installed PostScript face for a named font weight: \(self.name)")
        }
    }
}

enum PluginUIImages {
    static let aliases: [String: String] = [
        "msg_copy": "doc.on.doc", "copy": "doc.on.doc", "msg_share": "square.and.arrow.up",
        "msg_delete": "trash", "msg_settings": "gearshape", "msg_settings_old": "gearshape",
        "msg_info": "info.circle", "info": "info.circle", "msg_search": "magnifyingglass",
        "msg_openin": "safari", "msg_edit": "pencil", "msg_download": "arrow.down.to.line",
        "msg_forward": "arrowshape.turn.up.right", "msg_plugins": "puzzlepiece.extension",
        "msg_save": "square.and.arrow.down", "ic_save_to_gallery": "square.and.arrow.down",
        "msg_link": "link", "msg_photo": "photo", "msg_message": "message", "msg_help": "questionmark.circle",
        "msg_notifications": "bell", "msg_notifications_off": "bell.slash", "msg_add": "plus",
        "msg_clear": "xmark", "msg_success": "checkmark.circle", "msg_error": "exclamationmark.circle"
    ]

    static func reference(_ name: String) throws -> (bundle: Bool, name: String) {
        guard !name.isEmpty, name.utf8.count <= 256 else { throw PluginUIFailure.resource("Invalid native image name") }
        if let alias = self.aliases[name] { return (false, alias) }
        if name.hasPrefix("sf:"), name.count > 3 { return (false, String(name.dropFirst(3))) }
        if name.hasPrefix("bundle:"), name.count > 7 {
            let path = String(name.dropFirst(7))
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains("..") else { throw PluginUIFailure.resource("Invalid bundled image path") }
            return (true, path)
        }
        throw PluginUIFailure.resource("Unavailable native image: \(name)")
    }
}
