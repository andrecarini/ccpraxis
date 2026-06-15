---
name: status
description: Show the state of one or all blueprints — package statuses, live coordinator processes, ledger ages, attempts, and next actions — and recommend what to do. Use whenever the user asks how a blueprint, its packages, or "the agents" are doing, or wants a progress check.
argument-hint: [blueprint]
---

# /butler:status

You are the **orchestrator**. First read `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-protocol/SKILL.md` — it is the doctrine source for all butler orchestration operations.

Run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-status.sh" $0
```

(no argument → all blueprints). The script is the cheap monitoring surface: ledger frontmatter + process liveness + first line of Next action. Do not read stream logs or full ledgers for a status check.

Then summarize for the user, and recommend concretely:

- ✅ `done` rows not yet harvested → offer to harvest (verify outputs on disk per protocol) and launch the next wave.
- ⛔ `blocked` / ⏸ `parked` → read those ledgers' Escalation sections only; present the decisions needed, batched.
- Dead process + non-terminal ledger → offer `/butler:resume`.
- Pending packages whose dependencies are met → offer `/butler:launch`.

Keep your own context lean: the table plus targeted Escalation reads, nothing more.
