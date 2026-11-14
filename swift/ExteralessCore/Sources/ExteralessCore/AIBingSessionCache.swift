import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AIBingSession: Codable, Equatable, Sendable {
    public let host: String
    public let ig: String
    public let iid: String
    public let key: String
    public let token: String
    public let tokenTs: Int64
    public let tokenExpiryInterval: Int64

    public func isValid(at milliseconds: Int64) -> Bool {
        let age = milliseconds.subtractingReportingOverflow(tokenTs)
        return ["www.bing.com", "cn.bing.com"].contains(host)
            && !ig.isEmpty && !iid.isEmpty && !token.isEmpty
            && ig.utf8.count <= 1024 && iid.utf8.count <= 1024 && token.utf8.count <= 16_384
            && Int64(key) == tokenTs && tokenTs > 0
            && tokenExpiryInterval > 0 && tokenExpiryInterval <= 86_400_000
            && !age.overflow && age.partialValue >= 0 && age.partialValue < tokenExpiryInterval
    }

    public static func parse(_ data: Data, host: String = "www.bing.com") throws -> AIBingSession {
        let parsed = try AIBingConfiguration.parse(data)
        guard let timestamp = Int64(parsed.key), parsed.tokenExpiryInterval > 0 else { throw AIError.invalidResponse }
        return AIBingSession(host: host, ig: parsed.ig, iid: parsed.iid, key: parsed.key, token: parsed.token, tokenTs: timestamp, tokenExpiryInterval: parsed.tokenExpiryInterval)
    }
}

/// A single bounded acquisition is shared by waiters. Disposing one waiter does
/// not cancel another; disposing the last waiter closes the actual HTTP request.
/// Persistence is one Keychain value so token/timestamp/TTL cannot tear apart.
public actor AIBingSessionCache {
    private let transport: any AIHTTPTransport
    private let store: ClientSettings
    private let now: @Sendable () -> Int64
    private var session: AIBingSession?
    private var loaded = false
    private var sequence = 0
    private var acquisitionId: UUID?
    private var acquisition: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<AIBingSession, Error>] = [:]

    public init(transport: any AIHTTPTransport, store: ClientSettings, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.transport = transport
        self.store = store
        self.now = now
    }

    public func lease() async throws -> (session: AIBingSession, sequence: Int) {
        let session = try await acquire()
        try Task.checkCancellation()
        sequence = sequence == Int.max ? 1 : sequence + 1
        return (session, sequence)
    }

    public func invalidate(matching value: AIBingSession) throws {
        guard session == value else { return }
        session = nil
        try store.set(.string(""), for: "ai.bingSession")
    }

    public func cancelAll() {
        acquisitionId = nil
        acquisition?.cancel()
        acquisition = nil
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations { continuation.resume(throwing: AIError.cancelled) }
    }

    private func acquire() async throws -> AIBingSession {
        try Task.checkCancellation()
        if !loaded {
            try store.register([.init(key: "ai.bingSession", title: "Private Bing session cache", section: "AI state", defaultValue: .string(""), isSecret: true, androidSymbols: ["bingSession"])])
            let raw = store.string("ai.bingSession")
            session = try? JSONDecoder().decode(AIBingSession.self, from: Data(raw.utf8))
            loaded = true
        }
        if let session, session.isValid(at: now()) { return session }
        let waiterId = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: AIError.cancelled); return }
                waiters[waiterId] = continuation
                if acquisition == nil { startAcquisition() }
            }
        }, onCancel: { Task { await self.cancel(waiterId) } })
    }

    private func startAcquisition() {
        let id = UUID()
        acquisitionId = id
        let host = session.flatMap { ["www.bing.com", "cn.bing.com"].contains($0.host) ? $0.host : nil } ?? "www.bing.com"
        let transport = self.transport
        acquisition = Task { [weak self] in
            do {
                var request = URLRequest(url: URL(string: "https://\(host)/translator")!, timeoutInterval: 30)
                request.setValue(AITranslationRequest.browserAgent, forHTTPHeaderField: "User-Agent")
                let data = try await transport.data(for: request, maximumBytes: AILimits.responseBytes, timeout: 30)
                try Task.checkCancellation()
                let session = try AIBingSession.parse(data, host: host)
                await self?.finish(id, result: .success(session))
            } catch { await self?.finish(id, result: .failure(AIError.sanitized(error))) }
        }
    }

    private func finish(_ id: UUID, result: Result<AIBingSession, Error>) {
        guard acquisitionId == id else { return }
        acquisitionId = nil
        acquisition = nil
        let continuations = Array(waiters.values)
        waiters.removeAll()
        guard !continuations.isEmpty else { return }
        let completionResult: Result<AIBingSession, Error>
        do {
            let value = try result.get()
            guard value.isValid(at: now()) else { throw AIError.invalidResponse }
            let encoded = try JSONEncoder().encode(value)
            try store.set(.string(String(decoding: encoded, as: UTF8.self)), for: "ai.bingSession")
            session = value
            sequence = 0
            completionResult = .success(value)
        } catch { completionResult = .failure(error) }
        for continuation in continuations { continuation.resume(with: completionResult) }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: AIError.cancelled)
        if waiters.isEmpty {
            acquisitionId = nil
            acquisition?.cancel()
            acquisition = nil
        }
    }
}
