import ComponentFlow
import Display
import Foundation
import UIKit

/// A native-only seam for ChatListUI. The application owns the provider and account lifetime.
@MainActor public protocol ExteralessPillHeader: AnyObject {
    var view: UIView { get }
    var preferredHeight: CGFloat { get }
    var heightUpdated: (() -> Void)? { get set }
    func setVisible(_ visible: Bool)
    func invalidate()
}

public enum ExteralessPillEntry {
    public typealias Factory = @MainActor (AccountContext, @escaping (ViewController) -> Void) -> (any ExteralessPillHeader)?
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var factory: Factory?
    }
    private static let storage = Storage()
    public static func setHeaderFactory(_ factory: Factory?) {
        storage.lock.lock(); storage.factory = factory; storage.lock.unlock()
    }
    public static func makeHeader(context: AccountContext, open: @escaping (ViewController) -> Void) -> (any ExteralessPillHeader)? {
        precondition(Thread.isMainThread)
        storage.lock.lock(); let factory = storage.factory; storage.lock.unlock()
        return MainActor.assumeIsolated { factory?(context, open) }
    }
}

/// Insert as a keyed HeaderPanelContainerComponent.Panel. Its measured height enters the
/// existing navigation/list-inset calculation; the owning controller controls visibility.
public final class ExteralessPillPanelComponent: Component {
    public typealias EnvironmentType = Empty
    private let header: any ExteralessPillHeader
    private let height: CGFloat
    public init(header: any ExteralessPillHeader, height: CGFloat) { self.header = header; self.height = height }
    public static func == (lhs: ExteralessPillPanelComponent, rhs: ExteralessPillPanelComponent) -> Bool {
        lhs.header === rhs.header && lhs.height == rhs.height
    }
    public final class View: UIView {
        fileprivate var header: (any ExteralessPillHeader)?
        override init(frame: CGRect) { super.init(frame: frame) }
        required public init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
    public func makeView() -> View { MainActor.assumeIsolated { View(frame: .zero) } }
    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        MainActor.assumeIsolated {
            if view.header !== self.header {
                view.header?.view.removeFromSuperview()
                view.header = self.header
                view.addSubview(self.header.view)
            }
            let size = CGSize(width: max(0, availableSize.width), height: max(0, self.height))
            transition.setFrame(view: self.header.view, frame: CGRect(origin: .zero, size: size))
            return size
        }
    }
}
