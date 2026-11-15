import Foundation

/// Main-thread-confined account attachment for root presentation. Applying the
/// same account again is intentional: readiness can mount a root after every
/// initial settings callback has already run. No timers or retained account.
public final class AppearanceRootApplication<Context: AnyObject> {
    private weak var context: Context?
    private let apply: (Context) -> Void

    public init(apply: @escaping (Context) -> Void) { self.apply = apply }
    public func attach(_ context: Context) { self.context = context }
    public func clear() { self.context = nil }

    @discardableResult
    public func applyIfCurrent(_ context: Context) -> Bool {
        guard self.context === context else { return false }
        self.apply(context)
        return true
    }
}
