---
paths:
  - "openuf/ucihelper.lua"
  - "openuf/inform.lua"
  - "openuf/sysinfo.lua"
  - "openuf/modelmap/**"
  - "setup.sh"
---

# Radio settings: channel, width, PHY mode, regdomain

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **Controller channel "Auto" means hostapd ACS picks**, and on mt7915/mt7986 it readily
  picks a DFS channel whose CAC then fails (`start_dfs_cac() failed` → `AP-DISABLED`), so
  a 5 GHz SSID silently never comes up while the controller reports it provisioned. The
  fix is `dev.conf.radio.<band>.acs_exclude_dfs = true` in the modelmap. A *maximum
  channel* is not a fix: DFS runs 52–144, so any cap below 149 keeps every failing channel
  and drops the working ones.
- **UniFi's `ieee_mode` token lies about the PHY, not the width.** 80 MHz on 5 GHz arrives
  as `11naht80` — still `ht`, which has no 80 MHz. Taken literally that became `HT80`, and
  `clamp_htmode` knocked it back to `HT40`, silently discarding the operator's setting.
  The width is the authoritative half; a width above 40 promotes to `VHT`. Confirmed live
  on a UCG Ultra.
- **The REGDOMAIN, not the hardware, applies the DFS flags.** Measured on one JIDU6101:
  under `IN`/`DE`/`US` channels 52–144 are all `(radar detection)`; under `PA` they carry no
  flag at all, and the identical HE160 config that never came up starts first try. That is
  what `config.country_override` is for — it programs the override into UCI `country` while
  stamping the controller's own value in `openuf_country`, which `get_radio_table` reports
  in preference, so the controller's site setting does not appear to change. Removing the
  override reverses both halves; never leave a foreign regdomain programmed silently.
- **160 MHz on 5 GHz needs working DFS** (or a regdomain that flags none), whatever `iw phy` claims. Every 160 MHz block is
  8 contiguous channels and every one that fits overlaps DFS (ch36 → seg0=50 spans 36–64;
  ch100 → 114 spans 100–128); the clear 149–173 range is only 140 MHz wide. So on a board
  with broken CAC, 160 MHz is unreachable on *any* channel and `acs_exclude_dfs` cannot
  help (a fixed channel skips ACS). That is what `htmode_max` is for.
- **"Force WiFi 4 Mode" does not touch `radio.<n>.ieee_mode`.** It works by making the WLAN
  2.4-only + WPA2 + no 802.11k/v + `bss_load_update_period=0`. So it collides with
  `htmode_floor`, which would put the HE IEs back in the beacon that the mode exists to
  remove — hence the per-radio suppression in `rf_config`. The mode is per WLAN, htmode is
  per radio; that mismatch is the whole difficulty.
- **`htmode_floor` is the ONE exception to "clamp downward only"** (`ucihelper.lua:124`).
  A controller that does not know the hardware pushes its default for the emulated model —
  802.11n/40 at a 4x4 WiFi-6 radio. A modelmap may declare a floor; the hardware clamp
  still runs after it, so a floor can never invent capability. Keep it opt-in per board.
- **A fresh OpenWrt ships every radio `disabled='1'`.** openUF writes that option only
  when the controller explicitly pushes a radio status, so a push that omits it leaves the
  radio off — provisioning "succeeds" and not one SSID is on the air. `setup.sh` clears it.
- **The wire's `11naht40` names a width, not 802.11n.** `rf_config` runs a bare `HT<width>`
  at the band's best PHY (`best_phy`) unless the WLAN has Force WiFi 4 Mode; the modelmap
  `htmode_floor` is now only needed to raise the WIDTH. 2.4 GHz is capped at 40 MHz in
  `parse_phy_caps` whatever the PHY says.
