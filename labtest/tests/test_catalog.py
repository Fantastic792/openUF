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
        self.assertFalse(catalog.in_scope("Account"))
        self.assertFalse(any(f["obj"] in ("Broken", "List") for f in fields))  # unreadable or not an object: skipped

    def test_summary_counts_in_scope_only(self):
        s = catalog.summary(catalog.load(self.dir))
        self.assertEqual(s["files"], 2)
        self.assertEqual(s["fields"], 5)
        self.assertEqual(s["in_scope"], {"WlanConf": 2, "Device": 0, "Setting": 2})
        self.assertEqual(s["sections"], 1)
        self.assertEqual(s["kinds"], {"bool": 2, "enum": 1, "other": 1})

    def ring2_dir(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        files = {"WlanConf.json": {"hide_ssid": "true|false"}, "NetworkConf.json": {"igmp_snooping": "true|false"},
                 "UserGroup.json": {"qos_rate_max_up": "-1|[2-9]|[1-9][0-9]{1,4}", "name": ".{1,128}"},
                 "Device.json": {"led_override": "default|on|off", "port_overrides": [
                     {"port_idx": "[1-9]", "isolation": "true|false", "poe_mode": "auto|off", "name": ".{0,128}",
                      "excluded_networkconf_ids": [""]}]}}
        for name, body in files.items():
            with open(os.path.join(d, name), "w") as f:
                json.dump(body, f)
        return d

    def test_ring2_in_scope_and_counted_apart(self):
        for obj in ("NetworkConf", "PortConf", "UserGroup", "RadiusProfile", "Device.port_overrides"):
            self.assertTrue(catalog.in_scope(obj), obj)
        s = catalog.summary(catalog.load(self.ring2_dir()))
        self.assertEqual(s["in_scope"], {"WlanConf": 1, "Device": 2, "Setting": 0})  # ring 1: Device's own 2 keys
        self.assertEqual(s["ring2"], {"NetworkConf": 1, "UserGroup": 2, "Device.port_overrides": 4})

    def test_port_overrides_fields_loaded(self):
        po = {f["key"]: f["kind"] for f in catalog.load(self.ring2_dir()) if f["obj"] == "Device.port_overrides"}
        self.assertEqual(po, {"isolation": "bool", "poe_mode": "enum", "name": "other", "excluded_networkconf_ids": "other"})

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
