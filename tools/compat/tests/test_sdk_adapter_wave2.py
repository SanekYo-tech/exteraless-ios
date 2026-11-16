"""Actual SDK helpers and explicit Python ports; strict native service unit fixtures.

Every scenario runs in a fresh -I -S -B process with a hard 20-second timeout.
"""

import gc
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import threading


ROOT = Path(__file__).resolve().parents[3]
CASES = ("registry", "settings_menu", "config", "pill_types", "pills", "pill_scopes", "ui", "tl", "tl_hooks", "queues", "queue_publication", "cancellation_winners", "registrations", "native_controllers", "notifications", "notification_payloads", "reflection", "failures", "owner_binding", "protected_settings")


def worker(case, directory):
    sys.path.insert(0, str(ROOT / "python"))
    support_spec = importlib.util.spec_from_file_location(
        "_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))
    support = importlib.util.module_from_spec(support_spec)
    support_spec.loader.exec_module(support)

    class Host(support.StrictNativeHost):
        def __init__(self, root):
            super().__init__(root)
            self.owner = "native-owner-generation-1"
            self.serial = 0
            self.presentations, self.menus, self.requests, self.tasks = {}, {}, {}, {}
            self.messages, self.logs = [], []
            self.interceptions = {}
            self.fail_present = False
            self.fail_ui_update = False
            self.ui_updates = 0
            self.settings_updates = {}
            self.protected_paths = []
            self.client_settings = {}
            self.client_reads = []
            self.native_operations = {}
            self.service_operations = {
                "nativeGetUser", "nativeGetChat", "nativeObservePeer", "nativePeerInfo", "nativeGetContacts",
                "nativeMessageMedia", "nativeResourceStatus", "nativeObserveResource", "nativeDownload", "nativeNotificationSettings"}
            self.exports = self.service_operations | {"nativeConnectionState", "notificationSupported", "notificationSubscribe",
                "notificationUnsubscribe", "nativeServiceState", "nativeServiceCancel", "sdkEcho"}
            native_events = (ROOT / "swift/PluginHost/Sources/PluginHost/NativeServiceOperations.swift").read_text(encoding="utf-8")
            self.notification_events = [{"id": int(ident), "name": name} for name, ident in re.findall(r"case\s+(\w+)\s*=\s*(\d+)", native_events)]
            self.cancel_override = "native"
            self.release_counts = {}
            self.connection_state = None
            self.pause_task_return = False
            self.task_admitted, self.resume_task_return = threading.Event(), threading.Event()
            self.exports.update({"pillRegister", "pillUpdate", "pillUnregister", "pillGetLayout", "pillSaveLayout"})
            self.pill_regs, self.pill_mappings, self.pill_updates = {}, {910: 12007}, []
            self.pill_layout = {"active": [5, 12007, 22222], "hidden": [6], "selected": 5, "infiniteScrolling": True}
            self.pill_revision = 1
            self.pill_snapshot_reads = 0
            self.fail_pill = False

        def identity(self, kind):
            self.serial += 1
            return f"{kind}-{self.serial}"

        def release(self, handles):
            handles = list(handles)
            for handle in handles: self.release_counts[handle] = self.release_counts.get(handle, 0) + 1
            runtime.release_handles_json(json.dumps(handles))

        def call(self, request):
            from virtualjava import JavaMemberError
            request = dict(request)
            token = request.pop("ownerToken", None)
            assert token in (None, self.owner), "retired native owner"
            member, args = request["member"], request["args"]
            if request["op"] == "member_kind":
                assert not args
                return "method" if member in self.exports else "unknown"
            if member == "postToOwner":
                assert token == self.owner
                callback, delay, queue = args
                ident = self.identity("task")
                self.tasks[ident] = self.register(callback)
                if self.pause_task_return:
                    self.task_admitted.set()
                    assert self.resume_task_return.wait(3), "test did not unblock background admission"
                return {"id": ident}
            assert threading.get_ident() == self.thread
            if request["fqcn"] != "exteraless.ios.Runtime":
                if request["fqcn"] == "org.telegram.messenger.AndroidUtilities" and member in ("dp", "dpf2"):
                    import math
                    return math.ceil(args[0]) if member == "dp" else float(args[0])
                if request["fqcn"] == "org.telegram.messenger.LocaleController" and member == "getString":
                    assert args == ["Cancel"]
                    return "Отмена"
                return super().call(request)
            if member == "sdkEcho":
                if member not in self.exports: raise JavaMemberError("sdkEcho provider removed")
                assert token == self.owner
                return args[0]
            if member == "pillRegister":
                assert token == self.owner and "ui" in self.permissions
                if self.fail_pill: raise JavaMemberError("pill provider unavailable")
                descriptor, callbacks = args
                assert set(callbacks) == {"start", "update", "tap", "longPress", "stop"}
                assert set(descriptor) <= {"androidId", "title", "symbol", "refreshIntervalMs"}
                android = descriptor["androidId"]
                native = {910: 12007, 22222: 13000, -321: 14003}[android]  # native fixture allocation, never SDK arithmetic
                self.pill_mappings[android] = native
                for ident, previous in list(self.pill_regs.items()):
                    if previous["androidId"] == android:
                        raise JavaMemberError("duplicate native pill registration")
                ident = self.identity("pill")
                self.pill_regs[ident] = {"nativeId": native, "androidId": android, "selections": set(),
                    "callbacks": {name: self.register(fn) for name, fn in callbacks.items()}}
                return {"id": ident, "androidId": android, "nativeId": native, "mappingVersion": 1,
                    "refreshIntervalMs": max(5000, descriptor["refreshIntervalMs"]) if descriptor["refreshIntervalMs"] else 0}
            if member == "pillUpdate":
                ident, model = args
                assert set(model) <= {"selection", "title", "value", "detail", "source", "phase", "updatedAtMs", "progress", "isHighlighted"}
                if model["selection"] not in self.pill_regs[ident]["selections"]: raise JavaMemberError("InvalidHandle: retired selection")
                self.pill_updates.append((ident, dict(model)))
                return None
            if member == "pillUnregister":
                previous = self.pill_regs.pop(args[0], None)
                if previous: self.release(previous["callbacks"].values())
                return previous is not None
            if member == "pillGetLayout":
                assert {"ui", "settings"} <= self.permissions
                self.pill_snapshot_reads += 1
                return dict(self.pill_layout, revision=str(self.pill_revision), idSpace="native", mappingVersion=1,
                    mappings=[{"androidId": android, "nativeId": native} for android, native in self.pill_mappings.items()])
            if member == "pillSaveLayout":
                model, = args
                assert model["idSpace"] == "native" and {"ui", "settings"} <= self.permissions
                if model["revision"] != str(self.pill_revision): raise JavaMemberError("SettingsConflict")
                assert len(set(model["active"] + model["hidden"])) == len(model["active"] + model["hidden"])
                self.pill_layout = {key: model[key] for key in ("active", "hidden", "selected", "infiniteScrolling")}
                self.pill_revision += 1
                return None
            if member in self.service_operations or member == "notificationSubscribe":
                assert token == self.owner and len(args) == 2
                model, callback = args
                assert type(model["account"]) is int
                assert "messages.read" in self.permissions
                if member == "nativeDownload": assert {"network", "files"} <= self.permissions
                ident = self.identity(member)
                self.native_operations[ident] = {"member": member, "model": model, "handle": self.register(callback),
                    "state": {"ready": False, "kind": member, "value": None}}
                return {"id": ident}
            if member == "nativeServiceState": return self.native_operations[args[0]]["state"]
            if member in ("nativeServiceCancel", "notificationUnsubscribe"):
                if self.cancel_override == "throw": raise RuntimeError("fixture cancellation transport failed")
                if self.cancel_override != "native": return self.cancel_override
                record = self.native_operations.pop(args[0], None)
                if record: self.release([record["handle"]])
                return record is not None
            if member == "notificationSupported": return list(self.notification_events)
            if member == "nativeConnectionState":
                if self.connection_state is None: raise JavaMemberError("native state is not published")
                return self.connection_state
            if member == "getProtectedPaths": return list(self.protected_paths)
            if member in ("getClientSetting", "setClientSetting"):
                if "settings" not in self.permissions: raise PermissionError("settings permission required")
                if args[0] == "secret": raise PermissionError("secret value is not public")
                if member == "getClientSetting":
                    self.client_reads.append(args[0])
                    return self.client_settings.get(args[0], args[1] if len(args) == 2 else None)
                self.client_settings[args[0]] = args[1]
                return None
            if member == "uiPresent":
                assert token == self.owner and len(args) == 3
                if self.fail_present: raise JavaMemberError("native presentation unavailable")
                kind, model, callbacks = args
                assert kind in {"alert", "bulletin", "toast", "bottomSheet", "menu", "settings", "share", "page"}
                assert "closed" in callbacks
                json.dumps(model, allow_nan=False)
                ident = self.identity("ui")
                self.presentations[ident] = {"kind": kind, "model": model, "callbacks": {
                    key: self.register(value) for key, value in callbacks.items()}, "visible": False}
                return {"id": ident}
            if member == "uiState": return {"visible": self.presentations[args[0]]["visible"]}
            if member == "uiUpdate":
                assert len(args) in (2, 3) and isinstance(args[1], dict)
                assert "__handle__" not in json.dumps(args[1]), "uiUpdate cannot add C callbacks"
                if self.fail_ui_update: raise JavaMemberError("native resource unavailable")
                if len(args) == 3:
                    ident, model, control = args
                    assert ident not in self.settings_updates
                    assert control["previousSnapshotId"] == self.presentations[ident]["model"]["settingsSnapshotId"]
                    assert control["snapshotId"] == model["settingsSnapshotId"]
                    update_id = self.identity("settings-update")
                    self.settings_updates[ident] = {"id": update_id, "model": model,
                        "previous": control["previousSnapshotId"], "snapshot": control["snapshotId"],
                        "handle": self.register(control["completion"])}
                    return {"id": update_id}  # Admission only; the fixture must explicitly commit.
                self.ui_updates += 1
                self.presentations[args[0]]["model"] = args[1]
                return None
            if member == "uiDismiss":
                if not runtime._state.callbacks.active:
                    record = self.presentations.pop(args[0], None)
                    if record: self.release(record["callbacks"].values())
                    update = self.settings_updates.pop(args[0], None)
                    if update: self.release([update["handle"]])
                return None
            if member == "uiActiveFragment": return {"account": 2, "kind": "chat", "id": "screen-fixture", "scope": "scope-fixture", "isPresented": True}
            if member == "uiNavigate":
                assert args[0]["sourceId"] == "screen-fixture"
                self.messages.append(["navigate", args[0]])
                return None
            if member == "menuRegister":
                model, callback = args
                assert model["menu_type"] in {"MESSAGE_CONTEXT_MENU", "MAIN_MENU", "DRAWER_MENU", "CHAT_ACTION_MENU", "PROFILE_ACTION_MENU"}
                for ident, entry in list(self.menus.items()):
                    if entry["model"]["item_id"] == model["item_id"]:
                        self.release([entry["handle"]]); del self.menus[ident]
                ident = self.identity("menu")
                self.menus[ident] = {"model": model, "handle": self.register(callback)}
                return {"id": ident}
            if member == "menuRemove":
                self.release([self.menus.pop(args[0])["handle"]])
                return None
            if member in ("fileRegister", "intentRegister"):
                ident = self.identity(member)
                self.interceptions[ident] = (self.register(args[1]), args[0])
                return {"id": ident}
            if member in ("fileRemove", "intentRemove"):
                self.release([self.interceptions.pop(args[0])[0]])
                return None
            if member in ("tlRequest", "getPeer", "sendMedia", "editMedia"):
                model, callback = args
                assert model["schemaVersion"] == 1 and type(model["account"]) is int
                assert "__handle__" not in json.dumps(model)
                if member == "tlRequest":
                    assert model["request"]["_"] in ("users.getUsers", "messages.sendMessage", "messages.editMessage")
                if member in ("sendMedia", "editMedia"):
                    assert model["kind"] in ("photo", "video", "document", "audio", "album", "text")
                    if model["kind"] == "album": assert all(Path(item["path"]).is_file() for item in model["items"])
                    elif model["kind"] != "text": assert Path(model["path"]).is_file()
                ident = self.identity("request")
                self.requests[ident] = (self.register(callback), model)
                return {"requestId": ident}
            if member == "tlCancel":
                record = self.requests.pop(args[0], None)
                if record: self.release([record[0]])
                return {"cancelled": record is not None}
            if member == "cancelOwnerTask":
                if self.cancel_override == "throw": raise RuntimeError("fixture cancellation transport failed")
                if self.cancel_override != "native": return self.cancel_override
                handle = self.tasks.pop(args[0], None)
                if handle: self.release([handle])
                return handle is not None
            if member == "sendMessage":
                self.messages.append(args)
                return {"status": "scheduled", "requestId": self.identity("message")}
            if member == "logEvent": self.logs.append(args[0]); return None
            if member in ("addToClipboard", "openURL"):
                self.messages.append([member, *args]); return None
            return super().call(request)

        def event(self, ident, event, **values):
            record = self.presentations[ident]
            if "settingsSnapshotId" in record["model"]:
                values["_uiSettingsSnapshot"] = record["model"]["settingsSnapshotId"]
                values["_uiRevision"] = record.get("revision", 0)
            handle = record["callbacks"].get(event)
            if handle is not None:
                return runtime.invoke_handle_json(handle, "__call__", json.dumps([dict(id=ident, event=event, **values)]))

        def commit_settings_update(self, ident):
            update = self.settings_updates.pop(ident)
            record = self.presentations[ident]
            record["model"] = update["model"]
            record["revision"] = record.get("revision", 0) + 1
            self.ui_updates += 1
            try:
                runtime.invoke_handle_json(update["handle"], "__call__", json.dumps([{
                    "id": ident, "event": "settingsUpdate", "updateId": update["id"], "_uiTerminal": True,
                    "previousSnapshotId": update["previous"], "snapshotId": update["snapshot"],
                    "committed": True, "_uiRevision": record["revision"]}]))
            finally:
                self.release([update["handle"]])
            return update["handle"]

        def close_ui(self, ident):
            record = self.presentations[ident]
            try:
                try: self.event(ident, "dismiss")
                finally: self.event(ident, "closed", reason="dismissed")
            finally:
                self.release(record["callbacks"].values())
                update = self.settings_updates.pop(ident, None)
                if update: self.release([update["handle"]])
                del self.presentations[ident]

        def response(self, ident, response, error=None):
            handle, _ = self.requests.pop(ident)
            try: return runtime.invoke_handle_json(handle, "run", json.dumps([response, error]))
            finally: self.release([handle])

        def service_event(self, ident, value, error=None):
            record = self.native_operations[ident]
            subscription = record["member"] in ("nativeObservePeer", "nativeObserveResource")
            record["state"] = {"ready": True, "kind": record["member"], "value": value}
            try: return runtime.invoke_handle_json(record["handle"], "__call__", json.dumps([value, error]))
            finally:
                if not subscription:
                    self.native_operations.pop(ident)
                    self.release([record["handle"]])

        def pill_event(self, ident, event, selection="selection-1", account=4, generation="account-1", *extra):
            record = self.pill_regs[ident]
            context = {"id": ident, "nativeId": record["nativeId"], "androidId": record["androidId"],
                "selection": selection, "account": account, "accountRecordId": "1234567890123456789", "generation": generation}
            if event == "start": record["selections"].add(selection)
            if event == "stop": record["selections"].discard(selection)
            return runtime.invoke_handle_json(record["callbacks"][event], "__call__", json.dumps([context, *extra]))

    support.StrictNativeHost = Host
    runtime, host, bridge = support.bootstrap(Path(directory), "ios_sdk_wave2")
    if case not in ("owner_binding", "protected_settings"): runtime.bind_owner_json(json.dumps(host.owner))
    path = support.copy_fixture(host, "tl_hooks" if case == "tl_hooks" else "wave2")
    runtime.load_json(path)
    from extera_utils import plugin_loader as loader
    import client_utils
    from virtualjava import finder, get_registered
    backend = finder._State.backend
    plugin = loader.plugins[host.plugin_id].instance
    raises = support.raises

    if case == "registry":
        from java import jclass, jint, jarray
        from hook_utils import get_private_field, set_private_field
        List = jclass("java.util.ArrayList")
        values = List(["one"])
        assert values.add("two") and values.getClass().getDeclaredMethod("size").invoke(values, []) == 2
        values.set(0, "changed")
        view = values.subList(0, 1)
        view.set(0, "through-view")
        assert values[0] == "through-view"
        readonly = jclass("java.util.Collections").unmodifiableList(values)
        values.add("visible-in-view")
        assert readonly.get(readonly.size() - 1) == "visible-in-view"
        raises(TypeError, lambda: readonly.add("blocked"), "read-only")
        prefix = values.subList(0, 1)
        previous_size = values.size()
        prefix.clear()
        assert values.size() == previous_size - 1 and prefix.isEmpty()
        mapping = jclass("java.util.HashMap")()
        assert mapping.put("key", 7) is None and mapping.put("key", 9) == 7
        assert mapping.entrySet().get(0).getValue() == 9
        assert jclass("java.lang.String")("a😀").length() == 3
        assert jclass("java.lang.String")("abc").hashCode() == 96354
        from extera_utils.classes import J
        assert J(values).JIgnoreResult.add("side-effect") is None and values[-1] == "side-effect"
        assert jint(0xFFFFFFFF, truncate=True) == -1
        assert list(jarray(int)(3)) == [0, 0, 0]
        assert list(jarray(jint)(2)) == [0, 0]
        array = jarray(jint)([1, 2])
        array[1] = 3
        raises(TypeError, lambda: array.append(4), "fixed")
        raises(TypeError, lambda: array.__setitem__(slice(None), [1]), "fixed")
        from java import dynamic_proxy
        first = jclass("fixture.FirstInterface")
        second = jclass("fixture.SecondInterface")
        class Both(dynamic_proxy(first, second)):
            def __init__(self): self.value = 7
            def run(self): return self.value
        proxy = Both()
        assert proxy.run() == 7 and isinstance(proxy, first) and isinstance(proxy, second)
        assert not isinstance(proxy, jclass("fixture.Unrelated"))
        model = get_registered("org.telegram.tgnet.TLRPC$TL_users_getUsers")()
        model.id = List()
        assert get_private_field(model, "id") is model.id
        assert set_private_field(model, "id", List([1]))
        raises(AttributeError, lambda: getattr(model, "invented"))
        raises(Exception, lambda: jclass("unknown.NotImplemented").missing())
        assert finder._State.backend is backend
    elif case == "config":
        from java import jclass
        from virtualjava import get_registered
        from exteraless_runtime import UnsupportedSurfaceError
        host.client_settings = {
            "appearance.disableVibration": False, "appearance.avatarCorners": 28, "appearance.singleCornerRadius": False,
            "appearance.glassOutlineStyle": 0, "appearance.dividerStyle": 1, "appearance.separateHeaders": False,
            "appearance.centerActionBarTitle": False, "tools.flashWarmth": 50, "ai.translationProvider": 1,
            "ai.preferredTranslateTargetLang": "en", "privacy.proxyDisableConditions": 2,
            "chats.showTextTranslate": True, "ai.showTextTranslate": False, "ai.deepLTranslateKey": "private-fixture-credential"}
        extera = jclass("com.exteragram.messenger.ExteraConfig")
        neko = jclass("tw.nekomimi.nekogram.NekoConfig")
        na = jclass("xyz.nextalone.nagram.NaConfig")
        appearance = jclass("app.exteraless.appearance.AppearanceConfig")
        corner = jclass("com.exteragram.messenger.AvatarCornerType")
        with loader.plugin_context(host.plugin_id):
            assert extera.getInAppVibration() is True and extera.inAppVibration is True
            extera.inAppVibration = False
            assert host.client_settings["appearance.disableVibration"] is True and neko.disableVibration.Bool() is True
            assert neko.disableVibration.String() == "true"
            assert neko.disableVibration.toggleConfigBool() is False and extera.getInAppVibration() is True
            assert get_registered("com.exteragram.messenger.ExteraConfig").inAppVibration() is True
            raises(TypeError, lambda: neko.disableVibration.Int(), "not int")
            raises(TypeError, lambda: neko.disableVibration.setConfigBool(1), "boolean")
            assert extera.getAvatarCorners(100, True, True) == 33
            assert extera.getAvatarCorners(100, True, corner.FORUM) == 33
            assert extera.getAvatarCorners(100, True, True, True) == 31
            assert extera.getAvatarCorners(100, True, corner.COMMUNITY) == 28
            assert appearance.INSTANCE.getAvatarCorners(100, 1, True) == 31
            assert extera.getAvatarCorners(100) == 50 and extera.getAvatarCorners(100, True) == 50
            raises(TypeError, lambda: extera.getAvatarCorners(100, True, "FORUM"), "expected one")
            extera.setAvatarCorners(10.5)
            assert appearance.avatarCorners.Int() == 11 and extera.getAvatarCorners() == 11.0
            extera.setFlashWarmth(0.25)
            assert host.client_settings["tools.flashWarmth"] == 25 and extera.getFlashWarmth() == 0.25
            style = jclass("com.exteragram.messenger.GlassOutlineStyle")
            extera.setGlassOutlineStyle(style.SOLID)
            assert extera.getGlassOutlineStyle() is style.SOLID and style.SOLID.ordinal() == 1
            assert style.valueOf("GLARE") is style.GLARE
            extera.setCenterTitle(True)
            assert na.INSTANCE.getCenterActionBarTitle().Bool() is True and appearance.centerTitle() is True
            assert extera.getTranslationProvider() == 1
            na.INSTANCE.getPreferredTranslateTargetLang().setConfigString("雪\0π")
            assert extera.targetLang == "雪\0π"
            extera.setTargetLang(None)
            assert extera.getCurrentLangName() == "app"
            assert na.INSTANCE.getShowTextTranslate().Bool() is True  # canonical chats key
            condition = jclass("com.exteragram.messenger.ProxyDisableCondition")
            assert extera.isProxyDisabledOn(condition.MOBILE_DATA)
            extera.setProxyDisabledOn(condition.WIFI, True)
            assert host.client_settings["privacy.proxyDisableConditions"] == 6
            reads = host.client_reads[:]
            raises(PermissionError, lambda: na.INSTANCE.getDeepLTranslateKey().String(), "private")
            assert host.client_reads == reads
            raises(UnsupportedSurfaceError, extera.getTabCounter, "not registered")
            raises(UnsupportedSurfaceError, extera.getGSON, "getGSON")
            raises(Exception, extera.getPluginsSafeMode, "getPluginConfig")
            raises(AttributeError, lambda: extera.unknownUtility)
            host.client_settings.pop("appearance.disableVibration")
            raises(UnsupportedSurfaceError, neko.disableVibration.Bool, "not registered")
            host.client_settings["appearance.disableVibration"] = False
            host.permissions.remove("settings")
            raises(PermissionError, extera.getInAppVibration, "settings")
            raises(PermissionError, lambda: neko.disableVibration.setConfigBool(True), "settings")
            assert host.client_settings["appearance.disableVibration"] is False
    elif case == "pill_types":
        from java import jclass
        from android_utils import get_context
        from exteraless_runtime._pill_types import LayoutDraft, content
        from exteraless_runtime import UnsupportedSurfaceError
        BasePill = jclass("app.exteraless.pillstack.pills.BasePill")
        PillInfo = jclass("app.exteraless.pillstack.PillRegistry$PillInfo")
        PillType = jclass("app.exteraless.pillstack.PillType")
        class Reading(BasePill):
            def getPillId(self): return -321
            def getRefreshInterval(self): return 1000
        created = []
        def creator(context, resources):
            created.append((context, resources))
            return Reading(context, resources)
        info = PillInfo(-321, "Reading", "sf:chart.bar", 0xFF336699, 0xFF336699, creator)
        assert info.id == -321 and info.id() == -321 and info.name == info.name() == "Reading"
        reading = info.creator().create(get_context(), None)
        assert created == [(get_context(), None)] and reading.isRefreshDue()
        reading.setContent({"value": "12 MB", "phase": "ready"})
        assert reading.to_pill_content() == {"value": "12 MB", "phase": "ready"}
        reading.markDataUpdated()
        assert not reading.isRefreshDue() and reading.to_pill_content()["updatedAtMs"] > 0
        reading.startLoading(); assert reading.loading
        reading.stopLoading(); assert not reading.loading
        raises(ValueError, lambda: content({"updatedAtMs": 0}), "positive")
        raises(ValueError, lambda: content({"progress": float("nan")}), "finite")
        raises(UnsupportedSurfaceError, lambda: reading.setLoadingTargetView(object()), "Android View")
        assert [value.getId() for value in PillType.values()] == list(range(1, 16))
        assert PillType.CACHE.id() == 5 and PillType.LAST_SEEN.getId() == 15
        draft = LayoutDraft()
        raises(RuntimeError, draft.values, "not been read")
        draft.accept([5, -321, 98765], [6])
        retained = draft.active
        retained.remove(jclass("java.lang.Integer")(-321)); retained.add(7)
        draft.accept([6], [5])
        assert draft.dirty and draft.values() == ([5, 98765, 7], [6])
        draft.accept([5, 98765, 7], [6], force=True)
        assert retained is draft.active and not draft.dirty  # includes unknown/dormant ID
    elif case in ("pills", "pill_scopes"):
        from java import jclass
        from exteraless_runtime import RuntimeStateError, UnsupportedSurfaceError
        BasePill = jclass("app.exteraless.pillstack.pills.BasePill")
        Registry = jclass("app.exteraless.pillstack.PillRegistry")
        Config = jclass("app.exteraless.pillstack.PillStackConfig")
        made = []
        class Reading(BasePill):
            def __init__(self, context, resources, ident): super().__init__(context, resources); self.ident = ident; made.append(self)
            def getPillId(self): return self.ident
            def getRefreshInterval(self): return 1000
            def onPillSelected(self): plugin.note("pill-selected"); return object()
            def onUpdateData(self, force):
                plugin.note(["pill-update", force, self.pill_context["accountRecordId"]])
                self.setContent({"value": "12 MB", "phase": "ready", "updatedAtMs": 1700000000123})
                return {1: object()}
            def onPillClicked(self): plugin.note("pill-clicked"); return object()
            def onPillLongClicked(self): plugin.note("pill-long"); return True
            def onPillUnselected(self): raise ValueError("local stop cleanup")
            def updateColors(self): pass
        def info(ident):
            return Registry.PillInfo(ident, "Reading", "sf:chart.bar", 0, 0,
                lambda context, resources: Reading(context, resources, ident))
        with loader.plugin_context(host.plugin_id):
            first = info(910)
            Registry.register(first)
            ident = first.registrationId
            assert first.nativeId == 12007 and Registry.getPillInfo(910) is first
            raises(RuntimeStateError, lambda: Registry.register(info(910)), "already registered")
            assert len(set(host.pill_regs[ident]["callbacks"].values())) == 5
            assert host.pill_event(ident, "start") == "null"
            assert host.pill_event(ident, "update", "selection-1", 4, "account-1", True) == "null"
            assert plugin.events[-1] == (["pill-update", True, "1234567890123456789"], 4)
            assert host.pill_updates[-1][1]["selection"] == "selection-1"
            assert host.pill_event(ident, "longPress") == "true"
            assert host.pill_event(ident, "tap") == "null"
            if case == "pills":
                active = Config.getActivePills()
                assert list(active) == [5, 910, 22222] and Config.activePillsRaw.String() == "5,910,22222"
                reads = host.pill_snapshot_reads
                for _ in range(40): assert Config.getActivePills() is active
                assert host.pill_snapshot_reads == reads  # Native has 32 CAS receipts/owner, not an unbounded query cache.
                Config.saveLastActivePillId(910)
                assert host.pill_layout["selected"] == 12007 and Config.lastActivePillId.Int() == 910
                second = info(22222)
                Registry.register(second)
                active.add(22222)  # The existing opaque native 22222 must remain distinct.
                Config.savePillsLayout()
                assert host.pill_layout["active"] == [5, 12007, 22222, 13000]
                assert active is Config.getActivePills()
                raises(UnsupportedSurfaceError, Config.activePillsRaw.String, "ambiguous")
                active.add(7)
                host.pill_revision += 1
                Config.getHiddenPills()
                raises(Exception, Config.savePillsLayout, "SettingsConflict")
                assert 7 in active and 7 not in host.pill_layout["active"]
                Config.loadConfig(True)
                assert active is Config.getActivePills() and 7 not in active
                Registry.unregister(22222)
                host.permissions.remove("settings")
                third = info(-321)
                Registry.register(third)
                raises(PermissionError, Config.getActivePills, "settings")
                Registry.unregister(-321)
                host.permissions.add("settings")
            else:
                old = made[0]
                assert host.pill_event(ident, "stop") == "null" and any("local stop cleanup" in row["message"] for row in host.logs)
                raises(RuntimeStateError, lambda: old.setContent({"value": "late"}), "retired")
                host.pill_event(ident, "start", "selection-2", 5, "account-2")
                assert made[-1] is not old
                other = made[-1]
                host.pill_event(ident, "start", "selection-3", 5, "account-2")
                other.setContent({"value": "parallel selection"})
                assert host.pill_updates[-1][1]["selection"] == "selection-2"
                raises(RuntimeStateError, lambda: host.pill_event(ident, "update", "selection-1", 4, "account-1", False), "retired")
                made[-1].setContent({"value": "new account", "updatedAtMs": None, "progress": None})
                assert host.pill_updates[-1][1]["selection"] == "selection-3"
                previous = host.pill_regs.pop(ident)
                host.release(previous["callbacks"].values())
                assert Registry.getPillInfo(910) is None
                raises(RuntimeStateError, lambda: made[-1].setContent({"value": "retired"}), "retired")
                Registry.register(info(910))
                assert Registry.getPillInfo(910).nativeId == 12007
            Registry.unregister(910)
            host.fail_pill = True
            raises(Exception, lambda: Registry.register(info(-321)), "unavailable")
            assert not runtime._state.callbacks.leases and not bridge.xt_handle_count()
    elif case == "settings_menu":
        from base_plugin import MenuItemData, MenuItemType, PluginsController
        import plugin_settings
        with loader.plugin_context(host.plugin_id):
            plugin.set_setting("literal", {"__handle__": 123, "__bytes__": "not-a-tag"}, True)
            plugin.import_settings({"other": "雪", "enabled": False}, reload_settings=False)
            assert plugin.export_settings()["literal"]["__handle__"] == 123
            assert plugin_settings.get_settings(host.plugin_id)["other"] == "雪"
            plugin_settings._settings_cache[host.plugin_id].pop("other")
            assert plugin.get_setting("enabled") is False  # Does not overwrite the dirty SDK mirror.
            plugin_settings._save_settings_to_file()
            assert "other" not in plugin.export_settings()
            assert PluginsController.getInstance().getPlugin(host.plugin_id) is plugin
            ident = plugin.add_menu_item(MenuItemData(MenuItemType.MAIN_MENU, "Do", plugin.menu, item_id="action"))
            assert ident == "action"
            old = next(iter(host.menus.values()))["handle"]
            assert plugin.add_menu_item(MenuItemData(MenuItemType.MAIN_MENU, "Do", plugin.menu, item_id="action")) == ident
            assert old not in host.handles and len(runtime._state.callbacks.leases) == 1
            entry = next(iter(host.menus.values()))
            context = {"peer": 42, "account": 4, "fragment": {"id": "screen-fixture", "account": 4},
                       "message": {"getId": 7, "getDialogId": 42, "isOutOwner": False}}
            assert runtime.invoke_handle_json(entry["handle"], "__call__", json.dumps([context])) == "null"
            event, account = plugin.events[-1]
            assert account == 4 and event[0] == "menu" and event[1]["peer"] == 42
            assert event[1].message.getId() == 7 and event[1].message.getDialogId() == 42
            assert event[1].message.isOutOwner() is False and event[1].context is runtime._state.ui_context
            raises(AttributeError, lambda: event[1].message.isMusic)
            fragment = event[1].fragment
            assert fragment.getCurrentAccount() == 4
            fragment.presentFragment({"route": "page", "title": "Scoped"})
            assert host.messages[-1][1]["sourceId"] == "screen-fixture"
            raises(RuntimeError, lambda: fragment.presentFragment({"route": "page", "sourceId": "another"}), "retargeted")
            raises(RuntimeError, lambda: runtime.invoke_handle_json(entry["handle"], "__call__", '[{"account":true}]'), "account")
            plugin.remove_menu_item(ident)
            plugin.reset_settings()
            assert plugin.export_settings() == {} and host.settings_reloads >= 2
    elif case == "ui":
        from ui.alert import AlertDialogBuilder
        from java import jclass
        with loader.plugin_context(host.plugin_id):
            field = jclass("android.widget.EditText")()
            field.setText("initial")
            builder = AlertDialogBuilder().set_title("Title").set_view(field).set_positive_button("OK", plugin.button)
            builder.set_message_text_view_clickable(True).set_blurred_background(True, False)
            builder.set_on_dismiss_listener(plugin.dismissed).show()
            dialog = builder.get_dialog()
            native_handles = dict(host.presentations[dialog.id]["callbacks"])
            next_handle = host.next_handle
            assert set(native_handles) == {"positive", "negative", "neutral", "item", "dismiss", "cancel", "back", "change", "closed"}
            assert len(set(native_handles.values())) == 9
            assert host.presentations[dialog.id]["model"]["messageClickable"] is True
            assert host.presentations[dialog.id]["model"]["blurredBackground"] is True
            assert host.presentations[dialog.id]["model"]["blurBehind"] is False
            builder.set_blurred_background(False)
            assert host.presentations[dialog.id]["model"]["blurredBackground"] is False
            field.setVisibility(8)
            assert host.presentations[dialog.id]["model"]["view"]["visibility"] == "gone"
            field.setVisibility(0)
            assert dialog.isShowing() is False
            host.presentations[dialog.id]["visible"] = True
            assert dialog.isShowing() is True
            host.event(dialog.id, "positive", which=-1, values={field.model["id"]: "edited"})
            assert field.getText() == "edited" and plugin.events[-1][0][:2] == ["button", -1]
            builder.make_button_red(-1)
            assert host.presentations[dialog.id]["model"]["buttons"][0]["destructive"] is True
            dialog.getButton(-1).setTextColor(0xFF336699)
            assert host.presentations[dialog.id]["model"]["buttons"][0]["color"] == 0xFF336699
            builder.make_button_red(-1)
            assert host.presentations[dialog.id]["model"]["buttons"][0]["color"] is None
            dialog.getButton(-1).setEnabled(False)
            seen = []
            builder.set_positive_button("Changed", lambda current, which: seen.append((current is builder, which, field.getText())))
            builder.set_title("Live title").set_message("Live message").set_message_text_view_clickable(False)
            model = host.presentations[dialog.id]["model"]
            assert model["title"] == "Live title" and model["message"] == "Live message" and model["messageClickable"] is False
            assert model["buttons"][0]["enabled"] is False and model["buttons"][0]["destructive"] is True
            host.event(dialog.id, "positive", which=-1, values={field.model["id"]: "captured before click"})
            assert seen == [(True, -1, "captured before click")]
            builder.set_items(["Old"], lambda current, which: seen.append("old"), icons=["msg_copy"])
            builder.set_items(["New"], lambda current, which: seen.append(("item", current is builder, which, field.getText())), icons=["sf:checkmark"])
            assert host.presentations[dialog.id]["model"]["items"] == [{"text": "New", "icon": "sf:checkmark"}]
            host.event(dialog.id, "item", which=0, values={field.model["id"]: "item captured"})
            assert seen[-1] == ("item", True, 0, "item captured") and "old" not in seen
            builder.set_on_dismiss_listener(lambda current: seen.append(("dismiss", current is builder)))
            builder.set_on_back_button_listener(lambda current: seen.append(("back", current is builder)))
            host.event(dialog.id, "back")
            assert seen[-1] == ("back", True)
            assert builder._builder.create() is dialog and host.next_handle == next_handle
            assert host.presentations[dialog.id]["callbacks"] == native_handles
            host.close_ui(dialog.id)
            assert seen[-1] == ("dismiss", True) and not runtime._state.callbacks.leases
            Layout = jclass("android.widget.LinearLayout")
            Params = jclass("android.widget.LinearLayout$LayoutParams")
            Image = jclass("android.widget.ImageView")
            root = Layout()
            root.setPadding(1, 2, 3, 4)
            field.setTypeface({"name": "monospace", "weight": "medium"}); field.setTextSize(18)
            params = Params(-1, 40.5, 1)
            params.setMargins(5, 6, 7, 8)
            root.addView(field, params)
            image = Image(); image.setImageResource("sf:checkmark.circle")
            root.addView(image, 24, 24)
            panel = AlertDialogBuilder().set_view(root, 96).show().get_dialog()
            model = host.presentations[panel.id]["model"]["view"]
            assert model["padding"] == [1, 2, 3, 4] and model["layout"]["height"] == 96
            assert model["children"][0]["layout"] == {"width": -1, "height": 40.5, "weight": 1, "margins": [5, 6, 7, 8]}
            assert model["children"][0]["font"] == {"name": "monospace", "weight": "medium", "size": 18}
            assert model["children"][1]["image"] == "sf:checkmark.circle"
            handles = set(host.handles)
            image.setImageResource("msg_copy")
            assert host.presentations[panel.id]["model"]["view"]["children"][1]["image"] == "msg_copy"
            host.fail_ui_update = True
            raises(Exception, lambda: image.setImageResource("sf:missing-image"), "unavailable")
            assert image.model["image"] == "msg_copy"
            host.fail_ui_update = False
            assert set(host.handles) == handles
            raises(TypeError, lambda: Params(True, 10), "Bool")
            raises(TypeError, lambda: field.setPadding(1, True, 3, 4), "Bool")
            raises(TypeError, lambda: field.setTextSize(True), "Bool")
            raises(TypeError, lambda: field.setLayoutParams({"width": False}), "Bool")
            raises(Exception, lambda: field.setTypeface(object()), "font")
            raises(Exception, lambda: image.setImageResource(0), "named")
            host.close_ui(panel.id)
            for style in (2, 3):
                waiting = AlertDialogBuilder(alert_type=style).show().get_dialog()
                assert host.presentations[waiting.id]["model"]["cancelable"] is False
                host.close_ui(waiting.id)
            raises(TypeError, lambda: AlertDialogBuilder(alert_type=False), "Bool")
            raises(Exception, lambda: jclass("org.telegram.ui.ActionBar.AlertDialog$Builder")(None, False), "resources")
            raises(ValueError, lambda: runtime._state.present("alert", {}, {"closed": lambda event: None}), "reserved")
            first = runtime._state.present("bulletin", {"text": "one"}, {"action": lambda event: plugin.clicked()})
            second = runtime._state.present("bulletin", {"text": "two"}, {"action": lambda event: plugin.clicked()})
            assert set(host.presentations[first.id]["callbacks"].values()).isdisjoint(host.presentations[second.id]["callbacks"].values())
            host.close_ui(first.id); host.close_ui(second.id)
            void_ui = runtime._state.present("bulletin", {"text": "void"}, {"action": lambda event: {1: object()}})
            assert host.event(void_ui.id, "action") == "null"
            host.close_ui(void_ui.id)
            settings = runtime._state.show_settings()
            row = host.presentations[settings.id]["model"]["rows"][1]
            settings_handles = dict(host.presentations[settings.id]["callbacks"])
            assert set(settings_handles) == {"change", "action", "longAction", "refresh", "closed"}
            host.event(settings.id, "change", key="enabled", value=False, callbackId=row["callback_id"])
            assert plugin.get_setting("enabled") is False and plugin.events[-1][0] == ["change", False, False]
            rows = host.presentations[settings.id]["model"]["rows"]
            assert rows[2]["icon"] == "sf:pencil" and "integral" not in rows[4]
            old_callback = rows[3]["callback_id"]
            plugin.set_setting("ui_label", " refreshed")
            next_handle = host.next_handle
            before_update_handles = set(host.handles)
            host.fail_ui_update = True
            raises(Exception, lambda: host.event(settings.id, "refresh"), "unavailable")
            host.fail_ui_update = False
            assert host.presentations[settings.id]["model"]["rows"][3]["callback_id"] == old_callback
            assert set(host.handles) == before_update_handles, "rejected candidate completion must release its handle"
            host.event(settings.id, "action", callbackId=old_callback)
            assert plugin.events[-1][0] == "click"
            host.event(settings.id, "refresh")
            assert host.presentations[settings.id]["model"]["rows"][3]["callback_id"] == old_callback
            host.event(settings.id, "action", callbackId=old_callback)
            assert plugin.events[-1][0] == "click"
            update_handle = host.commit_settings_update(settings.id)
            rows = host.presentations[settings.id]["model"]["rows"]
            assert rows[3]["text"] == "Tap refreshed" and rows[3]["callback_id"] != old_callback
            host.event(settings.id, "action", callbackId=rows[3]["callback_id"])
            assert plugin.events[-1][0] == "click"
            host.event(settings.id, "longAction", callbackId=rows[3]["long_callback_id"])
            assert plugin.events[-1][0] == "long-click"
            # One completion wrapper per attempted update, neither retained nor
            # installed as a new presentation callback. Logical UI assertions above
            # still observe old callbacks until commit, then the refreshed callbacks.
            assert host.next_handle == next_handle + 2 and host.presentations[settings.id]["callbacks"] == settings_handles
            assert set(host.handles) == before_update_handles and host.release_counts[update_handle] == 1
            host.close_ui(settings.id)
            from android_utils import get_context
            Intent = jclass("android.content.Intent")
            share = get_context().startActivity(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "share text"))
            assert host.presentations[share.id]["model"]["text"] == "share text"
            host.close_ui(share.id)
            sheet = jclass("org.telegram.ui.ActionBar.BottomSheet$Builder")().setTitle("Sheet").setItems(["A"], None).show()
            assert host.presentations[sheet.id]["kind"] == "bottomSheet"
            host.close_ui(sheet.id)
    elif case == "tl":
        from java import jclass
        with loader.plugin_context(host.plugin_id):
            Request = jclass("org.telegram.tgnet.TLRPC$TL_users_getUsers")
            UserSelf = jclass("org.telegram.tgnet.TLRPC$TL_inputUserSelf")
            request = Request(id=[UserSelf()])
            token = client_utils.send_request(request, plugin.response, account=4)
            assert type(token).__name__ == "RequestToken"
            assert host.requests[token.native_id][1]["request"] == {"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]}
            host.response(token.native_id, [{"_": "userEmpty", "id": 17}])
            event, account = plugin.events[-1]
            assert event[1].objects[0].id == 17 and event[2] is None and account == 4
            token = client_utils.send_request(request, client_utils.RequestCallback(plugin.response, 3), account=3)
            host.response(token.native_id, None, {"_": "error", "code": 400, "text": "RPC_FAIL"})
            assert plugin.events[-1][0][2].text == "RPC_FAIL"
            token = client_utils.send_request(request, plugin.response, account=4)
            assert token.cancel() is True and not host.requests
            token = client_utils.send_request(request, lambda response, error: {1: object()}, account=4)
            assert host.response(token.native_id, None) == "null"
            assert not bridge.xt_handle_count()
            raises(ValueError, lambda: client_utils.send_request(Request(), plugin.response, account=0), "missing required")
            path = host.files / "small.bin"
            path.write_bytes(b"local-media-fixture")
            token = client_utils.send_document(42, path, caption="caption", account=4)
            assert host.requests[token.native_id][1]["kind"] == "document"
            token.cancel()
            token = client_utils.send_document(42, path, caption="**bold**", parse_mode="Markdown", account=4)
            assert host.requests[token.native_id][1]["entities"] == [{"_": "messageEntityBold", "offset": 0, "length": 4}]
            token.cancel()
            client_utils.send_text(42, "text", account=4)
            assert host.messages[-1] == [{"type": "user", "id": 42}, "text", 4]
            token = client_utils.send_text(42, "**text**", parse_mode="Markdown", replyToMsg=7, account=4)
            model = host.requests[token.native_id][1]
            assert model["kind"] == "text" and model["peer"] == {"type": "user", "id": 42}
            assert model["replyTo"] == {"id": 7} and model["caption"] == "text"
            assert model["entities"] == [{"_": "messageEntityBold", "offset": 0, "length": 4}]
            token.cancel()
            Params = jclass("org.telegram.messenger.SendMessagesHelper$SendMessageParams")
            client_utils.get_send_messages_helper(4).sendMessage(Params.of("direct params", 42))
            assert host.messages[-1][1] == "direct params"
            assert client_utils.get_account_instance(4).getConnectionsManager().account == 4
            token = client_utils.get_client(4).send_native_media({"kind": "text", "peer": {"type": "secret", "id": 7}, "caption": "encrypted native path",
                "ttlSeconds": 60, "replyTo": {"id": 5, "namespace": 2}})
            assert host.requests[token.native_id][1]["peer"] == {"type": "secret", "id": 7}
            assert host.requests[token.native_id][1]["replyTo"]["namespace"] == 2
            token.cancel()
            token = client_utils.send_album(42, [{"kind": "document", "path": str(path)}, {"kind": "document", "path": str(path)}], account=4)
            assert host.requests[token.native_id][1]["kind"] == "album"
            token.cancel()
            token = client_utils.edit_message({"peer": {"type": "user", "id": 42}, "id": 7, "kind": "document", "namespace": 3},
                text="replacement", file_path=str(path), with_spoiler=True, account=4)
            model = host.requests[token.native_id][1]
            assert model["message"] == {"id": 7, "namespace": 3} and model["spoiler"] is True
            token.cancel()
    elif case == "tl_hooks":
        schema = runtime._state.tl.schema
        assert schema.hook_names("users.getUsers") == ("TL_users_getUsers",)
        assert schema.hook_names("not.a.real.type") == ()
        assert runtime.hook_priority_json("pre_request_hook", "TL_users_getUsers", "users.getUsers") == "7"
        assert runtime.hook_priority_json("post_request_hook", "TL_users_getUsers", "users.getUsers") == "7"
        assert runtime.hook_priority_json("on_update_hook", "TL_updateUserName", "updateUserName") == "11"
        assert runtime.hook_priority_json("on_updates_hook", "TL_updates", "updates") == "13"
        assert runtime.hook_priority_json("on_updates_hook", "TL_updateUserName", "updateUserName") == "5"  # shared substring only
        assert runtime.hook_priority_json("on_update_hook", "TL_users_getUsers", "users.getUsers") == "7"  # shared substring only
        with loader.plugin_context(host.plugin_id): plugin.remove_hook("UserName"); plugin.remove_hook("getUsers")
        assert runtime.hook_priority_json("on_updates_hook", "TL_updateUserName", "updateUserName") == "null"
        assert runtime.hook_priority_json("on_update_hook", "TL_users_getUsers", "users.getUsers") == "null"
        assert runtime.hook_priority_json("pre_request_hook", "unknown", "unknown") == "null"
        def payload(field, name, value, observational=False, error=None):
            name_field = "request_name" if field in ("request", "response") else "update_name" if field == "update" else "container_name"
            snapshot = {"schemaVersion": 1, "observational": observational, "metadata": {"requestName": "users.getUsers", "nested": [1, 2]}, "canCancel": True, "tl": value}
            if error is not None: snapshot["tlError"] = error
            return json.dumps({"account": 4, name_field: name, field: snapshot})
        request = {"_": "users.getUsers", "id": [{"_": "inputUserSelf"}]}
        result = json.loads(runtime.dispatch_json("pre_request_hook", payload("request", "TL_users_getUsers", request)))
        assert result == {"strategy": "MODIFY", "request": {"_": "users.getUsers", "id": [{"_": "inputUserSelf"}, {"_": "inputUserSelf"}]}}
        assert plugin.events[-1] == ("pre", "TL_users_getUsers", 4, 1)
        plugin.mode = "final"
        assert json.loads(runtime.dispatch_json("pre_request_hook", payload("request", "users.getUsers", request, True)))["strategy"] == "MODIFY_FINAL"
        plugin.mode = "cancel"
        assert json.loads(runtime.dispatch_json("pre_request_hook", payload("request", "TL_users_getUsers", request)))["strategy"] == "CANCEL"
        runtime.dispatch_json("post_request_hook", payload("response", "TL_users_getUsers", [{"_": "userEmpty", "id": 7}]))
        runtime.dispatch_json("post_request_hook", payload("response", "TL_users_getUsers", None, error={"_": "error", "code": 400, "text": "actual error"}))
        assert plugin.events[-1] == ("post", "TL_users_getUsers", 4, 400)
        update = {"_": "updateUserName", "user_id": 7, "first_name": "before", "last_name": "unchanged", "usernames": []}
        result = json.loads(runtime.dispatch_json("on_update_hook", payload("update", "TL_updateUserName", update)))
        assert result["strategy"] == "MODIFY_FINAL" and result["update"]["first_name"] == "edited 雪\0π"
        assert set(result["update"]) == set(update)
        updates = {"_": "updates", "updates": [update], "users": [], "chats": [], "date": 123, "seq": 7}
        result = json.loads(runtime.dispatch_json("on_updates_hook", payload("updates", "TL_updates", updates)))
        assert result == {"strategy": "CANCEL", "updates": updates}
    elif case == "queues":
        with loader.plugin_context(host.plugin_id), client_utils.hook_scope(5):
            queue = client_utils.run_on_queue(lambda: plugin.note("queued"), delay_ms=9)
            assert queue.name == client_utils.PLUGINS_QUEUE
        for ident, handle in list(host.tasks.items()):
            runtime.invoke_handle_json(handle, "run", "[]")
            host.release([handle]); host.tasks.pop(ident)
        assert plugin.events[-1] == ("queued", 5)
        with loader.plugin_context(host.plugin_id): plugin.background()
        assert host.tasks
        for ident, handle in list(host.tasks.items()):
            runtime.invoke_handle_json(handle, "run", "[]")
            host.release([handle]); host.tasks.pop(ident)
        assert plugin.events[-1] == ("background-owner", None)
        with loader.plugin_context(host.plugin_id):
            client_utils.run_on_ui_thread(lambda: {1: object()})
        handle, _ = host.queued.pop()
        assert runtime.invoke_handle_json(handle, "run", "[]") == "null" and handle not in host.handles
    elif case == "queue_publication":
        scheduler = runtime._state.scheduler
        posted, errors = [], []
        host.pause_task_return = True
        def post():
            try:
                with client_utils.hook_scope(5):
                    posted.append(scheduler.post(lambda: (plugin.note("early-task"), object()), client_utils.PLUGINS_QUEUE))
            except BaseException as error: errors.append(error)
        thread = threading.Thread(target=post)
        thread.start()
        try:
            assert host.task_admitted.wait(3), "background task was not admitted"
            ident, handle = next(iter(host.tasks.items()))
            assert runtime.invoke_handle_json(handle, "run", "[]") == "null"
            assert plugin.events[-1] == ("early-task", 5)
            assert handle in host.handles, "SDK released a native-owned handle before FIFO release"
            host.release([handle]); host.tasks.pop(ident)
            assert not scheduler.tasks and not runtime._state.callbacks.leases
        finally:
            host.resume_task_return.set()
            thread.join(3)
        assert not thread.is_alive() and not errors and posted == [ident]
        assert not scheduler.tasks and not bridge.xt_handle_count(), "late admission resurrected a closed task"
    elif case == "cancellation_winners":
        from exteraless_runtime import RuntimeStateError
        with loader.plugin_context(host.plugin_id):
            for kind in ("controller", "task"):
                for label, reply in (("false", False), ("malformed", 1), ("throw", "throw")):
                    before = len(plugin.events)
                    if kind == "controller":
                        operation = client_utils.get_messages_controller(4).getUser(7, lambda value, error: plugin.note("completion-winner"))
                        lease = operation.lease
                        handle = host.native_operations.pop(operation.id)["handle"]
                        cancel, method, arguments = operation.cancel, "__call__", '[{"fixture":true},null]'
                    else:
                        with client_utils.hook_scope(5):
                            before_tasks = set(runtime._state.scheduler.tasks)
                            assert client_utils.get_queue_by_name(client_utils.PLUGINS_QUEUE).postRunnable(lambda: plugin.note("completion-winner")) is True
                            ident, = set(runtime._state.scheduler.tasks) - before_tasks
                        lease = runtime._state.scheduler.tasks[ident][0]
                        handle = host.tasks.pop(ident)
                        cancel = lambda: runtime._state.scheduler.cancel(ident)
                        method, arguments = "run", "[]"
                    host.cancel_override = reply
                    if label == "false": assert cancel() is False
                    else: raises(RuntimeError, cancel, "transport" if label == "throw" else "Bool")
                    assert lease.open and handle in host.handles
                    if kind == "task": assert runtime._state.scheduler.tasks[ident][0] is lease
                    assert runtime.invoke_handle_json(handle, method, arguments) == "null"
                    assert len(plugin.events) == before + 1 and plugin.events[-1] == ("completion-winner", 4 if kind == "controller" else 5)
                    assert not lease.open and handle in host.handles, "SDK released before native FIFO control"
                    raises(RuntimeStateError, lambda: runtime.invoke_handle_json(handle, method, arguments), "closed plugin generation")
                    host.release([handle])
                    assert host.release_counts[handle] == 1
                    if kind == "task": assert ident not in runtime._state.scheduler.tasks
            host.cancel_override = "native"
            operation = client_utils.get_messages_controller(4).getUser(7, lambda *_: plugin.note("cancelled-controller"))
            assert operation.cancel() is True and operation.cancel() is False
            callback = lambda: plugin.note("cancelled-task")
            queue = client_utils.get_queue_by_name(client_utils.PLUGINS_QUEUE)
            queue.postRunnable(callback); queue.postRunnable(callback)
            assert queue.cancelRunnable(callback) is True and queue.cancelRunnable(callback) is False
            # An old completion/close cannot erase an entry replaced at the same
            # dictionary slot while cancellation was outside the SDK lock.
            before_tasks = set(runtime._state.scheduler.tasks)
            assert queue.postRunnable(callback) is True
            ident, = set(runtime._state.scheduler.tasks) - before_tasks
            old = runtime._state.scheduler.tasks[ident][0]
            before_tasks = set(runtime._state.scheduler.tasks)
            assert queue.postRunnable(callback) is True
            replacement, = set(runtime._state.scheduler.tasks) - before_tasks
            entry = runtime._state.scheduler.tasks[replacement]
            runtime._state.scheduler.tasks[ident] = entry
            old.close()
            assert runtime._state.scheduler.tasks[ident] is entry
            runtime._state.scheduler.tasks.pop(ident)
            host.release([host.tasks.pop(ident)])
            assert queue.cancelRunnable(replacement) is True
            assert not runtime._state.scheduler.tasks and not runtime._state.callbacks.leases
    elif case == "registrations":
        from file_utils import FilesController
        from intents import IntentsManager
        with loader.plugin_context(host.plugin_id):
            file_id = FilesController.register("fixture", on_click=lambda context: plugin.note(context["file_name"]))
            file_handle = host.interceptions[file_id][0]
            assert runtime.invoke_handle_json(file_handle, "__call__", '[{"file_name":"file.fixture"}]') == "null"
            assert plugin.events[-1] == ("file.fixture", None)
            FilesController.unregister("fixture", file_id)
            intent = IntentsManager.new_global_before_handler(lambda id, scheme: id == "42" and scheme == "tg", scheme="tg", host="chat")
            callback, model = host.interceptions[intent.handler_id]
            assert model["filters"]["schemes"] == ["tg"]
            assert runtime.invoke_handle_json(callback, "__call__", '[{"scheme":"tg","query_args":{"id":"42"}}]') == "true"
            intent.unhandle()
            def file_result(context):
                assert context["file"].getPath() == str(host.files / "unread.fixture")
                return {1: object()}  # Invalid JSON, deliberately ignored by the void source API.
            file_id = FilesController.register("fixture", on_click=file_result)
            handle = host.interceptions[file_id][0]
            assert runtime.invoke_handle_json(handle, "__call__", json.dumps([{"file": str(host.files / "unread.fixture")}])) == "null"
            host.interceptions.pop(file_id); host.release([handle])
            assert (host.plugin_id, "fixture") not in FilesController._registrations
            def broken_file(context): raise ValueError("native opener must fall through")
            file_id = FilesController.register("fixture", on_click=broken_file)
            handle = host.interceptions[file_id][0]
            raises(ValueError, lambda: runtime.invoke_handle_json(handle, "__call__", "[{}]"), "fall through")
            FilesController.unregister("fixture", file_id)
            intent = IntentsManager.new_global_before_handler(lambda: False, scheme="tg")
            handle = host.interceptions[intent.handler_id][0]
            assert runtime.invoke_handle_json(handle, "__call__", "[{}]") == "false"
            host.interceptions.pop(intent.handler_id); host.release([handle])
            assert intent.handler_id not in IntentsManager._handlers and host.plugin_id not in IntentsManager._by_plugin
        assert not host.interceptions
    elif case == "native_controllers":
        from exteraless_runtime import UnsupportedSurfaceError
        from android_utils import get_context
        assert get_context().getString("Cancel") == "Отмена"
        peer = {"type": "channel", "id": 42}
        with loader.plugin_context(host.plugin_id):
            messages = client_utils.get_messages_controller(account=4)
            assert "nativeGetUser" in messages.supported()
            raises(UnsupportedSurfaceError, lambda: messages.getUser(0), "asynchronous")
            operation = messages.getUser(0, plugin.response)
            assert host.native_operations[operation.id]["model"] == {"account": 4, "id": 0}
            host.service_event(operation.id, None)
            assert plugin.events[-1] == (["response", None, None], 4) and not operation.lease.open
            operation = messages.observePeer(peer, plugin.response)
            assert operation.state().ready is False
            host.service_event(operation.id, None)
            assert operation.state().ready is True and operation.state().value is None
            host.service_event(operation.id, {"partial": True, "cached": {"id": 42}})
            assert operation.state().value.cached.id == 42
            raises(AttributeError, lambda: operation.state().value.invented)
            assert operation.cancel() and not operation.cancel()
            calls = [
                (messages.getChat(peer, plugin.response), "nativeGetChat"),
                (messages.getChat(42, plugin.response), "nativeGetChat"),
                (messages.getPeerInfo(peer, plugin.response), "nativePeerInfo"),
                (client_utils.get_contacts_controller(4).getContacts(plugin.response, offset=3, limit=5), "nativeGetContacts"),
                (client_utils.get_media_data_controller(4).getMessageMedia(peer, 7, plugin.response), "nativeMessageMedia"),
                (client_utils.get_notifications_settings(4).getPeerSettings(peer, plugin.response), "nativeNotificationSettings"),
            ]
            files = client_utils.get_file_loader(4)
            calls.extend([(files.getResourceStatus(peer, 7, -21, plugin.response), "nativeResourceStatus"),
                (files.loadFile({"peer": peer, "messageId": 7, "fileId": -21}, plugin.response), "nativeDownload")])
            for operation, name in calls:
                assert host.native_operations[operation.id]["member"] == name
                host.service_event(operation.id, None, {"kind": "unavailable", "message": "fixture absent"})
                assert plugin.events[-1][0][2].kind == "unavailable" and plugin.events[-1][1] == 4
            operation = files.observeResource(peer, 7, -21, plugin.response)
            host.service_event(operation.id, {"status": "fetching", "progress": 0.25})
            assert operation.state().value.progress == 0.25
            host.native_operations.pop(operation.id)
            host.release(operation.lease.handles[:])
            assert not operation.lease.open
            host.exports.remove("nativeGetUser")
            raises(UnsupportedSurfaceError, lambda: messages.getUser(0, plugin.response), "does not export")
            manager = client_utils.get_connections_manager(4)
            raises(Exception, manager.getConnectionState, "not published")
            for state, expected in (("waitingForNetwork", 2), ("connecting", 1), ("updating", 5), ("online", 3)):
                host.connection_state = state
                assert manager.getConnectionState() == expected
            host.permissions.remove("files")
            raises(PermissionError, lambda: files.loadFile({"peer": peer, "messageId": 7, "fileId": -21}, plugin.response), "files")
    elif case == "notifications":
        from exteraless_runtime import UnsupportedSurfaceError
        center = client_utils.get_notification_center(account=4)
        assert [row.id for row in center.supported()] == [1, 3, 25, 46, 137, 142, 143, 148, 150, 151, 152, 306]
        host.notification_events.append({"id": 999, "name": "futureNativeEvent"})
        assert 999 not in [row.id for row in center.supported()]
        class Observer(client_utils.NotificationCenterDelegate):
            def didReceivedNotification(self, event, account, args):
                plugin.note([event, account, args])
                return object()  # Notification callbacks are void too.
        observer = Observer()
        with loader.plugin_context(host.plugin_id), client_utils.hook_scope(9):
            for event in (25, 46, 137): observer.start_observing(event, 4)
            for ident, record in list(host.native_operations.items()):
                event = record["model"]["event"]
                assert runtime.invoke_handle_json(record["handle"], "__call__", json.dumps([event, 4, []])) == "null"
                assert plugin.events[-1] == ([event, 4, []], None)
            center.addObserver(observer, "contactsDidLoad")
            assert len(host.native_operations) == 3
            observer.stop_observing(25, 4)
            assert len(host.native_operations) == 2
            for ident, record in list(host.native_operations.items()):
                host.native_operations.pop(ident); host.release([record["handle"]])
            assert not center.observers
            host.notification_events = []
            raises(UnsupportedSurfaceError, lambda: observer.start_observing(25, 4), "unavailable")
            raises(UnsupportedSurfaceError, lambda: observer.start_observing(999, 4), "999")
    elif case == "notification_payloads":
        from exteraless_runtime import RuntimeStateError, UnsupportedSurfaceError
        from java import jclass
        center = client_utils.get_notification_center(4)
        observed = []
        class Observer(client_utils.NotificationCenterDelegate):
            def didReceivedNotification(self, event, account, args):
                observed.append((event, account, args, client_utils.get_hook_account()))
                return {1: object()}
        observer = Observer()
        message = {"nativeType": "MessageObject", "partial": True, "currentAccount": 4, "dialogId": -17,
            "namespace": 0, "isForwarded": True, "source": "Postbox.Message/native-message-v1",
            "messageOwner": {"id": 7, "date": 1700000000, "message": "native message", "out": False,
                "peer_id": {"_": "peerChannel", "channel_id": 17}, "grouped_id": None, "entities": [],
                "media": {"nativeType": "file", "partial": True, "document": {"id": 99, "resourceId": "opaque-resource"}}}}
        file = str(host.files / "native-completed.fixture")
        payloads = {1: [-17, [message], False, 0], 3: [], 25: [], 46: [], 137: [],
            142: ["opaque-resource", file], 143: ["opaque-resource", 0], 148: [7, 0.25],
            150: [7], 151: [message, None], 152: [7, 0.75], 306: []}
        with loader.plugin_context(host.plugin_id), client_utils.hook_scope(9):
            for row in host.notification_events:
                assert getattr(center, row["name"]) == row["id"]
                center.addObserver(observer, row["name"])
            for ident, record in list(host.native_operations.items()):
                event, handle = record["model"]["event"], record["handle"]
                assert runtime.invoke_handle_json(handle, "__call__", json.dumps([event, 4, payloads[event]])) == "null"
                assert observed[-1][0:2] == (event, 4) and observed[-1][3] is None
                args = observed[-1][2]
                if event == 1:
                    assert isinstance(args[1], jclass("java.util.ArrayList"))
                    item = args[1].get(0)
                    assert item.getId() == 7 and item.getDialogId() == -17 and item.isOut() is False and item.isForwarded() is True
                    assert item.messageOwner.peer_id.channel_id == 17 and item.messageOwner.media.partial is True
                    raises(AttributeError, lambda: item.messageOwner.flags, "flags")
                    raises(AttributeError, lambda: item.messageOwner.media.document.access_hash, "access_hash")
                if event == 142: assert args[1].getPath() == file and isinstance(args[1], jclass("java.io.File"))
                if event == 151: assert args[0].getId() == 7 and args[1] is None
                before = len(observed)
                raises(RuntimeStateError, lambda: runtime.invoke_handle_json(handle, "__call__", json.dumps([event, True, payloads[event]])), "account")
                raises(RuntimeStateError, lambda: runtime.invoke_handle_json(handle, "__call__", json.dumps([event, 4, ["wrong shape"]])), "shape")
                assert len(observed) == before
                center.removeObserver(observer, event)
                assert host.release_counts[handle] == 1
            rows = list(host.notification_events)
            host.notification_events = [dict(row, name="wrong") if row["id"] == 25 else row for row in rows]
            raises(RuntimeStateError, center.supported, "known native event name")
            host.notification_events = [row for row in rows if row["id"] != 25] + [{"id": 777, "name": "futureValidEvent"}]
            raises(UnsupportedSurfaceError, lambda: center.addObserver(observer, 25), "unavailable")
            raises(UnsupportedSurfaceError, lambda: center.addObserver(observer, 777), "777")
            host.notification_events = rows
            host.permissions.remove("files")
            raises(PermissionError, lambda: center.addObserver(observer, 142), "files")
            center.addObserver(observer, 25); center.removeObserver(observer, 25)
            assert not center.observers and not host.native_operations
    elif case == "reflection":
        from java import jclass
        native = jclass("exteraless.ios.Runtime")
        assert not hasattr(native, "InventedNestedClass")
        assert hasattr(native, "sdkEcho") and native.sdkEcho("live 雪\0π") == "live 雪\0π"
        stale = native.sdkEcho
        host.exports.remove("sdkEcho")
        assert not hasattr(native, "sdkEcho")
        raises(Exception, lambda: stale("late"), "removed")
        host.exports.add("sdkEcho")
        assert native.sdkEcho(42) == 42
    elif case == "owner_binding":
        raises(RuntimeError, lambda: runtime._state.present("alert", {"title": "unbound"}), "bind_owner_json")
        assert not runtime._state.callbacks.leases and not bridge.xt_handle_count()
        runtime.unload()
        runtime.bind_owner_json(json.dumps(host.owner))
        raises(RuntimeError, lambda: runtime.bind_owner_json('"other-owner"'), "immutable")
        runtime.load_json(path)
    elif case == "protected_settings":
        group = Path(directory) / "app-group"
        settings_dir = group / "exteraless"
        settings_dir.mkdir(parents=True)
        global_settings = settings_dir / "client-settings.json"
        global_settings.write_text("{}", encoding="utf-8")
        host.protected_paths = [str(settings_dir)]  # Arrives after an initially empty context.
        host.permissions = {"ui", "files"}
        handle = bridge.xt_register_handle(plugin)
        def mutation(target):
            return runtime.invoke_handle_json(handle, "audit_event", json.dumps([
                "open", [str(target), "w", os.O_WRONLY | os.O_TRUNC]]))
        raises(PermissionError, lambda: mutation(global_settings), "protected")
        assert mutation(group / "unrelated.txt") == "null"  # No blanket app-group seal.
        host.permissions.add("settings")
        raises(PermissionError, lambda: mutation(global_settings), "hooks")
        with loader.plugin_context(host.plugin_id):
            plugin.set_client_setting("chats.fixture", True)
            assert plugin.get_client_setting("chats.fixture", False) is True
            raises(PermissionError, lambda: plugin.set_client_setting("secret", "not-public"), "secret")
        host.permissions.add("hooks")
        assert mutation(global_settings) == "null"
        assert global_settings.read_text() == "{}"  # Audit events performed no actual write.
    elif case == "failures":
        host.fail_present = True
        before = bridge.xt_handle_count()
        raises(Exception, lambda: runtime._state.present("alert", {"title": "fail"}), "unavailable")
        assert bridge.xt_handle_count() == before and not runtime._state.callbacks.leases
        host.fail_present = False
        def broken(event): raise ValueError("lease callback failed")
        presentation = runtime._state.present("alert", {"title": "error"}, {"dismiss": broken})
        raises(ValueError, lambda: host.close_ui(presentation.id), "lease callback failed")
        assert not runtime._state.callbacks.leases and not bridge.xt_handle_count()
        presentation = runtime._state.present("alert", {"title": "silent replacement"})
        retired = host.presentations.pop(presentation.id)
        host.release(retired["callbacks"].values())  # Account replacement: no reverse closed callback.
        assert not presentation.lease.open and not runtime._state.callbacks.leases
        previous_budget = runtime._state.callbacks.max_handles
        runtime._state.callbacks.max_handles = 1
        raises(RuntimeError, lambda: runtime._state.present("alert", {"title": "budget"}, {"dismiss": lambda event: None}), "budget")
        assert not bridge.xt_handle_count() and not runtime._state.callbacks.leases
        runtime._state.callbacks.max_handles = previous_budget
        presentation = runtime._state.present("alert", {"title": "generation"})
        old = next(iter(host.presentations[presentation.id]["callbacks"].values()))
        wrapper = bridge.xt_resolve_handle(old)
        runtime.unload()
        runtime.load_json(path)
        raises(RuntimeError, lambda: wrapper({}), "closed plugin generation")
        assert not host.presentations

    runtime.unload()
    gc.collect()
    assert not bridge.xt_handle_count() and not runtime._state.callbacks.leases
    assert not host.presentations and not host.requests and not host.menus and not host.tasks
    assert not host.interceptions
    assert not host.native_operations and not runtime._state.scheduler.tasks
    assert not host.pill_regs
    assert finder._State.backend is backend
    print("SDK_WAVE2_OK " + json.dumps({"case": case, "registry_classes": len(__import__("virtualjava").registered_classes()),
                                       "native_logs": len(host.logs), "handles": bridge.xt_handle_count()}))


if __name__ == "__main__":
    worker(sys.argv[1], sys.argv[2])
else:
    import pytest

    @pytest.mark.parametrize("case", CASES)
    def test_sdk_wave2(case, tmp_path):
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(tmp_path)],
                                cwd=tmp_path, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        print(next(line for line in result.stdout.splitlines() if line.startswith("SDK_WAVE2_OK ")))
