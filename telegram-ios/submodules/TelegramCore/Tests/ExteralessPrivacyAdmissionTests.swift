import Foundation
import ExteralessCore
import MtProtoKit
import Postbox
import SwiftSignalKit
import TelegramApi
import XCTest
@testable import TelegramCore

/// Actual typed read adapter + admission ledger, with a held Signal prefix and a
/// synthetic transport. No Account/Network construction, RPC or plugin execution.
final class ExteralessPrivacyAdmissionTests: XCTestCase {
    private final class AccountOwner {}
    private final class SyntheticNetwork {
        weak var currentOwner: AccountOwner?
    }
    private typealias Request = (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.messages.AffectedMessages>)

    private final class Fixture {
        let owner = AccountOwner()
        let network = SyntheticNetwork()
        let admissions = ExteralessReadRequestAdmissions<AccountOwner, SyntheticNetwork, FunctionDescription>()
        let prefix = ValuePipe<Void>()
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(7))
        var values: [String: ClientSettingValue] = [:]
        var finalRequest: Request?
        var finalNetwork: SyntheticNetwork?
        var prefixStarts = 0
        var submissions = 0
        var automaticMetadataAllows = true
        var request: Request?

        init() { network.currentOwner = owner }
        var policy: PrivacyPolicy { PrivacyPolicy(values: values) }
        var peerKey: PrivacyPeerKey { PrivacyPeerKey(accountId: 1, peerId: peer.toInt64()) }

        func transport(_ request: Request) -> Signal<Api.messages.AffectedMessages, MTRpcError> {
            self.request = request
            self.prefixStarts += 1
            return (prefix.signal() |> take(1) |> castError(MTRpcError.self))
            |> mapToSignal { [self] _ -> Signal<Api.messages.AffectedMessages, MTRpcError> in
                let final = finalRequest ?? request
                let network = finalNetwork ?? self.network
                switch admissions.admit(transport: network, descriptor: final.0, body: final.1.makeData(), policy: policy, automaticMetadataAllows: automaticMetadataAllows) {
                case .allowed: break
                case .denied:
                    return .fail(MTRpcError(errorCode: 403, errorDescription: "EXTERALESS_PRIVACY_SUPPRESSED"))
                case .unregistered:
                    // A changed descriptor has no old manual grant. The ordinary
                    // final policy is still necessary for an unannotated request.
                    guard policy.permitsRequest(method: final.0.name, peer: nil, incrementViews: nil, requestsOnline: nil) else {
                        return .fail(MTRpcError(errorCode: 403, errorDescription: "EXTERALESS_PRIVACY_SUPPRESSED"))
                    }
                }
                submissions += 1
                // The recorder acknowledges admission without inventing RPC/PTS data.
                return .complete()
            }
        }

        func automatic() -> Signal<Api.messages.AffectedMessages?, MTRpcError> {
            return exteralessPrivacyRequest(allow: { [self] in policy.allowsMessageRead(peerKey) }, suppressed: { nil }, request: { [self] in
                exteralessAutomaticReadMessageContents(admissions: admissions, owner: owner, transport: network, accountId: 1, peerId: peer, ids: [11], ownerIsCurrent: { owner, network in
                    network.currentOwner === owner
                }, submit: { [self] request in transport(request) })
            })
        }

        func owned(_ intent: ExteralessReadRequestIntent) -> Signal<Api.messages.AffectedMessages, MTRpcError> {
            let request = Api.functions.messages.readHistory(peer: .inputPeerUser(.init(userId: 7, accessHash: 1)), maxId: 11)
            return exteralessBoundReadRequest(admissions: admissions, owner: owner, transport: network, request: request, intent: intent, ownerIsCurrent: { owner, network in
                network.currentOwner === owner
            }, submit: { [self] in transport(request) })
        }
    }

    func testPR02AutomaticUnchangedBytesAreRejectedAfterGlobalRevoke() {
        let fixture = Fixture()
        var errors = 0
        let disposable = fixture.automatic().start(error: { error in
            XCTAssertEqual(error.errorCode, 403)
            errors += 1
        })
        XCTAssertEqual(fixture.prefixStarts, 1)
        XCTAssertEqual(fixture.submissions, 0)
        fixture.values["privacy.sendReadMessagePackets"] = .bool(false)
        fixture.prefix.putNext(())
        fixture.prefix.putNext(())
        XCTAssertEqual(fixture.submissions, 0)
        XCTAssertEqual(errors, 1)
        disposable.dispose()
    }

    func testPR02AutomaticUnchangedBytesAreRejectedAfterExceptionRemoval() {
        let fixture = Fixture()
        fixture.values = ["privacy.sendReadMessagePackets": .bool(false), "privacy.ghostModeReadExclusions": .object([fixture.peerKey.settingKey: .bool(true)])]
        var errors = 0
        let disposable = fixture.automatic().start(error: { _ in errors += 1 })
        XCTAssertEqual(fixture.prefixStarts, 1)
        fixture.values["privacy.ghostModeReadExclusions"] = .object([:])
        fixture.prefix.putNext(())
        XCTAssertEqual(fixture.submissions, 0)
        XCTAssertEqual(errors, 1)
        disposable.dispose()
    }

    func testPR02AutomaticControlAndCancelledPrefix() {
        let allowed = Fixture()
        var completed = 0
        let first = allowed.automatic().start(completed: { completed += 1 })
        allowed.prefix.putNext(())
        XCTAssertEqual(allowed.submissions, 1)
        XCTAssertEqual(completed, 1)
        first.dispose()

        let cancelled = Fixture()
        let second = cancelled.automatic().start()
        second.dispose()
        cancelled.prefix.putNext(())
        XCTAssertEqual(cancelled.submissions, 0)
    }

    func testPR02AutomaticHintCannotOverrideFinalMetadataDenial() {
        let fixture = Fixture()
        fixture.values = ["privacy.sendReadMessagePackets": .bool(false), "privacy.ghostModeReadExclusions": .object([fixture.peerKey.settingKey: .bool(true)])]
        let disposable = fixture.automatic().start()
        fixture.automaticMetadataAllows = false
        fixture.prefix.putNext(())
        XCTAssertEqual(fixture.submissions, 0)
        disposable.dispose()
    }

    func testPR02ManualControlKeepsOwnOneShotGrantAfterPolicyRevoke() throws {
        let fixture = Fixture()
        let signal = fixture.owned(.manual)
        var completions = 0
        let first = signal.start(completed: { completions += 1 })
        fixture.values["privacy.sendReadMessagePackets"] = .bool(false)
        fixture.prefix.putNext(())
        XCTAssertEqual(fixture.submissions, 1)
        XCTAssertEqual(completions, 1)
        let request = try XCTUnwrap(fixture.request)
        XCTAssertEqual(fixture.admissions.admit(transport: fixture.network, descriptor: request.0, body: request.1.makeData(), policy: fixture.policy), .denied)
        var reuseErrors = 0
        let second = signal.start(error: { _ in reuseErrors += 1 })
        fixture.prefix.putNext(())
        XCTAssertEqual(reuseErrors, 1)
        XCTAssertEqual(fixture.submissions, 1)
        first.dispose(); second.dispose()
    }

    func testPR02ManualGrantCannotCrossOwnerOrNetwork() {
        let replaced = Fixture()
        replaced.values["privacy.sendReadMessagePackets"] = .bool(false)
        let first = replaced.owned(.manual).start()
        let replacement = AccountOwner()
        replaced.network.currentOwner = replacement
        replaced.prefix.putNext(())
        XCTAssertEqual(replaced.submissions, 0)
        first.dispose()

        let moved = Fixture()
        moved.values["privacy.sendReadMessagePackets"] = .bool(false)
        let second = moved.owned(.manual).start()
        let anotherNetwork = SyntheticNetwork()
        anotherNetwork.currentOwner = moved.owner
        moved.finalNetwork = anotherNetwork
        moved.prefix.putNext(())
        XCTAssertEqual(moved.submissions, 0)
        second.dispose()
    }

    func testPR02CancellingManualPrefixRetiresItsGrant() throws {
        let fixture = Fixture()
        fixture.values["privacy.sendReadMessagePackets"] = .bool(false)
        let disposable = fixture.owned(.manual).start()
        let request = try XCTUnwrap(fixture.request)
        disposable.dispose()
        XCTAssertEqual(fixture.admissions.admit(transport: fixture.network, descriptor: request.0, body: request.1.makeData(), policy: fixture.policy), .denied)
        fixture.prefix.putNext(())
        XCTAssertEqual(fixture.submissions, 0)
    }

    func testPR02ManualGrantCannotAuthorizeChangedBytesOrFreshDescriptor() throws {
        let changed = Fixture()
        changed.values["privacy.sendReadMessagePackets"] = .bool(false)
        let first = changed.owned(.manual).start()
        let original = try XCTUnwrap(changed.request)
        let other = Api.functions.messages.readHistory(peer: .inputPeerUser(.init(userId: 7, accessHash: 1)), maxId: 12)
        changed.finalRequest = (original.0, other.1, original.2)
        changed.prefix.putNext(())
        XCTAssertEqual(changed.submissions, 0)
        first.dispose()

        let fresh = Fixture()
        fresh.values["privacy.sendReadMessagePackets"] = .bool(false)
        let second = fresh.owned(.manual).start()
        fresh.finalRequest = Api.functions.messages.readHistory(peer: .inputPeerUser(.init(userId: 7, accessHash: 1)), maxId: 11)
        fresh.prefix.putNext(())
        XCTAssertEqual(fresh.submissions, 0)
        second.dispose()
    }

    func testPR02ReadAfterSendIsRevocableRatherThanManual() {
        let fixture = Fixture()
        fixture.values["privacy.sendReadMessagePackets"] = .bool(false)
        let disposable = fixture.owned(.afterSend(fixture.peerKey)).start()
        fixture.values["privacy.markReadAfterSend"] = .bool(false)
        fixture.prefix.putNext(())
        XCTAssertEqual(fixture.submissions, 0)
        disposable.dispose()
    }
}
