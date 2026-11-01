# Protocol validation findings

openUF's assumptions about the UniFi inform protocol were originally inferred from
third-party reference material — [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway)
and [paultyng/go-unifi](https://github.com/paultyng/go-unifi) — never checked against a
real UniFi Network Application. This document is the project's own ground truth,
established by running openUF against a real self-hosted controller, capturing decrypted
inform responses (`debug_dump_file`, see [USAGE.md](USAGE.md#3-configuration)), and
decompiling the controller's own Java bytecode and React bundles.

**Where this document and the third-party references disagree, this document wins.**
In particular, go-unifi models the controller's *admin REST API*, which is a different
surface from the inform wire protocol — several fields that exist there
(`dtim_mode`) have no counterpart on the wire. `bandsteering_mode` and the Roaming Assistant
do have one, but only for a device that claims `wifi_caps` bit `0x4` and `wifi_caps2` bit
`0x20` respectively -- see [Capability bitmasks](#capability-bitmasks).

This is a **reference for the confirmed current state**, not a lab journal. Superseded
hypotheses and the investigation trails that produced these facts have been removed;
git history has them if needed. Decompiled evidence is retained inline wherever a claim
would otherwise be hard to re-verify.

**Environments:**

- `lscr.io/linuxserver/unifi-network-application:10.4.57` (Docker, pinned), with openUF as
  the AP in a disposable Alpine container on the same Docker network (`tools/validation/`).
  Mocked `uci`/`ubus`, no radios.
- **Real hardware, 2026-07-28:** a TP-Link Archer C5 v1 (OpenWrt 25.12.5, ath79/mips_24kc,
  ath9k 2.4GHz + ath10k 5GHz) adopted by a **UniFi Cloud Gateway Ultra running Network
  10.4.57** — the same version as the Docker baseline, so the two are directly comparable.
  See [the first real-hardware run](#the-first-real-hardware-run) for what only appears
  once genuine `netifd`/`hostapd`/radios are in the loop.

**Status:** adoption, provisioning, and every UI-surfaced feature listed in the
[feature matrix](#feature-matrix) are confirmed working end-to-end against a real
controller, except where a row says otherwise. Adoption, the WiFi config push, live
clients and the radios themselves are additionally confirmed on real hardware.

---

## Validation environment

Everything in this section is about `tools/validation/`, not about openUF's product code.
Real OpenWrt target hardware has genuine `uci`/`iw`/`ubus`/`hostapd` and hits none of it.

### Required setup, in order

1. **`lua-openssl` must be present in the AP container.** Without an AES-GCM backend the
   controller will never provision the device — see
   [the GCM provisioning gate](#the-gcm-provisioning-gate). `tools/validation/ap/Dockerfile`
   builds the `zhaozg/lua-openssl` rock (`luarocks-5.1 install openssl`); no prebuilt Alpine
   apk exists. `install.sh` already installs `lua-openssl` on real OpenWrt hardware.
2. **Set the Inform Host Override before adopting anything.** Devices → Device Updates and
   Settings → Device SSH Settings. It must be the controller container's **literal IP** —
   the controller rejects a bare hostname with `ERROR inform - dev[<mac>] invalid inform_ip
   <hostname>`. This setting lives in the controller's own DB and is wiped by every
   `docker compose down -v`.
3. **Set a Device SSH Authentication password** (≥12 characters, enforced by the controller's
   own validator). Needed for L2/SSH adoption.

Skipping (2) presents as adoption silently stalling: `state.json` never flips
`adopted: true`, and `server.log` logs `inform decryption failed with defaultAuthKey=false`
— the controller *did* issue a per-device key, but the device never received a usable
config push. That is a setup omission, not a new bug.

### Always reset fully; never patch live state

Validation runs start from `docker compose down -v && docker compose up -d --build`.
Hand-editing a running container's `state.json`, or a device doc in Mongo, produces
results that do not reproduce — see [the minidev cache](#the-minidev-cache-never-sees-external-writes).

### The mocks, and their one sharp edge

The Alpine container has no `uci`, `ubus`, `iw`, `bridge`, or `hostapd`. Four
validation-only shims stand in, all outside `openuf/`:

| Shim | Stands in for | Notes |
|---|---|---|
| `ap/uci-mock.lua` | `require("uci")` | Installed at `/usr/local/share/lua/5.1/uci.lua`. Seeded with `radio0`/`radio1` `wifi-device` sections matching `generic-dualband-ap.lua`'s `hwassign`. |
| `ap/ubus-mock.sh` | `ubus call network.wireless status` | Static `radio0`→`wlan0`, `radio1`→`wlan1` map. |
| `ap/iw-mock.sh` | `iw dev … survey/station/scan dump` | Three fake stations with independently growing counters, plus fake neighbour BSSes. |
| `ap/bridge-mock.sh` | `bridge fdb show` | Two fake wired hosts; `entrypoint.sh` seeds `/proc/net/arp` via `ip neigh replace` (kernel state can't be baked into an image layer). |

**`uci-mock.lua` is in-memory only, per process.** Its `db` table is seeded fresh at
process start and only ever one-way dumped to a debug JSON file on `commit()` — never read
back. Consequences:

- Restarting `inform.lua` to pick up code changes **wipes any WiFi network config that was
  only ever pushed to the previous process's memory.** Recreate the WLAN in the controller
  UI afterwards to force a fresh `system_cfg` push.
- A throwaway `lua5.1 script.lua` invocation gets its own pristine mock state and proves
  nothing about the running daemon. **The only reliable way to check live wire data is to
  read what the controller actually received** (Mongo, or the REST API), never a fresh
  local script.

### Other environment facts

- **`cap_add: [NET_ADMIN]`** is required on the `ap` service — `netconfig.lua`'s `ip addr
  add`/`ip route replace` and `firewall.lua`'s `nft` both fail with `Operation not
  permitted` without it. Docker drops the capability by default even for root.
- **A `docker stop`/`start` of an AP container yields a fresh MAC from Docker**, so a
  restarted container is a brand-new device to the controller. Convenient for producing
  fresh adoption targets; means a stopped device's controller entry can never be resumed.
- **`ap2` compose service** (`replacement` profile) provides a second same-model device for
  the replace/clone flows; recipes in `tools/validation/README.md` §6.
- A `reboot` handled inside the container genuinely exits the container (no init to survive
  it). `docker start` the stopped — not removed — container to recover logs.
- Background `127.0.0.1:9080/api/ucore/manifest` and `get-ulp-manifest` connection-refused
  errors appear in `server.log` regardless of device activity. Pre-existing and harmless.

---

## The first real-hardware run

2026-07-28, Archer C5 v1 + UniFi Cloud Gateway Ultra (Network 10.4.57). Everything below
is what the Docker environment structurally *cannot* show: it mocks `uci`/`ubus` and has no
radios, so a config that `apply_config` writes "successfully" is never handed to `netifd`,
`hostapd`, or a regulatory domain. Three of the four findings are of the same shape — UCI
that reads perfectly and not one SSID on the air.

### The discovery path decides the adoption method, not the subnet

A controller that has heard a device's L2 broadcasts adopts it **by SSH**, even when it sits
on the controller's own subnet and its informs are landing perfectly. On the Adopt click the
gateway opened three SSH connections to the AP within 20 seconds:

```
dropbear[3746]: Child connection from 192.0.2.1:33114
dropbear[3746]: Login attempt for nonexistent user from 192.0.2.1:33114
```

and, failing them, parked the device at **Connection Interrupted** while the inform loop kept
running normally. The device record remembers this: removing it, stopping the broadcaster
(`config.l2_announce = false`), and letting the device re-appear from L3 informs alone made
the very next Adopt click complete over the inform channel with no SSH attempted at all.

So a device that cannot accept the controller's SSH login (no password auth, no bootstrap
account) **must** have `l2_announce` off, regardless of topology. "L3 adoption" names how the
controller discovered the device, not where it is.

### `macfilter="disable"` takes both radios off the air

OpenWrt's own schema (`/usr/share/schema/wireless.wifi-iface.json`) declares the option as
`enum: ["allow","deny"]`. 25.12's ucode validator does not ignore an out-of-enum value — it
aborts the radio setup:

```
wifi-scripts: macfilter: disable has to be one of [ "allow", "deny" ]
netifd: radio0 (4179): Died   (validate.uc:47 → die())
```

openUF wrote `macfilter="disable"` whenever the MAC filter was off, i.e. by default, so
**every** config push killed both radios. "Off" is the absence of the option: `ap.uc`'s
`iface_macfilter()` emits `accept_mac_file`/`deny_mac_file` for the two enum values and
returns for anything else. Fixed by deleting the option instead.

### `beacon_rate` is fatal on a driver that cannot program it

hostapd does not treat an unsupported beacon rate as a hint:

```
nl80211: Driver does not support setting Beacon frame rate (legacy)
Failed to set beacon parameters
Interface initialization failed
```

The 2.4GHz ath9k radio never came up, while the ath10k 5GHz radio — which the controller sent
no `beacon_rate` for — was fine. The capability is `NL80211_EXT_FEATURE_BEACON_RATE_LEGACY`,
reported **per phy** in `iw phy`'s "Supported extended features" list; neither phy on this
board has it. openUF now gates the option on that flag and still applies the rate floor
itself (`basic_rate`/`supported_rates`), which needs no driver support.

### The regulatory domain arrives as a numeric code, and nothing was applying it

`get_radio_table` has always *read* UCI `country` to derive the payload's `country_code`, but
nothing ever wrote it — so the radios kept whatever regdomain OpenWrt booted with while
reporting `840`/US back (the fallback when the option is unset). On the wire it is an
**ISO 3166-1 numeric** code, sent both unindexed and per radio:

```
radio.countrycode=203
radio.1.countrycode=203      # radio.1.phyname=radio0
radio.2.countrycode=203      # radio.2.phyname=radio1
```

UCI wants alpha-2, so 203 → `CZ`. Applying it moved the device from `country US: DFS-FCC` to
`country CZ: DFS-ETSI` and the 2.4GHz radio to channel 13 — legal in CZ, not in the US.

Worth knowing for anyone reading channel numbers off a live AP afterwards: with
`channel=auto` (which is what the controller sends unless a channel is pinned) hostapd ACS
picks freely within the new domain, and its choice can be a poor one in practice — it landed
on 5GHz channel 165, which CZ caps at **13 dBm**, and on 2.4GHz channel 13, which plenty of
client devices refuse outright. The controller's site-level Channel Plan exclusions are not
on the wire; pinning the channel per radio in the device's Radios settings is the remedy, and
that push (Auto → 6 / 36) was confirmed reaching UCI and the live radios within one inform
cycle.

### What the real controller sends that the Docker one did not

`radio.<n>.ieee_mode` came through as **`11naht40`** (5GHz) and **`11nght20`** (2.4GHz) — HT,
not HE, even though the device presents as an 802.11ax U6-InWall. openUF's downward clamp of
the PHY generation was therefore never triggered on this site; it remains insurance for a
site configured with wider/newer channel widths, not a confirmed-exercised path.

WPA2/WPA3 transition with PMF Optional arrives as `aaa.<n>.wpa=2` +
`wpa.key.1.mgmt=WPA-PSK` + `pmf.status=enabled` + `pmf.mode=1` — no SAE key-mgmt on the wire
at all, confirming the earlier Docker-era note that this controller signals WPA3-mixed purely
through PMF for a madwifi-driver model.

---

## The ports an AP reported were the CPU's, not the board's — FIXED

2026-08-02, two APs on the real UCG Ultra: a TL-WDR3500 (`Bedroom AP`) and an Archer C5 v1
(`Living room AP`). The Ports view showed **one port per AP**, and the number on it was
wrong. The investigation started from the user's own reading of the UI — only the uplink is
listed, and what is listed looks like it came from the gateway.

What the controller held for each AP (`/proxy/network/api/s/default/stat/device`):

```
port_table: [{port_idx:1, is_uplink:true, speed:1000, full_duplex:true, name:"PoE Out + Data"}]
ethernet_table: []      lldp_table: []
uplink: {..., uplink_remote_port:4, uplink_source:"lldp_downlink"}
```

Three separate things were wrong, all of them on the openUF side:

- **The speed was the CPU port's.** Both modelmaps declared a single port naming the CPU
  netdev, whose link is the internal SoC↔switch one — always `1000/full`. The Bedroom AP's
  actual uplink socket had negotiated 100baseT: `swconfig dev switch0 port 4 get link` said
  `speed:100baseT`, and the gateway's own row for the same cable said **FE** while the AP's
  row said **GbE**. A metric that contradicts the device on the other end of the wire.
- **The other sockets did not exist.** Both boards had live links on sockets the controller
  never heard of (the Archer C5 had three sockets up, of which one was reported).
- **Wired clients were attributed to the gateway.** Two hosts plugged into the APs' own LAN
  sockets showed up as `last_uplink_name: "Cloud Gateway Ultra"`, `sw_port` 2 and 4,
  `sw_depth: 1` — the gateway learned them through its downlink and, since the AP they sit
  behind reported no downstream port at all, the gateway's account was the only one.

The old code's premise was that MAC↔socket mapping "is knowable only from the switch's own
ARL table, which openUF does not read". The fix is that it now does. One
`swconfig dev switch0 show` returns per-port `link`/`pvid`, the ARL table, and (driver
permitting) per-port MIB counters — see the [`port_table[]` entry](#port_table-entry)
reference for what each field is sourced from now.

**Which socket is the uplink is measured, not declared.** The default route's gateway IP →
its MAC in `/proc/net/arp` → that MAC's port in the ARL. On these two boards the same
gateway MAC was learned on physical port 4 and physical port 2 respectively, matching the
cabling — a modelmap constant would have been wrong on one of them, and would go wrong on
either the next time a cable moves. It is also the guard on per-port VLAN: that socket is
refused an assignment, and a board that cannot determine it refuses every port.

**A side effect worth recording:** per-port VLAN assignment was unreachable on both real
boards before this. The only reported port was the uplink, and uplink ports deliberately
carry no `swport` — so the Port Manager had exactly one port and it was the one port that
must never be reassigned.

Two things looked broken and are not openUF's doing: `lldp_table` is empty because `lldpd`
on the APs receives nothing (the UCG Ultra does not transmit LLDP to them, though it happily
parses theirs), and `ethernet_table` is not sent at all — no evidence yet on what the
controller does with it, so it stays unsent rather than guessed at.

### The Ports view's other columns

Empty is the right answer for most of them, and the real gateway is the control group:

| Column | Source | On this site |
|---|---|---|
| **Anomaly** | Controller-side, from its own stats history ("24h AI Anomaly Score") | `0` on every AP port; `20` on the UCG's port facing the 100baseT-linked AP — the same conclusion it records on the device as `detailed_states.negotiated_low_uplink_port_speed: true`, which only appeared once openUF stopped claiming 1000 |
| **STP** | `stp_state`/`stp_pathcost`, a USW port property | `-` for every port, the gateway's own included |
| **Profile** | Port profile (`portconf_id` in `port_overrides`), controller-side config | `-` for every port, the gateway's own included |
| **Operation** | `op_mode` (`switch`/`mirror`/`aggregate`) | The controller writes `op_mode: "switch"` and `forward: "all"` onto openUF's ports **although openUF sends neither** — server-side defaults. `switch` is the truthful value for these sockets anyway |
| **Tx/Rx Sum, Tx/Rx Rate** | `rx_bytes`/`tx_bytes` | Populated from the per-port MIB — see below |
| **Tx/Rx Multicast, Broadcast, Dropped, Packets** | `rx_multicast`, `tx_broadcast`, `rx_dropped`, … | Sent by the gateway, not by openUF: swconfig's per-port MIB exposes `RxGoodByte`/`TxByte` and nothing else, and the CPU netdev's totals belong to every socket at once |

**Per-port counters are a driver setting, not a capability.** The ar8xxx driver only maintains
the MIB while `ar8xxx_mib_poll_interval` is non-zero, and boards differ: the AR9344 shipped at
`500` and reported counters, the AR8327 shipped at `0` and answered "Operation not supported"
for every port, so one AP's Ports view was populated and the other's read 0 B everywhere. One
`swconfig dev switch0 set ar8xxx_mib_poll_interval 500` produced counters on the next read, so
openUF now does that once at startup when the attribute exists and reads 0
(`switchvlan.enable_mib_polling`, opt out with `dev.conf.vlan.mib_poll_ms = false`).

---

## A tagged SSID's trunk deafened every wired client on the AP — FIXED

2026-08-02, same two APs. The user reported a printer at a static `192.0.2.11`, cabled
into the Bedroom AP, that nothing could reach and that never appeared in the controller UI.
It was an openUF bug, and the printer was only the visible half of it — a second host on
another socket had been dead the same way, unnoticed.

The printer was alive and talking: the AP's switch had learned its MAC in the ARL on
physical port 2, and that was the MAC the laptop's ARP cache held for `.11`. Frames got
*from* it and never *to* it.

**UCI and the switch disagreed**, which is the tell:

| | UCI `switch_vlan` for VLAN 1 | live `swconfig dev switch0 show` |
|---|---|---|
| WDR3500 — **AR8229**, `vlans: 16` | `1 2 3 4 0t` (sockets untagged) | `0t 1t 2t 3t 4t` — **all tagged** |
| Archer C5 — **AR8327**, `vlans: 4096` | `0 1 2 3 4 5` | `0 1t 2 3 4 5` — as written |

Both APs carried an identical `openuf_swvlan10` trunk of `0t 1t 2t 3t 4t`, written by
`switchvlan.trunk_ports()` for the tagged IoT SSID. Only the AR8229 let it bleed into
VLAN 1.

**On the `ar8216`/`ar8226`/`ar8229`/`ar8236` driver family, tagging is not a property of
(port, VLAN) — it is one global per-port bitmask.** `ar8xxx_sw_set_ports()` does

```c
if (p->flags & (1 << SWITCH_PORT_FLAG_TAGGED))
        priv->vlan_tagged |= (1 << p->id);
```

and `__ar8216_setup_port()` reads that single bitmask to choose `AR8216_OUT_ADD_VLAN` vs
`AR8216_OUT_STRIP_VLAN`, for every VLAN at once. So marking socket 2 tagged for VLAN 10
made it egress-tagged in VLAN 1 too, and the untagged printer dropped every frame. The
AR8327 escapes this because `ar8327.c` overrides the get/set-ports ops with a real
per-(port, VLAN) tag table — which is exactly why the bug shipped: **it is invisible on
the board the feature was developed against.**

The fix trunks only the CPU port and the uplink socket, which is the entire path a tagged
SSID's frames take. The old code's stated reason for tagging everything — that the uplink
socket is not knowable from config — had gone stale: `sysinfo.uplink_phys_port()` measures
it from the switch's own ARL, and `switchvlan.apply()` already had the answer in hand.
When it cannot be resolved openUF now holds any existing trunk rather than guessing;
letting a transient nil fall through to the reconcile pass would delete a working trunk
and reload, then rewrite it on the next inform, bouncing the IoT WLAN in a loop.

Verified live on both boards. WDR3500: VLAN 1 back to `0t 1 2 3 4t`, printer and the
second host answering ICMP from the AP and from a laptop two hops away. Archer C5: VLAN 1
untouched, VLAN 10 down from `0t 2t 3t 4t 5t` to `0t 2t`. On both, a one-shot
`udhcpc -i br-openuf10` still took a lease from the VLAN 20 gateway, so the feature the
trunk exists for is intact.

**A hardware limit that follows, and cannot be fixed in software.** On a global-bitmask
chip a port cannot be untagged in VLAN 1 *and* tagged in VLAN 10. Running a tagged
wireless VLAN therefore leaves the **uplink** socket egress-tagged for VLAN 1 as well —
visible above as the `4t` in `0t 1 2 3 4t`. The UCG Ultra accepts tagged VLAN 1 on that
port (it is the live, working state), and the effect is confined to the one socket facing
the gateway rather than every socket facing a client.

**Generalising:** this is the third finding in the same shape as the first real-hardware
run — config that reads perfectly and hardware that does something else. A `swconfig`
port string is a *request*; `swconfig dev <sw> show` is the only account of what the ASIC
actually holds, and the two must be compared on each chip family, not one.

---

## Controller behaviors that are not openUF bugs

Each of these cost real investigation time at least once.

### A 404 with an empty body does not mean the inform was rejected

A well-formed, correctly-encrypted first-contact inform gets **HTTP 404 with
`Content-Length: 0`**, with zero corresponding entry in the controller's `inform` logger —
yet the device is created server-side and shows as "1 device is ready to adopt." Verified at
the wire level through a raw byte-logging TCP relay: the `100 Continue` handshake completes
normally and the response genuinely has an empty body.

Malformed packets behave differently and are easy to tell apart: they get **400** with a
specific logged reason (`Bad packet magic`, `Data version 0 is not supported`,
`Content too short`).

Ruled out as causes, so they aren't re-tried: compression (a real zlib-compressed,
correctly-flagged payload gets the same 404) and GCM-vs-CBC (both get the same 404).

`http_post` treats any non-200 as a hard failure and never inspects the body. In every case
observed the body was genuinely empty, so nothing is lost — but the client cannot
distinguish "processed, nothing to say" from "rejected". An unadopted device therefore keeps its
own cadence on a 404 (so the inform after the Adopt click is not up to 60 s away) and logs
`pending adoption` once; after adoption a 404 backs off like any failure. An HTTP 503 (10.6
shedding inform load) waits the full 60 s at once.

**When you see this on a fresh device: click Adopt.** That is the correct next move, not
more debugging.

### Historical stats live in the `unifi_stat` database, on a 5-minute cadence

CPU/memory graphs, per-client Traffic Activity, the Radios tab's "Avg." columns, and the
Ports view's Bps chart are **not** rendered from live inform data. They are read from
`unifi_stat`'s `stat_5minutes` / `stat_hourly` / `stat_archive` collections, written by a
periodic archiver (`com.ubnt.service.system.QDcGUYAmLvJwylXw`, internally labelled
`stat-processor`).

So: a flat/empty graph checked two minutes after adoption is expected. Allow ~15 minutes, or
a few 5-minute buckets, before treating it as a defect. Query
`unifi_stat.stat_5minutes` directly to check whether the data is landing — `db.stat` in the
**`unifi`** database is a different, empty collection and querying it is misleading.

### The minidev cache never sees external writes

`com.ubnt.service.devmgr.SNMiFVJXxaonBOtqbJ`'s device lookup is cache-then-DB-fallback: an
in-memory "minidev" summary (`_id`, `site_id`, `authkeys`, `x_aes_gcm`, `hash_id`) keyed
`("global", "minidev", mac)`, populated once on the first DB hit and never invalidated by an
external write. Editing a device doc in Mongo while the controller runs therefore has no
observable effect. Restarting the controller to force a reload introduces its own artifact:
the device flips to **Offline** in the UI even while `last_seen` keeps advancing and informs
keep landing, and does not self-heal within a normal observation window.

This is why the "always reset fully" rule exists. It also explains why "Remove"
(factory-reset) leaves informs decrypting successfully afterwards — they are being served
from a stale cache entry while the underlying doc is already gone.

### Config sync can get stuck after informs stabilise

Observed while trying to force pure-WPA3 emission: switching the test WLAN's Security
Protocol to WPA3 made the controller **stop pushing the WLAN's `aaa.<n>`/`wireless.<n>`
blocks entirely** — not just the SAE fields — and reverting the setting did not restore
pushes, even across an `inform.lua` restart. No related error in `server.log`.

**Reusable warning:** a live no-op does *not* always mean "the controller is deliberately
withholding this field because of a capability gate" (which is exactly what it meant for
`advertise_ap_name`). Sometimes it means the environment's config sync is stuck. Decompile
the emitter to tell the two apart before concluding anything.

### Controller-side UI quirks

- **Environment tab (AirView) stops updating ~10 s after mount**, with no user interaction:
  the row disappears, "No WiFi broadcasts found" renders, and the sidebar filters grey out.
  Clicking any other Time Range tab instantly restores everything. Verified the data is
  present server-side the whole time (10/10 direct `stat/rogueap` polls over 23 s returned
  all entries). Consistent with the table capturing `rowsPerPage` from the pre-fetch, empty
  selector result at mount (`useState({pageNumber:0,from:0,rowsPerPage:r.length})`) and never
  recomputing it. A genuine defect in the controller's own frontend, outside openUF's control.
- **Radios tab's "Type" filter shows nothing until one option is explicitly checked**, unlike
  Band/MIMO/Status on the same page, where an empty selection means "show all." "Type" here
  means the **AP's own uplink** connection type, so a wired-uplinked AP correctly appears
  under "Wired" — the radios themselves being wireless is irrelevant.
- **"Remove" on a client sends no wire command at all** — pure controller-side bookkeeping.
  A still-present client reappears on the very next inform.
- **The upgrade confirmation dialog truncates versions to 3 components**, so a genuine
  full-string mismatch can render as "Update U6 IW from 6.8.2 to 6.8.2?".

---

## Decompiling the controller

The controller is a Java app, and Java bytecode retains field-name string constants in the
class-file constant pool even under ProGuard-style class/method obfuscation — a far friendlier
analysis target than the AP's encrypted ARM firmware (see [dead ends](#dead-ends--do-not-re-attempt)).

**Procedure:**

1. Extract `/usr/lib/unifi/lib/internal/internal-dependencies.jar` from the container — the
   real ~29 MB application jar. (`ace.jar` is only a license-protected bootstrap `Launcher`.)
2. **Unzip it on a case-sensitive filesystem.** `com.ubnt.service.aa` and
   `com.ubnt.service.aA` — and ~55 other package pairs differing only by case — are distinct
   real packages. macOS silently folds them into one directory, corrupting the extraction and
   producing a decompile of the *wrong* class's method body with no warning. Do the
   `unzip` + decompile inside a Linux container (`docker cp` the jar into the controller
   image itself, which already has a JVM).
3. **Use CFR (`cfr.jar` 0.152) for large methods.** `jadx` silently drops method bodies it
   can't reconstruct — no marker, just absent output. The ~5,182-unit method that gates
   provisioning was invisible to jadx and decompiled cleanly under CFR. jadx is still fine
   for browsing and for properly-scoped class listings.
4. For frontend behavior, fetch the live controller's own React chunks
   (`react-app-wrapper.*.js`, `radiosPage.*.js`, `swai.*.js`, `airview.*.js`) and grep them.
   **Where they are (10.6.106):** the UniFi OS shell at `/` is public but only loads its own
   bundles; the Network app lives behind `/proxy/network/manage/` (401 without a session). A
   UniFi OS **API key** sent as `X-API-KEY` opens it: `/proxy/network/manage/` returns the
   shell whose loader is `angular/<build>/js/index.js`; that file's chunk manifest names ~49
   entry chunks served from `/proxy/network/manage/react/js/<name>.<hash>.js`; the main bundle
   `swai.<hash>.js` (~5.5 MB) carries the capability constant tables and a map of ~1,600 lazy
   chunks (`<id>.<hash>.js`, same directory; ~21 MB in all) which hold the device settings
   forms. The same key works on the legacy API (`stat/device`, `rest/device`, `rest/setting`,
   `cmd/devmgr`) and on `/proxy/network/v2/api/...`, so a REST write can be reproduced without
   the UI and the response compared with the UI's behaviour (2026-10-03, mesh).
5. **Without a controller at hand at all (2026-10-03):** Ubiquiti's firmware catalog
   (`https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-controller&filter=eq~~channel~~release`)
   lists the current Network release per platform with a direct download; the `debian` entry
   is a .deb (147 MB for 10.6.106, build `atag-10.6.106-36011`, i.e. the UCG Ultra's own
   build). `ar x` it, `tar xf data.tar.xz`, and the application is
   `usr/lib/unifi/lib/internal/internal-dependencies.jar`. Unzip on a case-sensitive volume
   (step 2), find the classes by constant-pool string with `grep -rlaF` (the binary flag
   matters, and a `grep` that is really ugrep skips class files silently), then run `jadx`
   (Homebrew, pulls openjdk) on just those `.class` files. This is how the wireless-uplink
   contract was read in an afternoon after three guessed payload shapes had failed: the UAP
   inform processor is `com.ubnt.service.devmgr.iceUMDuewFNFLMOqti`, the VAP/uplink processor
   `com.ubnt.service.devmgr.C.RxFvcetMTlkSFFxK` (names are per build).
   Where a decode function's logic matters, the webpack module registry
   (`window["webpackChunk…"].push([[Symbol()], {}, req => …])`) gives a direct reference to
   the **live** function, which can be called with a sweep of inputs — ground truth, not a guess.

**Logging:** the controller's loggers use flat, hand-picked names (`inform`, `adopt`,
`inform.uap`, `core.lock`, `web.api`), not package paths — see
`com.ubnt.service.system.HCKpgcBFPLu`. Setting `com.ubnt` to DEBUG does nothing for them. A
custom `logback.xml` with explicit `<logger name="inform" level="DEBUG"/>` entries, wired in
via `-Dlogback.configurationFile=`, is needed. Note that most handlers only log on their
*short-circuit* branch, so silence is consistent with everything passing normally.

### Class index

| Class | Role |
|---|---|
| `com.ubnt.service.devmgr.l.MiVjHefaf` | Inform handler / adoption state machine; the provisioning gate; upgrade-offer gate |
| `com.ubnt.service.devmgr.PGOcbDWlbnYQdFW` | `uap`/`uacc` state processor — `radio_table`, `port_table`, `scan_radio_table` ingestion |
| `com.ubnt.service.devmgr.tFhABnrHYJqvjaoEa` | Sibling state processor; power/PoE field copy; `radio_caps` passthrough |
| `com.ubnt.service.devmgr.c.KHUkYjHujLgFBD` | vapInformProcessor — filters `vap_table`, copies `sta_table` attrs |
| `com.ubnt.service.devmgr.DyonYyyYJkiyv` | Per-port `mac_table` processing |
| `com.ubnt.service.devmgr.TtZhv` | Client record writer (wired + disconnect-time wireless archive) |
| `com.ubnt.service.devmgr.HCKpgcBFPLu` → `com.ubnt.g.s.jRsSex` | **Live** (still-connected) client generation display |
| `com.ubnt.service.devmgr.SNMiFVJXxaonBOtqbJ` | Device lookup / minidev cache; replace + clone config services |
| `com.ubnt.service.system.QDcGUYAmLvJwylXw` | Stat archiver (`stat-processor`) — writes `stat_5minutes` `o:"ap"` buckets |
| `com.ubnt.service.system.x.htDMji` | Archiver method that reads `radio_table[].athstats` |
| `com.ubnt.service.aO.hhFgUVZPT` / `aO.bLwwMKkr` | Scan ingestion; the `"PeerScan"` DTO |
| `com.ubnt.service.config.eWivisHeQsnaqDtx` | WLAN/radio config generator (emits `system_cfg`) |
| `com.ubnt.service.config.ubntconf.OXMua` | SAE field emitter |
| `com.ubnt.ace.api.e.VVyiC` | REST per-port VLAN validator |
| `com.ubnt.data.cVbZoFIZsWYaVCquTr` (+ ~90 nested) | The controller's entire internal Device model — one nested class per wire sub-object |
| `com.ubnt.data.cVbZoFIZsWYaVCquTr$QCtdvLKOBb` | vap-stats DTO (**not** the unrelated top-level `com.ubnt.data.QCtdvLKOBb`, a FirewallRule — obfuscated short names collide across packages, always extract by full path) |
| `com.ubnt.data.uuvchZbWVhirD` | Device DTO — `hasFirmwareCapability`, `hasWifiCapability2`, `isSwitch` |
| `com.ubnt.data.dhdeXcHqLRBKMUZk` | Model registry (per-model port count and feature set) |
| `com.ubnt.g.f.e.rYtJfMBbtgWvku` | Radio band enum: `ng`, `na`, `ad`, `6e` |

---

## The inform protocol

### Envelope

Header layout, flags (`0x01` encrypted, `0x02` compressed), zlib-before-encrypt ordering,
AES-128-CBC + PKCS#7, and the default `http://unifi:8080/inform` URL all match openUF's
implementation and fxkr/unifi-protocol-reverse-engineering's published documentation.
`PKT_VERSION` is 1; the GCM AAD is the 40-byte header.

**A response without flag `0x01` is refused.** The controller encrypts its answer to an
encrypted inform, and the AP firmware does the same ("only support encrypted data", BZ2 4.3.28
`mcad`, beside its TNBU header checks). Taking an unflagged packet would let anyone on the
plain-HTTP path push a `setparam` without the key; `parse_packet` raises and the tick waits
its normal interval.

`mgmt_cfg` is a newline-delimited `key=value` **string**, not JSON.

### The GCM provisioning gate

**On 10.4.57 the controller will not provision a device until it has received a genuine
AES-GCM-encrypted inform.** `x_aes_gcm` is set *only* in the decrypt path — `InformServlet`
reads the packet's on-the-wire encryption flag (`header.isGcm()`) and the handler does
`dev.set("x_aes_gcm", true)`. **There is no JSON/payload field that sets it.** The controller
always requests GCM (`use_aes_gcm=true` is written unconditionally into every `mgmt_cfg`), and
once `x_aes_gcm` is set it rejects a GCM→CBC downgrade outright (`"tried to downgrade inform
encryption from AES-GCM to AES-CBC, rejecting"`).

The gate itself, in `MiVjHefaf`:

```java
if (!(dev.isUnsupported() || dev.aesGcmInformEncryptionOnly() || <globalFlag>)) {
    // "dev[..] : mgmt config update before provision"
    resp = new setparam; resp.put("mgmt_cfg", ...);
    dev.set("cfgversion", <fresh random 16-hex>);   // rolls every cycle
    return resp;                                     // returns BEFORE provisioning
}
```

`aesGcmInformEncryptionOnly()` just returns the device doc's `x_aes_gcm` boolean. While it is
false, **every** inform hits this branch, gets a brand-new random `cfgversion`, and returns
early — never reaching `cfgversion`-convergence provisioning, and never reaching the
`wait_for_initial_inform` clear.

**The diagnostic signature** of a device stuck here: adoption reports as completed, informs
decrypt fine, `last_seen` advances — but `cfgversion` is different on *every single* cycle,
`x_aes_gcm` stays false, `provisioned_at` is absent, and the UI shows "Adopting" forever.

Once GCM is sent, all of it resolves in one cycle: `x_aes_gcm` → true, `cfgversion` stabilises,
`provisioned_at` set, `wait_for_initial_inform` cleared, device Connected.

`crypto.lua`'s GCM code works against the `zhaozg/lua-openssl` binding with no changes. The
`openssl(1)` CLI fallback **cannot** do GCM (`enc` refuses AEAD ciphers), so a container
without a real binding silently downgrades to CBC and hangs on this gate.

### Adoption: L2 vs L3

**L3 (inform-only, no SSH).** The controller logs `discovered via L3 inform, skip SSH adoption`
and delivers the new `authkey` directly in the `mgmt_cfg` of the `setparam` sent right after
the Adopt click:

```json
{"_type":"setparam","mgmt_cfg":"capability=notif,notif-assoc-stat\nselfrun_guest_mode=pass\ncfgversion=e07e7991b8c62b47\nled_enabled=true\nstun_url=stun://172.19.0.4:3478/\nmgmt_url=https://172.19.0.4:8443/manage/site/default\nauthkey=ccc32a3bbe40157773294de8ed683627\ninform_url=http://172.19.0.4:8080/inform\nuse_aes_gcm=true\nreport_crash=true\n","server_time_in_utc":"1783841863822"}
```

openUF accepts a hex32 `authkey` from `mgmt_cfg` **only while `st.adopted == false`** — while
unadopted the device is still using the well-known default key, so this exchange carries no
less confidentiality than the rest of L3 provisioning already assumes.

**L2 (broadcast discovery + real SSH).** With `announce.lua` broadcasting, the controller runs
genuine SSH on the Adopt click and executes `syswrapper.sh set-adopt <url> <key>`. The existing
`syswrapper.lua`/`state.lua` shape (`adopted`, `authkey`, `inform_url`, `cfgversion`, `use_gcm`)
is what real SSH adoption expects — confirmed by a real round-trip. The command may be given by its
absolute path (`/usr/bin/syswrapper.sh`) and may carry the device's MAC as a third argument;
the AP firmware reads only the first two (BZ2 4.3.28 `syswrapper.sh`), and `syswrapper.lua`
refuses a MAC that differs from the `mac` in `state.json`.

Two things real hardware does that the validation container had to be taught:

- The controller's SSH client (`sshj`) offers only legacy `ssh-rsa` (SHA-1), matching aging
  UBNT firmware; OpenSSH ≥8.8 excludes it by default. `HostKeyAlgorithms +ssh-rsa` /
  `PubkeyAcceptedAlgorithms +ssh-rsa` are needed in `sshd_config`.
- The controller authenticates as the Ubiquiti factory-default account **`ubnt`/`ubnt`**, not
  the admin-configured Device SSH credentials — correct behavior, because `announce.lua`'s
  `IsDefault` byte (`0x17` in the TLV blob, `make_blob_17_1a`) correctly declares the device
  unadopted.
- The reverse lesson, learned on a device: dropbear checks the account's shell against
  `/etc/shells` **before** the password (`getusershell(3)`), and OpenWrt ships that file with
  `/bin/ash` alone. The forced shell was not listed, so on AP2 (2026-10-25) the gateway's three
  SSH attempts in twelve seconds each ended in `User 'ubnt' has invalid shell, rejected` and the
  mobile app asked for root credentials instead ("advanced adoption"). The container's OpenSSH
  has no such check, which is why the account passed here and never on a device until
  `hook/openuf-bootstrap.sh` registered the shell.

`mgmt_url` is the **web UI deep link** (`https://host:8443/manage/site/default`), *not* an
alias for `inform_url`. Treating them as the same key makes the device overwrite its working
inform endpoint on the first routine post-adopt `setparam` and disappear permanently.

### Discovery requests (UDP 10001)

Ubiquiti's own tools (the UniFi app, WiFiman's Discovery tab, the Device Discovery Tool)
find devices by sending a bare request to UDP 10001 and listing whoever answers. Until
2026-10-25 openUF only broadcast (`02 06`, from an ephemeral port) and never listened, so
those tools saw a host with no model, name or firmware.

**Captured 2026-10-25 from a real UCG Ultra (Network 10.6), requests from an ephemeral port,
broadcast and unicast:**

| Request | Reply |
|---|---|
| `01 00 00 00` | unicast from **UDP 10001** to the asker's port: `01 00 <len16> <TLVs>`, 504 bytes |
| `02 08 00 00` | `02 09 <len16> <TLVs>`, the same 504-byte body; a broadcast request also drew a second 137-byte `02 09` datagram with announce-style TLVs (the UCG has two responders) |
| `01 04 00 06 <mac>` (right or wrong MAC), `02 06 00 00`, `01 00 00 01 00` | nothing |

The UCG body carries `0x01` hw, `0x02` (mac + ip) x4, `0x0a` uptime, `0x0b` hostname,
`0x0c` platform, `0x03` / `0x16` firmware, `0x15`, `0x17`, `0x0e`, `0x0d`, `0x06`, `0x0f`,
and gateway-only `0x2f`, `0x2b` (UUID), `0x32` (port JSON). An AP's reply is its announce TLVs
under the reply header. The two openUF APs answered nothing before the change (no listener).

**Firmware, `/bin/mcad` of UAP BZ2 4.0.15 (firmware-confirmed for 4.0.15 only):**
`init_mcast_sock` binds UDP 10001 at daemon start and joins `233.89.188.1`, with no
adoption check. `mcast_sock_process` drops any datagram whose source port is 10001 (other
devices' announces) and hands version 1 to `handle_version1`: command 0 with length 0
answers every asker, command 4 with length 6 answers only when the MAC equals the AP's own,
the reply header being `01` plus the request's command byte. No version-2 request handler
was found in this old build, so the AP side of `02 08` rests on the UCG capture alone.

**openUF** (`announce.lua`, `reply_for` / `_serve_requests`): listens on IPv4 UDP 10001 for
the daemon's whole life, under `l2_announce`; answers `01 00 00 00` with `01 00`, `02 08 00 00`
with `02 09`, and `01 04 00 06 <own mac>` with `01 04` (the last firmware-only, not seen on a
UCG); ignores everything else, including its own broadcast coming back. One reply per
asker address and request type per 0.5 s, since the reply is ~100x the request.
The UniFi app (WiFiman, captured on the home LAN 2026-10-25) sends `01 00 00 00` and
`02 08 00 00` back to back from one address and port, every second, to the broadcast
address and to `ff02::1`; a limit keyed on the address alone answered only one of the two,
and one AP lost the app's "AP" badge Lab (Docker AP, luasocket
3.0.0): replies arrive from port 10001, the body parses as the announce TLVs, and a second
instance logs `cannot listen on udp/10001` once and keeps broadcasting.

**Multicast (done 2026-10-25).** The UCG sends its own probes to `233.89.188.1:10001` and to
the broadcast address in the same millisecond, and the firmware's `mcad` joins the group, so
the AP joins it too (`ip-add-membership` on the LAN address, re-joined when the address moves,
retried on failure, logged once per distinct error). Probes sent to the group from the Mac
(unconnected socket) were answered by both home APs with `01 00` / `02 09`; the UCG answered
`02 08` over multicast with `02 09` and ignored `01 00 00 00` sent there. A request that
arrives as both a broadcast and a multicast copy is answered once (the limit above).

**This project's VM lab, 2026-10-30.** An openUF AP with `l2_announce = true`, probed from the
lab's LAN: `01 00 00 00` unicast drew `01 00`, `02 08 00 00` unicast and to `233.89.188.1` drew
`02 09`, `01 04 00 06 <its MAC>` drew `01 04`, each unicast from UDP 10001 with a 161-byte
packet; `01 04` naming another MAC, and an unknown request, drew nothing.

**IPv6 (NOT done, gap).** WiFiman also sends both probes to `ff02::1` every second from a
link-local address, and `mcad` opens an IPv6 socket on port 10001 (`init_mcast_sock`, family
`AF_INET6`), so a real AP may answer there. openUF listens on IPv4 only. What we know: a v4
broadcast of the same probe is sent alongside every v6 one, so the app is answered either
way; a v6 probe to `ff02::1` from the Mac drew **no reply from any device on the LAN, the UCG
included** (2026-10-25), so we have no reply format to copy; and LuaSocket 3.0 has no
scope-id handling for sending to a `fe80::` asker. Revisit if a client shows up that probes
IPv6 only, and capture a UAP's v6 reply before writing one.

### Response `_type`s

The complete set, per `InformServlet`: `noop`, `setparam`, `cmd`, `upgrade`, `reboot`,
`setdefault`. There is no export/backup/dump command.

| `_type` | Shape | Notes |
|---|---|---|
| `noop` | `{"_type":"noop","interval":…,"live_update":false,"include_blocks":[],"server_time_in_utc":"…"}` | Steady state. `interval` is the cadence the controller wants -- `10` normally, but **not constant**: on 2026-09-15 the UCG Ultra answered with 16–19 for two stretches of a minute or two while the RF stats page was open in the UI, then went back to 10. Honoured since that day (clamped to 5–300 s, back to the device's 10 s when absent) -- openUF used to discard it, so its informs would have kept arriving every 10 s against the controller's wish. `live_update` has only ever been observed `false` (row 17 in REVERSE-ENGINEERING.md's backlog); `include_blocks` see block-sta below. |
| `setparam` | `{"_type":"setparam","mgmt_cfg":"…","system_cfg":"…","server_time_in_utc":"…"}` | Both configs are flat `key=value` blobs. See [system_cfg](#system_cfg-the-real-config-channel). |
| `cmd` | `{"_type":"cmd","cmd":"…","mac":"…","device_id":"…",…}` | See command table below. |
| `upgrade` | `{"_type":"upgrade","version":"6.8.2.15592","md5sum":"…","url":"http://fw-download.ubnt.com/…"}` | Fire-and-forget, sent exactly once; no retry, no confirmation expected. |
| `reboot` | `{"_type":"reboot","reboot_type":"soft",…}` | The top-level form is the real one; `{"_type":"cmd","cmd":"restart"}` is not the path this action takes. `reboot_type` is unused by openUF. |
| `setdefault` | — | Handler exists but has never been observed dispatched live; see [open questions](#open-questions). |

**After executing a `cmd`, the device must send another inform immediately** (documented by
fxkr and confirmed live: the controller's next `noop` lands in the same second).

Confirmed `cmd` strings:

| `cmd` | Trigger | Payload |
|---|---|---|
| `set-locate` | Locate button | `{"cmd":"set-locate","device_id":…}` |
| `block-sta` | Block client | `{"cmd":"block-sta","mac":"…"}` |
| `unblock-sta` | Unblock client | `{"cmd":"unblock-sta","mac":"…"}` |
| `spectrum-scan` | — | Handler implemented; no UI affordance found in 10.4.57 to fire it. |

Block/unblock are **one-shot commands**, not persistent per-inform state. The candidate
persistent field `include_blocks` (present on every response) was ruled out — it stays `[]`
even while a client is genuinely blocked. The device is expected to remember the block itself,
which is why `state.json` carries `blocked_stas` and `firewall.reconcile()` runs at startup.

---

## `system_cfg`: the real config channel

**A real controller never sends `resp.vap_table` / `radio_table` / `network_table` as JSON.**
All device configuration — WiFi, radios, IP settings, per-port VLAN, minimum RSSI — arrives
inside the flat, OpenWrt/hostapd-style `system_cfg` key=value blob on a `setparam`.
`inform.lua`'s `M._parse_wifi_system_cfg()` translates it into the `{radio_table, vap_table}`
shape `ucihelper.apply_config()` expects.

Conventions used throughout: booleans are `"enabled"`/`"disabled"` (sometimes `"true"`/`"1"`);
an **absent block means disabled** — there is generally no explicit `status=false`.

A line splits at its **first** `=`: keys never contain one, values may (a passphrase
`pass=word`, an SSID `a=b`). Checked on the lab VMs (2026-10-31, controller 10.6): a WLAN
with `a=b` in both the SSID and the passphrase was pushed, hostapd got both values as
sent, and a client joined.

### `aaa.<n>.*` — per-SSID security

| Key | Meaning |
|---|---|
| `ssid` | SSID |
| `id` | The wlanconf Mongo ObjectId. **Must be echoed back** — see [`vap_table`](#vap_table-entry). |
| `wpa` | WPA protocol version (`2`/`3`). Stays `2` even for a WPA2/WPA3 transition WLAN. |
| `wpa.psk` | Passphrase |
| `wpa.key.<k>.mgmt` | AKM set (`WPA-PSK`, `SAE`, …). **This**, not `wpa`, is what distinguishes SAE. |
| `pmf.status` / `pmf.mode` | 802.11w. `mode` is `0`\|`1`\|`2` (disabled/optional/required), mapping 1:1 onto hostapd's `ieee80211w`. On this madwifi model, **WPA2/WPA3 transition intent is carried entirely by these fields** — dropping them silently collapses mixed mode to plain WPA2. |
| `pmf.cipher` | `AES-128-CMAC`. Not translated — hostapd's default BIP group-mgmt cipher already is this. |
| `ft.status` | Fast Roaming (802.11r) for the WLAN. No `mobility_domain`/`r0kh`/`r1kh` on the wire — the controller computes and syncs those internally across the site; `ucihelper.derive_mobility_domain()` fills the gap locally. |
| `wpa3.ft.status` | FT for the **SAE akm alone**, a separate toggle from `ft.status`, from the wlanconf's `isWpa3SaeFastRoamingEnabled()`. Emitted unconditionally on any SAE push (the first key `OXMua` writes) and absent otherwise. OpenWrt has one `ieee80211r` switch feeding hostapd's `key_mgmt`, and on `sae-mixed` it yields FT-PSK **and** FT-SAE together, so openUF enables FT if *either* toggle asks and logs the disagreement. |
| `bss_transition` | 802.11v. Present on every band's block, flips independently of Fast Roaming. |
| `br.devname` | `br0` untagged, **`br0.<vlan>`** when the WLAN is assigned to a VLAN network — CONFIRMED live 2026-08-01, the first capture of a tagged WLAN on real hardware. This suffix is the *only* per-WLAN VLAN signal; there is no `network_table`/`networkconf_id` join anywhere in the wire format. |
| `sae.anti_clogging` / `sae.sync` | Plain integers, emitted only when > 0 **and** the WLAN is genuinely WPA3 (see below). |
| `driver` | `madwifi` — confirms the controller is talking to this model as madwifi-era firmware, which explains several value encodings below. |

A VLAN assignment also produces companion `vlan.*`, `bridge.*` and `netconf.*` blocks.
**The `bridge.*` block is a specification, not decoration** — an earlier revision of this
document said openUF "does not need to reproduce these", which cost a live debugging
session. Captured 2026-08-01 when a WLAN was put on VLAN 20:

```
bridge.1.devname=br0            bridge.2.devname=br0.20
bridge.1.port.1.devname=eth0    bridge.2.port.1.devname=ath2      ← the vap
bridge.1.port.2.devname=ath0    bridge.2.port.2.devname=eth0.20   ← the tagged uplink
bridge.1.port.3.devname=ath1    bridge.2.stp.status=disabled
```

That second bridge is exactly the L2 a tagged SSID needs, and openUF must build the
equivalent (`br-openuf<vlan>` holding `<cpueth>.<vlan>`, with the VAP joined to it).
Skipping it yields a VAP and an uplink sub-device that are both up and completely
unconnected: the client associates and gets no DHCP, no gateway, nothing, while UCI,
netifd and hostapd all look correct.

`netconf.*` blocks are per-device-interface and stay anchored: the AP's own IP settings
remained at `netconf.1` (`devname=br0`) with the VLAN's entries taking later indices, so
inform.lua's `^netconf%.1%.` anchor is safe against a VLAN being added.

**Provisioning is not driven by `cfgversion` alone.** A device reporting a stale or bogus
version sometimes gets an immediate full push and sometimes only `noop`s, indefinitely,
even across restarts and fresh random values. An empty string is ignored outright. The
reliable trigger is a real config change in the controller — and note that a UI form
failing validation (e.g. switching a 2.4-GHz-only WLAN to Manual, where Band Steering
demands two bands) saves nothing and pushes nothing, with no error surfaced beyond the
form itself.

**SAE gating.** `com.ubnt.service.config.ubntconf.OXMua`'s emitter is capability-gate-free:

```
n = wlan.getInt("sae_anti_clogging", -1); if (n > 0) emit "aaa.<idx>.sae.anti_clogging" = n
s = wlan.getInt("sae_sync", -1);          if (s > 0) emit "aaa.<idx>.sae.sync" = s
```

but is only *called* when `wlan.isWpa3() || wlan.isOn6GHzBand()`. `isWpa3()` reads the DB flag
`wpa3_support`, which the **"WPA2/WPA3" dropdown does set** — read live from this site's
wlanconf: `wpa3_support: true`, `wpa3_transition: true`, `pmf_mode: optional`. (An earlier
revision of this document claimed the mixed choice left `wpa3_support` false and that a mixed
WLAN therefore never emits these keys. Wrong: the WLAN-side gate passes; what suppresses the
whole SAE block is the *per-device radio* capability check described in the WPA3 section.)
openUF used to map these to hostapd's `sae_anti_clogging_threshold` / `sae_sync`. **It no
longer does, and no longer parses them**: both are real hostapd keys but neither is a
wifi-iface UCI option — upstream checked the wifi-iface schema, `/usr/share/ucode/wifi/`
and `hostapd.sh`'s `config_add_*` lists on an Archer C5 and an AX3000T (both 25.12.5) and
found neither name anywhere, so the writes were stored in UCI and dropped in silence. See
feature 27 in the matrix.

### `wireless.<n>.*` — per-SSID radio binding and behavior

| Key | Meaning |
|---|---|
| `ssid`, `parent` | SSID, and the owning radio (`radio0`/`radio1`) |
| `dtim_period` | Plain integer, **always present** regardless of the WLAN's Auto/Custom DTIM toggle. There is no `dtim_mode`/`dtim_ng`/`dtim_na` key on the wire — go-unifi's band-split shape describes the REST API, not this protocol. |
| `no2ghz_oui` | **Band Steering's real wire representation.** Not a per-device `mgmt_cfg` field. Toggling Band Steering changes only this key, and only on the 2.4 GHz entry (the 5 GHz entry stays `disabled` — nothing to toggle there). A madwifi/QCA convention: omitting the AP's OUI from 2.4 GHz beacons nudges dual-band clients toward 5 GHz. Mainline mac80211/hostapd has no equivalent, so openUF derives a single device-wide `steering_active` boolean (true if *any* vap has it) and drives `usteer`, which is itself a device-wide daemon. |
| `mcast.enhance` | Multicast Enhancement / Multicast-to-Unicast. `0`\|`1`. |
| `minrate_data`, `beacon_rate`, `mgmt_rate`, `minrate_cck_rates.status`, `minrate_below_disable`, `pureg` | **Minimum Data Rate Control.** `minrate_data` is the floor in kb/s; `beacon_rate`/`mgmt_rate` simply mirror it. `minrate_cck_rates.status` and `pureg` are derived consequences on 2.4 GHz (a 12 Mbps floor is OFDM, so CCK goes `false` and `pureg` goes `1`). `minrate_below_disable` is the separate "advertising rates" sub-toggle. Emitted per band and **absent entirely** when that band's control is off — not band-gated, which an early reading of a 2.4-GHz-only capture suggested. |
| `bcfilt.status`, `bcfilt.<k>.mac`, `bcfilt.<k>.status` | **Multicast and Broadcast Blocker** (REST `bc_filter_enabled`/`bc_filter_list`). `status` appears whenever the control is on, including with an empty allow-list; the indexed entries only once it is non-empty. `<k>` is 1-based and does **not** follow the REST list's order — adding a second MAC renumbered the first — so the index means nothing beyond grouping. Emitted on both band entries. |
| `l2_isolation` | **Client Isolation.** `enabled`\|`disabled`, always present, emitted on both band entries. → OpenWrt `isolate` (hostapd `ap_isolate`). |
| `devname` | The Ubiquiti-side netdev for this vap (`ath0`…`ath3`). **The join key for the top-level [`macacl.*`](#macacl--mac-address-filter) section**, whose own indices do not line up with `<n>`. Not a name that exists on OpenWrt — enforcement resolves the real netdev via `ubus`. |
| `mac_acl.status`, `mac_acl.policy` | ⚠️ **Decoys — not the MAC Address Filter.** Sit at `enabled`/`deny` with the control off and do not move when it is toggled; the real feature is the top-level [`macacl.*`](#macacl--mac-address-filter) section. |
| `hide_ssid` | **Hide WiFi Name.** `true`\|`false` — note the vocabulary, not the `enabled`/`disabled` most keys here use. Always present, emitted on both band entries, and duplicated verbatim as `aaa.<n>.hide_ssid`. → OpenWrt `hidden` (hostapd `ignore_broadcast_ssid`). |
| `mcastrate` | Multicast rate. Observed only ever as `auto` — no WLAN-level control in 10.4.57's UI moves it, and OpenWrt's `mcast_rate` is adhoc/mesh-only anyway, so openUF does not map it. |
| `advertise_ap_name` | "Show Access Point Name in Beacon". **Only emitted when the device declares `wifi_caps2` bit `0x40`** — see [capability bitmasks](#capability-bitmasks). |
| `iot`, `qbssload` | **"Force WiFi 4 Mode"** (IoT Optimization; REST field `enhanced_iot`). Absent entirely when off; appear together as `iot=enabled` + `qbssload=disabled` on the WLAN's 2.4 GHz entry when on. The parent radio is *not* touched — `radio.<n>.ieee_mode` keeps the site's configured width — so this is a per-BSS flag only. `qbssload` is its one distinct on-air effect (suppress the QBSS Load IE); the rest of the mode arrives as ordinary keys: the 5 GHz vap is dropped outright, security pinned to WPA2, and `bss_transition`/`proxy_arp`/`no2ghz_oui`/PMF/`advertise_ap_name` all forced off. |

### `radio.<n>.*` — per-radio config

`phyname` (`radio0`), `channel` (integer or the literal `auto`), `txpower` (integer or `auto`),
`txpower_mode` (`auto`/`custom`/`disabled`), `status`, `ieee_mode`. When no radio is
provisionable the blob contains the literal comment `# no wlan provisioned as no radio found`
and the **unindexed** `radio.status=disabled` — see
[`radio_table` must not be empty](#radio_table-entry).

Do not confuse that unindexed key with the **indexed** `radio.<n>.status`, which is the real
per-radio enable/disable control — see
[`radio.<n>.status` — per-radio disable](#radionstatus--per-radio-disable).

`ieee_mode` is **the wire's only channel-width signal**: a compound `11` + band (`ng`/`na`) +
PHY and width token — `11nght20`, `11nght40`, `11naht40`, `11acvht80`, `11axhe80`. Changing
Devices → [AP] → Settings → Radios → "2.4 GHz Channel Width" from 20 to 40 changes exactly this
key (alongside `cwm.mode` 0→1, a redundant channel-width-management flag carrying no extra
information). openUF maps it to UCI `wifi-device.htmode`; on OpenWrt/mac80211 that option is the
PHY ceiling, so `HT20`/`HT40` also *is* "802.11n only". There is no separate 11n/11ac/11ax mode
key — an earlier version of openUF expected one, never populated it, and so silently never
applied channel width at all.

### `stamgr.<n>.*` — per-radio Station Manager (Minimum RSSI)

Indexed the same as `radio.<n>`, **not** tied to any SSID. This is a device/radio-level
setting (Devices → [AP] → Radios), not a WLAN one — distinct from the WLAN Advanced panel's
"Roaming Assistant", which is a different feature with its own REST fields
(`roamingAssistantNaEnabled`/`Rssi`) that never appear on the wire.

```
stamgr.1.status=true
stamgr.1.radio=ng
stamgr.1.minrssi.status=true
stamgr.1.minrssi.rssi=15
stamgr.1.loadbalance.status=false
```

**The threshold is not plain dBm.** UI `-80 dBm` → wire `15`; UI `-85 dBm` → wire `10` —
`wire = dbm + 95` exactly, a fixed madwifi-era encoding (matching `aaa.1.driver=madwifi`).
openUF stores the raw wire value in UCI and converts back with the same constant. **It is
NOT "dB above the live noise floor"** — an earlier version added `sysinfo.radio_stats()`'s
noise reading instead, which the controller cannot possibly have encoded against (it never
learns a radio's noise floor) and which only looked right on a radio whose floor happens to
be -95: an ath9k 2.4 GHz radio reads -107 and turned a requested -80 into -92, mt76 radios
read -90/-92 and turned it into -75. Corrected 2026-09-06, adopting upstream's fix.

`loadbalance.status` is a sibling sub-feature sharing the block; unimplemented.

**Enforcement semantics** (from web research — this is client-facing AP behavior, not a wire
format): Minimum RSSI is a **roaming aid, not a block**. The AP sends a single deauth frame to
a below-threshold client; there is no persistent drop rule and the client may reassociate
immediately, even to the same AP. This is materially different from `block-sta`, so it has its
own helper, `ucihelper.kick_station()`, rather than reusing `firewall.deauth()`.

### `macacl.*` — MAC Address Filter

A **top-level section keyed by devname**, not by the `wireless.<n>` index. Confirmed live
2026-07-18 by enabling the control on one WLAN with a single allow-listed MAC:

```
macacl.status=enabled                       # global gate
macacl.1.devname=ath0                       # join key -> wireless.<n>.devname
macacl.1.status=enabled
macacl.1.acl.status=enabled
macacl.1.acl.policy=allow                   # allow | deny  (UI "Filter Type")
macacl.1.acl.1.mac=02:11:22:33:44:55
macacl.1.acl.1.status=enabled
macacl.1.acl.1.type=user
macacl.2.devname=ath2                       # the same WLAN's 5 GHz vap
```

Only the vaps belonging to the filtered WLAN get a block, and they are numbered from 1
independently of `wireless.<n>` — in this capture `macacl.1`/`macacl.2` correspond to
`wireless.1`/`wireless.3`. **A join on `devname` is mandatory**; an index-based reading
misfiles the filter onto the wrong WLAN.

Like `bcfilt.<k>`, the `acl.<k>` index carries no meaning beyond grouping, so openUF sorts
the list. Maps onto OpenWrt's `macfilter` (`disable`\|`allow`\|`deny`) + `maclist`, whose
policy vocabulary lines up 1:1 with the controller's.

⚠️ **Two decoys excluded by the same diff.** `wireless.<n>.mac_acl.status` /
`wireless.<n>.mac_acl.policy` sit at `enabled`/`deny` with the control **off** and did not
move when it was toggled — the same shape as `radio.<n>.bcmc_l2_filter.status` was for the
broadcast blocker. `aaa.<n>.radius.macacl.status` is the unrelated RADIUS MAC Authentication
control. Do not re-investigate these.

### `qos.*` — WiFi Speed Limit

Another **top-level section keyed by devname**. Confirmed live 2026-07-18 by creating a
speed-limit profile (33 Mbps down / 17 Mbps up) and assigning it to one WLAN. Note the
per-WLAN toggle does nothing until at least one profile exists in the site settings — with no
profile there is nothing to select and nothing reaches the wire.

```
qos.status=enabled
qos.mode=1
qos.if.1.devname=eth0 / .devspeed=1000 / .type=uplink   # interface inventory
qos.if.2.devname=ath0 / .devspeed=570
qos.vap.1.devname=ath0                                  # join key
qos.vap.1.dwnlink.maxspeed=33000                        # kbps  (UI Mbps x 1000)
qos.vap.1.dwnlink.minspeed=33000
qos.vap.1.uplink.1.devname=eth0
qos.vap.1.uplink.1.maxspeed=17000                       # kbps
qos.ebt.1.cmd=PREROUTING --in-interface ath0 -j mark --mark-or 0x1000 ...
```

| Detail | |
|---|---|
| Units | **kbps**. The UI's Mbps value × 1000. |
| Discriminator | **Presence of `maxspeed`.** Not `qos.status` (global), and *not the block itself*: an unlimited vap still gets a `qos.vap.<m>` block carrying only `minspeed`, set to that radio's raw `devspeed` (570 on 2.4 GHz, 2400 on 5 GHz here). Treating the block as "limited" would cap every WLAN at its own PHY rate. |
| Scope | A **per-VAP aggregate** cap, not per-client — there is no per-station structure on the wire. All clients on the SSID share the ceiling, which is what makes one qdisc per VAP sufficient. |
| `qos.ebt.<n>.cmd` | Literal ebtables fragments the stock firmware would replay to fwmark each VAP. openUF implements the intent with `tc` instead (`shaper.lua`), since ebtables is not a given on OpenWrt while `tc` ships in the base iproute2. |

### `netconf.*` / `dhcpc.*` / `route.*` / `resolv.*` — IP settings

```
netconf.1.devname=br0
netconf.1.ip=172.19.0.50
netconf.1.netmask=255.255.255.0
netconf.1.autoip.status=disabled
route.1.gateway=172.19.0.1
resolv.nameserver.1.ip=192.0.2.1
resolv.host.1.name=<device name>      # also the source for wps_device_name
dhcpc.status=enabled
dhcpc.1.status / dhcpc.1.devname      # the actual DHCP-vs-static signal
```

**A fresh device's very first post-adopt `setparam` always carries `dhcpc.1.status=enabled`** —
a brand-new device is in DHCP by definition. Acting on that unconditionally (flush + `udhcpc`)
strands the interface if no DHCP server can grant a fresh lease. `netconfig.apply_dhcp` is
therefore only called when `st.ip_mode == "static"` already, i.e. when genuinely reverting our
own prior static push; first contact and steady-state reaffirmations are a no-op, matching how
real hardware's continuously-running DHCP client needs no manual re-invocation.

### `switch.*` — per-port VLAN

Appears only once the device declares switch capability. Fully mapped live 2026-07-19 by
diffing `system_cfg` across five states. An earlier version of this section claimed the
controller "manages VLAN membership server-side and only needs the device to *accept* the
push" — **that was wrong**, and it is why README claimed the feature worked while no code
existed. The device is sent a complete, actionable VLAN table.

**Baseline (B0) — Port VLAN off**, the state every device sits in until the control is
enabled:

```
switch.status=disabled
switch.vlan.status=disabled
switch.dot1x.status=disabled
switch.jumboframes=disabled
switch.port.1.name=PoE Out + Data   / .opmode=switch
switch.port.2.name=Data             / .opmode=switch     # ... through port 5
```

The `switch.port.N` entries are always present — one per the **model registry's** port count
(5 for U6IW), not per whatever `port_table` openUF reports. They carry only `name`/`opmode`
and never move; they are inventory, not control.

**The discriminator is `switch.status` / `switch.vlan.status` flipping to `enabled`.** Both
sit at `disabled` in B0, so — unlike `wireless.<n>.mac_acl.*` or `radio.<n>.bcmc_l2_filter.status`
— these are genuine gates, not decoys. They are driven by a **device-level** checkbox
(Devices → [AP] → Settings → IP Settings → **Port VLAN**), not by anything per-port, and until
it is ticked the whole per-port VLAN UI is greyed out.

**C1 — Port VLAN enabled, no port override.** The site's VLANs appear as a table:

```
switch.status=enabled
switch.vlan.status=enabled
switch.vlan.1.id=1      / .mode=untagged / .status=enabled
switch.vlan.2.id=20     / .mode=tagged   / .status=enabled
```

`switch.vlan.<m>` is a slot number; `.id` is the real VLAN id. `.mode` here is the VLAN's
device-wide default.

**C2 — port 2's Native VLAN set to the VLAN-20 network.** Three keys are added:

```
switch.port.2.pvid=20              # the port's untagged/native VLAN
switch.vlan.1.port.2.mode=tagged   # VLAN 1 is tagged on port 2
switch.vlan.2.port.2.mode=untagged # VLAN 20 is untagged on port 2
```

So membership is expressed **twice, redundantly**: once per-port (`pvid`) and once as a
per-VLAN-per-port matrix (`switch.vlan.<m>.port.<n>.mode`). The matrix is the authoritative
one — it is what carries tagging, and `pvid` is derivable from it (the VLAN whose mode is
`untagged`).

**`switch.port.<n>` joins directly to `port_table[].port_idx`** — no devname indirection,
unlike `macacl.*`/`qos.vap.*`. Confirmed by the Port Manager UI listing exactly the two ports
openUF reports at the time (not the registry's five) and the override landing on wire index
2, openUF's port_idx 2. This join is why `port_idx` is pinned to a physical socket in the
modelmaps and must not be renumbered: the controller stores a port's settings against it.

**C3 — Tagged VLAN Management → Block All.** One key changes:

```
switch.vlan.1.port.2.mode=exclude   # was "tagged"
```

giving the full mode vocabulary: **`untagged` | `tagged` | `exclude`**, which maps 1:1 onto
swconfig's untagged/tagged/absent port membership.

**C4 — port reverted to default.** The three per-port keys from C2 simply **disappear**, and
the blob returns byte-identical to C1. Teardown is therefore expressible: absence means
default (untagged on the management VLAN, all others tagged), the same "absent block means
disabled" convention used everywhere else in this format.

### `cron.*`, `ntpclient.*`, `system.timezone` — controller-managed system settings

Confirmed live 2026-09-15 on AP2 (JIDU6101, UCG Ultra 10.6.101), the first full push after
the unhandled ledger went in — every one of these had been in every capture and read by
nothing:

```
system.timezone=IST-5:30            locale.timezone=IST-5:30       # the same POSIX TZ string twice
ntpclient.status=enabled
ntpclient.1.status=enabled          ntpclient.1.server=0.ubnt.pool.ntp.org   # ... .4 = 3.ubnt.pool.ntp.org
cron.status=enabled
cron.1.status=enabled
cron.1.user=<the site's Device SSH Authentication username>
cron.1.job.1.status=enabled
cron.1.job.1.schedule=0 4 * * *
cron.1.job.1.cmd=syswrapper.sh 11k-scan
```

The cron job is the controller scheduling a **nightly 04:00 (device local time) neighbour
scan on every AP**, through the AP's own cron and its `syswrapper.sh` — the "automated RRM
scans" Ubiquiti's Channel AI describes. openUF's `sysconf.lua` writes the jobs into a marked
block of `/etc/crontabs/root` (only commands this build provides; the pushed user is ignored
and jobs run as root), and `syswrapper.sh 11k-scan` asks the running daemon to sweep every
radio on its next heartbeat. The timezone goes to UCI `system.@system[0].timezone` and the
servers to `system.ntp.server`, each stamping the value it replaced; `ntpclient.status=disabled`
restores the list. Device-side effect verified on AP2 the same day (see the feature matrix).

### `ebtables.*` — L2 hardening rules

Same push, ten literal ebtables fragments the stock firmware replays:

```
ebtables.status=enabled             ebtables.add_vlan.status=disabled
ebtables.1.cmd=-t nat -A PREROUTING  --in-interface  ath0 -d BGA -j DROP    # and ath1, ath2
ebtables.2.cmd=-t nat -A POSTROUTING --out-interface ath0 -d BGA -j DROP    # and ath1, ath2
ebtables.7.cmd=-t broute -A BROUTING -i ath1 -p 802_1Q -j DROP              # the VLAN-tagged SSID's VAP
ebtables.8.cmd=-t broute -A BROUTING --vlan-id 10 -p 802_1Q -j DROP         # bridge-wide
```

`BGA` is ebtables' alias for the Bridge Group Address `01:80:c2:00:00:00` (STP BPDUs); with
STP off the Linux bridge *forwards* frames to it, so without these a wireless client can inject
BPDUs into the wired LAN, and the `802_1Q` pair says no client may inject VLAN-tagged frames.
`l2guard.lua` re-expresses them as nft `bridge openuf_l2guard` on the **AP VAP netdevs only**:
the bridge-wide `--vlan-id` rule is safe on the stock firmware only because its tagged uplink
is an 8021q sub-device (`eth0.10`) that takes tagged frames before the bridge; on a DSA board
openUF's tagged uplink is `br-lan.10`, on the bridge, and the same rule would drop the IoT
WLAN's own uplink traffic. `qos.ebt.*` (WiFi Speed Limit) is the same replay mechanism.

### `radio.<n>.status` — per-radio disable

Also settled 2026-07-19, in the same session. Setting a radio's **Transmit Power → Disabled**
(Devices → [AP] → Settings → Radios) moves four keys:

```
radio.1.status=disabled            # was enabled
radio.1.txpower_mode=disabled      # was auto
radio.1.virtual.1.status=disabled  # was enabled
wireless.1.status=disabled         # and every other vap on that radio
wireless.2.status=disabled
```

This corrects an earlier reading of this document, which recorded `radio.status=disabled`
only as part of the radio-less `# no wlan provisioned as no radio found` case and concluded
the key carried no per-radio signal. **The indexed `radio.<n>.status` is a real control.**

openUF maps `radio.<n>.status` onto UCI `wifi-device.disabled` and `wireless.<n>.status` onto
each `wifi-iface.disabled`, and reports both back out (`radio_table[].disabled` /
`vap_table[].disabled` already read them off UCI), so the controller sees its own push
reflected. Two details worth keeping:

- The read is **tri-state**. An absent `status` key writes nothing, so a blob that never
  carries it cannot re-enable a radio or SSID the operator disabled by hand in
  `/etc/config/wireless`; only an explicit `enabled`/`disabled` writes. An explicit
  `enabled` must clear the flag, or a radio could never be switched back on.
- Only the **indexed** key is read. The unindexed `radio.status=disabled` in the radio-less
  blob would otherwise take every radio on the device down — the tokenizer's
  `radio.<n>.<key>` shape cannot match a two-component key, so this is structural, but it is
  pinned by a test.

A disabled WLAN is still provisioned, just with `disabled=1`, so its configuration survives
a re-enable.

---

### `connectivity.*`: SSIDs on uplink loss (upstream 2026-10-10; implemented here 2026-10-25)

**Question.** A UniFi AP that loses its uplink takes its SSIDs down, so clients roam to an
AP that still reaches the gateway. openUF keeps beaconing. Is that a gap?

**What the firmware does** (firmware-confirmed for 3.9.27 to 4.0.15: `ubntbox`, `mcad`,
`syswrapper.sh`):
- `ubntbox` starts `uplink-monitor` (part of `mcad`) only when `system_cfg` says
  `connectivity.status=enabled` and `wireless.status=enabled`. Otherwise it starts nothing,
  or on some boards `uplink-monitor -p`. In `-p` mode `update()` returns before it calls
  `syswrapper.sh state_reload`, so the VAPs are never touched.
- When it is enabled:
  - **Target:** the gateway, or the host in `connectivity.uplink`.
  - **Interval:** every 15 s with a wired uplink (5 s in `init`, 10 s in `up`).
  - **Probe:** `arping -q -c 1 -I br0` twice if the target is in the subnet, otherwise
    `ping -q -c 1 -I br0 -W 2` twice.
  - **Shortcuts:** the target counts as alive without a probe if its MAC was seen in the
    bridge FDB less than 15 s ago. A failed probe still counts as up if that FDB age is
    under 90 s.
  - **Going down:** losing carrier is "down" at once. Any other "down" needs 5 verdicts
    in a row (about 60 s).
  - **Recovery:** immediate.
- "down" leads to `configure_vap up down down`, which takes every user and guest VAP down.
  `/var/run/system.isolated_wlan_on`, which would have kept them up, has no writer in these
  builds.
- After 1800 s isolated while in selfrun, the AP runs `soft-restart`.
- **Inform:** the firmware sends `isolated`. Current controllers (10.4.57 and 10.6) ignore
  it and set the device's `isolated` from the inform's top-level `uplink == "down"`, which
  defaults to `"eth0"`.

**What the controller sends.** The `connectivity` block (CFR, `eWivisHeQsnaqDtx`):
- `connectivity.status=enabled` only when `device.supportVwire()` (`wifi_caps` bit `0x1`)
  **and** the site's `connectivity` setting is `enabled`.
- With it come `connectivity.uplink=<host>` (`uplink_type=custom`) or
  `connectivity.uplink_gateway=<ip>`, plus `uplink_eth`/`uplink_wds`/`uplink_bridge`.
- In every other case: `connectivity.status=disabled`.

**This tree (2026-10-25).** Since the mesh work, openUF claims `wifi_caps` `0x1` on every board,
so a site with the monitor on now pushes `connectivity.status=enabled`. `uplinkmon.lua`
implements the firmware's behaviour (see README "Uplink Connectivity Monitor"):
- one verdict per heartbeat, from two pings to the gateway or `connectivity.uplink`;
- 5 failed verdicts take the user and guest VAPs down;
- the first answer brings them back.

The carrier-loss shortcut and the FDB shortcut are not copied. Unit-tested only.

On the APs (read-only, 2026-10-10): OpenWrt 25.12 ships no `arping`. `bridge -s fdb` shows a
`used <tx>/<rx>` age for the gateway's MAC, which would serve as the FDB shortcut.

### Guest portal (Hotspot): what the controller pushes and expects (upstream; adopted here 2026-10-25)

Captured in the 10.4.57 lab on 2026-10-09 (C0 discovery). Setup: `guest_access.portal_enabled`
on with `auth: none`, then `PUT rest/wlanconf/<id> {"is_guest":true}` on the lab WLAN. The
`system_cfg` diff across that toggle (310 → 390 lines) is the whole of what the device is
told. `<ctl>` is the controller's IP, and `ath0`/`ath1` are the guest WLAN's two VAPs.

| Key | Off → on | Meaning |
|---|---|---|
| `wireless.<n>.is_guest`, `aaa.<n>.is_guest` | `false` → `true` | the VAP is a guest VAP |
| `wireless.<n>.usage` | `user` → `guest` | same, the field the stats side keys on |
| `wireless.<n>.l2_isolation` | `disabled` → `enabled` | forced client isolation (already mapped to `isolate`) |
| `redirector.status`, `redirector.https.status` | `disabled` → `enabled` | the AP runs the redirect target |
| `redirector.url`, `redirector.url_https` | (new) `http://<ctl>:8880/guest/s/default/` | where an unauthorized guest is sent |
| `redirector.redirect_pattern` | (new) `http://<ctl>:8882` | |
| `dnsmasq.status`, `dnsmasq.1.devname=br0`, `dnsmasq.1.status` | `disabled` → `enabled` | a local DNS answerer for unauthorized guests |
| `iptables.status` + `iptables.1..3.cmd` | `disabled` → 3 rules | `-t nat -A PREROUTING -p tcp -m mark --mark 0x40000000/0xc0000000 -j REDIRECT --to-ports 80` (0x80000000 → 443; udp 53 → 53) |
| `ebtables.5..51.cmd` | (new) 47 rules | the enforcement itself, below |
| `ebtables.52..53.cmd` | (new) | `-t broute -A BROUTING -i ath<n> -p 802_1Q -j DROP` |
| `qos.status` + `qos.ebt.*`, `qos.if.*`, `qos.vap.*`, `qos.mode=1` | `disabled` → enabled | per-VAP marks (`0x1000`, `0x2000`) and interface speeds: the shaping frame `rate-update` plugs into |

The ebtables ruleset, condensed. These are all `-t nat` rules; `ath<n>` stands for each guest VAP:
- `-N GUESTIN -P DROP`, `-N GUESTOUT -P ACCEPT`; `PREROUTING --in-interface ath<n> -j GUESTIN`,
  `POSTROUTING --out-interface ath<n> -j GUESTOUT`.
- GUESTIN accepts EAPOL (`--proto 0x888e`), DHCP requests (broadcast, udp 68→67) and ARP.
  It also accepts tcp 8880/8843 to `<ctl>` (the portal) and tcp 8881 to `<ctl>`. Its first
  rule (`-I`) sends tcp 8882 to `<ctl>` to `REDIRECT_HTTP`.
- DNS (udp/tcp 53) goes to `GUEST_DNS` (`-P DROP`). That chain jumps to `AUTHORIZED_GUESTS`,
  then to `REDIRECT_DNS` (mark `0x40000000`, `-j redirect`).
- GUESTIN drops IPv6 (`0x86dd`), other broadcast, multicast `224.0.0.0/4`, and the three
  `restricted_subnet_*` from `guest_access` (`192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`).
- tcp 443 goes to `CAPTIVE_PORTAL` (`-P RETURN`, empty).
- `-N AUTHORIZED_GUESTS -P RETURN` is **pushed empty**. `GUESTIN -p 0x800 --pkttype-type
  otherhost -j AUTHORIZED_GUESTS` comes before `tcp 80 -j REDIRECT_HTTP` / `tcp 443 -j
  REDIRECT_HTTPS` (marks `0x40000000`/`0x80000000`, `-j redirect`). The device fills the
  chain itself from `authorize-guest`. Whatever leaves GUESTIN unmatched hits its DROP policy.
- GUESTOUT accepts DHCP replies and ARP, and drops IPv6, other broadcast and multicast.

So the controller ships its whole enforcement as ebtables + iptables. The device's own
parts are the `AUTHORIZED_GUESTS` membership and a local HTTP/DNS answerer for the
redirect marks. Until C2, openUF applied none of it. `l2guard` accepted only the BGA rule
shapes and logged `l2guard: unrecognised ebtables rule shape, not applied` 47 times per push.

**Station `authorized` is the portal state, and the controller reconciles it every inform.**
`devmgr/dhdeXcHqLRBKMUZk` runs for each `vap_table[].sta_table[]` entry. When the VAP is a
guest VAP and `guest_access.portal_enabled` is on:
- no active guest record, and the station reports `authorized` true → `unauthorize-guest` +
  `guest_kicks++` (`devmgr/l/MiVjHefaf:1448`);
- an active guest record, and the station reports `authorized` not true → `authorize-guest`;
- a guest record over its usage quota → `unauthorize-guest` and the record is ended;
- otherwise nothing.

`is("authorized", true)` defaults a **missing** key to true. openUF sends no `authorized`,
so every guest-VAP station counts as authorized. Lab: with three mock stations on the guest
WLAN, `unauthorize-guest` was queued for each of them on **every inform**, and `guest_kicks`
reached 77 in about 10 minutes. On a guest WLAN, openUF's station entries must report
`authorized` as the portal state.

**openUF's answer (C1, lab-validated only, 2026-10-09).** Every `system_cfg` push records the
portal WLANs: the `aaa.<n>.id` of each `wireless.<n>.is_guest=true` WLAN, while
`redirector.status=enabled` (it reads `disabled` when the portal is off). This goes to
`st.guest_wlans`. `authorize-guest` / `unauthorize-guest` add the MAC to / remove it from
`st.guest_authorized`. Each `sta_table[]` entry now carries `authorized`: the ledger's answer
on a portal WLAN and `true` elsewhere. Lab, same three mock stations:
- After a force-provision, `guest_kicks` stayed at 1205 over 60 s; before, it rose on every
  inform. `stat/sta` shows the three stations as `authorized: false`.
- A REST `authorize-guest` for `…:01` brought **the first `authorize-guest` cmd ever seen**
  on the next inform. The ledger took the MAC, `stat/sta` showed it `authorized: true`, and
  no `rate-update` came (no `up`/`down` on the record).
- A REST `unauthorize-guest` brought one `unauthorize-guest` (`guest_kicks` 1205 → 1206) and
  nothing after it.
- After an inform restart, an authorized guest stayed `true` and no command was resent.

**The redirect the portal expects** (CFR, 10.4.57, `devmgr/IXbVCbWPDmZdkfbJ`). The initial
redirect handler reads the guest from the query string:
- `id`: the guest's MAC;
- `ap`: the AP's MAC;
- `url`: where the guest was going;
- `ssid`;
- `t`: the AP's epoch seconds. A `t` more than 60 s from the controller's clock is refused.

It stores them in its encrypted `ec` cookie for the login. An `ec` query parameter replaces all of these with an
encrypted cookie made by the AP (keyed by the AP's `guest_token`), but only on devices
with `supportRedirectorInitialEC`, which `redirector.initialec=enabled` would announce.
openUF does not get that key and uses the plain form.

**`guest_token` is required anyway.** Every login path (`"guest authorization"`), and the
`ec` paths, first checks that the AP's device record has a non-empty `guest_token`. If it
doesn't, the controller logs `Missing Guest Token in AP[<mac>] in Site[…] during guest
authorization` and refuses. The portal still answers the browser `{"authorized":true}`, but
no guest record is written and no `authorize-guest` follows. Lab: exactly that, until openUF
reported one. The record's `guest_token` is copied from the device's stats inform
(`devmgr/PGOcbDWlbnYQdFW:1040`, `copyAttrsIfPresent(…, "guest_kicks", "guest_token")`), so
the device names it. Its format is unverified, because macOS case-folding hides the
decrypting class in this decompile. openUF sends 32 random hex characters, persisted, while
the portal is on. The controller keeps the last value after the portal goes off, which is harmless.

**openUF's enforcement (C2, lab-validated only, 2026-10-10).** `guestportal.lua` reads the
facts from the guest rules:
- the `(ip, port)` ACCEPTs (8880, 8843 and 8881 to `<ctl>`);
- the `-I … -j REDIRECT_HTTP` intercept (8882 to `<ctl>`);
- the `--ip-dst … -j DROP` subnets;
- `redirector.url`.

Every known guest rule shape is classified. Any other guest-chain rule is logged as
unrecognised, and l2guard no longer reports them. From these facts it builds its own nft
chains in the controller's order. The marked HTTP gets `ether daddr` set to the bridge MAC
plus `pkttype host` (ebtables `redirect`), and is NAT-redirected to port 8820. The inform
loop answers there with the `302` above. Lab, 2026-10-10, with a fake guest in its own
network namespace behind a test bridge (MAC `de:ad:be:ef:00:03`, which is also a mock station on
the guest WLAN), and a fake gateway serving `203.0.113.10`:
- Unauthorized: `GET http://203.0.113.10/` → `302` to
  `…/guest/s/default/?id=de%3Aad%3Abe%3Aef%3A00%3A03&ap=…&t=…&url=http%3A%2F%2F203.0.113.10%2F&ssid=probe-wlan`;
  HTTPS timed out.
- The controller accepted that link (`200`), and `POST /guest/s/default/login` answered
  `{"authorized":true,"redirect_url":"http://203.0.113.10/"}`. Before openUF reported a
  `guest_token`, that same answer came back but the login was refused, as above.
- The next inform brought `authorize-guest` for `…:03`. The MAC was in the nft set within the
  heartbeat, and the same `GET` returned the gateway's page (`200`). A `GET` to the AP's own
  address was still redirected, and `10.9.9.9` stayed unreachable.
- REST `unauthorize-guest` → the `unauthorize-guest` cmd → the MAC left the set, and the guest
  was redirected again.
- `is_guest:false` on the WLAN → `redirector.status=disabled` → both tables were deleted, the
  listener closed and the guest was free. `is_guest:true` rebuilt everything.

Throughout: `handle_response failed` = 0, and no unrecognised rule lines.

Deliberate gaps: unauthorized DNS is passed rather than answered locally, marked HTTPS is
dropped rather than answered, and the `redirect` needs an IPv4 address on the guest
VAP's bridge.

| Wire (all `{"_type":"cmd", …, "mac":"…"}`) | Sent when |
|---|---|
| `{"cmd":"authorize-guest","mac":…}` | only from the inform reconcile above (openUF: into `st.guest_authorized`). A REST `cmd/stamgr authorize-guest` just writes the guest record (`authorized_by: "api"`, `end`) and sends **nothing** while the station already reports authorized (lab: none queued) |
| `{"cmd":"unauthorize-guest","mac":…}` | REST `cmd/stamgr unauthorize-guest` (ends the record, then the reconcile repeats it while the station still reports authorized: 3 in 30 s in the lab), plus the reconcile and quota paths above. openUF: out of `st.guest_authorized`, then a deauth on every BSS (see below) |
| `{"cmd":"rate-update","mac":…,"ul_max":2048,"ul_min":64,"dl_max":4096,"dl_min":64}` | once per association (`qos_policy_applied` latch, reset on roam and reconnect), when the guest record has `qos_overwrite` (REST `authorize-guest` with `up`/`down` in kbps). The maxima come from the record's `qos_rate_max_up`/`_down`, defaulting to `-1` (no limit). Without an override, the client's own WiFi Speed Limit profile is sent instead, if it is not the site default (same sender). openUF applies it per client, see "`qos.*` — WiFi Speed Limit" |

**`unauthorize-guest` disconnects the guest (lab-validated only, 2026-10-10).** UniFi
firmware drops the MAC from `/var/run/guest.authorized` and the authorized ipset, then
runs `kick_sta`: `iwpriv <ath> kickmac <mac>` on every VAP whose `/var/run/vapusage.<ath>`
is `user` or `guest` (`syswrapper.sh` `unauthorize-guest`, `platdep_funcs.sh` `kick_sta`;
firmware-confirmed for 3.9.27 to 4.0.15). It kicks unconditionally, with or without the
portal. Without the kick, the guest stays associated and unauthorized, and its OS never
re-runs captive-portal detection, so it never sees the portal again. openUF now does the
same after updating the `authorized` set: `hostapd_cli deauthenticate` on every BSS, the
path `kick-sta` uses. One difference: at most one kick per MAC per 60 s. The firmware
reports `authorized` from the very list it just changed, so it gets one
`unauthorize-guest`. openUF reports it only on the WLANs `st.guest_wlans` names. If that
ever disagreed with the controller, the command would come on every inform, and the hold
keeps it from becoming a deauth storm.

Lab, 10.4.57, with a logging wrapper around `hostapd_cli`:
- A REST `authorize-guest` for mock station `de:ad:be:ef:00:01` put it in the ledger and
  `stat/sta` showed it `authorized: true`. Nothing was deauthenticated.
- A REST `unauthorize-guest` brought the cmd on the next heartbeat (19 s later). While handling it,
  openUF emptied the ledger and ran `hostapd_cli -i wlan0 deauthenticate de:ad:be:ef:00:01`, then
  the same on `wlan1`.
  `guest_kicks` went to 1 and stayed there. Over the next 60 s no other cmd came and nothing
  else was deauthenticated. `handle_response failed` = 0.

Hardware: deployed to both APs, which keep informing. The home site has no guest portal
(`guest_wlans` empty), so the controller never sends `unauthorize-guest` there. The
over-the-air kick is the deauth path `kick-sta` and `block-sta` already use.

**`rate-update`, openUF's answer (C3, lab-validated only, 2026-10-10).** A REST
`authorize-guest` with `"up":2048,"down":4096` for a mock station brought, on the next
inform, `authorize-guest` and then
`{"cmd":"rate-update","mac":"de:ad:be:ef:00:02","ul_max":2048,"ul_min":64,"dl_max":4096,"dl_min":64}`,
in that order. The values are the REST `up`/`down` unchanged, so they are kbps.
openUF keeps `ul_max`/`dl_max` in `st.guest_rates` for an authorized MAC only (dropped
on `unauthorize-guest`; `-1` = no limit that way). It polices them in `bridge
openuf_guest`: `rate_up` (`ether saddr <mac> limit rate over <kbps×125> bytes/second … drop`)
is jumped before `guestin`, and `rate_down` (`ether daddr`) before `guestout`. They are
not queued, because the VAP's tc root qdisc belongs to the per-WLAN speed limit (`shaper.lua`).
Lab:
- Full loop with `up:1024, down:3072`: the ledger got the limits and both chains got the rules.
  They were rebuilt from `state.json` after an inform restart, and removed by the next
  `unauthorize-guest`.
- Data path, with the fake guest above limited to 2048 / 4096 kbps, using iperf3 through the
  bridge to the fake gateway:

  | Test | Limit | Result |
  |---|---|---|
  | TCP upload, 20 s | 2048 kbps | 2097 kbps |
  | TCP download, 20 s | 4096 kbps | 4246 kbps |
  | UDP flood, 10 Mbit/s offered | 2048 kbps | 2448 kbps passed (75 % dropped) |
  | Rules flushed (baseline) | none | ~33 Gbit/s |

`ul_min`/`dl_min` (64 kbps guaranteed) are not applied, since policing cannot guarantee a minimum.

`mgmt_cfg` carries `selfrun_guest_mode=pass` in **every** push, guest WLAN or not. Its
source is the site property `config.selfrun_guest_mode`, and any value other than `pass`
goes out as `off` (`config/GWoWvNEX`). It is not in the 10.4.57 UI. The site properties
are the per-site file `data/sites/<site name>/config.properties` (`config/bLwwMKkr` →
the file service by site name), **not** `system.properties`. Lab, 10.4.57: a line in
`system.properties` (restart included) left the wire at `pass`. Writing
`config.selfrun_guest_mode=off` to `data/sites/default/config.properties` made the next
push carry `selfrun_guest_mode=off`, with no restart needed.

**What the AP does with it (UniFi firmware, BZ2 3.9.27 and 4.0.15).** Both builds are
plaintext (as is every MIPS/QCA956x build read since, see the newer firmware audit; only
the ARM64 U6/U7 images are opaque), and their selfrun code is identical:
- `/bin/mcad` enters SELFRUN (state 3, writes `/var/run/system.selfrun`, calls
  `syswrapper.sh set_selfrun`) once its consecutive-failure count reaches 3 (`fail_count`
  at object offset 0x264, `sltiu …, 3`). The first successful inform calls `unset_selfrun`.
- `/usr/etc/syswrapper.sh` only acts while the portal is on (`redirector.status=enabled`).
  `selfrun_guest()` reads the key from `/etc/persistent/cfg/mgmt`: only `off` is off, so any
  other value, or none, means `pass`.
- `pass`: `ebtables -t nat -F AUTHORIZED_GUESTS; ebtables -t nat -A AUTHORIZED_GUESTS -j
  ACCEPT` ("bypass the guest authorization"). On return, `rm -f /var/run/guest.authorized`
  plus `authorized_guests_updated`: every authorization is forgotten, and the controller
  re-authorizes.
- `off`: `ifconfig $ath down` for every guest VAP (`/var/run/guest_devnames`). The VAP
  scheduler keeps them down while selfrun lasts. On return, `ifconfig $ath up`.

**openUF's answer (C4; lab-validated, and `off` hardware-tested).** It keeps the value as `st.guest_selfrun`,
where only `off` is off. Selfrun starts after 3 failed informs in a row
(`GUEST_SELFRUN_FAILS`) and ends with the first answer. With `pass`, the `selfrun` chain
(jumped from `guestin` right after the authorized accept) gets `meta pkttype other accept`,
the same position as the firmware's AUTHORIZED_GUESTS accept. With `off`, the guest VAPs
are taken down with `ip link set` and their names are kept in `st.guest_vaps_down`, so they
come back up even across a daemon restart. On return openUF keeps its authorized list
instead of clearing it, because the controller re-authorizes the same guests either way.
Lab, with the controller cut off from the AP by an nft `reject` on :8080:
- `pass`: three `POST failed`, then "3 informs unanswered, selfrun_guest_mode=pass …
  letting guests through", and the chain held the accept. Once the cut was lifted: "guest
  portal enforced again", and the chain was empty. The guest VAPs stayed up.
- `off` (the guest VAPs `wlan0`/`wlan1` as dummy interfaces, since the lab has no radios):
  after the third failure, "guest WLANs down (wlan0 wlan1)". Both went DOWN, the chain stayed
  empty, and `guest_vaps_down` was saved. The daemon was then restarted mid-outage: two more
  failures, and both stayed DOWN. With the cut lifted, "guest WLANs back up" appeared, both
  were UP again, and the ledger was gone.
- Data path, from the earlier 120 s run of this feature (the fake guest from C2, not
  authorized): closed → HTTP redirected to the portal and :5201 blocked. Open →
  `INTERNET-OK` and :5201 open, while a restricted subnet (10.9.9.9) still timed out.
- `handle_response failed` = 0.
- That run predates the beacon restart below. The lab has no hostapd, so the same run now
  leaves both dummies DOWN after the answer, with the ledger kept and retried.

**Hardware, 2026-10-11 (both APs, OpenWrt 25.12).** The guess above was wrong: on a real
radio, `ip link set <bss> up` alone leaves the BSS off the air, as found for the WiFi
Blackout Schedule (see that section). hostapd does not act on the link going down, so on
the way up it only updates a beacon mac80211 has already stopped. Reproduced on the living
room AP's ath10k: after `ip link set phy0-ap1 down; ip link set phy0-ap1 up`, `iw dev
phy0-ap1 info` showed no SSID and no channel. openUF now brings a guest WLAN back through
`wlansched.set_bss`: link up, then `hostapd_cli -i <bss> raw STOP_AP` and `update_beacon`.
A BSS whose beacon does not restart goes down again and stays in `st.guest_vaps_down`, so
the next answer retries it. On-device run of `_guest_selfrun` (`OPENUF_TEST_MODE`, the
state save stubbed) against a temporary WPA2 WLAN on both radios of both APs (ath10k ch
36, ath9k ch 1, mt76 ch 11 and ch 100 DFS): three missed informs → both BSSes DOWN with no
SSID; one answer → "guest WLANs back up", ledger cleared, and `iw dev <bss> info` showed the
SSID and its channel on all four. The temporary WLAN was deleted afterwards.

## Wireless uplink (mesh): the push, the contract, and the live result — 2026-10-03

Captured on AP2 against the UCG Ultra (Network 10.6.106) by claiming `wifi_caps` bits through
`debug_caps`, setting the device's mesh-connect flag and priority-1 parent through the
controller's own REST and command endpoints, and diffing the resulting `setparam`s against the
wired baseline; then **implemented (`backhaul.lua`) and verified end to end the same day**:
AP2's cable pulled, AP2 joined AP1's hidden downlink as a 4-address station at −10 dBm with
HE160 4×4 rates both ways, kept its address, informed over the hop, carried a VLAN-10 IoT
client to its own network, and the controller showed the uplink as wireless with AP1 as the
parent and AP1 listing AP2 as a wireless downlink. Full evidence: REVERSE-ENGINEERING.md,
Investigation 1.

**The reporting contract, from the controller's inform processor** (`internal-dependencies.jar`
of the matching Linux package, jadx on `com.ubnt.service.devmgr.iceUMDuewFNFLMOqti` and
`...devmgr.C.RxFvcetMTlkSFFxK`; the three shapes guessed before reading it were all wrong):

- The top-level **`uplink` is a string**: the *name* of the uplink interface. Default `"eth0"`;
  `"down"` marks an isolated device. When it names an entry of `if_table`, the wired path runs
  (counters from that entry, identity from the gateway's LLDP downlink). When it names a
  `vap_table` entry of `usage` `uplink`, the wireless path runs. Sending an object here is
  read as the default and yields a stale "wired via port N".
- A **wireless uplink is a `vap_table` entry** with `usage: "uplink"`, `name` equal to the
  `uplink` string, `up: true`, a non-zero `channel`, `essid` equal to the site's mesh ESSID
  (that is what sets `is_mesh_v3`), `bssid` = the station's own address, `state` RUN, and a
  **`sta_table` holding exactly one station: the parent's downlink BSS**, with `rx_packets > 0`
  and the attributes the controller copies onto the uplink (`signal`, `rssi`, `tx_rate`,
  `rx_rate`, `tx_packets`, `rx_packets`, `tx_bytes`, `rx_bytes`). That station is resolved to
  a device **by its `serialno`** when that is a MAC; the fallbacks are a `(vwire|vport)-<12
  hex>` ESSID (mesh v2, where the name encoded the parent) and an OUI-based derivation that
  only knows Ubiquiti prefixes, so openUF must supply `serialno` — the controller's priority-1
  parent (`mesh.serial1`), else the sibling element of the BSS joined.
- A **downlink is a `vap_table` entry** with `usage: "downlink"` (same validity rules), whose
  `sta_table` lists the children's 4-address stations; each resolves to a child by `serialno`,
  then by the controller's own BSSID tracker, else it logs "Can't resolve wireless mac".
- `uplink_table`, `vwire_table`, `vwire_vap_table`, `downlink_table` and the v2
  `wireless-links` view are **computed by the controller** from the above; device-sent
  copies are ignored. `meshv3_peer_mac` and `uplink_bssid` are stored verbatim.
- A `vap_table` entry whose ESSID starts with `vport-`/`vwire-` but has `usage: user` is
  dropped with "handling is done differently, update AP firmware".

**Device side (openUF, 2026-10-03 evening):** `_parse_wifi_system_cfg` hands the push's two
entries to `backhaul.lua`; `_parse_mesh_system_cfg` reads the `mesh`/`connectivity` blocks.
The downlink becomes `openuf_bh_dl_<radio>` (hidden `wds 1` WPA2-PSK AP in `lan`, beaconing
the sibling element), the uplink `openuf_bh_ul_<radio>` (4-address station, enabled only
while the wired uplink socket has no link). `get_vap_table` reports both as typed entries
named with the controller's devnames (`vwire3`, `ath4`), the uplink with its station
interface's own `station dump` as its one-entry `sta_table` plus `serialno`, the downlink
with the per-station WDS netdevs' dumps as its children; Minimum RSSI and Roaming Assistant
never act on either. `uplink` is the uplink VAP's name while associated. `wifi_caps`
`0x1|0x800` are claimed by default, on swconfig boards too since 2026-10-18 (`meshvlan.lua`
carries their tagged SSIDs over the hop, USAGE § 6b). First swconfig run 2026-10-19, a Deco
M4R v1 (user, shallow): with the cable pulled it came up online over the wireless uplink; the
cable coming back and a tagged SSID across the hop are not yet confirmed there.

**How the controller is told.** The device settings form issues
`PUT /api/s/<site>/rest/device/<_id>` with `mesh_sta_vap_enabled` (and `mesh_uplink_1`/`_2`),
then `POST /api/s/<site>/cmd/devmgr {"cmd":"set-priority-uplink","mac":<child>,"prefer1":<parent>}`
(`prefer2` optional; `unset-priority-uplink` clears). The flag is persisted only for a device
claiming `wifi_caps` `0x1`, and the controller turns it **on by itself** once a device claims
that bit. The parent dropdown is the device's `uplink_table`, which the controller derives from
the uplink VAP's resolved station.

**What arrives** (child = AP2, parent `00:00:5e:00:53:c9` = AP1, 5 GHz radio is `radio.2`):

```
# mesh                                       (needs 0x1 + 0x800)
mesh.status=enabled
mesh.version=3
mesh.essid=vwire-5f3369181f7fbab5             ← site setting connectivity.x_mesh_essid
mesh.psk=<32 chars>                           ← site setting connectivity.x_mesh_psk
mesh.serial1=00:00:5e:00:53:c9                ← priority-1 parent (mesh_uplink_1)
# connectivity                               (needs 0x1)
connectivity.status=enabled
connectivity.uplink_wds=ath4
connectivity.uplink_eth=eth0
connectivity.uplink_bridge=br0
# the downlink: a hidden WPA2 AP for children (needs 0x1 + 0x800; flag on or off)
radio.2.virtual.1.devname=vwire3   radio.2.virtual.1.mode=master   radio.2.virtual.1.status=enabled
wireless.4.devname=vwire3  mode=master  usage=downlink  wds=enabled  vwire=enabled  vport=disabled
wireless.4.ssid=vwire-5f3369181f7fbab5  hide_ssid=true  parent=radio1  security=none  authmode=1
aaa.4.devname=vwire3  ssid=vwire-…  wpa=2  wpa.key.1.mgmt=WPA-PSK  wpa.psk=<same 32 chars>
aaa.4.wpa.1.pairwise=CCMP  hide_ssid=true  status=enabled  br.devname=br0  pmf.status=disabled
# the uplink: a 4-address station toward the parent (needs 0x1 and the device's mesh flag)
radio.2.virtual.2.devname=ath4     radio.2.virtual.2.mode=managed  radio.2.virtual.2.status=enabled
wireless.5.devname=ath4  mode=managed  usage=uplink  wds=enabled  vport=enabled  vwire=disabled
wireless.5.ssid=vport-ac10076fc670  hide_ssid=true  parent=radio1  security=none
aaa.5.devname=ath4  ssid=vport-ac10076fc670  status=disabled   (no key here: the station uses mesh.psk)
# plumbing: both devnames join the bridges, tagged for every VLAN the AP carries
bridge.1.port.4.devname=ath4   bridge.1.port.5.devname=vwire3
vlan.2.devname=ath4 vlan.2.id=10   vlan.3.devname=vwire3 vlan.3.id=10
bridge.2.port.3.devname=ath4.10   bridge.2.port.4.devname=vwire3.10
netconf.<n>: ath4/vwire3 up=disabled promisc=enabled; ath4.10/vwire3.10 up=enabled
```

Everything else in the push was unchanged, including `radio.2.channel=auto` — the controller
does not pin the child to the parent's channel in the config, so the station itself has to
follow the parent (the parent's own channel is in its push). The `vport-<mac>` naming matches
fxkr's 2015 capture of a real UAP's uplink VAP.

### A wired child gets no uplink entry — 2026-10-29

Two JIDU6401s, 10.6.106, Wireless Meshing on for both. The child had meshed earlier and was
then cabled. One full push to it (cfgversion blanked, `debug_dump_file` on, mesh lines only):

```
mesh.status=enabled  mesh.version=3  mesh.essid=vwire-<site>  mesh.psk=<site key>
wireless.1  mode=master usage=user  parent=radio0
wireless.3  mode=master usage=user  parent=radio1
(no usage=uplink, no usage=downlink entry)
```

The controller sends the uplink station entry only to a device it last saw on its wireless
uplink. openUF used to build the station only from that entry, so once a push reached the
cabled child its station section was gone; pulling the cable then left it with nothing to
join (no attempt on the parent's downlink, nothing logged). `backhaul.plan` now builds the
station from the mesh block when the entry is missing, on the radio of the last pushed
uplink (`st.backhaul_ul`), else the downlink's, else the 5 GHz one, written disabled as
always. What real firmware does in this case was not captured; it has to do the same to
fail over, since the push gives it nothing else.

### The parent names its children — 2026-10-03

The controller resolves each station of a downlink VAP to a device by the station's
`serialno`, else by a BSS it has scanned with that MAC, else by Ubiquiti's OUI arithmetic
(first byte rewritten, fourth byte − 1). A 4-address station never beacons and a
TP-Link/Jio board has no Ubiquiti OUI, so without `serialno` the parent logged "Can't
resolve wireless mac" and its `downlink_table` stayed empty while the child's uplink
resolved fine. The parent can name the child itself: hostapd parks each WDS peer on its
own netdev (`phy1-ap1.sta<N>`), the bridge learns the child's identity MAC behind that
netdev, and the sibling element in the parent's scans says which MACs are site APs.
`backhaul.child_serialno()` intersects the two and the station's `serialno` is set when
exactly one sibling is behind the netdev (two would mean a grandchild on a multi-hop path,
and a wrong attribution is worse than none). This is the same first-class field the uplink
side already fills, which is why it was chosen over OUI games or renaming the station.
Implemented on both APs' trees 2026-10-03; it runs on whichever AP is the parent.

**The child's half had a cold-boot hole (found and fixed the same evening).** AP2 was
powered off, cabled off, and powered on: the station joined AP1 in 40 s, informs flowed
over the hop, AP1 named the child — and the controller still drew AP2 wired on the
gateway's port 2. The uplink VAP's one station had no `serialno`: `parent_for_bssid()`
tested the scan entries for `is_unifi`/`serialno`, which exist only on the payload's
`scan_radio_table`; `sysinfo.scan_table()` returns the raw sibling element as `peer_mac`.
The live test that day had passed because the controller's push names the parent
(`mesh.serial1` → `st.backhaul_parent`), and a device that boots straight onto the air with
a matching `cfgversion` never receives that push. The lookup now reads `peer_mac` too and
prefers the BSS actually joined over the push's parent (which describes the push's
topology, not where the station roamed to). Verified: the controller flipped AP2 to
`uplink.type: wireless`, `uplink_mac` = AP1, `name: ath4`, −53 dBm, channel 100, within one
heartbeat of the deploy. Lesson for the next field read off a scan entry: the two shapes
differ, and a test with hand-built entries proves nothing about which one a caller gets.

## RF scans: Airtime Scan, Quick Scan and Radio AI's sweep — 2026-10-03

Three different commands, one device-side job. Everything below is read from controller
10.6.106's bytecode (`com.ubnt.service.system.l.*`, `devmgr.b.g.ctfbDsCjrxgkv`,
`devmgr.iceUMDuewFNFLMOqti`, `devmgr.kDxteQiUX`, `devmgr.e.c.VsCpQiCuGEvNvUNmH`,
`stat.hyFnQ`) and its frontend bundles (`swai`, `airview`, `react-app-wrapper`), then
confirmed live against AP2 the same day.

**The gates.** Airtime Scan (Devices → [AP] → Radios → Airtime): button shown with
`wifi_caps` `0x10` (RF_SCAN) on a wired AP; the view's "scan while serving" flag is
`wifi_caps2` `0x2` (MONITOR_RF_SCAN). Quick Scan: `wifi_caps2` `0x80`; the REST handler
also requires `!isWirelessUplink()`, an active device, and no scan already running. Radio
AI's prescan asks every AP with `supportQuickScan()` that is not on a wireless uplink.
`stat/spectrum-scan`, the endpoint the view reads, skips any device without
`supportSpectrumScan()` — so without `0x10` the data is invisible even when sent.

**The commands.**

| cmd | arguments as the device receives them | who sends it |
|---|---|---|
| `spectrum-scan` | `{mac}` | the Airtime Scan button |
| `quick-scan` | `{mac, "scan-band": 0\|1\|2, "scan-bw": 20\|40\|80\|160}` — band index (ng/na/6e) and width in MHz, both **integers** (the REST side takes `"na"`/`80` and re-encodes) | the Quick Scan dialog; Radio AI's prescan |
| `scan_band` | `{band: "ng"\|"na"}` | the controller's scheduled neighbour sweep (`XbYOtjBEpjeHWlUU`); it sets the record's `scanning` and takes the next inform's `scan_radio_table` |

**What the device reports.** The sweep itself is `iw dev <if> scan ap-force` followed by
`iw dev <if> survey dump`, 1.5–2.7 s per radio; all three commands run it inside their own
dispatch, so the inform that follows the command already carries the result.

- `radio_table[].spectrum_table` — rows `{channel, width, center_freq, utilization,
  interference}`, one per 20 MHz channel per width the band offers (ng 20/40, na
  20/40/80/160). `utilization` is busy airtime in %, `interference` the busy time that was
  neither this radio's rx nor tx in %, both 0–100. The table must be on the **radio_table
  entry**: the UAP processor walks `payload.radio_table` (as it does for `athstats`) and
  copies `spectrum_table` from each radio into the stored `radio_table_stats` when the
  device is not mid-quick-scan and the list is non-empty. A table only in
  `radio_table_stats` is never read — two live sweeps left `stat/spectrum-scan` empty
  until the table moved. openUF sends it in both places.
- `radio_table[].spectrum_table_time` — seconds **since** the sweep. The processor stores
  `now − value` as the sweep's epoch; the view prints it as "N minutes ago".
- `quickscan_scanning` / `spectrum_scanning` — booleans. The controller set the record's
  `quick_scan_state.in_progress` when it dispatched the quick-scan; the device's `false`
  on the next inform is the "just finished" edge that pushes the fresh tables to the open
  view (`kDxteQiUX`). A quick-scan the device never answers times out after ten minutes.
- `EVT_AP_QuickScanEvent` — a **notification inform**: the regular payload plus
  `inform_as_notif: true`, `notif_reason: "event"` and `notif_payload: {event_string:
  "EVT_AP_QuickScanEvent", radio, radio_name, channel, width, center_freq, utilization,
  interference}`. The inform entry (`devmgr.l.AqxpICcpcuIxnda`) takes that branch before
  any statistics processing and answers a bare `noop`; the handler upserts the row and
  stamps the record's `spectrum_scan_timestamp` (ms) — which is the Quick Scan card's
  "last scan" and what Radio AI's prescan waits for before it reads the tables. The
  device's own top-level `spectrum_scan_timestamp` is ignored. openUF posts one such
  inform after the heartbeat that carried a sweep's table; one row is enough.
- The row shape, the averaging and the width tabs come from the frontend: `renderChannel`
  filters rows with `width === tab` whose `channel` is in the block's `subChannels` (which
  for 2.4 GHz 40 MHz blocks span every overlapping 20 MHz channel) and **averages** them
  (module 178221), so each row carries its own channel's figures.

**Live, 2026-10-03, AP2 (JIDU6101, 25 channels on 5 GHz):** `quick-scan` with
`scan-band: "na", scan-bw: 80` through `cmd/devmgr` → `cmd: quick-scan` in the daemon
log, `quick_scan_state.in_progress: true` with `last_band: na, last_width: 80`, then
`false` on the next inform; the notification inform set `spectrum_scan_timestamp` (ms)
and, once the table rode the radio_table entry, `stat/spectrum-scan` held **100 rows for
radio1 — 25 channels at each of 20/40/80/160 MHz** — with `spectrum_table_time` as the
sweep's epoch (the age the device sent, converted). `spectrum-scan` arrived and swept both
radios the same way. Three runs in all; the first two (table only in `radio_table_stats`)
left the stat empty, which is how that mistake was found.
The DTO (`stat/device`) strips `spectrum_table` from `radio_table_stats` unless a quick
scan is in progress, by design; `stat/spectrum-scan/<mac>` is the read path.

**A sweep in one go empties the room — found live, fixed the same evening.** The first
handler ran `iw dev <ap> scan ap-force` over the whole band inside the command's dispatch.
On an AP radio mac80211 stops beaconing for the entire off-channel run; 25 channels at
40–110 ms each is ~3 s of silence (2.7 s measured on this board), every client declared the
AP gone and roamed — and Radio AI's prescan asks every eligible AP at once, per band, so a
Quick Scan from the Channel AI page had the MacBook and the iPhone falling off AP1's 5 GHz
onto AP2's 2.4 GHz while that radio was being swept too ("kicks everyone off and we can't
join for a while", with the hostapd `AP-STA-DISCONNECTED` storm to match). Measured on
mt7986 with `iw ... scan ap-force freq <list>`: ~600 ms of wall time per channel where the
radio also carries an associated station (mac80211 returns to the operating channel between
channels, so AP2's own uplink never dropped), straight through where it does not; no
`SET_SCAN_DWELL` support. So every sweep — `quick-scan`, `spectrum-scan`, `scan_band` and
the controller's nightly `11k-scan` — is now a **job**: the radio's channel list (from the
cached `iw phy` dump, `sysinfo.phy_frequencies`) cut into chunks of four, one chunk per
heartbeat (`_scan_job_tick`), at most ~0.45 s without beacons (four passive dwells), with
the rows rebuilt and one `EVT_AP_QuickScanEvent` posted after each chunk so the
controller's prescan — which polls for 180 s, takes rows as they arrive and stops after
two quiet rounds — sees progress rather than a 90-second gap. `quickscan_scanning` /
`spectrum_scanning` stay true until the last chunk, which is the completion edge the UI
and the in_progress flag want; the quick-scan's own fuse is ten minutes. Where the channel
list cannot be read the job is one whole-band chunk, the old behaviour.

**Still approximate.** `interference` as "busy minus own rx/tx" counts other BSSs' traffic
as interference, which a real AP's hardware spectral scan would not. The survey counters
are cumulative since boot for the operating channel and a few ms for the others, so the
operating channel's figure is a long-run average while the rest are the sweep's dwell.

## Discovery requests and WiFiman — 2026-10-03

**WiFiman is console-side.** The site setting is `mgmt.wifiman_enabled`; the controller
never pushes any wifiman key to an AP (AP2's ledger has none after weeks), and the app
reads the console: `GET /v2/api/site/<site>/wifiman/<clientIp>` (client info: channel,
link rates, experience history, `uplink_devices` chain, `nearest_neighbors`, ISP
capability) and `.../wifiman/<clientIp>/devices`; `POST .../feedback` stores the app's
speed tests. The controller finds the client **by its IP** in the active clients, follows
`ap_mac` to the AP and `uplink.uplink_mac` up the chain, and asks the AP for an inform
within ten seconds (`wifiManInformService`). Queried with the API key for a laptop on
openUF's AP1, every field came back populated except `noise: 0` and `channel_width: null`
(openUF reports neither per station). The REST classes (`com.ubnt.service.wifiman.*`,
`com.ubnt.net.l.aN.RxFvcetMTlkSFFxK`) are the whole feature; the same `GET` under
`/api/` instead of `/v2/api/` answers `api.err.InvalidObject`, which cost an hour.

**The AP-side gap was discovery.** WiFiman's Discovery tab, the UniFi mobile app and the
Device Discovery Tool list Ubiquiti devices by broadcasting the four-byte probes
`01 00 00 00` (v1) and `02 08 00 00` (v2) to UDP 10001 and listing who answers. openUF's
announcer only ever **broadcast** (version 2, command 6) from an ephemeral port and never
listened on 10001, so those tools saw a bare host next to the UCG Ultra's full entry —
"no extra info". Captured 2026-10-03 with a probe script: the UCG answers v1 with version
1 / command 0 and v2 with version 2 / command 9, the same TLVs (hardware address, IP,
hostname, platform, firmware, uptime, …) in both, unicast from port 10001 to the asker's
own port; AP1 and AP2 answered nothing. `announce.lua` now binds 10001 and answers each
probe the same way (`reply_for`, `_serve_requests`); the first probe after the deploy got
four replies from AP2. The periodic broadcast is unchanged, and `l2_announce = false`
still turns both off together.

## Outbound payload field reference

Everything openUF sends. Names were audited against the controller's own Device model
(`com.ubnt.data.cVbZoFIZsWYaVCquTr` and its ~90 nested per-sub-object classes).

### Top level

| Field | Value / notes |
|---|---|
| `_type` | `"state"` |
| `default`, `state` | `not adopted`; `2` connected / `0` unadopted |
| `mac`, `serial`, `model`, `platform`, `hostname`, `ip` | `serial` is the MAC with colons stripped |
| `inform_url`, `cfgversion`, `uptime`, `time` | |
| **`version`** | **Bare firmware version only — never model-prefixed.** See below. |
| `required_version`, `bootrom_version`, `country_code` | `bootrom_version` has no counterpart anywhere in the device schema (closest is `boot_time`, a timestamp); likely ignored, left as-is for want of evidence to rename it to. |
| `mem_total`, **`mem_used`** | Bytes. `mem_used = total − free`; the schema has `mem_used`, not `mem_free`. |
| **`system-stats`** | Hyphenated key, `{cpu, mem, uptime}` — all three **strings**, cpu/mem as percentages. Not `sys_stats`, and not loadavgs. `cpu` is `0` on the very first inform (delta-sampling `/proc/stat` has no prior sample). |
| **`fw_caps`** | `0x110` — see [capability bitmasks](#capability-bitmasks) |
| **`wifi_caps2`** | `0x40` — see [capability bitmasks](#capability-bitmasks) |
| `spectrum_scanning`, `spectrum_scan_timestamp` | **Device-level**, not per-radio (the per-radio fields are `spectrum_table`/`spectrum_table_time`) |
| `if_table[]` | `name`, `mac`, `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets`, `rx_errors`, `tx_errors` |
| `radio_table[]`, `radio_table_stats[]`, `vap_table[]`, `scan_radio_table[]`, `port_table[]`, `lldp_table[]` | See below |

**Why `version` must be bare.** The upgrade-offer gate in `MiVjHefaf`:

```java
private boolean chgwykfBxZCAuEHPPQ(String string, String string2) {
    return this.TgovGTpPRqBiOa(string) && !StringUtils.equals(string, string2);
}
// object3 = ProductInfo.version         -- e.g. "6.8.2.15592" (bare)
// string  = inform.getString("version")
```

A **strict, unnormalized `StringUtils.equals`** — no prefix stripping, no numeric parsing.
Sending `"U6IW.6.8.2.15592"` never matches `"6.8.2.15592"`, so the "Update Available" banner is
permanent regardless of the actual firmware version. The catalog's version is confirmed bare
by the controller's own startup log: `firmware[U6IW] new version (6.8.2.15592) is available`.

`fw.pre` (`"U6IW."`) remains correct and untouched in `announce.lua`'s L2 discovery
"firmware version verbose" TLV — a different protocol surface. Do not reuse it here.

### Capability bitmasks

| Field | Bit | Controller method | Effect if absent |
|---|---|---|---|
| `fw_caps` | `0x10` (16) | `Device.hasQCASwitch()` = `hasFirmwareCapability(16)` | The Ports view's projection of `port_table` into the device DTO doesn't happen. Wired-client *ingestion* is gated only on `isSwitch()` (a model-registry property), so clients still appear in the list — but the Ports view stays empty. |
| `fw_caps` | `0x100` (256) | `Device.hasOWRTSwitch()` = `hasFirmwareCapability(256)` | Per-port VLAN assignment is rejected outright — see below. |
| `wifi_caps2` | `0x40` (64) | `Device.supportAdvertisingDeviceNameInBeacon()` = `hasWifiCapability2(64)` | The controller never emits `wireless.<n>.advertise_ap_name` at all, and doesn't even re-push config on the toggle. |
| `wifi_caps2` | `0x20` (32) | `Device.supportsAssistedRoaming()` | A WLAN's Roaming Assistant (`wireless.<n>.btm_disassoc.*`) is never emitted. Claimed since 2026-09-28 (`roamassist.lua`). |
| `wifi_caps2` | `0x80` (128) | `Device.supportQuickScan()` | The Quick Scan button is hidden and the REST `quick-scan` cmd is refused (`devmgr.b.g.ctfbDsCjrxgkv`); Radio AI's prescan skips the AP ("no quick-scan-capable eligible AP"). Claimed since 2026-10-03 — see [RF scans](#rf-scans-airtime-scan-quick-scan-and-radio-ais-sweep--2026-10-03). |
| `wifi_caps2` | `0x2` (2) | `MONITOR_RF_SCAN` (frontend table 718429) | The Airtime view's "scan while serving" check. Claimed since 2026-10-03 alongside `0x80`; the device's share is the same forced sweep. |
| `wifi_caps` | `0x10` (16) | `RF_SCAN` (frontend table 537871) → `supportSpectrumScan()` | The Airtime Scan button is hidden and `stat/spectrum-scan` skips the device (`if (hyfnq6.supportSpectrumScan())`). Claimed since 2026-10-03. No config key changed on the push that followed the claim (ledger diffed on AP2). |
| `wifi_caps` | `0x4` / `0x8` | `supportBandsteering()` / `supportVapBasedBandsteering()` | The device-level `bandsteering.status`/`mode` block (the AP's own Band Steering setting) and its per-WLAN pairs are never emitted; without `0x8` one single-band WLAN switches the device's steering off. Claimed since 2026-09-28. |
| `wifi_caps` | `0x20` (32) | `supportATFConfig()` | `atf.status`/`atf.mode` (Airtime Fairness) is never emitted. Claimed where mac80211's per-phy `airtime_flags` exists (`airtime.lua`). |
| `wifi_caps` | `0x100000` | `supportWpaPpsk()` | A WLAN with Private Pre-Shared Keys, or UID IoT, is **skipped** ("PPSK is not supported … will be skipped"). Claimed where the ucode generator writes `vlanid=` and hostapd has VLAN support (`sysinfo.ppsk_supported`). |
| `radio_caps2` | `0x1` | radio DTO `CVir()` | Every WPA3 WLAN is downgraded to WPA2 -- see the WPA3 section below. Claimed where hostapd has SAE. |
| `radio_caps2` | `0x2` | radio DTO, FT-with-WPA3 (`ytajcagDggPuTaL()`) | On an SAE WLAN `wpa3_fast_roaming` is forced off, so `aaa.<n>.wpa3.ft.status` is always `disabled`; on a WPA3-only WLAN `fast_roaming_enabled` too, and no 802.11r goes out at all. Claimed alongside `0x1`. |
| `radio_caps2` | `0x8` | radio DTO, OWE (`NoFWvUa()`) | An Enhanced Open WLAN is **not provisioned** ("WPA3-OWE cannot provision"); with OWE transition on it goes out as plain open. Claimed where `hostapd -vowe` passes and the ucode generator knows `owe_transition`. |
| `wifi_caps` | `0x1` (VWIRE) | backend validator of `rest/device` (field `mesh_sta_vap_enabled`); AP config generator | **Confirmed live 2026-10-03 (AP2, 10.6.106, REST writes bisected over five masks).** Without it the mesh-connect flag is silently dropped (`rc: ok`, empty `data`, reads back `false`) — the UI's tick "reverts". With it the flag persists and the push gains the **uplink station VAP** (`usage=uplink`, `wds`/`vport` enabled, `vport-<mac>`) and `connectivity.uplink_*`. Claimed by default since the 2026-10-03 mesh work (`backhaul.lua` provisions the station); on swconfig boards since 2026-10-18. |
| `wifi_caps` | `0x800` (MESHV3) | AP config generator | **Confirmed live 2026-10-03.** Together with `0x1` adds the `mesh.*` block (`status=enabled`, `version=3`, `essid`, `psk`, `serial1` while a parent is set) and the **downlink VAP** `vwire3` (`usage=downlink`, `vwire=enabled`, hidden WPA2-PSK), flag on or off. Alone it does nothing. Claimed with `0x1`, as above. |
| `wifi_caps` | `0x80` (MESH) | — | **No observable effect** (2026-10-03): pushes with and without it were identical. |

`wifi_caps2` is a **second, entirely separate** bitmask from `wifi_caps`. Since 2026-09-28
openUF claims `wifi_caps` `0xC` (+`0x20`, +`0x100000` where the device-side probe passes),
`wifi_caps2` `0x60` and `radio_caps2` `0x3` (+`0x8`); `debug_caps` in `conf.lua` still
replaces any mask whole for an experiment. The rows below come from upstream's full sweep of
the controller's gates.

#### Full sweep of the capability gates (controller 10.6.101, upstream, 2026-09-27)

Every `has*Capability` predicate on `com.ubnt.data.dChnXOlwHH` (the `Device` class) and
every `radio_caps`/`radio_caps2` bit test on the radio DTO `com.ubnt.i.g.e.DXufmCC` was
traced by upstream to its callers, mainly the AP config generator
`com.ubnt.service.config.oHgVgY` and the per-radio WLAN security filter
`com.ubnt.service.config.ubntconf.plVcFpIybmrpXclX`. Calls on
`com.ubnt.i.g.OZQcnZuvnRweLFaaG` in oHgVgY check the **model registry**, not anything the
device sends, and are excluded. **The unclaimed rows come from decompiled code only; none
has been checked on the wire.**

Gated, and deliberately not claimed:

| Field | Bit | Predicate | Effect while unclaimed |
|---|---|---|---|
| `fw_caps` | `0x1000` | `supportMultiBlockWlanSchedule()` | A WLAN Schedule with several blocks per day goes out as one `wireless.<n>.schedule_<day>` key per block, all under the same name, so the last one wins. With the bit set they become `schedule_<day>.<i>` |
| `fw_caps` | `0x400000` | `supportWlanScheduleInvert()` | The controller inverts a schedule itself instead of sending `schedule_invert` |

The two schedule bits are not claimed because openUF implements no WLAN Schedule: the
`schedule_*` keys are emitted whenever a WLAN has a schedule, regardless of any bit, and
openUF parses none of them. Claim both when the feature is built.

- **No OpenWrt equivalent, or out of scope:**
  - `radio_caps2` `0x400` and `wifi_caps2` `0x1`/`0x4000`/`0x8000`: MLO and Mesh-MLO.
  - `radio_caps` `0x20000`: `radio.<n>.hard_noisefloor.*` / sensitivity level, a QCA RX-sensitivity setting.
  - `wifi_caps` `0x4000`/`0x8000`: multi-vport and Element. (`0x1`/`0x80`/`0x800` — vwire, mesh, meshv3 — moved to the gated table above on 2026-10-03; see § Wireless uplink.)
  - `wifi_caps` `0x2000` "open hostapd", `0x40` `bga_filter`, `0x4000000` low-performance mode (`0x10` spectrum scan is claimed since 2026-10-03).
  - `wifi_caps2` `0x4` Green AP, `0x10` ACS-DFS, `0x200` neighbour-in-scan, `0x20000` (an AP-group check, purpose unclear) (`0x80` quick scan and `0x2` monitor RF scan are claimed since 2026-10-03).
  - `fw_caps` `0x800000` Hotspot 2.0 (such a WLAN is skipped without it) and `0x20000000` RADIUS `filter_id`.
  - `fw2_caps` `0x80000` RadSec, `0x20` `port_table.mac_table_ipv6`, `0x80` device command retry.
Two entries moved out of that list on 2026-10-26, after reading the 6.8.2 firmware's own
hostapd generator and the 10.6.106 jar:

- **`radio_caps2` `0x4` (WPA3-Enterprise-192) is not "no OpenWrt equivalent".** OpenWrt's
  live ucode generator has `encryption=wpa3-192` → `auth_type=eap192` →
  `wpa_key_mgmt=WPA-EAP-SUITE-B-192` with GCMP-256, read out of
  `/usr/share/ucode/wifi/iface.uc` on an Archer C5 (25.12, `wpad-mbedtls`) on 2026-10-26.
  openUF maps that value, but **still does not claim the bit**: without it the controller
  never sends a 192-bit WLAN, so the mapping is inert and costs nothing, whereas claiming it
  would assert a Suite-B path nothing has exercised.
- **`wifi_caps` `0x40` (`bga_filter`) is implemented already, in the other encoding.** The
  ebtables emitter (`ubntconf/YcZSaTCMOYFEMGE:201`) computes
  `emit_bpdu_rules = !config.forward_bpdu && !hasWifiCapability(64)`, and `l2guard.lua`
  parses exactly those rules (`-t nat -A PREROUTING --in-interface <dev> -d BGA -j DROP`
  and its POSTROUTING twin). Claiming the bit would make the controller **stop** sending
  them and send a single `bga_filter` key instead: no new capability, and a regression risk
  if the new key were mis-parsed. Left unclaimed deliberately, not for want of an equivalent.
- **`fw_caps` `0x800000` (Hotspot 2.0) is now claimed**, gated on a probe: the local
  generator must know `iw_enabled` and the hostapd binary must carry `hs20_conn_capab`
  (`CONFIG_HS20`). OpenWrt has the whole interworking option set, so "no equivalent" was
  wrong. Without the bit the controller drops a Passpoint WLAN outright
  (`ubntconf/LsyaJoEysWb`), so no `aaa.<n>.hs20.*` key is capturable at all.
- **`fw2_caps` `0x80000` (RadSec) is now claimed too, for a feature openUF does not have.**
  This is a trade, stated here as plainly as the win. The REST validator
  `com/ubnt/service/W/ctfbDsCjrxgkv` computes
  `supportsHotspot2Passpoint() = supportHotspot2() && supportsRadSec()` and rejects the
  WLAN with `api.err.DevicePasspointNotSupported` otherwise, where
  `supportsRadSec() = hasFirmware2Capability(524288)` reads the field **`fw2_caps`**
  (`com/ubnt/data/hyFnQ.getFirmware2Capabilities()`) — a third firmware mask openUF had
  never sent. Passpoint is therefore unreachable without claiming RadSec. What the claim
  changes on the wire is that a RadSec RADIUS server now arrives with its certificate
  *filenames*, which is the only thing that distinguishes it from a plaintext server;
  openUF drops such a server with a log instead of sending the shared secret in the clear.
  Before the claim it was indistinguishable, so the claim is the safer side of the trade —
  but openUF speaks no RADIUS-over-TLS, and a site that depends on RadSec will see its
  server dropped, not used.

- **`fw_caps` `0x40000` (`supportIPSet()`) stays unclaimed, and that is what makes the
  walled garden work.** It is not a missing capability but a choice of encoding: with the
  bit, `ubntconf/jNUeeSBEuWe` sends an `ipset.status=enabled` block of hash sets; without
  it, `VAZShipWTNxlo` sends the `dnsmasq.walled_garden.*` names and the `*/10` refresh
  job, which openUF implements as of 2026-10-26. Claiming it would swap a working form for
  one openUF does not implement. Settled from the jar; see
  [the walled garden](#the-walled-garden-two-forms-split-by-what-the-entry-looks-like).

- **Multicast Suppressor** (`wifi_caps2` `0x400000` → `wireless.<n>.multicast.suppressor`):
  could be enforced in nft like the Multicast/Broadcast Blocker, but it is the same feature
  class that breaks casting. Low priority.
- **No callers in the controller**, so a bit does nothing: `supportMinRateCtrl` (`wifi_caps`
  `0x200`), `supportMultiAclList` (`0x400`), `supportRadiusMacAuth` (`0x1000`),
  `supportHideChWidth` (`0x10000`), `supportZeroHandoff` (`0x2`), `supportLockAp`
  (`0x1000000`), `supportsRoamTopologyStats` (`wifi_caps2` `0x2000`).

The mesh bits (`wifi_caps` `0x1`/`0x800`) stay the subject of REVERSE-ENGINEERING.md's
mesh investigation and are only ever claimed through `debug_caps`.

#### The frontend's own names for the bits (Network app 10.6.106, `swai.*.js`, read 2026-10-03)

The React bundle carries both tables as constants, which fixes the names the decompile could
only infer. `wifi_caps`:

```
VWIRE 0x1 · ZERO_HANDOFF 0x2 · BANDSTEER 0x4 · BANDSTEER_PER_VAP 0x8 · RF_SCAN 0x10 ·
AIRTIME_CONFIG 0x20 · BGA_FILTER 0x40 · MESH 0x80 · MIN_RSSI_STRICT_MODE 0x100 ·
MULTIPLE_ACL_LIST 0x400 · MESHV3 0x800 · UNIFI_WIFI_CAP_RADIUS_MAC_AUTH 0x1000 ·
HIDE_CH_WIDTH 0x10000 · STA_ONLY 0x2000000 · LOW_PERFORMANCE_MODE 0x4000000 · RF_SCAN_6G 0x8000000
```

`wifi_caps2`:

```
MLO 0x1 · MONITOR_RF_SCAN 0x2 · GREEN_AP 0x4 · DFS_BACKGROUND_SCAN 0x8 · ROAMING_ASSISTANT 0x20 ·
QUICK_SCAN 0x80 · MESH_MLO_PARENT 0x4000 · MESH_MLO_CHILD 0x8000 · WIRELESS_UPLINK_ONLY 0x40000
```

The UI also treats a device as "wireless uplink only" when its model is a mesh/extender model
or `wifi_caps2` has `WIRELESS_UPLINK_ONLY`.

**The per-port VLAN validator** (`com.ubnt.ace.api.e.VVyiC`, reachable only once
`hasQCASwitch()` is true):

```java
private void chgwykfBxZCAuEHPPQ(UCthhvfQNZ port, boolean hasOWRTSwitch, boolean hasSwitchVlanCap8) {
    nwTNVfYOnNbEWSoCkPq.guoZiIiLhURleoJ(port).ifPresent(forwardMode -> {
        if (!((forwardMode != ALL && forwardMode != CUSTOMIZE) || hasOWRTSwitch)) {
            throw new QnvUxbsXyAJZ(VLAN_TAGGING_UNSUPPORTED, ...);
        }
        if (hasSwitchVlanCap8 && forwardMode NOT IN {CUSTOMIZE, NATIVE, DISABLED}) {
            throw new QnvUxbsXyAJZ(VLAN_TAGGING_UNSUPPORTED, ...);
        }
    });
}
```

For a port with no explicit `forward` override — the default `ALL` mode, true for every port
openUF sends — the first branch collapses to `!hasOWRTSwitch()`. Without bit `0x100`, **every
default-mode port is unconditionally rejected** with `api.err.VlanTaggingUnsupportedByDevice`,
before `vlan_caps` or anything port-specific is consulted. (Sweeping `switch_caps.vlan_caps`
through 0/3/4/5/6/7/15/31/255 only changed *which* of two near-identical errors fired.)
"OpenWrt switch" as opposed to a QCA hardware switch ASIC is, fittingly, exactly what this is.

### `radio_table[]` entry

| Field | Notes |
|---|---|
| `name` | UCI device name (`radio0`) |
| **`radio`** | **The band** (`ng`/`na`), from `band_for_channel()` — channels 1-14 → `ng`, else `na`. Parsed by `com.ubnt.g.f.e.rYtJfMBbtgWvku`'s `String.toLowerCase()` factory, which has **no null guard**: omitting this field throws an NPE inside the controller's adopt processing on *every* inform, corrupting its UI-facing device cache (Devices list shows "No UniFi Devices Have Been Adopted" while Mongo says adopted). 60 GHz/6 GHz aren't disambiguable from channel number alone and are unsupported. |
| `channel` | Live negotiated channel from `iw dev`, more authoritative than UCI's value (frequently the literal `"auto"`, which the controller will not resolve to a number) |
| **`ht`**, **`tx_power`** | Not `htmode`/`txpower` |
| `disabled`, `builtin_antenna`, `builtin_ant_gain`, `max_txpower` | |
| `nss`, `is_11ac`, `is_11ax`, `is_11be`, `has_dfs`, `has_fccdfs`, `has_ht160`, `has_eht240`, `has_eht320` | Read directly off each entry by `PGOcbDWlbnYQdFW`'s `copyAttrsIfPresent`, **independent of `radio_caps`**. Derived by `sysinfo.radio_caps()` from `iw phy phyN info`. |
| **`radio_caps`** | A separate **integer bitmask**, not `nss`. See below. |
| `min_rssi`, `min_rssi_enabled` | `min_rssi` is **dBm** on the wire (converted from the raw `stamgr` units with the fixed `raw - 95` offset, see the `stamgr` section) |
| **`athstats`** | Nested `{cu_total, cu_self_rx, cu_self_tx, cu_interf}`. See below. |

**An empty `radio_table` blocks a large amount of downstream behavior.** The controller checks
`if (list3.isEmpty()) { … "Missing radio_table in inform…" }` and this is exactly the
"no radio found" condition that suppresses WLAN provisioning. Real OpenWrt hardware has genuine
`wifi-device` sections populated by the driver at boot, independent of any configured SSID.

**`radio_caps` MIMO bits.** The controller's Java side only ever passes this int through
verbatim (`uCthhvfQNZ2.put("radio_caps", uCthhvfQNZ3.getInt("radio_caps", 0))`); the decode into
`"1x1"`…`"4x4"` happens **client-side only**, in the Radios tab's `mimo: e7(radio.radio_caps)`.
Reverse-engineered by calling the live `e7` decoder through the webpack module registry with a
single-bit sweep:

| `nss` | bit |
|---|---|
| 1 | `0x8` |
| 2 | `0x10` |
| 3 | `0x20` |
| 4 | `0x4000000` |

Checked highest-first when multiple bits are set. It is **not** simply `radio_caps == nss`
(live-tested and refuted). Left at the default `0`, the MIMO column is blank *and* the
1x1–4x4 filter checkboxes exclude the radio outright rather than merely filtering it wrong.

**`athstats` is required for the "Avg. Interference"/"Avg. Airtime" columns.** The archiver
method `com.ubnt.service.system.x.htDMji` iterates `radio_table` — not `radio_table_stats`, not
`vap_table` — and:

```java
if (!uCthhvfQNZ.containsField("athstats")) continue;
```

then reads `cu_total`/`cu_self_rx`/`cu_self_tx`/`satisfaction`/`cu_interf` off that nested
sub-object. Sending the same four fields on `radio_table_stats` and `vap_table` (both real, both
used by other paths) leaves every archived bucket without them. Named after the legacy Atheros
`ath9k`/`ath10k` stats struct UniFi firmware historically exposed under this name.

### `radio_table_stats[]` entry

Parallel to `radio_table` — the real controller's own split of static config vs. live stats.

`name`, `channel`, `cu_total`, **`cu_self_rx`**, **`cu_self_tx`** (two separate fields, not one
combined `cu_self`), `cu_interf`, plus `spectrum_table` / `spectrum_table_time` when a
`spectrum-scan` cmd has populated `M._spectrum_cache`.

All `cu_*` are percentages derived from `iw dev <ifname> survey dump`;
`cu_interf = max(0, cu_total − cu_self_rx − cu_self_tx)` — airtime busy for reasons other than
this radio's own tx/rx.

> **`iw` survey field names.** The real binary prints `channel active time:`,
> `channel busy time:`, `channel receive time:`, `channel transmit time:` — *not*
> `channel time:`/`channel time busy:`/etc. Patterns must be anchored to line start so
> `channel busy time:` doesn't also match inside `extension channel busy time:`, which `iw`
> emits on wider channels.

> **The operating channel's entry is not first — pick it by `[in use]`.** `survey dump`
> emits one entry per channel the phy supports, in the phy's own frequency order, so the
> operating channel sits wherever it falls: measured live on 2026-08-02, entry **11 of 13**
> for a 2.4GHz radio on ch11 and **3 of 24** for a 5GHz radio on ch44. Every other entry is
> a scan dwell carrying only a few milliseconds of accumulated time (3–146 ms observed).
> Deriving `cu_*` from `stats[1]` therefore divided a busy figure by a ~3 ms active time and
> reported a genuinely 24%-busy 2.4GHz channel to the controller as **100%**, and a 1.9%-busy
> 5GHz channel as **75%** — which is what made both APs look like they were drowning in
> interference. The same wrong entry also fed the noise floor Minimum RSSI was, at the time,
> (wrongly) converted with. Fixed by flagging `in_use` in `sysinfo.radio_stats()` and selecting it in
> `inform.lua`'s `_in_use_survey()`; the test fixture now mirrors the real ordering, and
> reverting the selection fails 4 tests.

`spectrum_table[]` entries carry `channel`, `center_freq`, `width`, `utilization`,
`interference` (field names recovered from two independent Lombok DTO constant pools).
`channel`/`center_freq`/`utilization` come mechanically from survey dump; `width` and
`interference` are best-effort — see [best-effort fields](#best-effort-and-unverified-fields).

### `vap_table[]` entry

| Field | Notes |
|---|---|
| `name` | UCI section name |
| **`essid`** | Not `ssid` |
| **`id`** and **`wlanconf_id`** | Both carry the wlanconf ObjectId from `aaa.<n>.id`. **Mandatory.** See below. |
| **`radio`** | The **band** (`ng`/`na`), same enum as `radio_table`. Sending `radio0` here logs `WARN stat - unexpected radio[radio0] while processing stats` on every inform and silently drops that vap's stats aggregation. |
| **`radio_name`** | The UCI device name (`radio0`) — a separate, real field on the same DTO. This is what `get_ifname_for_radio()` needs. |
| `encryption`, `disabled`, `bssid`, `channel`, `tx_power`, `usage` | `usage` is `"user"` |
| `num_sta` | Coexists with the nested `sta_table` on the real DTO |
| `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets`, `tx_retries`, `tx_dropped` | The UI's "Air Stats" panel. `iw` exposes these only per-station, so they're summed across connected stations while building `sta_table`. `rx_dropped`/`rx_errors`/`tx_errors`/`satisfaction` have no source in `iw` output at all — left unset rather than invented (802.11 ARQ retry/failure counters are inherently TX-side only). |
| `avg_client_signal` | Mean `signal` of associated clients, dBm. Omitted entirely when the VAP has no clients. |
| `cu_total`, `cu_self_rx`, `cu_self_tx`, `cu_interf` | Mirrored from the radio |
| `sta_table[]` | Nested — see below |

**`id` is mandatory or the entire VAP is discarded.** `com.ubnt.service.devmgr.c.KHUkYjHujLgFBD`
(vapInformProcessor) filters the raw `vap_table` *before* any per-station processing runs. For a
`usage=user` VAP it requires a non-`"unknown"` `id`, then re-looks it up via
`configCache.get(siteId, id)` to attach `wlanconf_id`/`ap_mac`/`site_id`/`is_guest`/`is_wep`.
A missing `id` is checked with `!"unknown".equals(id)` and drops the VAP **silently** —
no log line, no error, taking the nested `sta_table` and every wireless client with it.
The `"Inconsistent vap"`/`"Invalid id"` warn paths only fire on an actual lookup *failure*.

**"Air Stats" needs growing counters, not just non-zero ones.** The widget renders a
rate/delta between informs. Static counters produce a zero delta even when the absolute value
is correct — which is why `iw-mock.sh`'s fake counters must increase monotonically.

### `sta_table[]` entry (nested inside each `vap_table` entry)

Nested, **not** a flat top-level `user_table`.

| Field | Notes |
|---|---|
| `active`, `mac`, `ap_mac`, `channel`, `radio` | `active` is always `true` — an entry only exists while `iw station dump` lists the station |
| `signal`, `rssi` | Both the same value; `iw` exposes no separately-measured RSSI |
| `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets` | **Raw cumulative counters.** The vapInformProcessor computes its own `tx_bytes-d`/`rx_bytes-d`/`bytes-d`/`bytes-r` deltas server-side keyed by `time_delta` — never send a pre-computed rate here. |
| `tx_rate`, `rx_rate` | **Kbps** (`iw` reports Mbit/s, so ×1000) |
| `uptime`, `idletime` | `iw`'s "connected time" / "inactive time", both in seconds |
| **`tx_mcs`**, `rx_mcs` | Not `tx_mcs_index` (that name is only the ucore-message JSON name for a different internal event). Absent for legacy pre-11n rates. |
| `nss` | Read directly by the controller, no derivation |
| `radio_proto` | Read only by the **disconnect-time** archive path (`TtZhv`) |
| **`is_11n`, `is_11ac`, `is_11ax`, `is_11be`** | What the **live** display actually uses — see below |
| `wifi_tx_attempts`, `wifi_tx_retries_percentage` | `attempts = tx_packets + tx_retries` |
| `satisfaction`, `satisfaction_now` | Best-effort estimate — see below |
| `capacity`, `throughput`, `linkscore`, `multicast` | Best-effort / placeholders — see below |
| `name` | Omitted — controller/admin-assigned, no local source |

The attribute list `KHUkYjHujLgFBD` copies verbatim off each incoming entry is exactly:
`"channel", "radio", "name", "signal", "rssi", "tx_rate", "rx_rate", "tx_packets",
"rx_packets", "tx_bytes", "rx_bytes"`.

**Why the `is_11*` booleans matter more than `radio_proto`.** The live, still-connected client
display is computed by `com.ubnt.service.devmgr.HCKpgcBFPLu` → `com.ubnt.g.s.jRsSex`, which
**ignores the `radio_proto` string entirely**:

```java
private static jRsSex lhPagEPcc(UCthhvfQNZ uCthhvfQNZ) {  // 2.4GHz (ng) path
    if (uCthhvfQNZ.is("is_11be", false)) return BE;
    if (uCthhvfQNZ.is("is_11ax", false)) return AX;
    if (uCthhvfQNZ.is("is_11n",  false)) return NG;
    if (uCthhvfQNZ.is("is_11b",  false)) return B;
    return G;   // fallthrough when none are set
}
```

Sending only `radio_proto` leaves every live client showing `"g"` (2.4 GHz) or `"a"` (5 GHz),
while `nss` — read directly, no derivation — works immediately. Both must be sent.

**Generation/NSS derivation** from `iw`'s own bitrate line tokens (format strings confirmed via
`strings /usr/sbin/iw`):

| Token | Generation | NSS |
|---|---|---|
| bare `MCS N` | `n` | `floor(N/8)+1` (HT MCS layout: 0-7 = 1 stream, 8-15 = 2, …) |
| `VHT-MCS` / `VHT-NSS` | `ac` | read directly |
| `HE-MCS` / `HE-NSS` | `ax` | read directly |
| `EHT-MCS` / `EHT-NSS` | `be` | read directly |
| none (legacy) | falls back to the band: `a` on `na`, `g` on `ng` | 1 |

Never `b` — real dual-band 11n+ hardware doesn't negotiate down to 802.11b-only rates.

**`satisfaction` is a device-computed field.** The controller's `wifi_experience_score` is a
straight passthrough — `com.ubnt.service.l.e.AcrQJeJCScLn`:
`wifi_experience_score = doc.getOptionalInt("satisfaction")`. The wireless-client model
(`com.ubnt.service.l.e.AQODNNoMmBlFpWXX`) reads `satisfaction`, `satisfaction_now`,
`satisfaction_real`, `satisfaction_reason`, `wifi_tx_attempts`, `wifi_tx_retries_percentage`,
`tx_mcs`, `ccq`, `noise`, `nss` as **plain data**; the controller computes nothing itself beyond
a running `satisfaction_avg` accumulator. Real AP firmware computes it on-device with a
proprietary formula. Sending nothing renders as "No Experience", correctly.

### `port_table[]` entry

Processed only when `Device.isSwitch()` is true for the reported model —
`hasFeature(UiHQyVmgX) || hasFeature(yojQKHv)`. The model registry
(`com.ubnt.data.dhdeXcHqLRBKMUZk`) registers `U6IW` as device type `uap` with **5 ethernet
ports** and the switch feature, matching reality (a U6-InWall has a built-in 4-port downstream
switch). A plain AP like `U6MP` is not a switch. So for the model openUF impersonates, this is
not optional: an empty `port_table` means zero wired clients can ever appear.

One entry per `cfg.net.ports`. Each entry carries `port_idx` (1-based), `name`, `media`,
`up`, `enable`, `speed`, `full_duplex`, `is_uplink`, `speed_caps`, `port_poe`, `poe_caps`
and `rx_bytes`/`tx_bytes`/`rx_packets`/`tx_packets`/`rx_errors`/`tx_errors`. Where those
facts come from depends on what the board can be asked:

**Per-socket (swconfig board, modelmap field `{idx, swport}`).** One entry per physical
socket. `up`/`speed`/`full_duplex`/`pvid` and the ARL table come from a single
`swconfig dev <sw> show` (`sysinfo.switch_status`), and `is_uplink` is set on the socket the
default gateway's MAC was learned on (`sysinfo.uplink_phys_port`) — detected, never declared,
because on an AP the cable is in whichever LAN socket the installer used. Counters are the
switch's own per-port MIB (`RxGoodByte`/`TxByte`; there are no per-port packet or error
counts, and an AR8327 with `ar8xxx_mib_poll_interval: 0` has no MIB at all), falling back on
the uplink entry only to the CPU netdev's `sysinfo.interfaces()` counters — everything the
CPU sent or received crossed that socket. Other sockets report `0` rather than a fabricated
share of the same total.

The two shapes mix within one board, per port: an entry with no `swport` falls through to
the netdev source below even when the switch answered. That is not a fallback but the right
answer for a socket wired to its own MAC and PHY rather than to the switch — the
TL-WDR3500's WAN socket is a second `ag71xx` surfacing as `eth1`, so sysfs there describes
that socket and not the CPU's link.

**Netdev (no switch, no swconfig, or no identifiable uplink — modelmap field
`{idx, ifname, uplink}`, defaulting to `{wan_cpueth=uplink, lan_cpueth=lan}`).** `up` from
sysfs `carrier`/`operstate`, `speed`/`full_duplex` from sysfs, counters from
`sysinfo.interfaces()`, `is_uplink` from the modelmap. On a swconfig board every one of
those describes the *CPU port* — the internal SoC↔switch link, always 1000/full — which is
why this is the fallback and not the default. Confirmed live: a TL-WDR3500 reported GbE on
an uplink whose socket had negotiated 100baseT, and the gateway's own Ports view said FE for
the same cable.

**Non-uplink ports additionally carry `mac_table[]`** — `{mac, ip, hostname, age, uptime,
vlan}`, where `vlan` is present only for a socket openUF has assigned to a VLAN and is what
places the client on the right *network* (the controller keeps a host only where
`network.getVlan() == host.getInt("vlan", 1)`; absent means 1 — see the 2026-09-13 section),
joined with `/proc/net/arp` for IPs and `/tmp/dhcp.leases` when present for hostnames
(optional — an AP is usually not the DHCP server; `hostname` stays absent rather than
invented). The host list itself is per-socket from the ARL table
(`sysinfo.switch_mac_table`, multicast/broadcast MACs filtered on the address bit), or
`sysinfo.mac_table(ifname)` off `bridge fdb show dev <ifname>` on the netdev path (dynamic
`master br-lan` entries only; `self`/`permanent` and multicast/broadcast filtered).
`bridge fdb` can only ever say "behind the CPU port", so on a switch board it cannot place a
host on a socket — that is what the ARL adds. Sockets whose `pvid` is not the management
VLAN carry no `mac_table` either: the Archer C5's WAN socket is live and has learned a host,
but it sits on VLAN 2 with its CPU port down, so that host is not on the LAN it would be
listed in.

Ports flagged `is_uplink: true` are skipped by the controller for client creation, since that
port faces the controller's own network.

**An uplink port must carry no `mac_table` at all — not even the gateway.** Reporting just
the one MAC on the other end of the cable is tempting: openUF knows it (finding it is how the
uplink socket is identified), a real UniFi gateway visibly does it on its own uplink port, and
it would fill the Ports view's Connection column, which is otherwise blank or stuck on a
retained "last seen device". It would also invert the topology map. The controller matches
every MAC on a port against its adopted devices, and a port carrying exactly one known device
files that device into this one's `downlink_table` (`wRSpUfdrmMXnppHBKZ`):

```java
bl9 = !is_uplink && device.isUplinkMac(neighbour);
if (!bl9) downlink_table.add(neighbour, port);
```

The `isUplinkMac` guard that would prevent it is ANDed with `!is_uplink`, so it disables
itself on exactly the port where it is needed — the gateway would hang beneath every AP that
reported it. A real gateway escapes this because its upstream is the ISP's router, which is
not an adopted device and never reaches that branch; openUF cannot tell the two cases apart
from the device. Upstream verified it on their live site: with both APs silent on their
uplinks, each AP's `downlink_table` is empty and the gateway's holds both APs, which is the
correct shape.

A blank Connection column on an uplink port is therefore intended. `last_connection` is only
recomputed when a port reports exactly one MAC (`wefewPevorbc`: `if (list.size() > 1) return
existing`), and is never touched at all when the port sends no `mac_table` field — which is
why a stale value there persists until cleared with the Ports view's **Clear Last Seen
Device**.

Two exclusion filters prevent double-reporting: the device's **own** MACs, and any MAC
currently associated as a wireless station — a wireless client bridged into `br-lan` genuinely
appears in the bridge FDB too.

**Wired hosts will never show per-client traffic**, by design. `TtZhv` reads only
`mac`/`ip`/`hostname`/`age`/`uptime` off each `mac_table` entry; there is no per-client byte
counter anywhere in the wired-client wire protocol. A wired client's traffic is attributed via
its switch port's own counters.

### `scan_radio_table[]` entry

Backs Insights → AirView → **Environment** (`GET /api/s/default/stat/rogueap`). Built from
`iw dev <ifname> scan dump` — the kernel's already-cached BSS list, cheap and non-disruptive,
unlike the `spectrum-scan` cmd's real scan trigger.

Nested shape (confirmed against `PGOcbDWlbnYQdFW`, which reads a top-level `scan_radio_table`
array and hands each entry's nested `scan_table` to the ingestion service — not a flat list):

```
scan_radio_table[] = { radio, name, scan_table[] }
```

Per `scan_table[]` entry — the consumer DTO `com.ubnt.service.aO.bLwwMKkr` (literally named
`"PeerScan"` in its own builder's `toString`) confirms the full field list:

| Field | Notes |
|---|---|
| `mac`, `bssid`, `essid`, `channel`, `freq`, `signal`, `rssi`, `security` | |
| `radio`, `radio_name` | |
| **`band`** | A field **distinct from `radio`** but taking the identical enum values. The Environment tab's list selector applies an *unconditional* filter upstream of every visible sidebar filter: `A.filter(A=>!!T.R?.[A?.band]?.[A?.bw>0?A.bw:m.L?.[A?.band]])`. `T.R[undefined]` is `undefined`, so an entry without `band` fails silently for every row — indistinguishable from "no data", regardless of filter state. |
| **`bw`** | Channel width MHz. The "Ch. Width" cell reads it directly and renders nothing when falsy: `renderCell:({bw:A})=>A?…:null`. Parsed from `iw`'s `BSS operating channel width: N MHz` (only present for HE/VHT-capable neighbours), defaulting to `20` — legacy-safe and valid on both bands. |
| **`age`** | **Elapsed seconds, not an absolute timestamp.** The ingestion code reads `getInt("age")` and computes `last_seen = report_time − age` itself; it also **silently drops any entry with `age >= 30`** as a staleness guard. Sending an absolute timestamp under either key yields an empty result with no error. Parsed from `iw`'s `last seen: N ms ago`. |

`is_rogue` is much narrower than the tab name suggests: set true only when a neighbouring BSSID
broadcasts the **same essid as one of the site's own configured networks** (an evil-twin check
raising `EVT_AP_DetectRogueAP`). Ordinary neighbours correctly have `is_rogue: false` and still
appear in the Environment list.

### `lldp_table[]` entry

Field names from the real DTO (`OXMua`): `chassis_descr`, `chassis_id`, `local_port_name`,
`local_port_idx`, `is_wired`, `port_id`, `port_descr`.

- `chassis_descr` comes from `chassis.descr`, **not** `chassis.name` — System Description and
  System Name are different LLDP TLVs.
- `local_port_idx` is read from `/sys/class/net/<port>/ifindex` — this is *our own* local
  interface, not something lldpctl reports about the neighbour, so it is a local sysfs lookup
  rather than a protocol field. Omitted when unavailable.
- `is_wired` is unconditionally `true` — LLDP is inherently a wired-link protocol.

### Best-effort and unverified fields

These are explicitly approximations, flagged as such in the code. Listed here so nobody mistakes
them for measured values.

| Field | Status |
|---|---|
| `sta_table[].capacity` | Negotiated `tx_bitrate` (Mbps, floored) as a proxy for "available bandwidth to this client" |
| `sta_table[].throughput` | Delta-sampled byte rate (bytes/sec); `0` on first sample for a given MAC |
| `sta_table[].linkscore`, `.multicast` | `0` placeholders — **no local source and no public reference found for either.** Neither `paultyng/go-unifi`'s `User` model nor `unpoller/unifi`'s `clients.go` has them at all. Still needs live-capture verification. |
| `sta_table[].satisfaction` | `estimate_satisfaction()`, reworked from upstream 2026-09-28: the worst of three terms, following the uplink/downlink/coverage split of commercial controllers (Aruba/Aerohive client health = ideal ÷ actual airtime; Mist coverage and throughput SLEs; Meraki/Cisco SNR thresholds). **Downlink** = the airtime this client's frames would take (a per-frame cost of 110 µs on 2.4 GHz or 250 µs on 5 GHz, plus the payload at its ceiling rate) ÷ the `tx duration` they actually took, one window per ≥ 20 frames, capped at 100. The 5 GHz figure was measured 2026-10-03 on AP1: a −43 dBm HE80 2×2 MacBook at MCS 11 with 2.6 % retries spent 266 µs per unaggregated 782-byte frame (mt76's `tx duration` counts preamble, BlockAck and the RTS/CTS the driver adds on wide channels) and scored 49 "Poor" under the 2.4 GHz figure while the iPhone beside it, aggregating ~30 frames a PPDU at 38 µs each, scored 97; the realme with a genuinely bad 2.4 GHz link (MCS 4, 32 % retries, 454 µs per 1.2 kB frame) stays Poor under the 2.4 GHz figure. The ceiling is the stream count, width and top MCS the client associated with (`hostapd_cli all_sta`: `ht_mcs_bitmask`, `rx_vht_mcs_map`, `ht_caps_info`/`vht_caps_info` width bits, `[HE]` flag), capped by the AP's own streams and live channel width, one MCS below the top. Until a first airtime window, or on a driver without `tx duration`, the tx rate ÷ that ceiling stands in. **Uplink** = 50 + half the rx rate ÷ the same ceiling, only in an inform in which the client sent ≥ 20 frames (`rx bitrate` is the last frame's rate). **Coverage** = SNR against the radio's in-use survey noise (floored at −95 dBm: ath9k/ath10k report −107/−106), 5 dB → 0, 20 dB → 90, 25 dB → 100. Each term is smoothed (EWMA α 0.2). The constants are upstream's judgements, not UniFi calibration. Upstream's evidence (AX3000T, mt76, 2026-09-27): a −71 dBm dishwasher holding MCS 7 with 89 % failed attempts, 7.8 % ping loss and 503 µs of airtime per 97-byte frame scored 24 where signal-vs-retries gave 93; retry/failed counters were dropped because mt76's `tx failed` counts failed attempts (can exceed packets), ath9k's `tx retries` counts every attempt and ath10k never reports `tx failed`. ⚠️ Unconfirmed: whether ath10k firmware counts retries in `tx duration`, HE ceilings (MCS 0–11 assumed), and any of it on the JioRouter boards. Before 2026-09-28 the score was the worse of a signal score (−85 → 0, −50 → 100) and `100 − retries%`. `wifi_tx_attempts`/`wifi_tx_retries_percentage` stay the lifetime iw values. |
| `spectrum_table[].width` | The radio's configured `htmode` (e.g. `HT40` → 40) as a uniform approximation — no live-scan source gives per-channel width |
| `spectrum_table[].interference` | Noise-floor dBm passed through; `iw survey dump` has no interference metric of its own. Falls back to the pre-sweep reading for any frequency whose post-scan noise comes back `0` (see [the first real-hardware run](#the-first-real-hardware-run)) |
| `radio_table[].builtin_antenna` = `true`, `.builtin_ant_gain` = `3` (dBi) | **Constants — no software source exists for either.** Not inert: the controller adds the gain to TX power to display EIRP, so a board with different antennas reports a wrong EIRP. Change them in `ucihelper.RADIO_DEFAULTS` if your hardware differs. |
| `radio_caps().has_fccdfs` | Mirrors `has_dfs`; `iw` exposes no separate FCC-DFS indication |
| `radio_caps().has_eht240` / `.has_eht320` | Hardcoded `false` — openUF has no 802.11be target hardware to derive them from |
| `port_table[].media` = `"GE"`, `.enable` = `true`, `.speed_caps` = `0`, `.port_poe` = `false`, `.poe_caps` = `0` | Constants. The PoE ones are honest for every target board (none source PoE); `media`/`speed_caps` are unmodelled. `speed`/`full_duplex`/`up` **are** measured — per physical socket via swconfig where the board has a switch, else from sysfs |
| `port_table[].rx_packets`/`tx_packets`/`rx_errors`/`tx_errors` on a per-socket entry | `0`. swconfig's per-port MIB exposes byte counters only (`RxGoodByte`/`TxByte`), and the CPU netdev's packet/error totals belong to every socket at once. A downstream socket's `rx_bytes`/`tx_bytes` are likewise `0` on a driver with no MIB (AR8327 with polling off) rather than a share of the CPU total |
| `serial` | Derived from the device MAC with the colons stripped — a real AP's serial is a separate factory value openUF has no equivalent of |
| `spectrum_scanning` = `false` | Always false: scans are run synchronously inside the cmd handler, so the device is never "currently scanning" when a payload is built |
| `lldp_table[].is_wired` = `true` | LLDP is inherently a wired-link protocol |
| `model` / `platform` / `version` / `required_version` / `bootrom_version` | The emulated UniFi identity from `ufmodel/*.lua` — deliberately not the host hardware. This is the point of the project, not an accidental approximation |
| `fw_caps` = `0x110`, `wifi_caps` = `0x1C`(+`0x20`/`0x100000`/`0x801` by probe), `wifi_caps2` = `0xE2` | Claimed capability bits, each derived from the controller's own bytecode and confirmed live — see [Capability bitmasks](#capability-bitmasks). openUF claims only bits whose features it actually implements |
| `ucihelper` `wps_device_name` / `ap_setup_locked` | Standards-based rather than Ubiquiti-derived — see the beacon row in the [feature matrix](#feature-matrix) |
| ~~`usteer.lua`'s `USTEER_DEFAULTS`~~ | ✅ **Resolved upstream 2026-09-10.** Verified against the installed package (usteer 2025.10.04) on an Archer C5. `band_steering_threshold` is a real option — it is in the init script's own list of keys fed to `ubus call usteer set_config`. The named `local` section is read too: the loader does `config_foreach uci_usteer usteer`, which visits every section of type `usteer`, named or anonymous. `network` is read from `uci get usteer.@usteer[-1].network`, the last section of that type — openUF's — so both writes are load-bearing and correctly named. |

Everything not listed above is measured from the running system. Several fields
*used* to belong in this table and no longer do — `max_txpower`, `tx_power`,
`nss`, per-client `signal`, `hostname`, and `port_table[].speed`/`full_duplex`
were all constants or misparsed values until the first real-hardware run
surfaced them; they are now read from `iw`, sysfs and `/proc`.

### WPA3 was silently downgraded to WPA2 — the radio must claim the SAE bit — FIXED

Before `radio_caps2` was sent (see below), a WLAN set to **WPA2/WPA3** in the UI
reached openUF as plain WPA2, and nothing anywhere said so. The captured
`system_cfg` contained no `sae`, no `wpa3`, just:

```
aaa.1.wpa=2
aaa.1.wpa.key.1.mgmt=WPA-PSK
aaa.1.pmf.status=enabled     aaa.1.pmf.mode=1
```

openUF applies that faithfully, so hostapd runs
`wpa_key_mgmt=WPA-PSK FT-PSK WPA-PSK-SHA256` and every client — WPA3-capable
ones included — associates with AKM `00-0f-ac-2`/`-4`/`-6`. Never `00-0f-ac-8`
(SAE).

This is **not** the controller's WLAN being misconfigured. Its REST API confirms
the wlanconf really does carry `wpa3_support: true`, `wpa3_transition: true`.
The downgrade is per device, in `com.ubnt.service.config.ubntconf.QSAkfnbfInKJ`:

```java
if (wlanconf.isWpa3()) {                      // wlanconf field wpa3_support
    if (!radio.CVir()) {                      // radio lacks the SAE capability
        if (wlanconf.isWpa3LegacyEnabled())   // wlanconf field wpa3_transition
            return downgrade(wlanconf, radio);          // ← silent WPA2
        log.warn("SAE cannot provision {} to {}", name, mac);
        return null;                                     // WLAN dropped entirely
    }
```

So a **transition-mode** WLAN degrades quietly, while a **WPA3-only** WLAN would
be dropped from the device altogether with that one server-side log line.

`CVir()` tests **bit `0x1` of `radio_caps2`** — see the next section for the
field-level trace. openUF used to send `radio_caps` (the MIMO column:
`0x8`/`0x10`/`0x20`/`0x4000000` for 1x1…4x4) and **no `radio_caps2` at all**, so
the bit was clear and every WPA3 WLAN was downgraded on every openUF device.
That is fixed: `radio_caps2 = 0x1` now ships on each SAE-capable radio -- `0x3` since
2026-09-28, bit `0x2` being what keeps 802.11r on a WPA3-only WLAN, plus `0x8` where hostapd
has OWE (see [Capability bitmasks](#capability-bitmasks)).

The emission side is gated separately, on the WLAN alone
(`com.ubnt.service.config.j.rYtJfMBbtgWvku`: `isWpa3() || band == 6E`), and
produces `wpa3.support=enabled` + `wpa3.transition=enabled|disabled` — the keys
openUF's `_parse_wifi_system_cfg` would need to read, since **SAE never arrives
as a `wpa.key.<n>.mgmt` value**. `SECURITY_MAP`'s `wpa3` → `sae` and
`wpa2/wpa3` → `sae-mixed` entries were unreachable for exactly as long as the
capability bit was missing; both are now exercised on real hardware. (An earlier note in this document read the
PMF keys as the controller's way of signalling WPA3-mixed for a madwifi-driver
model. That was wrong — PMF is just PMF, and the real signal is these two keys.)

### The capability is `radio_caps2` bit `0x1` — RESOLVED

`CVir()` is a bit test, and tracing which field backs it settles the whole
question. The chain, all from the 10.4.57 bytecode:

```
config gen (QSAkfnbfInKJ)   calls radio.CVir()
CVir()                      = (1 & ZPjpXpgFhJSgqk().orElse(0)) == 1
ZPjpXpgFhJSgqk()            -> impl field iBjnA          (com.ubnt.g.f.e.jRsSex)
iBjnA                       <- builder field SuUD
SuUD                        <- setter rMxwXnPhhdotvjERKoA(int)
that setter is called with  getInt("radio_caps2")        ← the wire field
```

`radio_caps` lands somewhere else entirely — builder `kJeOrfqt` → impl
`DbisCuTqoItCGd` → accessor `FJaWnIAautY()`, which is the MIMO column and
nothing more. **The two capability integers are not interchangeable, and the one
that gates WPA3 is the one openUF never sent.** It arrived as `0` on every
inform (the parser's `getInt` default), `0` fails the bit test, and so every
WPA3 WLAN was silently downgraded on every openUF device.

**Confirmed live end-to-end, 2026-08-01, real hardware.** Sending
`radio_caps2 = 0x1` (gated on `sysinfo.sae_supported()`) flipped the very next
config push:

```
aaa.1.wpa.key.1.mgmt=SAE          (was WPA-PSK)
aaa.1.wpa3.support=enabled
aaa.1.wpa3.transition=enabled
aaa.1.wpa3.ft.status=disabled
aaa.1.sae.anti_clogging=5   aaa.1.sae.sync=5
```

and both APs came up controller-driven, no manual step:

```
UCI:     encryption='sae-mixed'  ieee80211w='1'  ieee80211r='1'
         sae_sync='5'  sae_anti_clogging_threshold='5'
hostapd: wpa_key_mgmt = SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK
```

Note the push also carries `wpa3.ft.status=disabled` alongside `ft.status=enabled`
— the exact disagreement case described in the [`aaa.<n>` table](#aaan--per-ssid-security-and-behavior).

#### What was wrong before, and why

Three earlier claims in this document are now retracted:

1. *"`wpa3_supported` is the gate."* It is not read at all — see below.
2. *"`radio_caps`/`radio_caps2` bit `0x1` were both set live with no effect."*
   The conclusion was wrong. Whatever that experiment actually set, sending
   `radio_caps2 = 0x1` from the radio-table builder works reproducibly on both
   APs. Suspected cause: the config was never regenerated, so no push followed
   — a device-state change alone does not trigger one. Clearing the stored
   `cfgversion` and restarting forces a full push, which is how this was tested.
3. *"The capability comes from the controller's model registry, so no payload
   field can unlock WPA3."* The model registry exists —
   `getModel().radiosByBand().getOrDefault(band, EMPTY_DEVICE_MODEL_RADIO)`,
   with the U6-InWall's entry mapping `BAND_NA→2400`, `BAND_NG→570` — but it
   returns `com.ubnt.g.f.VVyiC`, a **different type** from the device radio DTO
   `com.ubnt.g.f.e.VVyiC` that `CVir()` is invoked on. It is not on this path.
   Checking the receiver type is what broke the deadlock.

`wpa3_supported` genuinely is inert, and that part stands: the only class
carrying the literal (`com.ubnt.net.k.aI.jRsSex`, a record of `wpa3Supported` /
`band6GHzSupported` / `oweSupported`) is **constructed, never parsed** — built
from an injected `com.ubnt.service.wifi` service, ignoring the device parameter
— and reading the persisted device back confirms it: `radio_caps` round-trips
verbatim while `wpa3_supported` and `owe_supported` come back `undefined`.
openUF still sends it, because it is truthful and another version may read it,
but it unlocks nothing.

### What a transition-mode push looks like

Reconstructed from the emitters rather than captured, since no openUF device can
provoke one. Two classes produce it — `com.ubnt.service.config.eWivisHeQsnaqDtx`
for the WLAN block (prefix recipe `aaa.`, so keys are `aaa.<idx>.…`) and
`com.ubnt.service.config.ubntconf.OXMua` for the SAE sub-block — both behind the
same gate, `com.ubnt.service.config.j.rYtJfMBbtgWvku`:
**`isWpa3() || radioBand == 6E`** (that second clause is why 6 GHz always gets
WPA3). The key-mgmt method in full:

```java
String mgmt = "WPA-PSK";
if (gate(wlan)) {
    mgmt = "SAE";                       // replaces — never appended
    OXMua.emit(sb, wlan, "aaa." + i);   // the sae.* / wpa3.ft.status block
}
emit("aaa." + i, "wpa.key.1.mgmt", mgmt, "wpa.psk", wlan.getWpaPreSharedKey());
```

For a WPA2/WPA3 WLAN with PMF Optional and 802.11r on, that yields:

```
aaa.1.wpa=2                       # stays 2 — WPA3 never makes this 3
aaa.1.wpa.1.pairwise=CCMP         # the legacy flag is inverted under WPA3, so never "TKIP CCMP"
aaa.1.wpa.key.1.mgmt=SAE          # replaces WPA-PSK; both never appear together
aaa.1.wpa.psk=<psk>
aaa.1.wpa3.support=enabled
aaa.1.wpa3.transition=enabled     # "disabled" here means WPA3-only
aaa.1.wpa3.ft.status=enabled
aaa.1.pmf.status=enabled  aaa.1.pmf.mode=1  aaa.1.pmf.cipher=<cipher>
aaa.1.ft.status=enabled
```

plus, only when the site actually sets them: `sae.anti_clogging` / `sae.sync`
(each when > 0), `sae.groups.<n>.group` with `sae.has_groups=enabled` (from
`sae_groups`), `sae.psk.<n>.psk`/`.mac`/`.id`/`.vlan` (SAE private PSKs), and
`wpa3.enhanced_192=enabled` for EAP with Enhanced 192-bit.

**The structural trap:** `SAE` *replaces* `WPA-PSK` — the wire never carries
both, so the AKM set alone cannot distinguish transition mode from WPA3-only.
Only `wpa3.transition` does. Reading the AKM by itself provisions a mixed WLAN
as pure WPA3 and locks out every WPA2 client.

### The device side works — verified end-to-end

With the capability bit in place the controller sends transition mode of its own
accord, and openUF provisions it correctly on real hardware:

```
UCI:     encryption='sae-mixed'
hostapd: wpa_key_mgmt = SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK
         sae_require_mfp=1  sae_pwe=2  sae_groups=19 20 21
```

Live clients then split exactly as transition mode intends — a Pixel 9
negotiated `00-0f-ac-9` (FT-SAE) while older devices stayed on `00-0f-ac-2`
(WPA2-PSK) on the same SSID.

`wpad-mbedtls`, OpenWrt 25.12's ath79 default, does support SAE
(`sae_password`, `sae_groups`, `psk-sae` in `ap.uc`), so claiming it is honest
on that hardware.

### Fixtures must be verbatim command output

Three of the bugs found on real hardware were invisible to a green test suite
because the fixtures under `tests/fixtures/` were *tidier than reality*:

- `iw_station_dump.txt` had no `avg ack signal:` lines, so nothing caught an
  unanchored `signal:` pattern matching them and reporting every client at the
  ack value instead of its RSSI.
- `iw_phy_info_*.txt` carried an `HT TX Max spatial streams:` line that real
  ath9k/ath10k never emit, hiding that an HT-only radio has no source for `nss`
  at all and always fell back to 1x1.
- `iw_dev_info.txt` omitted the `ssid` and `multicast TXQ` blocks real output
  carries.

A fixture is a *recording*, not an illustration: paste real output from a real
device, including the lines that look irrelevant. The ones that look irrelevant
are exactly where unanchored patterns go wrong.

---

## Adopted from upstream (jonasevcik/openUF), 2026-09-06

This fork left upstream at `677f732`. Upstream's twenty commits of 1–2 September 2026 were
reviewed and the parts that were better than ours re-implemented here (not merged); the
hardware evidence below is **theirs**, gathered on a Xiaomi Mi Router AX3000T (mediatek/filogic
MT7981, OpenWrt 25.12.5) against the same model of gateway, and each item is marked with what
this fork has and has not re-verified on its own JioRouter boards.

| Finding | Evidence | Status here |
|---|---|---|
| A UCI section name may contain only `[A-Za-z0-9_]`; libuci discards anything else with `set()` and `commit()` both returning true | An SSID `openuf-verify` pushed, parsed, and never provisioned | Sanitizer fixed; our hash suffix keeps punctuation-only variants distinct. Mock cursors now refuse an invalid name |
| Minimum RSSI is `dBm = raw - 95`, not raw plus the live noise floor | UI -80 ↔ 15 and -85 ↔ 10 on every radio; the noise-floor version drifted -92…-75 across ath9k/ath10k/mt76 | Adopted; AP2's mt76 radios were exactly the -90/-92 case |
| `ft_psk_generate_local=1` disables FT-SAE | A station that negotiated FT-SAE reassociated with `auth_alg=sae` plus a 4-way, even between BSSes on one radio | Removed; OpenWrt's `auth_type`-keyed default derives the key holders |
| `kmod-nft-bridge` is required by the Blocker's `meta` rule and not implied by `nftables`; `kmod-sched-act-police` by the upload half of Speed Limit | Table and set built, only the drop rule rejected; `tc filter … police` failed with "Failed to load TC action module" | Both installers add them; both modules warn by name on rejection. **AP2 lacked both**, so its Blocker and upload cap were silently inert |
| The `ht` in `11naht40` is not a PHY request | 5 GHz radio came up HT40 on hardware that does HE160; a real U6-InWall runs the same token as HE40 | Adopted, in `rf_config` rather than the parser so it composes with the floor, ceiling, clamp and Force WiFi 4 |
| 2.4 GHz has no 80 MHz channel whatever the PHY | An HE 2.4 GHz radio reported `max_width` 80 and a pushed HE80 was fatal to hostapd | Adopted in `parse_phy_caps` |
| A tagged SSID needs no switch trunk on DSA; the 8021q device on the bridge port claims the VID before the bridge | `wan.10` on the `wan` bridge port carried VLAN 10 with `vlan_filtering` off | Consistent with AP2's `br-lan.10` on the bridge, which also works; both shapes supported via `sysinfo.lan_bridge` |
| Per-port VLAN on DSA as a bridge move (socket out of `br-lan`, into `br-openuf<id>`), never `bridge-vlan` | Verified on an mt7530: the driver accepts a user port in a second bridge; counters on the socket and the tagged uplink climb by the same amount | Adopted with their tests. **Not yet exercised on an mt7531** (the JioRouter switch, same driver family) |
| "Port VLAN off" can arrive as a `system_cfg` with no `switch.*` keys at all | Observed live after unticking the box | Adopted: absence counts as off while a reversibility ledger exists |
| Locate must restore the LED's previous trigger, persist it, and be torn down at startup | A radio LED stayed on the identify blink across three Locate cycles | Adopted with their tests |
| 802.11k beacon reports as an Environment-tab source | One request to one client returned 15 BSSes across both bands; 9 of 13 clients advertised no 802.11k | Adopted as `rrmscan.lua`, on by default (`rrm_enrichment`). Complements this fork's `neighbour_scan_interval` |
| `bridge fdb show br <bridge>` names the socket each MAC was learned on | Fixtures are real captures | Adopted, and it fixed a latent bug of ours: the whole-FDB read could pick the gateway's MAC as learned on the VLAN bridge's own port |
| Xiaomi Mi Router AX3000T profile | Adoption, LLDP, ports, wired clients, both radios, Locate, tagged VLAN all verified there | Adopted with `uplink_detect = "fdb"` and its board names added; **not run on this fork's hardware** |

Kept as ours where ours was stronger: atomic `state.json` writes and generic field
passthrough, the `_tick` error boundaries and debug switches, wire-value validation, the
per-pass ubus and `iw phy` caches, `--replace-conf`, the `iw` 6.17 parser fixes.

## Adopted from upstream (jonasevcik/openUF), 2026-09-13

Second review, covering upstream's 61 commits of 3–12 September 2026 (`d7d7e21..12b4db0`),
again re-implemented here rather than merged. As before, the hardware evidence is **theirs**
— an AX3000T and an Archer C5 against a UCG Ultra on Network 10.6.101 — and nothing below
has been re-verified on this fork's JioRouter boards. Roughly a third of their commits
turned out to be fixes this fork had already made on 2026-09-06 (the `_tick` boundary,
atomic state writes, wire validation, the announce fixes, the per-VAP BSSID, the iw 6.17
scan parser, the RRM benching, the ubus and `iw phy` caches, the HTTP 400 streak warning);
those were checked for equivalence and left alone.

| Finding | Evidence | Status here |
|---|---|---|
| A DSA socket moved into a VLAN bridge must have MAC learning **off**, or the ASIC's single address table hardware-drops every VLAN-tagged reply to it while outbound stays perfect | Captured at three points at once with a Trådfri hub on port 2: learning on, 4 DISCOVERs out and 0 replies anywhere; learning off, OFFER + ACK in 2 ms. An entry learned before the move cannot be deleted (ENOENT / EOPNOTSUPP) and ages out in ~140 s | Adopted: `switchvlan.dsa_apply` writes `openuf_brport<vid>_<socket>` with `learning '0'`; `ucihelper.ensure_vlan_network` does the same for the tagged uplink sub-device (`openuf_brport<vid>`), which the switch also files against the VLAN bridge; `prune_vlan_networks` and `dsa_restore` sweep both |
| Learning off empties `bridge fdb` for that socket, and on DSA the FDB is the ONLY wired-host source — so the port reported no clients and the controller credited them to the gateway | The wired IoT device listed under the gateway at GbE instead of under the AP's port 2 at FE. `vlan_filtering` + `bridge-vlan` would fix it at the switch (mt7530 sets `IVL_MAC`) but is blocked on netifd (openwrt#16314, #9089: every member incl. runtime VAPs needs an explicit `bridge-vlan`, and the 8021q sub-device would have to go) | Adopted: `switchvlan.reconcile_mac_taps` installs `table bridge openuf_learn` (sets `portmacs` and `portips`, 5-minute timeouts matching FDB ageing, one rule per set over every tapped socket); `sysinfo.mac_table(ifname, bridge, allow_tap)` reads it only for a socket whose bridge is not the uplink's and only when the FDB is silent. Rebuilt at startup from the UCI sections, left alone when it already matches |
| The controller files a wired client under a network by `mac_table[].vlan`, defaulting to 1 — not by the port's native VLAN and not by the IP it already holds | `com.ubnt.service.devmgr.isqI`: `if (network.getVlan() != host.getInt("vlan", 1)) continue;`; the dedup key is `mac .. vlan`; the client record copies `vlan` and drops a 1. With `vlan` and the tap's `ip` the live record read network IoT, vlan 10, Office AP port 2, FE | Adopted: `_filter_hosts` stamps each row with the VLAN of the bridge the socket sits in (`br-openuf<vid>`), nil on the management VLAN; the tap's second set harvests addresses from ARP and IPv4 (0.0.0.0 excluded), freshest wins, because the AP holds no address on that VLAN and `/proc/net/arp` can never answer |
| `port_table` asked the UPLINK's bridge about every socket, so a moved socket answered nothing even with learning on | Seen while tracing the above | Adopted: each socket asks `sysinfo.bridge_of` for its own bridge, memoized per pass; `forget_uplink_cache` after a switch push, since the 300 s TTL cannot see openUF moving a socket itself |
| An uplink port must carry no `mac_table` at all, gateway included: a port with exactly one known device files it into `downlink_table`, and the `isUplinkMac` guard is ANDed with `!is_uplink` | Both APs silent → each AP's `downlink_table` empty, the gateway's holding both. `last_connection` is never recomputed when the field is absent, so a stale Connection column is expected | Already our behaviour; the rationale recorded (feature 39) |
| A DSA map whose `lan_cpueth` names a socket announces one MAC and sources every frame from another (`br-lan` inherits the conduit's), and the gateway raises an IP conflict | Capture on `wan`: the reported address sending exclusively from the eth0 MAC | Adopted as `ucihelper.ensure_bridge_identity`, run once from `M.run`; pins `br-lan`'s `macaddr` to `lan_cpueth`'s only when they differ. **A no-op on this fork's maps**, whose `lan_cpueth` is `br-lan` itself |
| The blocker (nft) and speed limit (tc) are kernel state and were only ever built inside `apply_config`; after a reboot the controller replies `noop` and both stayed off while the UI showed them on | Verified in the validation lab once its UCI mock persisted; the `openuf_bcfilt*`/`openuf_ratelimit_*` stamps had never been read back | Adopted: `ucihelper.reapply_runtime_rules` rebuilds both from the stamps at startup, through the same `reconcile_runtime` `apply_config` uses |
| A controller-pushed static IP is `ip addr` state, died with the reboot, and the four `static_*` fields in `state.json` had no reader; and a raise between the apply and the tail-end save lost the record | The AP moved to its pushed address, usteer raised, `state.json` never learned about it | Adopted: `_reapply_static_ip` at startup, before `_populate_net_info`; the IP branch saves state the moment the interface changes |
| `rrmscan.collector_stop` had no caller: the detached `ubus subscribe` child outlived a disabled `rrm_enrichment` and a service stop, appending to a RAM disk forever; the procd reload trigger degraded to a restart on every LuCI wireless edit | Static analysis plus the 31.7 MB debug dump found the same week | Adopted: stopped from `_rrm_tick`'s disabled branch and from a real `stop_service()`; `service_triggers` dropped; the `pgrep` liveness check runs once a minute and is re-armed after a config push |
| `debug_dump_file` had no ceiling and lives on tmpfs | 31.7 MB after five weeks, 55% of a 59 MB `/tmp` | Adopted: 4 MiB cap, `debug_dump_max_bytes`, restart-with-marker rather than rotate |
| `conf.lua`'s `inform_url` and `state_file` were read by nothing | — | `state_file` was already honoured here; `inform_url` now seeds `state.DEFAULT_INFORM_URL` |
| `_state_mtime` forked `stat -c %Y` every heartbeat and fell back to the contents, which are the stronger token anyway | No stat applet on a WDR3500 | Adopted; `coreutils-stat` dropped from both installers |
| Six per-heartbeat costs: ARP and leases read once per socket, the ARL walked whole per socket, `bridge fdb show dev` forked per socket on DSA, the phy dump re-parsed per radio, `readlink`/`ip route` forked every 10 s, `lldpctl` forked every 10 s, `/proc/uptime` read per radio, `/etc/config/wireless` loaded three times | Measured with the new `tools/heartbeat-probe.lua` on the Archer C5 | Adopted: a `sysinfo` lookup pass mirroring ucihelper's, a 300 s uplink cache that never caches nil, the parsed phy caps cached with the text, a 60 s LLDP cache that never caches an empty answer, one `radio_rows` memo per pass with copies handed to each caller |
| `inflate` supplied zero bits past EOF and spun forever on a truncated stream | Found by writing the module's first tests | Adopted with `tests/test_inflate.lua` (Lua 5.1-safe `string.char`, not `\xNN`) |
| `sysupgrade` knows nothing about `/etc/openuf` or `conf.lua`; a firmware upgrade un-adopts the AP | `sysupgrade -b` listed 29 entries, neither among them | Adopted in `install.sh` with the four follow-up fixes (no trailing newline, uninstall keeps the state dir line, grep exit 2 leaves the file alone) |
| `cfg.vlan.device` had five readers and no producer | Every swconfig call addressed `switch0` regardless | Adopted: declared in all five swconfig maps, pinned by a modelmap test; `wan_name`/`wan_vlanid` and `uap.field` dropped as dead |
| `sae_anti_clogging_threshold`/`sae_sync` are not wifi-iface options; "Show AP Name in Beacon" never reaches a beacon | Schema, ucode and `hostapd.sh` checked on both boards | Adopted: writes and parser fields removed; features 26/27 re-graded |
| Test fixtures carried the author's real home-network MACs and addresses | — | Mapped one-for-one onto RFC 7042 / RFC 5737 documentation values here too, since this fork ships the same captures |

Kept as ours: `sysinfo.lan_bridge` (upstream resolves the uplink bridge with `bridge_of`,
which cannot handle a map whose `lan_cpueth` is the bridge itself), the `not uplink_unknown`
gate on wired clients, `keep_wlan_sections`, the `--replace-conf` installer flag, the
`/tmp/openuf-status` health file and `update.sh`, the `coreutils-stat` removal (upstream
still installs a package nothing reads). Not taken: upstream's README screenshots of their
own deployment.

## Adopted from upstream (jonasevcik/openUF), 2026-09-28

Third review, covering upstream's 26 commits of 25–27 September 2026 (`12b4db0..08d0003`,
tag `v0.9.3`), again re-implemented here rather than merged. The first seven of those
commits were upstream taking this fork's 2026-09-15 work (`sysconf.lua`, `l2guard.lua`, the
`noop` interval, the bootstrap re-lock guard) -- credited as such in their file headers --
and were checked for equivalence and left alone. The rest is new, and **every piece of
hardware evidence below is theirs** (an AX3000T and an Archer C5 against a UCG Ultra on
Network 10.6.101, plus their Docker lab on 10.4.57). Deployed to AP2 (build `d4c3460`) the
same day: rows 44, 45 and 49 of the feature matrix record what its first push showed, and
REVERSE-ENGINEERING.md backlog row 20 what is still owed.

| Finding | Evidence | Status here |
|---|---|---|
| Sibling openUF APs were listed as third-party APs impersonating the site's SSID: the controller decides `is_rogue` from the reporting AP's `is_unifi`/`serialno` alone and never consults its own devices' BSSIDs | Decompiled `com.ubnt.service.aS.rhAW`; all six sibling BSSes at upstream's home flagged | Adopted: every VAP beacons `vendor_elements` `dd0d 026f55 6f5546 01 <identity MAC>` (a private OUI, so a real UniFi AP cannot misparse it), `scan_table` joins it back over nl80211 through `ucode` (OpenWrt's `iw` prints no unknown vendor IE -- checked live on both of their boards), and a tagged BSS carries `is_unifi=true`, `serialno=<MAC>` |
| `iw` prints every non-ASCII SSID byte as `\xNN`, so "Café" reached the Environment tab as `Caf\xc3\xa9` and the evil-twin check could not match it | Seen live 2026-09-27 | Adopted: decoded in `scan_table`; a NUL-filled hidden SSID yields no `essid` |
| `band_steering_threshold` only biases usteer's load balancing and is inert with `load_balancing_threshold` 0; the real switch is `band_steering_interval`, whose non-zero default means a running daemon always steered | usteer source (`band_steering.c`, `policy.c`); confirmed in the running daemon with `ubus call usteer get_config` | Adopted: `usteer.lua` writes `band_steering_interval 0` for off and deletes it for on, with an `openuf_active` stamp; old thresholds are removed |
| The AP's own Band Steering setting arrives as `bandsteering.status`/`mode` (+ per-WLAN `vap.N.devname` pairs) only for a device claiming `wifi_caps` `0x4`; `0x8` keeps it on with a single-band WLAN present | Captured live on a real UCG Ultra; `equal` (Balance) has no usteer equivalent | Adopted: `_parse_bandsteering_system_cfg` / `_steering_flags`; Prefer 5G turns steering on, Balance logs once |
| Roaming Assistant (`wireless.<n>.btm_disassoc.status`/`.threshold`, 5 GHz vaps only) is emitted only with `wifi_caps2` `0x20`; usteer's own roam trigger is device-wide and its only scoping knob switches every usteer function off per SSID | Decompiled `ubntconf` (the −75/−88 constants); a −80 dBm client refused the BTM request (`status_code=4`), was disassociated 16 s later and reassociated on the −61 dBm AP within 1 s | Adopted as `roamassist.lua`: per-WLAN decision, BTM request then disassociation with a 30 s ban, only toward an AP that hears the client ≥ `roam_assist_diff_db` louder; `usteer.set_enabled` gains a third argument so the daemon runs for it with steering off |
| FT on a WPA3-only WLAN needs `radio_caps2` `0x2`; without it `wpa3.ft.status` is always `disabled` and no 802.11r goes out | Radio DTO `ytajcagDggPuTaL()` in the per-radio security filter; lab wire diff | Adopted: `0x3` wherever `sae_supported()` |
| Enhanced Open needs `radio_caps2` `0x8`; transition mode arrives as two VAPs per radio (open + hidden OWE, linked by `owe_devname`) that would collapse into one UCI section | Lab capture on 10.4.57 with `0xB` | Adopted: `owe_supported()` probes `hostapd -vowe` and the ucode generator, the parser keeps the open half with `owe_transition`, `get_ifnames_for_vap` covers the second BSS for stations, blocker and shaper. ⚠️ No OWE BSS on any real AP yet |
| Airtime Fairness (`atf.mode`) needs `wifi_caps` `0x20`; mac80211's per-phy `airtime_flags` (debugfs, 3 = TX+RX, 0 = off) is the only switch, and it resets on reboot | On confirmed on four radios against the real controller; the controller had `atf_enabled: false` stored from before the bit was claimed | Adopted as `airtime.lua`, `st.atf_enabled`, `_reapply_airtime` at startup, default restored on forget. ⚠️ Off is lab-only |
| Private Pre-Shared Keys need `wifi_caps` `0x100000`; the wire is `aaa.<n>.wpa.psk_file.<k>.psk`/`.vlanid` + `dynamic_vlan=1`, and OpenWrt's `wifi-station`/`wifi-vlan` sections already express them | Lab capture on 10.4.57 through to UCI | Adopted: `ppsk_supported()`, `ucihelper.ppsk_add`/`vap_vlan_ids`, `wlan_clear` drops the sections with their VAP, `bss_ifname` maps a VLAN netdev's stations back to their hostapd BSS, `switchvlan` trunks the keys' VLANs. ⚠️ No VLAN-key client on any real AP yet |
| The satisfaction estimate (signal vs. retry ratio) missed a failing link because retry counters mean different things per driver | See the `sta_table[].satisfaction` row above | Adopted: airtime / uplink rate / SNR terms, `hostapd_sta_caps`, `tx_duration` and per-direction width in `sta_table`, live width in `radio_caps` |
| A `setdefault` or out-of-process `reset-inform` left the l2guard table, the nightly cron job and a long controller interval behind | Reasoned from the code | Adopted: `_forget_controller` on both paths (`was_adopted` in `_reload_if_changed`) |
| A push that adds an SSID runs `wifi reload` asynchronously, so l2guard's VAP snapshot could miss the new netdev until the next push | Reasoned from the code | Adopted: `_l2guard_resync` once a minute, rebuilding only on a non-empty changed list |
| `_popen` drops stderr, so a refused `iw scan` was indistinguishable from a successful one; a plain scan on a beaconing AP sweeps the same channels as `ap-force` on ath9k/ath10k/mt76 | Compared channel by channel on their live APs, 2026-09-25 | Adopted: `_force_scan` (`ap-force` kept as a free guard, exit status judged, refusal logged) for both the spectrum-scan cmd and the 11k-scan |
| Full sweep of the controller's capability gates | Decompiled 10.6.101 | Adopted into [Capability bitmasks](#capability-bitmasks); WLAN Schedule recorded as the one unbuilt feature whose bits change the wire |

Kept as ours: `debug_caps`/`debug_payload_extra` (the masks above are still replaced whole by
an override), `state.lua`'s typed-passthrough design (`atf_enabled` added to the typed list),
`_maybe_scan_neighbours` and the rest of this tree's names, the unhandled ledger (which now
recognises `bandsteering.*` and `atf.*`), `update.sh`/`/tmp/openuf-status`, and this
fork's CLAUDE.md (upstream added its own; its Lua 5.1 and verification rules are folded in).
Not taken: their README screenshots, and their rename of the scan-request consumer.

## Adopted from upstream (jonasevcik/openUF), 2026-10-18

Fourth review, covering upstream's 82 commits of 1–17 October 2026 (`08d0003..2f263f3`,
tags `v0.10.0` and `v0.11.0`), re-implemented here commit by commit (a three-way apply per
commit, the displaced blocks hand-placed in this tree's layout, their tests ported by name)
rather than merged. Two things changed how upstream works and both matter for reading what
follows. **They now read UniFi AP firmware**: the ARM64 U6/U7 images are opaque (the U6-InWall
dead end below still stands), but the MIPS/QCA956x builds are plaintext (BZ2 3.9.27 to
4.0.15 here; later builds in the newer firmware audit, `tools/fw-extract.sh`), and
`/usr/etc/syswrapper.sh`, `/bin/mcad`, `/bin/ubntbox`, `libubnt.so` and `umac.ko` say what
a real AP does with each key. Those claims are labelled "firmware-confirmed for 3.9.27 to
4.0.15" and are not claims about current firmware. And **every piece of hardware evidence
in this section is theirs** (an Archer C5 and an AX3000T against a real UCG Ultra on
Network 10.6, plus their Docker lab on 10.4.57 and 10.6.106). Nothing from this review has
run on AP1 or AP2 beyond a Lua 5.1.5 compile of every module on AP2 (all 49 load);
REVERSE-ENGINEERING.md backlog row 23 lists the checks owed.

Not adopted: the guest portal / Hotspot series (seven commits, lab-validated only upstream
and not run with a real guest WLAN there either; backlog row 24), the ath9k interference
counters (`athstats.ast_txto`/`ast_cst`, no mt76 equivalent), and their installer test tier
(`docker run openwrt/rootfs`). Kept ours where ours was already ahead: the Airtime/Quick
Scan handler (rows 52–54, verified live here and chunked so a sweep no longer drops
clients), the unhandled ledger (their log-counting version is a subset), the init script's
probe (theirs corrected ours: `wnm_sleep_mode` is the 802.11v test, `bss_transition` also
matches a basic build's event names) and `lan_bridge` where they use `bridge_of`.

| Finding | Evidence | Status here |
|---|---|---|
| The firmware computes WiFi Experience as the lowest of six terms (signal, PHY rate, TCP loss, TCP latency, retries over the last minute, TX latency), with `satisfaction_reason` and an `anomalies` bitmask, per-VAP bar charts and a radio roll-up; the controller computes nothing | `calc_sta_satisfaction` and friends in `libubnt.so` 4.0.15 (3.9.27 computes none) | Adopted: `satisfaction.lua` replaces this tree's three-term estimate (and its 2026-10-03 per-band frame cost); TCP and latency terms score 100 since mac80211 has no source |
| A real AP refuses a client below Minimum RSSI in the driver (threshold + 3 dB) and kicks only after 30 consecutive one-second samples below it; the one-shot kick alone loops kick → rejoin | `ubntbox`/`stamgr` 4.0.15 | Adopted: `minrssi.lua` + hostapd's `rssi_reject_assoc_rssi`/`rssi_ignore_probe_request` (stamped `openuf_minrssi`); unit-tested only here |
| WiFi Speed Limit is per **client** (one HTB class per station under the VAP's), both directions queued; `rate-update` is a per-client override lasting one association and is sent for any client, not only guests | `config_sta_qosrule`/`update_sta_qosrate` 4.0.15; the 10.6 controller sends `rate-update` on connect, roam and profile change | Adopted: `shaper.lua` rewritten (MAC-keyed classes, upload on an IFB device with policing as the fallback, `sync()` diffs per station); row 38 corrected. **Needs `kmod-ifb`**, added to the installers and the package |
| WLAN Schedule: the controller inverts blackout windows into on-time blocks (`schedule_<day>[.<i>]`, `.<i>` only with `fw_caps` `0x1000`), the AP writes schedule lines per VAP and `configure_vap` takes the netdev down outside them, every five minutes and only once NTP has set the clock | `ubntbox` + `syswrapper.sh` 4.0.15; wire from their 10.4.57 lab; confirmed on their hardware | Adopted: `wlansched.lua`, checked every heartbeat, netdev down/up with the beacon restarted (hostapd `STOP_AP` + `update_beacon`); clock trusted once `server_time_in_utc` agrees within 60 s; `fw_caps` `0x1000` claimed. Row 50 |
| STUN: the AP is the STUN **client** (RFC 3489 Binding Request with a CHANGE-REQUEST attribute every 30 s; jstun rejects one without — which is why this tree's bare RFC 5389 probe got no answer on 2026-09-15); the mapped address goes out as `connect_request_ip`/`port`, and the controller's wake-up is a 20-byte type `0x8888` datagram to it whenever it queues a command or a config change | `mcad` `stun_init/send/recv` 4.0.15; confirmed against their 10.6 controller | Adopted: `stun.lua`, `_idle` ends early on the wake. Resolves REVERSE-ENGINEERING.md Investigation 3 |
| AirView Connectivity is fed by `STA_ASSOC_TRACKER` notif informs (one POST each, `inform_as_notif`), asked for by `capability=notif,notif-assoc-stat`; stages come from hostapd's `auth`/`assoc`/`sta-authorized` ubus events stamped with `/proc/uptime`, DHCP/DNS from a passive nft set that dates a station's first frame | Their lab (10.4.57) and both boards | Adopted: `assoctrack.lua`; `conf.lua` `assoc_tracker` switches it off |
| AirView Roaming: with `wifi_caps2` `0x2000` on both APs the controller takes roams from the AP's `association`/`sta_leave`/`sta_roam` notifs alone (Fast Roaming, failures, Minimum RSSI and Roaming Assistant tags) and must get a departure within a second of the arrival | 10.6.106 decompile + hardware; the Minimum RSSI tag lab-only | Adopted: the bit is claimed only while reports are sent; `_idle` polls the collector every 250 ms; `bridge monitor fdb` in the collector catches a station that left for another AP |
| Load balance is a per-radio client cap: `stamgr.<n>.loadbalance.status`/`maxsta`; `stamgr -n` kicks the most idle station above the cap once a second and refuses nobody | `ubntbox` 4.0.15; REST-only in the 10.6 UI | Adopted: `loadbalance.lua`, one pass per inform kicks the excess, Minimum RSSI's kicks not counted |
| 802.11r key holders are keyed with the WLAN's `aaa.<n>.iapp_key` (128 random bits per WLAN), with `pmk_r1_push=1` and a 3000 TU reassociation deadline; hostapd's RRB socket can lose its interface after weeks (ENXIO on every push/pull) and only a wpad restart repairs it | Their hostapd template reading + an office AP's log | Adopted: `r0kh`/`r1kh` from `iapp_key` (OpenWrt's passphrase derivation only without one), the two options, and `rrbguard.lua` (repairs when no client is connected or in the 04:00 hour) |
| `setdefault` on a real AP is a factory reset and reboot: no SSID, no VLAN afterwards. An L3 re-adoption over the default `http://unifi:8080/inform` fails with HTTP 400 ("invalid inform_ip unifi") | `syswrapper.sh restore-default` 4.0.15; UCG Ultra + lab 2026-10-11 | Adopted: `ucihelper.forget` + `_forget_controller(prev, cfg)` (WLANs, VLAN bridges, radio extras, per-port VLANs, steering, LED, interval); the inform URL that reached the controller is kept |
| The firmware applies U-APSD (`wireless.<n>.uapsd`), the GTK rekey interval (`aaa.<n>.wpa.group_rekey`, 0 = off) and the WLAN's own 802.11k toggle (`aaa.<n>.11k.status`) | `iwpriv`/hostapd template 4.0.15 | Adopted: `uapsd`, `wpa_group_rekey`, `ieee80211k` + both report options. Trade: with the controller's default (U-APSD off) SSIDs no longer advertise U-APSD |
| The firmware sends `rssi` as the SNR (signal − max(noise, −96)), `noise`, `state` bit `0x10` for a dozing station, `is_11r` only when true, per-client `tx_retries`, and none of `capacity`/`throughput`/`linkscore`/`multicast`; `wifi_tx_attempts` are frames sent, retries excluded (the controller's rate is retries ÷ (retries + attempts + dropped)) | `fill_stainfo_json` 3.9.27–4.0.15; devmgr/wifi.k decompile | Adopted. Power save is nil on mt76 (the driver takes PS tracking over: `AP_LINK_PS` in hwflags) |
| `sys_stats` (the three load averages as strings, memory in bytes) and a vap's `extchannel` (secondary-channel side) are sent; channel utilisation is the last ~1 s, not since the radio came up | `prepare_system_stats`, `ieee80211_beacon_chanutil_update2` 4.0.15 | Adopted: `sys_stats`, `extchannel`, and `cu_*` as deltas of the survey counters since the previous inform |
| mt76 as shipped in OpenWrt 25.12 can read a fresh station's `tx retries`/`tx failed` as 4294967295 (an unguarded `count − 1`), which added 2^32 to the controller's per-band totals; and on mt76 `tx failed` counts failed attempts, so drops are `failed − retries` | Their Office AP: 47 billion tx packets, 50 % retries | Adopted: `sysinfo.u32_count`, `satisfaction.dropped` |
| A real UniFi AP beacons `dd <len> 00 15 6d 00 01 01 <flags> 01 02 <sysid>` + TLVs, `81 06 <serialno>`; without reading it a current-firmware UniFi neighbour is listed as a rogue | `umac.ko` + a neighbour's AP seen live in 2026 | Adopted: `peer_match_ucode` walks the TLVs; `tools/peer-ie-vectors.lua` holds the vectors |
| `kick-sta` (Client → Reconnect) and `blocked_sta` (the site's whole block list, newline-separated, on every push) are in the controller's request set; a block should also refuse association, which hostapd's deny ACL does but a restart or BSS reload loses | Their 10.4.57 cmd audit; `addmac_blksta` 4.0.15 | Adopted: `kick-sta`, `_sync_blocked_stas`, `firewall.deny_sync` re-checked once a minute, on a hostapd socket change and for 60 s after openUF's own `wifi reload` |
| usteerd broadcasts its whole station table to 255.255.255.255:16720 every second (7 kB, five fragments with 119 entries), which the bridge floods out of every VAP and Multicast Enhancement turns into a unicast copy per client; OpenWrt forces `ap_isolate=1` with `multicast_to_unicast` or `proxy_arp` and a reconfigure can drop the bridge port's `hairpin_mode`, cutting a BSS's clients off from each other | Live 2026-10-07 on both their boards (a Google Home pair silent for eleven days) | Adopted: `bridge openuf_usteer` drop on the VAPs, `l2guard.reconcile_hairpin` once a minute |
| Each openUF nft table rebuilt in one `nft -f` transaction, so a blocked client never slips through between delete and rebuild; a rejected statement is retried one by one to name it | Their audit | Adopted: `util.nft_apply` in firewall, bcfilter, l2guard, usteer, switchvlan, assoctrack |
| The firmware spreads the nightly 11k-scan over two random times in an hour (`elevenk_sched 3600 2`): every AP's crond fires at 04:00 sharp, so without it all APs go off-channel together and find each other off-channel | `syswrapper.sh` 4.0.15 | Adopted in `syswrapper.lua` (two due times from `/dev/urandom`) and `_scan_requested`; a due time waits while a chunked sweep is still running |
| hostapd logs every beacon report it receives as ~15 hex lines; at a 600 s request interval they took 72–78 % of a 128 KB logread buffer, and the controller keeps a reported neighbour ~24 h | Live 2026-10-13 | Not adopted, by decision the same day: the default stays 600 so the Environment view follows the air as closely as a client can report it; the log cost is accepted and `rrm_request_interval` is the knob |
| OpenWrt's Lua carries the LNUM patch: `string.format("%d", x)` raises for \|x\| > 2^31 on the APs but not on CI or a dev machine | Their boards; **reproduced on AP2's Lua 5.1.5 on 2026-10-18** | Format epochs in ms with `%.0f` (CLAUDE.md) |
| The resource audit: forks per steady heartbeat 16 → 10 (C5) / 17 → 12 (AX3000T), CPU to build one 242 → 95 ms / 38 → 22 ms, RSS 3068 → 2378 kB / 3882 → 3030 kB after a full collection per tick | Measured on their two boards over 30 min each | Adopted where ours had the same shape: `util.lua` (sysfs reads for master/driver instead of `readlink` forks), one `iw dev` per pass, one ucihelper pass per tick, AKMs cached per association (not the sibling tags -- see below), the LLDP neighbour cache removed altogether instead, and the sibling-tag cache (a stranger kept ten minutes, a sibling an hour) not taken either -- both by decision the same day: what the controller shows follows reality on the next heartbeat, one fork per read is the price, probe requests dropped in the collector, zlib looked up once, `collectgarbage("collect")` per cycle. Not measured on a JioRouter yet |

## QEMU test VM against a live 10.6.106 controller — 2026-10-26

Not hardware: OpenWrt 25.12.6 x86-64 under QEMU (TCG), the JIDU6J01 modelmap with
`/tmp/sysinfo/board_name` overridden, three `mac80211_hwsim` radios (radio0 2.4 GHz, radio1
5 GHz, the third a test client in its own network namespace, or a hand-run hostapd playing
another AP), installed with `setup.sh --headless` and adopted by a self-hosted UniFi Network
10.6.106 (a container; inform on a non-default port through `unifi.http.port`). What it
proves is the protocol, UCI, hostapd and nft side end to end; radio order, DSA sockets, the
LED and real RF are untouched. `hwsim` claims EHT, so the logs read `EHT20` where an MT7986
runs HE.

**Passed with a real station on the VAPs:** adoption (404s until Adopt, then GCM, setparam,
noop); WPA2/WPA3 (`key_mgmt=SAE`, PMF); OWE transition (steered to the hidden OWE BSS); PPSK
(key 1 on `br-lan` with DHCP, key 2 on `<vap>-20` in `br-openuf20`, its frames tagged VLAN 20 on
the uplink); WiFi Speed Limit 5/2 Mbps (iperf3 4.7 down / 1.7 up, against 39 / 49 on an
unlimited SSID); the Blocker (no DHCP reply on the blocked SSID while the same server answers
every other one: the documented allow-list behaviour); the AP-name WSC element in the beacon
and probe response (`iw`'s scan print stops after HE Operation, so read the IEs through
`wpa_cli bss`); the guest portal (HTTP → `302` to `http://<ctl>:8880/guest/s/default/?id=…&ap=
…&t=…&url=…&ssid=…`, the portal page `200`, HTTPS dropped before login; the login click needs a
browser and was not run); Minimum RSSI (`rssi_reject_assoc_rssi` = threshold + 3 on 5 GHz
only); `system.timezone` (`GMT0 -> IST-5:30`, the old value stamped); a Blackout Schedule
(both BSSes of the OWE pair down inside the window, up when the schedule was removed, the
client's scan following); the wireless uplink with a hand-run parent (cable pulled → station
up in ~30 s, informs over the hop, own path element naming the parent, the downlink following
the parent from ch 44 to ch 36; a fake descendant learnt as `desc` and refused for 90 s with the
parent gone; cable back → wired in 2 s).

**Found and fixed there:**
- A guest WLAN arrives as `mode=master usage=guest` (the table above). The mesh guard read
  any `usage` but `user` as a backhaul VAP, so with Mesh Parent on the Hotspot SSID was never
  provisioned as a guest AP and replaced the vwire downlink in `backhaul.plan` (`phy1-ap4`
  beaconed the guest SSID as a WDS AP). `usage=guest` is now an ordinary AP.
- A root AP (Mesh Parent on, Mesh Connect off: a downlink and no uplink station) beaconed the
  version 1 sibling element alone: `backhaul.tick` returned before `multihop_tick`.
- The Blocker's ruleset is built right after `wifi reload`; when netifd had not brought the
  VAPs up yet it came out empty (chain present, no rule) and stayed so until a restart.
  `ucihelper.resync_runtime_rules` now rebuilds it once a minute when the live VAPs differ.
  The live run after the fix did not reproduce the race (a push that left the radios'
  config unchanged); the repair path is pinned by `test_ucihelper.lua`.
- A reinstall with `install.sh install` over a running daemon left the old code in memory
  (procd ignores a `start` whose command line is unchanged; same PID before and after).

**Not openUF, met on the way:** a controller whose site timezone is unset sends none, so a
schedule is evaluated in UTC; a controller in a container must publish 8880/8843 for the portal
page, not only the inform port; an inform port other than 8080 needs `unifi.http.port` in the
controller's `system.properties` (and its Inform Host override), a published port alone sends
devices to the wrong one.

### The combined build, 2026-10-27

The same VM and controller, reinstalled from the merge of this tree with yesrab's
802.11r translator, IP refresh and relicence (`setup.sh --headless`, which now pulls
`ucode-mod-socket` and `kmod-veth` as well), adopted afresh, four test SSIDs re-created
(WPA2/WPA3 with a 5/2 Mbps limit, the Blocker and the AP name; PPSK with a VLAN 20 key;
Enhanced Open; Hotspot), Mesh Parent and Mesh Connect on, 5 GHz Minimum RSSI on.
`selfcheck.sh` 32 OK, 0 FAIL; `tools/verify.py` 46 OK, its one FAIL the VM's missing LED.

- **Every station test above passed again:** SAE and WPA2 on the mixed SSID, OWE, both PPSK
  keys (the second as `vlan_id=20`, its MAC in `br-openuf20`'s FDB), a wrong key refused,
  iperf3 4.72 down / 1.83 up against 5/2, the AP-name element in both radios' beacons with no
  Config Methods attribute, the portal redirect (`302`, page `200`, HTTPS dropped).
- **The Blocker, measured from the LAN side:** broadcast ARP from a host on a veth in
  `br-lan` reached a client on the blocked SSID 0 times of 3 and one on an unblocked SSID 3 of
  3. The AP's own frames are not filtered: the chain hooks bridge `forward` (LAN → WLAN), so
  a test that pings from the AP itself proves nothing.
- **802.11r through the translator (yesrab's merge):** turning Fast Roaming on wrote
  `ieee80211r`, mobility domain `0afe` (UniFi's formula), `ft_psk_generate_local 0`, the
  wildcard key holders and `ft_iface=vft0`; that push created the veth pair, and `rrb-unifi`
  went from "waiting for the veth pair" to `running: hostapd side vft1 (ft_iface vft0), lan
  side br-lan` with `UBNT_ROAM on`, then listed both local BSSIDs. A station on the 5 GHz BSS
  roamed to the 2.4 GHz one with `AP-STA-CONNECTED … auth_alg=ft`, AKM `00-0f-ac-4` (FT-PSK)
  and `00-0f-ac-9` (FT-SAE). That is openUF ↔ openUF over the translator's veth; the roam
  against a genuine UniFi AP is still not run here.
- **The device IP refresh (yesrab's merge):** `state.ip` follows `br-lan`'s address.
- **The LuCI app in a real LuCI** (25.12.6, `luci-app-openuf` files laid out as `luci.mk`
  installs them): Overview, Setup, Settings, Log and the device page render with the device's
  data. Setup's Save & Apply wrote `openuf.main` (profile, identity, inform URL) and restarted
  the daemon; the identity MAC stayed and the next inform succeeded. A LuCI page in a hidden
  browser tab sits at "Loading view…": LuCI flushes batched RPC calls on
  `requestAnimationFrame`, which a background tab never runs. Not openUF.
- **The wireless uplink, with the loop guard:** the cable pulled with only a fake descendant
  on air, the station came up with that BSSID in `bssid_blacklist` and stayed unjoined; with
  the parent added (the two BSSIDs swapped roles on the restart) it first joined the
  now-descendant, logged `a downlink of this AP's own descendant -- a loop; leaving it` on the
  next heartbeat and moved to the parent; informs resumed over the hop (about a minute after
  the join while `br-lan`'s DHCP client came back) and the controller answered a ping over it in
  2.5 ms; cable back → the station disabled and informs carried on.


## Adopted from d-malinowski/openUF (`pr/unifi-ft-interop`), 2026-10-25

One commit (`94ac182`, 2026-10-22) from a third fork, not from upstream: `ftinterop.lua`, a
hook in `apply_config`, the `unifi_ft_interop` switch, seven tests. Re-implemented here in
this tree's layout (the switch also reaches `openuf.main`, `probe export` and both LuCI pages,
which upstream does not have). One deliberate difference: **they ship the switch off, this
tree ships it on for new installations** (the user's decision, 2026-10-25). Without the
translator the switch changes only the mobility-domain formula (UniFi's, which every openUF AP
still shares) and FT-PSK's key path (a pull over RRB instead of local derivation, the path
FT-SAE always took); `ft_iface` is written only when the veth exists. The one site that should
set it off is one with genuine UniFi APs and no translator, where clients would try a fast
transition towards those APs and fall back to a full reconnect. To keep an AP without the
translator from logging a diagnosis of every missing piece on every push, `ftinterop.lua`
checks for `/etc/config/rrb-unifi` or `/etc/init.d/rrb-unifi` and otherwise says one line per
FT WLAN. **Every piece of hardware evidence in this section is theirs**:
a BT Home Hub 5A (lantiq/xrx200, OpenWrt 24.10.4 then 25.12.6, `wpad-mbedtls`) and a U7 Lite
on UniFi 8.7.11, adopted into a UCG Ultra, a Samsung S24 walking between them. Nothing has run
from this lab, which has no genuine UniFi AP (REVERSE-ENGINEERING.md backlog row 25).

### 802.11r with genuine UniFi APs

The claim this tree made until now, "FT between openUF and a real UAP cannot work, because
real UAPs learn their peers through a Ubiquiti-only hostapd extension", holds only without a
translator. Their captures on both APs show the two hostapds speak the same protocol with a
different frame layout:

```
stock hostapd: 00 13 74 00 01 | type | auth_len (LE16) | auth TLVs | AES-SIV(enc TLVs)
UniFi:         00 13 74 00 01 | type | src AP (6) | dst AP (6) | auth_len | auth TLVs | AES-SIV(...)
```

UniFi's frames are exactly 12 bytes longer (96/142 vs 84/130 bytes): it sends RRB from the
AP's Ethernet MAC rather than the BSSID, so it names both APs in the payload. **The crypto is
identical**: every captured frame from both vendors decrypted offline with the same key,
derived as hostapd's `rkh_derive_key()` does (`HMAC-SHA256(iapp_key, "FT OLDKEY\0" || 0x01)`,
AES-SIV AD = [src BSSID, auth TLVs, type]). Their `rrb-unifi` daemon (ucode, GPL-3.0) inserts
or strips the 12 bytes between a veth (hostapd's `ft_iface`) and the LAN bridge. Before it,
FT failed in both directions: the phone stuck to one AP or fell back to a full 4-way handshake.
The UniFi AP's log for a stock frame is `FT: RRB-OUI frame too short`.

| Their claim | Their evidence | Here |
|---|---|---|
| UniFi firmware's mobility domain is the first two bytes of SHA1("salt" .. SSID zero-padded to 32 bytes) | ✅ Reproduces the `mobility_domain` in the U7's own hostapd config for the test SSID ("corp" → `5de5`) | `ftinterop.mobility_domain`, pinned by test; `derive_mobility_domain` stays openUF's own and different, so a client never tries FT across the two without the translator |
| OpenWrt's `ft_psk_generate_local=1` default for PSK writes no key holders, so a UAP pulling a PMK-R1 gets no answer; `0` plus explicit `r0kh`/`r1kh` for the UAP's BSSes keyed with `iapp_key` (the controller sends both APs the same one, confirmed by fingerprint) and `nas_identifier` = own BSSID (UniFi's R0KH-ID convention, from which the UAP derives the pull's destination) | ✅ **Pull, UAP → OpenWrt**: sequence sync (types 4/5) then pull request/response (1/2) in the translator log, `AP-STA-CONNECTED … auth_alg=ft` with no 4-way, both radios. ✅ **Push, OpenWrt → UAP**: type 3 to both U7 BSSes, accepted; the walk shows `auth_algo: ft` in the U7's log, associated in 10–20 ms | The one place this tree sets `ft_psk_generate_local` (CLAUDE.md's rule gets its exception). `nasid` is written when the VAP has a live netdev; OpenWrt's `hostapd.uc` (24.10 and 25.12) defaults `nas_identifier` to the same value, so a WLAN's first push is right too |
| Through openUF (`unifi_ft_interop = true`, HH5A adopted into a UCG Ultra), the running hostapd config carries exactly the FT options of the hand-made config | ✅ U7 → HH5A `auth_alg=ft`; ✅ HH5A → U7, WiFiman reports "AP roaming". One full reconnect followed a disconnect with no FT attempt logged: not a failed fast transition, cause not established | Same options generated; nothing observed here |
| The translator's roam announcements (`UBNT_ROAM`, ethertype `0x890d` to `01:80:c2:00:00:1c`: `01 f0 1a 00 \| sender BSSID \| wlan_id (= mobility domain) \| AES key wrap (RFC 3394, the r0kh key) of [time LE32, client MAC]`) make the UniFi AP drop a client the moment it arrives on OpenWrt, so the controller lists the roam on time with its Fast Roaming tag | Their 1.3 walk tests with openUF | Lives entirely in the translator (it reads the wildcard `r0kh` key from the running hostapd config); openUF writes nothing for it |

**Checked here, 2026-10-25, in the QEMU VM** (OpenWrt 25.12.6 armsr, two mac80211_hwsim
radios, internet over its WAN; no controller, no UniFi AP). `openuf deps --install
--only-rrb-unifi` on a box without the translator: installed `ucode-mod-socket` and
`kmod-veth`, fetched the four files from the fork (`yesrab/unifi-openwrt-roaming` at `main`,
translator 1.3), the setup tool wrote `network.vft`/`ftlink`/`ftpeer`, the guarded network
reload created `vft0`/`vft1` and the confirmation file landed, the service was enabled and
started, four lines went into `/etc/sysupgrade.conf`; `--check` then reported
`installed/veth/running` true. A second run said "current" and changed nothing. Then the
interop option set by hand on the hwsim AP's `wifi-iface` (`ieee80211r`, `mobility_domain
5de5`, `ft_psk_generate_local 0`, `pmk_r1_push 1`, one peer plus the wildcards in
`r0kh`/`r1kh`, `hostapd_bss_options 'ft_iface=vft0'`): the BSS came up; `/var/run/hostapd-
phy0.conf` carried the generator's own `ft_iface=br-lan` followed by `ft_iface=vft0` from the
raw option, `wpa_key_mgmt=WPA-PSK FT-PSK`, the key-holder lines and `reassociation_deadline=
20000` (25.12's default); `/proc/net/packet` showed hostapd's `0x88b7` socket bound to
`vft0`'s ifindex (and the translator's two on `vft1` and `br-lan`); `rrb-unifi check` said
`phy0-ap0 ... ft_iface=br-lan,vft0 -> served, BSSID 02:00:00:00:00:00, hostapd up`, `LAN
interface: br-lan (derived)`, `UBNT_ROAM on`, `check OK`. The install path and the OpenWrt
side are therefore proven on the target release; what remains unproven here is the roam
itself against a UniFi AP (REVERSE-ENGINEERING.md backlog row 25).

**Made part of openUF, 2026-10-25 (later the same day).** The translator is no longer an
external install: d-malinowski's `rrb-unifi.uc` (1.3, `767a28c`) is vendored as
`openuf/rrb/rrb-unifi.uc` (`openuf/rrb/README.md`; its GPL-3.0-or-later is why the whole
repository moved from MIT to GPL-3.0-or-later the same day, NOTICE keeping jonasevcik's MIT
notice) and runs as the
`openuf-rrb` service, with two changes marked `// openUF:` in the file: with `RRB_WAIT=0` it
waits for the veth pair and for a BSS on it instead of exiting, and it records every UniFi
BSSID it hears on the LAN in `/var/run/openuf/rrb-peers.json`, with the WLAN's mobility
domain once a roam announcement verified with that WLAN's key names it. openUF creates the
veth pair itself (`ucihelper.ensure_ft_veth`, netifd sections in `/etc/config/network`, on
the first config push with an FT WLAN; removed on Forget), keeps the learned peers in
`state.json` and forgets `cfgversion` so the controller re-pushes and they become key holders
(inform's `_rrb_peers_tick`, at most once every ten minutes), restarts the daemon after a push
that put a BSS on the veth, and only ever points hostapd at the veth while the service is
installed and enabled. The setup tool's `collect`/`verify`/`peers` live on as `openuf rrb`.
The learning replaces their SSH-into-the-UAP step on the assumption their own data supports:
a UniFi AP's R0KH-ID is its BSSID without colons (`nas_identifier=$bssid` in UniFi 8.7.11's
hostapd config, which their `collect` read). Unverified here: that a UniFi AP's roam
announcements reach this AP's LAN bridge on a real site (their 1.3 walk tests say they did,
with the standalone translator). The fork `yesrab/unifi-openwrt-roaming` is not used.

**The built-in translator checked in the VM, 2026-10-25.** Same VM, from a clean slate (the
standalone translator removed, its veth and sections deleted). The tree pushed with
`vm/install.sh`: `openuf-rrb` enabled and running, the daemon logging `waiting for the veth
pair vft0/vft1` since nothing had created it; `openuf rrb status` and `openuf deps --check`
agreeing (installed, enabled, running, no veth, no peers). Then the push's two steps by hand:
`ucihelper.ensure_ft_veth` wrote `network.openuf_ftveth` (veth, `vft0`/`vft1`) with the two
proto-none interfaces, reloaded the network and returned true with `vft0` up, upon which the
daemon logged `waiting for a hostapd BSS on ft_iface=vft0`; `ftinterop.apply` produced the
expected options (UniFi domain `5de5`, `ft_psk_generate_local 0`, a learned peer plus the
wildcards, `hostapd_bss_options ft_iface=vft0`, the deadline deleted, the nasid note since
the BSSID was not given), written to the hwsim AP and reloaded; after the restart
`apply_config` performs, the daemon reported `running: hostapd side vft1 (ft_iface vft0),
lan side br-lan, BSSes: phy0-ap0=02:00:00:00:00:00`, `check OK`, `UBNT_ROAM on`, and
`/proc/net/packet` had hostapd's `0x88b7` socket on `vft0`'s ifindex with the daemon's on
`vft1` and `br-lan`. A peers file in the daemon's format was read back by `openuf rrb peers`,
`ftinterop.learned` and the deps JSON (`learned: 2`). `ucihelper.forget` removed the three
network sections, `vft0` disappeared, the daemon exited on `recv(): Network is down` and
procd respawned it straight back into `waiting for the veth pair`. One defect found and fixed
by this run: two apostrophes inside the single-quoted package table of `openuf-deps.sh`
truncated the table on the device (every `--check` printed `PACKAGES: parameter not set`);
the rows are reworded. Not checked here, for want of a UniFi AP: a roam, a real UBNT_ROAM
announcement reaching the peers file, and `openuf rrb collect`/`verify` against a UAP.

Not adopted as-is: nothing from the commit was left out. Two of this tree's choices differ in
emphasis rather than behaviour. The `nasid` log line says hostapd's default covers a push with
no BSSID yet, where theirs reads as a gap. And the raw `hostapd_bss_options 'ft_iface=vft0'`
is kept on purpose even though 25.12 has a first-class `ft_iface` UCI option: the translator
derives a BSS's LAN bridge from the `ft_iface=` line the generator writes before the override
and its `check` tells the user to set `hostapd_bss_options`, and 24.10 has no such option.
`reassociation_deadline` goes back to OpenWrt's default under the switch (20000 TU on 25.12,
1000 on 24.10), the timing their validation ran with; whether UniFi's 3000 would do as well is
untested and the only open question the adoption adds.

## Feature matrix

Every controller-UI control exercised against a live openUF device. "Confirmed" means driven
through the real UI with the resulting wire payload captured or the effect verified.

| # | Control / feature | Wire mechanism | Status |
|---|---|---|---|
| 1 | Adopt (L2/SSH, L3/mgmt_cfg) | SSH `syswrapper.sh set-adopt`, or `authkey` in `mgmt_cfg` | ✅ Confirmed both paths |
| 2 | Baseline post-adopt inform | `setparam` + `mgmt_cfg` | ✅ Confirmed |
| 3 | SSID push (no VLAN) | `system_cfg` `aaa.*`/`wireless.*`/`radio.*` | ✅ Confirmed |
| 4 | VLAN-tagged network + SSID assignment | `aaa.<n>.br.devname = br0.<vlan>` | ✅ Confirmed. The switch trunk carries the CPU port and the uplink socket only — tagging the LAN sockets deafens untagged wired clients on `ar8216`-family switches, where the tag flag is one global per-port bitmask |
| 5 | Fast Roaming (802.11r) | `aaa.<n>.ft.status` only | ✅ Confirmed by byte-for-byte `system_cfg` diff, both directions |
| 6 | TX power / channel per radio | `radio.<n>.channel`/`.txpower`/`.txpower_mode` | ✅ Confirmed |
| 7 | Locate | `cmd:"set-locate"` | ✅ Confirmed, including the **LED hardware effect on a real board** (Archer C5, `dev.conf.led = "green:system"`): `locate_start` writes `trigger=timer` + 250/250 ms, `locate_stop` restores `trigger=none`, and the Manage → LED toggle drives `brightness` 1/0 |
| 8 | RF/spectrum scan trigger | `cmd:"spectrum-scan"` | ✅ Handler exercised **against real radios** — 27 channels on 5 GHz, 13 on 2.4 GHz, with genuine per-channel utilization and noise. Still **no manual trigger control exists anywhere in 10.4.57's UI** (AirView is passive), so it has never been fired *by the controller*; the handler was invoked directly on the device. |
| 9 | Firmware upgrade | `_type:"upgrade"` | ✅ Confirmed. openUF stores `upgrade_requested_version`/`_url` and logs — it never downloads, verifies, flashes, or reboots. Verified live: no side effects, device stayed Connected. The pushed `md5sum`/filename match Ubiquiti's real CDN artifact byte-for-byte. |
| 10 | Forget device / factory reset | `_type:"setdefault"` | ⚠️ UI action and server-side deletion work, but **no `setdefault` was ever dispatched on the wire**; handler unverified. See [open questions](#open-questions). Since 2026-09-28 the handler (and the `reset-inform` path) also tears down the l2guard table, the controller's cron block and a controller-set inform interval -- unit-tested only. |
| 11 | `fw.ver` acceptance | — | ✅ Accepted verbatim, no validation beyond storage |
| 12 | Restart | `_type:"reboot"` (top-level, **not** `cmd:"restart"`) | ✅ Confirmed; real container reboot observed |
| 13 | Manage LED on/off | `mgmt_cfg` `led_enabled` | ✅ Confirmed both values live. `led.set_enabled()` uses `trigger=none` + `brightness=1/0`, distinct from the locate blink's timer trigger. |
| 14 | IP Settings (DHCP/Static) | `system_cfg` `netconf.*`/`dhcpc.*`/`route.*` | ✅ Confirmed end-to-end: real kernel interface change, real route, informing from the new address, controller Overview reflecting it back |
| 15 | Power / PoE | `power_source`, `power_source_voltage`, `psu_table`, `power-monitor`, `total_max_power`, `led_state`, `outlet_table` — copied straight off the inform when present | 🔍 Not implemented. The "Power: -" element lives in the **Parent Device** subsection (properties of the upstream LLDP-linked switch), and this environment has no PoE switch. Field names confirmed; values/format not researched, and openUF has no local signal for a real PoE class. |
| 16 | Set Replacement Device / Load Configuration | **None** — controller-side Mongo document clone (`commonDeviceCloneConfigService`), then an ordinary adopt + `setparam` | ✅ Both confirmed live; zero product code needed. Replacement auto-adopts the target ~50 s after the source goes away. |
| 17 | Wired clients | `port_table[]` + per-port `mac_table[]` | ✅ Confirmed live: both fake hosts under Connection → Wired, on the correct port; Ports view renders them. Hosts are placed on the physical socket the switch learned them on (ARL table) as of 2026-08-02 — before that, real wired clients behind an AP were reported by nobody and the controller credited them to the gateway's port. Extended 2026-09-13 (from upstream's 2026-09-12 work): each socket is asked about its OWN bridge, a socket whose MAC learning is off is served by the `bridge openuf_learn` nft tap, and rows carry `vlan` (+ a tap-harvested `ip`) — which is what puts the client on the right **network**, not just the right port. See [Adopted from upstream, 2026-09-13](#adopted-from-upstream-jonasevcikopenuf-2026-09-13) |
| 18 | Per-port VLAN assignment | `fw_caps` bit `0x100`; controller pushes `switch.*` | ⚠️ Wire format fully mapped live 2026-07-19 (gate, per-VLAN table, per-port `pvid` + tagged/untagged/exclude matrix, teardown). The **controller side** is confirmed — it accepts the assignment and pushes an actionable table. Device-side apply on swconfig is unverifiable here (the validation AP has no switch); on DSA it is a bridge move adopted from upstream, verified there on an mt7530 — see [Adopted from upstream](#adopted-from-upstream-jonasevcikopenuf-2026-09-06). Note it was unreachable on both real boards until 2026-08-02: the only port they reported was the uplink, which is exactly the port that must never be reassigned |
| 19 | Client block / unblock | `cmd:"block-sta"` / `"unblock-sta"` | ✅ Confirmed live including real nftables enforcement and survival across a simulated reboot. `hostapd_cli` deauth is unit-tested only (no real hostapd here). |
| 20 | Environment / rogue-AP scan | `scan_radio_table[]` | ✅ openUF's payload and the controller's ingestion both confirmed correct (10/10 direct API polls). The tab's own display bug is [controller-side](#controller-side-ui-quirks). Since 2026-09-28 a sibling openUF AP is tagged `is_unifi`/`serialno` from its vendor element and non-ASCII SSIDs are decoded (both upstream's evidence, see [Adopted from upstream, 2026-09-28](#adopted-from-upstream-jonasevcikopenuf-2026-09-28)). |
| 21 | Radios tab + client MIMO/generation | `radio_table` capability fields; per-station `nss`/`is_11*` | ✅ Confirmed live on four stations spanning HT/VHT/HE/legacy |
| 22 | Radios tab Avg. Signal / Interference / Airtime / MIMO | `vap_table.avg_client_signal`; `radio_table.athstats`; `radio_table.radio_caps` | ✅ All four confirmed live on a fresh reset (`-64`/`-50 dBm`, `3%`, `7%`, `2x2`), with bidirectional filter behavior verified |
| 23 | Minimum RSSI | `system_cfg` `stamgr.<n>.*`; outbound `min_rssi`/`min_rssi_enabled` | ✅ Wire format and field names confirmed; conversion is the fixed `raw - 95` (corrected 2026-09-06 — the live-noise-floor version was wrong on every radio but one). Enforcement (`kick_station`) is unit-tested only — no real radios here. **Since 2026-10-18 it is the firmware's two halves** (upstream's reading of 4.0.15, see [Adopted from upstream, 2026-10-18](#adopted-from-upstream-jonasevcikopenuf-2026-10-18)): hostapd refuses probes and authentication at threshold + 3 dB, and the kick comes only after 30 s below on the driver's averaged signal (`minrssi.lua`), so a weak client no longer loops kick → rejoin. Not yet on AP1/AP2 |
| 24 | Security tab WPA2/WPA3 protocol options | **None** | ℹ️ Not capability-driven from anything openUF sends. No security-capability field exists in the payload; `ucihelper`'s `SECURITY_MAP` (`wpa2`→`psk2`, `wpa3`→`sae`, `wpa2/wpa3`→`sae-mixed`, `wpa-enterprise`→`wpa2+ccmp`) is a one-way map of a choice the controller has already made. The dropdown's options come from the controller's own internal per-model database, keyed on the reported `model`/`platform`. Not fixable here. |
| 25 | Band Steering / BSS Transition / DTIM | `wireless.<n>.no2ghz_oui` / `aaa.<n>.bss_transition` / `wireless.<n>.dtim_period` | ✅ All three confirmed live by individual before/after `system_cfg` diffs. The off switch was inert until 2026-09-28 (`band_steering_threshold` is not usteer's switch; `band_steering_interval` is -- upstream's evidence, in the running daemon). |
| 26 | Show AP Name in Beacon | `wifi_caps2` bit `0x40` → `wireless.<n>.advertise_ap_name` | ⚠️ Wire protocol and capability gating confirmed live, both directions. **The OpenWrt side does not work and is not implemented.** openUF writes `wps_device_name` + `ap_setup_locked` (both valid wifi-iface options — present in the schema and in `/usr/share/ucode/wifi/`), but OpenWrt emits the WPS/WSC block that carries `device_name` only under `if (config.wps_possible && length(config.config_methods))` (`ap.uc:227`), and `config_methods` is populated solely from `wps_pushbutton`/`wps_label`. openUF sets neither, so WPS never activates and no WSC Device Name IE reaches a beacon. Upstream verified 2026-09-10 on an Archer C5 (ath79) and an AX3000T (filogic), both 25.12.5, same gate on both; no live BSS conf carries any WPS key. Turning WPS on to broadcast a name trades a real security surface for a cosmetic feature — deliberately not done. |
| 27 | SAE Anti-clogging / Sync Time | `aaa.<n>.sae.anti_clogging` / `.sae.sync` | ❌ **Not applicable on OpenWrt.** Key names, integer shape and `isWpa3()` gating are confirmed via an unambiguous decompiled method body, and the emitting (true WPA3) case could not be live-diffed — forcing pure WPA3 tripped the [config-sync issue](#config-sync-can-get-stuck-after-informs-stabilise). It does not matter: `sae_anti_clogging_threshold` and `sae_sync` are real hostapd config keys but are **not** wifi-iface UCI options. Upstream verified 2026-09-10 on an Archer C5 (ath79) and an AX3000T (filogic), both 25.12.5, against all three places an option can be declared — the wifi-iface schema, `/usr/share/ucode/wifi/` and `hostapd.sh`'s `config_add_*` lists. Neither name appears in any of them, on either board, so openUF's writes were stored in UCI and dropped in silence. Both writes removed (2026-09-13 here); the wire keys are no longer parsed either, since nothing could consume them. |
| 28 | PMF (802.11w) / Multicast Enhancement | `aaa.<n>.pmf.status`/`.pmf.mode`; `wireless.<n>.mcast.enhance` | ✅ Confirmed live by `system_cfg` diff. PMF is what actually carries WPA2/WPA3 transition intent on this model. |
| 29 | Channel width | `radio.<n>.ieee_mode` → `wifi-device.htmode` | ✅ Confirmed live both directions: `11nght20`↔`11nght40` follows the per-AP 2.4 GHz Channel Width control, and the pushed value reaches UCI (`radio0` `HT20`, `radio1` `HT40`). Previously parsed by nothing, so width never applied. |
| 30 | IoT Optimization: Lock 2.4 GHz to Channel 6 | `radio.<n>.channel` (no dedicated key) | ✅ Confirmed live end-to-end: the toggle changes the 2.4 GHz radio's `channel` from `auto` to `6`, and UCI `radio0.channel` follows (verified 11 → 6, so it is not a coincidence of the default). |
| 31 | IoT Optimization: DTIM Interval Lock | `wireless.<n>.dtim_period` (no dedicated key) | ✅ Confirmed live end-to-end: pins the 2.4 GHz vap's `dtim_period` to `3` (REST `iot_dtim_lock` → `dtim_ng: 3`), which reaches UCI. |
| 32 | IoT Optimization: Force WiFi 4 Mode | `wireless.<n>.iot` + `wireless.<n>.qbssload` | ✅ **Fully confirmed on real hardware** (JIDU6101 / MT7986, OpenWrt 25.12.5, UCG Ultra 10.6.101). Wire signature by before/after diff: `wireless.1.iot=enabled`, `wireless.1.qbssload=disabled`, `wireless.1.parent=radio0` — 2.4 GHz only, the 5 GHz VAP is dropped from the push entirely. Both keys reach UCI (`openuf_iot=1`, `bss_load_update_period=0`), and the previously-unverified hostapd side was read back out of the generated `/var/run/hostapd-phy0.conf`: `bss_load_update_period=0`, `bss_transition=0`, `ieee80211w=0`, `wpa=2`, `wpa_key_mgmt=WPA-PSK`. **`radio.<n>.ieee_mode` is NOT changed by this mode** (stayed `11nght40`), which is what makes a board `htmode_floor` collide with it — see the suppression in `ucihelper.rf_config`. |
| 33 | Proxy ARP / Client Isolation | `aaa.<n>.proxy_arp` / `wireless.<n>.l2_isolation` | ✅ Confirmed live 2026-07-18 by REST-toggling `wlanconf.proxy_arp` + `l2_isolation` and diffing `system_cfg`: exactly these two keys flipped `disabled`→`enabled`, on **both** the 2.4 GHz and 5 GHz entries of the WLAN, nothing else moved. Both are always present on their block, so "off" is explicit. `proxy_arp` had been visible in the Force WiFi 4 Mode diff all along but was never parsed. |
| 34 | Minimum Data Rate Control | `wireless.<n>.minrate_data` (+ `beacon_rate`, `mgmt_rate`, `minrate_cck_rates.status`, `minrate_below_disable`, `pureg`) | ✅ Confirmed live 2026-07-18 by REST-setting `minrate_setting_preference=manual` + `minrate_ng_data_rate_kbps=12000` and diffing: `minrate_data`/`beacon_rate`/`mgmt_rate` 1000→12000, `minrate_cck_rates.status` true→false, `pureg` 0→1. Separately confirmed **not band-gated** — enabling `minrate_na` (24 Mbps) made the same keys appear on the 5 GHz entries. **The OpenWrt side is radio-level**, not per-BSS (verified in OpenWrt's `hostapd.sh`: these are `hostapd_common_add_device_config` options), so openUF aggregates a radio's VAPs to the most permissive floor. Note `beacon_rate` is passed to hostapd **verbatim in 100-kbps units** while `basic_rate`/`supported_rates` are divided by 100 by `hostapd_add_rate` — openUF converts only the former. Not verified on real hardware. |
| 35 | Multicast and Broadcast Blocker | `wireless.<n>.bcfilt.status` + `bcfilt.<k>.mac`/`.status` | ✅ Wire format confirmed live 2026-07-18 across four diffs (on with one MAC, with two MACs, on with an empty list, off). Two keys already on the wire were **excluded** as candidates by the same diffs: `radio.<n>.bcmc_l2_filter.status` (sits at `enabled` with the control off) and `wireless.<n>.multicast.inspect` — neither moved. ⚠️ Enforcement is openUF's own nftables ruleset (`bridge openuf_bcfilt`), since no hostapd/OpenWrt option expresses a multicast allow-list; the generated ruleset is verified against real nftables 1.0.9 and confirmed not to collide with `firewall.lua`'s table, but the on-air effect is unverified (no real radios). |
| 36 | Hide WiFi Name | `wireless.<n>.hide_ssid` (+ duplicate `aaa.<n>.hide_ssid`) | ✅ Confirmed live 2026-07-18 by toggling the control in the UI and diffing `system_cfg`: exactly those two keys flipped `false`→`true`, on both band entries of the WLAN, nothing else moved. Always present, so "off" is explicit and is written back out as `hidden=0`. Note the `true`/`false` vocabulary rather than `enabled`/`disabled`. Previously **documented in USAGE.md as already applied, but no code read or wrote it** — the same doc-vs-code drift as `use_only_unifi_wlan`. |
| 37 | MAC Address Filter | top-level `macacl.<m>.*`, joined on `wireless.<n>.devname` | ✅ Confirmed live 2026-07-18 by enabling the control with one allow-listed MAC and diffing `system_cfg`: the whole `macacl` section appeared at once, keyed by devname (`ath0`/`ath2`) and numbered independently of `wireless.<n>`, so **the devname join is mandatory**. Two keys already on the wire were **excluded** by the same diff: `wireless.<n>.mac_acl.status`/`.policy` (sit at `enabled`/`deny` with the control off) and `aaa.<n>.radius.macacl.status` (the separate RADIUS MAC Authentication control). → OpenWrt `macfilter` + `maclist`, whose allow/deny vocabulary matches the controller's 1:1. Enforced by hostapd itself, so no openUF-side ruleset is involved. |
| 38 | WiFi Speed Limit | top-level `qos.vap.<m>.*`, joined on `wireless.<n>.devname` | ✅ Wire format confirmed live 2026-07-18 by creating a speed-limit profile (33/17 Mbps) and assigning it to a WLAN. Values are **kbps**, and the discriminator is the presence of `maxspeed` — an unlimited vap still gets a block, carrying only `minspeed` set to its raw `devspeed`. ~~The cap is a per-VAP aggregate, not per-client.~~ **Per client** (corrected 2026-10-18 from upstream's firmware reading: one HTB class per station, both directions queued, and `cmd: rate-update {mac, ul_max, dl_max}` is a per-client override for any client, lasting one association). Requires a profile to exist before the per-WLAN toggle does anything. ⚠️ Enforcement is openUF's own `tc` ruleset (`shaper.lua`), since no hostapd/OpenWrt option expresses a throughput cap: HTB on egress for downlink, ingress policing for uplink. Every generated command is verified against real tc (iproute2 6.9.0), but the on-air throughput is unverified (no real radios). |
| 40 | Controller-scheduled `11k-scan` (cron) | `system_cfg` `cron.*` → `/etc/crontabs/root`; `syswrapper.sh 11k-scan` → the daemon's neighbour scan | ✅ Wire confirmed live 2026-09-15 (AP2). Device side: the block is written, crond runs it, the verb leaves a request the next heartbeat consumes, `iw scan` runs on every radio and the following inform carries the fresh `scan_radio_table`. Verified on AP2 by running the verb by hand — the 04:00 firing itself has not been waited for. |
| 41 | NTP servers and timezone | `system_cfg` `ntpclient.<n>.server`, `system.timezone` → UCI `system.ntp.server`, `system.@system[0].timezone` | ✅ Wire confirmed live 2026-09-15. On AP2 the timezone already matched (setup.sh had asked the same question) and the server list moved to `*.ubnt.pool.ntp.org` with the OpenWrt pool stamped as `openuf_ntp_orig`. Whether the jailed `sysntpd` then syncs is the open question from the same day: it had not in 30 minutes on the OpenWrt pool either, and the clock was stepped by hand. |
| 42 | `ebtables.*` hardening | `system_cfg` `ebtables.<n>.cmd` → nft `bridge openuf_l2guard` on the AP VAPs | ⚠️ Wire confirmed live 2026-09-15; the three generated rules are accepted by nft on AP2 (kmod-nft-bridge present). On-air effect (a client's BPDU or tagged frame actually dropped) not verified. Since 2026-09-28 the VAP list is re-read once a minute and the table is removed on a factory reset (unit-tested). |
| 39 | Ports view Connection column on an **uplink** port | `port_table[]` with **no** `mac_table` field on `is_uplink` ports | ✅ Blank (or a retained stale value) is the CORRECT state, verified upstream 2026-09-12. Reporting the one MAC on the other end of the cable is tempting — openUF knows it, since finding it is how the uplink socket is identified, and a real UniFi gateway visibly does it on its own uplink port — but it would invert the topology map: the controller files a known device seen alone on a port into this device's `downlink_table`, and the `isUplinkMac` guard against that is ANDed with `!is_uplink`, so it disables itself on exactly the port where it is needed. The gateway would hang beneath every AP that reported it. A real gateway escapes it only because the ISP's router is not an adopted device. Live proof of the correct shape: both of upstream's APs' `downlink_table` empty, the gateway's holding both APs. The stale text persists because `last_connection` is never recomputed when a port sends no `mac_table` field (and only ever recomputed when a port reports exactly **one** MAC) — clear it with the Ports view's **Clear Last Seen Device**. |
| 43 | Roaming Assistant | `wifi_caps2` bit `0x20` → `wireless.<n>.btm_disassoc.status`/`.threshold` (5 GHz entry only) | ⚠️ Adopted 2026-09-28. Upstream: wire, gate and teardown confirmed in their lab and against a real UCG Ultra; a −80 dBm client moved to a −61 dBm AP on real radios. Nothing between AP1 and AP2 yet |
| 44 | Device-level Band Steering (Prefer 5G / Balance) | `wifi_caps` bits `0x4`/`0x8` → `bandsteering.status`/`.mode` + `bandsteering.<n>.vap.<k>.devname` | ⚠️ Adopted 2026-09-28. Upstream: the real controller sends the block, Prefer 5G brings usteer's default interval back, Off sends `status=disabled`; a client steered by the device setting alone not observed. **AP2, 2026-09-28:** the real UCG Ultra sent `bandsteering.status=disabled` on the first push after the deploy (device setting Off); usteer was restarted with the old threshold removed and `openuf_active=1` |
| 45 | Airtime Fairness | `wifi_caps` bit `0x20` → `atf.status`/`atf.mode` → `/sys/kernel/debug/ieee80211/phyN/airtime_flags` | ⚠️ Adopted 2026-09-28. Upstream: On written and read back on four radios against the real controller; Off lab-only. The controller may hold `atf_enabled: false` from before the bit was claimed. **AP2 (mt7986/mt76), 2026-09-28: Off confirmed on hardware here** -- the first push after the deploy carried `atf.status=enabled`, `atf.mode=disabled` (the controller had held the setting from before the bit was claimed, exactly as upstream found) and both phys' `airtime_flags` read back empty; the scheduler stays off until the device panel says On |
| 46 | Enhanced Open (OWE) incl. transition | `radio_caps2` bit `0x8` → `wpa.key.1.mgmt=OWE` (+ `owe_devname` pair) → `encryption=owe`, `owe_transition=1` | ⚠️ Adopted 2026-09-28; upstream's lab wire capture only. No OWE BSS on any real AP |
| 47 | Private Pre-Shared Keys | `wifi_caps` bit `0x100000` → `aaa.<n>.wpa.psk_file.<k>.psk`/`.vlanid`, `dynamic_vlan=1` → `wifi-station` + `wifi-vlan` sections | ⚠️ Adopted 2026-09-28; upstream's lab wire capture through to UCI. No VLAN-key client on any real AP |
| 48 | FT on a WPA3-only WLAN | `radio_caps2` bit `0x2` | ⚠️ Adopted 2026-09-28; upstream's lab wire diff. An FT-SAE roam on a WPA3-only WLAN not verified on hardware |
| 49 | Sibling-AP recognition | `vendor_elements` on every VAP → `scan_table[].is_unifi`/`.serialno` | ⚠️ Adopted 2026-09-28; upstream saw the flags clear on their two APs. AP1/AP2 not on this build yet. **AP2, 2026-09-28:** after the forced re-push `vendor_elements=dd0d026f556f5546 01 <MAC>` is in both hostapd configs and on all three VAPs in UCI; AP1 not yet on this build, so no `is_unifi` tag has been seen on the wire. **✅ AP2 → AP1, 2026-10-03:** with both on the sibling-element build, AP2's `scan_radio_table` carries AP1's three BSSes with `is_unifi: true` and `serialno: <AP1 MAC>` (5 GHz ch 100 at −10 dBm, in 23 of 40 informs), and the controller's `stat/rogueap` (26 third-party rows) lists none of them — recognised, not flagged. (A device's own `stat/device` record never shows its scan table; look in `stat/rogueap`) |
| 50 | WLAN Schedule | `wireless.<n>.schedule_enabled` + `schedule_<day>[.<i>]` on-time blocks (`fw_caps` `0x1000` claimed; `0x400000` not, so the controller inverts the blackout windows itself) | ⚠️ **Implemented 2026-10-18** from upstream (`wlansched.lua`): the firmware's schedule lines are stored on the wifi-iface and checked every heartbeat; outside them the BSS netdev goes down, inside them up with the beacon restarted. Nothing moves until the clock is trusted (a controller answer's `server_time_in_utc` within 60 s of the local clock). Confirmed on upstream's hardware; unit-tested only here |
| 51 | Wireless uplink / mesh | `wifi_caps` `0x1`+`0x800` → `wireless.<n>.usage=uplink\|downlink`, `wds=enabled`, `mesh.*` → `openuf_bh_dl_*` (hidden `wds 1` AP) / `openuf_bh_ul_*` (4addr `sta`, wired-first policy); reported back as `usage`-typed VAPs, `uplink` = the uplink VAP's name, the parent as its one station with `serialno` | ✅ **Verified end to end 2026-10-03** (AP2 cable pulled → joined AP1's downlink at −10 dBm, informed over the hop, VLAN-10 client reached its network; controller: AP2 `uplink.type=wireless`, `uplink_mac`=AP1, `is_mesh_v3`, `uplink_table`=[AP1], AP1 `wireless_downlink_macs`=[AP2]). Wire-return path verified 14:07 UTC (station disabled on the first heartbeat, controller back to the LLDP uplink). Multi-hop not yet exercised. Bits claimed by default; on swconfig boards since 2026-10-18, first run 2026-10-19 on a Deco M4R v1 (user, shallow: online over the wireless uplink with the cable pulled; cable-back and tagged SSIDs across the hop not yet confirmed there) |
| 52 | Quick Scan (Radios → Quick Scan; Radio AI prescan) | `wifi_caps2` `0x80` → `cmd: quick-scan {scan-band: 0\|1\|2, scan-bw: 20\|40\|80\|160}`; device: `quickscan_scanning` + `radio_table[].spectrum_table`/`spectrum_table_time` + an `EVT_AP_QuickScanEvent` notification inform | ✅ **Verified live 2026-10-03** on AP2 against 10.6.106: the REST cmd arrived (`cmd: quick-scan` in the log), the controller's `quick_scan_state` went `in_progress` and back, the event stamped `spectrum_scan_timestamp` and `stat/spectrum-scan` carries the rows — see [RF scans](#rf-scans-airtime-scan-quick-scan-and-radio-ais-sweep--2026-10-03) |
| 53 | Airtime Scan (Radios → Airtime) | `wifi_caps` `0x10` (RF_SCAN; the view also checks `wifi_caps2` `0x2` MONITOR_RF_SCAN) → `cmd: spectrum-scan`; device: `spectrum_scanning` + the same per-radio tables | ✅ Same handler and same live run (`cmd: spectrum-scan` arrived, every radio swept). The result view reads `stat/spectrum-scan`, never the device DTO (which strips the tables unless a scan is running) |
| 54 | Radio AI neighbour sweep | `cmd: scan_band {band: ng\|na}` (the controller's own scheduler, `XbYOtjBEpjeHWlUU`; it sets `scanning` and reads the next inform's `scan_radio_table`) | ✅ Handled 2026-10-03: a forced sweep on the named band; the verb itself was captured on AP1 2026-10-02 |
| 55 | Discovery requests (WiFiman Discovery, UniFi app, Device Discovery Tool) | UDP 10001 probes `01 00 00 00` / `02 08 00 00`, answered unicast with the announce TLVs under version 1 / command 0 and version 2 / command 9 | ✅ **Verified live 2026-10-03**: AP2 answered both probes (4 replies) after answering none; a UCG Ultra answers them identically — see [Discovery requests and WiFiman](#discovery-requests-and-wifiman--2026-10-03) |
| 56 | WiFiman (Settings → System → WiFiman) | Console-side only: `mgmt.wifiman_enabled` is never pushed to an AP; the app reads `/v2/api/site/<site>/wifiman/<its own IP>` on the console | ✅ **Verified live 2026-10-03**: the console answered fully for a laptop connected through openUF's AP1 (channel, link rates, experience history, `uplink_devices` chain, `nearest_neighbors` from openUF's scans). Nothing to implement in the inform; the device-side gap was row 55 |
| 57 | Load balance (per-radio client cap) | `stamgr.<n>.loadbalance.status`/`.maxsta` → `loadbalance_maxsta` on the wifi-device | ⚠️ Adopted 2026-10-18 (upstream's firmware reading): the most idle stations above the cap are kicked once per inform, Minimum RSSI's kicks not counted. REST-only in the 10.6 UI |
| 58 | Client → Reconnect | `cmd: kick-sta {mac}` | ⚠️ Adopted 2026-10-18 (upstream's 10.4.57 cmd audit): a one-shot deauth on every BSS, no ledger |
| 59 | Site block list on every push | `setparam blocked_sta` (newline-separated MACs; present-but-empty clears) + hostapd deny ACL | ⚠️ Adopted 2026-10-18: the ledger is replaced and the nft set rebuilt only when the set changed; `firewall.deny_sync` keeps hostapd refusing the MACs, re-checked once a minute, on a control-socket change, and for 60 s after openUF's own `wifi reload` |
| 60 | U-APSD / Group Rekey / per-WLAN 802.11k | `wireless.<n>.uapsd`, `aaa.<n>.wpa.group_rekey`, `aaa.<n>.11k.status` → `uapsd`, `wpa_group_rekey`, `ieee80211k` + `rrm_*_report` | ⚠️ Adopted 2026-10-18, firmware-confirmed by upstream for 4.0.15. With the controller's default (U-APSD off) SSIDs no longer advertise it. **AP2's first push, 2026-10-18:** `uapsd` 1 on two WLANs and 0 on one, `wpa_group_rekey=0` on all three, `ieee80211k=1` on all three -- this site's wire, written to UCI |
| 61 | 802.11r key holders and PMK-R1 push | `aaa.<n>.iapp_key` → wildcard `r0kh`/`r1kh`; `pmk_r1_push=1`, `reassociation_deadline=3000`; `rrbguard.lua` | ⚠️ Adopted 2026-10-18 (upstream's hostapd-template reading + their office AP's stale-socket incident). Without the key OpenWrt derives one from the passphrase, which anyone with the passphrase can compute. **AP2's first push, 2026-10-18:** both FT WLANs got their `r0kh`/`r1kh` pair, `pmk_r1_push=1` and the 3000 TU deadline. An FT roam between AP1 and AP2 on this build not yet observed (AP1 not yet on it) |
| 62 | Forget tears the controller's config down | `setdefault` / `reset-inform` → `ucihelper.forget`, `switchvlan.restore`, usteer off, LED back | ⚠️ Adopted 2026-10-18: a forgotten AP has no controller SSID, VLAN bridge, radio extra, per-port VLAN or cron job left, without a reboot; the inform URL that reached the controller is kept (an L3 re-adopt over the default host name fails HTTP 400, upstream 2026-10-11). Row 10's caveat (no `setdefault` ever seen on this wire) still stands |
| 63 | WiFi Experience, the firmware's formula | `sta_table[].satisfaction`/`satisfaction_reason`/`anomalies`, `vap_table[].anomalies_bar_chart`/`reasons_bar_chart`, `radio_table[].athstats.satisfaction`, device `satisfaction` (−1 with no clients) | ⚠️ Adopted 2026-10-18 (`satisfaction.lua`, ported by upstream from `libubnt.so` 4.0.15). Replaces this tree's estimate; the Experience column on AP1/AP2 not yet compared against the previous build |
| 64 | Client fields as the firmware sends them | `rssi` (SNR), `noise`, `state` `0x10`, `is_11r`, `tx_retries`, `wifi_tx_dropped`; `wifi_tx_attempts` = frames sent; no `capacity`/`throughput`/`linkscore`/`multicast` | ⚠️ Adopted 2026-10-18. Power save is absent on mt76 (the driver takes PS tracking over). The `linkscore`/`multicast` open question is closed: the firmware never sends them |
| 65 | `sys_stats`, vap `extchannel`, windowed channel utilisation | `sys_stats.loadavg_1/5/15` + `mem_*` bytes; `vap_table[].extchannel` (±1); `cu_*` over the last inform | ⚠️ Adopted 2026-10-18: the UI's Load Average and the 40 MHz side come from these; utilisation no longer reports a lifetime average |
| 66 | STUN wake-up | `mgmt_cfg stun_url` → `stun.lua` (RFC 3489 Binding Request with CHANGE-REQUEST every 30 s); `connect_request_ip`/`connect_request_port` in the inform; a type `0x8888` datagram ends the sleep | ⚠️ Adopted 2026-10-18; upstream confirmed it against their 10.6 controller (commands land within a second). Resolves REVERSE-ENGINEERING.md Investigation 3. **AP2, 2026-10-18: this UCG Ultra answered the first Binding Request** -- a 56-byte Binding Response from `192.0.2.1:3478` to AP2's port on the wire, and the next inform carried `connect_request_ip` = AP2's own address and port 32777 (so the 2026-09-15 silence was the missing CHANGE-REQUEST attribute, as upstream said). The wake datagram itself not yet watched |
| 67 | AirView Connectivity | `capability=notif,notif-assoc-stat` → `STA_ASSOC_TRACKER` notif informs (`assoctrack.lua`, passive `bridge openuf_assoc`) | ⚠️ Adopted 2026-10-18; upstream's lab and hardware. `conf.lua` `assoc_tracker = false` switches it off |
| 68 | AirView Roaming | `wifi_caps2` `0x2000` (only while reporting) → `association`/`sta_leave`/`sta_roam` notifs within ~250 ms, departures tagged Minimum RSSI / Roaming Assistant | ⚠️ Adopted 2026-10-18; upstream hardware-confirmed (the Minimum RSSI tag lab-only). Needs both APs on this build to change what the controller shows |
| 69 | `cmd: scan` | `{type, mode, freq?, radio_name?}` from the controller's scan request | ⚠️ Adopted 2026-10-18 (upstream's cmd audit), mapped onto this tree's chunked sweep: the named radio, the band of the frequency, or every radio |
| 70 | Real UniFi AP as a sibling | vendor element `00:15:6d` type 1, TLV `0x81` = serialno → `is_unifi`/`serialno` | ⚠️ Adopted 2026-10-18; upstream saw a neighbour's current-firmware AP. No UniFi AP on this site |
| 71 | Hygiene from upstream's audit | `bridge openuf_usteer` (usteerd's sync kept off the VAPs), `l2guard.reconcile_hairpin`, one `nft -f` transaction per table, mt76 counter underflow read as 0, two random 11k-scan times (the firmware's own spread, kept), `util.lua` sysfs reads, per-cycle garbage collection. Not taken, by decision: the LLDP and sibling-tag caches and the hourly beacon requests -- reports here follow reality on the next heartbeat | ⚠️ Adopted 2026-10-18; all of it upstream's evidence (both their boards). Not measured on a JioRouter |
| 72 | 802.11r with genuine UniFi APs (`unifi_ft_interop`) | UniFi's mobility domain (first two bytes of SHA1("salt" .. SSID padded to 32)), `ft_psk_generate_local 0`, `nasid` = BSSID, per-peer `r0kh`/`r1kh` from `/etc/config/rrb-unifi` plus the wildcards, `hostapd_bss_options 'ft_iface=vft0'` when the veth exists; the external rrb-unifi translator reframes the RRB frames | ⚠️ Adopted 2026-10-25 from d-malinowski/openUF; their hardware evidence only (BT Home Hub 5A ↔ U7 Lite, FT-PSK, both directions). On by default for new installations (the user's decision; d-malinowski ships it off); set to `0` the section is byte-identical to before. ✅ The install path (`openuf deps --install --only-rrb-unifi` from the fork, veth, service) and the hostapd side (BSS up with the option set, the `0x88b7` socket on `vft0`, `rrb-unifi check OK`) proven in the 25.12.6 QEMU VM on 2026-10-25. ✅ Pushed by a 10.6.106 controller in the same VM on 2026-10-27: the veth created by that push, the translator running on it, and openUF ↔ openUF roams `auth_alg=ft` for FT-PSK and FT-SAE ("The combined build"). **The roam against a UniFi AP is not run here: the lab has none** (REVERSE-ENGINEERING.md backlog row 25) |

---

## Newer firmware audit (4.3.28, 6.8.2)

Builds read (plaintext MIPS/QCA956x, `tools/fw-extract.sh`): BZ2 3.9.27, 4.0.15 (2019), BZ2 4.3.28 (2021), U7LR 6.8.2 (2026).
ARM64 U6/U7 (incl. U6-IW) stays opaque; nothing below is claimed for it. Method: `strings` over `ubntbox`, `mcad`, `libubnt`,
`syswrapper.sh`; the `aaa.%d.*` key table in `ubntbox` is the firmware's controller-key → hostapd-line map.

- 4.0.15 has no WPA3/OWE/PPSK template; 4.3.28 adds more `aaa.*` keys; **6.8.2 `ubntbox` holds the full hostapd generator**:
  `sae.{pwe,confirm_immediate,anti_clogging,sync,groups,psk.<n>.{mac,vlan,id}}`, `owe_ptk_workaround`, `fils.*`,
  `ft_r0_key_lifetime`/`r1_max_key_lifetime`/`rkh_pos_timeout`/`ft_over_ds`/`rsn_preauth`, `wpa.{strict_rekey,gmk_rekey,group_update_count}`,
  `wpa3.enhanced_192`, `btm_disassoc.{status,threshold}`, `disable_na_mcast_to_ucast`. 6.8.2 also ships its own `wpad`, `scan-rrm`, `airtime-scan`.
- **Controller side (10.6.106 `internal-dependencies.jar`, CFR):** none of `sae.pwe`, `sae.confirm_immediate`, `owe_ptk_workaround`,
  `r0_key_lifetime`, `r1_max_key_lifetime`, `rkh_pos_timeout`, `rsn_preauth`, `wpa.{strict_rekey,gmk_rekey,group_update_count}`, `fils.*`
  occurs in the controller: the firmware understands them but nothing sends them, so they need no openUF code. (OWE: firmware's
  `owe_ptk_workaround=1` default equals OpenWrt's; `ap.uc:22` hardcodes the hidden BSS name `<ssid>OWE`, not overridable.)
- **`sae.psk.<n>`** (emitter `XWWFgnDBrNRLQZ`, wlanconf `sae_psk` list of `{psk, mac, vlan, id}`): entry `mac=ff:ff:ff:ff:ff:ff` is the WLAN's own key
  (WPA3-only: sent here instead of `wpa.psk`); others are station-bound (`mac` absent = any), `vlan` ≥ 1, `dynamic_vlan` 2 if `sae_psk_vlan_required`.
  Firmware writes `sae_password=<key>[|mac=][|vlanid=][|id=]`. openUF: feature matrix row 28.
- **Closed, no code needed:** capability bits are per-board data in `ubnthal.ko`, not readable for a U6-IW, and the controller-side sweep already
  decides them; 4.3.28/6.8.2 `mcad` adds `default_url`, `selfrun_beacon`, `last_dns_fail_count`, `ipv6_ll_inform_url`, none of which the controller
  sends or reads (jar string search); selfrun (3 fails, `mgmt.selfrun_guest_mode`) and `setdefault`/`restore-default` strings are unchanged from 4.0.15.
- **Group B, key set unchanged (4.0.15 → 4.3.28 → 6.8.2, `ubntbox` strings + consumers):** `stamgr.<n>.minrssi.*` (6.8.2 also `iwpriv <radio> minrssi`), `stamgr.<n>.loadbalance.status` (`stamgr -n <maxsta>` still exists; the literal `loadbalance.maxsta` string is gone from 6.8.2, so its source there is unconfirmed), `wireless.<n>.uapsd`, `aaa.<n>.wpa.group_rekey`, `wireless.<n>.schedule_*` (4.3.28/6.8.2 add `schedule_invert`: the `fw_caps` 0x400000 gate, unclaimed on purpose, see wlansched.lua), `ebtables.rule`, `qos.*` speed profiles (in `libubnt`), `macacl.*`, `aaa.<n>.11k.status`. `stamgr.<n>.radio` (band) is sent by the controller and already parsed. Not seen in any captured `system_cfg`: `wireless.<n>.element_adopt`, `intelligent_dhcp`. README rows for U-APSD, group rekey, blackout schedule and L2 hardening now name all three builds. Behaviour (not just key presence) was not re-derived for the others.
- **Roaming Assistant / Band Steering (U7LR 6.8.2; 4.3.28 and older have no BTM code):** `wireless.<n>.btm_disassoc.status/.threshold` becomes `iwpriv <vap> btm_disassoc <0|1>` and `btm_dis_thld <N>`; the work is in `umac.ko`: a per-station check logs `BTM: STA <mac> RSSI, candidates, force to roam`, so a BSS Transition request goes out only with candidate APs (`ubnt_fill_btm_candidate`, capped), the disassociation follows on a timer (`btm_dis_timer`, `btm_dis_max_cnt`, `btm_chk_max_cnt`), and the timer is cancelled by the client's BTM response or a new auth. That is what `roamassist.lua` does (candidate required, BTM, grace, then disassoc); the firmware's timer values and the threshold's unit (dBm vs SNR) are in the driver and were not read, so openUF's constants stay its own. Band Steering: the firmware consumes `bandsteering.status`, the per-WLAN pair devnames and `no2ghz_oui`; no `bandsteering.mode`, `prefer_5g` or `equal` string exists in 4.3.28 or 6.8.2, so Balance cannot be derived from them and stays ignored.
- **Open: WiFi Experience, decoded but not ported.** 4.3.28 gates a new model behind `satisfaction_new_impl_enabled` (default 0); in 6.8.2
  `calc_sta_satisfaction` (U7LR) is that model with no flag. Checked by running the real code in an emulator (`tools/fw-oracle`) and a
  disassembly. Result block at struct+520 (score, reason @+8, anomalies @+16, 16 sub-scores @+24) plus an experimental twin at +864; the
  controller gets the first. Terms: retry (needs ≥30 tries; ratio p = retries·100/tries: p≤25 → 100, else 100 − (min(p,105)−25)·51/100, so
  floor 60; only when the **VAP's** phy mode, struct+1560, is 17, 18 or 23, else 100: oracle-exact over modes × ratios), rate (5/6 GHz only:
  f(rate·free-airtime%/100), a soft-float curve, 0 below ~1000 and 92 at 20000), tcp latency (100 − (x−100)/15), and one 0/100 or stepped term each
  for ip timeout, arp timeout (`!= 0` → 100), dns timeout (100 − 10n), dns latency (curve), icmp rtt (100 − (x−100)/15), disconnects (100 − 10(n−1)),
  no-DHCP and drops (`sat_xretry_penalty_thrs`/`_metric_ranges` tables). The 4.0.15 signal, TCP-loss, stream-efficiency, sleepy and wifi-latency
  terms (bits 0x1/0x4/0x20/0x40/0x80) are not evaluated in it. `calc_sta_satisfaction_mov` averages each term over 4 samples. Charts have 16 keys.
  **Not ported because** the inputs are not pinned down: struct offsets 376/416/1560/328–340/1216–1232/1244–1252/1492 are named only by inference
  (rate, free-airtime %, VAP phy mode, tries/retries, network flags), the enum behind modes 17/18/23 is unknown, and the controller does not
  know the 8 new chart keys (not in the jar; the UI chunks were not checked). A port would drop today's signal term, which is a visible change.
  **Hybrid checked and dropped (2026-10-26):** keeping the 4.0.15 signal/PHY/retry terms and adding only sourceable 6.8.2 terms adds nothing: the network terms (ip/arp/dns/icmp, no-DHCP) and tcp latency need probes the AP firmware makes and OpenWrt has no source for (they would score 100, as now); rate needs the free-airtime % input (inferred); disconnects and drops need the window and units of the assoc tracker (unknown); the retry term's only 6.8.2 differences are the ≥30-tries gate and the 60 floor, behind the unidentified phy-mode gate. The score stays as 4.0.15.
- The complete cross of the firmware's key universe, producers and command verbs against openUF
  is upstream's firmware sweep, under "Ported from jonasevcik/openUF"; read it before opening a
  new firmware question.
- Per-feature results are in the feature matrix rows (27 = SAE tuning, 28 = SAE station keys).

## Open questions

- **`setdefault` is never dispatched.** Clicking Remove deletes the device server-side and
  flips the UI to "ready to adopt", but no `setdefault` reaches the wire and `state.json` keeps
  `adopted: true` with the old authkey. Whether a real `setdefault` is sent under different
  circumstances (e.g. only over SSH for L2-discovered devices, mirroring how initial adopt
  differs by discovery method) is unconfirmed. openUF's handler is untested but there is no
  evidence it is wrong.
- ~~**`linkscore` and `multicast`** have no known source or reference; currently `0`.~~ ✅ Resolved
  2026-10-18 by upstream's firmware reading: `fill_stainfo_json` sends neither (nor `capacity`
  or `throughput`), and the 10.x controller reads them only off a mesh uplink's entry. Not sent
  any more (row 64).
- **`bootrom_version`** has no counterpart in the device schema. Probably ignored.
- **The `spectrum-scan` cmd handler** has never received a real controller-issued command.
- ~~**openUF's `usteer` config option names**~~ — ✅ resolved upstream 2026-09-10, verified
  against the installed package; the option names and the named `local` section are both
  correct.
- ~~**hostapd's acceptance of `wps_device_name`/`ap_setup_locked`**~~ — ✅ resolved upstream
  2026-09-10: the option names are valid, but OpenWrt never emits the WPS block that would
  carry them (see feature 26). The feature is now documented as not implemented.
- **SAE anti-clogging / sync time** cannot be applied on OpenWrt at all:
  `sae_anti_clogging_threshold` and `sae_sync` are real hostapd keys but are declared in no
  wifi-iface schema, no ucode generator and no `hostapd.sh` `config_add_*` list, on either
  of upstream's boards. openUF no longer writes them (see feature 27).
- **Which `set-adopt` form a controller sends.** The bootstrap shell accepts the bare or
  absolute command path and an optional trailing MAC, which the BZ2 4.3.28 firmware ignores
  (`syswrapper.sh` reads `$1 $2`). No controller build has been captured sending the MAC form
  here; the lab adopts over L3. `syswrapper.lua` refuses a MAC that differs from the `mac` in
  `state.json`.
- **PoE self-reporting** could be reopened if the validation environment ever gains a real
  switch container, or if a non-Parent-Device UI surface for those fields is found.

---

## Dead ends — do not re-attempt

- **Extracting the AP→controller protocol from U6-InWall firmware.** The official image
  (`v6.8.2+15592`, pulled from `fw-update.ubnt.com`, md5
  `0fec04452cadd2d025777d36ab2974ea`) is a **kernel-only OTA delta**. Its GPT has 5 partitions
  of which only `HLOS` has data; there is no system/rootfs/application partition at all.
  `HLOS.img` is at flat 8.0 bits/byte entropy across ~95% of the file (computed per-1MB block,
  not eyeballed from a binwalk graph), with no compression magic and zero `strings` hits for a
  kernel banner, driver names, or any of `scan`/`spectrum`/`rssi`/`noise`/`channel`/`bssid`.
  Only the last ~1.3 MB is plaintext, and that is device-tree blobs. The inform-client binary
  simply is not in this artifact. Untried alternatives if this ever matters: a pre-2023 build
  that might predate encrypted/kernel-only packaging; pulling the binary off a live owned
  device over SSH; or a LAN packet capture between real hardware and a real controller.
  **The first of those is what upstream took (2026-10-10):** UAP BZ2 firmware 3.9.27 to 4.0.15
  is plaintext (`/usr/etc/syswrapper.sh`, `/bin/mcad`, `/bin/ubntbox`, `libubnt.so`, `umac.ko`),
  while every in-wall build back to 3.9.27 is encrypted. Claims from it are labelled
  "firmware-confirmed for 3.9.27 to 4.0.15" and say nothing about current firmware.
- **Chasing `wait_for_initial_inform` as a thing in itself.** It is downstream of
  [the GCM gate](#the-gcm-provisioning-gate). Editing it in Mongo does nothing (the process
  never re-reads), and restarting the controller to force a reload introduces a separate
  "Offline" artifact.
- **Looking for a manual RF-scan trigger in 10.4.57's UI.** There isn't one — AirView is fed
  entirely by passive, continuously-collected stats. Settings search for "spectrum" returns
  nothing, and no `_type:"cmd"` arrives on its own while the page is open.
- **`strings` on concatenated Java class files on macOS.** `0xCAFEBABE` is both the Java class
  magic and the Mach-O fat-binary magic, so macOS `strings` chokes. Extract printable-ASCII
  runs in Python instead.
- **Deleting a stale wireless client record and waiting for it to reappear.** The pattern works
  for wired clients but wireless ones never came back (45+ s). Recreate the WLAN instead.

## Ported from jonasevcik/openUF

Evidence for features brought over from [jonasevcik/openUF](https://github.com/jonasevcik/openUF),
copied from their PROTOCOL-VALIDATION.md with the commit each came from. Their lab and
hardware, not this project's: these results have not been re-run here.

### Firmware sweep: the whole key universe (U7LR 6.8.2, BZ2 4.3.28) (jonasevcik fda1226, f3f602c, f92e7e7, 2c94d75, 9c340cd, 6652535, 2026-10-26)

The audit above was a targeted read of the security keys. This is the **complete** cross of
what the firmware consumes, produces and answers against what openUF does, run 2026-10-26 so
that later work starts from evidence instead of a fresh read. Nothing here is a feature claim:
each row carries a verdict — **implement**, **decline** (with the reason), or **needs capture**
(the key exists in the firmware but no captured `system_cfg` has ever carried it, so the
controller setting that emits it has to be toggled in the lab first).

**Method.** `strings` over `sbin/ubntbox` for `%d`/`%s` key templates (the firmware's own
controller-key → action map), normalised to `N`; the union of every captured 10.6.106 push;
and a leaf-name cross against `openuf/*.lua`. Counts: **627** key templates in 6.8.2 → **609**
distinct keys (177 of them `switch.*`), **469** templates in 4.3.28, **234** distinct keys in
the captured pushes, **166** firmware keys with no leaf match in openUF (56 `switch.*`, 110
others). The leaf cross is a candidate filter, not a verdict — every row below was then
checked by hand against the code, and that hand check is now re-derivable mechanically with
`tools/cfg-coverage.lua` (see "Axis 1, mechanically" below). Builds read: **U7LR 6.8.2** (Jan 2026) and **BZ2 4.3.28**,
both MIPS/QCA956x and Wi-Fi 5 only; **nothing here is claimed for the ARM64 U6/U7 firmware**
openUF impersonates. Rebuild the artifacts with `tools/fw-extract.sh <fw.bin> <outdir>` (build
list via the `fw-update.ui.com` firmware API, see `tools/fw-oracle/README.md`).

#### Axis 1 — keys the controller already pushes that openUF reads nothing from

Values are verbatim from a lab push (10.6.106, U6-IW identity, four VAPs, PSK + EAP + guest).
A value that is constant with the matching UI control off is a decoy, not a setting — the
discriminator must be shown by a toggle diff before anything is implemented (the same test
that already demoted `mac_acl.status`, `bcmc_l2_filter.status` and `multicast.inspect`).

| Key | Value seen | Firmware action (6.8.2) | Candidate OpenWrt consumer | Verdict |
|---|---|---|---|---|
| `aaa.<n>.auth_cache` | `enabled` | PMKSA/opportunistic key caching | `okc` / `disable_pmksa_caching` | needs capture (toggle diff) — then implement if it moves |
| `aaa.<n>.eapol_version` | `2` | `eapol_version=` | `eapol_version` | needs capture |
| `aaa.<n>.wpa.1.pairwise` | `CCMP` | the authoritative pairwise cipher | openUF derives the cipher from its own `SECURITY_MAP` | implement as a cross-check: a mismatch between pushed and derived cipher is a bug signal we currently cannot see |
| `aaa.<n>.country_beacon` | `disabled` | country IE in the beacon | `ieee80211d` | needs capture |
| `aaa.<n>.tdls_prohibit` | `disabled` | `tdls_prohibit=` | `tdls_prohibit` | needs capture |
| `aaa.<n>.p2p`, `.p2p_cross_connect` | `disabled` | `manage_p2p=` / `allow_cross_connection=` | same names in hostapd | needs capture |
| `aaa.<n>.filter_id` | not seen | RADIUS `Filter-Id` handling | — | needs capture (arrives with a RADIUS profile variant we have not built) |
| `wireless.<n>.wmm` | `enabled` | WMM/WME on the VAP | `wmm` (wifi-iface) | needs capture — WMM off is a real UI control on some builds |
| `qos.mode` | `1` | selects the qos engine | `shaper.lua`'s own choice | **declined 2026-10-27: constant by construction** — the controller writes the literal `"mode", "1"` (`config/VAZShipWTNxlo:2078`). See [axis 1/2, settled](#axis-12-radio-and-system-keys-settled-2026-10-27) |
| `radio.<n>.antenna.gain` | `3` | antenna gain, feeds the tx-power ceiling (`iwpriv ant_gain`) | `wifi-device.antenna_gain` | **declined 2026-10-27:** the value describes the impersonated U6-IW's antennas, and UCI `antenna_gain` is in the schema but has no consumer in 25.12's generator. See [axis 1/2, settled](#axis-12-radio-and-system-keys-settled-2026-10-27) |
| `radio.outdoor` | `disabled` | regulatory/outdoor channel set (`iwpriv outdoor`) | `country3` is the nearest, and not equivalent | **declined 2026-10-27:** a real site toggle, but the only mac80211 knob changes the Country IE's environment octet, not the radio's channel/power table. See [axis 1/2, settled](#axis-12-radio-and-system-keys-settled-2026-10-27) |
| `radio.<n>.ampdu.status`, `.rate.auto`, `.rate.mcs`, `.acktimeout`, `.ack.auto`, `.cwm.enable`, `.bgscan.status`, `.hard_noisefloor.status`, `.clksel` | `enabled`/`auto`/`64`/`disabled`/`0` | airMAX-era radio tuning, mostly `iwpriv` on QCA | nothing in mac80211 takes them per-radio | decline: airMAX/QCA-specific, constant in every capture (`cwm.mode` was already documented as a decoy) |
| `wireless.<n>.authmode`, `.puren`, `.pureg`, `.element_adopt`, `.autowds`, `.vwire`, `.addmtikie` | `1`/`0`/`disabled` | legacy AirOS VAP flags | — | decline: legacy; `pureg` is already consumed as part of Minimum Data Rate |
| `switch.port.<n>.{name,opmode}`, `switch.{status,vlan.status,dot1x.status,jumboframes}` | `PoE Out + Data`, `switch`, `disabled` | the in-wall's own 5 ports | openUF's per-port VLAN path | already correct: openUF keeps only ports carrying a real override (`inform.lua:3493`); the name/opmode-only rows are the U6-IW identity's port list, not an override |

#### Axis 1, mechanically: the replay sweep (`tools/cfg-coverage.lua`)

The table above was hand-checked against the code, which is exactly the step that does not
survive a refactor. `tools/cfg-coverage.lua` (added 2026-10-26) re-derives it mechanically and
without reading the source at all: it replays a captured push through every pure parser, then
re-replays it once per key with that key **deleted** and once per key with its value
**replaced**, and sorts each key by whether any parser's output moved.

- **consumed** — the output moved. Proof that some parser read the key, not an inference.
- **inert** — nothing moved, and `RECOGNIZED_SYSTEM_CFG` claims the key.
- **ignored** — nothing moved and nothing claims it.

The value probes matter: deletion alone cannot see a key that a **redundant** key covers.
`radio.<n>.countrycode` falls back to the unindexed `radio.countrycode`, so dropping either one
leaves the regdomain unchanged and a deletion-only sweep calls both unread. Mutating the value
exposes the read instead — eight keys (`system.timezone`, `cron.status`, `ntpclient.status`,
`ebtables.status`, `dhcpc.<n>.status` among them) move from inert to consumed on that probe
alone. Where two keys shadow each other outright, the honest verdict is still "unobservable",
which is why a verdict needs **two** captures across the controller toggle, not one.

On the 2026-10-26 lab push (10.6.106, U6-IW identity, four VAPs: PSK + EAP + two guest), 665
key=value lines and 29 comment/blank lines: **296 consumed, 254 inert, 115 ignored**. What it
establishes beyond the hand check:

- Every axis-1 candidate above is confirmed unread by the oracle: `auth_cache`,
  `eapol_version`, `country_beacon`, `tdls_prohibit`, `p2p`, `p2p_cross_connect`,
  `wireless.<n>.wmm`, `wpa.<n>.pairwise` and `radio.<n>.antenna.gain` land in **inert**;
  `qos.mode` and `radio.outdoor` in **ignored**.
- **`RECOGNIZED_SYSTEM_CFG` over-claims by 254 keys.** Its patterns are prefix-coarse on
  purpose (`^aaa%.%d+%.` covers the whole per-WLAN block), so `_report_dropped_keys`
  systematically *under*-reports what openUF ignores. "Recognized" is a claim about a prefix;
  only the replay is evidence about a key.
- Several keys that look load-bearing are inert because openUF joins differently from the
  firmware: `aaa.<n>.devname` (openUF joins `aaa` to `wireless` by **index**; devname feeds
  only the OWE hidden-half pairing), `aaa.<n>.ssid` (the SSID is taken from
  `wireless.<n>.ssid`) and `wireless.<n>.security` (the cipher suite is derived from the
  `wpa.key.<k>.mgmt` list). Each is a correct verdict, and each is a key a source grep would
  have scored as consumed.
- The controller pushes `aaa.<n>.wpa.psk` on a **WPA-Enterprise** WLAN too (both EAP VAPs in
  this capture carry one). openUF ignores it there, which is right — but it means a capture's
  `wpa.psk` is not evidence that a WLAN is PSK.

Run it after implementing a key family and expect that family wholly in **consumed**; a row
left behind is a consumer wired to a producer that does not exist, this repo's recurring defect.
Usage is in `tools/validation/README.md`. Secrets are redacted even under `--values`, since the
output is meant to be pasted here.

#### Axis 1b — the reverse direction, which bounds how far the firmware can be trusted

**74 keys the controller pushes do not exist in 6.8.2's key universe at all**, among them
`wireless.<n>.advertise_ap_name`, `wireless.<n>.multicast.inspect`, `aaa.<n>.pmf.cipher`,
`aaa.<n>.hs20.{deauth_req_timeout,friendly_name.<k>.*,hs20_domain_name_list}`,
`aaa.<n>.wpa.key.<k>.mgmt`, `radio.<n>.bcmc_l2_filter.status`, `atf.*`, `cron.*`,
`dnsmasq.walled_garden.*`, `users.*`, `sshd.*`, `unifi.*`, and the whole `bridge.*`/`dhcpc.*`/
`ntpclient.*`/`resolv.*`/`route.*`/`iptables.*`/`ipset.*` plumbing. Two consequences worth
keeping: the MIPS firmware is **not** a complete oracle for a U6-IW identity (those keys are
consumed by the ARM64 builds, by `syswrapper.sh`, or by plain OpenWrt-style config files), and
a key's absence from `ubntbox` is therefore **not** evidence that the AP ignores it.

#### Axis 2 — keys the firmware consumes that no captured push has ever carried

All **needs capture**: find the controller setting in the jar, toggle it in the lab, diff. In
descending promise, with why each is worth the toggle:

- `wireless.<n>.advanced_isolation.{status,<k>.mac}` — a per-MAC **exception list** to client
  isolation. **Settled 2026-10-27: declined, no emitter** — zero occurrences in the whole
  10.6.106 jar. See
  [advanced_isolation](#wirelessnadvanced_isolation--declined-no-emitter). The
  forced-`ap_isolate` trade it would have removed was closed from the other end by the
  hairpin fix. The find next to it was real, though:
  [Multicast Suppression](#multicast-suppression-the-blocker-renamed-and-a-key-openuf-was-dropping).
- `wireless.<n>.intelligent_dhcp`, `.dhcp_bcast2ucast.status`, `.bintval`,
  `.ubnt_discovery_filter`, `.signal_led*` — VAP-level behaviour with plausible UCI
  counterparts (`dtim_period`, `beacon_int`); `intelligent_dhcp` and `element_adopt` were
  already noted as never captured in the audit above. **Settled 2026-10-27: declined, no
  emitter**, and `dtim_period`/`qbssload`/`no2ghz_oui` turned out to be already
  implemented. See [axis 2 closed](#axis-2s-remaining-rows-closed-2026-10-27).
- `radio.<n>.backup_channel`, `.acsdfs`, `.scan_list.{status,channels}`, `.ch144` — DFS
  fallback and channel-list narrowing. **Settled 2026-10-27:** `.acsdfs` is pushed (with
  `.blklst`) once `wifi_caps2` `0x10` is claimed, and both are implemented; the other three
  have **no emitter anywhere in the 10.6.106 jar**. See
  [axis 1/2, settled](#axis-12-radio-and-system-keys-settled-2026-10-27).
- `aaa.<n>.{rsn_preauth,rsn_preauth_uplinks,reauth_period,psk.sha256,sha1,sha256,rsn_group_cipher,wpa.group_update_count,wpa.strict_rekey,wpa.gmk_rekey,disable_na_mcast_to_ucast,strict_specification,log_level,verbose}`
  — the audit above already found **no occurrence in the 10.6.106 jar** for `rsn_preauth`,
  `wpa.{strict_rekey,gmk_rekey,group_update_count}` and `fils.*`: those stay **declined, no
  emitter**. The rest of the list is unchecked.
- `aaa.<n>.radius.macacl.{status,format,emptypassword}` (RADIUS MAC authentication) and
  `aaa.<n>.radius.{das,dad}.*` (DAS/CoA) — the two deliberate deferrals of the
  WPA-Enterprise commit. **Settled 2026-10-27, both implemented**; `format`,
  `emptypassword` and the whole `dad.*` shape are declined with reasons. The third key in
  this row, `aaa.<n>.accept_mac.{status,<k>.vlanid}`, turned out **not** to be part of
  RADIUS MAC auth at all — it is the site's MAC-based VLAN feature, with its own gate and
  its own open question. See
  [RADIUS MAC authentication and Dynamic Authorization](#radius-mac-authentication-and-dynamic-authorization-settled-2026-10-27).
- `connectivity.{status,uplink,uplink_eth,uplink_bridge,uplink_gateway,uplink_wds}` — the uplink
  connectivity monitor; `connectivity.status=disabled` in every capture. Read what `mcad` does
  when it is on **before** writing code: the firmware's response to a dead uplink can take
  radios down, which is not a change to make blind on a production AP.
- `mesh.*`, `aaa.<n>.owe_devname`, `wireless.<n>.{wds,parent,vwirepeers,vwirepayload*}` —
  wireless uplink / mesh. **Decline (scope):** openUF presents a wired AP, and a mesh uplink
  would need the whole vwire/WDS peering path plus `is_wireless_uplink` reporting.
- `ble.*` (12 keys: iBeacon, Eddystone, `ble.mode`) — **decline:** neither board has Bluetooth.
- `system.monitor.<x>.{host,poll_interval,status,threshold}`, `system.{resetbtn,kernel.panic,kernel.panic_on_oops,boot_sound.status,analytics.*}` — device-level monitors and knobs; only
  `system.analytics.status` has ever been captured. **Settled 2026-10-27:** the controller
  writes only `system.monitor.{memory,critical_memory}.threshold`, and only for gateway
  models; the ping monitor has no emitter. See
  [axis 1/2, settled](#axis-12-radio-and-system-keys-settled-2026-10-27).
- `switch.*` beyond the U6-IW port rows (177 keys: ACLs, STP/MSTP, IGMP, LAG, SNMP, dot1x,
  routing interfaces, DHCP server/relay, storm control, port mirroring) — **decline, wrong
  product:** these are UniFi *switch* keys in a shared `ubntbox`; the only `switch.*` an AP
  identity receives are the 14 rows in axis 1.

#### Axis 3 — the reporting side, which the last series never touched

What the controller *displays* comes from what the AP sends up, and 6.8.2's producers are
readable: `usr/lib/libubnt.so.1.0.0` (`fill_stainfo_json`, `fill_wireless_info[_full]`,
`fill_radio_stat_info_full`, `fill_ap_info_full`, `anomalies_bar_chart_to_json`,
`reasons_bar_chart_to_json`, `tcp_stats_to_json`, `wifi_tx_lat_to_json`), `bin/stainfo`,
`bin/stamgr`, `sbin/stahtd`, `sbin/wevent` (the wireless-event producer behind the
association/roam notifications), and `sbin/{sysmon,ubnt-netmon,ubntevent}`.

Per-station keys present in `libubnt` 6.8.2 and **absent from openUF's payload**:
`sta_ip_timeout`, `sta_arp_timeout`, `sta_dns_timeout`, `sta_dns_latency`, `sta_icmp_rtt`,
`sta_disconnects`, `wifi_drops`, `rx_tcp_lat_avg`, `tx_tcp_lat_avg`, `tx_rate_avg`,
`rx_rate_avg`. openUF sends `wifi_retries`/`wifi_latency` (and the anomaly/reason bar charts)
from `satisfaction.lua` and nothing else from this family. These are exactly the inputs of the
6.8.2 WiFi Experience terms that the hybrid port was dropped over, so the two questions are the
same one: **needs the controller side first** — whether 10.6.106 reads each key (jar string
search) and whether OpenWrt has any source for it, since the firmware fills most of them from
probes `mcad` runs against the client (ARP/DNS/ICMP) that openUF does not perform.


_(Axis 3, settled 2026-10-27: already in this file, under the matching "Ported from jonasevcik/openUF" entry.)_


_(DFS radar detection: `EVT_AP_RadarDetected`: already in this file, under the matching "Ported from jonasevcik/openUF" entry.)_

#### Axis 4 — commands: `syswrapper.sh`'s own answer list vs openUF's dispatcher

6.8.2 `bin/syswrapper.sh` dispatches ~150 verbs. openUF's dispatcher
(`inform.lua`, `_type`/`cmd`) answers: `set-locate`/`unset-locate`, `block-sta`/`unblock-sta`,
`kick-sta`, `authorize-guest`/`unauthorize-guest`, `rate-update`, `scan`/`scan_band`,
`spectrum-scan`, `upgrade` (stored only), `set-selfrun`/`unset-selfrun`,
`refresh-walled-garden` (as a cron job), `setdefault`/`restore-default`, `reboot`, `setparam`,
plus `_note_unhandled` for anything else — which makes the device itself the oracle for what
actually arrives.

Verbs with no openUF equivalent, worth triage (**needs jar check**: the controller's `cmd`
enum decides whether a verb can ever arrive; a verb `mcad` only invokes from its own state
machine is **declined as not a controller command**):

`vlan-detected`, `cache-vlan-detected`, `clear-vlan-detected` (the controller's VLAN-mismatch
warning), `scan-rrm`, `scan-rrm-check`, `airtime-scan`, `11k-boot`, `11k-scan`, `11k-stop`,
`dfs-reset`, `set-channel`, `get-support-file`, `gen-sup-file`, `pcap-start`, `pcap-stop`,
`read-crash-log`, `dump-radar-log`, `dump-isolation-log`, `send-wificoredump`,
`mca-custom-alert`, `mca-send-inform`, `set-element-payload`/`unset-element-payload`,
`set-meshv3-payload`, `schedule-action`, `probe-lan-iface`, `ip-changed`, `handle-dyn`,
`soft-restart`, `shutdown`, `wireless-vlan-add`/`-del`, `del-bridge-vlans`, `get-tmpfs-usage`,
`install-runtime-package`, `lcm-sync`, `lcm-tracker`, `relayctl`, `ssh-adopt`, `set-ready`,
`set-inform`, `check-is-adopted`, `led-locate`, `set-custom-sysled`, `netconsole`,
`sensitive-data-filter`, `systemcfg-sensitive-data-filter`, `uplink`, `wds`,
`wireless-bridge`, `wireless-bridge-failover`, `mesh-halt`, `do-ir-send`, `set-volume`,
`set-stream`/`set-stream-media`, `lte_prov`, `set-uboot-var`, `backup-part-upgrade`.
Already declined by product scope within that list: the speaker/IR verbs (`set-volume`,
`set-stream*`, `do-ir-send`), `lte_prov`, the mesh/WDS verbs (axis 2), and the U-Boot and
partition verbs, which openUF deliberately never flashes.


_(Axis 4, settled 2026-10-27: already in this file, under the matching "Ported from jonasevcik/openUF" entry.)_


_(`dfs-reset`: what the firmware does with it: already in this file, under the matching "Ported from jonasevcik/openUF" entry.)_


_(Axis 1/2 radio and system keys, settled 2026-10-27: already in this file, under the matching "Ported from jonasevcik/openUF" entry.)_


_(`radio.<n>.acsdfs` / `radio.<n>.blklst` — the site's auto-channel limits: already in this file, under the matching "Ported from jonasevcik/openUF" entry.)_


_(RADIUS MAC authentication and Dynamic Authorization, settled 2026-10-27: already in this file, under the matching "Ported from jonasevcik/openUF" entry.)_


_(Multicast Suppression: the blocker renamed, and a key openUF was dropping: already in this file, under the matching "Ported from jonasevcik/openUF" entry.)_

##### `wireless.<n>.advanced_isolation.*` — declined, no emitter

`wireless.%d.advanced_isolation.{,%d.mac,status}` is consumed by **both** readable
firmware builds (U7LR 6.8.2 and BZ2 4.3.28) and was axis 2's most promising row: a
per-MAC exception list to client isolation would have made the forced-`ap_isolate` trade
behind proxy ARP and Multicast Enhancement unnecessary.

**It has zero occurrences anywhere in 10.6.106's `internal-dependencies.jar`** — not in a
class, not in `api/fields/*.json`, not in the properties bundles. So no controller
setting can emit it, the same verdict as `backup_channel`/`scan_list.*`/`ch144`. The only
isolation key the WLAN writer emits is `wireless.<n>.l2_isolation` (defaulting to
`is_guest`), which openUF already maps to `isolate`/`ap_isolate`; the WLAN schema holds
only `l2_isolation` and `isolation_enabled`, and the site-level `acl_device_isolation` /
`acl_l3_isolation` / `enable_isolated_wlan` belong to the gateway's ACL and devmgr paths,
with no AP config writer among their callers.

Separately, the trade this row existed to remove was already closed from the other end:
the hairpin fix restores station-to-station reachability on a force-isolated BSS
(`l2guard.lua`), so nothing is outstanding here.

##### Axis 2's remaining rows, closed 2026-10-27

Every never-captured key left in the axis-2 list was crossed against the jar by literal
grep. Only six families had any hit at all, and five of those were already implemented:

| family | verdict |
|---|---|
| `advanced_isolation.*` | **decline, no emitter** (above) |
| `intelligent_dhcp`, `dhcp_bcast2ucast.*`, `bintval`, `ubnt_discovery_filter`, `signal_led*` | **decline, no emitter** — zero hits in the jar |
| `rsn_preauth_uplinks`, `reauth_period`, `rsn_group_cipher`, `disable_na_mcast_to_ucast`, `strict_specification` | **decline, no emitter** — zero hits, joining the `rsn_preauth`/`wpa.*_rekey`/`fils.*` declines already recorded |
| `qbssload`, `dtim_period`, `no2ghz_oui` | live emitters, **already implemented** (IoT Optimization, DTIM, Band Steering) |
| `owe_devname`, `element_adopt` | live emitters, already-recorded declines (mesh scope; Elements adoption) |
| `connectivity.*` | **decline, gated on `wifi_caps` `0x1`** (`supportVwire()`), the wireless-uplink capability openUF deliberately does not claim — `connectivity.status=disabled` in every capture follows from exactly that. The enabled form is all vwire/mesh anyway (`uplink_wds=vwirewan0`, `uplink_ssid`, `uplink_key`). Already documented under `connectivity.*`. |

**So axis 2 is closed.** The technique that did it is the one from step 4, and it is the
cheap one: grep the key literal over the extracted classes first — a family with zero
hits needs no capture at all, and the same grep is what surfaced `multicast.suppressor`
and `bcfilt.bypass_types`.



_(`aaa.<n>.accept_mac.*` — MAC-based VLANs, settled 2026-10-27: already in this file, under the matching "Ported from jonasevcik/openUF" entry.)_

#### Where the evidence lives

Extracted rootfs (6.8.2 `u7root`, 4.3.28 `root`), the `ubntbox` key dumps
(`keys682.txt`, `keys4328.txt`, `keys4015.txt`), `libubnt682.so`, `mcad682`, the captured
pushes and the CFR-decompiled 10.6.106 jar were all produced in session scratchpads, which are
not durable. Everything above is reproducible from `tools/fw-extract.sh` plus the lab
controller; the jar recipe is in "Decompiling the controller".

### Multicast Suppression (jonasevcik f46cf36, 2026-10-27)


Settled 2026-10-27, closing the last implementable row of axis 2. The row asked about
`wireless.<n>.advanced_isolation.*`; that turned out to be a decline (below), and the
real find was next to it.

**The control.** 10.6.106's WLAN form has "Multicast Suppression" with three positions,
whose own description is the whole semantic brief:

> Limits multicast and broadcast traffic to reduce WiFi airtime usage. Conservative
> prevents storms; Aggressive blocks all except DHCP and ARP

(`SETTINGS_WIFI_FORM_ADVANCED_MULTICAST_SUPPRESSION_DESC`, the `en` locale bundle under
`webapps/ROOT/app-unifi/react/data/locales/`. Worth remembering as a source: the config
writer gives the wire format, the locale bundle gives the *intent*, and for a key with
no readable firmware consumer that is the only statement of what the AP should do.)

The UI's own REST mapping shows it is the **old Multicast and Broadcast Blocker** in new
clothes, not a new feature:

```js
bc_filter_enabled:      mode === AGGRESSIVE
bc_filter_list:         mode === AGGRESSIVE && allowlist
multicast_suppressor_mode: mode
```

**The gates.** Two emitters, one capability bit:

| key | emitter | gate |
|---|---|---|
| `wireless.<n>.multicast.suppressor` | `VAZShipWTNxlo` (the WLAN writer) | `wlan.isEnhancedIot()`-style single `if`: `supportsMulticastSuppressor()` **and** mode ∈ {conservative, aggressive} **and** `!isServiceWlan()` |
| `wireless.<n>.bcfilt.*` + `bcfilt.bypass_types` | `com/ubnt/service/config/ubntconf/EYFcHmSpOqr` | emits nothing unless `bc_filter_enabled` **or** that same triple; `bypass_types` only for the triple |

`supportsMulticastSuppressor()` is `hasWifiCapability2(0x400000)` — an unclaimed bit, the
same shape as the `acsdfs` finding. **So the cost of not claiming it was not a missing
feature but a wrong one:** a WLAN set to Conservative pushed nothing at all, and a WLAN
set to Aggressive pushed a blocker with no ARP/DHCP carve-out, which openUF then enforced
to the letter.

**The mode is not on the wire.** `multicast.suppressor` is a bare `enabled` for
Conservative and Aggressive alike. What distinguishes them is whether a `bcfilt` block
comes with it — the *presence* of a block, which is normally this protocol's classic
decoy. Here it is load-bearing, because the jar proves `bcfilt.status` is written for
Aggressive and only Aggressive. Both captures, verbatim from the lab:

```
# multicast_suppressor_mode=conservative -- the key alone, on both band entries
wireless.1.multicast.inspect=false
wireless.1.multicast.suppressor=enabled
wireless.2.multicast.inspect=false
wireless.2.multicast.suppressor=enabled

# multicast_suppressor_mode=aggressive
wireless.1.multicast.suppressor=enabled
wireless.1.bcfilt.status=enabled
wireless.1.bcfilt.bypass_types=ARP|NSNA|DHCPV4|DHCPV6
wireless.1.bcfilt.1.status=enabled
wireless.1.bcfilt.1.mac=00:00:5e:00:53:02
wireless.1.bcfilt.2.status=enabled
wireless.1.bcfilt.2.mac=00:00:5e:00:53:01
```

`multicast.inspect` sits in the same block and stays a decoy: constant across every
toggle, and `cfg-coverage` still reports it `inert`.

**`bypass_types` is a single literal.** The writer does
`put("wireless." + n + ".bcfilt.bypass_types", "ARP|NSNA|DHCPV4|DHCPV6")` — one constant
string, so those four tokens are the closed vocabulary, not a sample. openUF maps each to
one nft `accept` placed before the drop, and names-and-drops anything else rather than
treating an unmapped token as "allowed":

| token | nft match |
|---|---|
| `ARP` | `ether type arp` |
| `NSNA` | `ether type ip6 icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert }` |
| `DHCPV4` | `ether type ip udp dport { 67, 68 }` |
| `DHCPV6` | `ether type ip6 udp dport { 546, 547 }` |

**The allow-list is bigger than the admin's.** `EYFcHmSpOqr` unions
`bc_filter_list` with every UniFi device MAC in the site *and* the gateway's
`getLanPeerMacs()`, which is why the UI says gateways need not be added by hand. openUF
needs no code for this — it consumes whatever MACs arrive.

**Conservative has no parameters, so its rate is openUF's own.** `limit rate over
100/second burst 50 packets drop`, chosen against a measurement rather than a guess: on
both production APs, over 60 s, `/sys/class/net/<br>/statistics/multicast` moved 3.2 and
3.6 frames/s on the main bridge and 1.4 and 1.5 on the IoT VLAN's. 100 pkt/s is ~30×
that. Recorded as openUF's choice in README and USAGE, not as a controller value.
`limit rate **over**` is the form that drops the excess; a bare `limit rate ... drop`
matches while *under* the rate and would discard the ordinary traffic and pass the storm.

**Verification.** Tier 1: 1154 pass, 13 new guards each mutation-tested red (including
the `over` keyword and the accept-before-drop ordering). Tier 2: both modes captured
verbatim above, every new key `consumed` in `cfg-coverage` (`multicast.inspect` still
`inert`), 0 `handle_response failed`, the recording-cursor replay produces the intended
UCI stamps and nft text, and every generated statement was accepted by a real nft 1.0.9
and reloaded idempotently against dummy netdevs. Switching the WLAN to Off produced a
setparam with none of the keys, so teardown is confirmed too. Tier 3: both APs deployed,
restarted, informing, `wifi_caps2 0x400070` accepted by the production controller with
steady noops and no new push; no WLAN here uses the control, so both APs show an empty
`openuf_bcfilt` chain and no stamps — which is the correct outcome and what was checked.

⚠️ **Not claimed:** no frame has been admitted or denied *by type*. Proving that needs
either network namespaces (unavailable in the validation container — `ip netns add` fails
with `mount --make-shared /var/run/netns failed: Operation not permitted`) or the control
switched on for a live WLAN on the production APs, which is a config push to ask for, not
to take. The earlier source-MAC half of the blocker *was* measured on real hardware
(14/14 dropped, 0/15 once allow-listed, AX3000T 2026-09-02) and is unchanged.

**This project's VM lab, 2026-10-29: the type half, on the air.** Two openUF APs and one plain
client, each an OpenWrt 25.12.6 x86-64 VM with `mac80211_hwsim` radios whose frames are carried
between the VMs, adopted by a UniFi Network 10.6.106 controller; the mode set through the
controller's API on a WPA2 WLAN, the client associated to one AP on 5 GHz. A 500 packets/s UDP
broadcast flood from the wired side for 5 s, counted on the client's WiFi interface:

| mode | what openUF installed | flood reaching the client | ARP / DHCP |
|---|---|---|---|
| Off | no stamps, empty `bcfilt` chain (teardown) | 2500 / 2500 | ok |
| Conservative | `limit rate over 100/second burst 50 packets drop` on each of the WLAN's VAPs only | 549–550 / 2500, i.e. 100/s × 5 s + the 50-packet burst | ok |
| Aggressive | the four bypass accepts, then the type drop with the allow-list set | 0 / 2500 | a broadcast ARP request from the wired side reached the client; a DHCP exchange with the broadcast flag set (server OFFER/ACK to 255.255.255.255) completed |

⚠️ Simulated radios: the frames are real 802.11 frames through mac80211 and hostapd, but no
real driver or RF is involved. Not yet repeated on a hardware AP.


### One wireless commit per push (jonasevcik 8f45d6a, 2026-10-28)

`apply_config` hands one UCI cursor to `wlan_add`, `ppsk_add` and `mac_vlans_add` and commits
once; `set_wlan_exclusive` commits only on a change. jonasevcik measured it by replaying a
capture through a recording cursor (wireless commits 18 → 6 on their three-WLAN capture).

**This project's VM lab, 2026-10-29**, counting every rewrite of `/etc/config/wireless` with
inotify during one controller push, two APs receiving the same push, one still on the build
before this change:

| push | before | after |
|---|---|---|
| one WLAN on two radios (a setting flipped) | 5 | 4 |
| two WLANs added, three on two radios (6 VAPs) | 9 | 4 |

All SSIDs came up on both builds, with no errors. The saving grows with the number of WLANs,
since the old code committed once per VAP.

### The guest walled garden (jonasevcik e6395d7, 2026-10-26)

**In this tree** `guestportal.lua` was taken whole from that commit, which also brings
upstream's one-transaction nft rebuild (b6dd8cf) and shared util (b7f06eb) for this module.
Their evidence follows; this project's lab run is below it.


Settled from the controller (10.6.106 `internal-dependencies.jar`, CFR), the AP firmware
(U7LR 6.8.2) and a lab capture, 2026-10-26. The site's guest settings hold one flat list
per direction — `guest_access.allowed_subnet_<n>` and `restricted_subnet_<n>`, read until
the first blank index — and `com/ubnt/service/config/hyFnQ` runs each entry through three
different producers:

| Producer | Keeps | Used by |
|---|---|---|
| `Cuhf.V4` | IPv4 addresses and CIDRs (a `/32` as a bare address, a `/0` split into `0.0.0.0/1` + `128.0.0.0/1`) | the ebtables rules |
| `Cuhf.V6` | IPv6, same shapes | the ip6tables side openUF does not implement |
| `OWIoHe.UGwcHSHUGpYtqo` | whatever Guava's `InternetDomainName.isValid` accepts | the `dnsmasq.walled_garden` keys |

Guava's check rejects an all-digit rightmost label, so the two sets never overlap: **an
entry is either an address or a name, and which list it is in does not decide how it
travels.**

**The IP half.** `ubntconf/YcZSaTCMOYFEMGE` emits, per allowed address:

    -t nat -I GUESTIN  -p 0x800 --ip-dst <net> -j ACCEPT
    -t nat -I GUESTOUT -p 0x800 --ip-src <net> -j ACCEPT

and per restricted address `-t nat -A GUESTIN -p 0x800 --ip-dst <net> -j DROP`. **These
carry no port**, unlike the portal's own accepts (`--ip-proto 6 --ip-dport 8880 --ip-dst
<ctl>`), which is why openUF's C1 parser rejected both lines as unknown shapes and left an
IP walled-garden entry silently unenforced until 2026-10-26. The egress rule matches on
`--ip-src`, so the reply direction needed its own list (`spec.accept_out`).

**The domain half.** Three empty chains and the jumps into them, gated on the site having
any garden domain at all (`devmgr/kDxteQiUX`):

    -t nat -N ALLOWED_DOMAIN_IN  -P RETURN   /  -t nat -I GUESTIN  -p 0x800 -j ALLOWED_DOMAIN_IN
    -t nat -N ALLOWED_DOMAIN_OUT -P RETURN   /  -t nat -I GUESTOUT -p 0x800 -j ALLOWED_DOMAIN_OUT
    -t nat -N RESTRICTED_DOMAIN_IN -P RETURN /  -t nat -A GUESTIN  -p 0x800 -j RESTRICTED_DOMAIN_IN

plus the names themselves, and the job that keeps them fresh. Verbatim from the lab
(10.6.106, 2026-10-26; site settings `allowed_subnet_1=www.example.net`,
`allowed_subnet_2=198.51.100.7/32`, `allowed_subnet_3=example.com`,
`restricted_subnet_1..3` the RFC1918 defaults, `restricted_subnet_4=ads.example.org`):

    cron.status=enabled
    cron.1.status=enabled
    cron.1.user=root
    cron.1.job.1.status=enabled
    cron.1.job.1.schedule=*/10 * * * *
    cron.1.job.1.cmd=syswrapper.sh refresh-walled-garden 1
    dnsmasq.walled_garden.1.status=enabled
    dnsmasq.walled_garden.1.site.1.allowed=www.example.net
    dnsmasq.walled_garden.1.site.2.allowed=example.com
    dnsmasq.walled_garden.1.site.1.restricted=ads.example.org

Key shapes worth writing down:

- The garden index is always `1`; the firmware's `if_seq` argument is that index
  (`syswrapper.sh refresh-walled-garden 1` → `/tmp/allowed.1.txt`,
  `/tmp/restricted.1.txt`).
- `allowed` and `restricted` are indexed **independently, both from 1**. `site.1.allowed`
  and `site.1.restricted` are two different sites.
- The order is a Java `Set`'s iteration order, not the operator's: the capture above put
  `www.example.net` (configured third) before `example.com`. The index is all there is.
- The whole block is emitted only when the **allowed** domain set is non-empty
  (`if (set.size() > 0)`), so a garden of restricted domains alone never reaches the
  device, although the `RESTRICTED_DOMAIN_IN` chain is still pushed.
- The allowed set is wider than the operator's list: it also carries the hosts each
  enabled payment or social-login provider needs, and `images.unsplash.com` when the
  portal's background gallery is on.

**Which form openUF gets is a capability gate.** `ubntconf/jNUeeSBEuWe` emits an
`ipset.status=enabled` block with hash sets instead, and the caller is explicit:

    boolean bl8 = this.Gdhc.NvfcKfHPI(settings) && !hyFnQ2.supportIPSet();   // the cron job
    ...
    if (!hyFnQ2.supportIPSet()) { this.kCNoUwYXLXMAUl(stringBuilder, settings); }  // the dnsmasq block

`supportIPSet()` is `hasFirmwareCapability(0x40000)`; openUF sends `fw_caps 0x1110`, so it
is unclaimed and the `dnsmasq.walled_garden` form is what arrives. No capture of the ipset
form is needed for that claim, and claiming the bit would swap a working encoding for one
openUF does not implement.

**What the firmware does with it (U7LR 6.8.2, `/bin/walled_action.sh`, plaintext).**
`ubntbox` writes the names to `/tmp/allowed.1.txt` / `/tmp/restricted.1.txt` (the strings
`dnsmasq.walled_garden.%d.status`, `dnsmasq.walled_garden.%d.site.`, `/tmp/allowed.%d.txt`
are all in that binary). The script then flushes the three chains, runs `nslookup` over
each name **twice** ("so we don't miss any ip" — round-robin records), dedupes the IPv4
answers, and appends `--ip-dst … -j ACCEPT` / `--ip-src … -j ACCEPT` /
`--ip-dst … -j DROP`. A failed lookup is logged to `/tmp/walled_action.log` and skipped,
which leaves that site out of the garden entirely. It runs on `ipready` (IP acquisition)
and from the pushed cron job.

**openUF (2026-10-26).** `guestportal.parse` reads both halves; `M._resolve` is the
resolver seam (`nslookup`, addresses taken only after the first `Name:` line, since the
header gives the resolver's own address in the same shape); `resolve_garden` asks each name
twice like the firmware and **keeps the last good answer** for a name that stops resolving,
in `state.json`'s `guest_wg_ips`. `inform._guest_wg_resync` re-resolves on the pushed
cadence (600 s) and rebuilds only when the address set actually moved, and
`sysconf.CRON_IN_DAEMON_PATTERNS` therefore installs no crontab line for the job.

Verification:
- **Tier 1:** 8 new tests; the kept-answer branch, the port-less accept, the all-digit
  label rule, the `Name:` cut and the two resolver passes were each mutation-tested red.
- **Tier 2:** the capture above replayed through `parse` with 0 unknown shapes, then the
  generated statements run against the lab's **real nft 1.0.9** on a dummy netdev — every
  statement accepted, 37 rules, identical on a second run (idempotent). Then end to end:
  the lab AP on the new code, a force-provision, `handle_response failed` = 0, no
  unrecognised-rule lines (there were five per push before), the two resolvable names in
  `guestin` as four `ip daddr … accept` rules above every drop, `ads.example.org` (NXDOMAIN)
  logged as not enforced, and `dnsmasq.walled_garden.*` gone from the dropped-key report
  (`dnsmasq.status` and `dnsmasq.<n>.*` stay: those ask for a local resolver openUF does
  not run).
- **Tier 3:** deployed to both APs and confirmed **inert** — the home site runs no guest
  portal, so no `openuf_guest` tables exist, which is the same tier the rest of the guest
  portal has. The resolver seam itself was run on both boards against their real resolver:
  `example.com` → two addresses, `www.iana.org` → two, `nxdomain.invalid` → none, identical
  on ath79 and filogic. No Passpoint-style claim is made for a real guest: no guest client
  has ever reached a garden site through openUF.

**This project's VM lab, 2026-10-30: the garden on the air.** The site's guest portal on (no
auth) with "Pre-Authorization Access" holding a domain (`example.com`) and an address
(`1.1.1.1/32`), and a WPA2 WLAN made a guest network. On the AP the guest table's `guestin` carried
`ip daddr 104.20.23.154 accept`, `ip daddr 172.66.147.243 accept` (the domain, resolved on the AP)
and `ip daddr 1.1.1.1 accept`, with the matching `ip saddr` accepts in `guestout`, all above the
restricted-subnet drops. From an unauthorised guest client over WiFi: `http://1.1.1.1/` answered
301 and `http://example.com/` 200 (both reached the internet), while `http://9.9.9.9/` got openUF's
302 to `http://<controller>:8880/guest/s/default/?id=<client>&ap=<ap>&...&ssid=<ssid>`.

### Hotspot 2.0 / Passpoint: `aaa.<n>.hs20.*` (jonasevcik ce7163f, 2026-10-26)

**In this tree** `fw_caps` gains `0x800000` and `fw2_caps` `0x80000` only where the probe
says hostapd can answer ANQP; the rest is as they wrote it.


Confirmed on the wire in the lab (10.6.106) on 2026-10-26: a WLAN with an embedded
`hotspot2` object, pushed to an openUF AP claiming `fw_caps` `0x800000` and `fw2_caps`
`0x80000`, carries 55 `aaa.<n>.hs20.*` keys plus `wireless.<n>.dgaf_disable`. Emitter:
`com/ubnt/service/config/VAZShipWTNxlo`.

Three gates had to be passed before any of it was capturable, and each one cost a wrong
first attempt:

1. **`fw_caps` `0x800000`** — without it `ubntconf/LsyaJoEysWb` drops the WLAN from the
   AP's config entirely, so the push contains no `hs20` key.
2. **`fw2_caps` `0x80000`** — a *third* firmware capability mask openUF had never sent,
   read by `hyFnQ.getFirmware2Capabilities()` from the field `"fw2_caps"`. The REST
   validator `com/ubnt/service/W/ctfbDsCjrxgkv` computes
   `supportsHotspot2Passpoint() = supportHotspot2() && supportsRadSec()` and refuses the
   WLAN with `api.err.DevicePasspointNotSupported`, so Passpoint cannot be reached without
   claiming RadSec. See [Capability bitmasks](#capability-bitmasks) for the trade.
3. **The profile must be an embedded object on the WLAN, not a reference.**
   `hotspot2conf_id` is not a `WlanConf` field and is silently dropped (the first attach
   produced a push with zero `hs20` keys). The settings live in a `hotspot2` object inside
   the wlanconf, whose schema (`api/fields/WlanConf.json`) is a **subset** of the
   standalone `api/fields/Hotspot2Conf.json`.

That subset is the whole reachable keyspace. These keys exist in the emitter and **cannot
be made to arrive** on a WLAN, so openUF reads none of them and no consumer is keyed on
them: `hessid`, `anqp_domain_id`, `network_auth_type`/`network_auth_url`,
`t_c_filename`/`t_c_timestamp`, `osu_ssid`, `osu.*`, `icon.*`,
`gas_comeback_delay`/`gas_frag_limit`, `qos.map.*`/`qos.exception.*`. OSU and icons are
unimplementable anyway: the installed hostapd (`wpad-mbedtls`, v2.12-devel) has no
`osu_server_uri`, `osu_ssid` or `hs20_icon` option at all. `aaa.<n>.hs20.esr` does arrive
but is deliberately not read — `ap.uc` never emits `esr`, so a field for it would be a
consumer with no producer at the other end.

The captured block, verbatim apart from placeholder addresses (it is replayed in full by
`tests/test_inform_packet.lua`):

```
aaa.1.hs20.status=enabled              aaa.1.hs20.access_network_type=2
aaa.1.hs20.internet=enabled            aaa.1.hs20.asra=disabled
aaa.1.hs20.esr=disabled                aaa.1.hs20.uesa=disabled
aaa.1.hs20.venue_group=2               aaa.1.hs20.venue_type=8
aaa.1.hs20.disable_dgaf=disabled       aaa.1.hs20.deauth_req_timeout=60
aaa.1.hs20.network_availability=13     aaa.1.hs20.hs20_domain_name_list=example.com,example.net
aaa.1.hs20.venue_name.1.lang=eng       aaa.1.hs20.venue_name.1.name=openUF Lab
aaa.1.hs20.venue_name.1.url=https://example.com/venue
aaa.1.hs20.nai_realm.1.status=enabled  aaa.1.hs20.nai_realm.1.encoding=0
aaa.1.hs20.nai_realm.1.name=example.com
aaa.1.hs20.nai_realm.1.eap_method=13
aaa.1.hs20.nai_realm.1.eap_method.auth.1.id=5
aaa.1.hs20.nai_realm.1.eap_method.auth.1.val=6
aaa.1.hs20.1.roaming_consortium=506f9a aaa.1.hs20.2.roaming_consortium=001bc504bd
aaa.1.hs20.3gpp.1.mcc=230              aaa.1.hs20.3gpp.1.mnc=01
aaa.1.hs20.friendly_name.1.language=eng
aaa.1.hs20.friendly_name.1.text=openUF Operator
aaa.1.hs20.capab.1.protocol=6          aaa.1.hs20.capab.1.port=80
aaa.1.hs20.capab.1.status=open
aaa.1.hs20.metrics.status=enabled      aaa.1.hs20.metrics.info=1
aaa.1.hs20.metrics.downlink_speed=8000 aaa.1.hs20.metrics.uplink_speed=1000
aaa.1.hs20.metrics.downlink_load=80    aaa.1.hs20.metrics.uplink_load=40
aaa.1.hs20.metrics.measurement=3000
wireless.1.dgaf_disable=disabled
```

Key shapes worth writing down, because none of them is the obvious one:

- The roaming-consortium index comes **before** the name (`hs20.<k>.roaming_consortium`),
  unlike every other indexed block here.
- `network_availability` is already the combined `(IPv4 availability << 2) | IPv6`
  octet hostapd wants as `ipaddr_type_availability`; the controller does the combining.
- `hs20_domain_name_list` arrives as one comma-separated string, which is also hostapd's
  `domain_name` format, so it passes through untouched.
- An MNC keeps the width it was sent with (`01` stays two digits, `002` three).
- `capab.<k>.status` is a word (`open`/`closed`/`unknown`) and hostapd wants
  `1`/`0`/`2`.
- `metrics.info` is a decimal on the wire and **hex in hostapd**: `hs20_wan_metrics`'s
  first field is parsed with `hexstr2bin()` over exactly two characters, so `1` must be
  written as `01`. This was found by feeding openUF's own generated config to a real
  hostapd — a rejected line is a config *parse* error, and hostapd then refuses the whole
  BSS, not just the line.

Consumer side, read from `/usr/share/ucode/wifi/ap.uc` on an Archer C5 (25.12,
`wpad-mbedtls`) on 2026-10-26: `iface_hs20()` is gated on `config.hs20` and
`iface_interworking()` on `config.iw_enabled`, which it turns into `interworking=1`. Two
hazards made openUF write every cumulative list as a raw `hostapd_bss_options` line
instead of a UCI list option:

- `wifi.common`'s `append()` joins an array with **spaces** into one `name=a b c` line,
  which is not what `venue_name`, `nai_realm`, `roaming_consortium`, `domain_name`,
  `anqp_3gpp_cell_net`, `hs20_oper_friendly_name` or `hs20_conn_capab` means — each needs
  one line per entry.
- `iface_interworking()` contains `if (config.anqp_3gpp_cell_net) config.domain_name =
  join(',', config.anqp_3gpp_cell_net)`, i.e. it **overwrites** `domain_name` with the
  cell-net list.

Raw options are appended last by `generate()`, after every `append_vars()` call, so
hostapd reads them last. Verified end to end on an Archer C5 on 2026-10-26: the wifi-iface
section openUF generates for the captured push was fed to the **device's own** ucode
generator (read-only, output to a temp file), which produced `interworking=1`, `hs20=1`,
`hs20_wan_metrics=01:8000:1000:80:40:3000` and all fourteen raw lines; that exact config
then parsed on a real hostapd v2.12-devel with **zero** `Line N:` errors. ⚠️ No Passpoint
client has associated, and no Passpoint WLAN exists on the production controller.

A last consumer-side constraint shapes the parser: hostapd refuses a configuration that
has `hs20=1` without WPA2-Enterprise/CCMP ("HS 2.0: WPA2-Enterprise/CCMP configuration is
required for Hotspot 2.0 functionality"), so openUF accepts an `hs20` block only on a
WPA-Enterprise WLAN and logs the drop otherwise.

**This project's VM lab, 2026-10-30: ANQP answered over the air.** With the probe passing,
the controller saw `fw_caps -2138042096` (0x80901110) and `fw2_caps 524288` and accepted a
Passpoint WLAN. On 10.6.106 the Hotspot 2.0 settings must be **embedded in the WLAN**
(`wlanconf.hotspot2 = {...}` plus `hotspot2conf_enabled`): a separate profile referenced by id
is not stored and the push then carries no `hs20` keys. A realm's `eap_method` must be one of
13/21/18/23/50. With that, the AP's live hostapd carried `interworking=1`, `hs20=1`,
`access_network_type`, `internet`, `venue_group/type`, `venue_name`, `domain_name`,
`nai_realm=0,lab.example,21`, `roaming_consortium` and `ipaddr_type_availability`, with no
config errors, and a client (`wpa_cli anqp_get`) received the venue name, the roaming
consortium, the NAI realm (EAP 21) and the domain name back as ANQP elements. No Passpoint
credential has been used to associate.

### RADIUS MAC authentication and Dynamic Authorization (jonasevcik bd2e29b, 2026-10-27)

Their evidence, as they wrote it; this project's lab run follows it.


The two deliberate deferrals of the WPA-Enterprise commit, closed. Both are settings of a
WLAN's RADIUS profile, and **neither needs the WLAN to be WPA-Enterprise.**

**Where they come from (10.6.106, `com/ubnt/service/config/VAZShipWTNxlo`).**

| Setting | Gate in the writer | Keys emitted |
|---|---|---|
| MAC Authentication | `glUEhxTYZtqmhf.is("radius_mac_auth_enabled")` at `:639` — **no capability bit, no security-type condition**; the `else` branch at `:646` sends `radius.macacl.status=disabled` | `aaa.<n>.radius.macacl.{status,emptypassword,format}`, plus the whole `radius.auth.<k>.*` block (`:640`, and `NvfcKfHPI(...)` for a non-EAP WLAN) |
| RADIUS DAS | `hasFirmwareCapability(0x100000)` at `:567`, AND (`radius_das_enabled` OR `hotspot2conf_enabled`), AND the profile's `accounting_enabled` at `:948` | `aaa.<n>.radius.das.{status,port,client,secret}` (`:954`, `:973`) and the second shape `aaa.radius.dad.{status,port}` + `aaa.<n>.radius.dad.client.<k>.{cidr,secret}` (`:951`, `:976`) |

`radius_mac_auth_enabled`, `radius_macacl_format` and `radius_macacl_empty_password` are
WlanConf fields (`api/fields/WlanConf.json:142-145`); `format` is an enum
`none|hyphen|colon` × `lower|upper`. The DAS client address and secret are taken from the
**first accounting server**, written once, and the port is `3800 + the WLAN's section index`.

**What the AP does with them (U7LR 6.8.2 `sbin/ubntbox`).** The format strings sit together
and name their hostapd output directly:

```
aaa.%d.radius.das.port      -> radius_das_port=%u
aaa.%d.radius.das.client
aaa.%d.radius.das.secret    -> radius_das_client=%s %s
aaa.%d.radius.dad.client.%d.secret -> radius_das_client=127.0.0.1 %s
aaa.%d.radius.macacl.status -> macaddr_acl=2
aaa.%d.radius.macacl.format -> macaddr_format=%s
aaa.%d.radius.macacl.emptypassword -> mac_acl_empty_passwd=%d
```

Two things fall out of that. The `dad.*` shape points hostapd at **localhost** — the request
reaches the AP's own `mcad`, which checks the CIDR and relays it — so it is unusable without
that relay. And `macaddr_format`/`mac_acl_empty_passwd` are options of UniFi's **patched**
hostapd: neither string occurs in `/usr/sbin/hostapd` on either AP (`strings -a | grep -c`
gives 0 on ath79 and on filogic), while `radius_das_client`, `radius_das_port` and
`macaddr_acl` all do.

**The OpenWrt consumers, read off the live 25.12.5 generator** (`/usr/share/ucode/wifi/ap.uc`,
identical on both boards):

- `macaddr_acl` is **not a wifi-iface option**: it is absent from
  `/usr/share/schema/wireless.wifi-iface.json`, and the only producers are
  `iface_macfilter()` (`allow` → 1, `deny` → 0) and `ppsk` → 2. So it goes in through
  `hostapd_bss_options` (ap.uc:612, raw lines appended last). `ppsk=1` would also set it, but
  in `case 'psk'` it additionally sets `wpa_psk_radius=2` and leaves the passphrase out —
  that is UniFi's *Private PSK* feature, not MAC auth, and would make the WLAN unjoinable.
- `iface_authentication_server()` is called **only** from the EAP branch and from
  `iface_ppsk()`, so on an open/PSK/SAE BSS the `auth_server_*` options are stored and
  dropped. `iface_accounting_server()` is called unconditionally, so `acct_server_*` is fine
  as an option. openUF therefore writes the auth servers raw on a non-EAP WLAN and through
  UCI on an EAP one.
- `radius_das_client` and `radius_das_port` are in ap.uc's unconditional `append_vars` list,
  **but the join** `radius_das_client = client + ' ' + secret` (ap.uc:187-189, with
  `set_default(radius_das_port, 3799)`) sits inside `case 'eap'`. `radius_das_secret` and its
  `dae_secret` alias are in the schema with no other consumer — the "stored and silently
  dropped" shape. openUF joins the two itself, which is both what the firmware writes and
  what hostapd parses (first token the address, the rest of the line the secret), and always
  writes the port explicitly because hostapd's own default is 0 = no listener.

**Why MAC authentication fails closed.** A WLAN that asks for it and cannot have it (no
usable RADIUS server, or a `wpad` with no RADIUS client) is **dropped**, not provisioned
without it: it is an access control, and on an open WLAN it is the only one. The RADIUS-client
check is not cosmetic either — on a basic `wpad`, `auth_server_addr` is an unknown option and
hostapd refuses the whole config, so the BSS would not come up anyway.

**Lab, 10.6.106, 2026-10-27.** MAC auth on an **open** guest WLAN with the lab RADIUS profile
attached, verbatim:

```
aaa.3.radius.macacl.status=enabled
aaa.3.radius.macacl.emptypassword=enabled
aaa.3.radius.macacl.format=%.2X-%.2X-%.2X-%.2X-%.2X-%.2X
aaa.3.radius.auth.1.ip=…   .port=1812  .secret=…       (and auth.2)
aaa.3.radius.acct.1.ip=…   .port=1813  .secret=…
aaa.3.interim_update.status=enabled   .interval=900
aaa.3.dynamic_vlan=2
```

— the `format` really is a printf string. With `fw_caps 0x100000` claimed and "RADIUS DAS" on,
the same push gained, per WLAN:

```
aaa.radius.dad.status=enabled        aaa.radius.dad.port=3799
aaa.1.radius.das.status=enabled      aaa.1.radius.das.port=3801
aaa.1.radius.das.client=<acct server ip>   aaa.1.radius.das.secret=<secret>
aaa.1.radius.dad.status=enabled
aaa.1.radius.dad.client.1.cidr=<acct server ip>/32   .secret=<secret>
```

with ports 3801–3804 across the four BSSes. `tools/cfg-coverage.lua` puts all four `das.*`
keys per BSS and `macacl.status` where it is enabled in **consumed**, and leaves `dad.*`,
`macacl.format` and `macacl.emptypassword` outside it. Replaying the capture through
`_parse_wifi_system_cfg` + `apply_config` with a recording cursor gives the EAP WLAN
`radius_das_client=<ip> <secret>` + `radius_das_port=3801` with the servers as UCI options,
and the open WLAN the raw `auth_server_addr/port/shared_secret` triplets followed by
`macaddr_acl=2`, with **no** `dynamic_vlan`. 0 `handle_response failed`.

**A real hostapd parses it, and refuses the alternative.** Feeding the generated option set to
the APs' own hostapd build (`openwrt/rootfs:x86-64-25.12.0` + `wpad-mbedtls`) gives zero
configuration errors — it proceeds to driver init and fails only for want of nl80211.
Splitting the DAS client and secret into two options instead, which is what the schema
invites, gives `Line 10: invalid DAS client` / `1 errors found in configuration file` and
hostapd refuses the interface: the join is load-bearing, not cosmetic.

**Hardware, 2026-10-27, both APs.** Deployed and restarted on both boards; `fw_caps` now
`0x101110` and the production controller answered with steady noops and no new push, which is
correct — no WLAN here has a RADIUS profile, so no `macacl`/`das` key is emitted. `uci show
wireless` carries no `radius_*`, `macaddr_acl` or `dynamic_vlan` anywhere, the SAE raw lines
are untouched, and no BSS in `/var/run/hostapd-phy*.conf` gained an option. **Not claimed:**
there is no RADIUS server at home, so no client has been admitted or denied by MAC, and no
CoA/Disconnect has been answered on hardware.

**Declines, each with its reason.**

| Key | Verdict |
|---|---|
| `radius.macacl.format` | **decline: no consumer.** A printf format string for UniFi's patched `macaddr_format=`; absent from OpenWrt's hostapd on both boards, which sends twelve lower-case hex digits with no separators (`00005e005301`, seen in this project's lab). A real limitation (a server expecting another format rejects the client), documented in USAGE.md |
| `radius.macacl.emptypassword` | **decline: no consumer.** UniFi's `mac_acl_empty_passwd=`; same absence |
| `aaa.radius.dad.{status,port,loglevel}`, `radius.dad.client.<k>.{cidr,secret}` | **decline: needs a relay openUF does not have.** The firmware turns it into `radius_das_client=127.0.0.1`, accepting the request from its own daemon; hostapd pointed at localhost would answer nobody. The `das.*` shape carries the same information and is implemented |
| `aaa.<n>.dynamic_vlan` on a non-EAP WLAN | **decline: would break the WLAN.** `2` (required) with no `vlan_file` makes hostapd reject every station, and openUF writes no `wifi-vlan` sections for RADIUS-assigned VLANs. Honouring it needs the dynamic-VLAN plumbing |

**This project's VM lab, 2026-10-29.** "MAC Authentication" on a WPA2-PSK WLAN with the lab
RADIUS profile (FreeRADIUS 3.2.10): the AP's live hostapd carried `macaddr_acl=2` and the auth
servers. **The format correction:** hostapd asked with `User-Name = "024f55030100"`, twelve
lower-case hex digits and **no separators**, not the colon-separated form written above. With the
client listed colon-separated the server answered Access-Reject and the client never joined;
listed as `024f55030100` it answered Access-Accept and the client joined and passed traffic. Then
**Dynamic Authorization**, with accounting and RADIUS DAS on in the profile: hostapd carried
`radius_das_client=<first accounting server> <secret>` and `radius_das_port=3803` (3800 + the
WLAN index); a Disconnect-Request (RFC 5176, Calling-Station-Id + Event-Timestamp) sent from
that address was answered Disconnect-ACK, hostapd logged `AP-STA-DISCONNECTED` for the client
and the client saw `CTRL-EVENT-DISCONNECTED reason=2`.

### WPA-Enterprise: `aaa.<n>.radius.*` (jonasevcik 9400e68, 2026-10-26)

Their evidence, as they wrote it; this project's lab run follows below it.


An earlier revision of this document, and of `inform.lua`, stated that "the wire protocol
carries no RADIUS server, port or secret" and skipped every WPA-Enterprise WLAN on that
basis. **That was wrong**, and the mistake has a clear cause: the capture it rested on was
taken from a site with no RADIUS profile configured, where the block is simply absent —
the recurring trap this document warns about, treating a block's absence as the
discriminator.

Emitter: `com/ubnt/service/config/VAZShipWTNxlo` (controller 10.6.106, CFR). Consumer on a
genuine AP: the hostapd generator inside `sbin/ubntbox` (firmware-confirmed for U7LR 6.8.2),
which writes `auth_server_addr`/`auth_server_port`/`auth_server_shared_secret`, the `acct`
twins, `radius_acct_interim_interval`, `dynamic_vlan` and `nas_identifier` from exactly
these keys. **The eligibility filter (`ubntconf/LsyaJoEysWb`) applies no device capability
gate to a WPA2-Enterprise WLAN**, so a controller has always been pushing this to openUF.

| Key | Meaning |
|---|---|
| `radius.auth.<k>.{ip,port,secret}` | Authentication servers, 1-based, in the RADIUS profile's order. Port defaults to 1812. |
| `radius.acct.<k>.{ip,port,secret}` | Accounting servers, same shape. Port defaults to 1813. Present only with `accounting_enabled`. |
| `radius.{auth,acct}.<k>.tls` | RadSec. The certificates themselves are **not** on the wire — only filenames of files transferred by another channel, so the server cannot be completed from the push alone. |
| `interim_update.status` / `.interval` | Interim accounting updates; the interval is seconds (default 3600). |
| `dynamic_vlan` | `0`/`1`/`2` from the profile's "RADIUS assigned VLAN" mode (off / optional / required). |
| `nas_identifier` | The profile's NAS id, when set. |
| `radius.das.*`, `radius.dad.*` | DAS/CoA (disconnect/change-of-authorization). Parsed by nothing; openUF derives no field from them. |
| `radius.macacl.status` | RADIUS **MAC authentication**, a separate control. Already flagged as a decoy in the MAC-filter row of the feature matrix. |

Captured verbatim in the lab on 2026-10-26 (controller 10.6.106, a `wpaeap` wlanconf with
two auth servers, one acct server, interim updates at 900 s and `vlan_wlan_mode: required`;
addresses scrubbed to the documentation range):

```
aaa.1.wpa=2
aaa.1.wpa.key.1.mgmt=WPA-EAP
aaa.1.wpa.psk=letmeinnow
aaa.1.radius.auth.1.ip=192.0.2.10     aaa.1.radius.auth.1.port=1812
aaa.1.radius.auth.1.secret=…          aaa.1.radius.auth.2.ip=192.0.2.11
aaa.1.radius.auth.2.port=1812         aaa.1.radius.auth.2.secret=…
aaa.1.radius.acct.1.ip=192.0.2.10     aaa.1.radius.acct.1.port=1813
aaa.1.radius.acct.1.secret=…          aaa.1.interim_update.status=enabled
aaa.1.interim_update.interval=900     aaa.1.dynamic_vlan=2
aaa.1.radius.macacl.status=disabled   aaa.1.hs20.status=disabled
wireless.1.security=none
```

Two decoys in that block, both now pinned by tests:

- **`aaa.<n>.wpa.psk` is still sent on an EAP WLAN** — `letmeinnow`, a dummy the controller
  fills in. Carrying it into UCI would give the BSS a passphrase it must not have, so
  openUF forces `x_passphrase = nil` on an Enterprise WLAN and refuses to write a `key` for
  any encryption outside an explicit pre-shared-key allow-set.
- **`wireless.<n>.security=none` on the same push.** The discriminator is
  `aaa.<n>.wpa.key.<k>.mgmt`, as it is for SAE.

OpenWrt side, read on an Archer C5 (ath79, 25.12, `wpad-mbedtls`, hostapd v2.12-devel) on
2026-10-26. On 25.12 `/lib/netifd/wireless/mac80211.sh` is itself a ucode script importing
`wifi.iface`, so `/usr/share/ucode/wifi/` is the live generator and `hostapd.sh` is dead
weight. Calling the generator's own `parse_encryption()`/`wpa_key_mgmt()` on the device:

| UCI `encryption` | `auth_type` | `wpa` | pairwise | `wpa_key_mgmt` (with 802.11r) |
|---|---|---|---|---|
| `wpa2+ccmp` | `eap` | 2 | CCMP | `WPA-EAP` (`+ FT-EAP`) |
| `wpa3` | `eap2` | 2 | CCMP | `WPA-EAP-SHA256` (`+ FT-EAP`) |
| `wpa3-mixed` | `eap-eap2` | 2 | CCMP | `WPA-EAP-SHA256 FT-EAP WPA-EAP` |
| `wpa3-192` | `eap192` | 2 | GCMP-256 | `WPA-EAP-SUITE-B-192` (`+ FT-EAP-SHA384`) |
| `eap` | `eap` | **0** | — | — |

That last row is the trap: `encryption=eap` sets the right `auth_type` and then matches no
`config.wpa` wildcard, so the BSS comes up with `wpa=0` — an open network where an
Enterprise one was asked for. openUF maps the four working values and never that one.

`ap.uc`'s EAP branch writes `ieee8021x=1`, `eapol_version`, the key-mgmt list and (unless
`eap_server` is set) calls `iface_authentication_server()`/`iface_accounting_server()`
itself, so openUF writes none of those — only the server options, the interim interval, the
NAS id and `dynamic_vlan`. It also sets `vlan_possible = 1`, which is what makes
`dynamic_vlan` reach hostapd at all. `iface_ppsk()` is gated to non-EAP auth types, so an
EAP VAP's `auth_server_addr` is not re-consumed by the PPSK path.

Two schema limits, both stated as narrowings in USAGE.md rather than worked around:
`auth_server_port`/`auth_server_shared_secret` are written **once** per server list, so a
server with its own port or secret cannot be expressed and is dropped with a log; and
openUF writes no `wifi-vlan` section for a RADIUS-assigned VLAN (the push enumerates none),
so with `dynamic_vlan=2` hostapd refuses a station assigned a VLAN this AP has no network
for. The schema's `auth_server`/`auth_port`/`auth_secret`/`acct_interval`/`nasid` are
`"type": "alias"` entries; openUF writes the canonical names `ap.uc` reads literally.

`radio_caps2` `0x4` (WPA3-Enterprise-192) stays **unclaimed** — see
[Capability bitmasks](#capability-bitmasks). WPA3-Enterprise needs only the SAE bit `0x1`;
WPA2-Enterprise needs no bit at all.

**This project's VM lab, 2026-10-29: a real 802.1X login.** A RADIUS profile pointing at a
FreeRADIUS 3.2.10 server on the lab LAN, a WPA2-Enterprise WLAN on 5 GHz, pushed by the
10.6.106 controller to two openUF APs. On the AP: `encryption='wpa2+ccmp'`,
`auth_server_addr`/`auth_server_port`/`auth_server_shared_secret` in UCI and in live hostapd
(`wpa_key_mgmt=WPA-EAP`, `ieee8021x=1`), no `key` on the EAP BSS, the PSK WLAN beside it
untouched. A client logged in with PEAP/MSCHAPv2 (`CTRL-EVENT-EAP-SUCCESS`), the server logged
`Sent Access-Accept`, the client took a DHCP lease and passed traffic. Note for a containerised
server: Docker's published UDP port can arrive from the bridge gateway, not the AP's address,
so the server's client list must cover that range.

### The site's auto-channel DFS switch and channel blacklist (jonasevcik 6883b20, 2026-10-27)

**In this tree** `wifi_caps2` gains `0x10` on top of our own bits (`0x4000F2`); a board
profile's `acs_exclude_dfs` is never lifted by the site's switch.

**This project's VM lab, 2026-10-29.** Two APs on Auto, a site with the default
"conservative" preset. Once the controller had re-pushed after seeing `wifi_caps2`
`0x4020F2`, the 2.4 GHz `radio.1.blklst=12,2,13,3,14,4,5,7,8,9,10` became
`chanlist='1' '6' '11'` (stamped `openuf_chanlist`) in UCI and `chanlist=1 6 11` in live
hostapd, and ACS picked 11 on one AP and 6 on the other. With the site's 5 GHz DFS switch
turned on, the push carried `radio.2.acsdfs=enabled` (read from a one-push `debug_dump_file`
capture, deleted after) and the AP, whose profile excludes DFS, kept `acs_exclude_dfs=1` in
UCI and in hostapd. No ACS has yet chosen among DFS channels here.

Their evidence follows.

| mask | bit | predicate | effect without it |
|---|---|---|---|
| `wifi_caps2` | `0x10` (16) | `Device.supportsAcsDfs()` = `hasWifiCapability2(16)` | The controller emits **neither** `radio.<n>.acsdfs` **nor** `radio.<n>.blklst`: one `if (supportsAcsDfs())` in `com/ubnt/service/config/ubntconf/PFljhxhmKJyhpeIhf` guards the block that writes both, so the site's auto-channel DFS switch and its channel blacklist are silently dropped. Confirmed live in the lab: claimed, both appear (and nothing else moves). |

#### Radio and system keys (their Axis 1/2), settled 2026-10-27

The last of the four axes' leftovers: `qos.mode`, `radio.<n>.antenna.gain`, `radio.outdoor`,
`backup_channel`, `scan_list.*`, `ch144` and `system.monitor.*`. Settled from the controller
side first, which is cheap and decisive: a key the 10.6.106 jar never writes cannot arrive,
whatever the firmware does with it. Method: `grep -rl` each key literal over the 21 629
extracted classes (the writer builds keys as `"radio." + n` plus a literal suffix, so the
suffix is searchable), then decompile the hits with CFR.

| Key | In the jar? | Verdict |
|---|---|---|
| `radio.<n>.acsdfs`, `radio.<n>.blklst` | yes, `config/ubntconf/PFljhxhmKJyhpeIhf` | **implemented** — see below |
| `qos.mode` | yes, `config/VAZShipWTNxlo:2078` | **decline: constant by construction.** The writer emits the literal `"mode", "1"` — there is no setting behind it, like `wireless.<n>.wmm`. |
| `radio.<n>.antenna.gain`, `radio.<n>.antenna` | yes, `config/VAZShipWTNxlo:510` | **decline: no consumer, and the value is not about this hardware.** It comes from the controller's own radio config document (`antenna_gain`, default 6; a U6-IW identity gets 3 with `antenna_id=-1`, i.e. built-in), so it describes the *impersonated* AP's antennas, not the host board's. 6.8.2 feeds it to a QCA vendor ioctl (`iwpriv <dev> ant_gain <n>`). UCI `antenna_gain` is in 25.12's `wireless.wifi-device.json` schema but appears **nowhere** in `/usr/share/ucode/wifi/` or `/lib/netifd/` on either AP — a stored-and-dropped option, the shape CLAUDE.md warns about. |
| `radio.outdoor` | yes, `config/VAZShipWTNxlo:492` | **decline: no equivalent consumer.** A real toggle (site `outdoor_mode_enabled`, with a per-device override; `devmgr/kDxteQiUX:114-119`), but 6.8.2 applies it as `iwpriv <dev> outdoor <0\|1>`, a QCA regulatory switch. mac80211's nearest knob is `country3` — the Country IE's environment octet — which only changes what clients are *told*, not the channel/power table the radio uses. Not a trade to make blind on a 5 GHz radio: `ieee80211d`/`h` already took both APs' 5 GHz down once. |
| `radio.<n>.backup_channel`, `radio.<n>.scan_list.{status,channels}`, `radio.<n>.ch144` | **no hits at all** | **decline: no emitter.** Consumed by `ubntbox` (the strings are right beside `blklst`), but nothing in the controller writes them, so they can never reach an AP. |
| `system.monitor.*` | only `memory.threshold` and `critical_memory.threshold`, `config/lwueNrOWUBYJX:802-806` | **decline: gateway-only.** They are written from a per-model enum (`config/kYktyHCkPVCBdJC`) whose entries are UDM/UDR/UCG/UXG — `ifPresent`, so an AP identity gets nothing. The firmware's `system.monitor.<x>.{host,poll_interval,status}` ping monitor has no emitter whatsoever. |

#### `radio.<n>.acsdfs` / `radio.<n>.blklst` — the site's auto-channel limits

Both keys sit inside one `if (hyFnQ2.supportsAcsDfs())` in
`com/ubnt/service/config/ubntconf/PFljhxhmKJyhpeIhf`, and `supportsAcsDfs()` is
`hasWifiCapability2(16)`. So one unclaimed capability bit was hiding two real settings:

```java
if (hyFnQ2.supportsAcsDfs()) {
    // BAND_NA only: enabled/disabled from radios_configuration[radio=na].dfs
    OWIoHe.kCNoUwYXLXMAUl(stringBuilder, "radio." + n, "acsdfs", string);
    if ("auto".equals(channel)) {           // only while the radio is on Auto
        // channels_blacklist, grouped by band
        OWIoHe.kCNoUwYXLXMAUl(stringBuilder, "radio." + n, "blklst", String.join(",", set));
    }
}
```

Both come from the site's **Radio AI** setting (`get/setting/radio_ai`): `radios_configuration`
carries a `dfs` boolean per band, `channels_blacklist` a list of `{radio, channel,
channel_width}`. A default site is not empty — the `conservative` preset blacklists every
2.4 GHz channel but 1/6/11, which is what the lab controller shipped with.

U7LR 6.8.2's side, from `sbin/ubntbox`: `blklst` becomes `wifitool <dev> block_acs_channel
<list>` (and `block_acs_channel 0` to clear), and `acsdfs=disabled` the same call over the
hardcoded DFS list `52,56,…,144`. Neighbouring strings show the firmware also narrows 2.4 GHz
ACS to 1/6/11 unless `acs_2g_allch` is set, which has no controller key.

openUF's equivalents, both `wifi-device` options read by hostapd's ACS:

- `acsdfs` → `acs_exclude_dfs` (hostapd's own flag; written as explicit 0/1).
- `blklst` → `chanlist`. hostapd has **no blacklist**, only the candidate list, so the
  blacklist is inverted against the channels the radio's regdomain allows, taken from the
  `iw phy` output `ucihelper.phy_caps` already parses (minus `no IR` channels: an AP may not
  beacon there). `openuf_chanlist` is the ledger that lets the list be removed again when the
  key vanishes from the wire, without touching a hand-set `chanlist`.

Three cases where openUF deliberately writes nothing, each logged: a blacklist that excludes
nothing this radio could have used (no churn), a blacklist covering the whole band (an ACS
with no candidate never comes up), and a radio on Auto whose UCI declares no `band`/`hwmode`
— `band_for_device` would fall back to the channel number, and `auto` is not one, so its
answer is "na" for every radio, which would hand a 2.4 GHz radio a list of 5 GHz channels.

Lab, 10.6.106, 2026-10-27: claiming the bit made both keys appear, and flipping the site's
DFS switch produced a **one-key diff** (`radio.2.acsdfs` `disabled` → `enabled`, nothing else
in 668 lines moved) with `acs_exclude_dfs` following it 1 → 0. `blklst` arrives unsorted
(`12,2,13,3,…` — a Java `Set`), which is why the parser keeps what it is given and the
ordering comes from the band's own channel list. `tools/cfg-coverage.lua` puts both in
**consumed**.

Hardware, 2026-10-27, both boards: the real site has DFS off for auto-channel, and after a
Force Provision `acs_exclude_dfs=1` was in UCI on the 5 GHz radio of each AP and in its live
`/var/run/hostapd-phy*.conf` (the 2.4 GHz BSS carries the schema default 0, which
`hostapd.uc` emits for every radio). Both radios here are pinned, so no `blklst` is pushed at
all; the inversion was instead run against each board's real channel list through the real
`rf_config` with a mock cursor, giving `36,40,44,48,149,153,157,161,165,169,173` for a DFS
blacklist on 5 GHz — exactly the non-DFS channels CZ allows, on ath10k and on mt76 — and the
teardown clearing both the list and its stamp. Not claimed: no radio here runs on Auto, so no
ACS has actually chosen under the restriction.

### The nightly dfs-reset, and the controller's cron verbs (jonasevcik ba3dec5, 2026-10-27)

**In this tree** `refresh-walled-garden` is declined and logged: the walled garden is not
ported yet.

**This project's VM lab, 2026-10-29.** The AP's 5 GHz radio pinned to channel 100 at 80 MHz
through the controller (site country US for the run). The build before this port logged the
pushed job as `not a command this build provides`; with it, the marked crontab block carries
`0 2 * * * /usr/bin/syswrapper.sh dfs-reset`. Moved to channel 36 by hand (a CSA through
hostapd, no radar), `syswrapper.sh dfs-reset` brought it back at the next heartbeat:
`dfs-reset: phy1-ap0 switching back from channel 36 to the configured 100 (5500
sec_channel_offset=1 center_freq1=5530 bandwidth=80 vht)`, back on 100 at 80 MHz after the CAC.
After a simulated radar hit (the radio went to 149), the job waited instead of switching.

**Fixed here: the wait message read iw's elapsed time as the time left.** It said "for another
10 s" 7 s after the hit. iw's `DFS state: unavailable (for N sec)` is how long the channel has
been in that state (`NL80211_FREQUENCY_ATTR_DFS_TIME`); the non-occupancy period is 30 minutes
(`IEEE80211_DFS_MIN_NOP_TIME_MS`). The line now reads `(unavailable for 258 s, about 1542 s
left)`, confirmed in the same lab. The decision itself was already right.

Their evidence follows, as they wrote it.


The jar check is done, and it settles the whole axis. Method, reproducible: extract
`internal-dependencies.jar` inside the lab controller container (`/tmp/idep`, 21 629
classes), decompile the command packages with CFR, and read the two ways a verb can
reach an AP.

**Route 1 — a `cmd` message.** The controller's device-command endpoint is one class per
command under `com/ubnt/service/devmgr/b/g/`, each carrying a `@…(…="<name>")`
annotation; the 48 names are the whole `cmd/devmgr` API surface
(`adv-adopt`, `build-ssh-session`, `cancel-migrate`, `clear-all-switch-counters`,
`clear-switch-port-counters`, `clone-config`, `close-ssh-session`, `esim-add`,
`esim-delete`, `force-provision`, `get-sdp-offer`, `hide-lcm-tracker`, `locate`,
`lte-set-profile`, `lte-verify-pin`, `migrate`, `outlet-ctl`, `port-recovery`,
`power-cycle`, `query-dpi-stats`, `quick-scan`, `read-inactive-slot-sim-card`,
`reset-usage`, `restart`, `rps-port-recovery`, `scan`, `set-alignment`, `set-locate`,
`set-port-locate`, `set-priority-uplink`, `set-rollupgrade`, `set-vwire-uplink`,
`setup-firewall`, `show-lcm-tracker`, `spectrum-scan`, `speedtest`, `speedtest-status`,
`ssh-sdp-answer`, `terminate-remote-user-vpn`, `unset-alignment`, `unset-locate`,
`unset-port-locate`, `unset-priority-uplink`, `unset-rollupgrade`, `unset-vwire-uplink`,
`upgrade`, `upgrade-all`, `upgrade-external`, `verify-pin`). The strings those handlers
actually put on the wire as `{"cmd": …}` are a smaller set:
`spectrum-scan`, `scan`, `kick-sta`, `block-sta`, `unblock-sta`, `rate-update`,
`authorize-guest`, `unauthorize-guest`, `set-locate`, `unset-locate`,
`clear-all-counters`, `clear-counters`, `clear-crashlog`, `clear-recovery`,
`clear-trace`, `send-crashlog`, `send-recovery`, `send-trace`, `query-dpi-stats`,
`clear-all-dpi-counters`, `power-cycle`, `rps-port-recovery`, `relayctl`,
`show-lcm-tracker`, `hide-lcm-tracker`, `build-ssh-session`, `close-ssh-session`,
`ssh-sdp-answer`, `set-element-payload`, `set-meshv3-payload`, `mesh-halt`, `unpair`,
plus the firmware-update enum (`fwupdate`, `get-udapi-blocks`, `probe-dhcpv6`,
`probe-slaac`, `shadow-mode-adopt`, `speed-test-udapi-start`/`-stop`,
`teleport-connect`/`-disconnect`, `wg-genkeypair`, all gateway/UDAPI).
**Not one of the ~50 triage verbs above is in either list.** They are declined, with the
reason named once for all of them: *not a controller command* — `mcad` invokes them from
its own state machine, from its cron, or over SSH. That closes `vlan-detected`,
`scan-rrm`, `airtime-scan`, `11k-boot`/`11k-stop`, `set-channel`, `get-support-file`,
`pcap-start`/`-stop`, `read-crash-log`, `dump-radar-log`, `mca-custom-alert`,
`schedule-action` *as a command*, `probe-lan-iface`, `ip-changed`, `soft-restart`,
`wireless-vlan-add`/`-del`, `del-bridge-vlans`, `get-tmpfs-usage`,
`install-runtime-package`, `netconsole`, `sensitive-data-filter` and the rest. The
counters/crashlog/SSH-console commands openUF already answers with `_note_unhandled`
stay no-ops on purpose (nothing here keeps per-port counters or a crash log).

**Route 2 — the pushed crontab.** This is the one that pays. Every `syswrapper.sh`
string in the whole jar, verbatim:

```
syswrapper.sh 11k-scan                 cron, 0 4 * * *
syswrapper.sh dfs-reset                cron, 0 2 * * *
syswrapper.sh refresh-walled-garden 1  cron, */10 * * * *
syswrapper.sh schedule-action          cron, 1-59/5 * * * *
/usr/bin/syswrapper.sh %s              over SSH: "set-adopt <url> <key> [mac]"
/usr/bin/syswrapper.sh unpair          over SSH
.../syswrapper.sh upgrade %s, upgrade2 over SSH, firmware download
```

The four cron jobs are emitted together by one method (`com/ubnt/service/config/`
`lwueNrOWUBYJX`, called from the AP config generator `VAZShipWTNxlo:2426`), each behind
its own gate, decompiled:

| Job | Gate as decompiled |
|---|---|
| `schedule-action` | any WLAN with `isScheduleEnabled()` |
| `refresh-walled-garden 1` | the guest-portal condition **and** `!device.supportIPSet()` |
| `dfs-reset` | the site's country resolves to a regdomain with DFS channels, **and** some radio with `radio == "na"` and `has_fccdfs` (country 840/124) or `has_dfs` (everyone else) has a `channel` that is not `auto` and is in that DFS list |
| `11k-scan` | any WLAN with `fast_roaming_enabled` |

So `dfs-reset` is pushed to a device **only because openUF reports `has_dfs` honestly**
off `iw phy` — the field added for the Radios tab's capability filters turns out to gate
this job too. Confirmed live, not inferred: the office AP (5 GHz pinned to channel 100,
country CZ) was being pushed the job and openUF was declining it by name —
`sysconf: cron job not installed -- not a command this build provides:
"syswrapper.sh dfs-reset"`, twice on 2026-10-27 — while the living-room AP (channel 36,
non-DFS) is pushed only `11k-scan`, which is the gate working exactly as decompiled.

#### `dfs-reset`: what the firmware does with it

`bin/syswrapper.sh` → `dfs_reset()` (firmware-confirmed for U7LR 6.8.2; `dfs_reset_mtk`
is the same logic through a different `iwconfig` field):

1. `is_wds` → "Downlink AP doesn't neet to do dfs reset action", return.
2. For each 5 GHz radio's first VAP (`list_first_vaps_ifs 5`) in `Mode:Master`.
3. Actual channel from `iwlist <if> frequency | grep Current`; configured channel from
   `radio.<n>.channel` in `/tmp/running.cfg` — the pushed `system.cfg` itself.
4. `-z`, `auto` or `0` → skip. Equal → skip.
5. `radartool -i <radio> chknol <ch>` = `true` → log "dfs <ch> still in nol_channel,
   wait next time" and skip.
6. Otherwise `iwconfig <if> channel <ch>`, logging `OK` or `FAIL(<rc>)`.

openUF's equivalent, verb for verb: the live channel from `iw dev <if> info`
(`sysinfo.radio_caps`), the configured one from `wireless.<radio>.channel`, the NOL from
mac80211's own per-channel state (`iw phy phyN channels` → `DFS state: unavailable (for
N sec)`, parsed by `rrmscan.parse_dfs_states`), and the move as a CSA on the BSS control
socket (`hostapd_cli chan_switch 5 <freq> sec_channel_offset=± center_freq1=<c>
bandwidth=<w> ht|vht`, built by `rrmscan.chan_switch_args` from the live width) instead
of a driver-level channel set. `is_wds` has no analogue: openUF does no wireless uplink.

Two things worth keeping:

- **The bonded-block centres are not evenly spaced.** UNII-3 starts at 149, which is not
  `36 + 16k`, so an anchor-on-36 formula gives the 149-161 block a centre of channel 154
  instead of 155 — a `center_freq1` hostapd accepts and then beacons a 5 MHz-shifted
  operation element with. `rrmscan.BLOCK_CENTERS` is therefore a table of the real
  centres (40 MHz: 38…159, 80 MHz: 42…155, 160 MHz: 50/114/163), and a channel belongs
  to the block whose centre is within `width/10 - 2` channels.
- **`iw phy … channels` is the only place the NOL is visible.** Verified on both boards
  2026-10-27: each radio's own 80 MHz block reads `available` (CAC done) and every other
  DFS channel `usable`, on ath10k and mt76 alike; non-DFS channels have no DFS state
  line at all, which is why `channel_in_nol` treats an absent entry as "not blocked"
  rather than as usable. `logread` never shows the NOL; nor does `hostapd_cli status`.

Not claimed: no live radar hit, so the CSA itself has never run in anger. What was
checked on hardware is everything up to it — the state read, the generated arguments
against what the live hostapd reports for its own channel, and the job doing nothing
while both radios are where they belong.

### The 5 GHz Country IE regression, and the radar event (jonasevcik f6dd839, 2026-10-27)

**Reproduced independently in this project's VM lab, 2026-10-29**, before this fix was
ported: with `36e830d` alone, setting `country_beacon` to false on a WLAN through the
controller's API wrote `ieee80211d='0'` on both radios, and at the reload the 5 GHz radio
stayed down with `Cannot enable IEEE 802.11h without IEEE 802.11d enabled` /
`hostapd.add_iface failed`, the 2.4 GHz radio unaffected. The same WLAN with the field unset
had provisioned cleanly, which is why the first look found nothing.

**The fix, in the same lab.** With `f6dd839` on both APs and the WLAN still asking for the
Country IE off, the next push brought the 5 GHz radio back on its own: `radio1.ieee80211d='1'`
beside `ieee80211h=1` in the live config, `radio0` (2.4 GHz) honouring `'0'`, every SSID up,
and the log line `Country IE off is not applicable on 5 GHz` once per radio.

**The radar event, end to end, 2026-10-29.** The AP's 5 GHz radio pinned to channel 100 at
80 MHz through the controller, the site's country set to the US for the run: CAC completed in
60 s, then `dfs_simulate_radar` on the simulated radio. hostapd logged `DFS-RADAR-DETECTED
freq=5500` on two BSS sockets and moved to channel 36; openUF logged one `DFS radar detected on
channel 100 (5500 MHz) on phy1-ap0 -- reported to the controller`; and the controller's own
system log (`POST /v2/api/site/<site>/system-log/all`) holds an `AP_DETECTED_RADAR_V2` entry for
that AP with `CHANNEL` 100. That is the row jonasevcik's lab could not see.

**Under India's regulatory domain no CAC can start at all.** With the site's country India,
the same channel gave `DFS start_dfs_cac() failed, -1` and the radio stayed down. wireless-regdb
lists `country IN: DFS-UNSET` (radar channels 52–144, but no DFS region), and the kernel's
`nl80211_start_radar_detection` returns `-EINVAL` when `reg_get_dfs_region()` is
`NL80211_DFS_UNSET` (net/wireless/nl80211.c, 6.12). So on any OpenWrt AP set to India, DFS
channels cannot be used whatever the driver. ⚠️ The JioRouter profiles blame the same log line
on the MT7986 driver; that was measured under IN, so it may be the regulatory domain instead.
To confirm on the hardware: `iw reg get` on the AP, and the CAC under a country with a DFS region.

Their evidence follows, as they wrote it.

**`ieee80211d='0'` on a 5 GHz radio is a production outage. Corrected 2026-10-27.**
About an hour after the provision above, an ordinary controller push rebuilt the wifi config
on both APs and the 5 GHz radio did not come back on either board:

```
hostapd.add_iface failed for phy phy0 ifname=phy0-ap0      # Archer C5, ath10k, ch 36
hostapd.add_iface failed for phy phy1 ifname=phy1-ap0      # AX3000T, mt76, ch 100
```

Feeding the device's own `/var/run/hostapd-phy0.conf` to a real hostapd (v2.12-devel, in
`openwrt/rootfs:x86-64-25.12.0`) names the cause in one line:

```
Cannot enable IEEE 802.11h without IEEE 802.11d enabled
1 errors found in configuration file
```

`hostapd.uc`'s `device_country_append()` emits `ieee80211h` for **every** radio with
`hw_mode == 'a'` and a country (it is deleted only for `hw_mode != 'a'`, and the schema
defaults it to `true`), while `ieee80211d` is emitted only when truthy. So `ieee80211d=0`
plus 5 GHz is a config hostapd rejects outright — not a dropped option but a refused
interface, with no SSID on the air and nothing in UCI to explain it.

Three things worth carrying forward:

- **The gate check has to include the consumer's cross-constraints, not just the option.**
  The original reasoning checked that `ieee80211d` exists in the schema and that the
  generator emits it — both true. hostapd's rule relating it to another option was the gap.
- **The failure is delayed.** It appears at the next `wifi reload`, not at the push that
  writes the option, so reading UCI and `hostapd-phy*.conf` straight after the provision —
  which is exactly what the table above records — showed a clean, consistent, wrong state.
  For anything that can keep an interface from starting, the check is `iw dev` showing an
  SSID and a channel, not the config file.
- **Unknown band counts as 5 GHz.** `band_for_device` falls back to `band_for_channel`,
  which answers `"na"` when it cannot tell. That default is now load-bearing: guessing
  "2.4 GHz" costs a radio.

openUF now writes `ieee80211d='1'` on any 5 GHz radio regardless of `country_beacon`
(repairing a radio an earlier version left at `0`), honours the controller's "off" on 2.4 GHz
only, and logs `Country IE off is not applicable on 5 GHz` once. Verified on the AX3000T
through a real force-provision: the warning fired, `wireless.radio1.ieee80211d='1'`,
`hostapd-phy1.conf` carries `ieee80211d=1` beside `ieee80211h=1`, and `phy1-ap0` is back on
**channel 100 at 80 MHz** — a DFS channel, which is precisely the case 802.11h exists for.

#### Device events (their Axis 3), settled 2026-10-27

The controller side was read first, as the paragraph above said it had to be: every `.class`
in 10.6.106's `internal-dependencies.jar` was extracted and searched for each key. Method,
so it is repeatable: `unzip` the jar, `tr -c '[:print:]' '\n'` over every class, intersect the
token set with the key names `libubnt.so.1.0.0` carries.

**Nine of the eleven per-station keys appear nowhere in the controller.** `sta_ip_timeout`,
`sta_arp_timeout`, `sta_dns_timeout`, `sta_dns_latency`, `sta_icmp_rtt`, `sta_disconnects`,
`wifi_drops`, `tx_rate_avg` and `rx_rate_avg` have zero hits in the jar — so sending them
would change nothing. Declined: **no consumer in 10.6.106**. (The same search explains a
standing oddity: `wifi_retries` and `wifi_latency`, which openUF *does* send, are not in the
jar either. They are satisfaction inputs the AP consumes itself, and the controller reads only
the resulting score and the bar charts.)

The two the controller does read are `rx_tcp_lat_avg` and `tx_tcp_lat_avg`, in
`com.ubnt.service.e.a.a.e.rGUtaVWZlySeOK` — the `stat.vap` archiver, which takes them as
`avgRxTcpRtt`/`avgTxTcpRtt` beside `client_signal_avg` and `num_sta_avg`. Declined:
**no OpenWrt producer**. They are per-station TCP round-trip averages, which the firmware
gets from mcad's own sampling of client traffic; openUF measures no TCP timing at all, and
`satisfaction.score` accordingly passes a constant 100 for both the TCP-loss and TCP-latency
terms. Implementing them means building a passive TCP RTT sampler first, which is its own
piece of work and not a reporting gap.

The same archiver class names the per-VAP sums the controller builds from the per-station
keys, which is worth writing down because the names differ on the two sides:
`sta_arp_timeout` → `sta_arp_failures`, `sta_dns_timeout` → `sta_dns_failures`,
`sta_ip_timeout` → `sta_dhcp_failures` (DHCP, not IP), plus `sta_wpa_auth_failures`,
`rx_tcp_stalls`/`tx_tcp_stalls`, `wifi_tx_latency_avg`, `sta_tx_rate`,
`ratio_sta_high_ux_avg`/`ratio_sta_low_ux_avg`. The `*_failures` names are the controller's
own; 6.8.2 never emits them, so a future attempt must send the per-station key, not the sum.

**The win on this axis was not in the station table but in the events.** openUF sent no
device event of any kind. 10.6.106 has handlers for eleven `EVT_AP_*` strings
(`AcsTriggerComplete`, `AfcEvent`, `ChannelChanged`, `DetectRogueAP`, `Isolated`,
`LocationEvent`, `PossibleInterference`, `QuickScanEvent`, `RadarDetected`,
`RestartedUnknown`, `RestartProc`), and U7LR 6.8.2's whole rootfs contains exactly three:
`EVT_AP_RadarDetected`, `EVT_AP_WirelessEvent` and `EVT_AP_Notification`, all in
`sbin/ubntbox`. The intersection is one event — `EVT_AP_RadarDetected` — and it is
implemented (see "DFS radar detection" below). The other eight controller-side strings are
declined as **not device-sent**: the controller raises them itself from what it already has.
`EVT_AP_WirelessEvent`/`EVT_AP_Notification` are declined the other way round: **no handler
in 10.6.106**.

Two further declines from the same sweep, both with the condition read out of the jar:

- `commit_errors` — the device reporting a failed config apply, which would be a genuinely
  useful thing for openUF to send. `com.ubnt.service.devmgr.l.AqxpICcpcuIxnda` reads it only
  under `hyFnQ2.hasFeature(GATEWAY)`, and an AP identity never has that feature. Declined:
  **gateway-only path**.
- `ethernet_table` / `antenna_table` / `hw_caps` / `fw3_caps` / `sys_error_caps` — all absent
  or zero in openUF's payload. `ethernet_table` is a controller-side setter
  (`setEthernetTable`, consumed by "Trusted Port: resolveWiredMacs") that 6.8.2 never emits;
  `hw_caps`'s bits are screen (1), LED colour (2), LCM (8), RPS (16), boot sound (32), smart
  outlet (128), accelerometer (512), LED brightness (0x4000) and the compatible-PoE mask
  (0x3800) — none of which an OpenWrt AP presenting as a U6-IW has. Declined: **nothing true
  to claim**.

#### DFS radar detection: `EVT_AP_RadarDetected`

The wire contract, read from the handler rather than inferred —
`com.ubnt.service.devmgr.e.c.Cuhf`, whose `kCNoUwYXLXMAUl(long, device, doc)` is:

```java
if (!doc.containsAllFields(new String[]{"channel", "freq"})) return false;
String channel = doc.getString("channel");
int freq = doc.getInt("freq");
... alert(..., "ap", dev.getMAC(), "ap_name", dev.getName(),
          "radar_channel", channel, "freq", freq)
```

So: the envelope is the ordinary notif inform (`inform_as_notif`, `notif_reason = "event"`),
the payload needs `event_string`, `channel` **as a string** and `freq` **as a number**, and
returning false lands in the dispatcher's `debug("Event without handler, payload: {}")`.
`event_defs.json` carries the rest: subsystem `wlan`, `event_enabled: true`, message
`"{ap} detected radar on channel {radar_channel} ({freq} MHz)"`, `is_negative: false`.
6.8.2's own payload is the same three fields plus `vap`, from the string pool around
`EVT_AP_RadarDetected` in `sbin/ubntbox`: `"DFS: Radar detected on channel %u (freq %u)"`,
`event_string`, `mca-custom-alert`, `freq`, `vap`. openUF sends `vap` too.

Device side: hostapd prints `DFS-RADAR-DETECTED freq=5500 ht_enabled=0 chan_offset=0
chan_width=1 cf1=5530 cf2=0` on the BSS control socket. `freq` is where the radar was and
`cf1` the BSS's centre frequency — on an 80 MHz channel they are different channels (5500 is
100, 5530 is 106), so the channel is derived from `freq`. A line whose `freq` is unusable is
dropped rather than reported with a guessed channel, since the handler needs both fields.

**Lab, 10.6.106, 2026-10-27.** `debug.device=debug` in `system.properties` (restart required)
puts the dispatcher's own decision in `server.log`, which makes this testable without a radio:

| sent | `server.log` |
|---|---|
| `{event_string: EVT_AP_RadarDetected, channel: "100", freq: 5500, vap: "phy1-ap0"}` | `notif inform` … `Inform finished`, **no** "Event without handler" |
| the same with `channel` removed | `Event without handler, payload: {"event_string":"EVT_AP_RadarDetected","freq":5500}` |
| `{event_string: EVT_AP_NoSuchEventOpenUF, channel: "100", freq: 5500}` | `Event without handler, payload: {…}` |

The two negative controls are what make the first row evidence: the dispatcher is reached, it
logs its refusals at the level that was enabled, and it refused exactly the payloads it should.

What the lab **cannot** show: the stored event. 10.6.106 keeps no documents in Mongo's
`event` or `alarm` collections (both are empty even for adoption on a 10-day-old lab site),
and `GET`/`POST /api/s/default/stat/event` is gone — 404 on this build. The jar carries
`com/ubnt/dao/logs/`, `schema/initial/script/logs-schema.sql` and `sqlite-jdbc`, so events
moved to a separate log store that this container does not provision. Handler acceptance is
proven; the UI row is not.

A notif inform with a *minimal* identity (mac/model/version only) is refused with HTTP 400.
The one-shot controls above had to repeat what `build_json` puts in `_notif_identity` —
serial, platform, hostname, ip, inform_url, cfgversion, required_version, state, uptime.
Worth knowing before writing another notif test by hand.

### SAE tuning and station keys in this project's VM lab (2026-10-30)

A WPA3-only WLAN created over the controller's REST API with `sae_anti_clogging=7`,
`sae_sync=9`, `sae_groups=[19,20]` and one `sae_psk` entry bound to the client's MAC. On the AP:
`encryption='sae'`, the raw lines `sae_anti_clogging_threshold=7` and `sae_sync=9` in live
hostapd beside `ieee80211w=2`, a `wifi-station` for the bound MAC and a `.sae` password file
holding `<key>|mac=<that MAC>`. The client joined with the **station key** (not the WLAN
passphrase): `AP-STA-CONNECTED ... auth_alg=sae`, 4-way handshake completed, a lease, traffic.

**Correction to jonasevcik's "`sae_groups` is a wifi-iface option".** On OpenWrt 25.12.6 it is not
in `/usr/share/schema/wireless.wifi-iface.json` (the SAE options there are `sae_pwe`,
`sae_require_mfp`, `sae_password_file`, `sae_track_password`, `sae_ext_key`), so netifd drops a UCI
`sae_groups` and `ap.uc`'s `set_default(config, 'sae_groups', '19 20 21')` goes out: the lab's
first push produced `sae_groups=19 20 21` with UCI saying `19 20`. Fixed in `22a9af5`: it now
rides `hostapd_bss_options`, which the generator appends after its own lines, and the live
config reads `sae_groups=19 20 21` then `sae_groups=19 20` (hostapd keeps the last).

### The feature table in this project's VM lab (2026-10-31)

Two openUF APs (QEMU, `mac80211_hwsim` radios sharing the air through a relay) and one plain
OpenWrt client, adopted by UniFi Network 10.6.106 in Docker, on the `jonas-merge` tip `1882b57`.
Every row was switched on through the controller's REST API, checked on the AP (UCI, live
hostapd, `logread`, `tc`/`nft`) and from the client, then put back. 19 PASS, 0 FAIL, 1 N/A.
A fresh flash with `wpad-basic-mbedtls` passed first: `install.sh` swapped in `wpad-mbedtls` in
one apk transaction, with the basic hostapd on the air through the ~25 s fetch.

| # | Feature | Result | What was seen |
|---|---|---|---|
| 1 | Adoption + inform (GCM) | PASS | both APs Connected, `x_aes_gcm=true`; a CBC inform is rejected, so GCM is what runs |
| 2 | WPA2 WLAN on both bands | PASS | the client joined on 5 GHz, got a lease, pinged over the Wi-Fi leg |
| 3 | Writes per push | PASS | 4 commits per push on vm1 and vm2 (a LabTest U-APSD toggle, on and back off). The run first counted 5: the 4 measured in `b145dd0` plus `backhaul_apply`'s own commit. Since `4e3b899` the backhaul sections are staged on the VAP loop's cursor and land in its commit; mesh failover and the downlink BSS re-checked after |
| 4 | Multicast Suppression | PASS | off 2500/2500 probes through, conservative 549 (100/s limit), aggressive 0, with ARP/ND/DHCP still passing in every mode |
| 5 | Per-BSS keys | PASS | `rsn_pairwise=GCMP` and `tdls_prohibit=1` on that BSS only; the client joined with pairwise GCMP |
| 6 | DFS Country IE + radar | PASS | site US, ch 100/80: CAC done, simulated radar moved the radio to ch 149, one `AP_DETECTED_RADAR_V2` in the controller's log |
| 7 | Nightly dfs-reset | PASS | the cron line arrives with the push; a manual run right after radar waits out the non-occupancy period |
| 8 | Auto-channel blacklist | PASS | 2.4 GHz `chanlist=1 6 11` from the site, `acs_exclude_dfs=1` on 5 GHz; the dfs-reset line leaves with the pinned channel |
| 9 | WPA-Enterprise (PEAP) | PASS | PEAP/MSCHAPv2 against the lab FreeRADIUS: Access-Accept, lease, traffic |
| 10 | RADIUS MAC auth + DAS | PASS | `macaddr_acl=2`, the client's MAC accepted; a Disconnect-Request got Disconnect-ACK and kicked it, a wrong secret was dropped. DAS needs an accounting server on the profile (`das.client` is the first one) |
| 11 | Passpoint | PASS | `[HS20]` in the beacon; ANQP answered capability list, venue name, roaming consortium and NAI realm as configured |
| 12 | Walled garden + portal | PASS | over Wi-Fi the garden hosts answer, a restricted subnet is dropped, other HTTP gets 302 to the controller's `/guest/s/default/` |
| 13 | SAE tuning + station key | PASS | joined with the MAC-bound key (SAE, group 19, PMF required); the WLAN passphrase is refused for that MAC, as it should be |
| 14 | Discovery reply | PASS | a v1 probe on UDP 10001 got a 15-TLV answer from each AP |
| 15 | Plugins | PASS | a sample plugin in `/etc/openuf/plugins/` + `plugins.enabled` set an option on both bands; removed, the next push dropped it |
| 16 | Mesh failover | PASS | guest carrier cut: the WDS station came up in ~10 s, the AP kept informing through its peer; carrier back, station off |
| 17 | Uplink monitor | PASS | wire and mesh both cut: the 4 user BSSes went off within one heartbeat (no route at all skips the 5-check count), the mesh BSS stayed; back within 20 s of the link |
| 18 | 802.11r | PASS | 6 roams in both directions, each `auth_alg=ft` with no 4-way handshake after the first join |
| 19 | Speed limit, schedule, blocker, band steering, min RSSI, load balance | PASS | `tc` HTB 2 Mbit on every VAP; schedule took the WLAN's BSSes down and back; `block-sta` kicked and refused the client; `usteerd` started and stopped; `rssi_reject_assoc_rssi=-72` for -75 (the firmware's +3 dB); `loadbalance_maxsta=5`. All cleared on reset |
| 20 | MAC-based VLANs | N/A | needs a UniFi OS gateway; see the hardware run below |

Lab notes from the run, none of them openUF bugs: the lab's `cable` command downs only the
host tap, so a carrier cut needs QEMU's `set_link`; the client's wired leg must be bypassed
(`ping -I`) for the guest rows; `wpa_cli roam` answers FAIL once the target's scan entry has
aged out; a device `radio_table` PUT merges per radio, so a key is cleared by sending `false`,
not by leaving it out. Open questions it left: the controller labels a meshed uplink as type
"wire" when the site has no mesh uplink in the push, and the BSS carries the default
`sae_groups` line before the controller's (above).

### WPA3 station keys: `aaa.<n>.sae.psk.*` (jonasevcik 8d0f5ed, 2026-10-26)

Their feature-matrix row:

| 28 | SAE station keys | `aaa.<n>.sae.psk.<k>.{psk,mac,vlan,id}` | ✅ Wire → UCI → hostapd confirmed 2026-10-26 on both APs, all radios (temp WPA3-only WLAN, REST `sae_psk` with an any-station key, a key bound to a MAC, a VLAN-10 key): `wifi-station` sections with the right `mac`/`vid`, hostapd `.sae` lines `<key>\|mac=<mac>[\|vlanid=10]`, `phy*-ap*-10` netdevs bridged into `br-openuf10`, all removed again on delete. ⚠️ No client joined. Joins the `psk_file` private keys (deduped); the `ff:..` entry is skipped. |

### SAE tuning: anti-clogging, sync, groups (jonasevcik a64bcfc, 2026-10-26)

**In this tree** the two raw lines are appended with `add_bss_option`, beside any other raw
line on the WLAN (their first version assigned the list and would have dropped them).
Their feature-matrix row:

| 27 | SAE tuning | `aaa.<n>.sae.anti_clogging` / `.sae.sync` / `.sae.has_groups` + `.sae.groups.<k>.group` | ✅ Hardware-confirmed 2026-10-26. Firmware 6.8.2 `ubntbox` writes `sae_anti_clogging_threshold=%d`, `sae_sync=%d`, `sae_groups=` (absent from 4.0.15, so the old "cannot be applied" verdict rested on the schema alone). They are no wifi-iface option; the per-BSS raw-line list is `hostapd_bss_options` (`ap.uc:612`), while `hostapd_options` is radio-level (`hostapd.uc:548`) and is silently ignored: a first attempt with it left hostapd without the lines. Temp WPA3-only WLAN (REST `sae_anti_clogging=7`, `sae_sync=9`) → both lines in every BSS on both APs; home WPA2/WPA3 WLAN got 5/5. Sent only for `sae`/`sae-mixed`. |

### Per-BSS keys: OKC, TDLS, Country IE, pairwise cipher (jonasevcik 36e830d, 2026-10-26)

**In this tree** `auth_cache` → `okc` is parsed but never applied: the controller sends it only
on a WPA-Enterprise WLAN, which this tree does not provision until that port. Their evidence
follows, as they wrote it.

| key | meaning and mapping |
|---|---|
| `auth_cache` | Opportunistic key caching, from the wlanconf's `auth_cache` — `is("auth_cache", true)`, so **default enabled**. REST-only; the 10.6 UI has no control. Emitted **only in the generator branch that also writes `wpa.key.1.mgmt` + `wpa.psk`**, and only ever observed on a WPA-Enterprise WLAN: a WPA2-PSK WLAN's `aaa` block carries no `auth_cache` at all, consistent with OKC being an 802.1X notion. Lab-confirmed 2026-10-26 against 10.6.106: flipping the field flipped `enabled`/`disabled` on both band entries. → OpenWrt `okc` (schema-confirmed on 25.12; `ap.uc`'s own default is on for sae/owe and for FT). |
| `tdls_prohibit` | Forbid direct station-to-station (TDLS) links, from the wlanconf's `tdls_prohibit` (REST-only), default disabled, on **every** `aaa` block. Lab-confirmed 2026-10-26 the same way. → OpenWrt `tdls_prohibit`, 1:1 (schema-confirmed on 25.12). |
| `country_beacon` | Advertise the regulatory domain in beacons (the 802.11d Country IE), from the wlanconf's `country_beacon` — `is("country_beacon", false)`, REST-only, on every `aaa` block. Lab-confirmed 2026-10-26 the same way. OpenWrt's counterpart `ieee80211d` is a **wifi-device** option, so openUF collapses the per-BSS key to one setting per radio: *any* WLAN on the radio asking for it turns it on. The element is an advertisement, not a restriction, so the permissive fold costs the other WLANs nothing. No guard on a country being configured is needed — `hostapd.uc`'s `device_country_append()` returns before emitting `ieee80211d` when no radio declares a country, so the option cannot reach hostapd unaccompanied (hostapd itself treats it as fatal). |
| `wpa.1.pairwise` | The pairwise cipher the controller chose, from the wlanconf's `wpa_enc` through `com.ubnt.i.b.aL.kYktyHCkPVCBdJC`: the enum is `{auto, ccmp, gcmp, ccmp-256, gcmp-256}`, `auto` becomes `CCMP` (or `TKIP CCMP` on a WPA1 WLAN) and every other value is the name upper-cased. Lab-confirmed 2026-10-26: `ccmp`, `ccmp-256` and `gcmp` all reach the wire; **`gcmp-256` is refused by the controller's own validator** and normalised back to `auto`, on both a PSK and an EAP WLAN. → the second `+` token of OpenWrt's `encryption` (`psk2+gcmp`), which is where `iface.uc` reads a cipher from. `CCMP` deliberately writes nothing: it is `iface.uc`'s own final default, so a suffix for it would change nothing and mask a genuine default. `TKIP CCMP` is declined — it appears only on a WPA1 WLAN, openUF maps no security value to WPA1, and TKIP is forbidden by WPA2 and WPA3 certification. **Gated on the radio's cipher suites** — see below. |

**A pairwise cipher must be gated on the radio, not on the band or the board.**
`iw` 6.17 on 25.12 prints no Supported Ciphers block at all, so openUF reads the suites
from nl80211 directly (`ucode -l nl80211`, `NL80211_CMD_GET_WIPHY` → `cipher_suites`,
IEEE 802.11 Table 12-4's `0x000FAC<n>`). Read on hardware 2026-10-26:

| Board | 2.4 GHz phy | 5 GHz phy |
|---|---|---|
| Archer C5 v1 (ath9k + ath10k) | CCMP, CCMP-256, GCMP, GCMP-256 | **CCMP only** |
| Xiaomi AX3000T (mt76) | CCMP, CCMP-256, GCMP, GCMP-256 | CCMP, CCMP-256, GCMP, GCMP-256 |

The Archer C5 is the case that matters and is not what anyone would guess: its *older*
ath9k 2.4 GHz radio has GCMP and its newer ath10k 5 GHz radio does not. hostapd treats a
pairwise cipher the driver cannot program as fatal, so writing `psk2+gcmp` on that 5 GHz
BSS takes the WLAN off the air entirely — strictly worse than running the default CCMP.
openUF therefore keeps the default and logs the refusal. Where two radios serve one band
the band's set is the **intersection**: a WLAN there can land on either radio. An unknown
or failed probe is treated as unknown and never vetoes, like every other clamp.

**Confirmed end to end on the production APs, 2026-10-27.** A `force-provision` through the
real UCG Ultra (10.6, `POST cmd/devmgr` from the logged-in UI session) put the new keys into
real UCI and through the live generator on **both** boards — the one thing the Docker lab
cannot show, since it has no radios, no hostapd and no `uci`:

| Read back | Archer C5 (ath79) | AX3000T (filogic/DSA) |
|---|---|---|
| `wireless.<vap>.tdls_prohibit` | `'0'` on all 3 WLANs | `'0'` on all 3 WLANs |
| `wireless.radio{0,1}.ieee80211d` | `'0'` | `'0'` |
| `/var/run/hostapd-phy*.conf` | `tdls_prohibit=0` in every BSS block | same |
| hostapd config errors in `logread` | 0 | 0 |

So both options survive netifd's schema gate and reach hostapd: this is the live proof that
the step-1 options are not among the "stored and silently dropped" class. Two caveats, stated
plainly. `country_beacon` is `disabled` site-wide here, so `ieee80211d='0'` is the only value
proven on hardware; and `hostapd-phy*.conf` carries `okc=1`/`okc=0` lines that openUF did
**not** write — `uci show wireless` has no `okc` at all, so those are the 25.12 generator's own
defaults. Neither AP runs a WPA-Enterprise WLAN, so the `auth_cache` → `okc` path stays
lab-only. The push also carried `wpa.1.pairwise=CCMP`, and openUF correctly wrote no suffix:
hostapd kept `wpa_pairwise=CCMP`.

**Three keys on this block are declines, each for a named reason** (10.6.106 generator
`com.ubnt.service.config.VAZShipWTNxlo`, read 2026-10-26):

- `wireless.<n>.wmm` — a hardcoded `"enabled"` **string literal** in the generator's
  62-element `wireless.<n>` array, not read from the wlanconf at all. A constant is a
  decoy by definition. OpenWrt has no `wmm_enabled` in `wireless.wifi-iface.json` either,
  and hostapd defaults it on for any HT/VHT/HE BSS.
- `aaa.<n>.eapol_version` — derived, not configured: the generator writes
  `securityProtocol.eapolVersion()`, which is `1` for `wpa_mode=wpa1` and `2` for
  everything else. openUF maps no controller security value to WPA1, so the only value it
  can ever receive is `2`, which is hostapd's own default.
- `aaa.<n>.p2p` and `aaa.<n>.p2p_cross_connect` — genuine settings (wlanconf `p2p` /
  `p2p_cross_connect`, default disabled, **lab-confirmed 2026-10-26 to flip on the wire**),
  but there is no consumer: hostapd's `manage_p2p` / `allow_cross_connection` are absent
  from the OpenWrt 25.12 binary (`grep` over `/usr/sbin/hostapd` on both boards finds
  neither string — built without `CONFIG_P2P_MANAGER`), and absent from the netifd schema.
  Writing them as raw BSS lines would make hostapd reject its own config file. Revisit only
  if an OpenWrt release ships the P2P manager.

### MAC-based VLANs (jonasevcik 1f017d1, 2026-10-27)

**In this tree** `fw_caps` is `0x1110` with the sign bit, sent as `-2147479280`: jonasevcik's
`0x100000` (RADIUS Dynamic Authorization) and `0x800000` (Hotspot 2.0) are not claimed here
until those features are ported. The RADIUS MAC authentication refusal below is in the code,
but this tree has no RADIUS MAC authentication yet. This project's own lab controller has no
gateway either, so it cannot emit these keys; the feature is unit-tested here only.

Their evidence follows, as they wrote it.


Not RADIUS at all, though the sweep's axis-2 table had filed it next to MAC auth. It is the
controller's per-CLIENT **"Virtual Network Override"**: a client set to another network lands
on that network's VLAN whatever SSID it joins. The emitter
(`com/ubnt/service/config/ubntconf/fdwW`) reads every `user` object carrying
`virtual_network_override_enabled`, groups them by `virtual_network_override_id`, and writes
the whole site's map to EVERY WLAN index:

```
aaa.<n>.accept_mac.status=enabled       (once, before the first entry)
aaa.<n>.accept_mac.<k>.mac              aaa.<n>.accept_mac.<k>.vlanid
switch.vnet.<n>.{name,vlan,mac.<k>}     (the same map for a switch identity)
```

`status` is **not** the discriminator and openUF does not read it: the writer emits it from
inside the loop that writes the first entry, so it is present exactly when entries are. The
entries are the whole signal — the block's presence says nothing, which is this protocol's
usual shape.

**Two gates, the second site-wide.** `hyFnQ2.supportsMacBasedVlans()` =
`hasFirmwareCapability(Integer.MIN_VALUE)` = `fw_caps` `0x80000000`, claimed since
2026-10-27. Beside it `com/ubnt/service/bz/bWpcUrDmeyjdNnrWeZ.kCNoUwYXLXMAUl(siteId)`
requires BOTH of:

- a device that `isUbios()` and either claims the bit or is one of **23 listed gateway
  models** (`UDMPRO`, `UDMPROMAX`, `UXG`, `UDMPROSE`, `UDW`, `UDM`, `UDR`, `UDRULT`,
  `UDMA67A`, `UDMA6B7`, `UDMA6B9`, `UCGMAX`, `UXGB`, `UDMENT`, `UXGENT`, `UXGA6AA`,
  `UDMA6A8`, `UX`, `UDMA69B`, `UDMA6B4`, `UDMEA39`, `UDMEA4B`, `UDMA6AD`);
- an EMPTY set difference between {devices with the `ACCESS_POINT` or `SWITCH` feature and
  `HAS_CLIENTS`, minus 11 excluded switch models} and {devices claiming the bit}.

So one AP without the bit switched the feature off for every client in the site — which is
where openUF stood. The home gateway is model `UDRULT`: in the list, and it already claims
the bit (`fw_caps` read live from the controller's own device record, 2026-10-27). With both
APs now claiming it, the quorum is satisfied here.

**The consumer is hostapd's accept-MAC list**, whose lines take an optional VLAN id after
the address. Read out of hostapd v2.12-devel — the build both APs run:

- `hostapd/config_file.c:hostapd_config_read_maclist()` parses `<mac>[ \t]<vlan_id>` per
  line, `#` comments, a leading `-` removing an entry.
- `src/ap/ieee802_11_auth.c:hostapd_check_acl()` consults `accept_mac` **first, before
  `macaddr_acl` is looked at**, and a match returns `HOSTAPD_ACL_ACCEPT` carrying the VLAN.
  An unlisted station falls through to the `macaddr_acl` default. So an accept file on its
  own assigns VLANs without restricting access, which is exactly the feature.
  `hostapd_allowed_address()` keeps that VLAN for every mode but
  `USE_EXTERNAL_RADIUS_AUTH`, where `dynamic_vlan=0` clears it.
- `src/ap/ieee802_11.c:ieee802_11_set_radius_info()` then requires the VLAN to be in
  `conf->vlan` (`hostapd_vlan_valid`) or **refuses the station** — it does not fall back to
  the VAP's network. Hence a `wifi-vlan` section per VLAN, which `src/ap/vlan_init.c`
  confirms is created from `vlan_file` whatever `dynamic_vlan` says.

**Three ways in, because OpenWrt owns the same file for "MAC Address Filter"** (`ap.uc`'s
`iface_macfilter`, which also has a `macfile` option appending an arbitrary file to the one
it writes):

| WLAN's MAC Address Filter | How openUF's entries reach hostapd |
|---|---|
| none | a raw `accept_mac_file=` line to openUF's own file. No `macaddr_acl` is emitted, so hostapd's default (accept-unless-denied) still admits unlisted clients |
| `allow` | the schema's `macfile`, appended by `ap.uc` to the accept file it writes from `maclist` — and openUF drops those addresses from `maclist`, so each appears exactly once. An override the allow list does not permit is skipped: adding it would widen the admin's whitelist |
| `deny` | the raw line again, minus any address on the deny list — the accept list is checked first and would otherwise let a denied client in |

`vlan_no_bridge` (which keeps hostapd out of the bridge netifd already built) sits behind
`vlan_possible && dynamic_vlan` in `iface_vlan`. `ap.uc` sets `vlan_possible` itself for
every psk/sae/eap auth type, so `dynamic_vlan=1` suffices there; on an **open or OWE** WLAN
neither is ever set, so openUF emits `vlan_no_bridge=1` raw.

**Refused outright on a WLAN with RADIUS MAC authentication**: `macaddr_acl=2` asks the
server about every client, and an accept-list entry returns ACCEPT before the question is
asked. A VLAN override is not worth bypassing an access control.

**The file is written before anything points at it.** Verified against real hostapd: an
`accept_mac_file` naming a missing file gives `MAC list file … not found` →
`Failed to read accept_mac_file` → `1 errors found in configuration file` → `Failed to set
up interface`, and the same for one malformed line (`Invalid MAC address 'not-a-mac 20' at
line 2`). Either takes the WLAN off the air, so on a write failure openUF abandons the plan
and provisions the WLAN without the overrides.

**The leading newline in openUF's file is load-bearing, and not for the obvious reason.**
`ap.uc` writes `join('\n', maclist)` with no terminator, so in the `macfile` case openUF's
first byte lands on the end of the last allow-list address. That does **not** fail:
`hwaddr_aton()` reads exactly six octets and ignores the rest (`src/utils/common.c`), so the
joined line is read as that LAST address and the VLAN id is taken from after its first
space — the mapped client's. The allow-listed station would silently get the override and the
intended one no entry at all. Confirmed both ways against hostapd v2.12-devel: the joined
line draws no complaint, and the generator's real output with the newline is

```
00:00:5e:00:53:09\n# openUF: MAC-based VLANs.\n00:00:5e:00:53:01 20\n
```

**Lab, 2026-10-27.** The claim itself is validated: the lab controller accepted
`fw_caps = -2138042096` with the bit reading set in its own device record, device state 1,
`grep -c "handle_response failed"` = 0. The generated UCI was then run through **the device's
own ucode generator** (`openwrt/rootfs:x86-64-25.12.0` + `wifi-scripts`, `ap.generate()`
driven directly) in all three modes: the no-filter case produced `dynamic_vlan=1`,
`vlan_file`, `vlan_no_bridge=1` and openUF's raw `accept_mac_file=` with **no `macaddr_acl`**;
the allow case produced ap.uc's own `accept_mac_file` + `macaddr_acl=1` with openUF's content
appended cleanly; the open case produced openUF's raw `vlan_no_bridge=1` and nothing else.
Every one of those configs, and the generator's own output file, was parsed by a real hostapd
v2.12-devel with zero errors. `tools/cfg-coverage.lua` over a capture with the keys spliced
in reports all four `accept_mac.<k>.{mac,vlanid}` as **consumed** and `accept_mac.status` as
**inert**, which is the intended split.

**The lab controller CANNOT emit these keys** — the site gate needs a ubios gateway and the
lab has none. Tested rather than inferred: a corporate network on VLAN 20 was created there,
a Virtual Network Override set on a lab client, the AP force-provisioned — and the resulting
`system_cfg` holds a full `aaa.1.*` block with **zero** `accept_mac` keys. (Side finding: the
override network must be *corporate*; a `vlan-only` one is refused with
`api.err.NetworkAssignedAsVlanOverrideIsNotCorporate`.)

**Wire captured on the home controller, 2026-10-27** (UniFi Network on a UCG Ultra), with a
Virtual Network Override set on a placeholder client — a MAC no device has — onto the IoT
network, VLAN 10. Verbatim, and the same block arrived on **every** WLAN index, which is the
emitter writing the site's whole map per WLAN:

```
aaa.1.accept_mac.status=enabled      aaa.2.accept_mac.status=enabled
aaa.1.accept_mac.1.mac=00:00:5e:00:53:01
aaa.1.accept_mac.1.vlanid=10         (and identically for aaa.2, aaa.3)
```

(The MAC above is the documentation placeholder that was actually used, not a mapped real
address.) This is the capture `tests/test_inform_packet.lua` replays.

**Hardware, 2026-10-27, both APs — end to end.** `fw_caps` reads `-2138042096`
(`0x80901110`) in the real controller's device record for both boards. With the override
live, each of the three WLANs on each AP got its own accept file
(`/etc/openuf/macvlan-openuf_<radio>_<ssid>`, holding the leading blank line, the comment and
`00:00:5e:00:53:01 10`), a `wifi-vlan` section into the existing `openuf_vlan10`, and in
**live hostapd**: `accept_mac_file=` pointing at that file, `vlan_file` carrying
`10 phyX-apY-10`, `dynamic_vlan=1`, `vlan_no_bridge=1`, and **no `macaddr_acl`** — so
unlisted clients still associate as before. Each VAP's VLAN netdev came up in
**`br-openuf10`**, the bridge netifd owns, and there is no `brvlan*` device on either board,
which is `vlan_no_bridge=1` doing its job. All three SSIDs stayed on the air on both boards
and `logread` shows no maclist, VLAN or hostapd error. Identical on the Archer C5
(ath79, ath10k + ath9k) and the AX3000T (filogic, mt76, DSA).

**Teardown confirmed in the same window.** The override was switched off and both APs
force-provisioned: every accept file is gone, no `dynamic_vlan`, no `_vlan10` section and no
`accept_mac` line survives on either board, the SAE raw lines on the same WLANs are
untouched (so the `hostapd_bss_options` append is intact), and all three SSIDs stayed up. The
placeholder client entry was then deleted and the site left with no overrides.

⚠️ **Not claimed:** no real client has been moved to a VLAN by MAC. The placeholder MAC
belongs to no device, so nothing authenticated against the accept list — the list's effect on
a real association is still unproven on hardware, though `hostapd_check_acl()` is read above
and the file hostapd loaded is the one openUF wrote.
