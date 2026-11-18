"""Flash writes: sectors written and files changed while openUF idles, and for one push there and back."""
import time

from labtest import results, table
from labtest.safety import plug

MARK = "/tmp/labtest-mark"
DIRS = "/etc /opt/openuf /usr/lib/openuf /root"
APPLY_WAIT = 90
# openUF's unhandled ledger saves repeat counts up to FLUSH_INTERVAL (300 s) after a push: the
# idle window starts only after that, or it measures the last push, not idling (release-run6)
SETTLE = 330


def sectors(t):
    """Sectors written to real disks (field 7 of /sys/block/*/stat), not ram/loop/zram."""
    out = t.ssh('for f in /sys/block/*/stat; do echo "$f $(cat $f)"; done')[1]
    total = 0
    for line in out.splitlines():
        p = line.split()
        if len(p) >= 8 and not p[0].split("/")[3].startswith(("ram", "loop", "zram")):
            total += int(p[7])
    return total


def mark(t):
    t.ssh(f"touch {MARK}")


def changed(t):
    return t.ssh(f"find {DIRS} -xdev -type f -newer {MARK} 2>/dev/null", timeout=60)[1].split()


def _push_and_wait(t, ctl, wlan_id):
    old = table._applied(t)
    ctl.force_push(wlan_id)
    for _ in range(APPLY_WAIT // 5):
        if table._applied(t) != old:
            return True
        time.sleep(5)
    return False


def run(conf, t, ctl, idle=600):
    ctl.login()
    out = {"pass": False, "error": None, "idle": None, "push": None}
    if not plug._connected(t, ctl):
        out["error"] = "openUF not connected to the controller"
    else:
        time.sleep(SETTLE)
        s, _ = sectors(t), mark(t)
        time.sleep(idle)
        out["idle"] = {"secs": idle, "sectors": sectors(t) - s, "files": changed(t)}
        wlan = ctl.locate("WlanConf", t.host, conf["row_wlan"])[1]["_id"]
        s, _ = sectors(t), mark(t)
        applied = [_push_and_wait(t, ctl, wlan) for _ in range(2)]  # there and back
        out["push"] = {"sectors": sectors(t) - s, "files": changed(t), "applied": applied}
        out["pass"] = not out["idle"]["files"]  # push numbers: recorded only, Part 5 sets limits
    results.save(conf, "writes", out)
    return out
