# Migration record — work copy → standalone clone

**Package:** `p04-migrate-promote-teardown` of blueprint `sandbox-refuse-in-place`
**Prepared:** 2026-07-28 · **Executes:** nothing. This document *prepares and verifies* (Decision #13).

> **This package mutates nothing.** Butler's `guard-bash.sh:24` denies `git commit` and `rm -rf`
> inside any coordinator, and the guard's own message reserves mutations for the orchestrator. Every
> command below is executed by the **drive-solo driver session**, where butler's hooks do not fire.
> A coordinator that ran any of these would have failed this package.

---

## 1. The three paths (each with the command that confirmed it)

| role | resolved absolute path | confirming command | result |
|---|---|---|---|
| **work copy** (`$WC`) | `C:/Users/André/ccpraxis-sandbox-workcopy` | `git rev-parse --show-toplevel` | as shown |
| **live install** (`$LIVE`) | `C:/Users/André/.claude/ccpraxis` | the `launcher.pl:222` anchor derivation (three `dirname()`s from `<live>/plugins/sandbox/scripts/launcher.pl`), re-computed independently | as shown; `-d` → exists |
| **clone target** (`$NEW`) | `C:/Development/ccpraxis` | `[ -e C:/Development/ccpraxis ]` → **free**; `[ -d C:/Development ]` → **exists** | target is unoccupied, parent exists |

```bash
WC=/c/Users/André/ccpraxis-sandbox-workcopy
LIVE=/c/Users/André/.claude/ccpraxis
NEW=/c/Development/ccpraxis
```

`$NEW` is the blueprint's default (Decision #10 / inputs: "`C:/Development/ccpraxis` unless the user
has said otherwise"). Nothing occupies it, so Phase B needs no pre-clearing.

## 2. Live blueprint directory — full enumeration, classified (Decision #12)

Enumerated from `$LIVE/.ccpraxis-local-data/blueprints/` on 2026-07-28. **Discovered, not presumed** —
the blueprint predicted "at least `workcopy-git-durability`"; there are in fact **three** entries.

| entry | size | classification | reason |
|---|---|---|---|
| `workcopy-git-durability` | 113K | **REMOVE** | Superseded by this blueprint (Decision #2). Preserved intact at `$WC/.ccpraxis-local-data/blueprints/_archive/workcopy-git-durability`, so removal loses nothing. |
| `sandbox-butler-overhaul` | 261K | **REMOVE** | A stale copy whose 24 ledgers read **all `pending`** — this is precisely the `copy_tree` clobber *source* described in B4. The authoritative copy (6 done / 2 parked / 16 pending) lives in the work copy and travels to the clone in Phase C. |
| `_archive` | 2.3M | **REMOVE** | 26 archived blueprints. **Proven redundant:** `diff -r --brief` against `$WC/.ccpraxis-local-data/blueprints/_archive/` reports only `Only in <work copy>: workcopy-git-durability` — i.e. live's archive is byte-identical to the work copy's, which is a strict superset (27 entries). |

**Net:** all three are removed, and after Phase C the clone holds a superset of everything live had.
The live install is not a project; it has no business holding blueprint state at all — that is the
misfiling B4 exploited.

> **Do not act on this table directly.** Phase F **re-enumerates and diffs** against it first (see
> §5.F). It was recorded at prepare time and a live fleet touches the live install independently.

## 3. Measured sizes of the gitignored payload

| tree | size | why it matters |
|---|---|---|
| `$WC/.ccpraxis-local-data/blueprints/` | **76M** | 24 paused-fleet ledgers + `runs/`, `specs/`, `reports/`, this blueprint, 27 archived |
| `$WC/.ccpraxis-local-data/claude-home/` | **100M** | agent memory, every session transcript under `projects/`, plans, beacons, backpack, `settings.json`, credentials |
| `$WC/.ccpraxis-local-data/` (total) | **179M** | |

> Measure each path in its **own** `du` invocation. `du -sh a b parent` under-reports the parent,
> because `du` will not re-count files it already counted for an earlier argument — during
> preparation this produced a spurious `3.5M` for the parent. Not a defect; a measurement trap.

`claude-home` is the **same inode** as a running container's `/root/.claude`. **Stop the sandbox
container before Phase C** or the copy can capture a torn write.

## 3b. ⚠️ Gitignored files at the work-copy ROOT — outside `.ccpraxis-local-data/`

**Found by red-team (B-1) and confirmed on disk.** `.ccpraxis-local-data/` is **not** the only
untracked tree that must travel. `git status --ignored --short` at `$WC` also reports:

| path | what it is | consequence if missed |
|---|---|---|
| `deploy_key` | the container's git **SSH private key** (`launcher.pl:1581-1582`) | in-container git auth breaks in the clone |
| `deploy_key.pub` | its public half | same |
| `.claude/` | `settings.json` (gitignored: install-specific `enabledPlugins`), `settings.local.json` | project-level Claude config lost |

`git worktree remove` **deletes ignored files silently** — it does not warn and does not refuse on
their account. So under the original plan these were destroyed by Phase F with **no copy anywhere**:
Phase C copied only `.ccpraxis-local-data/`, and the safety backup held only that too.

**Remediated 2026-07-28:** all three were added to the backup at
`ccpraxis-state-backup-20260728/workcopy-root-gitignored/` and verified byte-identical
(`diff -r --brief` on `.claude`, `cmp` on both keys). **Phase C now copies them explicitly** — see §5.C.

> Re-derive this list at execution time rather than trusting the table:
> `git -C "$WC" status --ignored --short | grep '^!!' | grep -v '^!! .ccpraxis-local-data'`

## 4. `.gitignore` — what will NOT travel via git

Read in full. The lines that matter for migration:

```
*.credentials*        *.key        *.pem        *.secret        deploy_key*
.statusline_usage_cache.json        .backup-preferences.json
.claude/settings.local.json         .claude/settings.json
.claude-plans/
.ccpraxis-local-data/          ← the load-bearing one
.claude/backup-metadata.json        .claude/backup-cache/
.claude/scheduled_tasks.lock        .claude/worktrees/
*.pre-merge.*        host-tools/bin/perl.cmd        deploy_key
```

**CORRECTED (was wrong in the first draft).** `.ccpraxis-local-data/` is the *largest* untracked tree
but **not the only one that matters** — see §3b. Reading `.gitignore` alone produced that error,
because a pattern being listed says nothing about whether a matching file actually exists at `$WC`.
`git status --ignored` is the authoritative question and it reports `deploy_key`, `deploy_key.pub`
and `.claude/` as well.

The Phase A commit carries **tracked code only**; everything in §3 (179M) **and** §3b moves by file
copy in Phase C or not at all.

---

## 5. The command sequence — ordered, gated, copy-pasteable

### 5.0 — Execution preamble (read before running anything)

**Shell:** bash (Git Bash), not PowerShell and not `cmd`. Paths below use the `/c/...` form
consistently. Start every phase's block with:

```bash
set -eu
WC=/c/Users/André/ccpraxis-sandbox-workcopy
LIVE=/c/Users/André/.claude/ccpraxis
NEW=/c/Development/ccpraxis
: "${WC:?}" "${LIVE:?}" "${NEW:?}"
```

`set -u` plus the `:?` guards exist so that an unset variable can never expand a later
`rm -rf "$LIVE/..."` into `rm -rf /...`. Never `> NUL` from bash (it creates a literal file); use
`/dev/null`.

### 5.0b — ⚠️ Where the Post-run log lives after Phase C (red-team B-6)

**This is a trap in the procedure itself, not in the code.** The driver records progress in
`$WC/.ccpraxis-local-data/blueprints/sandbox-refuse-in-place/blueprint.md` — the Post-run log table.
Phase C copies that tree to `$NEW`, and Phase F **destroys `$WC`**. So every row the driver writes
for phases C through G, plus any worker reports produced after C, land in a directory that is about
to be deleted and are **never re-synced**.

**Rule: after Phase C completes and its gate passes, the authoritative copy of the blueprint moves to
the clone.** From that point on:

- record Post-run log rows in `$NEW/.ccpraxis-local-data/blueprints/sandbox-refuse-in-place/blueprint.md`;
- treat `$WC`'s copy as read-only history;
- if anything is written into `$WC` after C (an unexpected fix, a new report), **re-run C's
  `diff -r --brief` and re-copy the differing paths before F0**, or that work is lost.

F0's recursive `diff` is what catches a violation of this rule: post-C drift in `$WC` shows up as
diff output and stops the procedure.

**Order is prove-then-promote-then-destroy and it is load-bearing.** D proves the replacement before
E disables the fallback; F destroys only after both; G cuts the safety net last.

**Every `STOP` below is a hard stop.** A failed gate ends the procedure — record it in the blueprint's
Post-run log and leave the work copy intact. There is no cost to a stale worktree; there is an
unrecoverable cost to removing it early.

### A0 — remove the orphaned steward verbs ✅ ALREADY DONE (2026-07-28)

Completed before Phase A so it travels in the same commit. Recorded in the blueprint's Post-run log.
Kept here for the audit trail:

```bash
rm -rf "$WC/plugins/steward/skills/mergeback-sandboxed-ccpraxis-workcopy" \
       "$WC/plugins/steward/skills/discard-sandboxed-ccpraxis-workcopy"
# + strike both from plugins/steward/.claude-plugin/plugin.json and plugins/.claude-plugin/marketplace.json
```

**GATE — expected literally:** repo-wide grep for `ccpraxis-mergeback|mergeback-sandboxed|discard-sandboxed`
(excluding `.ccpraxis-local-data/`) → **no output**. Both JSON files still decode via `JSON::PP`.
✅ *Verified 2026-07-28.*

### A — commit in the work copy

```bash
git -C "$WC" status --short | head -40      # look before committing
git -C "$WC" add -A
git -C "$WC" commit -m "<message>"
```

**GATE — expected literally:** `git -C "$WC" status --short` prints **nothing**.
*(Partly satisfied: commit `9e48db3` on 2026-07-28 landed p01 + A0 and left the tree clean. Re-run
the gate immediately before Phase B in case later work has dirtied it.)*
**STOP if the tree is dirty.**

### B — clone live, check out the migrated branch

```bash
git clone --no-hardlinks "$LIVE" "$NEW"
git -C "$NEW" branch -a
git -C "$NEW" checkout -b work origin/ccpraxis-sandbox-workcopy
```

`--no-hardlinks` is **mandatory** (Decision #9): a local clone hardlinks the object store by default,
silently re-coupling the clone to live and reintroducing the exact coupling this initiative removes.
The work copy is a worktree, so its commits live in `$LIVE`'s object store and the branch arrives as
a remote-tracking ref.

**GATE — expected literally:**
- `git -C "$NEW" branch -a` lists `remotes/origin/ccpraxis-sandbox-workcopy`;
- `git -C "$NEW" log --oneline -1` shows the Phase A commit;
- a known fleet-changed file is present: `grep -c CLEAN_ENV "$NEW/plugins/butler/tests/t/09-gate.t"` → **4**;
- p01 landed: `test -f "$NEW/plugins/sandbox/tests/t/42-refuse-in-place.t"` succeeds **and**
  `test -e "$NEW/plugins/sandbox/scripts/ccpraxis-mergeback.pl"` **fails** (it must be gone).

**STOP if the branch did not arrive** — without it the clone has none of this work.

**B2 — rename the remote so `origin` is not the live install (red-team M-5).**
`git clone <LIVE> <NEW>` sets `origin` = `$LIVE`. The object stores are separate (that is what
`--no-hardlinks` bought), so this is a pointer rather than true coupling — but leaving it named
`origin` means a reflexive `git pull`/`git push` in the clone targets the live install, which is the
relationship this initiative is removing.

```bash
git -C "$NEW" remote rename origin live
git -C "$NEW" remote -v          # => live  /c/Users/André/.claude/ccpraxis  (fetch/push)
```

Keep the remote — Phase E needs a path back to live — just do not let it be the default `origin`.

> **Recommended, not gated (red-team M-4): get the commits off this machine before Phase F.**
> Until F runs, the work exists in exactly two places on one disk (`$LIVE`'s object store and the
> clone), and F deletes one of them. If a real remote exists, `git -C "$NEW" push <remote> work`
> now. This is not made a hard gate because the blueprint never established a remote as a
> precondition — but a single disk failure between C and G loses everything, and the backup is on
> the same disk.

### C — stop the container, then copy ALL gitignored state

Run every command under `set -eu` in **bash** (Git Bash). `set -u` is not optional: an unset `$WC`
or `$NEW` in a later `rm -rf` is the difference between a migration and a disaster.

```bash
set -eu
podman ps -a --format '{{.Names}}'                      # find the CURRENT name; do not trust a recorded one
podman stop <the ccpraxis-workcopy container>
podman ps --format '{{.Names}}' | grep -i workcopy && { echo "STILL RUNNING"; exit 1; } || true
ps -W | grep -c '/usr/bin/perl' # informational: a live launcher heartbeat can restart it
```

Then copy — **from the WORK COPY, never from live** (a worktree does not share gitignored content,
and live's copy is the stale clobber source, §2):

```bash
test ! -e "$NEW/.ccpraxis-local-data"                   # cp -a NESTS on a re-run; refuse if it exists
cp -a "$WC/.ccpraxis-local-data" "$NEW/.ccpraxis-local-data"
cp -a "$WC/deploy_key" "$WC/deploy_key.pub" "$NEW/"     # §3b — NOT under .ccpraxis-local-data
cp -a "$WC/.claude" "$NEW/.claude"
```

`cp` exit status is checked by `set -e`. Do **not** run C twice: `cp -a src dst` where `dst` exists
creates `dst/src`, silently nesting.

**GATE — expected literally, ALL of these:**

```bash
# 1. structural
ls "$NEW/.ccpraxis-local-data/blueprints"                                   # _archive sandbox-butler-overhaul sandbox-refuse-in-place
ls "$NEW/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages"/*.md | wc -l   # 24
# 2. the anti-clobber canary — the single most important line here
grep -h '^status:' "$NEW/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages"/*.md | sort | uniq -c
#    => 6 done / 2 parked / 16 pending.  "24 pending" means the WRONG tree was copied. STOP.
grep -c 'CRITERION AMENDED' "$NEW/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages/b07-auto-remediation-engine.md"   # 1
# 3. COMPLETENESS — a real comparison, not a size eyeball (red-team B-5)
diff -r --brief "$WC/.ccpraxis-local-data" "$NEW/.ccpraxis-local-data"      # => NO OUTPUT
diff -r --brief "$WC/.claude"              "$NEW/.claude"                   # => NO OUTPUT
cmp "$WC/deploy_key" "$NEW/deploy_key" && cmp "$WC/deploy_key.pub" "$NEW/deploy_key.pub"
# 4. the payload is really there
du -sh "$NEW/.ccpraxis-local-data/claude-home"                              # ~100M
```

**`diff -r --brief` producing no output is the gate.** A `du` figure with a `~` tolerance cannot
detect a truncated or partial copy; a recursive diff can. **STOP on any output at all.**

### D — prove the replacement BEFORE disabling the fallback

```bash
cd "$NEW" && claude-sandbox
```

Must launch as an **ordinary project** — no refusal, no prompt. This already works today with no code
change: `is_ccpraxis_project` matches the clone by content marker, but `is_in_place` is false, so
`workcopy_route` returns `passthrough`.

**GATE — the thesis of the entire initiative. Inside the container:**
- `git -C /project status --short` → **succeeds** (this is what the work copy could never do)
- `ls /project/.ccpraxis-local-data/blueprints` → the three entries from Phase C

**STOP — do not run E or F if in-container git does not work.** The replacement is unproven and the
work copy is still the only working setup.

### E — promote the refusal into the live install

```bash
set -eu
# The branch already exists in $LIVE's object store — the work copy was a worktree OF $LIVE, so
# Phase A's commit landed there. There is nothing to fetch and NO upstream to "pull from"
# (red-team M-3: the branch has no remote; "pull from your remote" was not executable as written).
git -C "$LIVE" status --short                       # must be clean before merging
git -C "$LIVE" branch --show-current                # expect: main
git -C "$LIVE" merge --no-ff ccpraxis-sandbox-workcopy
cd "$LIVE" && perl install.pl
```

**Merge BEFORE `branch -d` in F2.** `git branch -d` refuses to delete an unmerged branch — that
refusal is the safety net, and it only works if E has already merged. Running F before E would
either lose the branch (with `-D`) or block.

The refusal only takes effect in the **installed** tree: `claude-sandbox` runs
`~/.claude/plugins/marketplaces/ccpraxis-local/sandbox/scripts/launcher.pl`, a separate copy from any
repo (B11). Landing `p01` in a repo and stopping there leaves live still offering worktrees.

**GATE — must be OBSERVED DIRECTLY, never inferred from `install.pl` exiting 0:**

```bash
cd "$LIVE" && claude-sandbox ; echo "exit=$?"
```

Expected literally: STDERR begins `claude-sandbox will not sandbox the ccpraxis installation in place:`,
the message contains `--no-hardlinks`, and **`exit=1`**. No container starts.

**STOP if it launches instead of refusing.**

### F — tear down (destructive; `cd` OUT FIRST)

**Decision #14: the driver must not be inside the worktree when it removes it.**

```bash
cd "$NEW"          # or "$LIVE" — anywhere but $WC. DO THIS FIRST.
```

**F0 — the destruction pre-gate. Everything below is blocked on this passing.**

Red-team B-4: under the first draft, the *strongest* verification of the copied 179M ran in G, i.e.
**after** `$WC` was already destroyed. Decision #10 requires every destructive step to be gated on a
**positive verification of the corresponding copy**, so that verification moves here, before F2.

```bash
set -eu
test -d "$NEW/.ccpraxis-local-data/claude-home"
diff -r --brief "$WC/.ccpraxis-local-data" "$NEW/.ccpraxis-local-data"   # NO OUTPUT
diff -r --brief "$WC/.claude"              "$NEW/.claude"                # NO OUTPUT
cmp "$WC/deploy_key" "$NEW/deploy_key"
grep -h '^status:' "$NEW/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages"/*.md | sort | uniq -c
#   => 6 done / 2 parked / 16 pending
git -C "$NEW" log --oneline -1        # the Phase A commit is present in the clone
```

**Any output from either `diff`, or any failure here, STOPS the procedure.** Nothing below runs.

**F1 — re-enumerate live, and diff CONTENT not just names:**

```bash
ls "$LIVE/.ccpraxis-local-data/blueprints/"
```

Expected literally: exactly `_archive`, `sandbox-butler-overhaul`, `workcopy-git-durability` (§2).
**If an entry was added or removed, STOP and report** — a live fleet touches the live install
independently and §2 was recorded at prepare time.

Red-team B-2: matching *names* is not enough. §2's REMOVE reasons are **content** claims ("byte-identical
to the work copy's", "all 24 ledgers pending"), so a fleet write into live's copy would pass a
name-only check and be destroyed. Re-prove the content immediately before deleting:

```bash
# _archive must still be redundant (only the work copy's extra entry may differ)
diff -r --brief "$LIVE/.ccpraxis-local-data/blueprints/_archive" \
                "$NEW/.ccpraxis-local-data/blueprints/_archive"
#   => at most "Only in <NEW>/...: workcopy-git-durability".  ANYTHING ELSE => STOP.

# live's sandbox-butler-overhaul must still be the stale all-pending copy, not live work
grep -h '^status:' "$LIVE/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages"/*.md | sort | uniq -c
#   => 24 pending.  If ANY entry is done/parked/running, live has real work => STOP.
```

**F2 — remove the worktree, branch, and the re-verified copies:**

```bash
set -eu
: "${WC:?}" "${LIVE:?}" "${NEW:?}"          # refuse to run with any variable unset or empty
test "$PWD" != "$WC"                        # Decision #14, ENFORCED rather than advised
git -C "$LIVE" worktree remove "$WC"
git -C "$LIVE" branch -d ccpraxis-sandbox-workcopy    # -d not -D: refuses if unmerged
git -C "$LIVE" worktree prune
rm -rf "$LIVE/.ccpraxis-local-data/blueprints/workcopy-git-durability" \
       "$LIVE/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul" \
       "$LIVE/.ccpraxis-local-data/blueprints/_archive"
```

> **Correction to a claim in the first draft (red-team M-1):** "`worktree remove` refuses if dirty —
> that refusal is a feature" is **only half true and must not be relied on**. It refuses on modified
> *tracked* files, but **ignored files never block it** — which is exactly how `deploy_key`, `.claude/`
> and (before §3b) the whole gitignored payload would have been deleted without a murmur. And after
> Phase A's `git add -A` the tree is clean by construction, so the check is disarmed anyway. **F0 is
> the real guard; this refusal is not.**

**NEVER** run `ccpraxis-mergeback.pl discard` to "clean up" — it force-removes the worktree and
`branch -D`s, discarding uncommitted work. `p01` deleted that script precisely because it existed.

**GATE — expected literally:**
- `test -e "$WC"` → **fails** (path gone)
- `git -C "$LIVE" worktree list` → no longer lists `$WC`
- `git -C "$LIVE" branch --list ccpraxis-sandbox-workcopy` → **empty**
- `ls "$LIVE/.ccpraxis-local-data/blueprints/"` → **empty** (or the directory itself removed)

### G — verify against the backup, then delete it

Pre-migration backup: `C:/Users/André/ccpraxis-state-backup-20260728/` (182M, see its `RESTORE.md`).

**G1 — re-run the canaries in the CLONE:**

```bash
grep -h '^status:' "$NEW/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages"/*.md | sort | uniq -c
grep -c 'CRITERION AMENDED' "$NEW/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages/b07-auto-remediation-engine.md"
ls "$NEW/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages"/*.md | wc -l
du -sh "$NEW/.ccpraxis-local-data/claude-home"
test -f "$NEW/deploy_key" && test -d "$NEW/.claude"
find "$NEW/.ccpraxis-local-data" -type f | wc -l    # informational ONLY — see below
```

Expected literally: **6 done / 2 parked / 16 pending** across **24** ledgers; `CRITERION AMENDED` → **1**;
`claude-home` **~100M**; `deploy_key` and `.claude/` present.

> **The absolute file count is NOT a gate (red-team B-3).** The first draft pinned **1886**, the
> figure captured when the backup was taken. It was already **1901** hours later — the driving
> session writes ledgers, specs and reports into `.ccpraxis-local-data` continuously, so the number
> drifts by design. Pinning it would fire spuriously and invite exactly the wrong reaction. Use it
> only as a sanity band: it must be **≥ 1886 and within a few percent**. A count *far below* the
> backup's is the real signal, and the recursive `diff` in F0 is the actual completeness proof.

**G2 — if ANY canary fails: STOP. Do NOT delete the backup, and do NOT blind-copy over the clone.**

> **Do not run `cp -a backup/. clone/` as a first response (red-team B-3).** The backup is a *point-in-time*
> snapshot that is now older than the clone. Merge-copying it over newer ledgers reverts them — which
> is precisely the B4 clobber shape this entire initiative exists to eliminate. Diagnose first: use
> `diff -r --brief backup/workcopy-ccpraxis-local-data "$NEW/.ccpraxis-local-data"` to see *what*
> differs, and restore only the specific paths that are genuinely missing or corrupt. Record the stop
> in the Post-run log.

**G3 — only after a clean verify.** First prove the backup and the clone actually agree on the
things that matter (red-team M-9: the first draft deleted the backup on the strength of checks that
never opened it):

```bash
BK=/c/Users/André/ccpraxis-state-backup-20260728
diff -r --brief "$BK/workcopy-ccpraxis-local-data/blueprints/_archive" \
                "$NEW/.ccpraxis-local-data/blueprints/_archive"          # NO OUTPUT
cmp "$BK/workcopy-root-gitignored/deploy_key" "$NEW/deploy_key"
test -d "$NEW/.ccpraxis-local-data/claude-home/projects"
```

Then, and only then:

```bash
rm -rf "$BK"
```

**GATE:** backup directory gone, and the clone still passes G1 afterwards.

> **Deleting the backup is the last irreversible act in the whole initiative.** If there is any
> doubt at all, keep it — it costs 182M of disk and nothing else. The blueprint counts as done with
> a *deliberately retained* backup provided the retention and its reason are recorded in the
> Post-run log; what it must never be is silently left behind with G unverified.

> **The blueprint is not done while that backup exists** — a surviving backup means G never confirmed
> the migration.

---

## 5b. `p03` liveness — checked, and it does NOT gate Phase A

Phase A commits the work copy and Phase F destroys it, so any package still writing there would be
at risk.

**Checked on disk 2026-07-28:** `p03-checkpoint-reverify` is **`status: parked`**, not running. It was
parked because its cross-blueprint precondition is unmet —
`blueprints/sandbox-butler-overhaul/packages/b02-durable-checkpoint-commits.md` reads
`status: pending`, so there is no delivered implementation to re-verify. No coordinator marker or live
process for it exists.

**Therefore Phase A is NOT gated on `p03`.** Its only deliverable would have been a tracked doc
(`plugins/sandbox/docs/checkpoint-reverify.md`), which ordinary git would carry into the clone if it
is ever written — which is precisely the workflow this initiative establishes. The blueprint
anticipates this: "`p04` deliberately does NOT depend on `p03` … the migration must not be held
hostage to that."

**If `p03` is ever unparked and run *before* the migration**, re-check its status before Phase A and
re-run Phase A's clean-tree gate; nothing else in this sequence changes.

## 6. Preconditions — all verified, none unverifiable

| precondition | status |
|---|---|
| `$WC` resolves and is a git worktree | ✅ `git rev-parse --show-toplevel` |
| `$LIVE` resolves and exists | ✅ independently re-derived + `-d` |
| `$NEW` is free, parent exists | ✅ |
| live blueprints dir readable + enumerated | ✅ 3 entries, §2 |
| live `_archive` redundancy | ✅ proven by `diff -r --brief`, not assumed |
| gitignored payload measured | ✅ 76M / 100M / 179M |
| `.gitignore` read in full | ✅ §4 |
| `claude-home` inode hazard | ✅ documented; Phase C stops the container first |

**No precondition could not be verified**, so this package does **not** park.

---

## 7. Red-team pass and what it changed

The first draft of this sequence was attacked by `bp-redteam` on 2026-07-28 and came back
**6 BLOCKER / 10 MAJOR / 6 MINOR / 3 NIT — "DO NOT RUN AS WRITTEN"**, with two blockers firing on the
happy path with no operator error required. The coordinator independently re-verified the two most
consequential before rewriting. Both were real:

| id | defect | verified how | fix |
|---|---|---|---|
| **B-1** | `deploy_key`, `deploy_key.pub`, `.claude/` are gitignored at `$WC` **root**, outside `.ccpraxis-local-data/`. Phase C never copied them, the safety backup never held them, and `git worktree remove` deletes ignored files silently — so Phase F destroyed the container's git SSH key with no copy anywhere. | `git status --ignored --short` at `$WC`; backup listing showed only the two `.ccpraxis-local-data` trees | §3b added; backup extended to `workcopy-root-gitignored/` and verified byte-identical; Phase C copies them explicitly; F0 and G1 check them |
| **B-3** | the `1886` file-count canary was already false. | measured **1901** — it drifts continuously because the driving session writes ledgers/reports | demoted to an informational sanity band; `diff -r --brief` is the real completeness proof. G2's blind `cp -a backup/. clone/` "restore" removed — it would revert newer ledgers, i.e. re-enact the B4 clobber |
| **B-2** | F2's `rm -rf` targets were gated on directory **names** while §2's REMOVE reasons are **content** claims — a live-fleet write into live's `sandbox-butler-overhaul` would pass F1 and be destroyed | reasoning | F1 now re-proves content: recursive diff of `_archive`, and live's overhaul copy must still read **24 pending** |
| **B-4** | the strongest verification of the copied 179M ran in G, i.e. **after** `$WC` was destroyed — a direct violation of Decision #10 | reading the draft's own order | **F0** added: a destruction pre-gate that must pass before anything in F runs |
| **B-5** | C's gate could not detect a partial copy — `~179M` `du` tolerances, no `cp` exit check, no comparison | reasoning | `set -e`, a refuse-if-destination-exists check, and `diff -r --brief` producing **no output** as the gate |
| **B-6** | the driver's own Post-run log rows for phases C–G live in `$WC` and are destroyed by F, never re-synced | reading the procedure against the blueprint's log table | §5.0b: the authoritative blueprint copy moves to the clone after C; F0's diff catches violations |

Majors also fixed: the false "`worktree remove` refuses if dirty — a FEATURE" claim (M-1, ignored
files never block it and `add -A` disarms it anyway); Decision #14 made an **enforced**
`test "$PWD" != "$WC"` rather than prose (M-2); Phase E given real merge commands and its impossible
"pull from your remote" removed (M-3); the off-machine-copy gap recorded as an explicit recommendation
(M-4); `origin` renamed away from the live install (M-5); `cp -a` re-run nesting guarded (M-6);
`podman stop` given a verification and told to re-derive the container name (M-7); backup deletion
now actually inspects the backup (M-9); shell, `set -eu` and `:?` variable guards specified (M-10).

**Cleared by the red-team as already sound:** the coarse phase order, `--no-hardlinks`, `branch -d`
over `-D`, the `24 pending` anti-clobber canary, the `ccpraxis-mergeback.pl discard` warning, §5b's
`p03` analysis, and that Phase E does not strand the fallback (`$WC` is not the install anchor, so
promoting the refusal does not disable the work copy).

Full report: `.ccpraxis-local-data/blueprints/sandbox-refuse-in-place/reports/p04-migrate-promote-teardown/redteam.md`
