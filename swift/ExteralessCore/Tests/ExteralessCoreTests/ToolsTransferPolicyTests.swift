import XCTest
@testable import ExteralessCore

final class ToolsTransferPolicyTests: XCTestCase {
    func testFacingChoiceOverridesLegacyRememberedStateAndAbsentChoiceMigratesIt() {
        XCTAssertFalse(ToolsCameraPolicy.initialCameraIsFront(facing: 1, explicitFacing: true, remember: true, lastFront: true))
        XCTAssertTrue(ToolsCameraPolicy.initialCameraIsFront(facing: 0, explicitFacing: true, remember: true, lastFront: false))
        XCTAssertFalse(ToolsCameraPolicy.initialCameraIsFront(facing: 0, explicitFacing: false, remember: true, lastFront: false))
        XCTAssertTrue(ToolsCameraPolicy.initialCameraIsFront(facing: 0, explicitFacing: false, remember: false, lastFront: false))
        XCTAssertTrue(ToolsCameraPolicy.initialCameraIsFront(facing: 2, explicitFacing: true, remember: true, lastFront: false))
    }

    func testOriginalExtensionListsGateAutomaticDownloadsIndependently() {
        for name in ["a.ZIP", "package.apk", "part.tar.gz", "data.zst"] {
            XCTAssertFalse(ToolsAutomaticDownloadPolicy.allows(fileName: name, skipArchives: true, skipWindowsExecutables: false))
            XCTAssertTrue(ToolsAutomaticDownloadPolicy.allows(fileName: name, skipArchives: false, skipWindowsExecutables: true))
        }
        for name in ["a.EXE", "script.PS1", "setup.msi", "run.vbscript"] {
            XCTAssertFalse(ToolsAutomaticDownloadPolicy.allows(fileName: name, skipArchives: false, skipWindowsExecutables: true))
        }
        for name in [nil, "file", "video.mp4", "a.rar", "file.zip.txt", "trailing."] {
            XCTAssertTrue(ToolsAutomaticDownloadPolicy.allows(fileName: name, skipArchives: true, skipWindowsExecutables: true))
        }
    }

    func testUploadChunkFloorDoesNotChangeStreamingEncryptedHeaderOrLargerNativeParts() {
        XCTAssertEqual(ToolsUploadPolicy.partSize(native: 16_384, enabled: true, completeSize: 1_000_000, encrypted: false, hasHeader: false), 524_288)
        XCTAssertEqual(ToolsUploadPolicy.partSize(native: 1_048_576, enabled: true, completeSize: 20_000_000, encrypted: false, hasHeader: false), 1_048_576)
        for (enabled, size, encrypted, header) in [(false, Optional<Int64>(1_000_000), false, false), (true, nil, false, false), (true, Optional<Int64>(128), false, false), (true, Optional<Int64>(1_000_000), true, false), (true, Optional<Int64>(1_000_000), false, true)] {
            XCTAssertEqual(ToolsUploadPolicy.partSize(native: 16_384, enabled: enabled, completeSize: size, encrypted: encrypted, hasHeader: header), 16_384)
        }
    }
}
