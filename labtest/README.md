# labtest

The new openUF test system. It runs checks on lab VMs (and later real routers) and prints
one `PASS` or `FAIL` line per check. It is a test tool: nothing here is ever packed into openUF.

## Run it

From the repo root, in WSL:

```sh
python3 -m unittest discover -s labtest/tests -t . -v   # unit tests, no lab needed
python3 labtest/run.py <stage> [--target vm1]            # a stage, default target vm1
```

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
