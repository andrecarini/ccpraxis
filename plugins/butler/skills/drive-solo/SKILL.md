---
name: drive-solo
description: The one interactive execute verb — drive one blueprint, a named set, or ALL audited blueprints to done in THIS session as a thin loop over the perl director (bp-drive-next.pl), with a flat one-level bp-* worker tree, host or sandbox. The director carries all mechanical orchestration (ready-set, usage-pause timing with auto-resume, keep-awake, logging, order/park state); you spend tokens only on judgment (blueprint order, validity re-eval, spec/review, commits) and batch every human decision to the end. Idempotent start-or-continue — no separate resume. Use when the user wants to run, continue, drive, or work through one/some/all blueprints interactively, or says "keep going", "run all the blueprints", "do them all while I'm gone", "run everything unattended".
argument-hint: "[scope]  — a blueprint, a space/comma list, or 'all' (default: all audited)"
---

# /butler:drive-solo

You are the **driver**: ONE interactive session, flat one-level `bp-*` `Task` worker tree, no detached coordinators — host or sandbox. You are a **thin loop** over the perl director `bp-drive-next.pl`, which carries all mechanical orchestration; you spend tokens only on judgment. Start-or-continue; idempotent.

## Read first

- `${CLAUDE_PLUGIN_ROOT}/skills/coordinator-protocol/SKILL.md` — the per-package 8-step pipeline, ledger discipline, worker-dispatch contract, and disk-is-truth rules you follow per `run-package` action. Do NOT restate the pipeline here.
- `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-protocol/SKILL.md` — the Cast, so you know precisely how this differs from the fleet.

## Scope

`$ARGUMENTS` is the **scope** — how many blueprints to drive:

- **a single blueprint name** → drive just that one;
- **a space-or-comma-separated list of names** → drive that set in the given order;
- **`all`**, or **no argument** → all audited / non-terminal blueprints.

Pass the raw scope straight through as `next --scope <arg>`; the director resolves it. The skill does NOT re-implement resolution.

## What drive-solo is NOT

- **No deterministic orchestrator** and **no `bp-launch.sh` / `bp-orchestrate.sh`** — those are the fleet's. You are the driver.
- **No parallel coordinators.** Packages run **sequentially** with one write-capable worker in flight at a time (hook-enforced).
- **You do NOT poll usage or manage keep-awake.** The director does both — you simply dispatch the actions it returns.

## Preflight

Run `perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-preflight.pl"` once, before the loop. Non-zero exit → stop and surface the itemized report. (Host is a supported platform; an unsupported environment = stop — butler's env-support policy.)

## The director loop

Call `bp-drive-next.pl next --scope <scope>` → dispatch the returned action **by name**. The director emits exactly one action per call; execute it and call `next` again.

> **Data root (project-anchored).** The director resolves the blueprint data root the same way `bp-lib.sh` does: `$CCPRAXIS_DATA_DIR` if set, else `<project root>/.ccpraxis-local-data` (project root = `$BP_PROJECT_ROOT` → git top-level → walk-up from cwd for `.ccpraxis-local-data`). It is **never** plugin/script-relative, so a marketplace install resolves the *project*, not the plugin dir. If it can't find a `blueprints/` dir it **fails loud** (nonzero exit, clear stderr) rather than reporting a false `done`. If you ever hit that, export `CCPRAXIS_DATA_DIR=<project>/.ccpraxis-local-data` and re-invoke.

| `action` | Session behavior | Next director call |
|---|---|---|
| `need-order` | JUDGE the blueprint order over `candidates` (dependencies / risk / value — a Claude judgment, Decision #3), then persist it. | `bp-drive-next.pl record-order <bp> [<bp> …]`, then `next` again |
| `run-package` | Drive `action.package` of `action.blueprint` through its pipeline per **`coordinator-protocol` VERBATIM** — flat plugin-namespaced `bp-*` worker tree, ledger kept current, disk-is-truth verify each worker. | `next` again |
| `pause` (reason=`usage`) | Wait **token-cheaply** until `action.until_epoch` — **Monitor** with an until-condition, or **ScheduleWakeup** to the epoch under `/loop`; never busy-poll, never spin tokens. | `next` again (after the epoch) |
| `pause` (reason=`token`) | **TERMINAL relogin park:** tell the user to `/login` and re-invoke `drive-solo`; add to the end-batch (Decision #15). NOT an auto-resume. | *(none — stop; user re-invokes)* |
| `blueprint-done` | RE-EVALUATE the still-`pending` blueprints' validity (semantic Claude judgment, Decision #3/#4/#17); PARK the stale/moot ones. | `bp-drive-next.pl park <blueprint> <reason…>` for each stale bp, then `next` again |
| `done` | Present ALL batched decisions/parks in ONE pass (Decision #5): per-blueprint done/total, every accumulated park with its one-line decision + verify command, any governance-degraded note, any relogin. | *(none — run settled; stop)* |

> The **governor** verdict (`bp-usage-gate.pl verdict`) that produces a `pause` is fetched INTERNALLY by the director — the session never runs it (Decision #13).
> **Keep-awake** is a director-managed side-effect, never a session action (Decision #7).

## Never end a turn with nothing scheduled — **mechanically enforced**

**A driver turn may end for exactly two reasons: something will wake the session, or
the run is settled.** Nothing else.

Something will wake you when the turn dispatched a subagent, or started a
`run_in_background` Bash call — both notify you and the loop resumes. A **foreground**
Bash call schedules nothing: it returns into the same turn. So a turn whose last act
was a ledger write, ending with text that promises the next step, is a **dead stop** —
the run halts mid-package while *appearing* finished, and the operator only discovers
it by asking. That is the worst failure an unattended run can have.

Observed three times in a single 12-hour run (2026-08-07), each time right after a
ledger write. So it is no longer prose:
`plugins/butler/hooks/gate-drive-loop.sh` (Stop) blocks the turn from ending when
nothing is scheduled and `bp-drive-next.pl next` still returns actionable work;
`mark-wakeup.sh` (PreToolUse) records the dispatch that earns a legitimate turn end.
Proven by `plugins/butler/tests/t/94-drive-loop-gate.t`.

- **Do the next thing in the same turn, rather than announcing it.** "Moving on to X"
  followed by a turn end is precisely the shape the gate exists to catch.
- Record the ledger **and then** dispatch, in one turn. The ledger write is not a
  stopping point.
- The gate yields after 3 consecutive blocks, honours `.drive-solo/.stop-ok`
  (one-shot) and `CCPRAXIS_DRIVE_STOP_OK=1`, and fails **open** on any internal
  error — a gate that will not yield is worse than a stalled run.

## Arm the watchdog — the other half, for **wedged** rather than **stopped**

The gate above catches a turn that ends with nothing scheduled. It cannot catch the
harder failure: you dispatch a worker, the turn legitimately ends because a wake-up
*was* scheduled, and **the wake-up never arrives** — the worker hung, died silently,
or is itself waiting on something that can never happen. No `Stop` event fires, so no
`Stop` hook can help. The session sits idle, indefinitely, looking exactly like a
session that is working. That is DAME field report batch-1 #11: an orphaned watcher
still looping after **seventeen hours**, counted as live the whole time.

So **arm the watchdog at the start of a run, and re-arm it every time it fires**:

```bash
perl plugins/butler/scripts/bp-watchdog.pl --sleep 1800 --arm    # run_in_background
```

A backgrounded Bash call notifies the session when it exits, so the watchdog's own
expiry is a wake-up you control. Even if every other wake-up in the run is lost, the
session revives on this one. It converts silent death into **at most 30 minutes of
silence**.

On each firing it prints one of three verdicts — act on it, don't just re-arm blindly:

| verdict | meaning | what to do |
|---|---|---|
| `SETTLED` | the director reports no remaining work | stop; do **not** re-arm |
| `PROGRESS` | the tree moved during the window | re-arm and carry on |
| `STALLED` | nothing moved, and the director still wants work | **diagnose before re-arming** — it names the wedged package, how long its ledger has been silent, and what to check |

A `STALLED` verdict is not a prompt to wait longer. A wait that has already failed once
does not improve by being repeated: re-dispatch the wedged worker instead. And treat an
empty or narration-shaped worker result as a **dead dispatch**, not a finding of
"nothing" — a worker that runs out of turns returns its last narration, which reads
exactly like success.

The watchdog observes and reports; it never kills anything and never writes into a
blueprint. Remediation is a judgment call and stays with you.

## Lean-context

> **lean-context** doctrine (Decision #6): the driver reads only ≤15-line worker summaries, ledgers, and the director's JSON. Workers do the heavy reading. The harness auto-summarizes; the run is idempotent — the director is stateless-from-disk, so a summarize or re-invoke resumes losslessly. Old decisions stay decided.

## Batch

> **batch** doctrine (Decision #5): all parks and human decisions accumulate on disk (director-recorded) and surface in ONE final pass at `done`. No mid-run questions except a truly-blocking one. Parks are recorded via `bp-drive-next.pl park`.

## Keep-awake (director-managed)

> The director auto-starts the wake-lock when active work or a pending usage-resume begins, and auto-stops it when the run settles. In sandbox, keep-awake is a no-op. The session does nothing (Decision #7/#19).

## Host or sandbox

> Runs identically host OR sandbox — perl + hooks only, no platform-specific spawns in the prompt (Decision #8).

## Commit mechanics

Commits are yours (workers and coordinators are hook-blocked from git): atomic, one commit per coherent deliverable, project CLAUDE.md policy, no `Co-Authored-By`.

## Self-modifying blueprints

> **self-modifying** blueprints — blueprints that edit butler's own executor, hooks, or skills — must be driven HERE (interactively), NEVER as a self-modifying dispatch-fleet. The running session keeps its already-loaded instructions, so the mid-run rewrite is safe. Do NOT re-read this SKILL.md file mid-run (Decision #11/#20).

## Idempotent start-or-continue

Re-invoking re-reads the ledgers and the director's on-disk state, skips verified `done` work, and resumes the rest. Old decisions stay decided. There is no separate resume verb.
