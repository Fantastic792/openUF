"""The controller's own field list (api/fields/*.json from ace.jar): what each field is and how to flip it."""
import glob
import json
import os
import re

WORDS = re.compile(r"^\^?\(?([\w.+-]+(?:\|[\w.+-]+)+)\)?\$?$")


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
        for key, spec in body.items():
            k, values = kind(spec)
            out.append({"obj": obj, "key": key, "kind": k, "values": values})
    return out


def in_scope(obj):
    return obj in ("WlanConf", "Device") or (obj.startswith("Setting") and not obj.startswith("SettingSuper"))


def section(obj):
    if not obj.startswith("Setting"):
        return None
    return re.sub(r"(?<!^)([A-Z])", r"_\1", obj[len("Setting"):]).lower()


def summary(fields):
    """Counts for the catalog stage: files, fields, in-scope fields per group, kinds in scope."""
    groups, kinds = {"WlanConf": 0, "Device": 0, "Setting": 0}, {"bool": 0, "enum": 0, "other": 0}
    for f in fields:
        if in_scope(f["obj"]):
            groups["Setting" if f["obj"].startswith("Setting") else f["obj"]] += 1
            kinds[f["kind"]] += 1
    return {"files": len({f["obj"] for f in fields}), "fields": len(fields), "in_scope": groups, "kinds": kinds}


def flip(field, current):
    if field["kind"] == "bool":
        return not bool(current)
    if field["kind"] == "enum" and current in field["values"]:
        v = field["values"]
        return v[(v.index(current) + 1) % len(v)]
    return None
