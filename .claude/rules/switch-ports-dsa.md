---
paths:
  - "openuf/switchvlan.lua"
  - "openuf/sysinfo.lua"
  - "openuf/lldp.lua"
  - "openuf/led.lua"
  - "openuf/modelmap/**"
  - "openuf/ucihelper.lua"
  - "setup.sh"
---

# Switch ports, DSA bridges, per-port VLANs and board quirks

Landmines moved from CLAUDE.md; they load when a matching file is touched.

- **lldpd's chassis ID must match `lan_cpueth`'s MAC** (`uci set
  lldpd.config.cid_interface=lan`) or the controller shows the wrong Parent Device: lldpd
  otherwise picks the lowest-numbered interface, which the gateway then learns under an ID
  matching no adopted device.
- **A DSA bridge's MAC follows its FIRST member, not the lowest address** (netifd `bridge.c`,
  `bridge_reset_primary`): with no `macaddr` on the bridge's `config device` section, br-lan
  takes the MAC of its alphabetically-first present port and re-picks whenever that port
  leaves. On a board whose `board.d` sets no LAN MAC (the Deco M5) a map with
  `lan_cpueth = "br-lan"` therefore has an identity that `switchvlan.dsa_apply` can move: a
  Native-VLAN push on that first socket takes it out of br-lan and the next inform arrives
  under a MAC the controller never adopted. Pin the address in UCI before adopting (the
  `deco-m5` header has the three lines). The JioRouters escape it because `board.d` sets
  `lan`'s MAC for them, the AX3000T because its map names a socket, the Deco M4R v4 because every
  one of its DSA ports inherits the conduit's label MAC.
- **On the Deco M4R v4, `eth0` and `eth1` are DSA sockets and the CPU conduit is `dsa`** (OpenWrt
  24.10 renamed them, commit 4fed462454, to keep the stock names working). The daemon keys on the
  name `eth0` in one place only, inform's fallback port table for a map with no `ports`; the generic
  maps' `lan_cpueth = "eth0"` would name a bridge port there, and a VLAN sub-device on a bridge
  port never sees a frame. Its map uses `br-lan`. New code that treats `eth<n>` as a CPU netdev is
  wrong on that board.
- **`led.set_enabled` writes the LED's own `max_brightness`, read from sysfs, not a literal 1.**
  A GPIO LED's ceiling is 1, so the literal was invisible on every board until the Deco M5's
  lp5521 (ceiling 255), where 1 is 0.4 %: the case light went dark the moment openUF started,
  Locate included, since the timer trigger blinks at the current brightness. Unreadable or
  non-numeric falls back to 1.
- **VLAN ids must be below the switch's VLAN table size** (16 on some boards) — netifd has
  no `vid` option, so the id doubles as the table slot.
- **`uplink_detect = "fdb"` reads ONE bridge's FDB** (`sysinfo.lan_bridge` resolves
  `lan_cpueth` whether it names the bridge or a socket). The whole-FDB read took whichever
  learned line came first for the gateway's MAC, which on an AP with a tagged SSID can be
  the VLAN bridge's own port.
- **DSA per-port VLAN is a bridge move, never `bridge-vlan`.** `switchvlan.dsa_apply` moves
  the socket into `br-openuf<id>`; `ucihelper.ensure_vlan_network` owns the tagged uplink
  member and never evicts anyone else; `apply_config`'s `keep_vlans` keeps a wired-only
  VLAN's bridge alive. The ledger is `st.dsa_brlan_ports`, and a push with no `switch.*`
  keys counts as "off" only while a ledger exists.
- **A moved DSA socket, and the tagged uplink sub-device, run with MAC learning OFF, and
  that is not optional.** The VLAN bridge is software but the socket is a port on the same
  ASIC as the uplink, and the ASIC has ONE address table: with learning on it files the
  attached device against the socket and hardware-drops every VLAN-tagged reply to it,
  while outbound stays perfect and every counter says the move worked (upstream: 4 DHCP
  DISCOVERs out, nothing back; 2 ms OFFER with learning off). `dsa_apply` writes
  `openuf_brport<vid>_<socket>` (`learning '0'`), `ensure_vlan_network` writes
  `openuf_brport<vid>` for `<uplink>.<vid>`; both are swept by `prune_vlan_networks` and
  `dsa_restore`. The bill: that socket's hosts vanish from `bridge fdb`, the only
  wired-host source on DSA. `switchvlan.reconcile_mac_taps` pays it with an nft
  bridge-family tap (`table bridge openuf_learn`, sets `portmacs` and `portips`, 5-minute
  timeouts), read by `sysinfo.mac_table(ifname, bridge, allow_tap)` only when the FDB is
  silent and only for a socket whose bridge is not the uplink's. Rows carry `vlan` (from
  the `br-openuf<vid>` name) and the tap's `ip`, because the controller files a wired
  client under a network by `host.vlan` (default 1) and the AP has no ARP entry for a host
  on a VLAN it holds no address on. **None of this has run on a JioRouter yet.** The
  uplink socket stays silent, gateway included: one known MAC alone on a port lands in
  `downlink_table` and inverts the topology (feature 39 in PROTOCOL-VALIDATION.md).
