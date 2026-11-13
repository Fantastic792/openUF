"""Install cycle on a fresh lab VM: install, uninstall leaves nothing, v0.13.0 then the tree over it."""
import os
import subprocess
import tempfile
import time

from labtest import results, table

# what install.sh's uninstall) block leaves on purpose: (prefix, the install.sh line saying so)
KEEP = [("/etc/openuf/", "install.sh uninstall: 'Remove installed files (leave state dir so authkey is preserved)'")]
SKIP = ("/proc/", "/sys/", "/dev/", "/tmp/", "/var/run/")
OLD = "v0.13.0"
BOOT_WAIT = 45  # the lab's fresh-VM recipe: reset; start; sleep 45; provision; prepare
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GOES_ON = {"leftovers"}  # recorded failure; later steps do not need it, so the upgrade data still comes
UNINSTALL ="f=/opt/openuf/install.sh; [ -f $f ] || f=/tmp/openUF/install.sh; sh $f uninstall"


def leftovers(before, after, keep=KEEP):
    return sorted(p for p in set(after) - set(before) if not any(p.startswith(k) for k, _ in keep))


def _files(t):
    out = t.ssh("find / -xdev -type f 2>/dev/null", timeout=120)[1]
    return [p for p in out.split() if not p.startswith(SKIP)]


def _sh(argv, timeout=900):
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    return p.returncode == 0, (p.stdout or b"").decode(errors="replace")[-300:]


def _conf_hash(t):
    return t.ssh("md5sum /opt/openuf/conf.lua")[1].split()[:1]


def run(conf, t, ctl):
    if t.kind != "vm":
        raise SystemExit(f"cycle wipes the install: refused on {t.name} (kind {t.kind}, not vm)")
    ctl.login()
    d = ctl.device(t.host)
    if d and d.get("adopted"):
        raise SystemExit(f"cycle wipes the install: refused on {t.name}, it is adopted")
    lab = ["sh", conf["lab_sh"]]
    n = str(t.lab_n)
    inst = ["sh", os.path.join(os.path.dirname(conf["lab_sh"]), "src", "install-openuf.sh"), n]
    state = {}

    def fresh():
        for step in ("reset", "start", "provision", "prepare"):
            ok, out = _sh(lab + [step, n])
            if not ok:
                return False, f"lab.sh {step}: {out}"
            if step == "start":
                time.sleep(BOOT_WAIT)  # provision types on the serial console; a key in GRUB's countdown stops the boot
        return t.wait(up=True, secs=300), "up"

    def before():
        state["before"] = _files(t)
        return bool(state["before"]), f"{len(state['before'])} files"

    def running():
        time.sleep(5)
        return t.ssh("/etc/init.d/openuf running")[0] == 0, ""

    def uninstall():
        rc, out = t.ssh(UNINSTALL, timeout=120)
        return rc == 0, out.strip()[-200:]

    def left():
        lo = leftovers(state["before"], _files(t))
        return not lo, ", ".join(lo[:10])

    def install_old():
        with tempfile.TemporaryDirectory() as tmp:
            ok, out = _sh(["sh", "-c", f"git -C {REPO} archive {OLD} | tar xf - -C {tmp}"])
            if not ok:
                return False, f"git archive {OLD}: {out}"
            ok, out = _sh(inst + [tmp])
        state["hash"] = _conf_hash(t)
        return ok, out

    def upgrade():
        t.ssh(f"logger -t labtest 'cycle upgrade {state.setdefault('mark', int(time.time()))}'")
        return _sh(inst + [REPO])

    def after_upgrade():
        bad = []
        if t.ssh("/etc/init.d/openuf running")[0] != 0:
            bad.append("openuf not running")
        if _conf_hash(t) != state["hash"]:
            bad.append("conf.lua changed")
        errs = table._errors(t, f"labtest: cycle upgrade {state['mark']}")
        if errs:
            bad.append(f"lua error: {errs[0]}")
        return not bad, "; ".join(bad)

    out = {"pass": False, "steps": []}
    for name, fn in (("fresh", fresh), ("before", before), ("install", lambda: _sh(inst + [REPO])),
                     ("running", running), ("uninstall", uninstall), ("leftovers", left),
                     ("install_old", install_old), ("upgrade", upgrade), ("after_upgrade", after_upgrade)):
        ok, detail = fn()
        out["steps"].append({"name": name, "ok": bool(ok), "detail": detail})
        if not ok and name not in GOES_ON:
            break
    else:
        out["pass"] = all(s["ok"] for s in out["steps"])
    results.save(conf, "cycle", out)
    return out
