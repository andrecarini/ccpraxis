---
name: backup
description: Sync Claude Code config to the export repo, scan for secrets, commit and push
disable-model-invocation: true
user-invocable: true
allowed-tools: Bash, Read, Write, Edit
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
3. Present a clear summary to the user: what's different, which changes are on which side
4. Propose a merged version
5. Ask the user to approve before writing
6. On approval, write the merged result to BOTH locations

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

Show the user what will be committed. If they approve:

```bash
git commit -m "<descriptive message>"
git pull --rebase
git push
```

If the repo has no remote configured, skip the pull/push and tell the user to set one up.

## Step 6: Report

Summarize: what was synced, what was merged, what was committed, and whether the push succeeded.
