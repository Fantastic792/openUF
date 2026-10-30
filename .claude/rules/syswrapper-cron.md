---
paths:
  - "openuf/sysconf.lua"
  - "openuf/hook/syswrapper*"
  - "openuf/inform.lua"
---

# syswrapper verbs and controller-pushed cron

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **`syswrapper.sh 11k-scan` does not scan. It leaves a dated request file** (`/tmp/openuf-
  scan-request`) that the daemon's `_maybe_scan_neighbours` consumes on the next heartbeat,
  ignoring anything older than ten minutes. Every sweep goes through `_force_scan`
  (`iw dev <if> scan ap-force`, exit status judged through `_popen`'s `&& echo scan-ok`):
  `_popen` drops stderr, so before that a refused scan looked exactly like a successful one. The scan code, the radios' netdev names and the
  cache the result lands in all live in the daemon; a second implementation in the hook
  would drift. A request older than the cutoff is what a stopped daemon leaves behind, and
  firing it at the next boot would land in hostapd's ACS sweep.
- **`sysconf` installs only commands in `CRON_COMMANDS`.** A pushed cron line is a string
  crond runs as root; the controller's is `syswrapper.sh 11k-scan`, and that maps to the
  verb this tree ships. Extend the table only alongside a new verb, never to "pass through".
