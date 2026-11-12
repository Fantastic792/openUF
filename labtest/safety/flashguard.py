"""Flash guard: openUF must never write firmware or flash partitions. Comments do not count."""
import re
import subprocess

ROOTS = ["openuf", "package", "install.sh", "setup.sh", "update.sh"]
FORBIDDEN = re.compile("|".join([
    r"\bsysupgrade\s+[-/]",  # the command with an option or a path, not /etc/sysupgrade.conf or prose
    r"\bmtd\s+(-\S+\s+)*(write|erase|unlock|fixtrx|jffs2write)\b",
    r"\bfw_setenv\b",
    r"\bubiformat\b",
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
    names = subprocess.run(["git", "-C", repo, "ls-files", *ROOTS], capture_output=True, text=True,
                           check=True).stdout.split()
    hits = []
    for name in names:
        try:
            with open(f"{repo}/{name}", encoding="utf-8") as f:
                hits += scan_text(name, f.read())
        except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
            pass  # binary (images, .mo), deleted in the work tree, or a symlink to a directory
    return hits
