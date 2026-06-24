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

(no argument → all blueprints). The script is the cheap monitoring surface: ledger frontmatter + process liveness + first line of Next action. Do not read stream logs or full ledgers for a status check.

Then summarize for the user, and recommend concretely:

- ✅ `done` rows → the deterministic orchestrator harvests + launches dependents itself; just report progress (no manual harvest loop).
- ⛔ `blocked` / ⏸ `parked` → read those ledgers' Escalation sections only, and check `runs/needs-you/` for queued decisions; present them, batched. To answer and unblock, point the user to `/butler:reporter $0`.
- A run that should be live but isn't (no `runs/.orchestrator` marker, dead coordinators, non-terminal ledgers) → offer `/butler:dispatch-fleet $0` (sandbox) or `/butler:drive-solo $0` (host/single-session). Both are start-or-continue and recover interrupted work automatically.
- Pending packages whose dependencies are met → same: `dispatch-fleet` / `drive-solo` picks them up; there is no separate launch/resume verb.

Keep your own context lean: the table plus targeted Escalation reads, nothing more.
