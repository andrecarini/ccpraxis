---
name: backup
description: Sync Claude Code config to the export repo, scan for secrets, commit and push
user-invocable: true
host-only: true
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

Sync the Claude Code config between `~/.claude/` (live) and the export repo at `~/.claude/claude-code-config/`.

## Step 1: Pull latest from remote

```bash
cd "$HOME/.claude/claude-code-config" && git pull --rebase 2>&1 || true
```

If the repo has no remote configured, skip this step silently.

## Step 1.5: Ensure local installation is up to date

After pulling, make sure the local `~/.claude/` is wired up correctly. This catches new skills, updated CLAUDE.md, and settings changes introduced by the pull.

**Skills:** For each subdirectory in `~/.claude/claude-code-config/skills/`, ensure `~/.claude/skills/` has a matching copy or symlink. Remove any existing file/directory first and re-create it — use symlinks on Unix, copies on Windows (where `ln -s` silently falls back to copying and `-L` checks always fail):

```bash
mkdir -p ~/.claude/skills
for skill in ~/.claude/claude-code-config/skills/*/; do
  name="$(basename "$skill")"
  rm -rf ~/.claude/skills/"$name"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cp -r "$skill" ~/.claude/skills/"$name" ;;
    *) ln -sf "$skill" ~/.claude/skills/"$name" ;;
  esac
done
```

**CLAUDE.md:** On Unix, if `~/.claude/CLAUDE.md` is not a symlink to the repo version, flag it. On Windows, compare content against `~/.claude/claude-code-config/global-config/CLAUDE.md` — if they differ, flag it. Don't change it automatically in either case (the user may have intentionally merged content).

**settings.json:** Run the merge script to pick up any new keys from the repo defaults (preserves local permissions):

```bash
perl ~/.claude/claude-code-config/scripts/merge-settings.pl ~/.claude/settings.json ~/.claude/claude-code-config/global-config/settings.json > /tmp/merged-settings.json && mv /tmp/merged-settings.json ~/.claude/settings.json
```

## Step 2: Detect differences

Run the detection script:

```
bash "$HOME/.claude/claude-code-config/scripts/sync-export.sh"
```

This outputs JSON describing each file's sync status:
- `identical` — no action needed
- `live_only` — exists in live but not export → copy to export
- `export_only` — exists in export but not live → copy to live
- `conflict` — both sides differ → needs merge (Step 2)
- `settings_changed` — settings.json differs (merge needed)

## Step 3: Handle each file

For **identical** files: skip, report as in sync.

For **live_only** / **export_only**: copy the file to the missing side.

For **settings_changed**: merge settings.json — export all keys except `permissions` from live to the repo. Preserve any keys in the repo version that don't exist in live. Write the merged result to the repo.

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
bash "$HOME/.claude/claude-code-config/scripts/sensitive-check.sh" "$HOME/.claude/claude-code-config"
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

## Step 6: Check for missing plugins

Read `enabledPlugins` from the repo's `global-config/settings.json`. Compare against `~/.claude/plugins/installed_plugins.json` (if it exists). If any plugins are listed in the config but not installed locally, inform the user and offer to install them with `/plugin install <name>@<marketplace>`.

## Step 7: Report

Summarize: what was synced, what was merged, what was committed, whether the push succeeded, and whether any plugins were installed.
