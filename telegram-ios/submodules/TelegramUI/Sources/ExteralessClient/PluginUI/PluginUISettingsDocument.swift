import Foundation
import UIKit

/// Extends the existing settings decoder without changing its stable row model
/// or identifier rules. Images stay native-only; the decoded document is Sendable.
struct PluginUISettingsRowIdentity: Hashable, Sendable {
    let path: [String]
    let rowId: String
}

struct PluginUISettingsPageDocument: Sendable {
    let rows: [PluginSetting]
    let icons: [PluginUISettingsRowIdentity: String]

    static func decode(_ json: String) throws -> PluginUISettingsPageDocument {
        let rows = try PluginSettingsDocument.decode(json)
        guard let raw = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw PluginUIFailure.malformed("Expected settings rows")
        }
        var icons: [PluginUISettingsRowIdentity: String] = [:]
        func visit(_ rows: [PluginSetting], raw: [[String: Any]], path: [String]) throws {
            guard rows.count == raw.count else { throw PluginUIFailure.malformed("Settings icon metadata does not match rows") }
            for (row, object) in zip(rows, raw) {
                if let value = object["icon"], !(value is NSNull) {
                    guard let name = value as? String else { throw PluginUIFailure.resource("Setting \(row.identifier) requires a named icon") }
                    _ = try PluginUIImages.reference(name)
                    icons[PluginUISettingsRowIdentity(path: path, rowId: row.identifier)] = name
                }
                if let children = row.subPage {
                    guard let childObjects = object["sub_page"] as? [[String: Any]] else { throw PluginUIFailure.malformed("Invalid settings subpage icon metadata") }
                    try visit(children, raw: childObjects, path: path + [row.identifier])
                }
            }
        }
        try visit(rows, raw: raw, path: [])
        return PluginUISettingsPageDocument(rows: rows, icons: icons)
    }

    func page(_ path: [String]) -> [PluginSetting]? { return PluginSettingsDocument.page(in: self.rows, path: path) }
}

final class PluginUISettingsRowIcon: UIImageView {
    private let originalLeadingMargin: CGFloat

    init(cell: UITableViewCell) {
        self.originalLeadingMargin = cell.contentView.directionalLayoutMargins.leading
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.contentMode = .scaleAspectFit
        self.isAccessibilityElement = false
        cell.contentView.addSubview(self)
        NSLayoutConstraint.activate([
            self.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: self.originalLeadingMargin),
            self.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            self.widthAnchor.constraint(equalToConstant: 24), self.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func apply(image: UIImage?, color: UIColor, to cell: UITableViewCell) {
        let existing = cell.contentView.subviews.compactMap { $0 as? PluginUISettingsRowIcon }.first
        guard image != nil || existing != nil else { return }
        let view = existing ?? PluginUISettingsRowIcon(cell: cell)
        view.image = image
        view.tintColor = color
        view.isHidden = image == nil
        var margins = cell.contentView.directionalLayoutMargins
        margins.leading = view.originalLeadingMargin + (image == nil ? 0 : 36)
        cell.contentView.directionalLayoutMargins = margins
    }
}
