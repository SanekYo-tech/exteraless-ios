import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct EmojiDownloadedFont: Sendable {
    public let data: Data
    public let url: URL
    public let mimeType: String
    public let inspection: EmojiFontInspection
}

/// User-choice downloads are not bundled dependencies. The UI shows their final
/// HTTPS source, format, byte count and computed SHA before selecting the font.
/// A supplied/bundled pin is always verified; redirects retain the same rules.
public final class EmojiFontHTTPClient: @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        self.configuration = configuration
    }

    public static func validatedURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 2048, let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
              ["ttf", "otf"].contains(url.pathExtension.lowercased()) else { throw EmojiPackError.invalidURL }
        return url
    }

    public func download(url: URL, expectedSHA256: String? = nil) async throws -> EmojiDownloadedFont {
        _ = try Self.validatedURL(url.absoluteString)
        if let expectedSHA256, !EmojiFontInspection.isSHA256(expectedSHA256) { throw EmojiPackError.checksumMismatch }
        let operation = EmojiFontDownload(url: url, expectedSHA256: expectedSHA256, configuration: configuration)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in operation.start(continuation) }
        }, onCancel: { operation.cancel() })
    }
}

private final class EmojiFontDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let expectedSHA256: String?
    private let configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<EmojiDownloadedFont, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var redirects = 0

    init(url: URL, expectedSHA256: String?, configuration: URLSessionConfiguration) {
        self.url = url; self.expectedSHA256 = expectedSHA256; self.configuration = configuration
    }

    func start(_ continuation: CheckedContinuation<EmojiDownloadedFont, Error>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(throwing: EmojiPackError.cancelled); return }
        self.continuation = continuation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("font/ttf, font/otf, application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() { finish(.failure(EmojiPackError.cancelled)) }

    private func finish(_ result: Result<EmojiDownloadedFont, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation, session = self.session
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 3, let url = request.url, (try? EmojiFontHTTPClient.validatedURL(url.absoluteString)) != nil else {
            completionHandler(nil); finish(.failure(EmojiPackError.invalidURL)); return
        }
        var request = URLRequest(url: url)
        request.setValue("font/ttf, font/otf, application/octet-stream", forHTTPHeaderField: "Accept")
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, let url = response.url,
              (try? EmojiFontHTTPClient.validatedURL(url.absoluteString)) != nil else {
            completionHandler(.cancel); finish(.failure(EmojiPackError.invalidURL)); return
        }
        guard response.statusCode == 200 else { completionHandler(.cancel); finish(.failure(EmojiPackError.http(response.statusCode))); return }
        guard response.expectedContentLength <= Int64(EmojiPackLimits.fontBytes) else { completionHandler(.cancel); finish(.failure(EmojiPackError.tooLarge)); return }
        let types: Set<String> = ["font/ttf", "font/otf", "font/sfnt", "application/font-sfnt", "application/x-font-ttf", "application/x-font-opentype", "application/octet-stream"]
        guard let mime = response.mimeType?.lowercased(), types.contains(mime) else { completionHandler(.cancel); finish(.failure(EmojiPackError.invalidFont("HTTP content type"))); return }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= EmojiPackLimits.fontBytes - bytes.count else { lock.unlock(); finish(.failure(EmojiPackError.tooLarge)); return }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let data = bytes, alreadyFinished = finished
        lock.unlock()
        guard !alreadyFinished else { return }
        if error != nil { finish(.failure(EmojiPackError.network)); return }
        guard let response, let url = response.url else { finish(.failure(EmojiPackError.network)); return }
        do {
            if response.expectedContentLength >= 0, response.value(forHTTPHeaderField: "Content-Encoding") == nil,
               response.expectedContentLength != Int64(data.count) { throw EmojiPackError.network }
            let inspection = try EmojiFontInspection.inspect(data, fileExtension: url.pathExtension, expectedSHA256: expectedSHA256)
            finish(.success(EmojiDownloadedFont(data: data, url: url, mimeType: response.mimeType ?? "", inspection: inspection)))
        } catch { finish(.failure(error)) }
    }
}
