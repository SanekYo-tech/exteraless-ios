import Foundation
import ExteralessCore
import UIKit
import Display
import ComponentFlow
import ComponentDisplayAdapters
import TelegramPresentationData
import AccountContext
import ChatListTitleView
import NavigationBarComponent

/// The chat list's title (`ChatListTitleView`: network status, lock, emoji status) as a row-filling
/// `NavigationBarComponent` title. Its content and hit testing stay in the lane
/// between native navigation actions, including collapsed stories and narrow rows.
final class ChatListTitleComponent: Component {
    typealias EnvironmentType = NavigationBarTitleEnvironment

    let context: AccountContext
    let theme: PresentationTheme
    let strings: PresentationStrings
    let title: NetworkStatusTitle
    let sideContentFraction: CGFloat
    let openStatusSetup: (UIView) -> Void
    let toggleIsLocked: () -> Void

    init(context: AccountContext, theme: PresentationTheme, strings: PresentationStrings, title: NetworkStatusTitle, sideContentFraction: CGFloat, openStatusSetup: @escaping (UIView) -> Void, toggleIsLocked: @escaping () -> Void) {
        self.context = context
        self.theme = theme
        self.strings = strings
        self.title = title
        self.sideContentFraction = sideContentFraction
        self.openStatusSetup = openStatusSetup
        self.toggleIsLocked = toggleIsLocked
    }

    static func ==(lhs: ChatListTitleComponent, rhs: ChatListTitleComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.theme !== rhs.theme {
            return false
        }
        if lhs.strings !== rhs.strings {
            return false
        }
        if lhs.title != rhs.title {
            return false
        }
        if lhs.sideContentFraction != rhs.sideContentFraction {
            return false
        }
        return true
    }

    final class View: UIView {
        private let snow = ExteralessSnowView(settingKey: "appearance.actionBarDecoration")
        private(set) var titleView: ChatListTitleView?
        private var component: ChatListTitleComponent?
        private var titleHitLane = CGRect.zero

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard !self.isHidden, self.alpha > 0.01, self.isUserInteractionEnabled,
                  self.titleHitLane.contains(point), let titleView = self.titleView, !titleView.isHidden else {
                return nil
            }
            return titleView.hitTest(self.convert(point, to: titleView), with: event)
        }

        func update(component: ChatListTitleComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<NavigationBarTitleEnvironment>, transition: ComponentTransition) -> CGSize {
            self.component = component
            if self.snow.superview == nil { self.insertSubview(self.snow, at: 0) }
            self.snow.frame = CGRect(origin: .zero, size: availableSize)
            self.snow.update(color: component.theme.overallDarkAppearance ? UIColor.white.withAlphaComponent(0.55) : component.theme.list.itemAccentColor.withAlphaComponent(0.4), maximumParticles: 8)
            let titleEnvironment = environment[NavigationBarTitleEnvironment.self].value
            let lane = AppearancePresentationPolicy.titleLane(width: Double(availableSize.width), leftButtons: Double(titleEnvironment.leftButtonsExtent), rightButtons: Double(titleEnvironment.rightButtonsExtent))
            let centered = AppearanceControlPolicy.centersHeader(enabled: ClientSettings.shared.bool("appearance.centerActionBarTitle"), scope: ClientSettings.shared.integer("appearance.centerActionBarTitleType", default: 1), isSettings: false)
            self.titleHitLane = CGRect(x: CGFloat(lane.origin), y: 0, width: CGFloat(lane.width), height: availableSize.height)
            let leadingAlignment: NSTextAlignment = self.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left

            var titleTransition = transition
            let titleView: ChatListTitleView
            if let current = self.titleView {
                titleView = current
            } else {
                titleTransition = .immediate
                titleView = ChatListTitleView(context: component.context, theme: component.theme, strings: component.strings, animationCache: component.context.animationCache, animationRenderer: component.context.animationRenderer)
                titleView.manualLayout = true
                self.titleView = titleView
                self.addSubview(titleView)
            }

            titleView.theme = component.theme
            titleView.strings = component.strings
            titleView.setTitle(component.title, animated: false)
            let laneSize = CGSize(width: CGFloat(lane.width), height: availableSize.height)
            let titleContentRect = titleView.updateLayoutInternal(size: laneSize, transition: transition.containedViewLayoutTransition, alignment: centered ? .center : leadingAlignment)

            titleView.openStatusSetup = { [weak self] sourceView in
                guard let self else {
                    return
                }
                self.component?.openStatusSetup(sourceView)
            }
            titleView.toggleIsLocked = { [weak self] in
                guard let self else {
                    return
                }
                self.component?.toggleIsLocked()
            }

            var titleOffset = CGFloat(lane.origin)
            if centered {
                let desired = availableSize.width * 0.5 - titleContentRect.midX
                titleOffset = max(CGFloat(lane.origin) - titleContentRect.minX, min(desired, CGFloat(lane.origin + lane.width) - titleContentRect.maxX))
            }
            titleView.isHidden = lane.width < 44
            titleTransition.setFrame(view: titleView, frame: CGRect(origin: CGPoint(x: titleOffset, y: 0.0), size: laneSize))

            return availableSize
        }
    }

    func makeView() -> View {
        return View(frame: CGRect())
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<NavigationBarTitleEnvironment>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
