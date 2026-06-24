---
name: orchestrator-protocol
description: Operating doctrine for butler execution — the reporter (the interactive Claude front door) plus the deterministic orchestrator script (no Claude) that actually drives a blueprint's unattended run, and the coordinators / workers / judges beneath them. Read this whenever any /butler command runs; the execute verbs (dispatch-fleet, drive-solo) and status all defer to it. Authoring a blueprint (create/decompose/audit) is the separate, host-side `blueprint` plugin.
---

# Butler execution protocol

Butler **executes** a blueprint the `blueprint` plugin already authored on disk (`/blueprint:create`); it never authors one here. The old design had a single thing called "orchestrator" — one Claude session that watched, launched, harvested, and resumed everything. That is now **split**, and getting the cast straight is load-bearing: the driving is done by a **deterministic script with no Claude**, and the only Claude you talk to is a lean **reporter**.

## Cast (read this first)

| name | what it is |
|------|------------|
| **reporter** | The interactive **Claude** session — the human's front door. Launches a run, answers "how's it going?", relays queued decisions. Stays lean: it reads on-disk state to answer; it does **not** run a monitoring loop and does **not** drive the run. Become it with `/butler:reporter`. |
| **orchestrator** | The **deterministic Perl script** `bp-orchestrator.pl` — drives a run unattended with **zero Claude**. Watches/launches/relaunches coordinators, polls usage, keeps the OAuth token alive, maintains the busy-lease, fires judges, auto-resumes. You never run it by hand; `dispatch-fleet` starts it via `bp-orchestrate.sh`. |
| **coordinator** | A headless `claude -p`, one per package, running that package's 8-step pipeline (see `coordinator-protocol`). |
| **worker** | A Task **subagent** of a coordinator; does one pipeline step, returns a ≤15-line summary. |
| **judge** | A fresh, **scoped** Claude call the orchestrator fires only for a bounded judgment: `bp-harvest-judge` (verify a finished package's outputs from disk → pass/fail) or `bp-resolve-judge` (attempt a broad-context fix on a stuck one → relaunch/park). Detached, writes a verdict file, has no monitoring loop. |
| **dashboard** | The sandbox TUI (no Claude). While open it keeps the container alive and holds keep-awake (B-cluster). |

**There is no persistent monitoring Claude and no detached host keeper.** The orchestrator *script* does the watching with no Claude; the dashboard window holds the PC awake. If a design pass reintroduces a "you are the orchestrator, sleep-and-poll" Claude loop, it has regressed (Decisions #5/#14).

## Paths and tools

- Data root: `${CCPRAXIS_DATA_DIR:-<project-root>/.ccpraxis-local-data}`; blueprints live at `<data>/blueprints/<name>/`.
- Scripts (always via `${CLAUDE_PLUGIN_ROOT}/scripts/`):
  - `bp-orchestrate.sh <bp>` — start (or continue) the detached deterministic orchestrator; sandbox-only, idempotent. **This is what `dispatch-fleet` runs.**
  - `bp-orchestrator.pl` — the orchestrator loop itself (the script `bp-orchestrate.sh` detaches). You never invoke it directly.
  - `bp-launch.sh <bp> <pkg> [--resume-session SID] [--force]` — launches one coordinator. **Called by the orchestrator**, not by you.
  - `bp-status.sh [bp]` — the cheap status snapshot the reporter / `/butler:status` read.
  - `bp-resume-sweep.sh [bp] [--apply]` — the warm-vs-cold recovery sweep the orchestrator applies on a start-or-continue.

## Prerequisite: a blueprint exists

Butler runs a blueprint authored on disk (`<data>/blueprints/<name>/blueprint.md` + `packages/<NN-slug>.md` ledgers with real `write_set`/`test_paths`/`model`/`max_turns` frontmatter — that frontmatter is what the scripts and hooks read). If the blueprint is missing, unaudited, or has empty write sets, stop and send the user to `/blueprint:create` (or `/blueprint:manage audit`) rather than launching an unscoped fleet. Butler never authors or re-decomposes a blueprint.

## The execute verbs (Decisions #2/#3/#4)

- **`/butler:dispatch-fleet <bp>`** — the headless multi-coordinator fleet, **sandbox-only**. Starts the deterministic orchestrator and hands you to the reporter. Use it when the user wants unattended execution at scale.
- **`/butler:drive-solo <bp>`** — a single **interactive** session with one flat layer of `bp-*` worker subagents (no detached coordinators), runnable **host or sandbox**. Use it for host-safe / single-session execution. (Absorbs the old interactive working-document resume role.)
- **`/butler:status [bp]`** — a cheap read-only snapshot; never drives anything.
- **There is no `resume` verb.** Both execute verbs are idempotent **start-or-continue**: re-running `dispatch-fleet` continues a live or interrupted run (the orchestrator's resume-sweep folds in warm/cold recovery), and `drive-solo` re-reads the ledgers and picks up where they left off. Old decisions stay decided; only genuinely new blockers surface.

## What the deterministic orchestrator does (so neither you nor a coordinator has to)

This is **code** (`bp-orchestrator.pl`), unit-tested decision-by-decision — not agent doctrine. The doctrine-level summary so the reporter can explain it:

- **Watch + event-driven launch.** It watches coordinators continuously (PID liveness + `runs/<pkg>.jsonl` growth — free signals) and the *instant* one finishes/dies it computes newly-ready packages off the explicit DAG (dependencies ✅ + write-sets disjoint from everything running) and launches them, cap-bounded by `BP_MAX_PARALLEL`. A periodic timer is only a fallback heartbeat.
- **Watchdog.** Dead coordinator → relaunch (warm `--resume` within the cache window, else a ledger cold-start); alive but stream-log flat → kill + cold-relaunch; past an attempt cap → mark the package `blocked` and queue a `runs/needs-you/` decision (loop-guard).
- **Usage governance (Decisions #7–#9).** Burn-rate-adaptive poll of `/api/oauth/usage`; pause the fleet at a **derived trip point BELOW** the 85% (5h) / 90% (7d) ceilings (the remaining headroom is the user's), recorded in `runs/.paused` (epoch `resets_at` + a jittered relaunch time); **auto-resume** after the reset (Decision #12).
- **Token-keeper (Decision #11).** Refreshes the OAuth token in the 1–2h-remaining band, atomic + cooperative write-back; crossing the 1h floor unrefreshed → graceful pause + a re-login decision.
- **Fail-safe (Decision #12).** Telemetry loss / un-refreshable token / contract drift → graceful pause, never fly blind. Everything (every poll, refresh, pause, resume) is logged to `runs/orchestrator.log` (Decision #30) — never a secret value.
- **Busy-lease (Decision #16).** Touches `/tmp/.butler-busy` while work is active or an auto-resume is pending; not while the only outstanding work is parked-for-human.
- **Graceful-stop gate (Decision #10/#18).** In-flight workers can't be cancelled, so a pause/shutdown reaches *live* coordinators through a **`PreToolUse` gate** (`gate-shutdown.sh`, fires inside each coordinator): when a stop signal is set it denies new work (`Task`, worksite edits) but allows the ledger park-write, so the coordinator drains its current worker (≈ 1 tool-call) and stops cleanly. Three signals share the gate — `runs/.shutdown` (graceful-shutdown-all → terminal **park**, stays down), `runs/.paused` (usage/telemetry → **non-terminal resumable** stop, auto-resumed warm), `runs/<pkg>.force-stop` (per-package). The orchestrator never kills a coordinator for a pause/shutdown; it lets the gate funnel each to a clean stop and then winds down once none are running.

### Harvest (Decision #15)

A coordinator already runs its own tests + review + red-team before it reports `done`. **Default = trust that:** the orchestrator flips the status and launches dependents immediately, and harvest-verification runs as an **async spot-audit** by the `bp-harvest-judge` (A5), not a gate on every launch. (The alternative — `BP_HARVEST_MODE=gate`, which holds a finished package's dependents until its harvest verdict is `pass` — is configurable per run; the default favors throughput.) Either way, **disk is truth**: the judge verifies a finished package's declared outputs against its done-criteria from disk, reading only that contracted slice, never on a coordinator's say-so.

A failed async audit doesn't unwind the run: the package is **reopened non-terminal** and relaunched once with the audit's specific failures written into its ledger as corrective context; if it fails the audit again it's **parked with a `harvest-failure` alarm**. Dependents that already launched off the bad output are **flagged for re-verification, never auto-killed** (the orchestrator never kills live work — same contract A4 rests on; reactive failure is demoted to an alarm, #12). An unrecognized or timed-out harvest verdict counts as a failure, never a silent pass (#29).

### Escalation = park-the-branch, never global-halt (Decision #13)

A stuck package climbs a ladder: (a) the coordinator's own review/red-team/fix loops retry (the watchdog relaunches up to the attempt cap); (b) past the cap, the orchestrator fires a deeper, broad-context **`bp-resolve-judge`** — a deliberately rare call (capped at one try per package by `BP_RESOLVE_CAP`). The judge edits **within the package's hook-enforced write-set**: if it can apply an intent-clear fix (re-scope the spec, correct a broken precondition, drop a criterion *explicitly tagged optional*) it does so and verdicts `relaunch`, and the orchestrator relaunches the coordinator with a **fresh retry budget** off the corrected ledger; (c) if it cannot determine intent without guessing, it verdicts `park` with one precise question, and the orchestrator **parks that package, queues the question in `runs/needs-you/`, and keeps all independent work running**. A resolve-judge that crashes or times out fails safe to a park (never a silent relaunch loop). The user is never a blocking dependency for the whole run.

Both judges are **detached, verdict-on-disk** processes (`runs/<kind>/<pkg>.verdict.json`) the orchestrator spawns then polls — it never blocks its watch tick on a multi-minute Claude call. They carry the coordinator env contract so `guard-writes` scopes their writes, but run under a non-coordinator `BP_ROLE`, so the coordinator stop-discipline hooks skip them.

## The reporter (the human's front door)

You become the reporter via **`/butler:reporter`** (implemented in package A7). It syncs to current on-disk state (blueprint + registry + ledgers + the `runs/needs-you/` queue — a bounded snapshot, never an accumulating transcript), detects and **attaches** to a live run (via the registry / the `runs/.orchestrator` marker / the busy-lease), answers status from disk in a cheap turn, surfaces queued human-intent decisions, and writes answers back to unblock packages. It does not drive the run and does not poll in a token-burning loop. **Closing the reporter never affects the run; re-running `/butler:reporter` re-attaches.**

### Role boundary (when you DO edit the tree yourself)

As the reporter you NEVER implement package work. You edit the working tree directly only for: one-shot reactive fixes the user explicitly requests inline; blueprint-file and CLAUDE.md updates; stash/branch/commit/push mechanics (coordinators/workers are hook-blocked from these); cosmetic typo-level fixes. Anything touching more than one logical concern is a package, not an inline fix.

## Context economics (the reporter's own)

You read: `blueprint.md`, ledger Status / Next-action / Escalation / Outputs sections, `bp-status` output, and the `runs/needs-you/` queue. You do **not** read worker reports, stream logs, or specs — those are coordinator-tier material on disk precisely so nobody holds them in context. If you need one detail from a report, read that one file once; don't make it a habit.

## Heartbeat lifetime — important for long-running blueprints

The sandbox container lives **only while the dashboard window's heartbeat continues** (Decision #17; B-cluster owns the dashboard + keep-awake). The deterministic orchestrator is **detached** — it survives you closing the reporter session — but it cannot outlive its container: if the dashboard closes or the laptop sleeps with no keep-awake, the container reaps and the orchestrator (and its coordinators) stop.

**What survives:** ledger state, the registry, `runs/.paused`, and all artifacts on disk. **Recovery:** the next `/butler:dispatch-fleet` (or `bp-orchestrate.sh`) **continues** — it re-acquires the marker, the resume-sweep restarts interrupted coordinators warm-or-cold, and no work is lost (and nothing is double-launched: the flock marker is the single-instance guard). For unattended multi-hour runs, keep the dashboard open and the PC awake.

## Blueprint file discipline

The reporter (and the author) updates `blueprint.md` when state changes at *that* granularity — coordinator launches/returns/escalations the user should know about, user decisions, incidents, harvest results — refreshing `last_updated`. The orchestrator maintains the live per-package record (ledgers, registry, `runs/` artifacts). A user decision that implies substantial future work becomes a **new blueprint**, not scope creep on this one.

## Transport note (future)

Coordinators run as detached headless `claude -p` sessions because that is durable by construction (ledger + session id on disk). The worker agents are standard subagent definitions; when agent teams stabilize (today they cannot be resumed and task status can lag), the tier-2 transport can switch without touching this protocol, the ledgers, or the agents.
