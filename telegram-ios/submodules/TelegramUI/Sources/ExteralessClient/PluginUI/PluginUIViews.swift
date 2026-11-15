import Display
import Foundation
import TelegramPresentationData
import UIKit

func pluginUIFont(_ data: PresentationData, style: UIFont.TextStyle = .body, semibold: Bool = false) -> UIFont {
    let ratio: CGFloat = style == .footnote ? 13.0 / 17.0 : 1.0
    let size = max(data.listsFontSize.itemListBaseFontSize * ratio, UIFont.preferredFont(forTextStyle: style).pointSize)
    return semibold ? Font.semibold(size) : Font.regular(size)
}

@MainActor func pluginUIIcon(_ name: String?, style: String? = nil) throws -> UIImage {
    if let name { return try PluginUIResources.image(name) }
    let symbol: String
    switch style {
    case "error": symbol = "exclamationmark.circle"
    case "success": symbol = "checkmark.circle"
    case "copy": symbol = "doc.on.doc"
    default: symbol = "info.circle"
    }
    return try PluginUIResources.image("sf:" + symbol)
}

final class PluginUIPassthroughView: UIView {
    var passthrough = false
    weak var content: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.passthrough, let content = self.content, !content.frame.contains(point) { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Multiline, 44-point-minimum native action row. Layout remains readable at
/// accessibility sizes instead of truncating UIKit's single-line button title.
final class PluginUIActionControl: UIControl {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let imageView = UIImageView()
    private let markerView = UIImageView()
    private let normalColor: UIColor
    private let highlightedColor: UIColor
    var action: (() -> Void)?

    init(text: String, detail: String? = nil, image: UIImage? = nil, checked: Bool = false,
         destructive: Bool = false, accent: Bool = true, enabled: Bool = true, color: UInt32? = nil, font: UIFont? = nil, data: PresentationData) {
        self.normalColor = data.theme.actionSheet.opaqueItemBackgroundColor
        self.highlightedColor = data.theme.list.itemHighlightedBackgroundColor
        super.init(frame: .zero)
        self.titleLabel.text = text
        self.titleLabel.numberOfLines = 0
        self.titleLabel.font = font ?? pluginUIFont(data)
        self.titleLabel.textColor = destructive ? data.theme.list.itemDestructiveColor : (accent ? data.theme.list.itemAccentColor : data.theme.list.itemPrimaryTextColor)
        if let color {
            self.titleLabel.textColor = UIColor(red: CGFloat((color >> 16) & 255) / 255.0,
                green: CGFloat((color >> 8) & 255) / 255.0, blue: CGFloat(color & 255) / 255.0,
                alpha: CGFloat((color >> 24) & 255) / 255.0)
        }
        self.detailLabel.text = detail
        self.detailLabel.numberOfLines = 0
        self.detailLabel.font = pluginUIFont(data, style: .footnote)
        self.detailLabel.textColor = data.theme.list.itemSecondaryTextColor
        self.detailLabel.isHidden = detail?.isEmpty != false
        self.titleLabel.adjustsFontForContentSizeCategory = true
        self.detailLabel.adjustsFontForContentSizeCategory = true
        self.imageView.image = image
        self.imageView.isHidden = image == nil
        self.imageView.tintColor = self.titleLabel.textColor
        self.imageView.contentMode = .scaleAspectFit
        self.markerView.image = UIImage(systemName: "checkmark")
        self.markerView.isHidden = !checked
        self.markerView.tintColor = data.theme.list.itemAccentColor
        self.markerView.contentMode = .scaleAspectFit
        let labels = UIStackView(arrangedSubviews: [self.titleLabel, self.detailLabel])
        labels.axis = .vertical
        labels.spacing = 4.0
        let row = UIStackView(arrangedSubviews: [self.imageView, labels, self.markerView])
        row.spacing = 12.0
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(row)
        let imageWidth = self.imageView.widthAnchor.constraint(equalToConstant: 24.0)
        let markerWidth = self.markerView.widthAnchor.constraint(equalToConstant: 22.0)
        imageWidth.priority = .defaultHigh
        markerWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            self.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0),
            row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12.0),
            row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12.0),
            row.topAnchor.constraint(equalTo: self.topAnchor, constant: 12.0),
            row.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -12.0),
            imageWidth,
            self.imageView.heightAnchor.constraint(equalToConstant: 24.0),
            markerWidth,
            self.markerView.heightAnchor.constraint(equalToConstant: 22.0)
        ])
        self.layer.cornerRadius = 10.0
        self.isEnabled = enabled
        self.alpha = enabled ? 1.0 : 0.5
        self.backgroundColor = self.normalColor
        self.isAccessibilityElement = true
        self.accessibilityLabel = [text, detail].compactMap { $0 }.joined(separator: ". ")
        self.accessibilityTraits = .button
        if checked { self.accessibilityTraits.insert(.selected) }
        if !enabled { self.accessibilityTraits.insert(.notEnabled) }
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { self.backgroundColor = self.isHighlighted ? self.highlightedColor : self.normalColor }
    }

    @objc private func pressed() { if self.isEnabled { self.action?() } }
}

private final class PluginUIValueSlider: UISlider {
    var adjust: ((Bool) -> Void)?
    override func accessibilityIncrement() { self.adjust?(true) }
    override func accessibilityDecrement() { self.adjust?(false) }
}

/// Each widget is UIKit, not an Android object surrogate. The controller owns
/// its frame/constraints and supplies a scope-checked event sink.
final class PluginUIWidgetView: UIView, UITextFieldDelegate, UITextViewDelegate {
    let model: PluginUIWidget
    private let stack = UIStackView()
    private var field: UITextField?
    private var editor: UITextView?
    private var toggle: UISwitch?
    private var slider: PluginUIValueSlider?
    private var valueLabel: UILabel?
    private var placeholderLabel: UILabel?
    private var childStack: UIStackView?
    private var childWidgets: [PluginUIWidgetContainer] = []
    private var groupConstraints: [NSLayoutConstraint] = []
    private var insetConstraints: [NSLayoutConstraint] = []
    private var localValue: PluginUIJSON
    private let change: (PluginUIWidget, PluginUIJSON) -> Bool
    private let select: (PluginUIWidget, UIView) -> Void
    private let activated: (PluginUIWidget, Bool) -> Void
    private let layoutChanged: () -> Void

    var value: PluginUIJSON { return self.localValue }
    var inputIsFirstResponder: Bool { return self.field?.isFirstResponder == true || self.editor?.isFirstResponder == true }
    var inputSelection: NSRange? {
        if let editor = self.editor, editor.isFirstResponder { return editor.selectedRange }
        if let field = self.field, field.isFirstResponder, let range = field.selectedTextRange {
            return NSRange(location: field.offset(from: field.beginningOfDocument, to: range.start), length: field.offset(from: range.start, to: range.end))
        }
        return nil
    }

    init(model: PluginUIWidget, data: PresentationData, value: PluginUIJSON? = nil, values: [String: PluginUIJSON] = [:],
         change: @escaping (PluginUIWidget, PluginUIJSON) -> Bool,
         select: @escaping (PluginUIWidget, UIView) -> Void,
         activated: @escaping (PluginUIWidget, Bool) -> Void,
         layoutChanged: @escaping () -> Void) throws {
        let bodyFont = try PluginUIResources.font(model.font, data: data, semibold: model.kind == .header)
        let smallFont = try PluginUIResources.font(model.font, data: data, small: true)
        let rowIcon: UIImage?
        if let icon = model.icon { rowIcon = try PluginUIResources.image(icon) } else { rowIcon = nil }
        self.model = model
        self.localValue = values[model.key] ?? value ?? model.value
        self.change = change
        self.select = select
        self.activated = activated
        self.layoutChanged = layoutChanged
        super.init(frame: .zero)
        self.backgroundColor = data.theme.actionSheet.opaqueItemBackgroundColor
        self.layer.cornerRadius = 10.0
        self.stack.axis = .vertical
        self.stack.spacing = 8.0
        self.stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(self.stack)
        self.insetConstraints = [
            self.stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: CGFloat(model.padding.left)),
            self.stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -CGFloat(model.padding.right)),
            self.stack.topAnchor.constraint(equalTo: self.topAnchor, constant: CGFloat(model.padding.top)),
            self.stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -CGFloat(model.padding.bottom))
        ]
        NSLayoutConstraint.activate(self.insetConstraints)
        func label(_ text: String, small: Bool = false) -> UILabel {
            let label = UILabel()
            label.numberOfLines = 0
            label.text = text
            label.font = small ? smallFont : bodyFont
            label.adjustsFontForContentSizeCategory = true
            label.textColor = small ? data.theme.list.itemSecondaryTextColor : (model.destructive ? data.theme.list.itemDestructiveColor : (model.accent ? data.theme.list.itemAccentColor : data.theme.list.itemPrimaryTextColor))
            return label
        }
        let titleText = model.text.isEmpty && (model.kind == .text || model.kind == .header) ? model.hint : model.text
        let title = label(titleText)
        title.isHidden = titleText.isEmpty
        if model.kind == .header { title.accessibilityTraits = .header }
        if let rowIcon {
            let image = UIImageView(image: rowIcon)
            image.contentMode = .scaleAspectFit
            image.tintColor = data.theme.list.itemAccentColor
            let header = UIStackView(arrangedSubviews: [image, title])
            header.spacing = 12
            header.alignment = .center
            image.widthAnchor.constraint(equalToConstant: 24).isActive = true
            image.heightAnchor.constraint(equalToConstant: 24).isActive = true
            self.stack.addArrangedSubview(header)
        } else { self.stack.addArrangedSubview(title) }
        if let subtext = model.subtext, !subtext.isEmpty { self.stack.addArrangedSubview(label(subtext, small: true)) }
        self.isHidden = model.visibility == "gone"
        self.alpha = model.visibility == "invisible" ? 0.0 : (model.enabled ? 1.0 : 0.5)
        self.isUserInteractionEnabled = model.enabled && model.visibility == "visible"
        self.accessibilityElementsHidden = model.visibility != "visible"
        switch model.kind {
        case .text, .header, .image:
            if model.kind == .image, let name = model.image {
                let image = UIImageView(image: try PluginUIResources.image(name))
                image.contentMode = model.imageMode == "fill" ? .scaleAspectFill : (model.imageMode == "center" ? .center : .scaleAspectFit)
                image.clipsToBounds = true
                image.tintColor = data.theme.list.itemAccentColor
                image.isAccessibilityElement = !titleText.isEmpty
                image.accessibilityLabel = titleText
                let height = image.heightAnchor.constraint(equalToConstant: 64)
                height.priority = .defaultLow
                height.isActive = true
                self.stack.addArrangedSubview(image)
            }
            if model.callback != nil || model.subpage != nil {
                self.isAccessibilityElement = true
                self.accessibilityLabel = [titleText, model.subtext].compactMap { $0 }.joined(separator: ". ")
                self.accessibilityTraits = .button
                self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapped)))
                self.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0).isActive = true
            }
        case .divider:
            let separator = UIView()
            separator.backgroundColor = data.theme.list.itemBlocksSeparatorColor
            separator.heightAnchor.constraint(equalToConstant: 1.0 / max(1.0, self.traitCollection.displayScale)).isActive = true
            self.stack.addArrangedSubview(separator)
        case .input:
            if model.multiline {
                let editor = UITextView()
                self.editor = editor
                editor.delegate = self
                editor.text = self.localValue.string ?? ""
                editor.font = bodyFont
                editor.adjustsFontForContentSizeCategory = true
                editor.textColor = data.theme.list.itemPrimaryTextColor
                editor.backgroundColor = .clear
                editor.tintColor = data.theme.list.itemAccentColor
                editor.isEditable = model.enabled
                editor.isScrollEnabled = true
                editor.keyboardAppearance = data.theme.overallDarkAppearance ? .dark : .light
                editor.accessibilityLabel = model.text
                editor.accessibilityHint = model.hint
                let height = editor.heightAnchor.constraint(equalToConstant: max(100.0, bodyFont.lineHeight * 4.0))
                height.priority = .defaultHigh
                height.isActive = true
                self.stack.addArrangedSubview(editor)
                let placeholder = label(model.hint)
                placeholder.textColor = data.theme.list.itemPlaceholderTextColor
                placeholder.isUserInteractionEnabled = false
                placeholder.isAccessibilityElement = false
                placeholder.translatesAutoresizingMaskIntoConstraints = false
                editor.addSubview(placeholder)
                NSLayoutConstraint.activate([
                    placeholder.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 5.0),
                    placeholder.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -5.0),
                    placeholder.topAnchor.constraint(equalTo: editor.topAnchor, constant: 8.0)
                ])
                placeholder.isHidden = !editor.text.isEmpty
                self.placeholderLabel = placeholder
            } else {
                let field = UITextField()
                self.field = field
                field.delegate = self
                field.text = self.localValue.string ?? ""
                field.placeholder = model.hint
                field.font = bodyFont
                field.adjustsFontForContentSizeCategory = true
                field.textColor = data.theme.list.itemPrimaryTextColor
                field.tintColor = data.theme.list.itemAccentColor
                field.keyboardAppearance = data.theme.overallDarkAppearance ? .dark : .light
                field.isSecureTextEntry = model.secure
                field.isEnabled = model.enabled
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.returnKeyType = .done
                field.accessibilityLabel = model.text.isEmpty ? model.hint : model.text
                field.heightAnchor.constraint(greaterThanOrEqualToConstant: max(44.0, bodyFont.lineHeight + 16.0)).isActive = true
                field.addTarget(self, action: #selector(self.fieldChanged), for: .editingChanged)
                self.stack.addArrangedSubview(field)
            }
        case .toggle:
            let toggle = UISwitch()
            self.toggle = toggle
            toggle.isEnabled = model.enabled
            toggle.isOn = self.localValue.bool ?? false
            toggle.onTintColor = data.theme.list.itemSwitchColors.contentColor
            toggle.thumbTintColor = data.theme.list.itemSwitchColors.handleColor
            toggle.accessibilityLabel = [model.text, model.subtext].compactMap { $0 }.joined(separator: ". ")
            toggle.addTarget(self, action: #selector(self.toggleChanged), for: .valueChanged)
            let holder = UIStackView(arrangedSubviews: [toggle, UIView()])
            holder.alignment = .center
            holder.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0).isActive = true
            self.stack.addArrangedSubview(holder)
        case .slider:
            if let range = model.range {
                let slider = PluginUIValueSlider()
                self.slider = slider
                slider.minimumValue = 0
                slider.maximumValue = 1
                slider.value = Float((range.normalize(self.localValue.number ?? range.minimum) - range.minimum) / (range.maximum - range.minimum))
                slider.isEnabled = model.enabled
                slider.minimumTrackTintColor = data.theme.list.itemAccentColor
                slider.maximumTrackTintColor = data.theme.list.controlSecondaryColor
                slider.accessibilityLabel = model.text
                slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44.0).isActive = true
                slider.addTarget(self, action: #selector(self.sliderMoved), for: .valueChanged)
                slider.addTarget(self, action: #selector(self.sliderCommitted), for: [.touchUpInside, .touchUpOutside])
                slider.addTarget(self, action: #selector(self.sliderCancelled), for: .touchCancel)
                slider.adjust = { [weak self, weak slider] increase in
                    guard let self, let slider else { return }
                    let value = range.normalize((self.localValue.number ?? range.minimum) + (increase ? range.step : -range.step))
                    if self.accept(.number(value)) {
                        slider.value = Float((value - range.minimum) / (range.maximum - range.minimum))
                        self.updateSliderLabel(value: value)
                    }
                }
                self.stack.addArrangedSubview(slider)
                let valueLabel = label("", small: true)
                self.valueLabel = valueLabel
                self.stack.addArrangedSubview(valueLabel)
                self.updateSliderLabel(value: self.localValue.number)
            }
        case .selector:
            let index = Int(self.localValue.integer ?? 0)
            let choice = model.choices.indices.contains(index) ? model.choices[index] : ""
            let control = PluginUIActionControl(text: choice, image: UIImage(systemName: "chevron.up.chevron.down"), enabled: model.enabled, font: bodyFont, data: data)
            control.action = { [weak self, weak control] in
                guard let self, let control else { return }
                self.select(model, control)
            }
            self.stack.addArrangedSubview(control)
        case .column, .row:
            let children = UIStackView()
            children.axis = .vertical
            children.spacing = CGFloat(model.spacing)
            self.childStack = children
            for child in model.children {
                let view = try PluginUIWidgetView(model: child, data: data, values: values, change: change, select: select, activated: activated, layoutChanged: layoutChanged)
                let container = PluginUIWidgetContainer(widget: view)
                self.childWidgets.append(container)
                children.addArrangedSubview(container)
            }
            self.stack.addArrangedSubview(children)
        }
        if model.longCallback != nil {
            self.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(self.longPressed(_:))))
            self.accessibilityCustomActions = [UIAccessibilityCustomAction(name: pluginText("Setting.LongPress", "Long press action"), actionHandler: { [weak self] _ in
                guard let self, self.model.enabled else { return false }
                self.activated(self.model, true)
                return true
            })]
        }
        if !model.enabled { self.accessibilityTraits.insert(.notEnabled) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The controller chooses the available width before its fitting pass. Rows
    /// become vertical on narrow phones/accessibility sizes, without mutating the
    /// widget's own frame or waiting for a second, visibly different layout.
    func constrain(to width: CGFloat, height: CGFloat? = nil) {
        let padding = self.model.padding.fitting(width: Double(width))
        self.insetConstraints[0].constant = CGFloat(padding.left)
        self.insetConstraints[1].constant = -CGFloat(padding.right)
        guard let children = self.childStack else { return }
        let available = max(0, width - CGFloat(padding.left + padding.right))
        let visible = self.childWidgets.filter { !$0.isHidden }
        let count = max(1, visible.count)
        let minimumWidth = visible.reduce(CGFloat(0)) { $0 + CGFloat($1.widget.model.layout.minimumColumnWidth()) } + CGFloat(count - 1) * CGFloat(self.model.spacing)
        let horizontal = self.model.kind == .row && !self.traitCollection.preferredContentSizeCategory.isAccessibilityCategory && available >= minimumWidth
        children.axis = horizontal ? .horizontal : .vertical
        children.distribution = .fill
        NSLayoutConstraint.deactivate(self.groupConstraints)
        self.groupConstraints.removeAll()
        let weighted = visible.filter { $0.widget.model.layout.weight > 0 }
        if horizontal {
            let space = max(0, available - CGFloat(count - 1) * CGFloat(self.model.spacing))
            let fixed = weighted.isEmpty ? 0 : visible.filter { $0.widget.model.layout.weight == 0 }.reduce(CGFloat(0)) { $0 + CGFloat($1.widget.model.layout.minimumColumnWidth()) }
            let totalWeight = weighted.reduce(0.0) { $0 + $1.widget.model.layout.weight }
            for child in visible {
                let layout = child.widget.model.layout
                let share: CGFloat
                if weighted.isEmpty { share = space / CGFloat(count) }
                else if layout.weight > 0 { share = max(0, space - fixed) * CGFloat(layout.weight / totalWeight) }
                else { share = CGFloat(layout.minimumColumnWidth()) }
                let constraint = child.widthAnchor.constraint(equalToConstant: share)
                constraint.priority = .defaultHigh
                self.groupConstraints.append(constraint)
                child.constrain(to: share, height: height)
            }
        } else {
            for child in visible { child.constrain(to: available, height: height) }
            if let first = weighted.first {
                for child in weighted.dropFirst() {
                    let constraint = child.heightAnchor.constraint(equalTo: first.heightAnchor, multiplier: CGFloat(child.widget.model.layout.weight / first.widget.model.layout.weight))
                    constraint.priority = .defaultHigh
                    self.groupConstraints.append(constraint)
                }
            }
        }
        NSLayoutConstraint.activate(self.groupConstraints)
    }

    func naturalWidth(maximum: CGFloat) -> CGFloat {
        return min(maximum, max(1, self.stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width + CGFloat(self.model.padding.left + self.model.padding.right)))
    }

    func focusInput(selection: NSRange?) {
        if let field = self.field {
            field.becomeFirstResponder()
            if let selection, let start = field.position(from: field.beginningOfDocument, offset: selection.location),
               let end = field.position(from: start, offset: selection.length) { field.selectedTextRange = field.textRange(from: start, to: end) }
        } else if let editor = self.editor {
            editor.becomeFirstResponder()
            if let selection {
                let location = min(selection.location, editor.text.utf16.count)
                editor.selectedRange = NSRange(location: location, length: min(selection.length, editor.text.utf16.count - location))
            }
        }
    }

    private func accept(_ value: PluginUIJSON) -> Bool {
        guard self.model.enabled, self.change(self.model, value) else { return false }
        self.localValue = value
        return true
    }

    @objc private func tapped() { if self.model.enabled { self.activated(self.model, false) } }
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began && self.model.enabled { self.activated(self.model, true) }
    }
    @objc private func fieldChanged() {
        guard let field = self.field, field.markedTextRange == nil else { return }
        let text = String((field.text ?? "").unicodeScalars.prefix(self.model.maximumLength))
        if self.accept(.string(text)) { field.text = text } else { field.text = self.localValue.string }
    }
    @objc private func toggleChanged() {
        guard let toggle = self.toggle else { return }
        if !self.accept(.bool(toggle.isOn)) { toggle.setOn(self.localValue.bool ?? false, animated: false) }
    }
    private var sliderValue: Double? {
        guard let range = self.model.range, let slider = self.slider else { return nil }
        return range.normalize(range.minimum + Double(slider.value) * (range.maximum - range.minimum))
    }
    @objc private func sliderMoved() { self.updateSliderLabel() }
    @objc private func sliderCommitted() {
        guard let value = self.sliderValue else { return }
        if !self.accept(.number(value)) { self.sliderCancelled() }
        self.updateSliderLabel(value: self.localValue.number)
    }
    @objc private func sliderCancelled() {
        guard let slider = self.slider, let range = self.model.range else { return }
        slider.value = Float((range.normalize(self.localValue.number ?? range.minimum) - range.minimum) / (range.maximum - range.minimum))
        self.updateSliderLabel(value: self.localValue.number)
    }
    private func updateSliderLabel(value: Double? = nil) {
        guard let value = value ?? self.sliderValue else { return }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 12
        let text = formatter.string(from: NSNumber(value: value)) ?? String(value)
        self.valueLabel?.text = text
        self.slider?.accessibilityValue = text
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let swiftRange = Range(range, in: textField.text ?? "") else { return false }
        if textField.markedTextRange != nil { return true }
        let updated = (textField.text ?? "").replacingCharacters(in: swiftRange, with: string)
        return updated.unicodeScalars.count <= self.model.maximumLength || updated.count < (textField.text ?? "").count
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }
    func textFieldDidBeginEditing(_ textField: UITextField) { self.layoutChanged() }
    func textViewDidBeginEditing(_ textView: UITextView) { self.layoutChanged() }
    func textViewDidChange(_ textView: UITextView) {
        self.placeholderLabel?.isHidden = !textView.text.isEmpty
        guard textView.markedTextRange == nil else { return }
        let text = String(textView.text.unicodeScalars.prefix(self.model.maximumLength))
        if !self.accept(.string(text)) { textView.text = self.localValue.string ?? "" }
        else if text != textView.text { textView.text = text }
        self.layoutChanged()
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let swiftRange = Range(range, in: textView.text) else { return false }
        if textView.markedTextRange != nil { return true }
        let updated = textView.text.replacingCharacters(in: swiftRange, with: text)
        return updated.unicodeScalars.count <= self.model.maximumLength || updated.count < textView.text.count
    }
}
