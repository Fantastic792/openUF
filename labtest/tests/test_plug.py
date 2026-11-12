import io
import time
import unittest
from unittest import mock

from labtest.safety import plug
from labtest.tests.test_heal_py import FakeTarget


class FakeWatch:
    """Stands in for ApplyWatch: start_after = None means no apply start is ever seen."""
    done = False
    start_after = 0.0

    def __init__(self, t):
        pass

    def wait_ready(self, secs):
        return True

    def wait_start(self, secs):
        return None if self.start_after is None else time.monotonic() + self.start_after

    def done_before(self, ts):
        return self.done

    def stop(self):
        pass


def lab_target():
    t = FakeTarget()
    t.host, t.lab_n, t.wait = "198.51.100.7", 1, lambda up, secs: True
    return t


def controller(state):
    ctl = mock.Mock()
    ctl.wlans.side_effect = lambda: [{"_id": "w1", "uapsd_enabled": state["v"]}]
    ctl.force_push.side_effect = lambda _id: state.update(v=not state["v"])
    ctl.devices.return_value = [{"ip": "198.51.100.7", "state": 1}]
    return ctl


class PlugTest(unittest.TestCase):
    def run_plug(self, watch, state=None):
        state = state if state is not None else {"v": False}
        with mock.patch("subprocess.run") as run, mock.patch("time.sleep"), \
                mock.patch("labtest.results.save", return_value="x"):
            r = plug.run({"lab_sh": "/x/lab.sh"}, lab_target(), controller(state), watch=watch)
        return r, run, state

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

    def test_file_empty_before_the_cuts_is_not_a_problem(self):
        # openUF's installers create /etc/config/openuf empty on purpose; uci reads it fine
        t = FakeTarget({"uci": (0, "EMPTY /etc/config/openuf\nEMPTY /etc/openuf/state\n")})
        p = plug.config_problems(t, known_empty={"/etc/config/openuf"})
        self.assertEqual(p, ["zero-length file /etc/openuf/state"])

    def test_empty_files_lists_zero_length_files(self):
        t = FakeTarget({"find": (0, "/etc/config/openuf\n")})
        self.assertEqual(plug.empty_files(t), {"/etc/config/openuf"})

    def test_config_problems_unreachable_is_a_problem(self):
        self.assertEqual(len(plug.config_problems(FakeTarget({"uci": (255, "")}))), 1)

    def test_offsets_include_zero_and_sub_second(self):
        self.assertIn(0, plug.OFFSETS)
        self.assertTrue(any(0 < o < 1 for o in plug.OFFSETS))

    def test_cut_inside_the_apply_records_offset_and_mid_apply(self):
        r, run, _ = self.run_plug(type("W", (FakeWatch,), {"done": False}))
        self.assertTrue(r["pass"], r)
        self.assertEqual([c["offset"] for c in r["cuts"]], plug.OFFSETS)
        for c in r["cuts"]:
            self.assertTrue(c["apply_seen"])
            self.assertTrue(c["mid_apply"])
            self.assertIsNotNone(c["cut_ms"])

    def test_no_apply_start_is_a_fail_with_a_reason_and_no_cut(self):
        r, run, _ = self.run_plug(type("W", (FakeWatch,), {"start_after": None}))
        self.assertFalse(r["pass"])
        for c in r["cuts"]:
            self.assertFalse(c["apply_seen"])
            self.assertIn("no apply start", c["error"])
        self.assertFalse(any("stop" in call.args[0] for call in run.call_args_list))

    def test_pass_needs_at_least_one_cut_inside_the_apply(self):
        # every cut after the apply had finished proves only "a cut while idle is safe"
        r, _, _ = self.run_plug(type("W", (FakeWatch,), {"done": True}))
        self.assertFalse(r["pass"])
        self.assertFalse(any(c["mid_apply"] for c in r["cuts"]))

    def test_uapsd_is_put_back_after_the_cuts(self):
        state = {"v": False}
        self.run_plug(FakeWatch, state)
        self.assertIs(state["v"], False)


class ApplyWatchTest(unittest.TestCase):
    def watch(self, text):
        with mock.patch("subprocess.Popen") as popen:
            popen.return_value.stdout = io.StringIO(text)
            t = lab_target()
            t._argv = lambda cmd: ["ssh", cmd]
            w = plug.ApplyWatch(t)
        self.assertTrue(w.wait_ready(2))
        lines = len(text.splitlines()) - 1
        for _ in range(200):  # let the reader thread take every line
            if len(w.events) == lines:
                break
            time.sleep(0.01)
        return w

    def test_start_is_the_wireless_write(self):
        w = self.watch("READY\nS 10.00\nW 10.02\nS 10.30\n")
        start = w.wait_start(2)
        self.assertIsNotNone(start)
        self.assertTrue(w.done_before(time.monotonic() + 1))

    def test_not_done_when_the_end_record_was_not_seen(self):
        w = self.watch("READY\nS 10.00\nW 10.02\n")
        self.assertIsNotNone(w.wait_start(2))
        self.assertFalse(w.done_before(time.monotonic() + 1))

    def test_state_write_alone_is_not_an_apply_start(self):
        w = self.watch("READY\nS 10.00\n")
        self.assertIsNone(w.wait_start(0.2))


if __name__ == "__main__":
    unittest.main()
