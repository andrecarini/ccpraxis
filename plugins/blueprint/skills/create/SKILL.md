---
name: create
description: Create a new blueprint — a durable multi-package initiative with per-package ledgers, write sets, and a dependency DAG, ready for unattended execution by the butler plugin. Use whenever the user wants to plan a feature, migration, or refactor that spans more than one work session, or says anything like "create a blueprint", "plan this initiative", or "set this up for the agents to run".
argument-hint: <blueprint-name> [objective]
---

# /blueprint:create

You are the **blueprint author**. First read `${CLAUDE_PLUGIN_ROOT}/skills/authoring-protocol/SKILL.md` — sections *Create* and *Decomposition rules* are binding for this command. You author the blueprint here; you do not execute it (execution is the `butler` plugin's `/butler:launch`, run inside the sandbox).

Steps:

1. `bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-init.sh"` — ensures the self-gitignoring data root exists. Blueprint name: `$0` (kebab-case it); objective from `$1`/conversation.
2. **Interrogate before decomposing.** Collect every architectural fork, ambiguity, and confirm-before-acting surface into ONE batched `AskUserQuestion` pass. The contract with the user: questions up front, then hours of unattended work.
3. Decompose into packages per the protocol's rules. Non-negotiables per package: testable `done_criteria`, exact `write_set` and `test_paths` (colon-separated; trailing `/` = prefix; `*` crosses `/`), explicit `depends_on`, `inputs` with file:line, `out_of_scope`.
4. Write `<data>/blueprints/<name>/blueprint.md` from `${CLAUDE_PLUGIN_ROOT}/templates/blueprint.md`, and one ledger per package at `packages/<NN-slug>.md` from `templates/package-ledger.md`. The ledger **frontmatter** must carry the real values (status, model, max_turns, write_set, test_paths) — that frontmatter is the contract butler's launch scripts and hooks read at execution time. Keep it in sync with the blueprint package block.
5. **Auditor gate.** Dispatch the auditor via Task with `subagent_type: blueprint:bp-auditor`, pointed at the blueprint dir. Its fresh context is the point: you and the user share session context that never made it into the file; an agent reading only the file finds exactly those gaps. Batch its numbered questions into one final `AskUserQuestion` pass, fold the answers into Decisions/packages, set blueprint `status: audited`.
6. Tell the user the blueprint is **authored and audited**, and which packages form wave 1. Execution is a separate, deliberate step: **inside the sandbox**, run `/butler:launch <name>` (butler is sandbox-only — it spawns the detached coordinators). Launching is never automatic.
