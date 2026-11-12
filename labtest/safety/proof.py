"""Timer proof: break a VM three ways and watch the self-heal timer bring it back. VMs only."""
import time

from labtest import results
from labtest.safety import heal

LIMIT = 180
BREAKS = {
    "wrong_address": "uci set network.lan.proto=static; uci set network.lan.ipaddr=198.51.100.1; "
                     "uci set network.lan.netmask=255.255.255.0; uci commit network; /etc/init.d/network restart",
    "deleted_network": "uci delete network.lan; uci commit network; /etc/init.d/network restart",
    "bad_vlan": "d=$(uci get network.lan.device); uci set network.lan.device=$d.4000; uci commit network; "
                "/etc/init.d/network restart",
}


def _openuf_back(t):
    t.ssh("/etc/init.d/openuf enable; /etc/init.d/openuf start; sync")  # sync: plug may cut power next
    for _ in range(12):
        if t.ssh("/etc/init.d/openuf running")[0] == 0:
            return True
        time.sleep(5)
    return False


def one(t, name, cmd):
    r = {"name": name, "cut": False, "healed": False, "secs": None, "network_same": False, "openuf_off": False}
    rc, saved = t.ssh("uci export network")
    if rc != 0:
        r["error"] = f"uci export failed ({rc})"
        return r
    heal.arm(t)
    start = time.monotonic()
    with heal.Knocker(t):
        t.ssh(f"(sleep 2; {cmd}) >/dev/null 2>&1 &")  # let the SSH call return first
        r["cut"] = t.wait(up=False, secs=60)
    if not r["cut"]:
        t.wait(up=False, secs=LIMIT + 60)  # knocks stopped: the timer heals it anyway; let that reboot pass
    back = t.wait(up=True, secs=LIMIT + 240)
    r["secs"] = round(time.monotonic() - start)
    if not back:
        r["error"] = "did not come back"
        return r
    r["healed"] = heal.healed(t)
    r["network_same"] = t.ssh("uci export network")[1] == saved
    r["openuf_off"] = t.ssh("/etc/init.d/openuf running")[0] != 0
    left = heal.disarm(t)
    if left:
        r["error"] = f"disarm left {left}"
    r["openuf_back"] = _openuf_back(t)
    return r


def ok(b):
    return b["cut"] and b["healed"] and b["network_same"] and b["openuf_off"] and not b.get("error")


def run(conf, t):
    if t.kind != "vm":
        raise SystemExit(f"proof breaks targets on purpose: refused on {t.name} (kind {t.kind}, not vm)")
    breaks = []
    for name, cmd in BREAKS.items():
        b = one(t, name, cmd)
        breaks.append(b)
        if not b.get("openuf_back", False):
            break  # next break must start from a normal state
    res = {"pass": len(breaks) == len(BREAKS) and all(ok(b) for b in breaks), "limit": LIMIT, "breaks": breaks}
    results.save(conf, "timer-proof", res)
    return res
