---
paths:
  - "setup.sh"
---

## Changing `setup.sh`

The guided installer: interview → packages → openUF → AP conversion → reboot.

**The phase order is load-bearing.** Packages install *before* the network teardown,
because the teardown can take the device's internet with it (this box stops being the
router). A failure in the first three phases leaves a working router; a failure in the
fourth leaves a working router with openUF installed but idle. Do not reorder.

Other things to preserve:

- **The re-exec.** `wget -qO- … | sh` hands the *script* to the shell on stdin, so a
  `read` would consume the script's own remaining bytes. It re-execs from a file with
  stdin on `/dev/tty`. It must be an `exec`, not `exec < /dev/tty` mid-script, which would
  take the rest of the script away from the shell still reading it. And test whether
  `/dev/tty` can be **opened** (`( exec < /dev/tty )` in a subshell) — `[ -r /dev/tty ]`
  answers yes in places where the open then fails.
- **Every question is asked before anything changes**, and each has a matching option so
  the same script runs unattended. Adding a prompt means adding an option.
- **The 802.11r translator's packages go in the packages phase.** `ucode-mod-socket` and
  `kmod-veth` are in `OPTIONAL`, so they arrive while the box still has internet; the daemon
  itself is in the tree (`openuf/rrb/`) and `install.sh` enables its service, which `setup.sh`
  also does on its package path. No question, no option: `openuf.rrb.enabled '0'` switches the
  daemon off and `unifi_ft_interop` the whole feature.
- **Value-taking options** must go through `need_val`, or a forgotten value silently
  configures the empty string.

### Testing it without hardware

The technique used so far, and worth reusing: extract the real block from `setup.sh` with
`sed -n` and run it against stub functions, so the test exercises the shipped code rather
than a copy that can drift.

```sh
{ cat harness-prologue.sh                      # stub uci/init.d/say/ok/warn/die, fake state
  sed -n "$(grep -n '^absorb_wan_swconfig() {' setup.sh | cut -d: -f1),NNNp" setup.sh
} > /tmp/t.sh && sh /tmp/t.sh
```

Stub `uci` over a flat `key=value` file — and use `grep -F` / `grep -vF`, because section
ids like `@switch_vlan[0]` are regex character classes and a plain `grep` silently matches
the wrong thing (this cost a debugging cycle and looked like a script bug).

Shapes worth covering: DSA and swconfig; untagged- and tagged-CPU swconfig; 21.02+
(`config device` bridge) and pre-21.02 (`network.lan.type=bridge`) layouts; every refusal
path; and the static-address forms `1.2.3.4/24`, `1.2.3.4,255.255.255.0`, bare `1.2.3.4`.

### The AP conversion

Reversible, and committed but not applied until the reboot. `wan`/`wan6` deleted,
`dhcp.lan.ignore=1`, `firewall`/`dnsmasq`/`odhcpd` stopped and disabled (packages kept),
`/tmp/resolv.conf` relinked to `resolv.conf.auto` (nothing listens on 127.0.0.1 once
dnsmasq is off, and a hostname inform URL would stop resolving), radios un-`disabled`,
`lldpd.config.cid_interface` set.

Moving the WAN socket is two different jobs — on DSA its netdev joins `br-lan`; on
swconfig `absorb_wan_swconfig` moves the physical port into the LAN VLAN inside the switch
(bridging the WAN *CPU* netdev works but hairpins every frame through the SoC). That
function refuses and falls back to the bridge unless it can prove the geometry. Keep it
that way.

An interface with proto `pppoe`/`wwan`/`dhcpv6` is **named and left alone**, not deleted —
it may be a management link.
