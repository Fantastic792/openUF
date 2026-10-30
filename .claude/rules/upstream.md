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
git remote -v                                    # expect `upstream` -> jonasevcik/openUF
git remote add upstream https://github.com/jonasevcik/openUF.git   # if a fresh clone lacks it
git fetch upstream                               # ALWAYS first -- nothing else refreshes it
git log --oneline 08d0003..upstream/main         # what has not been reviewed yet
```

**The sync is a selective re-implementation, never a merge.** Keep ours where ours is
stronger; where theirs is better, re-implement it in this tree's style, with their tests,
and label their hardware evidence as theirs (upstream runs a Xiaomi AX3000T and an Archer
C5; this tree's lab is a JioRouter AX6000, DSA, `lan_cpueth = "br-lan"`). Upstream also takes
work from here (their 2026-09-25 commits were our 09-15 sysconf/l2guard/interval work,
credited to this repo), so diff before assuming a commit is new.

- **Last review point: `2f263f3` (upstream v0.11.0), sync 4 on 2026-10-18.** Earlier: the
  fork point `677f732`; sync 1 (2026-09-06) to `d7d7e21`; sync 2 (2026-09-13) to `12b4db0`;
  sync 3 (2026-09-28) to `08d0003` (v0.9.3). Not adopted from sync 4 and still waiting:
  the guest portal (REVERSE-ENGINEERING.md backlog row 24).
  Each sync is a row in REVERSE-ENGINEERING.md's session log and an "Adopted from upstream,
  <date>" section in PROTOCOL-VALIDATION.md -- update both, and move this line.
- **A third fork is a remote too: `dmalinowski` → d-malinowski/openUF.** Its
  `pr/unifi-ft-interop` (one commit, `94ac182`) was adopted on 2026-10-25 as `ftinterop.lua`
  (PROTOCOL-VALIDATION.md, "Adopted from d-malinowski/openUF"); it is proposed to upstream but
  not merged there, so a later upstream sync may bring the same change back under
  `openuf/ftinterop.lua` -- diff before re-applying. Their `pr/hh5a-modelmap` (a BT Home Hub 5A
  map, lantiq/xrx200) was merged by jonasevcik on 2026-10-25 (`d6745b8`, the first upstream
  commits past `2f263f3`) and is not yet reviewed here. Their hardware is a HH5A and a U7 Lite;
  label it. **The translator has an upstream of its own**: `openuf/rrb/rrb-unifi.uc` is
  https://github.com/d-malinowski/unifi-openwrt-roaming at 1.3 (`767a28c`), vendored
  2026-10-25 with the changes marked `// openUF:`; take fixes from there (the local clone
  `../unifi-openwrt-roaming` has it as `upstream`), re-apply the marked changes, and update
  `openuf/rrb/README.md`'s commit. The fork `yesrab/unifi-openwrt-roaming` is not a source.
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
- **Fixtures** in both trees use RFC 7042 MACs (`00:00:5e:00:53:xx`) and RFC 5737 addresses
  (`192.0.2.x`). Pre-commit scan: `git diff --cached -U0 | grep "^+" | grep -nE
  "192\.168\.|([0-9a-f]{2}:){5}[0-9a-f]{2}"` -- `192.168.1.100` "testap" and `11:22:33`-style
  MACs are long-standing test placeholders, not lab values.
- **Nothing from the lab goes into this file or the docs**: no device passwords, no API keys,
  no controller credentials. REVERSE-ENGINEERING.md's lab table carries the addresses and
  roles; secrets are asked for each session.
