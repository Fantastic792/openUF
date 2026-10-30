---
paths:
  - "openuf/ucihelper.lua"
  - "openuf/inform.lua"
  - "openuf/usteer.lua"
  - "openuf/roamassist.lua"
  - "openuf/minrssi.lua"
  - "openuf/loadbalance.lua"
  - "openuf/wlansched.lua"
  - "openuf/rrmscan.lua"
  - "openuf/uplinkmon.lua"
  - "openuf/guestportal.lua"
---

# WLANs, VAP netdevs and per-station policy

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **One VAP can be several netdevs.** An OWE-transition section brings up a second, open BSS
  that netifd's status never lists (read from `hostapd bss_info`), and each private
  pre-shared key VLAN gets `<vap>-<vid>` (listed under the interface's `vlans[]`).
  `get_ifnames_for_vap` returns all of them, and stations, the blocker and the shaper must
  cover all of them; `get_ifname_for_vap` (singular) is only for something that addresses the
  hostapd BSS itself. A station seen on a VLAN netdev is kicked or BTM-requested through its
  BSS (`bss_ifname`), which is the only place hostapd listens. Taking a BSS down (schedule,
  uplink monitor, guest selfrun) takes its `<vap>-<vid>` netdevs with it and nothing brings
  them back, so a VLAN key is refused: `wlansched.set_bss` raises them after the beacon
  restarts, and netifd re-bridges them (JIDU6401, 2026-10-28).
- **Roaming Assistant and Band Steering share usteer but not its decision.** `usteer.lua`
  writes `band_steering_interval` (0 = off; the daemon default steers) and never the inert
  `band_steering_threshold`; `roamassist.lua` reads usteer's cross-AP table and sends its own
  BTM request and disassociation, per WLAN, only toward an AP that hears the client
  `roam_assist_diff_db` louder. `usteer.set_enabled(steering, cfg, roam_assist)` runs the
  daemon for either.
- **`get_vap_table` reports AP-mode sections only, and `use_only_unifi_wlan` never touches
  a non-AP one.** A mesh point or station interface (a wireless backhaul) is a link, not a
  competing SSID, and may be the device's own uplink. `keep_wlan_sections` exempts named
  AP sections. Each VAP reports its own BSSID via `get_ifname_for_vap`, not the radio's
  first interface's.
- **Minimum RSSI and Load balance are per radio and decided after the station loop.**
  The loop only collects observations (`minrssi_obs`, `lb_obs`); `minrssi.tick` kicks
  after HOLD (30 s) below, `loadbalance.kicks` the most idle above the cap, and
  `rf_config` writes hostapd's refusal (`rssi_reject_assoc_rssi`, stamped
  `openuf_minrssi`). A backhaul VAP's stations are never observed.
- **A WLAN Schedule waits for a trusted clock.** `_sched_resync` does nothing until a
  controller answer's `server_time_in_utc` agrees with the local clock within 60 s, which
  touches `/var/run/openuf.clock-ok` (survives a restart, not a reboot). The firmware
  keeps every VAP up until NTP has set the time; so does this. Down is the netdev; up is
  the netdev plus hostapd `STOP_AP` + `update_beacon`, or the BSS stays silent.
- **`openuf_` is a UCI section name, not an SSID filter.** Sections are
  `openuf_<radio>_<sanitized ssid>`; the broadcast SSID is exactly what the controller
  sent, and every pushed WLAN is provisioned whatever it is called. The prefix only marks
  what openUF may delete. `get_vap_table` reports *every* enabled `wifi-iface`, including
  hand-made ones. What is configurable is whether hand-made SSIDs keep broadcasting:
  `use_only_unifi_wlan`, which stamps `openuf_autodisabled=1` on what it turns off so the
  change is reversible.
- **`libuci-lua` is required and fails silently.** It provides `require("uci")`, which
  every wireless read and write goes through, and it is not pulled in by `lua`. Without it
  the device adopts, reports its ports and statistics and looks completely healthy, while
  `radio_table` goes out **empty** — so the controller has no radio to provision a WLAN
  onto, accepts the push, and creates nothing. It is silent because every ucihelper call
  is `pcall`-wrapped (correctly — a UCI error must not take the inform loop down). Found
  on a real JIDU6101 after four pushed WLANs produced zero UCI sections. `inform.lua`'s
  `_warn_missing_uci` now shouts at startup and `tools/check.sh` tests for it; keep both.
- **A UCI section name may contain only `[A-Za-z0-9_]`, and libuci discards anything else
  silently** (`set` and `commit` both return true). `wlan_add` sanitizes with `[^%w_]` and
  appends a hash of the original SSID when it had to change anything; the test mocks refuse
  an invalid name so the class cannot quietly widen again. An SSID with a hyphen used to
  provision nothing.
- **Minimum RSSI is a fixed wire offset, `dBm = raw - 95`**, not "raw plus the live noise
  floor". The controller never learns a radio's noise floor, so it has nothing but a
  constant to encode with; the old conversion drifted 12 dB between drivers.
- **A station's RRM capability bits are not a promise.** AP2's one "capable" client
  advertises passive, active and table beacon measurement and answers every request with
  mode 0x02 "incapable" -- and hostapd never notifies a bodiless refusal over ubus, so the
  only signal is silence. `_rrm_tick` asks a station at most `RRM_MAX_UNANSWERED` times
  without a mode-0 report before benching it for `RRM_BENCH_SECONDS`; the operating class
  follows the band the station is on (81 for 2.4 GHz, 115 for 5 GHz), because a 2.4-only
  client cannot measure a 5 GHz class at all.
- **WPA-Enterprise is supported** (`c8081ea`, from jonasevcik 9400e68; RADIUS MAC auth and
  DAS in `3b9fa28`). The wire DOES carry the RADIUS servers as `aaa.<n>.radius.*`:
  `inform.lua` `_wire_radius` reads them and `ucihelper.lua` `apply_config` writes them --
  through UCI on an `EAP_ENC` BSS, as raw `auth_server_*` lines on any other (ap.uc calls
  `iface_authentication_server()` only from its EAP branch). A basic wpad has no RADIUS
  client: Enterprise only warns (`sysinfo.eap_supported`), RADIUS MAC auth fails closed and
  drops the WLAN. `radius.dad.*`, `radius.macacl.{format,emptypassword}` and RadSec servers
  are deliberately not read (see the comment above `_wire_radius`).
