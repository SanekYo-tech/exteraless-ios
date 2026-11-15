import ExteralessCore
import SwiftSignalKit

/// Presentation readiness is not authorization. The caller must still finish the
/// consumed opaque grant and let PasscodeUI recheck its lifecycle before unlocking.
public func exteralessAwaitHiddenAccountPresentation(
    identity: PrivacyExtrasAccountIdentity,
    primary: Signal<PrivacyExtrasAccountIdentity?, NoError>,
    foreground: Signal<Bool, NoError>,
    rootReady: Signal<Bool, NoError>
) -> Signal<Bool, NoError> {
    return exteralessAwaitHiddenAccountPresentationImpl(identity: identity, primary: primary,
        foreground: foreground, rootReady: rootReady, timeoutSeconds: 5.0)
}

// The native signal fixture shortens only the clock. Production always uses 5 s.
func exteralessAwaitHiddenAccountPresentationImpl(
    identity: PrivacyExtrasAccountIdentity,
    primary: Signal<PrivacyExtrasAccountIdentity?, NoError>,
    foreground: Signal<Bool, NoError>,
    rootReady: Signal<Bool, NoError>,
    timeoutSeconds: Double
) -> Signal<Bool, NoError> {
    return combineLatest(primary, foreground, rootReady)
    |> map { primary, foreground, ready -> Bool? in
        if !foreground { return false }
        return ready && primary == identity ? true : nil
    }
    |> filter { $0 != nil }
    |> map { $0 == true }
    |> take(1)
    |> timeout(timeoutSeconds, queue: Queue.mainQueue(), alternate: .single(false))
    |> deliverOnMainQueue
}
