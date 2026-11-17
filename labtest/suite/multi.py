"""Two-AP suite: a push reaches both APs, 802.11r/k/v are set alike, a client roams, the second AP falls
back to the mesh when its cable goes and returns to the cable, and no loop or storm follows.
openUF runs no STP: loop_guard proves 'no storm and the BPDU drop rule is there', not RSTP timing."""
import contextlib
import time

from labtest import table, target
from labtest.safety import plug
from labtest.suite import common
from labtest.suite.common import SKIP

NAMES = ["ready", "propagation", "kv_config", "roam", "ap_loss", "mesh_failover", "loop_guard", "mesh_restore",
         "both_healthy"]
KV = "^(bss_transition|rrm_neighbor_report|mobility_domain|wpa_key_mgmt)="
BGA = "01:80:c2"  # start of the bridge group address the l2guard rule drops


def run(conf, ctl):
    s = common.cfg(conf)
    bad = common.ready(conf, s, ctl, ("ap1", "ap2", "client"))
    if bad:
        return common.finish(conf, "multi", [{"name": "ready", "ok": False, "detail": "; ".join(bad)}])
    a1, a2, client = (target.get_target(conf, s[r]) for r in ("ap1", "ap2", "client"))
    w, wired, st = common.wlan(conf, ctl), s["wired_ip"], {}
    lab_vm = all(t.kind == "vm" for t in (a1, a2, client))
    marks = {t.name: common.mark(t, "suite-multi") for t in (a1, a2)}

    def air(*pairs):
        for n, peer, level in pairs:
            common.lab(conf, "air", n.lab_n, peer.lab_n, level)

    def propagation():
        b1, b2 = table._applied(a1), table._applied(a2)
        ctl.force_push(w["_id"])
        try:
            d1, d2 = common.applied(a1, b1), common.applied(a2, b2)
        finally:
            ctl.force_push(w["_id"])  # the flag it flipped goes back
            time.sleep(20)
        s1, s2 = common.ssids(a1), common.ssids(a2)
        ok = None not in (d1, d2) and s1 == s2 and w["name"] in s1
        return ok, f"applied after {d1} s on {a1.name}, {d2} s on {a2.name} (None = not in 90 s); SSIDs " + \
            ("equal" if s1 == s2 else f"differ: {s1} / {s2}")

    def kv_config():
        l1, l2 = (set(common.hostapd(t, KV)) for t in (a1, a2))
        md1, md2 = ({x for x in l if x.startswith("mobility_domain=")} for l in (l1, l2))
        missing = [f"{n} on {t.name}" for t, l in ((a1, l1), (a2, l2))
                   for n in ("bss_transition=1", "rrm_neighbor_report=1") if n not in l]
        missing += [f"FT key management on {t.name}" for t, l in ((a1, l1), (a2, l2))
                    if not any(x.startswith("wpa_key_mgmt=") and "FT-" in x for x in l)]
        if not md1 or md1 != md2:
            missing.append(f"one mobility domain on both ({sorted(md1)} / {sorted(md2)})")
        return not missing, "missing: " + ", ".join(missing) if missing else "802.11r/k/v set alike on both APs"

    def ping():
        iv = s["ping_interval"]
        return ("ping", f"ping -c {int(30 / iv)} -i {iv} -W 1 -I $IF {wired}")

    def window(cmds, frm, to, limit, during=None):
        """Run a 50 s WiFi-only window; ok when the client went from AP frm to AP to within limit seconds."""
        r = common.wifi_only(s, client, [("before", "iw dev $IF link")] + cmds + [
            ("after", "iw dev $IF link"), ("wpa", "wpa_cli -i $IF status 2>/dev/null | grep -E '^key_mgmt='")],
            50, during=during)
        b0, b1 = common.bssid(r.get("before", "")), common.bssid(r.get("after", ""))
        g = common.gap(r.get("ping", ""), s["ping_interval"])
        moved = b1 in common.bssids(to)
        ok = b0 in common.bssids(frm) and moved and g is not None and g <= s[limit]
        return ok, (f"{'moved' if moved else 'did NOT move'} from {frm.name} to {to.name}; longest gap {g} s "
                    f"(limit {s[limit]}); {r.get('wpa', '').strip() or 'key_mgmt unknown'}")

    def roam():
        # F-20 (owner 2026-11-16): both APs up and heard, the client is told to roam (wpa_cli roam), as a
        # phone walking between two APs does. roam_max_s measures the handover itself.
        if not lab_vm:
            return True, SKIP + "needs the lab's air control; on hardware run benchmark H4 by hand"
        air((client, a2, "off"), (a2, client, "off"))
        if common.join(s, client, w, ft=True) is None:
            return False, "the client got no address over WiFi in 90 s"
        air((client, a2, "default"), (a2, client, "default"))  # the cable is still up: lab.sh reaches the client
        st["roamed"] = True
        targets = "|".join(sorted(common.bssids(a2)))
        go = (f"( sleep 5; wpa_cli -i $IF scan >/dev/null; sleep 4; "
              f"B=$(wpa_cli -i $IF scan_results | grep -ioE '{targets}' | head -1); "
              f"wpa_cli -i $IF roam $B > /tmp/suite-roam.out 2>&1 ) &")
        return window([("go", go), ping(), ("roamed", "cat /tmp/suite-roam.out")], a1, a2, "roam_max_s")

    def ap_loss():
        # the AP the client is on vanishes at once: loss detection + scan + join, not a handover (F-20)
        if "roamed" not in st:
            return True, SKIP + "as roam"
        # the client's cable is down in the window: `lab.sh air` cannot reach it, so its own air is switched
        # from inside the window (5 s after the commands start = when `move` runs here); the AP's from the host
        cut = ("cut", f"( sleep 5; echo '{a2.lab_n} off' > /etc/hwsim-air.conf ) &")
        return window([cut, ping()], a2, a1, "ap_loss_max_s", during=lambda: air((a2, client, "off")))

    def uplink():
        return ((ctl.device(a2.host) or {}).get("uplink") or {}).get("type")

    def mesh_failover():
        if not lab_vm:
            return True, SKIP + "needs the lab's cable control; on hardware pull the cable by hand"
        common.lab(conf, "cable", a2.lab_n, "down")
        st["cable"] = "down"
        time.sleep(10)  # the old SSH path is gone by now: reachable again means over the mesh
        d = common.wait_for(a2.reachable, 180)
        con = d is not None and plug._connected(a2, ctl, secs=300)
        # the controller shows the new uplink an inform or two after the AP is back
        seen = bool(con) and common.wait_for(lambda: uplink() == "wireless", 120) is not None
        return seen, (f"reachable over the mesh after {None if d is None else d + 10} s, "
                      f"controller {'connected' if con else 'NOT connected'}, uplink type {uplink()}")

    def rx():
        try:
            return int(a1.ssh("cat /sys/class/net/br-lan/statistics/rx_packets")[1].strip())
        except ValueError:
            return None

    def loop_guard():
        if st.get("cable") == "down":
            common.lab(conf, "cable", a2.lab_n, "up")  # cable and mesh both there: the moment a loop would form
            st["cable"] = "up"
            time.sleep(5)
        p0 = rx()
        time.sleep(10)
        p1 = rx()
        pps = None if None in (p0, p1) else (p1 - p0) / 10
        rules = [t.ssh(f"nft list table bridge openuf_l2guard 2>/dev/null | grep -c '{BGA}'")[1].strip()
                 for t in (a1, a2)]
        ok = pps is not None and pps <= s["storm_max_pps"] and all(r not in ("", "0") for r in rules)
        return ok, f"{pps} packets/s into {a1.name}'s bridge (limit {s['storm_max_pps']}); BPDU drop rules {rules}"

    def mesh_restore():
        if "cable" not in st:
            return True, SKIP + "as mesh_failover"
        d = common.wait_for(lambda: uplink() == "wire", 180)
        return d is not None and a2.reachable(), f"uplink back on the cable after {d} s"

    def both_healthy():
        problems = [p for p in (common.healthy(t, marks[t.name]) for t in (a1, a2)) if p]
        return not problems, "; ".join(problems)

    steps = [("ready", lambda: (True, "")), ("propagation", propagation), ("kv_config", kv_config), ("roam", roam),
             ("ap_loss", ap_loss), ("mesh_failover", mesh_failover), ("loop_guard", loop_guard), ("mesh_restore", mesh_restore),
             ("both_healthy", both_healthy)]
    with contextlib.ExitStack() as stack:
        before = table._applied(a1)
        if stack.enter_context(common.flip(ctl, w, {"fast_roaming_enabled": True, "bss_transition": True,
                                                    "rrm_enabled": True})):
            common.applied(a1, before)
            time.sleep(20)
        d2 = ctl.device(a2.host) or {}
        if lab_vm and d2.get("_id") and not d2.get("mesh_sta_vap_enabled"):
            # "Allow meshing to another access point": with it off openUF builds no standby station, by design
            path, before = f"rest/device/{d2['_id']}", table._applied(a2)
            ctl.put(path, {"mesh_sta_vap_enabled": True})
            stack.callback(ctl.put, path, {"mesh_sta_vap_enabled": False})
            common.applied(a2, before)
            time.sleep(20)
        try:
            checks = common.run_checks(steps)
        finally:
            if lab_vm:
                common.lab(conf, "cable", a2.lab_n, "up")
                air((client, a1, "default"), (a1, client, "default"), (client, a2, "default"), (a2, client, "default"))
            common.leave(client)
    return common.finish(conf, "multi", checks)
