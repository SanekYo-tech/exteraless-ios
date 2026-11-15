import ExteralessCore
import Foundation
import Postbox

/// Only the transaction-time record transition can construct this proof. It is
/// not the planned target list and does not itself execute logout or cleanup.
struct ExteralessAdmittedPanicIdentity {
    let identity: PrivacyExtrasAccountIdentity
    fileprivate init(_ identity: PrivacyExtrasAccountIdentity) { self.identity = identity }
}

func exteralessPanicRecordTransition(
    record: AccountRecord<TelegramAccountManagerTypes.Attribute>?,
    expected: PrivacyExtrasAccountIdentity
) -> (record: AccountRecord<TelegramAccountManagerTypes.Attribute>?, admission: ExteralessAdmittedPanicIdentity?) {
    guard let record, record.id.int64 == expected.recordId else { return (record, nil) }
    let backups = record.attributes.compactMap { attribute -> AccountBackupDataAttribute? in
        if case let .backupData(value) = attribute { return value }
        return nil
    }
    let environments = record.attributes.compactMap { attribute -> AccountEnvironment? in
        if case let .environment(value) = attribute { return value.environment }
        return nil
    }
    guard backups.count == 1, let peerValue = backups[0].data?.peerId, environments.count == 1 else { return (record, nil) }
    let peerId = PeerId(peerValue)
    guard peerId.namespace == Namespaces.Peer.CloudUser,
          peerId.id._internalGetInt64Value() == expected.userId,
          (environments[0] == .test) == expected.testingEnvironment else { return (record, nil) }
    let admission = ExteralessAdmittedPanicIdentity(expected)
    if record.attributes.contains(where: { if case .loggedOut = $0 { return true }; return false }) { return (record, admission) }
    return (AccountRecord(id: record.id, attributes: record.attributes + [.loggedOut(LoggedOutAccountAttribute())], temporarySessionId: nil), admission)
}

/// Shared by native post-transaction cleanup and injected effect recorders. A
/// rejected/missing record has no proof, hence none of its cleanup effects run.
func exteralessWithAdmittedPanicIdentity(_ admission: ExteralessAdmittedPanicIdentity?, _ effect: (PrivacyExtrasAccountIdentity) -> Void) {
    guard let admission else { return }
    effect(admission.identity)
}
