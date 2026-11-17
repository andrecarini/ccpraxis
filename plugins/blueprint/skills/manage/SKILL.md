---
name: manage
description: Manage blueprint lifecycle — list all blueprints with status, view one, re-run the completeness audit, archive a finished blueprint, or delete one. Use whenever the user wants to see, clean up, audit, archive, or remove blueprints.
argument-hint: <list|view|audit|archive|delete> [blueprint]
---

# /blueprint:manage

You are the **blueprint author**. First read `${CLAUDE_PLUGIN_ROOT}/skills/authoring-protocol/SKILL.md` — it is the doctrine source for all blueprint authoring operations. Operation is `$0`, target is `$1`. Data root: `${CCPRAXIS_DATA_DIR:-<project-root>/.ccpraxis-local-data}/blueprints/`.

This plugin is authoring-side and host-usable; it never manages running coordinator **processes** (those are butler's, and live only inside the sandbox). Read state from files, don't probe or kill processes.

Butler's scripts are reached as `${CLAUDE_PLUGIN_ROOT}/../butler/scripts/...` (the sibling plugin in the same ccpraxis tree), never as `plugins/butler/...` relative to the cwd, which only resolves inside a ccpraxis checkout.

## list

**Reconcile first, then read.** Run:

```
perl "${CLAUDE_PLUGIN_ROOT}/../butler/scripts/bp-lifecycle.pl" reconcile --all --archive --json
```

This is not optional bookkeeping — it is what makes the listing true. The ledgers are the only record written by the thing that does the work; `blueprint.md`'s own `status:`, its package-status table, `runs/registry.json` and `runs/.orchestrator` are all derived and have each been observed stale. Reconciling repairs them, and files an all-delivered blueprint into `_archive/`. Since s04-lifecycle-derived, `running`/`done` are never written to `status:` — they are only ever the reconciler's derived `lifecycle` field in its `--json` output. A live run (marker present **and** its pid alive) is left completely untouched.

`--archive` is on here deliberately: the operator should never have to ask for a finished blueprint to be closed out. Report what it moved rather than staying silent about it.

Then, for each blueprint's JSON result, read its `lifecycle` field for the blueprint's own status — not `blueprint.md`'s raw metadata `status:` line, which after s04 can be stale (a blueprint that is genuinely live or done right now can still carry an old authored word on disk, because nothing ever writes `running`/`done` into it). Per-package done/total and anything blocked/parked comes from the ledger-sourced rollup (`BpState`/`bp-status.sh`), not from the table — the table no longer carries a status column (Decision 11). Present a per-blueprint digest: blueprint status (from `lifecycle`), packages done/total, anything blocked/parked. Mention archived ones (under `_archive/`) by name only.

## view <name>
Run `perl "${CLAUDE_PLUGIN_ROOT}/../butler/scripts/bp-lifecycle.pl" reconcile --blueprint <name> --no-archive --dry-run --json` (read-only — no archive side effect for a single-blueprint view) and present its `lifecycle` field, not a raw read of `blueprint.md`'s metadata `status:` line. Also read `blueprints/<name>/blueprint.md` directly to summarize Objective, Decisions count, the Package status table (pkg/deliverable/depends_on/model — it carries no status column), and any open escalations/incidents. Per-package status comes from the same ledger-sourced rollup as `list`. Don't dump the whole file unless asked.

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
   perl "${CLAUDE_PLUGIN_ROOT}/../butler/scripts/bp-lifecycle.pl" reconcile --blueprint <name> --archive
   ```

   It sets `status: archived`, refreshes `last_updated`, clears a stale marker, and moves the directory into `_archive/` — which is invisible to listing and to butler's status/sweep by construction. It is a **move, never a delete**.

   For the deliberately-abandoned case the packages are *not* all delivered, so the reconciler declines. Add `--abandon`, which archives it anyway: the same `status: archived` write and the same move.

   ```
   perl "${CLAUDE_PLUGIN_ROOT}/../butler/scripts/bp-lifecycle.pl" reconcile --blueprint <name> --abandon
   ```

   Never move a blueprint directory by hand. A plain rename of one can fail even when nothing of yours holds it (a background handle on any one of hundreds of files is enough); the script then falls back to copy-then-remove, and a hand `mv` does not.

## delete <name>
Destructive. Show what will be removed (package count, reports, runs), require explicit confirmation, then `rm -rf` the blueprint dir (or its `_archive/` copy). Suggest archive instead when the blueprint reached `done`.
