"""Original SDK + actual _ui settings bodies; native services are wire recorders.

Each owned case is a fresh -I -S -B child with a 20-second deadline. This does
not execute the C extension, Swift Host, UIKit or production recorded frames.
"""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
CASES = ("materialization", "snapshot_callbacks", "bound_callback", "failed_materialization", "aliases", "portable_refresh", "worker_lifetime", "budgets",
         "deferred_refresh_commit", "deferred_refresh_reject", "deferred_refresh_dispose", "deferred_refresh_overlap", "root_callback_arguments")


def worker(case, directory):
    import gc
    import threading
    import uuid
    sys.path.insert(0, str(ROOT / "python"))
    spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))
    support = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(support)

    class Host(support.StrictNativeHost):
        def __init__(self, root):
            super().__init__(root)
            self.presentations = {}
            self.account = 7
            self.source_id = str(uuid.uuid4())
            self.fail_update = False
            self.pending_updates, self.settling_updates = {}, {}

        def call(self, request):
            request = dict(request)
            request.pop("ownerToken", None)
            member, args = request["member"], request["args"]
            if member == "selectedAccount": return self.account
            if member == "uiActiveFragment": return {"id": self.source_id, "account": self.account}
            if member == "uiPresent":
                kind, model, callbacks = args
                assert kind == "settings" and model["sourceId"] == self.source_id
                assert set(model) <= {"title", "rows", "pagePath", "targetRowId", "sourceId", "settingsSnapshotId"}
                json.dumps(model, allow_nan=False)
                ident = str(uuid.uuid4())
                self.presentations[ident] = {"model": json.loads(json.dumps(model)), "revision": 0,
                    "callbacks": {key: self.register(fn) for key, fn in callbacks.items()}}
                return {"id": ident}
            if member == "uiUpdate":
                if self.fail_update: raise RuntimeError("owned native update rejection")
                assert len(args) == 3, "settings refresh must use the native commit protocol"
                ident, model, control = args
                entry = self.presentations[ident]
                assert ident not in self.pending_updates and ident not in self.settling_updates
                assert set(control) == {"previousSnapshotId", "snapshotId", "completion"}
                assert control["previousSnapshotId"] == entry["model"]["settingsSnapshotId"]
                assert control["snapshotId"] == model["settingsSnapshotId"]
                update = {"id": str(uuid.uuid4()), "previous": control["previousSnapshotId"], "snapshot": control["snapshotId"],
                    "model": json.loads(json.dumps(model)), "handle": self.register(control["completion"])}
                self.pending_updates[ident] = update
                return {"id": update["id"]}  # Admission, deliberately NOT model/revision commit.
            if member == "uiState": return {"visible": args[0] in self.presentations}
            if member == "uiDismiss": return None
            if member == "logEvent": return None
            return super().call(request)

        def capture(self, ident, name, **event):
            entry = self.presentations[ident]
            return ident, entry["callbacks"][name], dict(event, id=ident, event=name,
                _uiRevision=entry["revision"], _uiSettingsSnapshot=entry["model"]["settingsSnapshotId"])

        def deliver(self, captured, *, enforce_native_gate=True):
            ident, handle, event = captured
            entry = self.presentations.get(ident)
            settling = self.settling_updates.get(ident)
            if enforce_native_gate and (entry is None or entry["revision"] != event["_uiRevision"]
                    or settling is not None and settling["committed"]): return False
            return runtime.invoke_handle_json(handle, "__call__", json.dumps([event]))

        def event(self, ident, name, **event): return self.deliver(self.capture(ident, name, **event))

        def commit_update(self, ident, *, committed=True, acknowledge=True):
            update = self.pending_updates.pop(ident, None)
            if update is None: return False
            entry = self.presentations[ident]
            if committed:
                entry["model"] = update["model"]
                entry["revision"] += 1
            update["committed"] = committed
            update["ack"] = {"id": ident, "event": "settingsUpdate", "updateId": update["id"], "_uiTerminal": True,
                "_uiRevision": entry["revision"], "_uiSettingsSnapshot": entry["model"]["settingsSnapshotId"],
                "previousSnapshotId": update["previous"], "snapshotId": update["snapshot"], "committed": committed}
            self.settling_updates[ident] = update
            if acknowledge: self.acknowledge_update(ident)
            return True

        def acknowledge_update(self, ident):
            update = self.settling_updates.pop(ident)
            try:
                return runtime.invoke_handle_json(update["handle"], "__call__", json.dumps([update["ack"]]))
            finally:
                runtime.release_handles_json(json.dumps([update["handle"]]))

        def close_ui(self, ident):
            entry = self.presentations[ident]
            _, handle, event = self.capture(ident, "closed")
            runtime.invoke_handle_json(handle, "__call__", json.dumps([event]))
            handles = list(entry["callbacks"].values())
            for updates in (self.pending_updates, self.settling_updates):
                update = updates.pop(ident, None)
                if update: handles.append(update["handle"])
            runtime.release_handles_json(json.dumps(handles))
            self.presentations.pop(ident)

    support.StrictNativeHost = Host
    runtime, host, bridge = support.bootstrap(Path(directory), "manager_custom_alias")
    runtime.bind_owner_json(json.dumps("owned-settings-worker-1"))
    runtime.load_json(support.copy_fixture(host, "manager_custom_alias"))
    from exteraless_runtime import _ui
    from java import jclass
    plugin = runtime._state.loader.plugins[host.plugin_id].instance
    record = runtime._state.loader.plugins[host.plugin_id]
    baseline = (record.click_callbacks, record.change_callbacks, record.custom_views)

    def read():
        ident = str(uuid.uuid4())
        rows = json.loads(_ui.read_settings_page_json(ident, json.dumps({"account": host.account})))
        assert all(a is b for a, b in zip(baseline, (record.click_callbacks, record.change_callbacks, record.custom_views)))
        assert not bridge.xt_handle_count(), "Manager callbacks must remain string IDs, not C handles"
        return ident, rows

    def event(ident, **value): return _ui.settings_page_event_json(ident, json.dumps(value))
    def release(ident): _ui.release_settings_page_json(ident)
    def page(ident): return runtime._state.settings_pages[ident]
    def widget(rows, alias="view_alias"):
        row = next(row for row in rows[0]["sub_page"] if row.get("link_alias") == alias)
        return row, json.loads(row["widget_json"])

    if case == "materialization":
        ident, rows = read()
        assert plugin.factory_calls == 3
        for alias in ("view_alias", "item_alias", "factory_alias"):
            row, model = widget(rows, alias)
            assert row["type"] == "custom" and "view_id" not in row and model["type"] == "column"
            assert [item["type"] for item in model["children"]] == ["input", "text"]
            assert all(isinstance(item["callback"], str) for item in model["children"])
        assert plugin.events == [(7, ["bind", 1])]
        release(ident)
        gc.collect()
        assert all(ref() is None for ref in plugin.weak_widgets)

    elif case == "snapshot_callbacks":
        first, rows = read()
        row, model = widget(rows)
        editor, label = model["children"]
        plugin.version = 2
        second, rows2 = read()
        event(first, kind="widget", rowId=row["row_id"], widgetId=editor["id"], callbackId=editor["callback"], event="change", value="edited")
        event(first, kind="widget", rowId=row["row_id"], widgetId=label["id"], callbackId=label["callback"], event="action")
        event(first, kind="widget", rowId=row["row_id"], widgetId=label["id"], callbackId=label["long_callback_id"], event="longAction")
        event(first, kind="click", callbackId=row["callback_id"])
        event(first, kind="change", key="known_key", value=True)
        assert plugin.events[-5:] == [(7, ["input", 1, "edited"]), (7, ["nested", 1, "nested"]),
            (7, ["long", 1, "nested"]), (7, ["root", 1, "edited"]), (7, ["switch", 1, True, True])]
        support.raises(LookupError, lambda: event(second, kind="widget", rowId=row["row_id"], widgetId=label["id"], callbackId=label["callback"], event="action"))
        release(first)
        support.raises(_ui.RuntimeStateError, lambda: event(first, kind="click", callbackId=row["callback_id"]))
        event(second, kind="change", key="known_key", value=False)
        assert plugin.events[-1] == (7, ["switch", 2, False, False])
        release(second)

    elif case == "bound_callback":
        plugin.mode = "bound_callback"
        ident, rows = read()
        row, model = widget(rows)
        label = model["children"][1]
        event(ident, kind="widget", rowId=row["row_id"], widgetId=label["id"], callbackId=label["callback"], event="action")
        assert plugin.events[-1] == (7, ["bound-original-instance", "nested"])
        original = page(ident).views[row["row_id"]].children[1].model["callback"]
        assert original.__self__ is plugin, "deepcopy must not clone the callback's plugin instance"
        release(ident)

    elif case == "failed_materialization":
        for mode, reason in (("bad_view", "Android View"), ("bad_factory", "owned factory error")):
            plugin.mode = mode
            ident, rows = read()
            assert rows[0]["type"] == "custom" and reason in rows[0]["custom_error"]
            assert "widget_json" not in rows[0] and "callback_id" not in rows[0]
            assert not page(ident).widget_routes and not page(ident).record.custom_views
            assert not page(ident).record.click_callbacks
            release(ident)
        gc.collect()
        assert all(ref() is None for ref in plugin.weak_widgets)
        assert not runtime._state.settings_pages and not runtime._state.callbacks.leases

    elif case == "aliases":
        ident, rows = read()
        expected = {"pagePath": [rows[0]["row_id"]], "rowId": rows[0]["sub_page"][0]["row_id"]}
        assert _ui.resolve_settings_target(rows, "known_alias") == expected
        assert _ui.resolve_settings_target(rows, "known_key") == expected
        assert _ui.resolve_settings_target(rows, None) == {"pagePath": [], "rowId": None}
        for target, code in (("missing", "unknown"), ("Known_Alias", "unknown"), (" x ", "unknown"), ("", "invalid"), ("\0", "invalid"), ("\ud800", "invalid"), ("é" * 129, "tooLong")):
            error = support.raises(_ui.SettingsTargetError, lambda: _ui.resolve_settings_target(rows, target))
            assert error.code == code
        class ForgedEquality(str):
            def __eq__(self, other): return True
        assert support.raises(_ui.SettingsTargetError, lambda: _ui.resolve_settings_target(rows, ForgedEquality("missing"))).code == "unknown"
        release(ident)
        plugin.mode = "duplicate"
        ident, rows = read()
        assert support.raises(_ui.SettingsTargetError, lambda: _ui.resolve_settings_target(rows, "duplicate")).code == "ambiguous"
        release(ident)
        plugin.mode = "unicode"
        ident, rows = read()
        assert _ui.resolve_settings_target(rows, "é")["rowId"] != _ui.resolve_settings_target(rows, "e\u0301")["rowId"]
        release(ident)
        support.raises(_ui.RuntimeStateError, lambda: jclass("app.exteraless.plugins.PluginsController").getInstance().openPluginSettings("other_plugin", "known_alias"))

    elif case == "portable_refresh":
        plugin.mode = "portable"
        controller = jclass("app.exteraless.plugins.PluginsController").getInstance()
        presentation = controller.openPluginSettings(host.plugin_id, "known_alias")
        model = host.presentations[presentation.id]["model"]
        assert model["pagePath"] == [model["rows"][0]["id"]]
        assert model["targetRowId"] == model["rows"][0]["sub_page"][0]["id"]
        assert not record.click_callbacks and not record.custom_views
        host.event(presentation.id, "change", key="known_key", value=True)
        assert plugin.events[-1] == (7, ["switch", 1, True, True])
        before = len(runtime._state.callbacks.leases)
        plugin.version = 2
        host.event(presentation.id, "refresh")
        assert len(runtime._state.callbacks.leases) == before + 2
        assert presentation.model == model and host.presentations[presentation.id]["model"] == model
        host.commit_update(presentation.id)
        assert len(runtime._state.callbacks.leases) == before
        host.fail_update = True
        support.raises(RuntimeError, lambda: host.event(presentation.id, "refresh"), "update rejection")
        assert len(runtime._state.callbacks.leases) == before
        host.fail_update = False
        plugin.mode = "unknown"
        support.raises(_ui.SettingsTargetError, lambda: host.event(presentation.id, "refresh"))
        assert len(runtime._state.callbacks.leases) == before
        host.close_ui(presentation.id)
        assert not runtime._state.callbacks.leases
        support.raises(_ui.SettingsTargetError, lambda: controller.openPluginSettings(host.plugin_id, "missing"))
        assert not host.presentations and not runtime._state.callbacks.leases

    elif case in ("deferred_refresh_commit", "deferred_refresh_reject", "deferred_refresh_dispose", "deferred_refresh_overlap"):
        plugin.mode = "portable"
        presentation = jclass("app.exteraless.plugins.PluginsController").getInstance().openPluginSettings(host.plugin_id, "known_alias")
        ident = presentation.id
        original_model = json.loads(json.dumps(presentation.model))
        original_page = presentation.page
        before = len(runtime._state.callbacks.leases)
        handles_before = bridge.xt_handle_count()
        captured = host.capture(ident, "change", key="known_key", value=True)
        plugin.version = 2
        host.event(ident, "refresh")
        assert host.presentations[ident]["model"] == original_model and presentation.model == original_model
        assert presentation.page is original_page and original_page.lease.open
        assert len(runtime._state.callbacks.leases) == before + 2 and bridge.xt_handle_count() == handles_before + 1
        host.deliver(captured)
        assert plugin.events[-1] == (7, ["switch", 1, True, True]), "S1 must not invoke S2 after update admission"
        if case == "deferred_refresh_dispose":
            host.close_ui(ident)
            assert not host.commit_update(ident)
            assert not runtime._state.callbacks.leases and not bridge.xt_handle_count()
        else:
            if case == "deferred_refresh_overlap":
                calls = plugin.factory_calls
                support.raises(_ui.RuntimeStateError, lambda: host.event(ident, "refresh"), "awaiting native commit")
                assert plugin.factory_calls == calls, "a second candidate must not build/replace a pending snapshot"
                assert len(runtime._state.callbacks.leases) == before + 2
            committed = case != "deferred_refresh_reject"
            host.commit_update(ident, committed=committed, acknowledge=False)
            assert presentation.page is original_page and presentation.model == original_model, "ACK has not reached the owner yet"
            if committed:
                assert host.presentations[ident]["model"] != original_model
                assert host.event(ident, "change", key="known_key", value=False) is False, "S2 events wait for ACK FIFO admission"
            else:
                assert host.presentations[ident]["model"] == original_model
                host.event(ident, "change", key="known_key", value=False)
                assert plugin.events[-1] == (7, ["switch", 1, False, False])
            host.acknowledge_update(ident)
            assert len(runtime._state.callbacks.leases) == before and bridge.xt_handle_count() == handles_before
            if committed:
                assert not original_page.lease.open and presentation.page is not original_page
                count = len(plugin.events)
                assert host.deliver(captured) is False
                support.raises(_ui.RuntimeStateError, lambda: host.deliver(captured, enforce_native_gate=False), "retired snapshot")
                assert len(plugin.events) == count, "old event must never look up replacement callback IDs"
            else:
                assert original_page.lease.open and presentation.page is original_page
                assert presentation.model == original_model
            host.event(ident, "change", key="known_key", value=True)
            assert plugin.events[-1] == (7, ["switch", 2 if committed else 1, True, True])
            host.close_ui(ident)

    elif case == "root_callback_arguments":
        ident, rows = read()
        row, model = widget(rows)
        editor = model["children"][0]
        event(ident, kind="widget", rowId=row["row_id"], widgetId=editor["id"], callbackId=editor["callback"], event="change", value="ab")
        event(ident, kind="click", callbackId=row["callback_id"])
        event(ident, kind="click", callbackId=row["long_callback_id"])
        event(ident, kind="click", callbackId=rows[0]["callback_id"])
        assert plugin.events[-3:] == [(7, ["root", 1, "ab"]), (7, ["root-long", 1, "ab"]), (7, ["ordinary", True])]
        release(ident)
        plugin.mode = "root_zero"
        ident, rows = read()
        row, _ = widget(rows)
        event(ident, kind="click", callbackId=row["callback_id"])
        assert plugin.events[-1] == (7, ["root-zero", 1])
        release(ident)

    elif case == "worker_lifetime":
        ident, rows = read()
        errors = []
        def wrong_worker():
            try: event(ident, kind="change", key="known_key", value=True)
            except Exception as error: errors.append(error)
        thread = threading.Thread(target=wrong_worker)
        thread.start(); thread.join(2)
        assert not thread.is_alive() and isinstance(errors[0], _ui.RuntimeStateError)
        assert host.value("known_key") is None
        owner = runtime._state.owner_token
        runtime._state.owner_token = "replacement-owner"
        support.raises(_ui.RuntimeStateError, lambda: event(ident, kind="change", key="known_key", value=True))
        runtime._state.owner_token = owner
        release(ident)
        release(ident)
        ident, _ = read()
        runtime.unload()
        assert not runtime._state.settings_pages and not runtime._state.callbacks.leases
        print("MANAGER_CUSTOM_ALIAS_OK " + case)
        return

    elif case == "budgets":
        for mode in ("oversize", "too_many_callbacks"):
            plugin.mode = mode
            support.raises(ValueError, read)
            assert not runtime._state.settings_pages and not runtime._state.callbacks.leases
        plugin.mode = "too_deep"
        ident, rows = read()
        assert "8 levels/512" in rows[0]["custom_error"]
        release(ident)

    assert not runtime._state.settings_pages
    assert not bridge.xt_handle_count()
    runtime.unload()
    assert not runtime._state.callbacks.leases
    print("MANAGER_CUSTOM_ALIAS_OK " + case)


if __name__ == "__main__":
    worker(sys.argv[1], sys.argv[2])
else:
    import pytest

    @pytest.mark.parametrize("case", CASES)
    def test_manager_custom_alias(case, tmp_path):
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(tmp_path)],
            cwd=tmp_path, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        assert "MANAGER_CUSTOM_ALIAS_OK " + case in result.stdout
