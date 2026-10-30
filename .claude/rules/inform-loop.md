---
paths:
  - "openuf/inform.lua"
  - "openuf/unhandled.lua"
  - "openuf/state.lua"
  - "openuf/stun.lua"
  - "openuf/assoctrack.lua"
  - "openuf/crypto.lua"
  - "openuf/inflate.lua"
  - "openuf/satisfaction.lua"
  - "openuf/announce.lua"
  - "tests/test_inform*.lua"
  - "tests/test_state*.lua"
---

# The inform loop, handle_response and the unhandled ledger

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **Everything the controller sends that openUF does not act on goes to the unhandled
  ledger, always.** `handle_response` records an unknown `_type` or `cmd` with its whole
  body, unknown top-level fields, and (through `_report_dropped_keys`) every `mgmt_cfg` key
  and `system_cfg` key shape no parser reads, into `unhandled.lua` → `/etc/openuf/unhandled.json`.
  So: implementing a new cmd or key means adding it to the dispatch or to `RECOGNIZED_*`, or
  it keeps being counted as ignored -- which is the honest state until it IS implemented.
  The ledger redacts by field NAME (`psk`, `passphrase`, `authkey`, `token`, `*key`...), so
  never hand it a payload whose secret sits under an innocent name, and never name a
  payload field of your own `*_key` (the first version did, and redacted its own sample).
  The `noop`'s `interval` is honoured (clamped 5–300 s); `_tick` re-reads it every cycle.
- **A capability bit is claimed only where a device-side probe passes**, and the probe is
  cached: `sae_supported` (`radio_caps2` 0x1/0x2), `owe_supported` (0x8), `airtime.supported`
  (`wifi_caps` 0x20), `ppsk_supported` (0x100000). These come from the hostapd build and are reported for
  every radio on every inform, live netdev or not: gated on one, they went missing exactly
  when a fresh or Forgotten device is adopted, and the controller's first push came down
  WPA2-only and OWE-less (two JIDU6401s, 2026-10-28; `test_inform_json.lua`). `wifi_caps` 0xC and `wifi_caps2` 0x60 are
  unconditional because they only make the controller *send* blocks openUF parses. The
  controller keeps a setting it could not push (upstream found `atf_enabled: false` stored
  from before the bit existed), so a newly claimed bit can change device state on the first
  push after an upgrade. `debug_caps` replaces a mask whole. PROTOCOL-VALIDATION.md's
  "Capability bitmasks" lists what every other bit would unlock and why it is not claimed.
- **`state.save` writes the whole table and `state.load` reads all of it back.** Eight
  fields are type-checked with defaults; everything else round-trips as-is. That
  symmetry is load-bearing: `swvlan_backup` (the switch reversibility ledger), `ip_mode`
  and the `static_*` fields, `locating`, `led_enabled` and the previous run's `mac` all
  live there, and `_warn_identity_change` only works because the previous MAC comes back.
  `load()` used to whitelist the eight and drop the rest on every start. The write is
  temp-file-and-rename, because a truncated file reads as "defaults" and un-adopts the
  device.
- **The inform loop is `_tick()`, and every stage in it is pcall-wrapped.** `build_json`
  shells out to a dozen tools; one nil in one field once crash-looped the daemon under
  procd. A bad cycle costs one heartbeat and one log line. Keep new stages inside the
  boundary, and keep `M.run` as nothing but the sleep loop around `_tick`.
- **`debug_caps` / `debug_payload_extra` are the one sanctioned exception to "never claim a
  capability you cannot honour".** They exist so the mesh go/no-go experiment is a
  `conf.lua` edit; the daemon shouts at startup while either is set. Never ship a default
  for them, and never let a real feature depend on them.
- **The reported address is read every heartbeat, not once.** `_populate_net_info` runs at
  startup, and on a DHCP-managed AP that is before the lease: START=99 is after `network`,
  but udhcpc is still broadcasting its DISCOVER (AP1, 2026-10-26: udhcpc started 01:18:41,
  the lease arrived :44), so `st.ip` stayed nil and every inform carried `ip "0.0.0.0"` --
  the controller showed both APs at 0.0.0.0 until a lucky reboot. `_refresh_net_info` in
  `_tick` asks `announce.get_ip` again before each payload (one `ip addr` per cycle, the
  holder cached), keeps the last address on a nil read, and logs each change. The announce
  module is loaded once (`M._load_announce`, `M._announce`); tests stub `inform._announce`.
- **`usage=guest` is an ordinary AP.** A portal WLAN arrives `mode=master usage=guest`; the
  mesh guard in `_parse_wifi_system_cfg` once read every `usage` but `user` as a backhaul VAP,
  and with Mesh Parent on the guest SSID replaced the vwire downlink. Only `downlink`/`uplink`
  (and a non-master `mode`) are backhaul.
- **The controller's wake-up is STUN, and openUF is the client** (`stun.lua`): a Binding
  Request with CHANGE-REQUEST every 30 s to `mgmt_cfg stun_url`, the mapped address out as
  `connect_request_ip`/`port`, and a type `0x8888` datagram back is "inform now". `_idle`
  is the one place that sleeps: it selects on the STUN socket, and while roam reports are
  on it also wakes every 250 ms for `_roam_poll`. Keep every wait inside `_idle`.
- **AirView needs two things the heartbeat cannot give.** Connection stages
  (`assoctrack.lua`) ride in `notif` informs, one POST each, sent only after the state
  inform and only while `st.notif_assoc_stat` (from `mgmt_cfg capability`) is true; roam
  reports must reach the controller within a second of the event, which is what the
  250 ms poll is for. `wifi_caps2` `0x2000` is claimed ONLY while those reports are sent --
  with it and no reports every roam vanishes from the controller. `_post_notif` (a finished
  RF sweep) is the other notif path; the two share nothing but the envelope.
- **A clock the controller says is off restarts ntpd; openUF never sets the clock.**
  BusyBox ntpd started at boot before its servers resolve never syncs (two JIDU6401s after
  a power cut, and a mesh child booting without its cable, every time). Every answer's
  `server_time_in_utc` is compared, trusted or not: over `CLOCK_MAX_SKEW` (60 s),
  `_note_server_time` runs `/etc/init.d/sysntpd restart`, at most every
  `NTP_KICK_INTERVAL` (300 s, timed on /proc/uptime), doubling up to `NTP_KICK_MAX` while
  it does not help. Symptom if it regresses: rrb-unifi logs `clock differs by N s` and
  fast roaming between openUF APs fails.
- **`_sta_stats_cache` holds the Experience window only** (`satisfaction.lua`): the
  firmware's retry term moves once a minute from the `_mov` deltas, so a station scores
  100 on retries until its first full minute. Capacity, throughput, linkscore and
  multicast are not sent any more; a test that expects them is wrong.
- **AES-GCM is mandatory for adoption.** UniFi 10.4.57 will not finish provisioning a
  device that has never sent a genuine GCM inform; a CBC-only device sticks at "Adopting"
  forever. Needs a GCM-capable `lua-openssl`; the `openssl` CLI fallback is CBC-only.
- **`_state_mtime` is the file's CONTENTS, not an mtime**, and nothing forks `stat` any more
  (BusyBox may have no applet; contents beat one-second mtime granularity anyway).
  `coreutils-stat` is no longer installed. `conf.lua`'s `inform_url` seeds
  `state.DEFAULT_INFORM_URL` and only fills a `state.json` with no URL of its own.
  `debug_dump_file` is capped at `debug_dump_max_bytes` (4 MiB, restart with a marker line,
  never rotate). `inflate` RAISES on a truncated stream -- it used to feed zero bits and
  spin forever inside a pcall nothing could interrupt.
