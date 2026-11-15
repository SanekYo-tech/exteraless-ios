"""Execute the exact native TL Python fixtures against a strict unit host.

This checks fixture/SDK behavior before the macOS native child, not Swift/C execution.
"""

import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]


def worker(role, directory):
    sys.path.insert(0, str(ROOT / "python"))
    spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))
    support = importlib.util.module_from_spec(spec); spec.loader.exec_module(support)
    class Host(support.StrictNativeHost):
        def call(self, request):
            request = dict(request)
            if "ownerToken" in request: assert request.pop("ownerToken") == self.owner_token
            return super().call(request)
    support.StrictNativeHost = Host
    plugin_id = "nativeTLSdkZ" if role == "first" else "nativeTLSdkA"
    runtime, host, bridge = support.bootstrap(Path(directory), plugin_id)
    host.permissions = {"ui", "messages.read"}
    runtime.bind_owner_json('"unit-tl-native-fixture-owner"')
    source = ROOT / "python/runtime/smoke/plugins" / ("native_tl_" + role + ".plugin")
    path = host.plugins / (plugin_id + ".plugin")
    shutil.copyfile(source, path)
    runtime.load_json(str(path))
    helper_spec = importlib.util.spec_from_file_location("_native_tl_unit_fixture", ROOT / "python/runtime/smoke/native_tl_probe.py")
    helper = importlib.util.module_from_spec(helper_spec); helper_spec.loader.exec_module(helper)
    identity = json.loads(helper.loaded())
    assert identity["pluginId"] == plugin_id and identity["handle"] in host.handles
    def payload(value):
        return json.dumps({"account": 2, "request_name": "TL_users_getUsers", "request": {
            "schemaVersion": 1, "observational": False, "phase": "preRequest", "metadata": {"requestName": "users.getUsers"},
            "canCancel": True, "tl": value}})
    request = {"_": "users.getUsers", "id": [{"_": "inputUserSelf"}] * (1 if role == "first" else 2)}
    expected_priority = "7" if role == "first" else "5"
    assert runtime.hook_priority_json("pre_request_hook", "TL_users_getUsers", "users.getUsers") == expected_priority
    result = json.loads(runtime.dispatch_json("pre_request_hook", payload(request)))
    assert result["strategy"] == ("MODIFY" if role == "first" else "MODIFY_FINAL")
    assert len(result["request"]["id"]) == (2 if role == "first" else 3)
    assert "metadata" not in result["request"]
    if role == "first":
        for mode, strategy in (("final", "MODIFY_FINAL"), ("cancel", "CANCEL"), ("invalid", "MODIFY")):
            host.seed("mode", mode)
            result = json.loads(runtime.dispatch_json("pre_request_hook", payload(request)))
            assert result["strategy"] == strategy
            if mode == "invalid": assert result["request"]["unknown_field"] is True
        assert host.value("readonly_metadata") is True
    else: assert host.value("seen_count") == 2
    def transform(hook, name, value):
        field = "request" if hook == "pre_request_hook" else "response"
        generated = runtime._state.tl.schema.hook_names(name)[0]
        return json.loads(runtime.dispatch_json(hook, json.dumps({"account": 2, "request_name": generated, "canonical_name": name,
            field: {"schemaVersion": 1, "observational": False, "metadata": {"requestName": name}, "tl": value}})))
    text = {"_": "messages.sendMessage", "flags": 0, "peer": {"_": "inputPeerSelf"}, "message": "fixture", "random_id": 1, "silent": False}
    if role == "first":
        host.seed("mode", "silent_on")
        result = transform("pre_request_hook", "messages.sendMessage", text)
        assert result["request"]["flags"] == 32 and result["request"]["silent"] is True
        host.seed("mode", "silent_off")
        result = transform("pre_request_hook", "messages.sendMessage", result["request"])
        assert result["request"]["flags"] == 0 and result["request"]["silent"] is False
    else:
        transform("pre_request_hook", "messages.sendMessage", text)
        assert host.value("seen_silent") is False and host.value("seen_flags") == 0
    host.seed("mode", "vector_users")
    result = transform("post_request_hook", "users.getUsers", [{"_": "userEmpty", "id": 7}])
    assert result["response"] == [{"_": "userEmpty", "id": 7}] + ([{"_": "userEmpty", "id": 29}] if role == "first" else [])
    result = transform("post_request_hook", "stories.readStories", [7])
    assert result["response"] == ([7, 29] if role == "first" else [7])
    result = transform("post_request_hook", "messages.receivedQueue", [9007199254740993])
    assert result["response"] == ([9007199254740994] if role == "first" else [9007199254740993])
    # Exact normalized Mac 43735410090/cca2d83a input, including the TL field
    # "self" materialized by the shipping codec even when its bit is clear.
    user = json.loads((Path(__file__).parent / "fixtures/tl_native_user_response.json").read_text(encoding="utf-8"))["response"]["tl"]
    for mode in ("flags2_on", "flags2_off", "bot_missing", "bot_on"):
        host.seed("mode", mode)
        result = transform("post_request_hook", "users.getUsers", user)
        if role == "first":
            updated = result["response"][0]
            assert updated["flags2"] == (5 if mode == "flags2_on" else 1)
            assert updated["bot"] is mode.startswith("bot_")
            if mode == "bot_on": assert updated["bot_info_version"] == 9
        else: assert host.value("seen_bot") is False
    runtime.unload()
    assert bridge.xt_handle_count() == 0


if __name__ == "__main__":
    worker(sys.argv[1], sys.argv[2])
else:
    import pytest
    @pytest.mark.parametrize("role", ("first", "second"))
    def test_native_tl_python_fixture(role, tmp_path):
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), role, str(tmp_path)],
                                cwd=tmp_path, text=True, encoding="utf-8", capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
