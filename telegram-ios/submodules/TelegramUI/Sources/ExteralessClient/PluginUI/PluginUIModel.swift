import CoreFoundation
import Foundation

// Foundation-only wire types. This file and PluginUILifecycle.swift are also
// compiled by the bounded, loginless fixture (without UIKit or PluginHost).
enum PluginUIJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([PluginUIJSON])
    case object([String: PluginUIJSON])

    static func decode(_ json: String) throws -> PluginUIJSON {
        guard json.utf8.count <= 512 * 1024 else {
            throw PluginUIFailure.malformed("UI request exceeds 512 KiB")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        } catch {
            throw PluginUIFailure.malformed("Invalid UI JSON")
        }
        return try Self.convert(object, depth: 0)
    }

    private static func convert(_ raw: Any, depth: Int) throws -> PluginUIJSON {
        guard depth <= 24 else { throw PluginUIFailure.malformed("UI JSON exceeds 24 levels") }
        if raw is NSNull { return .null }
        if let value = raw as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            if let integer = Int64(value.stringValue) { return .integer(integer) }
            if UInt64(value.stringValue) != nil { throw PluginUIFailure.malformed("UI integer does not fit Int64") }
            let type = String(cString: value.objCType)
            if type == "f" || type == "d" {
                guard value.doubleValue.isFinite else { throw PluginUIFailure.malformed("Non-finite UI number") }
                return .number(value.doubleValue)
            }
            throw PluginUIFailure.malformed("UI integer does not fit Int64")
        }
        if let value = raw as? String { return .string(value) }
        if let values = raw as? [Any] {
            guard values.count <= 2048 else { throw PluginUIFailure.malformed("UI array exceeds 2,048 entries") }
            return .array(try values.map { try Self.convert($0, depth: depth + 1) })
        }
        if let values = raw as? [String: Any] {
            guard values.count <= 512 else { throw PluginUIFailure.malformed("UI object exceeds 512 fields") }
            return .object(try values.mapValues { try Self.convert($0, depth: depth + 1) })
        }
        throw PluginUIFailure.malformed("Non-JSON UI value")
    }

    var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .integer(value): return NSNumber(value: value)
        case let .number(value): return NSNumber(value: value)
        case let .string(value): return value
        case let .array(value): return value.map { $0.jsonObject }
        case let .object(value): return value.mapValues { $0.jsonObject }
        }
    }

    func encoded() throws -> String {
        return String(decoding: try JSONSerialization.data(withJSONObject: self.jsonObject, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
    }

    var object: [String: PluginUIJSON]? { if case let .object(value) = self { return value }; return nil }
    var array: [PluginUIJSON]? { if case let .array(value) = self { return value }; return nil }
    var string: String? { if case let .string(value) = self { return value }; return nil }
    var integer: Int64? { if case let .integer(value) = self { return value }; return nil }
    var bool: Bool? { if case let .bool(value) = self { return value }; return nil }
    var number: Double? {
        switch self {
        case let .integer(value): return Double(value)
        case let .number(value): return value
        default: return nil
        }
    }
}

struct PluginUIFailure: Error, Equatable, Sendable {
    let kind: String
    let message: String

    static func malformed(_ message: String) -> Self { return Self(kind: "MalformedRequest", message: message) }
    static func unsupported(_ message: String) -> Self { return Self(kind: "Unimplemented", message: message) }
    static func unavailable(_ message: String) -> Self { return Self(kind: "ServiceUnavailable", message: message) }
    static func invalidHandle(_ message: String) -> Self { return Self(kind: "InvalidHandle", message: message) }
    static func permission(_ message: String) -> Self { return Self(kind: "SecurityError", message: message) }
    static func resource(_ message: String) -> Self { return Self(kind: "ResourceUnavailable", message: message) }

    var json: PluginUIJSON { return .object(["kind": .string(self.kind), "message": .string(self.message)]) }
}

extension Dictionary where Key == String, Value == PluginUIJSON {
    func uiString(_ key: String, default fallback: String? = nil, limit: Int = 16384) throws -> String? {
        guard let raw = self[key], raw != .null else { return fallback }
        guard let value = raw.string, value.utf16.count <= limit else {
            throw PluginUIFailure.malformed("\(key) must be a string of at most \(limit) UTF-16 units")
        }
        return value
    }

    func uiBool(_ key: String, default fallback: Bool) throws -> Bool {
        guard let raw = self[key], raw != .null else { return fallback }
        guard let value = raw.bool else { throw PluginUIFailure.malformed("\(key) must be a boolean") }
        return value
    }

    func uiNumber(_ key: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
        guard let raw = self[key], raw != .null else { return fallback }
        guard let value = raw.number, value.isFinite, range.contains(value) else {
            throw PluginUIFailure.malformed("\(key) is outside its finite native range")
        }
        return value
    }

    func uiArray(_ key: String, limit: Int) throws -> [PluginUIJSON] {
        guard let raw = self[key], raw != .null else { return [] }
        guard let value = raw.array, value.count <= limit else {
            throw PluginUIFailure.malformed("\(key) must be an array of at most \(limit) entries")
        }
        return value
    }

    func uiFields(_ allowed: Set<String>, name: String) throws {
        if let unknown = self.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw PluginUIFailure.unsupported("\(name).\(unknown) has no portable native implementation")
        }
    }
}

struct PluginUICallback: Equatable, Sendable {
    let handle: Int64

    init(_ value: PluginUIJSON) throws {
        guard let marker = value.object, let handle = marker["__handle__"]?.integer, handle > 0 else {
            throw PluginUIFailure.invalidHandle("UI callback requires a tagged positive C handle")
        }
        try marker.uiFields(["__handle__", "__fqcn__", "__fqcn"], name: "callback")
        let canonical = try marker.uiString("__fqcn__", limit: 256)
        let alias = try marker.uiString("__fqcn", limit: 256)
        if let canonical, let alias, canonical != alias {
            throw PluginUIFailure.invalidHandle("Conflicting UI callback type tags")
        }
        self.handle = handle
    }

    static func map(_ raw: PluginUIJSON) throws -> [String: PluginUICallback] {
        guard let object = raw.object, object.count <= 128 else {
            throw PluginUIFailure.malformed("callbacks must be an object of at most 128 leased callables")
        }
        var result: [String: PluginUICallback] = [:]
        for (key, value) in object {
            guard !key.isEmpty, key.utf8.count <= 128 else { throw PluginUIFailure.malformed("Invalid callback name") }
            if value != .null { result[key] = try PluginUICallback(value) }
        }
        return result
    }
}

enum PluginUIPresentationKind: String, Sendable {
    case alert, bulletin, toast, bottomSheet, menu, share, settings, page

    var isTransient: Bool { return self == .bulletin || self == .toast }
    var isPage: Bool { return self == .settings || self == .page }
}

struct PluginUIButton: Equatable, Sendable {
    let which: Int
    let text: String
    let destructive: Bool
    let enabled: Bool
    let dismiss: Bool
    let color: UInt32?

    var callback: String { return self.which == -1 ? "positive" : (self.which == -2 ? "negative" : "neutral") }

    init(_ raw: PluginUIJSON) throws {
        guard let object = raw.object, let which = object["which"]?.integer, [-1, -2, -3].contains(which),
              let text = try object.uiString("text", limit: 1024), !text.isEmpty else {
            throw PluginUIFailure.malformed("Alert button requires which (-1, -2, -3) and nonempty text")
        }
        try object.uiFields(["which", "text", "destructive", "enabled", "dismiss", "color"], name: "button")
        self.which = Int(which)
        self.text = text
        self.destructive = try object.uiBool("destructive", default: false)
        self.enabled = try object.uiBool("enabled", default: true)
        self.dismiss = try object.uiBool("dismiss", default: true)
        if let raw = object["color"], raw != .null {
            guard let value = raw.integer, value >= Int64(Int32.min), value <= Int64(UInt32.max) else { throw PluginUIFailure.malformed("Button color must be a 32-bit ARGB integer") }
            self.color = UInt32(truncatingIfNeeded: value)
        } else { self.color = nil }
    }
}

struct PluginUIItem: Equatable, Sendable {
    let id: String
    let text: String
    let subtext: String?
    let icon: String?
    let destructive: Bool
    let enabled: Bool
    let dismiss: Bool
    let checked: Bool

    init(_ raw: PluginUIJSON, index: Int) throws {
        let object: [String: PluginUIJSON]
        if let text = raw.string { object = ["text": .string(text)] } else if let value = raw.object { object = value } else {
            throw PluginUIFailure.malformed("UI item must be a string or row object")
        }
        try object.uiFields(["id", "text", "subtext", "icon", "destructive", "enabled", "dismiss", "checked"], name: "item")
        guard let text = try object.uiString("text", limit: 4096), !text.isEmpty else {
            throw PluginUIFailure.malformed("UI item requires nonempty text")
        }
        self.id = try object.uiString("id", default: String(index), limit: 256) ?? String(index)
        self.text = text
        self.subtext = try object.uiString("subtext", limit: 4096)
        self.icon = try object.uiString("icon", limit: 256)
        if let icon = self.icon { _ = try PluginUIImages.reference(icon) }
        self.destructive = try object.uiBool("destructive", default: false)
        self.enabled = try object.uiBool("enabled", default: true)
        self.dismiss = try object.uiBool("dismiss", default: true)
        self.checked = try object.uiBool("checked", default: false)
    }
}

struct PluginUIRange: Equatable, Sendable {
    let minimum: Double
    let maximum: Double
    let step: Double

    init(minimum: Double, maximum: Double, step: Double) throws {
        guard minimum.isFinite, maximum.isFinite, step.isFinite, maximum > minimum,
              step > 0, (maximum - minimum).isFinite, ceil((maximum - minimum) / step) <= 2147483647 else {
            throw PluginUIFailure.malformed("Invalid native slider range/step")
        }
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
    }

    func normalize(_ value: Double) -> Double {
        let clamped = min(self.maximum, max(self.minimum, value.isFinite ? value : self.minimum))
        return min(self.maximum, max(self.minimum, self.minimum + floor((clamped - self.minimum) / self.step + 0.5) * self.step))
    }
}

/// Portable views/settings share explicit value widgets; Android View handles,
/// layout classes, Java factories and drawable integers never reach UIKit.
struct PluginUIWidget: Equatable, Sendable {
    enum Kind: String, Sendable { case text, header, divider, input, toggle, slider, selector, column, row, image }

    let id: String
    let key: String
    let kind: Kind
    let text: String
    let subtext: String?
    let hint: String
    let value: PluginUIJSON
    let enabled: Bool
    let destructive: Bool
    let accent: Bool
    let multiline: Bool
    let secure: Bool
    let maximumLength: Int
    let choices: [String]
    let range: PluginUIRange?
    let callback: String?
    let longCallback: String?
    let children: [PluginUIWidget]
    let subpage: [PluginUIWidget]?
    let visibility: String
    let padding: PluginUIInsets
    let layout: PluginUIWidgetLayout
    let spacing: Double
    let icon: String?
    let image: String?
    let imageMode: String
    let font: PluginUIFontSpec?

    static func parse(_ raw: PluginUIJSON, fallbackId: String, depth: Int = 0, count: inout Int) throws -> PluginUIWidget {
        count += 1
        guard depth <= 8, count <= 512 else { throw PluginUIFailure.malformed("UI widgets exceed 8 levels or 512 rows") }
        guard let object = raw.object, object["__handle__"] == nil else {
            throw PluginUIFailure.unsupported("Android View/factory objects are not portable widget DTOs")
        }
        var type = try object.uiString("type", default: "input", limit: 32) ?? "input"
        if type == "switch" { type = "toggle" }
        if type == "edittext" || type == "edit_text" { type = "input" }
        guard let kind = Kind(rawValue: type) else { throw PluginUIFailure.unsupported("Unsupported native widget: \(type)") }
        let common: Set<String> = ["type", "id", "row_id", "key", "text", "subtext", "enabled", "red", "accent", "long_callback_id", "visibility", "padding", "layout", "icon", "font"]
        let fields: Set<String>
        switch kind {
        case .input: fields = ["hint", "value", "default", "multiline", "secure", "max_length", "callback", "callback_id"]
        case .toggle: fields = ["value", "default", "callback", "callback_id"]
        case .slider: fields = ["value", "default", "min", "max", "step", "callback", "callback_id"]
        case .selector: fields = ["value", "default", "items", "callback", "callback_id"]
        case .text, .header: fields = ["hint", "callback", "callback_id", "sub_page"]
        case .row, .column: fields = ["children", "spacing"]
        case .image: fields = ["image", "contentMode", "callback", "callback_id", "sub_page"]
        case .divider: fields = []
        }
        try object.uiFields(common.union(fields), name: "widget.\(type)")
        let rowId = try object.uiString("row_id", limit: 256)
        let callbackId = try object.uiString("callback_id", limit: 128)
        let id = try object.uiString("id", default: rowId ?? fallbackId, limit: 256) ?? fallbackId
        let key = try object.uiString("key", default: id, limit: 256) ?? id
        guard !id.isEmpty, !key.isEmpty else { throw PluginUIFailure.malformed("Widget id/key must not be empty") }
        let text = try object.uiString("text", default: "", limit: 16384) ?? ""
        let hint = try object.uiString("hint", default: "", limit: 4096) ?? ""
        let maximumLengthValue = try object.uiNumber("max_length", default: 16384, range: 0...65536)
        guard maximumLengthValue.rounded() == maximumLengthValue else { throw PluginUIFailure.malformed("max_length must be an integer") }
        let choices = try object.uiArray("items", limit: 256).map { raw -> String in
            guard let text = raw.string, text.utf16.count <= 4096 else { throw PluginUIFailure.malformed("Selector choices must be bounded strings") }
            return text
        }
        var range: PluginUIRange?
        var value = object["value"] ?? object["default"] ?? .null
        switch kind {
        case .input:
            if value == .null { value = .string("") }
            guard let string = value.string, string.unicodeScalars.count <= Int(maximumLengthValue) else {
                throw PluginUIFailure.malformed("Input value must fit max_length")
            }
        case .toggle:
            if value == .null { value = .bool(false) }
            guard value.bool != nil else { throw PluginUIFailure.malformed("Switch value must be boolean") }
        case .slider:
            let parsed = try PluginUIRange(
                minimum: object.uiNumber("min", default: 0, range: -1.0e12...1.0e12),
                maximum: object.uiNumber("max", default: 100, range: -1.0e12...1.0e12),
                step: object.uiNumber("step", default: 1, range: 1.0e-12...1.0e12))
            range = parsed
            if value == .null { value = .number(parsed.minimum) }
            guard let number = value.number else { throw PluginUIFailure.malformed("Slider value must be a number") }
            value = .number(parsed.normalize(number))
        case .selector:
            if value == .null { value = .integer(0) }
            guard let selected = value.integer, selected >= 0, selected < Int64(choices.count) else {
                throw PluginUIFailure.malformed("Selector requires choices and an in-range integer value")
            }
        default: break
        }
        func parseChildren(_ raws: [PluginUIJSON], prefix: String) throws -> [PluginUIWidget] {
            var result: [PluginUIWidget] = []
            for (index, raw) in raws.enumerated() {
                result.append(try Self.parse(raw, fallbackId: "\(id).\(prefix)\(index)", depth: depth + 1, count: &count))
            }
            guard Set(result.map { $0.id }).count == result.count else { throw PluginUIFailure.malformed("Duplicate widget row id") }
            return result
        }
        let children = try parseChildren(object.uiArray("children", limit: 512), prefix: "child")
        let subpage: [PluginUIWidget]?
        if object["sub_page"] == nil || object["sub_page"] == .null { subpage = nil }
        else { subpage = try parseChildren(object.uiArray("sub_page", limit: 512), prefix: "page") }
        guard children.isEmpty || kind == .column || kind == .row else { throw PluginUIFailure.malformed("Only row/column widgets can have children") }
        let multiline = try object.uiBool("multiline", default: false)
        let secure = try object.uiBool("secure", default: false)
        guard !(secure && multiline) else { throw PluginUIFailure.unsupported("Secure multiline input is not a native UIKit field") }
        let visibility = try object.uiString("visibility", default: "visible", limit: 16) ?? "visible"
        guard ["visible", "invisible", "gone"].contains(visibility) else { throw PluginUIFailure.malformed("Widget visibility must be visible, invisible or gone") }
        let icon = try object.uiString("icon", limit: 256)
        if let icon { _ = try PluginUIImages.reference(icon) }
        let image = try object.uiString("image", limit: 256)
        if kind == .image && image == nil { throw PluginUIFailure.resource("Image widget requires a named image") }
        if let image { _ = try PluginUIImages.reference(image) }
        let imageMode = try object.uiString("contentMode", default: "fit", limit: 16) ?? "fit"
        guard ["fit", "fill", "center"].contains(imageMode) else { throw PluginUIFailure.malformed("Image contentMode must be fit, fill or center") }
        let font: PluginUIFontSpec?
        if let raw = object["font"], raw != .null { font = try PluginUIFontSpec(raw) } else { font = nil }
        return PluginUIWidget(id: id, key: key, kind: kind, text: text, subtext: try object.uiString("subtext"), hint: hint, value: value,
            enabled: try object.uiBool("enabled", default: true), destructive: try object.uiBool("red", default: false),
            accent: try object.uiBool("accent", default: false), multiline: multiline, secure: secure, maximumLength: Int(maximumLengthValue),
            choices: choices, range: range, callback: try object.uiString("callback", default: callbackId, limit: 128),
            longCallback: try object.uiString("long_callback_id", limit: 128), children: children, subpage: subpage, visibility: visibility,
            padding: try PluginUIInsets.parse(object["padding"], default: .widget, name: "padding"),
            layout: try PluginUIWidgetLayout(object["layout"]), spacing: try object.uiNumber("spacing", default: 8, range: 0...128),
            icon: icon, image: image, imageMode: imageMode, font: font)
    }

    static func find(_ id: String, in rows: [PluginUIWidget]) -> PluginUIWidget? {
        for row in rows {
            if row.id == id { return row }
            if let found = self.find(id, in: row.children) { return found }
        }
        return nil
    }
}

struct PluginUIModel: Equatable, Sendable {
    let kind: PluginUIPresentationKind
    let raw: [String: PluginUIJSON]
    let title: String?
    let text: String
    let subtitle: String?
    let style: String
    let cancelable: Bool
    let cancelOnTouchOutside: Bool
    let dimEnabled: Bool
    let buttons: [PluginUIButton]
    let items: [PluginUIItem]
    let selectedIndex: Int?
    let progress: Double
    let durationMs: Int
    let buttonText: String?
    let position: String
    let icon: String?
    let widgets: [PluginUIWidget]
    let rows: [PluginUIWidget]
    let files: [String]
    let url: String?
    let pagePath: [String]
    let sourceId: UUID?
    let messageClickable: Bool
    let blurredBackground: Bool
    let blurBehind: Bool

    init(kind: PluginUIPresentationKind, value: PluginUIJSON) throws {
        guard let object = value.object else { throw PluginUIFailure.malformed("UI model must be an object") }
        let common: Set<String> = ["title", "text", "message", "sourceId"]
        let fields: Set<String>
        switch kind {
        case .alert: fields = ["style", "buttons", "items", "selectedIndex", "progress", "input", "view", "subtitle", "cancelable", "cancelOnTouchOutside", "dimEnabled", "icon", "messageClickable", "blurredBackground", "blurBehind"]
        case .bulletin, .toast: fields = ["style", "durationMs", "buttonText", "position", "subtitle", "cancelable", "icon"]
        case .bottomSheet, .menu: fields = ["items", "buttons", "view", "input", "selectedIndex", "subtitle", "cancelable", "cancelOnTouchOutside", "dimEnabled", "icon", "messageClickable", "blurredBackground", "blurBehind"]
        case .share: fields = ["files", "url", "mimeType", "cancelable"]
        case .settings, .page: fields = ["rows", "pagePath", "targetRowId", "settingsSnapshotId", "subtitle", "cancelable", "icon"]
        }
        try object.uiFields(common.union(fields), name: kind.rawValue)
        if kind == .settings && object["rows"] == nil {
            try object.uiFields(["title", "pagePath", "sourceId"], name: "nativeSettingsPage")
        }
        self.kind = kind
        self.raw = object
        self.title = try object.uiString("title", limit: 4096)
        self.text = try object.uiString("text", default: object.uiString("message", default: "", limit: 65536), limit: 65536) ?? ""
        self.subtitle = try object.uiString("subtitle", limit: 16384)
        let style = try object.uiString("style", default: kind == .alert ? "message" : "info", limit: 32) ?? "info"
        if kind == .alert && !["message", "loading", "spinner"].contains(style) { throw PluginUIFailure.unsupported("Unsupported alert style: \(style)") }
        if kind.isTransient && !["info", "error", "success", "undo", "simple", "copy"].contains(style) { throw PluginUIFailure.unsupported("Unsupported bulletin style: \(style)") }
        self.style = style
        self.cancelable = try object.uiBool("cancelable", default: kind != .alert || style == "message")
        self.cancelOnTouchOutside = try object.uiBool("cancelOnTouchOutside", default: self.cancelable)
        self.dimEnabled = try object.uiBool("dimEnabled", default: !kind.isTransient)
        self.messageClickable = try object.uiBool("messageClickable", default: false)
        self.blurredBackground = try object.uiBool("blurredBackground", default: false)
        self.blurBehind = try object.uiBool("blurBehind", default: true)
        self.buttons = try object.uiArray("buttons", limit: 3).map(PluginUIButton.init)
        guard Set(self.buttons.map { $0.which }).count == self.buttons.count else { throw PluginUIFailure.malformed("Duplicate alert button id") }
        self.items = try object.uiArray("items", limit: 256).enumerated().map { try PluginUIItem($0.element, index: $0.offset) }
        guard Set(self.items.map { $0.id }).count == self.items.count else { throw PluginUIFailure.malformed("Duplicate UI item id") }
        if let index = object["selectedIndex"], index != .null {
            guard let value = index.integer, value >= -1, value < Int64(self.items.count) else { throw PluginUIFailure.malformed("selectedIndex is outside items") }
            self.selectedIndex = value >= 0 ? Int(value) : nil
        } else { self.selectedIndex = nil }
        self.progress = try object.uiNumber("progress", default: 0, range: 0...100)
        let duration = try object.uiNumber("durationMs", default: style == "undo" ? 5000 : 2750, range: 250...60000)
        guard duration.rounded() == duration else { throw PluginUIFailure.malformed("durationMs must be an integer") }
        self.durationMs = Int(duration)
        self.buttonText = try object.uiString("buttonText", limit: 1024)
        if self.buttonText?.isEmpty == true { throw PluginUIFailure.malformed("Bulletin buttonText must not be empty") }
        self.position = try object.uiString("position", default: "bottom", limit: 16) ?? "bottom"
        guard ["top", "bottom"].contains(self.position) else { throw PluginUIFailure.malformed("position must be top or bottom") }
        self.icon = try object.uiString("icon", limit: 256)
        if let icon = self.icon { _ = try PluginUIImages.reference(icon) }
        var count = 0
        var widgets: [PluginUIWidget] = []
        for key in ["input", "view"] {
            if let value = object[key], value != .null {
                widgets.append(try PluginUIWidget.parse(value, fallbackId: key, count: &count))
            }
        }
        self.widgets = widgets
        self.rows = try object.uiArray("rows", limit: 512).enumerated().map { try PluginUIWidget.parse($0.element, fallbackId: "row\($0.offset)", count: &count) }
        guard Set(self.rows.map { $0.id }).count == self.rows.count else { throw PluginUIFailure.malformed("Duplicate settings row id") }
        self.files = try object.uiArray("files", limit: 16).map { raw in
            guard let path = raw.string, !path.isEmpty, path.utf8.count <= 4096 else { throw PluginUIFailure.malformed("Share files must be bounded paths") }
            return path
        }
        self.url = try object.uiString("url", limit: 8192)
        if let url = self.url { _ = try Self.validateURL(url) }
        self.pagePath = try object.uiArray("pagePath", limit: 16).map { raw in
            guard let id = raw.string, !id.isEmpty, id.utf8.count <= 256 else { throw PluginUIFailure.malformed("Invalid settings pagePath") }
            return id
        }
        if kind.isPage && (kind == .page || object["rows"] != nil) {
            var page = self.rows
            for id in self.pagePath {
                guard let next = PluginUIWidget.find(id, in: page)?.subpage else { throw PluginUIFailure.malformed("pagePath does not identify an existing portable settings page") }
                page = next
            }
        }
        if let source = try object.uiString("sourceId", limit: 64) {
            guard let id = UUID(uuidString: source) else { throw PluginUIFailure.invalidHandle("Invalid native fragment id") }
            self.sourceId = id
        } else { self.sourceId = nil }
        if let target = try object.uiString("targetRowId", limit: 256) {
            guard kind == .settings, object["rows"] != nil, !target.isEmpty, target.utf8.count <= 256 else {
                throw PluginUIFailure.malformed("SettingsTarget.invalid")
            }
            var page = self.rows
            for id in self.pagePath {
                guard let next = PluginUIWidget.find(id, in: page)?.subpage else { throw PluginUIFailure.invalidHandle("SettingsTarget.unknown") }
                page = next
            }
            guard PluginUIWidget.find(target, in: page) != nil else { throw PluginUIFailure.invalidHandle("SettingsTarget.unknown") }
        }
        if let snapshot = try object.uiString("settingsSnapshotId", limit: 36) {
            guard kind == .settings, object["rows"] != nil, UUID(uuidString: snapshot) != nil else {
                throw PluginUIFailure.malformed("Settings snapshot requires a portable settings model and UUID")
            }
        }
        if kind == .share && self.text.isEmpty && self.files.isEmpty && self.url == nil { throw PluginUIFailure.malformed("Share requires text, a URL or files") }
        if kind.isTransient && self.text.isEmpty && self.title?.isEmpty != false { throw PluginUIFailure.malformed("Bulletin/toast requires text") }
    }

    func applying(_ patch: PluginUIJSON) throws -> PluginUIModel {
        guard let object = patch.object else { throw PluginUIFailure.malformed("uiUpdate model must be an object") }
        if self.kind == .share { throw PluginUIFailure.unsupported("An active system share sheet cannot replace its activity items; present a new lease") }
        if self.kind == .settings && self.raw["rows"] == nil {
            throw PluginUIFailure.unsupported("Host settings pages refresh through uiRefreshSettings; uiUpdate takes portable row models")
        }
        var raw = self.raw
        for (key, value) in object { raw[key] = value }
        let updated = try PluginUIModel(kind: self.kind, value: .object(raw))
        guard updated.sourceId == self.sourceId else { throw PluginUIFailure.invalidHandle("uiUpdate cannot retarget the captured native fragment") }
        return updated
    }

    func validateCallbacks(_ names: Set<String>) throws {
        func visit(_ widget: PluginUIWidget) throws {
            guard widget.callback != "closed", widget.longCallback != "closed" else {
                throw PluginUIFailure.invalidHandle("closed is reserved for native terminal lease bookkeeping")
            }
            let changesValue: Bool
            switch widget.kind {
            case .input, .toggle, .slider, .selector: changesValue = true
            default: changesValue = false
            }
            if let name = widget.callback, !names.contains(name), !names.contains(changesValue ? "change" : "action") {
                throw PluginUIFailure.invalidHandle("Widget references an unleased callback; supply it or the generic change/action dispatcher")
            }
            if let name = widget.longCallback, !names.contains(name), !names.contains("longAction"), !names.contains("action") {
                throw PluginUIFailure.invalidHandle("Widget references an unleased long-click callback")
            }
            for child in widget.children { try visit(child) }
            for child in widget.subpage ?? [] { try visit(child) }
        }
        for widget in self.widgets + self.rows { try visit(widget) }
    }

    var valueDefaults: [String: PluginUIJSON] {
        var values: [String: PluginUIJSON] = [:]
        func visit(_ widget: PluginUIWidget) {
            switch widget.kind {
            case .input, .toggle, .slider, .selector: values[widget.key] = widget.value
            default: break
            }
            for child in widget.children { visit(child) }
            for child in widget.subpage ?? [] { visit(child) }
        }
        for widget in self.widgets + self.rows { visit(widget) }
        return values
    }

    static func validateURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["https", "http", "tg", "mailto", "tel"].contains(scheme),
              !["http", "https"].contains(scheme) || url.host?.isEmpty == false else {
            throw PluginUIFailure.malformed("Expected an absolute http(s), tg, mailto or tel URL")
        }
        return url
    }
}
