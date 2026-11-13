import shutil
import tempfile
import unittest
from unittest import mock

from labtest.extra import writes

STAT = ("/sys/block/sda/stat 100 0 2000 50 300 10 4000 90 0 120 140\n"
        "/sys/block/ram0/stat 1 0 8 0 9 0 999 0 0 0 0\n"
        "/sys/block/loop0/stat 1 0 8 0 9 0 777 0 0 0 0\n"
        "/sys/block/zram0/stat 1 0 8 0 9 0 555 0 0 0 0\n"
        "/sys/block/vdb/stat 5 0 10 0 6 0 25 0 0 0 0\n")


class FakeTarget:
    def __init__(self):
        self.name, self.kind, self.host, self.cmds = "fake", "vm", "h", []
        self.sectors, self.files, self.applied = 1000, "", 0

    def ssh(self, cmd, timeout=20, stdin=None):
        self.cmds.append(cmd)
        if "/sys/block" in cmd:
            self.sectors += 8
            return 0, f"/sys/block/sda/stat 1 0 1 0 1 0 {self.sectors} 0 0 0 0\n"
        if cmd.startswith("find"):
            return 0, self.files
        if "state.json" in cmd:
            return 0, f'{{"cfgversion": "c{self.applied}"}}'
        return 0, ""


class FakeCtl:
    def __init__(self, t):
        self.t, self.pushes = t, 0

    def login(self):
        pass

    def locate(self, obj, host, wlan):
        return "rest/wlanconf/w1", {"_id": "w1"}

    def force_push(self, wlan_id):
        self.pushes += 1
        self.t.applied += 1


class WritesTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.conf = {"results_dir": self.dir, "row_wlan": "T"}
        for p in (mock.patch("time.sleep"), mock.patch("labtest.extra.writes.plug._connected", return_value=True)):
            p.start()
            self.addCleanup(p.stop)

    def test_sectors_sums_real_disks_only(self):
        t = FakeTarget()
        t.ssh = lambda cmd, timeout=20, stdin=None: (0, STAT)
        self.assertEqual(writes.sectors(t), 4000 + 25)

    def test_idle_file_write_fails_the_run(self):
        t = FakeTarget()
        t.files = "/etc/openuf/state.json\n"
        r = writes.run(self.conf, t, FakeCtl(t), idle=60)
        self.assertFalse(r["pass"])
        self.assertEqual(r["idle"]["files"], ["/etc/openuf/state.json"])
        self.assertEqual(r["idle"]["secs"], 60)

    def test_push_numbers_are_recorded_not_judged(self):
        t = FakeTarget()
        ctl = FakeCtl(t)
        real = ctl.force_push
        ctl.force_push = lambda w: (setattr(t, "files", "/etc/config/wireless\n"), real(w))
        r = writes.run(self.conf, t, ctl, idle=60)
        self.assertTrue(r["pass"])  # push writes are only recorded
        self.assertEqual(r["push"]["files"], ["/etc/config/wireless"])
        self.assertGreater(r["push"]["sectors"], 0)
        self.assertEqual(ctl.pushes, 2)  # there and back
        self.assertEqual(r["idle"]["files"], [])

    def test_not_connected_fails_without_measuring(self):
        t = FakeTarget()
        with mock.patch("labtest.extra.writes.plug._connected", return_value=False):
            r = writes.run(self.conf, t, FakeCtl(t), idle=60)
        self.assertFalse(r["pass"])
        self.assertIn("not connected", r["error"])


if __name__ == "__main__":
    unittest.main()
