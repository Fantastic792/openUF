"""Fakes for the suite tests: targets that answer SSH from a rule list, a controller, the patches."""
import shutil
import tempfile
from unittest import mock

WLAN = "LabTest"
KEY = "not-a-real-key"


def mac(n):
    return ":".join(["02", "00", "00", "00", "00", f"{n:02x}"])  # made up, and built so no MAC is written here


class FakeTarget:
    """ssh() answers from rules: [(text in the command, (rc, out) or fn(target, cmd, stdin))], first hit wins."""

    def __init__(self, name, lab_n, rules, kind="vm", up=True):
        self.name, self.host, self.kind, self.lab_n, self.rules, self.up = name, "h" + name, kind, lab_n, rules, up
        self.cmds, self.stdin, self.back = [], [], True

    def ssh(self, cmd, timeout=20, stdin=None):
        self.cmds.append(cmd)
        self.stdin.append(stdin)
        for text, answer in self.rules:
            if text in cmd:
                return answer(self, cmd, stdin) if callable(answer) else answer
        return 0, ""

    def ran(self, text):
        return any(text in c for c in self.cmds)

    def reachable(self):
        return self.up

    def wait(self, up, secs):
        return self.back if up else True


class FakeCtl:
    def __init__(self):
        self.puts, self.pushes, self.uplink, self.adopted = [], 0, "wire", True
        self.wlan = {"_id": "w1", "name": WLAN, "security": "wpapsk", "x_passphrase": KEY, "enabled": True}

    def login(self):
        pass

    def wlans(self):
        return [self.wlan]

    def device(self, host):
        return {"_id": "d-" + host, "ip": host, "adopted": self.adopted, "state": 1, "uplink": {"type": self.uplink},
                "mesh_sta_vap_enabled": False}

    def devices(self):
        return []

    def put(self, path, body):
        self.puts.append((path, body))

    def force_push(self, wlan_id):
        self.pushes += 1


def ap_rules(n):
    def pid(t, cmd, stdin):
        return 0, "200\n" if t.ran("kill -9") else "100\n"
    return [("pgrep", pid), ("'^ssid2?='", (0, f'ssid2="{WLAN}"\n')), ("'^ap_isolate=1'", (0, "ap_isolate=1\n")),
            ("mobility_domain", (0, "bss_transition=1\nrrm_neighbor_report=1\nmobility_domain=abcd\n"
                                    "wpa_key_mgmt=WPA-PSK FT-PSK\n")),
            ("scope global", (0, "2: br-lan    inet 198.51.100.2/24 scope global br-lan\n")),
            ("ip route show default", (0, "default via 198.51.100.1 dev br-lan\n")),
            ("print a, $2, s", (0, f"{mac(n)} 36 {WLAN}\n{mac(n + 16)} 1 {WLAN}\n")),
            ("iw dev | awk", (0, mac(n) + "\n")), ("openuf_guest", (0, "ether type ip drop\n")),
            ("openuf_l2guard", (0, "1\n")), ("rx_packets", (0, "1000\n")), ("logread", (0, ""))]


def client_out(vlan_addr="", gap_from=40, gap_to=44, after=2):
    """The file the client's script leaves, by which window ran (read from the script it was sent)."""
    def answer(t, cmd, stdin):
        script = next((s.decode() for s in reversed(t.stdin) if s and b"== end" in s), "")
        if "sleep 30" in script:  # the VLAN window
            return 0, f"== wait\n== addr\n{vlan_addr}\n== ping\n3 packets transmitted, 3 received, 0% packet loss\n== end\n"
        if "wpa_cli" in script:  # the roam window
            seqs = [i for i in range(150) if not gap_from <= i < gap_to]
            ping = "".join(f"64 bytes from x: seq={i} ttl=64\n" for i in seqs) + "150 packets transmitted\n"
            return 0, (f"== before\nConnected to {mac(1)} (on phy1-sta0)\n== ping\n{ping}== after\n"
                       f"Connected to {mac(after)} (on phy1-sta0)\n== wpa\nkey_mgmt=FT-PSK\n== end\n")
        return 0, (f"== link\nConnected to {mac(1)} (on phy1-sta0)\n== addr\n5: phy1-sta0    inet 198.51.100.50/24\n"
                   "== ping\n5 packets transmitted, 5 packets received, 0% packet loss\n== dns\nrc=0\n"
                   '== iperf\n{"end": {"sum_received": {"bits_per_second": 50000000}}}\n'
                   '== down\n{"end": {"sum_received": {"bits_per_second": 4700000}}}\n== end\n')
    return answer


def client_rules(**kw):
    return [("[ -e /opt/openuf/inform.lua ]", (1, "")), ("wireless.radio1.band", (0, "5g\n")), ("cat /tmp/suite-client.out", client_out(**kw)),
            ("ip -4 -o addr show dev", (0, "5: phy1-sta0    inet 198.51.100.50/24\n"))]


class Lab:
    """A fake lab for one test: conf, three targets, a controller, and every patch the suites need."""

    def __init__(self, case, kind="vm", **client_kw):
        self.dir = tempfile.mkdtemp()
        case.addCleanup(shutil.rmtree, self.dir)
        self.conf = {"row_wlan": WLAN, "lab_sh": "/lab/lab.sh", "results_dir": self.dir,
                     "suite": {"wired_ip": "198.51.100.1", "min_mbps": 10, "vlan_host_ip": "203.0.113.1",
                               "vlan_client_ip": "203.0.113.2"}}
        self.t = {"vm1": FakeTarget("vm1", 1, ap_rules(1), kind), "vm2": FakeTarget("vm2", 2, ap_rules(2), kind),
                  "vm3": FakeTarget("vm3", 3, client_rules(**client_kw), kind)}
        self.ctl, self.sh, self.n = FakeCtl(), [], [0]
        for p in (mock.patch("time.sleep"),
                  mock.patch("labtest.target.get_target", side_effect=lambda conf, name: self.t[name]),
                  mock.patch("labtest.suite.common.sh", side_effect=self.fake_sh),
                  mock.patch("labtest.suite.common.wait_for", side_effect=lambda fn, secs, step=5: 0 if fn() else None),
                  mock.patch("labtest.suite.common.subprocess.Popen"),
                  mock.patch("labtest.suite.common.shutil.which", return_value="/usr/bin/iperf3"),
                  mock.patch("labtest.suite.common.results.save"),
                  mock.patch("labtest.table._applied", side_effect=self.version),
                  mock.patch("labtest.safety.plug._connected", return_value=True),
                  mock.patch("labtest.fixtures.make", return_value=("rest/usergroup/1", {})),
                  mock.patch("labtest.fixtures.clean", return_value=0)):
            p.start()
            case.addCleanup(p.stop)

    def version(self, t):  # every look sees a newer cfgversion: a push is applied at once
        self.n[0] += 1
        return self.n[0]

    def fake_sh(self, argv, timeout=300):
        self.sh.append([str(a) for a in argv])
        if "cable" in argv:
            self.ctl.uplink = "wireless" if "down" in argv else "wire"
        return 0, ""

    def ran_sh(self, *words):
        return any(all(w in argv for w in words) for argv in self.sh)


def by_name(result):
    return {c["name"]: c for c in result["checks"]}
