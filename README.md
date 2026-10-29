<p align="center">
  <img src="package/luci-theme-halo/htdocs/luci-static/halo/logo.svg" width="72" alt="">
</p>

<h1 align="center">openUF</h1>

<p align="center">
  <b>Run your OpenWrt access points from UniFi Network.</b><br>
  openUF makes an OpenWrt device look like a Ubiquiti access point to the UniFi controller:
  adopt it, push your WiFi networks to it, watch its clients, and mesh it with other openUF APs.
</p>

<p align="center">
  <a href="https://github.com/Fantastic792/openUF/actions/workflows/test.yml"><img src="https://github.com/Fantastic792/openUF/actions/workflows/test.yml/badge.svg" alt="Tests"></a>
  <a href="https://github.com/Fantastic792/openUF/releases"><img src="https://img.shields.io/github/v/release/Fantastic792/openUF?label=release" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg" alt="License: GPL-3.0-or-later"></a>
  <a href="https://www.lua.org/"><img src="https://img.shields.io/badge/Lua-5.1-blue.svg" alt="Lua 5.1"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#using-it-with-unifi-network">Guide</a> ·
  <a href="#tested-on-real-hardware">Tested</a> ·
  <a href="#known-issues">Known issues</a> ·
  <a href="#hardware">Hardware</a> ·
  <a href="#contributing">Contributing</a> ·
  <a href="#inherited-results-not-verified-here">Not yet verified</a>
</p>

---

This is an independent project, built on [yesrab/openUF](https://github.com/yesrab/openUF)
(see [Credits](#credits)). It has its own releases, its own fixes and its own testing. Only
what this project has tested itself is reported as tested below; the original project's
results are kept, clearly marked, under
[Inherited results, not verified here](#inherited-results-not-verified-here).

## See it

The device's own page, before and after the controller adopts it:

| Waiting to be adopted | Managed by UniFi Network |
|:---:|:---:|
| ![The device page before adoption: "Waiting to be adopted", the controller's address and the device facts](screenshots/device-page-ready-for-adoption.png) | ![The device page after adoption: "This device is managed by UniFi Network"](screenshots/device-page-managed-by-unifi.png) |

It shows up in UniFi Network as a U6 In-Wall and adopts with one click:

![UniFi Network's device list with an openUF access point ready to adopt](screenshots/unifi-devices-ready-to-adopt.png)

The few settings that stay on the device, behind the root password:

| Controller and hardware profile | Wireless, this page, service |
|:---:|:---:|
| ![Local Settings: inform URL, adoption state, hardware profile and the identity presented](screenshots/device-page-local-settings-top.png) | ![Local Settings: wireless options, the page switch, restarts](screenshots/device-page-local-settings-bottom.png) |

## What it does

- **Adoption like real hardware.** The AP announces itself on the LAN, appears in UniFi
  Network and WiFiman, and adopts with one click through the same locked-down `ubnt` login
  the controller expects. A controller on another subnet adopts it by inform URL instead.
- **WiFi from the controller.** WPA2, WPA3 and Enhanced Open, private pre-shared keys,
  per-network VLANs, hidden SSIDs, channel, width and power per radio, 802.11r/k/v, band
  steering, minimum RSSI, load balance, per-client speed limits, WiFi Blackout Schedules,
  the multicast and broadcast blocker, the access point's name in the beacon, client
  blocking and Locate.
- **Hotspot and uplink checks.** The controller's guest portal, and the Uplink Connectivity
  Monitor, which takes the WiFi networks off the air when the uplink stops answering.
- **Mesh.** A wireless uplink to another openUF AP when the cable is out, back to the cable
  when it returns, across several hops, with a loop guard.
- **Fast roaming.** 802.11r between openUF APs, and a translator for UniFi's own key
  exchange so phones can roam to and from genuine UniFi APs.
- **Live statistics.** Clients with WiFi Experience, radios and channel use, wired hosts per
  port, the uplink, neighbouring APs and RF scans.
- **A device page instead of LuCI's login**, with LuCI one step away, a dashboard, the Halo
  theme, and a Setup page that walks a new router through becoming an AP.
- **Pure Lua, no toolchain.** One command installs it on OpenWrt 24.10 or 25.12, as packages
  or as files, with upgrades in place.

openUF emulates an access point only: no gateway or switch emulation, by design.

## Install

One command on the device, over SSH:

```sh
wget -qO- https://raw.githubusercontent.com/Fantastic792/openUF/main/setup.sh | sh
```

The guided installer identifies the board, asks the few things it cannot know, and does
the rest in an order that never leaves the device unreachable:

1. **Interview.** Every question first. The default installs the `openuf` and
   `luci-app-openuf` packages from this project's latest release, plus the Halo theme where
   there is room; `--headless` installs the daemon alone.
2. **Access-point conversion.** The router role goes: no WAN, the WAN socket joins the LAN,
   DHCP server and firewall off. Everything is left installed and is one command to undo.
3. **Hardware profile**, **controller address** and the **adoption account**, which locks
   itself once the device is adopted.
4. **Dependencies**, including the full `wpad` build, then install and reboot.

Unattended, with every answer as an option (`sh setup.sh --help` lists them):

```sh
wget -qO- https://raw.githubusercontent.com/Fantastic792/openUF/main/setup.sh | sh -s -- \
    --yes --controller 10.0.0.5 --modelmap jiorouter-ax6000-jidu6j01 --no-reboot
```

The packages alone, from the [release page](https://github.com/Fantastic792/openUF/releases):

```sh
apk add --allow-untrusted ./openuf-<ver>.apk ./luci-app-openuf-<ver>.apk   # OpenWrt 25.12
opkg install ./openuf_<ver>_all.ipk ./luci-app-openuf_<ver>_all.ipk         # OpenWrt 24.10
openuf deps --install        # swaps a wpad-basic build for the full one
```

Upgrade with `openuf-update` on the device, or by installing the next release's packages.
Install the packages or the files, never both. The [usage guide](USAGE.md) covers every
option, the device page, upgrading, uninstalling and troubleshooting.

## Using it with UniFi Network

What this project learned running openUF against UniFi Network 10.6, in the order you meet
it.

**Adopting**
- On the same LAN the AP appears under Devices; click **Adopt**. On another subnet, point
  it at the controller first:
  `ssh root@<ap> 'syswrapper.sh set-inform http://<controller>:8080/inform'`
  (use your controller's inform port if you changed it from 8080). It then shows as
  *Pending*.
- After a **Forget**, wait for the AP to report in once before sending `set-inform` again;
  one sent too early is overwritten (see [Known issues](#known-issues)).
- **Name each device** in the controller. The name is what the beacon advertises; a device
  never named advertises `openUF`.

**WiFi settings**
- **Minimum RSSI** goes up to -67 dBm in the UI. openUF disconnects a client after 30 s
  below it and refuses it on that radio until it is 3 dB above.
- **Load balance** has no switch in Network 10.6's UI. It can be set through the
  controller's API on the device's `radio_table` (`loadbalance_enabled`, `maxsta`).
- **Multicast and broadcast blocker:** put your DHCP server's MAC on its exception list, or
  wireless clients get no address. That is Ubiquiti's own documented behaviour.
- **Band steering** comes from the network's toggle or the device's own setting (Off /
  Prefer 5G). Balance is not supported.
- **Airtime Fairness:** set it On for the device after adoption; the controller can hold an
  old Off and push it.
- **Per-port VLANs:** turn on **Port VLAN** in the device's settings first, then set a
  port's Native VLAN. On DSA boards (most WiFi 6 routers) only the native VLAN is applied.

**Mesh**
- Turn on **Wireless Meshing** for every AP that should take part. The wired AP then offers
  a hidden mesh network; an AP whose cable goes switches to it about 16 s later and is back
  on the controller within about 25 s, then returns to the cable within a second of it
  coming back. Since 0.1.5 a cabled AP keeps its mesh station even though the controller
  only sends it the mesh name and key.
- The Uplink Connectivity Monitor is on by default in new sites. An AP with no way out takes
  its SSIDs off the air after about 50 s, so clients move elsewhere.

**Checking an AP**
- `sh tools/selfcheck.sh` (from the source tree, copied over with `scp -O`) checks every
  feature the controller has turned on and prints OK, FAIL or SKIP for each.
- `logread | grep -E 'openuf|backhaul|uplinkmon'` shows what openUF did and why.

## Tested on real hardware

Two **JioRouter AX6000 JIDU6401** units on OpenWrt 25.12.6, managed by a self-hosted UniFi
Network 10.6.106 with no UniFi gateway, 2026-10-27 to 2026-10-29. One unit wired, the other
on a cable or the mesh. Clients: an iPhone, a Samsung Galaxy S22 and a wired PC. The full
record, in the [field-report format](field-reports/README.md), is
[field-reports/2026-10-29-jiorouter-jidu6401-fantastic792.toml](field-reports/2026-10-29-jiorouter-jidu6401-fantastic792.toml).

| Feature | Result |
|---|---|
| Install and upgrade | ✅ 0.1.0 to 0.1.3 with `apk`; the upgrade restarts openUF and the translator |
| Adoption | ✅ Found on the LAN and adopted; Forget and adopt again (see Known issues) |
| WPA3 (SAE) | ✅ Both phones; WPA3 kept after adoption |
| Enhanced Open (OWE) | ✅ A phone joined with OWE |
| Private pre-shared keys | ✅ Two phones, each on its key's VLAN, also after the SSID went off and on |
| Fast roaming between the two units | ✅ iPhone with FT-SAE, one lost ping per roam, both ways. The S22 does not use FT and roamed with a full reconnect (1.5 to 1.8 s) |
| Band steering | ✅ On: a phone on 2.4 GHz was asked to move to 5 GHz about a minute later and accepted. Off: no request in 3 minutes |
| Minimum RSSI | ✅ At -67 dBm a phone walking away was disconnected 44 s after falling below, and refused until it came back |
| Load balance | ✅ With a cap of 1, the more idle of two phones was disconnected 11 s after the second joined |
| Speed limit | ✅ 5 / 2 Mbps measured as 4.69 / 1.80 Mbps; 92 / 92 Mbps without |
| WiFi Blackout Schedule | ✅ Off and on within about 15 s of the times, mesh link untouched |
| Multicast and broadcast blocker | ✅ A host not on the exception list could not reach a phone; listed, it could; DHCP kept working |
| AP name in the beacon | ✅ The controller's device name in both units' beacons, no WPS prompt (unnamed devices: Known issues) |
| Locate | ✅ The LED blinked and stopped |
| Guest portal | ✅ Redirected to the hotspot page, let through once authorized |
| Uplink Connectivity Monitor | ✅ SSIDs off about 50 s after the uplink stopped answering, back about 5 s after |
| Mesh, one hop | ✅ Cable pulled: station on at 16 s, joined at 20 s, controller reached at 24 s. Back on the cable 1 s after it returned. No loop in any run |
| Mesh, cold boot without a cable | ✅ Came up on the mesh |
| Clock after a reboot | ✅ Booted 4 to 6 minutes slow; corrected within about 2 minutes |
| `selfcheck.sh` | ✅ No failures on either unit |
| Per-port VLANs | ⏳ Started: the port moves to its VLAN's bridge; client test not finished |

Also run in a virtual machine (OpenWrt 25.12.6, UniFi Network 10.6.106, 2026-10-27): every
feature above together, multi-hop mesh, and fast roaming between openUF APs through the
translator.

**Not run here yet:** fast roaming with a genuine UniFi AP, multi-hop mesh on hardware,
Airtime Fairness measured, OpenWrt 24.10, any other board, a UniFi gateway, and a run longer
than a few hours. The original project's results for some of these are
[below](#inherited-results-not-verified-here).

## Known issues

Found by this project's testing, to be fixed:

- **A new neighbour reloads WiFi once.** The first time an AP sees a neighbour's radio, it
  asks the controller for its whole configuration, and that push reloads its WiFi: clients
  drop once. It stops once the APs have seen each other. openUF also takes another openUF AP
  for a UniFi AP.
- **AP name and hostname.** A device not named in the controller beacons `openUF`, because
  the controller sends no name for it. WiFiman shows the router's hostname, which openUF does
  not yet set from the controller's name.
- **Silent disconnects.** Minimum RSSI and load balance disconnect clients without a log line.
- **Re-adoption.** After a Forget, a `set-inform` sent while the reset's own one is pending
  is overwritten, and the `ubnt` account is locked only when openUF next restarts.
- **Mesh switch time.** The station comes up 15 to 16 s after the cable goes, not the 10 s
  the code waits, when a report to the controller is already in flight.

## Hardware

Any dual-band OpenWrt device with **16 MB of flash or more** and about 5 MB free on
`/overlay` (the AES-GCM crypto the controller insists on needs `libopenssl3`). A **full
`wpad` build** is required and the installer swaps it in.

| Board | Profile | Tested here |
|---|---|---|
| JioRouter AX6000 JIDU6J01 family (JIDU6J01, 6201, 6401, 6601, 6701) | `jiorouter-ax6000-jidu6j01` | ✅ JIDU6401, see above. DFS channels are left out on purpose: this chip fails the radar check |
| JioRouter AX6000 JIDU6101 | `jiorouter-ax6000-jidu6101` | Not here; [inherited](#inherited-results-not-verified-here) |
| TP-Link Archer C5 v1 | `archer-c5-v1` | Not here; inherited |
| TP-Link TL-WDR3500 v1 | `tl-wdr3500-v1` | Not here; inherited (8 MB flash, needs an image with the crypto built in) |
| TP-Link Deco M4R v1 / v2 | `deco-m4r-v1` | Not here; inherited |
| Xiaomi Mi Router AX3000T | `xiaomi-ax3000t` | Not here; inherited |
| TP-Link Archer A7 v5 / C7 v4 / C7 v5, Deco M5 v1-v3, Deco M4R v4, Dynalink DL-WRX36 | from the OpenWrt sources | Never run on the board |
| TP-Link WR1043ND v2 | `tl-wr1043ndv2` | Single band; profile only |

Anything else runs on a generic dual-band or single-band profile, or on one the installer
generates from the running device. Each profile's details are in
[REFERENCE.md § Supported hardware](REFERENCE.md#supported-hardware). A board you have
tested belongs in a [field report](field-reports/README.md).

## Documentation

| Document | What it is for |
|---|---|
| [USAGE.md](USAGE.md) | Installing by hand, every configuration option, the device page and LuCI app, upgrading, troubleshooting |
| [REFERENCE.md](REFERENCE.md) | Every feature with its implementation status, the hardware matrix, local testing and protocol notes. Its status column is largely the original project's |
| [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) | What was confirmed against a live controller, with the wire evidence; it wins where other documents disagree |
| [REVERSE-ENGINEERING.md](REVERSE-ENGINEERING.md) | What is not implemented yet, what is known about it, and the experiment plan |
| [PACKAGING.md](PACKAGING.md) | The OpenWrt packages, the LuCI app, the theme and the release workflow |
| [field-reports/](field-reports/README.md) | Hardware test results, and how to send yours |
| [CLAUDE.md](CLAUDE.md) | Working notes for contributors: the constraints, the landmines, and how to add a hardware profile |

## Contributing

Issues and pull requests are welcome at [github.com/Fantastic792/openUF](https://github.com/Fantastic792/openUF).

**Send a field report.** The most useful contribution: test a feature on your hardware and
send the result in the [field-report format](field-reports/README.md), as a pull request
with one TOML file or through the **Field report** issue form. A failure is as useful as a
pass. `python3 tools/field_report.py check <file>` validates it before you send it.

**Report a problem** with the board and OpenWrt version, the controller version, and the
output of `openuf status` and `logread -e openuf` on the device. Say what the controller
showed. Leave out passwords, WiFi keys and public addresses.

**Add a hardware profile.** On a DSA board the installer can generate one (`setup.sh`, or
*Export* on the LuCI settings page); otherwise write `openuf/modelmap/<vendor>-<model>.lua`
from the board's OpenWrt DTS and `board.d` entry, following
[CLAUDE.md § Adding a new device map](CLAUDE.md#adding-a-new-device-map), and say in its
header what was and was not confirmed on the hardware.

**Change the code.** The daemon is Lua 5.1 as OpenWrt ships it, the installers are POSIX
shell for busybox; the constraints are listed in [CLAUDE.md](CLAUDE.md). Before a pull
request:

```sh
eval $(luarocks path --local) && lua tests/run_tests.lua   # the suite, pure Lua, no hardware
bash -n setup.sh && dash -n setup.sh                         # both shells, for every script touched
sh tools/dist.sh --verify                                    # the stripped tree is bytecode-identical and still passes
```

A new test file is registered in `tests/run_tests.lua`. Comments explain *why*, naming the
failure that motivated the code. Where a fact cannot be determined, report nothing rather
than a plausible guess. Protocol changes start from PROTOCOL-VALIDATION.md. No device
addresses, passwords or controller keys go into the tree. CI runs the suite, the release
verification and the field-report check on every push.

**Test without hardware.** `sh tools/simulate.sh --adopt` runs an adoption round-trip against
the Python controller stub; `tools/validation/` has a Docker UniFi controller for the real
thing.

## What this project changed

Compared with [yesrab/openUF](https://github.com/yesrab/openUF) `main` at `6277bdf`
(2026-10-26), the point it started from:

| Area | Before | Now |
|---|---|---|
| Mesh | One hop | Several hops, with the loop guard and the controller's parent choice; a downlink beacons its path element even with no uplink station |
| Mesh station on a cabled AP | The controller sends a cabled AP no uplink entry, so its station went with the next push and a later cable pull stranded it | Built from the mesh name and key when the push leaves it out |
| Mesh failover time | Checked once per report, after two failed ones: 39 s to 98 s | The cable is read every second; the station comes up 10 to 16 s after it goes |
| Mesh failback (DSA) | A device that crossed the wireless link could stay unreachable from other ports until a reboot | The switch entries left behind are rewritten |
| Mesh child's SSIDs after a WiFi reload | The AP on the station's radio could stay up but silent until a reboot | Its beacon is restarted after two silent heartbeats |
| Clock after a reboot | A clock wrong at boot could stay wrong for hours, and fast roaming then failed | Time sync is restarted when the controller's clock disagrees by more than a minute |
| Uplink Connectivity Monitor | — | New |
| Guest portal | — | New, from [jonasevcik/openUF](https://github.com/jonasevcik/openUF): redirect, authorize, per-guest limits, offline mode, disconnect when authorization ends |
| AP name in the beacon | The toggle had no effect | The name is in the beacon |
| WPA3 and Enhanced Open | The controller's first push after adoption downgraded them | Kept |
| Private pre-shared keys | A key's VLAN was lost when its SSID went off and on | Comes back with the SSID |
| Load balance | Could kick a mesh child | Leaves the mesh link alone |
| Guest WLAN | Read as a mesh link | An ordinary AP |
| Multicast and broadcast blocker | Built once | Rebuilt when the live SSIDs change |
| STUN | Never looked the controller's name up again | Looks it up again after 3 unanswered requests |
| Package upgrade | Left the old daemon running | Restarts openUF and the translator |
| LuCI | — | A Setup page for a new router |
| Tools | — | `tools/selfcheck.sh`, `tools/verify.py`, and field reports with `tools/field_report.py` |

Fixes from yesrab/openUF after `6277bdf` are merged in by hand.

## Credits

Built on [yesrab/openUF](https://github.com/yesrab/openUF): everything up to its `6277bdf`
is yesrab's and its contributors' work. openUF began as a fork of
[jonasevcik/openUF](https://github.com/jonasevcik/openUF) and still exchanges work with it.
The 802.11r translator for genuine UniFi APs is
[d-malinowski/unifi-openwrt-roaming](https://github.com/d-malinowski/unifi-openwrt-roaming),
whose author also contributed the interoperability work around it. The protocol groundwork
came from [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway),
[jeffreykog/unifi-inform-protocol](https://github.com/jeffreykog/unifi-inform-protocol) and
[fxkr/unifi-protocol-reverse-engineering](https://github.com/fxkr/unifi-protocol-reverse-engineering).
Built on [OpenWrt](https://openwrt.org/) and [LuCI](https://github.com/openwrt/luci).

## License

[GPL-3.0-or-later](LICENSE). [NOTICE](NOTICE) lists the copyright holders and preserves the
MIT notice of the original openUF. `luci-theme-halo` is Apache-2.0.

## Inherited results, not verified here

The original projects ([yesrab/openUF](https://github.com/yesrab/openUF) and, before it,
[jonasevcik/openUF](https://github.com/jonasevcik/openUF)) reported the results below on
their own hardware. This project has changed a lot since (the list above), and **has not
re-run these tests on its current code**. They are probably still true, but they are not
verified. If you can run any of them, please send a [field report](field-reports/README.md):
a pull request with one TOML file, or the **Field report** issue form. A confirmed result
moves up into [Tested on real hardware](#tested-on-real-hardware) with your name on it.

| Result reported by the original project | Field-report id |
|---|---|
| The core validated on real hardware against a **UniFi Cloud Gateway Ultra** on UniFi Network 10.x | `adoption`, `statistics` |
| **Fast roaming between openUF and a genuine UniFi AP** through the 802.11r translator | `ft-unifi` |
| **Per-port VLANs** on a Xiaomi AX3000T against a UCG Ultra, with a client getting its address on the assigned VLAN | `port-vlan` |
| **VLAN-tagged SSIDs**, end to end with a client on a tagged IoT network | `vlan-ssid` |
| **Airtime Fairness** On, pushed by a UCG Ultra and read back on four radios (ath10k, ath9k, two mt76) | `airtime-fairness` |
| **IoT Optimization: Force WiFi 4 Mode**, end to end | `radio-settings` |
| **Mesh** on a TP-Link Deco M4R v1, adopted and meshed by a user | `mesh-one-hop`, `board-profile` |
| **TP-Link Archer C5 v1** confirmed end to end, the reference device | `board-profile` |
| **TP-Link TL-WDR3500 v1** confirmed, with a custom image | `board-profile` |
| **JioRouter AX6000 JIDU6101**, the original lab APs | `board-profile` |
| **Xiaomi Mi Router AX3000T** confirmed, WiFi 6 | `board-profile` |
| **OpenWrt 24.10** with `opkg` | `openwrt-24.10` |
| The feature-by-feature status in [REFERENCE.md](REFERENCE.md) and the evidence in [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md), except where this README's own results cover it | any |

The original project's topology view, two openUF APs beside a UniFi Cloud Gateway Ultra:

![UniFi Network's topology view with two openUF access points and their clients](screenshots/unifi-topology.png)
