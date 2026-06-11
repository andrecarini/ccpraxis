---
name: setup
description: Onboard the current project to the ccpraxis system — create the local data dir + self-gitignore, migrate any legacy .claude-plans into blueprints, and register the project for vault backup (detect trackables, pick a slug, initial sync; or link/restore an existing vault slug from another machine). Manual, idempotent, host-side. Use when starting to use blueprints or backup in a project, or when the user says "set up this project", "onboard this project", "steward setup", "register for backup", "back up this project", "link to vault", "restore from vault", or "migrate my plans here".
argument-hint: (none)
allowed-tools: Bash, Read, AskUserQuestion
---

# /steward:setup

Manually onboard the **current project** to the ccpraxis system: local blueprint setup **and** vault-backup registration, end to end. Deterministic file/dir work is done by scripts; vault git/merge work goes through `vault-sync.pl`. Your job is to run them, parse JSON, and present `AskUserQuestion` for choices. Idempotent — safe to re-run.

Determine the **project root** / `PROJECT_CWD`: `git rev-parse --show-toplevel` (fallback: `pwd -P`; confirm with the user if ambiguous after prior `cd`s). All `vault-sync.pl` calls take `--cwd "$PROJECT_CWD"`.

## 1. Local setup (data dir, gitignore, plan migration)
```
perl "${CLAUDE_PLUGIN_ROOT}/scripts/onboard.pl" "$PROJECT_CWD"
```
Idempotent, local-only: creates `.ccpraxis-local-data/blueprints/` + self-gitignore, migrates any legacy `.claude-plans/*.md` into blueprints (archive-style, originals removed), and — **if already registered** — ensures `.ccpraxis-local-data/blueprints` is tracked. Parse the JSON; tell the user: data dir created/existing, plans migrated (`migration.wrote`/`deleted`), and `registered`.

- If `registered: true` → blueprints are now tracked; tell the user to run `/backup` to sync. **Done.**
- If `registered: false` → continue to registration (steps 2+).

## 2. Registration — preconditions (host only)
Skip everything below inside a sandbox (the vault is host-side) — say so and stop.

Vault must exist:
```bash
[ -d "$HOME/.claude/claude-code-vault/.git" ] && echo VAULT_OK || echo VAULT_MISSING
```
If `VAULT_MISSING` → tell the user the vault isn't initialized; run `/backup` first (it prompts for the vault repo URL). Stop.

Honor the opt-out marker:
```bash
[ -f "$PROJECT_CWD/.claude/backup-skip" ] && echo SKIP
```
If `SKIP` → mention the marker (delete it to re-enable) and stop without registering.

## 3. Restore vs fresh (orphan discovery)
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" list-orphans
```
If `orphans` is non-empty, present them via `AskUserQuestion` (one option per orphan — label = slug; description = `"created <created_at>, last from <source_notes[0].basename> on <source_notes[0].machine>, <file_count> files, <KB> KB"`), plus a final **"Create new registration"** option.
- Orphan picked → **link mode** (3a).
- "Create new registration" / no orphans → **fresh mode** (3b).

### 3a. Link mode (restore from another machine)
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" register --link --cwd "$PROJECT_CWD" --slug "<slug>"
```
On `error` → surface, stop. On `registered_link` → **preview before first sync** (it writes vault files into the project, overwriting on conflict):
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" vault-files --slug "<slug>"
```
Show paths+sizes; note that files only in vault auto-appear and same-path local files become conflicts. `AskUserQuestion`: **Proceed** → step 4; **Cancel — unregister** → `vault-sync.pl unregister --slug "<slug>"`, report rollback, stop.

### 3b. Fresh mode
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" detect-trackable --cwd "$PROJECT_CWD"
```
If `trackable` empty → report none found, stop. Else present each via `AskUserQuestion` `multiSelect: true` (label = `path`, description = `"<type>, <size>"`), all pre-selected. If user deselects all → abort. Then propose slugs:
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" propose-slugs --cwd "$PROJECT_CWD"
```
Offer `candidates` via `AskUserQuestion` (Other = custom slug). Register (comma-join selected paths):
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" register --fresh --cwd "$PROJECT_CWD" --slug "<slug>" --files "<files>"
```
On slug-collision `error` → tell user the slug is taken, re-run with a different one. On `registered_fresh` → step 4.

## 4. Initial sync
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" sync-project --slug "<slug>"
```
Capture `session_id`. `drift`/`error` → surface, stop. `synced` → if `conflicts` empty, go to step 5; else resolve each (step 4a). Mention non-empty `skipped_symlinks`/`skipped_bad_paths`.

### 4a. Conflict loop
Per conflict, `AskUserQuestion`: **Use local** / **Use vault** (always); **Show diff** + **Use merged** (only if `is_text` / `merge_result.exit_code==0`); **Abort sync** (last; discards this session's resolutions, no commit). Binary files: offer only Use local / Use vault / Abort.
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" resolve-conflict --slug "<slug>" --path "<path>" --action <use-local|use-vault|use-merged> --session-id "<session_id>" [--merged-file "<tmp_path>"]
```

## 5. Commit + push
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" commit-and-push --slug "<slug>" --session-id "<session_id>"
```
- `committed_and_pushed` → "Registered `<slug>` and synced." Mention any `rolled_back_during_sync`. Future syncs go through `/backup`.
- `sensitive_blocked` / `sensitive_blocked_post_rename` → surface `findings`; tell the user to fix the source and re-run. Vault not pushed.
- `error` → surface, stop.

## Important
- This is the **manual** onboarding+registration command — no auto-trigger. `/backup` invokes it for an unregistered cwd; otherwise run it yourself per project.
- **All** vault git/file/hash/merge work goes through `vault-sync.pl` — never run `git` against the vault, never `cp`/`mv`/`Write` into it, never compute hashes yourself.
- `onboard.pl`, `bp-migrate-plans`, and the `vault-sync` subcommands are all idempotent — re-invoking `/steward:setup` won't duplicate or clobber anything.
