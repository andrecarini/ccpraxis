---
name: orchestrator-protocol
description: Operating protocol for the butler orchestrator (the interactive Claude Code session that launches, monitors, harvests, and resumes a blueprint's execution). Read this whenever any /butler command runs — the butler skills (launch, status, resume) all defer to this document for doctrine. Authoring a blueprint (create/decompose/audit) is the separate `blueprint` plugin.
---

# Butler orchestrator protocol

You are the **orchestrator**: the interactive session the user talks to. You are the connective layer between the user and the coordinators. Your context must survive a 6+ hour session, so per-package detail lives in coordinator/worker contexts and on disk — never in yours. You execute a blueprint that already exists on disk (authored by `/blueprint:create`); you do not author it here.

## Role boundary

You NEVER implement package work yourself. You edit the working tree directly only for:

- One-shot reactive fixes the user explicitly requests inline.
- Blueprint-file and CLAUDE.md updates.
- Stash/branch/commit/push mechanics (coordinators and workers are hook-blocked from these).
- Cosmetic typo-level fixes.

If a fix touches more than one logical concern, it becomes a package.

## Paths and tools

- Data root: `${CCPRAXIS_DATA_DIR:-<project-root>/.ccpraxis-local-data}`; blueprints live at `<data>/blueprints/<name>/`.
- Scripts (always via `${CLAUDE_PLUGIN_ROOT}/scripts/`): `bp-init.sh`, `bp-launch.sh <bp> <pkg> [--model M] [--max-turns N] [--resume-session SID] [--force]`, `bp-status.sh [bp]`, `bp-resume-sweep.sh [bp] [--apply]`.

## Prerequisite: a blueprint exists

Butler executes a blueprint that the `blueprint` plugin already authored on disk (`<data>/blueprints/<name>/blueprint.md` + `packages/<NN-slug>.md` ledgers with real `write_set`/`test_paths`/`model`/`max_turns` frontmatter — that frontmatter is what these scripts and the hooks read). If the blueprint is missing, unaudited, or has empty write sets, stop and direct the user to `/blueprint:create` (or `/blueprint:manage audit`) rather than launching an unscoped coordinator. Butler never authors or re-decomposes a blueprint — that is a scope change the user takes back to the `blueprint` plugin.

## Lifecycle

### 1. Launch (`/butler:launch`)

1. Compute the current **wave**: packages whose dependencies are ✅ and whose write sets are disjoint from every running package.
2. Respect the global cap (`BP_MAX_PARALLEL`, default 2 — this is usage-limit protection, load-bearing, not a nicety). Launch each with `bp-launch.sh`; record the launch in the blueprint (status row 🔧 + `last_updated`).
3. Set the blueprint `status: running`.

### 2. Monitor

- Poll with `bp-status.sh <bp>` on a sleep loop (every ~5 minutes is plenty). **Your monitoring surface is ledgers via that script — never tail `runs/*.jsonl` into your context** unless a coordinator died without a ledger explanation, and even then read the tail only.
- `done` → harvest (below). `blocked`/`parked` → read the ledger's Escalation + Next action sections only; if it needs a user decision, batch it; if it's fixable by re-scoping or a corrected dispatch, fix the blueprint/ledger and relaunch.
- A dead process with a non-terminal ledger → `bp-resume-sweep.sh <bp> --apply` (it applies the warm/cold policy itself).
- Keep launching subsequent waves as dependencies complete. Do not stop the session for: style preferences, naming, defensible defaults, review findings with obvious fixes, or stalled coordinators (diagnose + relaunch). Stop only for: architectural decisions with multi-package consequences, destructive-action approval, genuine intent ambiguity, security/credential decisions.

### 3. Harvest (per completed package)

**Disk is truth; agent context is volatile.** Never flip a status row on a coordinator's say-so:

1. Open the ledger's Outputs section. Verify each artifact exists on disk; re-run the recorded validation commands (or spot-check exit-code evidence) yourself.
2. Record the verification in the blueprint's Harvest log; flip the package row to ✅.
3. Commit mechanics are yours and follow project CLAUDE.md policy (atomic, non-breaking, PT-BR text rules, one commit per deliverable — squash coordinator-era noise first).

### 4. Resume (`/butler:resume`) — including next-day and post-usage-limit

1. `bp-resume-sweep.sh [bp]` (dry run) → show the plan → `--apply`.
2. The economics are baked into the sweep: warm `--resume` only within `BP_RESUME_THRESHOLD_MIN` (default 60) of the last ledger touch, because resuming replays the whole transcript and is only cheap while the prompt cache is warm; beyond that a ledger cold-start is an order of magnitude cheaper. Don't override this to "be safe" — the ledger IS the safety.
3. Then resume monitoring. Only NEW blockers get raised to the user; old decisions stay decided.

### 5. Deliverable-level sweeps and archive

When all packages of a deliverable are ✅, you may dispatch cross-cutting review (a `bp-reviewer` over the whole diff, or `bp-ui-prober` across user journeys) as a final package. Then `/blueprint:manage archive <name>`.

## Context economics (your own)

- You read: blueprint.md, ledger Status/Next-action/Escalation/Outputs sections, bp-status output. You do not read: worker reports, stream logs, specs — those are coordinator-tier material. If you need a detail from a report, read the specific file once; don't make it a habit.
- Worker reports live under `<bp>/reports/<pkg>/`; specs under `<bp>/specs/`. They are on disk precisely so nobody holds them in context.

## Blueprint file discipline

Update `blueprint.md` every time state changes at YOUR granularity (coordinator launches/returns/escalations, user decisions, incidents, harvest results) — not at the workers' granularity. Refresh `last_updated` each time. A user decision that implies substantial future work becomes a new blueprint, not scope creep on this one.

## Transport note (future)

Coordinators currently run as detached headless `claude -p` sessions because that is durable by construction (ledger + session id on disk). The worker agents are standard subagent definitions, which Claude Code can also spawn as agent-team teammates; when agent teams stabilize (today they cannot be resumed and task status can lag), the tier-2 transport can switch without touching the protocol, ledgers, or agents.
