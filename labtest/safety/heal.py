"""Runner side of the self-heal timer (heal.sh): arm, knock, check, disarm."""
import os
import threading

HEAL_SH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "heal.sh")
REMOTE = "/etc/labtest-heal.sh"
# every file heal.sh can leave on the target
PATHS = [REMOTE, "/etc/labtest-good.tgz", "/etc/labtest-healed", "/etc/init.d/labtest-heal",
         "/etc/rc.d/S99labtest-heal", "/tmp/labtest-knock", "/tmp/labtest-last", "/var/run/labtest-heal.pid"]


def arm(t):
    t.put(HEAL_SH, REMOTE)
    rc, out = t.ssh(f"{REMOTE} arm")
    if rc != 0:
        raise RuntimeError(f"arm on {t.name} failed ({rc}): {out.strip()}")


class Knocker:
    """with Knocker(t): ... touches the knock file every `every` s. A failed knock is ignored:
    a target that cannot be reached is exactly the case the timer is for."""

    def __init__(self, t, every=10):
        self.t, self.every, self.stop = t, every, threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def _run(self):
        while not self.stop.is_set():
            self.t.ssh("touch /tmp/labtest-knock", timeout=5)
            self.stop.wait(self.every)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop.set()
        self.thread.join()


def healed(t):
    return t.ssh("test -e /etc/labtest-healed")[0] == 0


def disarm(t):
    rc, out = t.ssh(f"{REMOTE} disarm; ls -d {' '.join(PATHS)} 2>/dev/null")
    if rc == 255:
        raise RuntimeError(f"disarm on {t.name}: target not reachable")
    return [p for p in out.split() if p in PATHS]
