"""Small source fixtures: no Java/Kotlin/Python plugin code is executed."""

import json

import pytest

from tools.compat import feature_inventory as inventory


def source(root, relative, text):
    path = root / "TMessagesProj/src/main" / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def test_kotlin_keys_defaults_nested_comments_and_linked_storage():
    parsed = inventory.parse_config('''
        object AppearanceConfig {
            const val MAX_RADIUS = 28
            /* val fake = addConfig("fake", ConfigItem.configTypeBool, true)
               /* nested */ still a comment */
            val sample = "val fake = addConfig(never)"
            @JvmField
            val avatarCorners: ConfigItem = addConfig(
                "OEAppearanceAvatarCorners", ConfigItem.configTypeInt, MAX_RADIUS,
            )
            val visible = addConfig("visible", ConfigItem.configTypeBool, false)
            val rate = addConfig("rate", ConfigItem.configTypeFloat, 1.25f)
            val epoch = addConfig("epoch", ConfigItem.configTypeLong, 0L)
            val order = addConfig("order", ConfigItem.configTypeString, "a,b")
            val unknown = addConfig("unknown", ConfigItem.configTypeInt, calculate())
            val mask = addConfig("mask", ConfigItem.configTypeInt, 0)
            val linked = addConfig("linked", mask, 3, false)
            val outline = addConfig(object : ConfigItem("outline", ConfigItem.configTypeInt, 2) {
                override fun setConfigInt(v: Int) { super.setConfigInt(v) }
            })
            fun computeValue(): Int = calculate()
        }
    ''', "kotlin/app/exteraless/appearance/AppearanceConfig.kt")
    items = {i["field"]: i for i in parsed["items"]}
    assert set(items) == {"avatarCorners", "visible", "rate", "epoch", "order", "unknown", "mask", "linked", "outline"}
    assert items["avatarCorners"]["key"] == "OEAppearanceAvatarCorners"
    assert items["avatarCorners"]["default"] == {"kind": "literal", "value": 28, "symbol": "MAX_RADIUS"}
    assert items["visible"]["default"]["value"] is False
    assert items["rate"]["type"] == "float"
    assert items["rate"]["default"]["value"] == 1.25
    assert items["epoch"]["type"] == "long"
    assert items["order"]["default"]["value"] == "a,b"
    assert items["unknown"]["default"] == {"kind": "expression", "expression": "calculate()"}
    assert items["linked"]["storage_link"]["id"] == "appearance.mask"
    assert items["linked"]["storage_link"]["bit"]["value"] == 3
    assert items["outline"]["default"]["value"] == 2


def test_sensitive_defaults_are_not_copied():
    parsed = inventory.parse_config('''object NaConfig {
        val llmApiKey = addConfig("LlmApiKey", ConfigItem.configTypeString, "fixture-credential")
        val emptyToken = addConfig("EmptyToken", ConfigItem.configTypeString, "")
    }''', "kotlin/xyz/nextalone/nagram/NaConfig.kt")
    serialized = json.dumps(parsed["items"])
    assert "fixture-credential" not in serialized
    assert parsed["items"][0]["default"]["kind"] == "redacted"
    assert parsed["items"][1]["default"]["value"] == ""


def test_java_and_kotlin_modules_merge_in_both_source_roots(tmp_path):
    source(tmp_path, "java/app/exteraless/appearance/Renderer.java", "class Renderer {}")
    source(tmp_path, "java/app/exteraless/appearance/Helper.kt", "object Helper {}")
    source(tmp_path, "kotlin/app/exteraless/appearance/AppearanceConfig.kt", "object AppearanceConfig {}")
    source(tmp_path, "kotlin/app/exteraless/links/Url.kt", "object Url {}")
    source(tmp_path, "kotlin/tw/nekomimi/example/Legacy.kt", "object Legacy {}")
    modules = inventory.scan_modules(tmp_path)
    assert modules["appearance"]["files"] == 3
    assert modules["appearance"]["languages"] == {"java": 1, "kt": 2}
    assert modules["links"]["files"] == 1
    assert inventory.scan_legacy_trees(tmp_path)["tw.nekomimi"]["files"] == 1


def test_shim_getters_are_not_features_and_real_alias_getters_are_followed(tmp_path):
    source(tmp_path, "kotlin/app/exteraless/appearance/AppearanceConfig.kt", '''
        object AppearanceConfig {
            val avatarCorners = addConfig("avatarCorners", ConfigItem.configTypeInt, 28)
            private val centerTitle = addConfig("oldCenterTitle", ConfigItem.configTypeBool, false)
            val uiOnly = addConfig("uiOnly", ConfigItem.configTypeBool, true)
            fun avatarCorners(): Int = avatarCorners.Int()
            fun radius(): Int = avatarCorners()
            fun centerTitle(): Boolean = NaConfig.centerActionBarTitle.Bool()
        }
    ''')
    source(tmp_path, "kotlin/xyz/nextalone/nagram/NaConfig.kt", '''
        object NaConfig {
            val centerActionBarTitle = addConfig("CenterActionBarTitle", ConfigItem.configTypeBool, false)
        }
    ''')
    source(tmp_path, "java/com/exteragram/messenger/ExteraConfig.java", '''
        public class ExteraConfig {
            public static int getAvatarCorners() { return AppearanceConfig.avatarCorners(); }
            public static boolean getUnusedFlag() { return getPreferences().getBoolean("unused", true); }
        }
    ''')
    source(tmp_path, "java/org/telegram/ui/Renderer.java", '''
        class Renderer {
            int radius = AppearanceConfig.radius();
            boolean centered = AppearanceConfig.centerTitle();
            // AppearanceConfig.uiOnly.Bool() is not executed
            String example = "AppearanceConfig.uiOnly.Bool()";
        }
    ''')
    source(tmp_path, "java/app/exteraless/settings/SettingsActivity.java", '''
        class SettingsActivity {
            void bind() { cell.setTextAndCheck(getString(R.string.Title), AppearanceConfig.uiOnly.Bool(), true); }
        }
    ''')
    result = inventory.build_client_inventory(tmp_path, tmp_path)
    features = {f["id"]: f for f in result["features"]}
    assert result["configs"]["ExteraConfig"]["count"] == 0
    assert result["configs"]["ExteraConfig"]["scalar_getter_methods"] == 2
    assert len(features) == 4
    assert features["appearance.avatarCorners"]["android"]["behavior"] == "effect-callsite"
    assert features["nagram.centerActionBarTitle"]["android"]["behavior"] == "effect-callsite"
    assert features["appearance.centerTitle"]["android"]["behavior"] != "effect-callsite"
    assert features["appearance.uiOnly"]["android"]["behavior"] == "ui-only"
    assert features["appearance.uiOnly"]["android"]["ui_resources"] == ["Title"]
    shim = {s["symbol"]: s for s in result["compatibility_apis"]}
    assert shim["ExteraConfig.getAvatarCorners"]["targets"] == ["appearance.avatarCorners"]
    assert shim["ExteraConfig.getUnusedFlag"]["behavior"] == "compat-storage"
    assert all(f["implementation"]["status"] == "pending" for f in features.values())
    assert result["totals"]["verified_features"] == 0


def test_preference_getters_account_scope_collections_and_dynamic_default():
    parsed = inventory.parse_config('''
        public class FeedConfig {
            private static final String KEY_ARCHIVE = "includeArchived";
            private static final String KEY_EXCLUDED = "excludedChannels";
            private boolean includeArchived = preferences.getBoolean(KEY_ARCHIVE, false);
            private Set<Long> excludedChannels = readIds(KEY_EXCLUDED);
            public boolean getIncludeArchived() { return includeArchived; }
            public boolean getConditional(int account) { return getPreferences().getBoolean("conditional", !isPremium(account)); }
        }
    ''', "java/app/exteraless/feed/FeedConfig.java")
    items = {i["field"]: i for i in parsed["items"]}
    assert items["includeArchived"]["key"] == "includeArchived"
    assert items["includeArchived"]["default"]["value"] is False
    assert items["excludedChannels"]["type"] == "set<long>"
    assert items["conditional"]["default"]["kind"] == "expression"
    assert "!isPremium(account)" == items["conditional"]["default"]["expression"]


def test_reference_bound_retains_total_without_copying_source(tmp_path):
    source(tmp_path, "kotlin/app/exteraless/chats/ChatsConfig.kt", '''
        object ChatsConfig {
            val live = addConfig("live", ConfigItem.configTypeBool, true)
        }
    ''')
    for index in range(inventory.MAX_REFS + 3):
        source(tmp_path, f"java/org/telegram/ui/Renderer{index}.java", "class Renderer { boolean b = ChatsConfig.live.Bool(); }")
    payload = inventory.build_client_inventory(tmp_path, tmp_path)
    android = payload["features"][0]["android"]
    assert android["reference_counts"]["effect"] == inventory.MAX_REFS + 3
    assert len(android["references"]["effect"]) == inventory.MAX_REFS
    assert "boolean b =" not in json.dumps(payload)


def test_unknown_registration_type_is_visible_failure():
    with pytest.raises(ValueError, match="unrecognized ConfigItem type"):
        inventory.parse_config('object ChatsConfig { val x = addConfig("x", newType, false) }',
                               "kotlin/app/exteraless/chats/ChatsConfig.kt")


def test_java_comment_is_not_kotlin_nested_comment_and_add_getter_is_live(tmp_path):
    source(tmp_path, "kotlin/app/exteraless/OpenExteraConfig.kt", '''
        object OpenExteraConfig {
            val addCommaAfterMention = addConfig("comma", ConfigItem.configTypeBool, true)
            fun addCommaAfterMention(): Boolean = addCommaAfterMention.Bool()
        }
    ''')
    # This exact comment shape exists in the original DialogsActivity.java.
    source(tmp_path, "java/org/telegram/ui/DialogsActivity.java", '''
        class DialogsActivity {
            boolean unused = false /* || /* intentionally commented expression */;
            boolean comma = OpenExteraConfig.addCommaAfterMention();
        }
    ''')
    feature = inventory.build_client_inventory(tmp_path, tmp_path)["features"][0]
    assert feature["android"]["behavior"] == "effect-callsite"
    assert feature["android"]["references"]["effect"][0]["line"] == 4


def test_preference_getter_and_config_pair_derived_readers_are_live(tmp_path):
    source(tmp_path, "java/app/exteraless/ai/AiConfig.java", '''
        public class AiConfig {
            public static boolean isSaveHistory() { return getPreferences().getBoolean("saveHistory", true); }
        }
    ''')
    source(tmp_path, "java/tw/nekomimi/nekogram/NekoConfig.java", '''
        public class NekoConfig {
            public static ConfigItem sendOnline = addConfig("online", configTypeBool, true);
            public static ConfigItem locked = addConfig("locked", configTypeBool, false);
            private static final List<Pair<ConfigItem, ConfigItem>> toggles = Arrays.asList(new Pair<>(sendOnline, locked));
            public static boolean isGhostActive() { return check(toggles); }
        }
    ''')
    source(tmp_path, "java/app/exteraless/ai/ui/AiResponseSheet.java", '''
        class AiResponseSheet {
            boolean save = AiConfig.isSaveHistory();
            boolean ghost = NekoConfig.isGhostActive();
        }
    ''')
    features = inventory.build_client_inventory(tmp_path, tmp_path)["features"]
    assert len(features) == 3
    assert all(f["android"]["behavior"] == "effect-callsite" for f in features)


def test_manual_derived_edges_require_real_source_anchors(tmp_path):
    source(tmp_path, "kotlin/app/exteraless/pillstack/PillStackConfig.kt", '''
        object PillStackConfig {
            val raw = addConfig("raw", ConfigItem.configTypeString, "5,6")
            fun getActivePills(): List<Int> = materialized
        }
    ''')
    source(tmp_path, "java/app/exteraless/pillstack/PillStackController.java",
           "class PillStackController { Object pills = PillStackConfig.getActivePills(); }")
    doc = tmp_path / "docs/parity/android-evidence.json"
    doc.parent.mkdir(parents=True)
    evidence = {"derived_readers": [{"class": "PillStackConfig", "member": "getActivePills",
                 "targets": ["pillstack.raw"], "evidence": [{"file": "kotlin/app/exteraless/pillstack/PillStackConfig.kt", "anchor": "NOT_PRESENT"}]}]}
    doc.write_text(json.dumps(evidence), encoding="utf-8")
    with pytest.raises(ValueError, match="anchor missing"):
        inventory.build_client_inventory(tmp_path, tmp_path)
    evidence["derived_readers"][0]["evidence"][0]["anchor"] = "fun getActivePills()"
    doc.write_text(json.dumps(evidence), encoding="utf-8")
    feature = inventory.build_client_inventory(tmp_path, tmp_path)["features"][0]
    assert feature["android"]["behavior"] == "effect-callsite"
    assert feature["android"]["derived_readers"][0]["evidence"][0]["line"] == 4


def test_checked_non_config_helper_static_import_is_a_consumer_not_ui_only(tmp_path):
    source(tmp_path, "kotlin/xyz/nextalone/nagram/NaConfig.kt", '''
        object NaConfig { val flags = addConfig("flags", ConfigItem.configTypeInt, 0) }
    ''')
    source(tmp_path, "java/tw/nekomimi/settings/ModerationSettings.java", '''
        package tw.nekomimi.settings;
        class ModerationSettings { static boolean[] checks() { return derive(NaConfig.flags.Int()); } }
    ''')
    source(tmp_path, "java/org/telegram/Sheet.java", '''
        import static tw.nekomimi.settings.ModerationSettings.checks;
        class Sheet { void show() { present(checks()); } }
    ''')
    path = tmp_path / "docs/parity/android-evidence.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"derived_readers": [{"class": "ModerationSettings", "fqcn": "tw.nekomimi.settings.ModerationSettings",
                    "member": "checks", "targets": ["nagram.flags"], "evidence": [
                        {"file": "java/tw/nekomimi/settings/ModerationSettings.java", "anchor": "return derive(NaConfig.flags.Int());"}]}]}), encoding="utf-8")
    row = inventory.build_client_inventory(tmp_path, tmp_path)["features"][0]
    assert row["android"]["behavior"] == "effect-callsite"
    assert row["android"]["reference_counts"]["effect"] == 1
    assert row["android"]["references"]["effect"][0]["file"] == "java/org/telegram/Sheet.java"


def test_kotlin_import_alias_and_java_shadow_class_do_not_confuse_callsites(tmp_path):
    source(tmp_path, "kotlin/xyz/nextalone/nagram/NaConfig.kt", '''
        package xyz.nextalone.nagram
        object NaConfig { val live = addConfig("live", ConfigItem.configTypeBool, true) }
    ''')
    source(tmp_path, "java/org/telegram/Reader.kt", '''
        import xyz.nextalone.nagram.NaConfig as Settings
        fun use() = Settings.live.Bool()
    ''')
    source(tmp_path, "java/org/telegram/Wrong.java", '''
        import different.package.NaConfig;
        class Wrong { boolean b = NaConfig.live.Bool(); }
    ''')
    feature = inventory.build_client_inventory(tmp_path, tmp_path)["features"][0]
    assert feature["android"]["reference_counts"]["effect"] == 1
    assert feature["android"]["references"]["effect"][0]["file"].endswith("Reader.kt")


def test_same_class_effect_read_and_independent_ui_row_index(tmp_path):
    source(tmp_path, "java/app/exteraless/general/CloudHelper.java", '''
        import android.content.SharedPreferences;
        public class CloudHelper {
            private boolean autoSync = preferences.getBoolean("auto_sync", false);
            public boolean getAutoSync() { return autoSync; }
            public void sync() { if (autoSync) upload(); }
        }
    ''')
    source(tmp_path, "java/app/exteraless/settings/SettingsActivity.java", '''
        class SettingsActivity {
            void updateRows() { addRow("standaloneAction"); }
        }
    ''')
    payload = inventory.build_client_inventory(tmp_path, tmp_path)
    feature = payload["features"][0]
    assert feature["android"]["reference_counts"]["effect"] == 1
    assert feature["android"]["references"]["effect"][0]["line"] == 6
    assert payload["ui_definitions"][0]["row_key"] == "standaloneAction"
    assert payload["ui_definitions"][0]["setting_ids"] == []
