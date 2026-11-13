---
paths:
  - "openuf/**"
  - "tests/**"
---

# Upstream: jonasevcik/openUF is inspiration, not a parent

Moved from CLAUDE.md; it loads when a matching file is touched.

This repository began as a fork of https://github.com/jonasevcik/openUF and was
**detached from the GitHub fork network on 2026-10-03**. It is a standalone repository:
there is no Sync-fork button, no ahead/behind count, no cross-repo compare view, and
upstream's commits no longer appear as shared history on GitHub. Do not write "this fork"
in the docs any more. Upstream stays reachable as a plain git remote:

```sh
git remote -v                                    # expect `jonas` -> jonasevcik/openUF
git remote add jonas https://github.com/jonasevcik/openUF.git      # if a fresh clone lacks it
git fetch jonas                                  # ALWAYS first -- nothing else refreshes it
git log --oneline 5f521bf..jonas/main            # what has not been reviewed yet
```

**The sync is a selective re-implementation, never a merge.** Keep ours where ours is
stronger; where theirs is better, re-implement it in this tree's style, with their tests,
and label their hardware evidence as theirs (upstream runs a Xiaomi AX3000T and an Archer
C5; this tree's lab is a JioRouter AX6000, DSA, `lan_cpueth = "br-lan"`). Upstream also takes
work from here (their 2026-09-25 commits were our 09-15 sysconf/l2guard/interval work,
credited to this repo), so diff before assuming a commit is new.

- **Last review point: `5f521bf` (2026-10-28), tied in by the content-only merge `8fe6e55`**:
  every jonasevcik commit up to it is in this tree or deliberately left out (each `port:`
  commit's message says which), and later upstream work merges from there. The guest
  portal's walled garden came in that round (`348fccb`, `94aa2ed`). Earlier: the fork point
  `677f732`; sync 1 (2026-09-06) to `d7d7e21`; sync 2 (2026-09-13) to `12b4db0`; sync 3
  (2026-09-28) to `08d0003` (v0.9.3); sync 4 (2026-10-18) to `2f263f3` (v0.11.0).
  Each sync is a row in docs/journal/session-log.md and an "Adopted from upstream,
  <date>" section in PROTOCOL-VALIDATION.md -- update both, and move this line.
- **More forks are remotes too: `dmalinowski` → d-malinowski/openUF and `yesrab` → yesrab/openUF.**
  d-malinowski's `pr/unifi-ft-interop` (`94ac182`) was adopted on 2026-10-25 as `ftinterop.lua`
  and is gone since 2026-11-10 (see `fast-roaming.md`); a later upstream sync may bring the same
  change back under `openuf/ftinterop.lua` -- do not re-apply it. Their `pr/hh5a-modelmap` (a BT
  Home Hub 5A map, lantiq/xrx200) was merged by jonasevcik on 2026-10-25 (`d6745b8`) and is
  ported here (`cbc4c5b`, `cff4204`, `d72ec9d`). Their hardware is a HH5A and a U7 Lite; label
  it. **The translator has an upstream of its own** and is not in this tree: take
  https://github.com/d-malinowski/unifi-openwrt-roaming releases through
  `tools/rrb-unifi-compat.sh --bump`. yesrab/openUF (`b8797df`, 2026-11-10) was reviewed and
  ported by hand, not cherry-picked: b8797df, then 8a60095/97564d2 with the switch to the
  external plugin (9e405c5's parts). Second round 2026-11-14 to `69e1ed0` (v0.3.2): b0fad40 (rrb-unifi
  1.5.1 pin, compat tool shim) and 69e1ed0 (virtual upgrade: stage notifs, follow-up inform,
  announce version, setparam `interval`, U6IW fw.ver) on OUR report_upgraded_version state
  (their `st.fw_version` not taken). Next yesrab review starts after `69e1ed0`.
- **Mechanics that worked in syncs 3 and 4:** `git add -A` first, then per commit **in
  upstream's order** `git show --format= <c> -- openuf/ tests/ ':!openuf/guestportal.lua'
  ':!tests/test_guestportal.lua' | git apply --3way` (the fetch puts their blobs in our
  object store; applying out of order makes later hunks miss their context). `inform.lua`
  has diverged enough that a hunk often lands as a "displaced block" (ours N lines, theirs
  a whole unrelated region): resolve those as ours and port the change by hand. Test files:
  resolve displaced blocks as ours, then port upstream's NEW tests by name (an entry is a
  one-tab `\t{` ... `\t},` block; a modified test is removed and re-added from their file).
  Copy wholesale any module byte-identical to the last sync point. Gate on the suite's
  final `Results:` line -- every per-file summary also says `0 failed`. Run `eval $(luarocks
  path --local)` before both the suite and `sh tools/dist.sh --verify`; use `sh -c` for
  word-split loops (zsh does not split an unquoted variable). A compile check on AP2 is
  `lua -e 'assert(loadfile("<f>"))'` per file -- `lua -e ... <f>` runs `<f>` as a script.
