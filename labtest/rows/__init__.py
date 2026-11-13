"""Rows of the feature table: one per in-scope controller field, with its risk. CHECKS holds the real checks."""
import re

from labtest import catalog

CUT = re.compile(r"(^|_)(vlan|network|networkconf|ip|ssh|uplink|disabled|switch|port|lan|stp|dhcp|dns|gateway)(_|$)")
ORDER = {"safe": 0, "cutoff": 2}  # skipped rows sit between: reported, never run
CHECKS = {}  # row name -> {"set": callable(obj) -> dict, "check": callable(blocks, new) -> (bool, str)}


def risk(field):
    if field["key"].startswith("x_"):
        return "skip: secret"
    if field["kind"] == "other":
        return "skip: not a simple on/off or pick-one"
    return "cutoff" if CUT.search(field["key"]) else "safe"


def build(fields):
    keys = {}  # obj -> every field the controller knows for it: the put-back restores them all
    for f in fields:
        keys.setdefault(f["obj"], []).append(f["key"])
    out = [{"name": f"{f['obj']}.{f['key']}", "obj": f["obj"], "key": f["key"], "field": f, "risk": risk(f),
            "needs": "vm", "set": None, "keys": keys[f["obj"]]} for f in fields if catalog.in_scope(f["obj"])
           and f"{f['obj']}.{f['key']}" not in CHECKS]
    # a registry row is safe and replaces the automatic row of the same name (or stands alone, e.g. WlanConf.dtim)
    out += [{"name": n, "obj": n.rsplit(".", 1)[0], "key": n.rsplit(".", 1)[1], "field": None, "risk": "safe",
             "needs": "vm", "set": c["set"], "check": c["check"], "keys": keys.get(n.rsplit(".", 1)[0], [])}
            for n, c in CHECKS.items()]
    return sorted(out, key=lambda r: ORDER.get(r["risk"], 1))
