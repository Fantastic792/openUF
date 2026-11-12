"""Flash guard: openUF must never write firmware or flash partitions. Comments do not count."""
import re
import subprocess

ROOTS = ["openuf", "package", "install.sh", "setup.sh", "update.sh"]
FORBIDDEN = re.compile("|".join([
    r"\bsysupgrade\s+[-/$\"']",  # the command with an option, path or variable; not sysupgrade.conf or prose
    r"\bmtd\b[^;|&]*\b(write|erase|unlock|fixtrx|jffs2write)\b",
    r"\bfw_setenv\b",
    r"\bubiformat\b",
    r"\b(flashcp|flash_erase|flash_eraseall|nandwrite|ubiupdatevol|ubirmvol|ubimkvol)\b",
    r"/dev/mtd",
    r"\bof=/dev/(mtd|ubi|mmcblk|sd)",
]))


def _code(path, line):
    if path.endswith(".lua"):
        return line.split("--", 1)[0]
    if path.endswith(".js"):
        return line.split("//", 1)[0]
    if line.lstrip().startswith("#"):
        return ""
    return line.split(" #", 1)[0]


def scan_text(path, text):
    return [(path, n, line) for n, line in enumerate(text.splitlines(), 1) if FORBIDDEN.search(_code(path, line))]


def scan(repo="."):
    names = subprocess.run(["git", "-C", repo, "ls-files", "-z", *ROOTS], capture_output=True, text=True,
                           check=True).stdout.split("\0")
    hits = []
    for name in filter(None, names):
        try:
            with open(f"{repo}/{name}", "rb") as f:
                data = f.read()
        except (FileNotFoundError, IsADirectoryError):
            continue  # deleted in the work tree, or a symlink to a directory
        if b"\0" not in data:  # NUL = binary (images, .mo); any other odd byte is still scanned
            hits += scan_text(name, data.decode("utf-8", errors="replace"))
    return hits
