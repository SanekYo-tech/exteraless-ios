"""Owner-worker checks for the real TL SDK child; C/backend are never replaced."""

import json
import sys
import _thread


_loaded_source = None
_owner = None
_checks_handle = None


def loaded():
    global _loaded_source, _owner, _checks_handle
    import _exteraless_bridge as bridge
    runtime = sys.modules["exteraless_runtime"]
    loader = runtime._state.loader
    record = loader.plugins[runtime._state.plugin_id]
    _loaded_source = record.instance.on_plugin_load.__code__.co_filename
    _owner = _thread.get_ident()
    _checks_handle = bridge.xt_register_handle(_Checks())
    # EXLPythonRunScript preserves Unicode results and repr()s other objects.
    return json.dumps({"pluginId": runtime._state.plugin_id, "handle": _checks_handle})


def _state():
    import exteraless_runtime as runtime
    state = runtime._state
    assert _thread.get_ident() == _owner and state.loader.current_plugin_id() == state.plugin_id
    return state


class _Checks:
    def barrier(self):
        _state()

    def config(self, write):
        from java import jclass
        from exteraless_runtime import _config_manifest as manifest
        state = _state()
        plugin = state.loader.plugins[state.plugin_id].instance
        extera = jclass("com.exteragram.messenger.ExteraConfig")
        count = 0
        for identity, binding in manifest.BINDINGS.items():
            if not identity.startswith("compat.exteraconfig."): continue
            field = binding["source_key"]
            suffix = field[0].upper() + field[1:]
            getter, setter = getattr(extera, "get" + suffix), getattr(extera, "set" + suffix)
            metadata = json.loads(state.call("getClientSettingMetadata", binding["key"]))
            assert metadata["key"] == binding["key"] and metadata["scope"] == "global"
            initial = metadata["default"]
            expected = not initial if type(initial) is bool else "native Config 雪\0π" if isinstance(initial, str) else \
                9007199254740993 if binding["type"] == "long" else 2 if field in ("translationFormality", "tabIcons") else 41
            value = getter()
            actual = value.ordinal() if field in ("translationFormality", "tabIcons") else value
            assert actual == (initial if write else expected)
            if write:
                if field in ("translationFormality", "tabIcons"):
                    enum = jclass("com.exteragram.messenger." + ("TranslationFormality" if field == "translationFormality" else "TabIconsMode"))
                    setter(enum.values()[expected])
                    assert getter().ordinal() == expected
                else:
                    setter(expected)
                    assert getter() == expected
            count += 1
        assert count == 22
        if write: plugin.set_setting("tabCounter", "writer-private")
        else:
            assert plugin.get_setting("tabCounter") is None
            plugin.set_setting("readerPrivate", "reader-only")
        return count * 2 if write else count

    def begin_request(self):
        import client_utils as client
        state = _state()
        self.callbacks = 0
        def completed(response, error):
            assert client.get_hook_account() == 2 and error is None and response.objects[0].id == 101
            assert state.loader.current_plugin_id() == state.plugin_id
            self.callbacks += 1
            return {1: object()}  # A void delegate must not export a return handle.
        self.token = client.send_request({"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]}, completed, 2)
        return self.token.native_id

    def cancel_request(self, outcome):
        state = _state()
        lease = state.tl.pending[int(self.token)]
        if outcome == "throw":
            try:
                self.token.cancel()
            except Exception as error:
                assert "canned cancellation transport failure" in str(error)
            else:
                raise AssertionError("cancellation transport failure was swallowed")
        else:
            assert self.token.cancel() is (outcome == "true")
        if outcome != "true":
            assert lease.open and state.tl.pending[int(self.token)] is lease
        else:
            assert not lease.open and int(self.token) not in state.tl.pending
        return True

    def after_request(self, count):
        import _exteraless_bridge as bridge
        state = _state()
        assert self.callbacks == count and not state.tl.pending and not state.callbacks.leases
        assert bridge.xt_handle_count() == 1 and bridge.xt_resolve_handle(_checks_handle) is self
        assert self.token.cancel() is False
        return True

    def begin_text(self, kind):
        import client_utils as client
        _state()
        if kind == "rich":
            token = client.send_text(101, "**native**", parse_mode="Markdown", replyToMsg={"id": 7, "namespace": 1}, account=2)
        elif kind == "scheduled":
            token = client.send_message({"peer": 101, "message": "scheduled", "entities": [], "notify": True,
                "searchLinks": False, "scheduleDate": 1700000123, "replyToTopMsg": 7}, account=2)
        elif kind in ("edit_omitted", "edit_empty"):
            target = {"peer": {"type": "user", "id": 101}, "id": 7, "namespace": 3}
            token = client.edit_message(target, account=2) if kind == "edit_omitted" else client.edit_message(target, text="", with_spoiler=False, account=2)
        elif kind == "receipt":
            self.receipt = None
            def completed(value, error):
                assert client.get_hook_account() == 2 and error is None
                self.receipt = value
            token = client.send_native_media({"peer": 101, "kind": "text", "caption": "receipt"}, completed, 2)
        else:
            raise AssertionError("unknown native text fixture")
        return token.native_id

    def after_text(self):
        import _exteraless_bridge as bridge
        state = _state()
        assert self.receipt == {"status": "enqueued", "messageIds": [{"peerId": 101, "namespace": 1, "id": 901}]}
        assert not state.tl.pending and not state.callbacks.leases and bridge.xt_handle_count() == 1
        return True

    def legacy_unrelated(self):
        from java import jclass
        _state()
        result = jclass("exteraless.ios.Runtime").sendMessage({"type": "user", "id": 101}, "sdk-legacy-unrelated", 2)
        assert result["status"] == "scheduled" and isinstance(result["requestId"], str)
        return True


def observation():
    bridge = sys.modules.get("_exteraless_bridge")
    runtime = sys.modules.get("exteraless_runtime")
    state = getattr(runtime, "_state", None)
    loader = sys.modules.get("extera_utils.plugin_loader")
    finder = sys.modules.get("virtualjava.finder")
    operations = ("construct", "call", "call_instance", "get", "get_instance", "set", "set_instance")
    return json.dumps({
        "threadId": _thread.get_ident(), "pluginId": getattr(state, "plugin_id", None),
        "ownerToken": getattr(state, "owner_token", None), "pluginSource": _loaded_source,
        "runtimeSource": getattr(runtime, "__file__", None), "sdkSource": getattr(loader, "__file__", None),
        "handleCount": bridge.xt_handle_count() if bridge else 0,
        "callbackLeases": len(state.callbacks.leases) if state is not None else 0,
        "loadedPlugins": sorted(loader.plugins) if loader else [],
        "bridgeBuiltin": bridge is not None and bridge.__spec__.origin == "built-in" and type(bridge.xt_call_host) is type(len),
        "backendInstalled": bridge is not None and finder is not None and type(finder._State.backend) is bridge.BridgeBackend,
        "legacyServiceCount": sum(bool(bridge.xt_service_ptr("java." + op)) for op in operations) if bridge else 0,
        "mockCalls": len(bridge.xt_mock_log()) if bridge else 0,
    }, ensure_ascii=False, allow_nan=False)
