"""The controller's own field list (api/fields/*.json from ace.jar): what each field is and how to flip it."""
import glob
import json
import os
import re

WORDS = re.compile(r"^\^?\(?([\w.+-]+(?:\|[\w.+-]+)+)\)?\$?$")
# ring 2: objects a WiFi or a port only points at, plus one switch port's settings on the device
RING2 = ("PortConf", "NetworkConf", "RadiusProfile", "UserGroup", "User", "Hotspot2Conf", "WlanGroup", "ScheduleTask",
         "BroadcastGroup", "ChannelPlan", "HotspotOp", "HotspotPackage")
PORTS = "Device.port_overrides"


def kind(spec):
    m = WORDS.match(spec) if isinstance(spec, str) else None
    if not m:
        return "other", None
    words = m.group(1).split("|")
    if sorted(words) == ["false", "true"]:
        return "bool", [True, False]
    return "enum", words


def load(fields_dir):
    out = []
    for path in sorted(glob.glob(os.path.join(fields_dir, "*.json"))):
        try:
            with open(path) as f:
                body = json.load(f)
        except (OSError, ValueError):
            continue  # an unreadable file is skipped, not fatal
        if not isinstance(body, dict):
            continue
        obj = os.path.basename(path)[:-5]
        # Setting.json holds every site section as {section: {key: spec}}: one level deeper
        groups = ({f"Setting.{s}": b for s, b in body.items() if isinstance(b, dict)} if obj == "Setting"
                  else {obj: body})
        po = body.get("port_overrides") if obj == "Device" else None
        if isinstance(po, list) and po and isinstance(po[0], dict):  # one port's settings: one level deeper
            groups[PORTS] = {k: v for k, v in po[0].items() if k != "port_idx"}  # port_idx is the address
        for o, b in groups.items():
            for key, spec in b.items():
                k, values = kind(spec)
                out.append({"obj": o, "key": key, "kind": k, "values": values})
    return out


def ring1(obj):
    return obj in ("WlanConf", "Device") or (obj.startswith("Setting.") and not obj.startswith("Setting.super_"))


def in_scope(obj):
    return ring1(obj) or obj in RING2 or obj == PORTS


def section(obj):
    return obj[len("Setting."):] if obj.startswith("Setting.") else None


def summary(fields):
    """Counts for the catalog stage: files, fields, ring-1 fields per group and their kinds, ring-2 fields per object."""
    groups, kinds, ring2 = {"WlanConf": 0, "Device": 0, "Setting": 0}, {"bool": 0, "enum": 0, "other": 0}, {}
    for f in fields:
        if ring1(f["obj"]):
            groups["Setting" if f["obj"].startswith("Setting") else f["obj"]] += 1
            kinds[f["kind"]] += 1
        elif in_scope(f["obj"]):
            ring2[f["obj"]] = ring2.get(f["obj"], 0) + 1
    return {"files": len({f["obj"].split(".")[0] for f in fields}), "fields": len(fields), "in_scope": groups,
            "sections": len({f["obj"] for f in fields if f["obj"].startswith("Setting.") and ring1(f["obj"])}),
            "kinds": kinds, "ring2": ring2}


def flip(field, current):
    if field["kind"] == "bool":
        return not bool(current)
    if field["kind"] == "enum" and current in field["values"]:
        v = field["values"]
        return v[(v.index(current) + 1) % len(v)]
    return None
