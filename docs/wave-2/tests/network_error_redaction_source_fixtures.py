"""CA-04 local source checks, not native fixture execution. No network or writes."""
from pathlib import Path
import hashlib
import json
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
KIT = ROOT / "telegram-ios/submodules/MtProtoKit"
CORE = ROOT / "telegram-ios/submodules/TelegramCore"
RUST = ROOT / "telegram-ios/submodules/MTProtoRustEngine"


def read(path):
    return path.read_text(encoding="utf-8-sig")


class NetworkErrorRedactionSourceFixtures(unittest.TestCase):
    def test_exact_schema_and_existing_client_api_method_set(self):
        schema = read(ROOT / "telegram-ios/submodules/TelegramApi/swift_scheme.tl")
        signatures = {}
        hash_methods = set()
        for name, signature, fields in re.findall(r"(?m)^([\w.]+)#([0-9a-f]+)\s+(.+)$", schema):
            signatures[name] = int(signature, 16)
            if "api_hash:string" in fields:
                hash_methods.add(name)
        policy = read(CORE / "Sources/ExteralessClientAPI/ExteralessClientAPIRequestPolicy.swift")
        original = set(re.findall(r'"(auth\.[A-Za-z]+)"', policy))
        self.assertEqual(len(original), 6)
        self.assertEqual(hash_methods, original)
        classifier = read(KIT / "Sources/MTRequestLogContext.m")
        names = re.findall(r'initWithMethod:@"([\w.]+)" credentials:true', classifier)
        names = [name for name in names if "." in name]
        self.assertEqual(set(names), original | {"bots.invokeWebViewCustomMethod"})
        ids = re.search(r"constructors\[\] = \{([^}]+)\}", classifier).group(1)
        ids = [int(value.strip(), 16) for value in ids.split(",")]
        self.assertEqual(ids, [signatures[name] for name in names])
        self.assertNotIn("rangeOfString", classifier)
        self.assertNotIn("NSRegularExpression", classifier)
        self.assertNotIn("redactSensitiveData", classifier)

    def test_mtprotokit_shipping_formatter_precedes_unchanged_error_handling(self):
        service = read(KIT / "Sources/MTRequestMessageService.m")
        self.assertIn("[MTRequestMessageService responseLogDescriptionForRequest:request result:rpcResult error:rpcError]", service)
        self.assertIn("completed(rpcResult, info, rpcError)", service)
        self.assertIn("request.errorContext.floodWaitErrorText = rpcError.errorDescription", service)
        for line in service.splitlines():
            if "MTLog(" in line:
                self.assertNotIn("rpcError.errorDescription", line)
                self.assertNotIn("request.metadata,", line)
        self.assertIn("metadata:request.metadataForLogging", service)
        self.assertIn("shortMetadata:request.shortMetadataForLogging", service)
        self.assertNotIn('apnsSecret(%@', service)
        self.assertNotIn('recaptcha(%@', service)
        adapter = read(CORE / "Sources/Network/MtProtoKitEngine.swift")
        self.assertIn("let mtRequest = mtProtoKitRequestForEngineRequest(request)", adapter)
        self.assertIn("MTRequest(logContext: request.logContext)", adapter)

    def test_rust_error_logs_use_request_context_not_raw_interpolation(self):
        session = read(RUST / "Sources/MTProtoRustEngine/RustNetworkSession.swift")
        self.assertNotIn(r"\(event.text)", session)
        self.assertNotIn("pending.request.shortMetadata.description", session)
        self.assertGreaterEqual(session.count("RustRequestLog.failure("), 7)
        self.assertIn("errorCode: event.code, errorDescription: event.text", session)
        self.assertIn("rustEngineWorkerShouldTransferAuthToken(code: event.code, text: event.text)", session)
        self.assertIn("pending.errorState.applyRetryDecision", session)
        request = read(CORE / "Sources/Network/NetworkEngine.swift")
        self.assertIn("public let logContext: MTRequestLogContext", request)
        self.assertIn("self.shouldContinueAfterErrorImpl(context)", request)
        self.assertIn("NetworkEngineRequestFailure(error: failure.error, info: failure.info, logContext: self.logContext)", request)

    def test_applied_propagation_and_earlier_freeform_trace_postimages(self):
        network = read(CORE / "Sources/Network/Network.swift")
        for name in ["WrappedFunctionDescription", "WrappedShortFunctionDescription"]:
            wrapper = network.split("final class " + name + ":", 1)[1].split("\n}", 1)[0]
            self.assertIn("MTRequestLogContext.context(payload: nil, methodName: self.desc.name)", wrapper)
            self.assertIn("if context.containsCredentials { return context.metadataDescription(nil) }", wrapper)
        for name in ["requestWithAdditionalInfo<T>", "request<T>"]:
            builder = network.split("func " + name + "(", 1)[1].split("\n    func ", 1)[0]
            self.assertEqual(builder.count("logContext: .context(payload: requestPayload, methodName: data.0.name)"), 1, name)
        transformed = read(CORE / "Sources/ExteralessRuntime/TLNetworkRequest.swift")
        self.assertIn("logContext: MTRequestLogContext.context(payload: body, methodName: description.name)", transformed)
        self.assertIn(".merging(.context(payload: self.data.1.makeData(), methodName: self.data.0.name))", transformed)
        runtime = read(RUST / "Sources/MTProtoRustEngine/RustEngineRuntime.swift")
        callback = runtime.split("private func rustEngineLogCallback", 1)[1].split("final class RustEngineRuntime", 1)[0]
        self.assertIn("RustRequestLog.nativeEngineMessage(level: level)", callback)
        self.assertNotIn("rustEngineString(message)", callback)
        self.assertIn("Logger.shared.log(rustEngineLogTag, text)", callback)
        self.assertIn("Logger.shared.shortLog(rustEngineLogTag, text)", callback)

    def test_native_fixtures_use_shipping_formatters_and_both_flags(self):
        kit = read(CORE / "Tests/NetworkCredentialLogTests.swift")
        rust = read(RUST / "Tests/MTProtoRustEngineTests/RustCredentialLogTests.swift")
        for test in [kit, rust]:
            self.assertIn("for redact in [true, false]", test)
            self.assertIn("Logger.shared.redactSensitiveData", test)
            self.assertIn("CA04_SYNTHETIC_SENTINEL", test)
        self.assertIn("mtProtoKitRequestForEngineRequest", kit)
        self.assertIn("MTRequestMessageService.responseLogDescription", kit)
        self.assertIn("Api.functions.auth.initPasskeyLogin", kit)
        self.assertIn("delivered?.error === native", kit)
        self.assertIn("RustEngineEvent($0)", rust)
        self.assertIn("RustRequestLog.failure", rust)

    def test_frozen_rust_resolver_postimages_are_untouched(self):
        pins = json.loads(read(ROOT / "docs/wave-2/network-maps-native-pins.json"))["files"]
        for name in ["resolver.rs", "worker.rs", "session_runtime.rs"]:
            relative = "telegram-ios/third-party/mtproto-engine/crates/mtproto-engine/src/" + name
            raw = (ROOT / relative).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), pins[relative]["sha256"], relative)
            self.assertEqual(len(raw), pins[relative]["bytes"], relative)


if __name__ == "__main__":
    unittest.main(verbosity=2)
