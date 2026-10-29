#!/usr/bin/env python3
"""Field reports: hardware test results anyone can send in (field-reports/README.md).

    python3 tools/field_report.py ids                 the feature ids a report may name
    python3 tools/field_report.py check FILE...       validate reports; exit 1 on any error
    python3 tools/field_report.py table FILE...       one Markdown row per result, for the README

Standard library only (tomllib, Python 3.11+), so CI and a contributor's machine need
nothing installed. A report that does not validate is not merged: the checker refuses
unknown feature ids and outcomes, and anything that looks like a secret or a public
address, because a report is published as it is.
"""
import datetime
import ipaddress
import re
import sys
import tomllib

FORMAT = 1

# One id per row of the README's results table. Add an id here before a report may use it.
FEATURES = {
    "install": "Package or file install, and an upgrade in place",
    "adoption": "Found on the LAN and adopted (L2)",
    "adoption-l3": "Adopted by inform URL from another subnet (set-inform)",
    "forget": "Forget in the controller, then adopt again",
    "wpa2": "A WPA2 network, a client joined",
    "wpa3": "A WPA3 (SAE) or WPA2/WPA3 network, a client joined with SAE",
    "owe": "Enhanced Open (OWE), a client joined with OWE",
    "ppsk": "Private pre-shared keys: each key's client on its own VLAN",
    "vlan-ssid": "A WiFi network on a tagged VLAN, a client got an address on it",
    "hidden-ssid": "Hide WiFi Name",
    "radio-settings": "Channel, width and transmit power from the controller",
    "ft-openuf": "802.11r fast roaming between two openUF APs",
    "ft-unifi": "802.11r fast roaming between openUF and a genuine UniFi AP",
    "band-steering": "Band steering moves a 2.4 GHz client to 5 GHz",
    "min-rssi": "Minimum RSSI disconnects and refuses a weak client",
    "load-balance": "Load balance disconnects above the client cap",
    "airtime-fairness": "Airtime Fairness on and off, measured",
    "speed-limit": "Per-client speed limit, measured with a throughput test",
    "schedule": "WiFi Blackout Schedule takes the network off and back on",
    "blocker": "Multicast and broadcast blocker, with its exception list",
    "ap-name": "The AP name in the beacon, seen by a WiFi scanner",
    "client-block": "Blocking a client in the controller",
    "locate": "Locate blinks the LED and stops",
    "guest-portal": "Guest portal: redirect, authorize, browse",
    "uplink-monitor": "Uplink Connectivity Monitor takes the SSIDs off and back on",
    "mesh-one-hop": "Wireless uplink to a wired AP: failover and failback",
    "mesh-multi-hop": "Wireless uplink across two hops or more, no loop",
    "mesh-cold-boot": "An AP booted with no cable comes up on the mesh",
    "port-vlan": "Per-port VLAN from the controller's port settings",
    "clock": "A wrong clock after boot is corrected",
    "statistics": "Clients, WiFi Experience, radios and wired hosts in the controller",
    "rf-scan": "Neighbouring APs and the controller's RF scan",
    "openwrt-24.10": "Runs on OpenWrt 24.10 with opkg",
    "selfcheck": "tools/selfcheck.sh with the controller's features on",
    "board-profile": "A new or changed hardware profile (modelmap) works on the board",
}

OUTCOMES = ("pass", "fail", "partial", "not-run")

REQUIRED = {
    "format": int,
    "date": datetime.date,
    "reporter": str,
    "board": str,
    "openwrt": str,
    "openuf": str,
    "controller": str,
}

# What must never be published. Checked on every string in the file.
SECRET_PATTERNS = [
    (re.compile(r"(?i)\b(psk|passphrase|password|passwd|x_passphrase|authkey|secret|token)\s*[=:]\s*\S{6,}"),
     "a key, password or token"),
    (re.compile(r"(?i)\bBEGIN [A-Z ]*PRIVATE KEY"), "a private key"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "a GitHub token"),
]
IPV4 = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")


def strings(node, path=""):
    if isinstance(node, str):
        yield path, node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from strings(v, f"{path}.{k}" if path else k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from strings(v, f"{path}[{i}]")


def check(path):
    errors = []
    try:
        with open(path, "rb") as f:
            doc = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        return [f"cannot read: {e}"], None
    for key, typ in REQUIRED.items():
        if key not in doc:
            errors.append(f"missing `{key}`")
        elif not isinstance(doc[key], typ) or (typ is int and isinstance(doc[key], bool)):
            errors.append(f"`{key}` must be a {typ.__name__}")
    if doc.get("format") not in (None, FORMAT):
        errors.append(f"`format` is {doc.get('format')!r}; this checker reads format {FORMAT}")
    results = doc.get("result")
    if not isinstance(results, list) or not results:
        errors.append("no [[result]] entries")
        results = []
    for i, r in enumerate(results):
        where = f"result[{i}]"
        if not isinstance(r, dict):
            errors.append(f"{where} is not a table")
            continue
        feat = r.get("feature")
        if feat not in FEATURES:
            errors.append(f"{where}: unknown feature {feat!r} (see `field_report.py ids`)")
        if r.get("outcome") not in OUTCOMES:
            errors.append(f"{where}: outcome must be one of {', '.join(OUTCOMES)}")
        if not isinstance(r.get("how"), str) or not r["how"].strip():
            errors.append(f"{where}: `how` (what was done) is required")
        if r.get("outcome") in ("pass", "fail", "partial") and not str(r.get("evidence", "")).strip():
            errors.append(f"{where}: a {r.get('outcome')} needs `evidence` (log lines, command output, measurements)")
    for where, s in strings(doc):
        for pat, what in SECRET_PATTERNS:
            if pat.search(s):
                errors.append(f"{where}: looks like {what}; remove it")
        for m in IPV4.findall(s):
            try:
                ip = ipaddress.ip_address(m)
            except ValueError:
                continue
            if ip.is_global:
                errors.append(f"{where}: public address {m}; remove or mask it")
    return errors, doc


def cmd_check(files):
    bad = 0
    for path in files:
        errors, _ = check(path)
        if errors:
            bad += 1
            print(f"FAIL {path}")
            for e in errors:
                print(f"     {e}")
        else:
            print(f"ok   {path}")
    return 1 if bad else 0


def cmd_table(files):
    mark = {"pass": "✅", "fail": "❌", "partial": "⚠️", "not-run": "—"}
    print("| Feature | Board | openUF | OpenWrt | Controller | Result | Date | Reporter |")
    print("|---|---|---|---|---|---|---|---|")
    status = 0
    for path in files:
        errors, doc = check(path)
        if errors:
            print(f"skipped {path}: does not validate", file=sys.stderr)
            status = 1
            continue
        for r in doc["result"]:
            summary = " ".join(r["how"].split())
            if len(summary) > 120:
                summary = summary[:117] + "..."
            print(f"| {r['feature']} | {doc['board']} | {doc['openuf']} | {doc['openwrt']} | "
                  f"{doc['controller']} | {mark[r['outcome']]} {summary} | {doc['date']} | {doc['reporter']} |")
    return status


def main(argv):
    if len(argv) >= 1 and argv[0] == "ids":
        for k, v in FEATURES.items():
            print(f"{k:18} {v}")
        return 0
    if len(argv) >= 2 and argv[0] == "check":
        return cmd_check(argv[1:])
    if len(argv) >= 2 and argv[0] == "table":
        return cmd_table(argv[1:])
    print(__doc__.strip())
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
