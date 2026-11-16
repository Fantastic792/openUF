import unittest
from unittest import mock

from labtest.suite import multi
from labtest.suite.common import SKIP
from labtest.tests import suite_fakes as fakes


class MultiTest(unittest.TestCase):
    def test_all_checks_pass_on_a_healthy_lab(self):
        lab = fakes.Lab(self)
        r = multi.run(lab.conf, lab.ctl)
        self.assertEqual([c["name"] for c in r["checks"]], multi.NAMES)
        self.assertEqual([c for c in r["checks"] if not c["ok"]], [])
        self.assertTrue(r["pass"])
        self.assertEqual(lab.ctl.pushes, 2)  # the forced push and its way back
        self.assertEqual(lab.sh[-5][-3:], ["cable", "2", "up"])  # then the four air resets
        self.assertEqual(lab.ctl.uplink, "wire")

    def test_roaming_flags_are_set_for_the_run_and_put_back(self):
        lab = fakes.Lab(self)
        multi.run(lab.conf, lab.ctl)
        on = {"fast_roaming_enabled": True, "bss_transition": True, "rrm_enabled": True}
        self.assertEqual(lab.ctl.puts[0], ("rest/wlanconf/w1", on))
        self.assertEqual(lab.ctl.puts[-1], ("rest/wlanconf/w1", {k: False for k in on}))

    def test_the_second_ap_may_mesh_for_the_run_and_is_put_back(self):
        # "Allow meshing to another access point" off = openUF builds no standby station, by design
        lab = fakes.Lab(self)
        multi.run(lab.conf, lab.ctl)
        self.assertEqual([b for p, b in lab.ctl.puts if p == "rest/device/d-hvm2"],
                         [{"mesh_sta_vap_enabled": True}, {"mesh_sta_vap_enabled": False}])

    def test_the_roaming_client_is_not_pinned(self):
        lab = fakes.Lab(self)
        multi.run(lab.conf, lab.ctl)
        sent = next(x.decode() for x in lab.t["vm3"].stdin if x and b"wireless.cl.ssid" in x)
        self.assertNotIn("wireless.cl.bssid", sent)

    def test_failover_waits_for_the_controller_to_show_the_mesh_uplink(self):
        # live, 2026-11-16: the AP was back over the mesh after 32 s, the controller still said "wire"
        lab = fakes.Lab(self)
        real, looks = lab.ctl.device, []

        def device(host):
            d = real(host)
            if lab.ran_sh("cable", "2", "down") and not lab.ran_sh("cable", "2", "up"):
                looks.append(1)
                if len(looks) < 3:
                    d["uplink"] = {"type": "wire"}
            return d
        lab.ctl.device = device
        loop = lambda fn, secs, step=5: next((i for i in range(5) if fn()), None)
        with mock.patch("labtest.suite.common.wait_for", side_effect=loop):
            c = fakes.by_name(multi.run(lab.conf, lab.ctl))
        self.assertTrue(c["mesh_failover"]["ok"], c["mesh_failover"]["detail"])

    def test_hardware_gets_no_mesh_switch(self):
        lab = fakes.Lab(self, kind="hw")
        multi.run(lab.conf, lab.ctl)
        self.assertEqual([p for p, b in lab.ctl.puts if p.startswith("rest/device/")], [])

    def test_a_long_gap_fails_the_roam(self):
        lab = fakes.Lab(self, gap_from=40, gap_to=70)  # 30 lost pings of 0.2 s = 6 s, the limit is 3
        c = fakes.by_name(multi.run(lab.conf, lab.ctl))
        self.assertFalse(c["roam"]["ok"])
        self.assertIn("longest gap 6.0 s", c["roam"]["detail"])

    def test_staying_on_the_first_ap_fails_the_roam(self):
        lab = fakes.Lab(self, after=1)
        c = fakes.by_name(multi.run(lab.conf, lab.ctl))
        self.assertFalse(c["roam"]["ok"])
        self.assertIn("did NOT move", c["roam"]["detail"])

    def test_no_mesh_uplink_fails_the_failover(self):
        lab = fakes.Lab(self)
        lab.ctl.device =lambda host: {"ip": host, "adopted": True, "state": 1, "uplink": {"type": "wire"}}
        c = fakes.by_name(multi.run(lab.conf, lab.ctl))
        self.assertFalse(c["mesh_failover"]["ok"])
        self.assertIn("uplink type wire", c["mesh_failover"]["detail"])

    def test_a_storm_fails_the_loop_guard(self):
        lab = fakes.Lab(self)
        n = [0]

        def rx(t, cmd, stdin):
            n[0] += 100000
            return 0, f"{n[0]}\n"
        lab.t["vm1"].rules.insert(0, ("rx_packets", rx))
        c = fakes.by_name(multi.run(lab.conf, lab.ctl))
        self.assertFalse(c["loop_guard"]["ok"])

    def test_a_missing_bpdu_rule_fails_the_loop_guard(self):
        lab = fakes.Lab(self)
        lab.t["vm2"].rules.insert(0, ("openuf_l2guard", (1, "0\n")))
        self.assertFalse(fakes.by_name(multi.run(lab.conf, lab.ctl))["loop_guard"]["ok"])

    def test_the_cable_goes_back_when_a_check_crashes(self):
        lab = fakes.Lab(self)
        lab.t["vm2"].rules.insert(0, ("openuf_l2guard", lambda t, cmd, stdin: 1 / 0))
        r = multi.run(lab.conf, lab.ctl)
        self.assertFalse(r["pass"])
        self.assertIn("ZeroDivisionError", fakes.by_name(r)["loop_guard"]["detail"])
        self.assertEqual(lab.sh[-5][-3:], ["cable", "2", "up"])

    def test_hardware_skips_air_and_cable_and_never_calls_the_lab(self):
        lab = fakes.Lab(self, kind="hw")
        c = fakes.by_name(multi.run(lab.conf, lab.ctl))
        for name in ("roam", "mesh_failover", "mesh_restore"):
            self.assertTrue(c[name]["detail"].startswith(SKIP), name)
        self.assertEqual(lab.sh, [])

    def test_not_ready_runs_nothing(self):
        lab = fakes.Lab(self)
        lab.t["vm2"].up = False
        r = multi.run(lab.conf, lab.ctl)
        self.assertEqual([(c["name"], c["ok"]) for c in r["checks"]], [("ready", False)])
        self.assertEqual((lab.ctl.puts, lab.ctl.pushes, lab.sh), ([], 0, []))

    def test_the_roam_ping_sends_a_whole_interval_without_a_dot(self):  # busybox ping refuses "-i 1.0"
        lab = fakes.Lab(self)
        lab.conf["suite"]["ping_interval"] = 1.0
        multi.run(lab.conf, lab.ctl)
        script = next(s.decode() for s in lab.t["vm3"].stdin if s and b"wpa_cli" in s)
        self.assertIn("ping -c 30 -i 1 -W", script)


if __name__ == "__main__":
    unittest.main()
