import Foundation
import PluginHost
import TelegramPresentationData
import UIKit

/// The Manager's ordinary 1-MiB String document plus parsed portable Custom
/// widgets. Host still sees opaque JSON and a native lifetime, never UIKit.
final class PluginUIManagerSettingsDocument: Sendable {
    let base: PluginUISettingsPageDocument
    let widgets: [PluginUISettingsRowIdentity: PluginUIWidget]
    let lease: PluginSettingsPageLease

    private init(base: PluginUISettingsPageDocument, widgets: [PluginUISettingsRowIdentity: PluginUIWidget], lease: PluginSettingsPageLease) {
        self.base = base
        self.widgets = widgets
        self.lease = lease
    }

    deinit { self.lease.close() }

    var rows: [PluginSetting] { self.base.rows }
    var icons: [PluginUISettingsRowIdentity: String] { self.base.icons }
    func page(_ path: [String]) -> [PluginSetting]? { self.base.page(path) }

    static func decode(_ json: String, lease: PluginSettingsPageLease) throws -> Self {
        let base = try PluginUISettingsPageDocument.decode(json)
        var widgets: [PluginUISettingsRowIdentity: PluginUIWidget] = [:]
        var count = 0
        var callbacks = Set<String>()
        func widgetCallbacks(_ model: PluginUIWidget) {
            if let callback = model.callback { callbacks.insert(callback) }
            if let callback = model.longCallback { callbacks.insert(callback) }
            for child in model.children { widgetCallbacks(child) }
        }
        func visit(_ rows: [PluginSetting], path: [String]) throws {
            for row in rows {
                if let callback = row.callbackId { callbacks.insert(callback) }
                if let callback = row.longCallbackId { callbacks.insert(callback) }
                if row.kind == .custom, row.customError == nil, let json = row.widgetJSON {
                    let widget = try PluginUIWidget.parse(PluginUIJSON.decode(json), fallbackId: row.identifier, count: &count)
                    func validate(_ model: PluginUIWidget) throws {
                        guard model.subpage == nil else { throw PluginUIFailure.unsupported("Custom subpages use the settings row's sub_page") }
                        for child in model.children { try validate(child) }
                    }
                    try validate(widget)
                    widgetCallbacks(widget)
                    widgets[PluginUISettingsRowIdentity(path: path, rowId: row.identifier)] = widget
                }
                if let children = row.subPage { try visit(children, path: path + [row.identifier]) }
            }
        }
        try visit(base.rows, path: [])
        guard callbacks.count <= 128 else { throw PluginUIFailure.malformed("Settings callbacks exceed 128 entries") }
        return Self(base: base, widgets: widgets, lease: lease)
    }

    @MainActor func validateResources(data: PresentationData) throws {
        func visit(_ widget: PluginUIWidget) throws {
            _ = try PluginUIResources.font(widget.font, data: data)
            if let image = widget.image { _ = try PluginUIResources.image(image) }
            if let icon = widget.icon { _ = try PluginUIResources.image(icon) }
            for child in widget.children { try visit(child) }
        }
        for widget in self.widgets.values { try visit(widget) }
    }
}

/// A retained widget/cell closure must carry this snapshot, not ask the current
/// controller to reinterpret its old callback ID against a replacement read.
struct PluginUIManagerWidgetRoute: Sendable {
    let rowId: String
    let root: PluginUIWidget

    func event(widget: PluginUIWidget, name: String, value: PluginUIJSON? = nil) throws -> (String, String) {
        func interactive(_ model: PluginUIWidget) -> PluginUIWidget? {
            guard model.enabled, model.visibility == "visible" else { return nil }
            if model.id == widget.id { return model }
            for child in model.children { if let found = interactive(child) { return found } }
            return nil
        }
        guard let current = interactive(self.root), current == widget else {
            throw PluginUIFailure.invalidHandle("Custom widget does not belong to this rendered row")
        }
        let callback = name == "longAction" ? widget.longCallback : widget.callback
        guard let callback, !callback.isEmpty, callback != "closed" else {
            throw PluginUIFailure.invalidHandle("Custom event has no page-owned SDK callback ID")
        }
        var event: [String: PluginUIJSON] = ["kind": .string("widget"), "rowId": .string(self.rowId),
            "widgetId": .string(widget.id), "callbackId": .string(callback), "event": .string(name)]
        if name == "change" {
            guard let value else { throw PluginUIFailure.malformed("Custom change requires a value") }
            switch widget.kind {
            case .input:
                guard let text = value.string, text.unicodeScalars.count <= widget.maximumLength else { throw PluginUIFailure.malformed("Custom input exceeds max_length") }
            case .toggle:
                guard value.bool != nil else { throw PluginUIFailure.malformed("Custom toggle requires Bool") }
            case .selector:
                guard let index = value.integer, index >= 0, index < Int64(widget.choices.count) else { throw PluginUIFailure.malformed("Custom selector index is out of range") }
            case .slider:
                guard let number = value.number, let range = widget.range, number.isFinite,
                      number >= range.minimum, number <= range.maximum else { throw PluginUIFailure.malformed("Custom slider value is out of range") }
            default: throw PluginUIFailure.malformed("This Custom widget has no value-change operation")
            }
            event["value"] = value
        } else if name != "action" && name != "longAction" {
            throw PluginUIFailure.malformed("Unknown Custom widget event")
        }
        return (callback, try PluginUIJSON.object(event).encoded())
    }
}
