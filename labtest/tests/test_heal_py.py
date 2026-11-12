import time
import unittest

from labtest.safety import heal


class FakeTarget:
    def __init__(self, answers=None, kind="vm"):
        self.name, self.kind, self.answers, self.cmds, self.puts = "fake", kind, answers or {}, [], []

    def ssh(self, cmd, timeout=20, stdin=None):
        self.cmds.append(cmd)
        for key, ans in self.answers.items():
            if key in cmd:
                return ans
        return 0, ""

    def put(self, local, remote, mode="755"):
        self.puts.append((local, remote))


class HealPyTest(unittest.TestCase):
    def test_arm_puts_the_script_then_runs_arm(self):
        t = FakeTarget()
        heal.arm(t)
        self.assertTrue(t.puts[0][0].endswith("labtest/safety/heal.sh"))
        self.assertEqual(t.puts[0][1], "/etc/labtest-heal.sh")
        self.assertEqual(t.cmds, ["/etc/labtest-heal.sh arm"])

    def test_arm_raises_with_output_on_failure(self):
        t = FakeTarget({"arm": (3, "refused: healed mark")})
        with self.assertRaises(RuntimeError) as e:
            heal.arm(t)
        self.assertIn("healed", str(e.exception))

    def test_knocker_knocks_and_survives_a_dead_target(self):
        t = FakeTarget({"touch": (255, "")})
        with heal.Knocker(t, every=0.05):
            time.sleep(0.3)
        self.assertGreaterEqual(t.cmds.count("touch /tmp/labtest-knock"), 3)

    def test_knocker_stops_on_exit(self):
        t = FakeTarget()
        with heal.Knocker(t, every=0.05):
            time.sleep(0.1)
        n = len(t.cmds)
        time.sleep(0.2)
        self.assertEqual(len(t.cmds), n)

    def test_healed_reads_the_mark(self):
        self.assertTrue(heal.healed(FakeTarget({"labtest-healed": (0, "")})))
        self.assertFalse(heal.healed(FakeTarget({"labtest-healed": (1, "")})))

    def test_disarm_reports_leftovers(self):
        t = FakeTarget({"disarm": (2, "/etc/labtest-good.tgz\n")})
        self.assertEqual(heal.disarm(t), ["/etc/labtest-good.tgz"])
        self.assertIn("/etc/labtest-heal.sh disarm", t.cmds[0])

    def test_disarm_on_unreachable_target_raises(self):
        with self.assertRaises(RuntimeError):
            heal.disarm(FakeTarget({"disarm": (255, "")}))


if __name__ == "__main__":
    unittest.main()
