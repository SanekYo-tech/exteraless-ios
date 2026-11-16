import Foundation
import MtProtoKit
internal import TelegramApi
import XCTest
@testable import TelegramCore

private final class CredentialLogSentinel: CustomStringConvertible {
    var described = 0
    var description: String { described += 1; return "CA04_SYNTHETIC_SENTINEL" }
}

/// Canned request/error objects exercise the shipping adapter and service formatter.
/// No MTContext/account/connection is made; all values below are synthetic sentinels.
final class NetworkCredentialLogTests: XCTestCase {
    private let methods: [(String, UInt32)] = [
        ("bots.invokeWebViewCustomMethod", 0x087fc5e7),
        ("auth.sendCode", 0xa677244f), ("auth.exportLoginToken", 0xb7e085fe),
        ("auth.importBotAuthorization", 0x67a3ff2c), ("auth.importWebTokenAuthorization", 0x2db873a9),
        ("auth.initPasskeyLogin", 0x518ad0b7), ("auth.initFirebasePnvLogin", 0x644f15c0)
    ]
    private let sentinel = "CA04_SYNTHETIC_SENTINEL"

    private func payload(_ signature: UInt32) -> Data {
        var value = signature.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private func logger(_ redact: Bool) -> Logger {
        let logger = Logger(rootPath: "", basePath: "")
        logger.logToFile = false; logger.logToConsole = false
        logger.redactSensitiveData = redact
        Logger.setSharedLogger(logger)
        return logger
    }

    func testCannedMtProtoKitErrorsAndAllRequestDescriptionsHideSentinelForBothFlags() throws {
        for redact in [true, false] {
            let log = logger(redact)
            XCTAssertEqual(Logger.shared.redactSensitiveData, redact)
            for (method, signature) in methods {
                let metadata = CredentialLogSentinel()
                let engineRequest = NetworkEngineRequest(payload: payload(signature),
                    metadata: WrappedRequestMetadata(metadata: metadata, tag: nil),
                    shortMetadata: WrappedRequestShortMetadata(shortMetadata: metadata),
                    parse: { _ in nil }, options: .init(), shouldContinueAfterError: { _ in false },
                    dependsOn: nil, acknowledged: nil, progress: nil, completed: { _ in })
                // This is the same adapter used by MtProtoKitRequestService.add.
                let request = mtProtoKitRequestForEngineRequest(engineRequest)
                let error = try XCTUnwrap(MTRpcError(errorCode: 403, errorDescription: "echo [\(sentinel)] / \\u0041"))
                var capturedLogs: [String] = []
                capturedLogs.append(String(describing: request.metadataForLogging!))
                capturedLogs.append(String(describing: request.shortMetadataForLogging!))
                capturedLogs.append(MTRequestMessageService.responseLogDescription(request: request, result: nil, error: error))
                capturedLogs.append(MTRequestMessageService.responseLogDescription(request: request, result: metadata, error: nil))
                XCTAssertTrue(capturedLogs.allSatisfy { !$0.contains(sentinel) })
                XCTAssertTrue(capturedLogs.allSatisfy { $0.contains(method) })
                XCTAssertTrue(capturedLogs[2].contains("code=403"))
                XCTAssertTrue(capturedLogs[2].contains("CREDENTIAL_RPC_ERROR"))
                XCTAssertEqual(metadata.described, 0, "Redaction must precede description evaluation")
                XCTAssertTrue(error.errorDescription.contains(sentinel), "Formatter must not mutate native errors")
                XCTAssertEqual(request.payload, engineRequest.payload)
            }
            withExtendedLifetime(log) {}
        }
    }

    func testClassificationUsesExactMethodOrConstructorAndCannotBeDowngraded() {
        let selected = MTRequestLogContext.context(payload: payload(0x087fc5e7), methodName: "misleading.name")
        XCTAssertTrue(selected.containsCredentials)
        XCTAssertEqual(selected.methodName, "bots.invokeWebViewCustomMethod")
        XCTAssertFalse(MTRequestLogContext.context(payload: nil, methodName: "prefix.auth.sendCode.suffix").containsCredentials)
        for (method, _) in methods { XCTAssertTrue(MTRequestLogContext.context(payload: nil, methodName: method).containsCredentials) }
        let request = MTRequest(logContext: selected)
        request.setPayload(Data(), metadata: sentinel, shortMetadata: "ordinary", responseParser: { _ in nil })
        XCTAssertTrue(request.logContext.containsCredentials)
        XCTAssertFalse(String(describing: request.metadataForLogging!).contains(sentinel))
        XCTAssertTrue(request.logContext === selected)
    }

    func testGeneratedAuthPayloadReachesTheShippingFormatterWithoutNetwork() {
        for redact in [true, false] {
            _ = logger(redact)
            let api = Api.functions.auth.initPasskeyLogin(apiId: 1, apiHash: sentinel)
            let request = NetworkEngineRequest(payload: api.1.makeData(),
                metadata: WrappedRequestMetadata(metadata: exteralessClientAPIRequestLogMetadata(api.0), tag: nil),
                shortMetadata: WrappedRequestShortMetadata(shortMetadata: WrappedShortFunctionDescription(api.0)),
                parse: { _ in nil }, options: .init(), shouldContinueAfterError: { _ in false },
                dependsOn: nil, acknowledged: nil, progress: nil, completed: { _ in })
            let native = mtProtoKitRequestForEngineRequest(request)
            let text = MTRequestMessageService.responseLogDescription(request: native, result: nil,
                error: MTRpcError(errorCode: 400, errorDescription: sentinel))
            XCTAssertEqual(request.logContext.methodName, api.0.name)
            XCTAssertFalse(text.contains(sentinel))
            XCTAssertTrue(text.contains("auth.initPasskeyLogin code=400"))
            let ordinary = Api.functions.help.getConfig()
            let ordinaryMetadata = exteralessClientAPIRequestLogMetadata(ordinary.0)
            _ = WrappedRequestMetadata(metadata: ordinaryMetadata, tag: nil)
            XCTAssertTrue(String(describing: ordinaryMetadata).contains(ordinary.0.name))
        }
    }

    func testRetryAndCompletionKeepOriginalErrorWhileFailureFormattingIsSafe() throws {
        _ = logger(false)
        let native = try XCTUnwrap(MTRpcError(errorCode: 420, errorDescription: "FLOOD_WAIT_7_" + sentinel))
        var seenContext: NetworkEngineErrorContext?
        var delivered: NetworkEngineRequestFailure?
        let request = NetworkEngineRequest(payload: payload(0xa677244f), name: "auth.sendCode", parse: { _ in nil }, shouldContinueAfterError: { context in
            seenContext = context; return true
        }, completed: { result in if case let .failure(failure) = result { delivered = failure } })
        let context = NetworkEngineErrorContext(floodWaitSeconds: 7, floodWaitErrorText: native.errorDescription, internalServerErrorCount: 2)
        XCTAssertTrue(request.shouldContinueAfterError(context))
        XCTAssertEqual(seenContext, context)
        request.completed(.failure(.init(error: native, info: .init(timestamp: 1, networkType: 0, duration: 0.1))))
        XCTAssertTrue(delivered?.error === native)
        XCTAssertEqual(delivered?.error.errorDescription, native.errorDescription)
        if let delivered {
            var dumpText = ""
            dump(delivered, to: &dumpText)
            for text in [delivered.description, String(reflecting: delivered), dumpText] {
                XCTAssertFalse(text.contains(sentinel))
                XCTAssertTrue(text.contains("auth.sendCode"))
                XCTAssertTrue(text.contains("420"))
            }
        } else { XCTFail("No native completion") }
    }
}
