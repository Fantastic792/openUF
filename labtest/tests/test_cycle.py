import shutil
import tempfile
import unittest
from unittest import mock

from labtest.extra import cycle


class FakeTarget:
    def __init__(self, kind="vm"):
        self.name, self.kind, self.host, self.lab_n, self.cmds = "fake", kind, "h", 4, []
        self.leave = ""  # a file that appears after the first find: a leftover

    def ssh(self, cmd, timeout=20, stdin=None):
        self.cmds.append(cmd)
        if cmd.startswith("find /"):
            extra = self.leave if any(c.startswith("find /") for c in self.cmds[:-1]) else ""
            return 0, "/etc/passwd\n/etc/config/wireless\n" + extra
        if "md5sum" in cmd:
            return 0, "abc  /opt/openuf/conf.lua\n"
        return 0, ""

    def wait(self, up, secs):
        return True


class FakeCtl:
    def __init__(self, adopted=False):
        self.adopted = adopted

    def login(self):
        pass

    def device(self, host):
        return {"ip": host, "adopted": self.adopted}


class CycleTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.conf = {"results_dir": self.dir, "lab_sh": "/lab/lab.sh"}
        self.runs = []
        for p in (mock.patch("labtest.extra.cycle._sh", side_effect=self.fake_sh),
                  mock.patch("time.sleep", side_effect=lambda s: self.runs.append(["sleep", s])),
                  mock.patch("labtest.extra.cycle.table._errors", return_value=[])):
            p.start()
            self.addCleanup(p.stop)
        self.fail_on = None

    def fake_sh(self, argv, timeout=900):
        self.runs.append(argv)
        return not (self.fail_on and any(self.fail_on in str(a) for a in argv)), ""

    def test_leftovers_respects_keep(self):
        before = ["/etc/passwd"]
        after = ["/etc/passwd", "/etc/openuf/authkey", "/etc/init.d/openuf", "/opt/openuf/inform.lua"]
        keep = [("/etc/openuf/", "state dir stays")]
        self.assertEqual(cycle.leftovers(before, after, keep), ["/etc/init.d/openuf", "/opt/openuf/inform.lua"])
        self.assertTrue(all(reason for _, reason in cycle.KEEP))  # every keep says why

    def test_cycle_refuses_hardware(self):
        with self.assertRaises(SystemExit):
            cycle.run(self.conf, FakeTarget(kind="hw"), FakeCtl())
        self.assertEqual(self.runs, [])

    def test_cycle_refuses_an_adopted_target(self):
        with self.assertRaises(SystemExit):
            cycle.run(self.conf, FakeTarget(), FakeCtl(adopted=True))
        self.assertEqual(self.runs, [])

    def test_cycle_stops_at_the_first_failed_step(self):
        self.fail_on = "install-openuf.sh"
        t = FakeTarget()
        r = cycle.run(self.conf, t, FakeCtl())
        self.assertFalse(r["pass"])
        self.assertEqual([s["name"] for s in r["steps"]], ["fresh", "before", "install"])
        self.assertFalse(r["steps"][-1]["ok"])
        self.assertFalse(any("uninstall" in c for c in t.cmds))

    def test_leftovers_fail_but_the_upgrade_still_runs(self):
        t = FakeTarget()
        t.leave = "/etc/config/openuf\n"
        r = cycle.run(self.conf, t, FakeCtl())
        self.assertFalse(r["pass"])
        self.assertEqual([(s["name"], s["ok"]) for s in r["steps"]][5:],
                         [("leftovers", False), ("install_old", True), ("upgrade", True), ("after_upgrade", True)])

    def test_cycle_passes_when_every_step_does(self):
        t = FakeTarget()
        r = cycle.run(self.conf, t, FakeCtl())
        self.assertTrue(r["pass"], r["steps"])
        self.assertEqual([s["name"] for s in r["steps"]],
                         ["fresh", "before", "install", "running", "uninstall", "leftovers", "install_old",
                          "upgrade", "after_upgrade"])
        self.assertTrue(any("v0.13.0" in " ".join(map(str, a)) for a in self.runs))
        # provision types on the serial console: a key during GRUB's countdown stops the boot (lab recipe: sleep 45)
        flat = [" ".join(map(str, a)) for a in self.runs]
        start = flat.index("sh /lab/lab.sh start 4")
        self.assertEqual(flat[start + 1], f"sleep {cycle.BOOT_WAIT}")
        self.assertGreaterEqual(cycle.BOOT_WAIT, 45)


if __name__ == "__main__":
    unittest.main()
