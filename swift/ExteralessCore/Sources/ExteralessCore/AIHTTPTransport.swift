import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AIHTTPEvent: Sendable {
    case response(status: Int, headers: [String: String])
    case data(Data)
}

public protocol AIHTTPTransport: Sendable {
    func events(for request: URLRequest, maximumBytes: Int, timeout: TimeInterval) -> AsyncThrowingStream<AIHTTPEvent, Error>
}

extension AIHTTPTransport {
    public func data(for request: URLRequest, maximumBytes: Int = AILimits.responseBytes, timeout: TimeInterval = AILimits.resourceTimeout) async throws -> Data {
        var body = Data()
        var status: Int?
        do {
            try Task.checkCancellation()
            for try await event in events(for: request, maximumBytes: maximumBytes, timeout: timeout) {
                try Task.checkCancellation()
                switch event {
                case let .response(code, _):
                    status = code
                    guard (200 ..< 300).contains(code) else { throw AIError.http(code) }
                case let .data(data):
                    guard body.count + data.count <= maximumBytes else { throw AIError.responseTooLarge }
                    body.append(data)
                }
            }
            try Task.checkCancellation()
            guard status != nil else { throw AIError.invalidResponse }
            return body
        } catch { throw AIError.sanitized(error) }
    }
}

/// Delegate-based streaming works on both Apple Foundation and FoundationNetworking.
/// A request owns its session: cancellation closes the socket, not merely the UI.
public final class AIURLSessionTransport: AIHTTPTransport, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let resourceTimeout: TimeInterval

    public init(configuration: URLSessionConfiguration = .ephemeral, resourceTimeout: TimeInterval = AILimits.resourceTimeout) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = AILimits.requestTimeout
        self.resourceTimeout = resourceTimeout.isFinite ? max(0.01, min(resourceTimeout, AILimits.resourceTimeout)) : AILimits.resourceTimeout
        configuration.timeoutIntervalForResource = self.resourceTimeout
        self.configuration = configuration
    }

    public func events(for request: URLRequest, maximumBytes: Int, timeout: TimeInterval) -> AsyncThrowingStream<AIHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let exchange = AIHTTPExchange(continuation: continuation, maximumBytes: maximumBytes)
            continuation.onTermination = { @Sendable _ in exchange.cancel() }
            exchange.start(request: request, configuration: configuration, timeout: timeout.isFinite ? min(timeout, resourceTimeout) : resourceTimeout)
        }
    }
}

private final class AIHTTPExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AIHTTPEvent, Error>.Continuation?
    private var session: URLSession?
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var count = 0
    private let maximumBytes: Int

    init(continuation: AsyncThrowingStream<AIHTTPEvent, Error>.Continuation, maximumBytes: Int) {
        self.continuation = continuation
        self.maximumBytes = maximumBytes
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration, timeout: TimeInterval) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0.01, min(timeout, AILimits.resourceTimeout)))
        timer.setEventHandler { [weak self] in self?.finish(AIError.timeout) }
        lock.lock()
        let shouldStart = !finished
        if shouldStart {
            self.session = session
            self.timer = timer
        }
        lock.unlock()
        // Resume even a cancelled source, so it is never released while suspended.
        timer.resume()
        if shouldStart { task.resume() }
        else { timer.cancel(); session.invalidateAndCancel() }
    }

    func cancel() { finish(AIError.cancelled) }

    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        let timer = self.timer
        self.continuation = nil
        self.session = nil
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        if let error { continuation?.finish(throwing: AIError.sanitized(error)) }
        else { continuation?.finish() }
        session?.invalidateAndCancel()
    }

    private func emit(_ event: AIHTTPEvent) {
        lock.lock()
        let continuation = finished ? nil : self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(AIError.invalidResponse)
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(AIError.responseTooLarge)
            return
        }
        var headers: [String: String] = [:]
        // Never forward cookies, Authorization, URLs, or arbitrary echoed headers.
        for key in ["Content-Type", "Retry-After", "isgenderdebiasedtranslation"] {
            if let value = response.value(forHTTPHeaderField: key) { headers[key.lowercased()] = value }
        }
        emit(.response(status: response.statusCode, headers: headers))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        count += data.count
        let exceeded = count > maximumBytes
        lock.unlock()
        if exceeded { finish(AIError.responseTooLarge) }
        else { emit(.data(data)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // No provider redirect may forward a key or private POST body to a new URL.
        completionHandler(nil)
        finish(AIError.http(response.statusCode))
    }
}
