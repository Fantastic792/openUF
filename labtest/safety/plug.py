"""Pull-the-plug test: kill a VM in the middle of a config push, boot it, check its config. VMs only."""
import subprocess
import threading
import time

from labtest import results

# seconds after the apply start (openUF's write of /etc/config/wireless) to cut the power.
# Measured on vm1: the apply ends (next state.json write) ~0.3 s after that write.
OFFSETS = [0, 0.1, 0.2, 0.5]
APPLY_WAIT = 30  # no apply start within this after the push -> that cut fails

# Runs on the target: prints READY, then "W <uptime>" when wireless changes (apply start)
# and "S <uptime>" when state.json changes (the end record follows the wireless write).
# shortcut: md5sum busy loop (no inotify on the VM), ~tens of ms resolution; stops by itself after 90 s.
WATCH = (
    "f=/etc/config/wireless; s=/etc/openuf/state.json; "
    "w0=$(md5sum < $f); s0=$(md5sum < $s 2>/dev/null); echo READY; "
    "read up _ < /proc/uptime; end=$(( ${up%.*} + 90 )); "
    "while :; do w=$(md5sum < $f); x=$(md5sum < $s 2>/dev/null); read up _ < /proc/uptime; "
    "[ \"$w\" != \"$w0\" ] && { echo \"W $up\"; w0=$w; }; "
    "[ \"$x\" != \"$s0\" ] && { echo \"S $up\"; s0=$x; }; "
    "[ ${up%.*} -ge $end ] && break; done")


class ApplyWatch:
    """Watches one push on the target. Times are local time.monotonic() when the line arrived."""

    def __init__(self, t):
        self.events = []  # (arrival, "W" or "S", target uptime)
        self._ready, self._start = threading.Event(), threading.Event()
        self.proc = subprocess.Popen(t._argv(WATCH), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            now, parts = time.monotonic(), line.split()
            if parts == ["READY"]:
                self._ready.set()
            elif len(parts) == 2 and parts[0] in ("W", "S"):
                self.events.append((now, parts[0], parts[1]))
                if parts[0] == "W":
                    self._start.set()

    def wait_ready(self, secs):
        return self._ready.wait(secs)

    def wait_start(self, secs):
        """Arrival time of the first wireless write, or None."""
        if not self._start.wait(secs):
            return None
        return next(e[0] for e in self.events if e[1] == "W")

    def done_before(self, ts):
        """True if a state.json write after the apply start arrived at or before ts."""
        seen_w = False
        for arrival, kind, _ in list(self.events):
            seen_w = seen_w or kind == "W"
            if seen_w and kind == "S" and arrival <= ts:
                return True
        return False

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()

FIND_EMPTY = "find /etc/config /etc/openuf -type f -size 0 2>/dev/null"
CHECK = ("for f in /etc/config/*; do uci -q show \"${f##*/}\" >/dev/null 2>&1 || echo \"BAD $f\"; done; "
         f"{FIND_EMPTY} | sed 's/^/EMPTY /'; "
         "/etc/init.d/openuf running || echo NOTRUNNING")


def empty_files(t):
    """Zero-length files before any cut: some are empty by design (/etc/config/openuf from the installer)."""
    return set(t.ssh(FIND_EMPTY)[1].split())


def config_problems(t, known_empty=()):
    rc, out = t.ssh(CHECK, timeout=30)
    if rc == 255:
        return ["target not reachable"]
    problems = []
    for line in out.splitlines():
        if line.startswith("BAD "):
            problems.append(f"uci cannot read {line[4:]}")
        elif line.startswith("EMPTY ") and line[6:] not in known_empty:
            problems.append(f"zero-length file {line[6:]}")
        elif line.strip() == "NOTRUNNING":
            problems.append("openuf not running")
    return problems


def _connected(t, ctl, secs=300):
    end = time.monotonic() + secs
    while True:
        if any(d.get("ip") == t.host and d.get("state") == 1 for d in ctl.devices()):
            return True
        if time.monotonic() >= end:
            return False
        time.sleep(10)


def _uapsd(ctl, wlan_id):
    return next(w for w in ctl.wlans() if w["_id"] == wlan_id).get("uapsd_enabled", False)


def run(conf, t, ctl, watch=ApplyWatch):
    if t.kind != "vm":
        raise SystemExit(f"plug kills targets on purpose: refused on {t.name} (kind {t.kind}, not vm)")
    ctl.login()
    wlan = ctl.wlans()[0]["_id"]
    first = _uapsd(ctl, wlan)
    empty_before = empty_files(t)
    lab = ["sh", conf["lab_sh"]]
    cuts = []
    try:
        for off in OFFSETS:
            c = {"offset": off, "apply_seen": False, "cut_ms": None, "mid_apply": False, "booted": None,
                 "problems": [], "connected": False, "error": None}
            cuts.append(c)
            w = watch(t)
            try:
                if not w.wait_ready(20):
                    c["error"] = "apply watch did not start on the target"
                    continue
                ctl.force_push(wlan)
                start = w.wait_start(APPLY_WAIT)
                if start is None:
                    c["error"] = f"no apply start within {APPLY_WAIT} s of the push: no cut made"
                    continue
                c["apply_seen"] = True
                time.sleep(max(0.0, start + off - time.monotonic()))
                cut = time.monotonic()
                subprocess.run(lab + ["stop", str(t.lab_n)], capture_output=True)  # kills QEMU: the power cut
                c["cut_ms"] = round((cut - start) * 1000)
                c["mid_apply"] = not w.done_before(cut)  # the end record had not arrived when the power went
            finally:
                w.stop()
            subprocess.run(lab + ["start", str(t.lab_n)], capture_output=True)
            c["booted"] = t.wait(up=True, secs=180)
            if not c["booted"]:
                break  # a finding: leave the VM as it is for the lead to look at
            c["problems"] = config_problems(t, empty_before)
            c["connected"] = _connected(t, ctl)
    finally:
        if _uapsd(ctl, wlan) != first:
            ctl.force_push(wlan)  # leave the WLAN as found
    ok = (len(cuts) == len(OFFSETS)
          and all(c["apply_seen"] and c["booted"] and not c["problems"] and c["connected"] and not c["error"]
                  for c in cuts)
          and any(c["mid_apply"] for c in cuts))  # a cut only after the apply proves nothing about the apply
    res = {"pass": ok, "cuts": cuts}
    results.save(conf, "plug", res)
    return res
