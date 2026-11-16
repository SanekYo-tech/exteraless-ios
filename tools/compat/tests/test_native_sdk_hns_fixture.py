"""Execute the exact HNS native-child Python fixture in bounded SDK unit workers.

These checks validate the fixture and real SDK cleanup. The worker-time native
revocation/FIFO and nonterminal Host evidence still require the Swift/C child.
"""

import importlib.util
import json
import re
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]


def worker(case, directory):
    sys.path.insert(0, str(ROOT / "python"))
    spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))
    support = importlib.util.module_from_spec(spec); spec.loader.exec_module(support)
    class Host(support.StrictNativeHost):
        def __init__(self, root):
            super().__init__(root)
            self.retiring = False
            self.entries = {}
            self.retired = []
            self.cleanups = []
            self.serial = 0
            self.exports = {"postToOwner", "cancelOwnerTask", "nativeServiceCancel", "notificationUnsubscribe",
                "nativeGetUser", "nativeDownload", "nativeObservePeer", "notificationSupported", "notificationSubscribe", "uiPresent", "uiDismiss"}

        def call(self, request):
            request = dict(request)
            token = request.pop("ownerToken", None)
            member, args = request["member"], request["args"]
            if request["op"] == "member_kind": return "method" if member in self.exports else "unknown"
            if member in ("cancelOwnerTask", "nativeServiceCancel", "notificationUnsubscribe", "uiDismiss"):
                entry = self.entries.get(args[0])
                matched = entry is not None and entry[2] == token
                if matched:
                    self.entries.pop(args[0])
                    self.retired.extend(entry[1])
                    if not self.retiring: runtime.release_handles_json(json.dumps(entry[1]))
                self.cleanups.append((member, matched))
                return None if member == "uiDismiss" else matched
            if member in self.exports:
                if self.retiring: raise RuntimeError("HNS fixture owner is retired")
                assert token == self.owner_token
                if member == "notificationSupported":
                    source = (ROOT / "swift/PluginHost/Sources/PluginHost/NativeServiceOperations.swift").read_text(encoding="utf-8")
                    return [{"id": int(ident), "name": name} for name, ident in re.findall(r"case\s+(\w+)\s*=\s*(\d+)", source)]
                self.serial += 1
                ident = "hns-native-" + str(self.serial)
                if member == "uiPresent":
                    assert len(args[2]) == 9
                    handles = [self.register(fn) for fn in args[2].values()]
                else:
                    if member == "postToOwner": assert args[1:] == [60000, "PLUGINS_QUEUE"]
                    handles = [self.register(args[0] if member == "postToOwner" else args[1])]
                self.entries[ident] = (member, handles, token)
                return {"id": ident}
            return super().call(request)
    support.StrictNativeHost = Host
    runtime, host, bridge = support.bootstrap(Path(directory), "nativeHNSSdk")
    host.permissions = {"ui", "messages.read", "network", "files"}
    runtime.bind_owner_json('"unit-hns-native-fixture-epoch"')
    source = ROOT / "python/runtime/smoke/plugins/native_hns_probe.plugin"
    plugin_path = host.plugins / "nativeHNSSdk.plugin"
    shutil.copyfile(source, plugin_path)
    runtime.load_json(str(plugin_path))
    helper_spec = importlib.util.spec_from_file_location("_native_hns_unit_fixture", ROOT / "python/runtime/smoke/native_hns_probe.py")
    helper = importlib.util.module_from_spec(helper_spec); helper_spec.loader.exec_module(helper)
    checks = json.loads(helper.loaded())["handle"]
    assert len(json.loads(runtime.invoke_handle_json(checks, "notifications_table", "[]"))) == 12
    rows = json.loads(runtime.dispatch_json("create_settings", '{"account":41}'))
    runtime.setting_changed_json("enabled", "false", 41)
    runtime.setting_click_json(rows[1]["callback_id"], 41)
    assert host.value("enabled") is False and host.value("change_account") == host.value("click_account") == 41
    if case == "cleanup":
        pending = json.loads(runtime.invoke_handle_json(checks, "pending", "[]"))
        assert type(pending["task"]) is str and host.entries[pending["task"]][0] == "postToOwner"
        assert len(pending["handles"]) == 12 and bridge.xt_handle_count() == 13 and len(host.entries) == 4
        host.retiring = True
        runtime.unload()
        assert sorted(member for member, changed in host.cleanups if changed) == sorted(["cancelOwnerTask", "nativeServiceCancel", "notificationUnsubscribe", "uiDismiss"])
        assert sorted(host.retired) == pending["handles"] and len(set(host.retired)) == 12
        assert host.value("unloads") == 1 and host.value("retiring_admission_rejected") is True
    else:
        model = json.loads(runtime.invoke_handle_json(checks, "callbacks", "[true]"))
        ident = model["ids"][0]
        _, handles, _ = host.entries.pop(ident)
        assert runtime.invoke_handle_json(handles[0], "run", '[{"fixture":true},null]') == "null"
        assert bridge.xt_handle_count() == 2, "SDK released a native-owned handle before FIFO control"
        runtime.release_handles_json(json.dumps(handles))
        assert runtime.invoke_handle_json(checks, "after_callbacks", '[["user"]]') == "true"
        host.retiring = True
        runtime.unload()
    assert bridge.xt_handle_count() == 0 and not host.entries
    assert not runtime._state.callbacks.leases


if __name__ == "__main__":
    worker(sys.argv[1], sys.argv[2])
else:
    import pytest
    @pytest.mark.parametrize("case", ("cleanup", "terminal"))
    def test_native_hns_python_fixture(case, tmp_path):
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(tmp_path)],
                                cwd=tmp_path, text=True, encoding="utf-8", capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
