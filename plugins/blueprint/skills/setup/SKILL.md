---
name: setup
description: Onboard the current project to the blueprint system, deterministically — create the local data dir, migrate any legacy .claude-plans into blueprints, and offer vault-backup tracking. Use when starting to use blueprints in a project, or when the user says "set up blueprints here", "onboard this project to blueprints", "migrate my plans", or "blueprint setup".
argument-hint: (none)
allowed-tools: Bash, Read, AskUserQuestion, Skill
---

# /blueprint:setup

Deterministically prepare the current project to use blueprints. **All file/directory work is done by scripts** — your job is to run them, show the user the plan, and confirm before any destructive step. Don't hand-create dirs, hand-migrate files, or hand-edit `.gitignore`; the scripts own that (so it's consistent every time).

Determine the **project root**: `git rev-parse --show-toplevel` (fallback: cwd; if ambiguous because of prior `cd`s, confirm with the user).

## 1. Create the local data root
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-init.sh"
```
Creates `<root>/.ccpraxis-local-data/blueprints/` with a self-gitignore (`*`) so blueprint state never lands in the project's git. Idempotent — safe to re-run.

## 2. Migrate legacy plans (if any)
Dry run first — it writes nothing:
```
perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-migrate-plans.pl" "<root>"
```
- If it prints "nothing to migrate", skip to step 3.
- Otherwise present the active/archived breakdown to the user. The script is deterministic: recursive discovery (handles `archive/`, `archived/`, loose files, any nesting uniformly), `active` = a top-level plan still carrying incomplete-deliverable markers (→ `blueprints/<slug>/`, visible), everything else `archived` (→ `blueprints/_archive/<slug>/`); archive-style (full content preserved, no package re-decomposition); idempotent and slug-collision-safe.
- On confirmation, apply and remove the originals:
  ```
  perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-migrate-plans.pl" "<root>" --apply --delete
  ```
  Drop `--delete` if the user wants the originals kept as a backup. The script verifies each blueprint exists on disk before deleting its source, and prunes the emptied `.claude-plans` dirs.

## 3. Offer vault-backup tracking (host only)
Skip this step inside a sandbox (the vault is host-side). On the host:
```
perl "$HOME/.claude/ccpraxis/scripts/vault-sync.pl" is-registered --cwd "<root>"
```
- `registered: true` → note it; done.
- `registered: false` → the project's blueprints (and other Claude files) aren't backed up yet. Offer to register: invoke the `register-for-backup` skill via the Skill tool (empty args) — it owns the bootstrap flow (slug pick, trackable detection incl. `.ccpraxis-local-data/blueprints`, initial sync). Don't register by hand.

## Notes
- Host-usable. The `.ccpraxis-local-data/blueprints` tree this produces is what the sandbox-only `butler` plugin executes; authoring and setup happen here.
- The whole flow is re-runnable: `bp-init` and `bp-migrate-plans` are idempotent, so `/blueprint:setup` can be invoked again any time without duplicating or clobbering.
