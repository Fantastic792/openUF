---
paths:
  - "openuf/ftinterop.lua"
  - "openuf/rrb/**"
  - "openuf/rrbguard.lua"
  - "openuf/ucihelper.lua"
  - "openuf/hook/openuf-rrb.sh"
---

# 802.11r with genuine UniFi APs (ftinterop, rrb-unifi)

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **Never set `ft_psk_generate_local`.** It is FT-PSK-only, and pinning it stops OpenWrt
  configuring the key holders FT-SAE needs, so WPA3 clients silently lose fast roaming.
  The one exception is `ftinterop.lua` under `unifi_ft_interop`: it sets `0` and writes the
  explicit `r0kh`/`r1kh` key holders in the same breath, so the relationship FT-SAE needs
  exists; a UniFi AP never derives keys locally and pulls from this AP instead. That path also
  needs the external rrb-unifi translator's veth as hostapd's `ft_iface`, written as the raw
  `hostapd_bss_options` form (the translator reads the generated `ft_iface=<bridge>` line that
  precedes it), and only when the veth exists: hostapd fails a BSS whose `ft_iface` is missing.
- **hostapd is pointed at the translator's veth only while something forwards it.**
  `ftinterop.ft_iface` writes `hostapd_bss_options 'ft_iface=vft0'` only when the `openuf-rrb`
  service is installed, `openuf.rrb.enabled` is not `0`, and the netdev exists, and
  `ucihelper.ensure_ft_veth` creates the pair only under the same conditions: a veth nobody
  forwards would swallow every RRB frame, openUF-to-openUF key pulls included, and the symptom
  would be "FT silently falls back to a full handshake" on every roam. The daemon's own changes
  (waiting instead of exiting, the peers file) are marked `// openUF:` in a file whose upstream
  is d-malinowski's repository, not this one: keep them small and re-applicable. The whole
  repository is GPL-3.0-or-later since 2026-10-25 because of it; NOTICE carries the MIT notice
  for jonasevcik's original work, which MIT requires to travel with the code.
