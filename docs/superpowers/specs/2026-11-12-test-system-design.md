# openUF test system: design

Date: 2026-11-12. Status: waiting for the owner's review. Nothing is built yet.

## Goal

A new test system that:

- checks every feature openUF has,
- lists every controller setting openUF does not handle (the missing features),
- shows where the current code is weak,
- proves in a VM that a change is safe before it touches a real router,
- then runs the same checks on real routers with no hands needed,
- measures openUF's size and speed and makes it fit a low-end router (128 MB memory, 16 MB flash)
  without losing any feature.

The old tests (`tests/`, `tools/`, the gate) stay as they are. This system sits next to them.

## What was decided in the brainstorm

| Topic | Decision |
|---|---|
| Way back into a cut-off router | Reset button only. No serial cable. |
| Can openUF brick a router? | No. It never flashes firmware or writes the flash chip. The reset button always works. The real risk is "cut off, walk to the router, reset, install again". |
| Bugs and gaps found | Report first, then fix in order of how bad they are. A bug that stops the run itself is fixed at once. |
| Chrome tests | A script (Playwright) for about 10 fixed paths. Claude also explores by hand now and then. |
| WiFi client on hardware | One Android phone, by USB. |
| Shape | One table of rows, run first in the VM and then on hardware. |
| Low-end target | 128 MB memory, 16 MB flash. |
| Making openUF smaller and faster | Its own part (5), after the feature table exists. Measure first, then fix the worst first. |
| Emulating the router's chip | Left out. openUF is script code; the VM cannot fake the switch, radios or LEDs anyway. |

## Words

- **Row**: one test of one feature or one controller setting.
- **Runner**: the program that runs rows and writes results.
- **Target**: where a row runs: a lab VM, or a real router.
- **Cut-off row**: a row that can make the router unreachable (address, VLAN, switch, management network).

## Where things live

In the repo, a new folder `labtest/`:

| Path | What |
|---|---|
| `labtest/run.py` | The runner. One command, runs the stages in order. |
| `labtest/rows/` | The rows, one file per area (wifi, radio, network, guest, device, ...). |
| `labtest/safety/` | The flash guard and the self-heal timer script. |
| `labtest/ui/` | The Chrome paths. |
| `labtest/README.md` | How to run it. |

Outside the repo, in `/root/vmlab/`: the targets file (addresses, SSH key path), the lab-only
controller login file, and all results. No address, key or password goes into the repo.

`labtest/` is never packed into the openUF packages. A check in part 1 proves that.

Language: Python 3 (already in WSL). SSH goes through the plain `ssh` command. No new library
for parts 1 to 3.

## Part 1: the safety net

Job: no test can leave a real router in a state the owner cannot get back from without a walk.

1. **Flash guard.** Scans openUF's code and fails if anything calls `sysupgrade`, `mtd`,
   `fw_setenv`, `ubiformat`, or writes to `/dev/mtd*`. Comments do not count. Today the count
   is zero; this keeps it zero.

2. **Pack guard.** Fails if anything from `labtest/` ends up in a built package.

3. **Self-heal timer.** A script the runner copies onto the target at the start of a run. It is
   a test tool, never shipped.
   - At run start it saves the good config to one file on the router's flash (one write per run).
   - The runner "knocks" (touches a file over SSH) every 10 seconds.
   - If no knock comes for 180 seconds, the router: stops and disables openUF, puts the saved
     config back, writes a "healed" mark, and reboots.
   - It also starts at boot with a fresh 180 seconds, so a bad reboot still heals.
   - After one heal it switches itself off. This stops a heal-reboot loop when the test PC is gone.
   - At run end the runner removes the script, the saved config and the mark. A check proves
     nothing is left behind.

4. **Timer proof (VM).** Break a VM on purpose three ways (wrong address, deleted network, bad
   VLAN) and watch it come back alone each time. Hardware runs stay locked until this passes.

5. **Pull-the-plug tests (VM only).** Kill the VM in the middle of a config change. Boot it.
   The config must be whole and openUF must come back.

6. **VM-first rule.** A row may run on hardware only if it is green in the VM on the same code
   version (git commit). The results record the commit.

7. **Stop rule.** On hardware, the first heal stops the run and reports. It does not push on.

8. **Reset button check.** Manual, once per router model: the owner presses reset with openUF
   installed, and the router must come back clean.

openUF's own undo features (address rollback, switch-VLAN rollback) are product features. They
are tested as normal rows. The timer does not rely on them.

## Part 2: the feature table in the VM lab

**One row has:** a name, how to set it (controller API call and values), how to check it
(commands on the router and what they must show), how to put it back, its risk (safe or
cut-off), and what it needs (VM, hardware, phone).

**One row runs like this:**

1. Note the router's state.
2. Change one setting through the controller API.
3. Wait until the router reports it took the new config.
4. Check the router over SSH.
5. Put the setting back.
6. Write the result.

**Results:**

| Result | Meaning |
|---|---|
| Works | The router did what the setting asks. |
| Ignored | The controller sent it; the router changed nothing. |
| Broken | Wrong state, an error in the log, or a crash. |
| Not sent | The controller never sends this setting to an access point. |
| Not covered | No real check is written yet. |

**Where rows come from.** The controller carries its own list of every setting and its allowed
values. The runner reads that list and makes one row per setting. A setting with no real check
shows as "not covered", so nothing hides.

**The cheap first pass.** For every setting: flip it, and compare the router's whole config
(UCI plus the live WiFi daemon config) before and after. No change means "ignored". This gives
the missing-feature list from the first run. Real checks are then written worst gap first.

**Extra tests in this part:**

| Test | What it catches |
|---|---|
| Garbage from a fake controller | A bad or cut-off message crashing openUF |
| Install, upgrade, uninstall cycle | Leftover files; an upgrade from an older version breaking |
| Flash write counter | openUF writing to flash too often, idle and per config change |
| Day-long run | Memory leaks and slow drift |

**Speed.** One row at a time on one VM at first. The three VMs share the work later only if a
full pass is too slow.

**Output.** One results file per run (with the commit and the date), and one table a person can
read. Both stay outside the repo. A summary with no lab addresses may be copied into the notes.

**Owner's part.** Make a lab-only account on the lab controller and save its login in a file
under `/root/vmlab/`. The runner reads it. Claude never sees or types the password.

## Part 3: real routers and the phone

**Same rows, new target.** Only the targets file changes. The controller is the hardware lab
controller on the owner's PC, never the owner's real controller.

**Three locks before a hardware run:**

1. Every row to be run is green in the VM on the same commit.
2. The timer proof passed.
3. The owner says "go" in chat that day.

**Order.** Safe rows first, cut-off rows last. Cut-off rows run on one router at a time, so the
other stays known-good. The timer is on for the whole run.

**Hardware-only rows.** Real switch ports and VLANs, LEDs, real channels and power, radar
handling, the wireless link between the two routers, the uplink port shown in the controller,
the reset button.

**Phone rows.** The phone is on USB with USB debugging on. The runner tells it to join or leave
a WiFi and asks it which router it is on and what it can reach. This covers:

- joining each kind of WiFi (password types, guest, hidden),
- roaming between the routers (one turns its power down, or kicks a weak client),
- guest limits (the phone must fail to reach the PC),
- Lock to AP (the phone must stay put).

The test WiFi password is made fresh for each run and is not stored in the repo.

Not in the first version: load balancing and airtime sharing (they need two clients), and
measuring speed on the phone. Speed limits are checked on the router side only.

**Output.** The table shows VM and hardware side by side. Green in VM and red on hardware is
the most useful kind of find.

**Owner's part on a hardware day.** Power the routers, open port 8080, plug in the phone, say go.

## Part 4: Chrome tests

**Tool.** Playwright, run inside WSL with no screen ("headless"), because only WSL reaches both
the lab controller and the VMs' LuCI pages.

**Purpose.** The table proves the router does the right thing. The Chrome paths prove what the
API cannot: the UniFi app shows our router right, and our LuCI pages work.

**Fixed paths:**

| Where | Path |
|---|---|
| UniFi app | Log in |
| UniFi app | Adopt a new router |
| UniFi app | Make a WiFi; the router starts sending it |
| UniFi app | Change channel and power on the device page |
| UniFi app | Device page shows the right model, version, uplink and clients |
| UniFi app | Restart and Locate buttons work |
| UniFi app | Forget the router; it goes back to factory state |
| LuCI | openUF overview page loads and shows true status |
| LuCI | Change a setting, save, and it takes effect |
| LuCI | The undo hint shows after an address change |

Each path ends with a check on the router over SSH, using the same checks as the table.

**On failure** a path saves a screenshot and a step-by-step record.

**When.** Before a release and after any change to the LuCI pages. Not on every change.

**Explore pass.** When a new feature lands, Claude opens the lab controller and LuCI and looks
around. The owner logs in first. Each finding becomes a new row or a new fixed path.

## Part 5: size and speed

Job: openUF runs well on a router with 128 MB memory and 16 MB flash, and no feature is lost
on the way there.

**What is measured** (in the VM lab, as a stage of the runner):

| Measure | How |
|---|---|
| Memory | What openUF's own processes hold: at rest, at the peak of a config change, and with many WiFi clients |
| Processor | Time openUF uses per controller check-in |
| Flash space | Size of the packages, everything they pull in, and the files openUF keeps |
| Flash writes | The counter from part 2 |
| Start-up | Time from start to the first check-in with the controller |
| Growth | Memory and file growth over the day-long run from part 2 |

**Limits.** The first run only measures. Then a limit is proposed for each measure, sized to a
128 MB / 16 MB router that already runs OpenWrt and two radios. The owner approves the numbers.
They are kept in a file in the repo (they are not secrets).

**The optimize loop,** one change at a time:

1. Take the worst number.
2. Change the code for it.
3. Run the old test suite, the feature table and the measures.
4. A fresh reviewer reads the change.
5. Any test or row red, or the number not better: undo the change.

**Risky areas last.** The controller handshake and its encryption, adoption, the link between
routers and the WiFi name handling are changed only when a number proves they are the problem.

**Limits stay as tests.** After the loop, a change that pushes openUF over a limit fails the run.

**Tight-memory run.** One run on a VM that has only 128 MB, to prove nothing gets killed when
memory is short. Only if the lab can start such a VM without a change to its script.

**What stays unproven.** Memory and flash numbers from the VM carry over to a real router.
Speed on a slow processor does not; it needs a real low-end router, which the owner does not have.

## The stages, in order

`safety net -> table in VM -> size and speed -> Chrome paths -> hardware (only with the owner's "go")`

One command runs them. A stage must pass before the next one starts. Any stage can also be run
alone.

## Rules this system keeps

- Never pushes, never touches `release*`, never touches the real controller.
- Never touches the real routers without the owner's "go" in chat.
- No lab address, MAC, key, PSK or password in repo files.
- Claude never types a controller password.
- Downloads need the owner's OK.

## Downloads that need the owner's OK

| Download | For | Part |
|---|---|---|
| Android platform tools (adb) for Windows | Driving the phone | 3 |
| Playwright and its Chrome engine, in WSL | Chrome paths | 4 |

Parts 1 and 2 need no download.

## Known unknowns, and how each gets settled

| Unknown | Settled by |
|---|---|
| The right timer limit (180 s is a first value) | Measure a real router's reboot time on the first hardware day |
| How many settings the controller has | First step of part 2 reads the controller's list |
| How long one row and one full pass take | First trial run of part 2 |
| The phone can join a WiFi by command (needs Android 11 or newer) | First step of part 3 |
| Playwright's Chrome runs headless in WSL | First step of part 4 |
| The reset button still works with openUF running | The manual check in part 1 |
| How much memory and flash openUF uses today | First measuring run of part 5 |
| The lab can start a VM with 128 MB without a script change | First step of part 5 |

## Build order

Five build plans, one per part, in this order: 1 safety net, 2 table in VM, 5 size and speed,
3 hardware and phone, 4 Chrome. Each part is usable when it is done. Part 3 cannot start before
1 and 2 are done. Parts 4 and 5 only need part 2.

This design does not change the v2.0.0 release plan. The owner picks when each part is built.
The lab rows waiting in that plan (Task 12) are good first rows for part 2.
