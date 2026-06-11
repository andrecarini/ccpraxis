---
name: setup
description: Onboard the current project to the ccpraxis blueprint system — create the local data dir + self-gitignore, migrate any legacy .claude-plans into blueprints, and (with you present) register the project for vault backup so its blueprints sync across machines. Manual and idempotent; re-runnable any time. Use when starting to use blueprints or backup in a project, or when the user says "set up this project", "onboard this project", "steward setup", or "migrate my plans here".
argument-hint: (none)
allowed-tools: Bash, Read, AskUserQuestion, Skill
---

# /steward:setup

Manually onboard the **current project** to the ccpraxis system. All file/dir work is done by a deterministic script — your job is to run it, report, and (only for vault registration) confirm. Idempotent: safe to re-run.

Determine the **project root**: `git rev-parse --show-toplevel` (fallback: cwd; confirm with the user if ambiguous after prior `cd`s).

## 1. Run the deterministic onboarder
```
perl "${CLAUDE_PLUGIN_ROOT}/scripts/onboard.pl" "<root>"
```
It (idempotently, locally — no vault writes): creates `<root>/.ccpraxis-local-data/blueprints/` + self-gitignore, migrates any legacy `.claude-plans/*.md` into blueprints (archive-style, originals removed), and — if the project is already vault-registered — ensures `.ccpraxis-local-data/blueprints` is in its `tracked_paths`.

Parse the JSON summary and tell the user concisely: data dir created vs existing, how many plans were migrated (`migration.wrote`/`deleted`), and the registration status.

## 2. Vault registration (host only; needs you present)
Skip this step inside a sandbox (the vault is host-side) — say so and stop.

- If `registered: true` in the summary → blueprints are now tracked; report done.
- If `registered: false` → the project's blueprints are **local-only, not backed up**. First check the opt-out marker:
  ```
  [ -f "<root>/.claude/backup-skip" ] && echo SKIP
  ```
  If `SKIP`, mention the marker (and that deleting it re-enables the offer) and stop.
  Otherwise ask the user (registration commits + pushes this project's Claude files to your private vault):
  - **"Register for backup"** → invoke the `register-for-backup` skill via the Skill tool (empty args). It owns slug selection, file detection (incl. `.ccpraxis-local-data/blueprints` via the default trackables), orphan-linking, and the vault push. Don't register by hand.
  - **"Not now"** → note they can re-run `/steward:setup` later, or drop a `.claude/backup-skip` marker to stop being asked.

## Notes
- This is the **manual** onboarding command — there is intentionally no auto-trigger. Run it per project when you want to start using blueprints/backup there.
- Deterministic + idempotent: `onboard.pl` and the scripts it calls (`bp-migrate-plans`, `vault-sync ensure-tracked`) are all safe to re-run; re-invoking `/steward:setup` won't duplicate or clobber anything.
