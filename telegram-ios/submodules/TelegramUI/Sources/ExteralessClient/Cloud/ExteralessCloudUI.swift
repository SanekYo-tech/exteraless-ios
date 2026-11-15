import AccountContext
import Display
import ExteralessCore
import Foundation
import UIKit

func exteralessCloudAction(_ id: String, _ title: String, detail: String? = nil,
                           enabled: Bool = true, action: @escaping () -> Void) -> PluginListRow {
    var row = PluginListRow(id: id, title: title, detail: detail)
    row.style = .accent
    row.enabled = enabled
    row.action = action
    return row
}

@MainActor class ExteralessCloudListController: PluginListController {
    private var work: Task<Void, Never>?
    private var generation = UUID()
    private var writeAdmission: CloudWriteAdmission?
    private(set) var contextAvailable = true
    var operationMessage: String?
    var operationFailure: String?
    var externalBusy = false
    var allowsCancellation = true
    var cancelExternal: (() -> Void)?
    override var isBusy: Bool { work != nil || externalBusy }

    override init(context: AccountContext) {
        super.init(context: context)
        allowsRefresh = false
    }

    required init(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { writeAdmission?.revoke(); work?.cancel() }

    override func operationSections() -> [PluginListSection] {
        var rows: [PluginListRow] = []
        if let operationFailure {
            var row = PluginListRow(id: "cloud-error", title: "Operation failed", detail: operationFailure)
            row.style = .error
            rows.append(row)
        }
        if let operationMessage {
            var row = PluginListRow(id: "cloud-operation", title: operationMessage)
            row.loading = isBusy
            rows.append(row)
        }
        if isBusy && allowsCancellation && writeAdmission?.hasAdmittedWrite != true {
            rows.append(exteralessCloudAction("cloud-cancel", "Cancel") { [weak self] in self?.cancelOperation() })
        }
        return rows.isEmpty ? [] : [PluginListSection(rows: rows)]
    }

    func run<Value: Sendable>(_ title: String, operation: @escaping @MainActor () async throws -> Value,
                              completion: @escaping @MainActor (Value) -> Void) {
        runAdmitted(title, operation: { _ in try await operation() }, completion: completion)
    }

    func runWriter<Value: Sendable>(_ title: String, writer: @escaping @Sendable () throws -> Value,
                                    completion: @escaping @MainActor (Value) -> Void) {
        let identity = ObjectIdentifier(context)
        runAdmitted(title, operation: { admission in
            try await admission.perform(contextIdentity: identity, writer)
        }, completion: completion)
    }

    private func canStart(_ token: UUID, identity: ObjectIdentifier) -> Bool {
        contextAvailable && generation == token && ObjectIdentifier(context) == identity
    }

    private func runAdmitted<Value: Sendable>(_ title: String,
        operation: @escaping @MainActor (CloudWriteAdmission) async throws -> Value,
        completion: @escaping @MainActor (Value) -> Void) {
        guard !isBusy, contextAvailable else { return }
        let token = UUID()
        let identity = ObjectIdentifier(context)
        let admission = CloudWriteAdmission(contextIdentity: identity)
        writeAdmission = admission
        generation = token
        operationMessage = title
        operationFailure = nil
        work = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                guard self?.canStart(token, identity: identity) == true else { admission.revoke(); return }
                try admission.checkPending(contextIdentity: identity)
                let value = try await operation(admission)
                guard let self, self.canStart(token, identity: identity), !Task.isCancelled else { admission.revoke(); return }
                self.work = nil
                self.writeAdmission = nil
                self.allowsCancellation = true
                self.operationMessage = nil
                completion(value)
                self.render()
            } catch {
                admission.revoke()
                guard let self, self.canStart(token, identity: identity) else { return }
                self.work = nil
                self.writeAdmission = nil
                self.allowsCancellation = true
                self.operationMessage = error is CancellationError ? "Cancelled" : nil
                // Every displayed error is a fixed native domain message. A raw
                // server error or Keychain payload can never become UI text.
                self.operationFailure = error is CancellationError ? nil : ((error as? CloudError)?.errorDescription
                    ?? (error as? ClientAPIError)?.errorDescription ?? "The settings operation could not be completed.")
                self.render()
            }
        }
        render()
    }

    func cancelOperation() {
        guard allowsCancellation, writeAdmission?.hasAdmittedWrite != true else { return }
        writeAdmission?.revoke()
        writeAdmission = nil
        generation = UUID()
        work?.cancel()
        work = nil
        cancelExternal?()
        operationMessage = "Cancelled"
        render()
    }

    func clearCloudContext() {
        contextAvailable = false
        writeAdmission?.revoke()
        writeAdmission = nil
        generation = UUID()
        work?.cancel()
        work = nil
        if let alert = presentedViewController as? UIAlertController { alert.dismiss(animated: false) }
        operationMessage = "This account context has closed."
        operationFailure = nil
        render()
    }
}
