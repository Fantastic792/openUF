# Auto transmit power (design)

Date: 2026-11-25. Status: proposed, waiting for the owner's approval.

## Why

UniFi has no automatic power control on 2.4/5 GHz: Channel AI moves channels only, and
"Auto" power means full power. With several APs close together, full power makes
clients hold on to a far AP instead of roaming to the near one. The owner wants openUF to
set each radio's power itself, with the practical mix: roaming first, a coverage floor,
and "set and forget" behaviour.

## Goals

- Each radio set to Auto on the controller picks its own power so that neighbouring APs of
  the same network meet at a usable roaming edge.
- Never worse coverage than the owner's "Low" (max - 12 dB), and full power when the AP
  hears no other AP of its network.
- Rare, small, visible changes.

## Non-goals

- No change when the controller says Low, Medium, High or Custom: the owner's choice wins.
- No AP-to-AP protocol in this version.
- No off-channel scans of its own: it only reuses scans the controller already asks for.

## Anti-goals (a failure even if it "works")

- Power that changes often or flips up and down.
- A change that drops connected clients outside the scan window.
- A lone AP, or an AP whose neighbour went offline, left at reduced power.

## Approaches considered

1. **Each AP decides alone from its own scan** (picked). Small: one module, a toggle,
   tests. Weak point: assumes the link is equal both ways (if A hears B at -60 dBm, B
   hears A about the same), which is off when the APs are different hardware.
2. **APs share their measurements over the LAN** (Meraki-like). Fixes that weak point,
   but adds discovery, a protocol and failure cases. Too much for a first version.
3. **Use clients' 802.11k reports.** Only about 3 in 13 clients answer: too unreliable
   to steer power.

## Design (approach 1)

- **Switch:** `openuf.main.auto_txpower` (UCI) and LuCI, openUF Settings, WiFi behaviour,
  "Automatic transmit power". Default off.
- **Applies to:** radios whose controller Transmit Power is Auto (wire `txpower=auto`,
  no `txpower_mode` low/medium). Any other setting turns it off for that radio and puts
  the controller's value back at once.
- **Input:** after a controller-triggered scan (the Channel AI quick scan or its nightly
  run) completes on a radio, read the BSS list and keep only APs of the same network,
  recognised by the SSIDs this AP itself serves, minus its own BSSIDs. Per band.
- **Rule:** loudest same-network AP heard on that band:
  - above -67 dBm: lower this radio 3 dB
  - below -75 dBm: raise 3 dB
  - none heard: back to full power
- **Limits:** between max - 12 dB and max (max = the band's driver limit, as today); at
  most one change per radio per 20 hours (one per night); never during the scan's own
  window plus 5 minutes.
- **Output:** writes `wireless.<radio>.txpower`, reload like any push. The real dBm
  already flows to the controller (the live `txpower` read), so the UI shows it. One
  log line per change: radio, heard level, old and new dBm.
- **State:** last change time and current offset per radio in the existing state file,
  so a restart does not undo or repeat a step.
- **Tests:** the rule (down/up/none/floor/ceiling/once a night), the "Auto only" gate,
  the SSID filter. Proof on the two JIDU6401s, then the roaming walk.

## Left to the builder

Where exactly the scan-complete hook sits (inform.lua's scan job), the state-file key
names, the hysteresis band between -67 and -75 if the walk shows it needs tuning.

## Future plans

1. **Tune the numbers from the roaming walk:** target, hysteresis and step from the
   laptop's measured roam points, not guesses.
2. **AP-to-AP sharing (approach 2):** each AP publishes what it heard (a small UDP
   message on the LAN, or reuse usteer's peer link when usteer runs), so the rule uses
   "how loud B hears A" instead of the both-ways guess. Needed for mixed hardware.
3. **Client reports as a bonus input:** where 802.11k clients answer (rrmscan already
   collects this), use their view of each AP to check for dead spots before lowering.
4. **Coverage guard from real clients:** if clients on this radio sit below a weak
   level (say -75 dBm) after a step down, undo the step.
5. **Neighbour-gone fast path:** if a same-network AP stops being seen (or the
   controller reports it offline), go straight back to full power without waiting for
   the night.
6. **Per-band defaults:** 2.4 GHz usually needs a lower target than 5 GHz (it reaches
   further); split the target per band once data shows it.
7. **6 GHz:** follow the regulatory AFC rules if a 6 GHz board is ever supported.
8. **Upstream:** offer it to yesrab/openUF as a separate, small PR once proven.
