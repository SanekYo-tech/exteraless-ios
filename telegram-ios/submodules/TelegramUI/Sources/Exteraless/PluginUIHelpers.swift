import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData
import UIKit

func pluginText(_ key: String, _ fallback: String) -> String {
    return ExteralessPluginLocalization.text(key, fallback: fallback)
}

func pluginErrorText(_ error: Error) -> String {
    return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}

struct PluginUIError: LocalizedError {
    let message: String

    var errorDescription: String? {
        return self.message
    }
}

struct PluginListSlider {
    let range: PluginSliderRange
    let value: Double
    let commit: (Double) -> Void
}

struct PluginListInput {
    let text: String
    let placeholder: String
    let multiline: Bool
    let maxLength: Int?
    let updated: (String) -> Void
    let submitted: () -> Void
}

struct PluginListRow {
    enum Style {
        case plain
        case accent
        case destructive
        case error
    }

    enum Accessory {
        case none
        case disclosure
        case checkmark
    }

    let id: String
    var title: String
    var detail: String?
    var style: Style = .plain
    var accessory: Accessory = .none
    var enabled = true
    var loading = false
    var toggle: (value: Bool, updated: (Bool) -> Void)?
    var slider: PluginListSlider?
    var input: PluginListInput?
    var action: (() -> Void)?
    var longAction: (() -> Void)?
    var remove: (() -> Void)?

    init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

struct PluginListSection {
    var title: String?
    var footer: String?
    var rows: [PluginListRow]

    init(title: String? = nil, footer: String? = nil, rows: [PluginListRow]) {
        self.title = title
        self.footer = footer
        self.rows = rows
    }
}

/// Native grouped lists hosted in Telegram's navigation/layout system. All state,
/// UIKit effects and completions are confined to the main thread.
class PluginListController: ViewController, UITableViewDataSource, UITableViewDelegate {
    let context: AccountContext
    private(set) var presentationData: PresentationData
    let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private(set) var sections: [PluginListSection] = []
    private(set) var isScreenVisible = false
    private(set) var busyText: String?
    var errorText: String?
    var allowsRefresh = true

    private var presentationDisposable: Disposable?
    private var operationTask: Task<Void, Never>?
    private var hasInitialLayout = false

    var isBusy: Bool {
        return self.operationTask != nil || self.busyText != nil
    }

    init(context: AccountContext) {
        precondition(Thread.isMainThread)
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self._hasGlassStyle = true
        self.statusBar.statusBarStyle = self.presentationData.theme.rootController.statusBarStyle.style
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        self.scrollToTop = { [weak self] in
            guard let self else { return }
            self.tableView.setContentOffset(CGPoint(x: 0.0, y: -self.tableView.contentInset.top), animated: true)
        }
    }

    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.operationTask?.cancel()
        self.presentationDisposable?.dispose()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.view.addSubview(self.tableView)
        self.tableView.dataSource = self
        self.tableView.delegate = self
        self.tableView.contentInsetAdjustmentBehavior = .never
        self.tableView.keyboardDismissMode = .interactive
        self.tableView.rowHeight = UITableView.automaticDimension
        self.tableView.estimatedRowHeight = 74.0
        self.tableView.sectionHeaderHeight = UITableView.automaticDimension
        self.tableView.estimatedSectionHeaderHeight = 36.0
        self.tableView.sectionFooterHeight = UITableView.automaticDimension
        self.tableView.estimatedSectionFooterHeight = 28.0
        self.tableView.register(PluginListCell.self, forCellReuseIdentifier: "pluginRow")
        self.tableView.register(PluginListHeader.self, forHeaderFooterViewReuseIdentifier: "pluginHeader")
        if self.allowsRefresh {
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(self, action: #selector(self.refreshPressed), for: .valueChanged)
            self.tableView.refreshControl = refreshControl
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.contentSizeChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)
        self.updatePresentation()
        self.presentationDisposable = (self.context.sharedContext.presentationData
        |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            let changed = self.presentationData.theme !== data.theme || self.presentationData.strings !== data.strings || self.presentationData.listsFontSize != data.listsFontSize
            self.presentationData = data
            if changed {
                self.updatePresentation()
            }
        })
        self.displayNodeDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        self.isScreenVisible = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.isScreenVisible = false
        super.viewWillDisappear(animated)
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let sides = layout.sideInsets(forBandFrom: 0.0, to: layout.size.height)
        transition.updateFrame(view: self.tableView, frame: CGRect(x: sides.left, y: 0.0, width: max(0.0, layout.size.width - sides.left - sides.right), height: layout.size.height))
        var insets = layout.insets(options: [.input])
        insets.top = max(insets.top, self.navigationLayout(layout: layout).navigationFrame.maxY)
        insets.left = 0.0
        insets.right = 0.0
        self.tableView.contentInset = insets
        self.tableView.scrollIndicatorInsets = insets
        if !self.hasInitialLayout {
            self.hasInitialLayout = true
            self.tableView.setContentOffset(CGPoint(x: 0.0, y: -insets.top), animated: false)
        }
        if (layout.inputHeight ?? 0.0) > 0.0 {
            self.tableView.layoutIfNeeded()
            for case let cell as PluginListCell in self.tableView.visibleCells where cell.inputSelection != nil {
                if let caret = cell.inputCaretRect {
                    self.tableView.scrollRectToVisible(self.tableView.convert(caret, from: cell).insetBy(dx: 0.0, dy: -12.0), animated: false)
                }
            }
        }
    }

    func render() {
    }

    func refresh() {
        self.tableView.refreshControl?.endRefreshing()
        self.render()
    }

    func setSections(_ sections: [PluginListSection]) {
        precondition(Thread.isMainThread)
        let focused = self.tableView.visibleCells.compactMap { cell -> (String, NSRange)? in
            guard let cell = cell as? PluginListCell, let selection = cell.inputSelection else { return nil }
            return (cell.rowId, selection)
        }.first
        self.sections = sections
        self.tableView.reloadData()
        if let (id, selection) = focused, let indexPath = self.indexPath(for: id) {
            self.tableView.layoutIfNeeded()
            (self.tableView.cellForRow(at: indexPath) as? PluginListCell)?.focusInput(selection: selection)
        }
    }

    func operationSections() -> [PluginListSection] {
        if let busyText = self.busyText {
            var row = PluginListRow(id: "operation", title: busyText)
            row.loading = true
            return [PluginListSection(rows: [row])]
        } else if let errorText = self.errorText {
            var row = PluginListRow(id: "operation-error", title: pluginText("Error.Title", "Operation failed"), detail: errorText)
            row.style = .error
            row.action = { UIPasteboard.general.string = errorText }
            return [PluginListSection(footer: pluginText("Error.CopyHint", "Tap to copy the error."), rows: [row])]
        }
        return []
    }

    /// The async closure owns only host/data work. A dismissed controller is not
    /// kept alive by the task, and late results cannot present UI on another screen.
    func perform<Value>(title: String, operation: @escaping () async throws -> Value, completion: @escaping (Value) -> Void, failed: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        guard !self.isBusy else { return }
        self.busyText = title
        self.errorText = nil
        self.render()
        self.operationTask = Task { @MainActor [weak self] in
            do {
                let value = try await operation()
                guard !Task.isCancelled, let self else { return }
                self.operationTask = nil
                self.busyText = nil
                self.tableView.refreshControl?.endRefreshing()
                completion(value)
                self.render()
                self.revealOperationError()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.operationTask = nil
                self.busyText = nil
                self.errorText = pluginErrorText(error)
                self.tableView.refreshControl?.endRefreshing()
                failed?()
                self.render()
                self.revealOperationError()
            }
        }
    }

    private func revealOperationError() {
        if let error = self.errorText, self.isScreenVisible {
            self.tableView.setContentOffset(CGPoint(x: 0.0, y: -self.tableView.contentInset.top), animated: false)
            UIAccessibility.post(notification: .announcement, argument: error)
        }
    }

    private func updatePresentation() {
        let theme = self.presentationData.theme
        self.overrideUserInterfaceStyle = theme.overallDarkAppearance ? .dark : .light
        self.displayNode.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView.backgroundColor = theme.list.blocksBackgroundColor
        self.tableView.separatorColor = theme.list.itemBlocksSeparatorColor
        self.tableView.tintColor = theme.list.itemAccentColor
        self.tableView.indicatorStyle = theme.overallDarkAppearance ? .white : .black
        self.tableView.refreshControl?.tintColor = theme.list.itemAccentColor
        self.statusBar.statusBarStyle = theme.rootController.statusBarStyle.style
        self.navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: self.presentationData), transition: .immediate)
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: self.presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
        self.render()
    }

    @objc private func contentSizeChanged() {
        self.updatePresentation()
    }

    @objc private func refreshPressed() {
        if self.isBusy {
            self.tableView.refreshControl?.endRefreshing()
        } else {
            self.refresh()
        }
    }

    private func indexPath(for id: String) -> IndexPath? {
        for (sectionIndex, section) in self.sections.enumerated() {
            if let index = section.rows.firstIndex(where: { $0.id == id }) {
                return IndexPath(row: index, section: sectionIndex)
            }
        }
        return nil
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return self.sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "pluginRow", for: indexPath) as! PluginListCell
        cell.configure(self.sections[indexPath.section].rows[indexPath.row], presentationData: self.presentationData)
        cell.inputHeightChanged = { [weak self, weak cell] in
            guard let self, let cell else { return }
            UIView.performWithoutAnimation {
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
            }
            if let caret = cell.inputCaretRect {
                self.tableView.scrollRectToVisible(self.tableView.convert(caret, from: cell).insetBy(dx: 0.0, dy: -12.0), animated: false)
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = self.sections[indexPath.section].rows[indexPath.row]
        if row.enabled {
            row.action?()
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let row = self.sections[indexPath.section].rows[indexPath.row]
        guard row.enabled, let remove = row.remove else { return nil }
        let action = UIContextualAction(style: .destructive, title: self.presentationData.strings.Common_Delete) { _, _, done in
            done(false)
            remove()
        }
        action.backgroundColor = self.presentationData.theme.list.itemDestructiveColor
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        return self.header(text: self.sections[section].title, isFooter: false)
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return self.header(text: self.sections[section].footer, isFooter: true)
    }

    private func header(text: String?, isFooter: Bool) -> UIView? {
        guard let text, !text.isEmpty else { return nil }
        let view = self.tableView.dequeueReusableHeaderFooterView(withIdentifier: "pluginHeader") as! PluginListHeader
        view.configure(text: text, presentationData: self.presentationData, isFooter: isFooter)
        return view
    }
}

private func pluginFont(_ data: PresentationData, small: Bool = false) -> UIFont {
    // Telegram's chosen list size and system accessibility size are both respected,
    // without applying the system multiplier twice to an already enlarged list size.
    let telegramSize = data.listsFontSize.itemListBaseFontSize * (small ? 13.0 / 17.0 : 1.0)
    let systemSize = UIFont.preferredFont(forTextStyle: small ? .footnote : .body).pointSize
    return Font.regular(max(telegramSize, systemSize))
}

private final class PluginListHeader: UITableViewHeaderFooterView {
    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        self.label.numberOfLines = 0
        self.label.adjustsFontForContentSizeCategory = true
        self.label.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(self.label)
        NSLayoutConstraint.activate([
            self.label.leadingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.leadingAnchor),
            self.label.trailingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.trailingAnchor),
            self.label.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 10.0),
            self.label.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -8.0)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, presentationData: PresentationData, isFooter: Bool) {
        self.label.text = text
        self.label.font = pluginFont(presentationData, small: true)
        self.label.textColor = isFooter ? presentationData.theme.list.freeTextColor : presentationData.theme.list.sectionHeaderTextColor
        self.label.accessibilityTraits = isFooter ? .staticText : .header
        self.contentView.backgroundColor = presentationData.theme.list.blocksBackgroundColor
    }
}

private final class PluginSteppedSlider: UISlider {
    var adjust: ((Bool) -> Void)?

    override func accessibilityIncrement() {
        self.adjust?(true)
    }

    override func accessibilityDecrement() {
        self.adjust?(false)
    }
}

private final class PluginListCell: UITableViewCell, UITextViewDelegate {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let valueSwitch = UISwitch()
    private let arrowView = UIImageView()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let slider = PluginSteppedSlider()
    private let valueLabel = UILabel()
    private let inputViewNode = UITextView()
    private let placeholderLabel = UILabel()
    private var row: PluginListRow?
    private var inputMinimumHeight: NSLayoutConstraint?
    private var longPressGesture: UILongPressGestureRecognizer?
    var inputHeightChanged: (() -> Void)?

    var rowId: String { return self.row?.id ?? "" }
    var inputSelection: NSRange? { return self.inputViewNode.isFirstResponder ? self.inputViewNode.selectedRange : nil }
    var inputCaretRect: CGRect? {
        guard let selection = self.inputViewNode.selectedTextRange else { return nil }
        return self.convert(self.inputViewNode.caretRect(for: selection.end), from: self.inputViewNode)
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.titleLabel.numberOfLines = 0
        self.detailLabel.numberOfLines = 0
        self.valueLabel.numberOfLines = 0
        self.titleLabel.lineBreakMode = .byWordWrapping
        self.detailLabel.lineBreakMode = .byWordWrapping
        self.valueLabel.textAlignment = .natural
        for label in [self.titleLabel, self.detailLabel, self.valueLabel, self.placeholderLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        let labels = UIStackView(arrangedSubviews: [self.titleLabel, self.detailLabel])
        labels.axis = .vertical
        labels.spacing = 5.0
        let top = UIStackView(arrangedSubviews: [labels, self.valueSwitch, self.activity, self.arrowView])
        top.alignment = .center
        top.spacing = 12.0
        self.valueSwitch.setContentHuggingPriority(.required, for: .horizontal)
        self.valueSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.arrowView.contentMode = .scaleAspectFit
        self.arrowView.setContentHuggingPriority(.required, for: .horizontal)
        self.arrowView.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [top, self.slider, self.valueLabel, self.inputViewNode])
        stack.axis = .vertical
        stack.spacing = 8.0
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12.0),
            stack.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -12.0)
        ])
        self.valueSwitch.addTarget(self, action: #selector(self.switchChanged), for: .valueChanged)
        self.slider.minimumValue = 0.0
        self.slider.maximumValue = 1.0
        self.slider.addTarget(self, action: #selector(self.sliderChanged), for: .valueChanged)
        self.slider.addTarget(self, action: #selector(self.sliderCommitted), for: [.touchUpInside, .touchUpOutside])
        self.slider.addTarget(self, action: #selector(self.sliderCancelled), for: .touchCancel)
        self.slider.adjust = { [weak self] increment in
            guard let self, let row = self.row, row.enabled, let spec = row.slider else { return }
            let value = spec.range.normalize(spec.value + (increment ? spec.range.step : -spec.range.step))
            self.slider.value = spec.range.fraction(value)
            self.sliderChanged()
            spec.commit(value)
        }
        self.inputViewNode.delegate = self
        self.inputViewNode.isScrollEnabled = false
        self.inputViewNode.adjustsFontForContentSizeCategory = true
        self.inputViewNode.autocapitalizationType = .none
        self.inputViewNode.autocorrectionType = .no
        self.inputViewNode.smartQuotesType = .no
        self.inputViewNode.smartDashesType = .no
        self.inputViewNode.textContainer.lineFragmentPadding = 0.0
        self.inputViewNode.textContainerInset = UIEdgeInsets(top: 8.0, left: 0.0, bottom: 8.0, right: 0.0)
        self.placeholderLabel.numberOfLines = 0
        self.placeholderLabel.isUserInteractionEnabled = false
        self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        self.inputViewNode.addSubview(self.placeholderLabel)
        NSLayoutConstraint.activate([
            self.placeholderLabel.leadingAnchor.constraint(equalTo: self.inputViewNode.leadingAnchor),
            self.placeholderLabel.trailingAnchor.constraint(equalTo: self.inputViewNode.trailingAnchor),
            self.placeholderLabel.topAnchor.constraint(equalTo: self.inputViewNode.topAnchor, constant: 8.0)
        ])
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:)))
        self.longPressGesture = longPressGesture
        self.addGestureRecognizer(longPressGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ row: PluginListRow, presentationData: PresentationData) {
        self.row = row
        self.longPressGesture?.isEnabled = row.longAction != nil && row.enabled
        let theme = presentationData.theme
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        let highlightedView = UIView()
        highlightedView.backgroundColor = theme.list.itemHighlightedBackgroundColor
        self.selectedBackgroundView = highlightedView
        self.selectionStyle = row.action != nil && row.enabled ? .default : .none
        self.titleLabel.text = row.title
        self.titleLabel.font = pluginFont(presentationData)
        switch row.style {
        case .plain:
            self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        case .accent:
            self.titleLabel.textColor = theme.list.itemAccentColor
        case .destructive, .error:
            self.titleLabel.textColor = theme.list.itemDestructiveColor
        }
        self.detailLabel.text = row.detail
        self.detailLabel.isHidden = row.detail?.isEmpty != false
        self.detailLabel.font = pluginFont(presentationData, small: true)
        self.detailLabel.textColor = theme.list.itemSecondaryTextColor
        self.valueLabel.font = pluginFont(presentationData, small: true)
        self.valueLabel.textColor = theme.list.itemAccentColor
        self.titleLabel.alpha = row.enabled ? 1.0 : 0.55
        self.arrowView.tintColor = theme.list.disclosureArrowColor
        switch row.accessory {
        case .none:
            self.arrowView.isHidden = true
        case .disclosure:
            self.arrowView.isHidden = false
            self.arrowView.image = UIImage(systemName: "chevron.forward") ?? UIImage(systemName: "chevron.right")
        case .checkmark:
            self.arrowView.isHidden = false
            self.arrowView.tintColor = theme.list.itemAccentColor
            self.arrowView.image = UIImage(systemName: "checkmark")
        }
        self.activity.color = theme.list.itemAccentColor
        self.activity.isHidden = !row.loading
        if row.loading { self.activity.startAnimating() } else { self.activity.stopAnimating() }
        self.valueSwitch.isHidden = row.toggle == nil
        self.valueSwitch.isEnabled = row.enabled
        self.valueSwitch.onTintColor = theme.list.itemSwitchColors.contentColor
        self.valueSwitch.tintColor = theme.list.itemSwitchColors.frameColor
        self.valueSwitch.thumbTintColor = theme.list.itemSwitchColors.handleColor
        self.valueSwitch.setOn(row.toggle?.value ?? false, animated: false)
        self.slider.isHidden = row.slider == nil
        self.valueLabel.isHidden = row.slider == nil
        self.slider.isEnabled = row.enabled
        self.slider.minimumTrackTintColor = theme.list.itemAccentColor
        self.slider.maximumTrackTintColor = theme.list.controlSecondaryColor
        if let spec = row.slider {
            self.slider.value = spec.range.fraction(spec.value)
            self.updateSliderLabel(spec.range.label(spec.value))
        }
        self.inputViewNode.isHidden = row.input == nil
        self.inputViewNode.isEditable = row.enabled
        self.inputViewNode.font = pluginFont(presentationData)
        self.inputViewNode.keyboardAppearance = theme.overallDarkAppearance ? .dark : .light
        self.inputViewNode.textColor = theme.list.itemPrimaryTextColor
        self.inputViewNode.tintColor = theme.list.itemAccentColor
        self.inputViewNode.backgroundColor = .clear
        self.inputMinimumHeight?.isActive = false
        self.inputMinimumHeight = nil
        if let input = row.input {
            if self.inputViewNode.text != input.text { self.inputViewNode.text = input.text }
            self.inputViewNode.returnKeyType = input.multiline ? .default : .done
            self.placeholderLabel.text = input.placeholder
            self.placeholderLabel.font = self.inputViewNode.font
            self.placeholderLabel.textColor = theme.list.itemPlaceholderTextColor
            self.placeholderLabel.isHidden = !input.text.isEmpty
            let constraint = self.inputViewNode.heightAnchor.constraint(greaterThanOrEqualToConstant: input.multiline ? 148.0 : 44.0)
            constraint.priority = .defaultHigh
            constraint.isActive = true
            self.inputMinimumHeight = constraint
        }
        self.configureAccessibility(row)
    }

    func focusInput(selection: NSRange) {
        guard self.row?.input != nil, self.row?.enabled == true else { return }
        self.inputViewNode.becomeFirstResponder()
        self.inputViewNode.selectedRange = selection
    }

    private func configureAccessibility(_ row: PluginListRow) {
        let label = [row.title, row.detail].compactMap { $0 }.joined(separator: "\n")
        var actions: [UIAccessibilityCustomAction] = []
        if let action = row.action, row.toggle != nil {
            actions.append(UIAccessibilityCustomAction(name: pluginText("Plugin.Details", "Plugin details"), actionHandler: { _ in action(); return true }))
        }
        if let action = row.longAction {
            actions.append(UIAccessibilityCustomAction(name: pluginText("Setting.LongPress", "Long press action"), actionHandler: { _ in action(); return true }))
        }
        if let action = row.remove {
            actions.append(UIAccessibilityCustomAction(name: pluginText("Plugin.Remove", "Delete plugin"), actionHandler: { _ in action(); return true }))
        }
        if row.toggle != nil {
            self.isAccessibilityElement = false
            self.accessibilityElements = [self.valueSwitch]
            self.valueSwitch.accessibilityLabel = label
            self.valueSwitch.accessibilityCustomActions = row.enabled ? actions : []
        } else if row.slider != nil {
            self.isAccessibilityElement = false
            self.accessibilityElements = [self.slider]
            self.slider.accessibilityLabel = label
            self.slider.accessibilityCustomActions = row.enabled ? actions : []
        } else if row.input != nil {
            self.isAccessibilityElement = false
            self.accessibilityElements = [self.inputViewNode]
            self.inputViewNode.accessibilityLabel = label
            self.inputViewNode.accessibilityHint = row.input?.placeholder
        } else {
            self.accessibilityElements = nil
            self.isAccessibilityElement = true
            self.accessibilityLabel = label
            self.accessibilityTraits = row.action == nil ? .staticText : .button
            if !row.enabled { self.accessibilityTraits.insert(.notEnabled) }
            self.accessibilityCustomActions = row.enabled ? actions : []
        }
    }

    @objc private func switchChanged() {
        guard let row = self.row, row.enabled, let toggle = row.toggle else { return }
        let requestedValue = self.valueSwitch.isOn
        // Until the host returns, the switch continues to show its confirmed flag.
        self.valueSwitch.setOn(toggle.value, animated: false)
        toggle.updated(requestedValue)
    }

    @objc private func sliderChanged() {
        guard let spec = self.row?.slider else { return }
        self.updateSliderLabel(spec.range.label(spec.range.value(at: self.slider.value)))
    }

    private func updateSliderLabel(_ value: String) {
        self.valueLabel.text = value
        self.slider.accessibilityValue = value
    }

    @objc private func sliderCommitted() {
        guard let row = self.row, row.enabled, let spec = row.slider else { return }
        let value = spec.range.value(at: self.slider.value)
        self.slider.value = spec.range.fraction(value)
        if value != spec.range.normalize(spec.value) { spec.commit(value) }
    }

    @objc private func sliderCancelled() {
        guard let spec = self.row?.slider else { return }
        self.slider.value = spec.range.fraction(spec.value)
        self.updateSliderLabel(spec.range.label(spec.value))
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began, let row = self.row, row.enabled {
            row.longAction?()
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        self.placeholderLabel.isHidden = !textView.text.isEmpty
        self.row?.input?.updated(textView.text)
        textView.invalidateIntrinsicContentSize()
        self.inputHeightChanged?()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let input = self.row?.input else { return false }
        if text == "\n" && !input.multiline {
            input.submitted()
            return false
        }
        if let limit = input.maxLength, let swiftRange = Range(range, in: textView.text) {
            let candidate = textView.text.replacingCharacters(in: swiftRange, with: text)
            return candidate.unicodeScalars.count <= limit || candidate.unicodeScalars.count < textView.text.unicodeScalars.count
        }
        return true
    }
}
