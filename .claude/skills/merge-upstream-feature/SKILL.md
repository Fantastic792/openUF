---
name: merge-upstream-feature
description: Use when porting a feature or commit from another openUF tree (jonasevcik/openUF, a fork, d-malinowski's work) into this repository, one feature at a time. Covers the cherry-pick loop, keeping ours on conflicts, the full check list, the lab test, the commit identity and trailer, and when to stop.
---

# Porting an upstream feature

This tree re-implements upstream work feature by feature. It does not merge blindly. CLAUDE.md's
"Upstream" section says why and where the remotes are; this is the loop for one feature.

## Ground rules

- Work on a branch made for the port (a worktree of its own is easiest), never on
  `release` or `release-fantastic`. Never push, never force-push, and never touch the
  owner's routers or the real controller without the owner's go-ahead.
- Port features newest group first; inside a group, in upstream's history order (applying
  out of order makes later hunks miss their context).
- **Keep this tree's behaviour on conflicts** (the mesh, the uplink monitor, the three SSID
  holders, this tree's capability bits) and record every such decision in the commit
  message, and in the resume file if one is kept.
- A feature that cannot pass the checks below is logged as skipped, with the reason, and
  the port moves on.
- **Nothing from the lab goes into the repo docs**: no passwords, keys, controller
  credentials, lab addresses or MACs. Fixtures use RFC 7042 MACs and RFC 5737 addresses.

## The loop, per commit

1. `git fetch` the upstream remote, then `git show --stat <sha>` and read the message.
2. Check whether it is already here under another hash (an earlier sync or snapshot):
   compare its added lines with this tree before picking.
3. `git cherry-pick -x --no-commit <sha>`.
4. Resolve conflicts:
   - Docs (README, USAGE, PROTOCOL-VALIDATION, CLAUDE.md): take ours, then add only the
     commit's real change in this tree's layout. Check first that git did not already merge
     the section, so nothing is inserted twice.
   - Code: a conflict is often git aligning upstream's copy of a function this tree already
     has ("displaced block"). Resolve to ours and apply the commit's actual diff by hand.
     Never splice both sides into the middle of a function.
   - Tests: keep ours, then port upstream's new tests by name. A new test file goes into
     `tests/run_tests.lua`'s hardcoded list.
5. Run the full check list. Every item must pass:
   ```sh
   eval $(luarocks path --local)
   OPENUF_REQUIRE_GCM=1 lua tests/run_tests.lua      # gate on the final Results: line
   sh tools/dist.sh --verify                        # same shell as the eval above
   python3 tools/field_report.py check field-reports/*.toml
   for f in setup.sh install.sh update.sh tools/*.sh; do bash -n "$f" && dash -n "$f"; done
   ```
6. Test the feature on the lab VMs against the lab controller. Write down what was shown
   and what was not. Unit-tested only is a valid result, but say so.
7. Commit as `Fantastic792 <shichandak79@hotmail.com>`, subject `port: <what> (<upstream>
   <short sha>)`. The body says what was taken, what was kept ours and why. It ends with the
   `(cherry picked from commit <full sha>)` line, then the Co-Authored-By trailer.

## Stop conditions

- **A script stops on a failed suite or a failed `dist.sh --verify`.** Never pipe a check
  into `grep`/`tail` in a way that hides its exit status. Commit only after every check
  passes; a commit that went in red is fixed in the very next commit.
- **Controller login expired: stop everything and ask the owner to log in again.** Never
  create the controller's admin account or type its password.
- Debug dumps of a push contain secrets: grep only the key names you need, then delete the
  dump at once.

## After the last feature

Tie the histories with `git merge -s ours <upstream>/main` (the tree must not change;
compare `HEAD^{tree}` before and after), so later upstream work merges from there.
