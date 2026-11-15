import AccountContext
import CryptoKit
import ExteralessCore
import Foundation
import UIKit

func exteralessTrackingFilterURL(context: AccountContext) -> URL {
    return URL(fileURLWithPath: context.sharedContext.basePath, isDirectory: true)
        .appendingPathComponent("exteraless", isDirectory: true)
        .appendingPathComponent("adguard_url_tracking.txt")
}

func exteralessBundledTrackingFilterURL() -> URL? {
    return Bundle.main.url(forResource: "adguard_url_tracking", withExtension: "txt")
}

final class ExteralessLinkRulesController: ExteralessChatTableController {
    private var downloadTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var downloadedDigest: String?
    private let overrideURL: URL
    private let bundledURL: URL?

    init(context: AccountContext) {
        self.overrideURL = exteralessTrackingFilterURL(context: context)
        self.bundledURL = exteralessBundledTrackingFilterURL()
        super.init(context: context, title: "URL-tracking filter")
        self.accountInvalidated = { [weak self] in self?.cancelDownload() }
        self.render()
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { self.downloadTask?.cancel() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let overrideURL = self.overrideURL
        let bundledURL = self.bundledURL
        self.writeSettings({ try ChatTrackingRulesStore.shared.configure(overrideURL: overrideURL, bundledURL: bundledURL) }, completion: { [weak self] in self?.render() })
    }

    override func viewWillDisappear(_ animated: Bool) {
        self.cancelDownload()
        super.viewWillDisappear(animated)
    }

    private func cancelDownload() {
        self.generation &+= 1
        self.downloadTask?.cancel()
        self.downloadTask = nil
        if self.accountIsValid { self.render() }
    }

    private func updateFilter() {
        guard self.downloadTask == nil, self.accountIsValid else { return }
        self.generation &+= 1
        let generation = self.generation
        let destination = self.overrideURL
        self.downloadTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 15
                configuration.timeoutIntervalForResource = 30
                configuration.httpCookieStorage = nil
                configuration.urlCache = nil
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                var request = URLRequest(url: URL(string: "https://filters.adtidy.org/extension/ublock/filters/17.txt")!)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode), response.url?.scheme == "https" else { throw ChatTrackingRulesError.invalidFilter }
                guard response.expectedContentLength <= Int64(ChatAdGuardRules.maximumSourceBytes) else { throw ChatTrackingRulesError.tooLarge }
                var data = Data()
                data.reserveCapacity(192 * 1024)
                // Streaming limits the body even when Content-Length is absent or false.
                for try await byte in bytes {
                    if data.count % 1024 == 0 { try Task.checkCancellation() }
                    guard data.count < ChatAdGuardRules.maximumSourceBytes else { throw ChatTrackingRulesError.tooLarge }
                    data.append(byte)
                }
                try Task.checkCancellation()
                guard let source = String(data: data, encoding: .utf8) else { throw ChatTrackingRulesError.invalidFilter }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try ChatTrackingRulesStore.shared.install(source: source, overrideURL: destination, shouldCommit: { !Task.isCancelled })
                await MainActor.run { [weak self] in
                    guard let self, self.accountIsValid, self.generation == generation else { return }
                    self.downloadTask = nil
                    self.downloadedDigest = digest
                    self.render()
                }
            } catch {
                let message = (error as? ChatTrackingRulesError)?.errorDescription ?? "The filter couldn't be downloaded. Try again."
                await MainActor.run { [weak self] in
                    guard let self, self.accountIsValid, self.generation == generation else { return }
                    self.downloadTask = nil
                    self.render()
                    self.displayError(message)
                }
            }
        }
        self.render()
    }

    private func resetFilter() {
        self.cancelDownload()
        let overrideURL = self.overrideURL
        let bundledURL = self.bundledURL
        self.writeSettings({ try ChatTrackingRulesStore.shared.reset(overrideURL: overrideURL, bundledURL: bundledURL) }, completion: { [weak self] in
            self?.downloadedDigest = nil
            self?.render()
        })
    }

    private func render() {
        guard self.accountIsValid else { return }
        let info = ChatTrackingRulesStore.shared.snapshot()
        let source = info.isFallback ? "Built-in generic rules" : (info.isOverride ? "Updated AdGuard filter" : "Bundled AdGuard filter")
        var rows = [
            ExteralessChatRow(id: "links.filter.source", title: source, detail: info.updated.map { "Updated " + $0 }, enabled: false),
            ExteralessChatRow(id: "links.filter.count", title: "\(info.ruleCount) supported URL rules", detail: "\(info.ignoredRuleCount) non-document or unsupported rules ignored", enabled: false)
        ]
        if self.downloadTask != nil {
            rows.append(ExteralessChatRow(id: "links.filter.cancel", title: "Updating… · Cancel", action: { [weak self] in self?.cancelDownload() }))
        } else {
            rows.append(ExteralessChatRow(id: "links.filter.update", title: "Update from AdGuard", action: { [weak self] in self?.updateFilter() }))
            rows.append(ExteralessChatRow(id: "links.filter.reset", title: self.bundledURL == nil ? "Restore built-in rules" : "Restore bundled rules", action: { [weak self] in self?.resetFilter() }))
        }
        if let digest = self.downloadedDigest {
            rows.append(ExteralessChatRow(id: "links.filter.digest", title: "Downloaded SHA-256", detail: digest, action: { UIPasteboard.general.string = digest }))
        }
        self.sections = [ExteralessChatSection(footer: "AdGuard URL Tracking filter · filters.adtidy.org. Updates are explicit, bounded to 2 MiB and replace the active file only after successful parsing. Signed URLs retain their query.", rows: rows)]
        self.reloadRows()
    }
}
