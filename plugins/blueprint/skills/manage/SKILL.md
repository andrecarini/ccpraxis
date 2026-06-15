---
name: manage
description: Manage blueprint lifecycle — list all blueprints with status, view one, re-run the completeness audit, archive a finished blueprint, or delete one. Use whenever the user wants to see, clean up, audit, archive, or remove blueprints.
argument-hint: <list|view|audit|archive|delete> [blueprint]
---

# /blueprint:manage

You are the **blueprint author**. First read `${CLAUDE_PLUGIN_ROOT}/skills/authoring-protocol/SKILL.md` — it is the doctrine source for all blueprint authoring operations. Operation is `$0`, target is `$1`. Data root: `${CCPRAXIS_DATA_DIR:-<project-root>/.ccpraxis-local-data}/blueprints/`.

This plugin is authoring-side and host-usable; it never manages running coordinator **processes** (those are butler's, and live only inside the sandbox). Read state from files, don't probe or kill processes.

## list
Glob `<data>/blueprints/*/blueprint.md` (skip `_archive/`). For each, read the metadata block `status` and the Package status table; present a per-blueprint digest: blueprint status, packages done/total, anything ⛔ blocked / ⏸ parked. Mention archived ones (under `_archive/`) by name only.

## view <name>
Read `blueprints/<name>/blueprint.md`; summarize Objective, Decisions count, the Package status table, and any open escalations/incidents. Don't dump the whole file unless asked.

## audit <name>
Dispatch the auditor via Task with `subagent_type: blueprint:bp-auditor`, pointed at the blueprint dir. Present its numbered questions to the user in one batched `AskUserQuestion` pass, fold answers into the blueprint, and refresh `last_updated`. Use after substantial revisions or before handing a blueprint to butler.

## archive <name>
Only for blueprints whose work is done or deliberately abandoned:
1. **Check for an active execution first.** If `blueprints/<name>/runs/` exists with a `registry.json` whose packages are non-terminal (status not done/blocked/parked), a butler run may still be live **in the sandbox**. Do NOT try to stop it from here — tell the user to stop it inside the sandbox (`/butler:status <name>`, then let it finish or `touch runs/<pkg>.force-stop`), and confirm before continuing.
2. Set blueprint `status: archived`, refresh `last_updated`, add a one-line closing note under Incidents/Harvest.
3. `mkdir -p <data>/blueprints/_archive && mv <data>/blueprints/<name> <data>/blueprints/_archive/<name>` — `_archive/` is invisible to listing and to butler's status/sweep by construction.

## delete <name>
Destructive. Show what will be removed (package count, reports, runs), require explicit confirmation, then `rm -rf` the blueprint dir (or its `_archive/` copy). Suggest archive instead when the blueprint reached `done`.
