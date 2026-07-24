---
name: mergeback
description: Guarded merge-back of the ccpraxis self-host work-copy branch into live main. Use when the user has finished reviewing an in-sandbox self-host run and wants to merge the ~/ccpraxis-sandbox-workcopy branch back into the live ccpraxis. Refuses while a sandbox fleet is live; shows the diff. ALWAYS confirm with the user before committing the merge — never auto-merge.
user-invocable: true
host-only: true
argument-hint: "[--yes]"
allowed-tools: Bash, Read, AskUserQuestion
related:
  - discard
---

# Mergeback — Guarded self-host merge-back

Merge the self-host work-copy branch back into live ccpraxis `main`. The script
(`ccpraxis-mergeback.pl merge`) is the source of truth for the guard, the merge, and cleanup;
the script's own tty prompt is for direct terminal use. Because this skill runs non-interactively,
**you** own the confirmation: preview the diff read-only, ask the user, then run the script with
`--yes` (which still re-runs the fleet guard first and refuses if a run is live).

## Steps

1. **Preview (read-only, no side effects).** Show what would merge:
   `git -C ~/.claude/ccpraxis --no-pager diff main...ccpraxis-sandbox-workcopy`
   If the branch doesn't exist, tell the user there's no work-copy to merge and stop.
2. **Confirm.** Present the diff (summarize if large) and ask via `AskUserQuestion` whether to
   merge it into live `main`. This is the ALWAYS-confirm gate — never skip it.
3. **On confirm**, run `perl ~/.claude/ccpraxis/plugins/sandbox/scripts/ccpraxis-mergeback.pl merge --yes`.
   The script re-checks the fleet guard (refuses if a run is live), verifies live is on a clean
   `main`, merges `--no-ff`, commits, then removes the worktree + branch.
4. **Relay the result:** if `BLOCKED:` is printed, a fleet is live — stop and report, do not retry.
   If a conflict is reported (`merge aborted (conflict)`), relay it and stop — nothing was committed,
   the work-copy is kept. Otherwise relay the `STATUS:` line (`merged and cleaned up`).
5. If the user declines at step 2, do nothing (the work-copy is kept for later merge or `/selfhost:discard`).
