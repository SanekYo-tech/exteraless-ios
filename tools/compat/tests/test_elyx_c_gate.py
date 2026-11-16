"""Real xt_elyx_source ABI gate; explicit C recorder, never an FD registry.

Build from current source with this file's `build TARGET_PYTHON OUTPUT` command.
The driver may be the installed setuptools Python; TARGET_PYTHON supplies its
own headers, import library and extension suffix. No in-place extension is used.
EXTERALESS_ELYX_C_GATE names that freshly staged, source-fingerprinted extension.
Every test runs in a fresh <=30-second child without importing the SDK/archives.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import weakref


ROOT = Path(__file__).resolve().parents[3]
BRIDGE = ROOT / "python/bridge/_exteraless_bridge.c"
HEADER = ROOT / "python/runtime/include/EXLPythonBridge.h"
FIXTURE = Path(__file__).parent / "fixtures/elyx_c_gate_probe.c"
CONTRACT = ROOT / "docs/wave-2/elyx-source-descriptor-v1.json"
OPS = ("claim", "manifest", "read", "check", "release")
CASES = ("preflight", "identity", "responses", "retention", "terminal", "legacy_bypass", "own_gil")


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(target, output):
    from setuptools._distutils.ccompiler import new_compiler
    target, output = Path(target).resolve(), Path(output).resolve()
    assert not output.is_relative_to(ROOT), "build-lib/build-temp must be outside the repository"
    config = json.loads(subprocess.check_output([str(target), "-I", "-S", "-B", "-c",
        "import json,sys,sysconfig;print(json.dumps({'version':sys.version.split()[0],'home':sys.base_prefix,'include':sysconfig.get_path('include'),'suffix':sysconfig.get_config_var('EXT_SUFFIX'),'library':'python'+str(sys.version_info.major)+str(sys.version_info.minor)}))"],
        text=True, encoding="utf-8", timeout=20))
    pins = {p.relative_to(ROOT).as_posix(): sha(p) for p in (BRIDGE, HEADER, FIXTURE)}
    library, temporary = output / "build-lib", output / "build-temp"
    library.mkdir(parents=True, exist_ok=False)
    temporary.mkdir(parents=True, exist_ok=False)
    compiler = new_compiler(compiler="msvc" if sys.platform == "win32" else None)
    if sys.platform != "win32":
        from setuptools._distutils.sysconfig import customize_compiler
        customize_compiler(compiler)
    started = time.monotonic()
    objects = compiler.compile([str(FIXTURE)], output_dir=str(temporary),
        include_dirs=[config["include"]],
        extra_postargs=["/std:c11", "/utf-8", "/W3"] if sys.platform == "win32" else ["-std=c11", "-fPIC"])
    binary = library / ("_exteraless_bridge" + config["suffix"])
    compiler.link_shared_object(objects, str(binary),
        libraries=[config["library"]] if sys.platform == "win32" else [],
        library_dirs=[str(Path(config["home"]) / "libs")] if sys.platform == "win32" else [],
        export_symbols=["PyInit__exteraless_bridge", "PyInit__elyx_c_gate_fixture"])
    elapsed = round(time.monotonic() - started, 3)
    assert pins == {p: sha(ROOT / p) for p in pins}, "C inputs changed during this build"
    receipt = {"target": config, "compiler_driver_python": sys.version.split()[0], "source_sha256": pins,
               "compiler": str(getattr(compiler, "cc", compiler.compiler_type)), "compile_link_seconds": elapsed,
               "extension": str(binary), "extension_sha256": sha(binary),
               "contract_sha256": sha(CONTRACT),
               "instrumentation": "unchanged shipping C included by fixture; observe bridge free(), normal allocator; native C recorder and public module-clear helper",
               "native_fd_registry_tested": False}
    (output / "build-inputs.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt))


def staged_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    sys.modules[name] = module
    assert Path(module.__file__).resolve() == path
    return module


class GateError(RuntimeError):
    pass


class Instance:
    pass


def rejected(error, fn, text=None):
    try:
        fn()
    except error as failure:
        assert type(failure) is error, type(failure)
        if text is not None: assert text in str(failure), str(failure)
        return failure
    raise AssertionError("did not reject with " + error.__name__)


def worker(case, binary, report_path):
    binary = Path(binary).resolve()
    receipt = json.loads((binary.parent.parent / "build-inputs.json").read_text(encoding="utf-8"))
    assert sha(binary) == receipt["extension_sha256"]
    assert receipt["target"]["version"] == sys.version.split()[0]
    for path, pin in receipt["source_sha256"].items(): assert sha(ROOT / path) == pin, path
    assert sha(CONTRACT) == receipt["contract_sha256"]
    contract = json.loads(CONTRACT.read_text(encoding="utf-8"))
    assert tuple(contract["operations"]) == OPS and contract["descriptor_max_utf8_bytes"] == 4096
    bridge = staged_module("_exteraless_bridge", binary)
    probe = staged_module("_elyx_c_gate_fixture", binary)
    gate = bridge.xt_elyx_source
    assert type(gate) is type(len) and gate.__module__ == "_exteraless_bridge"
    checks = 0
    details = {}
    cleared = False
    expected_legacy_calls = 0
    def balanced():
        value = probe.metrics()
        assert value["buffers"] == value["freed"] and value["outstanding"] == 0, value
        assert value["active"] == value["gil_faults"] == value["released_active"] == 0, value
        return value
    def echo(operation="claim", payload="{}", owner="@elyx-inspection", token=None):
        nonlocal checks
        handles = bridge.xt_handle_count()
        value = gate(operation, payload)
        assert value["fixture"] == "native-C-recorder" and value["gil_held"] is True
        assert value["thread_id"] == threading.get_ident()
        assert value["caller"] == owner
        assert value["request"] == {"op": "elyx_source", "operation": operation, "payload": payload,
                                    "pluginId": owner, "ownerToken": token}
        assert bridge.xt_handle_count() == handles
        balanced()
        checks += 1
        return value
    try:
        if case == "preflight":
            assert probe.install("echo") == 0
            calls = probe.metrics()["calls"]
            invalid = [(), ("claim",), ("claim", "{}", "extra"), (b"claim", "{}"), ("claim", b"{}"),
                       (None, "{}"), ("claim", None), (1, "{}"), ("claim", {}), ("claim", True)]
            for args in invalid:
                rejected(TypeError, lambda: gate(*args))
                assert probe.metrics()["calls"] == calls
                checks += 1
            rejected(TypeError, lambda: gate(operation="claim", payloadJSON="{}"))
            checks += 1
            for operation in ("", "Claim", "claim ", "claim\0read", "unknown", "r" * 17, "雪" * 6):
                rejected(ValueError, lambda: gate(operation, "{}"), "operation or payload")
                assert probe.metrics()["calls"] == calls
                checks += 1
            for payload in ("", "\0", '{"x":"\0"}', "a" * 4097, "雪" * 1366):
                rejected(ValueError, lambda: gate("read", payload), "4096-byte")
                assert probe.metrics()["calls"] == calls
                checks += 1
            for args in (("\ud800", "{}"), ("read", "\udfff")):
                rejected(UnicodeEncodeError, lambda: gate(*args))
                assert probe.metrics()["calls"] == calls
                checks += 1
            assert bridge.xt_handle_count() == 0
            ascii_boundary = json.dumps("a" * 4094)
            unicode_boundary = json.dumps("雪" * 1364 + "aa", ensure_ascii=False)
            assert len(ascii_boundary.encode()) == len(unicode_boundary.encode()) == 4096
            for operation in OPS:
                echo(operation, ascii_boundary)
                echo(operation, unicode_boundary)
            rejected(ValueError, lambda: gate("claim", unicode_boundary[:-1] + 'a"'), "4096-byte")
            checks += 1
            assert probe.metrics()["calls"] == calls + 10
            # Escaped NUL is JSON text, not an embedded NUL byte. JSON syntax and
            # operation-specific schema belong to the actual native FD provider.
            echo("claim", '{"text":"\\u0000雪"}')
            echo("check", "not-json")
            details["json_syntax_is_provider_boundary"] = True

        elif case == "identity":
            assert probe.install("echo") == 0
            rejected(RuntimeError, lambda: bridge.xt_set_owner_token("too-early"), "plugin_id")
            checks += 1
            echo("manifest")
            owner, token = "Owner.ELYX-雪", "owner-π-epoch"
            bridge.xt_set_plugin_id(owner)
            echo("claim", owner=owner)
            bridge.xt_set_owner_token(token)
            bridge.xt_set_plugin_id(owner); bridge.xt_set_owner_token(token)
            class Text(str):
                def __str__(self): raise AssertionError("str override must not author wire context")
            sentinel = object()
            ident = bridge.xt_register_handle(sentinel)
            forged = json.dumps({"pluginId": "other", "ownerToken": "stolen", "op": "call", "operation": "other",
                "descriptor": {"plugin_id": "nested-other", "owner_token": "nested-stolen"}, "__handle__": ident, "fd": 99}, ensure_ascii=False)
            for operation in OPS:
                echo(Text(operation), Text(forged), owner, token)
                assert bridge.xt_resolve_handle(ident) is sentinel and bridge.xt_handle_count() == 1
            previous = bridge.xt_set_interpreter_id(701)
            echo("check", owner=owner, token=token)
            bridge.xt_set_interpreter_id(previous)
            assert bridge.xt_resolve_handle(ident) is sentinel
            for value in (None, 1):
                rejected(TypeError, lambda: bridge.xt_set_plugin_id(value))
                rejected(TypeError, lambda: bridge.xt_set_owner_token(value))
                checks += 2
            for value in ("", "bad\0id"):
                rejected(ValueError, lambda: bridge.xt_set_plugin_id(value))
                rejected(ValueError, lambda: bridge.xt_set_owner_token(value))
                checks += 2
            rejected(RuntimeError, lambda: bridge.xt_set_plugin_id("@elyx-inspection"), "plugin ID is already bound")
            rejected(RuntimeError, lambda: bridge.xt_set_owner_token("other-epoch"), "owner token is already bound")
            checks += 2
            echo("release", owner=owner, token=token)
            assert bridge.xt_release_handle(ident) is True and bridge.xt_handle_count() == 0

        elif case == "responses":
            rejected(RuntimeError, lambda: gate("claim", "{}"), "dispatcher is not installed")
            checks += 1
            defined_helpers = []
            def define_helper():
                class Helper:
                    receipt = gate("claim", "{}")
                defined_helpers.append(Helper)
            failure = rejected(RuntimeError, define_helper, "dispatcher is not installed")
            assert not defined_helpers and probe.metrics()["calls"] == 0
            details["helper_class_body_error"] = str(failure)
            checks += 1
            bridge.xt_bind(Instance, GateError)
            rejected(GateError, lambda: gate("release", "{}"), "dispatcher is not installed")
            checks += 1
            malformed = [
                ("empty", b"", "empty or invalid response buffer"),
                ("raw", b"", "empty or invalid response buffer"),
                ("huge", b"x", "empty or invalid response buffer"),
                ("raw", b"\xff", "not UTF-8"),
                ("raw", b"\xff\xfe{\x00}\x00", "not UTF-8"),
                ("raw", b"{broken", "not JSON"),
                ("raw", b'{"ok":true,"value":{}}\0trailer', "not JSON"),
                ("raw", b"[]", "must be an {ok,value/error} object"),
                ("raw", b"null", "must be an {ok,value/error} object"),
                ("raw", b"{}", "requires a boolean ok"),
                ("raw", b'{"ok":1,"value":{}}', "requires a boolean ok"),
                ("raw", b'{"ok":0,"value":{}}', "requires a boolean ok"),
                ("raw", b'{"ok":"true","value":{}}', "requires a boolean ok"),
                ("raw", b'{"ok":true}', "requires value"),
                ("raw", b'{"ok":false}', "requires error.message"),
                ("raw", b'{"ok":false,"error":{"message":7}}', "requires error.message"),
                ("raw", b'{"ok":true,"value":{"__bytes__":"***"}}', "__bytes__"),
                ("raw", b'{"ok":true,"value":{"__handle__":9223372036854775807}}', "handle"),
            ]
            for mode, body, error in malformed:
                assert probe.install(mode, body) == 0
                rejected(GateError, lambda: gate("read", "{}"), error)
                checks += 1
                assert bridge.xt_handle_count() == 0
                balanced(); assert probe.uninstall() == 0
            refused = json.dumps({"ok": False, "error": {"kind": "SecurityError", "message": "native refusal 雪"}}, ensure_ascii=False).encode()
            assert probe.install("raw", refused) == 0
            rejected(GateError, lambda: gate("claim", "{}"), "[SecurityError]: native refusal 雪")
            checks += 1; balanced(); assert probe.uninstall() == 0
            for mode, rc, message in (("raw", 23, "rc=23"), ("pending", 0, "pending exception"), ("pending", 29, "pending exception")):
                assert probe.install(mode, b'{"ok":true,"value":{}}', rc) == 0
                rejected(GateError, lambda: gate("check", "{}"), message)
                checks += 1; balanced(); assert probe.uninstall() == 0
                assert probe.install("echo") == 0
                echo("release")  # No pending error survives into the next native call.
                assert probe.uninstall() == 0
            raw = '{"ok":true,"value":{"text":"雪\\u0000π","released":false}}'.encode()
            assert probe.install("raw", raw) == 0
            assert gate("release", "{}") == {"text": "雪\0π", "released": False}
            checks += 1; balanced()
            details["operation_reply_schema_is_provider_boundary"] = True

        elif case == "retention":
            assert probe.install("detach") == 0
            assert probe.install("echo") == -2 and probe.metrics()["released"] == 0
            assert probe.wrong_detach() == -1 and probe.metrics()["released"] == 0
            echo()
            value = balanced()
            assert value["retained_checks"] == value["contexts"] == value["released"] == 1
            assert probe.uninstall() == -1
            rejected(RuntimeError, lambda: gate("read", "{}"), "dispatcher is not installed")
            checks += 4
            assert probe.install("echo") == 0
            echo("check")
            assert probe.uninstall() == 0
            assert probe.metrics()["contexts"] == probe.metrics()["released"] == 2

        elif case == "terminal":
            assert probe.install("echo") == 0
            echo("claim")
            constructor_calls, destructor_checks = [], []
            class Error(RuntimeError):
                def __init__(self, *args): constructor_calls.append(args); super().__init__(*args)
            bridge.xt_bind(Instance, Error)
            class LastHandle:
                def __del__(self):
                    for operation in OPS:
                        try: gate(operation, "{}")
                        except RuntimeError as error:
                            destructor_checks.append(type(error) is RuntimeError and "closed" in str(error))
                        else: destructor_checks.append(False)
            value = LastHandle(); weak = weakref.ref(value)
            bridge.xt_register_handle(value); del value
            assert bridge.xt_handle_count() == 1 and weak() is not None
            calls = probe.metrics()["calls"]
            probe.clear_bridge(bridge); cleared = True
            assert weak() is None and destructor_checks == [True] * 5
            for operation in OPS:
                error = rejected(RuntimeError, lambda: gate(operation, "{}"), "closed")
                assert type(error) is RuntimeError
                checks += 1
            rejected(RuntimeError, lambda: gate(None, None), "closed")
            rejected(RuntimeError, bridge.xt_handle_count, "closed")
            checks += 7
            assert not constructor_calls and probe.metrics()["calls"] == calls
            details["terminal_finalizer_gate_rejections"] = len(destructor_checks)

        elif case == "legacy_bypass":
            pointer = probe.legacy_pointer()
            names = ["elyx_source", "java.call", "java.elyx_source", *("elyx_source." + op for op in OPS)]
            for name in names:
                bridge.xt_register_service(name, pointer)
                assert bridge.xt_service_ptr(name) == pointer
            # Positive control: the actual legacy ABI is installed and callable.
            manifest = Path(report_path).with_name("legacy-control-manifest.json")
            manifest.write_text('{"classes":{"fixture.Legacy":{}}}', encoding="utf-8")
            backend = bridge.BridgeBackend(manifest_path=str(manifest))
            assert backend.class_exists("fixture.Legacy") is True
            assert backend.call("fixture.Legacy", "control", (), {}) == {"legacy_forgery": True}
            expected_legacy_calls = 1
            assert probe.metrics()["legacy_calls"] == expected_legacy_calls
            checks += 1
            for operation in OPS:
                rejected(RuntimeError, lambda: gate(operation, "{}"), "dispatcher is not installed")
                checks += 1
            assert probe.metrics()["legacy_calls"] == expected_legacy_calls and probe.metrics()["calls"] == 0
            assert probe.install("echo") == 0
            for operation in OPS: echo(operation)
            assert probe.metrics()["legacy_calls"] == expected_legacy_calls
            assert probe.uninstall() == 0
            for name in names: assert bridge.xt_unregister_service(name) is True
            bridge.xt_install_mock_service("java")
            rejected(RuntimeError, lambda: gate("claim", "{}"), "dispatcher is not installed")
            checks += 1
            assert not bridge.xt_mock_log() and probe.metrics()["legacy_calls"] == expected_legacy_calls
            details["legacy_positive_control_calls"] = expected_legacy_calls
            details["legacy_gate_calls"] = 0

        elif case == "own_gil":
            if sys.version_info >= (3, 14):
                try: import concurrent.interpreters as interpreters
                except ImportError:
                    print("ELYX_C_GATE_SKIP own_gil: concurrent.interpreters unavailable"); return 77
                owners = [interpreters.create(), interpreters.create()]
                execute = lambda owner, code: owner.exec(code)
                close = lambda owner: owner.close()
            else:
                try: import _xxsubinterpreters as interpreters
                except ImportError:
                    print("ELYX_C_GATE_SKIP own_gil: _xxsubinterpreters unavailable"); return 77
                owners = [interpreters.create(isolated=True), interpreters.create(isolated=True)]
                execute = lambda owner, code: interpreters.run_string(owner, code)
                close = lambda owner: interpreters.destroy(owner)
            interpreter_ids = [int(getattr(owner, "id", owner)) for owner in owners]
            assert len(set(interpreter_ids)) == 2 and 0 not in interpreter_ids
            assert probe.install("overlap") == 0
            bridge.xt_set_plugin_id("elyx-owner-one")
            bridge.xt_set_owner_token("parent-token")
            errors = []
            def child(index):
                try:
                    identity = "elyx-owner-one" if index == 0 else "elyx-owner-two"
                    code = "import importlib.util,sys,json,_thread\n" + \
                        f"path=bytes.fromhex({str(binary).encode().hex()!r}).decode()\n" + \
                        "spec=importlib.util.spec_from_file_location('_exteraless_bridge',path)\nb=importlib.util.module_from_spec(spec)\nspec.loader.exec_module(b)\nsys.modules['_exteraless_bridge']=b\n" + \
                        "initial=b.xt_elyx_source('manifest','{}')\nassert initial['caller']=='@elyx-inspection' and initial['request']['ownerToken'] is None\n" + \
                        f"assert initial['interpreter_id']=={interpreter_ids[index]}\n" + \
                        f"owner={identity!r}\ntoken='child-token-{index}'\nb.xt_set_plugin_id(owner)\nb.xt_set_owner_token(token)\n" + \
                        "value=b.xt_elyx_source('check',json.dumps({'pluginId':'forged','ownerToken':'forged'}))\nassert value['caller']==owner and value['request']['pluginId']==owner and value['request']['ownerToken']==token\nassert value['gil_held'] and value['thread_id']==_thread.get_ident()\nassert value['interpreter_id']!=0 and b.xt_handle_count()==0\n"
                    assert len(code.encode()) < 32768
                    execute(owners[index], code)
                except BaseException as error:
                    errors.append(type(error).__name__ + ": " + str(error)[-1500:])
            threads = [threading.Thread(target=child, args=(i,)) for i in range(2)]
            try:
                for thread in threads: thread.start()
                for thread in threads: thread.join(8)
                assert all(not thread.is_alive() for thread in threads), "OWN_GIL child did not finish"
                assert not errors, errors
                execute(owners[0], "again=b.xt_elyx_source('release','{}')\nassert again['request']['ownerToken']=='child-token-0'\n")
                echo("release", owner="elyx-owner-one", token="parent-token")
                value = probe.metrics()
                assert value["arrivals"] == 2 and value["overlap_passed"] == 1 and value["overlap_failed"] == 0
                assert value["peak_active"] == 2 and value["gil_faults"] == 0
                checks += 6
                details["own_gil_owners"] = 2
                details["interpreter_ids"] = interpreter_ids
            finally:
                for owner in owners: close(owner)

        metrics = balanced()
        probe.uninstall()
        metrics = balanced()
        assert metrics["contexts"] == metrics["released"] and metrics["legacy_calls"] == expected_legacy_calls
        if not cleared: assert bridge.xt_handle_count() == 0
        result = {"ok": True, "case": case, "checks": checks, "python": sys.version.split()[0],
                  "source_c_sha256": receipt["source_sha256"][BRIDGE.relative_to(ROOT).as_posix()],
                  "binary_sha256": receipt["extension_sha256"], "metrics": metrics, "details": details,
                  "native_fd_registry_proved": False, "apple_execution_claimed": False}
        Path(report_path).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print("ELYX_C_GATE_OK " + json.dumps(result))
        return 0
    finally:
        probe.uninstall()


if __name__ == "__main__":
    if sys.argv[1] == "build":
        output = Path(sys.argv[3]).resolve()
        assert not output.is_relative_to(ROOT), "build must be outside the repository"
        output.mkdir(parents=True, exist_ok=False)
        result = subprocess.run([sys.executable, "-X", "utf8", "-B", str(Path(__file__).resolve()),
            "compile", sys.argv[2], str(output)], env=dict(os.environ, VSLANG="1033"), capture_output=True, timeout=120)
        console = result.stdout + result.stderr
        (output / "build-console.log").write_bytes(console)
        print(console.decode("utf-8", errors="replace"))
        raise SystemExit(result.returncode)
    elif sys.argv[1] == "compile":
        build(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "worker":
        raise SystemExit(worker(sys.argv[2], sys.argv[3], sys.argv[4]))
    else:
        raise SystemExit("expected build TARGET_PYTHON OUTPUT or worker CASE BINARY REPORT")
else:
    import pytest
    @pytest.mark.parametrize("case", CASES)
    def test_elyx_c_gate(case, tmp_path):
        binary = os.environ.get("EXTERALESS_ELYX_C_GATE")
        if not binary: pytest.skip("Set EXTERALESS_ELYX_C_GATE to a freshly built staged extension")
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()),
            "worker", case, binary, str(tmp_path / "elyx-c-gate.json")], cwd=tmp_path,
            text=True, encoding="utf-8", capture_output=True, timeout=30)
        if result.returncode == 77: pytest.skip(result.stdout.strip())
        assert result.returncode == 0, (result.stdout + result.stderr)[-6000:]
        assert "ELYX_C_GATE_OK " in result.stdout
