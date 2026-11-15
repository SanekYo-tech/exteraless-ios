import AccountContext
import ExteralessCore
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

@MainActor
public final class ExteralessIdentityIntegration {
    private final class WeakPermit {
        weak var value: IdentityEditPermit?
        init(_ value: IdentityEditPermit) { self.value = value }
    }
    private var context: AccountContext?
    private var leases: [IdentityAccountId: ExteralessIdentityAccountLease] = [:]
    private var accountObjects: [IdentityAccountId: ObjectIdentifier] = [:]
    private var permits: [WeakPermit] = []
    private let accountsDisposable = MetaDisposable()
    private var foregroundObserver: NSObjectProtocol?
    private var timeObserver: NSObjectProtocol?

    public init() {
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshExpirations() }
        }
        timeObserver = NotificationCenter.default.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshExpirations() }
        }
    }

    private func refreshExpirations() {
        for lease in leases.values { lease.refreshExpiration() }
        // Calendar/date labels also need a fresh presentation after wall-time changes.
        ExteralessIdentityPresentation.shared.invalidate()
    }

    public func update(context: AccountContext) {
        if self.context === context { return }
        clearContext()
        self.context = context
        ExteralessIdentityPresentation.shared.reloadDisplayPolicy()
        ExteralessSettingsUI.registerActions([
            .init(id: "identity.account", title: "Local names and Premium appearance", section: "Identity", action: { [weak self] context, parent in
                guard let self, self.context === context else { return }
                let permit = IdentityEditPermit(account: exteralessIdentityAccountId(context.account))
                self.permits.removeAll { $0.value == nil }
                self.permits.append(WeakPermit(permit))
                parent.push(ExteralessIdentityAccountController(context: context, permit: permit))
            })
        ])
        accountsDisposable.set((context.sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self, weak context] value in
            guard let self, let context, self.context === context else { return }
            // All simultaneously alive native contexts get their own snapshot;
            // render helpers always supply the context's actual Account.
            var accounts = value.accounts.map { $0.1.account }
            if !accounts.contains(where: { $0 === context.account }) { accounts.append(context.account) }
            let identities = Set(accounts.map(exteralessIdentityAccountId))
            self.leases = self.leases.filter { identities.contains($0.key) }
            self.accountObjects = self.accountObjects.filter { identities.contains($0.key) }
            for account in accounts.prefix(IdentityPresentationCache.maximumAccounts) {
                let id = exteralessIdentityAccountId(account)
                if self.accountObjects[id] != ObjectIdentifier(account) {
                    self.leases.removeValue(forKey: id)
                    self.leases[id] = try? ExteralessIdentityAccountLease(account: account)
                    self.accountObjects[id] = ObjectIdentifier(account)
                }
            }
        }))
    }

    public func clearContext() {
        accountsDisposable.set(nil)
        for permit in permits { permit.value?.invalidate() }
        permits.removeAll()
        leases.removeAll()
        accountObjects.removeAll()
        context = nil
        ExteralessSettingsUI.unregisterActions(ids: ["identity.account"])
    }

    deinit {
        accountsDisposable.dispose()
        for permit in permits { permit.value?.invalidate() }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
    }
}
