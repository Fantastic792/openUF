import os
import subprocess
import tempfile
import unittest

HEAL = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "safety", "heal.sh")

# every path heal.sh may leave behind, relative to LABTEST_ROOT
PATHS = ["etc/labtest-heal.sh", "etc/labtest-good.tgz", "etc/labtest-healed", "etc/init.d/labtest-heal",
         "tmp/labtest-knock", "tmp/labtest-last", "var/run/labtest-heal.pid", "etc/rc.d/S99labtest-heal"]

STAND_IN = '#!/bin/sh\necho "$1" >> "{log}"\n'


class HealShTest(unittest.TestCase):
    def setUp(self):
        self.r = tempfile.mkdtemp()
        for d in ("etc/config", "etc/init.d", "etc/rc.d", "tmp", "var/run", "bin", "log"):
            os.makedirs(self.p(d))
        self.write("etc/config/network", "good")
        self.write("etc/init.d/openuf", STAND_IN.format(log=self.p("log/openuf")), 0o755)
        self.write("bin/reboot", STAND_IN.format(log=self.p("log/reboot")), 0o755)
        self.uptime(0)

    def p(self, rel):
        return os.path.join(self.r, rel)

    def write(self, rel, text, mode=None):
        with open(self.p(rel), "w") as f:
            f.write(text)
        if mode:
            os.chmod(self.p(rel), mode)

    def read(self, rel):
        with open(self.p(rel)) as f:
            return f.read()

    def lines(self, rel):
        return self.read(rel).splitlines() if os.path.exists(self.p(rel)) else []  # one line per call

    def uptime(self, secs):
        self.write("uptime", f"{secs}.42 {secs * 3}.10\n")

    def sh(self, cmd, **extra):
        env = dict(os.environ, LABTEST_ROOT=self.r, LABTEST_UPTIME_FILE=self.p("uptime"),
                   LABTEST_REBOOT=self.p("bin/reboot"), LABTEST_NO_WATCH="1", **extra)
        return subprocess.run(["sh", HEAL, cmd], env=env, capture_output=True, text=True, timeout=20).returncode

    def heal_now(self):
        self.assertEqual(self.sh("arm"), 0)
        return self.sh("heal")

    def test_arm_saves_config_and_enables_init(self):
        self.assertEqual(self.sh("arm"), 0)
        self.assertTrue(os.path.exists(self.p("etc/labtest-good.tgz")))
        self.assertTrue(os.path.exists(self.p("etc/init.d/labtest-heal")))
        self.assertTrue(os.path.lexists(self.p("etc/rc.d/S99labtest-heal")))
        self.assertFalse(os.path.exists(self.p("etc/labtest-healed")))

    def test_arm_keeps_an_existing_saved_config(self):
        self.sh("arm")
        self.write("etc/config/network", "bad")
        self.sh("arm")
        self.sh("heal")
        self.assertEqual(self.read("etc/config/network"), "good")

    def test_arm_refuses_a_healed_target(self):
        self.write("etc/labtest-healed", "")
        self.assertEqual(self.sh("arm"), 3)
        self.assertFalse(os.path.exists(self.p("etc/init.d/labtest-heal")))

    def test_arm_fails_when_save_fails(self):
        # root ignores a read-only etc/, so block the save with a directory where its temp file goes
        os.makedirs(self.p("etc/labtest-good.tgz.new"))
        self.assertEqual(self.sh("arm"), 1)
        self.assertFalse(os.path.exists(self.p("etc/labtest-good.tgz")))
        self.assertFalse(os.path.exists(self.p("etc/init.d/labtest-heal")))
        self.assertFalse(os.path.lexists(self.p("etc/rc.d/S99labtest-heal")))
        self.assertFalse(os.path.exists(self.p("var/run/labtest-heal.pid")))
        self.assertFalse(os.path.exists(self.p("tmp/labtest-last")))

    def test_knock_resets_the_clock(self):
        self.sh("arm")
        self.uptime(170)
        self.write("tmp/labtest-knock", "")
        self.sh("tick")
        self.assertFalse(os.path.exists(self.p("tmp/labtest-knock")))
        self.uptime(340)
        self.sh("tick")
        self.assertEqual(self.lines("log/reboot"), [])

    def test_no_knock_for_180_does_not_heal_at_180_but_heals_at_181(self):
        self.sh("arm")
        self.uptime(180)
        self.sh("tick")
        self.assertEqual(self.lines("log/reboot"), [])
        self.uptime(181)
        self.sh("tick")
        self.assertEqual(len(self.lines("log/reboot")), 1)

    def test_heal_restores_config_exactly(self):
        self.sh("arm")
        self.write("etc/config/network", "bad")
        self.write("etc/config/extra", "x")
        self.sh("heal")
        self.assertEqual(self.read("etc/config/network"), "good")
        self.assertEqual(os.listdir(self.p("etc/config")), ["network"])
        self.assertFalse(os.path.exists(self.p("etc/config.new")))
        self.assertFalse(os.path.exists(self.p("etc/config.bad")))

    def test_heal_stops_and_disables_openuf(self):
        self.heal_now()
        self.assertEqual(self.lines("log/openuf"), ["stop", "disable"])

    def test_heal_writes_mark_and_reboots(self):
        self.heal_now()
        self.assertTrue(os.path.exists(self.p("etc/labtest-healed")))
        self.assertEqual(len(self.lines("log/reboot")), 1)

    def test_healed_target_never_heals_again(self):
        self.heal_now()
        self.uptime(1000)
        self.sh("boot")
        self.sh("tick")
        self.assertEqual(len(self.lines("log/reboot")), 1)

    def test_old_knock_file_date_does_not_matter(self):
        self.sh("arm")
        self.uptime(170)
        self.write("tmp/labtest-knock", "")
        os.utime(self.p("tmp/labtest-knock"), (978307200, 978307200))  # 2001
        self.sh("tick")
        self.uptime(340)
        self.sh("tick")
        self.assertEqual(self.lines("log/reboot"), [])

    def test_heal_with_corrupt_saved_config(self):
        self.sh("arm")
        self.write("etc/labtest-good.tgz", "junk")
        self.write("etc/config/network", "changed")
        self.sh("heal")
        self.assertEqual(self.read("etc/config/network"), "changed")
        self.assertEqual(self.lines("log/openuf"), ["stop", "disable"])
        self.assertTrue(os.path.exists(self.p("etc/labtest-healed")))
        self.assertEqual(len(self.lines("log/reboot")), 1)
        self.assertFalse(os.path.exists(self.p("etc/config.new")))

    def test_heal_puts_config_back_when_the_second_move_fails(self):
        self.sh("arm")
        self.write("etc/config/network", "bad")
        os.makedirs(self.p("fakebin"))
        self.write("fakebin/mv", '#!/bin/sh\ncase $1 in *config.new) exit 1 ;; esac\nexec /bin/mv "$@"\n', 0o755)
        self.sh("heal", PATH=self.p("fakebin") + os.pathsep + os.environ["PATH"])
        self.assertEqual(self.read("etc/config/network"), "bad")
        self.assertFalse(os.path.exists(self.p("etc/config.bad")))
        self.assertEqual(len(self.lines("log/reboot")), 1)

    def test_heal_goes_on_when_openuf_stop_hangs(self):
        self.write("etc/init.d/openuf", f'#!/bin/sh\necho "$1" >> "{self.p("log/openuf")}"\n'
                   '[ "$1" = stop ] && exec sleep 1000\nexit 0\n', 0o755)
        self.sh("arm")
        self.write("etc/config/network", "bad")
        self.sh("heal", LABTEST_STOP_WAIT="1")
        self.assertEqual(self.read("etc/config/network"), "good")
        self.assertEqual(self.lines("log/openuf"), ["stop", "disable"])
        self.assertEqual(len(self.lines("log/reboot")), 1)

    def test_heal_switches_off_its_boot_start_even_if_the_mark_fails(self):
        self.sh("arm")
        os.makedirs(self.p("etc/labtest-healed"))  # writing the mark now fails
        self.sh("heal")
        self.assertFalse(os.path.exists(self.p("etc/init.d/labtest-heal")))
        self.assertFalse(os.path.lexists(self.p("etc/rc.d/S99labtest-heal")))

    def test_boot_gives_a_fresh_window(self):
        self.uptime(500)
        self.assertEqual(self.sh("boot"), 0)
        self.assertEqual(self.read("tmp/labtest-last").strip(), "500")

    def test_boot_on_healed_target_does_nothing(self):
        self.write("etc/labtest-healed", "")
        self.assertEqual(self.sh("boot"), 0)
        self.assertFalse(os.path.exists(self.p("tmp/labtest-last")))

    def test_disarm_leaves_nothing(self):
        self.sh("arm")
        self.write("etc/labtest-heal.sh", "")
        self.write("tmp/labtest-knock", "")
        self.write("etc/labtest-healed", "")
        self.write("var/run/labtest-heal.pid", "999999")
        self.assertEqual(self.sh("disarm"), 0)
        self.assertEqual([p for p in PATHS if os.path.lexists(self.p(p))], [])
        self.assertEqual(self.read("etc/config/network"), "good")


if __name__ == "__main__":
    unittest.main()
