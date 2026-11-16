"""Bounded original-SDK regressions; only native services are strict recorders.

Uses actual gen/gen2/lazy aliases, dev_server.dispatch, ElyxPluginState and the
configured worker invocation. Optional existing C extension supplies real handle
identity and BridgeBackend, not a fake Java interface or a copied SDK helper.
Each child, including OWN_GIL creation/destruction, has a 20-second outer limit.
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import threading
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
OWNER = "sdkDeveloperProbe"


def bootstrap(directory, bridge_path=None):
    spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", HERE / "test_ios_runtime.py")
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)
    runtime, host, bridge = support.bootstrap(directory, OWNER, configure=False)
    native_bridge = None
    if bridge_path:
        # Preserve the fixture's native-service transport, but use genuine C
        # handle operations and the real generic proxy backend. This does not
        # claim that the recorder is NativeBridgeBinding/Swift.
        spec = importlib.util.spec_from_file_location("_exteraless_bridge", bridge_path)
        native_bridge = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(native_bridge)
        import virtualjava
        native_bridge.xt_bind(virtualjava.JavaInstance, virtualjava.JavaMemberError)
        for name in ("xt_register_handle", "xt_resolve_handle", "xt_release_handle", "xt_clear_handles", "xt_handle_count"):
            setattr(bridge, name, getattr(native_bridge, name))
        bridge.BridgeBackend = native_bridge.BridgeBackend
        virtualjava.uninstall()
        virtualjava.reset_class_cache()
        virtualjava.install(native_bridge.BridgeBackend(service="sdk-developer-no-service"))
    runtime.configure(OWNER, str(host.plugins), str(host.settings))
    runtime.bind_owner_json(json.dumps("own-sdk-developer-epoch"))
    # StrictNativeHost's basic service reader predates owner epochs. Peel only
    # this fixture's expected transport stamp before its existing exact reader.
    original_call = host.call

    def owned_call(request):
        request = dict(request)
        assert request.pop("ownerToken", None) == host.owner_token
        return original_call(request)

    host.call = owned_call
    path = host.plugins / "owner.plugin"
    shutil.copyfile(HERE / "fixtures/sdk_developer/owner.plugin", path)
    runtime.load_json(str(path))
    return runtime, host, bridge, native_bridge, support.raises


def proxy_case(directory, bridge_path=None):
    runtime, host, bridge, native_bridge, raises = bootstrap(directory, bridge_path)
    import virtualjava
    from virtualjava.proxy import DynamicProxyMeta
    from java import dynamic_proxy, jclass
    from elyx_runtime import facade
    import elyx
    from exteraless_runtime import _codec

    assert Path(facade.gen.__code__.co_filename).resolve() == ROOT / "python/sdk/elyx_runtime/facade.py"
    assert Path(facade.gen2.__code__.co_filename).resolve() == ROOT / "python/sdk/elyx_runtime/facade.py"
    sentinel = object()
    seen = []

    def invoke(proxy, method, values):
        handle = bridge.xt_register_handle(proxy)
        assert bridge.xt_register_handle(proxy) == handle
        assert bridge.xt_resolve_handle(handle) is proxy
        raw = runtime.invoke_handle_json(handle, method, _codec.dumps(values, bridge))
        return _codec.decode(json.loads(raw), bridge)

    def observe(*args):
        seen.append(args)
        return sentinel

    for alias, arguments in (("Callback", [sentinel]), ("Callback2", [sentinel, "\u96ea"]),
                             ("Callback3", [sentinel, 7, False]), ("CallbackReturn", [sentinel])):
        interface_name, method, returns = facade._PROXY_SPECS[alias]
        interface = jclass(interface_name)
        assert virtualjava.get_registered(interface_name) is None, "must exercise generic proxy construction"
        proxy_type = facade.gen(interface, method, return_value=returns)
        assert isinstance(proxy_type, DynamicProxyMeta)
        assert getattr(elyx, alias) is proxy_type
        assert facade.gen(interface, method, return_value=returns) is proxy_type
        proxy = proxy_type(observe, "extra")
        other = proxy_type(observe)
        assert proxy is not other and proxy != other and len({proxy, other}) == 2
        assert isinstance(proxy, interface) and proxy._fqcn == interface_name
        assert proxy._backend is virtualjava.finder._State.backend
        assert invoke(proxy, method, arguments) is (sentinel if returns else None)
        assert seen[-1] == (*arguments, "extra") and seen[-1][0] is sentinel
        generated = facade.gen2(interface, return_value=returns, **{method: observe})()
        assert isinstance(generated, interface)
        assert invoke(generated, method, arguments) is (sentinel if returns else None)
        assert seen[-1] == tuple(arguments)

    for alias, arguments in (("Runnable", []), ("OnClickListener", [sentinel])):
        proxy = getattr(elyx, alias)(observe, "local")
        assert invoke(proxy, facade._PROXY_SPECS[alias][1], arguments) is None
        assert seen[-1] == (*arguments, "local")

    seekbar = jclass("android.widget.SeekBar$OnSeekBarChangeListener")
    multi = facade.gen2(seekbar, onProgressChanged=lambda *args: seen.append(("progress", *args)),
                        onStartTrackingTouch=lambda *args: seen.append(("start", *args)),
                        onStopTrackingTouch=lambda *args: seen.append(("stop", *args)))()
    for method, arguments, label in (("onProgressChanged", [sentinel, 5, True], "progress"),
                                     ("onStartTrackingTouch", [sentinel], "start"),
                                     ("onStopTrackingTouch", [sentinel], "stop")):
        assert invoke(multi, method, arguments) is None
        assert seen[-1] == (label, *arguments)

    first = jclass("org.telegram.messenger.Utilities$Callback")
    second = jclass("org.telegram.messenger.Utilities$Callback2")

    class OwnCallback(dynamic_proxy(first, second)):
        def __init__(self, value):
            super().__init__()
            self.value = value

        def run(self, *args):
            return self.value

    own = OwnCallback(sentinel)
    assert isinstance(own, first) and isinstance(own, second)
    assert invoke(own, "run", [1, 2]) is sentinel
    assert own._fqcn == first.__name__
    raises(TypeError, lambda: dynamic_proxy(first)(123))
    raises(TypeError, lambda: dynamic_proxy(first, jclass("java.lang.Runnable")))
    raises(TypeError, virtualjava.JavaInstance)
    ordinary = virtualjava.JavaInstance("own.native.Value", virtualjava.finder._State.backend)
    assert ordinary._fqcn == "own.native.Value"

    def fail(*args):
        raise ValueError("own callback failure")

    fallback = facade.gen(jclass("org.telegram.messenger.Utilities$Callback2Return"), "run", True, sentinel)(fail)
    with contextlib.redirect_stderr(io.StringIO()) as errors:
        assert invoke(fallback, "run", [1, 2]) is sentinel
        assert invoke(facade.gen2(first, run=fail)(), "run", [1]) is None
        assert invoke(elyx.CallbackReturn(fail), "run", [1]) is None
    assert "own callback failure" in errors.getvalue()
    stale = bridge.xt_register_handle(own)
    assert bridge.xt_release_handle(stale) is True
    raises(LookupError, lambda: runtime.invoke_handle_json(stale, "run", "[]"), "unknown callback handle")
    runtime.unload()
    assert bridge.xt_handle_count() == 0
    if native_bridge is not None:
        assert type(bridge.xt_resolve_handle) is type(len)
        assert type(virtualjava.finder._State.backend) is native_bridge.BridgeBackend
        assert native_bridge.xt_handle_count() == 0 and not native_bridge.xt_mock_log()
    return {"original_helpers": True, "c_handles": native_bridge is not None,
            "c_owner_epoch_api": native_bridge is not None and hasattr(native_bridge, "xt_set_owner_token")}


def command_case(directory):
    runtime, host, bridge, _, _ = bootstrap(directory)
    from exteraless_runtime import _developer
    import dev_server
    import elyx_runtime
    from elyx_runtime import loader, dev_commands, namespace

    original_dispatch = dev_server.dispatch
    _developer.install(runtime._state)
    assert dev_server.dispatch is original_dispatch
    assert Path(dev_commands.handle_dev_command.__code__.co_filename).resolve() == ROOT / "python/sdk/elyx_runtime/dev_commands.py"
    dev_server._token = "own-interpreter-token-not-native-auth"
    calls = []

    def profile(frame, event, arg):
        if event == "call" and frame.f_code is dev_commands.handle_dev_command.__code__:
            calls.append((frame.f_locals["command"], frame.f_locals["params"]))

    sys.setprofile(profile)
    try:
        assert dev_server.dispatch({"@": "ping", "#": 1}) == {"#": 1, "ok": True, "pong": True}
        for command in ("elyx_ping", "get_elyx_plugins"):
            for token in (None, "incorrect"):
                assert dev_server.dispatch({"@": command, "#": 2, "token": token}) == {
                    "#": 2, "ok": False, "error": "bad or missing token"}
        assert not calls, "authentication must happen before the original Elyx handler"
        request = {"@": "elyx_ping", "#": "\u96ea", "token": dev_server._token, "own_param": 7}
        before = dict(request)
        assert dev_server.dispatch(request) == {"#": "\u96ea", "ok": True, "elyx": True, "version": elyx_runtime.__version__}
        assert calls[-1] == ("elyx_ping", {"own_param": 7}) and request == before
        assert not loader._states
        assert dev_server.dispatch({"@": "get_elyx_plugins", "token": dev_server._token})["plugins"] == []
        root = str(host.files)
        state = loader.ElyxPluginState(OWNER, str(host.plugins / "own.elyx"), str(host.plugins), "own-digest", root,
            [], {"main": "main.py"}, {"id": OWNER, "name": "Own in-memory Elyx state"},
            namespace.PluginNamespace(OWNER, root, [root]), {})
        loader._states[OWNER] = state
        result = dev_server.dispatch({"@": "get_elyx_plugins", "#": 4, "token": dev_server._token})
        assert result == {"#": 4, "ok": True, "plugins": [{**state.metainfo, "archive_path": state.archive_path, "extract_dir": root}]}
        unknown = dev_server.dispatch({"@": "elyx_unknown", "#": 5, "token": dev_server._token})
        assert unknown["ok"] is False and unknown["error"] == "unknown Elyx command 'elyx_unknown'"
        assert calls[-1] == ("elyx_unknown", {})
    finally:
        sys.setprofile(None)
        loader._states.pop(OWNER, None)
        runtime.unload()
    assert bridge.xt_handle_count() == 0
    return {"original_dispatch_and_handler": True, "handler_calls": len(calls)}


def developer_case(directory):
    runtime, host, bridge, _, raises = bootstrap(directory)
    from exteraless_runtime import _developer, RuntimeStateError
    import dev_server
    import virtualjava

    state = {"enabled": False, "ready": False, "status": "Stopped"}
    methods = {"getDeveloperServerState", "requestDeveloperServerStart", "requestDeveloperServerStop"}
    attempts, logs, developer_calls = [], [], []
    outcomes = {"reply": {"accepted": True, "operationId": "own-native-admission"}, "failure": None}
    original_transport = bridge.xt_call_host

    def transport(request):
        member = request["member"]
        if request["fqcn"] != "exteraless.ios.Runtime" or member not in methods:
            return original_transport(request)
        developer_calls.append(member)
        if request["op"] == "member_kind":
            return "method" if outcomes.get("available", True) else "unknown"
        assert request["op"] == "call" and not request["args"] and not request["kwargs"]
        assert "settings" in host.permissions
        if outcomes["failure"]:
            raise virtualjava.JavaMemberError(outcomes["failure"])
        if member == "getDeveloperServerState":
            return dict(state)
        attempts.append(member)
        return outcomes["reply"]

    bridge.xt_call_host = transport
    threads = threading.enumerate()
    with patch.object(dev_server, "_log", logs.append), \
         patch.object(dev_server, "_Server", side_effect=AssertionError("Python listener constructed")), \
         patch.object(dev_server, "_publish_token", side_effect=AssertionError("native token published by Python")), \
        patch.object(threading, "Thread", side_effect=AssertionError("Python listener thread constructed")):
        _developer.install(runtime._state)
        assert not developer_calls and not attempts, "install must not auto-start or query native controls"
        assert dev_server.start() is False and not runtime._state.loader._dev_server_started
        assert not attempts, "SDK start cannot enable native developer mode"
        state.update(enabled=True, status="Starting 127.0.0.1:42690")
        for _ in range(2):
            assert runtime._state.loader.start_dev_server() is None
            assert runtime._state.loader._dev_server_started is False
        assert attempts == ["requestDeveloperServerStart"] * 2, "pending/failure must permit retry"
        state.update(ready=True, status="Listening on 127.0.0.1:42690")
        assert dev_server.start() is True and runtime._state.loader._dev_server_started is True
        assert len(attempts) == 2
        state.update(ready=False, status="Developer server failed: own fixture port busy")
        assert dev_server.start() is False and runtime._state.loader._dev_server_started is False
        assert "port busy" in logs[-1]
        state.update(ready=True, status="Listening on 127.0.0.1:42690")
        assert dev_server.start() is True
        assert dev_server.stop() is None and attempts[-1] == "requestDeveloperServerStop"
        assert state["ready"] is True, "admission must not fabricate completed native stop"
        assert runtime._state.loader._dev_server_started is False
        state.update(ready=False, enabled=False, status="Stopped")
        assert dev_server.start() is False

        state.update(enabled=True, status="Starting")
        for failure in ("native owner epoch retired", "native developer command queue is full"):
            outcomes["failure"] = failure
            assert dev_server.start() is False and failure in logs[-1]
            assert runtime._state.loader._dev_server_started is False
        outcomes["failure"] = None
        for reply in (True, {"accepted": False, "operationId": "no"}, {"accepted": True, "operationId": ""}):
            outcomes["reply"] = reply
            assert dev_server.start() is False and "did not admit" in logs[-1]
            raises(RuntimeStateError, dev_server.stop, "did not admit")
        outcomes["reply"] = {"accepted": True, "operationId": "retry"}
        assert dev_server.start() is False
        outcomes["available"] = False
        assert dev_server.start() is False and "Runtime.getDeveloperServerState" in logs[-1]
        outcomes["available"] = True
        for invalid in ({"ready": 1}, {"ready": True, "enabled": False}, {"token": "must-not-cross-to-python"}):
            saved = dict(state)
            state.update(invalid)
            assert dev_server.start() is False and "native developer state must be" in logs[-1]
            assert "must-not-cross-to-python" not in logs[-1]
            state.clear(); state.update(saved)
        before = len(attempts)
        host.permissions.remove("settings")
        assert dev_server.start() is False and "settings permission" in logs[-1]
        raises(PermissionError, dev_server.stop, "settings permission")
        assert len(attempts) == before
        host.permissions.add("settings")
        epoch = runtime._state.owner_token
        runtime._state.owner_token = None
        assert dev_server.start() is False and "bound native owner epoch" in logs[-1]
        runtime._state.owner_token = epoch

        dev_server._token = "own-local-token"
        count = len(host.calls)
        before = len(attempts)
        for command in ("get_plugins", "enable_plugin", "disable_plugin", "reload_plugin", "write_plugin", "remove_plugin"):
            result = dev_server.dispatch({"@": command, "#": 8, "token": dev_server._token, "plugin_id": OWNER})
            assert result["#"] == 8 and result["ok"] is False
            assert "grants no manager authority" in result["error"]
        debugger = dict(dev_server._debugger)
        assert "debugpy" not in sys.modules
        for command in ("start_debugger", "stop_debugger"):
            result = dev_server.dispatch({"@": command, "token": dev_server._token})
            assert result["ok"] is False and "allow_daemon_threads=false" in result["error"]
        assert dev_server._debugger == debugger and "debugpy" not in sys.modules
        assert len(host.calls) == count and len(attempts) == before
        assert dev_server._server is None and dev_server._failed is False
    assert threading.enumerate() == threads
    bridge.xt_call_host = original_transport
    runtime.unload()
    assert bridge.xt_handle_count() == 0
    return {"native_service_recorder": True, "admissions": len(attempts), "python_listener_threads": 0}


def worker(case, directory, yaml_path, bridge_path=None):
    assert sys.flags.isolated and sys.flags.no_site and sys.dont_write_bytecode
    sys.path[:0] = [str(ROOT / "python"), yaml_path]
    if case == "own_gil":
        import concurrent.interpreters as interpreters
        import _interpreters
        interpreter = interpreters.create()
        try:
            config = _interpreters.get_config(interpreter.id)
            assert config.gil == "own" and not config.allow_daemon_threads
            assert not config.allow_fork and not config.allow_exec
            interpreter.exec(
                "import threading\n"
                "try:\n"
                "    threading.Thread(target=lambda: None, daemon=True)\n"
                "except RuntimeError as error:\n"
                "    assert 'daemon' in str(error), str(error)\n"
                "else:\n"
                "    raise AssertionError('OWN_GIL fixture admitted a daemon thread')\n"
                "import runpy\n"
                f"test = runpy.run_path({str(Path(__file__).resolve())!r}, run_name='_developer_fixture_support')\n"
                f"test['worker']('developer', {str(directory)!r}, {yaml_path!r})\n")
        finally:
            interpreter.close()
        result = {"own_gil_created_and_destroyed": True, "daemon_policy_rejection": True}
    elif case == "proxy":
        result = proxy_case(Path(directory), bridge_path)
    elif case == "command":
        result = command_case(Path(directory))
    else:
        result = developer_case(Path(directory))
    print("SDK_DEVELOPER_PROXY_OK " + json.dumps({"case": case, **result}, sort_keys=True))


if __name__ == "__main__":
    worker(*sys.argv[1:])
elif __name__ != "_developer_fixture_support":
    import pytest

    @pytest.mark.parametrize("case", ("proxy", "proxy_c", "command", "developer", "own_gil"))
    def test_sdk_developer_proxy(case, tmp_path):
        yaml_spec = importlib.util.find_spec("yaml")
        assert yaml_spec is not None, "original Elyx imports require an existing PyYAML installation"
        arguments = []
        if case == "proxy_c":
            found = importlib.machinery.PathFinder.find_spec("_exteraless_bridge", [str(ROOT / "python/bridge")])
            if found is None:
                pytest.skip("no existing C extension for this Python ABI; pure-SDK case remains required")
            arguments = [found.origin]
            case = "proxy"
        if case == "own_gil" and importlib.util.find_spec("concurrent.interpreters") is None:
            pytest.skip("OWN_GIL creation fixture requires Python 3.14 concurrent.interpreters")
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case,
                                 str(tmp_path), str(Path(yaml_spec.origin).parent.parent), *arguments],
                                cwd=tmp_path, capture_output=True, text=True, encoding="utf-8", timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        summaries = [line for line in result.stdout.splitlines() if line.startswith("SDK_DEVELOPER_PROXY_OK ")]
        assert summaries
        print("\n".join(summaries))
