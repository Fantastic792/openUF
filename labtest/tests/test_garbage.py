import json
import shutil
import tempfile
import unittest
from unittest import mock

from labtest.extra import fake, garbage

MAC = bytes.fromhex("020000000001")
REQ = b"TNBU" + b"\x00\x00\x00\x01" + MAC + b"\x00\x01" + b"\x00" * 30


class FakeServer:
    """Every read of `informs` is one more inform from openUF, answered with the next queued reply."""

    def __init__(self, host, port=18080):
        self.next, self.n, self.replies = None, 0, []

    def start(self):
        pass

    def stop(self):
        pass

    @property
    def informs(self):
        self.n += 1
        if self.next:
            self.replies.append(self.next(REQ))
        return self.n


class FakeTarget:
    def __init__(self, kind="vm"):
        self.name, self.kind, self.host, self.cmds = "fake", kind, "h", []
        self.pid, self.rss, self.md5, self.errors, self.crash_on, self.change_on = "100", 1000, "aaa", "", None, None

    def ssh(self, cmd, timeout=20, stdin=None):
        self.cmds.append(cmd)
        if cmd.startswith("logger"):
            case = cmd.split("'")[1].split()[-2] if "case " in cmd else None
            if case and case == self.crash_on:
                self.pid = "101"
            if case and case == self.change_on:
                self.md5 = "bbb"
            return 0, ""
        if "pgrep" in cmd:
            return 0, self.pid + "\n"
        if "VmRSS" in cmd:
            return 0, f"VmRSS:\t{self.rss} kB\n"
        if "md5sum /etc/config" in cmd:
            return 0, self.md5
        if "logread" in cmd:
            return 0, self.errors
        return 0, ""


class FakeCtl:
    def __init__(self, adopted=False):
        self.adopted = adopted

    def login(self):
        pass

    def device(self, host):
        return {"ip": host, "adopted": self.adopted}


class GarbageCasesTest(unittest.TestCase):
    def test_every_case_gives_a_reply_and_none_is_a_command(self):
        self.assertEqual(sorted(garbage.CASES), sorted(
            ["empty_body", "http_500", "random_bytes", "short_header", "huge_length", "undecryptable", "not_json",
             "wrong_types", "two_megabytes", "cut_mid_body", "slow_40s"]))
        for name, case in garbage.CASES.items():
            replies = case(MAC)
            self.assertTrue(replies, name)
            for rep in replies:
                body = rep[1] if isinstance(rep, tuple) and isinstance(rep[0], int) else b""
                if isinstance(rep, tuple) and rep[0] == "cut":
                    body = rep[2]
                try:
                    obj = json.loads(fake.decode(body))
                except Exception:  # noqa: BLE001 -- not a frame, or not JSON: cannot be a command
                    continue
                if isinstance(obj, dict):
                    self.assertFalse(obj.get("_type") == "cmd" and obj.get("cmd") is not None, name)
                    cfg = obj.get("system_cfg")
                    self.assertFalse(isinstance(cfg, str) and len(cfg) < 1 << 20, name)
        self.assertEqual(len(garbage.CASES["wrong_types"](MAC)), 4)


class GarbageRunTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        self.conf = {"results_dir": self.dir, "fake_host": "192.0.2.1"}
        for p in (mock.patch("labtest.extra.garbage.fake.Server", FakeServer), mock.patch("time.sleep"),
                  mock.patch.object(garbage, "CASES", {"a": lambda mac: [(200, b"")], "b": lambda mac: [(500, b"")]})):
            p.start()
            self.addCleanup(p.stop)

    def test_refuses_hardware(self):
        with self.assertRaises(SystemExit):
            garbage.run(self.conf, FakeTarget(kind="hw"), FakeCtl())

    def test_refuses_adopted(self):
        t = FakeTarget()
        with self.assertRaises(SystemExit):
            garbage.run(self.conf, t, FakeCtl(adopted=True))
        self.assertFalse(any("set-inform" in c for c in t.cmds))

    def test_clean_run_passes_and_points_back(self):
        t = FakeTarget()
        r = garbage.run(self.conf, t, FakeCtl())
        self.assertTrue(r["pass"], r)
        self.assertEqual([c["name"] for c in r["cases"]], ["a", "b"])
        self.assertTrue(any("set-inform http://192.0.2.1:18080/inform" in c for c in t.cmds))
        self.assertIn(garbage.RESTORE, t.cmds[-1])

    def test_crash_after_a_case_fails_that_case(self):
        t = FakeTarget()
        t.crash_on = "a"
        r = garbage.run(self.conf, t, FakeCtl())
        self.assertFalse(r["pass"])
        self.assertIn("pid", r["cases"][0]["problems"][0])

    def test_config_change_after_a_case_fails_that_case(self):
        t = FakeTarget()
        t.change_on = "b"
        r = garbage.run(self.conf, t, FakeCtl())
        self.assertEqual([c["ok"] for c in r["cases"]], [True, False])
        self.assertIn("/etc/config", r["cases"][1]["problems"][0])

    def test_conf_is_restored_even_when_a_case_raises(self):
        t = FakeTarget()

        def boom(mac):
            raise RuntimeError("boom")
        with mock.patch.object(garbage, "CASES", {"a": boom}):
            with self.assertRaises(RuntimeError):
                garbage.run(self.conf, t, FakeCtl())
        self.assertIn(garbage.RESTORE, t.cmds[-1])


if __name__ == "__main__":
    unittest.main()
