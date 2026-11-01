# openUF — Usage Guide

## 1. Dependencies

The `openuf` package (§ 2) depends on every package below except the wpad build,
so a package install pulls them in; this list is for a tarball install, and for
knowing what each one is for. OpenWrt 25.12 replaced `opkg` with `apk`; on 24.10
and earlier substitute `opkg update` / `opkg install`.

**A full wpad build is not negotiable.** Every WiFi network the controller pushes
carries the 802.11v `bss_transition` option, which a `wpad-basic-*` build rejects
as unknown and takes the radio down with: the device is adopted, silent, and
has no WiFi. openUF therefore refuses to start until a full build is installed
(the log says so, naming the fix). No package dependency can say "any full
build" (every wpad variant provides the same names), so the swap is a command:

```sh
openuf deps --check                          # what is installed and what is missing, as JSON
openuf deps --install                        # install what is missing and swap a basic wpad
openuf deps --install --wpad wolfssl         # ...for a full build of another crypto library
```

The swap replaces the basic build with the full one of the **same** crypto
library (`wpad-basic-mbedtls` → `wpad-mbedtls`), so no second TLS library lands on
the flash; `--wpad openssl|wolfssl|mbedtls` chooses another. The radios are down
for about ten seconds in between, then brought back up on the new build and
openUF is restarted, so run it over a cable. The LuCI overview offers the same
as a button. `install.sh` and `setup.sh` run the swap themselves.

```sh
apk update
apk add lua lua-cjson luasocket lua-openssl luabitop libuci-lua iw lldpd nftables hostapd-utils usteer ip-bridge tc-tiny wpad-wolfssl
```

| Package | Purpose |
|---|---|
| `lua` | Lua 5.1 runtime |
| `lua-cjson` | Fast JSON encode/decode |
| `luasocket` | TCP client for HTTP POST to controller |
| `lua-openssl` | AES-128-CBC **and AES-128-GCM** (replaces `luacrypto`, which was dropped from the 25.12 feeds). Effectively mandatory — see the GCM note below |
| `luabitop` | bit operations for Lua 5.1 |
| `libuci-lua` | `require("uci")` — **every** wireless read and write goes through it (`ucihelper.lua`, `switchvlan.lua`, `usteer.lua`). Not pulled in by `lua`. Its absence is openUF's most invisible failure: the device adopts, reports its ports and statistics and looks perfectly healthy, but `radio_table` goes out **empty**, so the controller has no radio to provision a WLAN onto and not one pushed SSID is ever created. Confirmed on real hardware — four pushed WLANs, zero UCI sections, nothing logged. `openuf` now shouts about it at startup and `tools/check.sh` tests for it |
| `iw` | Radio and station statistics |
| `lldpd` | LLDP topology announcement and neighbor discovery |
| `openssl-util` | `openssl` CLI — last-resort AES-**CBC** fallback if `lua-openssl` is unavailable. This path cannot do GCM, so it is not sufficient to complete adoption on its own |
| `nftables` | Client block/unblock (`openuf/firewall.lua`) **and** Multicast Suppression (the blocker) (`openuf/bcfilter.lua`). ~490 KB with its kernel modules — the first thing that won't fit on a small-flash board, which leaves both features unavailable (openUF logs that rather than pretending) |
| `kmod-nft-bridge` | The Multicast/Broadcast Blocker, the L2 hardening (`bridge openuf_l2guard`, § 6a) and the guest portal (`bridge openuf_guest`, § 6b-3). `nftables` does not pull it in, and without `nft_meta_bridge` the bridge family has no `meta` expression — so the blocker's drop rule is rejected while its table, chain and allow-list set all build normally, and the control reports success while filtering nothing. openUF now logs the rejection and names this package. Client block/unblock matches on `ether saddr` alone and does not need it |
| `kmod-ifb` | The **upload** half of WiFi Speed Limit, queued: each SSID's ingress is redirected to an IFB device and shaped there per client, the way the download side is. Without it openUF falls back to policing (excess dropped, not queued) and says so |
| `kmod-sched-act-police` | The policing fallback for the upload half when there is no `kmod-ifb`. `tc-tiny` brings `sch_htb` but the ingress `police` action is a separate module a stock filogic image lacks; openUF logs the rejection and names this package |
| `kmod-leds-gpio` | Only on a board whose device tree declares GPIO LEDs the image has no driver for (an AX3000T registers nothing but its radio LEDs, which are wired to nothing). `install.sh` adds it when it sees that situation |
| `hostapd-utils` | `hostapd_cli` — immediate deauth of a just-blocked wireless client, client kick (Roaming Assistance) and Minimum RSSI enforcement |
| `tc-tiny` | `tc` — WiFi Speed Limit (`openuf/shaper.lua`). Busybox has no `tc`; without it the limit is recorded in UCI and never enforced |
| `usteer` | Band Steering (Behavior Controls) — ubus-based client-steering daemon, driven by `openuf/usteer.lua`. Roaming Assistant needs it too, for its view of which AP hears a client how loudly |
| `openuf/rrb/rrb-unifi.uc` (part of openUF, not a package; the `openuf-rrb` service) | 802.11r fast roaming between openUF and **genuine UniFi APs** (§ 6): d-malinowski's rrb-unifi translator, vendored (`openuf/rrb/README.md`), a ucode daemon on a veth pair that converts hostapd's inter-AP key exchange to UniFi's framing and learns which UniFi APs are on the LAN. Switched off with `openuf.rrb.enabled '0'` |
| `ucode-mod-socket`, `kmod-veth` | What the translator needs: raw packet sockets from ucode, and the veth pair hostapd's `ft_iface` moves onto. Optional like the others: without them only roaming to genuine UniFi APs is missing |
| `wpad-wolfssl` (or `wpad-openssl`, `wpad-mbedtls`, `wpad`) | Full hostapd build with 802.11k/v support — required for BSS Transition and Band Steering. Any of the full builds will do; `wpad-basic-*` lacks `bss_transition` entirely and errors with "unknown configuration item 'bss_transition'" |

`install.sh install` installs all of the above automatically when missing, so a
manual `apk add` is only needed if you're not using the installer. It treats any
full `wpad` build as sufficient and leaves an existing one alone — notably
`wpad-mbedtls`, which is what OpenWrt 25.12 ships on ath79 — rather than swapping
it for `wpad-wolfssl` and bouncing every SSID on the device for no gain.

> **AES-GCM is required for adoption.** UniFi Network Application 10.4.57 will
> not finish provisioning a device until it has received a genuine
> AES-128-GCM-encrypted inform; a device that can only do CBC stays stuck at
> "Adopting" indefinitely. openUF's GCM support needs a `lua-openssl` build with
> AEAD/GCM available — the `openssl-util` CLI fallback above is CBC-only and will
> not get you adopted. See PROTOCOL-VALIDATION.md's "The GCM provisioning gate".

There is no Lua zlib binding in the OpenWrt 25.12 feeds. openUF therefore sends
inform payloads uncompressed and decompresses zlib-compressed controller
responses with a bundled pure-Lua inflater (`openuf/inflate.lua`), so no zlib
package is required.

Only required if your inform URL uses `https://` (uncommon — the UniFi default
is `http://…:8080/inform`): `apk add luasec` for the TLS client. Without it, an
`https://` URL fails with a clear error instead of connecting in cleartext.
`install.sh` installs it for you when — and only when — the URL it finds (the
adopted `state.json`, else `conf.lua`'s default) actually is `https://`.

---

## 2. Installation

### The guided installer (`setup.sh`)

```sh
cd /tmp
wget -q https://github.com/Fantastic792/openUF/releases/latest/download/setup.sh
wget -q https://github.com/Fantastic792/openUF/releases/latest/download/SHA256SUMS
grep ' setup.sh$' SHA256SUMS | sha256sum -c - && sh setup.sh
```

The script is the latest release's, not a moving branch, and is checked before it runs;
everything it downloads afterwards (the source archive, the packages) comes from the same
release and is checked against the same `SHA256SUMS`, and a mismatch stops it before
anything is installed. There is no download without certificate checks: an image built
without `ca-bundle` is told to install it first.

This is the path to use unless you have a reason not to. It does everything in this
guide's sections 1–3 plus the access-point conversion, in an order chosen so a failure
never leaves the device unreachable — see REFERENCE.md's Quick start for the phase list
and the reasoning.

Piping it (`wget -qO- .../setup.sh | sh`) still works, but nothing can check a script
that is already running. Piping into `sh` and still being able to answer questions works because the script
re-execs itself from a file with stdin reattached to `/dev/tty`: on a pipe, stdin *is*
the script, so a `read` would otherwise eat the script's own remaining bytes. With no
controlling terminal at all (cron, a provisioning system) it says so and takes the
default answer for everything.

| Option | Question it answers | Default |
|---|---|---|
| `--ap-mode` / `--no-ap-mode` | convert to a pure AP? | yes |
| `--absorb-wan` / `--no-absorb-wan` | WAN socket into the LAN bridge? | yes |
| `--lan-address ADDR` | `dhcp`, `192.0.2.20/24`, or `192.0.2.20,255.255.255.0` | `dhcp` |
| `--lan-gateway IP`, `--lan-dns "IP [IP]"` | for a static address | — |
| `--modelmap NAME` | hardware profile, or `auto` to generate one | detected board, else a generic by radio count |
| `--controller HOST` | IP, hostname, or a full inform URL | none (L2 discovery) |
| `--bootstrap` / `--no-bootstrap` | create the `ubnt`/`ubnt` adoption account? | yes |
| `--exclusive-wlan` / `--shared-wlan` | `use_only_unifi_wlan` | exclusive |
| `--country CC` / `--no-country` | regulatory-domain override, 2-letter ISO code | none |
| `--l2-announce` / `--no-l2-announce` | L2 discovery broadcasts | derived (see below) |
| `--web` / `--headless` | the packages `openuf` + `luci-app-openuf` from the latest release (LuCI dashboard and device page), or the daemon alone as files under `/opt/openuf` | web |
| `--theme` / `--no-theme` | with `--web`: the Halo LuCI theme too | yes with 4 MB free, else no |
| `--reboot` / `--no-reboot` | reboot at the end? | yes |
| `-y`, `--yes` | take every default, ask nothing | — |
| `--keep-work` | leave the downloaded tree in `/tmp` | — |

`OPENUF_REPO=owner/repo`, `OPENUF_REF=vX.Y.Z` (a release tag) and
`OPENUF_SRC=/path/to/checkout` point it at a different source. `OPENUF_BRANCH=name`
installs a branch instead, **unverified** (a branch has no checksum; it says so), as does
`OPENUF_TARBALL_URL` unless `OPENUF_TARBALL_SHA256` gives the archive's hash. The packages
of a web install come from the same release;
`OPENUF_RELEASE_URL=https://api.github.com/repos/owner/repo/releases/tags/vX.Y.Z` picks
another release, and `OPENUF_PKG_DIR=/path` uses `.apk`/`.ipk` files already on the
device (your own build, or a device without internet), with a `SHA256SUMS` beside them
(`sha256sum *.apk > SHA256SUMS`): they are unsigned, so the checksum is what is checked.

**Web or headless.** A web install writes the interview's answers to `/etc/config/openuf`
(the `main` section, which puts UCI in charge of the daemon; LuCI's *Services → openUF →
Settings* edits the same file), creates the adoption account with `openuf
bootstrap-account`, and removes a file install left under `/opt/openuf` from an earlier
run -- the adoption state in `/etc/openuf` is shared and stays. A headless install is the
file install described in § 2, driven by `install.sh`, with `conf.lua` as its
configuration. The two never coexist: the init script would run the package's copy and
ignore `/opt/openuf/conf.lua`, and a device in that state has appeared in a controller as
two devices. `install.sh` refuses when the package is present; the package's install
warns when `/opt/openuf` is.

**The derived L2 setting.** `l2_announce` ships `true` and that is what makes the AP
appear in the controller by itself — but a controller that discovered a device over L2
insists on adopting it over SSH, and fails with "Connection Interrupted" if it cannot log
in, no matter how healthy the inform loop is. So when there is neither a bootstrap account
nor a root password, `setup.sh` turns broadcasts **off**: the controller then treats the
device as L3-discovered and delivers the adoption key over the inform channel, needing no
login. Override either way with `--l2-announce` / `--no-l2-announce`.

The same daemon also answers the discovery **requests** other Ubiquiti tools send to UDP
10001 (WiFiman's Discovery tab, the UniFi mobile app, the Device Discovery Tool), so the
AP lists there with its model, name and firmware. `l2_announce = false` turns the
broadcasts and the answers off together.

**What the AP conversion changes.** All reversible, and all of it committed but not applied
until the reboot:

| | Change |
|---|---|
| `network` | `wan` and `wan6` interfaces deleted; the WAN socket moved to the LAN side (see below); `lan` set to DHCP or the given static address; `ip6assign` dropped |
| `dhcp` | `dhcp.lan.ignore=1`, `dhcp.wan` deleted |
| services | `firewall`, `dnsmasq`, `odhcpd` stopped and `disable`d — packages kept, so re-enabling is one command each |
| resolver | `/tmp/resolv.conf` relinked to `resolv.conf.auto`, since nothing listens on 127.0.0.1 once `dnsmasq` is off and a hostname inform URL would stop resolving |
| `wireless` | `disabled='1'` removed from each radio — a fresh OpenWrt ships them off, and openUF only writes that option when the controller explicitly pushes a radio status |
| `lldpd` | `cid_interface` set to the profile's `lan_name` (section 7 explains why) |

An interface with proto `pppoe`/`wwan`/`dhcpv6`/etc. is **named and left alone** rather
than deleted — it may be a management link, and deleting a section the script did not put
there is worse than leaving it.

#### Moving the WAN socket to the LAN side

"The WAN port" is a different kind of object on the two switch generations, so this is
two different jobs:

- **DSA** — `network.wan.device` is the *socket's own* netdev (`wan`), so adding it to the
  LAN bridge genuinely puts that socket on the LAN, and traffic between it and a LAN socket
  stays inside the switch ASIC. This is the canonical dumb-AP recipe and what `setup.sh`
  does.
- **swconfig** — `network.wan.device` is a *CPU* netdev (`eth0` on an Archer C5, or
  `eth0.2` on a tagged-CPU board) reaching a socket the ASIC has segmented into its own
  VLAN. Bridging that netdev into `br-lan` works, but every frame between the WAN socket
  and a LAN socket then hairpins through the SoC — switch → CPU port → bridge → other CPU
  port → switch. On a 720 MHz QCA9558 that is the difference between wire speed and roughly
  100 Mbit/s, and it burns CPU openUF needs.

  So on swconfig `setup.sh` does the real fix instead: it rewrites the `config switch_vlan`
  sections, appending the WAN VLAN's non-CPU ports to the LAN VLAN and deleting the WAN
  VLAN. The socket becomes an ordinary LAN socket, switched in hardware, and the WAN CPU
  netdev is simply left unused. On an Archer C5 that is physical port 1 joining
  `ports '2 3 4 5 0'` and the VLAN 2 section going away.

  Because a wrong move here reassigns the wrong socket — and the first symptom is a device
  that does not come back from the reboot — it proceeds **only** when all of these hold,
  and otherwise falls back to bridging the netdev and says so:

  - the chosen profile declares `dev.conf.vlan` (the CPU port numbers) and
    `dev.conf.net.lan_vlanid`. UCI's port lists are bare numbers; which of them are CPU
    ports is board truth that lives only in the profile
  - exactly one `switch_vlan` section carries the LAN VLAN id
  - exactly one *other* `switch_vlan` section exists, on the same switch device
  - that section has at least one non-CPU port to move (a `t`/`u` suffix is stripped
    before the comparison, so a tagged CPU port is never mistaken for a socket)

  A side effect worth knowing: openUF suppresses wired clients on any socket whose pvid is
  not the management VLAN, so before this change the Archer C5's WAN socket reported no
  hosts even with a cable in it. Afterwards it is on VLAN 1 and reports them normally.

openUF's own nftables tables live in `bridge openuf` and `bridge openuf_bcfilt`,
deliberately outside `fw4`'s `inet fw4`, so client Block/Unblock and the Multicast and
Broadcast Blocker keep working with the firewall service off.

### As an OpenWrt package

The release page carries `openuf_<version>-<release>_all.ipk` (OpenWrt 24.10 and earlier,
`opkg`) and `openuf_<version>-<release>_all.apk` (25.12 and later, `apk`), built by the
release workflow from the same comment-stripped tree `tools/dist.sh --verify` proves. The
package installs to `/usr/lib/openuf`, its configuration is `/etc/config/openuf`, and both
that file and `/etc/openuf/` (the state) survive `sysupgrade`.

```sh
# 25.12 and later
apk add --allow-untrusted ./openuf_0.9.0-1_all.apk
# 24.10 and earlier
opkg install ./openuf_0.9.0-1_all.ipk

uci set openuf.main.inform_url='http://<controller>:8080/inform'   # if not "unifi"
uci commit openuf && /etc/init.d/openuf enable && /etc/init.d/openuf start
openuf status
```

With `modelmap 'auto'` (the default) the daemon runs as the shipped profile that declares
this board, exactly the match `setup.sh` makes. A board no profile declares is a refusal,
not a guess -- the log says `no modelmap declares board <name>` and the service does not
start -- because the generic profiles carry a `lan_cpueth` that is wrong for a DSA board,
and that field is the identity MAC. Pick a profile (`uci set openuf.main.modelmap=...`) or
describe the board in a custom map (§ 3, or the LuCI app's Settings page, which fills the
form in from what the board reports about itself).

**`luci-app-openuf`** (same release page, same two formats) adds *Services → openUF* to
LuCI, for OpenWrt 24.10 and later:

- *Overview*: the service and adoption state, the profile and identity in use, the WiFi
  networks the controller pushed, which optional packages are missing and the command that
  installs them, and Restart / Scan for neighbours / Forget the controller. A few of the
  same lines appear on *Status → Overview*.
- *Settings*: every `openuf.main` option with a plain-language description. The hardware
  profile and the UniFi model are dropdowns of the shipped presets plus "custom"; both are
  locked while the device is adopted, because either changes the address the controller
  knows the device by. Choosing "custom" reveals the custom profile form, filled in from
  what the board reports about itself (sockets, radios, LEDs and what OpenWrt already
  drives), the socket table and the custom identity form. Once saved, *Export the saved
  custom profile as a file* produces a modelmap file to contribute. While the device is
  still a router, *Convert to an access point and reboot* runs `openuf-convert` behind a
  confirmation; *Turn back into a router* on the Overview page runs `--revert`.
- *Log*: openUF's lines from the system log, newest first.

`openuf-convert` is the conversion `setup.sh`'s last phase performs, as a command:

```sh
openuf-convert --check      # {"state":"router"|"ap","reasons":[...],"converted":...}
openuf-convert --convert [--address dhcp|<ip>/<prefix>] [--gateway <ip>] \
                         [--dns "<ip> <ip>"] [--keep-wan-socket]
openuf-convert --revert     # the backed-up files come back at the next reboot
```

`--convert` removes `wan`/`wan6`, joins the WAN socket to the LAN (into the switch's LAN
VLAN on a swconfig board whose profile proves the geometry, into `br-lan` otherwise), gives
the LAN a DHCP address unless a static one is named, switches off the DHCP server, stops and
disables the firewall, dnsmasq and odhcpd, points the resolver and lldpd's chassis id away
from what is gone, and enables every radio. It commits and does not apply: the caller (the
LuCI button, or you) reboots, the only safe way to apply a network teardown you are
connected through. The configuration files it touches are saved to
`/etc/openuf/convert-backup.tgz` and a stamp in `openuf.convert` is what `--check` reports
and `--revert` restores from. Every unknown is a refusal, for the same reason `setup.sh`
refuses: a wrong guess is a device that does not come back from the reboot.

The package depends on everything openUF works through (`nftables`,
`kmod-nft-bridge`, `tc-tiny`, `kmod-ifb`, `kmod-sched-act-police`, `usteer`, `hostapd-utils`,
`ip-bridge`, `lldpd`, the Lua bindings), so one install brings them all. The one
thing it cannot bring is a **full wpad build**, which OpenWrt cannot express as a
dependency: on a stock image the service refuses to start until `openuf deps
--install` (or the button on the LuCI overview) has replaced the `wpad-basic-*`
build with the full one of the same crypto library. The package's install
message says so when it applies; § 1 has the why.

### By hand

Download the source tree directly on the device over SSH — no git client or scp required.
`install.sh` comment-strips the Lua on the way in (`tools/strip.lua`), so the device gets
the same lean tree a release would ship:

```sh
# On the OpenWrt device
wget -O openuf-src.tar.gz https://codeload.github.com/Fantastic792/openUF/tar.gz/main
tar xzf openuf-src.tar.gz && cd openUF-main
sh install.sh install
```

Releases are tagged `vX.Y.Z`; each one publishes a pre-stripped `openuf-X.Y.Z.tar.gz`
plus its `.sha256` via GitHub Actions under `https://github.com/Fantastic792/openUF/releases`.
It is the archive the OpenWrt package builds from, it unpacks to `openuf-X.Y.Z/`, and it
installs the same way. If you're
working from a git checkout instead (e.g. for development), the old transfer-then-install
flow still works:

```sh
# From your development machine
scp -r openuf/ install.sh setup.sh tools/ root@<device-ip>:/tmp/openuf/
ssh root@<device-ip> "cd /tmp/openuf && sh install.sh install"
# or, for the guided install from that same checkout:
ssh -t root@<device-ip> "cd /tmp/openuf && sh setup.sh"
```

`install.sh` does **not** touch the network configuration: a device installed this way is
still a router unless you convert it yourself. It works on both package managers — `apk`
on OpenWrt 25.12+ and `opkg` on 24.10 and earlier.

What `install.sh install` does:
- Copies `openuf/` to `/opt/openuf/` — **keeping an existing `conf.lua`** (the shipped
  default lands next to it as `conf.lua.dist`). That is what makes a re-run the upgrade
  path: `conf.lua` holds the modelmap the device was adopted under, and on a DSA board
  resetting it to the generic profile moves `lan_cpueth` and with it the identity MAC,
  after which the controller rejects every inform with HTTP 400. `--replace-conf`
  overwrites it deliberately; `setup.sh` passes that, since it has just rewritten
  `conf.lua` from its interview. Modelmaps are always replaced, so a board profile you
  edited on the device should be copied out first.
- Creates `/etc/openuf/` (state directory)
- Adds `/etc/openuf/` and `/opt/openuf/conf.lua` to `/etc/sysupgrade.conf`, so that a
  firmware upgrade keeps them. `sysupgrade` preserves `/etc/config` and a short built-in
  list and knows nothing about either path; without this a stock upgrade takes
  `state.json` — mac, authkey, cfgversion, `swvlan_backup` — and the modelmap selection
  with it, and the AP comes back unadopted, posing as a generic dualband AP the
  controller no longer recognises. Each line is appended only if it is not already there
  and nothing else in the file is touched, so a keep list you maintain yourself is safe.
  The Lua tree is deliberately *not* preserved: the installer reinstalls it, and carrying
  an old copy onto a new OpenWrt is a silent version mismatch
- Symlinks `/opt/openuf/hook/syswrapper.sh` → `/usr/bin/syswrapper.sh`
- Creates `/etc/init.d/openuf` with two procd service instances (announce + inform)
- Installs and enables `/etc/init.d/openuf-rrb`, the 802.11r translator for genuine UniFi
  APs (§ 6; the daemon is `openuf/rrb/rrb-unifi.uc`, copied with the tree). It idles until
  a config push carries an FT WLAN. Its two packages, `ucode-mod-socket` and `kmod-veth`,
  go in with the other optional ones
- Enables and starts the service
- Enables and starts `lldpd`

To uninstall:
```sh
sh install.sh uninstall
```

Uninstall removes the `/opt/openuf/conf.lua` line from `/etc/sysupgrade.conf` — the file
is gone with `/opt/openuf/` — but **keeps the `/etc/openuf/` line**. The state directory
itself is left intact so that the authkey survives, and un-registering it would let the
next firmware upgrade delete exactly what it is being kept for. Remove that line by hand
if you also delete `/etc/openuf/`; leaving it costs nothing either way.

### Upgrading an installed AP

Nothing about an upgrade needs a re-adoption, provided `conf.lua` survives it: it holds the
modelmap, the modelmap holds `lan_cpueth`, and that interface's MAC is the identity the
controller adopted the device under. `install.sh install` keeps it, `state.json` is never
touched, and a daemon restart between two ten-second informs is invisible to both the
controller and the clients (`wifi reload` only ever happens on a config push). Three ways
to run that, from the least to the most involved:

**On the device.** `install.sh` installs the updater as `openuf-update`:

```sh
openuf-update --check                     # what is installed: build stamp, modelmap,
                                          # identity, last inform, whether the daemons run
openuf-update                             # the latest release, sha256-checked, in place
openuf-update --ref v1.2.0                # that release instead, sha256-checked
openuf-update --branch main               # a branch: unverified (no checksum exists)
openuf-update --from /tmp/openuf-X.Y.Z.tar.gz
                                          # a release archive already on the device
```

It backs up `/opt/openuf` and `/etc/openuf` to a tarball in `/tmp`, runs `install.sh
install` (which also installs any dependency the new version added), restarts the service,
and then **waits for the new daemon to complete an inform** — the daemon rewrites
`/tmp/openuf-status` after every cycle — before declaring success. No completed cycle
within 75 s, or no daemon left running, and it puts the backup back and restarts the old
version. A daemon that is up but whose controller is not answering is reported and kept,
since the old version would face the same controller. It also lists the options that the
shipped `conf.lua.dist` knows and your kept `conf.lua` does not name; they take their
documented defaults, and this is how a new knob gets noticed.

**From your development machine, to several APs.** `tools/deploy.sh` builds the release
tarball (`tools/dist.sh --verify`, so the suite gates every deploy), copies it to each AP
over ssh and runs the same updater there, one AP at a time — a failure stops before the
next host:

```sh
sh tools/deploy.sh --check 192.0.2.22 192.0.2.149   # what each AP runs; nothing changes
sh tools/deploy.sh 192.0.2.22 192.0.2.149           # build, push, update, verify
OPENUF_SSH_PASS='...' sh tools/deploy.sh 192.0.2.22   # an AP whose root has a password
```

By default ssh runs non-interactively (a key in `/etc/dropbear/authorized_keys`, or a root
account with no password yet). `OPENUF_SSH_PASS` hands the password to ssh through a
throwaway askpass helper, so it is never written to a file; `OPENUF_SSH` replaces the ssh
command entirely (`OPENUF_SSH='ssh -i ~/.ssh/aps'`).

**By hand** is the same thing without the safety net: download the tree, `sh install.sh
install` (no `--replace-conf`), `/etc/init.d/openuf restart`. Every path leaves a build
stamp in `/opt/openuf/BUILD` (`git describe` of the tree plus a UTC time; `-dirty` means
uncommitted changes were in it), which `openuf-update --check` and `tools/check.sh` print.

What to expect afterwards: the controller sees no disconnect; new options are documented in
`conf.lua.dist` next to your kept copy; a modelmap you hand-edited on the device is
**overwritten** (the backup tarball has your copy). Downgrading is the same command with an
older `--ref`, or `tar xzf /tmp/openuf-backup-<stamp>.tgz -C / && /etc/init.d/openuf
restart` while the backup still exists — `/tmp` is tmpfs, so that means until the next
reboot.

---

### The device page (`luci-app-openuf`)

Once `luci-app-openuf` is installed and the device has rebooted, opening its address in a
browser shows openUF's **device page**, not LuCI. Like an adopted Ubiquiti or Omada device,
an openUF access point belongs to its controller, and the page says so:

- **Overview** -- visible to anyone who can reach the device: whether a controller manages
  it, a link to that controller, and the facts the access point already broadcasts in its
  UniFi discovery packets (model, MAC, firmware, uptime, last contact). No SSIDs, keys or
  configuration.
- **Local Settings** -- after the device's root password: the inform URL, *Forget
  controller*, the hardware profile and the UniFi model to present (locked while adopted),
  the WiFi behaviour switches, the page switch below, and restarting openUF or the device.
  On a tarball install (`install.sh`, no `main` section in `/etc/config/openuf`) openUF's
  own fields are shown read-only: they live in `conf.lua` there.

**Getting to LuCI.** On the device page type the Konami code -- ↑ ↑ ↓ ↓ ← → ← → B A -- or,
on a phone, tap the picture of the device seven times. A prompt offers LuCI; accept and
LuCI asks for the root password as usual. LuCI then shows *Exit LuCI mode* next to its own
*Refreshing* indicator: it signs out of LuCI and returns to the device page. The page comes
back on its own when the LuCI session ends (log out, or the session times out).

**Turning it off.** `uci set openuf.web.portal=0 && uci commit openuf`, or the switch
under *Local Settings* (*This page*) or in LuCI (*Services → openUF → Settings → Device
page*). It takes effect on the next page load. `luci-app-openuf`'s removal puts LuCI back
at once.

This is presentation, not a lock: LuCI keeps its own login, and the page never offers more
than the root password already allows.

**The Halo theme.** `luci-theme-halo` restyles all of LuCI in the same language as the
device page: a sidebar with icons, cards, switches for on/off options, a floating
*Save & Apply* bar, and light and dark (*Halo* follows the browser, *Halo Dark* and *Halo
Light* pin one; pick under *System → System → Language and Style*). It works on any LuCI
install, openUF or not. `openuf deps --install` adds it only where LuCI is installed and at
least 4 MB of flash is free (`--no-theme` skips it; `openuf deps --check` reports the
decision under `theme`), so a small-flash device never spends space on looks.

## 3. Configuration

### Hardware model map (`openuf/conf.lua`)

Select the modelmap that matches your hardware:

```lua
-- For TP-Link Archer C5 v1 (dual-band, board-specific):
dev = dofile("modelmap/archer-c5-v1.lua")

-- For TP-Link TL-WDR3500 v1 (dual-band, board-specific):
dev = dofile("modelmap/tl-wdr3500-v1.lua")

-- For TP-Link WR1043ND v2 (single-band):
dev = dofile("modelmap/tl-wr1043ndv2.lua")

-- For TP-Link Archer A7 v5 / Archer C7 v4 / Archer C7 v5 (dual-band; one map for all three,
-- presents as a UAP-IW-HD -- see "Device identity" below):
dev = dofile("modelmap/archer-a7-v5.lua")

-- For TP-Link Deco M5 v1 / v2 / v3 (IPQ4019 / ipq40xx — a DSA board; one map for all three,
-- presents as a UAP-AC-HD -- see "Device identity" below):
dev = dofile("modelmap/deco-m5.lua")

-- For TP-Link Deco M4R v1 / v2 (QCA9563 / ath79 — swconfig; one map for both, the v2 reports
-- the v1's board name; presents as a UAP-AC-HD):
dev = dofile("modelmap/deco-m4r-v1.lua")

-- For TP-Link Deco M4R v4 (MT7621 / ramips — a DSA board whose two sockets are the netdevs
-- eth0 and eth1; presents as a UAP-AC-HD):
dev = dofile("modelmap/deco-m4r-v4.lua")

-- For JioRouter AX6000 JIDU6101 (MT7986A / filogic — a DSA board):
dev = dofile("modelmap/jiorouter-ax6000-jidu6101.lua")

-- For JioRouter AX6000 JIDU6J01 / 6201 / 6401 / 6601 / 6701 (one map, all five):
dev = dofile("modelmap/jiorouter-ax6000-jidu6j01.lua")

-- For Dynalink DL-WRX36 (IPQ8072A / qualcommax — five sockets, one netdev each; presents as
-- a U6-InWall like the JioRouters; pin br-lan's MAC before adopting, see the file's header):
dev = dofile("modelmap/dynalink-dl-wrx36.lua")

-- For Xiaomi Mi Router AX3000T (MT7981 / filogic — DSA; adopted from upstream):
dev = dofile("modelmap/xiaomi-ax3000t.lua")

-- For BT Home Hub 5 Type A (lantiq xrx200, DSA — no swconfig;
-- VLAN-tagged SSIDs assume the uplink cable is in lan1):
dev = dofile("modelmap/bt-homehub-v5a.lua")

-- For any other dual-band OpenWrt AP:
dev = dofile("modelmap/generic-dualband-ap.lua")

-- For any other single-band OpenWrt AP:
dev = dofile("modelmap/generic-singleband-ap.lua")
```

`setup.sh` picks this line for you: each board-specific profile declares the OpenWrt
board names it is for in `dev.openwrt_boards` (the DTS compatible string, e.g.
`{"jiorouter,ax6000-jidu6101"}`), and the installer matches that against
`/tmp/sysinfo/board_name`. openUF itself never reads the field, so a profile without one
is still perfectly valid — but adding it is what makes a new profile get preselected on
every device like yours.

Prefer a board-specific map where one exists. A generic profile cannot know your
board's LED name (so Locate and the LED toggle do nothing) or which of its ports
is the uplink — and it gets the uplink wrong on an Archer C5 deployed as an AP,
which uses `eth1` and never touches `eth0`.

#### Radio policy (`dev.conf.radio`)

```lua
dev.conf.radio = {
	na = { acs_exclude_dfs = true, htmode_floor = "HE80" },
	ng = { htmode_floor = "HE20" },
}
```

| Field | What it does |
|---|---|
| `acs_exclude_dfs` | Writes UCI `acs_exclude_dfs=1` whenever the effective channel is `auto`, so hostapd's ACS chooses among **non-DFS** channels only |
| `channels` | Optional explicit ACS candidate list (UCI `channels` → hostapd `chanlist`). Narrower than `acs_exclude_dfs`, for a board that also needs specific channels excluded |
| `htmode_floor` | Raise a pushed `htmode` to at least this, kind and width independently. The hardware clamp still runs **after** it, so a floor can never invent capability. **Suppressed for a radio while any WLAN on it has "Force WiFi 4 Mode" on** — that mode is an explicit instruction, the floor is a correction for a controller default, and explicit intent wins |
| `htmode_max` | Lower a pushed `htmode` to at most this — for a width the driver *advertises* and the radio cannot actually run |

Both ACS options are torn down again the moment a concrete channel is pushed — they are
ACS-only inputs, and leaving them behind would silently resurrect the restriction the next
time **Auto** is selected.

**Why `acs_exclude_dfs` exists.** Controller channel **Auto** arrives as the literal
`channel=auto` and is handed to hostapd's ACS. On an MT7986 (JIDU6101) ACS reliably picks
a DFS channel the driver cannot start CAC on, and the radio is left **down** while the
controller happily reports the WLAN as provisioned:

```
phy1-ap0: ACS-COMPLETED freq=5260 channel=52
phy1-ap0: DFS-CAC-START freq=5260 chan=52 cac_time=60s
hostapd: DFS start_dfs_cac() failed, -1
phy1-ap0: interface state DFS->DISABLED / AP-DISABLED
```

With the flag set, the same radio came up first try — `ACS-COMPLETED channel=153` →
`AP-ENABLED`, live on channel 149 at 80 MHz. Note that a *maximum* channel is not a fix:
under `IN`, `iw phy` marks 52–64 and 100–144 "(radar detection)", so capping at 128 would
leave every failing channel in range while excluding 149–165, which are the ones that work.

**The PHY generation comes from the hardware, not from the wire.** What a real controller
sends is `radio.<n>.ieee_mode=11nght20` / `11naht40` — its vocabulary is Atheros-era (the
same push names the VAPs `ath0`/`ath1`/`ath2`), and that `ht` is *not* a request for 802.11n.
It is all this key has ever said: the **band** and the **width**. A real U6-InWall receiving
`11naht40` runs it as HE40. So openUF takes the width from the wire and the PHY from `iw phy`
(`ucihelper.best_phy`), then clamps as above — a 2.4 GHz-capable ax radio given `11nght20`
gets `HE20`, an n-only one gets `HT20`. Reading the token literally had pinned every 802.11ax
radio to 802.11n permanently, which is invisible in the controller (it shows the width, which
was right) and visible only in `iw dev`. An explicit `vht`/`he`/`eht` token, if one ever
arrives, is honoured as written, and a WLAN with **Force WiFi 4 Mode** keeps the radio on
HT, because that mode asked for an 802.11n beacon. (Found by upstream on an AX3000T; the
JioRouter maps had been compensating with an `htmode_floor`.)

**Why `htmode_floor` still exists.** The PHY is automatic now, but the WIDTH is what the
wire says, and a UCG Ultra pushes `11naht40` — 40 MHz — to this emulated U6IW at a 4x4
WiFi-6 radio, which threw away most of it (a client associated at MCS 15 / 144 Mbit/s).
That is a controller-side default for the model it thinks it is talking to rather than an
intent, so a board may declare a floor to raise the width back. This is the **one
exception** to openUF's otherwise absolute "clamp downward only" rule, which is why it is
opt-in per board and logged when it fires:

```
openuf: radio1: controller asked for htmode HE40, board floor is HE80 -- raised to HE80
```

`HE20` as the 2.4 GHz floor is now documentation rather than a correction: a pushed
`11nght40` keeps its 40 MHz and comes up HE40 with or without it. (2.4 GHz may still transmit
at 20 MHz on air — hostapd applies 802.11 40 MHz coexistence when it sees neighbouring BSSes.
That is standard behaviour, not a misconfiguration.)

**Why `htmode_max` exists.** A JIDU6101's `iw phy` reports `Supported Channel Width: 160
MHz`, so `clamp_htmode` passes `HE160` straight through — and the radio comes up **down**.
A 160 MHz block is 8 contiguous 20 MHz channels, and under `IN` every one that fits
overlaps DFS:

```
DFS-CAC-START freq=5180 chan=36 sec_chan=1, width=2, seg0=50, seg1=0, cac_time=60s
hostapd: DFS start_dfs_cac() failed, -1
hostapd: Interface initialization failed          -> AP-DISABLED
```

Channel 36 centres the block on `seg0=50` (channels 36–64, of which 52–64 are DFS);
channel 100 centres on 114 (100–128, all DFS). The only clear range, 149–173, is seven
channels — 140 MHz — and 177 is disabled, so no 160 MHz block fits there at all. With CAC
broken in this driver, 160 MHz is unreachable on any channel, and `acs_exclude_dfs` cannot
help because a **fixed** channel skips ACS entirely. No capability check can catch this —
only the board can say "advertised but unusable".

There is one way to get 160 MHz on such a board: change the **regdomain**, since that is
what applies the DFS flags in the first place. Under `PA` the same radio has no DFS
channels at all and 160 MHz comes up first try — see `country_override` in §3. If you use
it, raise `htmode_max` to `HE160` (or drop it) so the ceiling stops blocking what now
works.

#### swconfig boards vs DSA boards

Which of these your board is decides the whole shape of `dev.conf.net.ports`, and
getting it wrong is not cosmetic: a socket wrongly treated as downstream makes the AP
report the entire LAN, gateway included, as hosts plugged into it.

On the **swconfig** boards (ath79 and other pre-DSA targets) the kernel sees only the CPU
port. sysfs therefore answers questions about the internal SoC↔switch link — always
1000/full — rather than about the socket a cable is in, and the bridge FDB attributes every
wired host to that one netdev. The switch knows all of it, so a profile there sets
`dev.conf.vlan` and lists sockets by `swport`.

On a **DSA** board (mediatek/filogic and later) every socket is its own netdev with its own
carrier, negotiated speed and slice of the bridge FDB. The switch detour is unnecessary and
`dev.conf.vlan` must be **absent** — setting it sends openUF down the swconfig path,
shelling out to a `swconfig` that is not installed. Ports are listed by `ifname`, and the
uplink socket is found in the bridge FDB by setting:

```lua
dev.conf.net.uplink_detect = "fdb"
```

That looks up the default gateway's MAC and reports whichever socket learned it as
`is_uplink`. When it cannot answer — no default route yet, no `bridge` binary, gateway not
learned — openUF reports the ports but **no wired clients at all**, rather than attributing
the LAN to a guessed socket. Two more DSA differences:

- `lan_cpueth` names the LAN **bridge** (`br-lan`), not a socket. It decides the device's
  identity MAC, which must not depend on which of four equally-valid sockets the installer
  used; it is where the management address lives; and a tagged SSID's sub-device has to
  hang off the bridge (`br-lan.20`) — one on a bridge *port* never sees a frame.
- Per-port VLAN assignment is a **bridge move**, never `bridge-vlan`: `switchvlan.dsa_apply`
  takes the assigned socket out of `br-lan` and puts it into that VLAN's `br-openuf<id>`
  bridge — the same L2 a tagged SSID on that VLAN already uses. `br-lan` keeps the uplink
  and the management address and nothing ever runs with `vlan_filtering`, so a wrong answer
  cannot strand the AP. Native VLAN only; a tagged-only port is refused out loud.

  **openUF turns MAC learning off on every socket it moves**, with a `config device`
  section named `openuf_brport<vid>_<socket>`, and on the tagged uplink sub-device with
  `openuf_brport<vid>`. This is not a tuning knob. `br-openuf<vid>` is a *software* bridge,
  but the moved socket is still a real port on the same ASIC as the uplink, and that ASIC
  has **one** address table: let it learn the attached device against the socket and a
  reply arriving VLAN-tagged on the uplink port hits that entry, the switch resolves the
  frame in hardware to a port that is no longer in the uplink's bridge, and drops it.
  Outbound is perfect throughout, which is what makes it so hard to see. Upstream measured
  this on an AX3000T (mt7530): learning on, four DHCP DISCOVERs leave, nothing comes back;
  learning off, DISCOVER → OFFER → REQUEST → ACK in 2 ms. A live reassignment still
  converges slowly — an entry the ASIC learned before the move cannot be deleted and ages
  out on its own in ~140 s, so give a freshly moved port three minutes before suspecting
  anything else.

  With learning off the socket's hosts vanish from `bridge fdb`, which on a DSA board is the
  only wired-host source — so openUF installs a bridge-family nftables tap
  (`nft list table bridge openuf_learn`: two dynamic sets, `portmacs` and `portips`, with
  5-minute timeouts matching the bridge's own FDB ageing) and `port_table` reads that for a
  socket whose bridge is not the uplink's. The FDB always wins where it has an answer; a
  board with no assigned socket never forks `nft`. The tap also collects each host's
  address, because the AP holds no address on that VLAN and `/proc/net/arp` can never
  answer for it — and the row carries `vlan`, which is what the controller uses to file a
  wired client under the right **network** (it keeps a host only where the network's VLAN
  equals the row's `vlan`, defaulting to 1). Both are rebuilt from UCI at startup, since
  nftables keeps nothing across a reboot.

  ⚠️ All of the above is upstream's work, verified on a Xiaomi AX3000T against a UCG Ultra.
  The JioRouter boards' mt7531 is the same driver family, but this tree has not exercised
  per-port VLAN on them yet.

The modelmap sets:
- `dev.openwrt_boards`      — the OpenWrt board names this profile is for, e.g.
  `{"tplink,archer-c5-v1"}`. Read only by `setup.sh`, to preselect the profile; openUF
  ignores it. Omit it on a generic profile
- `dev.conf.net.lan_cpueth` — LAN CPU ethernet port (e.g. `eth1`), or the LAN **bridge**
  (`br-lan`) on a DSA board; also the trunk the VLAN-tagged sub-interfaces
  (`<lan_cpueth>.<vlanid>`) for controller-pushed VLAN SSIDs hang off
- `dev.conf.net.uplink_detect` — `"fdb"` on a DSA board, to find the uplink socket in the
  bridge FDB instead of a swconfig ARL table. Omit it on a swconfig board, where the
  ARL lookup already covers it; the two are mutually exclusive
- `dev.conf.radio`         — per-band answers to things the controller states in terms it
  cannot know are wrong for this board. Keyed by openUF's band keys (`ng` = 2.4 GHz,
  `na` = 5/6 GHz), all three fields optional, and with no entry the behaviour is exactly
  as before. See **Radio policy** below
- `dev.conf.vlan.mib_poll_ms` — how often the switch driver refreshes its per-port byte
  counters, which is where the Ports view's Tx/Rx figures come from. openUF turns polling on
  at startup (500 ms) when the driver ships it off, which an AR8327 does; set `false` to
  leave the switch alone, at the cost of 0 B on every socket
- `dev.conf.net.ports`      — the ports openUF reports to the controller, one entry per
  **physical socket** on a board with a switch: `{idx = 1, swport = "lan1"}`, where `idx`
  is the UniFi `port_idx` and `swport` names a key in `dev.conf.vlan.ports`. Pin each
  `idx` to a socket and leave it alone — the controller keys per-port settings on it.
  Do **not** flag one as `uplink`: openUF detects which socket the uplink cable is in
  from the switch's ARL table, so the flag follows a replug and the other sockets report
  their own link speed and their own wired clients. A board with no switch map instead
  uses the netdev shape (`{idx = 1, ifname = "eth0", uplink = true}`), which on a switch
  board can report only the CPU port's internal link. The two mix: a socket wired to its
  own MAC/PHY instead of the switch (the TL-WDR3500's WAN socket, `eth1`) is listed with an
  `ifname` and no `swport`, and sysfs then describes that socket correctly. Count the RJ45
  sockets on the case — the list should have one entry each
- `dev.conf.net.wan_cpueth` — WAN-side CPU netdev (e.g. `eth0`). Only used as the uplink
  entry of a fallback `port_table` for a board that declares no `dev.conf.net.ports`
- `dev.conf.vlan.device`    — swconfig device name (e.g. `switch0`), as `swconfig list`
  reports it. Boards that name it something else — `switch1` is common on ath79 and
  ramips — must set this, or every `swconfig` call silently addresses the wrong device
  and per-socket port reporting falls back to the CPU-port netdev. Not used on a DSA
  board, which has no swconfig at all
- `dev.conf.led`            — status LED, driven by the controller's Locate action and its
  **Manage → LED** toggle. Accepts a full sysfs path (`/sys/class/leds/tp-link:green:wlan`)
  or a bare LED name (`tp-link:green:wlan`). `nil` by default, since a generic profile can't
  know the board's LED — LED control is a silent no-op until you set it. Find yours with
  `ls /sys/class/leds`
- `dev.openuf.uap.ufmodel`  — Which ufmodel file to load (e.g. `"u6iw"`)
- `dev.openuf.uap.hwassign` — UCI radio names to report to the controller
  (e.g. `{"radio0", "radio1"}`). Every other `wifi-device` on the board is left out of
  `radio_table`, so a radio the emulated model doesn't have (a third phy, a mesh- or
  monitor-only one) is neither shown nor configurable in the UI. Omit it — or leave it
  empty — to report every radio UCI knows about, which is what a modelmap without the
  field means. openUF never touches an unreported radio: a config push naming one is
  refused rather than applied

### Device identity (`openuf/ufmodel/*.lua`)

The U6-InWall identity is configured in `ufmodel/u6iw.lua`.  The firmware version
(`fw.ver`) must be accepted by your controller.  If the controller rejects the
device with "firmware too old" or similar, increment `fw.ver` and try again.

```lua
uap = {
    platform = "U6IW",
    model    = "U6IW",
    fw = {
        pre        = "U6IW.",
        ver        = "6.6.55",    -- tune this if the controller rejects the device
        buildtime  = "230801.1200",
        factoryver = "6.5.28"
    },
    ...
}
```

The Archer A7/C7 profile selects `ufmodel/uhdiw.lua` instead: the **UAP-IW-HD**, the WiFi 5
in-wall AP with the same five sockets, so a controller offers that board 802.11ac modes rather
than the WiFi 6 ones it would push at a U6-InWall and openUF would have to clamp.  Its
`platform`/`model` are `UHDIW`, and its `fw.ver` (`6.7.57.15670`) is the release-channel entry
of Ubiquiti's firmware catalog for that platform — the value the controller compares the
reported version against with a strict string equality, so it must stay bare (`M.m.p.build`,
no model prefix) and must track the catalog.  When the controller shows a spurious "Update
Available" for the device, re-read the catalog URL in the file's header and update `fw.ver`.
⚠️ No controller has adopted a device under this identity yet; if adoption stalls, set
`ufmodel = "u6iw"` in the modelmap and report what the controller did.

The Deco M5 profile and both Deco M4R profiles select `ufmodel/u7hd.lua`: the **UAP-AC-HD**, the WiFi 5 Wave 2 ceiling
AP with **two** GbE sockets (Main and Secondary), chosen because both in-wall identities carry
five sockets and a two-port board reporting either leaves three rows in the controller's Ports
view that never link up.  `platform`/`model` are `U7HD` and `fw.ver` (`6.8.2.15592`) is the
catalog's release entry for that platform, subject to the same bare-version rule.  The UAP-AC-HD
also has a USB-C socket Ubiquiti marks "reserved for future use"; no inform field describes it,
so openUF reports nothing and the controller sees it as it would on a real unit.  ⚠️ Adopted
once so far, a Deco M4R v1 on 2026-10-18; the port questions in the file's header are still
open, and the same fallback applies.

### `/etc/config/openuf` (package installs)

On a package install the configuration is UCI, and whenever `/etc/config/openuf` has a
`main` section it replaces `conf.lua`'s `dev` and `config` tables (`uciconf.lua`).
Options the section leaves out keep `conf.lua`'s defaults, so a package upgrade that adds
an option needs no migration. LuCI's "Save & Apply" on this file restarts the daemons.

`openuf.web.portal` (`1` by default, its own `web` section so that creating it never puts
UCI in charge of the daemon) chooses between the device page and LuCI at the device's
address; see § 2, "The device page".

| `openuf.main` option | Meaning |
|---|---|
| `modelmap` | `auto` (the shipped profile that declares this board), a profile name from `/usr/lib/openuf/modelmap/`, or `custom` (the `device`, `port`, `vlan`, `swport` and `radio` sections) |
| `ufmodel` | `auto` (the profile's own identity), a name from `/usr/lib/openuf/ufmodel/`, or `custom` (the `identity` section) |
| `inform_url`, `use_only_unifi_wlan`, `keep_wlan_section` (a list), `l2_announce`, `neighbour_scan_interval`, `rrm_enrichment`, `rrm_request_interval`, `assoc_tracker`, `roam_assist_diff_db`, `country_override`, `bootstrap_adopt_user`, `debug_dump_file`, `debug_dump_requests`, `debug_dump_max_bytes`, `state_file`, `unhandled_file` | The `conf.lua` option of the same name, below. Booleans are `1`/`0`; an empty string clears an optional one |

A custom hardware profile is the modelmap's fields as UCI sections -- one `port` section
per RJ45 socket (`idx`, then `ifname` on DSA or `swport` on swconfig), a `vlan` section
named `custom_vlan` plus one `swport` section per label→physical-port pair on swconfig,
`radio` sections named `na`/`ng` for the per-band policy, and `device 'custom'` for
`lan_cpueth`, `wan_cpueth`, `uplink_detect`, `led`, `hwassign` and `openwrt_board`. It is
checked against the same invariants every shipped profile passes (`tests/test_modelmap.lua`)
before it is used; a map that fails is refused with the reason and the service does not
start. A custom identity (`identity 'custom_identity'`: `platform`, `model`, `fw_ver` as a
bare `M.m.p.build`, `fw_buildtime`, `fw_factoryver`, `required_version`) is checked the same
way. The full section reference is the header of `uciconf.lua`.

`openuf --version`, `openuf status`, `openuf set-inform <url>`, `openuf reset-inform` and
`openuf 11k-scan` are the command line; the last three are `syswrapper.sh`'s verbs.
`openuf probe status|presets|discover|export` prints JSON: how the configuration resolved
(the profile, identity and options in use, the state with the authkey left out, the
refusal reason if there is one), the shipped presets, what the board reports about itself
(the seed for a custom profile: sockets, switch geometry, radios, LEDs and which of them
OpenWrt already drives), and the saved custom profile as a modelmap file. The LuCI app
reads nothing else, so what it shows is what the daemon would run.

### Paths and options (`openuf/conf.lua`)

```lua
config = {
    use_only_unifi_wlan = true,  -- disable non-openuf_ SSIDs during provisioning
    keep_wlan_sections  = {},    -- AP sections that option must leave alone (see below)
    unifi_ft_interop = true,     -- 802.11r with genuine UniFi APs; needs the rrb-unifi translator to do anything there, see § 6
    inform_url  = "http://unifi:8080/inform",   -- first-boot URL; state.json's wins once set
    state_file  = "/etc/openuf/state.json",     -- honoured by inform, announce and syswrapper
    l2_announce = true,          -- see below
    unhandled_file = "/etc/openuf/unhandled.json", -- ledger of what openUF ignored (see below)
    debug_dump_file = nil,       -- see below
    debug_dump_requests = false, -- with debug_dump_file: record requests and HTTP errors too
    debug_dump_max_bytes = 4194304, -- ceiling for that file; 0 = unbounded (see below)
    debug_caps = nil,            -- RESEARCH ONLY: override the claimed capability bits
    debug_payload_extra = nil,   -- RESEARCH ONLY: extra top-level payload fields
    neighbour_scan_interval = 0, -- seconds between background neighbour scans, 0 = never
    rrm_enrichment = true,       -- ask 802.11k clients to report neighbours (see below)
    rrm_request_interval = 600,  -- seconds between those requests, one client at a time
    assoc_tracker = true,        -- AirView Connectivity/Roaming reports when the controller asks
    roam_assist_diff_db = 8,     -- Roaming Assistant: dB another AP must hear a client louder
    country_override = nil,      -- see below
    bootstrap_adopt_user = nil,  -- see below
}
```

`keep_wlan_sections` — `wifi-iface` section names that `use_only_unifi_wlan` must never
switch off, e.g. `{"guest_legacy"}`. Sections whose `mode` is not `ap` (a mesh point, a
station interface) are exempt without being listed: a link is not a competing SSID, and it
may be this AP's own uplink. A listed section openUF had already switched off on an
earlier pass is switched back on. Non-AP sections are also left out of the reported
`vap_table` — they have no SSID and are not a BSS the controller can provision.

`country_override` — an ISO 3166-1 alpha-2 code programmed into the driver **instead of**
the one the controller pushes. `nil` (default) means the controller's own value is used.

It exists because the regdomain, not the hardware, decides which channels carry a DFS flag
— and DFS does not work on every driver. Measured on a JIDU6101 (MT7986/mt7915, which
cannot start CAC at all):

| Regdomain | 5 GHz channels 52–144 | 160 MHz |
|---|---|---|
| `IN`, `DE`, `US` | all `(radar detection)` | **impossible** — every block that fits overlaps DFS |
| `PA` | **no DFS flag at all** | works: `channel 44, width 160 MHz, center1 5250`, `he_oper_chwidth=2` |

The controller is still told its **own** country, not the override: openUF stamps the
controller's value per radio as `openuf_country` and `get_radio_table` reports that in
preference to the live `country`, so the site setting does not appear to have changed.
Clearing the option puts the controller's regdomain back into UCI and removes the stamp —
it never leaves a foreign regdomain programmed with nothing in the config explaining why.

> This programs a regulatory domain the device may not physically be in. Which channels may
> be used, and at what power, is a legal limit rather than a preference. That call belongs
> to whoever runs the AP, which is why the option is off unless deliberately set.

`l2_announce` — on by default; sends the UDP discovery broadcasts that make the
device appear in UniFi Discover with no `set-inform` at all. The same process
listens on UDP 10001 for the whole of its life, adopted or not, and answers the
discovery requests the UniFi app, WiFiman's Discovery tab and the Device Discovery
Tool broadcast, so they list the AP with its model, name and firmware (one reply
per asker and request type per half second). Requests sent to the discovery multicast
group `233.89.188.1` are answered too; IPv6 (`ff02::1`) requests are not, because the
listener is IPv4 only (see PROTOCOL-VALIDATION.md, "Discovery requests"). `false` turns the broadcast and the responder off together.
Set it to `false` to be adopted over L3 only, and restart the service (the init script reads this
and simply doesn't start the broadcaster). The reason to turn it off isn't
noise: a controller that discovered a device via L2 adopts it *by SSHing in*,
so on a device that can't accept that login, adoption fails while the inform
loop looks perfectly healthy — see § 4.

`unhandled_file` — **always on**, default `/etc/openuf/unhandled.json`; `false` keeps the
ledger in memory only. Everything the controller sends that no handler in openUF acts on is
recorded here: a response `_type` other than the six known ones and a `cmd` other than the
handled ones, each with its **whole body**; a top-level field of a `noop`/`setparam` nothing
reads; every `mgmt_cfg` key and every `system_cfg` key shape (indices collapsed to `<n>`) no
parser consumes, each with one sample key and its value. Every entry carries a count and
first/last seen, so the file reads as a living list of what the controller wants that openUF
does not yet do. The 2026-09-06 `mesh-halt` command survived only as one `logread` line
naming the verb; with this, its body would be on disk.

```sh
lua -e 'local c=require"cjson"; local f=io.open("/etc/openuf/unhandled.json"); local d=c.decode(f:read("*a"))
  for id,e in pairs(d.entries) do print(e.count, e.last_seen, id) end' | sort -k3
```

Bounds, because the file lives on the overlay: 150 entries (the one seen longest ago is
evicted), 2 KiB per recorded body (past that only its key list is kept), strings cut at 200
characters, and any field whose **name** looks like a secret — `psk`, `passphrase`,
`password`, `secret`, `authkey`, `token`, anything ending in `key` — is replaced by
`<redacted>` at any depth. A new entry is written at once; a repeat count only every five
minutes; both through a temp file and rename like `state.json`. The ledger is research data,
not adoption state: a factory reset and `syswrapper.sh reset-inform` leave it alone.

Most of what it lists is dropped **deliberately** (`switch.dot1x.status`, `qos.ebt.*`,
`mgmt_url`, `bridge.*` — each explained in PROTOCOL-VALIDATION.md). Its value is the entry
that was not there yesterday.

`debug_dump_file` — opt-in, off by default. When set to a path (e.g.
`"/var/log/openuf-informs.log"`), every decrypted controller inform response is
appended verbatim, with a UTC timestamp, before it's dispatched. Used to capture
ground-truth payload shapes when validating field assumptions (`system_cfg`,
`cmd` dispatch, etc.) against a real UniFi controller — see
[PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md).

The same flag also turns on a **dropped-key report** on stderr: one line per
config blob listing the keys no parser consumed, collapsed to key shapes with
counts, e.g.

```
inform: mgmt_cfg: 5 dropped key(s): capability x1, mgmt_url x1, report_crash x1, selfrun_guest_mode x1, stun_url x1
inform: system_cfg: 12 dropped key(s): switch.port.<n>.name x5, switch.vlan.<n>.id x4, ...
```

Most of what it lists is dropped deliberately (each case is explained in
PROTOCOL-VALIDATION.md's `system_cfg` section) — its value is showing you when
the controller starts sending something openUF has *never* seen, which is how
two whole features sat unnoticed in every capture for months. Key names and
counts only: these blobs carry passphrases and the adoption key, so no value is
ever logged.

`debug_dump_requests` — with `debug_dump_file` set, also append what openUF *sends*
(one line tagged `TX` per inform, every 10 s) and any transport failure (`ERR HTTP 400`,
`ERR connect failed: …`). Response lines keep their untagged shape, so the recipes in
REVERSE-ENGINEERING.md still work; `grep ' TX '` / `grep -v ' TX '` separates the two.

`debug_dump_max_bytes` — ceiling for that dump, default 4 MiB, `0` for none. The dump is
append-only and the inform loop writes to it every few seconds, so left unattended it
grows without bound — and its usual home is `/tmp`, which on these boards is a RAM disk
shared with `state.json` and the package manager (upstream found one left on for five
weeks at 31.7 MB, 55% of a 59 MB tmpfs). Past the cap the file **restarts** rather than
rotating, leaving a marker line saying so: a second generation would double the peak
footprint on exactly the boards least able to afford it, and a capture is read from its
tail anyway.

`debug_caps` and `debug_payload_extra` — **research switches; leave them `nil`.** The
rule everywhere else is that openUF never claims a capability bit it cannot honour,
because a claimed bit makes the controller push config and show UI for a feature that
then silently does nothing. These are the deliberate exception, for protocol
experiments (REVERSE-ENGINEERING.md's mesh plan): `debug_caps = {fw_caps = …,
wifi_caps = …, wifi_caps2 = …}` replaces the masks the payload claims (a mask left out
keeps its shipped value; `wifi_caps` is not sent at all unless overridden), and
`debug_payload_extra = {uplink = {…}}` merges extra top-level fields into every
payload verbatim. The daemon shouts at startup while either is set.

`neighbour_scan_interval` — seconds between `iw dev <if> scan` on each radio; `0` Every sweep openUF runs — this one, the controller's nightly `11k-scan`, an Airtime or Quick Scan — goes in four-channel chunks, one per heartbeat, so the radio is never silent for more than ~0.5 s; `logread | grep swept` shows the chunks. A sweep of both radios takes about eleven heartbeats, and one still running is not started over, so an interval shorter than that (AP2 had 90) just means back-to-back sweeps.
(default) never scans. The Environment view is fed from the kernel's cached BSS list,
which forgets a network about 30 s after it was last seen, and the controller drops
anything with `age >= 30` on top — and nothing else in openUF scans, so after the
boot-time ACS sweep the list drains to empty. A scan takes the radio off-channel for a
moment (clients see a brief stall), which is why it is off unless you turn it on; `300`
is a sane value. The first scan happens one interval after start, never at boot.

`roam_assist_diff_db` — Roaming Assistant's margin: how many dB louder another AP must hear
a weak client before openUF moves it there (default 8). The threshold itself is the
controller's per-WLAN setting; see § 6.

`rrm_enrichment` / `rrm_request_interval` — client-assisted neighbour discovery, adopted
from upstream. Every `rrm_request_interval` seconds (default 600; upstream moved to 3600
because hostapd logs every report it receives as ~15 hex lines and at 600 s they filled
most of their logread -- this tree keeps the view fresh and accepts the log, the option is
the knob) openUF asks **one**
802.11k-capable client for an active beacon measurement: the *client* leaves the channel,
sweeps, and reports what it saw, while the AP keeps serving. This is the mechanism
Ubiquiti's Channel AI describes as *"neighbor reports and automated RRM scans"*, and the
no-cost complement to `neighbour_scan_interval` above. One answer returned 15 BSSes across
both bands upstream, and a client on 5 GHz routinely reports 2.4 GHz too. Only clients
advertising active or passive beacon measurement are asked (beacon-table-only clients
acknowledge and never answer); a minority of clients qualify, so this supplements the
passive cache rather than replacing it. Two refinements over upstream's version, both from
the first live run on AP2: the operating class follows the band the client is on (81 for a
2.4 GHz client, 115 for 5 GHz — a 2.4-only client answers a 5 GHz class with "incapable"),
and a client that advertises the capability but never produces a report is benched after
two unanswered requests for six hours, with one log line saying so, instead of being asked
forever. Rows sourced this way show a blank WiFi Name and
Security, because a beacon report carries neither — openUF will not invent a security mode
it did not measure. See § 6 for how to watch it work. `false` never sends a request, and
also tears down the background collector (a detached `ubus subscribe hostapd.*` child that
spools reports into `/tmp/openuf-rrm.jsonl`) on the next cycle — as does
`/etc/init.d/openuf stop`. That matters because the child is reparented to init and outlives
the daemon, and `harvest()` is the only thing that ever truncates its spool on a RAM-disk
`/tmp`; if you ever find it running with openUF stopped (`pgrep -f 'ubus subscribe
hostapd'`), `pkill -f 'ubus subscribe hostapd'` and delete the file. An *absent* key means
on, so a `conf.lua` kept across an upgrade (see § 2) picks the feature up without an edit.
The other new options default to off when absent.

`bootstrap_adopt_user` — set by `install.sh install --bootstrap-adopt`, not by
hand. Names the temporary SSH bootstrap account (see § SSH prerequisite below)
that `inform.lua` should lock/unlock as the device's adopted state changes.

### Plugins

A plugin lets a recipe that openUF does not ship, typically one that needs extra software on the
AP, edit the UCI options of the WLANs openUF provisions. It lives in its own project; openUF only
offers the hook. **Third-party plugins are unsupported by openUF, and a plugin is Lua running as
root**: list only code you have read.

Off by default. A plugin is `/etc/openuf/plugins/<name>.lua`, loaded only when named in
`config.plugins` (`conf.lua`) or on a line of `/etc/openuf/plugins.enabled` (the file an installer
should edit). A changed plugin set or plugin file makes openUF ask the controller for a fresh push
at the next start; Force Provision does the same at once. Failures are logged
(`logread | grep "openuf: plugin"`) and skipped, and the push goes on. The contract, the `ctx`
reference, uninstall order, versioning and testing are in [docs/PLUGINS.md](docs/PLUGINS.md).

---

## 4. Adoption flow

### SSH prerequisite

The controller SSHes into the device as `root` to run `syswrapper.sh set-adopt` during adoption.  **SSH must be accessible and the root password must be set** before clicking Adopt:

```sh
# On the OpenWrt device — set a root password if not already done
passwd root
```

Confirm SSH works from the controller's network before attempting adoption.  A fresh OpenWrt install often has a blank root password and SSH enabled; set the password first.

> **Security note:** openUF accepts a new `authkey` from the `mgmt_cfg` payload
> only while **not yet adopted** (needed for L3 adoption to complete at all — see
> the L3 section below and [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md)).
> Once adopted, that field is ignored — key rotation only happens via the SSH
> `set-adopt` path from that point on, matching real L2 hardware behavior.

#### Optional: zero-touch bootstrap adoption (`--bootstrap-adopt`)

Real Ubiquiti hardware ships a factory-default `ubnt`/`ubnt` SSH account
specifically so first adoption works without presetting anything — live testing
against a real controller (see PROTOCOL-VALIDATION.md) confirmed the controller's
SSH client tries exactly that account for L2-discovered, not-yet-adopted devices,
regardless of any admin-configured "Device SSH Authentication" credentials.
`install.sh install --bootstrap-adopt` sets up the same thing, scoped as tightly
as this project can manage:

```sh
sh install.sh install --bootstrap-adopt
```

- The account is **non-root**, a member of a dedicated `openuf` group with
  write access to `/etc/openuf` only — no other privilege, ever, even
  transiently.
- Its login shell (`openuf/hook/adopt-shell.sh`) is a forced-command wrapper
  that permits exactly one thing: running `syswrapper.sh set-adopt <url>
  <key>`. Any other command, or a plain interactive login attempt, is refused
  outright — the account can never be used as a general-purpose shell.
- That shell is also listed in `/etc/shells`. dropbear checks a login's shell
  against that file (`getusershell(3)`) before it looks at the password, and
  OpenWrt ships the file with `/bin/ash` alone — an unlisted shell is `User
  'ubnt' has invalid shell, rejected` in `logread`, the controller's SSH
  attempts fail, and the mobile app asks for the root credentials instead
  ("advanced adoption"). An account created before 2026-10-25 lacks the entry;
  `openuf bootstrap-account` (package install) or `sh install.sh install
  --bootstrap-adopt` (file install) adds it to an existing account.
- Once the device is adopted, `inform.lua` locks the account (`passwd -l`) —
  it detects this within one poll interval (~10s) of the SSH-driven
  `set-adopt` writing new state. It re-enables the account automatically on
  a factory reset (`reset-inform`, or a controller-initiated "Forget Device"),
  so re-adoption after a reset works the same zero-touch way.
- This is entirely opt-in: a plain `install.sh install` (no flag) never
  creates this account and behaves exactly as documented above — the admin
  sets their own root password.

`uninstall` always removes the bootstrap account if present, regardless of
whether `--bootstrap-adopt` is passed to it.

### L2 adoption (device and controller on the same subnet)

1. Start openUF (`/etc/init.d/openuf start` or `sh install.sh install`)
2. The `announce.lua` process sends UDP broadcasts to port 10001 every 10 seconds
3. The device appears in **UniFi Discover** with model "U6IW"
4. Click **Adopt** in the controller
5. The controller SSHes into the device and runs:
   ```sh
   syswrapper.sh set-adopt http://<controller>:8080/inform <32-char-hex-key>
   ```
6. `syswrapper.lua` stores the new authkey and sets `adopted = true` in `/etc/openuf/state.json`
7. The device appears as **Connected** in the controller

> **The controller picks the adoption path from how it discovered the device,
> not from where it is.** A device it heard via L2 broadcast gets the SSH
> treatment above even when it sits on the controller's own subnet and informs
> perfectly — confirmed against a real UniFi OS gateway, which SSHed in three
> times on the Adopt click, failed (`Login attempt for nonexistent user`), and
> parked the device at **Connection Interrupted** while the inform loop kept
> running normally. If SSH can't succeed on your device, set
> `config.l2_announce = false` in `conf.lua` and restart: with no broadcasts the
> controller treats it as L3-discovered and delivers the key over the inform
> channel instead. Forget any device record created while broadcasts were on
> first — the controller remembers how it found it.

### L3 adoption (device and controller on different subnets)

1. Manually point the device at the controller:
   ```sh
   syswrapper.sh set-inform http://<controller-ip>:8080/inform
   ```
2. The device starts sending inform packets to the controller
3. It appears as **Pending** in the controller
4. Click **Adopt**

> **No SSH is involved in L3 adoption.** For **L3-discovered** devices the
> controller explicitly logs `discovered via L3 inform, skip SSH adoption` and
> never attempts SSH at all — unlike the L2 flow documented above. It delivers
> the new `authkey` directly in the `mgmt_cfg` field of the `setparam` response
> sent right after the Adopt click — confirmed against a real controller
> (`linuxserver/unifi-network-application:10.4.57`), reproduced from a clean
> environment. openUF's `inform.lua` accepts this only while unadopted, matching
> `amd989/unifi-gateway`'s reference behavior. Adoption completes to
> **Connected** — provided the device can encrypt with AES-GCM (see § 1). An
> earlier version of this guide reported every newly-adopted device getting stuck
> at "Adopting"; that was the missing GCM backend, not a controller-side issue,
> and it is resolved — see [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md).

---

## 5. State file

Persistent state is stored at `/etc/openuf/state.json`:

```json
{
  "adopted":    false,
  "authkey":    "ba86f2bbe107c7c57eb5f2690775c712",
  "cfgversion": "",
  "inform_url": "http://unifi:8080/inform",
  "use_gcm":    false,
  "upgrade_requested_version": "",
  "upgrade_requested_url":     "",
  "blocked_stas": []
}
```

| Field | Description |
|---|---|
| `adopted` | `true` after successful adoption; `false` resets `authkey` to default on load |
| `authkey` | 32 hex chars (16-byte AES-128 key); default = pre-adoption key |
| `cfgversion` | Opaque string the controller uses to push config updates |
| `upgrade_requested_version` / `upgrade_requested_url` | Set when the controller sends an `upgrade` command; stored for visibility only — openUF never downloads or flashes firmware (see below) |
| `inform_url` | URL for the inform heartbeat (every 10 s, or the interval the controller's `noop` names). Seeded from `conf.lua` on a first boot (or after a factory reset) and overwritten by the controller or by `syswrapper.sh set-inform`; once present here it always wins over `conf.lua` |
| `use_gcm` | `true` when the controller has requested AES-128-GCM encryption (`use_aes_gcm=true` in mgmt_cfg) |
| `blocked_stas` | MACs blocked from the controller's Clients view; re-applied to nftables on startup so blocks survive restarts |
| `mac` | The identity MAC the previous run informed under (read off `lan_cpueth` at startup). Compared against the live one on the next start: a difference on an adopted device is the HTTP-400-forever condition, and is shouted about |
| `locating`, `led_enabled` | The controller's Locate and Manage → LED state, so a restart does not forget them |
| `swvlan_backup` | Original `ports` strings of the stock `switch_vlan` sections, snapshotted before per-port VLAN assignment first modifies them; used to restore them (see § 6) |

The sibling file `/etc/openuf/unhandled.json` is **not** state: it is the ledger of protocol
surfaces openUF received and ignored (§ 3, `unhandled_file`). Deleting it loses history and
nothing else.
| `ip_mode`, `static_ip`, `static_netmask`, `static_gateway`, `static_dns` | The last "IP Settings" push. `ip_mode` is `"static"` or `"dhcp"`; the `static_*` fields are set only in static mode and cleared on a revert to DHCP. `static_dns` is an array in the controller's primary/secondary order, written to `/etc/resolv.conf`. On DHCP, DNS is left to the lease and openUF does not touch `resolv.conf`. In static mode these are **re-applied on every start**, because the address is `ip addr` state that a reboot discards and the controller does not re-push it (a matching `cfgversion` gets a `noop` back, carrying no `system_cfg` at all) — the same reason `blocked_stas` and `led_enabled` are reconciled at startup |

Every field `state.save` writes is read back by `state.load` (the eight in the JSON
above are type-checked and fall back to a default; anything else round-trips as-is). The
file is written through a sibling temp file and renamed into place, so a power cut
mid-write leaves the old file rather than a truncated one — and a truncated file would
be read as "defaults", which un-adopts the device. A non-empty file that does not parse
is reported on stderr for the same reason.

To reset to factory defaults:
```sh
syswrapper.sh reset-inform
```

---

## 6. WiFi provisioning

When the controller pushes a config, `ucihelper.lua` applies it via OpenWrt UCI.  Only sections prefixed with `openuf_` are created or deleted.

> **The `openuf_` prefix is a UCI *section name*, not an SSID filter.**  Every WLAN the
> controller pushes is provisioned, whatever it is called: the section is named
> `openuf_<radio>_<sanitized ssid>` while the broadcast SSID is exactly what the controller
> sent.  The prefix exists so openUF can tell its own sections from yours and never rewrite
> or delete a hand-made one — it does not mean openUF only picks up controller WLANs whose
> name starts with `openuf_`, and there is no way to ask it to.  What *is* configurable is
> whether your hand-made SSIDs keep broadcasting, which is `use_only_unifi_wlan` below.

`use_only_unifi_wlan` (default `true`) additionally sets `disabled=1` on every *other* AP-mode `wifi-iface`, so the radios carry only what the controller provisioned.  openUF stamps each SSID it turns off with `openuf_autodisabled=1`; setting the option back to `false` re-enables exactly those and leaves everything else as-is, so an SSID you had disabled yourself is never switched back on.  Set it to `false` from the start to keep hand-configured SSIDs broadcasting alongside the controller's, or list the ones to keep in `keep_wlan_sections` (§ 3).  Sections whose `mode` is not `ap` — a mesh point or a station interface, i.e. a wireless backhaul — are never touched either way, and are not reported as VAPs.

Settings carried through from the controller:

| Controller setting | Applied as |
|---|---|
| SSID, passphrase, security | `wifi-iface` ssid/key/encryption |
| Hide WiFi Name | `hidden` (hostapd `ignore_broadcast_ssid`) |
| MAC Address Filter | `macfilter` (`disable`/`allow`/`deny`) + `maclist` |
| WiFi Speed Limit | `tc` shaping **per client**, not a hostapd option and not per SSID (the UniFi firmware's `config_sta_qosrule`, upstream's reading, adopted 2026-10-18). `openuf_ratelimit_down`/`openuf_ratelimit_up` on the section are the persisted record; every heartbeat `inform._shaper_resync` hands the stations each netdev lists, the WLAN's limits and the controller's per-client `rate-update` overrides to `shaper.sync`, which adds or removes one HTB class per station (download on the VAP, upload on an IFB device). Needs `kmod-ifb`, else the upload half is policed |
| WPA2 / WPA3 / WPA2-WPA3 mixed | `encryption=psk2`/`sae`/`sae-mixed`, from the pushed AKM set **plus** `wpa3.transition` — SAE replaces WPA-PSK on the wire, so the AKM alone cannot tell mixed from WPA3-only. Depends on openUF advertising `radio_caps2` bit `0x1` |
| SAE tuning | `sae.anti_clogging` → `sae_anti_clogging_threshold`, `sae.sync` → `sae_sync` (both as `hostapd_bss_options` raw lines), `sae.groups` → `sae_groups`; only on `sae`/`sae-mixed`. Needs the ucode wifi generator (24.10+). The controller sets them over REST only (`sae_anti_clogging`, `sae_sync`, `sae_groups`) |
| Enhanced Open (OWE) | `encryption=owe`, from `wpa.key.1.mgmt=OWE` with no `aaa.<n>.wpa`. **Transition mode** arrives as two VAPs per radio with the same SSID (open + hidden OWE, linked by `owe_devname`). openUF writes them as one section with `owe_transition=1`, and OpenWrt's ucode generator (24.10+) builds both BSSes from it, naming the hidden one `<ssid>OWE`. Depends on openUF advertising `radio_caps2` bit `0x8`, which it does when `hostapd -vowe` passes |
| Private Pre-Shared Keys | One `wifi-station` section per key (`openuf_<vap>_psk<k>`: `iface` = the VAP's section, `mac` = `00:00:00:00:00:00`, `key`, `vid` unless the key's network is VLAN 1) and one `wifi-vlan` per VLAN (`openuf_<vap>_vlan<vid>`: `name`/`vid` = the VLAN id, `network` = `openuf_vlan<vid>`), plus `dynamic_vlan=1` on the VAP, from `aaa.<n>.wpa.psk_file.<k>.psk`/`.vlanid`. OpenWrt turns them into hostapd's `wpa_psk_file` and `vlan_file`; the client's netdev is `<vap ifname>-<vid>`. The WLAN's own `wpa.psk` (a random passphrase the controller generates) stays the section's `key`. Needs a hostapd with VLAN support (the full `wpad-*` builds have it) and a `lan_cpueth` to build the VLANs on. `psk_radius=2` (keys from RADIUS only) skips the WLAN. The controller's `sae_psk` list (`sae.psk.<n>.psk/.mac/.vlan/.id`) feeds the same sections: with a `mac` the `wifi-station` carries that MAC instead of `00:00:00:00:00:00`; the `ff:ff:ff:ff:ff:ff` entry is the WLAN's own key and is skipped; a key also sent as `psk_file` is created once |
| MAC-based VLANs ("Virtual Network Override") | `aaa.<n>.accept_mac.<k>.{mac,vlanid}` → one `<mac> <vlanid>` line of a hostapd **accept-MAC list**, plus a `wifi-vlan` section per VLAN (`openuf_<vap>_vlan<vid>`, shared with the private-pre-shared-key path) and `dynamic_vlan=1` on the VAP so OpenWrt emits `vlan_no_bridge`. The list is openUF's own file, `/etc/openuf/macvlan-<wifi-iface section>`, rebuilt on every push and removed when the WLAN has no overrides. How it reaches hostapd depends on the WLAN's MAC Address Filter: with **no filter** a raw `accept_mac_file=` line (no `macaddr_acl`, so unlisted clients still join); with **`macfilter=allow`** the schema's `macfile` option, with those addresses dropped from `maclist` so each appears once, and any override the allow list does not permit skipped; with **`macfilter=deny`** the raw line minus any address on the deny list. `accept_mac.status` is not read: the entries are the whole signal. Needs `fw_caps 0x80000000` (claimed) plus the site-wide quorum below, and a `lan_cpueth` to build the VLANs on |
| WPA-Enterprise (802.1X / RADIUS) | ⚠️ Wire → UCI → the device's own hostapd generator confirmed; **no client has authenticated yet**. The controller does push the servers (`aaa.<n>.radius.{auth,acct}.<k>.{ip,port,secret}`, `interim_update.*`, `dynamic_vlan`, `nas_identifier`) — an earlier release skipped such WLANs on the belief that it did not. WPA2, WPA3, WPA2/WPA3-transition and 192-bit Enterprise all map to an encryption the OpenWrt generator turns into `wpa_key_mgmt=WPA-EAP`/`-SHA256`/`-SUITE-B-192`, and 802.11r adds FT-EAP for free. The dummy `wpa.psk` the controller still sends on an EAP WLAN is dropped, so the BSS never carries a passphrase. **Trades**: on an 802.11r WLAN the controller NAS-ID is dropped and RADIUS sees the BSSID as NAS-Identifier (hostapd uses the NAS-ID as the FT R0KH-ID, and one shared by every AP breaks FT-EAP roams); one port and one shared secret per server list (OpenWrt's schema has no per-server pair — a server that differs is dropped with a log); RadSec/TLS servers are dropped rather than contacted in the clear; DAS/CoA and RADIUS MAC auth are not implemented; and with "RADIUS assigned VLAN: required" openUF writes `dynamic_vlan=2` but no VLAN map, so hostapd refuses a station whose assigned VLAN this AP has no network for — failing closed rather than putting it on the wrong network. A basic `wpad` has no RADIUS client; openUF logs a warning and provisions anyway, since the controller applies no capability gate |
| RADIUS MAC authentication / Dynamic Authorization | `aaa.<n>.radius.macacl.status=enabled` → a raw `macaddr_acl=2` line, plus the same `radius.auth.<k>.*` servers as above — written as raw `auth_server_addr`/`auth_server_port`/`auth_server_shared_secret` lines on an open, PSK or SAE WLAN, where the generator never emits the UCI options. `aaa.<n>.radius.das.{client,secret}` → one `radius_das_client=<ip> <secret>`, `das.port` → `radius_das_port` (the controller uses 3800 + the WLAN index). Declined: `macacl.format`, `macacl.emptypassword` (UniFi hostapd patches, absent from OpenWrt's binary) and the whole `radius.dad.*` shape (it relays through the AP's own daemon from `127.0.0.1`). A WLAN that needs MAC authentication and cannot have it is skipped, not provisioned without it |
| Hotspot 2.0 / Passpoint | From the WLAN's embedded `hotspot2` object, pushed as `aaa.<n>.hs20.*`. Scalars become real wifi-iface options: `iw_enabled=1` (the generator's `iface_interworking()` gate, which emits `interworking=1`), `hs20=1`, `access_network_type`, `internet`/`asra`/`uesa` as 1/0, `venue_group`, `venue_type`, `disable_dgaf`, `hs20_deauth_req_timeout`, and `metrics.*` joined into one `hs20_wan_metrics` value (`<WAN info in hex>:<dl speed>:<ul speed>:<dl load>:<ul load>:<measurement>`). Every **cumulative** list is written as a raw `hostapd_bss_options` line instead: `ipaddr_type_availability`, `domain_name`, `venue_name=<lang>:<name>`, `venue_url=<i>:<url>`, `nai_realm=<encoding>,<realm>,<eap>[<id>:<val>]…`, `roaming_consortium=<oi>`, `anqp_3gpp_cell_net=<mcc>,<mnc>;…` (one line, semicolon-separated), `hs20_oper_friendly_name=<lang>:<text>`, `hs20_conn_capab=<proto>:<port>:<status>`. Needs `fw_caps` `0x800000` **and** `fw2_caps` `0x80000`; see the narrowings below |
| PMF (802.11w) | `ieee80211w` (0 disabled / 1 optional / 2 required) |
| Fast Roaming (802.11r) | `ieee80211r`. The controller carries **two** toggles — `ft.status` for the WLAN and `wpa3.ft.status` for the SAE akm alone (SAE pushes only). OpenWrt has one switch feeding hostapd's `key_mgmt`, and on `sae-mixed` it yields FT-PSK *and* FT-SAE together, so FT is enabled if **either** asks for it and a disagreement is logged. Both keys arrive `disabled` on a WPA3-only WLAN unless openUF advertises `radio_caps2` bit `0x2`, which it does wherever it advertises `0x1` |
| BSS Transition (802.11v) | `bss_transition` — **needs a full `wpad` build** |
| Band Steering | `usteer` config, not a hostapd option. On when any WLAN's Band Steering is on, or the AP's own setting is Prefer 5G. `usteer.local.band_steering_interval` is `0` when off and unset (the daemon's default) when on; `openuf_active` on the same section records whether openUF last started or stopped the daemon |
| Airtime Fairness (device panel) | Not UCI: `/sys/kernel/debug/ieee80211/phy*/airtime_flags`, `3` (TX+RX, the kernel default) for on and `0` for off, from `atf.mode`. Kept as `atf_enabled` in `state.json` and rewritten at every start, because debugfs resets to `3` on reboot. Forgetting the device puts `3` back. Depends on openUF advertising `wifi_caps` bit `0x20`, which it does when that debugfs file exists |
| Roaming Assistant (per WLAN, 5 GHz) | `openuf_roam_assist=<dBm>` on the 5 GHz section (openUF's own marker, absent when off); enforced by openUF over hostapd's ubus, not by a hostapd option — see below |
| Auto/Custom DTIM Period | `dtim_period` |
| Key caching (`auth_cache`, REST only, default **on**) | `okc` (`0`/`1`). Sent only on a WPA-Enterprise WLAN; a PSK WLAN's push carries no `auth_cache`, so nothing is written there and OpenWrt's own default applies (on for sae/owe and for FT). `disable_pmksa_caching` is not in the 25.12 schema, so an explicit `okc=0` is the whole of "off" that is available |
| TDLS (`tdls_prohibit`, REST only) | `tdls_prohibit` (`0`/`1`), 1:1. On every WLAN's push, so this always writes |
| Country IE / 802.11d (`country_beacon`, REST only) | per-**radio** `ieee80211d` (`0`/`1`). The wire key is per WLAN; `ieee80211d` is a wifi-device option, so openUF turns it on for a radio if **any** WLAN on that radio asks for it. A radio no WLAN carried the key for is left alone. It only reaches hostapd once a regulatory domain is set: the generator drops it otherwise, which is also what keeps hostapd from treating it as fatal. **On a 5 GHz radio "off" is ignored and `ieee80211d=1` is written anyway**: OpenWrt emits `ieee80211h=1` for every 5 GHz radio with a country, and hostapd refuses the whole interface with *"Cannot enable IEEE 802.11h without IEEE 802.11d enabled"* (`hostapd.add_iface failed` in `logread`, a radio with no SSID). openUF logs `Country IE off is not applicable on 5 GHz` once when it overrides. A radio whose band cannot be determined is treated as 5 GHz, for the same reason |
| Pairwise cipher (`wpa.1.pairwise`, from wlanconf `wpa_enc`, REST only) | the second token of `encryption`: `psk2+gcmp`, `psk2+ccmp256`, `sae+gcmp`, … `CCMP` (the controller's `auto` and `ccmp`) writes no suffix, since it is the generator's own default; `gcmp-256` never arrives, the controller refuses it. **Gated on the radio's cipher suites**, read over `ucode -l nl80211` (`iw` 6.17 prints none): a cipher the phy does not report keeps the default and logs `controller asked for pairwise cipher … -- keeping …`, because hostapd treats an unprogrammable cipher as fatal and the WLAN would never come up. Where two radios serve one band the band's set is the intersection; an unknown probe never vetoes. OWE is left alone |
| Multicast Enhancement | `multicast_to_unicast` |
| Minimum Data Rate | per-**radio** `basic_rate` / `supported_rates` / `legacy_rates` / `beacon_rate` |
| Multicast Suppression | nftables rules, not a hostapd option. `openuf_bcfilt`, `openuf_bcfilt_macs`, `openuf_bcfilt_bypass` and `openuf_mcast_suppress` on the section are the persisted record: the ruleset dies with a reboot, so openUF rebuilds it from those four options on every start |
| Proxy ARP | `proxy_arp` — **needs a full `wpad` build** |
| Client Isolation | `isolate` (hostapd `ap_isolate`) |
| Network / VLAN assignment | a per-VLAN bridge (`br-openuf<id>`) holding the tagged uplink sub-device (`eth1.<id>`), which the VAP joins — plus a `switch_vlan` trunk on swconfig boards. See below |
| Channel, TX power | `wifi-device` channel/txpower; the controller's **Auto** channel is written as the literal `channel=auto`, engaging hostapd ACS (the AP surveys the band at radio bring-up and picks the least-busy channel). **Auto** TX power *deletes* the `txpower` option (UCI has no auto value; absent = driver default/max), so reverting from a fixed dBm actually takes effect |
| Radio enable/disable (TX Power → Disabled) | `wifi-device` `disabled`; the radio's WLANs get `wifi-iface` `disabled` too, keeping their config for a later re-enable |
| Channel width | `wifi-device` htmode, from the radio's `ieee_mode` token, **clamped to what the radio can actually do** — see below |
| IoT Optimization: Lock 2.4 GHz to Channel 6 | nothing new — arrives as `channel=6` on the 2.4 GHz radio |
| IoT Optimization: DTIM Interval Lock | nothing new — arrives as `dtim_period=3` on the 2.4 GHz SSID |
| IoT Optimization: Force WiFi 4 Mode | `bss_load_update_period=0` (suppresses the QBSS Load IE) + an `openuf_iot` marker |
| Minimum RSSI | per-**radio**. Two halves since 2026-10-18 (the firmware's): hostapd refuses probes and authentication at threshold + 3 dB (`rssi_reject_assoc_rssi`/`rssi_ignore_probe_request`, stamped `openuf_minrssi`), and openUF kicks a client only after 30 s below the threshold on the driver's averaged signal |
| Per-port VLAN (Ports → *port* → Native VLAN) | swconfig `switch_vlan` sections named `openuf_swvlan<id>` — see below |

**Channel width is clamped to the hardware.** openUF presents itself as a
U6-InWall (802.11ax) whatever the host radios really are, so a controller will
happily push `ieee_mode=11nahe80` at an 802.11n/ac radio. Written to UCI
verbatim that produces a config file that looks perfectly correct and a hostapd
that refuses to start — no SSID on the air, and nothing in the config to explain
why. openUF therefore probes `iw phy` for each band's real PHY and maximum
width and clamps the request **downward only** (`HE80` → `VHT80` on an ac
radio, `HE40` → `HT40` on an n-only 2.4 GHz radio); a request the hardware can
already satisfy is never touched, and every clamp is logged:

```
openuf: radio0: controller asked for htmode HE80, hardware supports VHT80 -- clamped
```

If `iw` is unavailable or its output can't be parsed, the controller's value is
written through unchanged rather than clamped to a guess. The same probe supplies
each radio's real `max_txpower` (the ceiling the controller's TX Power slider
uses) instead of a static default.

> **SSID punctuation is sanitized into the UCI section name.** A UCI section name may
> contain only `[A-Za-z0-9_]`, so an SSID of `Guest-WiFi` becomes a section named
> `openuf_radio0_Guest_WiFi_<hash>` — the SSID *itself* is stored and broadcast unchanged,
> and the short hash of the original name keeps `Guest-WiFi`, `Guest WiFi` and `Guest_WiFi`
> as three distinct sections. This matters because libuci enforces the rule **silently**:
> `set()` returns true, `commit()` returns true, and a section whose name contains anything
> else is discarded before it reaches `/etc/config`. openUF's sanitizer used to keep `-`,
> so an SSID with a hyphen cost the entire WLAN with nothing logged anywhere (found by
> upstream, live, with an SSID of `openuf-verify`).

**WPA-Enterprise: two narrowings worth knowing before you enable it.** Both are
limits of what the UCI schema can express, not of the RADIUS config the
controller sends.

- **One port and one shared secret per server list.** OpenWrt's generator writes
  `auth_server_port`/`auth_server_shared_secret` once and reuses them for every
  address in `auth_server_addr`, so two servers that differ in either cannot be
  expressed. openUF takes the port and secret from the **first** server, puts
  every later server that agrees into the list, and drops the rest with a log
  line naming the index (never the secret). Same for accounting. A RadSec/TLS
  server is dropped too: the controller sends only the *filenames* of
  certificates it transfers by another channel, so the server cannot be
  completed, and treating it as plain RADIUS would put the shared secret on the
  wire in the clear. There is no `radius.*.tls` key to key that on — the
  controller never sends one; the presence of
  `radius.<kind>.<k>.{ca_cert,client_cert,private_key}` is the whole
  discriminator, and those filenames only arrive at all because openUF claims
  `fw2_caps` `0x80000` for Hotspot 2.0 (see that row). A WLAN whose every auth server is dropped is
  skipped loudly rather than brought up as a BSS nobody can join.
- **A RADIUS-assigned VLAN only works for VLANs this AP already has.** openUF
  passes the profile's mode through as `dynamic_vlan` (1 optional / 2 required)
  but writes no `wifi-vlan` section for it — the push enumerates no VLANs, so
  there is nothing to build them from. hostapd's VLAN map therefore holds only
  the VLANs the WLAN itself or a private pre-shared key brought. With
  "RADIUS assigned VLAN: required" a station assigned anything else is refused.
  That is deliberate: failing closed beats putting the client on the wrong
  network, past the segmentation the setting exists for.

Not implemented, and silently ignored rather than half-applied: RadSec
certificates. DAS/CoA and RADIUS MAC authentication were in this list until
2026-10-27; they have their own section below.

### RADIUS MAC authentication and Dynamic Authorization (CoA / Disconnect)

Two settings of the same RADIUS profile, both implemented since 2026-10-27, and
neither limited to a WPA-Enterprise WLAN.

| Controller setting | Wire keys | UCI / hostapd |
|---|---|---|
| WLAN → Security → **MAC Authentication** | `aaa.<n>.radius.macacl.status` plus the full `aaa.<n>.radius.auth.<k>.*` block | `macaddr_acl=2`, and the auth servers (see below) |
| RADIUS profile → **RADIUS DAS** (needs accounting on) | `aaa.<n>.radius.das.{status,port,client,secret}` | `radius_das_port`, `radius_das_client=<ip> <secret>` |

- **MAC authentication is not a security type.** The controller offers it on an
  open or WPA-PSK WLAN just as readily as an Enterprise one, puts no capability
  gate on it, and sends `radius.macacl.status` on **every** WLAN — the value is
  the whole discriminator. With it on, the same RADIUS server block an
  Enterprise WLAN gets arrives on that open WLAN, and hostapd's `macaddr_acl=2`
  makes the AP ask the server whether a MAC may associate before it may.
- **The servers go in as raw hostapd lines on a non-Enterprise WLAN.** OpenWrt's
  generator calls `iface_authentication_server()` only from its EAP branch, so
  on an open, PSK or SAE BSS the `auth_server_*` UCI options are stored and
  never reach hostapd. openUF writes them through `hostapd_bss_options` there,
  repeating the port and secret after each address exactly as the generator
  does. Accounting is unaffected: `iface_accounting_server()` runs for every
  auth type, so `acct_server_*` stays an ordinary option.
- **It fails closed.** A WLAN that asks for MAC authentication and cannot have
  it is **not provisioned**: the log says `skipping WLAN "<ssid>" -- it requires
  RADIUS MAC authentication, and ...`, naming either the RADIUS problem or a
  `wpad` with no RADIUS client. An open WLAN brought up without its MAC ACL
  would admit everyone the setting exists to screen, so a missing WLAN an admin
  can see beats a silently open one.
- **The MAC *formatting* keys are declined.** `radius.macacl.format` is a printf
  format string (`%.2X-%.2X-%.2X-%.2X-%.2X-%.2X` for "hyphen upper") and
  `radius.macacl.emptypassword` a flag; UAP firmware turns them into
  `macaddr_format=` and `mac_acl_empty_passwd=`, options of UniFi's own patched
  hostapd. Neither string exists in OpenWrt's hostapd binary on either AP, which
  sends the MAC as twelve lower-case hex digits with no separators
  (`00005e005301`, seen in a FreeRADIUS log, 2026-10-29) as both User-Name and
  User-Password. **A RADIUS server configured for another format will reject the
  client**: list the MACs in that form on the server, or add
  that form to the server's user list.
- **Dynamic Authorization needs a capability claim, and hostapd is the
  listener.** openUF claims `fw_caps` `0x100000`; the controller then adds the
  `das.*` keys to every WLAN whose profile has accounting on and which has
  "RADIUS DAS" or Hotspot 2.0 enabled, one UDP port per WLAN (3800 + its
  index). hostapd's own `radius_das_client` holds the address **and** the shared
  secret on one line, so openUF joins them; writing the schema's
  `radius_das_secret` instead would be dropped on a non-EAP BSS (the generator
  joins it only in its EAP branch) and hostapd then refuses the whole config
  with `invalid DAS client` — the BSS would not come up at all.
- **The `radius.dad.*` shape is declined.** The controller sends CoA twice over:
  `dad.*` carries a per-client CIDR and expects the AP's own daemon to check it
  and relay the request from `127.0.0.1` (which is literally what UAP firmware
  writes as the DAS client). openUF has no such relay, so pointing hostapd at
  localhost would make it answer nobody; only the `das.*` shape, which names the
  client directly, is used.
- **A RADIUS-assigned VLAN is not honoured on a MAC-authenticated WLAN.** The
  profile's `dynamic_vlan` is written only on an Enterprise WLAN. On any other,
  `2` (required) would make hostapd reject every client of a WLAN that worked a
  moment earlier, since openUF writes no VLAN map for RADIUS-assigned VLANs.

**Hotspot 2.0 / Passpoint: what openUF claims, what it drops.** A Passpoint
WLAN is a WPA-Enterprise WLAN with an ANQP/GAS profile on top, so everything in
the WPA-Enterprise section above applies first.

- **Two capability bits, one of them for a feature openUF does not have.** The
  controller's own validator computes "supports Passpoint" as "supports
  Hotspot 2.0 **and** supports RadSec", so a Passpoint WLAN is refused with
  `api.err.DevicePasspointNotSupported` unless openUF claims `fw_caps`
  `0x800000` *and* `fw2_caps` `0x80000`. openUF claims both when the local
  hostapd has the interworking options and `CONFIG_HS20`, although it
  implements no RadSec. The trade is reported here rather than hidden: the one
  thing the RadSec claim changes on the wire is that the controller starts
  sending certificate *filenames* for a RadSec RADIUS server, which is the only
  way openUF can tell such a server apart from a plaintext one — and it then
  drops it instead of sending the shared secret in the clear. Without the
  claim, that same server arrived indistinguishable from a plaintext one.
- **Lists are raw hostapd lines, not UCI lists.** The OpenWrt generator joins a
  list option's values with spaces into a single `name=a b c` line, which is
  not what any of the cumulative interworking options means, and
  `iface_interworking()` additionally overwrites `domain_name` with the joined
  `anqp_3gpp_cell_net`. openUF therefore writes those through
  `hostapd_bss_options`, which the generator appends verbatim and last.
- **Dropped individually, never silently mangled.** Any value carrying a
  control character is dropped (it would end the hostapd config line and let
  the rest be read as further options), as is a language code longer than three
  characters, a roaming-consortium OI that is not 3–15 hex bytes, an MCC that
  is not three digits, a connection-capability status that is not
  open/closed/unknown, and an incomplete WAN-metrics block (it is all or
  nothing). A disabled NAI realm, and one with no EAP method, are left out.
- **Not implemented, because the controller does not send it on a WLAN:**
  HESSID, ANQP domain id, network auth type, terms-and-conditions, GAS timings
  and QoS maps all exist in the controller's standalone Hotspot 2.0 profile
  schema but not in the subset a WLAN carries, so no key ever arrives. OSU
  (online sign-up) and Passpoint icons are not implemented either, and could
  not be: OpenWrt's hostapd has no `osu_server_uri`, `osu_ssid` or `hs20_icon`
  option at all, and icons would need files on disk the controller transfers by
  another channel. An `esr` key is read by nothing, because the generator never
  emits it.
- **Only on an EAP WLAN.** hostapd refuses a configuration with `hs20=1` and
  anything but WPA2-Enterprise/CCMP, so an hs20 block arriving on a
  PSK WLAN is dropped with a log line rather than written out into a BSS that
  would never start.

**Fast Roaming (802.11r) and the `ft_psk_generate_local` trap.** openUF sets
`ieee80211r`, a `mobility_domain` derived from the SSID (so every AP computes the same one
with no coordination) and `ft_over_ds=0` — and deliberately does **not** set
`ft_psk_generate_local`. It used to force it to `1`, which silently disabled fast roaming
for every WPA3 client: local key generation only exists for **FT-PSK**, while FT-SAE derives
its keys from the per-session SAE PMK and needs the `r0kh`/`r1kh` key holders OpenWrt only
configures when that option is `0`. Left unset, `hostapd.sh` keys it on the auth type and
derives deterministic wildcard key holders from `md5(mobility_domain/psk)`, so independent
APs sharing an SSID and passphrase agree without coordination. Upstream observed the failure
live: a station that had negotiated FT-SAE still reassociated with `auth_alg=sae` plus a full
4-way handshake, even between two BSSes on the same radio. To tell a real fast transition
apart, force one with `hostapd_cli bss_tm_req` and read the target AP's log: `auth_alg=ft`
**and no `EAPOL-4WAY-HS-COMPLETED`** is fast; `auth_alg=sae` followed by a 4-way is the
fallback.

**Fast roaming with genuine UniFi APs (`unifi_ft_interop`).** Stock hostapd and UniFi's
hostapd use the same FT key hierarchy and the same AES-SIV protected RRB payloads, but UniFi
frames RRB differently: it inserts the source and destination AP addresses (12 bytes) after
the RRB type, because it sends from the AP's Ethernet MAC rather than the BSSID
(PROTOCOL-VALIDATION.md, "802.11r with genuine UniFi APs"). openUF carries the translator
that converts between the two framings: `openuf/rrb/rrb-unifi.uc`, d-malinowski's
[rrb-unifi](https://github.com/d-malinowski/unifi-openwrt-roaming) vendored (that repository
stays the source of fixes; `openuf/rrb/README.md` lists what was changed), run as the
`openuf-rrb` service on a veth pair: hostapd's `ft_iface` is `vft0`, the daemon holds `vft1`
and the LAN bridge. Nothing on the UniFi AP is changed. The switch is **on by default for new
installations** (`unifi_ft_interop` in `conf.lua`, `option unifi_ft_interop` in
`openuf.main`, a toggle on both LuCI pages). On, every FT WLAN gets what a UniFi peer needs:

| UCI option | Off | On (default) |
|---|---|---|
| `mobility_domain` | openUF's own hash of the SSID | UniFi firmware's: first two bytes of SHA1("salt" .. SSID zero-padded to 32 bytes) |
| `ft_psk_generate_local` | unset (OpenWrt: 1 for PSK) | `0`, so the key holders below are written |
| `nasid` (R0KH-ID) | unset (hostapd's default is already the BSSID) | this BSS's BSSID without colons, written explicitly so `openuf rrb verify` can read it |
| `r0kh` / `r1kh` | wildcards keyed with `iapp_key` | one entry per UniFi peer BSS of the WLAN (learned, or listed by hand), plus the wildcards |
| `hostapd_bss_options` | unset | `ft_iface=vft0`, the translator's veth end, only while the translator is installed and enabled and the veth exists |
| `reassociation_deadline` | 3000 | OpenWrt's default |

**How the pieces fit.** The first config push that carries an FT WLAN writes the veth pair
into `/etc/config/network` (`openuf_ftveth`, a `config device` of type veth, with two
proto-none interfaces) and reloads the network, so netifd creates it at boot before the radios
come up from then on; openUF restarts the daemon after every push that put a BSS on the veth,
since the daemon derives the BSSes and the LAN bridge from the running hostapd configs when
it starts. The daemon records every UniFi BSSID it hears on the LAN
(`/var/run/openuf/rrb-peers.json`), with the WLAN's mobility domain once a roam announcement
verified with that WLAN's key names it (a UniFi AP announces every client that joins it). The
inform loop keeps those in `state.json` (`rrb_peers`) and, on an adopted AP, forgets
`cfgversion` so the controller pushes the full config again and the new peer becomes a key
holder, at most once every ten minutes. A UniFi AP's R0KH-ID is its BSSID without colons,
their firmware's convention; `openuf.rrb` can list a peer by hand
(`list peer 'bssid,r0kh-id'`) for a site where the daemon hears nothing. The daemon's other
settings are the same section: `enabled`, `ft_iface`, `peer_iface`, `lan_iface`,
`roam_announce`, `verbose`; the init script documents them. The veth goes with everything
else on Forget.

Without the translator's packages the switch costs nothing on a site with no genuine UniFi
AP: every openUF AP computes the same (UniFi-formula) mobility domain and the wildcard key
holders, so they keep roaming among themselves; FT-PSK keys are then pulled over RRB instead
of derived locally, the path FT-SAE always took. `hostapd_bss_options` is only written while
the daemon is installed, enabled and its veth exists, so hostapd is never pointed at a veth
nobody forwards. The one case to turn the switch **off** is a site with genuine UniFi APs
where the translator is switched off: with UniFi's mobility domain, clients try a fast
transition towards those APs and fall back to a full reconnect, which is slower than never
trying. Which installations get the new default: a fresh `setup.sh`/`install.sh` or a fresh
package install; an `install.sh` upgrade keeps the device's older `conf.lua`, which has no
such key, so it stays off there; a package upgrade ships the new `conf.lua` and a UCI-managed
device takes its defaults for every option `openuf.main` leaves out, so it turns on unless
`option unifi_ft_interop '0'` is set first.

From the shell: `openuf rrb status` (the service, the veth, what the daemon derives),
`openuf rrb peers` (heard and hand-listed peers), and, for a check against a UniFi AP's own
settings, `openuf rrb collect <user>@<unifi-ap>` (reads its hostapd config over SSH, only a
hash of the passphrase) followed by `openuf rrb verify`; `openuf rrb peers --write` lists the
collected BSSes by hand. The raw `hostapd_bss_options` form is deliberate even on 25.12,
which has a first-class `ft_iface` option: the translator learns a BSS's LAN bridge from the
`ft_iface=` line OpenWrt generates before the override, and 24.10 has no such option.

Troubleshooting: openUF logs `ftinterop:` lines to the system log when something is missing.
`the openuf-rrb translator service is not installed` means the init script is gone (reinstall
openUF); `ft_iface not present` means the veth is not up (`openuf rrb status`; the daemon logs
`waiting for the veth pair` until the first push with an FT WLAN); `no UniFi peer known for
this WLAN yet` means nothing has been heard on the LAN and nothing is listed, so UniFi peers
can pull keys from this AP but get none pushed; `the controller sent no iapp_key` means the
push carried no FT key (Fast Roaming off for the WLAN). Only WPA2-PSK with FT-PSK is verified
against a UniFi AP so far, and only by the translator's author (a BT Home Hub 5A against a U7
Lite); this lab has no UniFi AP. FT-SAE should take the same path but is untested. hostapd's
key-exchange socket then lives on the veth, and `rrbguard.lua`'s stale-socket check covers it
the same way.

**VLAN-tagged SSIDs** (assigning a WiFi network to a non-native network) need three
things on the AP, and openUF builds all three:

1. a tagged sub-device on the uplink — `eth1.<vlan>`;
2. a **bridge** holding it, `br-openuf<vlan>`, which the VAP joins. This is the part
   that is easy to miss: point the VAP's network at the bare sub-device instead and
   netifd brings the interface up, `ip link` shows both netdevs, hostapd starts, and a
   client associates and gets *nothing* — because the VAP and the uplink are two
   separate masterless interfaces. Everything looks healthy except `ip link`'s missing
   `master`;
3. on swconfig boards, a `switch_vlan` **trunk** so the switch passes the VID at all.
   Without it an ASIC that filters unknown VIDs drops every frame (confirmed: 100%
   packet loss on an AR8327 until the entry existed). openUF tags exactly two ports —
   the CPU port and the uplink socket, the latter found at runtime by
   `sysinfo.uplink_phys_port()`. That is the whole path a tagged SSID's frames take
   (`VAP → br-openuf<id> → eth0.<id> → CPU → uplink → gateway`); no LAN socket is on it.
   If the uplink cannot be resolved openUF leaves any existing trunk alone rather than
   guessing.

> **Why not simply tag every socket.** openUF used to, and it broke every untagged
> wired client behind an AP running a tagged SSID. On the `ar8216`/`ar8226`/`ar8229`/
> `ar8236` driver family the tag flag is **not** per (port, VLAN): `ar8xxx_sw_set_ports()`
> folds it into one global per-port bitmask (`priv->vlan_tagged`) from which
> `__ar8216_setup_port()` picks add-tag vs strip-tag *for every VLAN at once*. Tagging a
> socket into VLAN 10 therefore made it egress-tagged in VLAN 1 too, and the printer
> plugged into it went deaf while still transmitting — UCI read `1 2 3 4 0t` while the
> switch reported `0t 1t 2t 3t 4t`. The AR8327 has a real per-(port, VLAN) tag table and
> showed none of it, which is how the bug survived. A consequence worth knowing on the
> global-bitmask chips: a port cannot be untagged in VLAN 1 *and* tagged in VLAN 10, so
> running a tagged wireless VLAN necessarily leaves the **uplink** socket egress-tagged
> for VLAN 1 as well. UniFi gateways accept that, and it is confined to the one port
> facing the gateway.

> **Keep VLAN ids below the switch's VLAN table size.** netifd has no `vid` option
> (`strings /sbin/netifd` lists only `vlan` and `ports`), so a `switch_vlan` section's
> `vlan` value is *both* the table slot and the VLAN id. Small switches have small
> tables — the TL-WDR3500's AR8229 reports `vlans: 16` in `swconfig dev switch0 help` —
> and a section naming a slot the hardware lacks is skipped by netifd **silently**.
> openUF reads that size and logs the mismatch instead of writing config that will be
> ignored. Whether it actually breaks traffic depends on the ASIC: the AR8327 filters
> unknown VIDs and needs the entry, the AR8229 forwards them and the SSID works without
> one. Choosing a VLAN id under 16 keeps both boards properly configured.

Changing a network's VLAN id, or deleting the WLAN, tears the old bridge and interface
down again — only `openuf_`-prefixed sections are ever removed.

**Per-port VLAN assignment** must be switched on twice: once on the device
(Devices → *AP* → Settings → IP Settings → **Port VLAN**, which is what flips the wire's
`switch.status`/`switch.vlan.status` gates), then per port under **Ports**. Until the
device-level box is ticked the per-port VLAN controls stay greyed out and nothing reaches
the wire.

On **swconfig** boards (ath79-era) openUF writes one `config switch_vlan` section per
VLAN, named `openuf_swvlan<id>`, translating the controller's `untagged`/`tagged`/`exclude`
per-port modes into swconfig's port syntax (`1`, `1t`, omitted) with the CPU port always
tagged in.

**On a DSA board it works differently, and deliberately not via `config bridge-vlan`**
(adopted from upstream, who verified it on an AX3000T's mt7530; the JioRouter boards'
mt7531 is the same driver family). The socket assigned to VLAN 10 is moved out of `br-lan`
and into `br-openuf10` — the bridge that already holds the tagged uplink sub-device
(`br-lan.10` on the JioRouter maps, `wan.10` on the AX3000T's), and the IoT VAP if a tagged
SSID sits on the same VLAN:

```
device on lan3 --untagged--> lan3 -> br-openuf10 -> <uplink>.10 --tagged--> uplink -> gateway
```

That a wired port and a wireless client on VLAN 10 land in the *same* bridge is the point,
not a coincidence: they are one broadcast domain and the controller models them as one
network. `br-lan` keeps the uplink socket, the unassigned sockets and the AP's management
address, untouched, and nothing anywhere runs with `vlan_filtering`, so a wrong answer
cannot strand the AP. The `bridge-vlan` route was rejected because turning `vlan_filtering`
on `br-lan` means every VLAN, the management one included, must be declared exactly right
or the device is stranded — and because an 8021q device on a bridge *port* claims tagged
frames before the bridge ever sees them, so a `bridge-vlan` declaring the same VID would
receive nothing while looking correct in UCI.

Scope on DSA: **Native VLAN only.** A bridge gives a port exactly one untagged home, which
is what a Native VLAN is. A port given nothing but *tagged* VLANs is refused with a log line
rather than half-applied (the controller's default "Tagged VLAN Management: Allow All" marks
every non-native VLAN tagged — a default, not a request, and not warned about). The socket
the uplink cable is in is never moved, and when the bridge FDB cannot say which socket that
is, every port is refused. Reversibility is `st.dsa_brlan_ports`: `br-lan`'s port list as
the board shipped it, snapshotted once before the first move; unticking **Port VLAN** puts it
back verbatim. Note the off signal can be an *absence*: a device that had Port VLAN on and
then has it unticked receives a `system_cfg` with no `switch.*` keys at all rather than the
gates set to `disabled`. openUF treats that as off only while it holds a ledger, so there is
something to undo. Moving a socket between bridges is invisible to the attached host, which
keeps its old lease on the wrong subnet — bounce the port or power-cycle the device.

Three things must line up or the port is skipped rather than guessed at:

- `dev.conf.vlan` must exist in your modelmap (`cpu_lan` + a `ports` name→number map).
  Without it openUF has no idea what the physical switch ports are, and guessing strands
  the device.
- the port needs a `swport` in `dev.conf.net.ports`, naming its `dev.conf.vlan.ports` key.
- the port must not be the uplink — reassigning the uplink's VLAN would cut the device off
  the network, so that is refused outright. On a modelmap that declares sockets rather
  than netdevs, the uplink is whichever socket the default gateway is reached through
  (found in the switch's ARL table); if that cannot be determined, **every** port is
  refused rather than risking the wrong one.

Because assigning a port to a VLAN means removing it from the stock VLAN's port list
(swconfig allows one *untagged* VLAN per port), this is the one place openUF modifies UCI
sections it did not create: a port moved untagged onto an openUF VLAN loses its untagged
membership in every other `switch_vlan` section, and an explicit *exclude* drops the
port's membership from that VLAN. Two safety refusals apply — an exclude that would leave
the port untagged **nowhere** is ignored, and the management VLAN is never stripped of
its last downstream port. openUF snapshots the original `ports` strings into `state.json`
(`swvlan_backup`) before the first change, and `switchvlan.restore()` puts them back. Unticking the device-level **Port VLAN** box runs
that restore automatically (the wire keeps the `switch.*` block with both gates at
`disabled`, which openUF treats as the explicit off signal); a push that carries no
`switch.*` block at all leaves the switch untouched. Inspect the result with
`uci show network` and `swconfig dev switch0 show`.

> The generated UCI is unit-tested, but **openUF has no switch hardware to verify against** —
> that these sections actually program the switch ASIC, and that
> `/etc/init.d/network reload` behaves on real ath79, are unconfirmed.

The **Environment** tab (Insights → AirView) is fed from `iw dev <ifname> scan dump`, the
kernel's passive BSS cache. That cache is filled from beacons the radio overhears **on the
channel it is already serving**, and the kernel forgets an entry about 30 s after it was
last seen — so on its own the tab lists co-channel neighbours and, after the boot-time ACS
sweep, nothing else. Measured on AP2 (a JIDU6101): 0 neighbours on 5 GHz, 4 co-channel on
2.4 GHz. Two options close that gap, and they compose: `neighbour_scan_interval` makes the
AP itself sweep (a brief client stall per scan, off by default), and `rrm_enrichment` asks
802.11k-capable *clients* to sweep and report (costs the AP nothing, on by default; see § 3).
To see the latter work: `pgrep -f 'ubus subscribe hostapd'` is the collector that receives
the reports (hostapd delivers them as ubus *notifications*, so `ubus listen` shows nothing —
only `ubus subscribe` works), `logread | grep BEACON-REQ-TX-STATUS` shows requests going
out, and `/tmp/openuf-rrm.jsonl` is the spool, drained on every inform. Rows sourced this
way show a blank WiFi Name and Security.

**Auto-channel limits: the site's DFS switch and channel blacklist** (from jonasevcik/openUF).

Settings → Radios carries two things that only matter while a radio is on **Auto**: whether
auto-channel may land on a DFS channel, and a per-band list of channels it must not pick.
The controller sends both per radio, and only to a device claiming `wifi_caps2` `0x10`
(`supportsAcsDfs()`), which openUF does since 2026-10-27.

| Wire key | When it is sent | UCI (`wifi-device`) | hostapd |
|---|---|---|---|
| `radio.<n>.acsdfs=enabled\|disabled` | 5 GHz radio, always | `acs_exclude_dfs` 0/1 | `acs_exclude_dfs` |
| `radio.<n>.blklst=12,2,13,…` | any radio, only while its channel is `auto` | `chanlist` (+ `openuf_chanlist`) | `chanlist` |

`blklst` is a **blacklist**, and hostapd has no blacklist — only `chanlist`, the list ACS may
choose from. So openUF inverts it against the channels the radio's regdomain actually allows,
read from `iw phy` (which already drops what the domain forbids, and openUF drops "no IR"
channels on top: an AP may not beacon there). The order the controller sends does not matter;
the list is written ascending.

Three deliberate refusals, each logged:

- **A blacklist that excludes nothing the radio could have used** (say channel 14 in a
  regdomain without it) writes no `chanlist` at all, instead of churning the band's whole
  channel list into UCI on every push.
- **Every channel of the band blacklisted** leaves auto-channel unrestricted: an ACS with no
  candidate is a radio that does not come up.
- **A radio on Auto whose UCI declares no `band`/`hwmode`** is left alone. The band would
  have to be guessed from the channel, and `auto` is not a channel — the guess answers
  "5 GHz" for every radio, which would hand a 2.4 GHz radio a list of 5 GHz channels.

`openuf_chanlist` records that openUF wrote the list, so when the site clears its blacklist
(the key simply vanishes) the `chanlist` is removed again — while a `chanlist` set by hand on
an unstamped radio is never touched.

Both keys are inert on a radio pinned to a fixed channel: they are written, visible in UCI,
and read by nothing until that radio is switched back to Auto. U7LR 6.8.2 does the same work
through `wifitool <dev> block_acs_channel`, with the DFS list hardcoded for `acsdfs=disabled`.

**A board's own DFS exclusion wins.** A profile that sets `acs_exclude_dfs` in `dev.conf.radio` (the JioRouter maps) keeps DFS out of auto-channel even when the site allows DFS: the site can add the restriction, never lift a board's.

**DFS radar reporting** (from jonasevcik/openUF). On a DFS channel (52–144) the radio must
leave the channel for 30 minutes when it detects radar. hostapd does that by itself; what was
missing is telling the controller, which otherwise logs nothing and the channel change looks
unexplained. openUF reads `DFS-RADAR-DETECTED` off hostapd's control socket (the same
`hostapd_cli -a /tmp/openuf-bresp.sh` monitors the 802.11k enrichment uses) and sends it as
the AP's own event:

```
inform_as_notif = true, notif_reason = "event",
notif_payload = {event_string = "EVT_AP_RadarDetected",
                 channel = "100", freq = 5500, vap = "phy1-ap0"}
```

The controller logs *"&lt;AP&gt; detected radar on channel 100 (5500 MHz)"* and raises the
matching alert. `channel` is a string and `freq` a number, because that is how 10.6.106's
handler reads them; with either missing the controller discards the event. The channel comes
from `freq`, where the radar was seen, not from the BSS's centre frequency. One detection is
reported once even when the radio carries several BSSes; at most 16 events wait while the
controller is unreachable. Nothing to configure: the monitors are kept running whenever a
radio is on a DFS channel or on `auto` on 5 GHz, even with `rrm_enrichment = false` and
`assoc_tracker = false` (the `ubus subscribe` child is not started for this alone). The log
line is `inform: DFS radar detected on channel 100 (5500 MHz) on phy1-ap0 -- reported to the
controller`. The other `DFS-*` events reach the spool and are dropped (no controller handler);
`grep DFS- /tmp/openuf-rrm.jsonl` after a hostapd start on a DFS channel shows the CAC pair,
which proves the path without waiting for radar. Note that the JioRouter profiles keep DFS
channels out (the profile blames the MT7986 driver for the failed CAC), and that under the
country **India** no Linux AP can start a CAC at all: wireless-regdb gives IN no DFS region,
and the kernel refuses radar detection without one (PROTOCOL-VALIDATION, "The 5 GHz Country IE
regression, and the radar event").

**`dfs-reset`: back onto a pinned DFS channel** (from jonasevcik/openUF). A radar hit takes a
5 GHz radio off its channel for at least 30 minutes, and nothing brings it back: the radio
keeps serving on whatever channel the driver moved to, so a planned DFS cell stays wrong until
someone re-provisions the AP. The controller therefore pushes a nightly cron job,
`0 2 * * * syswrapper.sh dfs-reset`, to every AP with a 5 GHz radio pinned to a DFS channel
the site's country allows; openUF installs it in its marked crontab block. The hook does no
radio work: it writes a timestamp to `/tmp/openuf-dfs-reset-request` and the daemon acts on
the next heartbeat (a request older than 30 minutes is dropped). Per enabled 5 GHz radio, in
the order UniFi firmware's own `dfs_reset` checks: a radio on `auto` is left alone; a live
channel (`iw dev <if> info`) equal to the configured one (`wireless.<radio>.channel`) means
nothing to do; a configured DFS channel still `unavailable` in `iw phy phyN channels` (the
non-occupancy list) is waited for, with the time left logged; otherwise the BSS is moved with
`hostapd_cli -i <bss> chan_switch 5 <freq> sec_channel_offset=± center_freq1=<c>
bandwidth=<w> ht|vht`, rebuilt from the live width so an 80 MHz cell comes back at 80 MHz. UCI
is never written. The radio goes quiet for the CAC on arrival, which is why it runs at 02:00.

```sh
/usr/bin/syswrapper.sh dfs-reset               # ask for it now
logread -e openuf | grep dfs-reset
iw phy phy1 channels | grep -A5 "5500 MHz"     # the kernel's own DFS state
```

**MAC-based VLANs ("Virtual Network Override")** (from jonasevcik/openUF). A client given a
Virtual Network Override, on the client's own page, belongs on that network's VLAN whatever
SSID it joins. The controller sends the whole site's map to **every** WLAN as
`aaa.<n>.accept_mac.{status,<k>.{mac,vlanid}}`. The override network must be a *corporate*
network; the controller refuses a VLAN-only one.

- **Two gates, and the second is site-wide.** `fw_caps` `0x80000000` is the device's own
  claim. Beside it the controller needs a UniFi OS gateway that claims the bit or is one of 23
  listed models (a UCG Ultra is both), **and** no client-bearing AP or switch in the site that
  fails to claim it. One AP without the bit switches the feature off for every device in the
  site. A site with no gateway never gets the keys at all.
- **hostapd's accept-MAC list does the work.** Its lines take a VLAN id after the address.
  The list is checked before `macaddr_acl`, and a match is accepted with that VLAN, so the
  file assigns VLANs without restricting access: an unlisted client still joins.
- **Each VLAN also needs a `wifi-vlan` section**, because hostapd refuses a station whose
  VLAN is not in its `vlan_file` ("Invalid VLAN %d received from RADIUS server" in
  `logread`, even with no RADIUS involved). openUF builds them as the private-pre-shared-key
  path does, into the same `br-openuf<id>`, and one section serves both features. An
  override whose VLAN openUF cannot build (no `lan_cpueth`) is left out and logged, never
  put on the SSID's own network.
- **The MAC Address Filter shares the file**, so an override the allow list does not permit
  is skipped, and so is one the deny list names (the accept list is checked first and would
  otherwise let a denied client in).
- **Refused on a WLAN with RADIUS MAC authentication**, where an accept-list entry would
  skip the server's decision. openUF has no RADIUS MAC authentication yet; the refusal is in
  place for when it does.
- **The file is written before anything points hostapd at it.** An `accept_mac_file=` that
  hostapd cannot read, or a malformed line, takes the whole WLAN off the air. So the option
  is only written once the file is, and every address is validated when the push is parsed.

⚠️ jonasevcik's lab captured the push on a live controller with a gateway, and confirmed the
accept file, the `wifi-vlan` section and live hostapd on two APs. The capture used a
placeholder MAC, so no real client has been moved to a VLAN by MAC, and this project has not
run it yet.

**Multicast Suppression** (Settings → WiFi → [WLAN] → Advanced; the control the
controller used to call "Multicast and Broadcast Blocker") has no hostapd or OpenWrt
equivalent — hostapd can suppress group-addressed frames wholesale but has no notion of
an allow-list, a bypass list or a rate — so openUF enforces all of it with nftables, in
its own `bridge openuf_bcfilt` table (separate from the client-blocking `bridge openuf`
table, which is rebuilt wholesale on every block/unblock and would otherwise wipe these
rules).

The control has three positions and **the wire never names the mode**. Both keys need
`wifi_caps2 0x400000`, which openUF claims:

| Mode | Keys that arrive | What openUF does |
|---|---|---|
| Off | nothing | nothing; the table is left empty |
| Conservative | `wireless.<n>.multicast.suppressor=enabled` **only** | rate-limits group-addressed frames leaving that VAP: `limit rate over 100/second burst 50 packets drop` |
| Aggressive | that key **plus** `wireless.<n>.bcfilt.status`, `bcfilt.bypass_types=ARP\|NSNA\|DHCPV4\|DHCPV6` and the `bcfilt.<k>.mac` allow-list | drops group-addressed frames leaving that VAP unless the *sender's* MAC is allow-listed, after letting the four bypass types through |
| (older controller) | `bcfilt.status` with no suppressor key | the pre-2026-10 behaviour, unchanged — see the warning below |

So Aggressive is distinguished from Conservative by the *presence of the `bcfilt` block*,
not by any value. The allow-list the controller sends is not only the one you typed: it
adds every UniFi device MAC in the site and the gateway's LAN peers, which is why the UI
says gateways need not be added by hand.

The four bypass types become four `accept` rules placed **before** the drop, each pinned
to that VAP's own `oifname`: `ether type arp`, `ether type ip6 icmpv6 type { nd-neighbor-solicit,
nd-neighbor-advert }`, `ether type ip udp dport { 67, 68 }` and `ether type ip6 udp dport
{ 546, 547 }`. That is what makes the controller's own description true — "Limits
multicast and broadcast traffic to reduce WiFi airtime usage. Conservative prevents
storms; Aggressive blocks all except DHCP and ARP".

**The Conservative rate is openUF's own number, not the controller's.** The wire carries
a bare `enabled` with no parameters, so 100 packets/second with a 50-packet burst was
chosen against a measurement: both production bridges carry 1.4–3.6 multicast frames per
second at idle (read from `/sys/class/net/<br>/statistics/multicast` over 60 s on an
ath79 and a filogic board), so the ceiling sits roughly 30× above real discovery traffic
while still capping what a storm can take. It is a ceiling, not a target. If your site
needs a different one, it is the `LIMIT_RATE`/`LIMIT_BURST` pair at the top of
`openuf/bcfilter.lua`.

This needs **`kmod-nft-bridge`**, as does the L2 hardening below. The `meta pkttype` rule
is a bridge-family `meta` match, and `nft_meta_bridge` is a separate module that
`nftables` does not depend on — absent from a stock filogic *and* ath79 image alike. The
failure is quiet in the worst way: the table, the chain and the per-VAP allow-list set
are all created and populated, and only that rule is rejected, so the control reads
as enabled in the controller and `nft list table bridge openuf_bcfilt` shows a table that
filters nothing. openUF logs `nft rejected the pkttype rule for <ifname> -- install
kmod-nft-bridge` when this happens.

The source-MAC half was measured on real hardware twice: upstream on an AX3000T (14 of 14
broadcast frames from a sender not on the list dropped, 0 of 15 once listed), and this
project on two JIDU6401s (2026-10-29: a wired host not on the list could not resolve a
phone's address; listed, it could; DHCP kept working with the DHCP server listed). The
bypass types and the Conservative rate limit come from jonasevcik/openUF and are
lab-confirmed only.

> **A controller that sends no bypass types still breaks DHCP for wireless clients
> unless you add the DHCP server's MAC to the excepted-devices list.** That is Ubiquiti's
> own documented behaviour for the older control, and openUF reproduces it faithfully
> rather than inventing an exemption that controller never asked for — a silent exemption
> would be harder to debug than the documented breakage, and would change a WLAN that was
> working as documented. Aggressive on a current controller does send the bypass types, so
> there the carve-out is the controller's instruction, not openUF's guess. Inspect the live
> rules with `nft list table bridge openuf_bcfilt`.

**Minimum Data Rate** is set per WLAN in the controller but OpenWrt's rate options
(`basic_rate`, `supported_rates`, `legacy_rates`, `beacon_rate`) are `wifi-device`
options, so two WLANs sharing a radio cannot each get their own floor. openUF applies
the most permissive of them — the lowest floor, CCK still allowed if any WLAN allows
it — because the stricter choice would silently lock clients out of a co-hosted WLAN
that was meant to admit them. Give a WLAN its own radio if it needs its floor enforced
exactly. Note also that the floor is enforced by making it the sole *basic* rate (a
station must support every basic rate to associate); the "advertising rates" sub-toggle
additionally trims `supported_rates`. Rate options openUF writes are stamped with an
`openuf_rates` marker on the radio section: turning the control off (the wire simply
omits every `minrate_*` key) tears down exactly the marked options, while rate options
you hand-tuned on an unmarked radio are never touched.

Minimum RSSI is a *radio* setting in the controller UI (Devices → AP → Radios), not a per-WLAN one, and the wire value is not dBm but a fixed offset from it (`wire = dBm + 95`; UI -80 ↔ wire 15, UI -85 ↔ wire 10) — openUF converts it back with that same constant. An earlier version added the *live* noise floor instead, which only looked right on a radio whose floor happens to be -95 and drifted 12 dB between drivers (upstream's finding). The controller signals *disable* by omitting the whole `stamgr.<n>` block from the next config push; openUF treats that as an explicit off and clears `minrssi_enabled` in UCI (the stored threshold stays parked for a later re-enable).

The reported **country code** comes from the wifi-device's UCI `country` option (the
regulatory domain OpenWrt programs), mapped best-effort from ISO alpha-2 to the numeric
code the controller expects; an absent or unrecognized regdomain falls back to 840 (US),
the value that used to be hardcoded for every deployment.

The **IoT Optimization** panel (Settings → WiFi → *WLAN* → IoT Optimization) is mostly controller-side sugar: two of its three toggles just set values the protocol already had — channel 6 on the 2.4 GHz radio, and DTIM 3 — so they need no dedicated support. "Force WiFi 4 Mode" additionally drops the WLAN's 5 GHz vap, pins WPA2, and turns off PMF, BSS Transition, proxy ARP, fast roaming and band steering; those all arrive as their ordinary keys. Note that it does *not* narrow the radio: the shared 2.4 GHz radio keeps whatever channel width it is configured for, so `htmode` is untouched.

To verify provisioned SSIDs:
```sh
uci show wireless | grep openuf_
```

To remove all provisioned SSIDs:
```sh
lua -e "dofile('/opt/openuf/ucihelper.lua').wlan_clear()"
# or simply reset-inform and re-adopt
```

**Band Steering** has two switches in the controller: the per-WLAN toggle, and the AP's
own setting in its device panel (Off / Prefer 5G / Balance). Either one turns steering on
for the whole AP, because usteer is a single daemon. Balance is not supported (see
Troubleshooting). Steering itself is `usteer`'s decision, not openUF's: openUF configures the
daemon (`usteer.local.band_steering_interval`: `0` when off, unset so usteer's own default
applies when on) and forces 802.11k neighbour reports plus `bss_transition=1` onto every VAP,
since usteer cannot work without them. If a client is not being steered, check
`ubus call usteer get_clients` for a 5 GHz sighting of it and
`ubus call hostapd.<iface> get_clients` for its `rrm` bits and the BSS-Transition bit in
`extended_capabilities`. A successful steer looks like
`BSS-TM-RESP <sta> status_code=0 target_bssid=<the 5 GHz BSSID>` in `logread`.

**Roaming Assistant** (Settings → WiFi → *WLAN* → Advanced, 5 GHz) moves a weak client to
an AP that hears it clearly better. It does nothing to a client that has no better AP to go
to. It is per WLAN and runs in openUF (`openuf/roamassist.lua`), not in usteer, because
usteer's own roam trigger can only be switched on for the whole device. For each client on a
WLAN with it on:

1. Its signal has been below the WLAN's threshold for 30 s, it has been associated for at
   least 60 s, and it was not moved in the last 120 s.
2. Another openUF AP on the same SSID and band hears it at or above the threshold **and** at
   least `roam_assist_diff_db` (default 8) dB louder. usteer shares those readings between
   APs. If no AP qualifies, nothing is sent, and the client is looked at again after 30 s.
3. openUF sends an 802.11v BSS Transition request naming that AP. A client still associated
   10 s later is disassociated, with a 30 s ban on the weak BSS only, so it cannot bounce
   straight back. That is also how a client without 802.11v gets moved.

It needs `usteer` running on every AP (openUF starts it whenever Roaming Assistant or Band
Steering is on) and a full `wpad` build. Each action is logged: `logread | grep roamassist`.
usteer's readings are up to two minutes old, so a client that has just walked away can be
pointed at an AP that is no longer better; the disassociation then lets it pick for itself,
which is where a UniFi AP would leave it too. Verified on real hardware upstream (a client at
−80 dBm moved to a −61 dBm AP); not yet tried between AP1 and AP2 here.

| Setting | Meaning |
|---|---|
| `roam_assist_diff_db` | How much louder (dB) the other AP must hear the client. Default 8 |

**Sibling openUF APs are not rogues.** The controller takes the reporting AP's word for
which scanned BSSes belong to the site — it never checks its own devices' BSSIDs — so without
help every other openUF AP broadcasting your SSID shows up as *"a third-party access point
broadcasting your network's SSID"*. Each openUF VAP therefore beacons a small vendor element
carrying its identity MAC (hostapd `vendor_elements`, which OpenWrt 25.12's wifi scripts pass
through), and a scan that hears it reports that BSS as a UniFi AP of the site; it then leaves
the Environment list, as a real UniFi AP's would. The element is read back over nl80211 with
a one-line `ucode` script, because OpenWrt's `iw` build never prints an unknown vendor IE.
Only openUF APs recognise each other this way — a mixed site's genuine UniFi APs are still
reported as third-party by openUF and vice versa.

---

## 6a. Controller-managed system settings and hardening

Three `system_cfg` blocks the controller sends on every full push are applied to the
device itself rather than to WiFi (confirmed live 2026-09-15, PROTOCOL-VALIDATION.md):

| Wire | Device side | Reversal |
|---|---|---|
| `system.timezone=IST-5:30` | UCI `system.@system[0].timezone` (the wire string is already a POSIX TZ string). Written only when it differs; `zonename` is retired to `openuf_zonename_orig` since it would name a different zone | `openuf_timezone_orig` holds what was there |
| `ntpclient.<n>.server=…` ×4 | UCI `system.ntp.server`, then `sysntpd` restart | `openuf_ntp_orig` holds the board's own list; `ntpclient.status=disabled` on the wire puts it back |
| `cron.<n>.job.<m>.schedule` / `.cmd` | A marked block in `/etc/crontabs/root` between `# openuf-cron-begin` and `# openuf-cron-end`, then `cron` enabled and restarted. **Only commands this build provides are installed** — today that is `syswrapper.sh 11k-scan` — and anything else is logged, never written: a pushed cron line is a string crond runs as root. The pushed `cron.<n>.user` is ignored (jobs run as root) | The block is removed when the push stops carrying installable jobs; lines outside the markers are never touched |
| `ebtables.<n>.cmd=…` ×10 | nft table `bridge openuf_l2guard`: frames to the Bridge Group Address (`01:80:c2:00:00:00`, STP BPDUs) dropped in and out of every AP VAP, and 802.1Q-tagged frames from clients dropped on every AP VAP. Needs `kmod-nft-bridge` (already installed for the Blocker); a rejected rule is warned about by name. **Wired sockets are deliberately not covered** — see CLAUDE.md's landmine | `ebtables.status=disabled` tears the table down; it is rebuilt at every start from `state.json`; the daemon also re-reads the VAP list once a minute and rebuilds the table when it changed, and a factory reset removes it |

`syswrapper.sh 11k-scan` — what the controller's nightly 04:00 job runs — does not scan
itself: it leaves a dated request in `/tmp/openuf-scan-request` that the running daemon
picks up within one heartbeat, sweeps every radio (`iw dev <if> scan ap-force`, the same
stall clients see with `neighbour_scan_interval`; `ap-force` sweeps the same channels as a
plain scan on the boards tried so far and guards against a driver that refuses to scan on a
beaconing AP), and reports on the following inform. A radio where iw refuses logs
`iw refused to scan <if>` and is left out of the count. A request older than ten minutes is
discarded, so one left behind by a stopped daemon cannot fire at the next boot. You can run
it by hand to refresh the Environment view: `syswrapper.sh 11k-scan`, then
`logread -e openuf | grep 11k`.

Three things remove the marked cron block: `install.sh uninstall`, a controller *Forget*
(`setdefault`) and `syswrapper.sh reset-inform`. All three leave the timezone and NTP values
in place: those are sane settings for the board either way, and the originals stay stamped.
The same two resets tear the `openuf_l2guard` table down and drop a controller-set inform
interval.

## 6b. Wireless uplink (mesh backhaul)

UniFi's mesh is a 4-address WDS link, not 802.11s: a parent beacons a hidden WPA2-PSK
network named `vwire-<site>` with a site-wide key, and a child joins it with a 4-address
station, so the link is a transparent L2 pipe and VLAN tags ride along. The controller
describes both ends in a meshing device's push (PROTOCOL-VALIDATION § Wireless uplink),
and openUF turns them into two `wifi-iface` sections on the 5 GHz radio:

| Section | What it is | When it is up |
|---|---|---|
| `openuf_bh_dl_<radio>` | the **downlink**: a hidden AP, `wds 1`, `psk2`, in `lan` | whenever the push carries it (a wired mesh-capable AP is a parent by default) |
| `openuf_bh_ul_<radio>` | the **uplink**: a `sta`, `wds 1`, same SSID and key, in `lan` | only while the wired uplink socket has no link |

Both are rewritten on every push like the user SSIDs, neither is reported as a VAP, and the
downlink is kept out of the L2 hardening rules (a child's tagged frames and BPDUs cross it by
design). The per-VLAN bridges need nothing extra on a DSA board: `br-lan.<vid>` sits on top
of `br-lan`, which is where both backhaul netdevs land.

A swconfig board needs more, and gets it from `meshvlan.lua` (since 2026-10-18; **a tagged
SSID across the hop is not yet confirmed on hardware**, though the untagged mesh ran on a Deco
M4R v1 on 2026-10-19, and the guard and the port were checked on an OpenWrt 25.12 kernel in a
VM, with veth stand-ins for the wired and the wireless port). Its per-VLAN bridge rides `eth0.<vid>`, the CPU trunk's sub-device, which
reaches the switch and nothing else. So while a mesh is configured, each tagged SSID's bridge
`br-openuf<vid>` also gets `br-lan.<vid>` as a second uplink, the one DSA has by design. That
port alone would be a loop: a tagged frame `br-lan` hands to its wired port `eth0.1` leaves
double-tagged, and the switch puts it back on the wire as an ordinary VLAN frame. So it only
ever exists behind a guard, nft table `bridge openuf_meshvlan`: a VLAN-tagged frame may enter
or leave `br-lan` only through a wireless port (`phy*`, `wlan*`, `ath*`), never a wired one.
The port is runtime state, never UCI. openUF adds it after the guard is in, re-installs the
guard once a minute, and deletes the port the moment the guard cannot be installed (no
`kmod-nft-bridge`, say); a reboot clears both and openUF rebuilds them in that order. Learning
is off on it, so neither uplink keeps the gateway learnt after the device moves between wire
and air. One limit: a swconfig parent carries a child's tagged traffic only on VLANs it has a
tagged SSID of its own on, since its switch drops a VLAN it has no entry for.

**The uplink policy** (`backhaul.lua`, one decision per heartbeat) is wired-first. openUF
remembers which socket the gateway was last seen behind: `state.json` `backhaul_wired_port`
names the netdev on a DSA board. On a swconfig board, `br-lan` only ever sees the CPU trunk's
sub-device `eth0.1`, whose link is the internal one and never drops, so the switch is asked
instead. `backhaul_wired_phys` is the physical switch port its address table has the gateway
on, and that port's link in `swconfig dev switch0 show` is what counts. When the uplink moves
between wire and air, a swconfig board also makes its bridges forget what they learnt on
wired ports, and for a few heartbeats after the wire comes back it flushes the switch's
address table if that still has the gateway on the CPU port; the CPU link never goes down, so
the kernel would not clear either. When that socket's link has been gone for 10 s the station is
enabled and the radio reloads. On a DSA board the link is read every second between heartbeats,
so the 10 s count from the moment the cable is pulled; until the switch is made, and for 30 s
after it, the device informs every few seconds instead of backing off, so the controller hears
from it over the new uplink as soon as that is up. A swconfig board reads its switch port once
per heartbeat; while the station is enabled the AP SSIDs on that radio start
only once it has joined a parent, on the parent's channel — the behaviour of a real mesh
child. The moment the socket's link is back the station is disabled again. The two uplinks
are never up together: with STP off in every UniFi push, that would be a bridge loop. The
mode in effect is `state.json` `backhaul_mode` (`wired`/`wireless`), and `logread` says
`backhaul: wired uplink lost on <port> -- enabling the WDS station` and the reverse.

**More than one hop** (unit-tested, not yet run on hardware). A wireless child gets a downlink
of its own too, so chains form by themselves. Each downlink beacons a second sibling element
(version 2): its identity, whether it has a path to the wire, its own station's MAC and its
ancestors up to the wired AP. From what its scans hear, each AP keeps `state.json`
`backhaul_seen`: every downlink whose ancestors include it is a descendant, written to the
station as `bssid_blacklist` so it is never joined. If the station ever does find itself on a
descendant (a downlink not heard before), it is blacklisted on that heartbeat and the station
moves. The parent picked in the controller (Devices → AP → uplink, `mesh.serial1`) is pinned
with `bssid` once its downlink has been heard and is not a descendant; after six heartbeats
without joining it the pin is dropped and any eligible parent will do. The element is updated
in the running hostapd (`hostapd_cli set vendor_elements` + `update_beacon`), so a changed chain
does not drop the children. `logread | grep backhaul` says `a loop; leaving it` or
`unpinning` when either happens; `uci show wireless | grep -E "bssid|blacklist"` shows what
the station may join.

While on the wireless uplink the inform reports what the controller actually reads
(PROTOCOL-VALIDATION § Wireless uplink): `uplink` is the uplink VAP's name, the uplink
VAP is a `vap_table` entry of usage `uplink` whose one station is the parent's downlink BSS
tagged with the parent's MAC, and the downlink is an entry of usage `downlink` listing the
children. The controller then shows the wireless uplink, the parent, the signal and rates,
and the topology hop; the parent lists the child as a wireless downlink.

**What you need for it:** nothing. openUF claims `wifi_caps` `0x1`/`0x800` on every board,
the controller turns the device's mesh-connect flag on by itself, and the push carries both
entries. Verified end to end on DSA boards. swconfig boards claim it since 2026-10-18; the
first run on one, a Deco M4R v1 on 2026-10-19 (user, shallow), came up online over the
wireless uplink with its cable pulled. The cable coming back and a tagged SSID across the hop
are not yet confirmed there. A parent on a DFS channel worked in the lab
(channel 100); if a child never associates, check `iw dev phy1-sta0 info` says `4addr: on`
and compare the two sections' keys.

**Checking a swconfig board** (the first M4R v1 run). With the cable in, then pulled:

```sh
swconfig dev switch0 show | grep -E "^Port|link:"   # the socket's link, and which port the ARL has
logread | grep -E "backhaul|meshvlan"                # "wired uplink lost on switch port 3 -- enabling"
iw dev phy0-sta0 info | grep 4addr                   # the 5 GHz radio is phy0 on an M4R; 4addr: on
grep -E "backhaul_wired_phys|backhaul_mode|meshvlan" /etc/openuf/state.json
nft list table bridge openuf_meshvlan                # only with a tagged SSID: two drop rules
ip -d link show br-lan.20                            # vlan id 20, master br-openuf20
```

A client on a tagged SSID of the child should reach its own network over the hop, and a host
plugged into the child's other socket should keep working. If the guard is missing,
`logread` says why and the tagged SSIDs simply do not cross the hop; untagged ones still do.

## 6b-2. Uplink Connectivity Monitor

The controller's site setting (Settings → WiFi → Uplink Connectivity Monitor) reaches the AP
as `connectivity.status=enabled`. The controller sends that only to a device claiming
`wifi_caps` `0x1`, which openUF does for the mesh. A custom target arrives as
`connectivity.uplink`. While the setting is on, openUF pings the gateway (or that target) twice
per heartbeat. After 5 failed checks in a row, the user and guest SSIDs' BSS netdevs go down,
as UniFi firmware's `uplink-monitor` does: `logread` says `uplinkmon: uplink unreachable --
SSIDs off the air: phy0-ap0 phy1-ap0`, and `state.json` `uplinkmon_down` lists them. The first
answer brings them back (`SSIDs back`). The mesh downlink and uplink station are never touched.
On a meshing AP, pulling the cable does not blink the SSIDs, because the station has joined a
parent well before the fifth failed check.

```lua
uplink_monitor = nil,         -- nil: follow the controller; true/false: force
uplink_monitor_host = nil,    -- e.g. "1.1.1.1" to test the internet, not just the gateway
```

UCI equivalents: `option uplink_monitor '1'` and `option uplink_monitor_host '1.1.1.1'` in
`openuf.main`. Two firmware details are not copied. Carrier loss is not an instant verdict,
because it would blink a meshing AP's SSIDs during the wired-to-wireless switch. The bridge-FDB
shortcut is skipped too: it only saves probes.

## 6b-3. Guest portal (Hotspot): ⚠️ lab-validated only (adopted from upstream 2026-10-25)

In this tree, guest WLANs that `selfrun_guest_mode=off` takes down share the down/up ledger rules of the WLAN schedule (§ 6) and the Uplink Connectivity Monitor (§ 6b-2): none of the three brings back up an SSID another one still holds down.

Never run against a real guest WLAN on hardware; treat it as a preview. It turns on by
itself when the controller pushes a guest WLAN with the portal enabled
(`redirector.status=enabled` plus the guest `ebtables.*` rules). It turns off, removing
everything, when the portal or the guest WLAN goes away, or on a factory reset.

**What runs.** `guestportal.lua` builds two nftables tables from the pushed rules.

`bridge openuf_guest` hooks every live netdev of the guest WLANs. For an unauthorized guest:
- **Allowed:** EAPOL, the portal's ports on the controller, broadcast DHCP, ARP and DNS.
- **Dropped:** IPv6, other broadcast, multicast, and the restricted subnets
  (`10/8`, `172.16/12`, `192.168/16` by default).
- **Plain HTTP:** marked and handed to the bridge's own IP stack.
- **Everything else:** dropped.

A MAC in the `authorized` set (filled from `state.json`'s `guest_authorized`) may reach
any host other than the AP, but the restricted subnets still apply.

**The walled garden ("Pre-Authorization Access").** The controller splits the site's
`allowed_subnet_<n>` / `restricted_subnet_<n>` list by what each entry *looks like*, not
by which list it is in, and sends the two halves by different routes:

| Entry | How it arrives | What openUF does |
|---|---|---|
| IP or CIDR | `ebtables.<n>.cmd` — `-I GUESTIN -p 0x800 --ip-dst <net> -j ACCEPT` and its `-I GUESTOUT … --ip-src` twin, or `-A GUESTIN … -j DROP` for a restricted one | one `ip daddr … accept` / `ip saddr … accept` / `ip daddr … drop`, above every drop (allowed) or among the restricted-subnet drops |
| domain name | `dnsmasq.walled_garden.1.site.<n>.{allowed,restricted}`, plus empty `ALLOWED_DOMAIN_IN` / `ALLOWED_DOMAIN_OUT` / `RESTRICTED_DOMAIN_IN` chains the firmware would fill | resolved on the AP with `nslookup`, then the same rules inline |

Two traps worth knowing:

- **An IP entry carries no port.** The portal's own accepts do (`8880`, `8843`, `8881`),
  and until 2026-10-26 openUF knew only that shape — so an IP walled-garden entry, and
  the egress rule that lets its replies back, were parsed as unknown and silently
  unenforced. Both shapes are now applied.
- **Re-resolution is on the controller's own cadence.** Along with the garden it pushes
  `*/10 * * * *  syswrapper.sh refresh-walled-garden 1`. openUF does that work in the
  inform loop (`GUEST_WG_INTERVAL`, 600 s) and on every config push, so `sysconf.lua`
  installs no crontab line for the job — the same treatment `syswrapper.sh
  schedule-action` gets. Each name is asked twice per round, as the firmware's
  `walled_action.sh` does, so a round-robin record does not shrink the set.

`nslookup` **blocks**, and the inform loop is single-threaded, so the garden is bounded
on three sides — a dead resolver must not cost the AP its heartbeat:

| Bound | Value | What it does |
|---|---|---|
| `guestportal.WG_MAX_SITES` | 32 per list | names past it are dropped with a log line naming the first one |
| `inform.GUEST_WG_BUDGET` | 5 s per pass | past it no further name is asked; the rest keep their last answer, exactly as a name that failed to resolve does. One name can overrun by a single lookup |
| the name list's signature | — | a push repeats the whole garden whether or not it changed, and a Force Provision loop repeats it every few seconds. An unchanged list inside the refresh window is not re-asked at all |

A pass that ran out of time opens a two-minute window (`GUEST_WG_RETRY`) instead of the
usual ten, so the names it never reached are picked up soon — without letting the pushes
in between re-ask. On the Archer C5 a blackholed lookup takes 5 s (musl's resolver cap),
so the worst a push can cost is about 10 s.

The answers live in `state.json` as `guest_wg_ips` (`{allowed = {name = {ip, …}},
restricted = …}`), which makes two things true: a reboot rebuilds the rules from the last
good answers instead of waiting on DNS, and a name that *stops* resolving keeps the
addresses it had. A name that has never resolved is simply not enforced, and the log says
which one.

`ip openuf_guest` redirects the marked HTTP to port **8820**. The inform daemon answers
there between heartbeats with a `302` to the controller's portal, adding:
- `?id=<guest MAC>`, looked up in `/proc/net/arp`;
- `&ap=<AP MAC>`;
- `&t=<now>`: the controller refuses a `t` more than 60 s off its own clock, so the AP's clock must be right;
- `&url=<what the guest asked for>`;
- `&ssid=…`.

Logging in on the portal makes the controller send `authorize-guest`. The guest is let
through within one heartbeat.

When a guest's authorization ends (`unauthorize-guest`: an admin revoked it, it expired or
it went over its quota), openUF takes the MAC out of the `authorized` set and disconnects the
guest from every SSID, as UniFi firmware does. On reconnecting, the device's
captive-portal check runs again and shows the portal. A repeat for the same MAC within 60 s
is not kicked again.

**Per-guest speed limit.** When a guest is authorized with a limit (a REST
`authorize-guest` with `up`/`down` in kbps, or the guest's user group), the controller
sends `rate-update` right after `authorize-guest`, and again whenever the guest reconnects.
It is a client's own WiFi Speed Limit like any other (see "WiFi Speed Limit" above): a
queue per direction for that MAC, `-1` meaning unlimited that way.

**Without the controller (`selfrun_guest_mode`).** Every `mgmt_cfg` carries
`selfrun_guest_mode`. It is `pass` unless the site's `config.properties` sets
`config.selfrun_guest_mode` to something else, and then it is `off`. openUF does what
UniFi firmware does (read from its `mcad` and `syswrapper.sh`, builds 3.9.27–4.0.15):
selfrun starts after **3 informs in a row** go unanswered (`GUEST_SELFRUN_FAILS`). With the
backoff (10, 20, 40 s) that is about 70 s after the last answer. Selfrun ends with the first
answer, and it only does anything while the portal is on.
- **`pass`, or never received:** openUF adds `meta pkttype other accept` to the `selfrun`
  chain. Every guest then gets through, as an authorized one would: the restricted subnets
  and the AP itself stay behind the portal's rules. Nobody could log in meanwhile, because
  the portal is the controller's. The first answer empties the chain again.
- **`off`:** the guest WLANs are taken down (`ip link set <vap> down`) and brought back up
  with the first answer: the netdev comes up and hostapd is told to start its beacon again
  (`hostapd_cli raw STOP_AP` + `update_beacon`, as when a Blackout Schedule ends). Their
  names are kept in `st.guest_vaps_down`, so a daemon restart in between leaves them down
  until the controller answers, and then brings them up. One whose beacon does not restart
  goes down again and stays in that list, and every later answer tries again.
- One deliberate difference: when the controller comes back, UniFi firmware forgets every
  authorized guest and waits for the controller to re-authorize them. openUF keeps its
  list, and the controller re-sends `authorize-guest` for the same guests anyway.
- `off` is tested on hardware (ath9k, ath10k, mt76) on its own, with a temporary WLAN; the
  rest of the guest portal has not run on hardware. Without `hostapd-utils` the WLANs cannot
  come back on the air: they stay down, and the log says so once.

The daemon also reports a random `guest_token`. Without one, the controller refuses
every portal login on the AP and logs "Missing Guest Token in AP[…] during guest
authorization".

**Where it differs from UniFi firmware, on purpose:**
- **DNS passes for every guest.** UniFi firmware answers an unauthorized guest's DNS
  itself; openUF runs no resolver.
- **HTTPS is dropped, not answered.** The client's plain-HTTP connectivity check is what
  finds the portal.
- **The redirect needs an IPv4 address on the guest network's bridge.** The answer
  leaves from there. A guest WLAN on a VLAN where the AP has no address keeps its
  guests blocked, and they never see the portal.
- **The walled garden is IPv4 only and resolved on the AP.** AAAA answers are
  discarded, because both the firmware's chains and openUF's are IPv4. A name whose
  answer differs from the client's — a CDN, geo-DNS, short-TTL round robin — can be
  reachable at an address openUF never saw, and the ten-minute refresh is the only thing
  that catches up. UniFi firmware has exactly the same limit; a DNS-intercepting garden
  would need a resolver on the AP, which openUF does not run.
- **A domain-only restricted list never arrives.** The controller emits the whole
  `dnsmasq.walled_garden` block only when the *allowed* list contains at least one
  domain (10.6.106), so restricted domains alone are dropped on its side. Put one
  allowed domain in the list, or express the restriction as a subnet.

**Needs** `kmod-nft-bridge` (for `iifname`/`oifname`), and `kmod-nft-nat` for the
redirect. firewall4 already pulls in `kmod-nft-nat`.

**The controller's portal ports must be reachable from the guest network.** The redirect
sends guests to `http://<controller>:8880/…` (and the page may use 8843). A controller in a
container publishes only what its port list names: with just the inform and web ports, guests
get the redirect and then a page that never loads. Publish 8880 and 8843 under the same
numbers.

**With Mesh Parent on** a guest WLAN sits beside the mesh downlink. Builds before 2026-10-26
took the guest WLAN for a second downlink (it arrives as `usage=guest`) and lost both; check
that `iw dev` lists the guest SSID and a `vwire-…` BSS separately.

**Check it:**

    nft list table bridge openuf_guest      # selfrun is empty unless guests are let through
    nft list table ip openuf_guest
    netstat -lnt | grep 8820

**Log lines and what they mean:**
- `guestportal: … not bridged`: those guests are blocked but not redirected.
- `nft rejected …`: a rule failed. The log says which one and why.
- `guestportal: 3 informs unanswered, selfrun_guest_mode=pass -- letting guests through`:
  the portal is open until the controller answers again
  (`… guest portal enforced again`).
- `guestportal: 3 informs unanswered, selfrun_guest_mode=off -- guest WLANs down (…)`:
  the guest WLANs are down until the controller answers again
  (`guestportal: guest WLANs back up (…)`).
- `guestportal: unrecognised guest rule shape`: the controller pushed a rule openUF
  doesn't know. It was not applied.
- `guestportal: walled garden: <name> did not resolve -- keeping the last N address(es)`:
  DNS failed for that name this round; the rules it had still stand.
- `guestportal: walled garden: <name> did not resolve and has no earlier answer -- not
  enforced`: that site is not in the garden at all. Check the AP's own resolver
  (`nslookup <name>` on the device) before blaming openUF.
- `guestportal: ignoring malformed walled-garden site`: the name did not pass openUF's
  check (spaces, an IPv4 literal, a label over 63 characters). It never reaches a
  command line.
- `guestportal: walled garden: out of time at <name> -- the names from here on keep
  their last answer until the next refresh`: the pass spent its `GUEST_WG_BUDGET`. The
  usual cause is a resolver that is not answering; check `nslookup <name>` on the
  device. The remaining names are retried two minutes later.
- `guestportal: walled garden: more than 32 allowed sites pushed`: the list is longer
  than `WG_MAX_SITES`. Express the tail as subnets instead.
- `guestportal: walled-garden addresses changed -- rebuilding`: the ten-minute refresh
  found a different address set and rebuilt the chains.

**Check the garden:**

    nft list chain bridge openuf_guest guestin | head -20   # allowed sites, above every drop
    nft list chain bridge openuf_guest guestout             # their replies
    grep -o '"guest_wg_ips":[^}]*}}' /etc/openuf/state.json # the last good answers

## 6d. Self-check: is each feature really in effect?

`tools/selfcheck.sh` runs on an adopted AP and checks, one feature at a time, that what the
controller turned on is actually in place: PPSK VLAN netdevs bridged, OWE in hostapd, schedule
holds, speed-limit qdiscs, blocker and hardening tables, the mesh station (4-address, joined,
pin and blacklist), the uplink monitor, the guest portal's tables and listener, the AP-name
element, and Airtime Fairness. It is read-only: it never writes or reloads anything and sends
at most one ping.

    sh tools/selfcheck.sh                 # from the source tree install.sh was run from
    sh tools/selfcheck.sh mesh guest      # only some groups

It is not installed with openUF (the package ships `openuf/` only). Run it from the extracted
source tree, or copy just that file over: `scp -O tools/selfcheck.sh root@<ap>:/tmp/`.

Each line is `OK`, `FAIL`, `SKIP` (the controller has not turned that feature on: nothing to
check, not a pass) or `INFO`. The exit status is 1 if anything failed. Many features are
unit-tested only (⚠️ in the README); a clean run on real hardware is what moves them to ✅. The
`INFO the real test:` lines name the client-side test to finish the job, such as iperf3 for
speed limits or joining the guest SSID.

## 6c. What the AP does on its own since 2026-10-18

These came from upstream's reading of the UniFi AP firmware (UAP BZ2 3.9.27 to 4.0.15,
plaintext) and their hardware; none has run on a JioRouter yet (REVERSE-ENGINEERING.md
backlog row 23). Each is on by default and needs nothing in `conf.lua`.

- **Commands arrive at once.** openUF keeps a STUN binding with the controller
  (`stun_url` from every `mgmt_cfg`, a request every 30 s) and reports the mapped address as
  `connect_request_ip`/`port`; the controller's wake-up datagram ends the heartbeat's sleep,
  so Locate, Reconnect and a WLAN edit land within a second. `logread | grep stun` says when
  the binding fails (a controller that does not run STUN is not an error, just the old
  cadence).
- **AirView → Connectivity and Roaming** are fed by `notif` informs: connection stages from
  hostapd's events plus a passive nft table (`bridge openuf_assoc`) that dates each
  station's first DHCP and DNS frames, and arrivals, departures and roams within ~250 ms.
  `assoc_tracker = false` in `conf.lua` switches both off and removes the table.
  Each decided attempt is logged as one line, `openuf: assoctrack: <mac> <ifname> vap=<vap> ->
  <verdict> (assoc <n>ms, authz <n>ms|never, gone=true|false)`, where the verdict is
  `success`, `failure wpa|dhcp|dns`, `soft failure` or `no event` (decided, nothing sent)
  (`logread | grep assoctrack`).
- **Minimum RSSI** refuses weak clients in hostapd (threshold + 3 dB) and kicks only after
  30 s below; **Load balance** (`stamgr.<n>.loadbalance.maxsta`, REST-only in the 10.6 UI)
  kicks the most idle clients above a radio's cap.
- **WiFi Speed Limit** is per client (§ 6), **WLAN Schedule** takes SSIDs off the air in
  their blackout windows once the clock is trusted (troubleshooting table below), and
  **Forget** (`setdefault` or `syswrapper.sh reset-inform`) now removes every controller
  SSID, VLAN bridge, radio extra, per-port VLAN and cron job without a reboot, keeping the
  inform URL that reached the controller so the device shows up there as pending again.
- **802.11r** key holders are keyed with the controller's per-WLAN `iapp_key` (so every
  openUF AP on the WLAN is a peer without sharing the passphrase's derivation), PMK-R1 is
  pushed, and a stale key-exchange socket in hostapd (seen upstream after weeks of uptime)
  is repaired by restarting wpad when no client is connected or in the 04:00 hour. With
  `unifi_ft_interop` on, the key holders also name the genuine UniFi APs the rrb-unifi
  translator lists, and hostapd exchanges keys through the translator's veth (§ 6).
- **Hygiene:** usteerd's AP-to-AP table broadcasts are dropped before they leave a VAP,
  the bridge hairpin flag is re-asserted on BSSes OpenWrt force-isolates (Multicast
  Enhancement, Proxy ARP), the nightly 11k-scan runs at two random times in the hour, and
  beacon requests go out hourly.

## 7. LLDP topology

`lldpd` must be running for topology announcements to work.  openUF queries `lldpctl -f json` and includes the neighbor table in each inform payload so the controller can render the upstream switch on its topology map.

Check LLDP status:
```sh
lldpctl          # show neighbors
lldpctl -f json  # JSON output (what openUF reads)
```

If `lldpd` is absent or returns no neighbors, `lldp.lua` returns an empty table — non-fatal.

The neighbour table is included in every inform and `lldpctl` is re-run for
every 10-second heartbeat, by decision (2026-10-18): a topology change — a new
neighbour, a moved cable, `lldpd` coming up after openUF — shows on the
controller's map on the very next inform, never a minute late. The price is
one process spawn and a JSON decode per heartbeat, which these boards do not
notice. (Upstream reuses the list for a minute to save that fork; this tree's
rule is that what the controller shows follows reality as soon as it can.)

### Point lldpd's chassis ID at the same interface as `lan_cpueth`

```sh
uci set lldpd.config.cid_interface='lan'
uci commit lldpd && /etc/init.d/lldpd restart
```

**Without this the controller cannot place the AP on its topology map**, and shows
some unrelated device (here the ISP's uplink) as the AP's Parent Device.

The reason is that two different MACs are involved. openUF identifies the device
by the MAC of `dev.conf.net.lan_cpueth`, and that is the MAC the controller
adopts it under. `lldpd`, left to itself, picks its chassis ID from whichever
interface it likes — in practice the lowest-numbered one, i.e. `eth0`. The
upstream gateway therefore learns the AP as a neighbour under a chassis ID that
does not match any adopted device, and silently declines to join the two.

Whether that bites is pure luck of the board's port naming:

| Board | `eth0` | `lan_cpueth` | Default chassis ID | Topology |
|---|---|---|---|---|
| TL-WDR3500 v1 | LAN trunk | `eth0` | matches identity | resolves by accident |
| Archer C5 v1 | unused WAN socket | `eth1` | **`eth0`, wrong** | Parent Device wrong |

Setting `cid_interface` to the LAN network makes the chassis ID the same MAC
openUF reports, and the controller resolves the uplink immediately — confirmed
live: an Archer C5 went from no `uplink_mac` at all to
`Cloud Gateway Ultra, port 4` on the next LLDP advertisement.

**openUF closes the other half of this itself.** The same two-MAC split has a second
symptom that LLDP does not cover: openUF reports its IP from the *bridge* `lan_cpueth` is
enslaved to (a bridge member carries no address of its own), so a DSA map that names a
socket announces the device under the socket's MAC while every frame it sends, and the ARP
entry for the address it reports, carry `br-lan`'s. The gateway sees one device claiming
the IP and another using it, and raises **"IP Address Conflict — multiple devices are using
the same address"** against a network that is perfectly configured (upstream saw this on
the AX3000T, whose map names `wan`).

`ucihelper.ensure_bridge_identity` runs once at daemon start and pins the bridge's
`macaddr` to `lan_cpueth`'s MAC when — and only when — the two differ, so identity, LLDP
and management traffic all agree, the way they do on a real UniFi AP. Boards where they
already match are untouched and no reload is issued — that includes this tree's JioRouter
maps, whose `lan_cpueth` *is* `br-lan`. It logs what it pinned; adoption is keyed on
`lan_cpueth`'s MAC, which it never changes.

> If the board takes its management address by **DHCP**, the new L2 identity means a new
> lease and possibly a new address. The adoption survives and openUF reports the new
> address on the next inform, but expect the change.

Verify the two agree:
```sh
lldpcli show chassis | grep ChassisID          # lldpd's identity
grep -o '"mac":"[^"]*"' /etc/openuf/state.json # openUF's identity
```

---

## 8. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Device doesn't appear in UniFi Discover, or WiFiman's Discovery tab lists it without model or name | `announce.lua` not running (`l2_announce = false` turns it off, responder included), or UDP port 10001 blocked. A failed listener bind is logged once (`announce: cannot listen on udp/10001`) and the broadcast carries on |
| Controller shows device as "Disconnected" | `inform.lua` not running, or wrong `inform_url` |
| Controller shows the device's IP as `0.0.0.0` although it has one | A build before 2026-10-26 read the address once at startup; on a DHCP-managed AP the service can start before the lease arrives (seen on both lab APs after a fresh install). `/etc/init.d/openuf restart` re-reads it; current builds re-read it every heartbeat |
| Adoption fails with SSH error | SSH not reachable from controller, or root password not set — run `passwd root` on the device, or reinstall with `--bootstrap-adopt` |
| Mobile app or controller asks for root credentials ("advanced adoption") although the `ubnt` account exists | `logread` shows `User 'ubnt' has invalid shell, rejected`: the account's forced shell is not in `/etc/shells`, which dropbear checks before the password. Run `openuf bootstrap-account`, or `sh install.sh install --bootstrap-adopt` on a file install — both register it for an existing account |
| Device stays stuck at "Adopting" forever | No AES-GCM backend — `lua-openssl` missing or built without AEAD support. The CLI `openssl-util` fallback is CBC-only and will not work (see § 1) |
| Controller rejects device ("firmware incompatible") | Adjust `fw.ver` in `ufmodel/u6iw.lua` |
| hostapd fails: "unknown configuration item 'bss_transition'" | A `wpad-basic-*` build is installed — replace it with `apk add wpad-wolfssl` |
| Multicast Suppression is on in the controller but nothing is filtered | `nft list table bridge openuf_bcfilt` shows the mode: `limit rate over` rules mean Conservative, `drop` rules mean Aggressive, an empty chain means nothing arrived. An empty chain with the control on means the keys were not pushed — Force Provision, and check `uci show wireless \| grep -E "openuf_mcast_suppress\|openuf_bcfilt"`. A table with the sets and no `meta pkttype` rule is the missing `kmod-nft-bridge`, which openUF logs by name |
| Aggressive suppression still breaks DHCP or ARP | Check the controller actually sent the carve-out: the push must carry `wireless.<n>.bcfilt.bypass_types`, and the live rules must show four `accept` lines **above** the drop for that VAP. An older controller sends `bcfilt.status` alone, in which case the drop applies to DHCP and ARP too — Ubiquiti's documented behaviour for that control — and the DHCP server's MAC has to go on the excepted-devices list |
| Conservative suppression drops traffic that was fine before | The ceiling is 100 packets/second with a 50-packet burst, and it is openUF's number, not the controller's — the wire sends none. Measured idle rates are 1.4–3.6 frames/s, so a site hitting it has real group-addressed volume. Raise `LIMIT_RATE`/`LIMIT_BURST` at the top of `openuf/bcfilter.lua`, or set the WLAN to Off |
| A client's Virtual Network Override does nothing | The controller only sends overrides when the site has a UniFi OS gateway and every AP and switch claims `fw_caps 0x80000000`: one device without it turns the feature off for the whole site. With `debug_dump_file` set in `conf.lua`, `grep accept_mac` the capture to see whether the keys arrived at all |
| The override arrives but the client stays on the SSID's network | `cat /etc/openuf/macvlan-openuf_*` is openUF's file; `cat /var/run/hostapd-<ifname>.maclist` is OpenWrt's when the WLAN also has a MAC Address Filter. `logread \| grep -i "MAC-based VLAN"` gives the reason an address was left out: a VLAN it could not build (no `lan_cpueth`), an allow list that does not permit it, a deny list that names it |
| A WLAN with an override vanished from the air | `logread \| grep -i "maclist\|accept_mac"`. hostapd drops the whole WLAN over an accept file it cannot read or a line it cannot parse, so the file went missing after it was written, or something else rewrote it |
| A 5 GHz radio has no SSID after a config push; `logread` shows `hostapd.add_iface failed` | `logread \| grep -B3 "errors found"`. *"Cannot enable IEEE 802.11h without IEEE 802.11d enabled"* means `ieee80211d=0` on a 5 GHz radio, which openUF builds before 2026-10-29 could write when a WLAN turned the Country IE off; upgrade, or `uci set wireless.<radio>.ieee80211d=1; uci commit; wifi` |
| A 5 GHz radio left its DFS channel and the controller logged nothing | The radar event comes off hostapd's control socket, so it needs a monitor attached: `pgrep -f '[h]ostapd_cli .*-a /tmp/openuf-bresp.sh'` must list one per BSS, and `hostapd-utils` must be installed. `grep DFS- /tmp/openuf-rrm.jsonl` right after a hostapd start on a DFS channel should show the CAC pair; if that is empty the monitors are not running |
| A 5 GHz radio is on the wrong channel after a radar hit and stays there | `sed -n '/openuf-cron-begin/,/openuf-cron-end/p' /etc/crontabs/root` must carry `0 2 * * * /usr/bin/syswrapper.sh dfs-reset`; if it does not, the controller is not pushing the job: it only does so for a radio pinned to a DFS channel the site's country allows (`uci get wireless.<radio>.channel` must be a number, not `auto`). Run `/usr/bin/syswrapper.sh dfs-reset` to ask for it now; `logread \| grep dfs-reset` gives the reason it was left alone. The commonest is the non-occupancy list: `iw phy phy<N> channels` shows the channel as `DFS state: unavailable` with the time left |
| Auto-channel still picks a DFS or blacklisted channel | Both keys only arrive for a radio whose channel is `auto`, and the blacklist half only then. `uci show wireless | grep -E "acs_exclude_dfs|chanlist"` shows what landed: the 5 GHz radio should carry `acs_exclude_dfs` matching Settings → Radios, and a radio on Auto in a site with a channel blacklist should carry a `chanlist` plus `openuf_chanlist=1`. Missing entirely: the controller is not sending them — `tools/heartbeat-probe.lua` must show `wifi_caps2` with bit `0x10` set (`0x2070` with roam reports on), and new wifi-device options need a **Force Provision**. Present in UCI but ACS ignores them: `grep -E "acs_exclude_dfs|chanlist" /var/run/hostapd-phy*.conf` — options reach hostapd only on a WiFi reload. `logread | grep -E "channel blacklist|auto-channel unrestricted"` names the three cases where openUF deliberately writes nothing (§ Auto-channel limits) |
| A WPA-Enterprise WLAN is on the air but no client can authenticate | Read hostapd's own truth: `grep -E "wpa_key_mgmt\|auth_server_addr\|auth_server_port\|acct_server_addr\|radius_acct_interim_interval\|dynamic_vlan\|nas_identifier\|wpa_passphrase" /var/run/hostapd-phy*.conf`. Expect `wpa_key_mgmt=WPA-EAP` (plus `FT-EAP` with 802.11r), the server lines, and **no** `wpa_passphrase`. `logread \| grep -i radius` shows what hostapd made of each exchange. If the server lines are there but nothing is answered, the AP cannot reach the server, or its shared secret differs — the server's own log is the place to look, and openUF never logs a secret |
| A WPA-Enterprise WLAN exists but `hostapd-phy*.conf` has no `auth_server_addr` | A `wpad-basic-*` build: it has no RADIUS client. openUF logs `WLAN "<ssid>" is WPA-Enterprise, but this hostapd has no RADIUS client` and provisions anyway, since the controller applies no capability gate here. `grep -c auth_server_addr /usr/sbin/hostapd` must be non-zero; swap in a full `wpad-*` as in the `bss_transition` row above |
| A WPA-Enterprise WLAN is skipped with `no usable RADIUS authentication server` | Every server the profile names was dropped. The log line gives the reason per index: a RadSec/TLS server (not supported), no usable IPv4 address, or a missing/oversized shared secret. A second server dropped for `has its own port/secret` is the schema limit described in § 6 |
| A Passpoint WLAN cannot be saved: `api.err.DevicePasspointNotSupported` | The controller needs **both** Hotspot 2.0 (`fw_caps` `0x800000`) and RadSec (`fw2_caps` `0x80000`) claimed. openUF claims them only when `/usr/share/ucode/wifi/ap.uc` knows `iw_enabled` and the hostapd binary carries `hs20_conn_capab` (`grep -c hs20_conn_capab /usr/sbin/hostapd`) — a `wpad-basic-*` build has neither, so swap in a full `wpad-*`. The capability fields openUF reports are in the inform payload (`tools/heartbeat-probe.lua`) |
| A Passpoint WLAN is on the air but clients see no ANQP data | Read hostapd's own truth: `grep -E "^(interworking|hs20|nai_realm|venue_name|venue_url|roaming_consortium|domain_name|anqp_3gpp_cell_net|hs20_oper_friendly_name|hs20_conn_capab|hs20_wan_metrics)=" /var/run/hostapd-phy*.conf`. New wifi-iface options need a **Force Provision** from the controller; a restart alone does not apply them. Plain `iw` will not show you the elements — ANQP answers are sent on request, not beaconed |
| The Passpoint WLAN's BSS does not come up at all after a profile change | A malformed value in a hostapd config is a **parse error, and hostapd then refuses the whole BSS**, not just the line. `logread | grep -i "Line \|Invalid"` right after a provision names the offending line. If it is one openUF wrote, report it: every mapped line is validated against a real hostapd, so a rejected one is a bug, not a setting |
| EAP clients authenticate but are then refused | The RADIUS profile has "RADIUS assigned VLAN: required" (`dynamic_vlan=2` in `hostapd-phy*.conf`) and the server returned a VLAN this AP has no network for — `cat /var/run/hostapd-<ifname>.vlan` lists the only ones it can honour. Set the mode to optional, or put the WLAN on a network that already carries those VLANs |
| A WLAN with MAC Authentication on never appears | It is skipped on purpose when openUF cannot set the ACL up. `logread | grep "requires RADIUS MAC authentication"` gives the reason: no usable RADIUS server in the profile, or a `wpad-basic-*` with no RADIUS client (`grep -c auth_server_addr /usr/sbin/hostapd`). Provisioning it without the ACL would leave the WLAN open to everyone |
| Every client is rejected on a MAC-authenticated WLAN | The RADIUS server is being asked in a format it does not know. OpenWrt's hostapd sends the MAC as twelve lower-case hex digits with no separators
  (`00005e005301`, seen in a FreeRADIUS log, 2026-10-29) as both User-Name and User-Password; the controller's `radius.macacl.format` (and `emptypassword`) only reach UniFi's own patched hostapd and are ignored here. List the MACs on the server in that form; the profile's MAC format setting has no effect here |
| CoA/Disconnect from the RADIUS server does nothing | Check `grep radius_das /var/run/hostapd-phy*.conf`: the line must read `radius_das_client=<server ip> <secret>` with a `radius_das_port`. If both are missing, the WLAN's profile has no accounting server or "RADIUS DAS" is off — the controller sends the keys only then. If the server sends from a different address than its accounting address, hostapd drops the request: the controller fills the DAS client from the **first accounting server**, and hostapd accepts only that one |
| Band Steering has no effect | `usteer` not installed or not running — `/etc/init.d/usteer status` |
| Clients are steered 2.4 → 5 GHz with Band Steering off | `ubus call usteer get_config` must show `band_steering_interval: 0`. Any other value means usteer's default applies, and it steers. openUF writes the 0 on the next WiFi config push. Force Provision if it is missing |
| Log says `device Band Steering mode "equal" is not supported` | The AP's own Band Steering is set to Balance. usteer can only balance by rejecting associations, so openUF does not map it. Use Prefer 5G or the per-WLAN toggle |
| Roaming Assistant never moves a weak client | Expected when no other AP hears it clearly better. Check `ubus call usteer get_client_info '{"address":"<mac>"}'`: another AP (`<ip>#hostapd.*`) on the same SSID and band needs a signal at or above the threshold and at least `roam_assist_diff_db` stronger. No remote entries at all means the usteer instances are not peering — both APs need usteer running on the same L2 network. `logread \| grep roamassist` shows every action |
| Airtime Fairness switch does nothing | `ls /sys/kernel/debug/ieee80211/phy*/airtime_flags` must list a file per radio. Without it openUF does not claim `wifi_caps` bit `0x20` and the controller sends no `atf.*` at all (debugfs not mounted, or a kernel without `CONFIG_MAC80211_DEBUGFS`). `cat` it after a push: two flag names for on, none for off. A driver that does not schedule through mac80211 TXQs ignores the flags |
| A WLAN Schedule switches at the wrong hours | The controller site has no timezone (Settings → System → Timezone shows *Select*), so none is pushed and the schedule's wall-clock times are read in UTC. Set the site timezone: `logread \| grep sysconf` then shows `timezone GMT0 -> <zone> (controller)` and `date` on the AP reads local time |
| Multicast/Broadcast Blocker on, but `nft list table bridge openuf_bcfilt` has no `drop` rule | The rules were built while a push's `wifi reload` was still bringing the VAPs up. openUF rebuilds them within a minute (`bcfilter: VAPs changed … -- rebuilding`); builds before 2026-10-26 waited for a daemon restart |
| An Enhanced Open WLAN is missing from the AP, or a transition one is plain open | The radio does not claim `radio_caps2` bit `0x8`. Check `hostapd -vowe; echo $?` (must print 0; `wpad-basic-*` or `-mini` builds may lack OWE) and that `/usr/share/ucode/wifi/hostapd.uc` exists (OpenWrt 24.10+). Force Provision after fixing it |
| A WLAN with Private Pre-Shared Keys is missing, or a key does not work | Missing: openUF does not claim `wifi_caps` bit `0x100000` (the controller logs "PPSK is not supported … will be skipped"). `grep -c vlanid= /usr/share/ucode/wifi/ap.uc` and `grep -c "from wpa_psk_file" /usr/sbin/hostapd` must both be non-zero. A VLAN key does not work: `uci show wireless \| grep psk` should list it, `cat /var/run/hostapd-<ifname>.psk` should have its `vlanid=` line, and `logread \| grep "from wpa_psk_file"` shows the VLAN hostapd assigned. openUF logs a key it left out because the VLAN had no network |
| A WLAN Schedule has no effect: the SSID stays up outside its schedule | The schedule waits for a trusted clock: `ls /var/run/openuf.clock-ok` must exist (openUF writes it once a controller answer's `server_time_in_utc` is within a minute of the local clock; after a reboot that is the first answered inform). Then `uci get wireless.<section>.openuf_schedule` lists the on-time lines (`1=07:00-22:00` is Monday) and `logread \| grep wlansched` shows each down/up. Windows are in the device's local time (`system.@system[0].timezone`) |
| A wired AP with Wireless Meshing on does not fail over when its cable is pulled; the parent's downlink sees no join attempt | No uplink station: `uci show wireless \| grep openuf_bh_ul` is empty. The controller sends the station entry only to a device it last saw meshed, and builds before 2026-10-29 removed the station on the next push to a cabled AP. Now openUF builds it from the mesh block and logs `backhaul: no mesh uplink in the push -- the station is built from the mesh block on <radio>`; `... no 5 GHz radio -- this AP cannot fail over` means it found no radio to put it on |
| A mesh child's SSID on the mesh radio (5 GHz on most boards) is missing from scans after a settings change, and `logread` has `hostapd: handle_probe_req: send failed` | The AP was left silent by the Wi-Fi reload (hostapd says ENABLED, `ip link show <phyN-apM>` says NO-CARRIER). openUF restarts its beacon within two heartbeats (`backhaul: <ifname> is up with no carrier while the station is joined -- restarted its beacon`). By hand: `hostapd_cli -i <ifname> raw STOP_AP; hostapd_cli -i <ifname> update_beacon` |
| Fast roaming between two openUF APs fails, and `logread` has `rrb-unifi: ... ignored: clock differs by N s (NTP?)` | The two clocks disagree. openUF compares each controller answer's time with the local clock and, when they are more than 60 s apart, restarts ntpd (`openuf: the clock is N s behind the controller's -- restarting ntpd`), at most every 5 minutes and less often while that does not help. If it keeps saying so, ntpd cannot reach its servers (`uci show system.ntp`, DNS, a default route), or the controller's own clock is wrong |
| Another openUF AP shows in Insights as a third-party AP broadcasting your SSID | Both APs must run a build with the sibling-AP element (2026-09-28 or later) and have had one config push since: `hostapd_cli -i <ifname> get_config` shows nothing for it, so check `uci get wireless.<section>.vendor_elements` (starts `dd0d026f55`), and on the other AP `ucode -e 'print(require("nl80211"))'` must not fail — the reader needs ucode's nl80211 module, which OpenWrt's own wifi scripts ship |
| A client shows poor WiFi Experience | Since 2026-10-18 the score is the UniFi firmware's own (`satisfaction.lua`): the lowest of signal (SNR over a noise floor taken as no lower than −96 dBm: 15 dB → 90, 25 dB → 100), PHY rate (the mean of the last tx and rx rates in steps: 54 Mbit/s → 80, 200 → 90, 400 → 95) and retries over the last full minute (≤ 25 % → 100, then down to 0 at 100 %, minus a point per dropped frame); `satisfaction_reason` names the term that bound and `anomalies` the weak ones. A fresh client scores 100 on retries until its first minute is complete. Before that the score was the worst of three terms, all read from `iw dev <ifname> station get <mac>`. **Downlink airtime**: Δ`tx duration` per Δ`tx packets` against the ideal (a fixed cost per frame — 110 µs on 2.4 GHz, 250 µs on 5 GHz, where the HE preamble, the BlockAck and the driver's RTS/CTS make every unaggregated frame dearer — plus the payload at the client's ceiling rate). Anything well over ~130 µs for small frames on 2.4 GHz, or ~280 µs on 5 GHz, means frames are being re-sent: a weak or noisy link, or a power-saving client that dozes through them. A client sending interactive traffic (one small frame per PPDU) is NOT penalised for that; a MacBook at −43 dBm doing exactly that was scored Poor on 2026-10-03 until the 5 GHz figure existed. **Uplink** (only while the client sends ≥ 20 frames between heartbeats, since `rx bitrate` is the last frame's rate): `rx bitrate` against the client's ceiling (its streams, width and top MCS from `hostapd_cli -i <ifname> all_sta`, capped by the AP's own, one MCS below the top). **Coverage**: `signal` minus the radio's noise (`iw dev <ifname> survey dump`, the `[in use]` entry, taken as at least −95 dBm): under 20 dB is below Excellent, under ~17 dB below Good. Retry and failure counters are not used, since they mean different things per driver (see PROTOCOL-VALIDATION.md). Without `tx duration` the tx rate against the ceiling stands in, and a client with a legacy rate or no hostapd record is scored on SNR alone |
| Locate/LED does nothing | `dev.conf.led` is `nil` in your modelmap — set it to a path from `ls /sys/class/leds` |
| JSON decode error in controller logs | AES key mismatch — try `syswrapper.sh reset-inform` |
| `inform: parse error: ... inflate: truncated stream` | A compressed controller response arrived incomplete. One heartbeat is lost and the next retries, so an occasional line is harmless; a steady stream of them points at the link to the controller (an MTU or proxy problem), not at the device. Before this the pure-Lua inflater spun forever on such a stream and the daemon went silent |
| **Adopted and healthy, but no pushed SSID is ever created** | **`libuci-lua` is missing** — the most likely cause by far, and it looks like nothing is wrong. Check with `lua -e 'print(pcall(require,"uci"))'`; fix with `apk add libuci-lua` and restart. Every wireless read/write is `pcall`-wrapped, so without it the device adopts, reports ports and statistics, and sends an **empty `radio_table`** — the controller has no radio to put a WLAN on, accepts the push, and creates nothing. openUF warns about this at startup (`logread \| grep openuf`) and `tools/check.sh` tests for it |
| SSID not appearing after adoption | Confirm the controller actually pushed it: set `debug_dump_file` in `conf.lua`, restart, and look for `wireless.*`/`aaa.*` keys in the `setparam` `system_cfg`. If the controller only ever sends `noop`, it believes the device is already configured — clear `cfgversion` in `state.json` and restart to force a full re-push. Then check `uci show wireless \| grep openuf` |
| Controller channel width is ignored; radio runs 802.11n | UniFi's `ieee_mode` token keeps the vestigial `ht` PHY marker and moves only the width, so 80 MHz arrives as `11naht80`. openUF used to take that literally as `HT80` — which does not exist — and `clamp_htmode` knocked it back to `HT40`, silently discarding the setting. Fixed: a width above 40 MHz promotes the token to `VHT`, the narrowest PHY that can express it. If the radio still runs below its capability, set a `dev.conf.radio.<band>.htmode_floor` |
| Radios provisioned but a **5 GHz** SSID never comes up | hostapd's ACS picked a **DFS** channel and the driver's CAC failed — `logread \| grep DFS` shows `start_dfs_cac() failed` then `AP-DISABLED`. Common on mt7915/mt7986 (filogic). Fix it in the modelmap with `dev.conf.radio.na.acs_exclude_dfs = true`, which restricts ACS to non-DFS channels (see **Radio policy**); pinning a non-DFS channel in the controller also works |
| `lldp_table` empty | `lldpd` not running — run `/etc/init.d/lldpd start` |
| Bootstrap account (`ubnt`) doesn't lock after adoption, or doesn't re-enable after a factory reset | `inform.lua` must be running for this — it's what detects the state change and runs `passwd -l`/`-u` (see § SSH prerequisite). Check `logread -e openuf`. |
| Adopted, but every inform is answered `HTTP 400` and the controller shows the device Offline | The identity MAC changed underneath the adoption: `dev.conf.net.lan_cpueth` now names a different interface than the device was adopted under (a modelmap switch, or a reinstall that reset `conf.lua`). openUF says so at startup (it compares against the MAC the previous run persisted) and again on the first 400 of a streak. Forget the device in the controller and re-adopt, or point `lan_cpueth` back |
| Insights → Environment shows nothing, or only right after boot | Nothing rescans: the kernel's BSS cache forgets neighbours after ~30 s and the controller drops entries with `age >= 30`. Set `neighbour_scan_interval` in `conf.lua` (§ 3), accepting the brief client stall each scan costs |
| Device clock wrong although `sysntpd` runs | Seen on AP2 (eight days slow, 2026-09-15). `logread \| grep ntpd` empty means the jailed daemon never got a reply. Unjailed `ntpd -q -n -N -p 0.openwrt.pool.ntp.org` syncs at once; the cause inside the jail is still open (REVERSE-ENGINEERING.md backlog row 13) |
| The controller does something and the device shows no sign of it | Look in `/etc/openuf/unhandled.json` (§ 3, `unhandled_file`) before arming `debug_dump_file`: if the controller sent a command or config key openUF does not implement, it is listed there with a count and its last body |
| `logread` says `cannot read a MAC from dev.conf.net.lan_cpueth` | The modelmap names an interface this board does not have (a generic profile on a DSA board, say). The daemon keeps informing under the identity `state.json` persisted; fix `conf.lua` |

Logs go to the system log via procd: `logread -e openuf` (follow with `logread -f`).

For development testing without hardware, see `tools/test_controller.py`.

### Measuring what a heartbeat costs on the device

`tools/heartbeat-probe.lua` builds one real inform payload and reports every
process it spawns and every file it opens, broken down by command and path. It
builds its own payload in a throwaway process, so it is safe to run on a live,
adopted AP alongside `openuf`.

```sh
ssh root@<ap> 'cat > /tmp/heartbeat-probe.lua' < tools/heartbeat-probe.lua
ssh root@<ap> 'cd /opt/openuf && lua /tmp/heartbeat-probe.lua'
```

Read the **steady** figure, not the cold one: the first payload of a process
warms everything TTL-cached across heartbeats (the phy dump, the uplink lookup,
the LLDP neighbour list), so it overstates what openUF pays every ten seconds.
Add `payload` as an argument to also print the payload on stdout, which is how
you show a change is behaviour-neutral — build one before and after, and diff
them with the live counters (`time`, `uptime`, byte/packet counts, `signal`,
`tx_mcs`, `satisfaction`, `satisfaction_now`, `anomalies`, `idletime`) scrubbed.

The probe measures the *build* half only. To confirm the daemon is still
informing, count outbound TCP connections — an AP originates almost nothing
else, so this rises once per heartbeat:

```sh
grep -A1 '^Tcp:' /proc/net/snmp | sed -n 2p | cut -d' ' -f6
```

Polling `netstat` for a connection to the controller does **not** work: a POST
is sub-second, and once-a-second sampling misses it on a perfectly healthy AP.
openUF logs nothing on success, so silence in `logread` is not evidence either
(`/tmp/openuf-status`, which `_tick` rewrites every cycle, is).
