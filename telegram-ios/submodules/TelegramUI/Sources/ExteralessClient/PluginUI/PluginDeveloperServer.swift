import Foundation
import Network

/// Opt-in native transport for the SDK's authenticated loopback JSON protocol.
/// Network state stays on one queue; management actions hop to the application
/// actor and then use the real PluginHost worker APIs.
final class PluginDeveloperServer: @unchecked Sendable {
    typealias Snapshot = PluginDeveloperConnectionState

    typealias Handler = @MainActor @Sendable ([String: PluginUIJSON], PluginDeveloperSession) async throws -> [String: PluginUIJSON]
    private let queue = DispatchQueue(label: "exteraless.plugin-developer")
    private let lock = NSLock()
    private var published = Snapshot(status: "Stopped", token: nil)
    private var currentSession: PluginDeveloperSession? // lock-protected
    private var networkSession: PluginDeveloperSession? // network queue only
    private var epoch = UUID()
    private var listener: NWListener?
    private var tokenURL: URL?
    private var connections: [UUID: Connection] = [:]
    private let handler: Handler

    private final class Connection: @unchecked Sendable {
        let value: NWConnection
        var bytes = Data()
        var request: Task<Void, Never>?
        init(_ value: NWConnection) { self.value = value }
    }

    init(handler: @escaping Handler) { self.handler = handler }

    var snapshot: Snapshot { self.lock.lock(); defer { self.lock.unlock() }; return self.published }

    func start(tokenDirectory: URL) {
        self.lock.lock()
        guard self.currentSession == nil else { self.lock.unlock(); return }
        let session = PluginDeveloperSession()
        self.currentSession = session
        self.published = Snapshot(status: "Starting 127.0.0.1:42690", token: nil)
        self.lock.unlock()
        self.queue.async { [weak self] in self?.startOnQueue(tokenDirectory: tokenDirectory, session: session) }
    }

    func stop() {
        self.lock.lock()
        self.currentSession?.cancel()
        self.currentSession = nil
        self.published = Snapshot(status: "Stopped", token: nil)
        self.lock.unlock()
        self.queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func publish(_ snapshot: Snapshot, session: PluginDeveloperSession, failed: Bool = false) {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.currentSession === session, session.isActive else { return }
        self.published = snapshot
        if failed { session.cancel(); self.currentSession = nil }
    }

    private func startOnQueue(tokenDirectory: URL, session: PluginDeveloperSession) {
        guard session.isActive else { return }
        self.stopOnQueue()
        self.networkSession = session
        self.epoch = UUID()
        let epoch = self.epoch
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            let port = NWEndpoint.Port(rawValue: 42690)!
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            let file = tokenDirectory.appendingPathComponent(".devserver_token")
            self.tokenURL = file
            try Data(token.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.epoch == epoch, session.isActive else { return }
                switch state {
                case .ready: self.publish(Snapshot(status: "Listening on 127.0.0.1:42690", token: token), session: session)
                case let .waiting(error): self.publish(Snapshot(status: "Developer server waiting: \(error)", token: nil), session: session)
                case let .failed(error):
                    self.publish(Snapshot(status: "Developer server failed: \(error)", token: nil), session: session, failed: true)
                    self.stopOnQueue()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.epoch == epoch, session.isActive, self.connections.count < 4 else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = Connection(connection)
                connection.start(queue: self.queue)
                self.receive(id, epoch: epoch, token: token)
            }
            listener.start(queue: self.queue)
        } catch {
            self.publish(Snapshot(status: "Developer server unavailable: \(error)", token: nil), session: session, failed: true)
            self.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        self.epoch = UUID()
        self.listener?.cancel()
        self.listener = nil
        for connection in self.connections.values { connection.request?.cancel(); connection.value.cancel() }
        self.connections.removeAll()
        if let url = self.tokenURL { try? FileManager.default.removeItem(at: url) }
        self.tokenURL = nil
        self.networkSession = nil
    }

    private func close(_ id: UUID) {
        let connection = self.connections.removeValue(forKey: id)
        connection?.request?.cancel()
        connection?.value.cancel()
    }

    private func receive(_ id: UUID, epoch: UUID, token: String) {
        guard self.epoch == epoch, let connection = self.connections[id] else { return }
        connection.value.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.epoch == epoch, let connection = self.connections[id] else { return }
            if let data { connection.bytes.append(data) }
            guard error == nil, connection.bytes.count <= PluginDeveloperProtocol.maximumLineBytes else { self.close(id); return }
            if connection.bytes.firstIndex(of: 10) != nil { self.process(id, epoch: epoch, token: token) }
            else if complete { self.close(id) }
            else { self.receive(id, epoch: epoch, token: token) }
        }
    }

    private func process(_ id: UUID, epoch: UUID, token: String) {
        guard self.epoch == epoch, let connection = self.connections[id] else { return }
        guard let session = self.networkSession, session.isActive else { self.close(id); return }
        guard let line = PluginDeveloperProtocol.takeLine(from: &connection.bytes) else { self.receive(id, epoch: epoch, token: token); return }
        let request: [String: PluginUIJSON]
        do { request = try PluginDeveloperProtocol.request(line, token: token) }
        catch { self.respond(id, epoch: epoch, token: token, response: PluginDeveloperProtocol.response(id: PluginDeveloperProtocol.echoedId(line), error: String(describing: error))); return }
        let handler = self.handler
        connection.request = Task { [weak self] in
            let result: PluginUIJSON
            do {
                try Task.checkCancellation()
                let value = try await handler(request, session)
                // The handler's final guard carries native publication knowledge.
                // Preserve that receipt; epoch/connection checks in respond still
                // reject closed transports without replacing it by a bare error.
                result = PluginDeveloperProtocol.response(id: request["#"] ?? .null, value: value)
            } catch { result = PluginDeveloperProtocol.response(id: request["#"] ?? .null, error: String(describing: error)) }
            guard let self else { return }
            self.queue.async { [weak self] in self?.respond(id, epoch: epoch, token: token, response: result) }
        }
    }

    private func respond(_ id: UUID, epoch: UUID, token: String, response: PluginUIJSON) {
        guard self.epoch == epoch, let connection = self.connections[id], let json = try? response.encoded(), json.utf8.count <= PluginDeveloperProtocol.maximumLineBytes else { self.close(id); return }
        connection.request = nil
        connection.value.send(content: Data((json + "\n").utf8), completion: .contentProcessed { [weak self] error in
            guard let self, self.epoch == epoch, let connection = self.connections[id] else { return }
            if error != nil { self.close(id) }
            else if connection.bytes.firstIndex(of: 10) != nil { self.process(id, epoch: epoch, token: token) }
            else { self.receive(id, epoch: epoch, token: token) }
        })
    }
}
