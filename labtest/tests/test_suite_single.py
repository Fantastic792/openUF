import unittest

from labtest.suite import single
from labtest.suite.common import SKIP
from labtest.tests import suite_fakes as fakes


class SingleTest(unittest.TestCase):
    def test_all_checks_pass_on_a_healthy_lab(self):
        lab = fakes.Lab(self)
        r = single.run(lab.conf, lab.ctl)
        self.assertEqual([c["name"] for c in r["checks"]], single.NAMES)
        self.assertEqual([c for c in r["checks"] if not c["ok"]], [])
        self.assertTrue(r["pass"])
        self.assertFalse(any(c["detail"].startswith(SKIP) for c in r["checks"]))
        self.assertTrue(lab.t["vm3"].ran("uci -q delete wireless.cl"))  # the client is put back

    def test_not_ready_runs_nothing(self):
        lab = fakes.Lab(self)
        lab.t["vm1"].up = False
        r = single.run(lab.conf, lab.ctl)
        self.assertEqual([(c["name"], c["ok"]) for c in r["checks"]], [("ready", False)])
        self.assertIn("vm1 is not reachable", r["checks"][0]["detail"])
        self.assertFalse(lab.t["vm1"].ran("reboot"))
        self.assertFalse(r["pass"])

    def test_no_floor_means_the_speed_checks_say_skipped(self):
        lab = fakes.Lab(self)
        lab.conf["suite"]["min_mbps"] = 0
        c = fakes.by_name(single.run(lab.conf, lab.ctl))
        self.assertTrue(c["throughput"]["detail"].startswith(SKIP))
        self.assertTrue(c["rate_limit"]["detail"].startswith(SKIP))

    def test_throughput_under_the_floor_fails(self):
        lab = fakes.Lab(self)
        lab.conf["suite"]["min_mbps"] = 80  # the fake client measures 50
        c = fakes.by_name(single.run(lab.conf, lab.ctl))
        self.assertFalse(c["throughput"]["ok"])
        self.assertIn("50.0 Mbit/s", c["throughput"]["detail"])

    def test_an_untagged_address_on_the_vlan_fails_isolation(self):
        lab = fakes.Lab(self, vlan_addr="5: phy1-sta0    inet 198.51.100.77/24")
        c = fakes.by_name(single.run(lab.conf, lab.ctl))
        self.assertTrue(c["vlan_tag"]["ok"])
        self.assertFalse(c["vlan_isolation"]["ok"])

    def test_the_host_vlan_interface_is_removed_again(self):
        lab = fakes.Lab(self)
        single.run(lab.conf, lab.ctl)
        self.assertTrue(lab.ran_sh("ip", "link", "add", "br-lab.77"))
        self.assertTrue(lab.ran_sh("ip", "link", "del", "br-lab.77"))

    def test_hardware_never_stops_a_controller(self):
        lab = fakes.Lab(self, kind="hw")
        c = fakes.by_name(single.run(lab.conf, lab.ctl))
        self.assertTrue(c["controller_recovery"]["detail"].startswith(SKIP))
        self.assertFalse(lab.ran_sh("docker"))

    def test_a_lost_client_stops_the_run_and_still_cleans_up(self):
        lab = fakes.Lab(self)
        lab.t["vm3"].back = False
        r = single.run(lab.conf, lab.ctl)
        self.assertEqual(r["checks"][-1]["name"], "client_join")
        self.assertFalse(r["pass"])
        self.assertTrue(lab.t["vm3"].ran("uci -q delete wireless.cl"))

    def test_dns_asks_the_server_the_client_got_over_dhcp(self):
        # OpenWrt's own dnsmasq on the client never forwards a plain name: the question must cross the AP
        lab = fakes.Lab(self)
        single.run(lab.conf, lab.ctl)
        script = next(s.decode() for s in lab.t["vm3"].stdin if s and b"== dns" in s)
        self.assertIn("resolv.conf.auto", script)

    def test_mgmt_fails_without_a_default_route(self):  # busybox prints every route for "show default"
        lab = fakes.Lab(self)
        lab.t["vm1"].rules.insert(0, ("ip route show default", (0, "198.51.100.0/24 dev br-lan scope link\n")))
        c = fakes.by_name(single.run(lab.conf, lab.ctl))
        self.assertFalse(c["mgmt"]["ok"])
        self.assertEqual(c["mgmt"]["detail"], "default route: none")

    def test_a_controller_that_is_still_starting_is_waited_for(self):
        # live, 2026-11-16: a starting controller answers with a page that is not JSON; login raised ValueError
        lab = fakes.Lab(self)
        calls = []

        def login():
            calls.append(1)
            if len(calls) > 1:
                raise ValueError("Expecting value: line 1 column 1 (char 0)")
        lab.ctl.login = login
        c = fakes.by_name(single.run(lab.conf, lab.ctl))
        self.assertFalse(c["controller_recovery"]["ok"])
        self.assertIn("controller back after None s", c["controller_recovery"]["detail"])

    def test_the_client_is_pinned_to_the_ap_under_test(self):
        # live, 2026-11-16: after the AP's reboot the client joined the lab's other AP, which has the same SSID
        lab = fakes.Lab(self)
        single.run(lab.conf, lab.ctl)
        sent = next(x.decode() for x in lab.t["vm3"].stdin if x and b"wireless.cl.ssid" in x)
        self.assertIn(f"set wireless.cl.bssid={fakes.mac(1)}", sent)

    def test_a_restarted_controller_that_answers_no_json_is_waited_for(self):
        # live, 2026-11-16: the login worked, the device list was not JSON yet
        lab = fakes.Lab(self)
        real = lab.ctl.device

        def device(host):
            if lab.ran_sh("docker", "start"):
                raise ValueError("Expecting value: line 1 column 1 (char 0)")
            return real(host)
        lab.ctl.device = device
        c = fakes.by_name(single.run(lab.conf, lab.ctl))
        self.assertFalse(c["controller_recovery"]["ok"])
        self.assertIn("NOT connected", c["controller_recovery"]["detail"])

    def test_wlan_flags_are_put_back(self):
        lab = fakes.Lab(self)
        single.run(lab.conf, lab.ctl)
        bodies = [b for p, b in lab.ctl.puts if p == "rest/wlanconf/w1"]
        self.assertEqual(bodies, [{"is_guest": True}, {"is_guest": False},
                                  {"l2_isolation": True}, {"l2_isolation": False}])


if __name__ == "__main__":
    unittest.main()
