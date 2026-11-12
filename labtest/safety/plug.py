"""Pull-the-plug test: kill a VM in the middle of a config push, boot it, check its config. VMs only."""
import subprocess
import time

from labtest import results

DELAYS = [1, 2, 4, 7]  # seconds between the push and the power cut

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


def run(conf, t, ctl):
    if t.kind != "vm":
        raise SystemExit(f"plug kills targets on purpose: refused on {t.name} (kind {t.kind}, not vm)")
    ctl.login()
    wlan = ctl.wlans()[0]["_id"]
    first = _uapsd(ctl, wlan)
    empty_before = empty_files(t)
    lab = ["sh", conf["lab_sh"]]
    cuts = []
    try:
        for delay in DELAYS:
            ctl.force_push(wlan)
            time.sleep(delay)
            subprocess.run(lab + ["stop", str(t.lab_n)], capture_output=True)  # kills QEMU: the power cut
            subprocess.run(lab + ["start", str(t.lab_n)], capture_output=True)
            c = {"delay": delay, "booted": t.wait(up=True, secs=180), "problems": [], "connected": False}
            cuts.append(c)
            if not c["booted"]:
                break  # a finding: leave the VM as it is for the lead to look at
            c["problems"] = config_problems(t, empty_before)
            c["connected"] = _connected(t, ctl)
    finally:
        if _uapsd(ctl, wlan) != first:
            ctl.force_push(wlan)  # leave the WLAN as found
    ok = len(cuts) == len(DELAYS) and all(c["booted"] and not c["problems"] and c["connected"] for c in cuts)
    res = {"pass": ok, "cuts": cuts}
    results.save(conf, "plug", res)
    return res
