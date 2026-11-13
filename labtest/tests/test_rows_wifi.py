import unittest

from labtest import rows


def blk(*lines):
    return ["bss=p1", "ssid=T", *lines]


class WifiChecksTest(unittest.TestCase):
    def check(self, name, blocks, new):
        return rows.CHECKS[name]["check"](blocks, new)[0]

    def test_the_eight_rows_are_registered(self):
        self.assertEqual(sorted(n for n in rows.CHECKS if n.startswith("WlanConf.")), sorted(
            f"WlanConf.{k}" for k in ("enabled", "hide_ssid", "uapsd_enabled", "l2_isolation", "pmf_mode",
                                      "group_rekey", "dtim", "fast_roaming_enabled")))

    def test_enabled(self):
        s = rows.CHECKS["WlanConf.enabled"]["set"]
        self.assertEqual(s({"enabled": True}), {"enabled": False})
        self.assertTrue(self.check("WlanConf.enabled", [blk()], {"enabled": True}))
        self.assertFalse(self.check("WlanConf.enabled", [], {"enabled": True}))
        self.assertTrue(self.check("WlanConf.enabled", [], {"enabled": False}))
        self.assertFalse(self.check("WlanConf.enabled", [blk()], {"enabled": False}))

    def flag_row(self, name, key, line):
        s = rows.CHECKS[name]["set"]
        self.assertEqual(s({}), {key: True})
        self.assertEqual(s({key: True}), {key: False})
        self.assertTrue(self.check(name, [blk(f"{line}=1"), blk(f"{line}=1")], {key: True}))
        self.assertFalse(self.check(name, [blk(f"{line}=1"), blk(f"{line}=0")], {key: True}))
        self.assertFalse(self.check(name, [blk()], {key: True}))
        self.assertFalse(self.check(name, [], {key: True}))  # no block: nothing to check is not a pass
        self.assertTrue(self.check(name, [blk(f"{line}=0")], {key: False}))
        self.assertTrue(self.check(name, [blk()], {key: False}))
        self.assertFalse(self.check(name, [blk(f"{line}=1")], {key: False}))

    def test_hide_ssid(self):
        self.flag_row("WlanConf.hide_ssid", "hide_ssid", "ignore_broadcast_ssid")

    def test_uapsd(self):
        self.flag_row("WlanConf.uapsd_enabled", "uapsd_enabled", "uapsd_advertisement_enabled")

    def test_l2_isolation(self):
        self.flag_row("WlanConf.l2_isolation", "l2_isolation", "ap_isolate")

    def test_pmf_mode(self):
        s = rows.CHECKS["WlanConf.pmf_mode"]["set"]
        self.assertEqual(s({"pmf_mode": "disabled"}), {"pmf_mode": "optional"})
        self.assertEqual(s({"pmf_mode": "required"}), {"pmf_mode": "disabled"})
        self.assertEqual(s({}), {"pmf_mode": "optional"})
        n = "WlanConf.pmf_mode"
        self.assertTrue(self.check(n, [blk("ieee80211w=2")], {"pmf_mode": "required"}))
        self.assertFalse(self.check(n, [blk("ieee80211w=1")], {"pmf_mode": "required"}))
        self.assertTrue(self.check(n, [blk()], {"pmf_mode": "disabled"}))  # absent counts as 0
        self.assertTrue(self.check(n, [blk("ieee80211w=1")], {"pmf_mode": "optional"}))
        self.assertFalse(self.check(n, [blk()], {"pmf_mode": "optional"}))

    def test_group_rekey(self):
        s = rows.CHECKS["WlanConf.group_rekey"]["set"]
        self.assertEqual(s({"group_rekey": 3600}), {"group_rekey": 7200})
        self.assertEqual(s({"group_rekey": 7200}), {"group_rekey": 3600})
        n = "WlanConf.group_rekey"
        self.assertTrue(self.check(n, [blk("wpa_group_rekey=7200")], {"group_rekey": 7200}))
        self.assertFalse(self.check(n, [blk("wpa_group_rekey=3600")], {"group_rekey": 7200}))
        self.assertFalse(self.check(n, [blk()], {"group_rekey": 7200}))

    def test_dtim(self):
        s = rows.CHECKS["WlanConf.dtim"]["set"]
        self.assertEqual(s({}), {"dtim_mode": "custom", "dtim_na": 3, "dtim_ng": 3})
        self.assertEqual(s({"dtim_na": 3}), {"dtim_mode": "custom", "dtim_na": 2, "dtim_ng": 2})
        n = "WlanConf.dtim"
        new = {"dtim_mode": "custom", "dtim_na": 3, "dtim_ng": 3}
        self.assertTrue(self.check(n, [blk("dtim_period=3"), blk("dtim_period=3")], new))
        self.assertFalse(self.check(n, [blk("dtim_period=3"), blk("dtim_period=1")], new))

    def test_fast_roaming(self):
        n = "WlanConf.fast_roaming_enabled"
        on = blk("mobility_domain=a1b2", "wpa_key_mgmt=WPA-PSK FT-PSK")
        self.assertTrue(self.check(n, [on], {"fast_roaming_enabled": True}))
        self.assertFalse(self.check(n, [blk("wpa_key_mgmt=WPA-PSK FT-PSK")], {"fast_roaming_enabled": True}))
        self.assertFalse(self.check(n, [blk("mobility_domain=a1b2", "wpa_key_mgmt=WPA-PSK")],
                                    {"fast_roaming_enabled": True}))
        self.assertTrue(self.check(n, [blk("wpa_key_mgmt=WPA-PSK")], {"fast_roaming_enabled": False}))
        self.assertFalse(self.check(n, [on], {"fast_roaming_enabled": False}))

    def test_check_says_why(self):
        ok, why = rows.CHECKS["WlanConf.hide_ssid"]["check"]([blk("ignore_broadcast_ssid=0")], {"hide_ssid": True})
        self.assertFalse(ok)
        self.assertIn("ignore_broadcast_ssid", why)

    def test_registry_row_replaces_the_automatic_one(self):
        fields = [{"obj": "WlanConf", "key": "hide_ssid", "kind": "bool", "values": [True, False]},
                  {"obj": "WlanConf", "key": "x_passphrase", "kind": "other", "values": None},
                  {"obj": "WlanConf", "key": "pmf_mode", "kind": "other", "values": None}]
        built = rows.build(fields)
        names = [r["name"] for r in built]
        self.assertEqual(names.count("WlanConf.hide_ssid"), 1)
        hide = next(r for r in built if r["name"] == "WlanConf.hide_ssid")
        self.assertIs(hide["set"], rows.CHECKS["WlanConf.hide_ssid"]["set"])
        self.assertIs(hide["check"], rows.CHECKS["WlanConf.hide_ssid"]["check"])
        pmf = next(r for r in built if r["name"] == "WlanConf.pmf_mode")
        self.assertEqual(pmf["risk"], "safe")  # a registry row is safe even when its field is "other"
        self.assertIn("WlanConf.dtim", names)  # a registry row with no field of that name is still a row


if __name__ == "__main__":
    unittest.main()
