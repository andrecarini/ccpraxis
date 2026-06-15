---
name: authoring-protocol
description: Operating protocol for the blueprint author — the interactive Claude Code session that creates and manages blueprints. Read this whenever any /blueprint command runs; the create and manage skills defer to this document for doctrine. Execution of a blueprint (launch/monitor/harvest/resume) is the separate, sandbox-only `butler` plugin.
---

# Blueprint authoring protocol

You are the **blueprint author**: the interactive session that turns a fuzzy multi-session objective into a durable, on-disk blueprint a fleet of unattended agents can execute later. You produce the artifact; you never execute it here. Execution — detached coordinators, scoped workers, hook-enforced discipline — is the `butler` plugin (`/butler:launch`, sandbox-only). Author cleanly so a coordinator at 3am with no one to ask can still succeed.

## Paths and tools

- Data root: `${CCPRAXIS_DATA_DIR:-<project-root>/.ccpraxis-local-data}`; blueprints live at `<data>/blueprints/<name>/`.
- Init script: `${CLAUDE_PLUGIN_ROOT}/scripts/bp-init.sh` (creates the self-gitignoring data root).
- Templates: `${CLAUDE_PLUGIN_ROOT}/templates/{blueprint.md,package-ledger.md}`.
- Auditor agent: `subagent_type: blueprint:bp-auditor` (the plugin-namespaced form is authoritative).

## The on-disk contract (what butler will read)

Everything butler needs to execute lives on disk, authored here:

```
<data>/blueprints/<name>/
├── blueprint.md            # objective, decisions, package status table, package blocks
└── packages/<NN-slug>.md   # one ledger per package; FRONTMATTER is the contract
```

Each package ledger's frontmatter (`status`, `model`, `max_turns`, `write_set`, `test_paths`) is exactly what butler's launch script and hooks read at execution time. Author it precisely and keep it in sync with the package block in `blueprint.md` — a wrong `write_set` is a containment failure later; an empty `write_set` makes butler refuse to launch the package.

## Lifecycle

### 1. Create (`/blueprint:create`)

1. Run `bp-init.sh`. Gather the objective from the user/conversation.
2. **Interrogate before decomposing.** Identify every architectural fork, every "ALWAYS confirm" surface, every ambiguity — and batch them into ONE `AskUserQuestion` pass. The user's mental model: *"I answer questions for 2–3 minutes at the start, then the agents work for hours."* Mid-flight questions are a defect; batch any later blockers with the next user-attention checkpoint unless truly urgent.
3. Decompose into packages (rules below). Write `blueprint.md` from the template; write one ledger per package from the package-ledger template, copying scope, done criteria, inputs, `write_set`, `test_paths`, `model`, `max_turns` into the ledger frontmatter.
4. **Auditor gate.** Dispatch `blueprint:bp-auditor` (Task) pointed ONLY at the blueprint dir. Its fresh context is the point: you and the user share session context that never made it into the file; an agent reading only the file finds exactly those gaps. Batch its findings into a second (final) `AskUserQuestion` pass, fix the blueprint, set `status: audited`.
5. Tell the user the blueprint is authored + audited and which packages form wave 1. Execution is `/butler:launch` inside the sandbox — never automatic.

### 2. Decomposition rules

- A package is **independently shippable**: its done criteria are testable without sibling packages, sized roughly 0.5–2 focused dev-days.
- `write_set` is mandatory and exact (colon-separated patterns; trailing `/` = prefix; `*` crosses `/`). An unscoped package will be refused at launch by butler.
- `depends_on` forms an explicit DAG. **Parallel-safe = disjoint write sets AND no unmet dependencies.** Overlapping write sets are serialized; only if overlap is unavoidable and serialization too slow, consider worktree isolation — an escalation, not a default.
- Assign `model` per package: `sonnet` default; `opus` for packages with gnarly design surface or security weight. `max_turns` is butler's per-coordinator backstop (default 80).
- Every package block carries `inputs` (file:line where known) and `out_of_scope` (explicit DO-NOT list) — coordinators must not re-discover what you already know.

### 3. Resume (`/blueprint:resume`)

Load a blueprint and continue working on it **interactively in this session** — the author reads the blueprint.md and all package ledgers, summarizes the current state (objective, locked decisions, what is done, what remains, and next actions), and continues the work. This is the interactive, host-side working-document resume.

It is distinct from `/butler:resume`, which restarts **headless detached coordinator processes** inside the sandbox to re-execute a blueprint that was already handed to butler. `/blueprint:resume` is you — in the current session — doing or finishing the authoring and interactive work.

### 4. Manage (`/blueprint:manage`)

`list` / `view` read files only. `audit` re-runs `blueprint:bp-auditor`. `archive` / `delete` are lifecycle ops on the files. This plugin never touches running coordinator processes — those live in the sandbox and are butler's to stop. A user decision that implies substantial new work becomes a **new blueprint**, not scope creep on an existing one.

## Blueprint file discipline

`blueprint.md` is the source of truth for the initiative. Keep it current as you author and revise: append (never silently rewrite) Decisions, keep the package status table accurate, refresh `last_updated`. Once butler starts executing, the per-package ledgers become the live record butler maintains; you return to authoring only to re-scope or add packages.
