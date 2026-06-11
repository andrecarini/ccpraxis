---
name: backup
description: Syncs everything personal between the live host and your private repos — ccpraxis config (global + container) AND every project registered for vault backup (CLAUDE.md, skills, plans, memory). Scans for secrets before pushing. Resolves vault sync conflicts interactively. If you're in a project that has trackable Claude files but isn't registered for backup, offers to register it. Also surfaces Claude Code binary snapshots taken by /update and supports manual revert. Use when the user wants to sync config, back up settings, push config changes, sync vault projects, list/revert Claude Code snapshots, or says "backup", "sync config", "push config", "sync everything", "back up my work", "revert claude code", "list claude snapshots", "rollback claude".
user-invocable: true
host-only: true
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Skill
---

## Two modes

This skill has two modes:

1. **Default (full sync):** when the user says "backup", "sync config", etc. — run Steps 1 through 7 below (full config + vault sync).
2. **Snapshot/revert (Step R):** when the user says "revert claude code", "list snapshots", "rollback claude code", "restore claude code binary", or similar — skip directly to **Step R** at the bottom. Don't run the full sync flow.

If intent is unclear, use AskUserQuestion to choose.

Sync your ccpraxis between `~/.claude/` (live) and the export repo at `~/.claude/ccpraxis/`, then sync every vault-registered project at `~/.claude/claude-code-vault/projects/<slug>/`.

## Step 1: Integrate remote

```bash
cd "$HOME/.claude/ccpraxis" && git fetch origin 2>&1 || true
```

If the repo has no remote configured, skip this step silently.

If remote has new commits, integrate them now so the repo is fully up to date before syncing:

```bash
cd "$HOME/.claude/ccpraxis"
# Stash any uncommitted local changes (from /steward:ccpraxis-extend, manual edits, etc.)
git stash 2>&1 || true
# Merge remote — fast-forward when possible, merge commit when diverged
git merge origin/main --no-edit 2>&1
# Re-apply stashed changes
git stash pop 2>&1 || true
```

If the merge or stash pop produces conflicts, resolve them automatically by reading both versions and producing a clean merge. Only use AskUserQuestion if both sides made substantial, incompatible changes to the same section and the right resolution is genuinely ambiguous.

After this step, the repo is fully up to date with remote.

## Step 1.2: README drift pre-flight

Before committing or pushing, make sure README.md still describes the repo as it actually is on disk. Two cheap linters catch the common drift cases — they exist precisely so we don't ship a README that references files we renamed or deleted.

```bash
perl ~/.claude/ccpraxis/scripts/lint-readme-paths.pl
perl ~/.claude/ccpraxis/scripts/gen-readme-tree.pl --check
```

Handle each:

- **`lint-readme-paths.pl`** — fails (exit 1) when an inline backticked path (e.g. ``` `scripts/foo.pl` ```) doesn't resolve on disk. Stdout names each missing path with its README line number. Surface them to the user and offer to fix: either correct the path in the README, or — if the backtick is an intentional non-host reference (container-internal etc.) — add the literal to `scripts/lint-readme-paths.allow`.

- **`gen-readme-tree.pl --check`** — fails (exit 1) when the file-tree section between the `<!-- BEGIN-FILE-TREE -->` markers is stale. The fix is mechanical: run `perl ~/.claude/ccpraxis/scripts/gen-readme-tree.pl --write` to regenerate the tree, then re-read the README — newly-added entries appear with no description until you write a `.about` sidecar (or a plugin.json / SKILL.md / script-comment description) for them. Ask the user before running `--write` if there are entries to describe; if it's just structural (an existing entry moved), running `--write` directly is fine.

Don't auto-fix without confirmation — drift sometimes signals intent (e.g. the user moved a file but the description is still accurate, just needs a path update). When in doubt, surface and ask.

## Step 1.5: Ensure local installation is up to date

Make sure the local `~/.claude/` is wired up correctly. This catches new skills, updated CLAUDE.md, and settings changes from remote or local edits.

**Skills:** Mirror every skill in `~/.claude/ccpraxis/skills/` to `~/.claude/skills/`. Symlink on Unix, copy on Windows. Idempotent — `unchanged` rows mean nothing was touched.

```bash
perl ${CLAUDE_PLUGIN_ROOT}/scripts/ccpraxis-helpers.pl sync-skills
```

Parse the JSON. If `status` is `partial`, surface the per-skill errors. Otherwise mention any non-`unchanged` results in the Step 7 report. Do NOT iterate the loop yourself — the script owns the file-system writes.

**CLAUDE.md:**

```bash
perl ${CLAUDE_PLUGIN_ROOT}/scripts/ccpraxis-helpers.pl check-claude-md
```

Parse the JSON `status`:
- `linked` or `equal_content` — silently OK, no action.
- `differs` (Windows) or `symlinked_elsewhere` (Unix) — flag it in the Step 7 report. Don't change it automatically (the user may have intentionally merged content).
- `missing_live` / `missing_repo` — flag prominently.

**settings.json:** Before making any changes to `~/.claude/settings.json`, create a timestamped backup:

```bash
cp ~/.claude/settings.json "$HOME/.claude/settings.json.$(date +%Y-%m-%dT%H%M%S)"
```

Do NOT auto-modify the live settings without user approval. Run the semantic diff filtered through saved preferences:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/json-diff.pl" ~/.claude/settings.json ~/.claude/ccpraxis/global-config/settings.json \
  | perl "${CLAUDE_PLUGIN_ROOT}/scripts/filter-diff.pl" --prefs "$HOME/.claude/ccpraxis/.backup-preferences.json" --scope live_vs_repo
```

This outputs a JSON report with:
- `auto_applied` — keys skipped due to saved preferences (notify the user these were applied)
- `needs_decision` — keys requiring user input, grouped by `only_left`, `only_right`, `diverged`
- `has_undecided` — boolean, whether any keys need a decision

Note: keys whose values are nested objects on both sides (like `env`, `enabledPlugins`) are expanded to dotted sub-keys (e.g., `env.DISABLE_LOGIN_COMMAND`). Present each sub-key as an individual decision.

If `status` is `"identical"`, skip silently. If there are `auto_applied` entries, list them briefly (e.g. "Applied 2 saved preferences: `key1` (intentionally different), `key2` (live-only)").

For each key in `needs_decision`, use AskUserQuestion to present the difference and let the user choose:

- For `diverged` keys:
  - **"Use live value"** — one-time sync; repo will be updated during export in Step 3
  - **"Use repo value"** — update the live settings.json with the repo value
  - **"Keep different (remember)"** — leave both as-is and save preference so this key is not asked about again
  - **"Skip"** — leave both sides as-is (will be asked again next sync)
- For `only_left` keys (only in live):
  - **"Export to repo"** — repo will pick it up during export in Step 3
  - **"Keep live-only (remember)"** — save preference so this key is not asked about again
  - **"Skip"** — will be asked again next sync
- For `only_right` keys (only in repo):
  - **"Add to live"** — update live settings.json with the repo value
  - **"Keep repo-only (remember)"** — save preference so this key is not asked about again
  - **"Skip"** — will be asked again next sync

For any choice that includes "(remember)", save the preference:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/save-preference.pl" \
  --prefs "$HOME/.claude/ccpraxis/.backup-preferences.json" \
  --scope live_vs_repo --key "<KEY>" --category "<CATEGORY>" --action "<ACTION>"
```

Map each "(remember)" option to its `--category` and `--action`:

| Option label | `--category` | `--action` |
|---|---|---|
| Keep different (remember) | `diverged` | `skip-always` |
| Keep live-only (remember) | `only_left` | `left-only` |
| Keep repo-only (remember) | `only_right` | `right-only` |

**Marketplaces:** Detect discrepancies between live and repo `known_marketplaces.json` (the script strips `installLocation` before comparing):

```bash
perl ${CLAUDE_PLUGIN_ROOT}/scripts/ccpraxis-helpers.pl marketplace-diff
```

Parse the JSON. If `status` is `identical`, skip silently. Otherwise iterate `live_only`, `repo_only`, and `diverged` — for each discrepancy, use AskUserQuestion to present the difference and let the user choose:

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
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync-export.sh"
```

This outputs JSON describing each file's sync status:
- `identical` — no action needed
- `live_only` — exists in live but not export → copy to export
- `export_only` — exists in export but not live → copy to live
- `conflict` — both sides differ → needs merge (Step 2)
- `settings_changed` — settings.json differs (merge needed)
- `marketplace_changed` — known_marketplaces.json differs (already reconciled in Step 1.5)
- `container_settings_diverged` — plugins/sandbox/container/settings.json has shared keys that differ from global-config (Step 3.5)

## Step 3: Handle each file

For **identical** files: skip, report as in sync.

For **live_only** / **export_only**: copy the file to the missing side.

For **settings_changed**: run the deterministic merge script (live wins on shared keys; keys only in repo are preserved). Don't hand-merge JSON — the script handles atomic write and post-write verification:

```bash
perl ${CLAUDE_PLUGIN_ROOT}/scripts/ccpraxis-helpers.pl settings-export-merge
```

Surface the result. If `status: error`, stop and report the JSON.

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

After `global-config/settings.json` is finalized in Step 3, run the semantic diff filtered through saved preferences:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/json-diff.pl" ~/.claude/ccpraxis/global-config/settings.json ~/.claude/ccpraxis/plugins/sandbox/container/settings.json \
  | perl "${CLAUDE_PLUGIN_ROOT}/scripts/filter-diff.pl" --prefs "$HOME/.claude/ccpraxis/.backup-preferences.json" --scope global_vs_container
```

Note: keys whose values are nested objects on both sides (like `env`, `enabledPlugins`) are expanded to dotted sub-keys (e.g., `env.DISABLE_LOGIN_COMMAND`). Present each sub-key as an individual decision.

If `status` is `"identical"`, skip silently. If there are `auto_applied` entries, list them briefly (e.g. "Applied 3 saved preferences: `env.FOO` (container-only), `model` (intentionally different), ...").

For each key in `needs_decision`, use AskUserQuestion to present the difference and let the user choose:

- For `diverged` keys (same key, different values):
  - **"Propagate to container"** — one-time sync; update `plugins/sandbox/container/settings.json` to match `global-config`
  - **"Keep container value"** — leave `plugins/sandbox/container/settings.json` as-is (one-time)
  - **"Keep different (remember)"** — leave both as-is and save preference so this key is not asked about again
  - **"Skip"** — leave as-is (will be asked again next sync)
- For `only_left` keys (only in global-config):
  - **"Add to container"** — copy the key to `plugins/sandbox/container/settings.json`
  - **"Keep global-only (remember)"** — save preference so this key is not asked about again
  - **"Skip"** — will be asked again next sync
- For `only_right` keys (only in plugins/sandbox/container):
  - **"Keep container-only (remember)"** — save preference so this key is not asked about again
  - **"Remove from container"** — delete the key from `plugins/sandbox/container/settings.json`
  - **"Skip"** — will be asked again next sync

For any choice that includes "(remember)", save the preference:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/save-preference.pl" \
  --prefs "$HOME/.claude/ccpraxis/.backup-preferences.json" \
  --scope global_vs_container --key "<KEY>" --category "<CATEGORY>" --action "<ACTION>"
```

Map each "(remember)" option to its `--category` and `--action`:

| Option label | `--category` | `--action` |
|---|---|---|
| Keep different (remember) | `diverged` | `skip-always` |
| Keep global-only (remember) | `only_left` | `left-only` |
| Keep container-only (remember) | `only_right` | `right-only` |

## Step 4: Sensitive data scan

Before committing, run the sensitive data scanner:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sensitive-check.sh" "$HOME/.claude/ccpraxis"
```

If it finds anything, show the user what was detected and **do NOT proceed** with git operations until resolved.

## Step 5: Commit and push

Only after the scan passes:

```bash
cd "$HOME/.claude/ccpraxis"
git add -A
git status
```

If nothing to commit and local is up to date with remote: report "Everything is already in sync" and skip to Step 6.

If there are changes to commit, summarize what's being sent (new files, modified files, key changes). Use AskUserQuestion:
- **"Push it"** — commit and push
- **"Abort"** — discard staged changes and stop

If confirmed: commit and push. Since Step 1 already integrated remote, pushing is always a clean fast-forward.

If the repo has no remote configured, commit locally and tell the user to set up a remote.

## Step 5.4: Sync todos

Todos live at the vault root in `todos/` (separate from per-project content). They're written locally by `/create-todo` and `/manage-todos`, which no longer self-sync — `/steward:backup` owns committing and pushing them. Run this **before** the project syncs below, so the vault working tree is clean for their `git pull --rebase`.

First check the vault exists (same check as Step 5.5):

```bash
[ -d "$HOME/.claude/claude-code-vault/.git" ] && echo "VAULT_OK" || echo "VAULT_MISSING"
```

If `VAULT_MISSING`, skip this step. Otherwise:

```bash
perl "$HOME/.claude/ccpraxis/scripts/todo-sync.pl" sync "backup: sync todos"
```

`todo-sync.pl` lives in `scripts/` (it's the shared todo engine, not part of steward). Its `sync` `git stash -u`s any uncommitted vault state, rebases onto origin, commits **`todos/` only** (scoped — never `projects/`), pushes, and pops — safe to run on a dirty `todos/`. Parse the `KEY: value` lines:

- `STATUS: synced` → note `PULLED`/`COMMITTED`/`PUSHED` for Step 7's report (e.g. "Todos: committed + pushed" or "no changes").
- `STATUS: conflict` → a rebase conflict in `todos/`; surface it (resolve under `~/.claude/claude-code-vault/todos/`) and continue with the rest of the backup.
- `STATUS: error` → surface verbatim; continue.

## Step 5.5: Sync registered vault projects

`vault-sync.pl` owns ALL git/file/hash/merge work — your job is to invoke subcommands, parse JSON, and present `AskUserQuestion` for conflicts. Never run `git` against the vault yourself, never `cp`/`mv` files into the vault, never compute hashes yourself.

First check that the vault exists locally:

```bash
[ -d "$HOME/.claude/claude-code-vault/.git" ] && echo "VAULT_OK" || echo "VAULT_MISSING"
```

If `VAULT_MISSING`, skip this step (vault not initialized on this machine — covered by setup in the ccpraxis README).

Otherwise list registered projects on this machine:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/vault-sync.pl" list-projects
```

If `projects` is empty, skip to Step 5.6.

For each entry in `projects` (sequentially — the vault lock serializes them; do NOT parallelize):

### 5.5.a — Sync the project

**Stale-entry check first (fix H7 from red-team):** if the entry's `project_exists` field is `false`, the registered project directory has been moved or deleted. Surface this to the user:

> ⚠ Project `<slug>` is registered but its directory no longer exists at `<path>`. Skipping. Run `perl ${CLAUDE_PLUGIN_ROOT}/scripts/vault-sync.pl unregister --slug <slug>` to remove the stale entry (vault contents will be preserved as orphans).

Then skip to the next project — do NOT call `sync-project` for a missing path.

For entries with `project_exists: true`:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/vault-sync.pl" sync-project --slug "<slug>"
```

Capture the `session_id` field from the response — you'll pass it through `resolve-conflict` and `commit-and-push` (fix H2: prevents a parallel invocation from splicing into this session's journal).

Handle the response:

- `status: drift` — vault has uncommitted changes in `projects/<slug>/` outside any known journal (left over from an unclean exit). Surface `dirty_files` to the user; **skip this project** and continue with the next one. The user can clean up manually at `~/.claude/claude-code-vault/` and re-run `/steward:backup`.
- `status: error` — surface the error; skip this project; continue.
- `status: synced` — continue.

If the response has `skipped_symlinks` or `skipped_bad_paths` non-empty, mention those (informational, not blocking).

### 5.5.b — Conflict resolution loop

If `conflicts` is non-empty, iterate them in order. For each conflict, use `AskUserQuestion`:

**Question:** `"Conflict on '<path>' in project '<slug>' — local and vault both changed since last sync. How to resolve?"`

**Options** (build dynamically based on the conflict entry):

1. **"Use local version"** — overwrite vault with local. Always offered.
2. **"Use vault version"** — overwrite local with vault. Always offered.
3. **"Show diff"** — display merge tmp content, then re-prompt. Offered only when `is_text == true`.
4. **"Use merged"** — accept the auto-merged result. Offered ONLY when `is_text == true` AND `merge_result.exit_code == 0`.
5. **"Abort sync"** — stop processing THIS project (do NOT commit-and-push for this slug); move on to the next project. Always offered last.

**Binary files (`is_text == false`):** offer only options 1, 2, and 5. Add a note in the question text: *"This is a binary file — diff and merged-view are not available."*

**"Show diff":** `bash cat "<merge_result.tmp_path>"` to display the `git merge-file --diff3` result (conflict markers, or clean merged file when `exit_code == 0`). Re-ask the SAME conflict's question afterward.

**"Abort sync":** report **explicitly** that any conflicts the user already resolved in this slug's session will be discarded:

> Aborted sync for project `<slug>`. **The N conflict(s) you already resolved in this session will be discarded** — they'll be re-asked on the next `/steward:backup`. Vault is untouched for this project. Continuing with the next project.

Then continue to the next project. Do NOT call commit-and-push for THIS slug.

**"Use local" / "Use vault" / "Use merged":** pass the same `--session-id` captured from `sync-project`:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/vault-sync.pl" resolve-conflict --slug "<slug>" --path "<path>" --action <use-local|use-vault|use-merged> --session-id "<session_id>" [--merged-file "<merge_result.tmp_path>"]
```

(Pass `--merged-file` only for `use-merged`.)

### 5.5.c — Commit and push

After all conflicts resolved (or if there were none), pass the same `--session-id`:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/vault-sync.pl" commit-and-push --slug "<slug>" --session-id "<session_id>"
```

Handle the response:

- `committed_and_pushed` — success. Note the `last_synced_at`. If `rolled_back_during_sync` present, mention those paths (their source files changed mid-sync; will be picked up next `/steward:backup`).
- `sensitive_blocked` — vault was NOT modified; pre-rename scan caught secrets in staged files. Surface `findings` (file/line/pattern) to the user; tell them to remove the secrets and re-run `/steward:backup`.
- `sensitive_blocked_post_rename` — defense-in-depth scan caught a leak after rename. The script automatically rolls back the rename via `git checkout` and clears the journal, so the vault is restored to its pre-sync state. Surface the `findings` to the user and tell them to fix the source files before re-running `/steward:backup`.
- `error` — surface error; continue with next project.

Collect per-project results (slug, status, conflict count, rolled-back count, sensitive-blocked status) for Step 7's report.

## Step 5.6: Sync beacon vault data

Beacons live at the vault root in `beacons/<uuid>.json` (separate from per-project content). They're written locally by `/beacon:on` (host) and by the statusline-triggered background sync that ingests sandbox beacons. `/steward:backup` commits and pushes them so they survive across machines.

First check the vault exists locally (reuse the same check as Step 5.5):

```bash
[ -d "$HOME/.claude/claude-code-vault/.git" ] && echo "VAULT_OK" || echo "VAULT_MISSING"
```

If `VAULT_MISSING`, skip this step.

Otherwise:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/vault-sync.pl" sync-beacons
```

Parse the JSON `status`:

- `no_op` — no beacons in the vault (empty dir/absent OR nothing to push). Skip silently.
- `synced` — note the result in Step 7's report. The response includes `count` (current beacon records), `committed` (bool — whether a commit was made this run), `pushed` (bool — whether a push happened), `ingested` (sandbox beacons newly copied into the vault), `ingest_skipped` (sandbox beacons already up-to-date). Summarize as e.g. "Synced N beacons (M ingested from sandboxes; committed; pushed)" or "Synced N beacons (no changes)".
- `sensitive_blocked` — surface `findings` (each has `file`, `line`, `pattern`). Vault was NOT modified by this run, but the offending content lives in beacon JSONs. Tell the user to fix them (delete the offending beacon via `/beacon:delete <id-or-prefix>` OR open the JSON directly and remove the secret from the label/summary), then re-run `/steward:backup`. Do not auto-redact — beacon labels are user-supplied and should be edited intentionally.
- `error` — surface the error verbatim; continue with the remaining steps. If the error is "git push failed", reassure the user that the local commit DID succeed and the next `/steward:backup` run will automatically detect the unpushed commit (via `vault_ahead_behind`) and retry the push — no manual git recovery needed.

If the response has `ingest_errors` (sandbox ingestion partial failures), mention them informationally — the main commit/push still proceeded.

## Step 5.7: Offer registration for unregistered current project

```bash
CWD="$(pwd -P)"
perl "${CLAUDE_PLUGIN_ROOT}/scripts/vault-sync.pl" is-registered --cwd "$CWD"
```

If `registered: true`, skip (already handled in Step 5.5).

If `registered: false`, check the opt-out marker:

```bash
[ -f "$CWD/.claude/backup-skip" ] && echo "SKIP_MARKER"
```

If `SKIP_MARKER` is present, skip the offer — but **mention it in the Step 7 report** so the user remembers it's there and can delete it if they want to re-enable the prompt (fix M2 from red-team):

> Skipped registration offer for `<cwd>` — `.claude/backup-skip` marker present. Delete it to re-enable the prompt.

Otherwise check whether the cwd has anything worth tracking:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/vault-sync.pl" detect-trackable --cwd "$CWD"
```

If `trackable` is empty, skip (nothing to back up).

If `trackable` is non-empty, use `AskUserQuestion`:

**Question:** `"This directory has trackable Claude files but isn't registered for vault backup. Found: <list of paths from trackable>. Register now?"`

**Options:**

- **"Yes, register"** — invoke the `/steward:setup-project` skill (use the `Skill` tool with `skill: "steward:setup-project"`, empty args). Do NOT try to register manually — the skill owns the bootstrap flow.
- **"Not now"** — skip this time. Mention they can run `/steward:setup-project` later.
- **"Don't ask again for this directory"** — create the opt-out marker so future `/steward:backup` runs skip the offer:
  ```bash
  mkdir -p "$CWD/.claude" && : > "$CWD/.claude/backup-skip"
  ```
  Tell the user the marker was created (at `<cwd>/.claude/backup-skip`) and that they can delete it to re-enable the offer.

## Step 6: Check for missing plugins

Run the plugin check script:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/check-plugins.pl" \
  --settings "$HOME/.claude/ccpraxis/global-config/settings.json" \
  --installed "$HOME/.claude/plugins/installed_plugins.json" \
  --marketplaces "$HOME/.claude/plugins/known_marketplaces.json"
```

If `status` is `"ok"` or `"no_config"`, skip silently.

If `status` is `"missing_plugins"`:
- For entries in `missing_marketplaces`: inform the user that the marketplace needs to be added first with `/plugin marketplace add <owner>/<repo>`.
- For entries in `missing`: inform the user and offer to install with `/plugin install <name>@<marketplace>`.
- For entries in `extra_installed`: mention informally that these are installed locally but not tracked in the config (no action needed).

## Step 6.6: Claude Code binary snapshots (informational)

List snapshots taken by `/update` (or manually). This is informational only — don't prompt for revert during a regular sync.

```bash
perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl list
```

Capture the `count` and the newest snapshot's `id` + `version` from the JSON for the report in Step 7. If the script fails or returns count=0, just skip — no snapshots is a normal state.

## Step 7: Report

Summarize:

- ccpraxis sync: what was merged, what was committed, whether the push succeeded
- Marketplaces: any added/changed
- Vault projects (Step 5.5): per-slug status (synced / conflicts-resolved / aborted / sensitive-blocked / error); count of files pushed/pulled per project
- Beacons (Step 5.6): one line — "N beacons synced (committed/pushed)" or "no changes" or "skipped (vault missing)" or "sensitive_blocked" with the findings if any
- Current-project registration prompt (Step 5.7): offered? user's choice?
- Plugins: any installed or missing
- Claude Code snapshots: count, plus newest id and version (from Step 6.6). One line. Mention the revert command: `perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl restore --latest`.

## Step R: Snapshot/revert mode

When invoked in revert/snapshot intent (not full sync), do ONLY the steps below.

### R.1 — List available snapshots

```bash
perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl list
```

Parse the JSON. Show the user a numbered table: id, version, captured_at_utc, reason (if present), mark (if present), corrupt flag. Newest first.

If `count` is 0: tell the user no snapshots exist (probably never ran `/update` yet). Exit.

### R.2 — Detect current binary state

```bash
perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl detect
```

Surface the current binary's path, version, and SHA-256. This helps the user see whether they actually need to revert.

### R.3 — Ask what to do

Use AskUserQuestion:

- **"Restore latest snapshot"** — runs `restore --latest`. Recommended if the user is confident any snapshot will work.
- **"Restore a specific snapshot"** — follow-up: ask which id from the table in R.1.
- **"Verify a snapshot's integrity"** — runs `verify --snapshot <id>` against a chosen id.
- **"Cancel"** — exit without changes.

### R.4 — Execute restore (if chosen)

```bash
# Restore latest:
perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl restore --latest

# Or restore a specific id:
perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl restore --snapshot <id>
```

The script automatically takes a pre-restore snapshot before swapping the binary, so the restore is itself reversible.

After the restore completes, verify:

```bash
claude --version
```

If `claude --version` matches the restored version: ✅ tell the user, and mention the pre-restore snapshot id (from the restore JSON) — they can revert the revert if needed.

If `claude --version` fails: surface the error. The pre-restore snapshot id is the user's escape hatch. Do not try further restores automatically — let the user decide.

### R.5 — Execute verify (if chosen)

```bash
perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl verify --snapshot <id>
```

Report the JSON. If exit code is 2 (integrity failure), surface the details — the snapshot is corrupt and cannot safely be restored from. Running `prune --keep N` will auto-remove ALL corrupt entries (corrupt entries are dropped regardless of the keep-N window). To force-remove a single corrupt snapshot without touching others, the user can `rm -rf ~/.claude/backups/claude-code/<id>` manually.
