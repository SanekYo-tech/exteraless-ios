import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Image-only transport with exact provider hosts, bounded streaming bodies,
/// normal TLS trust, no redirects, no URL/header logging and no persistent cache.
public final class MapProviderHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let shared = MapProviderHTTP()
    private struct Pending {
        let completion: MapResourceCache.Completion
        var data = Data()
        var ttl: TimeInterval = 0
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    public init(protocolClasses: [AnyClass]? = nil) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 6; configuration.timeoutIntervalForResource = 6
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.protocolClasses = protocolClasses ?? configuration.protocolClasses
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public func invalidate() { session.invalidateAndCancel() }

    public func fetch(url: URL, completion: @escaping MapResourceCache.Completion) -> NetworkResolverCancellation {
        guard url.scheme == "https", ["tile.openstreetmap.org", "static-maps.yandex.ru"].contains(url.host ?? ""), url.user == nil, url.password == nil, url.port == nil else {
            completion(.failure(.invalidRequest)); return NetworkResolverCancellation()
        }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("image/png,image/jpeg", forHTTPHeaderField: "Accept")
        request.setValue("Exteraless-iOS/1.0 (native location map viewer)", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        lock.lock(); pending[task.taskIdentifier] = Pending(completion: completion); lock.unlock()
        task.resume()
        return NetworkResolverCancellation { [weak self, weak task] in
            guard let task else { return }
            self?.finish(task.taskIdentifier, result: .failure(.cancelled)); task.cancel()
        }
    }

    private func finish(_ id: Int, result: Result<MapResourceData, MapResourceError>) {
        lock.lock(); let callback = pending.removeValue(forKey: id)?.completion; lock.unlock(); callback?(result)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(task.taskIdentifier, result: .failure(.unavailable)); task.cancel()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              ["image/png", "image/jpeg"].contains(response.mimeType?.lowercased() ?? ""), response.expectedContentLength <= 4 * 1024 * 1024 else {
            finish(dataTask.taskIdentifier, result: .failure(.unavailable)); completionHandler(.cancel); return
        }
        let isOSM = dataTask.originalRequest?.url?.host == "tile.openstreetmap.org"
        var ttl: TimeInterval = isOSM ? 604800 : 300
        var prohibitsCache = false
        for directive in (response.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased().split(separator: ",") {
            let part = directive.trimmingCharacters(in: .whitespaces)
            if part == "no-store" || part == "no-cache" { prohibitsCache = true }
            if part.hasPrefix("max-age="), let age = Double(part.dropFirst(8)), age.isFinite, age >= 0 { ttl = min(604800, age) }
        }
        let age = max(0, Double(response.value(forHTTPHeaderField: "Age") ?? "0") ?? 0)
        lock.lock(); pending[dataTask.taskIdentifier]?.ttl = prohibitsCache ? 0 : max(0, ttl - age); lock.unlock()
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let tooLarge = (pending[dataTask.taskIdentifier]?.data.count ?? 0) + data.count > 4 * 1024 * 1024
        if !tooLarge { pending[dataTask.taskIdentifier]?.data.append(data) }
        lock.unlock()
        if tooLarge { finish(dataTask.taskIdentifier, result: .failure(.tooLarge)); dataTask.cancel() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let item = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let item else { return }
        item.completion(error == nil ? .success(.init(data: item.data, ttl: item.ttl)) : .failure((error as NSError?)?.code == NSURLErrorCancelled ? .cancelled : .unavailable))
    }
}
