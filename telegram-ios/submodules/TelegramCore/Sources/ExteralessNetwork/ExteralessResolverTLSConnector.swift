import ExteralessCore
import Foundation
import MtProtoKit
import Network
import Security

public final class ExteralessTLSConnectToken: @unchecked Sendable {
    private let token: NetworkResolverCancellation
    fileprivate init(_ token: NetworkResolverCancellation) { self.token = token }
    public func cancel() { token.cancel() }
}

/// Rust's HTTPS / WSS stream host uses this native resolver + dialer. The original
/// hostname stays the TLS server name even when the TCP endpoint is an IP. TLS
/// retains Network.framework's normal chain and hostname validation.
@available(iOS 15.0, macOS 14.0, *)
public enum ExteralessResolverTLSConnector {
    public static func connect(host: String, port: UInt16, serverName: String?, alpn: [String], queue: DispatchQueue,
                               ready: @escaping (nw_connection_t) -> Void, failed: @escaping () -> Void) -> ExteralessTLSConnectToken {
        let dial = Dial(host: host, port: port, serverName: serverName, alpn: alpn, queue: queue, ready: ready, failed: failed)
        queue.async { dial.start() }
        return ExteralessTLSConnectToken(NetworkResolverCancellation { queue.async { dial.cancel() } })
    }

    private final class Dial {
        let host: String, port: UInt16, serverName: String?, alpn: [String], queue: DispatchQueue
        var ready: ((nw_connection_t) -> Void)?
        var failed: (() -> Void)?
        var lookup: NetworkResolverCancellation?
        var connections: [UUID: nw_connection_t] = [:]
        var addresses: [NetworkIPAddress] = []
        var nextIndex = 0
        var stagger: DispatchWorkItem?
        var timeout: DispatchWorkItem?
        var finished = false
        var policyObserver: NSObjectProtocol?
        init(host: String, port: UInt16, serverName: String?, alpn: [String], queue: DispatchQueue, ready: @escaping (nw_connection_t) -> Void, failed: @escaping () -> Void) {
            self.host = host; self.port = port; self.serverName = serverName; self.alpn = alpn; self.queue = queue; self.ready = ready; self.failed = failed
        }
        func start() {
            guard !finished, port > 0 else { fail(); return }
            policyObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.MTAppNetworkResolverDidChange, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { if !self.finished { self.fail() } }
            }
            let timeout = DispatchWorkItem { [weak self] in self?.fail() }
            self.timeout = timeout; queue.asyncAfter(deadline: .now() + 12, execute: timeout)
            lookup = ExteralessNetworkResolverRuntime.shared.resolver.resolve(host: host) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard !self.finished else { return }
                    self.lookup = nil
                    switch result {
                    case let .success(addresses): self.addresses = addresses; self.next()
                    case .failure: self.fail()
                    }
                }
            }
        }
        func next() {
            guard !finished, connections.count < 2, nextIndex < addresses.count else { return }
            let ip = addresses[nextIndex].string; nextIndex += 1
            let tcp: nw_parameters_configure_protocol_block_t = { options in nw_tcp_options_set_no_delay(options, true); nw_tcp_options_set_connection_timeout(options, 10) }
            let parameters: nw_parameters_t
            if let serverName {
                parameters = nw_parameters_create_secure_tcp({ [alpn] options in
                    let security = nw_tls_copy_sec_protocol_options(options)
                    sec_protocol_options_set_tls_server_name(security, serverName)
                    sec_protocol_options_set_tls_false_start_enabled(security, true)
                    for name in alpn { sec_protocol_options_add_tls_application_protocol(security, name) }
                    // Deliberately no verify callback: the system validates trust.
                }, tcp)
            } else {
                parameters = nw_parameters_create()
                let options = nw_tcp_create_options(); tcp(options)
                nw_protocol_stack_set_transport_protocol(nw_parameters_copy_default_protocol_stack(parameters), options)
            }
            nw_parameters_set_prefer_no_proxy(parameters, true)
            let connection = nw_connection_create(nw_endpoint_create_host(ip, String(port)), parameters)
            let id = UUID(); connections[id] = connection
            nw_connection_set_queue(connection, queue)
            nw_connection_set_state_changed_handler(connection) { [weak self] state, _ in
                guard let self, !self.finished, self.connections[id] === connection else { return }
                if state == nw_connection_state_ready {
                    // Ownership passes to the stream host, which replaces the state
                    // callback and performs all subsequent send/receive/close work.
                    self.connections.removeValue(forKey: id)
                    let ready = self.ready
                    self.cancel()
                    nw_connection_set_state_changed_handler(connection, nil)
                    ready?(connection)
                } else if state == nw_connection_state_failed || state == nw_connection_state_waiting {
                    self.connections.removeValue(forKey: id); nw_connection_cancel(connection)
                    if self.nextIndex < self.addresses.count { self.next() }
                    else if self.connections.isEmpty { self.fail() }
                }
            }
            nw_connection_start(connection)
            stagger?.cancel()
            if connections.count < 2 && nextIndex < addresses.count {
                let item = DispatchWorkItem { [weak self] in self?.next() }; stagger = item; queue.asyncAfter(deadline: .now() + 0.25, execute: item)
            }
        }
        func fail() { let failed = self.failed; cancel(); failed?() }
        func cancel() {
            finished = true; ready = nil; failed = nil
            if let policyObserver { NotificationCenter.default.removeObserver(policyObserver); self.policyObserver = nil }
            lookup?.cancel(); lookup = nil; stagger?.cancel(); stagger = nil; timeout?.cancel(); timeout = nil
            for connection in connections.values { nw_connection_cancel(connection) }
            connections.removeAll()
        }
    }
}
