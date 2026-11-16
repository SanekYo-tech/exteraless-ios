"""Owner-worker observations for swift_plugin_probe; no service/backend doubles.

The native engine loads this helper before the host's untouched bootstrap. The
profiler observes real SDK/plugin calls and the built-in xt_call_host C function.
Exported checks enter through PluginHost/dispatcher callbacks, in SDK context.
"""

import _thread
import json
import os
import sys


_plugin_id = "nativeWaveProbe"
_runtime_class = "exteraless.ios.Runtime"
_operations = ("construct", "call", "call_instance", "get", "get_instance", "set", "set_instance")
_sdk_names = {
    "load_plugin", "unload_plugin", "get_settings_json", "_serialize_setting_item",
    "notify_setting_changed", "dispatch_setting_click", "call_app_event",
    "call_send_message_hook", "_import_module",
}
_fixture_names = {"<module>", "on_plugin_load", "on_plugin_unload", "create_settings",
                  "clicked", "on_app_event", "on_send_message_hook"}
_owner = None
_native_reference = None
_python_root = None
_plugin_file = None
_files = {}
_sdk_calls = {}
_fixture_calls = {}
_native_members = {}
_sources = {}
_events = []
_problems = []
_transport_calls = 0
_transport_errors = 0
_backend_calls = 0
_metadata_calls = 0
_checks_handle = None
_services_verified = False
_unknown_rejected = False
_directories = {}
_sdk_checks = {}


def _path(path):
    return os.path.normcase(os.path.normpath(path))


def install(python_root, installed_plugin, native_reference):
    global _owner, _python_root, _plugin_file, _native_reference, _files
    if _owner is not None or sys.getprofile() is not None:
        raise RuntimeError("native plugin probe profiler must be installed exactly once")
    _owner = _thread.get_ident()
    _python_root = os.path.realpath(python_root)
    _plugin_file = _path(installed_plugin)
    _native_reference = native_reference
    _files = {
        "loader": _path(os.path.join(_python_root, "sdk", "extera_utils", "plugin_loader.py")),
        "metadata": _path(os.path.join(_python_root, "sdk", "extera_utils", "metadata_parser.py")),
        "android": _path(os.path.join(_python_root, "sdk", "android_utils.py")),
    }
    sys.setprofile(_profile)


def _profile(frame, event, arg):
    global _transport_calls, _transport_errors, _metadata_calls, _backend_calls
    try:
        if event in ("c_call", "c_exception"):
            bridge = sys.modules.get("_exteraless_bridge")
            # Multi-phase module execution publishes sys.modules before adding
            # BridgeBackend. The pre-bootstrap profiler also sees those C calls.
            backend_type = getattr(bridge, "BridgeBackend", None)
            if (event == "c_call" and backend_type is not None
                    and isinstance(getattr(arg, "__self__", None), backend_type)
                    and getattr(arg, "__name__", None) in _operations):
                _backend_calls += 1
            if bridge is not None and arg is getattr(bridge, "xt_call_host", None):
                if event == "c_exception":
                    _transport_errors += 1
                else:
                    _transport_calls += 1
                    local = frame.f_locals
                    fqcn = local.get("fqcn", _runtime_class)
                    member = local.get("member", "<direct>")
                    if isinstance(fqcn, str) and isinstance(member, str):
                        key = fqcn + "#" + member
                        _native_members[key] = _native_members.get(key, 0) + 1
                if _thread.get_ident() != _owner:
                    _problems.append("native transport entered from a foreign worker")
            return
        if event != "call":
            return
        code = frame.f_code
        filename = _path(code.co_filename)
        name = code.co_name
        if filename == _files["metadata"] and name == "read_metadata":
            _metadata_calls += 1
            _sources["read_metadata"] = code.co_filename
        if ((filename == _files["loader"] and name in _sdk_names)
                or (filename == _files["android"] and name == "run_on_ui_thread")):
            _sdk_calls[name] = _sdk_calls.get(name, 0) + 1
            _sources[name] = code.co_filename
        if filename == _plugin_file and name in _fixture_names:
            _fixture_calls[name] = _fixture_calls.get(name, 0) + 1
            _sources["fixture." + name] = code.co_filename
            if _thread.get_ident() != _owner:
                _problems.append("fixture executed on a foreign worker")
            if name != "<module>":
                loader = sys.modules.get("extera_utils.plugin_loader")
                owner = loader.current_plugin_id() if loader else None
                if owner != _plugin_id:
                    _problems.append("fixture executed outside its SDK plugin context: " + name)
                local = frame.f_locals
                _events.append({"method": name, "pluginId": owner,
                                "account": local.get("account"),
                                "event": local.get("event_type")})
    except BaseException as error:
        # Observation failures must fail the probe, without changing SDK control flow.
        if len(_problems) < 16:
            _problems.append(type(error).__name__ + ": " + str(error))


def _record():
    if _thread.get_ident() != _owner:
        raise RuntimeError("probe checks require the owning native worker")
    loader = sys.modules.get("extera_utils.plugin_loader")
    if loader is None or _plugin_id not in loader.plugins:
        raise RuntimeError("the real SDK fixture has not loaded")
    return loader, loader.plugins[_plugin_id]


def export_checks():
    """Register only this probe helper; the plugin/SDK objects are never replaced."""
    global _checks_handle
    _record()
    if _checks_handle is None:
        import _exteraless_bridge
        _checks_handle = _exteraless_bridge.xt_register_handle(_NativeChecks())
    return _checks_handle


def _native(member, *args):
    import _exteraless_bridge
    return _exteraless_bridge.xt_call_host({
        "op": "call", "fqcn": _runtime_class, "member": member,
        "args": list(args), "kwargs": {},
    })


def _probe_darwin_family_fds(record, cache):
    # Actual embedded sys.platform; no selector substitution or service double.
    if sys.platform not in ("darwin", "ios"):
        return
    import hashlib
    import uuid
    from exteraless_runtime import _archives, _audit_paths
    raw = cache
    for name in ("var", "tmp", "etc"):
        if raw.startswith("/private/" + name + "/"):
            raw = raw[len("/private"):]
            break
    nonce = uuid.uuid4().hex
    digest = hashlib.sha256(b"owned native FD family probe").hexdigest()
    extraction = _archives._Extraction(raw, "elyx/" + digest + "/" + digest + "-" + nonce)
    descriptors = []
    try:
        extraction.create()
        extraction.write("contents/asset.bin", b"before")
        extraction.write("contents/code.py", b"# owned data-only code fixture\n")
        directory = extraction.directory("contents")
        for name in ("asset.bin", "code.py"):
            descriptors.append(os.open(name, os.O_RDWR, dir_fd=directory.fd))
        if not record.instance.fd_family_probe(*descriptors, directory.fd):
            raise AssertionError("native FD family fixture did not finish")
        resolved = _audit_paths._descriptor_path(descriptors[0])
        if not resolved or not os.path.samefile(resolved, os.path.join(directory.path, "asset.bin")):
            raise AssertionError("actual Darwin-family F_GETPATH lost the owned asset inode")
        os.lseek(descriptors[0], 0, os.SEEK_SET)
        if os.read(descriptors[0], 5) != b"owned":
            raise AssertionError("actual owned asset FD write failed")
        os.symlink(".", "untrusted-link", dir_fd=directory.fd)
        try:
            _archives._Directory.open_native(os.path.join(directory.path, "untrusted-link"))
        except _archives.ArchiveValidationError:
            pass
        else:
            raise AssertionError("native root-alias support followed a descendant symlink")
        _sdk_checks["darwin_family_fd_paths"] = True
        if sys.platform == "ios":
            _sdk_checks["actual_ios_fd_paths"] = True
    finally:
        for descriptor in descriptors:
            os.close(descriptor)
        try:
            extraction.cleanup()
        finally:
            extraction.close()


class _NativeChecks:
    def verify_owner(self):
        import _exteraless_bridge as bridge
        import exteraless_runtime as runtime
        token = _native("sdkFixtureOwner")
        if not isinstance(token, str) or token != runtime._state.owner_token:
            raise AssertionError("C/SDK/Host owner epochs disagree")
        request = {"op": "call", "fqcn": _runtime_class, "member": "sdkFixtureOwner",
                   "args": [], "kwargs": {}, "ownerToken": "caller-forged-epoch"}
        if bridge.xt_call_host(request) != token:
            raise AssertionError("caller changed native C owner provenance")
        try:
            bridge.xt_set_owner_token("rebind-must-fail")
        except RuntimeError:
            pass
        else:
            raise AssertionError("C owner epoch was rebound")
        _sdk_checks["immutable_c_owner"] = True
        return token

    def reflection(self, available):
        from java import jclass
        runtime_class = jclass(_runtime_class)
        if bool(hasattr(runtime_class, "sdkFixtureEcho")) != bool(available):
            raise AssertionError("native extension metadata outlived its installed provider")
        if available:
            text = "reflection 雪\0π"
            before = _backend_calls
            if runtime_class.sdkFixtureEcho(text) != text:
                raise AssertionError("BridgeBackend.call did not execute the native extension")
            if _backend_calls <= before:
                raise AssertionError("reflection call bypassed the actual C BridgeBackend")
            _sdk_checks["c_reflection_extension"] = True
        else:
            _sdk_checks["unadvertised_extension"] = True
        return bool(available)

    def bulk_settings(self):
        loader, record = _record()
        original = record.instance.export_settings()
        literal = {"__handle__": 123, "__bytes__": "literal", "unicode": "雪\0π"}
        record.instance.import_settings({"sdk_literal": literal}, reload_settings=True)
        if record.instance.get_setting("sdk_literal") != literal or record.instance.get_setting("loads") != original["loads"]:
            raise AssertionError("opaque bulk merge lost literal tags or prior values")
        from base_plugin import PythonBridge
        from plugin_settings import encode_values
        PythonBridge.replaceSettings(_plugin_id, json.dumps(encode_values(original)))
        if record.instance.export_settings() != original:
            raise AssertionError("bulk replace failed to delete the temporary key")
        _sdk_checks["bulk_opaque_settings"] = True
        return True

    def begin_ui(self):
        import _exteraless_bridge as bridge
        import exteraless_runtime as runtime
        from java import jclass
        from virtualjava import finder
        from ui.alert import AlertDialogBuilder
        loader, record = _record()
        self.ui_backend = finder._State.backend
        if type(self.ui_backend) is not bridge.BridgeBackend:
            raise AssertionError("UI model work replaced the actual C backend")
        field = jclass("android.widget.EditText")()
        field.setText("draft")
        field.setTypeface("monospace")
        field.setTextSize(18)
        layout = jclass("android.widget.LinearLayout$LayoutParams")(-1, 40, 1)
        layout.setMargins(1, 2, 3, 4)
        root = jclass("android.widget.LinearLayout")()
        root.setPadding(4, 6, 4, 6)
        root.addView(field, layout)
        image = jclass("android.widget.ImageView")()
        image.setImageResource("sf:checkmark.circle")
        root.addView(image, 24, 24)
        def obsolete(*args): raise AssertionError("a replaced UI listener executed")
        def item_clicked(builder, which):
            if builder is not self.builder or which != 0 or field.getText() != "fixture item 雪\0π":
                raise AssertionError("item listener did not receive its exact captured input")
            record.instance.set_setting("sdk_ui_item", field.getText())
        def clicked(builder, which):
            if _thread.get_ident() != _owner or loader.current_plugin_id() != _plugin_id or which != -1:
                raise AssertionError("SDK UI callback left its owner or changed arity")
            if field.getText() != "fixture click 雪\0π":
                raise AssertionError("UI field values were not captured before onClick")
            record.instance.set_setting("sdk_ui_click", "clicked 雪\0π")
        def dismissed(builder):
            record.instance.set_setting("sdk_ui_dismiss", True)
        self.builder = AlertDialogBuilder().set_title("SDK native DTO fixture").set_message("No UIKit is created").set_view(root, 96)
        self.builder.set_positive_button("Record", obsolete).set_on_dismiss_listener(dismissed).show()
        handles = tuple(self.builder.get_dialog().lease.handles)
        count = bridge.xt_handle_count()
        self.builder.set_title("SDK live DTO fixture").set_message("Live native DTO")
        self.builder.set_blurred_background(True, False).set_message_text_view_clickable(True)
        self.builder.set_positive_button("Record updated", clicked)
        self.builder.set_items(["Old"], obsolete, icons=["msg_copy"])
        self.builder.set_items(["Fresh"], item_clicked, icons=["sf:checkmark"])
        if tuple(self.builder.get_dialog().lease.handles) != handles or bridge.xt_handle_count() != count:
            raise AssertionError("live Builder/listener changes introduced new C handles")
        if finder._State.backend is not self.ui_backend or len(runtime._state.callbacks.leases) != 1:
            raise AssertionError("live UI changes replaced the backend or presentation lease")
        if self.builder.get_dialog().isShowing():
            raise AssertionError("Foundation recorder falsely claimed UIKit visibility")
        return self.builder.get_dialog().id

    def after_ui(self):
        import exteraless_runtime as runtime
        from virtualjava import finder
        _, record = _record()
        if runtime._state.callbacks.leases or record.instance.get_setting("sdk_ui_click") != "clicked 雪\0π" \
                or record.instance.get_setting("sdk_ui_dismiss") is not True \
                or record.instance.get_setting("sdk_ui_item") != "fixture item 雪\0π":
            raise AssertionError("SDK UI action/closed/release FIFO did not finish")
        if finder._State.backend is not self.ui_backend:
            raise AssertionError("UI callback delivery changed the installed C backend")
        _sdk_checks["terminal_ui_lease"] = True
        _sdk_checks["ui_live_models"] = True
        return True

    def barrier(self):
        _record()  # FIFO fence executed on the real SDK/native owner.

    def begin_task(self):
        import client_utils
        loader, record = _record()
        def work():
            if loader.current_plugin_id() != _plugin_id or _thread.get_ident() != _owner or client_utils.get_hook_account() != 2:
                raise AssertionError("owner task left its interpreter")
            record.instance.set_setting("sdk_task_done", True)
            _sdk_checks["owner_task_result"] = True
            return {1: object()}  # Runnable ignores ANY result without exporting C handles.
        with client_utils.hook_scope(2):
            client_utils.run_on_queue(work)

    def async_result(self):
        loader, record = _record()
        if loader.current_plugin_id() != _plugin_id or _thread.get_ident() != _owner:
            raise AssertionError("result callback left its native owner")
        return {"value": 42, "text": "result 雪\0π", "taskDone": record.instance.get_setting("sdk_task_done")}

    def after_transients(self):
        import _exteraless_bridge as bridge
        import exteraless_runtime as runtime
        state = runtime._state
        if state.callbacks.leases or state.scheduler.tasks or state.tl.pending or bridge.xt_handle_count() != 1:
            raise AssertionError("transient callback/FIFO release leaked a lease or C return handle")
        if bridge.xt_resolve_handle(_checks_handle) is not self:
            raise AssertionError("transient release lost the reusable checks handle")
        _sdk_checks["transient_handles_released"] = True
        return True

    def begin_request(self):
        from java import jclass
        import client_utils
        loader, record = _record()
        request = jclass("org.telegram.tgnet.TLRPC$TL_users_getUsers")()
        request.id = [jclass("org.telegram.tgnet.TLRPC$TL_inputUserSelf")()]
        def received(response, error):
            if error is not None or response.objects[0].id != 101 or client_utils.get_hook_account() != 2 \
                    or loader.current_plugin_id() != _plugin_id:
                raise AssertionError("native DTO response/SDK callback account was lost")
            record.instance.set_setting("sdk_request_done", True)
            _sdk_checks["request_response_dto"] = True
            return {1: object()}  # RequestDelegate's ignored value cannot create return handles.
        token = client_utils.send_request(request, received, account=2)
        return token.native_id

    def verify_services(self):
        global _services_verified, _unknown_rejected, _directories
        loader, record = _record()
        if loader.current_plugin_id() != _plugin_id:
            raise RuntimeError("invokeCallback did not enter SDK plugin context")
        from base_plugin import PythonBridge
        from virtualjava import JavaMemberError
        directories = {"plugins": PythonBridge.getPluginsDir(),
                       "files": PythonBridge.getFilesDir(), "cache": PythonBridge.getCacheDir()}
        for name, directory in directories.items():
            if not os.path.isabs(directory) or not os.path.isdir(directory):
                raise AssertionError("native directory does not exist: " + name)
        if _path(directories["plugins"]) != _path(os.path.dirname(_plugin_file)):
            raise AssertionError("native plugins directory differs from host configuration")
        if PythonBridge.getVersion() != "native-swift-sdk-fixture/1":
            raise AssertionError("Runtime.getVersion did not reach the Swift fixture provider")
        value = "native \u96ea\x00\u03c0"
        record.instance.set_setting("probe_roundtrip", value)
        if record.instance.get_setting("probe_roundtrip", "missing") != value:
            raise AssertionError("native UTF-8/NUL settings roundtrip failed")
        if PythonBridge.removeSetting(_plugin_id, "probe_roundtrip") is not True:
            raise AssertionError("native removeSetting did not remove the stored value")
        if record.instance.get_setting("probe_roundtrip", "missing") != "missing":
            raise AssertionError("removed native setting survived")
        try:
            _native("__unsupported_probe_member__")
        except JavaMemberError as error:
            if "__unsupported_probe_member__" not in str(error):
                raise AssertionError("unexpected native error: " + str(error)) from error
            _unknown_rejected = True
        else:
            raise AssertionError("unknown native member was silently accepted")
        _probe_darwin_family_fds(record, directories["cache"])
        _directories = directories
        _services_verified = True

    def queue_click(self):
        loader, record = _record()
        if loader.current_plugin_id() != _plugin_id:
            raise RuntimeError("callback scheduler check is outside SDK context")
        from android_utils import run_on_ui_thread
        # Actual SDK lambda -> C handle -> Swift onOwnedCallback -> host owner queue.
        run_on_ui_thread(record.instance.clicked, 0)


def snapshot_json():
    """Read-only observations, collected while the same owner thread is attached."""
    if _thread.get_ident() != _owner:
        raise RuntimeError("snapshot requested on the wrong worker")
    loader = sys.modules.get("extera_utils.plugin_loader")
    bridge = sys.modules.get("_exteraless_bridge")
    finder = sys.modules.get("virtualjava.finder")
    runtime = sys.modules.get("exteraless_runtime")
    state = getattr(runtime, "_state", None)
    module_paths = {}
    for name in ("extera_utils.plugin_loader", "extera_utils.metadata_parser", "base_plugin",
                 "ui.settings", "exteraless_runtime", "virtualjava"):
        module = sys.modules.get(name)
        if module is not None:
            module_paths[name] = getattr(module, "__file__", "")
    return json.dumps({
        "nativeReference": _native_reference,
        "threadId": _owner,
        "pluginId": getattr(state, "plugin_id", None),
        "profileActive": sys.getprofile() is _profile,
        "sdkLoaderPresent": loader is not None,
        "metadataCalls": _metadata_calls,
        "sdkCalls": dict(_sdk_calls),
        "fixtureCalls": dict(_fixture_calls),
        "transportCalls": _transport_calls,
        "transportErrors": _transport_errors,
        "bridgeBackendCalls": _backend_calls,
        "nativeMembers": dict(_native_members),
        "sources": dict(_sources),
        "modulePaths": module_paths,
        "events": list(_events),
        "problems": list(_problems),
        "bridgeBuiltin": bridge is not None and bridge.__spec__.origin == "built-in"
            and type(bridge.xt_call_host) is type(len),
        "backendInstalled": bridge is not None and finder is not None
            and type(finder._State.backend) is bridge.BridgeBackend,
        "legacyServiceCount": sum(bool(bridge.xt_service_ptr("java." + op)) for op in _operations) if bridge else 0,
        "mockCalls": len(bridge.xt_mock_log()) if bridge else 0,
        "handleCount": bridge.xt_handle_count() if bridge else 0,
        "loadedPlugins": sorted(loader.plugins) if loader else [],
        "checksHandle": _checks_handle,
        "servicesVerified": _services_verified,
        "unknownRejected": _unknown_rejected,
        "directories": dict(_directories),
        "ownerToken": getattr(state, "owner_token", None),
        "sdkChecks": dict(_sdk_checks),
        "callbackLeases": len(state.callbacks.leases) if state is not None else 0,
    }, ensure_ascii=False, allow_nan=False)


def finish_json():
    result = snapshot_json()
    sys.setprofile(None)
    return result
