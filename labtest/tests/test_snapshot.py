import unittest

from labtest import snapshot
from labtest.tests.test_heal_py import FakeTarget


class SnapshotTest(unittest.TestCase):
    def test_secret_values_never_stored(self):
        for line in ("wireless.w.key='hunter2hunter2'", "wpa_passphrase=hunter2hunter2",
                     "aaa.1.radius_secret=hunter2hunter2", "mgmt.authkey=hunter2hunter2",
                     "r0kh=02:00:00:00:00:01 id hunter2hunter2", "sae_password=hunter2hunter2",
                     "r1kh=02:00:00:00:00:01 02:00:00:00:00:01 hunter2hunter2",
                     "wireless.openuf_radio0_T.r0kh='ff:ff:ff:ff:ff:ff,*,hunter2hunter2' 'x,y,hunter2'",
                     "wireless.openuf_radio0_T.r1kh='00:00:00:00:00:00,00:00:00:00:00:00,hunter2hunter2'"):
            out = snapshot.redact(line)
            self.assertNotIn("hunter2", out)
            self.assertEqual(out, snapshot.redact(line))  # stable
        self.assertNotEqual(snapshot.redact("wpa_passphrase=a"), snapshot.redact("wpa_passphrase=b"))  # a change shows
        self.assertEqual(snapshot.redact("wireless.w.ssid='Lab'"), "wireless.w.ssid='Lab'")
        self.assertEqual(snapshot.redact("no equals sign here"), "no equals sign here")

    def test_key_mgmt_and_rekey_are_not_secrets(self):
        # the checks read these values: "key" in the name is not a key here
        self.assertEqual(snapshot.redact("wpa_key_mgmt=WPA-PSK FT-PSK"), "wpa_key_mgmt=WPA-PSK FT-PSK")
        self.assertEqual(snapshot.redact("wpa_group_rekey=3600"), "wpa_group_rekey=3600")

    def test_diff_and_volatile(self):
        a = {"uci": ["x=1", "y=1"], "tc": ["q 5"]}
        b = {"uci": ["x=2", "y=1"], "tc": ["q 6"]}
        self.assertEqual(snapshot.diff(a, b), ["tc: -q 5", "tc: +q 6", "uci: -x=1", "uci: +x=2"])
        self.assertEqual(snapshot.diff(a, b, ignore=frozenset(["tc: -q 5", "tc: +q 6"])), ["uci: -x=1", "uci: +x=2"])
        self.assertEqual(snapshot.volatile(a, b), frozenset(snapshot.diff(a, b)))
        self.assertEqual(snapshot.diff(a, a), [])

    def test_bss_blocks(self):
        snap = {"hostapd": ["## f", "interface=p0", "ssid=A", "ignore_broadcast_ssid=0", "bss=p1", "ssid=B",
                            "ap_isolate=1", "## g", "interface=q0", "ssid=B"]}
        self.assertEqual(snapshot.bss(snap, "B"), [["bss=p1", "ssid=B", "ap_isolate=1"], ["interface=q0", "ssid=B"]])
        self.assertEqual(snapshot.bss(snap, "Z"), [])
        # OpenWrt writes the quoted ssid2= form (seen on vm1)
        ow = {"hostapd": ["## f", "interface=phy0-ap0", 'ssid2="LabTest"', "bss=phy0-ap1", 'ssid2="LabTest2"']}
        self.assertEqual(snapshot.bss(ow, "LabTest"), [["interface=phy0-ap0", 'ssid2="LabTest"']])

    def test_take_splits_sections_and_redacts(self):
        out = ("@@labtest@@ uci\nwireless.w.key='hunter2'\nwireless.w.ssid='T'\n@@labtest@@ hostapd\n## /var/run/h.conf\n"
               "ssid=T\n@@labtest@@ nft\n@@labtest@@ tc\nqdisc noqueue 0: dev lo\n@@labtest@@ ip\nlo UNKNOWN\n")
        t = FakeTarget({"uci show": (0, out)})
        snap = snapshot.take(t)
        self.assertEqual(sorted(snap), sorted(snapshot.SECTIONS))
        self.assertEqual(snap["uci"][1], "wireless.w.ssid='T'")
        self.assertNotIn("hunter2", str(snap))
        self.assertEqual(snap["nft"], [])

    def test_take_raises_when_ssh_fails(self):
        with self.assertRaises(RuntimeError):
            snapshot.take(FakeTarget({"uci show": (255, "")}))


if __name__ == "__main__":
    unittest.main()
