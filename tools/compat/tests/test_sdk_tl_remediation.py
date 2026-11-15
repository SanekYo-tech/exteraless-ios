"""Real SDK calls in fresh <=20s workers; native-recording unit transport only.

Swift/C/codec evidence belongs to the SDK native probe, not this Python receipt.
"""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
CASES = ("cancel_winner", "text_routes", "vector_roots", "boolean_flags")


def worker(case, directory):
    sys.path.insert(0, str(ROOT / "python"))
    spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))
    support = importlib.util.module_from_spec(spec); spec.loader.exec_module(support)

    class Host(support.StrictNativeHost):
        def __init__(self, root):
            super().__init__(root)
            self.requests, self.trace = {}, []
            self.serial = 0
            self.cancel_mode = "true"
            self.early = False

        def call(self, request):
            request = dict(request)
            token = request.pop("ownerToken", None)
            member, args = request["member"], request["args"]
            if member in ("tlRequest", "sendMedia", "editMedia", "tlCancel"):
                assert token == self.owner_token
                if member == "tlCancel":
                    self.trace.append((member, args[0]))
                    if self.cancel_mode == "throw": raise RuntimeError("fixture cancellation transport failed")
                    if self.cancel_mode == "false": return {"cancelled": False}
                    if self.cancel_mode == "malformed": return {"cancelled": 1}
                    record = self.requests.pop(args[0], None)
                    if record: runtime.release_handles_json(json.dumps([record[2]]))
                    return {"cancelled": record is not None}
                model, callback = args
                permission = "network" if member == "tlRequest" else "messages.send"
                if permission not in self.permissions: raise PermissionError(permission)
                assert model["schemaVersion"] == 1 and model["account"] == 2
                self.serial += 1
                ident = "native-tl-" + str(self.serial)
                handle = self.register(callback)
                self.requests[ident] = (member, model, handle)
                self.trace.append((member, model))
                if self.early:
                    runtime.invoke_handle_json(handle, "run", '[[],null]')
                    runtime.release_handles_json(json.dumps([handle]))
                    self.requests.pop(ident)
                return {"requestId": ident}
            if member == "getPeer": raise AssertionError("high-level send required messages.read")
            return super().call(request)

        def finish(self, token, value, error=None, *, release=True):
            _, _, handle = self.requests.pop(token.native_id)
            result = runtime.invoke_handle_json(handle, "run", json.dumps([value, error]))
            if release: runtime.release_handles_json(json.dumps([handle]))
            return handle, result

    support.StrictNativeHost = Host
    runtime, host, bridge = support.bootstrap(Path(directory), "sdkTLRemediation")
    host.permissions = {"network", "messages.send", "messages.read"}
    runtime.bind_owner_json('"unit-tl-remediation-epoch"')
    plugin_path = host.plugins / "sdkTLRemediation.plugin"
    plugin_path.write_text('''__id__ = "sdkTLRemediation"
__name__ = "Own bounded TL SDK fixture"
from base_plugin import BasePlugin, HookResult, HookStrategy
from java import jclass
class Fixture(BasePlugin):
    def on_plugin_load(self):
        self.add_hook("users.getUsers")
        self.add_hook("contacts.getContactIDs")
    def post_request_hook(self, name, account, response, error):
        assert isinstance(response, jclass("org.telegram.tgnet.Vector"))
        assert response._exteraless_tl_context["metadata"]["requestName"] == name
        if name == "users.getUsers": response.objects.add(jclass("org.telegram.tgnet.TLRPC$TL_userEmpty")(id=29))
        else: response.objects.add(jclass("org.telegram.tgnet.Vector$Int")(29))
        return HookResult(HookStrategy.MODIFY, response=response)
''', encoding="utf-8")
    runtime.load_json(str(plugin_path))
    from extera_utils import plugin_loader as loader
    import client_utils as client
    from java import jclass
    from exteraless_runtime import RuntimeStateError, UnsupportedSurfaceError
    from exteraless_runtime._tl import RequestToken, Requests, to_wire
    schema = runtime._state.tl.schema
    raises = support.raises
    with loader.plugin_context(host.plugin_id):
        if case == "cancel_winner":
            calls = []
            request = {"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]}
            for mode in ("false", "throw", "malformed"):
                token = client.send_request(request, lambda value, error: calls.append((value.objects[0].id, client.get_hook_account())), 2)
                lease = runtime._state.tl.pending[int(token)]
                host.cancel_mode = mode
                if mode == "false": assert token.cancel() is False
                else: raises(RuntimeError, token.cancel, "transport" if mode == "throw" else "cancelled")
                assert lease.open and runtime._state.tl.pending[int(token)] is lease
                handle, result = host.finish(token, [{"_": "userEmpty", "id": len(calls) + 1}], release=False)
                assert result == "null" and not lease.open and int(token) not in runtime._state.tl.pending
                assert handle in host.handles, "SDK released a native-owned terminal before FIFO control"
                raises(RuntimeStateError, lambda: runtime.invoke_handle_json(handle, "run", '[[],null]'), "closed plugin")
                runtime.release_handles_json(json.dumps([handle]))
                assert handle not in host.handles
            assert calls == [(1, 2), (2, 2), (3, 2)]
            host.cancel_mode = "true"
            old = client.send_request(request, lambda *_: calls.append("cancelled body"), 2)
            assert old.cancel() is True
            current = client.send_request(request, lambda *_: None, 2)
            before = len(host.trace)
            assert old.cancel() is False
            assert runtime._state.tl.cancel(RequestToken(int(current), runtime._state.tl, old.native_id)) is False
            assert runtime._state.tl.cancel(RequestToken(int(current), Requests(runtime._state, schema), current.native_id)) is False
            assert len(host.trace) == before and current.cancel() is True
            assert len(calls) == 3
            host.early = True
            completed = client.send_request(request, lambda *_: None, 2)
            assert completed.cancel() is False and not runtime._state.tl.pending
            assert bridge.xt_handle_count() == 0
        elif case == "text_routes":
            host.permissions = {"messages.send"}
            token = client.send_text(42, "**native**", replyToMsg={"id": 7, "namespace": 1}, parse_mode="Markdown", account=2)
            member, model, _ = host.requests[token.native_id]
            assert member == "sendMedia" and model == {"schemaVersion": 1, "account": 2, "peer": {"type": "user", "id": 42},
                "kind": "text", "caption": "native", "entities": [{"_": "messageEntityBold", "offset": 0, "length": 6}], "replyTo": {"id": 7, "namespace": 1}}
            assert not any(key in model for key in ("random_id", "access_hash", "request"))
            host.finish(token, {"status": "enqueued", "messageIds": [{"id": 71, "namespace": 1}]})
            token = client.send_message({"peer": 42, "message": "scheduled", "entities": [], "notify": True,
                "searchLinks": False, "scheduleDate": 1700000123, "replyToTopMsg": 7}, account=2)
            model = host.requests[token.native_id][1]
            assert model["silent"] is False and model["entities"] == [] and model["scheduleTime"] == 1700000123
            assert model["threadId"] == 7 and model["disableLinkPreviews"] is True
            # Native preparation owns paid/restricted rejection; SDK logs the real
            # terminal error and performs no secondary raw request.
            host.finish(token, None, {"_": "error", "code": 403, "text": "PAID_MESSAGES_UNSUPPORTED"})
            target = {"peer": {"type": "user", "id": 42}, "id": 7, "namespace": 3}
            token = client.edit_message(target, account=2)
            member, model, _ = host.requests[token.native_id]
            assert member == "editMedia" and model["kind"] == "text" and model["message"] == {"id": 7, "namespace": 3}
            assert {"caption", "entities", "spoiler"}.isdisjoint(model)
            token.cancel()
            token = client.edit_message(target, text="", with_spoiler=False, account=2)
            model = host.requests[token.native_id][1]
            assert model["caption"] == "" and model["spoiler"] is False and "entities" not in model
            token.cancel()
            token = client.edit_message(target, text="**edit**", parse_mode="Markdown", account=2)
            assert host.requests[token.native_id][1]["entities"] == [{"_": "messageEntityBold", "offset": 0, "length": 4}]
            token.cancel()
            before = len(host.trace)
            raises(TypeError, lambda: client.send_message({"peer": 42, "message": "x", "notify": 1}, account=2), "Bool")
            raises(ValueError, lambda: client.send_message({"peer": 42, "message": "x", "scheduleDate": True}, account=2), "Int32")
            raises(UnsupportedSurfaceError, lambda: client.send_message({"peer": 42, "message": "x", "payStars": 9}, account=2), "payStars")
            raises(UnsupportedSurfaceError, lambda: client.send_message({"peer": 42, "message": "x", "replyMarkup": {}}, account=2), "replyMarkup")
            assert len(host.trace) == before and not runtime._state.tl.pending
        elif case == "vector_roots":
            values = []
            for name, fields, response in (("users.getUsers", {"id": []}, [{"_": "userEmpty", "id": 7}]),
                ("contacts.getContactIDs", {"hash": 0}, [-1, 7]), ("messages.receivedQueue", {"max_qts": 0}, [9007199254740993])):
                token = client.send_request(dict(fields, _=name), lambda value, error: values.append(value), account=2)
                host.finish(token, response)
                result = values[-1]
                assert isinstance(result, jclass("org.telegram.tgnet.Vector")) and result._definition is None
                assert result._exteraless_tl_context is None and to_wire(result) == response
                assert result.getClass().getName() == "org.telegram.tgnet.Vector"
            assert values[0].objects[0].id == 7
            assert list(values[1].toIntArray()) == [-1, 7]
            assert isinstance(values[2].objects[0], jclass("org.telegram.tgnet.Vector$Long"))
            assert values[2].objects[0].value == 9007199254740993 and list(values[2].toIntArray()) == []
            nested = schema.decode({"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]})
            assert type(nested.id) is jclass("java.util.ArrayList") and not hasattr(nested.id, "objects")
            for name, response in (("users.getUsers", [{"_": "userEmpty", "id": 7}]), ("contacts.getContactIDs", [7])):
                payload = {"account": 2, "request_name": name, "canonical_name": name, "response": {"schemaVersion": 1,
                    "observational": False, "metadata": {"requestName": name}, "tl": response}}
                result = json.loads(runtime.dispatch_json("post_request_hook", json.dumps(payload)))
                assert result == {"strategy": "MODIFY", "response": response + ([{"_": "userEmpty", "id": 29}] if name.startswith("users") else [29])}
            raises(ValueError, lambda: jclass("org.telegram.tgnet.Vector$Int")(True), "Int32")
        elif case == "boolean_flags":
            request = schema.decode({"_": "messages.sendMessage", "flags": 0, "peer": {"_": "inputPeerSelf"},
                "message": "fixture", "random_id": 1, "silent": False})
            request.silent = True
            assert request.flags == 32 and to_wire(request)["flags"] == 32
            request.silent = False
            assert request.flags == 0 and request.to_dict()["flags"] == 0
            request.flags = 1 << 31
            request.silent = True
            assert to_wire(request)["flags"] == (1 << 31) | 32, "unknown bits were sanitized instead of left to native rejection"
            raises(TypeError, lambda: setattr(request, "silent", 1), "Bool")
            user = schema.decode({"_": "user", "id": 1, "flags": 0, "flags2": 0, "bot": False, "close_friend": False})
            user.close_friend = True
            user.bot = True
            wire = to_wire(user)
            assert wire["flags2"] == 4 and wire["flags"] == 16384 and "bot_info_version" not in wire
            user.bot_info_version = 9
            assert to_wire(user)["bot_info_version"] == 9
            user.bot = False
            assert to_wire(user)["flags"] == 0 and to_wire(user)["bot_info_version"] == 9, "shared companion was silently removed"
            # The real native normalization/strict shared-bit rejection is tested
            # in swift_sdk_tl_probe, not asserted from this Python-only transport.
    runtime.unload()
    assert not host.requests and bridge.xt_handle_count() == 0


if __name__ == "__main__":
    worker(sys.argv[1], sys.argv[2])
else:
    import pytest
    @pytest.mark.parametrize("case", CASES)
    def test_tl_remediation(case, tmp_path):
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(tmp_path)],
                                cwd=tmp_path, text=True, encoding="utf-8", capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
