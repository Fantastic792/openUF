"""Result files, stamped with the git commit they ran on (the VM-first rule needs it)."""
import datetime
import json
import os
import subprocess


def commit(repo="."):
    git = ["git", "-C", repo]
    h = subprocess.run(git + ["rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    # untracked files (the owner's notes) do not change what the commit runs
    dirty = subprocess.run(git + ["status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True,
                           check=True).stdout.strip()
    return h + "+dirty" if dirty else h


def _path(conf, name):
    return os.path.join(conf["results_dir"], name + ".json")


def save(conf, name, data):
    os.makedirs(conf["results_dir"], exist_ok=True)
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    data = dict(data, commit=commit(repo), date=datetime.datetime.now().isoformat(timespec="seconds"))
    p = _path(conf, name)
    with open(p, "w") as f:
        json.dump(data, f, indent=2)
    return p


def last(conf, name):
    try:
        with open(_path(conf, name)) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
