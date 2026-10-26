#!/usr/bin/env python3
"""
verify.py — did the openuf-fixes changes work on a real AP?

Reads both sides and judges each change from CLAUDE.local.md section 3:
  * the router, over ssh: tools/selfcheck.sh, filtered logread, the daemon's
    status file, chosen state.json fields (tools/verify-collect.sh);
  * the UniFi Network controller's API: the device record (stat/device), the
    site's Uplink Connectivity Monitor setting, its WLANs and clients.

Usage (from the repository root, on the dev machine):
  python3 tools/verify.py --router 192.168.1.20 \\
      --controller https://192.168.1.50:8443 [--site default]
  python3 tools/verify.py --router 192.168.1.20          # router side only

Controller login, in order of preference:
  UNIFI_API_KEY=...            an API key (Settings > Control Plane >
                               Integrations), sent as X-API-KEY
  UNIFI_USER=admin             a local admin account; the password is
                               UNIFI_PASSWORD or asked for on the terminal
Both UniFi OS consoles (/proxy/network) and the self-hosted Network
application (/api) are probed. TLS certificates are not checked unless
--verify-tls is given (controllers ship self-signed ones).

Router login is plain ssh as root: keys, a blank password, or ssh's own
prompt. OPENUF_SSH overrides the command, as in tools/deploy.sh.

Output: one line per check, OK / FAIL / WARN / SKIP / INFO / TODO.
  SKIP  the feature is off here, so nothing was tested -- not a pass
  TODO  only a manual test on air can answer it; the line says which
Everything raw is saved under verify-<router>-<time>/ (router.txt,
controller-*.json, report.txt), with secrets redacted, for a bug report.
Exit status: 1 when anything FAILed, 2 for a usage or connection error.

Read-only on both sides: it writes selfcheck.sh to /tmp on the router and
removes it, and only GETs from the controller (plus the login POST).
"""

import argparse
import getpass
import http.cookiejar
import json
import os
import re
import shlex
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PROFILE = "jiorouter-ax6000-jidu6j01"
BOARD = "jiorouter,ax6000-jidu6j01"

# ──────────────────────────────────────────────────────────────────────────────
# Report
# ──────────────────────────────────────────────────────────────────────────────

class Report:
    def __init__(self):
        self.lines = []
        self.counts = {}

    def group(self, title):
        self._emit("")
        self._emit("[ " + title + " ]")

    def add(self, level, msg):
        self.counts[level] = self.counts.get(level, 0) + 1
        self._emit("  %-4s %s" % (level, msg))

    def _emit(self, s):
        print(s)
        self.lines.append(s)

    def ok(self, m):   self.add("OK", m)
    def fail(self, m): self.add("FAIL", m)
    def warn(self, m): self.add("WARN", m)
    def skip(self, m): self.add("SKIP", m)
    def info(self, m): self.add("INFO", m)
    def todo(self, m): self.add("TODO", m)


SECRET = re.compile(r"(^x_|key|psk|passw|secret|token|passphrase|auth)", re.I)

def redact(v):
    """Drop every value whose NAME looks secret. stat/device carries x_authkey,
    x_vwirekey and the WLANs' x_passphrase; none of them belong in a report."""
    if isinstance(v, dict):
        return {k: ("<redacted>" if SECRET.search(k) else redact(x)) for k, x in v.items()}
    if isinstance(v, list):
        return [redact(x) for x in v]
    return v

# ──────────────────────────────────────────────────────────────────────────────
# Router side
# ──────────────────────────────────────────────────────────────────────────────

def collect_router(host, timeout):
    """One ssh session: selfcheck.sh to /tmp, then verify-collect.sh. One
    session so a password prompt appears once."""
    with open(os.path.join(HERE, "selfcheck.sh")) as f:
        selfcheck = f.read()
    with open(os.path.join(HERE, "verify-collect.sh")) as f:
        collect = f.read()
    script = ("mkdir -p /tmp/openuf-verify\n"
              "cat > /tmp/openuf-verify/selfcheck.sh <<'OUF_SELFCHECK_EOF'\n"
              + selfcheck.rstrip("\n") + "\nOUF_SELFCHECK_EOF\n" + collect)
    ssh = shlex.split(os.environ.get("OPENUF_SSH") or
                      "ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR")
    try:
        p = subprocess.run(ssh + ["root@" + host, "sh -s"], input=script.encode(),
                           stdout=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "ssh timed out after %ds" % timeout
    out = p.stdout.decode("utf-8", "replace")
    if "### end" not in out:
        return out, "ssh exited %d before the collector finished" % p.returncode
    return out, None


def parse_sections(text):
    sec, cur = {}, None
    for line in text.splitlines():
        if line.startswith("### "):
            cur = line[4:].strip()
            sec[cur] = []
        elif cur is not None:
            sec[cur].append(line)
    return sec


def kv(lines):
    d = {}
    for l in lines:
        if "=" in l:
            k, v = l.split("=", 1)
            d.setdefault(k.strip(), v.strip())
    return d

# ──────────────────────────────────────────────────────────────────────────────
# Controller side
# ──────────────────────────────────────────────────────────────────────────────

class Controller:
    def __init__(self, url, site, api_key, user, password, verify_tls):
        self.url = url.rstrip("/")
        self.site = site
        self.api_key = api_key
        self.user, self.password = user, password
        self.prefix = None
        self.csrf = None
        ctx = ssl.create_default_context()
        if not verify_tls:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=ctx),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def _req(self, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(self.url + path, data=data,
                                   method="POST" if data else "GET")
        r.add_header("Accept", "application/json")
        if data:
            r.add_header("Content-Type", "application/json")
        if self.api_key:
            r.add_header("X-API-KEY", self.api_key)
        if self.csrf:
            r.add_header("X-CSRF-Token", self.csrf)
        with self.opener.open(r, timeout=15) as resp:
            tok = resp.headers.get("X-CSRF-Token") or resp.headers.get("X-Updated-CSRF-Token")
            if tok:
                self.csrf = tok
            return json.loads(resp.read().decode() or "{}")

    def login(self):
        """Find the API prefix: UniFi OS serves the Network app under
        /proxy/network, the self-hosted application at the root."""
        if self.api_key:
            last = None
            for prefix in ("/proxy/network", ""):
                try:
                    self._req(prefix + "/api/s/%s/stat/device" % self.site)
                    self.prefix = prefix
                    return
                except (urllib.error.URLError, ValueError) as e:
                    last = e
            raise RuntimeError("the API key was not accepted on /proxy/network or /api: %s" % last)
        creds = {"username": self.user, "password": self.password, "remember": False}
        for login, prefix in (("/api/auth/login", "/proxy/network"), ("/api/login", "")):
            try:
                self._req(login, creds)
                self.prefix = prefix
                return
            except urllib.error.HTTPError as e:
                # UniFi OS answers a bad password 401/403; the self-hosted
                # application 400 (api.err.Invalid). A 404 is the wrong flavour.
                if e.code in (400, 401, 403):
                    raise RuntimeError("controller refused the login (HTTP %d)" % e.code)
            except (urllib.error.URLError, ValueError):
                pass
        raise RuntimeError("no login endpoint answered at " + self.url)

    def get(self, path):
        doc = self._req("%s/api/s/%s/%s" % (self.prefix, self.site, path))
        meta = doc.get("meta", {})
        if meta.get("rc") not in (None, "ok"):
            raise RuntimeError("%s: %s" % (path, meta.get("msg")))
        return doc.get("data", [])

# ──────────────────────────────────────────────────────────────────────────────
# Checks
# ──────────────────────────────────────────────────────────────────────────────

def selfcheck_group(sec, name):
    """The lines of one selfcheck.sh group, e.g. 'mesh'."""
    out, on = [], False
    for l in sec.get("selfcheck", []):
        if l.startswith("==="):
            # selfcheck's own header and closing summary, not a group's line
            on = False
            continue
        if l.startswith("[ "):
            on = (l.strip() == "[ %s ]" % name)
            continue
        if on and l.strip():
            out.append(l.strip())
    return out


def relay(r, lines):
    """Pass selfcheck's own verdicts through; it already knows the device."""
    for l in lines:
        level, _, msg = l.partition(" ")
        msg = msg.strip()
        {"OK": r.ok, "FAIL": r.fail, "SKIP": r.skip}.get(level, r.info)(msg)


def log_matching(sec, pattern):
    rx = re.compile(pattern)
    return [l for l in sec.get("log", []) if rx.search(l)]


def show_log(r, lines, level, what, keep=3):
    if not lines:
        return
    getattr(r, level)("%s: %d line(s) in logread, latest:" % (what, len(lines)))
    for l in lines[-keep:]:
        r.info("    " + l[-200:])


def check_install(r, sec):
    r.group("install (headless, from this tree)")
    b, ins, st = kv(sec.get("board", [])), sec.get("install", []), kv(sec.get("status", []))
    if b.get("board_name") == BOARD:
        r.ok("board %s (%s)" % (BOARD, b.get("model", "?")))
    else:
        r.fail("board is %r, not %s -- wrong device, or not the JIDU6J01 family"
               % (b.get("board_name"), BOARD))
    r.info("OpenWrt: " + b.get("release", "?"))
    prefixes = [l.split("=", 1)[1] for l in ins if l.startswith("prefix=")]
    if prefixes == ["/opt/openuf"]:
        r.ok("headless install in /opt/openuf")
    elif "/usr/lib/openuf" in prefixes and "/opt/openuf" in prefixes:
        r.fail("both /opt/openuf and the package's /usr/lib/openuf are installed -- never both")
    elif prefixes == ["/usr/lib/openuf"]:
        r.fail("only the released package (/usr/lib/openuf) is installed -- it has none of these changes; "
               "reinstall headless from this tree")
    else:
        r.fail("openUF is not installed")
    i = kv(ins)
    if i.get("build"):
        r.info("build stamp: " + i["build"])
    mm = i.get("uci_modelmap") or i.get("conf_modelmap")
    if mm == PROFILE:
        r.ok("modelmap " + PROFILE)
    else:
        r.fail("modelmap is %r, expected %s" % (mm, PROFILE))
    if i.get("daemon") == "running":
        r.ok("daemon running")
    else:
        r.fail("daemon not running (/etc/init.d/openuf start; logread | grep inform)")
    now = int((sec.get("now") or ["0"])[0] or 0)
    last_ok, last_fail = int(st.get("last_ok", 0) or 0), int(st.get("last_fail", 0) or 0)
    if last_ok and now - last_ok < 120:
        r.ok("last inform answered %ds ago (%s)" % (now - last_ok, st.get("last_type", "")))
    elif last_ok:
        r.fail("last answered inform was %ds ago" % (now - last_ok))
    else:
        r.fail("no inform has ever been answered")
    if last_fail > last_ok:
        r.fail("latest inform failed: " + st.get("last_fail_msg", ""))
    if st.get("adopted") == "true":
        r.ok("adopted (identity MAC %s)" % st.get("mac", "?"))
    else:
        r.fail("not adopted -- adopt it in the controller")
    d = kv(sec.get("deps", []))
    if d.get("bitlib") == "ok":
        r.ok("bit library present (lua-bitop / bit32)")
    else:
        r.fail("no bit library -- install luabitop (the bit-lib error message fix)")
    if d.get("wpad") == "full":
        r.ok("full wpad (bss_transition)")
    else:
        r.fail("basic wpad -- the first WLAN push takes the radio down; install a full wpad")


def check_profile(r, sec):
    r.group("JIDU6401 profile (never verified on this family)")
    radios = sec.get("radios", [])
    phys = {l.split(" ", 1)[0]: l for l in radios if l.startswith("phy")}
    p0 = phys.get("phy0", "")
    m = re.search(r"(\d{4})(?:\.\d+)? MHz", p0)
    if m and 2400 <= int(m.group(1)) < 2500:
        r.ok("phy0 is 2.4 GHz, as the map says (radio0 = 2.4, radio1 = 5)")
    elif p0:
        r.fail("phy0 is not 2.4 GHz (%s) -- the map's radio order comment is wrong; "
               "check uci band of radio0/radio1" % p0.strip())
    else:
        r.fail("no phy0 -- the Wi-Fi driver did not load")
    for l in radios:
        if l.startswith("wireless."):
            r.info(l)
    leds = sec.get("leds", [])
    if "green:status" in leds:
        r.ok("LED green:status exists (Locate, LED toggle)")
    else:
        r.fail("no green:status LED; available: %s -- fix dev.conf.led" % " ".join(leds))
    # AP-DISABLED alone is not a DFS failure: hostapd logs it for every BSS on
    # every ordinary `wifi reload` (each config push), so matching it failed
    # every AP that had been provisioned (QEMU test VM, 2026-10-27). A failed
    # CAC is start_dfs_cac() failed, or the interface leaving DFS for DISABLED.
    dfs = log_matching(sec, r"start_dfs_cac\(\) failed|DFS->DISABLED")
    if dfs:
        show_log(r, dfs, "fail", "a radio went down on DFS/CAC")
    else:
        r.ok("no DFS CAC failure in the log")


def check_controller_device(r, dev, mac):
    r.group("controller: device record")
    if dev is None:
        r.fail("controller has no device %s -- not adopted, or adopted under another MAC "
               "(an identity change: HTTP 400 forever)" % mac)
        return
    state = dev.get("state")
    names = {0: "disconnected", 1: "connected", 2: "pending adoption", 4: "upgrading",
             5: "provisioning", 6: "heartbeat missed", 7: "adopting", 10: "adoption failed",
             11: "isolated"}
    if state == 1:
        r.ok("connected: %s (%s, %s)" % (dev.get("name") or dev.get("mac"),
                                          dev.get("model"), dev.get("ip")))
    else:
        r.fail("state %s (%s)" % (state, names.get(state, "?")))
    r.info("version %s, uptime %ss, last seen %ss ago"
           % (dev.get("version"), dev.get("uptime"),
              int(time.time()) - int(dev.get("last_seen") or 0)))
    radios = dev.get("radio_table") or []
    bands = sorted(x.get("radio") for x in radios)
    if "na" in bands and "ng" in bands:
        r.ok("controller sees both radios (%s)" % ", ".join(bands))
    else:
        r.fail("controller radio_table: %s (expected ng + na; libuci-lua missing?)" % bands)
    vaps = dev.get("vap_table") or []
    up = [v for v in vaps if v.get("up")]
    r.info("%d SSID(s) reported, %d up: %s" % (len(vaps), len(up),
           ", ".join(sorted({"%s/%s" % (v.get("essid"), v.get("radio")) for v in vaps}))))
    ports = dev.get("port_table") or []
    if len(ports) == 5:
        r.ok("5 ports reported")
    else:
        r.warn("%d ports reported (the map has 5 sockets; a variant with fewer holes?)" % len(ports))


def check_mesh(r, sec, dev, devices):
    r.group("multi-hop wireless mesh")
    relay(r, selfcheck_group(sec, "mesh"))
    st = kv(sec.get("state", []))
    if st.get("backhaul_seen"):
        r.info("siblings heard on air (BSSIDs): " + st["backhaul_seen"])
    if st.get("backhaul_blacklist"):
        r.info("descendants blacklisted (loop prevention): " + st["backhaul_blacklist"])
    show_log(r, log_matching(sec, r"backhaul: joined .* a loop"), "fail",
             "a loop was joined and left")
    show_log(r, log_matching(sec, r"backhaul: .*unpinning"), "info", "parent pin given up")
    show_log(r, log_matching(sec, r"ucihelper: backhaul sections not written|backhaul: could not"),
             "fail", "backhaul errors")
    if dev is None:
        return
    up = dev.get("uplink") or {}
    by_mac = {d.get("mac"): d for d in devices}
    if up.get("type") == "wireless":
        parent = by_mac.get(up.get("uplink_mac"), {})
        r.ok("controller draws a wireless uplink to %s (%s dBm)"
             % (parent.get("name") or up.get("uplink_mac"), up.get("signal", up.get("rssi", "?"))))
    elif up:
        r.info("controller draws a %s uplink" % up.get("type", "?"))
    children = dev.get("downlink_table") or []
    wl = [c for c in children
          if (by_mac.get(c.get("mac"), {}).get("uplink") or {}).get("type") == "wireless"]
    if wl:
        r.ok("wireless children named by this AP: " +
             ", ".join(by_mac[c["mac"]].get("name") or c["mac"] for c in wl))
    hop2 = [d for d in devices if (d.get("uplink") or {}).get("type") == "wireless"
            and (d.get("uplink") or {}).get("uplink_mac") in {c.get("mac") for c in wl}]
    if hop2:
        r.ok("second hop drawn: " + ", ".join(d.get("name") or d["mac"] for d in hop2))
    r.todo("three APs in a chain, pull the middle one's cable: no loop, both hops drawn")


def check_loadbalance(r, sec):
    r.group("load balance never kicks mesh children")
    r.info("kicks are silent in the log by design; the fix shows as a mesh child that stays joined")
    r.todo("with Load balance on and a wireless child, the child's uptime keeps growing")


def check_uplinkmon(r, sec, setting):
    r.group("uplink connectivity monitor")
    st = kv(sec.get("state", []))
    if setting is not None:
        on = bool(setting.get("enabled"))
        r.info("site setting: monitor %s, uplink_type %s%s"
               % ("on" if on else "off", setting.get("uplink_type", "?"),
                  (", host " + setting["uplink_host"]) if setting.get("uplink_host") else ""))
        if on and st.get("uplinkmon_enabled") != "true":
            r.fail("the site's monitor is on but the AP never got connectivity.status=enabled "
                   "(wifi_caps 0x1 claimed? set debug_dump_file in conf.lua and look)")
        elif not on and st.get("uplinkmon_enabled") == "true":
            r.warn("the AP runs the monitor though the site setting is off (uplink_monitor override?)")
    relay(r, selfcheck_group(sec, "uplinkmon"))
    show_log(r, log_matching(sec, r"uplinkmon: "), "info", "monitor actions", keep=4)
    r.todo("pull the uplink: SSIDs off after 5 checks, back on the first answer")


def check_guest(r, sec, wlans, clients, mac):
    r.group("guest portal")
    guest_wlans = [w for w in wlans if w.get("is_guest") and w.get("enabled", True)]
    st = kv(sec.get("state", []))
    if guest_wlans:
        r.info("controller guest WLANs: " + ", ".join(w.get("name", "?") for w in guest_wlans))
        if not st.get("guest_portal"):
            r.warn("the controller has a guest WLAN but the AP holds no portal config "
                   "(portal off on the site, or the WLAN is not on this AP)")
    relay(r, selfcheck_group(sec, "guest"))
    show_log(r, log_matching(sec, r"guestportal: (cannot listen|unrecognised|could not|answer failed)"),
             "fail", "guest portal errors")
    show_log(r, log_matching(sec, r"guestportal: .*(unanswered|enforced again|back up)"),
             "info", "selfrun (controller unreachable) episodes")
    g = [c for c in clients if c.get("is_guest") and c.get("ap_mac") == mac]
    if g:
        auth = [c for c in g if c.get("authorized")]
        r.info("%d guest client(s) on this AP, %d authorized" % (len(g), len(auth)))
    r.todo("on a test guest SSID: join, open http://neverssl.com, log in, browse")


def check_apname(r, sec):
    r.group("AP name in beacon")
    relay(r, selfcheck_group(sec, "apname"))
    r.todo("a Wi-Fi scanner (WiFiman, Wireshark) shows the WPS Device Name; Windows shows no WPS prompt")


def check_stun(r, sec, dev):
    r.group("STUN re-resolve")
    show_log(r, log_matching(sec, r"inform: stun: "), "info", "STUN errors (said once each)")
    if dev is not None and dev.get("connect_request_ip"):
        r.ok("controller has a STUN wake-up address for the AP (%s:%s)"
             % (dev.get("connect_request_ip"), dev.get("connect_request_port")))
    elif dev is not None:
        r.info("controller holds no STUN wake-up address yet")
    r.todo("change the controller's IP (or its DNS name's): the AP follows within 3 unanswered requests")


def check_rest(r, sec):
    r.group("other features (selfcheck)")
    for g in ("deps", "daemon", "ppsk", "owe", "schedule", "speed", "blocker", "l2guard", "airtime"):
        relay(r, ["%s %s: %s" % (l.split(" ", 1)[0], g, l.split(" ", 1)[1].strip())
                  if " " in l else l for l in selfcheck_group(sec, g)])


def check_errors(r, sec):
    r.group("daemon errors in the log")
    bad = log_matching(sec, r"lua: |traceback|build_json failed|handle_response failed|"
                            r"build_packet failed|parse error|install lua-bitop")
    if bad:
        show_log(r, bad, "fail", "errors", keep=6)
    else:
        r.ok("no Lua errors or failed inform stages in the log")
    posts = log_matching(sec, r"inform: POST failed")
    if posts:
        show_log(r, posts, "warn", "informs that did not reach the controller")
    unh = [l.split("\t") for l in sec.get("unhandled", []) if l.count("\t") >= 2]
    if unh:
        r.info("%d kind(s) of controller config openUF does not act on (unhandled ledger), top:" % len(unh))
        for e in sorted(unh, key=lambda e: -int(e[2] or 0))[:5]:
            r.info("    %s %s x%s" % (e[0], e[1], e[2]))

# ──────────────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--router", required=True, help="the AP's address (root ssh)")
    ap.add_argument("--controller", help="controller URL, e.g. https://192.168.1.50:8443")
    ap.add_argument("--site", default="default", help="site id (default: default)")
    ap.add_argument("--mac", help="the AP's identity MAC, if the status file has none")
    ap.add_argument("--verify-tls", action="store_true", help="check the controller's certificate")
    ap.add_argument("--timeout", type=int, default=90, help="ssh timeout in seconds")
    ap.add_argument("--out", help="report directory (default: verify-<router>-<time>)")
    a = ap.parse_args()

    out_dir = a.out or "verify-%s-%s" % (a.router.replace(":", "_"), time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(out_dir, exist_ok=True)

    print("=== openUF verify: router %s%s ===" % (a.router, (", controller " + a.controller) if a.controller else ""))
    raw, err = collect_router(a.router, a.timeout)
    if raw is not None:
        with open(os.path.join(out_dir, "router.txt"), "w") as f:
            f.write(raw)
    if err:
        print("router: " + err, file=sys.stderr)
        if raw is None or "### install" not in raw:
            return 2
    sec = parse_sections(raw or "")
    mac = (a.mac or kv(sec.get("status", [])).get("mac", "")).lower()

    dev, devices, setting, wlans, clients = None, [], None, [], []
    if a.controller:
        key = os.environ.get("UNIFI_API_KEY")
        user = os.environ.get("UNIFI_USER")
        pw = None
        if not key:
            if not user:
                user = input("controller admin user: ")
            pw = os.environ.get("UNIFI_PASSWORD") or getpass.getpass("controller password for %s: " % user)
        c = Controller(a.controller, a.site, key, user, pw, a.verify_tls)
        try:
            c.login()
            devices = c.get("stat/device")
            dev = next((d for d in devices if d.get("mac", "").lower() == mac), None)
            if dev is None:
                dev = next((d for d in devices if d.get("ip") == a.router), None)
        except Exception as e:  # noqa: BLE001 -- any controller failure is reported, not raised
            print("controller: %s" % e, file=sys.stderr)
            return 2
        # The rest only adds context; a controller version without one of
        # these endpoints should not cost the device verdicts.
        def optional(path):
            try:
                return c.get(path)
            except Exception as e:  # noqa: BLE001
                print("controller: %s unavailable (%s)" % (path, e), file=sys.stderr)
                return []
        setting = next((s for s in optional("get/setting") if s.get("key") == "connectivity"), None)
        wlans = optional("rest/wlanconf")
        clients = optional("stat/sta")
        for name, data in (("device", dev), ("devices", devices), ("setting-connectivity", setting),
                           ("wlans", wlans)):
            with open(os.path.join(out_dir, "controller-%s.json" % name), "w") as f:
                json.dump(redact(data), f, indent=2, sort_keys=True)

    r = Report()
    check_install(r, sec)
    check_profile(r, sec)
    if a.controller:
        check_controller_device(r, dev, mac)
    check_mesh(r, sec, dev, devices)
    check_loadbalance(r, sec)
    check_uplinkmon(r, sec, setting)
    check_guest(r, sec, wlans, clients, mac)
    check_apname(r, sec)
    check_stun(r, sec, dev)
    check_rest(r, sec)
    check_errors(r, sec)
    if not a.controller:
        r.group("controller")
        r.skip("no --controller given; only the router side was judged")

    summary = "=== " + ", ".join("%d %s" % (r.counts.get(k, 0), k)
                                for k in ("OK", "FAIL", "WARN", "SKIP", "TODO")) + " ==="
    r._emit("")
    r._emit(summary)
    r._emit("raw data: " + out_dir)
    with open(os.path.join(out_dir, "report.txt"), "w") as f:
        f.write("\n".join(r.lines) + "\n")
    return 1 if r.counts.get("FAIL") else 0


if __name__ == "__main__":
    sys.exit(main())
