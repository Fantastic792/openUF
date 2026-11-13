"""Feature table: flip one controller setting at a time, see what openUF does with it, put it back."""
import datetime
import json
import os
import re
import time

from labtest import catalog, push, report, results, snapshot, unifi
from labtest.safety import heal, plug, proof

PUSH_WAIT = 25  # seconds for the controller's push to reach openUF
APPLY_WAIT = 60  # seconds for openUF to apply it (state.json cfgversion)
POLL = 5
SETTLE = 30  # seconds the router may take to go quiet after an apply
BACK_WAIT = 70  # seconds the put-back may take: openUF's l2guard resyncs its VAP list once a minute
RESULTS = ("broken", "ignored", "not_covered", "not_sent", "works")
LUA_ERR = "traceback|attempt to (index|call|compare|perform|concatenate)|lua: "
STATE = "/etc/openuf/state.json"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NO_PUSH = {"cfgversion": None, "keys": {}}
# known noise, labelled not judged (findings.md): an 802.11r key-holder line (F4), the l2guard drop rule (F2)
KNOWN = [(re.compile(r"[ .+-]r[01]kh="), "known: F4 (controller made a new roaming key)"),
         (re.compile(r"^nft: .*ether daddr 01:80:c2:00:00:00 drop"), "known: F2 (l2guard rebuilt late)")]


def _known(lines):
    """The labels when every line is known noise, else None."""
    hits = [next((note for rx, note in KNOWN if rx.search(x)), None) for x in lines]
    return None if None in hits else sorted(set(hits))


def _note(r, extra):
    r["note"] = "; ".join(x for x in (r["note"], *extra) if x)


class CutOff(Exception):
    """The target stopped answering during a row."""


class PutBackFailed(Exception):
    """The controller did not take the old value back: the run must stop."""


def _journal(conf):
    return os.path.join(conf["results_dir"], "table-pending.json")


def _write_journal(conf, path, old):
    os.makedirs(conf["results_dir"], exist_ok=True)
    with open(_journal(conf), "w") as f:
        json.dump({"path": path, "old": old}, f)


def _drop_journal(conf):
    if os.path.exists(_journal(conf)):
        os.remove(_journal(conf))


def _applied(t):
    try:
        return json.loads(t.ssh(f"cat {STATE}")[1]).get("cfgversion")
    except (ValueError, AttributeError):
        return None


def _pid(t):
    return t.ssh("pgrep -f '^lua inform.lua'")[1].strip() or None  # ^: not the ssh shell holding this line


def _errors(t, mark):
    out = t.ssh(f"logread | sed -n '/{mark}/,$p' | grep -iE '{LUA_ERR}'", timeout=30)[1]
    return out.strip().splitlines()[:3]


def _alive(t):
    if not t.reachable():
        raise CutOff()


def _snap(env):
    """A snapshot once the router is quiet: openUF writes cfgversion before the WiFi interfaces and their
    nft/tc rules are back, so wait for two equal snapshots in a row (at most SETTLE s)."""
    try:
        a = snapshot.take(env["t"])
        for _ in range(SETTLE // POLL):
            time.sleep(POLL)
            b = snapshot.take(env["t"])
            if not snapshot.diff(a, b, env.get("ignore", frozenset())):
                return b
            a = b
        return a
    except RuntimeError:
        _alive(env["t"])
        raise


def _new_push(env, base):
    """The first push newer than `base` that sends something different, or None after push_wait."""
    for _ in range(max(1, env["push_wait"] // POLL)):
        time.sleep(POLL)
        p = push.pushes(env["t"])
        if p and p[-1]["cfgversion"] != base["cfgversion"] and push.sent(base, p[-1]):
            return p[-1]
    return None


def _wait_applied(env, p):
    for _ in range(max(1, env["apply_wait"] // POLL)):
        if _applied(env["t"]) == p["cfgversion"]:
            return True
        time.sleep(POLL)
    return False


def _health(env, pid, mark):
    t = env["t"]
    _alive(t)
    if t.ssh("/etc/init.d/openuf running")[0] != 0:
        return "openuf not running"
    if _pid(t) != pid:
        return f"openuf restarted (pid {pid} -> {_pid(t)})"
    errs = _errors(t, mark)
    return f"lua error in log: {errs[0]}" if errs else ""


def one(env, row):
    t, ctl, start = env["t"], env["ctl"], time.monotonic()
    r = {"name": row["name"], "result": "not_covered", "note": "", "sent": [], "changed": [], "also_changed": [],
         "secs": 0}

    def done(result, note=""):
        r.update(result=result, note=note, secs=round(time.monotonic() - start))
        return r

    if row["risk"].startswith("skip"):
        return done("not_covered", row["risk"][len("skip: "):])
    loc = ctl.locate(row["obj"], t.host, env["wlan"])
    if loc is None:
        return done("not_covered", "the site has no such object")
    path, cur = loc
    if row.get("set"):
        new = row["set"](cur)
    else:
        v = catalog.flip(row["field"], cur.get(row["key"]))
        new = None if v is None else {row["key"]: v}
    if not new:
        return done("not_covered", "not set on this object")
    # every known field goes back, not only the flipped one: the controller changes others on its own
    # (enhanced_iot narrows wlan_band, setting_preference resets minrate). x_* secrets are never sent or stored.
    old = {k: cur[k] for k in row.get("keys", []) if k in cur and not k.startswith("x_")}
    old.update({k: cur.get(k, False) for k in new})  # an absent flipped key goes back as False
    _write_journal(env["conf"], path, old)
    stamp = f"row {row['name']} {int(time.time())}"
    t.ssh(f"logger -t labtest '{stamp}'")
    base = (push.pushes(t) or [env["base"]])[-1]
    before, pid = _snap(env), _pid(t)
    try:
        ctl.put(path, new)
    except unifi.Refused as e:
        _drop_journal(env["conf"])
        return done("not_covered", str(e))
    pushed, cut = None, False
    try:
        # fields the controller rewrote itself (enhanced_iot narrows wlan_band): a router change may be theirs
        now = (ctl.locate(row["obj"], t.host, env["wlan"]) or (path, {}))[1]
        r["also_changed"] = sorted(k for k, v in old.items() if k not in new and now.get(k, False) != v)
        pushed = _new_push(env, base)
        if pushed is None:
            return done("not_sent")
        r["sent"] = push.sent(base, pushed)
        if not _wait_applied(env, pushed):
            _alive(t)
            return done("broken", f"push not applied in {env['apply_wait']} s")
        after = _snap(env)
        r["changed"] = snapshot.diff(before, after, env["ignore"])
        bad = _health(env, pid, f"labtest: {stamp}")
        if bad:
            return done("broken", bad)
        if not r["changed"]:
            return done("ignored")
        if row.get("check"):
            ok, why = row["check"](snapshot.bss(after, env["wlan"]), new)
            return done("works") if ok else done("broken", f"check failed: {why}")
        if _known(r["changed"]):  # a before-snapshot inside the F2 gap: the setting itself did nothing
            return done("ignored", "; ".join(_known(r["changed"])))
        return done("not_covered", "router changed, no check yet")
    except CutOff:
        cut = True
        raise
    finally:
        _put_back(env, row, r, path, old, pushed, before, cut)
        r["secs"] = round(time.monotonic() - start)


def _put_back(env, row, r, path, old, pushed, before, cut):
    t, ctl = env["t"], env["ctl"]
    try:
        ctl.put(path, old)
        now = ctl.locate(row["obj"], t.host, env["wlan"])
    except Exception as e:  # noqa: BLE001 -- any failure here leaves the setting flipped
        raise PutBackFailed(f"{row['name']}: put-back failed: {e}") from None
    if now is None or any(now[1].get(k, False) != v for k, v in old.items()):
        raise PutBackFailed(f"{row['name']}: put-back failed: the controller still holds the new value")
    if cut:
        return  # the router side is set right by the heal and the reconnect
    if pushed is not None:
        back = _new_push(env, pushed)
        if back is not None:
            _wait_applied(env, back)
        env["base"] = back or pushed
    gone = snapshot.diff(before, _snap(env), env["ignore"])
    for _ in range(BACK_WAIT // (2 * POLL)):  # each round: a sleep plus a _snap of at least one POLL
        if not gone:
            break
        time.sleep(POLL)
        gone = snapshot.diff(before, _snap(env), env["ignore"])
    if gone and _known(gone):
        _note(r, _known(gone))
    elif gone:
        r.update(result="broken", back=gone, note="; ".join(x for x in (r["note"], f"did not go back: {gone[:3]}") if x))
    _drop_journal(env["conf"])


def _baseline(env):
    """One force_push there and back: the push every row compares against."""
    path, w = env["ctl"].locate("WlanConf", env["t"].host, env["wlan"])
    base = (push.pushes(env["t"]) or [NO_PUSH])[-1]
    for _ in range(2):
        env["ctl"].force_push(w["_id"])
        p = _new_push(env, base)
        if p is None:
            raise RuntimeError("table: no push reached openUF at the start")
        _wait_applied(env, p)
        base = p
    return base


def _rest(env):
    a = _snap(env)
    time.sleep(15)
    return snapshot.volatile(a, _snap(env))


def _recover(env):
    """After a cut-off row. Returns (row note, why the run stops or None)."""
    t, ctl = env["t"], env["ctl"]
    if not t.wait(up=True, secs=proof.LIMIT + 240):
        return "cut off, did not come back", "a cut-off target did not come back"
    note = "cut off, healed by the timer" if heal.healed(t) else "cut off, came back by itself"
    if t.kind == "hw":
        return note, "cut off on hardware (the stop rule)"
    heal.disarm(t)
    proof._openuf_back(t)
    plug._connected(t, ctl)
    push.on(t)
    heal.arm(t)
    env["base"] = _baseline(env)
    return note, None


def _finish(conf, out):
    c = {k: 0 for k in RESULTS}
    for r in out["rows"]:
        c[r["result"]] += 1
    out["counts"] = c
    out["pass"] = out["finished"] and not c["broken"]


def run(conf, t, ctl, rows, push_wait=PUSH_WAIT, apply_wait=APPLY_WAIT):
    ctl.login()
    jp = _journal(conf)
    if os.path.exists(jp):  # a run died mid-row: its setting goes back before anything else
        with open(jp) as f:
            j = json.load(f)
        ctl.put(j["path"], j["old"])
        os.remove(jp)
    env = {"conf": conf, "t": t, "ctl": ctl, "wlan": conf["row_wlan"], "push_wait": push_wait,
           "apply_wait": apply_wait}
    out = {"pass": False, "finished": False, "stopped": None, "counts": {}, "rows": []}
    push.on(t)
    heal.arm(t)
    try:
        with heal.Knocker(t):
            env["ignore"] = _rest(env)
            env["base"] = _baseline(env)
            for row in rows:
                try:
                    res = one(env, row)
                except PutBackFailed as e:
                    res, out["stopped"] = {"name": row["name"], "result": "broken", "note": str(e), "sent": [],
                                           "changed": [], "secs": 0}, str(e)
                except CutOff:
                    note, out["stopped"] = _recover(env)
                    res = {"name": row["name"], "result": "broken", "note": note, "sent": [], "changed": [], "secs": 0}
                out["rows"].append(res)
                _finish(conf, out)
                results.save(conf, "table", out)
                if out["stopped"]:
                    break
            else:
                out["finished"] = True
    finally:
        try:
            push.off(t)
            out["left"] = heal.disarm(t)
        except RuntimeError as e:
            out["left"] = [str(e)]
        _finish(conf, out)
        out["pass"] = out["pass"] and not out["left"]
        results.save(conf, "table", out)
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
        results.save(conf, f"table-{results.commit(REPO)}-{stamp}", out)
        with open(os.path.join(conf["results_dir"], "table.md"), "w") as f:
            f.write(report.markdown(dict(out, commit=results.commit(REPO),
                                         date=datetime.datetime.now().isoformat(timespec="seconds"))))
    return out
