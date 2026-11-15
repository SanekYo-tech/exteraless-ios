import ExteralessCore

/// Invoked by the ordinary automatic-download and predownload decisions. Manual
/// fetches use their existing explicit action paths and do not call this policy.
public func exteralessToolsAllowsAutomaticFileDownload(fileName: String?) -> Bool {
    ToolsAutomaticDownloadPolicy.allows(fileName: fileName,
        skipArchives: ClientSettings.shared.bool("tools.skipAutoDownloadArchives", default: true),
        skipWindowsExecutables: ClientSettings.shared.bool("tools.skipAutoDownloadExecutables", default: true))
}
