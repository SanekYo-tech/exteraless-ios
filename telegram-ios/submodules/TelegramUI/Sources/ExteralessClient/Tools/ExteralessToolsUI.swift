import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit

func exteralessToolsAction(_ id: String, _ title: String, detail: String? = nil,
                           enabled: Bool = true, action: @escaping () -> Void) -> PluginListRow {
    var row = PluginListRow(id: id, title: title, detail: detail)
    row.style = .accent
    row.enabled = enabled
    row.action = action
    return row
}

func exteralessToolsShare(_ url: URL, from controller: ViewController, removeOnCompletion: Bool = false) {
    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    activity.popoverPresentationController?.sourceView = controller.view
    activity.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
    activity.completionWithItemsHandler = { _, _, _, _ in
        if removeOnCompletion { exteralessToolsDiscardTemporaryFile(url) }
    }
    controller.present(activity, animated: true)
}

func exteralessToolsDiscardTemporaryFile(_ url: URL) {
    let folder = url.deletingLastPathComponent().standardizedFileURL
    let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard url.isFileURL, folder.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents == temporary.pathComponents,
          folder.lastPathComponent.hasPrefix("exteraless-tools-") || folder.lastPathComponent.hasPrefix("update-") else { return }
    try? FileManager.default.removeItem(at: folder)
}

func exteralessToolsTemporaryFile(data: Data, name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exteraless-tools-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
        let file = try ToolsFileSafety.checkedChild(name, root: directory)
        try data.write(to: file, options: .atomic)
        return file
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

/// Call on a worker. The picked URL is used only while its security scope and file
/// coordination lease are alive; a provider cannot turn a small-file check into an
/// unbounded read by growing the file after metadata was checked.
func exteralessToolsReadPickedFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var result: Result<Data, Error>?
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
        result = Result { try ToolsFileSafety.read(coordinated, maximumBytes: maximumBytes) }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw ToolsError.unavailable("The selected file could not be read.") }
    return try result.get()
}

/// Reuses the Telegram-native list/theme/layout host, with cancellable owned work.
/// A stale completion after an account switch or a second operation is discarded.
class ExteralessToolsListController: PluginListController {
    private var toolsTask: Task<Void, Never>?
    private var generation = UUID()
    private(set) var contextAvailable = true
    var toolsStatus: String?
    var toolsLoading = false
    var toolsError: String?
    var canCancelWork = true

    override var isBusy: Bool { toolsTask != nil }

    override init(context: AccountContext) {
        super.init(context: context)
        self.allowsRefresh = false
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if canCancelWork { toolsTask?.cancel() } }

    override func operationSections() -> [PluginListSection] {
        if let error = toolsError {
            var row = PluginListRow(id: "tools-error", title: "Operation failed", detail: error)
            row.style = .error
            return [PluginListSection(rows: [row])]
        }
        guard let text = toolsStatus else { return [] }
        var row = PluginListRow(id: "tools-operation", title: text)
        row.loading = toolsLoading
        var rows = [row]
        if isBusy && canCancelWork {
            rows.append(exteralessToolsAction("tools-cancel", "Cancel") { [weak self] in self?.cancelWork() })
        }
        return [PluginListSection(rows: rows)]
    }

    func runToolsOperation<Value: Sendable>(title: String, operation: @escaping () async throws -> Value,
                                  discard: ((Value) -> Void)? = nil,
                                  completion: @escaping (Value) -> Void) {
        guard !isBusy, contextAvailable else { return }
        let generation = UUID()
        self.generation = generation
        toolsStatus = title
        toolsError = nil
        toolsLoading = true
        toolsTask = Task { @MainActor [weak self] in
            guard self?.generation == generation, self?.contextAvailable == true, !Task.isCancelled else { return }
            do {
                let value = try await operation()
                guard let self, self.generation == generation, self.contextAvailable, !Task.isCancelled else { discard?(value); return }
                self.toolsTask = nil
                self.toolsLoading = false
                self.toolsStatus = nil
                completion(value)
                self.render()
            } catch {
                guard let self, self.generation == generation, self.contextAvailable else { return }
                self.toolsTask = nil
                self.toolsLoading = false
                self.toolsStatus = error is CancellationError ? "Cancelled" : nil
                self.toolsError = error is CancellationError ? nil : pluginErrorText(error)
                self.render()
                if self.isScreenVisible, let error = self.toolsError {
                    UIAccessibility.post(notification: .announcement, argument: error)
                }
            }
        }
        render()
    }

    func cancelWork() {
        guard canCancelWork else { return }
        generation = UUID()
        toolsTask?.cancel()
        toolsTask = nil
        toolsLoading = false
        toolsStatus = "Cancelled"
        render()
    }

    func clearToolsContext() {
        contextAvailable = false
        generation = UUID()
        // A filesystem commit, once begun, finishes its rollback/maintenance lease
        // even if this presentation disappears. It must not be interrupted halfway.
        if canCancelWork { toolsTask?.cancel() }
        toolsTask = nil
        toolsLoading = false
        toolsStatus = "This account context has closed."
        render()
    }
}
