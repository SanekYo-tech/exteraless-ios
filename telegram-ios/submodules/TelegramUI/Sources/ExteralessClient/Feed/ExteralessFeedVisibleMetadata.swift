import Foundation
import TelegramCore

protocol ExteralessFeedMetadataLease: AnyObject {
    func update(messages: [EngineMessage])
    func dispose()
}

extension ExteralessFeedVisibleMetadataLease: ExteralessFeedMetadataLease {}

/// Independent of page completion. One lease survives visible-set changes and removes only
/// the IDs that left; native AccountViewTracker owns poll deadlines/webpage producer lifetime.
@MainActor
final class ExteralessFeedVisibleMetadata {
    private let makeLease: () -> ExteralessFeedMetadataLease
    private var lease: ExteralessFeedMetadataLease?
    private var signature: [EngineMessage.Id: UUID] = [:]

    init(makeLease: @escaping () -> ExteralessFeedMetadataLease) { self.makeLease = makeLease }

    func update(projections: [ExteralessFeedMessageProjection], active: Bool) {
        var seen = Set<EngineMessage.Id>()
        let visible = Array(projections.filter { $0.isEligible && seen.insert($0.message.id).inserted }.prefix(32))
        guard active, !visible.isEmpty else { self.stop(); return }
        let signature = Dictionary(uniqueKeysWithValues: visible.map { ($0.message.id, $0.renderToken) })
        guard signature != self.signature else { return }
        self.signature = signature
        if self.lease == nil { self.lease = self.makeLease() }
        self.lease?.update(messages: visible.map(\.message))
    }

    func stop() {
        self.lease?.dispose()
        self.lease = nil
        self.signature.removeAll()
    }

    deinit { self.lease?.dispose() }
}
