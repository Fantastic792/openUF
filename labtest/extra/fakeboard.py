"""A lab VM dressed as a JioRouter AX6000 JIDU6J01: board name at boot, five veth ports in br-lan."""
import json
import os
import time

from labtest import results, table
from labtest.extra import cycle
from labtest.safety import plug

BOARD = "jiorouter,ax6000-jidu6j01"
MAP = "jiorouter-ax6000-jidu6j01.lua"
MARK = "fakeboard install"
WAIT = 120  # seconds for the controller to show a change
HOST_MAC = "02:00:00:00:00:77"  # the made-up wired host
MODEL = "JioRouter AX6000 JIDU6J01"
PORTS = ["lan1", "lan2", "lan3", "lan4", "wan"]  # list position + 1 = port idx in openUF's map
FAR_BRIDGE = "br-far"
INIT = "/etc/init.d/fakeboard"

BOOT_SCRIPT = f"""#!/bin/sh /etc/rc.common
# labtest fake board: not part of openUF, removed by a VM reset
START=15
boot() {{
\tmkdir -p /tmp/sysinfo
\techo '{BOARD}' > /tmp/sysinfo/board_name
\techo '{MODEL}' > /tmp/sysinfo/model
}}
"""


def far(port):
    return port + "p"


def macs(base):
    tail = "02:" + ":".join(base.split(":")[2:6]) + ":"  # 02: locally administered, then bytes 3-6 of base
    m = {"br-lan": base, "eth0": tail + "e0"}
    for i, p in enumerate(PORTS, 1):
        m[p], m[far(p)] = tail + f"{i:02x}", tail + f"{0x10 + i:02x}"
    return m


def uci_batch(base, uplink="lan1"):
    m = macs(base)
    b = [f"set network.@device[0].macaddr='{base}'", "delete network.@device[0].ports"]
    b += [f"add_list network.@device[0].ports='{p}'" for p in PORTS]
    b += ["set network.fb_eth0=device", "set network.fb_eth0.name='eth0'", f"set network.fb_eth0.macaddr='{m['eth0']}'"]
    for p in PORTS:
        b += [f"set network.fb_{p}=device", f"set network.fb_{p}.name='{p}'", f"set network.fb_{p}.type='veth'",
              f"set network.fb_{p}.peer_name='{far(p)}'", f"set network.fb_{p}.macaddr='{m[p]}'",
              f"set network.fb_{p}.peer_macaddr='{m[far(p)]}'"]
    b += ["set network.fb_far=device", f"set network.fb_far.name='{FAR_BRIDGE}'", "set network.fb_far.type='bridge'",
          "add_list network.fb_far.ports='eth0'", f"add_list network.fb_far.ports='{far(uplink)}'",
          "set network.fb_farif=interface", f"set network.fb_farif.device='{FAR_BRIDGE}'",
          "set network.fb_farif.proto='none'",
          "set network.lan.force_link='1'"]  # netifd misses br-lan's link-up on about every second boot
    for p in PORTS:
        if p != uplink:  # an interface keeps the far end up: cable plugged
            b += [f"set network.fb_{far(p)}=interface", f"set network.fb_{far(p)}.device='{far(p)}'",
                  f"set network.fb_{far(p)}.proto='none'"]
    return "\n".join(b + ["commit network"]) + "\n"


def dressed(t):
    return t.ssh("cat /tmp/sysinfo/board_name")[1].strip() == BOARD and t.ssh("uci -q get network.fb_far")[0] == 0


def verify(t):
    bad = []
    if t.ssh("cat /tmp/sysinfo/board_name")[1].strip() != BOARD:
        bad.append("board_name is not " + BOARD)
    if t.ssh("cat /tmp/sysinfo/model")[1].strip() != MODEL:
        bad.append("model is not " + MODEL)
    links = set(t.ssh("ls /sys/class/net")[1].split())
    bad += [f"no link {n}" for n in PORTS + [far(p) for p in PORTS] + [FAR_BRIDGE] if n not in links]
    lan = t.ssh("ls /sys/class/net/br-lan/brif")[1].split()  # openUF's WiFi interfaces join br-lan too
    if set(PORTS) - set(lan) or "eth0" in lan:
        bad.append(f"br-lan ports are {sorted(lan)}: not all five, or eth0 still in it")
    ports = t.ssh(f"ls /sys/class/net/{FAR_BRIDGE}/brif")[1].split()
    if "eth0" not in ports or len([p for p in ports if p in map(far, PORTS)]) != 1 or len(ports) != 2:
        bad.append(f"{FAR_BRIDGE} ports are {ports}, not eth0 and one far end")
    if t.ssh("cat /sys/class/net/br-lan/address")[1].strip().startswith("02:"):
        bad.append("br-lan has a made-up 02: address, not the lab's")
    return bad


def dress(t, adopted):
    if t.kind != "vm":
        raise SystemExit(f"fakeboard rewires the network: refused on {t.name} (kind {t.kind}, not vm)")
    if dressed(t):
        return verify(t)
    if adopted:
        raise SystemExit(f"refused: {t.name} is adopted and not a fake board")
    dev = t.ssh("uci get network.@device[0].name")[1].strip()
    if dev != "br-lan":
        raise SystemExit(f"refused: {t.name}'s first network device is {dev!r}, not br-lan")
    if t.ssh("ls /lib/modules/*/veth.ko")[0] != 0:  # a fresh lab VM has no veth: netifd would make no ports
        t.ssh("apk add kmod-veth", timeout=120)
        if t.ssh("ls /lib/modules/*/veth.ko")[0] != 0:
            raise SystemExit(f"refused: no kmod-veth on {t.name} after apk add kmod-veth; nothing written")
    base = t.ssh("cat /sys/class/net/eth0/address")[1].strip()  # only on an undressed VM: the lab's own MAC
    t.ssh(f"cat > {INIT} && chmod 755 {INIT} && {INIT} enable", stdin=BOOT_SCRIPT.encode())
    if t.ssh("uci batch", stdin=uci_batch(base).encode())[0] != 0:
        raise SystemExit(f"uci batch failed on {t.name}: not rebooted; sh /root/vmlab/lab.sh reset {t.lab_n}")
    t.ssh("(sleep 1; reboot) >/dev/null 2>&1 &")
    t.wait(False, 60)
    if not t.wait(True, 180):
        raise SystemExit(f"{t.name} did not come back: sh /root/vmlab/lab.sh reset {t.lab_n}, then the fresh-VM recipe")
    return verify(t)


def wait_for(fn, secs=None, step=10):
    end = time.monotonic() + (WAIT if secs is None else secs)
    while not fn():
        if time.monotonic() >= end:
            return False
        time.sleep(step)
    return True


def install(conf, t):
    """The lab installer with this repo tree (every run: results match the commit), then modelmap 'auto'."""
    inst = os.path.join(os.path.dirname(conf["lab_sh"]), "src", "install-openuf.sh")
    ok, out = cycle._sh(["sh", inst, str(t.lab_n), cycle.REPO])
    if not ok:
        return False, out[-200:]
    rc, out = t.ssh(f"uci set openuf.main=openuf && uci set openuf.main.modelmap='auto' && uci commit openuf && "
                    f"logger -t labtest '{MARK}' && /etc/init.d/openuf restart", timeout=60)
    return rc == 0, out.strip()[-200:]


def map_pick(t):
    if not table._pid(t):
        return False, "openuf is not running"
    log = t.ssh(f"logread | sed -n '/{MARK}/,$p'", timeout=30)[1].splitlines()
    bad = [x for x in log if "no modelmap declares" in x or ("modelmap" in x and "unreadable" in x)]
    if bad:
        return False, bad[0][-200:]
    claim = t.ssh(f"grep -l '{BOARD}' /opt/openuf/modelmap/*.lua")[1].split()
    if [os.path.basename(c) for c in claim] != [MAP]:
        return False, f"maps naming the board: {claim}"
    return True, MAP


def adopt(t, ctl):
    d = ctl.device(t.host)
    if d and d.get("adopted") and plug._connected(t, ctl, secs=0):
        return True, "already adopted and connected"
    if not wait_for(lambda: ctl.device(t.host)):
        return False, "the controller never saw the device"
    ctl.post("cmd/devmgr", {"cmd": "adopt", "mac": ctl.device(t.host)["mac"]})
    return (True, "adopted") if plug._connected(t, ctl, secs=300) else (False, "not connected 300 s after adopt")


def ports(dev):
    return {p["port_idx"]: {"name": p.get("name", ""), "up": bool(p.get("up")), "uplink": bool(p.get("is_uplink")),
                            "macs": [m["mac"] for m in p.get("mac_table", [])]} for p in dev.get("port_table", [])}


def uplink_idx(dev):
    up = [i for i, p in ports(dev).items() if p["uplink"]]
    return up[0] if len(up) == 1 else None


def pull(t, port):
    t.ssh(f"ip link set {far(port)} down")


def plug_in(t, port):
    t.ssh(f"ip link set {far(port)} up")


def move_uplink(t, old, new):
    t.ssh(f"ip link set {far(old)} nomaster; ip link set {far(old)} down; "
          f"ip link set {far(new)} master {FAR_BRIDGE}; ip link set {far(new)} up")


def add_host(t, port):
    t.ssh(f"bridge fdb add {HOST_MAC} dev {port} master static")


def del_host(t, port):
    t.ssh(f"bridge fdb del {HOST_MAC} dev {port} master static")


def restore(t):
    """Uplink back on lan1, every far end up, the fake host gone. Safe when nothing was moved."""
    c = [f"ip link set {far(p)} nomaster" for p in PORTS if p != "lan1"] + [f"ip link set {far(p)} up" for p in PORTS]
    c += [f"bridge fdb del {HOST_MAC} dev lan4 master static 2>/dev/null", f"ip link set {far('lan1')} master {FAR_BRIDGE}"]
    t.ssh("; ".join(c))


def checks(t, ctl):
    out, before = [], {}

    def dev():
        return ctl.device(t.host) or {}

    def c_ports():
        d = dev()
        p = ports(d)
        return sorted(p) == [1, 2, 3, 4, 5] and d.get("model") == "U6IW", \
            f"model {d.get('model')}, ports {[(i, p[i]['name']) for i in sorted(p)]}"

    def c_uplink():
        i = uplink_idx(dev())
        return i == 1, f"uplink idx {i}"

    def c_moved():
        d = dev()
        before["id"] = (d.get("mac"), d.get("_id"), len(ctl.devices()))
        start = time.monotonic()
        move_uplink(t, "lan1", "lan3")

        def moved():
            d = dev()
            return uplink_idx(d) == 3 and not ports(d).get(1, {}).get("up")

        ok = wait_for(moved)
        return ok, f"{round(time.monotonic() - start)} s, uplink idx {uplink_idx(dev())}"

    def c_identity():
        d = dev()
        now = (d.get("mac"), d.get("_id"), len(ctl.devices()))
        restore(t)
        back = wait_for(lambda: uplink_idx(dev()) == 1)
        return now == before.get("id") and back, f"same device and count: {now == before.get('id')}, uplink back on 1: {back}"

    def c_cable():
        pull(t, "lan2")
        down = wait_for(lambda: not ports(dev()).get(2, {}).get("up", True))
        plug_in(t, "lan2")
        up = wait_for(lambda: ports(dev()).get(2, {}).get("up", False))
        return down and up, f"down seen: {down}, up again: {up}"

    def c_host():
        t0 = time.time() - 5
        add_host(t, "lan4")
        # the controller lists a port's wired hosts as clients (stat/sta sw_port), not in port_table's mac_table
        seen = wait_for(lambda: any(s.get("mac") == HOST_MAC and s.get("is_wired") and s.get("sw_port") == 4 and
                                    s.get("last_seen", 0) >= t0 for s in ctl.get("stat/sta")))
        del_host(t, "lan4")
        gone = HOST_MAC not in t.ssh("bridge fdb show br br-lan")[1]
        return seen and gone, f"seen on port 4: {seen}, gone from fdb: {gone}"

    def c_reboot():
        t.ssh("(sleep 1; reboot) >/dev/null 2>&1 &")
        t.wait(False, 60)
        if not t.wait(True, 180):
            return False, f"did not come back: sh /root/vmlab/lab.sh reset {t.lab_n}"
        conn = plug._connected(t, ctl, secs=300)
        bad = verify(t)
        up1 = wait_for(lambda: uplink_idx(dev()) == 1)
        n = len(ports(dev()))
        return conn and not bad and up1 and n == 5, f"connected {conn}, verify {bad or 'clean'}, uplink 1 {up1}, ports {n}"

    try:
        for name, fn in (("ports", c_ports), ("uplink", c_uplink), ("uplink_moved", c_moved), ("identity", c_identity),
                         ("cable", c_cable), ("wired_host", c_host), ("reboot", c_reboot)):
            try:
                ok, detail = fn()
            except Exception as e:  # noqa: BLE001 -- one check's error must not skip the rest or the restore
                ok, detail = False, f"{type(e).__name__}: {e}"
            out.append({"name": name, "ok": bool(ok), "detail": detail})
    finally:
        restore(t)
    return out


def run(conf, t, ctl):
    ctl.login()
    d = ctl.device(t.host)
    out = {"pass": False, "checks": []}

    def dress_step():
        bad = dress(t, adopted=bool(d and d.get("adopted")))
        return not bad, "; ".join(bad)

    steps = [("dress", dress_step), ("install", lambda: install(conf, t)), ("map_pick", lambda: map_pick(t)), ("adopt", lambda: adopt(t, ctl))]
    for name, fn in steps:
        ok, detail = fn()
        out["checks"].append({"name": name, "ok": ok, "detail": detail})
        if not ok:
            break
    else:
        with open(os.path.join(conf["results_dir"], "fakeboard-device.json"), "w") as f:
            json.dump(ctl.device(t.host), f, indent=1)  # outside the repo: the field names checks() reads
        out["checks"] += checks(t, ctl)
        out["pass"] = all(c["ok"] for c in out["checks"])
    results.save(conf, "fakeboard", out)
    return out
