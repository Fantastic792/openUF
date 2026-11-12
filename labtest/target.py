"""Lab config and SSH to one target. Lab addresses live in /root/vmlab, never here."""
import json
import os
import subprocess
import time

DEFAULT_CONF = "/root/vmlab/labtest.json"


def load_config(path=None):
    path = path or os.environ.get("LABTEST_CONF") or DEFAULT_CONF
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        raise SystemExit(f"labtest: no config file at {path}")


class Target:
    def __init__(self, name, host, kind, key, lab_n=None):
        self.name, self.host, self.kind, self.key, self.lab_n = name, host, kind, key, lab_n

    def _argv(self, cmd):
        return ["ssh", "-i", self.key, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
                f"root@{self.host}", cmd]

    def ssh(self, cmd, timeout=20, stdin=None):
        try:
            p = subprocess.run(self._argv(cmd), input=stdin, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=timeout)
        except (subprocess.TimeoutExpired, OSError):
            return 255, ""
        out = p.stdout
        return p.returncode, out.decode(errors="replace") if isinstance(out, bytes) else (out or "")

    def put(self, local, remote, mode="755"):
        # no scp on the router: cat over stdin
        with open(local, "rb") as f:
            rc, out = self.ssh(f"cat > {remote} && chmod {mode} {remote}", stdin=f.read())
        if rc != 0:
            raise RuntimeError(f"put {remote} on {self.name} failed ({rc}): {out.strip()}")

    def reachable(self):
        return self.ssh("true", timeout=5)[0] == 0

    def wait(self, up, secs):
        end = time.monotonic() + secs
        while True:
            if self.reachable() == up:
                return True
            if time.monotonic() >= end:
                return False
            time.sleep(5)


def get_target(conf, name):
    t = conf.get("targets", {}).get(name)
    if t is None:
        raise SystemExit(f"labtest: unknown target {name}; known: {', '.join(sorted(conf.get('targets', {})))}")
    return Target(name, t["host"], t["kind"], conf["ssh_key"], t.get("lab_n"))
