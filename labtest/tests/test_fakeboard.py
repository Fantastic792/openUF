import unittest
from labtest.extra import fakeboard as fb

BASE = "aa:bb:cc:dd:ee:05"  # made up


class TestText(unittest.TestCase):
    def test_far(self):
        self.assertEqual([fb.far(p) for p in fb.PORTS], ["lan1p", "lan2p", "lan3p", "lan4p", "wanp"])

    def test_macs(self):
        m = fb.macs(BASE)
        self.assertEqual(m["br-lan"], BASE)
        self.assertEqual(m["eth0"], "02:cc:dd:ee:05:e0")
        self.assertEqual(m["lan1"], "02:cc:dd:ee:05:01")
        self.assertEqual(m["wan"], "02:cc:dd:ee:05:05")
        self.assertEqual(m["wanp"], "02:cc:dd:ee:05:15")
        self.assertEqual(len(set(m.values())), 12)

    def test_batch(self):
        b = fb.uci_batch(BASE).splitlines()
        self.assertEqual(b[0], f"set network.@device[0].macaddr='{BASE}'")
        self.assertEqual(b[-1], "commit network")
        self.assertEqual([l for l in b if l.startswith("add_list network.@device[0].ports")],
                         [f"add_list network.@device[0].ports='{p}'" for p in fb.PORTS])
        self.assertIn("set network.fb_lan3.peer_name='lan3p'", b)
        self.assertIn("set network.fb_lan3.peer_macaddr='02:cc:dd:ee:05:13'", b)
        self.assertIn("add_list network.fb_far.ports='lan1p'", b)
        self.assertNotIn("set network.fb_lan1p=interface", b)   # the uplink far end sits in br-far
        self.assertIn("set network.fb_lan2p=interface", b)

    def test_batch_other_uplink(self):
        b = fb.uci_batch(BASE, uplink="wan").splitlines()
        self.assertIn("add_list network.fb_far.ports='wanp'", b)
        self.assertIn("set network.fb_lan1p=interface", b)

    def test_boot_script(self):
        self.assertIn("START=15", fb.BOOT_SCRIPT)
        self.assertIn(f"echo '{fb.BOARD}' > /tmp/sysinfo/board_name", fb.BOOT_SCRIPT)
        self.assertIn(f"echo '{fb.MODEL}' > /tmp/sysinfo/model", fb.BOOT_SCRIPT)


if __name__ == "__main__":
    unittest.main()
