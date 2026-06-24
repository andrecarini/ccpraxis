---
name: drive-solo
description: Execute a blueprint in THIS interactive session as a single driver with one flat layer of bp-* worker subagents (no detached coordinators) — idempotent start-or-continue, runnable on host or sandbox. Use when the user wants to run, continue, drive, or work through a blueprint's packages interactively in the current session (the host-safe / single-session alternative to the headless dispatch-fleet). Absorbs the old interactive blueprint:resume role.
argument-hint: <blueprint> [package]
---

# /butler:drive-solo

You are the **driver**: in THIS interactive session you execute a blueprint yourself, playing the coordinator role for one package at a time and dispatching the `bp-*` workers as a **flat, one-level `Task` layer** — no detached `claude -p` coordinators. So it needs no sandbox skip-permissions and runs **host or sandbox**. It is the single-session counterpart to **`/butler:dispatch-fleet`** (the headless fleet driven by the deterministic orchestrator script); two verbs exist only because of the subagent-depth limit (`dispatch-fleet` gets depth via detached coordinators; `drive-solo` accepts a flat worker tree and runs anywhere). It is **start-or-continue** — there is no separate resume — and it absorbs the old interactive `/blueprint:resume` working-document role.

**Read first:** `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-protocol/SKILL.md` (the **Cast** — so you know how this differs from the fleet) and `${CLAUDE_PLUGIN_ROOT}/skills/coordinator-protocol/SKILL.md` (the **8-step pipeline, ledger discipline, worker-dispatch contract, and disk-is-truth rules** — you follow these per package, in-session).

## What drive-solo is NOT

- **No deterministic orchestrator** (`bp-orchestrator.pl`) and **no `bp-launch.sh` / `bp-orchestrate.sh`** — those are the fleet's. You are the driver; you do the watching and the work yourself, in this session.
- **No usage-governance / token-keeper.** Your session shares the user's usage and OAuth token; if you approach a limit, **stop cleanly and tell the user** (park the in-flight package with a concrete Next action) rather than pushing through. For long unattended multi-hour runs that must survive limits, that's `dispatch-fleet`, not this.
- **No parallel coordinators.** You work packages **sequentially** and keep **one write-capable worker in flight** at a time (hook-enforced for the worker subagents).

## Steps

1. **Resolve + load the blueprint.** `$0` is the name. If omitted or it doesn't resolve, Glob `<data>/blueprints/*/blueprint.md`, read each `status`, and let the user pick (`AskUserQuestion`). Read `blueprint.md` in full plus every `packages/<pkg>.md` ledger and the files it points at under Objective / Decisions / Constraints / Key references — enough context to actually drive, not just the summary.

2. **Summarize where it stands** (this is the absorbed `blueprint:resume` behavior): objective, locked Decisions, and per package `done` / `running`/`converging` / `blocked`/`parked` / `pending` with the first line of each non-terminal Next action. Re-establish shared context after any gap.

3. **Preflight (A8).** Run `perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-preflight.pl"`. If it exits non-zero it has printed an itemized "unsupported" report — **stop** and surface it; do not start real work on an unsupported environment (Decision #29). (On the host the `runtime.container` check is skipped only inside the sandbox; the host itself is a supported platform.)

4. **Pick the package(s) to work.** If `$1` names one, drive just that (after verifying its `depends_on` are all ✅). Otherwise compute the ready set off the DAG (dependencies ✅) and drive them **one at a time** in dependency order. A package whose ledger is already `done` is skipped (verify its Outputs exist on disk first — disk is truth); a non-terminal ledger is a **continuation** (verify recorded Outputs, re-run the last validation, resume from its Next action — never redo verified work).

5. **Drive each package as its coordinator** — follow `coordinator-protocol` exactly, with these single-session adaptations:
   - Export the package's env contract for the workers/hooks before dispatching: `BP_LEDGER`, `BP_DIR`, `BP_PACKAGE`, `BP_BLUEPRINT`, `BP_WRITE_SET`, `BP_TEST_PATHS`, `BP_PROJECT_ROOT`, `BP_ROLE=coordinator` (read the values from the ledger frontmatter; `bp-lib.sh` helpers resolve the paths). The plugin hooks fire for the `Task` worker subagents (write-set containment, implementer/test-writer role separation, single-writer, git safety) — work with them, never around them.
   - Dispatch the pipeline workers with the **plugin-namespaced** `subagent_type` (`butler:bp-scout`, `butler:bp-architect`, `butler:bp-test-writer`, `butler:bp-implementer`, `butler:bp-reviewer`, `butler:bp-redteam`, `butler:bp-ui-prober`), each with the explicit Scope / Files / Do-NOT / Acceptance / Report-to / Return-≤15-lines contract.
   - Keep the **ledger** current (medical-chart discipline: update Next action before each step; record Outputs + validation commands + exit codes; append to the attempt log). **Disk is truth** — after every write-capable worker, confirm the files exist and run the validation yourself.
   - Honor the 4-attempts-on-the-same-failure cap → `blocked` with a precise escalation. Park (don't guess) when a genuine user-intent decision is needed.

6. **On a terminal state.** `done` → harvest-verify the ledger's Outputs on disk (re-run/spot-check the recorded validations yourself), then flip the package row in `blueprint.md` to ✅ and refresh `last_updated`. A package taken to `done` this way is **indistinguishable on disk** from a fleet-`done` one (same ledger Outputs, same validation evidence, same registry-irrelevant artifacts). `blocked`/`parked` → leave the Escalation + Next action concrete and tell the user the single decision needed. Then move to the next ready package, or stop.

7. **Commit mechanics are yours** (coordinators/workers are hook-blocked from git) and follow project CLAUDE.md policy — atomic, one commit per coherent deliverable, no `Co-Authored-By`.

> **Self-modifying blueprints (Decision #22).** A blueprint that edits butler's own executor/hooks must be run **here (drive-solo) or interactively — never as a self-modifying `dispatch-fleet`**. drive-solo is the sanctioned path for exactly that case.

> **Idempotent.** Re-running `/butler:drive-solo $0` re-reads the ledgers, skips verified `done` work, and continues the rest — old decisions stay decided; only genuinely new blockers are raised.
