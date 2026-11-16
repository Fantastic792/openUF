# openUF and the UniFi U6 In-Wall: what matches, what is emulated, what cannot be done

openUF makes an OpenWrt device appear to a UniFi controller as a **U6 In-Wall (U6IW)** access
point. This page says, feature by feature, how close that is. Figures for the U6 In-Wall come
from Ubiquiti's public pages (https://techspecs.ui.com/unifi/wifi/u6-iw and the datasheet
https://dl.ui.com/ds/u6-iw_ds): 2.4 GHz 2x2 and 5 GHz 4x4 WiFi 6, one uplink port that takes
PoE, four gigabit ports, one of them a PoE output (needs PoE+ on the uplink), 250+ clients.

**Classes**

- **A, native:** the OpenWrt device really does it, set from the controller like on the U6 In-Wall.
- **B, emulated:** the controller sees what it expects, but openUF gets there another way, or
  the result is close and not equal. The difference is written in the row.
- **C, cannot be done:** the hardware or the platform has no way to do it. The row says what
  the controller shows instead (the fallback).

**Proof words**

- `hardware`: seen on real routers, listed in README "Tested on real hardware".
- `vm`: seen in the virtual lab only (simulated radios, no switch chip, no PoE).
- `inherited`: reported by the original project, not re-run on this code.
- `none`: not verified by anyone. Do not promise it.

| # | Feature | U6 In-Wall | openUF | Class | Proof | Benchmark |
|---|---|---|---|---|---|---|
| 1 | Adoption, inform, shown as U6IW | yes | yes | A | hardware | `single.boot` |
| 2 | Radio table | 2.4 GHz 2x2, 5 GHz 4x4 | the board's real radios, shown inside the U6IW radio slots; a choice the board cannot do (width, channel, power) is refused or clamped, never guessed | B | hardware | H1 |
| 3 | WiFi 6 (802.11ax) | yes | yes on an ax board | A | hardware | H1 |
| 3c | WiFi 6 on an ac or n board | n/a | the radio runs WiFi 5 or 4; the controller still shows a U6IW | C | none | H1 |
| 4 | OFDMA, MU-MIMO, BSS colouring, TWT | on, set by the stock firmware; the controller has no switch for them | whatever the OpenWrt driver turns on by default; openUF sets none of them | A (driver) | none | H1 records the values |
| 5 | Band steering | yes | yes | A | hardware | README row |
| 6 | Minimum RSSI | yes | yes | A | hardware | README row |
| 7 | Load balance | yes | yes | A | hardware | README row |
| 8 | Per-client speed limit | yes | yes (4.69 / 1.80 Mbps measured for 5 / 2) | A | hardware | `single.rate_limit` |
| 9 | WiFi Blackout Schedule | yes | yes | A | hardware | README row |
| 10 | Multicast and broadcast blocker | yes | yes | A | hardware | README row |
| 11 | Client isolation | yes | yes (`ap_isolate` + bridge rules) | A | vm | `single.client_isolation` |
| 12 | Guest portal, guest restrictions | yes | yes | A | hardware (portal) | `single.guest_firewall` |
| 13 | VLAN per WiFi network | yes | yes | A | hardware (private keys on VLANs), inherited (`vlan-ssid`) | `single.vlan_tag`, `single.vlan_isolation` |
| 14 | VLAN per wired port (port profile, native network) | yes, 4 ports | yes on a board with a DSA switch | A | started on hardware, client test not finished | H2 |
| 14c | VLAN per wired port on a one-port board | n/a | nothing to set; the controller shows the ports the board has | C | none | - |
| 15 | Port list | 1 uplink + 4 ports | the board's ports, numbered by its device map; a board with another count shows that count | B | vm (`fakeboard`), hardware | `fakeboard` stage |
| 16 | PoE output on a port, PoE on/off from the controller | port 1 passes PoE | no PoE hardware. openUF reports `port_poe = false`, `poe_caps = 0`; the controller shows no PoE control and a PoE setting changes nothing | C | vm | H3 |
| 17 | Port speed and duplex, storm control, port mirroring, egress limit, 802.1X, per-port STP, port security | on a UniFi switch; partly on the U6 In-Wall | not supported: the controller mostly does not send them to an AP, and openUF applies none | C | vm (table rows `not_sent`, `ignored`) | `table --only 'port_overrides\|PortConf'` |
| 18 | Wireless uplink (mesh) | yes | yes, one hop proven; several hops in the lab only | A | hardware (one hop), vm (multi-hop) | `multi.mesh_failover`, `multi.mesh_restore` |
| 19 | 802.11r/k/v between two openUF APs | yes | yes | A | hardware (iPhone FT-SAE, one lost ping) | `multi.roam`, `multi.kv_config` |
| 19b | Fast roaming to and from a genuine UniFi AP | yes | through the key translator plugin | B | inherited (`ft-unifi`) | H4 |
| 20 | Uplink Connectivity Monitor | yes | yes | A | hardware | README row |
| 21 | WPA2, WPA3, Enhanced Open, private pre-shared keys | yes | yes | A | hardware | README rows |
| 21b | RADIUS (802.1X), dynamic authorization, Hotspot 2.0 | yes | yes | A | vm | `table` rows |
| 22 | Client statistics, WiFi Experience | measured by the radio firmware | computed by openUF from signal and rates; close, not equal | B | hardware | - |
| 23 | Firmware upgrade from the controller | flashes Ubiquiti firmware | accepted and answered, nothing is flashed; openUF never writes firmware (the `guards` test proves it) | B | vm | `guards` |
| 24 | Locate, LED on/off | LED ring | the board's LED where its device map names one | A where a LED exists, else C | hardware | README row |
| 25 | DFS channels | yes | per board and country; left out on the JioRouter AX6000 under India | C for that board | hardware | - |
| 26 | Bluetooth setup from the phone app | yes | no Bluetooth; adopt over the LAN or by inform URL | C | - | - |
| 27 | 250+ clients | stated by Ubiquiti | not measured | - | none | - |
| 28 | Loop protection | STP on its switch | no STP or RSTP in openUF. BPDUs are dropped on WiFi and the mesh has a loop guard; the wired side relies on the upstream switch | B | hardware ("no loop in any run") | `multi.loop_guard` |
| 29 | DHCP and DNS for clients | none (an AP) | none (an AP): they come from the router upstream | same | - | `single.client_dhcp`, `single.client_dns` |

**Benchmarks named above**

- Names like `single.boot` and `multi.roam` are checks of the automated suite
  (`python3 labtest/run.py single`, `python3 labtest/run.py multi`; see `labtest/README.md`).
- `README row` = the line of that feature in README "Tested on real hardware".
- H1 to H4 are run on real hardware, on the router over SSH:

| Id | Command | Passes when |
|---|---|---|
| H1 | `grep -h -E '^(interface\|hw_mode\|channel\|ieee80211ax\|ieee80211ac\|he_bss_color\|he_su_beamformer\|he_mu_beamformer\|he_twt_required)=' /var/run/hostapd-phy*.conf` | each radio of an ax board has `ieee80211ax=1`; the other lines are copied into the field report as they are |
| H2 | controller: give port 3 a native network on VLAN N. Router: `ip -o link show \| grep -E 'master br-' ` and a wired client on port 3 asks for an address | the port's line names a bridge that is not `br-lan`, and the client's address is in VLAN N's range |
| H3 | controller API: `stat/device`, the device's `port_table` | no port has `port_poe` true; no `poe_mode` control is offered |
| H4 | a phone that uses FT walks from an openUF AP to a genuine UniFi AP and back while pinging the gateway | at most one lost ping each way; the openUF log has no `FT: Failed` line |

A feature that is not in the table: run its setting through the `table` stage. `works` = A,
`ignored` or `not_sent` = not supported (say so, it is not a fault), `broken` = a fault to fix.
