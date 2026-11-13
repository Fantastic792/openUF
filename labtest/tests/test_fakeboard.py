import unittest
from labtest.extra import fakeboard as fb

BASE = "aa:bb:cc:dd:ee:05"  # made up
ALL = "br-lan br-far eth0 " + " ".join(p + " " + fb.far(p) for p in fb.PORTS)


class FakeTarget:
    """Answers ssh from command fragments; a dressed VM when board == fb.BOARD and fb_far."""

    def __init__(self, kind="vm", board="qemu-standard-pc", fb_far=False, comes_back=True, lab_n=5, links=ALL,
                 log="", claimers="/opt/openuf/modelmap/jiorouter-ax6000-jidu6j01.lua", veth="present", batch_rc=0):
        self.name, self.host, self.kind, self.lab_n, self.cmds = "fake", "h", kind, lab_n, []
        self.board, self.fb_far, self.comes_back, self.links = board, fb_far, comes_back, links
        self.log, self.claimers, self.veth, self.batch_rc = log, claimers, veth, batch_rc

    def ssh(self, cmd, timeout=20, stdin=None):
        self.cmds.append(cmd)
        if "apk add kmod-veth" in cmd:  # veth: present | installable | missing
            self.veth = "present" if self.veth == "installable" else self.veth
            return (0 if self.veth == "present" else 1, "")
        if "veth.ko" in cmd:
            return (0, "/lib/modules/x/veth.ko") if self.veth == "present" else (1, "")
        if cmd == "uci batch":
            return (self.batch_rc, "")
        answers = [("sysinfo/board_name", (0, self.board)),
                   ("sysinfo/model", (0, fb.MODEL if self.board == fb.BOARD else "QEMU")),
                   ("network.fb_far", (0, "device") if self.fb_far else (1, "")),
                   ("network.@device[0].name", (0, "br-lan")),
                   ("eth0/address", (0, BASE)), ("br-lan/address", (0, BASE)),
                   ("br-lan/brif", (0, " ".join(fb.PORTS))), ("br-far/brif", (0, "eth0 lan1p")),
                   ("ls /sys/class/net", (0, self.links)), ("logread", (0, self.log)),
                   ("grep -l", (0, self.claimers)), ("pgrep", (0, "100"))]
        return next((a for frag, a in answers if frag in cmd), (0, ""))

    def wait(self, up, secs):
        return self.comes_back or not up


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
        self.assertIn("set network.lan.force_link='1'", b)  # netifd misses br-lan's link-up on some boots

    def test_batch_other_uplink(self):
        b = fb.uci_batch(BASE, uplink="wan").splitlines()
        self.assertIn("add_list network.fb_far.ports='wanp'", b)
        self.assertIn("set network.fb_lan1p=interface", b)

    def test_boot_script(self):
        self.assertIn("START=15", fb.BOOT_SCRIPT)
        self.assertIn(f"echo '{fb.BOARD}' > /tmp/sysinfo/board_name", fb.BOOT_SCRIPT)
        self.assertIn(f"echo '{fb.MODEL}' > /tmp/sysinfo/model", fb.BOOT_SCRIPT)


class TestDress(unittest.TestCase):
    def test_refuses_hardware(self):
        t = FakeTarget(kind="hw")
        with self.assertRaises(SystemExit):
            fb.dress(t, adopted=False)
        self.assertEqual(t.cmds, [])

    def test_refuses_adopted_plain_vm(self):          # vm1 by mistake
        t = FakeTarget(board="qemu-something")
        with self.assertRaises(SystemExit) as e:
            fb.dress(t, adopted=True)
        self.assertIn("adopted", str(e.exception))
        self.assertFalse(any("uci batch" in c or "reboot" in c for c in t.cmds))

    def test_dressed_is_left_alone(self):             # run twice
        t = FakeTarget(board=fb.BOARD, fb_far=True)
        fb.dress(t, adopted=True)
        self.assertFalse(any("uci batch" in c or "reboot" in c or "eth0/address" in c for c in t.cmds))

    def test_no_comeback_names_the_reset(self):
        t = FakeTarget(board="qemu-something", comes_back=False, lab_n=5)
        with self.assertRaises(SystemExit) as e:
            fb.dress(t, adopted=False)
        self.assertIn("lab.sh reset 5", str(e.exception))

    def test_verify_lists_missing_link(self):
        t = FakeTarget(board=fb.BOARD, fb_far=True, links="br-lan br-far eth0 lan1 lan1p lan2 lan3 lan4 wan")
        self.assertTrue(any("lan2p" in p for p in fb.verify(t)))

    def test_dress_feeds_the_batch_and_reboots(self):
        t = FakeTarget()
        fb.dress(t, adopted=False)
        self.assertTrue(any("uci batch" in c for c in t.cmds))
        self.assertTrue(any("reboot" in c for c in t.cmds))

    def test_no_veth_refuses_before_writing(self):    # a fresh lab VM has no kmod-veth
        t = FakeTarget(veth="missing")
        with self.assertRaises(SystemExit) as e:
            fb.dress(t, adopted=False)
        self.assertIn("kmod-veth", str(e.exception))
        self.assertTrue(any("apk add kmod-veth" in c for c in t.cmds))
        self.assertFalse(any(fb.INIT in c or "uci batch" in c or "reboot" in c for c in t.cmds))

    def test_veth_installed_then_dresses(self):
        t = FakeTarget(veth="installable")
        fb.dress(t, adopted=False)
        self.assertTrue(any("reboot" in c for c in t.cmds))

    def test_batch_failure_stops_before_reboot(self):
        t = FakeTarget(batch_rc=1)
        with self.assertRaises(SystemExit) as e:
            fb.dress(t, adopted=False)
        self.assertIn("uci batch", str(e.exception))
        self.assertFalse(any("reboot" in c for c in t.cmds))


if __name__ == "__main__":
    unittest.main()
