"""Ring-2 objects for the table: one object per kind named NAME, tied to the test target so the controller has a
reason to send it. Every tie is journaled (table-ties.json) so a dead run's ties go back first; clean() undoes them
and deletes every NAME object. RADIUS secrets are random per run and scrubbed from everything saved."""
import json
import os
import secrets

from labtest import catalog, unifi

NAME = "labtest-fixture"
WLAN_TIE = {"UserGroup": "usergroup_id", "NetworkConf": "networkconf_id", "RadiusProfile": "radiusprofile_id",
            "Hotspot2Conf": "hotspot2conf_id"}
SECRETS = set()  # made this run; never written anywhere


def _body(obj):
    b = {"name": NAME}
    if obj == "UserGroup":
        b.update(qos_rate_max_down=-1, qos_rate_max_up=-1)
    elif obj == "NetworkConf":
        b.update(purpose="vlan-only", vlan=77, vlan_enabled=True, enabled=True)
    elif obj == "RadiusProfile":
        s = secrets.token_hex(16)
        SECRETS.add(s)
        b["auth_servers"] = [{"ip": "192.0.2.10", "port": 1812, "x_secret": s}]  # TEST-NET address: never answers
    elif obj == "PortConf":  # without it a flip adds it and forward "all" never comes back (only "native")
        b["tagged_vlan_mgmt"] = "auto"
    elif obj == "User":
        b["mac"] = "02:00:00:00:00:78"  # made up
    return b


def scrub(data):
    """`data` with every secret made this run replaced: for anything that is saved."""
    text = json.dumps(data)
    for s in SECRETS:
        text = text.replace(s, "<secret>")
    return json.loads(text)


def _ties_path(conf):
    return os.path.join(conf["results_dir"], "table-ties.json")


def _ties(conf):
    try:
        with open(_ties_path(conf)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def _tie(ctl, conf, path, old, new):
    ties = _ties(conf)
    if not any(t["path"] == path and t["old"].keys() == old.keys() for t in ties):  # the first old value is the real one
        os.makedirs(conf["results_dir"], exist_ok=True)
        with open(_ties_path(conf), "w") as f:
            json.dump(scrub(ties + [{"path": path, "old": old}]), f)
    ctl.put(path, new)


def make(ctl, obj, conf, host):
    """(path, object) of the NAME object of this kind, made and tied on first use. Refused when the controller
    will not make one."""
    rest = f"rest/{obj.lower()}"
    o = next((x for x in ctl.get(rest) if x.get("name") == NAME), None) or ctl.post(rest, _body(obj))[0]
    if obj in WLAN_TIE:
        w = next(x for x in ctl.wlans() if x.get("name") == conf["row_wlan"])
        new = {WLAN_TIE[obj]: o["_id"], **({"hotspot2conf_enabled": True} if obj == "Hotspot2Conf" else {})}
        if any(w.get(k) != v for k, v in new.items()):
            _tie(ctl, conf, f"rest/wlanconf/{w['_id']}", {k: w.get(k, "" if k.endswith("_id") else False) for k in new},
                 new)
    elif obj == "PortConf" and conf.get("row_port"):
        d = ctl.device(host)
        new = {"port_overrides": [{"port_idx": conf["row_port"], "portconf_id": o["_id"]}]}
        if (d.get("port_overrides") or []) != new["port_overrides"]:
            _tie(ctl, conf, f"rest/device/{d['_id']}", {"port_overrides": d.get("port_overrides") or []}, new)
    return f"{rest}/{o['_id']}", o


def clean(ctl, conf):
    """Untie (last tie first), then delete every NAME object. Returns how many were deleted."""
    for t in reversed(_ties(conf)):
        ctl.put(t["path"], t["old"])
    if os.path.exists(_ties_path(conf)):
        os.remove(_ties_path(conf))
    n = 0
    for obj in catalog.RING2:
        rest = f"rest/{obj.lower()}"
        try:
            found = [x for x in ctl.get(rest) if x.get("name") == NAME]
        except (unifi.Refused, RuntimeError):  # a kind this controller has no list for
            continue
        for x in found:
            ctl.delete(f"{rest}/{x['_id']}")
            n += 1
    return n
