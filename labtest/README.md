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
| `catalog` | Reads the controller's field list (`fields_dir`) and prints files, fields, in-scope fields (WlanConf / Device / Setting, no SettingSuper) and bool / enum / other counts. Writes `catalog.json` | `fields_dir` | ~1 s |

`fields_dir` is the controller's `api/fields` folder, unpacked once from its `ace.jar`
(`unzip -o -q ace.jar 'api/fields/*' -d /root/vmlab/unifi-fields`).

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
  "targets": { "vm1": { "host": "<vm1's lab address>", "kind": "vm", "lab_n": 1 } }
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
