import Foundation
import XCTest
internal import TelegramApi
@testable import TelegramCore

final class ClientAPIRequestMetadataTests: XCTestCase {
    func testActualAuthFactoryDescriptionsNeverPlaceAppHashInLogMetadata() {
        let syntheticHash = String(repeating: "f", count: 32)
        let requests = [
            Api.functions.auth.initPasskeyLogin(apiId: 123, apiHash: syntheticHash).0,
            Api.functions.auth.exportLoginToken(apiId: 123, apiHash: syntheticHash, exceptIds: []).0
        ]
        for request in requests {
            XCTAssertTrue(exteralessClientAPIRequestContainsIdentity(request))
            let text = String(describing: exteralessClientAPIRequestLogMetadata(request))
            XCTAssertFalse(text.contains(syntheticHash))
            XCTAssertTrue(text.contains("appHash: set"))
        }
    }
}
