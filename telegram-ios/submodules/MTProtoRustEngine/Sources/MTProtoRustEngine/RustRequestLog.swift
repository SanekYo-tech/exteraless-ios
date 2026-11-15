import Foundation
import MtProtoKit
import TelegramCore

/// Shipping formatter. Raw engine errors go to retry/completion intact; only this
/// description, never event.text, is interpolated into request-error logs.
enum RustRequestLog {
    static func failure(request: NetworkEngineRequest?, requestId: UInt64, code: Int32, text: String) -> String {
        let context = request?.logContext ?? MTRequestLogContext.redactedUnattributed()
        return "#\(requestId) " + context.errorDescription(code: code, text: text)
    }

    /// Frozen Rust also emits a free-form query trace BEFORE the structured event.
    /// That callback has neither request identity nor trusted privacy metadata.
    /// Never parse/mask it to recover trust. Structured events supply method/code.
    static func nativeEngineMessage(level: Int32) -> String {
        return "NATIVE_ENGINE_DIAGNOSTIC level=\(level) [UNSTRUCTURED_TEXT_REDACTED]"
    }
}
