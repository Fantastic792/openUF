# Field reports

Test results from real hardware, one TOML file per test session. They are how a feature
moves from "inherited, not re-verified" to verified in the [README](../README.md), and how
a board gets onto the verified list.

## Send one

1. Copy [TEMPLATE.toml](TEMPLATE.toml) to
   `field-reports/<YYYY-MM-DD>-<board>-<your-github-name>.toml`.
2. Fill in the header (board, OpenWrt, openUF and controller versions) and one
   `[[result]]` per feature you tested. `python3 tools/field_report.py ids` lists the
   feature ids.
3. Check it:

   ```sh
   python3 tools/field_report.py check field-reports/<your file>.toml
   ```

4. Open a pull request with just that file. No pull request? Open an issue with the
   **Field report** form and paste the file there.

A failure is as useful as a pass. Say what you expected and what happened instead, and put
the log lines in `evidence`.

## The format

| Key | Required | What |
|---|---|---|
| `format` | yes | `1` |
| `date` | yes | The test day, a TOML date (`2026-10-29`, no quotes) |
| `reporter` | yes | Your GitHub name |
| `board` | yes | OpenWrt's board name: `ubus call system board`, `board_name` |
| `openwrt` | yes | `DISTRIB_RELEASE` from `/etc/openwrt_release` |
| `openuf` | yes | The release, or the commit you built from |
| `controller` | yes | The UniFi Network version |
| `modelmap`, `gateway`, `clients`, `notes` | no | The hardware profile, the gateway, the clients used, anything else |
| `[[result]]` | at least one | `feature` (an id), `outcome` (`pass`, `fail`, `partial`, `not-run`), `how` (what you did), `evidence` (required unless `not-run`), `notes` |

The checker rejects an unknown feature id or outcome, a missing `how`, a result with no
evidence, and anything that looks like a password, key, token or public IP address. Private
addresses and MAC addresses are allowed; mask them if you prefer.

## Useful evidence

- `sh tools/selfcheck.sh` (from the source tree) with the feature turned on in the controller.
- `logread | grep -E 'openuf|backhaul|uplinkmon|bcfilter|wlansched'` around the test.
- For WiFi features, the client's view (what it joined, its speed test) and the AP's
  (`iw dev <if> station dump`, `hostapd` lines in `logread`).
- Times, so the AP's log and what you saw can be lined up.

## Merging

The maintainer runs `python3 tools/field_report.py table field-reports/*.toml` to get the
README rows, and CI runs `check` on every report on each push.
