"""Captured native User response through the shipping SDK and real C transport.

EXTERALESS_TL_C_BRIDGE names a freshly built extension exporting the three
EXLPythonBridge dispatcher/buffer functions. Only the desktop host services are
recorders; C BridgeBackend, C epochs/handles and both plugin sources stay real.
The captured input is native-normalized. This does not execute the Swift codec.
"""

import ctypes
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading


ROOT = Path(__file__).resolve().parents[3]
SAMPLE = Path(__file__).parent / "fixtures/tl_native_user_response.json"
BOUND = 32_768


def read_json(path):
    raw = path.read_bytes()
    assert len(raw) <= BOUND, str(path)
    return json.loads(raw)


def write_json(path, value):
    raw = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
    assert len(raw) <= BOUND, str(path)
    path.write_bytes(raw)


def worker(role, directory, bridge_path):
    sys.path.insert(0, str(ROOT / "python"))
    bridge_spec = importlib.util.spec_from_file_location("_exteraless_bridge", bridge_path)
    bridge = importlib.util.module_from_spec(bridge_spec)
    bridge_spec.loader.exec_module(bridge)
    sys.modules["_exteraless_bridge"] = bridge
    assert type(bridge.xt_call_host) is type(len)
    import virtualjava
    import exteraless_runtime as runtime
    from exteraless_runtime import _dependencies
    from exteraless_runtime._tl import to_wire
    support_spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))
    support = importlib.util.module_from_spec(support_spec)
    support_spec.loader.exec_module(support)
    host = support.StrictNativeHost(directory / role)
    plugin_id = "nativeTLSdkZ" if role == "first" else "nativeTLSdkA"
    # The test host binds C before the SDK; wire requests must carry that exact
    # immutable epoch. No Python BridgeBackend or legacy service is installed.
    epoch = "desktop-native-tl-owner-" + role
    host.set_plugin_id(plugin_id)
    host.set_owner_token(epoch)
    owner_bound = False
    errors, security_rejections = [], []
    native_calls = 0

    class Buffer(ctypes.Structure):
        _fields_ = [("bytes", ctypes.c_void_p), ("count", ctypes.c_size_t)]
    Dispatch = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(Buffer))
    library = ctypes.CDLL(str(bridge_path))
    library.EXLPythonBridgeInstallDispatcher.argtypes = [Dispatch, ctypes.c_void_p, ctypes.c_void_p]
    library.EXLPythonBridgeUninstallDispatcher.argtypes = [Dispatch, ctypes.c_void_p]
    library.EXLPythonBridgeBufferCopy.argtypes = [ctypes.POINTER(Buffer), ctypes.c_void_p, ctypes.c_size_t]
    bootstrap_members = {"getPluginsDir", "getFilesDir", "getCacheDir", "getVersion", "getProtectedPaths", "log", "hasPermission", "isUnsafeMode"}

    def dispatch(context, request, request_count, owner, owner_count, response):
        nonlocal native_calls
        try:
            assert request_count <= BOUND and threading.get_ident() == host.thread
            assert ctypes.string_at(owner, owner_count).decode("utf-8") == plugin_id
            model = json.loads(ctypes.string_at(request, request_count))
            assert model.pop("pluginId") == plugin_id
            token = model.pop("ownerToken", None)
            assert token == (epoch if owner_bound else None), "C did not stamp its own epoch"
            native_calls += 1
            if not owner_bound and (model["fqcn"] != "exteraless.ios.Runtime" or model["member"] not in bootstrap_members):
                security_rejections.append(model["member"])
                reply = {"ok": False, "error": {"kind": "SecurityError", "message": "Native interpreter owner expired or missing"}}
            else:
                try:
                    if model["op"] == "member_kind":
                        value = "field" if (model["fqcn"], model["member"]) == ("org.telegram.messenger.UserConfig", "selectedAccount") else "unknown"
                    else:
                        value = host.call(model)
                    reply = {"ok": True, "value": value}
                except virtualjava.JavaMemberError as error:
                    reply = {"ok": False, "error": {"kind": "Unimplemented", "message": str(error)}}
        except BaseException as error:
            errors.append(type(error).__name__ + ": " + str(error)[:300])
            reply = {"ok": False, "error": {"kind": "FixtureFailure", "message": errors[-1]}}
        raw = json.dumps(reply, ensure_ascii=False, allow_nan=False).encode("utf-8")
        assert len(raw) <= BOUND
        return library.EXLPythonBridgeBufferCopy(response, raw, len(raw))

    callback = Dispatch(dispatch)
    assert library.EXLPythonBridgeInstallDispatcher(callback, None, None) == 0
    try:
        manifest = directory / (role + "-manifest.json")
        write_json(manifest, {"classes": {
            "org.telegram.messenger.UserConfig": {"declared": {"fields": ["selectedAccount"]}},
            "org.telegram.messenger.AndroidUtilities": {"declared": {"fields": []}},
        }})
        bridge.xt_set_plugin_id(plugin_id)
        bridge.xt_bind(virtualjava.JavaInstance, virtualjava.JavaMemberError)
        backend = bridge.BridgeBackend(service="java", manifest_path=str(manifest))
        virtualjava.install(backend)
        _dependencies.create_provider = lambda: _dependencies.ProvidedDependencies({})
        runtime.configure(plugin_id, str(host.plugins), str(host.settings))
        bridge.xt_set_owner_token(epoch)
        owner_bound = True
        runtime.bind_owner_json(json.dumps(epoch))
        source = ROOT / "python/runtime/smoke/plugins" / ("native_tl_" + role + ".plugin")
        assert source.stat().st_size <= BOUND
        plugin_path = host.plugins / (plugin_id + ".plugin")
        shutil.copyfile(source, plugin_path)
        runtime.load_json(str(plugin_path))
        assert type(virtualjava.finder._State.backend) is bridge.BridgeBackend
        assert runtime.hook_priority_json("post_request_hook", "TL_users_getUsers", "users.getUsers") == ("7" if role == "first" else "5")
        # The exact bridge functions remain installed after the bootstrap scans.
        assert type(bridge.xt_call_host) is type(len) and security_rejections
        sample = read_json(SAMPLE)

        def transform(name, value):
            payload = dict(sample, canonical_name=name, request_name=runtime._state.tl.schema.hook_names(name)[0],
                           response=dict(sample["response"], tl=value, metadata={"fixture": True, "requestName": name}))
            raw = json.dumps(payload, ensure_ascii=False, allow_nan=False)
            assert len(raw.encode("utf-8")) <= BOUND
            result = runtime.dispatch_json("post_request_hook", raw)
            assert len(result.encode("utf-8")) <= BOUND and "__handle__" not in result
            return json.loads(result)

        if role == "first":
            records = []
            original = sample["response"]["tl"]
            value = original
            for mode, close_friend, flags2 in (("flags2_on", True, 5), ("flags2_off", False, 1)):
                host.seed("mode", mode)
                result = transform("users.getUsers", value)
                assert result["strategy"] == "MODIFY"
                value = result["response"]
                assert value == [dict(original[0], close_friend=close_friend, flags2=flags2)]
                assert host.value("readonly_metadata") is True
                records.append({"mode": mode, "method": "users.getUsers", "value": value})
            for mode in ("bot_missing", "bot_on", "bot_off_inconsistent"):
                host.seed("mode", mode)
                result = transform("users.getUsers", result["response"] if mode == "bot_off_inconsistent" else original)
                user = result["response"][0]
                assert user["self"] is False and user["flags2"] == 1 and user["usernames"] == []
                assert user["bot"] is (mode != "bot_off_inconsistent")
                assert user["flags"] == (0 if mode == "bot_off_inconsistent" else 1 << 14)
                if mode == "bot_missing": assert "bot_info_version" not in user
                else: assert user["bot_info_version"] == 9
                # Rejection belongs to the shipping native validator. Only the
                # valid shared-bit candidate is handed to the second SDK worker.
                if mode == "bot_on": records.append({"mode": mode, "method": "users.getUsers", "value": result["response"]})
            for name, value, expected in (("users.getUsers", [{"_": "userEmpty", "id": 7}], [{"_": "userEmpty", "id": 7}, {"_": "userEmpty", "id": 29}]),
                                          ("stories.readStories", [7], [7, 29]),
                                          ("messages.receivedQueue", [9007199254740993], [9007199254740994])):
                host.seed("mode", "vector_users")
                result = transform(name, value)
                assert result == {"strategy": "MODIFY", "response": expected}
                records.append({"mode": "vector_users", "method": name, "value": result["response"]})
            # Also cover the set self bit and an absent optional getter, using
            # the same schema/constructor rather than a renamed test class.
            schema = runtime._state.tl.schema
            decoded = schema.decode(dict(original[0], self=True, flags=1 << 10))
            assert decoded.self is True and to_wire(decoded)["flags"] == 1 << 10
            decoded.self = False
            assert to_wire(decoded)["flags"] == 0 and to_wire(decoded)["flags2"] == 1
            assert getattr(decoded, "bot_info_version", None) is None
            write_json(directory / "first-results.json", records)
        else:
            records = read_json(directory / "first-results.json")
            assert len(records) == 6
            for record in records:
                result = transform(record["method"], record["value"])
                assert result == {"strategy": "MODIFY_FINAL", "response": record["value"]}
                if record["mode"] in ("flags2_on", "flags2_off"):
                    assert host.value("seen_close_friend") is (record["mode"] == "flags2_on")
                    assert host.value("seen_flags2") == (5 if record["mode"] == "flags2_on" else 1)
                    assert host.value("vector_user_ids") == [7]
                elif record["mode"] == "bot_on":
                    assert host.value("seen_bot") is True and host.value("seen_bot_version") == 9
                elif record["method"] == "users.getUsers": assert host.value("vector_user_ids") == [7, 29]
                else: assert host.value("vector_numbers") == record["value"]
        runtime.unload()
        assert bridge.xt_handle_count() == 0 and not bridge.xt_mock_log() and not errors, errors
        assert all(bridge.xt_service_ptr("java." + op) == 0 for op in (
            "construct", "call", "call_instance", "get", "get_instance", "set", "set_instance"))
        write_json(directory / (role + "-report.json"), {
            "role": role, "ok": True, "native_c_bridge": True, "native_calls": native_calls,
            "bootstrap_security_rejections": len(security_rejections), "handles_after_unload": bridge.xt_handle_count(),
            "swift_codec_executed": False,
        })
    finally:
        assert library.EXLPythonBridgeUninstallDispatcher(callback, None) == 0


if __name__ == "__main__":
    worker(sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]))
else:
    import pytest

    @pytest.mark.skipif(not os.environ.get("EXTERALESS_TL_C_BRIDGE"), reason="Set EXTERALESS_TL_C_BRIDGE to the current C extension with dispatcher ABI exports")
    def test_actual_native_response_through_two_c_sdk_workers(tmp_path):
        for role in ("first", "second"):
            result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), role, str(tmp_path), os.environ["EXTERALESS_TL_C_BRIDGE"]],
                                    cwd=tmp_path, text=True, encoding="utf-8", capture_output=True, timeout=30)
            assert result.returncode == 0, (result.stdout + result.stderr)[-6000:]
