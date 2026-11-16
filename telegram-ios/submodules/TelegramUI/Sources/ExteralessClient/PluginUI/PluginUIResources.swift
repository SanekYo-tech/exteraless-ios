import AppBundle
import Foundation
import ItemListUI
import TelegramPresentationData
import UIKit

@MainActor enum PluginUIResources {
    static func image(_ name: String) throws -> UIImage {
        let reference = try PluginUIImages.reference(name)
        let result = reference.bundle ? UIImage(bundleImageName: reference.name) : UIImage(systemName: reference.name)
        guard let result else { throw PluginUIFailure.resource("Unavailable native image: \(name)") }
        return result
    }

    static func font(_ spec: PluginUIFontSpec?, data: PresentationData, small: Bool = false, semibold: Bool = false) throws -> UIFont {
        guard let spec else { return pluginUIFont(data, style: small ? .footnote : .body, semibold: semibold) }
        let weights: [String: UIFont.Weight] = ["ultraLight": .ultraLight, "thin": .thin, "light": .light,
            "regular": .regular, "medium": .medium, "semibold": .semibold, "bold": .bold, "heavy": .heavy, "black": .black]
        guard let weight = weights[spec.weight] else { throw PluginUIFailure.resource("Unavailable font weight: \(spec.weight)") }
        let baseSize = CGFloat(spec.size ?? Double(data.listsFontSize.itemListBaseFontSize)) * (small ? 13.0 / 17.0 : 1.0)
        let font: UIFont
        if spec.name == "system" { font = UIFont.systemFont(ofSize: baseSize, weight: weight) }
        else if spec.name == "monospace" { font = UIFont.monospacedSystemFont(ofSize: baseSize, weight: weight) }
        else {
            guard let named = UIFont(name: spec.name, size: baseSize) else { throw PluginUIFailure.resource("Unavailable native font: \(spec.name)") }
            font = named
        }
        return UIFontMetrics(forTextStyle: small ? .footnote : .body).scaledFont(for: font)
    }

    static func validate(_ model: PluginUIModel, data: PresentationData) throws {
        if let icon = model.icon { _ = try self.image(icon) }
        for item in model.items { if let icon = item.icon { _ = try self.image(icon) } }
        func visit(_ widget: PluginUIWidget) throws {
            if let icon = widget.icon { _ = try self.image(icon) }
            if let image = widget.image { _ = try self.image(image) }
            _ = try self.font(widget.font, data: data)
            for child in widget.children { try visit(child) }
            for child in widget.subpage ?? [] { try visit(child) }
        }
        for widget in model.widgets + model.rows { try visit(widget) }
    }
}
