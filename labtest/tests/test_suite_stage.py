import argparse
import os
import tempfile
import unittest
from unittest import mock

from labtest import run


class StageTest(unittest.TestCase):
    def setUp(self):
        f = tempfile.NamedTemporaryFile(delete=False)
        f.close()
        self.addCleanup(os.remove, f.name)
        self.conf = {"account_file": f.name}
        for p in (mock.patch("labtest.run.target.load_config", return_value=self.conf),
                  mock.patch("labtest.run.unifi.Controller")):
            p.start()
            self.addCleanup(p.stop)
        self.args = argparse.Namespace(target="vm1", only="", limit=None, hours=24)

    def test_the_three_stages_are_registered(self):
        for name in ("single", "multi", "release"):
            self.assertIn(name, run.STAGES)

    def test_a_suite_stage_prefixes_names_and_shows_details(self):
        checks = [{"name": "boot", "ok": True, "detail": "SSH 20 s"}, {"name": "mgmt", "ok": False, "detail": "x"}]
        with mock.patch("labtest.run.single.run", return_value={"checks": checks, "pass": False}):
            out = run.STAGES["single"](self.args)
        self.assertEqual(out, [("single.boot", True, "SSH 20 s", True), ("single.mgmt", False, "x", True)])

    def test_a_suite_stage_needs_the_account_file(self):
        self.conf["account_file"] = "/nonexistent/account"
        self.assertEqual(run.STAGES["multi"](self.args), [("multi", False, "no account file")])

    def test_release_stops_at_the_first_failing_stage(self):
        ok, bad = [("a", True, "")], [("b", False, "broke")]
        with mock.patch("labtest.run.safety", return_value=ok), mock.patch("labtest.run.vm_stage", return_value=bad), \
                mock.patch("labtest.run.single.run") as single_run:
            out = run.release(self.args)
        self.assertEqual(out, ok + bad)
        single_run.assert_not_called()

    def test_release_runs_all_four_in_order(self):
        one = {"checks": [{"name": "ready", "ok": True, "detail": ""}], "pass": True}
        with mock.patch("labtest.run.safety", return_value=[("s", True, "")]), \
                mock.patch("labtest.run.vm_stage", return_value=[("v", True, "")]), \
                mock.patch("labtest.run.single.run", return_value=one), \
                mock.patch("labtest.run.multi.run", return_value=one):
            out = run.release(self.args)
        self.assertEqual([c[0] for c in out], ["s", "v", "single.ready", "multi.ready"])

    def test_release_logs_progress_as_it_goes(self):
        with mock.patch("labtest.run.safety", return_value=[("s", True, "")]), \
                mock.patch("labtest.run.vm_stage", return_value=[("v", False, "broke")]), \
                mock.patch("labtest.run._log") as log:
            run.release(self.args)
        self.assertEqual([c.args[0] for c in log.call_args_list],
                         ["release 1/4 safety: start", "release 1/4 safety: 1 pass, 0 fail",
                          "release 2/4 vm: start", "release 2/4 vm: 0 pass, 1 fail", "release: stopped at vm"])

    def test_main_exit_codes(self):
        one = {"checks": [{"name": "ready", "ok": False, "detail": "vm1 is not reachable"}], "pass": False}
        with mock.patch("labtest.run.single.run", return_value=one), mock.patch("builtins.print"):
            self.assertEqual(run.main(["single"]), 1)
            self.assertEqual(run.main(["no-such-stage"]), 2)


if __name__ == "__main__":
    unittest.main()
