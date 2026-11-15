import Display
import Foundation
import ObjectiveC
import SwiftSignalKit

private final class ExteralessAppearanceAssociationToken: @unchecked Sendable {}
private let groupSelectionAssociationToken = ExteralessAppearanceAssociationToken()

private final class ExteralessGroupSelectionLifetime: NSObject {
    let disposable: Disposable

    init(_ disposable: Disposable) {
        self.disposable = disposable
        super.init()
    }

    deinit { self.disposable.dispose() }
}

/// The native selector's Back gesture does not emit .none. Bind its result
/// subscription to the controller lifetime rather than a standalone signal.
func exteralessRetainGroupSelection(_ disposable: Disposable, controller: ViewController) {
    precondition(Thread.isMainThread)
    let key = UnsafeRawPointer(Unmanaged.passUnretained(groupSelectionAssociationToken).toOpaque())
    objc_setAssociatedObject(controller, key, ExteralessGroupSelectionLifetime(disposable), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}
