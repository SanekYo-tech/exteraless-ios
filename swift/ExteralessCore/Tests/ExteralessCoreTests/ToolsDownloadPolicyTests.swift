import XCTest
@testable import ExteralessCore

final class ToolsDownloadPolicyTests: XCTestCase {
    func testActualManagerBudgetsRespectProtocolAndSpecialResources() {
        let native = ToolsDownloadBudget(partBytes: 128 * 1_024, parallelParts: 6)
        XCTAssertEqual(ToolsDownloadPolicy.budget(level: 2, size: 4_000_000, isStory: false, encrypted: false, native: native), .init(partBytes: 1_024 * 1_024, parallelParts: 12))
        let special: [(Int64?, Bool, Bool)] = [(nil, false, false), (100, false, false), (4_000_000, true, false), (4_000_000, false, true)]
        for (size, story, encrypted) in special {
            XCTAssertEqual(ToolsDownloadPolicy.budget(level: 2, size: size, isStory: story, encrypted: encrypted, native: native), native)
        }
        let fast = ToolsDownloadBudget(partBytes: 1_024 * 1_024, parallelParts: 32)
        XCTAssertEqual(ToolsDownloadPolicy.budget(level: 2, size: 4_000_000, isStory: false, encrypted: false, native: fast), fast)
    }
}
