---
paths:
  - "openuf/rrbguard.lua"
  - "openuf/plugins.lua"
  - "openuf/ucihelper.lua"
  - "tests/fixtures/rrb-unifi/**"
  - "tools/rrb-unifi-compat.sh"
---

# 802.11r with genuine UniFi APs (the rrb-unifi plugin)

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **openUF carries no UniFi translator of its own since 2026-11-10.** d-malinowski's rrb-unifi
  (translator daemon + `openuf-plugin/rrb-unifi.lua`) is a separate install: `setup.sh` offers
  it at the pinned release (`RRB_UNIFI_TAG=v1.5`, `RRB_UNIFI_PLUGIN_SHA256`), through the plugin
  hook (`plugins.lua`, api 1, `docs/PLUGINS.md`). The plugin rewrites every FT WLAN in
  `vap_options` (UniFi's mobility domain, `ft_psk_generate_local 0`, nasid, `ft_iface=vft0`
  while its veth exists). Nothing in ucihelper knows about it. Removed with the vendored
  translator: `ftinterop.lua`, `openuf/rrb/`, the `openuf-rrb` service, `unifi_ft_interop`,
  `state.rrb_peers`, the veth code. Our fixes to it (BSSID from sysfs first, restart only when
  its inputs changed, quiet-moment re-push) no longer exist here: they are the external
  project's to make.
- **Never set `ft_psk_generate_local` in ucihelper.** It is FT-PSK-only, and pinning it stops
  OpenWrt configuring the key holders FT-SAE needs, so WPA3 clients silently lose fast roaming.
  Only the plugin sets it, together with the key holders.
- **The NAS-ID rule stays in ucihelper** (`resolve_nas_id`, policy `ft`): hostapd uses
  `nas_identifier` as the R0KH-ID, a controller NAS-ID is shared by every AP, so on FT WLANs it
  is dropped and hostapd defaults to the BSSID. Without it an FT-EAP roam to another openUF AP
  never pulls its key.
- **The pin moves only through `tools/rrb-unifi-compat.sh`** (his contract tests through our
  hook, ours against his latest plugin, a diff of the contract surface). `tests/test_rrb_unifi_compat.lua`
  runs the pinned copy in `tests/fixtures/rrb-unifi/` on every suite run and checks its sha256
  equals the one in `setup.sh`. A change to `plugins.lua`, `ctx` or the FT block must keep it green.
- **A device upgraded from the vendored translator** still has the veth sections
  `openuf_ftveth/ftlink/ftpeer`. They go AFTER the push that rewrote the WLANs without
  `ft_iface=vft0` (`ucihelper.remove_legacy_ft_veth`; `inform._migrate_legacy_rrb` forgets
  `cfgversion` once): a BSS whose `ft_iface` vanishes under it fails. Never remove them first.
- **`rrbguard.lua` stays**: it repairs hostapd's own stale key-exchange socket, wherever
  `ft_iface` points.
