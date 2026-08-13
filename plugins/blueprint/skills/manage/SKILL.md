---
name: manage
description: Manage blueprint lifecycle — list all blueprints with status, view one, re-run the completeness audit, archive a finished blueprint, or delete one. Use whenever the user wants to see, clean up, audit, archive, or remove blueprints.
argument-hint: <list|view|audit|archive|delete> [blueprint]
---

# /blueprint:manage

You are the **blueprint author**. First read `${CLAUDE_PLUGIN_ROOT}/skills/authoring-protocol/SKILL.md` — it is the doctrine source for all blueprint authoring operations. Operation is `$0`, target is `$1`. Data root: `${CCPRAXIS_DATA_DIR:-<project-root>/.ccpraxis-local-data}/blueprints/`.

This plugin is authoring-side and host-usable; it never manages running coordinator **processes** (those are butler's, and live only inside the sandbox). Read state from files, don't probe or kill processes.

## list

**Reconcile first, then read.** Run:

```
perl plugins/butler/scripts/bp-lifecycle.pl reconcile --all --archive
```

This is not optional bookkeeping — it is what makes the listing true. The ledgers are the only record written by the thing that does the work; `blueprint.md`'s own `status:`, its package-status table, `runs/registry.json` and `runs/.orchestrator` are all derived and have each been observed stale. Reconciling repairs them, advances a blueprint whose packages are all delivered to `done`, and files it into `_archive/`. A live run (marker present **and** its pid alive) is left completely untouched.

`--archive` is on here deliberately: the operator should never have to ask for a finished blueprint to be closed out. Report what it moved rather than staying silent about it.

Then glob `<data>/blueprints/*/blueprint.md` (skip `_archive/`). For each, read the metadata block `status`; per-package done/total and anything blocked/parked comes from the ledger-sourced rollup (`BpState`/`bp-status.sh`), not from the table — the table no longer carries a status column (Decision 11). Present a per-blueprint digest: blueprint status, packages done/total, anything blocked/parked. Mention archived ones (under `_archive/`) by name only.

## view <name>
Read `blueprints/<name>/blueprint.md`; summarize Objective, Decisions count, the Package status table (pkg/deliverable/depends_on/model — it carries no status column), and any open escalations/incidents. Per-package status comes from the same ledger-sourced rollup as `list`. Don't dump the whole file unless asked.

## audit <name>
Dispatch the auditor via Task with `subagent_type: blueprint:bp-auditor`, pointed at the blueprint dir. Present its numbered questions to the user in one batched `AskUserQuestion` pass, fold answers into the blueprint, and refresh `last_updated`. Use after substantial revisions or before handing a blueprint to butler.

## archive <name>

For a blueprint whose packages are **all delivered**, this is automatic and needs no verb — `list`, `/butler:status` and the drive loop all reconcile, and the reconciler files it. Use this section for the deliberately-abandoned case, or when the operator asks explicitly.

1. **Establish whether a run is actually live — from the PID, never from the registry.**

   A live run is `runs/.orchestrator` present **AND** the pid inside it alive. Nothing else is evidence.

   > This step used to say "if `registry.json` has non-terminal packages, a run may still be live". **That is wrong and it actively misleads.** `registry.json` is orchestrator scratch that nothing reconciles when a run ends any way other than the orchestrator's own clean exit. `sandbox-butler-overhaul` was archived with a registry claiming six `running` coordinators that had been dead for eleven days, while all 79 of its package ledgers said `done`. Read the pid; ignore the registry.

   If a run *is* live, do not stop it from here — that is butler's, inside the sandbox. Tell the operator, and confirm before continuing.

2. Add a one-line closing note under Incidents (via `bp-blueprint.pl set-section`, never `Edit`).

3. Let the reconciler do the move:

   ```
   perl plugins/butler/scripts/bp-lifecycle.pl reconcile --blueprint <name> --archive
   ```

   It sets `status: archived`, refreshes `last_updated`, clears a stale marker, and moves the directory into `_archive/` — which is invisible to listing and to butler's status/sweep by construction. It is a **move, never a delete**.

   For the deliberately-abandoned case the packages are *not* all delivered, so the reconciler will decline. Set `status: archived` yourself with `bp-blueprint.pl set-meta --field status --value archived`, then `mv` the directory into `_archive/`.

   > On Windows, `mv` of a blueprint directory can fail with **`Device or resource busy`** even when nothing of yours holds it — a background handle (search indexer, AV) on any one of hundreds of files is enough. A native move of the same directory succeeds. If `mv` fails, use PowerShell `Move-Item`; `bp-lifecycle.pl` already falls back to a copy-then-remove for exactly this.

## delete <name>
Destructive. Show what will be removed (package count, reports, runs), require explicit confirmation, then `rm -rf` the blueprint dir (or its `_archive/` copy). Suggest archive instead when the blueprint reached `done`.
