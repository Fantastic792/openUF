# Automatic Transmit Power Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Radios on controller "Auto" power lower or raise their own TX power, once a night, from how loudly they hear the network's other APs in a controller-triggered scan.

**Architecture:** A new pure module `openuf/autotx.lua` holds the rule. After a quick-scan or spectrum-scan finishes on a radio (`hostwatch.lua` `_scan_job_tick`), openUF reads that radio's `scan dump` and keeps only BSSes carrying this AP's own SSIDs. It runs the rule and stores the result as UCI options on the `wifi-device`. `ucihelper.rf_config` turns a controller "auto" into `max - offset` while the switch is on.

**Tech Stack:** Lua 5.1 (OpenWrt), UCI, `iw`, LuCI JS; tests via `lua tests/run_tests.lua`.

**Spec:** `docs/superpowers/specs/2026-11-25-auto-txpower-design.md`

**One deviation from the spec:** per-radio state lives in UCI on the `wifi-device`, not state.json:
- `openuf_autotx_offset` (dB below max)
- `openuf_autotx_at` (epoch seconds of the last change)

This keeps it next to `txpower`, survives restarts like state.json does, and is removed with the radio.

## Global Constraints

- Switch: `openuf.main.auto_txpower`, default `'0'`. LuCI: openUF Settings, tab "WiFi behaviour", title "Automatic transmit power".
- Acts only when the controller sends `txpower=auto` with no `txpower_mode` low/medium (rf_config's `txpwr == "auto"`).
- Rule:
  - loudest same-network AP above -67 dBm: offset + 3
  - below -75 dBm: offset - 3
  - none heard: offset 0
- Offset bounds: 0..12 dB (max - 12 = the Low floor).
- At most one change per radio per 20 h (72000 s).
- One stderr log line per change: `autotx: <radio>: heard <dBm|none>, <old> -> <new> dBm`.
- No lab IPs/MACs in code, tests or commits. Commits as Fantastic792 with the Co-Authored-By trailer. Gate before each commit.

## Review Focus

1. **Turning the switch off or picking Low/Medium/High/Custom** must restore the controller's value at once. The offset is cleared and not reapplied on the next push. Task 3 test.
2. **Own BSSIDs in the scan** (all VAPs of this AP, both radios) must never count as a neighbour. Task 2 test.
3. **A neighbour SSID that matches ours on a foreign AP** (e.g. the home router uses the same name) is counted. This is accepted: same SSID = same roaming domain. Documented in the module header, no test.
4. **The scan dump holding the other band's BSSes** (multi-band phy) must not steer this radio. Filter by this radio's band. Task 2 test.
5. **Unknown max** (phy_caps empty) leaves txpower deleted (driver max) and does not crash. Task 3 test.

---

### Task 1: The rule (`openuf/autotx.lua`)

**Files:**
- Create: `openuf/autotx.lua`
- Test: `tests/test_autotx.lua`
- Modify: `tests/run_tests.lua` (only if test files are listed explicitly there; check first)

**Interfaces:**
- Produces:
  - `autotx.decide(heard, offset, last_at, now) -> new_offset, changed`
    - `heard`: number dBm or nil
    - `offset`: number 0..12
    - `last_at`: number or nil
    - `now`: number
    - returns a number and a boolean
  - Constants `autotx.HIGH = -67`, `autotx.LOW = -75`, `autotx.STEP = 3`, `autotx.MAX_OFFSET = 12`, `autotx.MIN_GAP = 72000`.

- [ ] **Step 1: Write the failing tests** in `tests/test_autotx.lua` (same return-a-list-of-{name,fn} shape as `tests/test_led.lua`):

```lua
local a = dofile("openuf/autotx.lua")
-- "autotx: a loud neighbour steps down 3 dB"
assert_eq(select(1, a.decide(-60, 0, nil, 100000)), 3)
-- "autotx: a faint neighbour steps up"
assert_eq(select(1, a.decide(-80, 6, nil, 100000)), 3)
-- "autotx: between -75 and -67 holds"
local o, ch = a.decide(-70, 6, nil, 100000); assert_eq(o, 6); assert_eq(ch, false)
-- "autotx: no neighbour goes straight to full power, even inside the gap"
assert_eq(select(1, a.decide(nil, 9, 99000, 100000)), 0)
-- "autotx: never below the Low floor nor above max"
assert_eq(select(1, a.decide(-40, 12, nil, 100000)), 12)
assert_eq(select(1, a.decide(-90, 0, nil, 100000)), 0)
-- "autotx: one change per 20 hours"
local o2, ch2 = a.decide(-60, 3, 100000 - 3600, 100000); assert_eq(o2, 3); assert_eq(ch2, false)
assert_eq(select(1, a.decide(-60, 3, 100000 - 72000, 100000)), 6)
```

- [ ] **Step 2: Run** `lua tests/run_tests.lua 2>&1 | grep -E "autotx|Results"`. Expected: the autotx tests fail (module missing).
- [ ] **Step 3: Implement `M.decide`** with the constants above. "No neighbour" bypasses the gap: it is a return to safety, per the spec's anti-goal.
- [ ] **Step 4: Run again.** Expected: all pass, `Results: N passed, 0 failed`.
- [ ] **Step 5: Gate and commit** "autotx: the power rule".

### Task 2: What this radio hears (`autotx.loudest_peer`)

**Files:**
- Modify: `openuf/autotx.lua`
- Test: `tests/test_autotx.lua`

**Interfaces:**
- Consumes: the `sysinfo.scan_table(ifname)` rows `{bssid, essid, signal, channel, ...}`.
- Produces: `autotx.loudest_peer(rows, own_ssids, own_bssids, band) -> dBm|nil`
  - `own_ssids`, `own_bssids`: sets `{[name]=true}`, BSSIDs lower-case
  - `band`: `"ng"` or `"na"`; a row's band comes from its channel, 2.4 GHz for channel <= 14, else 5 GHz

- [ ] **Step 1: Failing tests:**

```lua
local rows = {
  {bssid="00:00:5e:00:53:01", essid="LabTest", signal=-58, channel=36},  -- peer, 5 GHz
  {bssid="00:00:5e:00:53:02", essid="LabTest", signal=-50, channel=6},   -- peer, other band
  {bssid="00:00:5e:00:53:03", essid="Neighbour", signal=-40, channel=40},-- not ours
  {bssid="00:00:5e:00:53:aa", essid="LabTest", signal=-20, channel=36},  -- our own VAP
  {bssid="00:00:5e:00:53:04", essid="LabTest", signal=-64, channel=44},
}
local ss, bs = {LabTest=true}, {["00:00:5e:00:53:aa"]=true}
-- "autotx: loudest same-SSID AP on this band, own BSSIDs and other bands ignored"
assert_eq(a.loudest_peer(rows, ss, bs, "na"), -58)
assert_eq(a.loudest_peer(rows, ss, bs, "ng"), -50)
-- "autotx: nobody of ours heard -> nil"
assert_eq(a.loudest_peer(rows, {Other=true}, bs, "na"), nil)
-- "autotx: upper-case BSSID in the dump still matches our own"
```

- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Compare BSSIDs lower-cased.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Gate and commit** "autotx: loudest same-network peer per band".

### Task 3: Apply it (`rf_config`, the switch, LuCI)

**Files:**
- Modify: `openuf/ucihelper.lua`
  - `rf_config`, the `txpwr == "auto"` branch near the Low/Medium code added in 6b16071
  - the `apply_config` opts table that already passes `honour_width`
- Modify: `openuf/conf.lua` (`auto_txpower = false`, after `honour_controller_width`)
- Modify: `openuf/uciconf.lua` (add `"auto_txpower"` to `BOOL_OPTS`)
- Modify: `package/openuf/files/openuf.config` (`option auto_txpower '0'` with a one-line comment)
- Modify: `package/luci-app-openuf/htdocs/luci-static/resources/openuf/common.js` (flags list)
- Modify: `package/luci-app-openuf/htdocs/luci-static/resources/view/openuf/settings.js` (`form.Flag`, after `honour_controller_width`, default `'0'`, `rmempty = false`)
- Test: `tests/test_ucihelper.lua`

**Interfaces:**
- Consumes: UCI `wireless.<radio>.openuf_autotx_offset` (written by Task 4).
- Produces: `opts.auto_txpower` (boolean) on `rf_config`. When true and `txpwr == "auto"`:
  - `txpower = max - offset` when `offset > 0` and max is known
  - otherwise the option is deleted, as today

  When false, or `txpwr` is anything but `"auto"`: delete `openuf_autotx_offset` and `openuf_autotx_at`.

- [ ] **Step 1: Failing tests** (pattern of "Transmit Power Low/Medium run below the radio's max": `JIDU6101_IW_PHY`, `seed_radios({"radio1"})`, band 5g, `max = ucihelper.phy_caps().na.max_txpower`):
  - "autotx: auto with an offset runs max - offset":
    - set `openuf_autotx_offset='6'`
    - `rf_config("radio1", nil, nil, "auto", nil,nil,nil,nil,nil,nil, {auto_txpower=true})`
    - assert `txpower == tostring(max - 6)`
  - "autotx: switch off restores Auto and forgets the offset":
    - same, with `{auto_txpower=false}`
    - assert `txpower == nil` and `openuf_autotx_offset == nil`
  - "autotx: a Custom dBm from the controller wins":
    - offset 6, `txpwr=17`, `{auto_txpower=true}`
    - assert `txpower == "17"` and the offset is gone
  - "autotx: unknown max leaves the driver's max":
    - `_popen` returns `""`, offset 6
    - assert `txpower == nil`
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**, plus the config/LuCI wiring. The LuCI help text says:
  - On: radios set to Auto on the controller lower their power, at most 3 dB a night, when another AP of this network is heard louder than -67 dBm, and never below Low.
  - Off: Auto means full power.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Gate and commit** "autotx: switch, rf_config applies the offset".

### Task 4: Run after a scan (`hostwatch.lua`)

**Files:**
- Modify: `openuf/hostwatch.lua`
  - `M._scan_job_tick`: where the finished job is removed (`if not job.freqs or job.next > #job.freqs`)
  - new `M._autotx_after_scan(job, cfg)`
- Test: `tests/test_inform_*.lua`. Use the file that already tests `_scan_job_tick`; find it with `grep -ln _scan_job_tick tests/`.

**Interfaces:**
- Consumes:
  - `autotx.decide` and `autotx.loudest_peer` (Tasks 1, 2)
  - `M._sysinfo.scan_table(job.ifname)`
  - UCI `wireless` for this radio's `wifi-iface` `ssid`s and its own `macaddr`/live BSSIDs (as get_vap_table already reads them)
  - `cfg.config.auto_txpower`
- Produces: on change:
  - writes `openuf_autotx_offset` and `openuf_autotx_at`
  - re-runs the radio's txpower through the same code as rf_config (or sets `txpower = max - offset` directly)
  - commits wireless, `wifi reload`
  - logs the Global Constraints line

- [ ] **Step 1: Failing test** "autotx: a finished quick-scan that hears a loud peer lowers the radio 3 dB":
  - fake one job for radio1 with `who="quick-scan"` and no freqs left
  - `scan_table` returns one same-SSID row at -60 on ch 36
  - switch on; offset unset
  - assert `openuf_autotx_offset == "3"` and `txpower == tostring(max - 3)`
  - second test: switch off → nothing written
  - third test: `who="11k"` → nothing written
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Only for `who == "quick-scan"` or `"spectrum-scan"`, only when the radio's UCI has no fixed `txpower` other than one autotx set, and wrapped in `pcall` (the scan tick is on the inform path).
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Gate and commit** "autotx: decide after the controller's scan".

### Task 5: Prove on the two JIDU6401s, README

**Files:**
- Modify: `README.md` ("Fixed after 1.0.5, not released yet" list: a "New:" bullet)
- Modify: `NOTES.md` (Log line)

- [ ] **Step 1:** Copy `autotx.lua`, `hostwatch.lua`, `ucihelper.lua`, `uciconf.lua`, `conf.lua` and the two LuCI files to both units, with backups to `/root/pre-fix3`. Then `uci set openuf.main.auto_txpower=1`, commit, and restart openuf.
- [ ] **Step 2:** On the controller, run Channel AI "Quick Scan". Expected:
  - each unit logs one `autotx:` line
  - `iw dev phy1-ap0 info` shows the new txpower
  - the controller's device page shows the same dBm
- [ ] **Step 3:** Set unit 1's 5 GHz to Custom 20. Expected: 20 dBm, and the offset is gone from UCI. Back to Auto: full power until the next scan.
- [ ] **Step 4:** README bullet:
  - "New: Automatic transmit power (off by default)", with a one-sentence rule
  - "proven on hardware" only for what Steps 2–3 showed
- [ ] **Step 5:** Gate and commit "README: automatic transmit power". NOTES Log line.
