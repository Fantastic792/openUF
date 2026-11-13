"""Garbage from a fake controller: openUF must survive every bad reply, keep its pid, memory and config."""
import json
import os
import re
import struct
import time

from labtest import results, table
from labtest.extra import fake

PORT = 18080
STATE = "/etc/openuf/state.json"  # openUF informs to state.json's inform_url (set-inform), not conf.lua's
BAK = STATE + ".labtest-bak"
RESTORE = f"/etc/init.d/openuf stop; [ -f {BAK} ] && mv {BAK} {STATE}; /etc/init.d/openuf start"
INFORM_WAIT = 60
POLL = 5


def _noop(mac):
    return 200, fake.encode(b'{"_type": "noop", "interval": 10}', mac)


def _frame(mac, obj):
    return 200, fake.encode(json.dumps(obj).encode(), mac)


def _huge(mac):
    head = fake.encode(b"x", mac)[:36]
    return [(200, head + struct.pack(">I", 0xFFFFFFFF) + os.urandom(16))]


def _undecryptable(mac):
    head = fake.encode(b"x", mac)[:36]
    return [(200, head + struct.pack(">I", 64) + os.urandom(64))]


# name -> callable(mac) -> replies, one per inform. None is a real command: no reboot, reset or valid config.
CASES = {
    "empty_body": lambda mac: [(200, b"")],
    "http_500": lambda mac: [(500, b"")],
    "random_bytes": lambda mac: [(200, os.urandom(512))],
    "short_header": lambda mac: [(200, fake.encode(b'{"_type": "noop"}', mac)[:10])],
    "huge_length": _huge,
    "undecryptable": _undecryptable,
    "not_json": lambda mac: [(200, fake.encode(b"{{{", mac))],
    "wrong_types": lambda mac: [_frame(mac, {"_type": 5}), _frame(mac, {"_type": "setparam", "system_cfg": 12345}),
                                _frame(mac, {"_type": "cmd", "cmd": None}), _frame(mac, [])],
    "two_megabytes": lambda mac: [_frame(mac, {"_type": "setparam", "system_cfg": "a" * (2 << 20)})],
    "cut_mid_body": lambda mac: [("cut", 1000, b"TNBU\x00\x00\x00\x01\x00\x00")],
    "slow_40s": lambda mac: [("slow", 40, _noop(mac))],
}


def _rss(t, pid):
    m = re.search(r"VmRSS:\s+(\d+)", t.ssh(f"grep VmRSS /proc/{pid}/status")[1])
    return int(m.group(1)) if m else 0


def _cfg(t):
    return t.ssh("md5sum /etc/config/* 2>/dev/null")[1]


def _served(server, n, secs):
    """True once more than n informs reached the fake within secs."""
    for _ in range(secs // POLL + 1):
        if server.informs > n:
            return True
        time.sleep(POLL)
    return False


def run(conf, t, ctl):
    if t.kind != "vm":
        raise SystemExit(f"garbage repoints openUF: refused on {t.name} (kind {t.kind}, not vm)")
    ctl.login()
    d = ctl.device(t.host)
    if d and d.get("adopted"):
        raise SystemExit(f"garbage repoints openUF: refused on {t.name}, it is adopted")
    host = conf["fake_host"]
    server, queue, out = fake.Server(host, PORT), [], {"pass": False, "error": None, "cases": []}
    server.next = lambda req: queue.pop(0) if queue else _noop(req[8:14])
    try:
        t.ssh(f"[ -f {BAK} ] && mv {BAK} {STATE}; cp {STATE} {BAK}")
        server.start()
        t.ssh(f"syswrapper.sh set-inform http://{host}:{PORT}/inform; /etc/init.d/openuf restart", timeout=60)
        if not _served(server, server.informs, INFORM_WAIT):
            out["error"] = "no inform reached the fake"
            return out
        pid0 = table._pid(t)
        rss0, cfg0 = _rss(t, pid0), _cfg(t)
        for name, case in CASES.items():
            mark = f"case {name} {int(time.time())}"
            t.ssh(f"logger -t labtest '{mark}'")
            n = server.informs
            queue[:] = case(bytes(6))
            wait = (len(queue) + 1) * INFORM_WAIT + sum(r[1] for r in queue if r[0] == "slow")
            bad = [] if _served(server, n + len(queue), wait) else [f"no new inform within {wait} s"]
            queue[:] = []
            pid = table._pid(t)
            if pid != pid0:
                bad.append(f"openuf restarted (pid {pid0} -> {pid})")
            errs = table._errors(t, f"labtest: {mark}")
            if errs:
                bad.append(f"lua error: {errs[0]}")
            rss = _rss(t, pid) if pid else 0
            if rss0 and rss > 2 * rss0:
                bad.append(f"memory {rss0} -> {rss} kB")
            if _cfg(t) != cfg0:
                bad.append("/etc/config changed")
            out["cases"].append({"name": name, "ok": not bad, "problems": bad, "rss_kb": rss})
            pid0 = pid or pid0  # judge each case on its own
        out["pass"] = all(c["ok"] for c in out["cases"])
        return out
    finally:
        server.stop()
        t.ssh(RESTORE, timeout=60)
        results.save(conf, "garbage", out)
