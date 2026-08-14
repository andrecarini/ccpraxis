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
- **No parallel coordinators.** Packages run **sequentially** with one write-capable worker in flight
  at a time — **your discipline, not a hook.** `track-dispatch.sh` maintains that lock but opens with
  `bp_hook_gate`, which needs `BP_LEDGER`/`BP_DIR`/`BP_PROJECT_ROOT` — exported only into a
  `bp-launch.sh` coordinator, never into this session. Check `git status` after every write-capable
  worker; see coordinator-protocol, "…but only inside a butler-LAUNCHED coordinator".
- **You do NOT poll usage or manage keep-awake.** The director does both — you simply dispatch the actions it returns.
- **Validation can be denied while a write-capable worker is live.** `guard-validation-interlock.sh`
  (PreToolUse, mechanically enforced — not this doc) blocks a test/build/lint-shaped `Bash` command
  whenever a write-capable worker's marker is fresh, so you don't read its live/leftover temp state
  as a false red. The denial (exit 2) says so itself and names the wait/retry remedy — nothing further
  to memorize here; just wait for the worker to return (or the marker to age out) and re-run.

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
| `stop` (reason=`token-refresh-failed`) | **Genuinely terminal:** the director already tried and failed to refresh the token (via `bp-token-keeper.pl`). Tell the user to `/login` and re-invoke `drive-solo`; add to the end-batch (Decision #15). NOT an auto-resume. | *(none — stop; user re-invokes)* |
| `blueprint-done` | RE-EVALUATE the still-`pending` blueprints' validity (semantic Claude judgment, Decision #3/#4/#17); PARK the stale/moot ones. | `bp-drive-next.pl park <blueprint> <reason…>` for each stale bp, then `next` again |
| `done` | Present ALL batched decisions/parks in ONE pass (Decision #5): per-blueprint done/total, every accumulated park with its one-line decision + verify command, any governance-degraded note, any relogin. | *(none — run settled; stop)* |

> The **governor** verdict (`bp-usage-gate.pl verdict`) that produces a `pause` is fetched INTERNALLY by the director — the session never runs it (Decision #13).
> **Keep-awake** is a director-managed side-effect, never a session action (Decision #7).
> A merely-**stale** token (still refreshable) is recovered **transparently** before any action ever surfaces to the session — the director attempts the refresh on-demand inside `next` the moment the governor reports the token floor, and proceeds silently on success. No session-visible row exists for that path by design; `stop`/`token-refresh-failed` above fires only once that refresh attempt has actually failed.

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

## Arm the watcher — the other half, for **wedged** rather than **stopped**

The gate above catches a turn that ends with nothing scheduled. It cannot catch the
harder failure: you dispatch a worker, the turn legitimately ends because a wake-up
*was* scheduled, and **the wake-up never arrives** — the worker hung, died silently,
or is itself waiting on something that can never happen. No `Stop` event fires, so no
`Stop` hook can help. The session sits idle, indefinitely, looking exactly like a
session that is working. That is DAME field report batch-1 #11: an orphaned watcher
still looping after **seventeen hours**, counted as live the whole time.

**Step 1 — stamp the dispatch, foreground, before backgrounding anything.** Elapsed
time is measured DRIVER-SIDE, from the driver's own clock at launch (Decision 7) —
never from the worker's own self-report: a dispatch that ran roughly four hours once
self-reported 47 minutes, and any detector built on that self-report is built on
sand.

```bash
perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-dispatch-log.pl start \
     --id <bp>-<pkg>-<epoch-or-short-tag> --worker-type <bp-implementer|bp-test-writer|...> \
     --budget-seconds <this dispatch's own expected budget — the SAME number used below>
```

**Step 2 — arm `bp-watch.pl` for the dispatch you just made, sized to that dispatch's
own expected budget** (the SAME number as step 1's `--budget-seconds`) —
`bp-watchdog.pl` is **superseded** by this (see its own header) and is no longer
armed here: it used to print one of `SETTLED`/`PROGRESS`/`STALLED` on a fixed
30-minute tick, but its progress scan
walked the whole blueprint tree with no subject-scoping at all, so a driver's own
ledger edit read as the worker's progress and manufactured false `PROGRESS` verdicts
during a real four-hour stall. One arm here covers the **whole** dispatch — there is
no routine 30-minute tick to forget, unlike the old universal-timer habit that
produced dozens of forgettable re-arms across a single long run (2026-08-06 #11):

```bash
perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-watch.pl --arm --package <bp>/<pkg-just-dispatched> \
     --max-seconds <this dispatch's own expected budget — SAME number as step 1> \
     --keepawake        # run_in_background
```

A backgrounded Bash call notifies the session when it exits — `mark-wakeup.sh`
matches any backgrounded Bash call by shape, not by binary name, so this satisfies
"registers as a legitimate wake-up" for free, no new wiring needed. `--keepawake`
refreshes the *existing* `bp-keepawake.pl` lease (the same `.drive-solo/keepawake.pid`
`bp-drive-next.pl` already manages) once per poll tick — closing the gap where that
900s lease is refreshed only when the director runs, and the director is skipped
whenever a wakeup is already pending. It never creates a second, independent
lease: if no lease is currently held, `--keepawake` is a no-op for that tick — the
director remains the only thing that ever spawns the first one.

**Step 3 — one `pause` call satisfies BOTH gates.** `guard-subagent-stall.sh`
already blocks this turn's own Stop until you call `finish` or a verified `pause` on
`bp-runstate.pl`, and its own denial text already spells out the exact
`pause --watcher-pid <pid> --until <epoch>` call. That SAME call —
`bp-runstate.pl pause --watcher-pid <the backgrounded watcher's own pid> --until
<launch-epoch + N>` — is also the exact state `gate-drive-loop.sh`'s runstate fold
(below) now reads on a LATER turn while the dispatch is still in flight. This is
reuse, not new plumbing: w02 adds no new state machine.

On exit `bp-watch.pl` prints one of five verdicts — act on it, don't just re-arm
blindly:

| verdict (exit code) | meaning | what to do |
|---|---|---|
| `TERMINAL` (0) | the watched package's ledger reached `done`/`dropped`/`blocked`/`parked` | stop; assess the result — does not imply "never re-arm anything else" |
| `BOUND` (1) | `--max-seconds` elapsed, nothing resolved; liveness is **unknown** | investigate, or widen the budget and re-arm — never assume dead or done |
| `WORKERS-GONE` (2) | any ONE configured pid died with no terminal status observed | likely crash — **re-dispatch the wedged worker instead**, don't wait longer |
| `ARTIFACT` (3) | a watched path's mtime advanced, or it appeared | re-arm and carry on |
| `STATUS-CHANGE` (4) | the ledger status changed to a **non-terminal** value | re-arm and carry on |

**Step 4 — before killing, and before waiting again: interrupt and ask for a
report.** Once `bp-dispatch-log.pl elapsed --id <id>` shows `over_budget: true`,
**do not defer again.** State it as the instruction, not merely as an observation:
the 2026-08-12 report is explicit that a driver deferring "this has been too long"
four consecutive times is a design that will fail the same way again. Send the
dispatch this canonical prompt, adapted to what it is actually running:

> *"STOP ITERATING AND REPORT NOW. Do not start another verification/build/test
> cycle. Let anything currently in flight finish, then report immediately: what you
> changed, what state each file is in, what you were iterating on, and how you were
> verifying it. If something is currently failing, do NOT keep trying to fix it —
> leave the file as-is and report the failure verbatim."*

This is carried from the 2026-08-12 report's own prompt (structure preserved
exactly: stop iterating, let in-flight work finish, report state verbatim, do not
keep trying to fix), generalised from its verbatim `flutter test` wording to any
verification loop. It demonstrably worked once: the worker returned promptly with a
complete, accurate accounting and nothing was lost. Record the outcome:

```bash
perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-dispatch-log.pl finish --id <id> --status interrupted \
     --note "<one line: what the report said>"
```

The dispatch is **not** killed by this move — it is asked to stop iterating and hand
back what it has. Deciding whether to then re-dispatch, accept partial work, or
escalate is a judgment call that stays with you, same as `bp-watch.pl`'s own
"observes and reports; never kills" posture.

A `WORKERS-GONE` (or a `BOUND` where you have independent reason to believe the worker
died) is not a prompt to wait longer. A wait that has already failed once does not
improve by being repeated: **re-dispatch the wedged worker instead**. And treat an
empty or narration-shaped worker result as a **dead dispatch**, not a finding of
"nothing" — a worker that runs out of turns returns its last narration, which reads
exactly like success.

`bp-watch.pl` observes and reports; it never kills anything and never writes into a
blueprint. Remediation is a judgment call and stays with you.

**The residual named by w01 is closed by the fold, contingent on `gate-drive-loop.sh`
being in w02's write set.** A `BOUND` exit with a live, verified pause in place no
longer risks a silent block-then-nag on the next Stop — `bp-runstate.pl status`
reporting `paused` is exactly the signal `gate-drive-loop.sh`'s fold now consults. A
`BOUND` exit with **no** verified pause (the watcher died, or nobody ever called
`pause`) correctly still blocks: the gate cannot tell the difference between "forgot
to re-arm" and "nothing was ever watching," and per `t/94` section H it must not
guess in the permissive direction.

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
