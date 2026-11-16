"""Parts the single and multi suites share: the suite config, parsers, the WiFi-only client window."""
import contextlib
import json
import re
import shutil
import subprocess
import time

from labtest import results, table, target

# names only; every address the suite needs comes from the lab's config file, block "suite"
DEFAULTS = {"ap1": "vm1", "ap2": "vm2", "client": "vm3", "client_if": "phy1-sta0", "client_radio": "radio1",
            "client_down": "eth0 br-lan", "dns_name": "vm1", "host_if": "br-lab",
            "controller_container": "lab-unifi", "min_mbps": 0, "roam_max_s": 3, "ping_interval": 0.2,
            "storm_max_pps": 500}
OUT = "/tmp/suite-client.out"
SKIP = "SKIPPED: "
VLAN = 77  # the vlan of fixtures' NetworkConf
HOSTAPD = "/var/run/hostapd-phy*.conf"


class ClientLost(RuntimeError):
    """The client did not come back on its cable after a WiFi-only window."""


def cfg(conf):
    s = dict(DEFAULTS, **conf.get("suite", {}))
    if not s.get("wired_ip"):
        raise SystemExit("labtest: the config has no suite.wired_ip (the address a WiFi client reaches by cable)")
    iv = float(s["ping_interval"])
    s["ping_interval"] = int(iv) if iv == int(iv) else iv  # busybox ping refuses "-i 1.0"
    return s


def mbps(text):
    """Received Mbit/s of one `iperf3 -J` run, or None."""
    try:
        return round(json.loads(text[text.index("{"):])["end"]["sum_received"]["bits_per_second"] / 1e6, 2)
    except (ValueError, KeyError, TypeError):
        return None


def loss(text):
    m = re.search(r"(\d+)% packet loss", text)
    return int(m.group(1)) if m else None


def gap(text, interval):
    """The longest run of lost pings in seconds, or None when no reply came at all."""
    seqs = sorted({int(n) for n in re.findall(r"seq=(\d+)", text)})
    if not seqs:
        return None
    first = 1 if "icmp_seq=" in text else 0  # iputils counts from 1, busybox from 0
    sent = re.search(r"(\d+) packets transmitted", text)
    last = first + int(sent.group(1)) - 1 if sent else seqs[-1]
    holes = [b - a - 1 for a, b in zip([first - 1] + seqs, seqs + [last + 1])]
    return round(max(holes) * interval, 2)


def bssid(text):
    m = re.search(r"Connected to ([0-9a-fA-F:]{17})", text)
    return m.group(1).lower() if m else None


def sections(text):
    """{name: text} for the '== name' marks the client script prints."""
    out, name = {}, None
    for line in text.splitlines():
        if line.startswith("== "):
            name = line[3:].strip()
            out[name] = ""
        elif name is not None:
            out[name] += line + "\n"
    return out


def sh(argv, timeout=300):
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    return p.returncode, (p.stdout or b"").decode(errors="replace")


def lab(conf, *args):
    return sh(["sh", conf["lab_sh"]] + [str(a) for a in args])


def wait_for(fn, secs, step=5):
    """Seconds until fn() is true, or None after secs."""
    start = time.monotonic()
    while True:
        if fn():
            return round(time.monotonic() - start)
        if time.monotonic() - start >= secs:
            return None
        time.sleep(step)


def script(s, cmds, hold):
    """The client's WiFi-only script: cable down, the commands, cable up again whatever happens."""
    down = s["client_down"].split()
    up = "; ".join(f"ip link set {d} up" for d in reversed(down))
    head = ["#!/bin/sh", f"IF={s['client_if']}", f"up() {{ {up}; }}",
            f"( sleep {hold}; up ) &",  # watchdog: the cable comes back even when a command hangs
            "W=$!",
            # the watchdog dies with the script: left alive it fires inside the NEXT window and puts the cable back
            "trap 'up; kill $W 2>/dev/null' EXIT", "trap 'exit 1' INT TERM",
            "sleep 2"] + [f"ip link set {d} down" for d in down] + \
           ["sleep 3", "A=$(ip -4 -o addr show dev $IF | awk '{print $4}' | cut -d/ -f1)"]
    body = [line for name, cmd in cmds for line in (f"echo '== {name}'", cmd)]
    return "\n".join(head + body + ["echo '== end'"]) + "\n"


def wifi_only(s, client, cmds, secs, during=None, at=10):
    """Run cmds [(name, shell)] on the client with its cable down, so its traffic can only leave by WiFi.
    `during` is called `at` seconds in (the roam check moves the air then). Returns sections()."""
    hold = secs + 30
    rc, out = client.ssh("cat > /tmp/suite-client.sh", stdin=script(s, cmds, hold).encode())
    if rc != 0:
        raise RuntimeError(f"could not write the client script on {client.name}: {out.strip()[-100:]}")
    client.ssh(f"rm -f {OUT}; (sh /tmp/suite-client.sh > {OUT} 2>&1 </dev/null &)")
    if during:
        time.sleep(at)
        during()
        time.sleep(max(0, secs - at))
    else:
        time.sleep(secs)
    if not client.wait(True, hold + 60):
        raise ClientLost(f"{client.name} is not back on its cable {hold + 60} s after the WiFi-only window")
    wait_for(lambda: "== end" in client.ssh(f"cat {OUT}")[1], 30)
    return sections(client.ssh(f"cat {OUT}")[1])


def wlan(conf, ctl):
    return next((w for w in ctl.wlans() if w.get("name") == conf["row_wlan"]), None)


def _q(v):
    return "'" + str(v).replace("'", "'\\''") + "'"


def ap_bssid(s, ap, client, w):
    """The BSSID of WLAN w on ap, on the band of the client's radio, or None."""
    five = client.ssh(f"uci -q get wireless.{s['client_radio']}.band")[1].strip() != "2g"
    out = ap.ssh("iw dev | awk '$1 == \"addr\" {a = $2} $1 == \"ssid\" {s = substr($0, index($0, $2))} "
                 "$1 == \"channel\" {print a, $2, s}'")[1]
    for line in out.splitlines():
        p = line.split(None, 2)
        # shortcut: channel > 14 = 5 GHz; a 6 GHz client radio needs the frequency, add it then
        if len(p) == 3 and p[2] == w["name"] and p[1].isdigit() and (int(p[1]) > 14) == five:
            return p[0].lower()
    return None


def join(s, client, w, bssid=None, ft=False):
    """Make the client a WPA2 station of WLAN w (of that one BSSID when given: a second AP in range has the
    same SSID). The key goes over SSH's stdin, never on a command line."""
    radio = s["client_radio"]
    pin = ([f"set wireless.cl.bssid={bssid}"] if bssid else []) + (["set wireless.cl.ieee80211r=1"] if ft else [])
    text = "\n".join(["uci -q delete wireless.cl",  # an old section, and the pin it may hold, goes first
                      "uci -q batch <<EOF", "set network.wwan=interface", "set network.wwan.proto=dhcp",
                      "set network.wwan.metric=100",  # the cable's routes win whenever the cable is up
                      "set wireless.cl=wifi-iface", f"set wireless.cl.device={radio}",
                      "set wireless.cl.mode=sta", "set wireless.cl.network=wwan",
                      f"set wireless.cl.ssid={_q(w['name'])}", "set wireless.cl.encryption=psk2",
                      f"set wireless.cl.key={_q(w['x_passphrase'])}"] + pin + ["EOF",
                      "uci commit; /etc/init.d/network reload",
                      # a station whose AP rebooted can sit on a dead link ("Connected", no traffic): join afresh
                      f"sleep 2; wifi down {radio}; sleep 1; wifi up {radio}"]) + "\n"
    rc, out = client.ssh("sh -s", stdin=text.encode(), timeout=60)
    if rc != 0:
        return None
    return wait_for(lambda: "inet " in client.ssh(f"ip -4 -o addr show dev {s['client_if']}")[1], 90)


def leave(client):
    client.ssh("uci -q delete wireless.cl; uci -q delete network.wwan; uci commit; /etc/init.d/network reload",
               timeout=60)


def bssids(t):
    return set(t.ssh("iw dev | awk '$1 == \"addr\" {print $2}'")[1].lower().split())


@contextlib.contextmanager
def flip(ctl, w, body):
    """Set WLAN fields for the length of the block; put the old values back after it."""
    old = {k: w.get(k, False) for k in body}
    changed = old != body
    if changed:
        ctl.put(f"rest/wlanconf/{w['_id']}", body)
    try:
        yield changed
    finally:
        if changed:
            ctl.put(f"rest/wlanconf/{w['_id']}", old)


@contextlib.contextmanager
def iperf_server(s):
    p = subprocess.Popen(["iperf3", "-s", "-B", s["wired_ip"]], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL) if s["min_mbps"] else None
    try:
        yield
    finally:
        if p:
            p.terminate()
            p.wait(10)


def applied(t, before, secs=90):
    """Seconds until the target applied a push newer than `before` (a cfgversion), or None."""
    return wait_for(lambda: table._applied(t) not in (None, before), secs)


def hostapd(t, pattern):
    return t.ssh(f"grep -h -E '{pattern}' {HOSTAPD} 2>/dev/null")[1].splitlines()


def ssids(t):
    """The SSIDs hostapd has on t. OpenWrt writes ssid2="name"; older builds ssid=name."""
    return sorted({line.split("=", 1)[1].strip('"') for line in hostapd(t, "^ssid2?=")})


def mark(t, name):
    m = f"{name}-{int(time.time())}"
    t.ssh(f"logger {m}")
    return m


def healthy(t, m):
    """'' or what is wrong with openUF on t since log mark m."""
    if t.ssh("/etc/init.d/openuf running")[0] != 0:
        return f"openUF not running on {t.name}"
    errs = table._errors(t, m)
    return f"Lua error in the log of {t.name}: {errs[0]}" if errs else ""


def ready(conf, s, ctl, roles):
    """Why the suite cannot run: a list of reasons, empty when it can. Changes nothing."""
    ts = {r: target.get_target(conf, s[r]) for r in roles}
    bad = [f"{t.name} is not reachable over SSH" for t in ts.values() if not t.reachable()]
    if bad:
        return bad
    try:
        ctl.login()
    except (RuntimeError, OSError) as e:
        return [f"controller login failed: {e}"]
    for r, t in ts.items():
        if r == "client":
            continue
        if t.ssh("/etc/init.d/openuf running")[0] != 0:
            bad.append(f"openUF is not running on {t.name}")
        try:
            d = ctl.device(t.host)
        except ValueError as e:  # a controller that is still starting answers a page that is not JSON
            return [f"the controller does not answer yet (no JSON): {e}"]
        if not (d and d.get("adopted") and d.get("state") == 1):
            bad.append(f"{t.name} is not adopted and connected in the controller")
    w = wlan(conf, ctl)
    if not w:
        bad.append(f"the controller has no WLAN named {conf['row_wlan']}")
    elif not w.get("enabled", True) or w.get("security") != "wpapsk" or not w.get("x_passphrase") or \
            (w.get("wpa3_support") and not w.get("wpa3_transition")):
        bad.append(f"WLAN {conf['row_wlan']} must be on, WPA2 personal (or WPA2/WPA3 mixed), with a passphrase")
    c = ts.get("client")
    if c:
        if c.ssh("[ -e /opt/openuf/inform.lua ]")[0] == 0:
            bad.append(f"{c.name} has openUF installed: the client must be a plain OpenWrt box")
        if s["min_mbps"] and c.ssh("command -v iperf3")[0] != 0:
            bad.append(f"no iperf3 on {c.name}")
        if c.ssh(f"ping -c 1 -i {s['ping_interval']} -W 1 127.0.0.1")[0] != 0:
            bad.append(f"ping on {c.name} does not take -i {s['ping_interval']}: set suite.ping_interval to 1")
    if s["min_mbps"] and not shutil.which("iperf3"):
        bad.append("no iperf3 on this host")
    return bad


def run_checks(steps):
    """[(name, fn)] -> [{name, ok, detail}]. fn returns (ok, detail). Stops when the client is lost."""
    out = []
    for name, fn in steps:
        try:
            ok, detail = fn()
        except ClientLost as e:
            out.append({"name": name, "ok": False, "detail": str(e)})
            break
        except Exception as e:  # a check that crashes is a failed check; the others still run
            ok, detail = False, f"error: {e!r}"[:300]
        out.append({"name": name, "ok": bool(ok), "detail": detail})
    return out


def finish(conf, name, checks):
    r = {"checks": checks, "pass": bool(checks) and all(c["ok"] for c in checks)}
    results.save(conf, name, r)
    return r
