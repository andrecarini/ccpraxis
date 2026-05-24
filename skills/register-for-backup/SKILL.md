---
name: register-for-backup
description: Bootstraps the current project for vault backup — detects trackable Claude files, proposes a slug, runs initial sync. If the vault has unlinked projects from another machine, surfaces them as restore candidates. Use when the user wants to start backing up a project's Claude files, set up vault tracking, or says "register for backup", "back up this project", "link to vault", "restore from vault".
user-invocable: true
host-only: true
allowed-tools: Bash, AskUserQuestion
related:
  - backup
---

# Register a project for vault backup

Bootstraps the current working directory for sync with the personal `claude-code-vault` repo. All git/file operations go through `~/.claude/ccpraxis/scripts/vault-sync.pl` (which owns locking, atomicity, journaling, 3-way merge, and sensitive-check). Your job is to call subcommands, parse their JSON, and present `AskUserQuestion` for choices.

**No skip option on conflicts — they must be resolved or the whole sync aborts.** No commits or file moves outside the script.

## Step 0 — Verify the vault exists

```bash
[ -d "$HOME/.claude/claude-code-vault/.git" ] && echo "VAULT_OK" || echo "VAULT_MISSING"
```

If `VAULT_MISSING`, tell the user:

> The `claude-code-vault` repo isn't initialized at `~/.claude/claude-code-vault/`. Set it up via `/backup` first (which will prompt for the vault repo URL).

…and stop.

## Step 1 — Identify the project

```bash
PROJECT_CWD="$(pwd -P)"
```

This is the directory being registered. All later script calls take `--cwd "$PROJECT_CWD"`.

## Step 2 — Check if already registered

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl is-registered --cwd "$PROJECT_CWD"
```

If JSON contains `"registered": true`, report:

> This project is already registered as `<slug>`. Run `/backup` to sync.

…and stop.

## Step 3 — Surface orphan slugs (potential restores from another machine)

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl list-orphans
```

If the `orphans` array is empty, skip to Step 5 (fresh registration).

Otherwise, present orphans via `AskUserQuestion`. Build one option per orphan with:
- Label: the slug
- Description: format as `"created <created_at>, last from <source_notes[0].basename> on <source_notes[0].machine>, <file_count> files, <total_size_kb> KB"` (round bytes to KB).

Add one final option: **"Create new registration"** with description "Fresh registration — this project isn't a restore of an existing vault slug."

The "Other" option is provided automatically by `AskUserQuestion` (do not add it yourself).

If the user picks an orphan label → Step 4 (link mode).
If they pick "Create new registration" → Step 5 (fresh mode).

## Step 4 — Link mode (restore)

### 4a. Link the project

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl register --link --cwd "$PROJECT_CWD" --slug "<picked-slug>"
```

On `"status": "error"` → surface and stop. On `"status": "registered_link"` → continue.

### 4b. Preview what will be pulled — REQUIRED before first sync

The first sync will write every vault file into the project directory. If the user picked the wrong orphan, this destroys local files silently. **Always preview before syncing.**

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl vault-files --slug "<picked-slug>"
```

Present the returned list to the user (paths + sizes, formatted as KB if > 1024). Note any existing local files at the same paths — those will become conflicts in Step 6 (the user gets to choose Use local / Use vault per file). Files only in vault auto-write to the project on first sync — call those out explicitly so the user understands what appears on disk.

**`AskUserQuestion`:**

> "About to pull `<N>` files (`<size>` total) from vault `<slug>` into `<PROJECT_CWD>`. Files that already exist locally at the same paths will be conflict-prompted; files only in vault will appear on disk automatically. Proceed?"

Options:

- **"Proceed"** → continue to Step 6.
- **"Cancel — unregister"** → roll back the link and stop:
  ```bash
  perl ~/.claude/ccpraxis/scripts/vault-sync.pl unregister --slug "<picked-slug>"
  ```
  Report that the link was undone, vault contents preserved (the slug is back to being an orphan), and the project metadata + cache + registry entry have been removed locally.

## Step 5 — Fresh registration

### 5a. Detect trackable files

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl detect-trackable --cwd "$PROJECT_CWD"
```

If `trackable` is empty, report:

> No trackable Claude files found in this directory. (Looking for: `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/{skills,agents,hooks,commands,plans}/`, `.claude-plans/`, `.claude-data/{memory,plans}/`.) Create some first, or `cd` into the right directory and re-run.

…and stop.

### 5b. Confirm file selection

Present each trackable entry via `AskUserQuestion` with `multiSelect: true`. Question: *"Which files should the vault track for this project?"*. Build one option per entry with:
- Label: the `path`
- Description: `"<type>, <size> bytes"` (or KB if > 1024)

All options pre-selected by default (user can deselect any). If the user deselects everything, report:

> No files selected — registration aborted.

…and stop.

### 5c. Propose slugs

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl propose-slugs --cwd "$PROJECT_CWD"
```

Use the returned `candidates` array as `AskUserQuestion` options. Each option label is the candidate slug; descriptions can briefly explain ("matches directory name", "with random suffix", etc.). The user picks one or uses **Other** to type a custom slug.

### 5d. Register

Comma-join the selected paths from 5b into `<files>`:

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl register --fresh --cwd "$PROJECT_CWD" --slug "<picked-slug>" --files "<files>"
```

On `"status": "registered_fresh"` → proceed to Step 6.

On `"status": "error"` with a slug-collision message → tell the user the slug is taken in the vault and suggest re-running and picking a different slug. Stop.

## Step 6 — Initial sync

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl sync-project --slug "<slug>"
```

Parse the JSON.

- `"status": "drift"` → vault has uncommitted changes outside the journal. Surface `dirty_files` to the user; tell them to inspect `~/.claude/claude-code-vault/`. Stop.
- `"status": "synced"` → continue.
- `"status": "error"` → surface and stop.

Capture `skipped_symlinks` and `skipped_bad_paths` from the response — if either is non-empty, mention to the user (informational, not blocking).

If `conflicts` is empty, jump straight to Step 8.

## Step 7 — Conflict resolution loop

For each entry in `conflicts`, ask via `AskUserQuestion`:

**Question:** `"Conflict on '<path>': local and vault both changed since last sync. How to resolve?"`

**Options** (build the list dynamically based on the conflict entry):

1. **"Use local version"** — overwrite vault with local. Always offered.
2. **"Use vault version"** — overwrite local with vault. Always offered.
3. **"Show diff"** — display the merge tmp content for inspection, then re-prompt. Offered only when `is_text == true`.
4. **"Use merged"** — accept the auto-merged result. Offered ONLY when `is_text == true` AND `merge_result.exit_code == 0`.
5. **"Abort sync"** — discard partial work; do NOT commit. Always offered last.

**Binary files (`is_text == false`):** offer only options 1, 2, and 5. Add a note to the question text: *"This is a binary file — diff and merged-view are not available."*

**"Show diff":** `bash cat "<merge_result.tmp_path>"` — output is the `git merge-file --diff3` view with conflict markers (or clean merged content when `exit_code == 0`). After displaying, re-ask the SAME question. Do NOT advance to the next conflict.

**"Abort sync":** report **explicitly** that any conflicts the user already resolved in THIS session will be discarded:

> Sync aborted. **The N conflict(s) you already resolved in this session will be discarded** — they'll be re-asked on the next sync. No changes committed to vault. Re-run `/register-for-backup` or `/backup` when ready.

…then stop. Do not call commit-and-push.

**"Use local" / "Use vault" / "Use merged":** pass `--session-id` from the original `sync-project` response so a second invocation can't splice into this session's journal:

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl resolve-conflict --slug "<slug>" --path "<path>" --action <use-local|use-vault|use-merged> --session-id "<session_id>" [--merged-file <merge_result.tmp_path>]
```

(Pass `--merged-file` only for `use-merged`.)

After all conflicts resolved, proceed to Step 8.

## Step 8 — Commit and push

Pass the same `--session-id` from `sync-project` so the finalize call validates against the journal:

```bash
perl ~/.claude/ccpraxis/scripts/vault-sync.pl commit-and-push --slug "<slug>" --session-id "<session_id from sync-project>"
```

- `"status": "committed_and_pushed"` → success. Report:

  > Registered `<slug>` and synced. Last synced at `<last_synced_at>`. Use `/backup` for future syncs.

  If the response includes `rolled_back_during_sync` (files whose source changed mid-sync), mention those paths and suggest re-running `/backup` to pick them up.

- `"status": "sensitive_blocked"` → surface `findings` (file/line/pattern) to the user. Tell them: vault was NOT modified; resolve the leaks in the source files and re-run `/backup`.

- `"status": "sensitive_blocked_post_rename"` → surface `findings`. Tell the user: vault files were updated locally but NOT pushed. They need to either `git restore` the vault file (at `~/.claude/claude-code-vault/projects/<slug>/files/<path>`) or fix the source and re-run sync.

- `"status": "error"` → surface and stop.

## Important

- All git ops, file moves, hashes, and merges happen inside `vault-sync.pl`. **Never** run `git` against the vault yourself, never `cp`/`mv`/`Write` into the vault, never compute hashes yourself.
- Conflicts MUST be resolved before commit. No "skip" option, no "remember" option — only **Use local / Use vault / Show diff / Use merged / Abort sync**.
- The project gets two auto-created files: `.claude/backup-metadata.json` (slug + last-synced hashes) and `.claude/backup-cache/` (mirror of last-synced content, used as 3-way merge base). Both are auto-added to the project's `.gitignore` by registration. Do not touch them manually.
- `/register-for-backup` is one-shot per project. After it succeeds, the project syncs through `/backup` going forward.
