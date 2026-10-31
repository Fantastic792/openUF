---
paths:
  - "openuf/backhaul.lua"
  - "openuf/meshvlan.lua"
  - "openuf/inform.lua"
  - "openuf/wlansched.lua"
---

# The mesh (wireless uplink)

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **A wired AP's push has no mesh uplink entry; the station is built anyway.** The
  controller sends `usage=uplink` only to a device it last saw meshed; a cabled child gets
  `mesh.status/essid/psk` and no vwire entry (PROTOCOL-VALIDATION § Wireless uplink,
  2026-10-29). `backhaul.plan` builds the station from the mesh block on the last pushed
  uplink's radio (`st.backhaul_ul`), else the downlink's, else `mesh_radio()` (5 GHz).
  Taking the push literally removed the station on the next push and stranded a child
  whose cable was then pulled.
- **On swconfig, mesh is two problems DSA does not have** (since 2026-10-18; first run on a
  Deco M4R v1 on 2026-10-19: untagged, online over the air with the cable pulled). (1)
  `br-lan`'s wired port is the CPU trunk's sub-device, whose carrier never
  drops: the uplink policy must read the socket's link from the switch
  (`st.backhaul_wired_phys`, `backhaul.tick`), and on a switch between wire and air the
  bridges are flushed by hand. (2) The VLAN bridges ride `eth0.<vid>`, so a tagged SSID
  needs `br-lan.<vid>` as a second uplink over the hop -- and that port next to `eth0.1` is
  a loop (`br-lan` -> `eth0.1` double-tags, the switch strips the outer tag onto the
  uplink). `meshvlan.lua` therefore keeps it runtime-only and strictly behind nft `bridge
  openuf_meshvlan` (802.1Q in or out of `br-lan` through wireless ports only): guard in
  before the port, port out before the guard, one atomic `nft -f` (not `util.nft_apply`,
  whose fallback deletes the table first). Never move that port into UCI: netifd would
  bring it up at boot, before any guard exists.
- **On DSA, a host the mesh link carried stays stuck on the switch's CPU port** (found on
  two JIDU6401s, 2026-10-28). A MAC the bridge learns behind a WDS port is also written
  into the switch chip against the CPU; when the link ends and the host turns up behind a
  socket, the bridge's entry moves but the chip's does not, and frames for the host from
  any other socket die at the CPU (taken as already switched). A link flap and a bridge
  flush both leave it; a reboot cleared it. `backhaul.heal_wds_moves` remembers the hosts
  behind WDS ports each heartbeat and rewrites a moved one's entry (static on the socket,
  then deleted). A host that crossed the link between two heartbeats (the controller, at
  failback) is caught by the switch's own dump instead: for a few heartbeats after a WDS
  port goes, a switch-port entry with no `self` twin is rewritten too. Symptom if it
  regresses: after failback, a wired host reaches the APs but nothing beyond the uplink.
- **A mesh child's AP on the station's radio goes silent after a Wi-Fi reload** (JIDU6401,
  mt76, 2026-10-29). At boot it starts when the station joins; a reload (any config push)
  while the station stays joined leaves it ENABLED in hostapd, netdev UP, carrier 0,
  nothing sent, and `handle_probe_req: send failed` in the log: the child's 5 GHz SSID
  was off the air until the next reboot. `backhaul.revive_silent_aps` (every heartbeat
  in wireless mode, station joined, `SILENT_TICKS` = 2 in a row) restarts such a BSS with
  `raw STOP_AP` + `update_beacon`, wlansched's recipe; `disable`/`enable` does not work.
  A netdev that is DOWN (schedule, uplink monitor, guest selfrun) is not silent and is
  left alone.
- **The mesh uplink policy must not run at the inform's pace.** It once counted heartbeats
  (two without carrier), but a heartbeat whose inform cannot reach the controller waits a
  10 s connect timeout and then a doubling backoff, and a pulled cable is exactly when that
  happens: the station came up 39 s to 98 s after the pull on a JIDU6401 (2026-10-28), and
  the controller heard of it up to 60 s later still. So the loss is timed in seconds
  (`backhaul.DOWN_SECS`; a return must hold `backhaul.UP_SECS` before failback, since each
  failback is a commit + `wifi reload`), `inform._idle` reads a DSA socket's link every
  `CARRIER_POLL_S` and wakes the loop when it changes, and `inform._cycle` caps the wait
  (`backhaul.wait_cap`) while a switch is due or has just been made, starting the backoff
  over. swconfig boards still read the switch port once per heartbeat.
