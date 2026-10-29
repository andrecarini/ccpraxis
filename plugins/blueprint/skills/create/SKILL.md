---
name: create
description: Create a new blueprint — a durable multi-package initiative with per-package ledgers, write sets, and a dependency DAG, ready for unattended execution by the butler plugin. Use whenever the user wants to plan a feature, migration, or refactor that spans more than one work session, or says anything like "create a blueprint", "plan this initiative", or "set this up for the agents to run".
argument-hint: <blueprint-name> [objective]
---

# /blueprint:create

You are the **blueprint author**. First read `${CLAUDE_PLUGIN_ROOT}/skills/authoring-protocol/SKILL.md` — sections *Create* and *Decomposition rules* are binding for this command. You author the blueprint here; you do not execute it (execution is the `butler` plugin's `/butler:dispatch-fleet`, run inside the sandbox).

Steps:

1. `bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-init.sh"` — ensures the self-gitignoring data root exists. Blueprint name: `$0` (kebab-case it); objective from `$1`/conversation.
2. **Interrogate before decomposing.** Collect every architectural fork, ambiguity, and confirm-before-acting surface into ONE batched `AskUserQuestion` pass. The contract with the user: questions up front, then hours of unattended work. **`model`/`effort` are never part of this pass** — see authoring-protocol/SKILL.md's Decomposition rules.
3. Decompose into packages per the protocol's rules. Non-negotiables per package: testable `done_criteria`, exact `write_set` and `test_paths` (colon-separated; trailing `/` = prefix; `*` crosses `/`), `inputs` with file:line, `out_of_scope`; `model: sonnet` + `effort: medium` per package unless a recorded reason says otherwise. Ordering is explicit too, but it goes in the **package-status table's `depends_on` column** — via `add-package --deps` / `set-deps` — and **never into a package ledger's frontmatter**: `bp-ledger.pl` rejects that key on every write including `set-status`, which leaves the coordinator unable to reach any terminal state (reports `20260916-185610-8ee1`, `20260917-063908-db14`).
4. Create `blueprint.md` **through the API — never with `Write`/`Edit`.** `guard-blueprint-write.sh` denies a direct Write to any `blueprint.md` path, *including one that does not exist yet*, and it exempts Bash only so the API's own writer can run. Copying a hand-authored file past it is the hand-splice the guard exists to prevent, through a door the hook cannot see. Every mutation is typed and atomic:

   ```bash
   BP=<data>/blueprints/<name>/blueprint.md
   perl "${CLAUDE_PLUGIN_ROOT}/../butler/scripts/bp-blueprint.pl" init --file "$BP" \
        --template "${CLAUDE_PLUGIN_ROOT}/templates/blueprint.md" --name <kebab-name>
   # prose sections — one call per section, body from a file. Make the file with
   # `mktemp` and write the body into the path it prints; never a fixed /tmp name,
   # which another session authoring at the same moment would overwrite:
   perl "${CLAUDE_PLUGIN_ROOT}/../butler/scripts/bp-blueprint.pl" set-section --file "$BP" \
        --section Objective --text-file <path-from-mktemp>
   # decisions and package rows — typed verbs, validated against the real parser:
   perl "${CLAUDE_PLUGIN_ROOT}/../butler/scripts/bp-blueprint.pl" add-decision --file "$BP" --id 1 --text "..."
   perl "${CLAUDE_PLUGIN_ROOT}/../butler/scripts/bp-blueprint.pl" add-package  --file "$BP" --pkg 01-slug \
        --deliverable "..." --model sonnet --status pending
   ```

   The butler scripts are reached through `${CLAUDE_PLUGIN_ROOT}/../butler/`, the sibling plugin
   in the same ccpraxis tree, never as `plugins/butler/...`: that relative form only resolves when
   the session's cwd happens to be a ccpraxis checkout, and authoring runs in any project.

   `init` refuses to overwrite an existing blueprint, requires a kebab-case name, and strips the template's illustrative rows (left in, `parse_dag` reads `01-<slug>` as a real package). `set-section` refuses the structured sections — `Package status`, `Decisions`, `Harvest log` have their own verbs.

   Package **ledgers** are ordinary files: write `packages/<NN-slug>.md` from `templates/package-ledger.md` with `Write` as normal — only `blueprint.md` is guarded. The ledger **frontmatter** must carry the real values (status, model, max_turns, effort, write_set, test_paths, checks) — that frontmatter is the contract butler's launch scripts and hooks read at execution time. Keep it in sync with the blueprint package block.
5. **Auditor gate.** Dispatch the auditor via Task with `subagent_type: blueprint:bp-auditor`, pointed at the blueprint dir. Its fresh context is the point: you and the user share session context that never made it into the file; an agent reading only the file finds exactly those gaps. Batch its numbered questions into one final `AskUserQuestion` pass, fold the answers into Decisions/packages, set blueprint `status: audited`.
6. Tell the user the blueprint is **authored and audited**, and which packages form wave 1. Execution is a separate, deliberate step: **inside the sandbox**, run `/butler:dispatch-fleet <name>` (butler is sandbox-only — it starts the deterministic orchestrator that spawns the detached coordinators), or `/butler:drive-solo <name>` for a host-safe single interactive session. Launching is never automatic.
