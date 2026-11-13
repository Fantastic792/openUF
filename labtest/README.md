# labtest

The new openUF test system. It runs checks on lab VMs (and later real routers) and prints
one `PASS` or `FAIL` line per check. It is a test tool: nothing here is ever packed into openUF.

## Run it

From the repo root, in WSL:

```sh
python3 -m unittest discover -s labtest/tests -t . -v   # unit tests, no lab needed
python3 labtest/run.py <stage> [--target vm1]            # a stage, default target vm1
```

## Stages (part 1: the safety net)

| Stage | What it checks | Needs | Time |
|---|---|---|---|
| `guards` | No firmware or flash write in openUF's code; nothing from `labtest/` in the package | the repo only | ~30 s |
| `proof` | Breaks a VM three ways (wrong address, deleted network, bad VLAN); the self-heal timer must bring it back each time | lab up, VM running openUF | ~11 min |
| `plug` | Pushes from the controller, watches the VM for the apply start (its write of `/etc/config/wireless`), and kills the VM 0, 0.1, 0.2 and 0.5 s after it. Each cut records the offset, the time from the apply start, and `mid_apply` (the apply had not finished). The config must be whole and openUF back; no apply start within 30 s fails that cut; at least one cut must land mid-apply | as `proof`, VM adopted, the account file | ~6 min |
| `safety` | `guards`, `proof`, `plug` in that order; stops at the first stage that fails | as `plug` | ~15 min |

`proof` and `plug` refuse any target whose `kind` is not `vm`.

## Stages (part 2: the feature table)

| Stage | What it checks | Needs | Time |
|---|---|---|---|
| `catalog` | Reads the controller's field list (`fields_dir`) and prints files, fields, in-scope fields (WlanConf / Device / Setting; `Setting.json` is one file of site sections, read as `Setting.<section>`, `Setting.super_*` left out) and bool / enum / other counts. Writes `catalog.json` | `fields_dir` | ~1 s |
| `table` | One row per in-scope field: flips it through the controller API, reads the push openUF got (its own `debug_dump_file`), waits for the apply, compares the router's whole config (uci, hostapd, nft, tc, ip) before and after, checks openUF's health, puts the setting back. `--only REGEX` (row names, e.g. `'^WlanConf\.'`), `--limit N`. Writes `table.json` after every row, then `table.md` and a kept copy `table-<commit>-<date>.json` | lab up, VM adopted, the account file, `fields_dir`, `row_wlan` | see below |
| `writes` | Flash writes: sectors written to real disks (`/sys/block/*/stat`, not ram/loop/zram) and files changed under `/etc /opt/openuf /usr/lib/openuf /root`, first while openUF idles connected for 10 min (any changed file fails), then for one push there and back (recorded only). Writes `writes.json` | lab up, VM adopted, the account file, `row_wlan` | ~10 min (616 s measured) |
| `cycle` | On a fresh VM (`lab.sh reset/start/provision/prepare`): install the tree, openUF runs, `install.sh uninstall` leaves no new file (except `cycle.KEEP`, each with the install.sh line that keeps it), install `v0.13.0` from `git archive`, install the tree over it: openUF runs, `conf.lua` kept, no Lua error. Stops at the first failed step, except `leftovers` (recorded, the stage still fails, the upgrade steps still run). Writes `cycle.json`. Refuses hardware and an adopted target (it wipes the VM) | lab up, a spare VM (vm4), the account file | ~4 min measured (lab VM) |
| `garbage` | A fake controller (`extra/fake.py`, port 18080 on `fake_host`) answers openUF's informs with garbage, one case at a time (`garbage.CASES`: empty body, HTTP 500, random bytes, short or lying header, undecryptable, not JSON, wrong types, 2 MB, cut mid-body, 40 s slow). After each case: same pid, no Lua error since the case's logger mark, RSS at most 2x, `/etc/config` unchanged. Points openUF with `set-inform` after saving `state.json`, puts it back at the end, even on error. Writes `garbage.json`. Refuses hardware and an adopted target | lab up, a spare un-adopted VM (vm4) running the tree, `fake_host` (the host address the VM reaches), the account file | ~5 min measured |
| `soak` | A sample every 5 min (`--hours`, default 24): RSS of `inform.lua` and `announce.lua`, open files, files and kB under `/tmp/openuf*` and `/etc/openuf`, disk sectors written, pid, connected; a push there and back every 30 min. Fails when a sample is not connected, the pid changes, or the last hour's median memory, open files or temp size is more than 1.2x the first hour's. `soak.json` is saved after every sample (a run that dies keeps them). Not part of `vm` | lab up, VM adopted, the account file, `row_wlan` | `--hours` |
| `vm` | `catalog`, `table`, `writes` (on `--target`), `cycle`, `garbage` (always on `vm4`), in that order; stops at the first stage that fails | all of the above | table + ~20 min |

The five results of a row:

| Result | Meaning |
|---|---|
| `works` | a real check (`labtest/rows/`) says the router did what the setting asks |
| `ignored` | the controller sent a change; the router's config did not change |
| `broken` | push not applied in 60 s, openUF died or restarted, a Lua error in the log, the router did not go back, or the row cut the target off |
| `not_sent` | no new push with a changed key reached openUF within 25 s |
| `not_covered` | skipped (secret `x_*`, not on/off or pick-one), no such object on the site, controller refused, or the router changed and no check is written yet |

Rows whose key names a VLAN, network, address, uplink, switch port and similar run last (`cutoff`). A row
that cuts a VM off waits for the self-heal timer, brings openUF back and goes on; on hardware it stops the run.

Before each flip the runner writes `results_dir/table-pending.json` (`{"path", "old"}`) and deletes it once
the old value is verified back. A run that died mid-row puts that value back first at its next start. A
put-back the controller refuses stops the run and keeps the journal.

The put-back sends every catalog field of the object (never `x_*`), because the controller rewrites some
fields itself on a flip; those are listed per row under "Controller also changed". The router counts as back
when a settled snapshot matches the one before the flip, waiting up to 70 s (openUF's l2guard resyncs once a
minute).

`fields_dir` is the controller's `api/fields` folder, unpacked once from its
`internal-dependencies.jar` (`unzip -o -q internal-dependencies.jar 'api/fields/*' -d /root/vmlab/unifi-fields`).

Results go to `results_dir` (default `/root/vmlab/results`): `timer-proof.json` and `plug.json`,
each stamped with the git commit it ran on (`+dirty` when the tree had changes) and the date.

The self-heal timer is `labtest/safety/heal.sh`: a test tool, never shipped. The runner copies it to
`/etc/labtest-heal.sh`, knocks every 10 s, and removes every trace at the end. No knock for 180 s
(counted with `/proc/uptime`) -> the target stops openUF, puts its saved config back, marks itself
healed and reboots. It heals once, then stays off.

`plug` needs a lab-only admin account on the lab controller: `account_file` holds the user name on
line 1 and the password on line 2 (mode 600). Without it, `plug` prints `FAIL plug: no account file`.

## The config file

Everything about the lab lives outside the repo, in `/root/vmlab/labtest.json`
(or the file named by `$LABTEST_CONF`). No address, key or password goes in the repo.

```json
{
  "controller": "https://127.0.0.1:8443",
  "site": "default",
  "account_file": "/root/vmlab/labtest-account",
  "ssh_key": "/root/vmlab/id_lab",
  "lab_sh": "/root/vmlab/lab.sh",
  "results_dir": "/root/vmlab/results",
  "fields_dir": "/root/vmlab/unifi-fields/api/fields",
  "row_wlan": "<name of the WLAN the WlanConf rows change>",
  "fake_host": "<the host address the VMs reach; garbage's fake controller binds it>",
  "targets": { "vm1": { "host": "<vm1's lab address>", "kind": "vm", "lab_n": 1 },
               "vm4": { "host": "<vm4's lab address>", "kind": "vm", "lab_n": 4 } }
}
```

`kind` is `vm` or `hw`. Code that breaks a target on purpose refuses anything but `vm`.

## Reset-button check (manual, once per router model)

The only way back into a cut-off router is its reset button. Prove it works with openUF on it:

1. Install openUF on the router and let it adopt.
2. Press and hold reset until the LED blinks (about 10 s), then let go.
3. Wait for the boot to finish.
4. Check: the router answers on its default address, LuCI opens, SSH works.
5. Write down the model, the date and the result.
