---
name: backup
description: Sync Claude Code config (live host ↔ global-config ↔ container-config), backup live settings, scan for secrets, commit and push
user-invocable: true
host-only: true
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

Sync the Claude Code config between `~/.claude/` (live) and the export repo at `~/.claude/claude-code-config/`.

## Step 1: Integrate remote

```bash
cd "$HOME/.claude/claude-code-config" && git fetch origin 2>&1 || true
```

If the repo has no remote configured, skip this step silently.

If remote has new commits, integrate them now so the repo is fully up to date before syncing:

```bash
cd "$HOME/.claude/claude-code-config"
# Stash any uncommitted local changes (from /create-skill, manual edits, etc.)
git stash 2>&1 || true
# Merge remote — fast-forward when possible, merge commit when diverged
git merge origin/main --no-edit 2>&1
# Re-apply stashed changes
git stash pop 2>&1 || true
```

If the merge or stash pop produces conflicts, resolve them automatically by reading both versions and producing a clean merge. Only use AskUserQuestion if both sides made substantial, incompatible changes to the same section and the right resolution is genuinely ambiguous.

After this step, the repo is fully up to date with remote.

## Step 1.5: Ensure local installation is up to date

Make sure the local `~/.claude/` is wired up correctly. This catches new skills, updated CLAUDE.md, and settings changes from remote or local edits.

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

**settings.json:** Before making any changes to `~/.claude/settings.json`, create a timestamped backup:

```bash
cp ~/.claude/settings.json "$HOME/.claude/settings.json.$(date +%Y-%m-%dT%H%M%S)"
```

Do NOT auto-modify the live settings without user approval. Run the semantic diff to see exactly what differs:

```bash
perl "$HOME/.claude/claude-code-config/scripts/json-diff.pl" ~/.claude/settings.json ~/.claude/claude-code-config/global-config/settings.json
```

This outputs a JSON report with:
- `identical` — keys with matching values in both files
- `only_left` — keys only in the live settings (first argument)
- `only_right` — keys only in the repo settings (second argument)
- `diverged` — keys present in both but with different values (shows both sides)

If the report's `status` is `"identical"`, skip silently. Otherwise, for each entry in `only_left`, `only_right`, and `diverged`, use AskUserQuestion to present the differences and let the user choose:
- **"Use live value"** — no change to live; repo will be updated during export in Step 3
- **"Use repo value"** — update the live settings.json with the repo value
- **"Skip"** — leave both sides as-is

**Marketplaces:** Compare `~/.claude/plugins/known_marketplaces.json` (live) against `~/.claude/claude-code-config/global-config/known_marketplaces.json` (repo). Ignore `installLocation` when comparing (it's machine-specific). For each discrepancy, use AskUserQuestion to present the difference and let the user choose:

- **Marketplace in live but not repo** (added locally):
  - **"Export to repo"** — will be included in the repo version
  - **"Remove locally"** — remove with `/plugin marketplace remove <name>`
  - **"Skip"** — leave both sides as-is (same discrepancy next sync)

- **Marketplace in repo but not live** (from another machine, or removed locally):
  - **"Add locally"** — add with `/plugin marketplace add <source>` (`<owner>/<repo>` for GitHub, URL for others)
  - **"Remove from repo"** — will be excluded from the repo version
  - **"Skip"** — leave both sides as-is (same discrepancy next sync)

- **Same marketplace, different `source`** (source URL changed):
  - **"Use live"** — repo will be updated to match
  - **"Use repo"** — inform the user to `/plugin marketplace remove <name>` and `/plugin marketplace add <repo-source>` to update locally
  - **"Skip"** — leave both sides as-is (same discrepancy next sync)

After all choices, write the reconciled result to `global-config/known_marketplaces.json`. Strip `installLocation` from each entry before writing (paths are machine-specific). If no discrepancies exist, skip silently.

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
- `marketplace_changed` — known_marketplaces.json differs (already reconciled in Step 1.5)
- `container_settings_diverged` — container-config/settings.json has shared keys that differ from global-config (Step 3.5)

## Step 3: Handle each file

For **identical** files: skip, report as in sync.

For **live_only** / **export_only**: copy the file to the missing side.

For **settings_changed**: merge settings.json — export all keys from live to the repo (including `permissions`). Preserve any keys in the repo version that don't exist in live. Write the merged result to the repo.

For **conflict** files:
1. Read BOTH versions (live and export)
2. Understand what changed on each side
3. For each conflict, use AskUserQuestion to ask the user how to resolve it:
   - **"Use live version"** — live overwrites export
   - **"Use export version"** — export overwrites live
   - **"Merge"** — present a merged version for approval, then write to BOTH locations
   If all conflicts have the same obvious cause (e.g., line-ending differences only), batch
   them into a single AskUserQuestion instead of asking one-by-one.

For **container_settings_diverged**: handled in Step 3.5 after global-config is finalized — no action here.

For **marketplace_changed**, **live_only**, or **export_only** marketplace: already reconciled in Step 1.5 — no additional action needed.

## Step 3.5: Container settings sync

After `global-config/settings.json` is finalized in Step 3, run the semantic diff against `container-config/settings.json`:

```bash
perl "$HOME/.claude/claude-code-config/scripts/json-diff.pl" ~/.claude/claude-code-config/global-config/settings.json ~/.claude/claude-code-config/container-config/settings.json
```

If the report's `status` is `"identical"`, skip silently. Otherwise:

1. For each entry in `diverged` (shared keys with different values), use AskUserQuestion to present the difference and let the user choose:
   - **"Propagate to container"** — update the key in `container-config/settings.json` to match `global-config`
   - **"Keep container value"** — leave `container-config/settings.json` as-is
   - **"Skip"** — leave as-is for now

   If multiple keys differ, batch into a single multiSelect AskUserQuestion showing all divergences.

2. Keys in `only_right` (only in `container-config`) are often intentionally container-specific. Do not remove them.

3. Keys in `only_left` (only in `global-config`) are often intentionally absent from the container. Do not add them automatically — only mention if the user asks.

## Step 4: Sensitive data scan

Before committing, run the sensitive data scanner:

```
bash "$HOME/.claude/claude-code-config/scripts/sensitive-check.sh" "$HOME/.claude/claude-code-config"
```

If it finds anything, show the user what was detected and **do NOT proceed** with git operations until resolved.

## Step 5: Commit and push

Only after the scan passes:

```bash
cd "$HOME/.claude/claude-code-config"
git add -A
git status
```

If nothing to commit and local is up to date with remote: report "Everything is already in sync" and skip to Step 6.

If there are changes to commit, summarize what's being sent (new files, modified files, key changes). Use AskUserQuestion:
- **"Push it"** — commit and push
- **"Abort"** — discard staged changes and stop

If confirmed: commit and push. Since Step 1 already integrated remote, pushing is always a clean fast-forward.

If the repo has no remote configured, commit locally and tell the user to set up a remote.

## Step 6: Check for missing plugins

Read `enabledPlugins` from the repo's `global-config/settings.json`. Compare against `~/.claude/plugins/installed_plugins.json` (if it exists). If any plugins are listed in the config but not installed locally:

1. For each missing plugin, check that its marketplace (the part after `@` in the plugin key) exists in `~/.claude/plugins/known_marketplaces.json`. If a marketplace is missing, inform the user to add it first with `/plugin marketplace add`.
2. For plugins whose marketplace is present, inform the user and offer to install them with `/plugin install <name>@<marketplace>`.

## Step 7: Report

Summarize: what was synced, what was merged, what was committed, whether the push succeeded, whether any marketplaces were added, and whether any plugins were installed.
