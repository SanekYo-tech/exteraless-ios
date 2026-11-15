import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Idempotent cancellation; no implicit cancellation on deinit. Owners explicitly
/// cancel their leases, including the last coalesced lookup subscriber.
public final class NetworkResolverCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var cancelled = false
    public init(_ action: @escaping @Sendable () -> Void = {}) { self.action = action }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() {
        lock.lock()
        cancelled = true
        let action = self.action; self.action = nil
        lock.unlock()
        action?()
    }
}

public struct NetworkResolverHTTPResponse: Sendable {
    public let data: Data
    public let age: TimeInterval
    public let maximumTTL: TimeInterval?
    public init(data: Data, age: TimeInterval = 0, maximumTTL: TimeInterval? = nil) {
        self.data = data; self.age = age; self.maximumTTL = maximumTTL
    }
}

public protocol NetworkResolverHTTPTransport: Sendable {
    func send(_ request: URLRequest, completion: @escaping @Sendable (Result<NetworkResolverHTTPResponse, NetworkResolverError>) -> Void) -> NetworkResolverCancellation
}

/// One ephemeral URLSession for the resolver. No URL cache, cookies, credentials,
/// custom trust delegate or redirect following. Endpoint hostnames are bootstrapped
/// by URLSession's native resolver, never recursively by this resolver.
public final class NetworkResolverURLSessionTransport: NSObject, NetworkResolverHTTPTransport, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        let completion: @Sendable (Result<NetworkResolverHTTPResponse, NetworkResolverError>) -> Void
        var data = Data()
        var age = 0.0
        var maximumTTL: TimeInterval?
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    /// `protocolClasses` is a per-session fixture seam, never globally registered.
    public init(protocolClasses: [AnyClass]? = nil) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.protocolClasses = protocolClasses ?? configuration.protocolClasses
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public func invalidate() { session.invalidateAndCancel() }

    public func send(_ request: URLRequest, completion: @escaping @Sendable (Result<NetworkResolverHTTPResponse, NetworkResolverError>) -> Void) -> NetworkResolverCancellation {
        let task = session.dataTask(with: request)
        lock.lock(); pending[task.taskIdentifier] = Pending(completion: completion); lock.unlock()
        task.resume()
        return NetworkResolverCancellation { [weak self, weak task] in
            guard let task else { return }
            self?.finish(task.taskIdentifier, result: .failure(.cancelled))
            task.cancel()
        }
    }

    private func finish(_ id: Int, result: Result<NetworkResolverHTTPResponse, NetworkResolverError>) {
        lock.lock(); let completion = pending.removeValue(forKey: id)?.completion; lock.unlock()
        completion?(result)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(task.taskIdentifier, result: .failure(.redirect))
        task.cancel()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let failure: NetworkResolverError?
        if let response = response as? HTTPURLResponse {
            let expected = dataTask.originalRequest?.value(forHTTPHeaderField: "Accept") ?? "application/dns-message"
            let mime = response.mimeType?.lowercased() ?? ""
            if response.statusCode != 200 { failure = .httpStatus }
            else if response.expectedContentLength > Int64(NetworkDNSWire.maximumPacketBytes) { failure = .responseTooLarge }
            else if !(expected == "application/dns-json" ? ["application/dns-json", "application/json"].contains(mime) : mime == "application/dns-message") { failure = .contentType }
            else { failure = nil }
            lock.lock()
            let age = Double(response.value(forHTTPHeaderField: "Age") ?? "0") ?? 0
            pending[dataTask.taskIdentifier]?.age = age.isFinite ? max(0, age) : 0
            for directive in (response.value(forHTTPHeaderField: "Cache-Control") ?? "").lowercased().split(separator: ",") {
                let value = directive.trimmingCharacters(in: .whitespaces)
                if value == "no-store" || value == "no-cache" { pending[dataTask.taskIdentifier]?.maximumTTL = 0 }
                if value.hasPrefix("max-age="), let limit = Double(value.dropFirst(8)), limit.isFinite, limit >= 0 {
                    let maximumTTL = min(pending[dataTask.taskIdentifier]?.maximumTTL ?? 3600, limit)
                    pending[dataTask.taskIdentifier]?.maximumTTL = maximumTTL
                }
            }
            lock.unlock()
        } else { failure = .malformedResponse }
        if let failure {
            finish(dataTask.taskIdentifier, result: .failure(failure)); completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let oversized = (pending[dataTask.taskIdentifier]?.data.count ?? 0) + data.count > NetworkDNSWire.maximumPacketBytes
        if !oversized { pending[dataTask.taskIdentifier]?.data.append(data) }
        lock.unlock()
        if oversized { finish(dataTask.taskIdentifier, result: .failure(.responseTooLarge)); dataTask.cancel() }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let value = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let value else { return }
        if let error {
            let code = (error as NSError).code
            value.completion(.failure(code == NSURLErrorCancelled ? .cancelled : code == NSURLErrorTimedOut ? .timeout : .transport))
        } else { value.completion(.success(.init(data: value.data, age: value.age, maximumTTL: value.maximumTTL))) }
    }
}

public enum NetworkDoHRequest {
    public static func make(endpoint: NetworkDoHEndpoint, question: NetworkDNSQuestion, id: UInt16, timeout: TimeInterval) throws -> URLRequest {
        guard timeout.isFinite, timeout > 0, var components = URLComponents(url: endpoint.url, resolvingAgainstBaseURL: false) else { throw NetworkResolverError.invalidEndpoint }
        let wire = NetworkDNSWire.query(question, id: id)
        var items: [URLQueryItem] = []
        switch endpoint.format {
        case .wirePost: break
        case .wireGet:
            let encoded = wire.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            items.append(URLQueryItem(name: "dns", value: encoded))
        case .jsonGet:
            items += [URLQueryItem(name: "name", value: question.name), URLQueryItem(name: "type", value: String(question.type.rawValue))]
        }
        if !items.isEmpty {
            var addition = URLComponents()
            addition.queryItems = items
            // Do not decode/re-encode a user-provided token or signed query.
            // In particular %2B must not become a form-decoded '+' / space.
            components.percentEncodedQuery = [components.percentEncodedQuery, addition.percentEncodedQuery].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "&")
        }
        guard let url = components.url else { throw NetworkResolverError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(5, timeout))
        request.httpMethod = endpoint.format == .wirePost ? "POST" : "GET"
        request.setValue(endpoint.format == .jsonGet ? "application/dns-json" : "application/dns-message", forHTTPHeaderField: "Accept")
        if endpoint.format == .wirePost {
            request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
            request.httpBody = wire
        }
        return request
    }

    public static func decode(_ response: NetworkResolverHTTPResponse, endpoint: NetworkDoHEndpoint, question: NetworkDNSQuestion, id: UInt16) throws -> NetworkDNSAnswer {
        let answer = try endpoint.format == .jsonGet ? NetworkDNSJSON.response(response.data, question: question) : NetworkDNSWire.response(response.data, question: question, id: id)
        return NetworkDNSAnswer(records: answer.records, canonicalName: answer.canonicalName, ttl: max(0, min(answer.ttl, response.maximumTTL ?? answer.ttl) - max(0, response.age)), negative: answer.negative)
    }
}

public enum NetworkDNSJSON {
    private struct Message: Decodable {
        struct QuestionValue: Decodable { let name: String; let type: UInt16 }
        struct Record: Decodable { let name: String; let type: UInt16; let TTL: UInt32; let data: String }
        let Status: Int
        let TC: Bool
        let Question: [QuestionValue]
        let Answer: [Record]?
        let Authority: [Record]?
    }

    public static func response(_ data: Data, question: NetworkDNSQuestion) throws -> NetworkDNSAnswer {
        guard data.count <= NetworkDNSWire.maximumPacketBytes else { throw NetworkResolverError.responseTooLarge }
        let message: Message
        do { message = try JSONDecoder().decode(Message.self, from: data) } catch { throw NetworkResolverError.malformedResponse }
        guard !message.TC else { throw NetworkResolverError.truncatedResponse }
        guard message.Question.count == 1, try NetworkDNSQuestion.canonicalName(message.Question[0].name) == question.name, message.Question[0].type == question.type.rawValue else { throw NetworkResolverError.mismatchedResponse }
        guard (message.Answer?.count ?? 0) + (message.Authority?.count ?? 0) <= NetworkDNSWire.maximumRecords else { throw NetworkResolverError.responseTooLarge }
        func records(_ input: [Message.Record]) throws -> [NetworkDNSRecord] {
            try input.compactMap { record in
                let name = record.name == "." ? "" : try NetworkDNSQuestion.canonicalName(record.name)
                let value: NetworkDNSRecord.Value
                switch record.type {
                case 1, 28:
                    guard let ip = NetworkIPAddress(record.data), ip.scope == nil, ip.family == (record.type == 1 ? .ipv4 : .ipv6) else { throw NetworkResolverError.malformedResponse }
                    value = .address(ip)
                case 5: value = .cname(try NetworkDNSQuestion.canonicalName(record.data))
                case 16: value = .text(try textParts(record.data))
                case 6:
                    let parts = record.data.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    guard parts.count == 7, let minimum = UInt32(parts[6]), parts.dropFirst(2).allSatisfy({ UInt32($0) != nil }) else { throw NetworkResolverError.malformedResponse }
                    value = .soa(minimum: minimum)
                default: return nil
                }
                return NetworkDNSRecord(name: name, ttl: record.TTL, value: value)
            }
        }
        return try NetworkDNSAnswer.select(question: question, records: records(message.Answer ?? []), authority: records(message.Authority ?? []), rcode: message.Status)
    }

    /// DNS presentation text: preserve each quoted character-string, including
    /// escaped quotes and decimal octets. Do not remove every quote indiscriminately.
    static func textParts(_ text: String) throws -> [Data] {
        let bytes = Array(text.utf8)
        var at = 0, result: [Data] = []
        while at < bytes.count {
            while at < bytes.count && (bytes[at] == 32 || bytes[at] == 9) { at += 1 }
            if at == bytes.count { break }
            guard bytes[at] == 34 else { throw NetworkResolverError.malformedResponse }
            at += 1
            var part = Data(), closed = false
            while at < bytes.count {
                let byte = bytes[at]; at += 1
                if byte == 34 { closed = true; break }
                if byte == 92 {
                    guard at < bytes.count else { throw NetworkResolverError.malformedResponse }
                    if at + 2 < bytes.count, bytes[at..<(at + 3)].allSatisfy({ (48...57).contains($0) }) {
                        let value = Int(bytes[at] - 48) * 100 + Int(bytes[at + 1] - 48) * 10 + Int(bytes[at + 2] - 48)
                        guard value <= 255 else { throw NetworkResolverError.malformedResponse }
                        part.append(UInt8(value)); at += 3
                    } else { part.append(bytes[at]); at += 1 }
                } else { part.append(byte) }
                guard part.count <= 255 else { throw NetworkResolverError.malformedResponse }
            }
            guard closed else { throw NetworkResolverError.malformedResponse }
            result.append(part)
        }
        guard !result.isEmpty else { throw NetworkResolverError.malformedResponse }
        return result
    }
}
