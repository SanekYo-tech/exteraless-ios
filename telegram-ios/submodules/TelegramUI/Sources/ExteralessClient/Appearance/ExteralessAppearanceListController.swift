import AccountContext
import Display
import ExteralessCore
import Foundation
import TelegramPresentationData
import UIKit

/// Feature-scoped styling. Stock UITableView/ItemList defaults are never mutated.
/// Other Exteraless screens may use this base or call the cell helper explicitly.
class ExteralessAppearanceListController: PluginListController {
    private let appearanceTitleView = ExteralessAppearanceTitleView(frame: .zero)

    override func setSections(_ sections: [PluginListSection]) {
        self.appearanceTitleView.update(title: self.title ?? "", color: self.presentationData.theme.rootController.navigationBar.primaryTextColor)
        if self.navigationItem.titleView !== self.appearanceTitleView { self.navigationItem.titleView = self.appearanceTitleView }
        let policy = ExteralessAppearanceListStyle.policy()
        let sections = sections.map { section -> PluginListSection in
            guard !policy.separateHeaders, let title = section.title, !title.isEmpty else { return section }
            var header = PluginListRow(id: "appearance.header.\(title)", title: title)
            header.style = .accent
            header.enabled = false
            return PluginListSection(footer: section.footer, rows: [header] + section.rows)
        }
        self.tableView.separatorStyle = policy.showsDividers ? .singleLine : .none
        super.setSections(sections)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let row = self.sections[indexPath.section].rows[indexPath.row]
        ExteralessAppearanceListStyle.apply(to: cell, theme: self.presentationData.theme, first: indexPath.row == 0, last: indexPath.row == self.sections[indexPath.section].rows.count - 1, hasDetail: row.detail != nil)
    }
}

enum ExteralessAppearanceListStyle {
    static func policy() -> AppearanceListPolicy {
        let settings = ClientSettings.shared
        return AppearanceListPolicy(radius: settings.integer("appearance.sectionRadius", default: 20), separateHeaders: settings.bool("appearance.separateHeaders", default: true), dividerStyle: settings.integer("appearance.dividerStyle", default: 1), materialRows: settings.bool("appearance.m3ListItems"))
    }

    static func apply(to cell: UITableViewCell, theme: PresentationTheme, first: Bool, last: Bool, hasDetail: Bool) {
        let policy = self.policy()
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = policy.materialRows ? theme.list.itemBlocksBackgroundColor.mixedWith(theme.list.itemAccentColor, alpha: 0.08) : theme.list.itemBlocksBackgroundColor
        background.cornerRadius = policy.segmented ? CGFloat(policy.radius) : 0
        if policy.segmented {
            background.backgroundInsets = NSDirectionalEdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0)
        }
        cell.backgroundConfiguration = background
        cell.backgroundColor = .clear
        cell.clipsToBounds = true
        cell.layer.cornerRadius = CGFloat(policy.radius)
        var corners: CACornerMask = []
        if first || policy.segmented { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if last || policy.segmented { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        cell.layer.maskedCorners = corners
        let identifier = "Exteraless.Appearance.MinimumRowHeight"
        let constraint: NSLayoutConstraint
        if let current = cell.contentView.constraints.first(where: { $0.identifier == identifier }) {
            constraint = current
        } else {
            constraint = cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
            constraint.identifier = identifier
            constraint.priority = .defaultHigh
            constraint.isActive = true
        }
        constraint.constant = CGFloat(policy.minimumRowHeight(hasDetail: hasDetail))
    }
}

enum ExteralessAppearancePersistence {
    private static let queue = DispatchQueue(label: "Exteraless.Appearance.Persistence", qos: .utility)

    static func set(_ value: ClientSettingValue, for key: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try ClientSettings.shared.set(value, for: key)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
