---
name: backup
description: Sync Claude Code config to the export repo, scan for secrets, commit and push
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

Sync the Claude Code config between `~/.claude/` (live) and the export repo at `~/.claude/claude-code-config/`.

## Step 1: Pull latest from remote

```bash
cd "$HOME/.claude/claude-code-config" && git pull --rebase 2>&1 || true
```

If the repo has no remote configured, skip this step silently.

## Step 2: Detect differences

Run the detection script:

```
bash "$HOME/.claude/sync-export.sh"
```

This outputs JSON describing each file's sync status:
- `identical` — no action needed
- `live_only` — exists in live but not export → copy to export
- `export_only` — exists in export but not live → copy to live
- `conflict` — both sides differ → needs merge (Step 2)
- `settings_changed` — settings.json needs re-export (one-way, sanitized)

## Step 3: Handle each file

For **identical** files: skip, report as in sync.

For **live_only** / **export_only**: copy the file to the missing side.

For **settings_changed**: regenerate the sanitized settings.json in the export repo using the Perl one-liner from `sync-export.sh`.

For **conflict** files:
1. Read BOTH versions (live and export)
2. Understand what changed on each side
3. For each conflict, use AskUserQuestion to ask the user how to resolve it:
   - **"Use live version"** — live overwrites export
   - **"Use export version"** — export overwrites live
   - **"Merge"** — present a merged version for approval, then write to BOTH locations
   If all conflicts have the same obvious cause (e.g., line-ending differences only), batch
   them into a single AskUserQuestion instead of asking one-by-one.

## Step 4: Sensitive data scan

Before committing, run the sensitive data scanner:

```
bash "$HOME/.claude/sensitive-check.sh" "$HOME/.claude/claude-code-config"
```

If it finds anything, show the user what was detected and **do NOT proceed** with git operations until resolved.

## Step 5: Git operations

Only after the scan passes:

```bash
cd "$HOME/.claude/claude-code-config"
git add -A
git status
```

Show what will be committed, then use AskUserQuestion as a final confirmation:
- **"Push it"** — commit, pull --rebase, and push
- **"Abort"** — discard staged changes and stop

If the repo has no remote configured, commit locally and tell the user to set up a remote.

## Step 6: Report

Summarize: what was synced, what was merged, what was committed, and whether the push succeeded.
