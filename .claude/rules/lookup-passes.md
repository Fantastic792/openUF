---
paths:
  - "openuf/sysinfo.lua"
  - "openuf/inform.lua"
  - "openuf/ucihelper.lua"
  - "openuf/lldp.lua"
  - "tests/run_tests.lua"
---

# The per-payload lookup passes and caches

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **`ubus call network.wireless status` is cached per `build_json` pass** (`begin_pass` /
  `end_pass`), and `iw phy phyN info` per phy with a five-minute TTL in sysinfo. Both
  caches are dropped after `wifi reload`; `phy_caps` additionally re-reads for a minute
  after a regdomain write, because the driver applies the new domain only when the
  radios come back up. Tests that stub `_popen`/`_run_cmd` must reset these (the harnesses
  do).
- **sysinfo has the same lookup pass, and two TTL caches.** `sysinfo.begin_pass` is opened
  at the very TOP of `build_json` (before the uptime read) and closed on return and in
  `_tick`; inside it `/proc/net/arp`, `/tmp/dhcp.leases`, `/proc/uptime`, each `bridge fdb
  show br` dump and the bucketed ARL/FDB (`hosts_by_port`) are read once per payload.
  The default gateway's IP is cached for `UPLINK_TTL` (300 s) -- **a nil answer is never
  cached**, boot is full of them -- and `forget_uplink_cache` still runs after a switch
  push. `bridge_of` is a live sysfs read since 2026-10-18 (`util.master_of` on
  `/sys/class/net/<if>/master/uevent`, no `readlink` fork, no memo); `lan_bridge` resolves
  `lan_cpueth` whether it names the bridge or a socket, and is what inform's DSA paths
  call. The parsed phy caps live in the same cache entry as the dump's text.
  `lldp.neighbors` is **not cached at all** (the user's rule, 2026-10-18: anything the
  controller shows follows reality on the next heartbeat; upstream's 60 s cache, empty
  answers included, was taken out again -- one lldpctl fork per 10 s is the accepted
  price, and the same rule applies to any future "report it a bit later to save a fork"
  trade -- the sibling-tag cache and the hourly beacon requests went the same way; the
  goal is the most accurate emulation, so what a real AP does by design, like spreading
  the nightly 11k-scan over the hour, is kept). `ucihelper.get_radio_table` reads the wifi-device rows once
  per pass and hands each caller a COPY. `ucihelper.begin_pass` is nest-safe: `_tick`
  opens ONE pass from its first resync to the payload and `build_json` only closes a pass
  it opened itself. Outside a pass everything reads every time, which is what keeps
  per-test stubs independent; harnesses reset `_uplink_cache`, `_phy_info_cache`, the lldp
  caches and call `end_pass()` on the way in and out.
