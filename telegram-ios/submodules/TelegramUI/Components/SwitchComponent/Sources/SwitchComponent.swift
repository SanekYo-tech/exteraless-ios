import Foundation
import ExteralessCore
import UIKit
import Display
import AsyncDisplayKit
import ComponentFlow
import TelegramPresentationData

public final class SwitchComponent: Component {
    public typealias EnvironmentType = Empty
    
    let tintColor: UIColor?
    let value: Bool
    let valueUpdated: (Bool) -> Void
    private let accessibilityLabel: String?
    private let appearanceStyle: Int
    
    public init(
        tintColor: UIColor? = nil,
        value: Bool,
        accessibilityLabel: String? = nil,
        appearanceSettings: ClientSettings = .shared,
        valueUpdated: @escaping (Bool) -> Void
    ) {
        self.tintColor = tintColor
        self.value = value
        self.valueUpdated = valueUpdated
        self.accessibilityLabel = accessibilityLabel
        self.appearanceStyle = appearanceSettings.integer("appearance.switchStyle", default: 2)
    }
    
    public static func ==(lhs: SwitchComponent, rhs: SwitchComponent) -> Bool {
        if lhs.appearanceStyle != rhs.appearanceStyle { return false }
        if lhs.accessibilityLabel != rhs.accessibilityLabel { return false }
        if lhs.tintColor != rhs.tintColor {
            return false
        }
        if lhs.value != rhs.value {
            return false
        }
        return true
    }
    
    public final class View: UIView {
        private let switchView: UISwitch
        private let appearanceSwitch = AppearanceSwitchControl(frame: .zero)
    
        private var component: SwitchComponent?
        
        override init(frame: CGRect) {
            self.switchView = UISwitch()
            
            super.init(frame: frame)
            
            self.addSubview(self.switchView)
            self.addSubview(self.appearanceSwitch)
            self.appearanceSwitch.addTarget(self, action: #selector(self.valueChanged(_:)), for: .valueChanged)
            
            self.switchView.addTarget(self, action: #selector(self.valueChanged(_:)), for: .valueChanged)
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        @objc func valueChanged(_ sender: Any) {
            self.component?.valueUpdated(self.appearanceSwitch.isHidden ? self.switchView.isOn : self.appearanceSwitch.isOn)
        }
        
        func update(component: SwitchComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            if self.component?.appearanceStyle != component.appearanceStyle {
                self.switchView.cancelTracking(with: nil)
                self.appearanceSwitch.cancelTracking(with: nil)
            }
            self.component = component
            self.switchView.accessibilityLabel = component.accessibilityLabel
            self.appearanceSwitch.accessibilityLabel = component.accessibilityLabel
            let material = component.appearanceStyle != 0
            self.switchView.isHidden = material
            self.appearanceSwitch.isHidden = !material
            if material {
                self.appearanceSwitch.update(value: component.value, style: component.appearanceStyle == 3 ? 3 : 2, tint: component.tintColor, animated: !transition.animation.isImmediate)
                let size = self.appearanceSwitch.intrinsicContentSize
                self.appearanceSwitch.frame = CGRect(origin: .zero, size: size)
                self.appearanceSwitch.setNeedsLayout()
                return size
            }
          
            self.switchView.tintColor = component.tintColor
            self.switchView.setOn(component.value, animated: !transition.animation.isImmediate)
            
            self.switchView.sizeToFit()
            self.switchView.frame = CGRect(origin: .zero, size: self.switchView.frame.size)
                        
            return self.switchView.frame.size
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }
    
    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
