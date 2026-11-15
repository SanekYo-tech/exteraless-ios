import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit

final class ExteralessUpdateController: ExteralessToolsListController {
    private let client: ToolsReleaseClient
    private var release: ToolsGitHubRelease?
    private var downloaded: ToolsDownloadedUpdate?
    private var hasChecked = false
    private var downloadGeneration = UUID()
    private var downloadProgress: (Int64, Int64)?
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let installedVersion: String
    private let installedBuild: String
    private let onChecked: (ToolsGitHubRelease?) -> Void
    private let onSkip: (String) -> Void

    init(context: AccountContext, client: ToolsReleaseClient, cachedRelease: ToolsGitHubRelease? = nil, lastError: String? = nil,
         onChecked: @escaping (ToolsGitHubRelease?) -> Void, onSkip: @escaping (String) -> Void) {
        self.client = client
        self.onChecked = onChecked
        self.onSkip = onSkip
        self.release = cachedRelease
        self.hasChecked = cachedRelease != nil || lastError != nil
        self.installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        self.installedBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        super.init(context: context)
        self.title = "Updates"
        self.toolsError = lastError
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let downloaded { try? FileManager.default.removeItem(at: downloaded.url.deletingLastPathComponent()) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasChecked && !isBusy { check() }
    }

    override func render() {
        var sections = operationSections()
        sections.append(PluginListSection(title: "Installed version", rows: [
            PluginListRow(id: "installed", title: installedVersion, detail: "Build \(installedBuild)")
        ]))
        if let downloaded {
            sections.append(PluginListSection(title: "Ready for manual signing", footer:
                "Export this IPA to your iOS signing tool (for example, AltStore or Sideloadly). Sign and install it there using your own Apple account. Keep the same app bundle identifier to preserve its data. Downloading an IPA does not install it.", rows: [
                    PluginListRow(id: "verified", title: "Downloaded and SHA-256 verified", detail: downloaded.sha256),
                    exteralessToolsAction("share-ipa", "Export IPA…", enabled: contextAvailable) { [weak self] in
                        guard let self else { return }
                        exteralessToolsShare(downloaded.url, from: self)
                    }
                ]))
        } else if let release {
            let comparison = release.version.flatMap { version in
                ToolsReleaseVersion(tag: installedVersion, buildNumber: installedBuild).map { version.compared(to: $0) }
            } ?? .unknown
            let status: String
            switch comparison {
            case .newer: status = "A newer release is available"
            case .notNewer: status = "This release is not newer than your installed build"
            case .unknown: status = "Version/build comparison unavailable — review the release before downloading"
            }
            var rows = [PluginListRow(id: "release", title: release.name, detail: "\(release.tag) · \(status)")]
            if let progress = downloadProgress, isBusy {
                rows.append(PluginListRow(id: "bytes", title: "\(Int(progress.0 * 100 / max(1, progress.1)))%",
                                          detail: "\(ByteCountFormatter.string(fromByteCount: progress.0, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: progress.1, countStyle: .file))"))
            } else if release.asset.sha256 != nil {
                rows.append(exteralessToolsAction("download", "Download IPA…", detail: ByteCountFormatter.string(fromByteCount: release.asset.size, countStyle: .file),
                                                   enabled: !isBusy && contextAvailable) { [weak self] in self?.download(release) })
            }
            let footer = release.asset.sha256 == nil
                ? "This asset has no GitHub SHA-256 digest. Open the release page for its manual distribution instructions."
                : "The downloaded IPA is verified against the digest supplied by GitHub Releases. Signing happens outside the app."
            sections.append(PluginListSection(title: "GitHub release", footer: footer, rows: rows))
            if !release.notes.isEmpty {
                sections.append(PluginListSection(title: "Release notes", rows: [PluginListRow(id: "notes", title: release.notes)]))
            }
            if comparison == .newer {
                let skipped = UserDefaults.standard.string(forKey: "ExteralessToolsSkippedUpdate") == release.tag
                sections.append(PluginListSection(rows: [exteralessToolsAction("skip-version", skipped ? "Show this version in update notices" : "Skip this version in update notices", enabled: !isBusy && contextAvailable) { [weak self] in
                    guard let self else { return }
                    self.onSkip(skipped ? "" : release.tag)
                    self.render()
                }]))
            }
        } else if hasChecked && !isBusy && toolsError == nil {
            sections.append(PluginListSection(rows: [PluginListRow(id: "none", title: "No public iOS IPA release found for this channel")]))
        }
        sections.append(PluginListSection(rows: [
            exteralessToolsAction("check", "Check again", enabled: !isBusy && contextAvailable) { [weak self] in self?.check() },
            exteralessToolsAction("release-page", "Open GitHub Releases", enabled: contextAvailable) { [weak self] in self?.openReleasePage() }
        ]))
        setSections(sections)
        if let progress = downloadProgress, isBusy {
            let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 12))
            progressView.frame = CGRect(x: 20, y: 5, width: max(0, tableView.bounds.width - 40), height: 2)
            progressView.progressTintColor = presentationData.theme.list.itemAccentColor
            progressView.progress = Float(progress.0) / Float(max(1, progress.1))
            progressView.accessibilityLabel = "IPA download progress"
            header.addSubview(progressView)
            tableView.tableHeaderView = header
        } else { tableView.tableHeaderView = nil }
    }

    override func cancelWork() {
        downloadGeneration = UUID()
        downloadProgress = nil
        super.cancelWork()
    }

    private func check() {
        let client = client
        let prereleases = ClientSettings.shared.integer("tools.autoUpdateChannel") == 2
        UserDefaults.standard.set(Date(), forKey: "ExteralessToolsLastUpdateAttempt")
        runToolsOperation(title: "Checking public GitHub Releases…", operation: {
            try await client.latest(includePrereleases: prereleases)
        }, completion: { [weak self] release in
            guard let self else { return }
            self.hasChecked = true
            self.release = release
            self.downloadProgress = nil
            if let old = self.downloaded { try? FileManager.default.removeItem(at: old.url.deletingLastPathComponent()) }
            self.downloaded = nil
            self.onChecked(release)
        })
    }

    private func download(_ release: ToolsGitHubRelease) {
        let client = client
        let generation = UUID()
        downloadGeneration = generation
        downloadProgress = (0, release.asset.size)
        runToolsOperation(title: "Downloading IPA…", operation: { [weak self] in
            try await client.download(release, directory: FileManager.default.temporaryDirectory) { [weak self] done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadGeneration == generation, self.contextAvailable, self.isBusy else { return }
                    self.downloadProgress = (done, total)
                    self.render()
                }
            }
        }, discard: { exteralessToolsDiscardTemporaryFile($0.url) }, completion: { [weak self] downloaded in
            self?.downloaded = downloaded
            self?.downloadProgress = nil
        })
    }

    private func openReleasePage() {
        UIApplication.shared.open(release?.releaseURL ?? client.repository.releasesURL, options: [:]) { [weak self] opened in
            if !opened {
                self?.toolsError = "The release page could not be opened."
                self?.render()
            }
        }
    }
}
