---
name: discard
description: Guarded discard of the ccpraxis self-host work-copy WITHOUT merging. Use when the user wants to throw away the ~/ccpraxis-sandbox-workcopy branch entirely after an in-sandbox self-host run. Refuses while a sandbox fleet is live. ALWAYS confirm with the user before discarding the work-copy — this action is irreversible.
user-invocable: true
host-only: true
argument-hint: "[--yes]"
allowed-tools: Bash, Read, AskUserQuestion
related:
  - mergeback
---

# Discard — Guarded self-host work-copy discard

Remove the self-host work-copy WITHOUT merging (worktree remove + `branch -D`). **Destructive:**
any unmerged commits on `ccpraxis-sandbox-workcopy` are thrown away. The script
(`ccpraxis-mergeback.pl discard`) owns the guard + removal; this skill owns the confirmation.

## Steps

1. **Confirm first.** Warn the user this permanently discards the work-copy and any unmerged work,
   and ask via `AskUserQuestion` whether to proceed. This is the ALWAYS-confirm gate — never skip it.
   If they want to keep the work, suggest `/selfhost:mergeback` instead.
2. **On confirm**, run `perl ~/.claude/ccpraxis/plugins/sandbox/scripts/ccpraxis-mergeback.pl discard --yes`.
   The script re-runs the fleet guard first (refuses if a run is live), then removes the worktree
   (forcing if it has uncommitted changes) and force-deletes the branch.
3. **Relay the result:** if `BLOCKED:` is printed, a fleet is live — stop and report, do not retry.
   Otherwise relay the `STATUS:` line (`discarded work-copy`).
4. If the user declines at step 1, do nothing — the work-copy is kept.
