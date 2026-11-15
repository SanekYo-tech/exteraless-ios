import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ToolsDownloadedUpdate: Equatable, Sendable {
    public let url: URL
    public let sha256: String
    public let size: Int64
}

/// Public GitHub Releases only. This client never authenticates, installs, signs,
/// publishes a release, or executes an asset. The caller owns the downloaded IPA.
public final class ToolsReleaseClient: @unchecked Sendable {
    public let repository: ToolsReleaseRepository
    private let configuration: URLSessionConfiguration
    public static let maximumAssetBytes: Int64 = 1_024 * 1_024 * 1_024

    public init(repository: ToolsReleaseRepository = .application, configuration: URLSessionConfiguration = .ephemeral) {
        self.repository = repository
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 900
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = nil
        configuration.urlCache = nil
        self.configuration = configuration
    }

    public func latest(includePrereleases: Bool) async throws -> ToolsGitHubRelease? {
        let request = Self.request(repository.apiURL, json: true)
        let transfer = ToolsReleaseTransfer(configuration: configuration, maximumBytes: 2 * 1_024 * 1_024)
        let result = try await transfer.run(request)
        return try Self.decodeReleases(result.data, repository: repository, includePrereleases: includePrereleases)
    }

    public func download(_ release: ToolsGitHubRelease, directory: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> ToolsDownloadedUpdate {
        let asset = release.asset
        guard repository.acceptsAssetURL(asset.url), ToolsFileSafety.isComponent(asset.name),
              asset.name.utf8.count <= 200, asset.name.lowercased().hasSuffix(".ipa"),
              asset.size > 0, asset.size <= Self.maximumAssetBytes else { throw ToolsError.invalidRelease }
        guard let checksum = asset.sha256 else {
            throw ToolsError.unavailable("GitHub did not publish a SHA-256 checksum for this IPA. Open the release page for its manual distribution instructions.")
        }
        let folder = try ToolsFileSafety.checkedChild("update-" + UUID().uuidString, root: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let partial = try ToolsFileSafety.checkedChild(asset.name + ".partial", root: folder)
        let complete = try ToolsFileSafety.checkedChild(asset.name, root: folder)
        do {
            let transfer = ToolsReleaseTransfer(configuration: configuration, maximumBytes: asset.size,
                                                output: partial, expectedSize: asset.size, progress: progress)
            let result = try await transfer.run(Self.request(asset.url, json: false))
            try Task.checkCancellation()
            guard result.count == asset.size else { throw ToolsError.incompleteDownload }
            guard result.digest == checksum else { throw ToolsError.checksumMismatch }
            guard result.data.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]) else { throw ToolsError.invalidRelease }
            try FileManager.default.moveItem(at: partial, to: complete)
            return ToolsDownloadedUpdate(url: complete, sha256: result.digest, size: result.count)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func request(_ url: URL, json: Bool) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("exteraless-ios-updater", forHTTPHeaderField: "User-Agent")
        request.setValue(json ? "application/vnd.github+json" : "application/octet-stream", forHTTPHeaderField: "Accept")
        if json { request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        return request
    }

    public static func decodeReleases(_ data: Data, repository: ToolsReleaseRepository,
                                      includePrereleases: Bool) throws -> ToolsGitHubRelease? {
        try ToolsFileSafety.checkJSON(data, maximumBytes: 2 * 1_024 * 1_024)
        let releases: [ReleaseDTO]
        do { releases = try JSONDecoder().decode([ReleaseDTO].self, from: data) }
        catch { throw ToolsError.unavailable("GitHub returned an invalid Releases response.") }
        guard releases.count <= 100 else { throw ToolsError.sizeLimit }
        for release in releases where !release.draft && (!release.prerelease || includePrereleases) {
            guard release.tag_name.utf8.count <= 200, release.assets.count <= 100 else { continue }
            let assets = release.assets.filter { asset in
                let name = asset.name.lowercased()
                return name.hasSuffix(".ipa") && !name.contains("simulator") && !name.contains("x86")
                    && ToolsFileSafety.isComponent(asset.name) && asset.name.utf8.count <= 200
                    && asset.size > 0 && asset.size <= maximumAssetBytes && repository.acceptsAssetURL(asset.browser_download_url)
            }.sorted { lhs, rhs in
                let l = lhs.name.lowercased().contains("arm64"), r = rhs.name.lowercased().contains("arm64")
                return l == r ? lhs.name < rhs.name : l
            }
            guard let asset = assets.first else { continue }
            let digest: String?
            if let value = asset.digest, value.hasPrefix("sha256:") {
                let hex = String(value.dropFirst(7)).lowercased()
                digest = hex.count == 64 && hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) ? hex : nil
            } else { digest = nil }
            let releaseURL = repository.releasesURL.appendingPathComponent("tag").appendingPathComponent(release.tag_name)
            return .init(id: release.id, tag: release.tag_name, name: String((release.name ?? release.tag_name).prefix(300)),
                         notes: String((release.body ?? "").prefix(32_768)), prerelease: release.prerelease,
                         releaseURL: releaseURL, asset: .init(name: asset.name, url: asset.browser_download_url, size: asset.size, sha256: digest),
                         version: ToolsReleaseVersion(tag: release.tag_name))
        }
        return nil
    }

    private struct ReleaseDTO: Decodable {
        let id: Int64
        let tag_name: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [AssetDTO]
    }

    private struct AssetDTO: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int64
        let digest: String?
    }
}

/// A serial delegate streams into a private partial file (or bounded metadata
/// memory). Cancellation works while waiting for headers as well as during data.
private final class ToolsReleaseTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result: Sendable { let data: Data; let count: Int64; let digest: String }
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int64
    private let output: URL?
    private let expectedSize: Int64?
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    // The remaining fields are confined to the serial URLSession delegate queue.
    private var continuation: CheckedContinuation<Result, Error>?
    private var handle: FileHandle?
    private var data = Data()
    private var count: Int64 = 0
    private var contentHash = ToolsSHA256()
    private var failure: Error?
    private var previousPercent = -1

    init(configuration: URLSessionConfiguration, maximumBytes: Int64, output: URL? = nil,
         expectedSize: Int64? = nil, progress: (@Sendable (Int64, Int64) -> Void)? = nil) {
        self.configuration = configuration
        self.maximumBytes = maximumBytes
        self.output = output
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws -> Result {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: { self.cancel() })
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        task?.cancel()
        // Do not depend on a provider/delegate sending another event to release
        // the caller. The serial delegate still closes its file on completion.
        continuation?.resume(throwing: CancellationError())
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"].contains(url.host?.lowercased() ?? "") else {
            failure = ToolsError.invalidRelease
            completionHandler(nil)
            task.cancel()
            return
        }
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = ToolsError.invalidRelease
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
                failure = ToolsError.rateLimited
            } else if http.statusCode == 404 {
                failure = ToolsError.unavailable("This repository or asset is not publicly available. The updater cannot access private releases.")
            } else { failure = ToolsError.http(http.statusCode) }
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= maximumBytes else {
            failure = ToolsError.sizeLimit
            completionHandler(.cancel)
            return
        }
        if let expectedSize, response.expectedContentLength > 0, response.expectedContentLength != expectedSize {
            failure = ToolsError.incompleteDownload
            completionHandler(.cancel)
            return
        }
        if let output {
            do {
                guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw ToolsError.unavailable("Could not create the update file.")
                }
                handle = try FileHandle(forWritingTo: output)
            } catch {
                failure = error
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        guard Int64(chunk.count) <= maximumBytes - count else {
            failure = ToolsError.sizeLimit
            dataTask.cancel()
            return
        }
        do {
            if let handle {
                try handle.write(contentsOf: chunk)
                if data.count < 4 { data.append(chunk.prefix(4 - data.count)) }
            } else { data.append(chunk) }
            count += Int64(chunk.count)
            contentHash.update(chunk)
            if let expectedSize, expectedSize > 0 {
                let percent = Int(count * 100 / expectedSize)
                if percent != previousPercent {
                    previousPercent = percent
                    progress?(count, expectedSize)
                }
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try handle?.synchronize(); try handle?.close() }
        catch { if failure == nil { failure = error } }
        handle = nil
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let wasCancelled = cancelled
        self.task = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let failure { continuation?.resume(throwing: failure) }
        else if let error { continuation?.resume(throwing: error) }
        else if let expectedSize, count != expectedSize { continuation?.resume(throwing: ToolsError.incompleteDownload) }
        else { continuation?.resume(returning: Result(data: data, count: count, digest: contentHash.hexDigest())) }
    }
}
