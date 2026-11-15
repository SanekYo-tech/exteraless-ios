import Foundation
import XCTest
@testable import ExteralessCore

final class ToolsNativeModePolicyTests: XCTestCase {
    func testVideoRungsAndGroupAudioUnitsAreIndependentOfTransferBoost() {
        XCTAssertEqual(ToolsNativeModePolicy.videoBitrateKbps(native: 3_700, width: 720, height: 1_280, enabled: true), 6_800)
        XCTAssertEqual(ToolsNativeModePolicy.videoBitrateKbps(native: 5_000, width: 1_920, height: 1_080, enabled: true), 14_000)
        XCTAssertEqual(ToolsNativeModePolicy.videoBitrateKbps(native: 40_000, width: 3_840, height: 2_160, enabled: true), 40_000)
        XCTAssertEqual(ToolsNativeModePolicy.videoBitrateKbps(native: 1_200, width: 480, height: 480, enabled: true), 1_200)
        XCTAssertEqual(ToolsNativeModePolicy.groupAudioBitrate(preferred: 128, native: 32), 128)
        XCTAssertEqual(ToolsNativeModePolicy.groupAudioBitrate(preferred: 0, native: 48), 48)
        XCTAssertEqual(ToolsNativeModePolicy.groupAudioBitrate(preferred: Int.max, native: 32), 32)
    }

    func testRpcDiagnosticsAreBoundedAndDoNotAcceptArbitraryPayloadText() {
        let buffer = ToolsRPCFailureBuffer(capacity: 2)
        buffer.record(method: "messages.getHistory", code: 400)
        buffer.record(method: "secret response body / token", code: 403)
        buffer.record(method: nil, code: 420)
        XCTAssertEqual(buffer.snapshot().map(\.method), ["RPC", "RPC"])
        XCTAssertEqual(buffer.snapshot().map(\.code), [403, 420])
    }

    func testCurrentCameraSelectionWinsOverLegacyRearAndCrashOptOutStaysOneWay() throws {
        let definitions = ToolsFeatures.definitions
        let archive = Data("{\"exteraconfig\":{\"rearVideoMessages\":true,\"cameraInVideoMessages\":2,\"staticZoom\":true,\"enhancedFileLoader\":true,\"downloadSpeedBoost\":2,\"disableCrashlyticsCollection\":true}}".utf8)
        let value = try ToolsBackupArchive.inspect(archive, definitions: definitions)
        XCTAssertEqual(value.settings["tools.videoMessageCameraFacing"], .integer(2))
        XCTAssertEqual(value.settings["tools.downloadSpeedBoost"], .integer(2))
        XCTAssertEqual(value.settings["tools.crashReports"], .bool(false))
        let oldRear = try ToolsBackupArchive.inspect(Data("{\"exteraconfig\":{\"rearVideoMessages\":true}}".utf8), definitions: definitions)
        XCTAssertEqual(oldRear.settings["tools.videoMessageCameraFacing"], .integer(1))
    }
}
