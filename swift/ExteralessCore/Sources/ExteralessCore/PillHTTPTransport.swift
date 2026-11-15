import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PillHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data
    public init(status: Int, headers: [String: String] = [:], data: Data) {
        self.status = status; self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last }); self.data = data
    }
    public func validate(now: Date) throws {
        if status == 429 { throw PillError.rateLimited(retryAt: retryAt(now: now) ?? now.addingTimeInterval(60)) }
        guard (200...299).contains(status) else { throw PillError.http(status) }
    }
    public func retryAt(now: Date) -> Date? {
        guard let value = headers["retry-after"] else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(min(seconds, 7 * 24 * 3600))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value)
    }
}

public protocol PillHTTPTransport: Sendable {
    func get(_ url: URL, completion: @escaping @Sendable (Result<PillHTTPResponse, PillError>) -> Void) -> PillCancellation
}

public enum PillEndpoints {
    public static let coinbase = URL(string: "https://api.coinbase.com/v2/exchange-rates?currency=USD")!
    public static let gold = URL(string: "https://api.gold-api.com/price/XAU")!
    /// Exact endpoint/parameters preserved in Android Weather.java:379 (the inactive HTTP implementation).
    public static func openMeteo(_ coordinate: PillCoordinate) -> URL {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [URLQueryItem(name: "latitude", value: String(coordinate.latitude)), URLQueryItem(name: "longitude", value: String(coordinate.longitude)), URLQueryItem(name: "current_weather", value: "true")]
        return url.url!
    }
}

/// Ephemeral foreground-only HTTP. Bounded time/body, no cookies, credential persistence or redirects.
public final class PillURLSessionTransport: PillHTTPTransport {
    public init() {}
    public func get(_ url: URL, completion: @escaping @Sendable (Result<PillHTTPResponse, PillError>) -> Void) -> PillCancellation {
        let request = PillURLSessionRequest(completion: completion)
        request.start(url)
        return PillCancellation { request.cancel() }
    }
}

private final class PillURLSessionRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<PillHTTPResponse, PillError>) -> Void)?
    private var session: URLSession?
    private var data = Data()
    private var response: HTTPURLResponse?
    init(completion: @escaping @Sendable (Result<PillHTTPResponse, PillError>) -> Void) { self.completion = completion }
    func start(_ url: URL) {
        guard url.scheme == "https", url.user == nil, url.password == nil else { finish(.failure(.invalidConfiguration)); return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        #if !os(Linux) && !os(Windows)
        configuration.waitsForConnectivity = false
        #endif
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        lock.lock(); self.session = session; lock.unlock()
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
    }
    func cancel() { finish(.failure(.cancelled)) }
    private func finish(_ result: Result<PillHTTPResponse, PillError>) {
        lock.lock()
        let completion = self.completion; self.completion = nil
        let session = self.session; self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        completion?(result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 1_048_576 else {
            completionHandler(.cancel); finish(.failure(.invalidData)); return
        }
        self.response = response
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= 1_048_576 - self.data.count else { finish(.failure(.invalidData)); return }
        self.data.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError {
            finish(.failure(error.code == .cancelled ? .cancelled : error.code == .timedOut ? .timeout : .network)); return
        }
        guard error == nil, let response else { finish(.failure(.network)); return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { if let key = key as? String { headers[key.lowercased()] = String(describing: value) } }
        finish(.success(PillHTTPResponse(status: response.statusCode, headers: headers, data: data)))
    }
}

public struct PillProviderUsage: Equatable, Sendable {
    public var requests = 0
    public var responses = 0
    public var failures = 0
    /// nil means the source did not expose a quota. It is never displayed as zero.
    public var remaining: Int?
    public var retryAt: Date?
    public var retryIsSourceReported = false
    public var lastHTTPStatus: Int?
    public init() {}
}

/// Counts actual producer requests after coalescing. Rate-limit headers are optional facts.
public final class PillHTTPClient: @unchecked Sendable {
    private let transport: any PillHTTPTransport
    private let lock = NSLock()
    private var usage: [String: PillProviderUsage] = [:]
    private var lastStart: [String: Date] = [:]
    private let now: @Sendable () -> Date
    public init(transport: any PillHTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) { self.transport = transport; self.now = now }
    public func statistics(domain: String) -> PillProviderUsage { lock.lock(); defer { lock.unlock() }; return usage[domain] ?? PillProviderUsage() }
    public func get(_ url: URL, domain: String, completion: @escaping @Sendable (Result<PillHTTPResponse, PillError>) -> Void) -> PillCancellation {
        let now = self.now()
        lock.lock()
        var value = usage[domain] ?? PillProviderUsage()
        let retry = value.retryAt
        let earliest = lastStart[domain]?.addingTimeInterval(5) // Bound repeated manual taps, including unsuccessful requests.
        if let retry, retry > now {
            lock.unlock(); completion(.failure(.rateLimited(retryAt: retry))); return PillCancellation()
        }
        if let earliest, earliest > now {
            lock.unlock(); completion(.failure(.throttled(retryAt: earliest))); return PillCancellation()
        }
        lastStart[domain] = now; value.requests += 1; usage[domain] = value
        lock.unlock()
        return transport.get(url) { [weak self] result in
            if let self {
                self.lock.lock()
                var value = self.usage[domain] ?? PillProviderUsage()
                switch result {
                case let .success(response):
                    value.responses += 1; value.lastHTTPStatus = response.status
                    value.remaining = response.headers["x-ratelimit-remaining"].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
                    value.retryAt = response.retryAt(now: self.now())
                    value.retryIsSourceReported = value.retryAt != nil
                    if response.status == 429 && value.retryAt == nil { value.retryAt = self.now().addingTimeInterval(60) }
                    if !(200...299).contains(response.status) { value.failures += 1 }
                case .failure(.cancelled): break
                case .failure: value.failures += 1
                }
                self.usage[domain] = value
                self.lock.unlock()
            }
            completion(result)
        }
    }
}
