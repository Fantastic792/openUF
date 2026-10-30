---
paths:
  - "openuf/firewall.lua"
  - "openuf/bcfilter.lua"
  - "openuf/shaper.lua"
  - "openuf/l2guard.lua"
  - "openuf/guestportal.lua"
  - "openuf/meshvlan.lua"
  - "openuf/switchvlan.lua"
  - "openuf/util.lua"
  - "openuf/usteer.lua"
  - "openuf/inform.lua"
---

# nftables and tc enforcement modules

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **`l2guard` protects the VAPs only, never a wired socket, by design.** The controller's
  `--vlan-id <n> -p 802_1Q -j DROP` is bridge-wide on the stock firmware because there the
  tagged uplink is an 8021q sub-device that takes tagged frames before the bridge sees them.
  On a DSA board openUF's tagged uplink is `br-lan.<n>`, ON the bridge, so tagged frames
  from the uplink socket traverse it -- a bridge-wide rule kills the IoT WLAN's uplink. The
  uplink socket is a runtime detection that is refused when unsure, so the rule stays on
  the interfaces the controller's other eight rules name: the VAPs.
- **Every openUF nft table is rebuilt in ONE `nft -f` transaction** (`util.nft_apply`):
  `add table` + `delete table` + the new statements in one commit, so a blocked client
  never slips through between the delete and the rebuild. When the batch is rejected the
  statements are re-run one at a time so the warning can name the rule (the
  `kmod-nft-bridge` case). Tests capture the script through the runner's `fake_nft`,
  which expands `nft -f <file>` into its statements; a module's `_exec` seam gets the
  `nft -f` line, never the statements.
- **WiFi Speed Limit is per client and lives in `_shaper_resync`, not in the UCI reapply.**
  `build_json` records which netdev lists which station (`M._shape_obs`), the heartbeat
  hands that plus `st.sta_rates` (the `rate-update` ledger, one association each) to
  `shaper.sync`, which diffs per station. `reapply_runtime_rules` rebuilds the blocker
  only. Upload is queued on an IFB device (`kmod-ifb`); without it the police fallback
  needs `kmod-sched-act-police`, and both are listed in every installer.
- **Two kernel modules are not implied by their packages.** `kmod-nft-bridge` for the
  Multicast/Broadcast Blocker's `meta` rule (everything else in that table builds without
  it, so the control looks enabled and filters nothing) and `kmod-sched-act-police` for the
  upload half of WiFi Speed Limit. Both modules now warn by name when `nft`/`tc` reject the
  rule, and both installers add them. `os.execute` returns the raw exit status on Lua 5.1
  (0 = success, non-zero = failure, BOTH truthy), so any "did it work" check needs
  `exec_ok`, not a bare truth test.
