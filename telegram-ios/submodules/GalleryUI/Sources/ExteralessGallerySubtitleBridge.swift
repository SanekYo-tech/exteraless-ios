import Display
import ExteralessCore
import Foundation
import UIKit

/// Gallery owns playback and layout; the application supplies the picker/sidecar UI.
/// Disposed controls release their adapter and reject queued menu callbacks.
@MainActor public final class ExteralessGallerySubtitleControls {
    private struct Actions {
        let update: (ToolsSubtitlePlaybackSample?) -> Void
        let visible: (Bool) -> Void
        let layout: (CGRect, CGFloat, ContainedViewLayoutTransition) -> Void
        let select: (UIViewController) -> Void
        let clear: (UIViewController) -> Void
        let dispose: () -> Void
    }

    private var actions: Actions?
    public var isDisposed: Bool { self.actions == nil }

    public init(update: @escaping (ToolsSubtitlePlaybackSample?) -> Void,
                visible: @escaping (Bool) -> Void,
                layout: @escaping (CGRect, CGFloat, ContainedViewLayoutTransition) -> Void,
                select: @escaping (UIViewController) -> Void,
                clear: @escaping (UIViewController) -> Void,
                dispose: @escaping () -> Void) {
        self.actions = Actions(update: update, visible: visible, layout: layout,
                               select: select, clear: clear, dispose: dispose)
    }

    public func update(_ sample: ToolsSubtitlePlaybackSample?) { self.actions?.update(sample) }
    public func visible(_ value: Bool) { self.actions?.visible(value) }
    public func layout(_ bounds: CGRect, _ bottomInset: CGFloat, _ transition: ContainedViewLayoutTransition) {
        self.actions?.layout(bounds, bottomInset, transition)
    }
    public func select(_ presenter: UIViewController) { self.actions?.select(presenter) }
    public func clear(_ presenter: UIViewController) { self.actions?.clear(presenter) }

    public func dispose() {
        let actions = self.actions
        self.actions = nil
        actions?.dispose()
    }
}

/// A single active application context, with a token so delayed teardown cannot
/// clear a newer registration. Neither this bridge nor its API imports TelegramUI.
@MainActor public enum ExteralessGallerySubtitleBridge {
    private final class WeakControls {
        weak var value: ExteralessGallerySubtitleControls?
        init(_ value: ExteralessGallerySubtitleControls) { self.value = value }
    }

    private struct Registration {
        let token: UUID
        let accountId: Int64
        let contextIdentity: ObjectIdentifier
        let make: (String, UIView) -> ExteralessGallerySubtitleControls
    }

    private static var registration: Registration?
    private static var controls: [WeakControls] = []

    /// The context identity is captured from the real AccountContext by both sides.
    public static func register(accountId: Int64, contextIdentity: ObjectIdentifier,
                                make: @escaping (String, UIView) -> ExteralessGallerySubtitleControls) -> UUID {
        if let current = self.registration { self.unregister(current.token) }
        let token = UUID()
        self.registration = Registration(token: token, accountId: accountId,
                                         contextIdentity: contextIdentity, make: make)
        return token
    }

    public static func isRegistered(_ token: UUID) -> Bool {
        return self.registration?.token == token
    }

    /// Revokes existing nodes as well as the factory, including their open pickers.
    public static func unregister(_ token: UUID) {
        guard self.registration?.token == token else { return }
        self.registration = nil
        let controls = self.controls
        self.controls.removeAll()
        for control in controls { control.value?.dispose() }
    }

    public static func make(accountId: Int64, contextIdentity: ObjectIdentifier,
                            identity: String, container: UIView) -> ExteralessGallerySubtitleControls? {
        guard let registration = self.registration, registration.accountId == accountId,
              registration.contextIdentity == contextIdentity else { return nil }
        self.controls.removeAll { $0.value == nil || $0.value?.isDisposed == true }
        let controls = registration.make(identity, container)
        self.controls.append(WeakControls(controls))
        return controls
    }
}
