"""Day-long run: openUF stays connected, keeps its pid, and its memory, open files and temp size do not grow."""
import statistics
import time

from labtest import results, table
from labtest.extra import garbage, writes
from labtest.safety import plug

GROWTH = 1.2  # last hour's median over the first hour's
HOUR = 3600


def _int(s):
    try:
        return int(s.strip())
    except ValueError:
        return 0


def sample(t, ctl):
    pid = table._pid(t)
    apid = t.ssh("pgrep -f '^lua announce.lua'")[1].strip() or None
    files, kb = (t.ssh("find /tmp/openuf* /etc/openuf -type f 2>/dev/null | wc -l; "
                       "du -sk /tmp/openuf* /etc/openuf 2>/dev/null | awk '{s+=$1} END {print s+0}'")[1].split()
                 + ["0", "0"])[:2]
    return {"t": int(time.time()), "rss_kb": {"inform": garbage._rss(t, pid) if pid else 0,
                                              "announce": garbage._rss(t, apid) if apid else 0},
            "fds": _int(t.ssh(f"ls /proc/{pid}/fd | wc -l")[1]) if pid else 0, "tmp_files": _int(files),
            "tmp_kb": _int(kb), "sectors": writes.sectors(t), "pid": pid, "connected": plug._connected(t, ctl, secs=0)}


def verdict(samples):
    why = [f"not connected at {x['t'] - samples[0]['t']} s" for x in samples if not x["connected"]][:1]
    why += [f"pid changed {samples[0]['pid']} -> {x['pid']} at {x['t'] - samples[0]['t']} s"
            for x in samples if x["pid"] != samples[0]["pid"]][:1]
    t0, t1 = samples[0]["t"], samples[-1]["t"]
    first = [x for x in samples if x["t"] <= t0 + HOUR]
    last = [x for x in samples if x["t"] >= t1 - HOUR]
    for name, get in (("inform", lambda x: x["rss_kb"]["inform"]), ("announce", lambda x: x["rss_kb"]["announce"]),
                      ("fds", lambda x: x["fds"]), ("tmp_kb", lambda x: x["tmp_kb"])):
        a, b = statistics.median(map(get, first)), statistics.median(map(get, last))
        if a and b > GROWTH * a:
            why.append(f"{name} grew {a} -> {b} (first hour -> last hour, median)")
    return not why, why


def run(conf, t, ctl, hours=24, every=300, push_every=1800):
    ctl.login()
    out = {"pass": False, "hours": hours, "problems": [], "pushes": [], "samples": []}
    start = last_push = time.monotonic()
    while True:
        out["samples"].append(sample(t, ctl))
        results.save(conf, "soak", out)  # a run that dies keeps its samples
        now = time.monotonic()
        if now - start >= hours * HOUR:
            break
        if now - last_push >= push_every:
            wlan = ctl.locate("WlanConf", t.host, conf["row_wlan"])[1]["_id"]
            out["pushes"].append([writes._push_and_wait(t, ctl, wlan) for _ in range(2)])  # there and back
            last_push = now
        time.sleep(every)
    out["pass"], out["problems"] = verdict(out["samples"])
    results.save(conf, "soak", out)
    return out
