import json
import os
import shutil
import tempfile
import unittest

from labtest import catalog


class CatalogTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        files = {"WlanConf.json": {"hide_ssid": "true|false", "name": ".{1,32}"},
                 "Setting.json": {"guest_access": {"auth": "none|hotspot", "portal_enabled": "true|false"},
                                  "super_mgmt": {"x": "true|false"}, "odd": "true|false"}}
        for name, body in files.items():
            with open(os.path.join(self.dir, name), "w") as f:
                json.dump(body, f)
        with open(os.path.join(self.dir, "Broken.json"), "w") as f:
            f.write("not json")
        with open(os.path.join(self.dir, "List.json"), "w") as f:
            json.dump(["a|b"], f)

    def test_kinds(self):
        self.assertEqual(catalog.kind("true|false"), ("bool", [True, False]))
        self.assertEqual(catalog.kind("false|true"), ("bool", [True, False]))
        self.assertEqual(catalog.kind("^(disabled|optional|required)$"), ("enum", ["disabled", "optional", "required"]))
        self.assertEqual(catalog.kind("open|wpapsk|wpaeap"), ("enum", ["open", "wpapsk", "wpaeap"]))
        self.assertEqual(catalog.kind(".{1,32}"), ("other", None))
        self.assertEqual(catalog.kind("^[0-9]{1,3}$"), ("other", None))

    def test_odd_shapes_are_other(self):
        for spec in (["a|b"], {"x": "true|false"}, 5, None, "", "a"):
            self.assertEqual(catalog.kind(spec), ("other", None))

    def test_load_and_scope(self):
        fields = catalog.load(self.dir)
        self.assertIn({"obj": "WlanConf", "key": "hide_ssid", "kind": "bool", "values": [True, False]}, fields)
        self.assertIn({"obj": "WlanConf", "key": "name", "kind": "other", "values": None}, fields)
        self.assertIn({"obj": "Setting.guest_access", "key": "portal_enabled", "kind": "bool", "values": [True, False]},
                      fields)
        self.assertFalse(any(f["obj"] == "Setting" for f in fields))  # sections, never the file; "odd" is dropped
        self.assertTrue(catalog.in_scope("Setting.guest_access"))
        self.assertTrue(catalog.in_scope("WlanConf"))
        self.assertTrue(catalog.in_scope("Device"))
        self.assertFalse(catalog.in_scope("Setting.super_mgmt"))
        self.assertFalse(catalog.in_scope("Setting"))
        self.assertFalse(catalog.in_scope("NetworkConf"))
        self.assertFalse(any(f["obj"] in ("Broken", "List") for f in fields))  # unreadable or not an object: skipped

    def test_summary_counts_in_scope_only(self):
        s = catalog.summary(catalog.load(self.dir))
        self.assertEqual(s["files"], 2)
        self.assertEqual(s["fields"], 5)
        self.assertEqual(s["in_scope"], {"WlanConf": 2, "Device": 0, "Setting": 2})
        self.assertEqual(s["sections"], 1)
        self.assertEqual(s["kinds"], {"bool": 2, "enum": 1, "other": 1})

    def test_section_and_flip(self):
        self.assertEqual(catalog.section("Setting.guest_access"), "guest_access")
        self.assertIsNone(catalog.section("WlanConf"))
        self.assertIsNone(catalog.section("SettingNtp"))
        b = {"kind": "bool", "values": [True, False]}
        e = {"kind": "enum", "values": ["disabled", "optional", "required"]}
        self.assertIs(catalog.flip(b, None), True)
        self.assertIs(catalog.flip(b, True), False)
        self.assertEqual(catalog.flip(e, "optional"), "required")
        self.assertEqual(catalog.flip(e, "required"), "disabled")
        self.assertIsNone(catalog.flip(e, None))
        self.assertIsNone(catalog.flip(e, "bogus"))
        self.assertIsNone(catalog.flip({"kind": "other", "values": None}, "x"))


if __name__ == "__main__":
    unittest.main()
