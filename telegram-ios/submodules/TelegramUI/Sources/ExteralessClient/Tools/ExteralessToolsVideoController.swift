import AccountContext
import AsyncDisplayKit
import AVFoundation
import AVKit
import Display
import ExteralessCore
import Foundation
import UIKit
import UniformTypeIdentifiers

/// A local Files video with selectable external subtitles. All playback is native
/// AVPlayer; no account/network player state or Telegram history is modified.
final class ExteralessToolsVideoController: ViewController, UIDocumentPickerDelegate {
    private let playerController = AVPlayerViewController()
    private let subtitleLabel = UILabel()
    private let videoURL: URL
    private let scoped: Bool
    private let sidecar: URL
    private var track: ToolsSubtitleTrack?
    private var timeObserver: Any?
    private var readTask: Task<Void, Never>?
    private var closed = false

    init(context: AccountContext, videoURL: URL) throws {
        guard videoURL.isFileURL else { throw ToolsError.unsafePath }
        let scoped = videoURL.startAccessingSecurityScopedResource()
        do {
            let values = try FileManager.default.attributesOfItem(atPath: videoURL.path)
            guard values[.type] as? FileAttributeType == .typeRegular else { throw ToolsError.unsafePath }
        } catch {
            if scoped { videoURL.stopAccessingSecurityScopedResource() }
            throw error
        }
        self.videoURL = videoURL
        self.scoped = scoped
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            if scoped { videoURL.stopAccessingSecurityScopedResource() }
            throw ToolsError.unavailable("Subtitle storage is unavailable.")
        }
        let directory = support.appendingPathComponent("exteraless/tools-subtitles", isDirectory: true)
        self.sidecar = directory.appendingPathComponent(ToolsSHA256.hex(Data(videoURL.absoluteString.utf8)) + ".srt")
        let presentation = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentation))
        title = videoURL.lastPathComponent
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "Subtitles", style: .plain, target: self, action: #selector(pickSubtitles)),
            UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clearSubtitles))
        ]
        playerController.player = AVPlayer(url: videoURL)
        let sidecar = self.sidecar
        readTask = Task { @MainActor [weak self] in
            let track = await Task.detached { () -> ToolsSubtitleTrack? in
                guard FileManager.default.fileExists(atPath: sidecar.path),
                      let bytes = try? ToolsFileSafety.read(sidecar, maximumBytes: ToolsSubtitleTrack.maximumBytes) else { return nil }
                return try? ToolsSubtitleTrack(data: bytes)
            }.value
            if let self, !self.closed, !Task.isCancelled { self.track = track; self.refreshSubtitles() }
        }
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        readTask?.cancel()
        if let timeObserver { playerController.player?.removeTimeObserver(timeObserver) }
        playerController.player?.pause()
        if scoped { videoURL.stopAccessingSecurityScopedResource() }
    }

    override func loadDisplayNode() {
        displayNode = ASDisplayNode()
        displayNode.backgroundColor = .black
        addChild(playerController)
        displayNode.view.addSubview(playerController.view)
        playerController.didMove(toParent: self)
        subtitleLabel.numberOfLines = 3
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .white
        subtitleLabel.backgroundColor = UIColor(white: 0, alpha: 0.75)
        subtitleLabel.font = UIFont.preferredFont(forTextStyle: .body)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.layer.cornerRadius = 8
        subtitleLabel.clipsToBounds = true
        subtitleLabel.isHidden = true
        (playerController.contentOverlayView ?? playerController.view).addSubview(subtitleLabel)
        timeObserver = playerController.player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSubtitles() }
        }
        displayNodeDidLoad()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        playerController.player?.pause()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: playerController.view, frame: CGRect(x: 0, y: top, width: layout.size.width, height: max(0, layout.size.height - top - layout.intrinsicInsets.bottom)))
        layoutSubtitles()
    }

    func closePlayback() {
        closed = true
        readTask?.cancel()
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        playerController.player?.pause()
        playerController.player?.replaceCurrentItem(with: nil)
    }

    private func layoutSubtitles() {
        let bounds = subtitleLabel.superview?.bounds ?? .zero
        let width = max(0, bounds.width - 32)
        let height = min(112, subtitleLabel.sizeThatFits(CGSize(width: width, height: 112)).height + 12)
        subtitleLabel.frame = CGRect(x: 16, y: max(0, bounds.height - height - 70), width: width, height: height)
    }

    private func refreshSubtitles() {
        guard !closed else { return }
        let text = playerController.player.flatMap { track?.text(at: $0.currentTime().seconds) }
        if subtitleLabel.text != text { subtitleLabel.text = text; layoutSubtitles() }
        subtitleLabel.isHidden = text == nil
    }

    @objc private func pickSubtitles() {
        guard !closed else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func clearSubtitles() {
        readTask?.cancel()
        do {
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
            track = nil
            refreshSubtitles()
        } catch { showError("Saved subtitles could not be removed.") }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !closed, urls.count == 1, let url = urls.first else { return }
        guard ["srt", "vtt"].contains(url.pathExtension.lowercased()) else { showError("Choose an .srt or .vtt subtitle file."); return }
        readTask?.cancel()
        let sidecar = self.sidecar
        readTask = Task { @MainActor [weak self] in
            do {
                let result = try await Task.detached {
                    let bytes = try exteralessToolsReadPickedFile(url, maximumBytes: ToolsSubtitleTrack.maximumBytes)
                    let track = try ToolsSubtitleTrack(data: bytes)
                    return (track, bytes)
                }.value
                guard let self, !self.closed, !Task.isCancelled else { return }
                try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try result.1.write(to: sidecar, options: .atomic)
                self.track = result.0
                self.refreshSubtitles()
            } catch {
                guard let self, !self.closed, !Task.isCancelled else { return }
                self.showError(pluginErrorText(error))
            }
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Subtitles", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
