---
paths:
  - "install.sh"
  - "update.sh"
  - "setup.sh"
  - "openuf/uciconf.lua"
  - "openuf/etc/init.d/**"
  - "openuf/hook/**"
  - "package/**"
  - "tools/deploy.sh"
  - "tools/hotpatch.sh"
  - "tools/verify-collect.sh"
  - "tools/verify.py"
  - "openuf/rrbguard.lua"
---

# Install prefixes, packages and the wpad build

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **Two install prefixes, one rule for the configuration.** The OpenWrt package installs
  to `/usr/lib/openuf`, `install.sh` to `/opt/openuf`; the init script, `syswrapper.sh`
  and `openuf-cli.sh` probe for whichever holds `inform.lua`. Whenever `/etc/config/openuf`
  has a `main` section, `uciconf.lua` replaces conf.lua's `dev` and `config` in both daemons
  and the hook -- conf.lua is then only the shipped default. `install.sh` never creates
  that section, so a tarball device keeps its conf.lua identity. `modelmap 'auto'` with
  no matching preset is a refusal (the init script's probe), never a generic fallback: the
  generic maps' `lan_cpueth` would move the identity MAC. A custom map goes through
  `uciconf.validate`, which is `test_modelmap.lua`'s invariants as refusals -- add an
  invariant in both places.
- **`wpad-basic-*` has no `bss_transition` at all** and errors the radio down, and every
  controller-pushed WLAN carries it. A full build is therefore **not negotiable**: the init
  script refuses to start without one (`grep wnm_sleep_mode /usr/sbin/hostapd` -- not
  `bss_transition`, which a basic build also carries as event names; upstream's correction), the
  package's postinst-pkg says so, and `hook/openuf-deps.sh` (`openuf deps --install`,
  `/usr/sbin/openuf-deps`, the LuCI overview's button) does the swap -- `del` the basic
  build, `add` the full one of the same crypto library, put the basic one back if that
  fails, `wifi up`, restart openUF -- and `--check` is the JSON the overview reads.
  `install.sh` and `setup.sh` run it too. No package dependency can express "any full
  build": every wpad variant PROVIDES the same names, and naming one CONFLICTS with the
  stock basic one.
- **8 MB flash is not enough** from a stock image: `lua-openssl` pulls in `libopenssl3`
  (~4.35 MB installed) and a stock 8 MB build leaves ~1.6 MB of overlay. Needs a custom
  image with the crypto in squashfs, or extroot.
- **`install.sh` registers `/etc/openuf/` and `conf.lua` in `/etc/sysupgrade.conf`**, or a
  firmware upgrade un-adopts the device. Append only when absent (`grep -qxF`), terminate a
  last line that lacks a newline first, and on uninstall drop only the `conf.lua` line --
  the state dir line stays because the directory does. Rewrite the file only on grep exit
  0 or 1; exit 2 with a full `/tmp` would otherwise truncate the user's own keep list.

## Package prefix or /opt prefix, never both

A device runs openUF from ONE prefix: the OpenWrt package's `/usr/lib/openuf` or
`install.sh`'s headless `/opt/openuf`. Never install both. The init script, `syswrapper.sh`
and `openuf-cli.sh` run whichever holds `inform.lua`, so with both present one copy is
dormant and an update to it changes nothing: `tools/deploy.sh` only updates `/opt/openuf`,
and `tools/hotpatch.sh` writes the RUNNING prefix. `tools/verify-collect.sh` reports every
prefix it finds; more than one is a fault to fix first, not a state to test against.
Remove one copy (`sh install.sh uninstall`, or the package manager) before installing the
other.

After a wpad restart, `wifi up`: the wpad init script restarts the daemons, but netifd has
to hand them their BSSes again (`rrbguard.lua`'s repair command, and the deps swap).
