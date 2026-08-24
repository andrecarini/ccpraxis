---
name: status
description: Show the state of one or all blueprints — package statuses, live coordinator processes, ledger ages, attempts, and next actions — and recommend what to do. Use whenever the user asks how a blueprint, its packages, or "the agents" are doing, or wants a progress check.
argument-hint: [blueprint]
---

# /butler:status

First read `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-protocol/SKILL.md` — it is the doctrine source for all butler execution operations. This is a read-only snapshot; it never drives anything.

Run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-status.sh" $0
```

(no argument → all blueprints). The script is the cheap monitoring surface: ledger frontmatter + process liveness + first line of Next action. Do not read stream logs or full ledgers for a status check. It runs on the **host** as well as in the sandbox — jq is optional, and without it only the `PROC`/`ATT` columns degrade to `?`.

It **reconciles before it reports** (`bp-lifecycle.pl reconcile --all --no-archive`): a stale `runs/.orchestrator`, and a `registry.json` left behind by a run that ended any way other than the orchestrator's clean exit are repaired against the ledgers. It does **not** archive — filing a finished blueprint away is not a side effect of asking for status. Report a `blueprint status: done` row as ready to archive and offer `/blueprint:manage archive <name>`.

Known gap, not a regression: `bp-status.sh` itself is out of s04-lifecycle-derived's package write set and still prints `blueprint.md`'s raw stored `status:` word rather than the reconciler's derived `lifecycle` field. Until package `s05-retire-reconciler-drift-paths` updates it, a freshly-all-delivered blueprint keeps showing its pre-existing authored word (`running` or `audited`) here instead of `done`, even though `bp-lifecycle.pl reconcile` (which this script already shells to) now correctly computes `done`/`archived` internally.

**Liveness is the marker's pid, never the marker's existence, and never the registry.** The header line says `[orchestrator pid N LIVE]` or `[stale orchestrator marker pid N]` — trust that. `sandbox-butler-overhaul` carried a marker for eleven days after its container was reaped, and a registry claiming six running coordinators, while every one of its 79 package ledgers said `done`.

Then summarize for the user, and recommend concretely:

- ✅ `done` rows → the deterministic orchestrator harvests + launches dependents itself; just report progress (no manual harvest loop).
- ⛔ `blocked` / ⏸ `parked` → read those ledgers' Escalation sections only, and check `runs/escalations/` for queued decisions; present them, batched. To answer and unblock, point the user to `/butler:reporter $0`.
- A run that should be live but isn't (no `runs/.orchestrator` marker, dead coordinators, non-terminal ledgers) → offer `/butler:dispatch-fleet $0` (sandbox) or `/butler:drive-solo $0` (host/single-session). Both are start-or-continue and recover interrupted work automatically.
- Pending packages whose dependencies are met → same: `dispatch-fleet` / `drive-solo` picks them up; there is no separate launch/resume verb.

Keep your own context lean: the table plus targeted Escalation reads, nothing more.
