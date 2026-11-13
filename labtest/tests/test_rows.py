import unittest

from labtest import rows


def f(key, kind="bool", obj="WlanConf"):
    return {"obj": obj, "key": key, "kind": kind, "values": [True, False] if kind == "bool" else None}


class RowsTest(unittest.TestCase):
    def test_risk(self):
        self.assertEqual(rows.risk(f("x_passphrase", "other")), "skip: secret")
        self.assertEqual(rows.risk(f("name", "other")), "skip: not a simple on/off or pick-one")
        self.assertEqual(rows.risk(f("hide_ssid")), "safe")
        for k in ("vlan_enabled", "networkconf_id", "disabled", "mgmt_vlan", "x_ssh_enabled", "dhcp_enabled", "lan"):
            self.assertNotEqual(rows.risk(f(k)), "safe", k)
        self.assertEqual(rows.risk(f("vlan_enabled")), "cutoff")
        self.assertEqual(rows.risk(f("wlan_band")), "safe")  # "wlan" is not "lan"
        self.assertEqual(rows.risk(f("iptv_enabled")), "safe")  # "iptv" is not "ip"

    def test_build_orders_safe_before_cutoff_and_keeps_skipped(self):
        fields = [f("vlan_enabled"), f("name", "other"), f("bc_filter_enabled"), f("x", obj="NetworkConf"),
                  f("auto", obj="Setting.super_mgmt"), f("led_enabled", obj="Setting.mgmt")]
        built = [r for r in rows.build(fields) if r["name"] not in rows.CHECKS]  # registry rows: test_rows_wifi
        self.assertEqual([r["name"] for r in built],
                         ["WlanConf.bc_filter_enabled", "Setting.mgmt.led_enabled", "WlanConf.name", "WlanConf.vlan_enabled"])
        r = built[0]
        self.assertEqual((r["obj"], r["key"], r["risk"], r["needs"], r["set"]), ("WlanConf", "bc_filter_enabled", "safe", "vm", None))
        self.assertEqual(r["field"], f("bc_filter_enabled"))
        self.assertEqual(r["keys"], ["vlan_enabled", "name", "bc_filter_enabled"])  # every field of the object, for the put-back


if __name__ == "__main__":
    unittest.main()
