import UIKit

/// Row focus for an already resolved original settings alias. The model's
/// targetRowId is validated against pagePath before this MainActor helper runs.
/// It never resolves plugin metadata, runs a factory or invokes a row callback.
@MainActor final class PluginUISettingsTargetFocus {
    private var revealedRevision: Int64?

    func reveal(model: PluginUIModel, revision: Int64, pagePath: [String], scrollView: UIScrollView,
                widgets: [PluginUIWidgetView], permitted: Bool) {
        guard permitted, self.revealedRevision != revision, model.kind == .settings,
              pagePath == model.pagePath, let rowId = model.raw["targetRowId"]?.string,
              scrollView.window != nil, scrollView.bounds.height > 0,
              let widget = widgets.first(where: { $0.model.id == rowId }) else { return }
        scrollView.layoutIfNeeded()
        scrollView.scrollRectToVisible(widget.convert(widget.bounds, to: scrollView).insetBy(dx: 0, dy: -12), animated: false)
        self.revealedRevision = revision
        UIAccessibility.post(notification: .layoutChanged, argument: widget)
    }
}
