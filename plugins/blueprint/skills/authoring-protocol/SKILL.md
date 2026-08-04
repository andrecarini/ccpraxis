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
2. **Interrogate before decomposing.** Identify every architectural fork, every "ALWAYS confirm" surface, every ambiguity — and batch them into ONE `AskUserQuestion` pass. The user's mental model: *"I answer questions for 2–3 minutes at the start, then the agents work for hours."* Mid-flight questions are a defect; batch any later blockers with the next user-attention checkpoint unless truly urgent. **This pass always includes the quality-profile question (below) — there is no default, so it must ask every time, not only when the objective seems ambiguous.**
3. Decompose into packages (rules below). Write `blueprint.md` from the template; write one ledger per package from the package-ledger template, copying scope, done criteria, inputs, `write_set`, `test_paths`, `model`, `max_turns` into the ledger frontmatter.
4. **Auditor gate.** Dispatch `blueprint:bp-auditor` (Task) pointed ONLY at the blueprint dir. Its fresh context is the point: you and the user share session context that never made it into the file; an agent reading only the file finds exactly those gaps. Batch its findings into a second (final) `AskUserQuestion` pass, fix the blueprint, set `status: audited`.
5. Tell the user the blueprint is authored + audited and which packages form wave 1. Execution is `/butler:dispatch-fleet` inside the sandbox (or `/butler:drive-solo` for a host-safe single session) — never automatic.

### 2. Decomposition rules

- A package is **independently shippable**: its done criteria are testable without sibling packages, sized roughly 0.5–2 focused dev-days.
- `write_set` is mandatory and exact (colon-separated patterns; trailing `/` = prefix; `*` crosses `/`). An unscoped package will be refused at launch by butler.
- `depends_on` forms an explicit DAG. **Parallel-safe = disjoint write sets AND no unmet dependencies.** Overlapping write sets are serialized; only if overlap is unavoidable and serialization too slow, consider worktree isolation — an escalation, not a default.
- Assign `model` per package: `sonnet` default; `opus` for packages with gnarly design surface or security weight. `max_turns` is butler's per-coordinator backstop — an **authoring-time** default only (runtime turn budgeting is `b11`'s).

**Do not write a number here.** The canonical value lives in `plugins/butler/turn-caps.json` (`coordinator_default`), the ledger template is generated from it, and `bp-turn-caps.pl check` / `t/93` fail on drift. This paragraph previously carried its own literal, and that is exactly how the divergence happened: `b23` raised the prose 80 → 150 and never touched `templates/package-ledger.md` (still at the original `80`) or `agents/bp-scout.md` (still at `15`, the value this same paragraph called known-starving). Prose that restates a number becomes another copy to drift.

A cap is a **runaway backstop, not a budget** — it only binds when the coordinator would otherwise still be working, so a healthy one costs the same at 80 as at 800 while a starved one loses the package. Raise per package when its scope needs more; if you are tempted to lower one, lower the scope instead.
- Assign `effort` per package (opt-in; omit the key entirely for "no flag, inherit `effortLevel` from settings.json" — butler never invents a default here). Under the **higher** quality profile, most packages get no explicit `effort` (i.e. inherit the settings-payload default, today `high`), with `xhigh` reserved for the hardest packages. Under the **normal** profile, prefer `sonnet` more broadly, reserve `opus` for genuinely gnarly packages, and set `effort: medium` on most packages.

### Quality profile — always asked, never defaulted (operator ruling R-03)

Before decomposing, the author **must ask the user** to choose a quality profile for the whole blueprint — **normal** or **higher** — as part of the batched `AskUserQuestion` interrogation pass above. This question has **no default**: the author never silently picks one, never falls back to either option when the user doesn't answer, and never infers a profile from the objective's wording. If the answer is unclear, ask again; do not proceed to decomposition without an explicit choice.

- **higher** — approximately today's behavior: default effort (no explicit `effort:` key, so `effortLevel` from settings.json applies) on most packages, with `xhigh` on the packages judged hardest.
- **normal** — more `sonnet`, `opus` used sparingly, and `effort: medium` on most packages.

The chosen profile governs the `model`/`effort` assignment guidance above for every package in the blueprint.
- Every package block carries `inputs` (file:line where known) and `out_of_scope` (explicit DO-NOT list) — coordinators must not re-discover what you already know.
- **Record runtime/version choices up front.** For every runtime or toolchain a package needs (node, python, pnpm, …), name the version *and the reason* in the package block: latest LTS/stable, **≥7 days old**, mutually compatible, **never EOL**, and **declared in the backpack** so a container rebuild restores it. Version selection is a deliberate, reviewed choice — an undeclared runtime that vanishes on rebuild stalls an unattended fleet. A coordinator that must guess a version at 3am has already lost; `bp-deps-check.pl` enforces the mechanical half of this at execution time.

### 3. Manage (`/blueprint:manage`)

`list` / `view` read files only. `audit` re-runs `blueprint:bp-auditor`. `archive` / `delete` are lifecycle ops on the files. This plugin never touches running coordinator processes — those live in the sandbox and are butler's to stop. A user decision that implies substantial new work becomes a **new blueprint**, not scope creep on an existing one.

## Soft ordering vs a hard dependency edge

`depends_on` is not the only ordering tool. Two different needs get confused if you reach for the DAG
for both:

- **Hard edge (`depends_on`)** — you need the other package's **output**. It must reach `done` before
  you can start; if it never runs, you must never start either. Use `depends_on`.
- **Soft constraint (`requires_clean_tree: true`, package-ledger frontmatter)** — you need the tree in
  a **state** (it compiles, nothing else is mid-edit), and you do not care whether the other package
  ever runs at all — only that it is not running **right now**. A package declaring
  `requires_clean_tree: true` will not be launched while *any* other package is running, and this is
  invisible to write-set disjointness by design: two packages can have completely disjoint `write_set`s
  and still break each other if one needs the whole tree to build while the other is mid-edit anywhere
  in it.

Worked example: package `07` needs the repository to compile end-to-end (it runs the full test suite
against the built tree). Packages `04` and `05` touch unrelated files but leave the tree
non-compiling for stretches while they work. Naming `04` and `05` in a hand-written "do not run me with
X" list breaks the moment a third such package, `06`, gets added later in the blueprint — the
declaration is stale the instant the blueprint grows. `requires_clean_tree: true` on `07` needs no
names and never goes stale: it derives its conflict set from whatever happens to be running at
evaluation time.

**Do not turn a soft constraint into a `depends_on` edge as a shortcut.** That silently converts "not
concurrently with" into "only after `X` reaches `done`" — if `X` is ever skipped, retired, or never
scheduled, your package would then hang forever waiting on it. `requires_clean_tree` gates on the
*running* set only, so a conflicting package that never runs at all does not block you.

**Warning — this is real serialization, not a hang, but it costs you parallelism.** If every package in
a blueprint declares `requires_clean_tree: true`, the whole run becomes fully serial: only one package
at a time is ever eligible, because each one blocks every other while it runs. That is a correct
result, not a bug — but it silently opts the blueprint out of parallelism, and an author should learn
that from this paragraph, not from watching a fleet dispatch run one package at a time. Reach for
`requires_clean_tree` only on the packages that actually need a compiling tree; leave the rest
ungated.

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
