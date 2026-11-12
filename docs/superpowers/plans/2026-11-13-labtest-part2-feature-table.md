# labtest Part 2: Feature Table in the VM Lab — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command flips every controller setting on a lab VM, one at a time, and writes a table that says for each: works, ignored, broken, not sent, or not covered. Four extra tests (flash writes, install cycle, garbage from a fake controller, day-long run) sit next to it.

**Architecture:** A catalog reads the controller's own field list and turns each on/off or pick-one field into a row. The row runner changes one setting through the controller API, reads the push openUF received (openUF's own `debug_dump_file`), compares the router's whole config before and after, and puts the setting back. Hand-written checks upgrade a row from "not covered" to "works" or "broken". Everything reuses Part 1's `Target`, `Controller`, `results` and the self-heal timer.

**Tech Stack:** Python 3 stdlib, `requests`, `cryptography` (both already in WSL), `unittest`, plain `ssh`. No new library, no download.

**Spec:** `docs/superpowers/specs/2026-11-12-test-system-design.md` (Part 2). Part 1 plan: `docs/superpowers/plans/2026-11-12-labtest-part1-safety-net.md`.

## Global Constraints

- The old tests (`tests/`, `tools/`, the gate, `lab.sh`, `install-openuf.sh`) stay as they are. Call them, never edit them.
- No address, MAC, key, PSK or password in repo files. Lab config is `/root/vmlab/labtest.json`; results go to `results_dir`. Test fixtures are made up by hand, never copied from the lab.
- `labtest/` is never packed into openUF (the pack guard from Part 1 keeps checking).
- Claude never sees or types the controller password. Code reads `account_file`; nothing prints it.
- Only the lab controller and lab VMs. Code that breaks a target on purpose refuses `kind != "vm"`.
- Report first: this plan does not fix openUF bugs it finds. A bug that stops the run itself: stop and ask the owner.
- Never push. Only branch `jonas-merge`. Commits as `Fantastic792 <shichandak79@hotmail.com>` with the Co-Authored-By trailer. Gate + secret scan green before every commit (`openuf-gate` skill).
- Every commit step also runs `python3 -m unittest discover -s labtest/tests -t .` and it must pass.
- Results are stamped with the git commit (`results.save` does it).

## Review Focus

1. **The run dies in the middle of a row** (Ctrl-C, WSL sleeps). The setting must not stay flipped: the next start puts it back first. Test in Task 4 (`test_pending_row_is_put_back_at_start`).
2. **The controller refuses the put-back.** The run must stop loudly, not go on flipping. Test in Task 4 (`test_failed_put_back_stops_the_run`).
3. **The login runs out after hours.** One silent re-login from the account file, then the same call again. Test in Task 2 (`test_401_logs_in_again_once`).
4. **A PSK or key lands in a result file.** Values of secret-named keys are replaced before anything is stored. Test in Task 3 (`test_secret_values_never_stored`).
5. **A field file with a shape nobody expected** (a list, a nested object, a number). The catalog must count it as "other", not crash. Test in Task 1 (`test_odd_shapes_are_other`).

## Files

| File | Job |
|---|---|
| `labtest/catalog.py` | Read the field files; say what each field is and how to flip it |
| `labtest/unifi.py` (modify) | `Refused`, re-login, `settings()`, `device()`, `locate()` |
| `labtest/snapshot.py` | The router's whole config as lines; redaction; diff |
| `labtest/push.py` | Turn openUF's push dump on and off; read the pushes |
| `labtest/rows/__init__.py` | Row list, risk rules, the registry of real checks |
| `labtest/rows/wifi.py` | The first real checks |
| `labtest/table.py` | Run rows, classify, journal, heal handling |
| `labtest/report.py` | `table.md` for people |
| `labtest/extra/writes.py`, `cycle.py`, `fake.py`, `garbage.py`, `soak.py` | The four extra tests |
| `labtest/run.py` (modify) | Stages `catalog`, `table`, `writes`, `cycle`, `garbage`, `soak`, `vm` |
| `labtest/tests/test_*.py` | One per module, with fake `Target` / `Controller` as in `test_plug.py` |

New keys in `/root/vmlab/labtest.json` (outside the repo): `fields_dir`, `row_wlan` (name of the WLAN rows may change, e.g. the lab's plain WPA2 one), `lab_host` (the PC's address on the lab bridge), and a target `vm4` (`kind` `vm`, `lab_n` 4) used as a scratch VM.

---

### Task 1: Catalog

**Files:** Create `labtest/catalog.py`, `labtest/tests/test_catalog.py`. Modify `labtest/run.py`, `labtest/README.md`.

**Interfaces — Produces:**
- `catalog.kind(spec) -> tuple[str, list | None]`: `("bool", [True, False])` for `"true|false"` / `"false|true"`; `("enum", [..literals..])` for an alternation of plain words (letters, digits, `_ - . +`), with or without `^( )$` around it; else `("other", None)`.
- `catalog.load(fields_dir) -> list[dict]`: one `{"obj", "key", "kind", "values"}` per top-level key of every `*.json` file; `obj` is the file name without `.json`.
- `catalog.in_scope(obj) -> bool`: `WlanConf`, `Device`, and every `Setting*` except `SettingSuper*`.
- `catalog.section(obj) -> str | None`: `SettingGuestAccess` -> `guest_access`; not a `Setting*` -> `None`.
- `catalog.flip(field, current) -> value | None`: bool -> `not bool(current)`; enum -> the literal after `current` (wrapping), `None` when `current` is absent or not in the list; other -> `None`.

- [ ] **Step 0 (owner, once):** the field list sits inside the controller's `internal-dependencies.jar` (not `ace.jar`), already on disk. Ask the owner to run this in a terminal, then set `fields_dir` to `/root/vmlab/unifi-fields/api/fields` in `labtest.json`:

```bash
wsl -u root -- unzip -o -q /root/re/ace10.6.106/internal-dependencies.jar "api/fields/*" -d /root/vmlab/unifi-fields
```

- [ ] **Step 1: Write the failing tests** (`test_catalog.py`, field files written to a temp dir by the test):

```python
def test_kinds(self):
    self.assertEqual(catalog.kind("true|false"), ("bool", [True, False]))
    self.assertEqual(catalog.kind("^(disabled|optional|required)$"), ("enum", ["disabled", "optional", "required"]))
    self.assertEqual(catalog.kind("open|wpapsk|wpaeap"), ("enum", ["open", "wpapsk", "wpaeap"]))
    self.assertEqual(catalog.kind(".{1,32}"), ("other", None))
    self.assertEqual(catalog.kind("^[0-9]{1,3}$"), ("other", None))

def test_odd_shapes_are_other(self):
    for spec in (["a|b"], {"x": "true|false"}, 5, None, ""):
        self.assertEqual(catalog.kind(spec), ("other", None))

def test_load_and_scope(self):
    # temp dir: WlanConf.json {"hide_ssid": "true|false", "name": ".{1,32}"}, SettingSuperMgmt.json {...}, Broken.json "not json"
    fields = catalog.load(self.dir)
    self.assertIn({"obj": "WlanConf", "key": "hide_ssid", "kind": "bool", "values": [True, False]}, fields)
    self.assertTrue(catalog.in_scope("SettingGuestAccess"))
    self.assertFalse(catalog.in_scope("SettingSuperMgmt"))
    self.assertFalse(catalog.in_scope("NetworkConf"))
    self.assertFalse(any(f["obj"] == "Broken" for f in fields))  # an unreadable file is skipped, not fatal

def test_section_and_flip(self):
    self.assertEqual(catalog.section("SettingGuestAccess"), "guest_access")
    self.assertIsNone(catalog.section("WlanConf"))
    b = {"kind": "bool", "values": [True, False]}
    e = {"kind": "enum", "values": ["disabled", "optional", "required"]}
    self.assertIs(catalog.flip(b, None), True)
    self.assertIs(catalog.flip(b, True), False)
    self.assertEqual(catalog.flip(e, "required"), "disabled")
    self.assertIsNone(catalog.flip(e, None))
    self.assertIsNone(catalog.flip({"kind": "other", "values": None}, "x"))
```

- [ ] **Step 2:** Run `python3 -m unittest labtest.tests.test_catalog -v`. Expected: FAIL (no module `catalog`).
- [ ] **Step 3:** Implement `catalog.py`.
- [ ] **Step 4:** Add stage `catalog` to `run.py`: fails with `no fields_dir` when the key or folder is missing; else one line `PASS catalog` with detail printed even on pass: files, fields, in-scope fields per object group (WlanConf / Device / Setting), and bool / enum / other counts in scope. Write the same numbers to `results_dir/catalog.json`.
- [ ] **Step 5:** Run the tests (PASS), then `python3 labtest/run.py catalog`. Expected: `PASS catalog` and real counts. Write the counts into the plan ledger: they settle the spec's unknown "how many settings the controller has".
- [ ] **Step 6:** README: add the stage row and the `fields_dir` key. Gate, commit `feat(labtest): catalog of controller settings`.

### Task 2: Controller client

**Files:** Modify `labtest/unifi.py`, `labtest/tests/test_unifi.py`.

**Interfaces — Produces:**
- `class unifi.Refused(RuntimeError)`: raised on HTTP 400; text is the path plus the reply's `meta.msg` only (never the body, never on `/api/login`).
- `Controller._check`: on HTTP 401 for any path but `/api/login`, call `login()` once and repeat the request; a second 401 raises `RuntimeError`.
- `Controller.settings() -> list` (`rest/setting`); `Controller.device(host) -> dict | None` (from `stat/device`, by `ip`).
- `Controller.locate(obj, host, wlan_name) -> tuple[str, dict] | None`: the PUT path and the current object. `WlanConf` -> `rest/wlanconf/<_id>` of the WLAN named `wlan_name`; `Device` -> `rest/device/<_id>` of the device at `host`; `Setting*` -> `rest/setting/<section>/<_id>`; `None` when the site has no such object.

- [ ] **Step 1: Failing tests** (extend the fake session in `test_unifi.py`):

```python
def test_400_is_refused_with_the_controllers_reason(self):
    self.session.replies = [answer(400, meta={"rc": "error", "msg": "api.err.InvalidPayload"})]
    with self.assertRaises(unifi.Refused) as e:
        self.c.put("rest/wlanconf/1", {"x": 1})
    self.assertIn("api.err.InvalidPayload", str(e.exception))

def test_401_logs_in_again_once(self):
    self.session.replies = [answer(401), answer(200), answer(200, data=[{"_id": "1"}])]  # call, login, call again
    self.assertEqual(self.c.get("rest/wlanconf"), [{"_id": "1"}])

def test_second_401_raises(self):
    self.session.replies = [answer(401), answer(200), answer(401)]
    with self.assertRaises(RuntimeError):
        self.c.get("rest/wlanconf")

def test_locate(self):
    # fake data: wlan "T" id w1; device ip "h" id d1; setting key guest_access id s1
    self.assertEqual(self.c.locate("WlanConf", "h", "T")[0], "rest/wlanconf/w1")
    self.assertEqual(self.c.locate("Device", "h", "T")[0], "rest/device/d1")
    self.assertEqual(self.c.locate("SettingGuestAccess", "h", "T")[0], "rest/setting/guest_access/s1")
    self.assertIsNone(self.c.locate("SettingNtp", "h", "T"))
```

- [ ] **Step 2:** Run, expect FAIL. **Step 3:** Implement. **Step 4:** Run, expect PASS; the Part 1 tests for `unifi` still pass.
- [ ] **Step 5:** Gate, commit `feat(labtest): controller client finds objects, survives a login timeout`.

### Task 3: Snapshot and push capture

**Files:** Create `labtest/snapshot.py`, `labtest/push.py`, `labtest/tests/test_snapshot.py`, `labtest/tests/test_push.py`.

**Interfaces — Produces:**
- `snapshot.SECTIONS`: `uci` = `uci show`; `hostapd` = every `/var/run/hostapd-*.conf` with a `## <file>` line before each; `nft` = `nft -s list ruleset` (no counters); `tc` = `tc qdisc show`; `ip` = `ip -br link; ip -br addr`.
- `snapshot.redact(line) -> str`: when the name left of `=` contains `key`, `psk`, `passphrase`, `password`, `secret` or `token`, the value becomes `<8 hex of its sha256>`. So a change still shows, the secret does not.
- `snapshot.take(t) -> dict[str, list[str]]` (redacted lines per section; raises `RuntimeError` if SSH fails).
- `snapshot.diff(a, b, ignore=frozenset()) -> list[str]`: `"<section>: -<line>"` / `"<section>: +<line>"`, skipping entries in `ignore`.
- `snapshot.volatile(a, b) -> frozenset[str]`: `diff(a, b)` of two snapshots taken at rest; used as `ignore`.
- `snapshot.bss(snap, ssid) -> list[list[str]]`: the hostapd lines of each BSS block (a block starts at `interface=` or `bss=`) that has `ssid=<ssid>`.
- `push.DUMP = "/tmp/labtest-dump"`, `push.CONF = "/opt/openuf/conf.lua"`, backup `CONF + ".labtest-bak"`.
- `push.on(t)`: if a backup exists, put it back first; back up; set the `debug_dump_file = nil,` line to `debug_dump_file = "/tmp/labtest-dump",`; restart openUF. Raises if the line is not there.
- `push.off(t)`: move the backup back, delete the dump, restart openUF.
- `push.parse(text) -> list[dict]`: one `{"cfgversion", "keys"}` per dump line whose JSON has `system_cfg`. A dump line is `<UTC time> <JSON>`; `system_cfg` and `mgmt_cfg` are strings of `key=value` lines; `mgmt_cfg` keys get the prefix `mgmt.`; values go through `redact`. Lines that do not parse are skipped.
- `push.pushes(t) -> list[dict]`: `parse` of the dump on the target.
- `push.sent(old, new) -> list[str]`: `"-k=v"` / `"+k=v"` for keys that differ, leaving out `mgmt.cfgversion`.

- [ ] **Step 1: Failing tests:**

```python
# test_snapshot.py
def test_secret_values_never_stored(self):
    for line in ("wireless.w.key='hunter2hunter2'", "wpa_passphrase=hunter2hunter2", "aaa.1.radius_secret=hunter2hunter2"):
        out = snapshot.redact(line)
        self.assertNotIn("hunter2", out)
        self.assertEqual(out, snapshot.redact(line))                    # stable
    self.assertNotEqual(snapshot.redact("wpa_passphrase=a"), snapshot.redact("wpa_passphrase=b"))  # a change shows
    self.assertEqual(snapshot.redact("wireless.w.ssid='Lab'"), "wireless.w.ssid='Lab'")

def test_diff_and_volatile(self):
    a = {"uci": ["x=1", "y=1"], "tc": ["q 5"]}
    b = {"uci": ["x=2", "y=1"], "tc": ["q 6"]}
    self.assertEqual(snapshot.diff(a, b), ["tc: -q 5", "tc: +q 6", "uci: -x=1", "uci: +x=2"])
    self.assertEqual(snapshot.diff(a, b, ignore=frozenset(["tc: -q 5", "tc: +q 6"])), ["uci: -x=1", "uci: +x=2"])

def test_bss_blocks(self):
    snap = {"hostapd": ["## f", "interface=p0", "ssid=A", "ignore_broadcast_ssid=0", "bss=p1", "ssid=B", "ap_isolate=1"]}
    self.assertEqual(snapshot.bss(snap, "B"), [["bss=p1", "ssid=B", "ap_isolate=1"]])
    self.assertEqual(snapshot.bss(snap, "Z"), [])

def test_take_raises_when_ssh_fails(self): ...   # fake target returning (255, "")

# test_push.py  (made-up lines, no lab data)
LINE1 = '2026-01-01T00:00:00Z {"_type":"setparam","mgmt_cfg":"cfgversion=aa\\nauthkey=0011\\n","system_cfg":"wireless.1.ssid=T\\nwireless.1.hide_ssid=false\\n"}'
LINE2 = LINE1.replace("cfgversion=aa", "cfgversion=bb").replace("hide_ssid=false", "hide_ssid=true")
def test_parse_and_sent(self):
    p = push.parse("\n".join([LINE1, '2026-01-01T00:00:10Z {"_type":"noop"}', "garbage", LINE2]))
    self.assertEqual([x["cfgversion"] for x in p], ["aa", "bb"])
    self.assertNotIn("0011", str(p))                                   # authkey redacted
    self.assertEqual(push.sent(p[0], p[1]), ["-wireless.1.hide_ssid=false", "+wireless.1.hide_ssid=true"])
def test_on_puts_back_a_left_over_backup_first(self): ...   # fake target records the commands, in order
def test_on_raises_when_the_conf_line_is_missing(self): ...
```

- [ ] **Step 2:** Run, expect FAIL. **Step 3:** Implement both modules. **Step 4:** Run, expect PASS.
- [ ] **Step 5 (lab):** lab up, vm1 connected. In a Python one-off: `push.on(t)`; `ctl.force_push(...)` twice (there and back); print `len(push.pushes(t))` (expected 2 or more) and `push.sent(...)` of the last two (expected: only U-APSD keys); take two snapshots 15 s apart and print `len(volatile)`; `push.off(t)`; check `conf.lua` equals its backup hash from before. If a real dump line does not parse, fix `parse` and add a made-up line of that shape to the test.
- [ ] **Step 6:** Gate, commit `feat(labtest): router config snapshot and push capture`.

### Task 4: Row runner, first pass, report

**Files:** Create `labtest/rows/__init__.py`, `labtest/table.py`, `labtest/report.py`, tests `test_rows.py`, `test_table.py`, `test_report.py`. Modify `labtest/run.py`, `labtest/README.md`.

**Interfaces — Consumes:** `catalog.load/in_scope/flip`, `Controller.locate/put/Refused`, `snapshot.take/diff/volatile`, `push.on/off/pushes/sent`, `heal.arm/Knocker/healed/disarm`, `proof._openuf_back`, `plug._connected`, `results.save`.

**Interfaces — Produces:**
- `rows.risk(field) -> str`: `"skip: secret"` when the key starts with `x_`; `"skip: not a simple on/off or pick-one"` for kind `other`; `"cutoff"` when the key matches `(^|_)(vlan|network|networkconf|ip|ssh|uplink|disabled|switch|port|lan|stp|dhcp|dns|gateway)(_|$)`; else `"safe"`.
- `rows.build(fields) -> list[dict]`: in-scope fields as rows `{"name": "<obj>.<key>", "obj", "key", "field", "risk", "needs": "vm", "set": None}` (`needs` is what the row must have to run; Part 3 adds `hw` and `phone`); safe rows first, cut-off rows last, skipped rows kept (they are reported). A row from the registry (Task 5) replaces the automatic row of the same name.
- `table.PUSH_WAIT = 25`, `table.APPLY_WAIT = 60` (seconds).
- `table.one(env, row) -> dict`: `{"name", "result", "note", "sent", "changed", "secs"}`; `result` is one of `works`, `ignored`, `broken`, `not_sent`, `not_covered`.
- `table.run(conf, t, ctl, rows) -> dict`: `{"pass", "counts", "rows"}`; saves `table.json` after every row; at the end writes `table.md` and a kept copy `table-<commit>-<YYYYMMDD-HHMM>.json` (one file per run). `pass` = the run finished and no row is `broken`.
- `report.markdown(result) -> str`: counts on top, then one table per result, worst first (broken, ignored, not covered, not sent, works), columns Row / Note / Sent keys / Router changes (first 3 of each, then "+N more").
- Journal: `results_dir/table-pending.json` = `{"path", "old"}`, written before a flip, deleted after the put-back is verified.

**How one row runs:**

| Step | What | Outcome if it stops here |
|---|---|---|
| 1 | `risk` says skip | `not_covered`, note = the reason |
| 2 | `ctl.locate` gives `None` | `not_covered`, "the site has no such object" |
| 3 | new body: `row["set"](current_object)` when the row has one, else `{key: flip(field, current)}`; flip gives `None` | `not_covered`, "not set on this object" |
| 4 | write the journal; `logger -t labtest "row <name>"` on the target; snapshot `before`; note the push count and openUF's pid | |
| 5 | `ctl.put(path, new)`; `Refused` | `not_covered`, "controller refused: <msg>" (journal deleted) |
| 6 | wait up to `PUSH_WAIT` for a new push whose `sent(...)` against the last push is not empty | none: `not_sent` |
| 7 | wait up to `APPLY_WAIT` until `cfgversion` in the target's `/etc/openuf/state.json` equals the push's | timeout: `broken`, "push not applied in 60 s" |
| 8 | snapshot `after`; `changed = diff(before, after, ignore)` | |
| 9 | health: target reachable, openUF running, same pid, no line since the `labtest: row` mark in `logread` matching `traceback\|attempt to (index\|call\|compare\|perform\|concatenate)\|lua: ` | fails: `broken`, note says which |
| 10 | classify: `changed` empty -> `ignored`; a real check exists -> `works` / `broken` by the check; else `not_covered`, "router changed, no check yet" | |
| 11 | put back (always, in `finally`): `ctl.put(path, old)`; if a push was seen, wait for the next push and apply; GET the object and compare the touched keys with `old` (absent equals `False`); snapshot must equal `before` | "did not go back" -> `broken` |

`old` holds the touched keys' earlier values; a key that was absent is restored as `False` (bool).

**Around the rows (`table.run`):** refuse nothing by kind (rows run on hardware too in Part 3). At start: put back a pending journal entry; `push.on`; `heal.arm`; `Knocker` for the whole run; two snapshots 15 s apart give `ignore`; one `force_push` there and back gives the baseline push. A row that leaves the target unreachable: wait `proof.LIMIT + 240` s for it to return; mark the row `broken`, "cut off, healed by the timer" (or "cut off, did not come back": stop the run); on `kind == "hw"` stop the run (the stop rule); on a VM: `heal.disarm`, `proof._openuf_back`, put the setting back, `plug._connected`, `push.on`, `heal.arm`, go on. A put-back that fails or raises: stop the run, `pass` False, the journal stays for the next start. At the end: `push.off`, `heal.disarm` (nothing may be left), save.

- [ ] **Step 1: Failing tests** (`FakeTarget` answers by command substring; `FakeController` holds objects and records puts; `time.sleep` patched out; waits injected as `env`):

```python
# test_rows.py
def test_risk(self):
    f = lambda key, kind="bool": {"obj": "WlanConf", "key": key, "kind": kind, "values": None}
    self.assertEqual(rows.risk(f("x_passphrase", "other")), "skip: secret")
    self.assertEqual(rows.risk(f("name", "other")), "skip: not a simple on/off or pick-one")
    self.assertEqual(rows.risk(f("hide_ssid")), "safe")
    for k in ("vlan_enabled", "networkconf_id", "disabled", "mgmt_vlan", "x_ssh_enabled"):
        self.assertNotEqual(rows.risk(f(k)), "safe")
    self.assertEqual(rows.risk(f("wlan_band")), "safe")          # "wlan" is not "lan"
def test_build_orders_safe_before_cutoff_and_keeps_skipped(self): ...

# test_table.py — one test per line of the table above, plus:
def test_no_push_is_not_sent(self): ...                          # result "not_sent", setting put back, no wait for apply
def test_push_but_no_router_change_is_ignored(self): ...         # "sent" lists the key
def test_router_change_without_check_is_not_covered(self): ...   # "changed" lists the lines
def test_lua_error_in_log_is_broken(self): ...
def test_openuf_restart_is_broken(self): ...                     # pid changed
def test_refused_put_is_not_covered_and_nothing_is_left(self): ...
def test_pending_row_is_put_back_at_start(self): ...             # journal file present -> first put restores "old"
def test_failed_put_back_stops_the_run(self): ...                # pass False, later rows not run, journal kept
def test_cut_off_row_on_a_vm_is_broken_and_the_run_goes_on(self): ...
def test_cut_off_row_on_hardware_stops_the_run(self): ...
def test_absent_bool_goes_back_as_false(self): ...
def test_results_are_saved_after_every_row(self): ...

# test_report.py
def test_markdown_puts_broken_first_and_counts_on_top(self): ...
```

- [ ] **Step 2:** Run, expect FAIL. **Step 3:** Implement `rows/__init__.py`, `table.py`, `report.py`. **Step 4:** Run, expect PASS.
- [ ] **Step 5:** Stage `table` in `run.py` with `--only REGEX` (row names) and `--limit N`. Prints `PASS table` / `FAIL table` with the counts, e.g. `212 rows: 0 broken, 58 ignored, 24 not covered, 97 not sent, 33 works`.
- [ ] **Step 6 (lab, trial):** `python3 labtest/run.py table --target vm1 --only '^WlanConf\.' --limit 10`. Expected: finishes, every row has a result, `table.json` and `table.md` exist, the WLAN equals its state before (compare `rest/wlanconf` by hand once), no `labtest` file left on vm1, `conf.lua` unchanged. Note seconds per row in the ledger. If pushes arrive later than 25 s, raise `PUSH_WAIT` and say so in the ledger.
- [ ] **Step 7:** README: the stage, the five results, the journal, the new config keys. Gate, commit `feat(labtest): feature table, first pass`.

### Task 5: Real checks

**Files:** Create `labtest/rows/wifi.py`, `labtest/tests/test_rows_wifi.py`. Modify `labtest/rows/__init__.py` (registry), `labtest/table.py` (call the check).

**Interfaces — Produces:**
- `rows.CHECKS: dict[str, dict]`: row name -> `{"set": callable(current_object) -> dict, "check": callable(blocks, new) -> tuple[bool, str]}`. `blocks` = `snapshot.bss(after, <WLAN name>)`; `new` = the body that was set.
- `rows.wifi` fills `CHECKS` on import. A row in `CHECKS` is `safe` and replaces the automatic row.

First rows (each bool is flipped from its current value; the check follows the value that was set):

| Row | Set | Every hostapd block of the WLAN must |
|---|---|---|
| `WlanConf.enabled` | `enabled` flipped | exist when true; not exist when false |
| `WlanConf.hide_ssid` | flipped | `ignore_broadcast_ssid=1` when true; `=0` or no such line when false |
| `WlanConf.uapsd_enabled` | flipped | `uapsd_advertisement_enabled=1` when true; `=0` or absent when false |
| `WlanConf.l2_isolation` | flipped | `ap_isolate=1` when true; `=0` or absent when false |
| `WlanConf.pmf_mode` | next of disabled / optional / required | `ieee80211w=0` / `1` / `2` (absent counts as 0) |
| `WlanConf.group_rekey` | `7200` if it is not 7200, else `3600` | `wpa_group_rekey=<value>` |
| `WlanConf.dtim` | `dtim_mode=custom`, `dtim_na=3`, `dtim_ng=3` (or 2 if already 3) | `dtim_period=<value>` |
| `WlanConf.fast_roaming_enabled` | flipped | when true: a `mobility_domain=` line and `FT-` in `wpa_key_mgmt`; when false: neither |

- [ ] **Step 1: Failing tests:** for each row, a made-up block that satisfies it and one that does not, both values; `test_registry_row_replaces_the_automatic_one`; `test_check_result_decides_works_or_broken` in `test_table.py`.
- [ ] **Step 2:** Run, expect FAIL. **Step 3:** Implement. **Step 4:** Run, expect PASS.
- [ ] **Step 5 (lab):** `python3 labtest/run.py table --target vm1 --only '^WlanConf\.(enabled|hide_ssid|uapsd_enabled|l2_isolation|pmf_mode|group_rekey|dtim|fast_roaming_enabled)$'`. A red row is a finding, not a reason to edit the check: write it in the findings file with the row's `sent` and `changed` lines. Only when those lines show openUF did the right thing in another valid form may the check change, with a one-line comment saying why.
- [ ] **Step 6:** Gate, commit `feat(labtest): first real checks for WLAN rows`.

### Task 6: Flash write counter and install cycle

**Files:** Create `labtest/extra/__init__.py`, `labtest/extra/writes.py`, `labtest/extra/cycle.py`, tests `test_writes.py`, `test_cycle.py`. Modify `labtest/run.py`, README.

**Interfaces — Produces:**
- `writes.sectors(t) -> int`: sum of field 7 of `/sys/block/*/stat`, leaving out `ram*`, `loop*`, `zram*`.
- `writes.mark(t)` (touch `/tmp/labtest-mark`); `writes.changed(t) -> list[str]`: files under `/etc /opt/openuf /usr/lib/openuf /root` newer than the mark.
- `writes.run(conf, t, ctl, idle=600) -> dict`: `{"pass", "idle": {"secs", "sectors", "files"}, "push": {"sectors", "files"}}`. Idle: openUF connected, no push, for `idle` seconds. Push: one `force_push` there and back, wait for both applies. `pass` = `idle["files"]` is empty. The push numbers are only recorded (Part 5 sets limits). Saves `writes.json`.
- `cycle.leftovers(before, after, keep=KEEP) -> list[str]`: paths in `after` and not in `before`, minus prefixes in `KEEP`.
- `cycle.KEEP: list[tuple[str, str]]` (prefix, reason). Starts empty. The implementer reads `install.sh`'s `uninstall)` block and adds only what that block keeps on purpose, each with the `install.sh` line as the reason.
- `cycle.run(conf, t) -> dict`: refuses `kind != "vm"` and refuses a target that is adopted (it wipes the install). Steps: fresh VM (`lab.sh reset N; start N`, wait, `provision N; prepare N`); file list `before` (`find / -xdev -type f`, without `/proc /sys /dev /tmp /var/run`); install the tree (`install-openuf.sh N <repo>`); openUF must run; `sh /opt/openuf/install.sh uninstall` (the path the installer leaves; read `install-openuf.sh` for it); `leftovers` must be empty; install `v0.13.0` (`git archive v0.13.0` into a temp dir, no download); install the current tree over it; openUF must run, `conf.lua` kept (hash equal before and after the second install), no Lua error line in `logread`. Saves `cycle.json` with each step's result.

- [ ] **Step 1: Failing tests:** `test_sectors_sums_real_disks_only` (canned `stat` text), `test_idle_file_write_fails_the_run`, `test_push_numbers_are_recorded_not_judged`, `test_leftovers_respects_keep`, `test_cycle_refuses_hardware`, `test_cycle_refuses_an_adopted_target`, `test_cycle_stops_at_the_first_failed_step`.
- [ ] **Step 2:** Run, expect FAIL. **Step 3:** Implement. **Step 4:** Run, expect PASS.
- [ ] **Step 5 (lab):** add `vm4` to `/root/vmlab/labtest.json`. `python3 labtest/run.py writes --target vm1` (about 12 min) and `python3 labtest/run.py cycle --target vm4`. Anything red goes to the findings file. Leave vm4 stopped after.
- [ ] **Step 6:** README, gate, commit `feat(labtest): flash write counter and install cycle`.

### Task 7: Garbage from a fake controller

**Files:** Create `labtest/extra/fake.py`, `labtest/extra/garbage.py`, tests `test_fake.py`, `test_garbage.py`. Modify `labtest/run.py`, README.

**Interfaces — Produces:**
- `fake.DEFAULT_KEY = "ba86f2bbe107c7c57eb5f2690775c712"` (the public key every un-adopted UniFi device uses; same constant as `state.lua`).
- `fake.encode(payload: bytes, mac: bytes, key_hex=DEFAULT_KEY) -> bytes`: the inform frame, AES-128-CBC, not compressed. Layout as `tools/test_controller.py` `encode_packet` (read it; do not import it, it needs a library that is not installed): `TNBU`, version 1, 6-byte MAC, 2-byte flags (encrypted = 1), 16-byte IV, data version 1, 4-byte length, ciphertext. Uses `cryptography`.
- `fake.Server(host, port=18080)`: HTTP server in a thread; `server.next = callable(request_bytes) -> (status, body_bytes) | "close" | ("slow", secs)`; `server.informs` counts requests; `start()`, `stop()`.
- `garbage.CASES: dict[str, callable]`: `empty_body`, `http_500`, `random_bytes` (512), `short_header` (first 10 bytes of a frame), `huge_length` (length field `0xFFFFFFFF`, 16 bytes follow), `undecryptable` (valid header, random payload), `not_json` (`{{{`), `wrong_types` (four frames in turn: `{"_type": 5}`, `{"_type":"setparam","system_cfg":12345}`, `{"_type":"cmd","cmd":null}`, `[]`), `two_megabytes` (`system_cfg` of 2 MB of `a`), `cut_mid_body` (Content-Length 1000, 10 bytes, close), `slow_40s`. No case sends a real command (no reboot, no reset, no valid config).
- `garbage.run(conf, t) -> dict`: refuses `kind != "vm"` and an adopted target. Points openUF's `inform_url` line in `conf.lua` at `http://<lab_host>:18080/inform` (backup first, restore at the end), restarts it, waits 60 s for the first inform (none: FAIL "no inform reached the fake"). After each case: a new inform within 60 s, same openUF pid, no Lua error line in `logread`, memory of `inform.lua` (VmRSS) at most twice the start value, `md5sum` of `/etc/config/*` unchanged. Saves `garbage.json`, one entry per case.

- [ ] **Step 1: Failing tests:** `test_encode_round_trips` (decrypt with `cryptography`, compare), `test_frame_header_fields` (magic, MAC, flags, length), `test_every_case_gives_a_reply_and_none_is_a_command` (no frame decodes to `_type` `cmd` with a non-null `cmd`, nor to a string `system_cfg` under 1 MB), `test_refuses_hardware`, `test_refuses_adopted`, `test_crash_after_a_case_fails_that_case` (pid changed), `test_config_change_after_a_case_fails_that_case`, `test_conf_is_restored_even_when_a_case_raises`.
- [ ] **Step 2:** Run, expect FAIL. **Step 3:** Implement. **Step 4:** Run, expect PASS.
- [ ] **Step 5 (lab):** `python3 labtest/run.py garbage --target vm4` (fresh vm4 with the current tree, as the cycle leaves it; about 15 min). Red cases go to the findings file. Stop vm4 after.
- [ ] **Step 6:** README, gate, commit `feat(labtest): garbage from a fake controller`.

### Task 8: Day-long run, the `vm` stage, first full pass

**Files:** Create `labtest/extra/soak.py`, `labtest/tests/test_soak.py`. Modify `labtest/run.py`, README. Notes: findings file (below).

**Interfaces — Produces:**
- `soak.sample(t, ctl) -> dict`: `{"t", "rss_kb": {"inform": int, "announce": int}, "fds", "tmp_files", "tmp_kb", "sectors", "pid", "connected"}` (VmRSS from `/proc/<pid>/status` of `lua inform.lua` and `lua announce.lua`; files and size of `/tmp/openuf*` and `/etc/openuf`).
- `soak.verdict(samples) -> tuple[bool, list[str]]`: fails when a sample is not connected, the pid changes, or the median memory of the last hour is more than 1.2 times the median of the first hour (same rule for open files and temp size).
- `soak.run(conf, t, ctl, hours=24, every=300, push_every=1800) -> dict`: a sample every 5 min, a `force_push` there and back every 30 min, `soak.json` saved after every sample (a run that dies keeps its samples).
- Stage `soak` takes `--hours` (default 24). Stage `vm` = `catalog`, `table`, `writes`, `cycle` (on `vm4`), `garbage` (on `vm4`), in that order, stopping at the first failed stage. `soak` is not in `vm`.

- [ ] **Step 1: Failing tests:** `test_verdict_passes_flat_memory`, `test_verdict_fails_twenty_percent_growth`, `test_verdict_fails_on_pid_change`, `test_verdict_fails_when_not_connected`, `test_samples_survive_a_dead_run` (file written after each sample), `test_vm_stage_stops_at_first_failure`.
- [ ] **Step 2:** Run, expect FAIL. **Step 3:** Implement. **Step 4:** Run, expect PASS. Then `python3 labtest/run.py soak --target vm1 --hours 0.2` in the lab: two samples, PASS.
- [ ] **Step 5:** README: all Part 2 stages with needs and run times measured so far. Gate, commit `feat(labtest): day-long run and the vm stage`.
- [ ] **Step 6 (lab, first full pass):** `nohup python3 labtest/run.py table --target vm1 > /root/vmlab/results/table.log 2>&1 &` with the WSL keep-alive running. When it ends: read `table.md`. Then start the 24 h `soak` the same way (owner's OK for the lab to stay up a day).
- [ ] **Step 7 (report):** write `docs/superpowers/sdd/2026-11-13-labtest-part2-feature-table/findings.md` in the notes folder: the counts, then every broken row, every ignored row and every red extra test, worst first, one line each, no lab address. First entry is already known: each mid-apply power cut leaves a `/etc/config/.wireless.uci-*` temp file that nothing cleans up. Bookkeeping (`openuf-bookkeep`). Then stop: the owner picks what gets fixed first.

## Not in this plan

- Fixing anything the table finds (report first).
- Checks beyond the eight in Task 5: they are written worst gap first, after the owner has seen the first report.
- The lab rows owed by the v2.0 plan (Task 12: push replay, UCI address, Lock to AP, guest limits, DAS, SNMP). They become hand rows once this runner exists.
- Rows for objects that must be created first (networks, RADIUS profiles, user groups, AP groups) and for nested device fields (the radio table). The catalog counts them as out of scope so they stay visible.
- Sharing rows over three VMs (only if a full pass is too slow).
- Limits on the write counter and on memory (Part 5).

## Known unknowns

| Unknown | Settled by |
|---|---|
| How many settings, and how many are on/off or pick-one | Task 1 Step 5 |
| The exact shape of a dump line on 10.6.106 | Task 3 Step 5 |
| Seconds per row, and whether 25 s is enough to see a push | Task 4 Step 6 |
| The lab can run a fourth VM | Task 6 Step 5 |
| `v0.13.0` installs with today's `install-openuf.sh` | Task 6 Step 5 (if not: use `v0.14.0_beta5` and note it) |
| An un-adopted openUF takes `inform_url` from `conf.lua` | Task 7 Step 5 |
