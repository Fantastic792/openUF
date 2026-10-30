---
paths:
  - "openuf/**"
  - "package/**"
  - "tools/**"
  - "tests/**"
  - "*.sh"
---

## File map

```
openuf/
  conf.lua          modelmap + ufmodel selection, runtime options (user-editable)
  modelmap/*.lua    hardware profiles          ufmodel/*.lua  UniFi identities
  inform.lua        TNBU inform loop, response dispatch, payload assembly (the core)
  announce.lua      L2 UDP discovery broadcasts (port 10001)
  crypto.lua        AES-128-CBC/GCM            inflate.lua  pure-Lua zlib inflate
  ucihelper.lua     all wireless UCI writes (VAPs, radios, VLAN networks)
  sysinfo.lua       /proc, iw, swconfig and bridge-fdb parsing; the per-payload lookup
                    pass and the 300 s uplink cache; the nft MAC-tap reader
  switchvlan.lua    per-port VLAN assignment: switch_vlan sections on swconfig, a bridge
                    move + learning off + nft tap (`bridge openuf_learn`) on DSA
  netconfig.lua     controller-pushed IP settings   led.lua  Locate / LED toggle
  firewall.lua      client block/unblock (nft `bridge openuf`)
  bcfilter.lua      multicast/broadcast blocker (nft `bridge openuf_bcfilt`)
  shaper.lua        WiFi speed limit: per-client HTB classes on the VAP (download) and an
                    IFB device (upload), synced every heartbeat from what build_json listed
  usteer.lua        band steering + the nft filter keeping usteerd's sync off the VAPs
  lldp.lua          neighbour table via lldpctl, read fresh every heartbeat (no cache, by
                    decision -- see the lookup-pass landmine)
  rrmscan.lua       802.11k beacon-report neighbour enrichment; the hostapd event collector
                    (ubus subscribe + control-socket monitors + `bridge monitor fdb`) that
                    assoctrack reads too
  satisfaction.lua  WiFi Experience: the UniFi firmware's formula (libubnt 4.0.15)
  assoctrack.lua    AirView Connectivity stages and Roaming reports as notif informs
  minrssi.lua       Minimum RSSI: refusal margin, 30 s hold before the kick
  loadbalance.lua   Load balance: the most idle stations above a radio's cap
  wlansched.lua     WiFi Blackout Schedule: the firmware's schedule lines, netdev down/up
  stun.lua          the STUN client whose mapped address the controller wakes
  rrbguard.lua      repairs hostapd's stale 802.11r key-exchange socket (wpad restart)
  ftinterop.lua     802.11r with genuine UniFi APs (conf `unifi_ft_interop`, on by default
                    for new installations; with the translator switched off it only changes
                    the mobility-domain formula and FT-PSK's key path): UniFi's
                    mobility domain, explicit key holders for the peers the rrb-unifi
                    translator lists, nasid = BSSID, hostapd's ft_iface on the translator's veth
  util.lua          shared helpers: file/command reads, exec_ok, is_mac, bit shim, sysfs
                    master_of/driver_of, nft_apply (one `nft -f` transaction per table)
  unhandled.lua     /etc/openuf/unhandled.json: every _type, cmd, mgmt_cfg key and
                    system_cfg key shape the controller sent that nothing here acted on,
                    with counts and a redacted body -- always on, bounded
  sysconf.lua       controller-managed system settings: system.timezone and ntpclient.*
                    into UCI (stamped, reversible), cron.* into a marked block of
                    /etc/crontabs/root (allow-listed commands only: `syswrapper.sh 11k-scan`)
  l2guard.lua       the ebtables.* block as nft `bridge openuf_l2guard`: BPDU and 802.1Q
                    drop on the AP VAPs only; intent + names in state.json for the reboot
  backhaul.lua      the mesh (wireless uplink): plan of the WDS downlink/uplink sections,
                    the wired-first policy (switch port link on swconfig), the `uplink` report
  meshvlan.lua      swconfig only: a tagged SSID's VLAN over the mesh hop, as a runtime
                    `br-lan.<vid>` port behind nft `bridge openuf_meshvlan`
  state.lua         /etc/openuf/state.json (authkey, adopted, cfgversion, inform_url)
  lib/lib.lua       globals every script expects; wraps `bit` so the same source runs
                    on the device's Lua 5.1 (luabitop) and a 5.3+ dev interpreter
  uciconf.lua       /etc/config/openuf -> the `dev`/`config` tables when a `main` section
                    exists; a custom profile passes test_modelmap's invariants or is refused
  hook/             syswrapper.sh|.lua (set-adopt / set-inform / reset-inform),
                    adopt-shell.sh — the forced login shell for the bootstrap account,
                    which permits exactly `syswrapper.sh set-adopt <url> <key>` and
                    refuses everything else. That restriction IS the security boundary;
                    openuf-cli.sh (/usr/bin/openuf), probe.lua (`openuf probe status|
                    presets|discover|export`, the one source the LuCI app reads),
                    openuf-convert.sh (/usr/sbin/openuf-convert: setup.sh's AP
                    conversion as --check/--convert/--revert), openuf-deps.sh
                    (/usr/sbin/openuf-deps, `openuf deps`: what openUF needs
                    installed as JSON, the basic-to-full wpad swap, and the
                    translator service's start), openuf-rrb.sh (`openuf rrb
                    status|peers|collect|verify`, adapted from rrb-unifi-setup)
  rrb/              the 802.11r translator for genuine UniFi APs: rrb-unifi.uc
                    (d-malinowski's, vendored; README.md there
                    names the upstream commit and the `// openUF:` changes), run as
                    etc/init.d/openuf-rrb; learns the UniFi APs on the LAN into
                    /var/run/openuf/rrb-peers.json for ftinterop.lua
  etc/init.d/openuf procd service: announce + inform instances; finds either prefix
package/            the OpenWrt feed: openuf (net/), luci-app-openuf (the LuCI pages, the device
                    page htdocs/openuf/ and its gate root/usr/share/ucode/openuf/gate.uc) and
                    luci-theme-halo (see PACKAGING.md)
setup.sh            guided installer: AP conversion + deps + install
install.sh          file/service install and dependency resolution
update.sh           on-device updater (installed as openuf-update): backup, install keeping
                    conf.lua, restart, wait for /tmp/openuf-status, roll back on failure
tools/              dist.sh (package), check.sh (preflight), simulate.sh (e2e),
                    deploy.sh (push a build to adopted APs and run update.sh on each),
                    heartbeat-probe.lua (what one inform costs a board: forks and reads),
                    fw-extract.sh (rootfs of a UniFi MIPS AP firmware: xz, cpio, binwalk),
                    strip.lua, test_controller.py, validation/ (docker controller)
PROTOCOL-VALIDATION.md   evidence for every protocol claim — read before disputing one
REVERSE-ENGINEERING.md   the open questions: unimplemented surfaces + experiment plans
```

`PROTOCOL-VALIDATION.md` records what was confirmed against a live controller versus
inferred from decompilation, and **supersedes REFERENCE/USAGE where they disagree**. If you
are about to change protocol behaviour, check there first for why it is the way it is.

`REVERSE-ENGINEERING.md` is the other half: what is *not* implemented, what is known about
each, and the next experiment. Before starting work on an unimplemented protocol feature,
read its entry — several have a "do not re-attempt" list that will save you a session. Its
first rule is the one to internalise: **never claim a capability bit openUF cannot honour**,
because that turns a missing feature into a silently broken one.
