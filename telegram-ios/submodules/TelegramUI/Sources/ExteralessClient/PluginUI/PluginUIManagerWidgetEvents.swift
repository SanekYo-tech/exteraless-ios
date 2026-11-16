import Foundation
import PluginHost

/// Bounded owner-worker event admission for inline controls. Enqueuing a change
/// updates the local UIKit value; it does not rebuild Python settings per keystroke.
@MainActor final class PluginUIManagerWidgetEvents {
    let lease: PluginSettingsPageLease
    private let actions: PluginManagerActions
    private let failure: (String) -> Void
    private let fifo = PluginUIManagerEventFIFO()

    init(lease: PluginSettingsPageLease, actions: PluginManagerActions, failure: @escaping (String) -> Void) {
        self.lease = lease
        self.actions = actions
        self.failure = failure
    }

    @discardableResult
    func send(callbackId: String, eventJSON: String, invocation: PluginUISettingsActionInvocation) -> Bool {
        do {
            _ = try self.enqueue(callbackId: callbackId, eventJSON: eventJSON, invocation: invocation, reportFailure: true)
            return true
        } catch {
            if self.lease.isOpen, invocation.isCurrent { self.failure(pluginErrorText(error)) }
            return false
        }
    }

    /// Enqueue synchronously at the tap, BEFORE the controller creates its Task.
    /// nil is a navigation-only root barrier and does not invoke Python.
    func root(callbackId: String?, invocation: PluginUISettingsActionInvocation) throws -> PluginUIManagerEventReceipt {
        let json = try callbackId.map { try PluginUIJSON.object(["kind": .string("click"), "callbackId": .string($0)]).encoded() }
        return try self.enqueue(callbackId: callbackId, eventJSON: json, invocation: invocation, reportFailure: false)
    }

    private func enqueue(callbackId: String?, eventJSON: String?, invocation: PluginUISettingsActionInvocation,
                         reportFailure: Bool) throws -> PluginUIManagerEventReceipt {
        let lease = self.lease
        let actions = self.actions
        guard invocation.owner == lease.owner, invocation.account == lease.account else {
            throw PluginUIFailure.invalidHandle("Custom event belongs to another page owner/account")
        }
        return try self.fifo.enqueue(bytes: eventJSON?.utf8.count ?? 2,
            isCurrent: { lease.isOpen && invocation.isCurrent }, cancel: { invocation.cancel() }, operation: {
                try await PluginUISettingsActionExecution.withInvocation(invocation) {
                    guard let callbackId else { return }
                    try await PluginSettingsPageExecution.$current.withValue(lease) {
                        try await PluginSettingsPageExecution.$widgetEventJSON.withValue(eventJSON) {
                            try await actions.click(lease.owner.pluginId, callbackId)
                        }
                    }
                }
            }, failed: { [weak self] error in
                if reportFailure, lease.isOpen, invocation.isCurrent { self?.failure(pluginErrorText(error)) }
            })
    }

    func cancel() { self.fifo.close() }
}
