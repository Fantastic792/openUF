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
  python3 tools/verify.py --router 192.168.1.20 --profile xiaomi-ax3000t

Any supported board: the profile (board names, radio order, LED, sockets)
is read from the device as the daemon resolves it; --profile only adds a
check that it is the one you meant to install.

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

# The board, the profile and what the profile says about the radios, LED and
# sockets all come from the device (verify-collect.sh's "profile" section,
# the daemon's own resolver), so one tool judges every supported board. It
# was written for the JIDU6J01 alone, with that profile's board name, radio
# order, LED and five sockets as constants: on any other board it FAILed
# checks that were fine. --profile still names the one you meant to install.

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


def profile_of(sec):
    """The profile section: the resolved modelmap/identity (JSON) and the map's
    own hwassign line. {} when the collector could not run probe.lua."""
    p = {}
    for l in sec.get("profile", []):
        if l.startswith("json="):
            try:
                p.update(json.loads(l[5:]))
            except ValueError:
                pass
        elif l.startswith("hwassign_line="):
            p["hwassign_line"] = l[len("hwassign_line="):]
    return p


def band_of_mhz(mhz):
    if 2400 <= mhz < 2500:
        return "2g"
    if 4900 <= mhz < 5900:
        return "5g"
    if 5925 <= mhz < 7200:
        return "6g"
    return None


GHZ = {"2g": "2.4 GHz", "5g": "5 GHz", "6g": "6 GHz"}


def stated_bands(line):
    """{"radio0": "2g", ...} from a profile's hwassign comment, e.g.
    '-- radio0 = 5 GHz, radio1 = 2.4 GHz (unverified)'. {} when it says none."""
    out = {}
    comment = line.split("--", 1)[1] if "--" in (line or "") else ""
    for radio, ghz in re.findall(r"(radio\d+)\s*=\s*(2\.4|5|6)\s*GHz", comment):
        out[radio] = {"2.4": "2g", "5": "5g", "6": "6g"}[ghz]
    return out


def git_here(*args):
    """Output of a git command run in this checkout, or None (no git, not a checkout)."""
    try:
        p = subprocess.run(["git", "-C", HERE, "-c", "safe.directory=*"] + list(args),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout.decode(errors="replace").strip() if p.returncode == 0 else None


def check_build(r, stamp):
    """Judge the device's BUILD stamp ("<commit> <time>", from dist.sh) against this
    checkout. The package used to be "the released package, none of these changes"
    (yesrab's releases); since the fork's Release workflow builds from this tree, a
    package is exactly as current as the commit its stamp names."""
    commit = stamp.split()[0] if stamp else ""
    head = git_here("rev-parse", "HEAD")
    full = git_here("rev-parse", "--verify", "-q", commit + "^{commit}") if commit else None
    if not commit:
        r.warn("no build stamp: cannot tell which code the device runs")
    elif head is None:
        r.info("build %s (not run from a git checkout, not compared)" % commit)
    elif full is None:
        r.warn("build %s is not in this checkout's history (git fetch, or another tree)" % commit)
    elif full == head:
        r.ok("built from this checkout's HEAD (%s)" % commit)
    elif git_here("merge-base", "--is-ancestor", full, head) is not None:
        behind = git_here("rev-list", "--count", full + ".." + head) or "?"
        r.warn("built from %s, %s commit(s) behind this checkout: deploy or install the newer build"
               % (commit, behind))
    else:
        r.warn("built from %s, which this checkout's HEAD does not contain" % commit)


def check_install(r, sec):
    r.group("install")
    b, ins, st = kv(sec.get("board", [])), sec.get("install", []), kv(sec.get("status", []))
    r.info("board %s (%s)" % (b.get("board_name") or "?", b.get("model", "?")))
    r.info("OpenWrt: " + b.get("release", "?"))
    prefixes = [l.split("=", 1)[1] for l in ins if l.startswith("prefix=")]
    if prefixes == ["/opt/openuf"]:
        r.ok("headless install in /opt/openuf")
    elif "/usr/lib/openuf" in prefixes and "/opt/openuf" in prefixes:
        r.fail("both /opt/openuf and the package's /usr/lib/openuf are installed -- never both")
    elif prefixes == ["/usr/lib/openuf"]:
        r.ok("package install in /usr/lib/openuf")
    else:
        r.fail("openUF is not installed")
    i = kv(ins)
    if prefixes:
        check_build(r, i.get("build"))
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


def check_profile(r, sec, expect=None):
    p = profile_of(sec)
    mm = p.get("modelmap") or {}
    name = mm.get("name")
    r.group("%s profile (%s)" % (mm.get("title") or name or "hardware",
                                 name or "not resolved"))
    if p.get("config_error"):
        r.fail("the configuration does not load: " + str(p["config_error"]))
    if not name:
        i = kv(sec.get("install", []))
        name = i.get("uci_modelmap") or i.get("conf_modelmap")
        r.warn("probe.lua gave no profile (older build?); conf/UCI names %r -- "
               "profile checks below are limited" % name)
    if expect:
        if name == expect:
            r.ok("modelmap %s, as asked (--profile)" % name)
        else:
            r.fail("modelmap is %r, --profile asked for %s" % (name, expect))
    elif name:
        r.ok("modelmap %s%s" % (name, " (from UCI)" if p.get("uci_managed") else ""))

    # The board: one of the names the profile claims. A generic profile
    # claims none and fits any board with its radio count.
    board = kv(sec.get("board", [])).get("board_name") or p.get("board")
    claims = mm.get("boards") or []
    if claims:
        if board in claims:
            r.ok("board %s is one the profile claims" % board)
        else:
            r.fail("board is %r, the profile claims %s -- wrong profile for this device"
                   % (board, ", ".join(claims)))
    elif mm:
        r.info("generic profile: claims no board name (board %s)" % (board or "?"))
    ident = p.get("identity") or {}
    if ident.get("name"):
        r.info("presents as %s (%s, firmware %s)" % (ident.get("model") or "?", ident["name"],
                                                    ident.get("fw_ver") or "?"))

    # The radios: each hwassign radio's UCI band against the frequencies its
    # phy really runs, and against what the profile says the order is.
    radios = sec.get("radios", [])
    phy_band = {}
    for l in radios:
        if l.startswith("phy"):
            m = re.search(r"\* (\d{4})(?:\.\d+)? MHz", l)
            phy_band[l.split(" ", 1)[0]] = band_of_mhz(int(m.group(1))) if m else None
    uci_band = {}
    for l in radios:
        m = re.match(r"wireless\.([^.]+)\.(band|hwmode)='?([^']*)'?", l)
        if m:
            v = m.group(3)
            if m.group(2) == "hwmode":
                v = "5g" if "a" in v else "2g"
            uci_band.setdefault(m.group(1), v)
    # "radio phy [operating MHz]": the operating frequency is the band the
    # radio really runs; a phy's first listed frequency only stands in when
    # the interface reported none (a phy may support several bands).
    radio_phy, radio_live = {}, {}
    for l in sec.get("radiophy", []):
        f = l.split()
        if len(f) >= 2:
            radio_phy[f[0]] = f[1]
            if len(f) >= 3 and f[2].isdigit():
                radio_live[f[0]] = band_of_mhz(int(f[2]))
    stated = stated_bands(p.get("hwassign_line"))
    hw = mm.get("hwassign") or sorted(uci_band)
    if not phy_band:
        r.fail("no phy at all -- the Wi-Fi driver did not load")
    for radio in hw:
        ub, phy = uci_band.get(radio), radio_phy.get(radio)
        live = radio_live.get(radio) or (phy_band.get(phy) if phy else None)
        if ub is None:
            r.fail("%s is in hwassign but has no band in UCI (no such radio section?)" % radio)
            continue
        if phy and live and live != ub:
            r.fail("%s: UCI says %s but %s runs %s" % (radio, GHZ.get(ub, ub), phy, GHZ.get(live, live)))
        elif phy and live:
            r.ok("%s = %s (%s)" % (radio, GHZ.get(ub, ub), phy))
        else:
            r.info("%s = %s in UCI; no interface up to tie it to a phy yet" % (radio, GHZ.get(ub, ub)))
        want = stated.get(radio)
        if want and want != ub:
            r.fail("%s is %s here, the profile says %s -- fix its hwassign comment (radio order)"
                   % (radio, GHZ.get(ub, ub), GHZ.get(want, want)))
        elif want:
            r.ok("%s matches the profile's radio order (%s)" % (radio, GHZ.get(want, want)))
    bands = sorted({uci_band.get(x) for x in hw if uci_band.get(x)})
    if len(hw) >= 2 and not ("2g" in bands and "5g" in bands):
        r.fail("a dual-radio profile with bands %s -- expected 2.4 GHz and 5 GHz" % bands)
    for l in radios:
        if l.startswith("wireless."):
            r.info(l)

    # The LED the profile drives for Locate and the LED toggle: a sysfs name,
    # or a full path; none at all is a profile choice (Locate is a no-op).
    led = mm.get("led")
    leds = sec.get("leds", [])
    if not led:
        r.skip("the profile declares no LED: Locate and the LED toggle do nothing")
    elif os.path.basename(str(led).rstrip("/")) in leds:
        r.ok("LED %s exists (Locate, LED toggle)" % led)
    else:
        r.fail("no LED %s; available: %s -- fix dev.conf.led" % (led, " ".join(leds) or "none"))
    # AP-DISABLED alone is not a DFS failure: hostapd logs it for every BSS on
    # every ordinary `wifi reload` (each config push), so matching it failed
    # every AP that had been provisioned (QEMU test VM, 2026-10-27). A failed
    # CAC is start_dfs_cac() failed, or the interface leaving DFS for DISABLED.
    dfs = log_matching(sec, r"start_dfs_cac\(\) failed|DFS->DISABLED")
    if dfs:
        show_log(r, dfs, "fail", "a radio went down on DFS/CAC")
    else:
        r.ok("no DFS CAC failure in the log")


def check_controller_device(r, dev, mac, sockets=None):
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
    if sockets is None:
        r.info("%d ports reported (the profile's socket count is unknown)" % len(ports))
    elif len(ports) == sockets:
        r.ok("%d ports reported, as the profile's sockets" % len(ports))
    else:
        r.warn("%d ports reported, the profile has %d sockets (a variant with fewer holes?)"
               % (len(ports), sockets))


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
    ap.add_argument("--profile", help="the modelmap you meant to install, e.g. "
                    "jiorouter-ax6000-jidu6j01 (default: judge against whatever the device runs)")
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
    check_profile(r, sec, a.profile)
    if a.controller:
        mm = profile_of(sec).get("modelmap") or {}
        check_controller_device(r, dev, mac, len(mm["ports"]) if mm.get("ports") else None)
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
