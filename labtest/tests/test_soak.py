import argparse
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

from labtest import run
from labtest.extra import soak


def s(t, rss=8000, pid="100", connected=True, fds=10, tmp_kb=40):
    return {"t": t, "rss_kb": {"inform": rss, "announce": 3000}, "fds": fds, "tmp_files": 3, "tmp_kb": tmp_kb,
            "sectors": 0, "pid": pid, "connected": connected}


def day(**late):
    """25 h of samples every 5 min; samples in the last hour take `late`."""
    return [s(i * 300, **(late if i * 300 > 24 * 3600 else {})) for i in range(25 * 12 + 1)]


class VerdictTest(unittest.TestCase):
    def test_verdict_passes_flat_memory(self):
        ok, why = soak.verdict(day())
        self.assertTrue(ok, why)

    def test_verdict_fails_twenty_percent_growth(self):
        ok, why = soak.verdict(day(rss=9700))  # 8000 -> 9700: more than 1.2x
        self.assertFalse(ok)
        self.assertIn("inform", why[0])
        self.assertTrue(soak.verdict(day(rss=9500))[0])  # 1.19x passes
        self.assertFalse(soak.verdict(day(fds=13))[0])
        self.assertFalse(soak.verdict(day(tmp_kb=49))[0])

    def test_verdict_fails_on_pid_change(self):
        ok, why = soak.verdict(day(pid="200"))
        self.assertFalse(ok)
        self.assertIn("pid", why[0])

    def test_verdict_fails_when_not_connected(self):
        samples = day()
        samples[40]["connected"] = False
        ok, why = soak.verdict(samples)
        self.assertFalse(ok)
        self.assertIn("not connected", why[0])


class RunTest(unittest.TestCase):
    def test_samples_survive_a_dead_run(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        clock = [0.0]
        ctl = mock.Mock()
        with mock.patch.object(soak, "sample", side_effect=[s(0), s(300), RuntimeError("ssh died")]), \
                mock.patch("time.monotonic", side_effect=lambda: clock[0]), \
                mock.patch("time.sleep", side_effect=lambda x: clock.__setitem__(0, clock[0] + x)):
            with self.assertRaises(RuntimeError):
                soak.run({"results_dir": d, "row_wlan": "W"}, mock.Mock(host="h"), ctl, hours=1)
        with open(os.path.join(d, "soak.json")) as f:
            self.assertEqual(len(json.load(f)["samples"]), 2)


class VmStageTest(unittest.TestCase):
    def test_vm_stage_stops_at_first_failure(self):
        seen = []

        def stage(name, ok):
            def fn(args):
                seen.append((name, args.target))
                return [(name, ok, "")]
            return fn
        with mock.patch.object(run, "catalog_stage", stage("catalog", True)), \
                mock.patch.object(run, "table_stage", stage("table", True)), \
                mock.patch.object(run, "writes_stage", stage("writes", True)), \
                mock.patch.object(run, "cycle_stage", stage("cycle", False)), \
                mock.patch.object(run, "garbage_stage", stage("garbage", True)):
            out = run.vm_stage(argparse.Namespace(target="vm1", only="", limit=None, hours=24))
        self.assertEqual(seen, [("catalog", "vm1"), ("table", "vm1"), ("writes", "vm1"), ("cycle", "vm4")])
        self.assertEqual([c[1] for c in out], [True, True, True, False])
        self.assertNotIn("soak", [n for n, _ in seen])


if __name__ == "__main__":
    unittest.main()
