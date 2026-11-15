import ExteralessCore
import Foundation
import MtProtoKit
import Network

/// Process/app scope, not the currently selected Telegram account. Construction
/// performs no lookup or connection. start() installs policy before account start.
public final class ExteralessNetworkResolverRuntime: @unchecked Sendable {
    public static let shared = ExteralessNetworkResolverRuntime()
    public static let stateDidChange = Notification.Name("ExteralessNetworkResolverStateDidChange")
    public let resolver: NetworkResolver
    private let queue = DispatchQueue(label: "Exteraless.NetworkPolicy", qos: .utility)
    private let transport: NetworkResolverURLSessionTransport
    private let pathMonitor = NWPathMonitor()
    private var observation: ClientSettingsObservation?
    private var started = false
    private var route = NetworkResolverRoute.unknown
    private var rejectedConfiguration: NetworkResolverError?
    private var activeConfiguration: NetworkResolverConfiguration
    private var hasValidConfiguration = false
    private let contextsLock = NSLock()
    private let contexts = NSHashTable<MTContext>.weakObjects()
    private var contextObserver: NSObjectProtocol?

    private init() {
        let initial = try! NetworkResolverConfiguration(mode: .telegram)
        activeConfiguration = initial
        transport = NetworkResolverURLSessionTransport()
        // A compile-time valid native default, without a request or Keychain read.
        resolver = NetworkResolver(configuration: initial, http: transport, system: ExteralessSystemDNS())
    }

    public func start() {
        queue.sync {
            guard !started else { return }
            started = true
            contextObserver = NotificationCenter.default.addObserver(forName: MTAppNetworkResolverDidChange, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.contextsLock.lock(); let contexts = self.contexts.allObjects; self.contextsLock.unlock()
                for context in contexts { context.invalidateTransportSchemesForKnownDatacenterIds() }
            }
            reloadOnQueue(routeChanged: false)
            MTAppNetworkResolver.installResolver({ [resolver] host, _ in
                return MTSignal(generator: { subscriber in
                    let token = resolver.resolve(host: host) { result in
                        switch result {
                        case let .success(addresses): subscriber?.putNext(addresses.map(\.string)); subscriber?.putCompletion()
                        case .failure: subscriber?.putError(nil)
                        }
                    }
                    return MTBlockDisposable(block: { token.cancel() })
                })
            }, cacheLifetime: { [resolver] host, _ in resolver.remainingTTL(host: host) }, preference: preferenceOnQueue())
            observation = ClientSettings.shared.observe { [weak self] keys in
                guard keys.isEmpty || !NewNetworkFeatures.keys.isDisjoint(with: keys), let self else { return }
                self.queue.async { self.reloadOnQueue(routeChanged: false) }
            }
            pathMonitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                // Capabilities come from NWPath, not interface-name heuristics.
                self.route = .init(supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6)
                self.reloadOnQueue(routeChanged: true)
            }
            pathMonitor.start(queue: queue)
        }
    }

    public func configurationError() -> NetworkResolverError? { queue.sync { rejectedConfiguration } }

    public func register(context: MTContext) {
        contextsLock.lock(); contexts.add(context); contextsLock.unlock()
    }

    public func clearCachedState() {
        queue.async {
            self.resolver.invalidate()
            MTAppNetworkResolver.invalidateCaches()
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
    }

    private func preferenceOnQueue() -> Int {
        return route.prefersIPv6(userPreference: activeConfiguration.preferIPv6) ? 1 : 0
    }

    private func reloadOnQueue(routeChanged: Bool) {
        do {
            let configuration = try NetworkResolverConfiguration.current()
            rejectedConfiguration = nil
            activeConfiguration = configuration
            hasValidConfiguration = true
            resolver.update(configuration: configuration, route: route)
            if routeChanged { resolver.invalidate() }
            MTAppNetworkResolver.updatePreference(route.prefersIPv6(userPreference: configuration.preferIPv6) ? 1 : 0)
        } catch {
            // Retain the last valid resolver; the settings status explicitly says
            // the submitted custom configuration was rejected. Never log its URL.
            rejectedConfiguration = error as? NetworkResolverError ?? .invalidConfiguration
            if !hasValidConfiguration {
                resolver.rejectConfiguration(rejectedConfiguration ?? .invalidConfiguration)
                MTAppNetworkResolver.invalidateCaches()
            } else if routeChanged {
                resolver.update(configuration: activeConfiguration, route: route)
                resolver.invalidate()
                MTAppNetworkResolver.updatePreference(preferenceOnQueue())
            }
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    /// Wrap only MTProto TCP. WEB proxy carriers retain their original factory;
    /// they must never be substituted with a direct socket or a localhost listener.
    @available(iOS 15.0, macOS 14.0, *)
    public func makeConnection(delegate: MTTcpConnectionInterfaceDelegate, queue: DispatchQueue) -> MTTcpConnectionInterface {
        return ExteralessResolverTcpConnectionInterface(delegate: delegate, delegateQueue: queue, resolver: resolver)
    }
}
