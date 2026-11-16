import AccountContext
import AsyncDisplayKit
import Display
import ExteralessCore
import Foundation
import ItemListUI
import SwiftSignalKit
import TelegramPresentationData
import UIKit

func clientSettingsText(_ key: String, _ fallback: String) -> String {
    return ExteralessSettingsLocalization.text(key, fallback: fallback)
}

func clientSettingsErrorText(_ error: Error) -> String {
    return (error as? ClientSettingsError)?.errorDescription
        ?? clientSettingsText("Error.Generic", "Unable to update settings. Please try again.")
}

struct ExteralessSettingsSlider {
    let minimum: Double
    let maximum: Double
    let step: Double
    let value: Double
    let commit: (Double) -> Void

    init?(definition: ClientSettingDefinition, value: ClientSettingValue, commit: @escaping (Double) -> Void) {
        guard let minimum = definition.minimum, let upper = definition.maximum, let step = definition.step,
              minimum.isFinite, upper.isFinite, step.isFinite, upper > minimum, step > 0.0 else { return nil }
        let count = floor((upper - minimum) / step + 0.000000001)
        guard count.isFinite, count >= 1.0, count <= 1_000_000 else { return nil }
        switch value {
        case let .integer(value):
            guard let number = Double(exactly: value), abs(minimum) <= 9_007_199_254_740_991,
                  abs(upper) <= 9_007_199_254_740_991 else { return nil }
            self.value = number
        case let .number(value): self.value = value
        default: return nil
        }
        self.minimum = minimum
        self.maximum = min(upper, minimum + count * step)
        self.step = step
        self.commit = commit
    }

    func normalized(_ value: Double) -> Double {
        let value = min(self.maximum, max(self.minimum, value))
        return min(self.maximum, max(self.minimum, self.minimum + ((value - self.minimum) / self.step).rounded() * self.step))
    }

    func fraction(_ value: Double) -> Float {
        return Float((self.normalized(value) - self.minimum) / (self.maximum - self.minimum))
    }

    func value(at fraction: Float) -> Double {
        return self.normalized(self.minimum + Double(fraction) * (self.maximum - self.minimum))
    }

    func label(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 15
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

struct ExteralessSettingsInput {
    enum Kind: Equatable { case text, json, integer, decimal, secret }
    let text: String
    let placeholder: String
    let kind: Kind
    let updated: (String) -> Void
    let submitted: () -> Void

    var multiline: Bool {
        switch self.kind {
        case .text, .json: return true
        default: return false
        }
    }
}

struct ExteralessSettingsRow {
    enum Style { case plain, accent, destructive }
    enum Accessory: Equatable { case none, disclosure, checkmark }
    let id: String
    var title: String
    var detail: String?
    var style: Style = .plain
    var accessory: Accessory = .none
    var enabled = true
    var toggle: (Bool, (Bool) -> Void)?
    var slider: ExteralessSettingsSlider?
    var input: ExteralessSettingsInput?
    var action: (() -> Void)?
    var reset: (() -> Void)?
    var longAction: (() -> Void)?

    init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

struct ExteralessSettingsSection {
    var title: String?
    var footer: String?
    var rows: [ExteralessSettingsRow]

    init(title: String? = nil, footer: String? = nil, rows: [ExteralessSettingsRow]) {
        self.title = title
        self.footer = footer
        self.rows = rows
    }
}

/// Follows the native PluginManager's Display-hosted grouped-list pattern.
/// PresentationData remains the source for Telegram list colors and text sizes.
@MainActor
class ExteralessSettingsListController: ViewController, UITableViewDataSource, UITableViewDelegate {
    let context: AccountContext
    private(set) var presentationData: PresentationData
    let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private(set) var sections: [ExteralessSettingsSection] = []
    private(set) var isScreenVisible = false
    private(set) var isBusy = false
    var errorText: String?
    var allowsRefresh = true
    private var presentationDisposable: Disposable?
    private var operationTask: Task<Void, Never>?
    private var initialLayout = true

    init(context: AccountContext) {
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

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        self.tableView.estimatedRowHeight = 76.0
        self.tableView.sectionHeaderHeight = UITableView.automaticDimension
        self.tableView.estimatedSectionHeaderHeight = 36.0
        self.tableView.sectionFooterHeight = UITableView.automaticDimension
        self.tableView.estimatedSectionFooterHeight = 28.0
        self.tableView.register(ExteralessSettingsCell.self, forCellReuseIdentifier: "setting")
        self.tableView.register(ExteralessSettingsHeader.self, forHeaderFooterViewReuseIdentifier: "settingHeader")
        if self.allowsRefresh {
            let refresh = UIRefreshControl()
            refresh.addTarget(self, action: #selector(self.refreshPressed), for: .valueChanged)
            self.tableView.refreshControl = refresh
        }
        NotificationCenter.default.addObserver(self, selector: #selector(self.contentSizeChanged), name: UIContentSizeCategory.didChangeNotification, object: nil)
        self.updatePresentation()
        self.presentationDisposable = (self.context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            guard let self else { return }
            let changed = self.presentationData.theme !== data.theme || self.presentationData.strings !== data.strings || self.presentationData.listsFontSize != data.listsFontSize
            self.presentationData = data
            if changed { self.updatePresentation() }
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
        if self.initialLayout {
            self.initialLayout = false
            self.tableView.setContentOffset(CGPoint(x: 0.0, y: -insets.top), animated: false)
        }
        if (layout.inputHeight ?? 0.0) > 0.0 { self.revealInput() }
    }

    func render() {}

    func refresh() {
        self.tableView.refreshControl?.endRefreshing()
        self.render()
    }

    func setSections(_ sections: [ExteralessSettingsSection]) {
        let policy = ExteralessAppearanceListStyle.policy()
        let sections = sections.enumerated().map { index, section -> ExteralessSettingsSection in
            guard !policy.separateHeaders, let title = section.title, !title.isEmpty else { return section }
            var header = ExteralessSettingsRow(id: "appearance.header.\(index)", title: title)
            header.style = .accent
            header.enabled = false
            return ExteralessSettingsSection(footer: section.footer, rows: [header] + section.rows)
        }
        self.tableView.separatorStyle = policy.showsDividers ? .singleLine : .none
        let focused = self.tableView.visibleCells.compactMap { cell -> (String, NSRange)? in
            guard let cell = cell as? ExteralessSettingsCell, let selection = cell.inputSelection else { return nil }
            return (cell.rowId, selection)
        }.first
        self.sections = sections
        self.tableView.reloadData()
        if let (id, selection) = focused {
            for (section, group) in sections.enumerated() {
                if let row = group.rows.firstIndex(where: { $0.id == id }) {
                    self.tableView.layoutIfNeeded()
                    (self.tableView.cellForRow(at: IndexPath(row: row, section: section)) as? ExteralessSettingsCell)?.focus(selection)
                }
            }
        }
    }

    func operationSections(storageError: ClientSettingsError? = nil) -> [ExteralessSettingsSection] {
        if self.isBusy {
            return [ExteralessSettingsSection(rows: [ExteralessSettingsRow(id: "operation", title: clientSettingsText("Saving", "Updating settings…"))])]
        }
        if let error = self.errorText ?? storageError?.errorDescription {
            var row = ExteralessSettingsRow(id: "error", title: clientSettingsText("Error.Title", "Settings error"), detail: error)
            row.style = .destructive
            return [ExteralessSettingsSection(rows: [row])]
        }
        return []
    }

    /// Only Sendable data/store work enters the detached task. A popped screen
    /// cannot present a late result; a durable write already underway may finish.
    func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value, completion: @escaping (Value) -> Void) {
        guard !self.isBusy else { return }
        self.isBusy = true
        self.errorText = nil
        self.render()
        self.operationTask = Task { @MainActor [weak self] in
            do {
                let value = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try operation()
                }.value
                guard !Task.isCancelled, let self else { return }
                self.operationTask = nil
                self.isBusy = false
                self.tableView.refreshControl?.endRefreshing()
                completion(value)
                self.render()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.operationTask = nil
                self.isBusy = false
                self.tableView.refreshControl?.endRefreshing()
                self.showError(error)
            }
        }
    }

    func showError(_ error: Error) {
        self.errorText = clientSettingsErrorText(error)
        self.render()
        if self.isScreenVisible {
            self.tableView.setContentOffset(CGPoint(x: 0.0, y: -self.tableView.contentInset.top), animated: false)
            UIAccessibility.post(notification: .announcement, argument: self.errorText)
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

    private func revealInput() {
        self.tableView.layoutIfNeeded()
        for case let cell as ExteralessSettingsCell in self.tableView.visibleCells where cell.inputSelection != nil {
            if let caret = cell.inputCaretRect {
                self.tableView.scrollRectToVisible(self.tableView.convert(caret, from: cell).insetBy(dx: 0.0, dy: -12.0), animated: false)
            }
        }
    }

    @objc private func contentSizeChanged() { self.updatePresentation() }
    @objc private func refreshPressed() {
        if self.isBusy { self.tableView.refreshControl?.endRefreshing() }
        else { self.refresh() }
    }

    func numberOfSections(in tableView: UITableView) -> Int { self.sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { self.sections[section].rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "setting", for: indexPath) as! ExteralessSettingsCell
        cell.configure(self.sections[indexPath.section].rows[indexPath.row], data: self.presentationData)
        cell.inputHeightChanged = { [weak self] in
            guard let self else { return }
            UIView.performWithoutAnimation {
                self.tableView.beginUpdates()
                self.tableView.endUpdates()
            }
            self.revealInput()
        }
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let rows = self.sections[indexPath.section].rows
        ExteralessAppearanceListStyle.apply(to: cell, theme: self.presentationData.theme,
            first: indexPath.row == 0, last: indexPath.row == rows.count - 1,
            hasDetail: rows[indexPath.row].detail != nil)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = self.sections[indexPath.section].rows[indexPath.row]
        if row.enabled { row.action?() }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        return self.header(self.sections[section].title, footer: false)
    }

    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        return self.header(self.sections[section].footer, footer: true)
    }

    private func header(_ text: String?, footer: Bool) -> UIView? {
        guard let text, !text.isEmpty else { return nil }
        let header = self.tableView.dequeueReusableHeaderFooterView(withIdentifier: "settingHeader") as! ExteralessSettingsHeader
        header.configure(text, data: self.presentationData, footer: footer)
        return header
    }
}

private func clientSettingsFont(_ data: PresentationData, small: Bool = false) -> UIFont {
    return Font.regular(max(data.listsFontSize.itemListBaseFontSize * (small ? 13.0 / 17.0 : 1.0),
                            UIFont.preferredFont(forTextStyle: small ? .footnote : .body).pointSize))
}

private final class ExteralessSettingsHeader: UITableViewHeaderFooterView {
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

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ text: String, data: PresentationData, footer: Bool) {
        self.label.text = text
        self.label.font = clientSettingsFont(data, small: true)
        self.label.textColor = footer ? data.theme.list.freeTextColor : data.theme.list.sectionHeaderTextColor
        self.label.accessibilityTraits = footer ? .staticText : .header
        self.contentView.backgroundColor = data.theme.list.blocksBackgroundColor
    }
}

private final class ExteralessSettingsAccessibleSlider: UISlider {
    var adjust: ((Bool) -> Void)?
    override func accessibilityIncrement() { self.adjust?(true) }
    override func accessibilityDecrement() { self.adjust?(false) }
}

private final class ExteralessSettingsCell: UITableViewCell, UITextViewDelegate, UITextFieldDelegate {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let valueLabel = UILabel()
    private let valueSwitch = UISwitch()
    private let arrow = UIImageView()
    private let slider = ExteralessSettingsAccessibleSlider()
    private let textView = UITextView()
    private let textField = UITextField()
    private var row: ExteralessSettingsRow?
    private var longPress: UILongPressGestureRecognizer?
    var inputHeightChanged: (() -> Void)?

    var rowId: String { self.row?.id ?? "" }
    private var input: (UIView & UITextInput)? {
        if self.textView.isFirstResponder { return self.textView }
        if self.textField.isFirstResponder { return self.textField }
        return nil
    }
    var inputSelection: NSRange? {
        guard let input = self.input, let range = input.selectedTextRange else { return nil }
        return NSRange(location: input.offset(from: input.beginningOfDocument, to: range.start), length: input.offset(from: range.start, to: range.end))
    }
    var inputCaretRect: CGRect? {
        guard let input = self.input, let range = input.selectedTextRange else { return nil }
        return self.convert(input.caretRect(for: range.end), from: input)
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        for label in [self.titleLabel, self.detailLabel, self.valueLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.lineBreakMode = .byWordWrapping
        }
        let labels = UIStackView(arrangedSubviews: [self.titleLabel, self.detailLabel])
        labels.axis = .vertical
        labels.spacing = 5.0
        let top = UIStackView(arrangedSubviews: [labels, self.valueSwitch, self.arrow])
        top.alignment = .center
        top.spacing = 12.0
        self.valueSwitch.setContentHuggingPriority(.required, for: .horizontal)
        self.valueSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.arrow.contentMode = .scaleAspectFit
        self.arrow.setContentHuggingPriority(.required, for: .horizontal)
        self.arrow.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [top, self.slider, self.valueLabel, self.textView, self.textField])
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
            guard let self, let row = self.row, row.enabled, let slider = row.slider else { return }
            slider.commit(slider.normalized(slider.value + (increment ? slider.step : -slider.step)))
        }
        self.textView.delegate = self
        self.textView.isScrollEnabled = false
        self.textView.adjustsFontForContentSizeCategory = true
        self.textView.textContainer.lineFragmentPadding = 0.0
        self.textView.textContainerInset = UIEdgeInsets(top: 8.0, left: 0.0, bottom: 8.0, right: 0.0)
        self.textField.delegate = self
        self.textField.adjustsFontForContentSizeCategory = true
        self.textField.addTarget(self, action: #selector(self.fieldChanged), for: .editingChanged)
        self.textView.autocorrectionType = .no
        self.textView.autocapitalizationType = .none
        self.textView.smartQuotesType = .no
        self.textView.smartDashesType = .no
        self.textField.autocorrectionType = .no
        self.textField.autocapitalizationType = .none
        self.textField.smartQuotesType = .no
        self.textField.smartDashesType = .no
        for (view, height) in [(self.textView as UIView, CGFloat(148.0)), (self.textField as UIView, CGFloat(44.0))] {
            let constraint = view.heightAnchor.constraint(greaterThanOrEqualToConstant: height)
            constraint.priority = .defaultHigh
            constraint.isActive = true
        }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:)))
        self.longPress = longPress
        self.addGestureRecognizer(longPress)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        self.row = nil
        self.textField.text = nil
        self.textView.text = nil
        self.inputHeightChanged = nil
    }

    func configure(_ row: ExteralessSettingsRow, data: PresentationData) {
        self.row = row
        let theme = data.theme
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        let selected = UIView()
        selected.backgroundColor = theme.list.itemHighlightedBackgroundColor
        self.selectedBackgroundView = selected
        self.selectionStyle = row.action != nil && row.enabled ? .default : .none
        self.titleLabel.text = row.title
        self.titleLabel.font = clientSettingsFont(data)
        switch row.style {
        case .plain: self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        case .accent: self.titleLabel.textColor = theme.list.itemAccentColor
        case .destructive: self.titleLabel.textColor = theme.list.itemDestructiveColor
        }
        self.titleLabel.alpha = row.enabled ? 1.0 : 0.55
        self.detailLabel.text = row.detail
        self.detailLabel.isHidden = row.detail?.isEmpty != false
        self.detailLabel.font = clientSettingsFont(data, small: true)
        self.detailLabel.textColor = theme.list.itemSecondaryTextColor
        self.valueLabel.font = clientSettingsFont(data, small: true)
        self.valueLabel.textColor = theme.list.itemAccentColor
        self.arrow.isHidden = row.accessory == .none
        self.arrow.image = UIImage(systemName: row.accessory == .checkmark ? "checkmark" : "chevron.forward")
        self.arrow.tintColor = row.accessory == .checkmark ? theme.list.itemAccentColor : theme.list.disclosureArrowColor
        self.valueSwitch.isHidden = row.toggle == nil
        self.valueSwitch.isEnabled = row.enabled
        self.valueSwitch.onTintColor = theme.list.itemSwitchColors.contentColor
        self.valueSwitch.tintColor = theme.list.itemSwitchColors.frameColor
        self.valueSwitch.thumbTintColor = theme.list.itemSwitchColors.handleColor
        self.valueSwitch.setOn(row.toggle?.0 ?? false, animated: false)
        self.slider.isHidden = row.slider == nil
        self.slider.isEnabled = row.enabled
        self.slider.minimumTrackTintColor = theme.list.itemAccentColor
        self.slider.maximumTrackTintColor = theme.list.controlSecondaryColor
        self.valueLabel.isHidden = row.slider == nil
        if let slider = row.slider {
            self.slider.value = slider.fraction(slider.value)
            self.sliderLabel(slider.label(slider.value))
        }
        self.textView.isHidden = row.input?.multiline != true
        self.textField.isHidden = row.input == nil || row.input?.multiline == true
        self.textView.isEditable = row.enabled
        self.textField.isEnabled = row.enabled
        self.textView.font = clientSettingsFont(data)
        self.textField.font = clientSettingsFont(data)
        self.textView.textColor = theme.list.itemPrimaryTextColor
        self.textField.textColor = theme.list.itemPrimaryTextColor
        self.textView.tintColor = theme.list.itemAccentColor
        self.textField.tintColor = theme.list.itemAccentColor
        self.textView.backgroundColor = .clear
        self.textField.backgroundColor = .clear
        self.textView.keyboardAppearance = theme.overallDarkAppearance ? .dark : .light
        self.textField.keyboardAppearance = theme.overallDarkAppearance ? .dark : .light
        if let input = row.input {
            if input.multiline {
                if self.textView.text != input.text { self.textView.text = input.text }
            } else {
                self.textField.isSecureTextEntry = input.kind == .secret
                self.textField.textContentType = input.kind == .secret ? .password : nil
                self.textField.keyboardType = (input.kind == .integer || input.kind == .decimal) ? .numbersAndPunctuation : .default
                self.textField.returnKeyType = .done
                if self.textField.text != input.text { self.textField.text = input.text }
                self.textField.attributedPlaceholder = NSAttributedString(string: input.placeholder, attributes: [.foregroundColor: theme.list.itemPlaceholderTextColor])
            }
        }
        self.longPress?.isEnabled = row.enabled && (row.longAction != nil || row.reset != nil) && row.input == nil
        self.configureAccessibility(row)
    }

    func focus(_ range: NSRange) {
        guard let spec = self.row?.input, self.row?.enabled == true else { return }
        let input: UIView & UITextInput = spec.multiline ? self.textView : self.textField
        input.becomeFirstResponder()
        if let start = input.position(from: input.beginningOfDocument, offset: range.location),
           let end = input.position(from: start, offset: range.length) {
            input.selectedTextRange = input.textRange(from: start, to: end)
        }
    }

    private func configureAccessibility(_ row: ExteralessSettingsRow) {
        let label = [row.title, row.detail].compactMap { $0 }.joined(separator: "\n")
        var actions: [UIAccessibilityCustomAction] = []
        if row.enabled, let menu = row.longAction {
            actions.append(UIAccessibilityCustomAction(name: clientSettingsText("Search.LinkMenu", "Settings link and actions"), actionHandler: { _ in menu(); return true }))
        }
        if row.enabled, let reset = row.reset {
            actions.append(UIAccessibilityCustomAction(name: clientSettingsText("Reset", "Reset to default"), actionHandler: { _ in reset(); return true }))
        }
        if row.enabled, row.slider != nil, let edit = row.action {
            actions.append(UIAccessibilityCustomAction(name: clientSettingsText("EditValue", "Enter a value"), actionHandler: { _ in edit(); return true }))
        }
        let control: UIView?
        if row.toggle != nil { control = self.valueSwitch }
        else if row.slider != nil { control = self.slider }
        else if let input = row.input { control = input.multiline ? self.textView : self.textField }
        else { control = nil }
        self.isAccessibilityElement = control == nil
        if let control {
            self.accessibilityElements = [control]
            control.accessibilityLabel = label
            control.accessibilityIdentifier = row.id
            control.accessibilityCustomActions = actions
        } else {
            self.accessibilityElements = nil
            self.accessibilityLabel = label
            self.accessibilityIdentifier = row.id
            self.accessibilityTraits = row.action == nil ? .staticText : .button
            if row.accessory == .checkmark { self.accessibilityTraits.insert(.selected) }
            if !row.enabled { self.accessibilityTraits.insert(.notEnabled) }
            self.accessibilityCustomActions = actions
        }
    }

    @objc private func switchChanged() {
        guard let row = self.row, row.enabled, let (value, update) = row.toggle else { return }
        let candidate = self.valueSwitch.isOn
        self.valueSwitch.setOn(value, animated: false)
        update(candidate)
    }

    private func sliderLabel(_ label: String) {
        self.valueLabel.text = label
        self.slider.accessibilityValue = label
    }

    @objc private func sliderChanged() {
        guard let slider = self.row?.slider else { return }
        self.sliderLabel(slider.label(slider.value(at: self.slider.value)))
    }

    @objc private func sliderCommitted() {
        guard let row = self.row, row.enabled, let slider = row.slider else { return }
        let candidate = slider.value(at: self.slider.value)
        self.sliderCancelled()
        if candidate != slider.value { slider.commit(candidate) }
    }

    @objc private func sliderCancelled() {
        guard let slider = self.row?.slider else { return }
        self.slider.value = slider.fraction(slider.value)
        self.sliderLabel(slider.label(slider.value))
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began, self.row?.enabled == true { (self.row?.longAction ?? self.row?.reset)?() }
    }

    @objc private func fieldChanged() { self.row?.input?.updated(self.textField.text ?? "") }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { self.row?.input?.submitted(); return false }
    func textViewDidChange(_ textView: UITextView) {
        self.row?.input?.updated(textView.text)
        textView.invalidateIntrinsicContentSize()
        self.inputHeightChanged?()
    }
}
