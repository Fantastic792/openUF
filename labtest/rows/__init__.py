"""Rows of the feature table: one per in-scope controller field, with its risk. CHECKS holds the real checks."""
import re

from labtest import catalog

CUT = re.compile(r"(^|_)(vlan|network|networkconf|ip|ssh|uplink|disabled|switch|port|lan|stp|dhcp|dns|gateway)(_|$)")
HW = re.compile(r"stp|jumbo|flowctrl|dot1x|switch|mirror|lag|igmp")
PORT_OBJS = (catalog.PORTS, "PortConf")  # switch port settings: may cut the uplink, a VM has no switch
ORDER = {"safe": 0, "cutoff": 2}  # skipped rows sit between: reported, never run
# row name -> {"set": callable(obj) -> dict, "check": callable(blocks, new) -> (bool, str) (optional),
#              "risk"/"needs" (optional, default "safe"/"vm")}
CHECKS = {}


def risk(field):
    if field["key"].startswith("x_"):
        return "skip: secret"
    if field["kind"] == "other":
        return "skip: not a simple on/off or pick-one"
    return "cutoff" if field["obj"] in PORT_OBJS or CUT.search(field["key"]) else "safe"


def needs(obj, key):
    """"hw": only real hardware can say more than sent or not sent (Part 3)."""
    hw = obj in PORT_OBJS or obj == "Setting.global_switch" or (obj == "Device" and HW.search(key))
    return "hw" if hw else "vm"


def build(fields):
    keys = {}  # obj -> every field the controller knows for it: the put-back restores them all
    for f in fields:
        keys.setdefault(f["obj"], []).append(f["key"])
    out = [{"name": f"{f['obj']}.{f['key']}", "obj": f["obj"], "key": f["key"], "field": f, "risk": risk(f),
            "needs": needs(f["obj"], f["key"]), "set": None, "keys": keys[f["obj"]]} for f in fields
           if catalog.in_scope(f["obj"]) and f"{f['obj']}.{f['key']}" not in CHECKS]
    # a registry row replaces the automatic row of the same name (or stands alone, e.g. WlanConf.dtim)
    out += [{"name": n, "obj": n.rsplit(".", 1)[0], "key": n.rsplit(".", 1)[1], "field": None,
             "risk": c.get("risk", "safe"), "needs": c.get("needs", "vm"), "set": c["set"], "check": c.get("check"),
             "keys": keys.get(n.rsplit(".", 1)[0], [])} for n, c in CHECKS.items()]
    return sorted(out, key=lambda r: ORDER.get(r["risk"], 1))


from labtest.rows import linked, ports, wifi  # noqa: E402 -- fill CHECKS; need the names above

for _m in (wifi, linked, ports):
    _m.register(CHECKS)
