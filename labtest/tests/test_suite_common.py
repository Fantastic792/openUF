import os
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock

from labtest.suite import common
from labtest.tests import suite_fakes as fakes


class ParserTest(unittest.TestCase):
    def test_mbps_reads_the_received_rate(self):
        text = 'warning line\n{"end": {"sum_received": {"bits_per_second": 93500000.0}}}'
        self.assertEqual(common.mbps(text), 93.5)

    def test_mbps_is_none_on_an_error_or_no_json(self):
        self.assertIsNone(common.mbps('{"error": "unable to connect"}'))
        self.assertIsNone(common.mbps("iperf3: not found"))

    def test_loss(self):
        self.assertEqual(common.loss("5 packets transmitted, 4 packets received, 20% packet loss"), 20)
        self.assertIsNone(common.loss("ping: sendto: Network unreachable"))

    def test_gap_busybox_counts_from_zero(self):
        text = "".join(f"64 bytes from x: seq={i} ttl=64\n" for i in (0, 1, 2, 7, 8)) + "10 packets transmitted\n"
        self.assertEqual(common.gap(text, 0.2), 0.8)  # seq 3..6 lost: 4 pings of 0.2 s

    def test_gap_sees_a_hole_at_the_start_and_the_end(self):
        text = "64 bytes from x: seq=5 ttl=64\n10 packets transmitted\n"
        self.assertEqual(common.gap(text, 1), 5)  # 0..4 lost before, 6..9 lost after: the longer is 5

    def test_gap_iputils_counts_from_one(self):
        text = "".join(f"64 bytes from x: icmp_seq={i} ttl=64\n" for i in (1, 2, 3)) + "3 packets transmitted\n"
        self.assertEqual(common.gap(text, 1), 0)

    def test_gap_is_none_without_a_reply(self):
        self.assertIsNone(common.gap("10 packets transmitted, 0 packets received", 0.2))

    def test_bssid(self):
        self.assertEqual(common.bssid(f"Connected to {fakes.mac(1).upper()} (on phy1-sta0)"), fakes.mac(1))
        self.assertIsNone(common.bssid("Not connected."))

    def test_sections(self):
        self.assertEqual(common.sections("noise\n== a\n1\n2\n== b\n== end\n"), {"a": "1\n2\n", "b": "", "end": ""})


class ConfigTest(unittest.TestCase):
    def test_cfg_needs_the_wired_address(self):
        with self.assertRaises(SystemExit):
            common.cfg({})

    def test_cfg_fills_defaults(self):
        s = common.cfg({"suite": {"wired_ip": "198.51.100.1", "client": "vm9"}})
        self.assertEqual((s["client"], s["ap1"], s["min_mbps"]), ("vm9", "vm1", 0))

    def test_cfg_gives_a_whole_ping_interval_without_a_dot(self):  # busybox ping refuses "-i 1.0"
        s = common.cfg({"suite": {"wired_ip": "198.51.100.1", "ping_interval": 1.0}})
        self.assertEqual((f"{s['ping_interval']}", f"{common.cfg({'suite': {'wired_ip': 'x'}})['ping_interval']}"),
                         ("1", "0.2"))


class WindowTest(unittest.TestCase):
    def test_script_takes_the_cable_down_and_always_brings_it_back(self):
        s = dict(common.DEFAULTS, wired_ip="198.51.100.1")
        lines = common.script(s, [("ping", "ping -c 1 x")], 55).splitlines()
        self.assertIn("trap 'up; kill $W 2>/dev/null' EXIT", lines)
        self.assertIn("( sleep 55; up ) &", lines)  # the watchdog
        self.assertIn("up() { ip link set br-lan up; ip link set eth0 up; }", lines)
        self.assertLess(lines.index("ip link set eth0 down"), lines.index("ping -c 1 x"))
        self.assertLess(lines.index("trap 'up; kill $W 2>/dev/null' EXIT"), lines.index("ip link set eth0 down"))
        self.assertEqual(lines[-1], "echo '== end'")

    def test_ssids_reads_both_spellings(self):  # OpenWrt writes ssid2="name", older builds ssid=name
        t = fakes.FakeTarget("vm1", 1, [("'^ssid2?='", (0, 'ssid2="A B"\nssid=C\nssid2="A B"\n'))])
        self.assertEqual(common.ssids(t), ["A B", "C"])

    def test_join_joins_afresh_and_keeps_the_cable_routes_first(self):
        # a station whose AP rebooted sits on a dead link; with equal metrics its replies leave by that link
        s = dict(common.DEFAULTS, wired_ip="198.51.100.1")
        t = fakes.FakeTarget("vm3", 3, fakes.client_rules())
        with mock.patch("time.sleep"):
            common.join(s, t, {"name": "x", "x_passphrase": fakes.KEY})
        sent = next(x for x in t.stdin if x).decode()
        self.assertIn("set network.wwan.metric=100", sent)
        self.assertIn("wifi down radio1", sent)
        self.assertLess(sent.index("wifi down radio1"), sent.index("wifi up radio1"))

    def test_the_watchdog_dies_with_the_script(self):
        # live, 2026-11-16: a watchdog left alive fired inside the NEXT window and put the cable back in the
        # middle of a measurement (1500 Mbit/s "over WiFi"). Runs the real script with a fake ip and a fast sleep.
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        for name, body in (("ip", f'echo "$*" >> {d}/log'),
                           ("sleep", 'exec /bin/sleep $(awk "BEGIN {print $1 / 20}")')):
            with open(f"{d}/{name}", "w") as f:
                f.write("#!/bin/sh\n" + body + "\n")
            os.chmod(f"{d}/{name}", 0o755)
        s = dict(common.DEFAULTS, wired_ip="198.51.100.1")
        subprocess.run(["sh", "-c", common.script(s, [("x", "true")], 20)], check=True,
                       env={"PATH": f"{d}:/usr/bin:/bin"}, stdout=subprocess.DEVNULL)
        time.sleep(1.5)  # the watchdog's 20 s are 1 s here
        with open(f"{d}/log") as f:
            self.assertEqual(f.read().count("link set eth0 up"), 1)

    def test_ap_bssid_is_the_bss_of_that_ssid_on_the_clients_band(self):
        s = dict(common.DEFAULTS, wired_ip="198.51.100.1")
        ap, client = fakes.FakeTarget("vm1", 1, fakes.ap_rules(1)), fakes.FakeTarget("vm3", 3, fakes.client_rules())
        self.assertEqual(common.ap_bssid(s, ap, client, {"name": fakes.WLAN}), fakes.mac(1))
        self.assertIsNone(common.ap_bssid(s, ap, client, {"name": "another"}))

    def test_join_pins_the_bssid_when_given_one_and_drops_an_old_pin(self):
        s = dict(common.DEFAULTS, wired_ip="198.51.100.1")
        t = fakes.FakeTarget("vm3", 3, fakes.client_rules())
        with mock.patch("time.sleep"):
            common.join(s, t, {"name": "x", "x_passphrase": fakes.KEY}, bssid=fakes.mac(1))
            common.join(s, t, {"name": "x", "x_passphrase": fakes.KEY})
        pinned, free = [x.decode() for x in t.stdin if x]
        self.assertIn(f"set wireless.cl.bssid={fakes.mac(1)}", pinned)
        self.assertNotIn("wireless.cl.bssid", free)
        self.assertIn("delete wireless.cl", free)  # a pin an earlier run left goes with the old section

    def test_ready_says_so_when_the_controller_answers_no_json(self):
        lab = fakes.Lab(self)

        def device(host):
            raise ValueError("Expecting value: line 1 column 1 (char 0)")
        lab.ctl.device = device
        bad = common.ready(lab.conf, common.cfg(lab.conf), lab.ctl, ("ap1", "client"))
        self.assertEqual(len(bad), 1)
        self.assertIn("the controller does not answer", bad[0])

    def test_wifi_only_raises_when_the_client_stays_away(self):
        s = dict(common.DEFAULTS, wired_ip="198.51.100.1")
        t = fakes.FakeTarget("vm3", 3, [])
        t.back = False
        with mock.patch("time.sleep"), self.assertRaises(common.ClientLost):
            common.wifi_only(s, t, [("x", "true")], 5)

    def test_join_keeps_the_key_off_the_command_line(self):
        s = dict(common.DEFAULTS, wired_ip="198.51.100.1")
        t = fakes.FakeTarget("vm3", 3, fakes.client_rules())
        with mock.patch("time.sleep"):
            self.assertIsNotNone(common.join(s, t, {"name": "Lab's Net", "x_passphrase": fakes.KEY}))
        self.assertFalse(any(fakes.KEY in c for c in t.cmds))
        sent = next(x for x in t.stdin if x).decode()
        self.assertIn(f"set wireless.cl.key='{fakes.KEY}'", sent)
        self.assertIn("set wireless.cl.ssid='Lab'\\''s Net'", sent)  # a quote in the SSID is escaped


class ChecksTest(unittest.TestCase):
    def test_a_crashing_check_fails_and_the_next_still_runs(self):
        def boom():
            raise ValueError("x")
        out = common.run_checks([("a", boom), ("b", lambda: (True, "fine"))])
        self.assertEqual([(c["name"], c["ok"]) for c in out], [("a", False), ("b", True)])
        self.assertIn("ValueError", out[0]["detail"])

    def test_a_lost_client_stops_the_run(self):
        def lost():
            raise common.ClientLost("gone")
        out = common.run_checks([("a", lost), ("b", lambda: (True, ""))])
        self.assertEqual([(c["name"], c["ok"], c["detail"]) for c in out], [("a", False, "gone")])

    def test_flip_puts_the_old_values_back_even_on_an_error(self):
        ctl = fakes.FakeCtl()
        with self.assertRaises(RuntimeError):
            with common.flip(ctl, ctl.wlan, {"is_guest": True}):
                raise RuntimeError("x")
        self.assertEqual([b for _, b in ctl.puts], [{"is_guest": True}, {"is_guest": False}])

    def test_flip_does_nothing_when_already_set(self):
        ctl = fakes.FakeCtl()
        ctl.wlan["is_guest"] = True
        with common.flip(ctl, ctl.wlan, {"is_guest": True}) as changed:
            self.assertFalse(changed)
        self.assertEqual(ctl.puts, [])

    def test_ready_lists_every_reason_and_changes_nothing(self):
        lab = fakes.Lab(self)
        lab.ctl.adopted = False
        lab.t["vm3"].rules.insert(0, ("[ -e /opt/openuf/inform.lua ]", (0, "")))
        bad = common.ready(lab.conf, common.cfg(lab.conf), lab.ctl, ("ap1", "client"))
        self.assertEqual(len(bad), 2)
        self.assertIn("vm1 is not adopted", bad[0])
        self.assertIn("vm3 has openUF installed", bad[1])
        self.assertEqual(lab.ctl.puts, [])


if __name__ == "__main__":
    unittest.main()
