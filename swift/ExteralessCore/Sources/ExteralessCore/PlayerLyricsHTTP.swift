import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PlayerLyricsHTTPResponse: Sendable {
    public let status: Int
    public let retryAfter: String?
    public let data: Data
    public init(status: Int, retryAfter: String? = nil, data: Data) {
        self.status = status; self.retryAfter = retryAfter; self.data = data
    }
}

public protocol PlayerLyricsHTTPTransport: Sendable {
    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> PlayerLyricsHTTPResponse
}

/// One bounded, cancellable URLSession per request. No shared cookies,
/// credentials, redirects, URLCache, Android keys or unbounded data(for:) buffer.
public final class PlayerLyricsURLSessionTransport: PlayerLyricsHTTPTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 2
        self.configuration = configuration
    }

    public func send(_ request: URLRequest, timeout: TimeInterval) async throws -> PlayerLyricsHTTPResponse {
        let exchange = PlayerLyricsHTTPExchange()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                exchange.start(request, configuration: configuration, timeout: timeout, continuation: continuation)
            }
        }, onCancel: { exchange.cancel() })
    }
}

private final class PlayerLyricsHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PlayerLyricsHTTPResponse, Error>?
    private var session: URLSession?
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var body = Data()
    private var response: HTTPURLResponse?

    func start(_ request: URLRequest, configuration: URLSessionConfiguration, timeout: TimeInterval, continuation: CheckedContinuation<PlayerLyricsHTTPResponse, Error>) {
        let timeout = timeout.isFinite ? max(0.01, min(20, timeout)) : 10
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.failure(PlayerLyricsError.timeout)) }
        lock.lock()
        let shouldStart = !finished
        if shouldStart {
            self.continuation = continuation
            self.session = session
            self.timer = timer
        }
        lock.unlock()
        timer.resume()
        if shouldStart { task.resume() }
        else {
            timer.cancel()
            session.invalidateAndCancel()
            continuation.resume(throwing: PlayerLyricsError.cancelled)
        }
    }

    func cancel() { finish(.failure(PlayerLyricsError.cancelled)) }

    private func finish(_ result: Result<PlayerLyricsHTTPResponse, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation, session = self.session, timer = self.timer
        self.continuation = nil
        self.session = nil
        self.timer = nil
        self.body.removeAll(keepingCapacity: false)
        self.response = nil
        lock.unlock()
        timer?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(PlayerLyricsError.invalidResponse))
            return
        }
        guard response.expectedContentLength <= Int64(PlayerLyricsLimits.responseBytes) else {
            completionHandler(.cancel)
            finish(.failure(PlayerLyricsError.responseTooLarge))
            return
        }
        lock.lock()
        let allowed = !finished
        if allowed { self.response = response }
        lock.unlock()
        completionHandler(allowed ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let exceeded = body.count + data.count > PlayerLyricsLimits.responseBytes
        if !finished && !exceeded { body.append(data) }
        lock.unlock()
        if exceeded { finish(.failure(PlayerLyricsError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(PlayerLyricsError.sanitized(error))); return }
        lock.lock()
        let response = self.response, data = self.body
        lock.unlock()
        guard let response else { finish(.failure(PlayerLyricsError.invalidResponse)); return }
        finish(.success(PlayerLyricsHTTPResponse(status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"), data: data)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(PlayerLyricsError.http(response.statusCode)))
    }
}

public enum PlayerLyricsRequest {
    public enum Endpoint: Sendable { case exact, search, fallback }

    /// Endpoint and parameter names are pinned to OnlineLyrics.java. All metadata
    /// is encoded as query values; it cannot replace a host, path or header.
    public static func make(query: PlayerLyricsQuery, endpoint: Endpoint, timeout: TimeInterval = 10) throws -> URLRequest {
        guard query.valid else { throw PlayerLyricsError.invalidQuery }
        let base: String
        var items: [URLQueryItem]
        switch endpoint {
        case .exact:
            base = "https://lrclib.net/api/get"
            items = [.init(name: "artist_name", value: query.artist), .init(name: "track_name", value: query.title)]
            if !query.album.isEmpty { items.append(.init(name: "album_name", value: query.album)) }
            if query.duration > 0 { items.append(.init(name: "duration", value: String(query.duration))) }
        case .search:
            base = "https://lrclib.net/api/search"
            items = [.init(name: "track_name", value: query.title)]
            if !query.artist.isEmpty { items.append(.init(name: "artist_name", value: query.artist)) }
        case .fallback:
            base = "https://api.lrcmux.dev/get"
            items = [.init(name: "title", value: query.title), .init(name: "level", value: "line"), .init(name: "format", value: "json")]
            if !query.artist.isEmpty { items.append(.init(name: "artist", value: query.artist)) }
            if !query.album.isEmpty { items.append(.init(name: "album", value: query.album)) }
            if query.duration > 0 { items.append(.init(name: "duration", value: String(query.duration))) }
        }
        guard var components = URLComponents(string: base) else { throw PlayerLyricsError.invalidQuery }
        components.queryItems = items
        // '+' must stay a literal plus in artist/track names, not form encoding.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw PlayerLyricsError.invalidQuery }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("exteraless-ios/1 (https://github.com/exteraless/exteraless)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }
}
