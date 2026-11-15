import Foundation
import UIKit

/// Window-coordinate occlusions published by native overlays. Accounts/windows never share
/// a snapshot, and removing one overlay never removes another publisher's geometry.
@MainActor
public final class ExteralessContentOcclusions {
    public static let shared = ExteralessContentOcclusions()

    public struct Snapshot: Equatable {
        public let accountId: Int64
        public let revision: UInt64
        public let rects: [CGRect]
    }

    private final class Publication {
        let accountId: Int64
        weak var window: UIWindow?
        let rects: [CGRect]

        init(accountId: Int64, window: UIWindow, rects: [CGRect]) {
            self.accountId = accountId
            self.window = window
            self.rects = rects
        }
    }

    private final class Observer {
        let accountId: Int64
        weak var window: UIWindow?
        let updated: @MainActor (Snapshot) -> Void
        var deliveredRects: [CGRect]?

        init(accountId: Int64, window: UIWindow, updated: @escaping @MainActor (Snapshot) -> Void) {
            self.accountId = accountId
            self.window = window
            self.updated = updated
        }
    }

    private var publications: [UUID: Publication] = [:]
    private var observers: [UUID: Observer] = [:]
    private var revision: UInt64 = 0
    private var notifying = false
    private var dirty = false

    public init() {}

    public func publish(owner: UUID, accountId: Int64, window: UIWindow, rects: [CGRect]) {
        self.prune()
        let rects = Self.normalized(rects, within: window.bounds)
        guard !rects.isEmpty else { self.clear(owner: owner); return }
        if let old = self.publications[owner], old.accountId == accountId, old.window === window, old.rects == rects { return }
        self.publications[owner] = Publication(accountId: accountId, window: window, rects: rects)
        self.revision &+= 1
        self.notify()
    }

    public func clear(owner: UUID) {
        guard self.publications.removeValue(forKey: owner) != nil else { return }
        self.revision &+= 1
        self.notify()
    }

    @discardableResult
    public func subscribe(accountId: Int64, window: UIWindow, updated: @escaping @MainActor (Snapshot) -> Void) -> UUID {
        self.prune()
        let token = UUID()
        self.observers[token] = Observer(accountId: accountId, window: window, updated: updated)
        // Delivers a current (possibly empty) value even during another callback. notify's
        // deferred pass sees deliveredRects and cannot replay an older snapshot afterward.
        self.deliver(token)
        return token
    }

    public func unsubscribe(_ subscription: UUID) { self.observers.removeValue(forKey: subscription) }

    private func prune() {
        self.publications = self.publications.filter { $0.value.window != nil }
        self.observers = self.observers.filter { $0.value.window != nil }
    }

    private func notify() {
        self.dirty = true
        guard !self.notifying else { return }
        self.notifying = true
        defer { self.notifying = false }
        while self.dirty {
            self.dirty = false
            self.prune()
            for token in Array(self.observers.keys) { self.deliver(token) }
        }
    }

    private func deliver(_ token: UUID) {
        guard let observer = self.observers[token], let window = observer.window else { return }
        let rects = Self.normalized(self.publications.values.filter { $0.accountId == observer.accountId && $0.window === window }.flatMap(\.rects), within: window.bounds)
        guard observer.deliveredRects != rects else { return }
        observer.deliveredRects = rects
        observer.updated(Snapshot(accountId: observer.accountId, revision: self.revision, rects: rects))
    }

    private static func normalized(_ rects: [CGRect], within bounds: CGRect) -> [CGRect] {
        let sorted = rects.compactMap { rect -> CGRect? in
            guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return nil }
            let clipped = rect.intersection(bounds)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }.sorted { lhs, rhs in
            if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            if lhs.height != rhs.height { return lhs.height < rhs.height }
            return lhs.width < rhs.width
        }
        var result: [CGRect] = []
        for rect in sorted where result.last != rect { result.append(rect) }
        return result
    }
}
