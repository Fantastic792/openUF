# labtest Part 1 (Safety Net) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the safety net of the new test system: two guards, a self-heal timer for routers, and VM proofs that the timer and a power cut never leave a target dead.

**Architecture:** A new top-level `labtest/` folder in the repo (Python 3, plus one POSIX sh script that runs on the router). One runner, `labtest/run.py`, runs named stages and prints one PASS/FAIL line per check. Everything about the lab (addresses, key, controller login, results) lives outside the repo in `/root/vmlab/`.

**Tech Stack:** Python 3.14 stdlib + `requests` (both already in WSL), `unittest`, plain `ssh`, POSIX sh (busybox ash on the router), the existing `/root/vmlab/lab.sh` (called, never changed).

**Spec:** `docs/superpowers/specs/2026-11-12-test-system-design.md` (Part 1). Read it first.

## Global Constraints

- Repo: `/root/jonas-merge`, branch `jonas-merge` only. Never push. Run everything through `.claude/scripts/wsl.sh` (skill `openuf-wsl`).
- The old `tests/`, `tools/`, `.claude/scripts/gate.sh` and `lab.sh` are not edited. Calling them is fine.
- No downloads. No pytest (not installed): tests are `unittest`, run with
  `python3 -m unittest discover -s labtest/tests -t . -v` from the repo root.
- No lab address, MAC, key, PSK or password in any repo file, test or commit. Example addresses in tests use `198.51.100.x`.
- Nothing under `labtest/` may end up in a built package.
- This part runs on lab VMs only. Code that breaks a target on purpose must refuse any target whose `kind` is not `"vm"`.
- The controller password is read from a file and never printed, logged or put in an exception text.
- `labtest/safety/heal.sh` must pass both `bash -n` and `sh -n` (the gate checks every tracked `.sh`).
- Timer values from the spec: knock every **10** seconds, heal after **180** seconds with no knock, heal **once** then switch off.
- Every commit: gate green + secret scan clean first (skill `openuf-gate`), author `Fantastic792 <shichandak79@hotmail.com>`, with the Co-Authored-By trailer. Gate fails -> no commit.
- Lab state changes (start, stop, reset a VM) are done by the lead, not a subagent.

## Review Focus

Failure modes the spec implies; each has its test in the task named.

1. The router's clock jumps (time sync after boot): the timer must not heal early. It counts with `/proc/uptime`, never wall time or file dates. (Task 3)
2. The saved config is missing or corrupt when a heal fires: `/etc/config` must be left as it is, and openUF is still stopped, the mark written, the router rebooted. (Task 3)
3. A run dies and the next run arms again on a target that is in a bad state: `arm` must never overwrite an existing saved config, and must refuse a target that carries the "healed" mark. (Task 3)
4. A forbidden flash call sits in a file with no extension or an odd one: the flash guard scans every tracked text file under `openuf/` and `package/`, whatever its name. (Task 2)
5. Flash is full when `arm` saves the config: `arm` must fail loudly and leave no timer running. (Task 3)

## File Structure

| File | Job |
|---|---|
| `labtest/__init__.py`, `labtest/safety/__init__.py`, `labtest/tests/__init__.py` | Empty. |
| `labtest/target.py` | Load the lab config; run commands on one target over `ssh`. |
| `labtest/results.py` | Save and read result files, stamped with the git commit. |
| `labtest/safety/flashguard.py` | Find firmware or flash writes in openUF's code. |
| `labtest/safety/packguard.py` | Prove `labtest/` is not in the built package. |
| `labtest/safety/heal.sh` | The self-heal timer. Runs on the router. |
| `labtest/safety/heal.py` | Runner side of the timer: arm, knock, check, disarm. |
| `labtest/safety/proof.py` | Break a VM three ways and watch it heal. |
| `labtest/unifi.py` | Small controller API client (login, WLANs, devices, force a push). |
| `labtest/safety/plug.py` | Kill a VM in the middle of a config change, boot it, check it. |
| `labtest/run.py` | The command: `guards`, `proof`, `plug`, `safety` (all three in order). |
| `labtest/README.md` | How to run it, the config file's shape, the manual reset-button check. |
| `labtest/tests/test_*.py` | Unit tests; none needs the lab. |

Outside the repo, made by hand in Task 1: `/root/vmlab/labtest.json`. Made by the owner before Task 5: `/root/vmlab/labtest-account`.

Not in this plan (they are enforced where hardware runs are built, in the Part 3 plan): refusing a hardware row that is not green in the VM on the same commit, stopping a hardware run at the first heal, and recording the reset-button check. This part delivers the pieces they need: `results.last()`, `results.commit()`, `heal.healed()`.

---

### Task 1: Skeleton, targets and results

**Files:**
- Create: `labtest/__init__.py`, `labtest/safety/__init__.py`, `labtest/tests/__init__.py`, `labtest/target.py`, `labtest/results.py`, `labtest/run.py`, `labtest/README.md`
- Test: `labtest/tests/test_target.py`, `labtest/tests/test_results.py`
- By hand, outside the repo: `/root/vmlab/labtest.json`

**Interfaces (produced):**

```python
# labtest/target.py
def load_config(path: str | None = None) -> dict
    # path defaults to $LABTEST_CONF, else /root/vmlab/labtest.json. Missing file -> SystemExit with the path named.
class Target:
    name: str; host: str; kind: str      # kind is "vm" or "hw"
    lab_n: int | None                    # the N of lab.sh, VMs only
    def ssh(self, cmd: str, timeout: int = 20, stdin: bytes | None = None) -> tuple[int, str]
        # (exit code, stdout+stderr). Unreachable or timed out -> (255, ""). Never raises for those.
    def put(self, local: str, remote: str, mode: str = "755") -> None   # RuntimeError on failure
    def reachable(self) -> bool                    # ssh "true" with timeout 5
    def wait(self, up: bool, secs: int) -> bool    # poll every 5 s until reachable == up
def get_target(conf: dict, name: str) -> Target    # unknown name -> SystemExit listing the known names

# labtest/results.py
def commit(repo: str = ".") -> str                 # short hash; "+dirty" added when `git status --porcelain` is not empty
def save(conf: dict, name: str, data: dict) -> str # writes <results_dir>/<name>.json with "commit" and "date" added; returns the path
def last(conf: dict, name: str) -> dict | None
```

`ssh` options (same as `lab.sh`): `-i <ssh_key> -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes`, user `root`. `put` sends the file through `ssh ... "cat > remote && chmod mode remote"` on stdin (no scp on the router).

Shape of `/root/vmlab/labtest.json`:

```json
{
  "controller": "https://127.0.0.1:8443",
  "site": "default",
  "account_file": "/root/vmlab/labtest-account",
  "ssh_key": "/root/vmlab/id_lab",
  "lab_sh": "/root/vmlab/lab.sh",
  "results_dir": "/root/vmlab/results",
  "targets": { "vm1": { "host": "<vm1's lab address, see the lab.sh header>", "kind": "vm", "lab_n": 1 } }
}
```

- [ ] **Step 1: Write the failing tests**

```python
# labtest/tests/test_target.py  (subprocess.run is patched with unittest.mock)
def test_ssh_returns_code_and_output():      # run -> returncode 0, stdout "ok\n"  => (0, "ok\n")
def test_ssh_timeout_is_255_not_an_error():  # run raises subprocess.TimeoutExpired => (255, "")
def test_ssh_command_has_key_and_batchmode():# argv contains "-i", conf key path, "BatchMode=yes", "root@198.51.100.7"
def test_put_raises_on_failure():            # run -> returncode 1 => RuntimeError
def test_get_target_unknown_name_exits():    # SystemExit, message contains "vm1"
def test_load_config_missing_file_exits():   # SystemExit, message contains the path

# labtest/tests/test_results.py  (results_dir = a tempfile.mkdtemp())
def test_save_adds_commit_and_date_and_last_reads_it():
    p = results.save(conf, "timer-proof", {"pass": True})
    d = results.last(conf, "timer-proof")
    assert d["pass"] is True and d["commit"] and d["date"]
def test_last_is_none_when_no_file():
def test_commit_marks_a_dirty_tree():        # in a temp git repo with an untracked file: endswith("+dirty")
```

- [ ] **Step 2: Run them, see them fail**

Run: `python3 -m unittest discover -s labtest/tests -t . -v` — Expected: errors, `No module named 'labtest.target'`.

- [ ] **Step 3: Write `target.py` and `results.py`** to the interfaces above.

- [ ] **Step 4: Write `run.py`** with `argparse`: `python3 labtest/run.py <stage> [--target NAME]`, default target `vm1`. A stage is a function that returns a list of `(check_name, passed, detail)`. `run.py` prints `PASS <name>` or `FAIL <name>: <detail>` per check and exits 1 if any failed. Stages are added by later tasks; for now an unknown stage exits 2 with the list of stages.

- [ ] **Step 5: Write `labtest/README.md`**: what labtest is (two lines), the run commands, the config file shape above with no real address, and the manual reset-button check from the spec (Part 1, point 8) as a short checklist.

- [ ] **Step 6: Run the tests, see them pass.** Same command — Expected: `OK`.

- [ ] **Step 7: Make `/root/vmlab/labtest.json`** by hand with vm1, vm2, vm3. Check: `python3 -c "from labtest.target import *; print(sorted(load_config()['targets']))"` prints `['vm1', 'vm2', 'vm3']`.

- [ ] **Step 8: Gate, then commit** — `feat(labtest): skeleton, targets, results`

---

### Task 2: Flash guard and pack guard

**Files:**
- Create: `labtest/safety/flashguard.py`, `labtest/safety/packguard.py`
- Modify: `labtest/run.py` (add stage `guards`)
- Test: `labtest/tests/test_flashguard.py`, `labtest/tests/test_packguard.py`

**Interfaces (produced):**

```python
# flashguard.py
def scan_text(path: str, text: str) -> list[tuple[str, int, str]]   # (path, line number, the line)
def scan(repo: str = ".") -> list[tuple[str, int, str]]
# packguard.py
def name_problems(names: list[str]) -> list[str]
def check(repo: str = ".") -> list[str]                              # empty list = clean
```

Decisions:

- `scan` reads every file from `git ls-files openuf package install.sh setup.sh update.sh`, whatever its extension, and skips files that do not decode as UTF-8.
- Before matching, a line's comment is cut off: from `--` in `.lua` files, from `//` in `.js` files, from ` #` or a leading `#` in all other files.
- A hit is any of these on what is left of the line:
  - `\bsysupgrade\s+[-/]` (the command followed by an option or a path; so `/etc/sysupgrade.conf` and prose about sysupgrade are not hits)
  - `\bmtd\s+(-\S+\s+)*(write|erase|unlock|fixtrx|jffs2write)\b`
  - `\bfw_setenv\b`
  - `\bubiformat\b`
  - `/dev/mtd`
  - `\bof=/dev/(mtd|ubi|mmcblk|sd)`
- `packguard.check` runs `sh tools/dist.sh`, lists `openuf.tar.gz`, and passes the names to `name_problems` (a problem for each name containing `labtest`). It also reports each of `package/*/Makefile`, `tools/dist.sh`, `install.sh`, `setup.sh`, `update.sh` that contains the word `labtest`.

- [ ] **Step 1: Write the failing tests**

```python
# test_flashguard.py
HITS = ['os.execute("sysupgrade -n /tmp/fw.bin")', 'mtd -r write /tmp/x firmware',
        'fw_setenv bootcount 0', 'ubiformat /dev/ubi0', 'dd if=x of=/dev/mtdblock3', 'cat /dev/mtd2']
CLEAN = ['-- owns it through boot, failsafe and sysupgrade',
         'echo "Registered $keep with sysupgrade (survives a firmware upgrade)."',
         'SYSUPGRADE_CONF=/etc/sysupgrade.conf', 'x = 1 -- mtd write would be bad']
def test_each_forbidden_call_is_found():      # for s in HITS: len(scan_text("a.lua" or "a.sh", s)) == 1
def test_comments_and_prose_are_not_hits():   # for s in CLEAN: scan_text(...) == []
def test_file_with_no_extension_is_scanned(): # scan_text("package/openuf/files/hook", "fw_setenv a b") has 1 hit
def test_hit_reports_path_and_line_number():  # text "ok\nfw_setenv a b\n" -> [("f.sh", 2, "fw_setenv a b")]
def test_real_tree_is_clean():                # flashguard.scan(REPO) == []

# test_packguard.py
def test_labtest_name_is_a_problem():         # name_problems(["openuf/a.lua", "labtest/run.py"]) has length 1
def test_clean_names():                       # name_problems(["openuf/a.lua"]) == []
```

- [ ] **Step 2: Run, see them fail** — Expected: `No module named 'labtest.safety.flashguard'`.
- [ ] **Step 3: Write `flashguard.py` and `packguard.py`.**
- [ ] **Step 4: Add stage `guards` to `run.py`**: checks `flash_guard` (detail = first 3 hits as `path:line`) and `pack_guard` (detail = the problems).
- [ ] **Step 5: Run the tests** — Expected: `OK`. Run `python3 labtest/run.py guards` — Expected: `PASS flash_guard`, `PASS pack_guard`, exit 0.
- [ ] **Step 6: Prove the guard bites.** Add a line `os.execute("sysupgrade -n /tmp/x")` to a scratch copy of the tree (not the repo), run `flashguard.scan` on it — Expected: one hit. Do not commit the scratch copy.
- [ ] **Step 7: Gate, then commit** — `feat(labtest): flash guard and pack guard`

---

### Task 3: The self-heal timer (router side)

**Files:**
- Create: `labtest/safety/heal.sh`
- Test: `labtest/tests/test_heal_sh.py`

**Interfaces (produced):** `heal.sh <arm|boot|tick|watch|heal|disarm>`

| Sub-command | Does |
|---|---|
| `arm` | Exit 3 if the healed mark exists. If no saved config exists, save `/etc/config` to the saved-config file (an existing one is kept, never overwritten). Write and enable the init script. Run `boot`. Exit 1, with nothing enabled or running, if the save fails. |
| `boot` | Exit 0 if the healed mark exists. Write the current uptime to the last-knock file. Start `watch` in the background so it outlives the SSH session; write its pid file. |
| `tick` | One check. Exit at once if the healed mark exists. If the knock file exists: delete it and write the current uptime to the last-knock file. If `uptime - last knock > limit`: run `heal`. |
| `watch` | `tick`, sleep 10, forever. |
| `heal` | Stop and disable openUF. Restore the saved config. Write the healed mark. `sync`. Reboot. |
| `disarm` | Kill the watcher, disable and delete the init script, delete the saved config, the mark, the knock, last-knock and pid files, and the script itself. |

Paths (every one is prefixed with `$LABTEST_ROOT`, which is empty on a router):

| What | Path |
|---|---|
| The script on the router | `/etc/labtest-heal.sh` |
| Saved config | `/etc/labtest-good.tgz` |
| Healed mark | `/etc/labtest-healed` |
| Init script | `/etc/init.d/labtest-heal` (`START=99`, `start()` runs `/etc/labtest-heal.sh boot`) |
| Knock file (the runner touches it) | `/tmp/labtest-knock` |
| Last-knock uptime | `/tmp/labtest-last` |
| Watcher pid | `/var/run/labtest-heal.pid` |

Environment, for tests and tuning: `LABTEST_ROOT` (path prefix), `LABTEST_HEAL_LIMIT` (default `180`), `LABTEST_UPTIME_FILE` (default `/proc/uptime`), `LABTEST_REBOOT` (default `reboot`), `LABTEST_NO_WATCH` (when `1`, `boot` does not start the watcher; tests only).

Decisions:

- Time is the first field of the uptime file, whole seconds. Wall time and file dates are never read.
- Restore is a swap, so a power cut cannot leave an empty config: unpack the saved config into `/etc/config.new`; if that fails, leave `/etc/config` alone and go on with the rest of `heal`; else `mv /etc/config /etc/config.bad`, `mv /etc/config.new /etc/config`, delete `/etc/config.bad`.
- openUF is stopped and disabled through `/etc/init.d/openuf stop` and `disable`. If the VM proof in Task 4 shows openUF coming back after the heal reboot, find its other boot entry and disable that here too.

- [ ] **Step 1: Write the failing tests.** Each test builds a scratch root with `etc/config/network` (content `good`), `etc/init.d/openuf` and a `reboot` stand-in (both append their arguments to a log file), and an uptime file. It runs `sh labtest/safety/heal.sh <cmd>` with the four environment variables set. `boot` is run with `watch` stubbed out by the test (set `LABTEST_NO_WATCH=1`; `boot` then skips starting the watcher).

```python
def test_arm_saves_config_and_enables_init():   # rc 0; labtest-good.tgz and init.d/labtest-heal exist; no healed mark
def test_arm_keeps_an_existing_saved_config():  # arm; write "bad" to network; arm again; heal -> network == "good"
def test_arm_refuses_a_healed_target():         # healed mark exists -> rc 3
def test_arm_fails_when_save_fails():           # etc/ made read-only -> rc 1; no init script; no pid file
def test_knock_resets_the_clock():              # uptime 0 arm; uptime 170 touch knock, tick; uptime 340 tick -> no reboot logged
def test_no_knock_for_180_does_not_heal_at_180_but_heals_at_181():
    # uptime 0 arm; uptime 180 tick -> no reboot; uptime 181 tick -> reboot logged
def test_heal_restores_config_exactly():        # after arm: network="bad", add file etc/config/extra; heal ->
                                                # network == "good", extra is gone, no config.new or config.bad left
def test_heal_stops_and_disables_openuf():      # openuf log == ["stop", "disable"]
def test_heal_writes_mark_and_reboots():        # healed mark exists; reboot log has one line
def test_healed_target_never_heals_again():     # after a heal: uptime +1000, tick -> reboot log still one line
def test_old_knock_file_date_does_not_matter(): # knock file with mtime in 2001 still counts as a knock (Review Focus 1)
def test_heal_with_corrupt_saved_config():      # saved config overwritten with "junk": heal -> network unchanged,
                                                # openuf stopped+disabled, mark written, reboot logged (Review Focus 2)
def test_boot_gives_a_fresh_window():           # uptime 500, boot -> labtest-last == "500"
def test_boot_on_healed_target_does_nothing():  # rc 0, no labtest-last written
def test_disarm_leaves_nothing():               # none of the seven paths exists afterwards
```

- [ ] **Step 2: Run, see them fail** — Expected: `heal.sh` not found.
- [ ] **Step 3: Write `heal.sh`** (POSIX sh, busybox tools only: `tar`, `mv`, `rm`, `cut`, `kill`, `sync`).
- [ ] **Step 4: Run the tests** — Expected: `OK`. Then `bash -n labtest/safety/heal.sh && sh -n labtest/safety/heal.sh` — Expected: no output.
- [ ] **Step 5: Gate, then commit** — `feat(labtest): self-heal timer script`

---

### Task 4: Runner side of the timer, and the VM proof

**Files:**
- Create: `labtest/safety/heal.py`, `labtest/safety/proof.py`
- Modify: `labtest/run.py` (add stage `proof`)
- Test: `labtest/tests/test_heal_py.py`, `labtest/tests/test_proof.py`

**Interfaces:**
- Consumes: `Target` (Task 1), `results.save` (Task 1), `heal.sh` (Task 3).
- Produces:

```python
# heal.py
def arm(t: Target) -> None            # put heal.sh at /etc/labtest-heal.sh, run "arm"; RuntimeError with the output on a non-zero exit
class Knocker:                         # with Knocker(t): ...   a thread that runs `touch /tmp/labtest-knock` on t every 10 s
    def __init__(self, t: Target, every: int = 10)
def healed(t: Target) -> bool         # the healed mark exists
def disarm(t: Target) -> list[str]    # run "disarm"; return the Task 3 paths that still exist (empty = clean)

# proof.py
BREAKS: dict[str, str]                 # name -> shell command
def run(conf: dict, t: Target) -> dict # {"pass": bool, "limit": 180, "breaks": [{"name", "healed", "secs", "network_same", "openuf_off"}]}
```

Decisions:

- A failed knock is ignored without a word; a target that cannot be reached is exactly the case the timer is for.
- `proof.run` raises `SystemExit` at once if `t.kind != "vm"`.
- The three breaks. Each is sent as `(sleep 2; <command>) >/dev/null 2>&1 &` so the SSH call returns first:
  - `wrong_address`: `uci set network.lan.proto=static; uci set network.lan.ipaddr=198.51.100.1; uci set network.lan.netmask=255.255.255.0; uci commit network; /etc/init.d/network restart`
  - `deleted_network`: `uci delete network.lan; uci commit network; /etc/init.d/network restart`
  - `bad_vlan`: `d=$(uci get network.lan.device); uci set network.lan.device=$d.4000; uci commit network; /etc/init.d/network restart`
- For each break: save `uci export network`; `arm`; start a `Knocker`; send the break; `t.wait(up=False, 60)` must be true (the break really cut it off, else the break fails); `t.wait(up=True, 180 + 240)`; then check `healed(t)`, `uci export network` equals the saved text, and `/etc/init.d/openuf running` is false. Then `disarm` (must return `[]`), `/etc/init.d/openuf enable` and `start`, and wait until it runs, so the next break starts from a normal state.
- The result is saved with `results.save(conf, "timer-proof", ...)`. Stage `proof` passes only if all three breaks pass.

- [ ] **Step 1: Write the failing tests** (a fake `Target` records the commands it is given)

```python
# test_heal_py.py
def test_arm_puts_the_script_then_runs_arm():      # put(.../heal.sh, "/etc/labtest-heal.sh"), then ssh "/etc/labtest-heal.sh arm"
def test_arm_raises_with_output_on_failure():      # ssh -> (3, "healed") => RuntimeError containing "healed"
def test_knocker_knocks_and_survives_a_dead_target():
    # every=0.05, fake ssh returns (255, ""): after 0.3 s at least 3 knocks were sent and no exception came out
def test_knocker_stops_on_exit():                  # after the with-block, the count stops growing
def test_disarm_reports_leftovers():               # fake `ls` output names /etc/labtest-good.tgz => ["/etc/labtest-good.tgz"]

# test_proof.py
def test_proof_refuses_hardware():                 # Target kind "hw" => SystemExit
def test_breaks_are_the_three_from_the_spec():     # set(BREAKS) == {"wrong_address", "deleted_network", "bad_vlan"}
```

- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Write `heal.py` and `proof.py`; add stage `proof` to `run.py`.**
- [ ] **Step 4: Run the unit tests** — Expected: `OK`.
- [ ] **Step 5: Lab run (lead).** Lab up, vm1 running with this tree installed (`sh /root/vmlab/src/install-openuf.sh 1 /root/jonas-merge`) and adopted. Run in the background (it takes about 15 minutes): `python3 labtest/run.py proof --target vm1`. Expected: `PASS timer_proof`, and `/root/vmlab/results/timer-proof.json` has `"pass": true` with three breaks, each `healed`, `network_same` and `openuf_off` true.
- [ ] **Step 6: If a break fails,** read the VM's log (`logread`, through agent `log-filter` if long), fix `heal.sh` or `proof.py`, add a unit test for the cause, and run Step 5 again. Two honest failed attempts on the same break: stop and report to the owner.
- [ ] **Step 7: Gate, then commit** — `feat(labtest): timer proof in the VM`

---

### Task 5: Pull-the-plug test

**Needs from the owner first:** a lab-only admin account on the lab controller, with its login in `/root/vmlab/labtest-account` (line 1 the user name, line 2 the password, file mode 600). If the file is missing, stage `plug` prints `FAIL plug: no account file` and the stage `safety` still runs the other two.

**Files:**
- Create: `labtest/unifi.py`, `labtest/safety/plug.py`
- Modify: `labtest/run.py` (add stages `plug` and `safety`), `labtest/README.md`
- Test: `labtest/tests/test_unifi.py`, `labtest/tests/test_plug.py`

**Interfaces:**
- Consumes: `Target`, `load_config`, `results.save` (Task 1).
- Produces:

```python
# unifi.py
class Controller:
    def __init__(self, conf: dict)                  # reads conf["controller"], conf["site"], conf["account_file"]
    def login(self) -> None                         # POST /api/login; keeps the session cookie; sends X-CSRF-Token (cookie csrf_token) on writes
    def get(self, path: str) -> list                # path below /api/s/<site>/ ; returns the "data" list
    def put(self, path: str, body: dict) -> list
    def wlans(self) -> list[dict]                   # rest/wlanconf
    def devices(self) -> list[dict]                 # stat/device
    def force_push(self, wlan_id: str) -> None      # flip uapsd_enabled on that WLAN
# plug.py
DELAYS = [1, 2, 4, 7]                               # seconds between the push and the power cut
def config_problems(t: Target) -> list[str]
def run(conf: dict, t: Target, ctl: Controller) -> dict   # {"pass": bool, "cuts": [{"delay", "booted", "problems", "connected"}]}
```

Decisions:

- `requests.Session` with `verify=False` (the lab controller's certificate is self-signed) and the urllib3 warning switched off. A non-200 answer raises `RuntimeError` with the status code and the path only; the request body is never included.
- `plug.run` raises `SystemExit` if `t.kind != "vm"`.
- For each delay: `ctl.force_push(first WLAN)`; sleep the delay; `lab.sh stop N` (it kills QEMU, which is the power cut); `lab.sh start N`; `t.wait(up=True, 180)`; then `config_problems(t)`; then wait up to 300 s for the controller to show the device with `state == 1`. After the last delay, `force_push` once more so `uapsd_enabled` is back to its first value.
- `config_problems` returns one line per fault: a file in `/etc/config` that `uci -q show <name>` cannot read; a zero-length file in `/etc/config` or `/etc/openuf`; openUF not running (`/etc/init.d/openuf running`).
- A VM that does not boot after a cut is a finding, not a harness error: record `booted: false`, stop the stage, and leave the VM as it is for the lead to look at.
- The result is saved with `results.save(conf, "plug", ...)`. Stage `safety` runs `guards`, `proof`, `plug` in that order and stops at the first stage that fails.

- [ ] **Step 1: Write the failing tests** (`requests.Session` is patched; the account file is a temp file holding `u` and `s3cret-word`)

```python
# test_unifi.py
def test_login_posts_the_account():                 # POST to .../api/login with json {"username": "u", "password": "s3cret-word"}
def test_put_sends_the_csrf_token():                # cookie csrf_token "T" => header X-CSRF-Token "T"
def test_error_text_never_holds_the_password():     # login answers 400 => RuntimeError; "s3cret-word" not in str(error)
def test_force_push_flips_uapsd():                  # wlan has uapsd_enabled False => PUT rest/wlanconf/<id> {"uapsd_enabled": True}
def test_missing_account_file_is_a_clear_error():   # RuntimeError containing "account file", not the path's content

# test_plug.py
def test_plug_refuses_hardware():                   # kind "hw" => SystemExit
def test_config_problems_names_each_fault():        # fake ssh output "BAD /etc/config/wireless\nEMPTY /etc/openuf/state\nNOTRUNNING"
                                                    # => 3 problems, each naming its file or "openuf not running"
def test_config_problems_empty_when_clean():        # fake ssh output "" => []
```

- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Write `unifi.py` and `plug.py`; add stages `plug` and `safety` to `run.py`.**
- [ ] **Step 4: Run the unit tests** — Expected: `OK`.
- [ ] **Step 5: Lab run (lead).** vm1 adopted and connected. Run in the background: `python3 labtest/run.py plug --target vm1`. Expected: `PASS plug`, and `/root/vmlab/results/plug.json` shows four cuts, each `booted` true, `problems` empty, `connected` true.
- [ ] **Step 6: A cut that leaves a broken config is a real openUF bug.** Do not fix it in this plan. Write it down for the owner (which delay, which file, the log lines) as the first entry of the findings list, and go on. The stage stays red until it is fixed; that is the correct result.
- [ ] **Step 7: Full pass.** `python3 labtest/run.py safety --target vm1` — Expected: every check `PASS`, or exactly the findings from Step 6.
- [ ] **Step 8: Update `labtest/README.md`** with the three stages, how long each takes, and where results go.
- [ ] **Step 9: Gate, then commit** — `feat(labtest): pull-the-plug test and the safety stage`
- [ ] **Step 10: Bookkeeping** (skill `openuf-bookkeep`): Log entry and START HERE in `MERGE-RESUME.md`.
