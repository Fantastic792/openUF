import unittest
from unittest import mock

from labtest.safety import plug
from labtest.tests.test_heal_py import FakeTarget


class PlugTest(unittest.TestCase):
    def test_plug_refuses_hardware(self):
        ctl = mock.Mock()
        with self.assertRaises(SystemExit):
            plug.run({}, FakeTarget(kind="hw"), ctl)
        self.assertEqual(ctl.method_calls, [])

    def test_config_problems_names_each_fault(self):
        t = FakeTarget({"uci": (0, "BAD /etc/config/wireless\nEMPTY /etc/openuf/state\nNOTRUNNING\n")})
        p = plug.config_problems(t)
        self.assertEqual(len(p), 3)
        self.assertIn("/etc/config/wireless", p[0])
        self.assertIn("/etc/openuf/state", p[1])
        self.assertIn("openuf not running", p[2])

    def test_config_problems_empty_when_clean(self):
        self.assertEqual(plug.config_problems(FakeTarget({"uci": (0, "")})), [])

    def test_config_problems_unreachable_is_a_problem(self):
        self.assertEqual(len(plug.config_problems(FakeTarget({"uci": (255, "")}))), 1)

    def test_uapsd_is_put_back_after_the_cuts(self):
        # four flips would leave it as it was; one more (as first planned) would not
        state = {"v": False}
        ctl = mock.Mock()
        ctl.wlans.side_effect = lambda: [{"_id": "w1", "uapsd_enabled": state["v"]}]
        ctl.force_push.side_effect = lambda _id: state.update(v=not state["v"])
        ctl.devices.return_value = [{"ip": "198.51.100.7", "state": 1}]
        t = FakeTarget()
        t.host, t.lab_n, t.wait = "198.51.100.7", 1, lambda up, secs: True
        with mock.patch("subprocess.run"), mock.patch("time.sleep"), \
                mock.patch("labtest.results.save", return_value="x"):
            r = plug.run({"lab_sh": "/x/lab.sh"}, t, ctl)
        self.assertTrue(r["pass"], r)
        self.assertIs(state["v"], False)


if __name__ == "__main__":
    unittest.main()
