# Credits

openUF is the work of many people over ten years. This file says who did what, which code
came from where, and what was only read or used as a tool. Commit hashes are in this
repository's history unless a line says otherwise. [NOTICE](NOTICE) holds the licence texts.

## Who maintains this repository

[Fantastic792](https://github.com/Fantastic792) maintains this fork
([Fantastic792/openUF](https://github.com/Fantastic792/openUF)). Fantastic792 also sends pull
requests to [yesrab/openUF](https://github.com/yesrab/openUF), the project this one is built
on. This fork is independent: yesrab, jonasevcik and the other authors below have not
reviewed or endorsed it, and it is not the "official" openUF. Neither project is affiliated
with Ubiquiti. UniFi is a Ubiquiti trademark.

Much of this fork's code, tests and documentation was written with the help of an AI coding
assistant (Claude, by Anthropic), and reviewed, tested and committed by the maintainer.

## Code this repository contains or was built from

| Project | Licence | What came from it |
|---|---|---|
| [trueserve/openUF](https://github.com/trueserve/openUF) (2016-2017) | in jonasevcik/openUF's history | The first openUF: the idea, the layout, and the first working discovery announce. Its commits are the oldest in this history. |
| [jonasevcik/openUF](https://github.com/jonasevcik/openUF), Jonas Sevcik | MIT | The openUF this repository grew from: the inform loop, the UCI translation, the device model profiles and most of the daemon. Later work is adopted from it on purpose (`port:` commits name the upstream commit); see [README § What this project changed](README.md#what-this-project-changed) for the features that came that way, among them the guest portal, Multicast Suppression, WPA-Enterprise, SAE options, Hotspot 2.0, RADIUS MAC auth and DFS radar reporting. |
| [yesrab/openUF](https://github.com/yesrab/openUF), Yesrab Ali and contributors | GPL-3.0-or-later | The base of this fork: everything up to its `6277bdf` (2026-10-26), including the OpenWrt packages (`package/`), the LuCI app and the Halo theme, plugins and hooks, and the relicence to GPL-3.0-or-later. Later yesrab fixes are merged by hand. |
| [fonix232/openUF](https://github.com/fonix232/openUF) | MIT (its LICENSE carries Jonas Sevcik's notice) | Read at `0afe453` and ported, with our own tests: RADIUS Dynamic Authorization relay (`das.lua`, `9f0c05d`); SNMP monitoring (`snmp.lua`, `48f70b6`, `8d8b389`); Hotspot 2.0 realm, HESSID, ANQP and QoS map reading (`a806043`, `fcd23fe`); guest restrictions without the portal (`50c480f`, `2e5d902`); Lock to AP (`07c338d`); and from its `168c362`: refusing an unencrypted controller reply, queries on renamed wiphys, Airtime Fairness and l2guard on renamed phys, blocked clients kept off the AP itself (`ba72836`, `8e15073`, `2b937b4`, `0bd8cc9`). |
| [d-malinowski/openUF](https://github.com/d-malinowski/openUF), d-malinowski | MIT (a jonasevcik/openUF fork) | The BT Home Hub 5 Type A board profile (`cf8de43`, merged as pull request #1), and the first 802.11r interop with genuine UniFi APs (`pr/unifi-ft-interop`, adopted 2026-10-25). That interop code has since been replaced by the separate translator below. |
| [d-malinowski/unifi-openwrt-roaming](https://github.com/d-malinowski/unifi-openwrt-roaming) | GPL-3.0-or-later | The `rrb-unifi` translator that lets openUF APs fast-roam with genuine UniFi APs. Not part of this repository: `setup.sh` installs it at a pinned release (v1.5). `tests/fixtures/rrb-unifi/` keeps a copy of its plugin for the compatibility test. |
| luci-theme-bootstrap ([openwrt/luci](https://github.com/openwrt/luci)), Nut & Bolt / Twitter, Inc. | Apache-2.0 | The Halo theme's widget mechanics follow it, as `package/luci-theme-halo` says. |

## Read for reference, no code taken

| Project | What we used it for |
|---|---|
| [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway) | The main protocol reference early on: the inform packet, its encryption, the announce. Its daemon was also run against our controller as a cross-check (`8a4c8c4`, `2aa28d2`). |
| [jeffreykog/unifi-inform-protocol](https://github.com/jeffreykog/unifi-inform-protocol) | Inform protocol documentation. |
| [fxkr/unifi-protocol-reverse-engineering](https://github.com/fxkr/unifi-protocol-reverse-engineering) | Protocol notes and a real UAP's captured traffic, used to check field names and the discovery announce. |
| [jamesbraid/unifi-emu](https://github.com/jamesbraid/unifi-emu) (MIT) | Reviewed at `b180786`. Its upgrade handling gave the idea for the optional switch that reports a controller-pushed firmware version (`d923dd8`). No code copied. |
| [paultyng/go-unifi](https://github.com/paultyng/go-unifi), [unpoller/unifi](https://github.com/unpoller/unifi) | Controller REST models, read when looking for field names; [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md) notes where they differ from the device protocol. |
| [zerotypic/unifi-ble-client](https://github.com/zerotypic/unifi-ble-client) | Bluetooth setup protocol research ([REVERSE-ENGINEERING.md](REVERSE-ENGINEERING.md), Investigation 4). Nothing built from it yet. |
| [dutchmillbytes/openwrt](https://github.com/dutchmillbytes/openwrt) | Its TP-Link Deco M5 images and port layout, for `openuf/modelmap/deco-m5.lua`. |

## Tools used in testing, not shipped

| Project | Licence | Use |
|---|---|---|
| [jda/pixiedust](https://github.com/jda/pixiedust) | MIT | Decoding inform captures, and its real UAP and USW captures as a reference for what an unadopted device sends. |
| [dmke/inform-inspect](https://github.com/dmke/inform-inspect) | MIT | Decoding inform captures from the lab. |
| [lua-openssl](https://github.com/zhaozg/lua-openssl) | MIT | AES-GCM/CBC for the inform crypto, on the device and in CI. |
| UniFi Network (Ubiquiti) | proprietary | Run in Docker as the test controller. Behaviour was observed on the wire; no Ubiquiti code is in this repository. |

## The platform

[OpenWrt](https://openwrt.org/), [LuCI](https://github.com/openwrt/luci), hostapd, usteer and
the rest of the OpenWrt package feed, which openUF configures and does not replace.

Missing someone, or a line is wrong? Open an issue and it will be fixed.
