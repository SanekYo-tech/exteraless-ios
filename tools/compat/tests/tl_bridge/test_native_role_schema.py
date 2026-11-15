"""Audit explicit native roles against the actual schema, without importing plugins."""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]


class NativeRoleSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = (ROOT / "telegram-ios/submodules/TelegramCore/Sources/ExteralessRuntime/TLTransformCodec.swift").read_text(encoding="utf-8")
        block = source.split("let columns: [String: String] = [", 1)[1].split("        ]", 1)[0]
        cls.columns = {key: set(value.split()) for key, value in re.findall(r'"([a-z_]+)": "([^"]*)"', block)}
        schema = json.loads((ROOT / "python/runtime/tl-schema.json").read_text(encoding="utf-8"))
        cls.rows = {row["name"]: row for row in schema["constructors"] + schema["methods"]}
        cls.constructors = schema["constructors"]

    def test_roles_exist_and_have_integer_shapes(self):
        for field, constructors in self.columns.items():
            for name in constructors:
                row = self.rows[name]
                params = {param["name"]: param["type"].split("?")[-1] for param in row["params"]}
                self.assertIn(params.get(field), ("int", "long", "Vector<int>", "Vector<long>"), (name, field))

    def test_named_peer_columns_require_explicit_classification(self):
        # These real similarly named fields are counts/durations, NOT PeerIds.
        # A schema addition requires review instead of auto-promoting its integer.
        non_peer = {
            ("inputStorePaymentStarsGiveaway", "users"),
            ("premiumGiftCodeOption", "users"),
            ("starsGiveawayWinnersOption", "users"),
            ("channelAdminLogEventActionToggleSlowMode", "prev_value"),
            ("channelAdminLogEventActionToggleSlowMode", "new_value"),
            ("channelAdminLogEventActionChangeHistoryTTL", "prev_value"),
            ("channelAdminLogEventActionChangeHistoryTTL", "new_value"),
        }
        for field, constructors in self.columns.items():
            if field == "id":
                continue  # Polymorphic id has a separate declared-type oracle.
            for name, row in self.rows.items():
                numeric = any(p["name"] == field and p["type"].split("?")[-1] in
                              ("int", "long", "Vector<int>", "Vector<long>") for p in row["params"])
                if numeric:
                    self.assertEqual(name in constructors, (name, field) not in non_peer, (name, field))

    def test_native_peer_sum_types_are_covered(self):
        for row in self.constructors:
            name = row["name"]
            if row["type"] in ("User", "Chat", "ChatFull", "UserFull", "EncryptedChat"):
                self.assertIn(name, self.columns["id"], name)

    def test_opaque_long_ids_are_not_peer_roles(self):
        for name, field in (("document", "id"), ("photo", "id"), ("inputFile", "id"),
                            ("encryptedMessage", "random_id"), ("inputSingleMedia", "random_id"),
                            ("inputAppEvent", "peer"), ("messageEntityCustomEmoji", "document_id"),
                            ("authorization", "hash")):
            self.assertNotIn(name, self.columns.get(field, set()), (name, field))


if __name__ == "__main__":
    unittest.main()
