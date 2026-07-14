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
