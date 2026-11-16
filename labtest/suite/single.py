"""Single-AP suite: boot, the client's DHCP / DNS / reach over WiFi, throughput, speed limit, VLAN tag and
isolation, guest rules, client isolation, recovery after a killed daemon and a stopped controller.
DHCP and DNS are the upstream's, not openUF's: the checks prove a WiFi client gets them through the AP."""
import time

from labtest import fixtures, table, target
from labtest.safety import plug
from labtest.suite import common
from labtest.suite.common import SKIP

NAMES = ["ready", "boot", "mgmt", "client_join", "client_dhcp", "client_dns", "client_reach", "throughput",
         "rate_limit", "vlan_tag", "vlan_isolation", "guest_firewall", "client_isolation", "daemon_recovery",
         "controller_recovery", "no_lua_error"]
LIMIT = 5  # Mbit/s down for rate_limit
# the servers DHCP gave an OpenWrt client: its own dnsmasq never forwards a plain name, so ask them
DNS = "/tmp/resolv.conf.d/resolv.conf.auto"


def run(conf, ctl):
    s = common.cfg(conf)
    bad = common.ready(conf, s, ctl, ("ap1", "client"))
    if bad:
        return common.finish(conf, "single", [{"name": "ready", "ok": False, "detail": "; ".join(bad)}])
    ap, client = target.get_target(conf, s["ap1"]), target.get_target(conf, s["client"])
    w, wired, st = common.wlan(conf, ctl), s["wired_ip"], {}

    def boot():
        try:
            ap.ssh("reboot", timeout=10)
            if not ap.wait(False, 60):
                return False, "still on SSH 60 s after reboot"
            t0 = time.monotonic()
            if not ap.wait(True, 180):
                return False, "not back on SSH after 180 s"
            ssh_s = round(time.monotonic() - t0)
            d = common.wait_for(lambda: table._pid(ap), 120)
            if d is None:
                return False, f"SSH after {ssh_s} s; openUF not running 120 s later"
            con = plug._connected(ap, ctl, secs=300)
            air = common.wait_for(lambda: common.ssids(ap), 120)
            return con and air is not None, (f"SSH {ssh_s} s, openUF +{d} s, controller "
                                             f"{'connected' if con else 'NOT connected in 300 s'}, "
                                             f"WiFi {'on' if air is not None else 'NOT on in 120 s'}")
        finally:
            st["mark"] = common.mark(ap, "suite-single")  # after the reboot: it empties the log

    def mgmt():
        addr = ap.ssh("ip -4 -o addr show scope global")[1]
        # busybox prints every route for "show default": keep the default line only
        route = next((r.strip() for r in ap.ssh("ip route show default")[1].splitlines() if r.startswith("default")), "")
        return "inet " in addr and bool(route), f"default route: {route or 'none'}"

    def client_join():
        d = common.join(s, client, w, bssid=common.ap_bssid(s, ap, client, w))
        if d is None:
            return False, "the client got no address over WiFi in 90 s"
        cmds = [("link", "iw dev $IF link"), ("addr", "ip -4 -o addr show dev $IF"),
                ("ping", f"ping -c 5 -W 1 -I $IF {wired}"),
                ("dns", f"nslookup {s['dns_name']} $(awk '/^nameserver/ {{print $2; exit}}' {DNS} 2>/dev/null) "
                        ">/dev/null 2>&1; echo rc=$?")]
        if s["min_mbps"]:
            cmds.append(("iperf", f"iperf3 -c {wired} -B $A -t 5 -J"))
        with common.iperf_server(s):
            st["w"] = common.wifi_only(s, client, cmds, 40 if s["min_mbps"] else 25)
        b = common.bssid(st["w"].get("link", ""))
        ok = b in common.bssids(ap)
        return ok, f"joined after {d} s; associated to " + ("the AP" if ok else "ANOTHER access point" if b else "nothing")

    def window(name):
        if "w" not in st:
            raise RuntimeError("the client window did not run")
        return st["w"].get(name, "")

    def client_dhcp():
        a = window("addr").split()
        return "inet" in a, "address over WiFi: " + (a[a.index("inet") + 1] if "inet" in a else "none")

    def client_dns():
        return "rc=0" in window("dns"), f"nslookup {s['dns_name']} over WiFi"

    def client_reach():
        lost = common.loss(window("ping"))
        return lost is not None and lost <= 20, f"{lost}% ping loss to the wired host over WiFi"

    def throughput():
        if not s["min_mbps"]:
            return True, SKIP + "suite.min_mbps is 0"
        m = common.mbps(window("iperf"))
        return m is not None and m >= s["min_mbps"], f"{m} Mbit/s up (floor {s['min_mbps']})"

    def settle(before):
        ok = common.applied(ap, before) is not None
        time.sleep(15)  # cfgversion is written before the WiFi interfaces are back
        return ok

    def rate_limit():
        if not s["min_mbps"]:
            return True, SKIP + "suite.min_mbps is 0"
        before = table._applied(ap)
        path, _ = fixtures.make(ctl, "UserGroup", conf, ap.host)
        ctl.put(path, {"qos_rate_max_down": LIMIT * 1000, "qos_rate_max_up": 2000})
        try:
            if not settle(before):
                return False, "the limit was not applied in 90 s"
            with common.iperf_server(s):
                r = common.wifi_only(s, client, [("down", f"iperf3 -c {wired} -B $A -t 5 -J -R")], 30)
            m = common.mbps(r.get("down", ""))
            return m is not None and LIMIT * 0.5 <= m <= LIMIT * 1.3, f"{m} Mbit/s down under a {LIMIT} limit"
        finally:
            before = table._applied(ap)
            fixtures.clean(ctl, conf)
            settle(before)

    def vlan_tag():
        vh, vc = s.get("vlan_host_ip"), s.get("vlan_client_ip")
        if not (vh and vc and s["host_if"]):
            st["vlan"] = None
            return True, SKIP + "suite.vlan_host_ip, vlan_client_ip or host_if not set"
        vif = f"{s['host_if']}.{common.VLAN}"
        before = table._applied(ap)
        fixtures.make(ctl, "NetworkConf", conf, ap.host)
        for argv in (["ip", "link", "add", "link", s["host_if"], "name", vif, "type", "vlan", "id", str(common.VLAN)],
                     ["ip", "addr", "add", f"{vh}/24", "dev", vif], ["ip", "link", "set", vif, "up"]):
            common.sh(argv)
        try:
            if not settle(before):
                return False, f"VLAN {common.VLAN} was not applied in 90 s"
            cmds = [("wait", "sleep 30"), ("addr", "ip -4 -o addr show dev $IF"),
                    ("ping", f"ip addr add {vc}/24 dev $IF; ping -c 3 -W 1 -I $IF {vh}; ip addr del {vc}/24 dev $IF")]
            r = common.wifi_only(s, client, cmds, 50)
            st["vlan"] = r.get("addr", "")
            lost = common.loss(r.get("ping", ""))
            return lost is not None and lost <= 34, f"{lost}% ping loss to the host's VLAN {common.VLAN} address"
        finally:
            before = table._applied(ap)
            fixtures.clean(ctl, conf)
            common.sh(["ip", "link", "del", vif])
            settle(before)

    def vlan_isolation():
        if "vlan" not in st:
            return False, "the VLAN window did not run"
        if st["vlan"] is None:
            return True, SKIP + "as vlan_tag"
        return "inet " not in st["vlan"], ("no address from the untagged network" if "inet " not in st["vlan"]
                                           else "the client on the VLAN got an untagged address")

    def flipped(body, probe):
        before = table._applied(ap)
        with common.flip(ctl, w, body) as changed:  # already set: no push comes, so nothing to wait for
            if changed and not settle(before):
                return None
            out = probe()
            before = table._applied(ap)
        if changed:
            settle(before)
        return out

    def guest_firewall():
        out = flipped({"is_guest": True}, lambda: ap.ssh("nft list table bridge openuf_guest"))
        if out is None:
            return False, "the guest flag was not applied in 90 s"
        n = out[1].count("drop")
        return out[0] == 0 and n > 0, f"{n} drop rules in table bridge openuf_guest (rules only, no traffic test)"

    def client_isolation():
        out = flipped({"l2_isolation": True}, lambda: common.hostapd(ap, "^ap_isolate=1"))
        if out is None:
            return False, "isolation was not applied in 90 s"
        return bool(out), f"ap_isolate=1 on {len(out)} BSS (config only: one client cannot test traffic)"

    def daemon_recovery():
        old = table._pid(ap)
        if not old:
            return False, "openUF was not running"
        ap.ssh("kill -9 " + " ".join(old.split()))
        d = common.wait_for(lambda: table._pid(ap) not in (None, old), 120)
        con = d is not None and plug._connected(ap, ctl, secs=300)
        return bool(con), f"restarted after {d} s" + ("" if con else "; NOT connected again")

    def controller_up():
        try:
            ctl.login()
            return isinstance(ctl.devices(), list)
        except (RuntimeError, OSError, ValueError):  # ValueError: a starting controller's page is not JSON
            return False

    def connected():
        try:
            d = ctl.device(ap.host)
            return bool(d and d.get("adopted") and d.get("state") == 1)
        except (RuntimeError, OSError, ValueError):
            return False

    def controller_recovery():
        if ap.kind != "vm":
            return True, SKIP + "not a lab VM: a controller outside the lab is never stopped"
        name = s["controller_container"]
        rc, out = common.sh(["docker", "stop", name])
        if rc != 0:
            return False, f"docker stop {name}: {out.strip()[-100:]}"
        try:
            time.sleep(60)
            n = len(common.ssids(ap))
        finally:
            common.sh(["docker", "start", name])
        back = common.wait_for(controller_up, 300)
        con = back is not None and common.wait_for(connected, 600) is not None
        return n > 0 and bool(con), (f"{n} SSIDs stayed on the air with the controller down; controller back "
                                     f"after {back} s, AP {'connected' if con else 'NOT connected'}")

    def no_lua_error():
        problem = common.healthy(ap, st.get("mark", "suite-single"))
        return not problem, problem

    steps = [("ready", lambda: (True, "")), ("boot", boot), ("mgmt", mgmt), ("client_join", client_join),
             ("client_dhcp", client_dhcp), ("client_dns", client_dns), ("client_reach", client_reach),
             ("throughput", throughput), ("rate_limit", rate_limit), ("vlan_tag", vlan_tag),
             ("vlan_isolation", vlan_isolation), ("guest_firewall", guest_firewall),
             ("client_isolation", client_isolation), ("daemon_recovery", daemon_recovery),
             ("controller_recovery", controller_recovery), ("no_lua_error", no_lua_error)]
    try:
        checks = common.run_checks(steps)
    finally:
        common.leave(client)
    return common.finish(conf, "single", checks)
