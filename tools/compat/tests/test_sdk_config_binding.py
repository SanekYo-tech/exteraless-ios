"""Bounded real SDK Config calls against a strict native-service recorder.

Two plugin workers share the same simulated native global file; each retains its
own original SDK per-plugin storage. Production persistence is covered by Core's
ExteraConfigCompatibilityTests, not by claiming this recorder executes Swift.
"""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[3]
DEFAULTS = {
    "translationFormality": 0, "useYandexMaps": False, "tabIcons": 1, "tabCounter": True,
    "newSliderStyle": True, "newSwitchStyle": True, "springAnimations": True,
    "forceBlur": False, "eventType": 0, "unlimitedRecentStickers": False,
    "quickTransitionForChannels": True, "quickTransitionForTopics": True,
    "showClearButton": True, "showGenerateButton": True, "recognitionLanguage": "none",
    "postprocessingWithAi": False, "useGoogleAnalytics": False, "enableAdBlock": True,
    "updateScheduleTimestamp": 0, "sdkUpdateScheduleTimestamp": 0,
    "pluginsPySdkAutoUpdate": True, "pluginsPySdkBetaVersions": False,
}


def worker(case, root):
    sys.path.insert(0, str(ROOT))
    sys.path.insert(0, str(ROOT / "python"))
    from tools.compat.sdk_config_manifest import root_registration
    # The fixture cannot make the old absent-root implementation pass merely by
    # adding its own defaults. Validate the shipping registered group first.
    registered = root_registration({})
    assert "ExteraConfigCompatibility.definitions" in registered["groups"]
    spec = importlib.util.spec_from_file_location("_ios_runtime_fixture_support", Path(__file__).with_name("test_ios_runtime.py"))
    support = importlib.util.module_from_spec(spec); spec.loader.exec_module(support)
    plugin_id = "configReader" if case in ("read", "native_reader") else "configWriter"
    directory = Path(root) / case
    directory.mkdir()
    global_file = Path(root) / "native-global.json"

    class Host(support.StrictNativeHost):
        def __init__(self, root):
            super().__init__(root)
            self.definitions = {"compat.exteraconfig." + key: value for key, value in DEFAULTS.items()}
            self.definitions.update({"appearance.disableVibration": False, "appearance.actionBarDecoration": 0,
                "appearance.chatDecoration": 0, "identity.idDcType": 1, "identity.showOnlineStatus": False})
            self.definitions.update({"appearance.useSystemFonts": True, "appearance.tabletMode": 0,
                "appearance.forceFontWeightFallback": False, "appearance.monetStyle": 0, "tools.performanceClass": 0})
            self.metadata_overrides = {}
            self.definitions.update({"tools.uploadBoost": False, "appearance.hideAllTab": False,
                "appearance.hideAiEditor": False, "appearance.hideMessageSummary": False, "appearance.useSystemIconShape": False,
                "tools.videoMessageCameraFacing": 0, "tools.enhancedVideoBitrate": False, "tools.voiceEnhancement": False,
                "tools.groupAudioBitrate": 0, "tools.showRPCError": False,
                "appearance.hideHelpSection": True, "appearance.hidePremiumSection": False, "appearance.showStickersRowToplevel": True})
            self.manager = {"safeMode": False, "engineEnabled": True, "developerMode": False, "compactView": False, "pinned": []}
            self.pending = []
            self.batch_calls = 0
            self.single_calls = 0

        def call(self, request):
            request = dict(request)
            if "ownerToken" in request: assert request.pop("ownerToken") == self.owner_token
            member, args = request["member"], request["args"]
            if member in ("getPluginConfig", "setPluginConfig", "getClientSetting", "setClientSetting", "setClientSettings", "getClientSettingMetadata"):
                if "settings" not in self.permissions: raise PermissionError("settings permission required")
                assert self.owner_token is not None
                if member == "getPluginConfig": return self.manager[args[0]]
                if member == "setPluginConfig":
                    self.pending.append((args[0], args[1], self.owner_token))
                    return {"accepted": True, "operationId": "native-command-" + str(len(self.pending))}
                if member == "getClientSettingMetadata":
                    if args[0] in ("ai.privateCredential", "legacyCredential"): raise PermissionError("private credential")
                    if args[0] not in self.definitions: return None
                    default = self.definitions[args[0]]
                    metadata = {"key": args[0], "scope": "global", "type": {bool: "bool", int: "int", str: "text"}[type(default)], "default": default}
                    metadata.update(self.metadata_overrides.get(args[0], {}))
                    return json.dumps(metadata)
                values = json.loads(global_file.read_text(encoding="utf-8")) if global_file.is_file() else {}
                if member == "getClientSetting": return values.get(args[0], self.definitions[args[0]]) if args[0] in self.definitions else None
                if member == "setClientSettings":
                    assert len(args) == 1 and isinstance(args[0], str), "atomic batch must be opaque JSON text"
                    patch = json.loads(args[0])
                    self.batch_calls += 1
                else:
                    patch = {args[0]: args[1]}
                    self.single_calls += 1
                for key, value in patch.items():
                    if key in ("ai.privateCredential", "legacyCredential"): raise PermissionError("private credential alias")
                    if key not in self.definitions: raise LookupError("unregistered key")
                    if type(value) is not type(self.definitions[key]): raise TypeError("native setting type mismatch")
                    if key in ("compat.exteraconfig.translationFormality", "compat.exteraconfig.tabIcons", "identity.idDcType", "tools.videoMessageCameraFacing", "appearance.tabletMode") and value not in (0, 1, 2):
                        raise ValueError("native enum option")
                    if key in ("appearance.actionBarDecoration", "appearance.chatDecoration") and value not in (0, 1):
                        raise ValueError("native snow option")
                    if key == "appearance.monetStyle" and value not in (0, 1):
                        raise ValueError("native enum option")
                    if key == "tools.performanceClass" and value not in (0, 1, 2, 3):
                        raise ValueError("native enum option")
                values.update(patch)
                global_file.write_text(json.dumps(values, ensure_ascii=False), encoding="utf-8")
                return None
            return super().call(request)

    support.StrictNativeHost = Host
    runtime, host, bridge = support.bootstrap(directory, plugin_id)
    host.permissions = {"ui", "settings"}
    runtime.bind_owner_json(json.dumps("unit-config-owner-" + plugin_id))
    path = host.plugins / (plugin_id + ".plugin")
    path.write_text("__id__ = " + repr(plugin_id) + "\n__name__ = 'Own config fixture'\nfrom base_plugin import BasePlugin\nclass ConfigPlugin(BasePlugin):\n    pass\n", encoding="utf-8")
    runtime.load_json(str(path))
    from java import jclass
    from extera_utils import plugin_loader as loader
    from exteraless_runtime import RuntimeStateError, UnsupportedSurfaceError
    extera = jclass("com.exteragram.messenger.ExteraConfig")
    plugin = loader.plugins[plugin_id].instance
    raises = support.raises
    with loader.plugin_context(plugin_id):
        if case in ("native_writer", "native_reader"):
            helper_spec = importlib.util.spec_from_file_location("_native_config_fixture_helper", ROOT / "python/runtime/smoke/native_tl_probe.py")
            helper = importlib.util.module_from_spec(helper_spec); helper_spec.loader.exec_module(helper)
            handle = json.loads(helper.loaded())["handle"]
            result = runtime.invoke_handle_json(handle, "config", "[true]" if case == "native_writer" else "[false]")
            assert result == ("44" if case == "native_writer" else "22")
        elif case == "write":
            for field, expected in DEFAULTS.items():
                suffix = field[0].upper() + field[1:]
                getter, setter = getattr(extera, "get" + suffix), getattr(extera, "set" + suffix)
                value = getter()
                if field in ("translationFormality", "tabIcons"):
                    assert value.ordinal() == expected
                    enum = jclass("com.exteragram.messenger." + ("TranslationFormality" if field == "translationFormality" else "TabIconsMode"))
                    setter(enum.values()[2]); assert getter().ordinal() == 2
                    setter(enum.values()[expected])
                else:
                    assert type(value) is type(expected) and value == expected
                    changed = not expected if type(expected) is bool else "literal 雪\0π" if isinstance(expected, str) else 123456789
                    setter(changed); assert getter() == changed
                    setter(expected)
            assert extera.getTabCounter() is True and extera.getTabIcons().name() == "TITLES_ONLY"
            extera.setTabCounter(False)
            extera.setTranslationFormality(jclass("com.exteragram.messenger.TranslationFormality").FORMAL)
            extera.setRecognitionLanguage("雪\0π")
            extera.setUpdateScheduleTimestamp(9_007_199_254_740_993)
            plugin.set_setting("tabCounter", "writer-private")
            assert extera.getTabCounter() is False and plugin.get_setting("tabCounter") == "writer-private"
        elif case == "read":
            assert extera.getTabCounter() is False and plugin.get_setting("tabCounter") is None
            assert extera.getTranslationFormality().name() == "FORMAL"
            assert extera.getRecognitionLanguage() == "雪\0π"
            assert extera.getUpdateScheduleTimestamp() == 9_007_199_254_740_993
            plugin.set_setting("tabCounter", "reader-private")
            assert extera.getTabCounter() is False
        elif case == "metadata_batch":
            item = jclass("tw.nekomimi.nekogram.NekoConfig").disableVibration
            assert item.defaultValue is False
            host.definitions["appearance.disableVibration"] = True
            assert item.defaultValue is True, "Python cached the Android/native default"
            del host.definitions["appearance.disableVibration"]
            raises(UnsupportedSurfaceError, lambda: item.defaultValue, "not registered")
            extera.setForceSnow(True)
            assert host.batch_calls == 1 and host.single_calls == 0
            state = json.loads(global_file.read_text(encoding="utf-8"))
            assert state["appearance.actionBarDecoration"] == state["appearance.chatDecoration"] == 1
            before = global_file.read_bytes()
            raises(ValueError, lambda: runtime._state.call("setClientSettings", '{"appearance.actionBarDecoration":0,"appearance.chatDecoration":2}'), "snow")
            raises(PermissionError, lambda: runtime._state.call("setClientSettings", '{"appearance.actionBarDecoration":0,"legacyCredential":"bad"}'), "credential")
            assert global_file.read_bytes() == before
            raises(TypeError, lambda: extera.setTabCounter(1), "boolean")
            raises(TypeError, lambda: extera.setEventType(True), "expected one")
            host.permissions.remove("settings")
            raises(PermissionError, extera.getTabCounter, "settings")
            raises(PermissionError, lambda: extera.setForceSnow(False), "settings")
        elif case == "manager":
            assert extera.getPluginsEngine() is True and extera.getPluginsSafeMode() is False
            assert extera.setPluginsSafeMode(True) is None
            assert extera.getPluginsSafeMode() is False, "SDK pretended admission was completed delivery"
            extera.setPluginsCompactView(True)
            extera.setPluginsDevMode(True)
            extera.setPluginsEngine(False)
            extera.setPinnedPlugins(jclass("java.util.HashSet")(["configWriter"]))
            assert [field for field, _, _ in host.pending] == ["safeMode", "compactView", "developerMode", "engineEnabled", "pinned"]
            for field, value, owner in host.pending:
                assert owner == host.owner_token
                host.manager[field] = value
            assert extera.getPluginsSafeMode() is True and extera.pluginsSafeMode is True
            assert extera.getPluginsDevMode() is True and extera.getPluginsCompactView() is True
            assert extera.getPluginsEngine() is False
            assert extera.getPinnedPlugins().contains("configWriter")
            raises(UnsupportedSurfaceError, extera.getPluginsDisableArtOpts, "ART")
            host.permissions.remove("settings")
            raises(PermissionError, lambda: extera.setPluginsEngine(False), "settings")
        elif case == "domain_cohort":
            for suffix, key, inverse in (
                ("UploadSpeedBoost", "tools.uploadBoost", False),
                ("HideAllChats", "appearance.hideAllTab", False),
                ("TelegramAiEditor", "appearance.hideAiEditor", True),
                ("TelegramAiSummaries", "appearance.hideMessageSummary", True),
                ("UseSystemIconShape", "appearance.useSystemIconShape", False),
            ):
                getter, setter = getattr(extera, "get" + suffix), getattr(extera, "set" + suffix)
                assert getter() is inverse
                setter(not inverse)
                assert json.loads(global_file.read_text(encoding="utf-8"))[key] is True
                assert getter() is (not inverse)
                setter(inverse)
                assert getter() is inverse
                raises(TypeError, lambda: setter(1), "expected one")
            neko = jclass("tw.nekomimi.nekogram.NekoConfig")
            na = jclass("xyz.nextalone.nagram.NaConfig")
            rear = neko.rearVideoMessages
            camera = jclass("com.exteragram.messenger.VideoMessagesCamera")
            assert rear.defaultValue is False and extera.getVideoMessagesCamera() is camera.FRONT
            extera.setVideoMessagesCamera(camera.REAR)
            assert rear.Bool() is True and extera.getVideoMessagesCamera() is camera.REAR
            assert json.loads(global_file.read_text(encoding="utf-8"))["tools.videoMessageCameraFacing"] == 1
            rear.setConfigBool(False)
            assert na.getCameraInVideoMessages().Int() == 0
            na.getCameraInVideoMessages().setConfigInt(2)
            assert rear.defaultValue is False, "default metadata was replaced with the current Ask value"
            raises(UnsupportedSurfaceError, rear.Bool, "Ask")
            raises(UnsupportedSurfaceError, extera.getVideoMessagesCamera, "Ask")
            assert na.getCameraInVideoMessages().Int() == 2, "an unrepresentable getter changed native mode"
            raises(TypeError, lambda: rear.setConfigBool(1), "boolean")
            extera.setVideoMessagesCamera(camera.FRONT)
            assert rear.Bool() is False and na.getCameraInVideoMessages().Int() == 0
            del host.definitions["tools.videoMessageCameraFacing"]
            raises(UnsupportedSurfaceError, rear.Bool, "not registered")
            raises(UnsupportedSurfaceError, lambda: rear.defaultValue, "not registered")
            for getter, key, default, changed in (
                (na.getEnhancedVideoBitrate, "tools.enhancedVideoBitrate", False, True),
                (na.getNoiseSuppressAndVoiceEnhance, "tools.voiceEnhancement", False, True),
                (lambda: neko.customAudioBitrate, "tools.groupAudioBitrate", 0, 128),
                (na.getShowRPCError, "tools.showRPCError", False, True),
                (na.getHideHelpSection, "appearance.hideHelpSection", True, False),
                (na.getHidePremiumSection, "appearance.hidePremiumSection", False, True),
                (na.getShowStickersRowToplevel, "appearance.showStickersRowToplevel", True, False),
            ):
                item = getter()
                assert item.defaultValue == default
                (item.setConfigBool if type(changed) is bool else item.setConfigInt)(changed)
                assert json.loads(global_file.read_text(encoding="utf-8"))[key] == changed
            crash = jclass("app.exteraless.general.GeneralConfig").crashReports
            host.definitions["tools.crashReports"] = False
            crash.setConfigBool(True)
            migrated = na.getDisableCrashlyticsCollection()
            for value in (False, True):
                raises(UnsupportedSurfaceError, lambda: migrated.setConfigBool(value), "migration-only")
                assert crash.Bool() is True, "a legacy migration flag changed the live collection control"
            raises(UnsupportedSurfaceError, migrated.Bool, "migration-only")
        elif case == "general_scalars":
            general = jclass("app.exteraless.general.GeneralConfig")
            for field, key in (("contentCapture", "privacy.contentCapture"), ("crashReports", "tools.crashReports")):
                host.definitions[key] = False
                item = getattr(general, field)
                assert item() is False
                item.setConfigBool(True)
                assert item() is True and item.Bool() is True
                assert json.loads(global_file.read_text(encoding="utf-8"))[key] is True
                host.permissions.remove("settings")
                raises(PermissionError, item, "settings")
                host.permissions.add("settings")
                del host.definitions[key]
                raises(UnsupportedSurfaceError, item, "not registered")
            raises(UnsupportedSurfaceError, general.loadConfig, "loadConfig")
        elif case == "font_layout":
            neko = jclass("tw.nekomimi.nekogram.NekoConfig")
            font, layout = neko.typeface, neko.tabletMode
            # These remain the actual source ConfigItems, backed by the two
            # registered native keys rather than synthetic Typeface/device data.
            assert font is jclass("tw.nekomimi.nekogram.NekoConfig").typeface
            assert layout is jclass("tw.nekomimi.nekogram.NekoConfig").tabletMode
            assert font.getKey() == "TypefaceUseDefault" and font.type == font.configTypeBool
            assert layout.getKey() == "TabletMode" and layout.type == layout.configTypeInt
            assert extera.getUseSystemFonts() is True and font.defaultValue is True
            extera.setUseSystemFonts(False)
            assert font.Bool() is False and extera.getUseSystemFonts() is False
            assert json.loads(global_file.read_text(encoding="utf-8"))["appearance.useSystemFonts"] is False
            assert neko.forceFontWeightFallback.Bool() is False
            font.setConfigBool(True)
            assert extera.getUseSystemFonts() is True
            assert layout.defaultValue == 0
            for value in (1, 2, 0):
                extera.setTabletMode(value)
                assert extera.getTabletMode() == layout.Int() == value
                assert json.loads(global_file.read_text(encoding="utf-8"))["appearance.tabletMode"] == value
            before = global_file.read_bytes()
            for value in (-1, 3):
                raises(ValueError, lambda: extera.setTabletMode(value), "native enum option")
            for value in (True, 1.5, "1"):
                raises(TypeError, lambda: extera.setTabletMode(value), "expected one")
            raises(TypeError, lambda: extera.setUseSystemFonts(1), "expected one")
            raises(TypeError, lambda: font.setConfigBool(1), "boolean")
            raises(TypeError, lambda: layout.setConfigInt(True), "integer")
            assert global_file.read_bytes() == before
            host.permissions.remove("settings")
            for action in (extera.getUseSystemFonts, extera.getTabletMode,
                lambda: extera.setUseSystemFonts(False), lambda: extera.setTabletMode(2),
                lambda: font.defaultValue, lambda: layout.defaultValue):
                raises(PermissionError, action, "settings")
            assert global_file.read_bytes() == before
            host.permissions.add("settings")
            del host.definitions["appearance.tabletMode"]
            del host.definitions["appearance.useSystemFonts"]
            for getter in (extera.getTabletMode, extera.getUseSystemFonts, lambda: font.defaultValue, lambda: layout.defaultValue):
                raises(UnsupportedSurfaceError, getter, "not registered")
        elif case == "portable_scalars":
            appearance = jclass("app.exteraless.appearance.AppearanceConfig")
            na = jclass("xyz.nextalone.nagram.NaConfig")
            monet, performance = appearance.monetStyle, na.getPerformanceClass()
            assert appearance.INSTANCE.monetStyle is monet
            assert na.INSTANCE.getPerformanceClass() is na.performanceClass is performance
            items = ((monet, "appearance.monetStyle", "OEAppearanceMonetStyle", (1, 0)),
                     (performance, "tools.performanceClass", "PerformanceClass", (1, 2, 3, 0)))
            for item, key, source_key, values in items:
                assert item.getKey() == source_key and item.type == item.configTypeInt
                assert item.Int() == item.defaultValue == 0 and type(item.defaultValue) is int
                for value in values:
                    item.setConfigInt(value)
                    assert type(item.Int()) is int and item.Int() == value
                    assert json.loads(global_file.read_text(encoding="utf-8"))[key] == value
                    assert item.defaultValue == 0, "stored selection replaced native default metadata"
                host.definitions[key] = max(values)
                assert item.defaultValue == max(values) and item.Int() == 0, "SDK cached an Android default"
                host.definitions[key] = 0
                before, calls = global_file.read_bytes(), host.single_calls
                for value in (-1, max(values) + 1):
                    raises(ValueError, lambda: item.setConfigInt(value), "native enum option")
                assert host.single_calls == calls + 2, "range rejection must come from the native authority"
                for value in (True, 1.5, "1"):
                    raises(TypeError, lambda: item.setConfigInt(value), "integer")
                for value in (-2 ** 31 - 1, 2 ** 31):
                    raises(OverflowError, lambda: item.setConfigInt(value), "out of range")
                raises(TypeError, item.Bool, "not bool")
                raises(TypeError, lambda: item.setConfigBool(True), "not bool")
                for invalid in ({"key": "unrelated.setting"}, {"type": "bool"}, {"scope": "plugin"}):
                    host.metadata_overrides[key] = invalid
                    raises(RuntimeStateError, lambda: item.defaultValue, "disagrees")
                del host.metadata_overrides[key]
                assert global_file.read_bytes() == before
            raises(UnsupportedSurfaceError, appearance.monetAssetSuffix, "monetAssetSuffix")
            before = global_file.read_bytes()
            host.permissions.remove("settings")
            for item, _, _, _ in items:
                for action in (item.Int, lambda: item.value, lambda: item.defaultValue, lambda: item.setConfigInt(1)):
                    raises(PermissionError, action, "settings")
            assert global_file.read_bytes() == before
            host.permissions.add("settings")
            for item, key, _, _ in items:
                del host.definitions[key]
                for getter in (item.Int, lambda: item.defaultValue):
                    raises(UnsupportedSurfaceError, getter, "not registered")
    runtime.unload()
    assert bridge.xt_handle_count() == 0


if __name__ == "__main__":
    worker(sys.argv[1], sys.argv[2])
else:
    import pytest
    def run(case, root):
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(Path(__file__).resolve()), case, str(root)],
                                cwd=root, capture_output=True, text=True, encoding="utf-8", timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr

    def test_two_plugins_share_global_compatibility_namespace(tmp_path):
        run("write", tmp_path)
        run("read", tmp_path)

    def test_exact_native_root_probe_python_calls(tmp_path):
        run("native_writer", tmp_path)
        run("native_reader", tmp_path)

    @pytest.mark.parametrize("case", ("metadata_batch", "manager", "domain_cohort", "general_scalars", "font_layout", "portable_scalars"))
    def test_config_native_bindings(case, tmp_path):
        run(case, tmp_path)
