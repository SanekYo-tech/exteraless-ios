import AccountContext
import AsyncDisplayKit
import AVFoundation
import Display
import ExteralessCore
import Foundation
import ImageIO
import SwiftSignalKit
import TelegramPresentationData
import TextFormat
import UIKit
import UniformTypeIdentifiers

private enum ExteralessPhotoUtilities {
    static func exportWithoutMetadata(_ data: Data) throws -> URL {
        guard data.count <= 32 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache as String: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.int64Value,
              width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 40_000_000 else {
            throw ToolsError.unavailable("Choose a single-frame photo up to 32 MiB and 40 megapixels.")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately as String: true] as CFDictionary) else {
            throw ToolsError.unavailable("This image could not be decoded.")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ToolsError.unavailable("The JPEG encoder is unavailable.")
        }
        // Add decoded pixels, not AddImageFromSource: EXIF/XMP/GPS dictionaries
        // cannot be copied accidentally. Preserve only the image orientation.
        let orientation = properties[kCGImagePropertyOrientation as String] as? NSNumber ?? NSNumber(value: 1)
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality as String: 0.95,
                                                      kCGImagePropertyOrientation as String: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ToolsError.unavailable("The cleaned photo could not be encoded.") }
        let bytes = output as Data
        guard let verify = CGImageSourceCreateWithData(bytes as CFData, nil),
              let verified = CGImageSourceCopyPropertiesAtIndex(verify, 0, nil) as? [String: Any],
              verified[kCGImagePropertyGPSDictionary as String] == nil else {
            throw ToolsError.unavailable("The photo metadata could not be removed.")
        }
        return try exteralessToolsTemporaryFile(data: bytes, name: "photo-without-metadata.jpg")
    }
}

final class ExteralessFileUtilitiesController: ExteralessToolsListController, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private enum Operation { case text, photo, inspectPhoto, video }
    private var picking: Operation?
    private var photoInfo: String?
    private weak var videoController: ExteralessToolsVideoController?

    override init(context: AccountContext) {
        super.init(context: context)
        self.title = "Files and device utilities"
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func render() {
        var sections = operationSections()
        sections.append(PluginListSection(title: "Files", rows: [
            exteralessToolsAction("video-subtitles", "Open video with subtitles…", detail: "Native local playback with .srt/.vtt sidecars",
                                  enabled: !isBusy && picking == nil && contextAvailable) { [weak self] in self?.pick(.video) },
            exteralessToolsAction("open-text", "Read text or source file…", detail: "Markdown and syntax highlighting · UTF-8 · up to 256 KiB",
                                  enabled: !isBusy && picking == nil && contextAvailable) { [weak self] in self?.pick(.text) },
            exteralessToolsAction("clean-photo", "Export photo without location metadata…", detail: "Creates a new JPEG from the image pixels at 95% quality",
                                  enabled: !isBusy && picking == nil && contextAvailable) { [weak self] in self?.pick(.photo) },
            exteralessToolsAction("inspect-photo", "Inspect photo header…", detail: "Encoder signature and GPS metadata presence",
                                  enabled: !isBusy && picking == nil && contextAvailable) { [weak self] in self?.pick(.inspectPhoto) }
        ]))
        if let photoInfo { sections.append(PluginListSection(title: "Photo inspection", rows: [PluginListRow(id: "photo-info", title: photoInfo)])) }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified).devices
        var rows = devices.map { device in
            PluginListRow(id: device.uniqueID, title: "\(device.position == .front ? "Front" : "Rear") · \(device.localizedName)",
                          detail: "Zoom \(String(format: "%.1f", device.minAvailableVideoZoomFactor))–\(String(format: "%.1f", device.maxAvailableVideoZoomFactor))× · Torch \(device.hasTorch ? "available" : "unavailable")")
        }
        if rows.isEmpty { rows.append(PluginListRow(id: "no-cameras", title: "No camera is available in this environment")) }
        rows.append(exteralessToolsAction("app-settings", "Open iOS app permissions", enabled: contextAvailable) { [weak self] in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:]) { [weak self] opened in
                if !opened { self?.toolsError = "iOS Settings could not be opened."; self?.render() }
            }
        })
        sections.append(PluginListSection(title: "Camera devices", footer: "Zoom, focus, torch and recording use Telegram's AVFoundation camera. Lens availability depends on the active format and multi-camera hardware budget.", rows: rows))
        sections.append(PluginListSection(title: "Device-specific features", rows: [
            PluginListRow(id: "glyph", title: "Nothing Glyph", detail: "Nothing's rear LED strip/matrix and Android Glyph service are not present on iPhone. iOS controls LED Flash for Alerts in Settings → Accessibility → Audio & Visual. Apps cannot configure or reproduce Glyph matrix animations through a public iOS API.")
        ]))
        setSections(sections)
    }

    private func pick(_ operation: Operation) {
        picking = operation
        let types: [UTType] = operation == .text ? [.data] : operation == .video ? [.movie] : [.image]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        picker.presentationController?.delegate = self
        present(picker, animated: true)
        render()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let operation = picking else { return }
        picking = nil
        guard urls.count == 1, let url = urls.first, contextAvailable else { render(); return }
        switch operation {
        case .video:
            do {
                let controller = try ExteralessToolsVideoController(context: self.context, videoURL: url)
                self.videoController = controller
                self.push(controller)
            } catch { toolsError = pluginErrorText(error); render() }
        case .text:
            runToolsOperation(title: "Reading text file…", operation: {
                try await Task.detached {
                    let data = try exteralessToolsReadPickedFile(url, maximumBytes: 256 * 1_024)
                    guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                        throw ToolsError.unavailable("This is not a UTF-8 text file.")
                    }
                    return text
                }.value
            }, completion: { [weak self] text in
                guard let self else { return }
                self.push(ExteralessToolsTextController(context: self.context, name: url.lastPathComponent, text: text))
            })
        case .photo:
            runToolsOperation(title: "Creating photo without metadata…", operation: {
                try await Task.detached {
                    let data = try exteralessToolsReadPickedFile(url, maximumBytes: 32 * 1_024 * 1_024)
                    return try ExteralessPhotoUtilities.exportWithoutMetadata(data)
                }.value
            }, discard: exteralessToolsDiscardTemporaryFile, completion: { [weak self] url in
                guard let self else { return }
                exteralessToolsShare(url, from: self, removeOnCompletion: true)
            })
        case .inspectPhoto:
            runToolsOperation(title: "Inspecting photo…", operation: {
                try await Task.detached {
                    let data = try exteralessToolsReadPickedFile(url, maximumBytes: 32 * 1_024 * 1_024)
                    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache as String: false] as CFDictionary),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                        throw ToolsError.unavailable("This photo format could not be inspected.")
                    }
                    let platform = ToolsJPEGPlatform.guess(header: data) ?? "unknown"
                    return "Encoder signature: \(platform) (a heuristic about the last encoder, not the camera)\nGPS metadata: \(properties[kCGImagePropertyGPSDictionary as String] == nil ? "not present in ImageIO properties" : "present")"
                }.value
            }, completion: { [weak self] result in self?.photoInfo = result })
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { picking = nil; render() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { picking = nil; render() }

    override func clearToolsContext() {
        videoController?.closePlayback()
        super.clearToolsContext()
    }
}

/// Native, read-only text inspection. No WebView, URL fetch, shell or plugin loader.
final class ExteralessToolsTextController: ViewController {
    private let context: AccountContext
    private let text: String
    private let kind: ToolsDocumentKind
    private var presentationData: PresentationData
    private var presentationDisposable: Disposable?
    private var highlightDisposable: Disposable?
    private var highlight: MessageSyntaxHighlight?
    private let textView = UITextView()

    init(context: AccountContext, name: String, text: String) {
        self.context = context
        self.text = text
        self.kind = ToolsDocumentKind.detect(name: name) ?? .plainText
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: self.presentationData))
        self.title = name
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { presentationDisposable?.dispose(); highlightDisposable?.dispose() }

    override func loadDisplayNode() {
        displayNode = ASDisplayNode()
        displayNode.view.addSubview(textView)
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.contentInsetAdjustmentBehavior = .never
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        presentationDisposable = (context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in
            self?.presentationData = data
            self?.renderText()
        })
        if case let .code(language) = kind {
            let spec = CachedMessageSyntaxHighlight.Spec(language: language, text: text)
            highlightDisposable = (asyncStanaloneSyntaxHighlight(current: nil, specs: [spec]) |> deliverOnMainQueue).start(next: { [weak self] value in
                self?.highlight = value.values[spec]
                self?.renderText()
            })
        }
        renderText()
        displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        transition.updateFrame(view: textView, frame: CGRect(origin: .zero, size: layout.size))
        var insets = layout.insets(options: [])
        insets.top = max(insets.top, navigationLayout(layout: layout).navigationFrame.maxY)
        textView.contentInset = insets
        textView.scrollIndicatorInsets = insets
    }

    private func renderText() {
        let theme = presentationData.theme
        let font = UIFont.monospacedSystemFont(ofSize: max(14, UIFont.preferredFont(forTextStyle: .body).pointSize), weight: .regular)
        let rendered: NSMutableAttributedString
        if kind == .markdown, let markdown = try? AttributedString(markdown: text) {
            rendered = NSMutableAttributedString(attributedString: NSAttributedString(markdown))
        } else { rendered = NSMutableAttributedString(string: text) }
        rendered.addAttributes([.font: font, .foregroundColor: theme.list.itemPrimaryTextColor], range: NSRange(location: 0, length: rendered.length))
        if let highlight {
            for token in highlight.entities where token.range.lowerBound >= 0 && token.range.upperBound <= rendered.length {
                rendered.addAttribute(.foregroundColor, value: UIColor(rgb: UInt32(bitPattern: token.color)),
                                      range: NSRange(location: token.range.lowerBound, length: token.range.count))
            }
        }
        textView.attributedText = rendered
        textView.backgroundColor = theme.list.blocksBackgroundColor
        textView.tintColor = theme.list.itemAccentColor
        displayNode.backgroundColor = theme.list.blocksBackgroundColor
        navigationBar?.updatePresentationData(NavigationBarPresentationData(presentationData: presentationData), transition: .immediate)
        statusBar.statusBarStyle = theme.rootController.statusBarStyle.style
    }
}
