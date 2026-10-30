# openUF — working notes

A Lua daemon that makes an OpenWrt device appear to a UniFi Network Application as a
Ubiquiti **U6-InWall** access point: L2/L3 adoption, controller-pushed SSID and radio
config, live client/radio/port statistics. AP emulation only — gateway (USG) and switch
(USW) are not implemented and not planned.

Two orthogonal concepts, constantly confused:

- **modelmap** (`openuf/modelmap/*.lua`) — *your real hardware*: radio names, ethernet
  sockets, switch geometry, status LED.
- **ufmodel** (`openuf/ufmodel/*.lua`) — *the UniFi identity presented to the controller*.
  `u6iw` is the only one validated end-to-end. `uhdiw` (UAP-IW-HD: WiFi 5, the same five
  sockets) and `u7hd` (UAP-AC-HD: WiFi 5, two sockets, for the Deco M5 and M4R) are sourced from
  Ubiquiti's firmware catalog but have never adopted -- see "Adding a UniFi identity" below.

`openuf/conf.lua` picks one of each and holds runtime options. It is the file users
hand-edit on the device, so it (and `modelmap/*`) keep their comments when packaged.

---

## Commands

```sh
# Tests. Must run from the project root — test files dofile("openuf/...") relatively.
eval $(luarocks path --local) && lua tests/run_tests.lua

# End-to-end adoption round-trip against the Python controller stub
sh tools/simulate.sh --adopt          # needs pycryptodome, luasocket, lua-cjson

# Release tarball; --verify proves the comment-stripped tree is bytecode-identical
# to the source and still passes the suite. Run it in the same shell as the
# luarocks eval above: without LUA_PATH the suite step fails on lua-cjson and
# --verify reports a false failure.
sh tools/dist.sh --verify

# Push this tree to adopted APs: builds with --verify, then runs the on-device updater
# on each (backup → install keeping conf.lua → restart → wait for an inform → roll back)
sh tools/deploy.sh --check <ap-ip>...   # read-only: what each AP runs
sh tools/deploy.sh <ap-ip>...           # OPENUF_SSH_PASS=... for a password-protected root

# Put this tree onto an AP's RUNNING prefix -- the package's /usr/lib/openuf or
# install.sh's /opt/openuf, whichever holds inform.lua -- with .pre-hotpatch backups,
# the init script included when it differs. deploy.sh only ever updates /opt/openuf,
# which on a device that also has the package installed is the dormant copy.
sh tools/hotpatch.sh [--repush] <ap-ip>  # --repush blanks cfgversion for a full config push

# Judge a deployed AP from both sides: selfcheck.sh + logread over ssh
# (tools/verify-collect.sh) and the controller's stat/device record. Read-only;
# UNIFI_API_KEY, or UNIFI_USER (+ password prompt). Report in verify-<ap>-<time>/
# Any board: the profile is read off the device (probe.lua status); --profile
# <modelmap> also FAILs when the device runs a different one.
python3 tools/verify.py --router <ap-ip> --controller https://<controller>:8443

# Shell syntax — BOTH, every time (see "Shell code" below)
bash -n setup.sh && dash -n setup.sh
```

A new test file must be added to the hardcoded `test_files` list in
`tests/run_tests.lua` — it is not globbed. The runner now fails the run if a
`tests/test_*.lua` exists on disk that is not in the list, so forgetting is loud rather
than silent. CI also runs `tools/dist.sh --verify` on every push, not only on a release
tag.

`lua tests/run_tests.lua` from the project root is not the only way the suite runs:
`tools/dist.sh --verify` re-runs it in a scratch tree holding only `openuf/` (stripped),
`tests/` and `tools/`, and the Release workflow builds with `--verify`, so a test that
reads any other path passes locally and fails only on the tag. A test that `dofile()`s or
opens something outside those three needs that path copied into the verify tree in the
same commit. Run `sh tools/dist.sh --verify` whenever a test gains a new file dependency
(`tools/cfg-coverage.lua` broke it: a whole test FILE errored out, so the total dropped by
one file, not one test).

---

## Hard constraints

### Lua

**Lua 5.1** on the device (CI runs `lua5.1`). No `goto`, no `//`, no native bitwise
operators (`luabitop` provides `bit.*`), `break` must be the last statement in its block,
no `\xNN` string escapes (5.1 silently emits the letters `x07`; use `string.char`), no `\z`,
`\u{}` or `table.unpack`. `os.execute` returns a number on 5.1, and both 0 and 1 are truthy,
so normalise before branching. OpenWrt's Lua carries the LNUM patch: `string.format("%d", x)`
**raises** for |x| > 2^31 on the APs (reproduced on AP2's 5.1.5, 2026-10-18) and not on CI or a
dev machine -- format epochs in ms and other large values with `%.0f`. A newer local Lua will happily accept code the device rejects —
CI is the check, and AP2's own `lua` (`loadfile` on each module) is the quickest local one.
`openuf/lib/lib.lua` is what lets one source tree run on both: it resolves `bit` from
luabitop, bit32, or native 5.3+ operators built with `load()` so 5.1 never parses the
newer syntax. Follow that pattern rather than branching on `_VERSION`.

Every script loads siblings by **cwd-relative path**, and `conf.lua` does
`dofile("modelmap/…")`. Everything therefore runs from `openuf/`; the procd init script
does `sh -c "cd /opt/openuf && exec lua inform.lua"` for exactly this reason. Anything
that shells out to Lua from elsewhere must `cd` first.

Flash is scarce. `tools/dist.sh` strips comments from every `.lua` except `conf.lua` and
`modelmap/*`, roughly halving the installed bytes. `--verify` compares `luac` opcode
streams before and after, so it catches a "comment" edit that changed behaviour.

### Shell code

`install.sh`, `setup.sh` and `tools/*.sh` run under **busybox ash**, not bash. Check with
`bash -n` *and* `dash -n` — dash is the strictest POSIX shell available on a runner and
catches bashisms `bash -n` accepts. CI does both for `setup.sh`, `install.sh`, `update.sh`
and `tools/deploy.sh`.

- `sed -i` with no suffix (GNU/busybox form). This **fails on macOS/BSD** — use
  `/opt/homebrew/opt/gnu-sed/libexec/gnubin` in `PATH` when testing locally.
- Avoid `case` inside `$( )`. It has bitten this repo: a `)` in a case pattern terminated
  the substitution early and wrote a garbage netmask. Assign to a variable first.
- `local` is fine inside functions, never at top level.
- A pipeline's exit status is its **last** command's. `sh tools/dist.sh --verify | tail -3`
  reported success while dist.sh had failed, and `deploy.sh` shipped the previous run's
  tarball. Send output to a file and test the command itself, and delete stale outputs
  before building.
- Test POSIX snippets under `sh`, not in the zsh you are typing into: zsh does not
  word-split an unquoted `$var`, so `for k in $list` runs once over the whole string and a
  correct `case`/`for` loop looks broken — or a broken one looks fine.
- Support both package managers: OpenWrt 25.12 uses `apk`, 24.10 and earlier `opkg`, with
  identical package names. Both scripts define `pkg_installed` / `pkg_add` wrappers — use
  them rather than naming a manager.

### Conventions

Tabs, 4 wide — `.editorconfig` scopes that to `[*.lua]`, but the shell scripts use tabs
too. Comments in this repo explain **why**, and usually name the failure that motivated
the code ("this was hardcoded 1000/full, so every device reported GbE"). Match that
density — it is the repo's main defence against re-breaking things that are invisible
without hardware.

The load-bearing discipline: **refuse rather than guess.** Where a fact cannot be
determined (which socket the uplink is in, which physical port is which), report nothing
rather than a plausible wrong answer. A wrong answer here means the AP tells the
controller the whole LAN is plugged into it, or a VLAN push strands the device.

**Design a new feature for weak hardware as you write it**, not in a later audit pass.
Users run openUF on 9.6 MB-overlay ath79 boards. Hold new code against the ruleset before
calling it done: one lookup/walk pass per tick, derived facts computed once per push, caches
keyed on what can change them, an interval gate plus a cheap change detector, sysfs over
forks, one `nft -f` transaction per rebuild, shared helpers in `util.lua` over copies,
read-and-compare before a flash write, `table.concat` over `..`, one line → one pattern,
`find` over `gsub`. Never put a blocking `io.popen` on the `handle_response` path without a
guard and a `timeout`. State the measured cost in the commit body.

### Lab data and fixtures

- **Fixtures** in both trees use RFC 7042 MACs (`00:00:5e:00:53:xx`) and RFC 5737 addresses
  (`192.0.2.x`). Pre-commit scan: `git diff --cached -U0 | grep "^+" | grep -nE
  "192\.168\.|([0-9a-f]{2}:){5}[0-9a-f]{2}"` -- `192.168.1.100` "testap" and `11:22:33`-style
  MACs are long-standing test placeholders, not lab values.
- **Nothing from the lab goes into the repository (code, fixtures, docs, rules)**: no
  device passwords, no API keys, no controller credentials. REVERSE-ENGINEERING.md's lab
  table carries the addresses and roles; secrets are asked for each session.

---

## Landmines that apply anywhere

The rest are in `.claude/rules/`, by the files they are about (see "More rules").

- **`_forget_controller` is what a factory reset owes the kernel.** `setdefault` and an
  out-of-process `reset-inform` (seen by `_reload_if_changed` as adopted → not adopted) both
  drop the controller's interval, the l2guard table, the cron block and put Airtime Fairness
  back on. A new controller-driven kernel or system state belongs in that function too, or a
  forgotten AP keeps acting for a controller that no longer manages it.
- **Wire values that reach a shell are shape-checked first.** `netconf.1.ip`, the netmask,
  `route.1.gateway`, block-sta's `resp.mac`, the bcfilt allow-list and the MAC filter all
  go through `is_ipv4`/`is_mac` at the parser *and* again in netconfig/firewall/bcfilter.
  Pre-adoption the inform channel is plain HTTP under the well-known key, so a forged
  `setparam` is within reach of anyone on the path; without these it was a root shell.
- **Kernel state is rebuilt at startup, because the controller never re-pushes it.** After
  a reboot `cfgversion` matches and the reply is `noop` with no `system_cfg`, so anything
  applied only from `apply_config`/`handle_response` is gone for good. `M.run` therefore
  reapplies, in order: the pushed static IP (`_reapply_static_ip`, before
  `_populate_net_info`), the bridge identity (`ensure_bridge_identity`), the blocked-client
  rules, the blocker and speed limit from the `openuf_bcfilt*`/`openuf_ratelimit_*` stamps
  (`reapply_runtime_rules`), the LED state, Airtime Fairness from `st.atf_enabled`
  (`_reapply_airtime`; debugfs resets to on), the nft MAC tap
  (`switchvlan.reconcile_mac_taps`, from the `openuf_brport<vid>_<socket>` sections) and the
  l2guard table from `st.l2guard`, whose VAP list `_l2guard_resync` then corrects once a
  minute. Every one is pcall'd. A new kernel-resident feature belongs in that list or it is a
  reboot bug.
  The IP branch of `handle_response` saves state the moment the interface changes, not at
  the tail: anything after it can raise, and the startup reapply reads what was saved.
- **Anything keyed to a VAP's live netdev needs a resync, not just a build after `wifi
  reload`.** netifd brings the VAPs up asynchronously, so a lookup right after the reload can
  find none: the Blocker's ruleset came out empty that way and stayed empty until a restart
  (QEMU test VM, 2026-10-26). l2guard, the guest portal, usteer's filter and now the Blocker
  (`ucihelper.resync_runtime_rules`) each re-check once a minute; a new per-VAP kernel rule
  needs the same, and "nothing resolves" must mean "not answering yet", never "tear down".
- **A `setdefault` or `reset-inform` now tears the controller's config DOWN**
  (`_forget_controller(prev, cfg)` → `ucihelper.forget`, `switchvlan.restore`, usteer
  off, LED back). It needs the state from BEFORE the reset (`prev`): the per-port VLAN
  ledgers live only there. Anything new a controller leaves in UCI or the kernel belongs
  in `ucihelper.forget` or that function.

---

## File map (short)

```
openuf/        the daemon: inform.lua (core loop), ucihelper.lua (UCI writes), sysinfo.lua,
               the enforcement modules (firewall, bcfilter, shaper, l2guard, guestportal),
               mesh (backhaul, meshvlan), radio policy (minrssi, loadbalance, usteer,
               roamassist, wlansched, uplinkmon), ftinterop + rrb/ (802.11r with UniFi),
               util.lua, state.lua, unhandled.lua, conf.lua, modelmap/, ufmodel/, hook/
package/       the OpenWrt feed: openuf, luci-app-openuf, luci-theme-halo
setup.sh / install.sh / update.sh   guided install / headless install / on-device updater
tools/         dist.sh, check.sh, simulate.sh, deploy.sh, hotpatch.sh, verify.py, ...
tests/         run_tests.lua (hardcoded list) and the test_*.lua files
```

The full map, module by module: `.claude/rules/file-map.md`.

`PROTOCOL-VALIDATION.md` records what was confirmed against a live controller versus
inferred from decompilation, and **supersedes REFERENCE/USAGE where they disagree**. If you
are about to change protocol behaviour, check there first for why it is the way it is.

`REVERSE-ENGINEERING.md` is the other half: what is *not* implemented, what is known about
each, and the next experiment. Before starting work on an unimplemented protocol feature,
read its entry — several have a "do not re-attempt" list that will save you a session. Its
first rule is the one to internalise: **never claim a capability bit openUF cannot honour**,
because that turns a missing feature into a silently broken one.

---

## More rules

Claude Code loads these automatically when a matching file is touched. Other agents
(AGENTS.md is a link to this file) should read the one that fits before editing.

Rules (`.claude/rules/`):
- `inform-loop.md`: inform.lua, handle_response, the unhandled ledger, state.json, STUN, crypto.
- `lookup-passes.md`: the per-payload lookup passes and caches in sysinfo, ucihelper and inform.
- `wlan-vaps.md`: WLANs and VAP netdevs, usteer and Roaming Assistant, Minimum RSSI, schedules, UCI names.
- `radio-phy.md`: channel, width, PHY mode, regdomain and DFS (rf_config, ucihelper).
- `fast-roaming.md`: ftinterop.lua and the rrb-unifi translator.
- `nft-enforcement.md`: firewall, bcfilter, shaper, l2guard and every nft table.
- `syswrapper-cron.md`: syswrapper verbs and controller-pushed cron (sysconf.lua).
- `switch-ports-dsa.md`: switch ports, DSA bridges, per-port VLANs, LEDs, lldpd.
- `mesh-backhaul.md`: the wireless uplink (backhaul.lua, meshvlan.lua).
- `luci-web.md`: the LuCI app, theme and device page under package/.
- `install-prefixes.md`: package or /opt prefix (never both), sysupgrade.conf, wpad, flash size.
- `setup-sh.md`: changing setup.sh. `install-sh.md`: changing install.sh or update.sh.
- `upstream.md`: jonasevcik/openUF and the other remotes, how a sync re-implements
  rather than merges, the last review point, fixtures and the pre-commit scan.
- `file-map.md`: the full file map, module by module.

Skills (`.claude/skills/`):
- `add-device-map`: adding a hardware profile (modelmap) or a UniFi identity (ufmodel).
- `merge-upstream-feature`: porting a feature from another openUF tree, commit by commit.
