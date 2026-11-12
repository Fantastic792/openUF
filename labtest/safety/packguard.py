"""Pack guard: nothing from labtest/ may end up in a built openUF package."""
import glob
import os
import subprocess

BUILDERS = ["tools/dist.sh", "install.sh", "setup.sh", "update.sh"]


def name_problems(names):
    return [f"packed: {n}" for n in names if "labtest" in n]


def check(repo="."):
    # LUA_PATH the same way the gate sets it, for dist.sh's Lua steps
    b = subprocess.run(["sh", "-c", 'eval "$(luarocks path --local 2>/dev/null)"; sh tools/dist.sh'], cwd=repo,
                       capture_output=True, text=True)
    if b.returncode != 0:
        return [f"tools/dist.sh failed: {(b.stdout + b.stderr).strip()[-300:]}"]
    names = subprocess.run(["tar", "tzf", "openuf.tar.gz"], cwd=repo, capture_output=True, text=True,
                           check=True).stdout.split()
    problems = name_problems(names)
    for f in sorted(glob.glob(os.path.join(repo, "package/*/Makefile"))) + [os.path.join(repo, b) for b in BUILDERS]:
        with open(f, encoding="utf-8") as fh:
            if "labtest" in fh.read():
                problems.append(f"mentions labtest: {os.path.relpath(f, repo)}")
    return problems
