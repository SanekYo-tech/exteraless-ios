import Foundation
import PluginHooks
import XCTest

final class PluginSendResultCodecTests: XCTestCase {
    private var original: PluginSendPayload {
        return PluginSendPayload(accountRecordId: Int64.max - 37, peerId: 73, text: "original", canModifyText: true, threadId: 101, correlationId: 202)
    }

    func testDefaultAndCancelNeedNoParams() throws {
        XCTAssertEqual(try PluginSendResultCodec.decode(#"{"strategy":"DEFAULT"}"#, original: self.original), .keepOriginal)
        XCTAssertEqual(try PluginSendResultCodec.decode(#"{"strategy":"CANCEL","params":null}"#, original: self.original), .cancel)
    }

    func testSparseModifyAndModifyFinalPreserveAllSupportedValues() throws {
        let patch = PluginSendMessagePatch(text: "Привет 👋", silent: true, disableLinkPreviews: true)
        XCTAssertEqual(try PluginSendResultCodec.decode(
            #"{"strategy":"MODIFY","params":{"text":"Привет 👋","silent":true,"disableLinkPreviews":true}}"#,
            original: self.original
        ), .modify(patch))
        XCTAssertEqual(try PluginSendResultCodec.decode(
            #"{"strategy":"MODIFY_FINAL","params":{"text":"Привет 👋","silent":true,"disableLinkPreviews":true}}"#,
            original: self.original
        ), .modifyFinal(patch))
    }

    func testFullEchoAcceptsOnlyChangesToSupportedFieldsWithoutRoundingIdentity() throws {
        let json = try self.original.jsonString()
        let roundTrip = try JSONDecoder().decode(PluginSendPayload.self, from: Data(json.utf8))
        XCTAssertEqual(roundTrip, self.original)
        XCTAssertEqual(roundTrip.accountRecordId, Int64.max - 37)
        var params = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        params["text"] = "changed"
        params["silent"] = true
        let resultData = try JSONSerialization.data(withJSONObject: ["strategy": "MODIFY", "params": params])
        XCTAssertEqual(try PluginSendResultCodec.decode(String(decoding: resultData, as: UTF8.self), original: self.original), .modify(PluginSendMessagePatch(text: "changed", silent: true)))
    }

    func testUnsupportedAndReadOnlyChangesRejectWholePatch() {
        let cases: [(String, PluginSendCodecError)] = [
            (#"{"strategy":"MODIFY","params":{"text":"changed","entities":[]}}"#, .unsupportedField("entities")),
            (#"{"strategy":"MODIFY","params":{"peerId":74}}"#, .readOnlyField("peerId")),
            (#"{"strategy":"MODIFY","params":{"accountRecordId":1}}"#, .readOnlyField("accountRecordId")),
            (#"{"strategy":"MODIFY","params":{"threadId":null}}"#, .readOnlyField("threadId")),
            (#"{"strategy":"MODIFY","params":{"silent":1}}"#, .invalidFieldType("silent")),
            (#"{"strategy":"MODIFY","params":{"text":null}}"#, .invalidFieldType("text")),
            (#"{"strategy":"MODIFY","params":{"schemaVersion":true}}"#, .readOnlyField("schemaVersion")),
            (#"{"strategy":"MODIFY","params":{"text":""}}"#, .emptyText),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try PluginSendResultCodec.decode(json, original: self.original)) { error in
                XCTAssertEqual(error as? PluginSendCodecError, expected)
            }
        }
    }

    func testAttributedTextCannotBeReplacedButUnchangedTextCanBeEchoed() throws {
        let attributed = PluginSendPayload(accountRecordId: 42, peerId: 73, text: "original", hasTextEntities: true, attributeTypes: ["TextEntitiesMessageAttribute"])
        XCTAssertThrowsError(try PluginSendResultCodec.decode(#"{"strategy":"MODIFY","params":{"text":"changed"}}"#, original: attributed)) { error in
            XCTAssertEqual(error as? PluginSendCodecError, .textModificationUnavailable)
        }
        XCTAssertEqual(try PluginSendResultCodec.decode(#"{"strategy":"MODIFY","params":{"text":"original","silent":true}}"#, original: attributed), .modify(PluginSendMessagePatch(silent: true)))
    }

    func testForwardModificationIsExplicitlyUnsupported() {
        let forward = PluginSendPayload(accountRecordId: 42, peerId: 73, kind: .forward)
        XCTAssertThrowsError(try PluginSendResultCodec.decode(#"{"strategy":"MODIFY","params":{"silent":true}}"#, original: forward)) { error in
            XCTAssertEqual(error as? PluginSendCodecError, .forwardModificationUnavailable)
        }
        XCTAssertThrowsError(try PluginSendResultCodec.decode(#"{"strategy":"MODIFY","params":{"text":"changed"}}"#, original: forward)) { error in
            XCTAssertEqual(error as? PluginSendCodecError, .textModificationUnavailable)
        }
    }

    func testMalformedResultAndMissingReplacementFailExplicitly() {
        let cases: [(String, PluginSendCodecError)] = [
            ("[]", .malformedResult),
            ("{", .malformedResult),
            (#"{"strategy":"OTHER"}"#, .unknownStrategy),
            (#"{"strategy":"MODIFY"}"#, .missingParams),
            (#"{"strategy":"MODIFY_FINAL","params":null}"#, .missingParams),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try PluginSendResultCodec.decode(json, original: self.original)) { error in
                XCTAssertEqual(error as? PluginSendCodecError, expected)
            }
        }
    }

    func testObservationsExposeMetadataAndBytesWithoutPretendingToBeTLJSON() throws {
        let metadata = PluginRequestMetadata(accountRecordId: Int64.max - 37, requestId: "fixture-request", requestName: "fixture.method", datacenterId: 2, automaticFloodWait: false, usesAdditionalInfo: true)
        let payload = PluginRequestObservation(phase: .completed, metadata: metadata, serializedTLBytes: Data([1, 2, 255]), tlBytesEncoding: .responseBody, responseTypeName: "FixtureResponse", response: PluginRPCResponseMetadata(timestamp: 123, duration: 0.5, networkType: 0))
        let json = try PluginHookObservation.postRequest(payload).jsonString()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["observational"] as? Bool, true)
        XCTAssertEqual(object["serializedTLBytes"] as? String, "AQL/")
        XCTAssertEqual(object["tlBytesEncoding"] as? String, "responseBody")
        XCTAssertEqual(try JSONDecoder().decode(PluginRequestObservation.self, from: Data(json.utf8)), payload)
    }
}
