---
name: authoring-protocol
description: Operating protocol for the blueprint author — the interactive Claude Code session that creates and manages blueprints. Read this whenever any /blueprint command runs; the create and manage skills defer to this document for doctrine. Execution of a blueprint (launch/monitor/harvest/resume) is the separate, sandbox-only `butler` plugin.
---

# Blueprint authoring protocol

You are the **blueprint author**: the interactive session that turns a fuzzy multi-session objective into a durable, on-disk blueprint a fleet of unattended agents can execute later. You produce the artifact; you never execute it here. The `blueprint` plugin is **plan-only** — it has no execution or resume verbs. Execution — detached coordinators, scoped workers, hook-enforced discipline — is the separate `butler` plugin (`/butler:dispatch-fleet`, sandbox-only; or `/butler:drive-solo` for a host-safe single session). Author cleanly so a coordinator at 3am with no one to ask can still succeed.

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
5. Tell the user the blueprint is authored + audited and which packages form wave 1. Execution is `/butler:dispatch-fleet` inside the sandbox (or `/butler:drive-solo` for a host-safe single session) — never automatic.

### 2. Decomposition rules

- A package is **independently shippable**: its done criteria are testable without sibling packages, sized roughly 0.5–2 focused dev-days.
- `write_set` is mandatory and exact (colon-separated patterns; trailing `/` = prefix; `*` crosses `/`). An unscoped package will be refused at launch by butler.
- `depends_on` forms an explicit DAG. **Parallel-safe = disjoint write sets AND no unmet dependencies.** Overlapping write sets are serialized; only if overlap is unavoidable and serialization too slow, consider worktree isolation — an escalation, not a default.
- Assign `model` per package: `sonnet` default; `opus` for packages with gnarly design surface or security weight. `max_turns` is butler's per-coordinator backstop (default 80).
- Every package block carries `inputs` (file:line where known) and `out_of_scope` (explicit DO-NOT list) — coordinators must not re-discover what you already know.
- **Record runtime/version choices up front.** For every runtime or toolchain a package needs (node, python, pnpm, …), name the version *and the reason* in the package block: latest LTS/stable, **≥7 days old**, mutually compatible, **never EOL**, and **declared in the backpack** so a container rebuild restores it. Version selection is a deliberate, reviewed choice — an undeclared runtime that vanishes on rebuild stalls an unattended fleet. A coordinator that must guess a version at 3am has already lost; `bp-deps-check.pl` enforces the mechanical half of this at execution time.

### 3. Manage (`/blueprint:manage`)

`list` / `view` read files only. `audit` re-runs `blueprint:bp-auditor`. `archive` / `delete` are lifecycle ops on the files. This plugin never touches running coordinator processes — those live in the sandbox and are butler's to stop. A user decision that implies substantial new work becomes a **new blueprint**, not scope creep on an existing one.

## Blueprint file discipline

`blueprint.md` is the source of truth for the initiative. Keep it current as you author and revise: append (never silently rewrite) Decisions, keep the package status table accurate, refresh `last_updated`. Once butler starts executing, the per-package ledgers become the live record butler maintains; you return to authoring only to re-scope or add packages.

### Recording a decision — binding statement in, argument out

**Durable rationale and coordinator context are not the same budget.** Everything in `blueprint.md`
is fixed prefix: every coordinator loads it before its first tool call, re-ingested at cache-**write**
rates on every relaunch that misses. A decision written to be durable — evidence, measurements,
alternatives you rejected, history — is worth writing, but it does not belong in every coordinator's
prefix. Measured on `sandbox-butler-overhaul`: the decisions section reached **32,844 bytes, 29.9% of
the file**, and three decisions authored in a single session added 9,097 of them. That was a reporter
following this protocol correctly as it was previously written.

So a decision is recorded in **two halves**:

- **In `blueprint.md`** — the stable id and a **binding statement**: what is ruled, and what it
  constrains, in one paragraph, ending in a pointer to the full text. **Budget: 400 bytes; hard
  ceiling 800.** If a decision genuinely rules more than fits in 400, exceed the budget — a lost
  ruling is a defect, a long statement is only a cost. Needing the ceiling is a signal you are
  recording several decisions as one; prefer splitting them into separate ids.
- **In `reports/decisions/<ID>.md`** — the complete argument, verbatim. Nothing is deleted; this is
  relocation with the original preserved (SYN-10: archive, never delete).

Coordinators load constraints. Auditors, red-teamers and the conformance judge follow the pointer.

Writing a binding statement is compression of *rationale*, never revision of *substance*. The failure
mode is a plausible summary that quietly drops a constraint: if a decision rules three things, all
three survive; if it mandates a specific file, id, threshold or forbidden action, that specific is a
**ruling**, not rationale, and it stays. The test to apply to your own sentence: *if someone obeyed
only this, could they violate the original?* If yes, it is lossy.

> **Never write the literal token `depends_on` in a decision.** `parse_dag` treats the **first**
> markdown table row containing that token as the dependency-table header, and the decisions table
> sits **above** the real one — a single occurrence silently mis-routes the whole run (SYN-14). Say
> "dependency edges" instead. `bp-blueprint.pl` refuses the token mechanically; do not rely on that
> as your only guard.

Use `bp-blueprint.pl` (`add-decision`, `set-decision`) rather than editing `blueprint.md` by hand.
