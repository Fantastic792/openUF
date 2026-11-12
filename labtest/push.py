"""openUF's own push dump (conf.lua debug_dump_file): turn it on and off, read the pushes."""
import json

from labtest.snapshot import redact

DUMP = "/tmp/labtest-dump"
CONF = "/opt/openuf/conf.lua"
BAK = CONF + ".labtest-bak"
NIL = "debug_dump_file = nil,"
ON = f'debug_dump_file = "{DUMP}",'
RESTART = "/etc/init.d/openuf restart"


def on(t):
    t.ssh(f"if [ -f {BAK} ]; then mv {BAK} {CONF}; fi")  # a run that died left its backup: put it back first
    if t.ssh(f"grep -q '{NIL}' {CONF}")[0] != 0:
        raise RuntimeError(f"push.on {t.name}: no '{NIL}' line in {CONF}")
    rc, out = t.ssh(f"cp {CONF} {BAK} && sed -i 's|{NIL}|{ON}|' {CONF} && rm -f {DUMP} && {RESTART}")
    if rc != 0:
        raise RuntimeError(f"push.on {t.name} failed ({rc}): {out.strip()}")


def off(t):
    rc, out = t.ssh(f"if [ -f {BAK} ]; then mv {BAK} {CONF}; fi; rm -f {DUMP}; {RESTART}")
    if rc != 0:
        raise RuntimeError(f"push.off {t.name} failed ({rc}): {out.strip()}")


def _lines(text):
    return dict(line.split("=", 1) for line in (text or "").splitlines() if "=" in line)


def parse(text):
    out = []
    for line in text.splitlines():
        try:
            msg = json.loads(line.split(" ", 1)[1])
        except (IndexError, ValueError):
            continue
        if not isinstance(msg, dict) or not isinstance(msg.get("system_cfg"), str):
            continue
        raw = _lines(msg["system_cfg"])
        raw.update({"mgmt." + k: v for k, v in _lines(msg.get("mgmt_cfg") if isinstance(msg.get("mgmt_cfg"), str)
                                                      else "").items()})
        keys = {k: redact(f"{k}={v}").split("=", 1)[1] for k, v in raw.items()}
        # 10.6.106 sends cfgversion both at the top and in mgmt_cfg
        out.append({"cfgversion": keys.get("mgmt.cfgversion") or msg.get("cfgversion"), "keys": keys})
    return out


def pushes(t):
    # shortcut: only the last 5 pushes come back (the dump holds every 10 s reply), enough to compare the newest two
    rc, out = t.ssh(f"grep '\"system_cfg\"' {DUMP} 2>/dev/null | tail -n 5", timeout=30)
    return parse(out)


def sent(old, new):
    a, b = old["keys"], new["keys"]
    out = []
    for k in sorted(set(a) | set(b)):
        if k == "mgmt.cfgversion" or a.get(k) == b.get(k):
            continue
        out += ([f"-{k}={a[k]}"] if k in a else []) + ([f"+{k}={b[k]}"] if k in b else [])
    return out
