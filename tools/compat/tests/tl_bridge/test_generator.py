"""Bounded source/registry fixtures. They never import a plugin or open a network."""

import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
APPROVED_TEMP = Path.home() / "AppData/Local/Temp/opencode"
SPEC = importlib.util.spec_from_file_location("tl_bridge_generator", ROOT / "tools/compat/generate_tl_bridge.py")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class TLBridgeGeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.json_text, cls.swift_text = GENERATOR.generate()
        cls.schema = json.loads(cls.json_text)
        cls.records = {r["name"]: r for r in cls.schema["constructors"] + cls.schema["methods"]}

    def test_outputs_are_reproducible_and_current(self):
        self.assertEqual(self.json_text, GENERATOR.JSON_OUTPUT.read_text(encoding="utf-8"))
        self.assertEqual(self.swift_text, GENERATOR.SWIFT_OUTPUT.read_text(encoding="utf-8"))

    def test_native_layout_hash_is_the_build_generators_hash(self):
        native_generator = (ROOT / "telegram-ios/build-system/SwiftTL/Sources/SwiftTL/main.swift").read_text(encoding="utf-8")
        self.assertIn('Array("SwiftTL-Storage/1".utf8)', native_generator)
        source = GENERATOR.SCHEMA.read_text(encoding="utf-8")
        self.assertEqual(self.schema["nativeLayoutHash"], GENERATOR.native_layout_hash(source))
        self.assertIn("0x" + self.schema["nativeLayoutHash"], self.swift_text)

    def test_schema_is_native_input_not_the_stale_alternate_json(self):
        source = GENERATOR.SCHEMA.read_text(encoding="utf-8")
        declarations = re.findall(r"^([\w.]+)#([\da-fA-F]+) .*?= (.+);", source, re.M)
        native_ids = {name: GENERATOR.signed32(int(value, 16)) for name, value, _ in declarations}
        self.assertEqual(len(native_ids) + 1, len(self.records))  # SwiftTL adds help.test
        for name, constructor_id in native_ids.items():
            self.assertEqual(constructor_id, self.records[name]["id"], name)
        self.assertEqual(self.records["help.test"]["id"], GENERATOR.signed32(0xC0E202F7))

    def test_actual_android_aliases_and_native_field_names(self):
        aliases = self.schema["aliases"]
        self.assertEqual(aliases["org.telegram.tgnet.TLRPC$TL_users_getUsers"], "users.getUsers")
        self.assertEqual(aliases["org.telegram.tgnet.TLRPC$TL_messages_getHistory"], "messages.getHistory")
        self.assertEqual(aliases["org.telegram.tgnet.TLRPC$TL_user"], "user")
        self.assertEqual(aliases["org.telegram.tgnet.tl.TL_stories$TL_stories_storyViews"], "stories.storyViews")
        self.assertEqual(self.schema["typeAliases"]["org.telegram.tgnet.TLRPC$User"], "User")
        self.assertEqual(self.schema["fieldAliases"]["org.telegram.tgnet.TLRPC$TL_inputGeoPoint"], {"_long": "long"})
        self.assertEqual(self.records["users.getUsers"]["params"], [{"name": "id", "type": "Vector<InputUser>"}])
        self.assertEqual(self.records["users.getUsers"]["type"], "Vector<User>")
        self.assertEqual(self.schema["preferredHookNames"]["users.getUsers"], "TL_users_getUsers")
        self.assertEqual(self.schema["hookAliases"]["TL_users_getUsers"], ["users.getUsers"])
        for name, aliases in self.schema["hookNames"].items():
            self.assertIn(self.schema["preferredHookNames"][name], aliases)

    def test_old_layers_and_generic_methods_are_explicitly_unavailable(self):
        old_name = "org.telegram.tgnet.TLRPC$TL_user_layer199"
        self.assertNotIn(old_name, self.schema["aliases"])
        self.assertIn(old_name, self.schema["unsupportedAliases"])
        self.assertFalse(self.records["invokeWithLayer"]["supported"])
        self.assertIn("generic", self.records["invokeWithLayer"]["unsupportedReason"])
        self.assertGreaterEqual(sum(r["supported"] for r in self.schema["methods"]), 800)
        self.assertTrue(all(name in self.records for name in self.schema["aliases"].values()))

    def test_flag_dependencies_and_schema_order_are_not_dropped(self):
        params = self.records["inputMediaPoll"]["params"]
        self.assertEqual(params[0], {"name": "flags", "type": "#"})
        self.assertIn({"name": "solution", "type": "flags.1?string"}, params)
        self.assertIn({"name": "solution_entities", "type": "flags.1?Vector<MessageEntity>"}, params)
        user_fields = self.records["user"]["params"]
        self.assertLess(next(i for i, p in enumerate(user_fields) if p["name"] == "flags2"),
                        next(i for i, p in enumerate(user_fields) if p["name"] == "id"))
        with self.assertRaisesRegex(ValueError, "flags reference"):
            GENERATOR.parse_schema("broken#12345678 x:flags.32?int flags:# = Broken;")
        with self.assertRaisesRegex(ValueError, "flags reference"):
            GENERATOR.parse_schema("broken#12345678 x:flags.1?int flags:# = Broken;")

    def test_java_parser_ignores_commented_and_local_class_ids(self):
        with tempfile.TemporaryDirectory(prefix="tl-schema-fixture-", dir=APPROVED_TEMP if APPROVED_TEMP.is_dir() else None) as temporary:
            path = Path(temporary) / "T.java"
            path.write_text('''package fixtures;
public class T {
  // class Fake { public static final int constructor = 0x123; }
  public static class Real extends Value {
    public static final int constructor = 0xfedcba98;
    String ignored = "class Fake { static int constructor = 1; }";
    void body() { class Local { static int constructor = 2; } }
  }
  public static class Value {}
}
''', encoding="utf-8")
            classes = GENERATOR.java_classes(path)
            actual = {c["fqcn"]: c["id"] for c in classes if "id" in c}
            self.assertEqual(actual, {"fixtures.T$Real": GENERATOR.signed32(0xFEDCBA98)})


if __name__ == "__main__":
    unittest.main()
