import Foundation
import MtProtoKit
import MTProtoEngineFFI
import TelegramCore
import XCTest
@testable import MTProtoRustEngine

final class RustCredentialLogTests: XCTestCase {
    private let sentinel = "CA04_SYNTHETIC_SENTINEL"
    private let methods = ["bots.invokeWebViewCustomMethod", "auth.sendCode", "auth.exportLoginToken", "auth.importBotAuthorization", "auth.importWebTokenAuthorization", "auth.initPasskeyLogin", "auth.initFirebasePnvLogin"]

    func testCannedFFIErrorsUseShippingFormatterWithRedactionEnabledAndDisabled() {
        for redact in [true, false] {
            let logger = Logger(rootPath: "", basePath: "")
            logger.logToFile = false; logger.logToConsole = false; logger.redactSensitiveData = redact
            Logger.setSharedLogger(logger)
            XCTAssertEqual(Logger.shared.redactSensitiveData, redact)
            for method in methods {
                let request = NetworkEngineRequest(payload: Data(), name: method, parse: { _ in nil }, shouldContinueAfterError: { _ in false }, completed: { _ in })
                for code in [Int32(400), 401, 403, 406, 420, 500] {
                    sentinel.withCString { pointer in
                        var raw = MTEvent()
                        raw.kind = MTEventKindFailed; raw.code = code; raw.request_id = 42
                        raw.text = MTString(data: pointer, length: sentinel.utf8.count)
                        let event = withUnsafePointer(to: &raw) { RustEngineEvent($0) }
                        let capturedLog = RustRequestLog.failure(request: request, requestId: event.requestId, code: event.code, text: event.text)
                        XCTAssertFalse(capturedLog.contains(sentinel))
                        XCTAssertTrue(capturedLog.contains(method))
                        XCTAssertTrue(capturedLog.contains("code=\(code)"))
                        XCTAssertTrue(capturedLog.contains("CREDENTIAL_RPC_ERROR"))
                        XCTAssertEqual(event.text, sentinel, "Only logging is sanitized")
                    }
                }
            }
        }
    }

    func testRetryUnattributedAuthAndFrozenNativeTraceNeverFormatFreeText() {
        let request = NetworkEngineRequest(payload: Data(), name: "bots.invokeWebViewCustomMethod", parse: { _ in nil }, shouldContinueAfterError: { _ in true }, completed: { _ in })
        let retry = RustRequestLog.failure(request: request, requestId: 1, code: 420, text: "FLOOD_WAIT_7_" + sentinel)
        let auth = RustRequestLog.failure(request: nil, requestId: 0, code: 401, text: sentinel)
        // The native free-form callback has no request/code fields. Its shipping
        // formatter accepts only a level; structured event logs retain method/code.
        let native = RustRequestLog.nativeEngineMessage(level: 2)
        XCTAssertFalse([retry, auth, native].joined().contains(sentinel))
        XCTAssertTrue(retry.contains("bots.invokeWebViewCustomMethod code=420"))
        XCTAssertTrue(auth.contains("code=401"))
        XCTAssertTrue(native.contains("UNSTRUCTURED_TEXT_REDACTED"))
    }
}
