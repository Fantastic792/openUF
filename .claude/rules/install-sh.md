---
paths:
  - "install.sh"
  - "update.sh"
---

## Changing `install.sh`

Copies `openuf/` to `/opt/openuf`, creates `/etc/openuf`, symlinks `syswrapper.sh`,
installs `/etc/init.d/openuf`, then dependencies.

**openUF's own files go in before any package install.** The optional feature packages are
collectively larger than openUF (nftables alone is ~490 KB with its kernel modules), and
installing them first has filled a small overlay and left the product itself uncopied —
the install "succeeded" with no `/opt/openuf` on disk. Product first means a space
shortage costs a feature, never openUF.

`try_optional` only installs when there is room to spare *afterwards*: filling an overlay
to 100% breaks `state.json` writes, the package database, and any later upgrade.

**An existing `conf.lua` is kept.** It holds the modelmap the device was adopted under,
and overwriting it on a reinstall (the natural upgrade path) reset the modelmap to the
generic one — on a DSA board that moves `lan_cpueth`, hence the identity MAC, hence
HTTP 400 forever. The shipped default lands as `conf.lua.dist`; `--replace-conf`
overwrites, and `setup.sh` passes it because it has just written `conf.lua` from its
interview. Options come after the action and an unknown one is an error, so a mistyped
flag cannot install silently without what it asked for.

**`update.sh` is the upgrade path, and it leans on two things `install.sh` provides.** It
installs `update.sh` as `/usr/bin/openuf-update` (a copy, not a symlink — it has to survive
its own `rm -rf /opt/openuf` during a rollback), and it leaves a build stamp in
`/opt/openuf/BUILD` (`dist.sh` writes one into a release tarball; a git checkout gets
`git describe`). The updater's health check reads `/tmp/openuf-status`, which `_tick`
rewrites after every completed cycle — `last_ok` on success, `last_fail` on a transport
failure, both kept, so a controller outage after a good update reads as "up but
unanswered" and is not rolled back. Keep that file flat `key=value`: busybox `sed` is what
parses it. `tools/deploy.sh` is the same updater driven from the dev machine over ssh, one
host at a time, with `dist.sh --verify` gating every push.

`--bootstrap-adopt` creates the locked-down non-root `ubnt`/`ubnt` account, scoped to
running `syswrapper.sh set-adopt` only, which self-locks once adopted and re-enables on
factory reset. The account's shell must be listed in `/etc/shells` or dropbear rejects the
login before the password (`User 'ubnt' has invalid shell, rejected`): `hook/openuf-bootstrap.sh`
registers it, also for an account that exists already, and `uninstall` removes it. The
validation container's OpenSSH never checked, so this was invisible until a real L2 adoption
(AP2, 2026-10-25).

**There is no 802.11r translator in the tree any more** (2026-11-10). `install.sh` removes the
former `openuf-rrb` service and, on uninstall, the old veth sections; 802.11r with genuine UniFi
APs is d-malinowski's rrb-unifi plugin, which `setup.sh` installs (`.claude/rules/fast-roaming.md`).
