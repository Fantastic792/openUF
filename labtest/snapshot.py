"""The router's whole config as lines per section, secrets replaced by a short hash, and a diff."""
import hashlib
import re

SECTIONS = {
    "uci": "uci show",
    "hostapd": 'for f in /var/run/hostapd-*.conf; do [ -e "$f" ] && echo "## $f" && cat "$f"; done',
    "nft": "nft -s list ruleset",  # -s: no counters
    "tc": "tc qdisc show",
    "ip": "ip -br link; ip -br addr",
}
MARK = "@@labtest@@ "
SECRET = re.compile(r"key|psk|passphrase|password|secret|token|r0kh|r1kh")
NOT_SECRET = re.compile(r"key_mgmt|rekey")  # read by the checks; not secrets


def redact(line):
    name, eq, value = line.partition("=")
    if eq and SECRET.search(NOT_SECRET.sub("", name.lower())):
        return f"{name}=<{hashlib.sha256(value.encode()).hexdigest()[:8]}>"
    return line


def take(t):
    script = "; ".join(f"echo '{MARK}{name}'; {cmd}" for name, cmd in SECTIONS.items())
    rc, out = t.ssh(script + " 2>&1", timeout=60)
    if rc == 255:
        raise RuntimeError(f"snapshot of {t.name}: target not reachable")
    snap, cur = {name: [] for name in SECTIONS}, None
    for line in out.splitlines():
        if line.startswith(MARK):
            cur = line[len(MARK):]
        elif cur in snap:
            snap[cur].append(redact(line))
    return snap


def diff(a, b, ignore=frozenset()):
    out = []
    for sec in sorted(set(a) | set(b)):
        old, new = a.get(sec, []), b.get(sec, [])
        so, sn = set(old), set(new)
        out += [f"{sec}: -{x}" for x in old if x not in sn] + [f"{sec}: +{x}" for x in new if x not in so]
    return [x for x in out if x not in ignore]


def volatile(a, b):
    return frozenset(diff(a, b))


def bss(snap, ssid):
    blocks, cur = [], None
    for line in snap.get("hostapd", []):
        if line.startswith(("interface=", "bss=")):
            cur = [line]
            blocks.append(cur)
        elif line.startswith("## "):
            cur = None
        elif cur is not None:
            cur.append(line)
    return [b for b in blocks if f"ssid={ssid}" in b]
