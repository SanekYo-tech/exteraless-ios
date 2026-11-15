import Foundation
import UIKit
import AsyncDisplayKit
import Display
import TelegramPresentationData
import ImageBlur

public enum ListSectionHeaderActionType {
    case generic
    case destructive
}

public final class ListSectionHeaderNode: ASDisplayNode {
    private let backgroundLayer: SimpleLayer
    private let label: ImmediateTextNode
    private let labelBackgroundView: UIImageView
    private var actionButtonLabel: ImmediateTextNode?
    private var actionButton: HighlightableButtonNode?
    private var theme: PresentationTheme
    private var textFont: UIFont?
    
    private var validLayout: (size: CGSize, leftInset: CGFloat, rightInset: CGFloat)?
    
    public var title: String? {
        didSet {
            self.updateText(font: Font.regular(13.0))
            
            if let (size, leftInset, rightInset) = self.validLayout {
                self.updateLayout(size: size, leftInset: leftInset, rightInset: rightInset)
            }
        }
    }
    
    public var actionType: ListSectionHeaderActionType = .generic {
        didSet {
            self.updateAction()
        }
    }
    
    public var action: String? {
        didSet {
            self.updateAction()
        }
    }
    
    private func updateAction() {
        if (self.action != nil) != (self.actionButton != nil) {
            if let _ = self.action {
                let actionButtonLabel = ImmediateTextNode()
                actionButtonLabel.displaysAsynchronously = false
                self.addSubnode(actionButtonLabel)
                self.actionButtonLabel = actionButtonLabel
                let actionButton = HighlightableButtonNode()
                self.addSubnode(actionButton)
                self.actionButton = actionButton
                actionButton.addTarget(self, action: #selector(self.actionButtonPressed), forControlEvents: .touchUpInside)
            } else {
                if let actionButtonLabel = self.actionButtonLabel {
                    self.actionButtonLabel = nil
                    actionButtonLabel.removeFromSupernode()
                }
                if let actionButton = self.actionButton {
                    self.actionButton = nil
                    actionButton.removeFromSupernode()
                }
            }
        }
        if let action = self.action {
            self.actionButton?.accessibilityLabel = action
            self.actionButton?.accessibilityTraits = [.button]
        }
        self.updateText(font: Font.regular(13.0))
        
        if let (size, leftInset, rightInset) = self.validLayout {
            self.updateLayout(size: size, leftInset: leftInset, rightInset: rightInset)
        }
    }
    
    public var activateAction: ((ASDisplayNode) -> Void)?
    
    public init(theme: PresentationTheme) {
        self.theme = theme
        
        self.backgroundLayer = SimpleLayer()
        
        self.label = ImmediateTextNode()
        self.label.isUserInteractionEnabled = false
        self.label.isAccessibilityElement = true
        self.label.displaysAsynchronously = false
        
        self.labelBackgroundView = UIImageView()
        
        super.init()
        
        self.layer.addSublayer(self.backgroundLayer)
        
        //self.view.addSubview(self.labelBackgroundView)
        self.addSubnode(self.label)
        
        //self.backgroundLayer.backgroundColor = theme.chatList.sectionHeaderFillColor.cgColor
    }
    
    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let actionButton = self.actionButton {
            if actionButton.frame.contains(point) {
                return actionButton.view
            }
        }
        
        return super.hitTest(point, with: event)
    }
    
    private func updateText(font: UIFont) {
        self.textFont = font
        self.label.attributedText = NSAttributedString(string: self.title ?? "", font: font, textColor: self.theme.chatList.sectionHeaderTextColor)
        self.label.accessibilityLabel = self.title
        self.updateActionTitle(font: font)
    }

    private func updateActionTitle(font: UIFont) {
        guard let action = self.action else {
            return
        }
        let actionColor: UIColor
        switch self.actionType {
            case .generic:
                actionColor = self.theme.chatList.sectionHeaderTextColor
            case .destructive:
                actionColor = self.theme.list.itemDestructiveColor
        }
        let attributedText = NSMutableAttributedString(string: action, font: font, textColor: actionColor)
        if let range = attributedText.string.range(of: "<"), let arrowImage = UIImage(bundleImageName: "Item List/HeaderContextDisclosureArrow") {
            attributedText.addAttribute(.attachment, value: arrowImage, range: NSRange(range, in: attributedText.string))
            attributedText.addAttribute(.baselineOffset, value: 2.0, range: NSRange(range, in: attributedText.string))
        }
        if let range = attributedText.string.range(of: ">"), let arrowImage = UIImage(bundleImageName: "Item List/InlineTextRightArrow") {
            attributedText.addAttribute(.attachment, value: arrowImage, range: NSRange(range, in: attributedText.string))
            attributedText.addAttribute(.baselineOffset, value: 1.0, range: NSRange(range, in: attributedText.string))
        }
        self.actionButtonLabel?.attributedText = attributedText
    }
    
    public func updateTheme(theme: PresentationTheme) {
        let font = Font.regular(13.0)
        if self.theme !== theme || self.textFont !== font {
            self.theme = theme
                        
            //self.backgroundLayer.backgroundColor = theme.chatList.sectionHeaderFillColor.cgColor
            
            self.updateText(font: font)
            
            if let (size, leftInset, rightInset) = self.validLayout {
                self.updateLayout(size: size, leftInset: leftInset, rightInset: rightInset)
            }
        }
    }
    
    public func updateLayout(size: CGSize, leftInset: CGFloat, rightInset: CGFloat, showBackground: Bool = true) {
        self.validLayout = (size, leftInset, rightInset)
        // A layout can arrive with the same theme after a font-family change.
        // Font's family-keyed cache keeps this lookup cheap while old layouts
        // retain their original immutable UIFont/CTLine instances.
        let font = Font.regular(13.0)
        if self.textFont !== font {
            self.updateText(font: font)
        }
        let labelSize = self.label.updateLayout(CGSize(width: max(0.0, size.width - leftInset - rightInset - 18.0), height: size.height))
        let labelFrame = CGRect(origin: CGPoint(x: leftInset + 16.0, y: 6.0 + UIScreenPixel), size: CGSize(width: labelSize.width, height: labelSize.height))
        self.label.frame = labelFrame
        
        let labelBackgroundSize: CGFloat = labelSize.height
        let labelBackgroundInnerInset: CGFloat = 2.0
        let labelBackgroundInset: CGFloat = 10.0 + labelBackgroundInnerInset
        if self.labelBackgroundView.image?.size.width != labelBackgroundSize + labelBackgroundInset * 2.0 {
            self.labelBackgroundView.image = blurredImage(generateImage(CGSize(width: labelBackgroundSize + labelBackgroundInset * 2.0, height: labelBackgroundSize + labelBackgroundInset * 2.0), rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: CGRect(origin: CGPoint(x: labelBackgroundInset - labelBackgroundInnerInset, y: labelBackgroundInset - labelBackgroundInnerInset), size: CGSize(width: labelBackgroundSize + labelBackgroundInnerInset * 2.0, height: labelBackgroundSize + labelBackgroundInnerInset * 2.0)))
            })!, radius: 17, iterations: 3)?.stretchableImage(withLeftCapWidth: Int(labelBackgroundInset + labelBackgroundSize * 0.5), topCapHeight: Int(labelBackgroundInset + labelBackgroundSize * 0.5)).withRenderingMode(.alwaysTemplate)
        }
        self.labelBackgroundView.tintColor = self.theme.list.plainBackgroundColor.withAlphaComponent(self.theme.overallDarkAppearance ? 0.5 : 0.7)
        
        self.labelBackgroundView.frame = labelFrame.insetBy(dx: -labelBackgroundInset - 4.0, dy: -labelBackgroundInset)
        
        if let actionButton = self.actionButton, let actionButtonLabel = self.actionButtonLabel {
            let buttonSize = actionButtonLabel.updateLayout(CGSize(width: size.width, height: size.height))
            actionButtonLabel.frame = CGRect(origin: CGPoint(x: size.width - rightInset - 16.0 - buttonSize.width, y: 6.0 + UIScreenPixel), size: buttonSize)
            actionButton.frame = CGRect(origin: CGPoint(x: size.width - rightInset - 16.0 - buttonSize.width, y: 6.0 + UIScreenPixel), size: buttonSize)
        }
        
        self.backgroundLayer.isHidden = !showBackground
        self.backgroundLayer.frame = CGRect(origin: CGPoint(x: 0.0, y: -UIScreenPixel), size: CGSize(width: size.width, height: size.height + UIScreenPixel))
    }
    
    @objc private func actionButtonPressed() {
        if let actionButton = self.actionButton {
            self.activateAction?(actionButton)
        }
    }
}
