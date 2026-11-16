import Display
import ExteralessCore
import Foundation
import SwiftSignalKit

/// SettingsUI cannot import TelegramUI. The installed provider owns all native
/// factories and current-context checks; this seam contains no account storage.
@MainActor
public protocol ExteralessSettingsSearchProvider: AnyObject {
    func retire()
    func makeRoot(context: AccountContext, settings: ClientSettings?) -> ViewController?
    func prepare(request: Result<ClientSettingsRouteRequest, ClientSettingsRouteError>, context: AccountContext) -> ExteralessSettingsSearchOpen?
    func items(context: AccountContext) -> [ClientSettingsSearchItem]
    func open(ticket: ClientSettingsSearchTicket, context: AccountContext, from: ViewController) -> Bool
    func open(request: ClientSettingsRouteRequest, context: AccountContext, from: ViewController) -> Bool
    func link(ticket: ClientSettingsSearchTicket, context: AccountContext) -> URL?
    func show(error: ClientSettingsRouteError, context: AccountContext, from: ViewController)
}

/// One explicit URL operation. Preparation captures a concrete provider and
/// selection before waiting; starting it cannot look up a replacement provider.
/// The provider owns cancellation and enforces the same 30-second unlock bound.
@MainActor
public final class ExteralessSettingsSearchOpen {
    private var startImpl: (@MainActor (Signal<Bool, NoError>, @escaping @MainActor () -> ViewController?) -> Void)?

    public init(start: @escaping @MainActor (Signal<Bool, NoError>, @escaping @MainActor () -> ViewController?) -> Void) {
        self.startImpl = start
    }

    public func start(whenUnlocked: Signal<Bool, NoError>, from: @escaping @MainActor () -> ViewController?) {
        guard let start = startImpl else { return }
        startImpl = nil
        start(whenUnlocked, from)
    }
}

@MainActor
public enum ExteralessSettingsSearchEntry {
    private static weak var provider: (any ExteralessSettingsSearchProvider)?
    private static var generation: UInt64 = 0
    private static let changed = ValuePromise<UInt64>(0, ignoreRepeated: true)

    public static var updates: Signal<UInt64, NoError> { changed.get() }

    public static func install(_ provider: (any ExteralessSettingsSearchProvider)?) {
        if let previous = self.provider {
            if let provider, previous === provider { return }
            previous.retire()
        }
        self.provider = provider
        notifyChanged()
    }

    public static func makeRoot(context: AccountContext, settings: ClientSettings? = nil) -> ViewController? {
        provider?.makeRoot(context: context, settings: settings)
    }

    /// Call before dismissing input or subscribing to readiness. Recognized
    /// malformed links become a typed local error; their raw query is not retained.
    public static func prepare(url: URL, context: AccountContext) -> ExteralessSettingsSearchOpen? {
        do {
            guard let request = try ClientSettingsLink.parseURL(url) else { return nil }
            return provider?.prepare(request: .success(request), context: context)
        } catch {
            return provider?.prepare(request: .failure((error as? ClientSettingsRouteError) ?? .invalidLink), context: context)
        }
    }

    public static func notifyChanged() {
        generation &+= 1
        changed.set(generation)
    }

    public static func items(context: AccountContext) -> [ClientSettingsSearchItem] {
        provider?.items(context: context) ?? []
    }

    @discardableResult
    public static func open(ticket: ClientSettingsSearchTicket, context: AccountContext, from: ViewController) -> Bool {
        provider?.open(ticket: ticket, context: context, from: from) ?? false
    }

    public static func link(ticket: ClientSettingsSearchTicket, context: AccountContext) -> URL? {
        provider?.link(ticket: ticket, context: context)
    }

    nonisolated public static func recognizes(_ url: URL) -> Bool {
        do { return try ClientSettingsLink.parseURL(url) != nil }
        catch { return true } // malformed, but already recognized as our namespace
    }

    /// A recognized route is consumed even if no account/provider is ready.
    /// Nothing in an unavailable client link is handed to URL/network resolution.
    @discardableResult
    public static func handle(url: URL, context: AccountContext, from: ViewController) -> Bool {
        do {
            guard let request = try ClientSettingsLink.parseURL(url) else { return false }
            _ = provider?.open(request: request, context: context, from: from)
        } catch {
            provider?.show(error: (error as? ClientSettingsRouteError) ?? .invalidLink, context: context, from: from)
        }
        return true
    }

    @discardableResult
    public static func handle(path: String, context: AccountContext, from: ViewController) -> Bool {
        do {
            guard let request = try ClientSettingsLink.parsePath(path) else { return false }
            _ = provider?.open(request: request, context: context, from: from)
        } catch {
            provider?.show(error: (error as? ClientSettingsRouteError) ?? .invalidLink, context: context, from: from)
        }
        return true
    }
}
