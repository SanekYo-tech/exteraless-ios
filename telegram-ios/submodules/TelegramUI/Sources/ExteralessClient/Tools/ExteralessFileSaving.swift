import AccountContext
import Display
import ExteralessCore
import Foundation
import OverlayStatusController
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import UIKit
import UniformTypeIdentifiers

@MainActor final class ExteralessToolsFileSaveService {
    static let shared = ExteralessToolsFileSaveService()
    private let secrets: any ClientSecretStore = ClientKeychainSecretStore(service: "exteraless.tools.file-destinations")
    private let bookmarkKey = "selected-folder"

    func hasDestination() throws -> Bool { try secrets.data(for: bookmarkKey) != nil }
    func destinationName() throws -> String? { try destination()?.lastPathComponent }
    func forget() throws { try secrets.set(nil, for: bookmarkKey) }

    func select(_ url: URL) throws {
        guard url.isFileURL else { throw ToolsError.unsafePath }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ToolsError.unsafePath }
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        guard data.count <= 65_536 else { throw ToolsError.sizeLimit }
        try secrets.set(data, for: bookmarkKey)
    }

    private func destination() throws -> URL? {
        guard let data = try secrets.data(for: bookmarkKey) else { return nil }
        guard data.count <= 65_536 else { throw ToolsError.unsafePath }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL else { throw ToolsError.unsafePath }
        if stale { try select(url) }
        return url
    }

    func save(source: URL, name: String, accountId: Int64, chatId: Int64?) async throws -> URL {
        guard let destination = try destination() else { throw ToolsError.unavailable("Choose a Files destination first.") }
        let components = try ToolsSavePathPolicy.components(customFolder: ClientSettings.shared.string("tools.customSavePath", default: "exteraless"),
            perChat: ClientSettings.shared.bool("tools.saveToChatSubfolder"), accountId: accountId, chatId: chatId)
        let task = Task.detached(priority: .userInitiated) {
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<URL, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: .forMerging, error: &coordinationError) { coordinated in
                result = Result { try ToolsLocalFileSaver.copy(source: source, destination: coordinated, components: components, name: name) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw ToolsError.unavailable("The Files provider did not grant coordinated access.") }
            return try result.get()
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

@MainActor func exteralessToolsSaveNotice(context: AccountContext, message: String, present: (ViewController, Any?) -> Void) {
    weak var weakController: ViewController?
    let controller = textAlertController(context: context, title: "Files", text: message, actions: [
        TextAlertAction(type: .defaultAction, title: "OK", action: { weakController?.dismiss() })
    ])
    weakController = controller
    present(controller, nil)
}

/// Called only after the ordinary Telegram downloader produced a complete local
/// resource and its caller already applied copy-protection/account checks.
@MainActor func exteralessToolsSaveDownloaded(context: AccountContext, source: URL, file: FileMediaReference,
                                             present: @escaping (ViewController, Any?) -> Void) -> Disposable? {
    let service = ExteralessToolsFileSaveService.shared
    do { guard try service.hasDestination() else { return nil } }
    catch { exteralessToolsSaveNotice(context: context, message: pluginErrorText(error), present: present); return EmptyDisposable }
    let chatId: Int64?
    if case let .message(message, _) = file { chatId = message.id?.peerId.toInt64() } else { chatId = nil }
    let name = file.media.fileName ?? "document-\(file.media.fileId.id)"
    var task: Task<Void, Never>?
    let data = context.sharedContext.currentPresentationData.with { $0 }
    let progress = OverlayStatusController(theme: data.theme, type: .loading(cancelled: { task?.cancel() }))
    task = Task { @MainActor in
        do {
            let saved = try await service.save(source: source, name: name, accountId: context.account.id.int64, chatId: chatId)
            progress.dismiss()
            if !Task.isCancelled { exteralessToolsSaveNotice(context: context, message: "Saved \(saved.lastPathComponent).", present: present) }
        } catch {
            progress.dismiss()
            if !Task.isCancelled { exteralessToolsSaveNotice(context: context, message: pluginErrorText(error), present: present) }
        }
    }
    present(progress, nil)
    return ActionDisposable { task?.cancel(); DispatchQueue.main.async { progress.dismiss() } }
}

final class ExteralessFileSavingController: ExteralessToolsListController, UIDocumentPickerDelegate {
    override init(context: AccountContext) { super.init(context: context); title = "Files destination" }
    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func render() {
        var sections = operationSections()
        let name: String
        do { name = try ExteralessToolsFileSaveService.shared.destinationName() ?? "Ask each time (native Files picker)" }
        catch { name = "Saved destination unavailable"; toolsError = pluginErrorText(error) }
        sections.append(PluginListSection(footer: "The folder permission bookmark stays in Keychain and is not exported. Custom folder and per-chat options apply when Telegram's Save to Files is used; existing files receive a numbered suffix.", rows: [
            PluginListRow(id: "folder", title: name),
            exteralessToolsAction("choose-folder", "Choose destination folder…", enabled: contextAvailable) { [weak self] in
                guard let self else { return }
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
                picker.allowsMultipleSelection = false
                picker.delegate = self
                self.present(picker, animated: true)
            },
            exteralessToolsAction("forget-folder", "Ask where to save each time", enabled: contextAvailable) { [weak self] in
                do { try ExteralessToolsFileSaveService.shared.forget(); self?.toolsStatus = "Native Files picker restored." }
                catch { self?.toolsError = pluginErrorText(error) }
                self?.render()
            }
        ]))
        setSections(sections)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard urls.count == 1, let url = urls.first, contextAvailable else { return }
        do { try ExteralessToolsFileSaveService.shared.select(url); toolsError = nil; toolsStatus = "Destination saved." }
        catch { toolsError = pluginErrorText(error) }
        render()
    }
}
