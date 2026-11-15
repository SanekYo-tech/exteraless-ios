import Foundation
import ExteralessCore
import Network
import Postbox
import SwiftSignalKit

/// Event-driven default-route observation. No ping loop or persistent background work.
/// The user's enabled/selected proxy remains durable; suspension is only a projection.
public final class ExteralessProxyEnvironment: @unchecked Sendable {
    public static let shared = ExteralessProxyEnvironment()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var current = PrivacyProxyPathState()
    private let value = ValuePromise<PrivacyProxyPathState>(PrivacyProxyPathState(), ignoreRepeated: true)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.current.update(isAvailable: path.status == .satisfied, mobileData: path.usesInterfaceType(.cellular), wifi: path.usesInterfaceType(.wifi))
            let state = self.current
            self.lock.unlock()
            self.value.set(state)
        }
        monitor.start(queue: DispatchQueue(label: "org.exteraless.proxy-path"))
    }

    deinit {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    public var isSuppressed: Bool {
        lock.lock()
        let current = self.current
        lock.unlock()
        return current.suppressesProxy(conditions: PrivacyPolicy.current.proxyDisableConditions)
    }

    // The singleton's route monitor is process-wide, like Android's one registered
    // callback. Each account's ValuePromise/settings subscriptions are cancellable.
    func changes() -> Signal<PrivacyProxyPathState, NoError> { value.get() }
}

func exteralessEffectiveProxySettings(accountManager: AccountManager<TelegramAccountManagerTypes>) -> Signal<ProxyServerSettings?, NoError> {
    return combineLatest(accountManager.sharedData(keys: [SharedDataKeys.proxySettings]), ExteralessProxyEnvironment.shared.changes(), exteralessPrivacySettingsChanges())
    |> map { sharedData, _, _ in
        return sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self)?.effectiveActiveServer
    }
    |> distinctUntilChanged
}
