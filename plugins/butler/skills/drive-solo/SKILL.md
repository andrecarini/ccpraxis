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
- **No parallel coordinators**, but the director may hand out a further ready package whose write
  set is disjoint from every in-flight one, so several packages can be in flight, with one
  write-capable worker per package at a time as your discipline.
- **You do NOT poll usage or manage keep-awake.** The director does both — you simply dispatch the actions it returns.
- **Validation can be denied while a write-capable worker is live.** `guard-bash.sh`
  (PreToolUse, mechanically enforced — not this doc) blocks a test/build/lint-shaped `Bash` command
  whenever a write-capable worker's marker is fresh, so you don't read its live/leftover temp state
  as a false red (the worker running its own tests is exempt). The denial (exit 2) says so itself and
  names the wait/retry remedy — nothing further to memorize here; just wait for the worker to return
  (or the marker to age out) and re-run.

**Write scope.** In an armed drive-solo session the write guards apply to you and your
subagents. A subagent may write only its bound package's write set (test paths only as the
test-writer), its own ledger, and its own blueprint dir except a sibling package's ledger, and
temp. With two or more packages in flight, an unbound subagent's edits are refused. Your own
edits are checked against the in-flight write set, or their union. Check `git status` after
every write-capable worker.

## Continuity and dispatch

<!-- continuity:begin -->
First step, before Preflight: `butler-continuity on --role driver --new-thread <name> --goal '<what this run is for>'`, or `--thread <name>` (same `--goal`) in place of `--new-thread` to resume this run's handed-off thread (`almanac thread list` shows it). Arms the session onto that thread and clears an earlier off; after a new session id, the first director call re-arms it.
Then `almanac thread add-packages <name> <blueprint> [<blueprint> ...]` for each blueprint in scope (for `all`, each blueprint when its first `run-package` arrives); at `done`, archive the thread if it is done (see the `done` row).
Every dispatch prompt carries one line `Ledger: .ccpraxis-local-data/blueprints/<blueprint>/packages/<package>.md` (the `blueprint` and `package` of `run-package`, data-dir-relative).
With more than one package in flight, a dispatch without exactly one such line naming an in-flight package is denied, and the denial lists the valid lines.
Never dispatch with `subagent_type: fork`; launch a fresh subagent with a self-contained prompt instead.
Before a turn ends with background workers or a pause running: `butler-hold <id> [<id> ...]` with `run_in_background: true` only when `butler-continuity status` shows `holder: none`; while one is already running, run `butler-hold <new id>` in the foreground instead, which extends it and returns at once.
When the holder exits, act on its report and hold again for ids still running.
At `done`, at `pause-long`, or when the operator says stop: `butler-continuity off --reason '<what is done>'`.
A denied stop prints commands carrying a stop token; run them as printed.
On `ac-stand-down`, step (c): `butler-continuity off --reason 'AC power lost: stood down until AC returns'`; if it refuses because a thread task is `doing`, set that task `pending` and run it again. Never `butler-hold` the AC monitor: continuity is off.
When the AC monitor exits 0 or 2: `butler-continuity on --thread <your thread> --role driver --goal '<what this run is for>'`, then `next`.
<!-- continuity:end -->

## Preflight

Run `perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-preflight.pl"` once, before the loop. Non-zero exit → stop and surface the itemized report. (Host is a supported platform; an unsupported environment = stop — butler's env-support policy.)

## The director loop

Call `bp-drive-next.pl next --scope <scope>` → dispatch the returned action **by name**. The director emits exactly one action per call; execute it and call `next` again.

> **Data root (project-anchored).** The director resolves the blueprint data root the same way `bp-lib.sh` does: `$CCPRAXIS_DATA_DIR` if set, else `<project root>/.ccpraxis-local-data` (project root = `$BP_PROJECT_ROOT` → git top-level → walk-up from cwd for `.ccpraxis-local-data`). It is **never** plugin/script-relative, so a marketplace install resolves the *project*, not the plugin dir. If it can't find a `blueprints/` dir it **fails loud** (nonzero exit, clear stderr) rather than reporting a false `done`. If you ever hit that, export `CCPRAXIS_DATA_DIR=<project>/.ccpraxis-local-data` and re-invoke.

| `action` | Session behavior | Next director call |
|---|---|---|
| `need-order` | JUDGE the blueprint order over `candidates` (dependencies / risk / value — a Claude judgment, Decision #3), then persist it. | `bp-drive-next.pl record-order <bp> [<bp> …]`, then `next` again |
| `run-package` | Set the ledger to `running`, dispatch the package's next pipeline step per **`coordinator-protocol` VERBATIM** with its `Ledger:` line, and verify each worker's result on disk. When that worker runs in the background, call `next` again in the same turn; the director may hand out another disjoint package. A `run-package` for a package already in flight means no dispatch was bound to it for 30 minutes: dispatch its next step. | `next` again |
| `pause` (reason=`usage`) | Wait **token-cheaply** until `action.until_epoch` with one background Bash call that sleeps until that epoch, held as described in Continuity and dispatch. Never busy-poll. | `next` again (after it finishes) |
| `pause-long` (reason=`usage`) | The usage window reopens more than 12 h out (`action.until_iso`), so this session ends instead of waiting: no background sleep, no holder (no report-first step: waiting for one needs a holder, which this action rules out). Write the handoff first: stop (`TaskStop`) any worker of yours still running, and stop the holder's background task if one is running; close each stopped worker's dispatch-log record with `bp-dispatch-log.pl finish --id <id> --status interrupted`, and note any refused call from `bp-denials summary` against a stopped worker so the recorded interruption reason is accurate. In every in-flight package's ledger append an attempt-log entry (step reached, uncommitted files from `git status`, each stopped worker's step marked interrupted by the usage pause, any such refused call) and set `## Next action` to the concrete step a fresh session resumes with. Then report per blueprint what is done and what is pending, each in-flight package with its next action, every decision batched for the operator, and when to re-invoke `/butler:drive-solo` (after `until_iso`) — report, then, in that same response turn, turn continuity off (see Continuity and dispatch) with a reason naming the pause end and that the handoff is written; the report is the last text. Ignore any holder report or PROMPT line that arrives after continuity is off. | *(none — session ends; the operator re-invokes after `until_iso`)* |
| `stop` (reason=`token-refresh-failed`) | **Genuinely terminal:** the director already tried and failed to refresh the token (via `bp-token-keeper.pl`). Tell the user to `/login` and re-invoke `drive-solo`; add to the end-batch (Decision #15). NOT an auto-resume. | *(none — stop; user re-invokes)* |
| `blueprint-done` | RE-EVALUATE the still-`pending` blueprints' validity (semantic Claude judgment, Decision #3/#4/#17); PARK the stale/moot ones. Then report the archive in one line: `archived` true means it was filed into `_archive/`; false quotes `archive_detail` (a "deferred:" or "archive failed:" one is retried by later `next` calls, nothing to do). Unrelated to the blueprint-level `park`. | `bp-drive-next.pl park <blueprint> [--needs-operator] <reason…>` for each stale bp, then `next` again |
| `in-flight` | Nothing new can start yet; the packages named in the action's `inflight` key are still being driven (use `running` when the key is absent). Any listed package with no worker of yours running (after `/clear`, a crash or a new session) is resumed from its ledger per coordinator-protocol "Resumption". Otherwise end the turn waiting on your workers (see Continuity and dispatch). It is never completion. | `next` again after a worker returns |
| holder prints `PROMPT <agent>: <message>` | A worker is stuck at a permission prompt that no hook can answer. If `<agent>` is a real subagent id, `TaskStop` that id. If `<agent>` is `main` (the routine case, per Decision 40 — a main-session prompt has no task id to `TaskStop`), instead stop or redispatch whatever worker(s) are actually in flight for the package. Either way, redispatch the same step with guidance that avoids the refused call; `bp-denials summary` lists what auto mode refused. | `next` again |
| `done` | Present ALL batched decisions/parks in ONE pass (Decision #5): per-blueprint done/total, every accumulated park with its one-line decision + verify command, any governance-degraded note, any relogin. Then run `almanac thread archive-if-done <name>` on your own thread (the `thread:` line of the continuity status names it); it archives only when every task is done, a linked package counting as done when its ledger says done or dropped. Then, as the LAST act, turn continuity off (see Continuity and dispatch). | *(none — run settled; stop)* |
| holder prints `ACLOSS …` (exit 4) | AC power has been lost past the 5-minute grace period (package 11, tooling-backlog). Call `next` now; it returns `ac-stand-down` below. | `bp-drive-next.pl next` |
| `ac-stand-down` | **AC power lost — stand down, in one turn.** (a) SendMessage each running worker: *"AC POWER LOST - STAND DOWN NOW. The host is on battery and will be allowed to sleep. Do not start another tool call or verification cycle. If a call is in flight, let it finish, then reply immediately with your report: what you changed, each file's state, what you were doing and how far it got. Do not try to fix anything further."* **Do not `TaskStop` workers** — only `TaskStop` a usage-pause `sleep` task. (b) In each in-flight package's ledger, append an attempt-log entry with the time, the step, and the signalled worker ids; `## Next action` stays the concrete step to resume. (c) Turn continuity off as the continuity block above says for `ac-stand-down`. (d) If the action's `monitor_live` is false, start `perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-ac-watch.pl" monitor --data-dir <action.data_dir>` with `run_in_background: true` — **always pass `--data-dir <action.data_dir>`** (the `ac-stand-down` action's own `data_dir` field: your Bash tool has neither `CCPRAXIS_DATA_DIR` nor `BP_PROJECT_ROOT` set, so without it the CLI cannot resolve a data dir at all) — and do not hold it, because continuity is off. End the turn. | *(none this turn — the monitor's exit wakes the session)* |
| Woken while stood down (`bp-ac-watch.pl status --data-dir <your data dir>` shows phase `standing-down` or `monitoring`) | Record any returned worker: run `perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-dispatch-log.pl" finish --id <id> --status interrupted --note …` and add a ledger attempt-log entry. Never call `next`, dispatch, or re-arm. If `monitor_live` is false, start the monitor as in the `ac-stand-down` row (same `--data-dir`). End the turn. | *(none this turn)* |
| Monitor exits 0 or 2 | AC is back (0) or the probe failed 10 times in a row and the monitor is resuming fail-open (2). Re-arm as the continuity block above says, then `next`. A stood-down worker that is still running is held and waited on, never re-dispatched over; a worker that returned is reconciled from disk per coordinator-protocol "Resumption". | `bp-drive-next.pl next` |
| Monitor exits 3 | Another `bp-ac-watch.pl monitor` is already live. End the turn. | *(none this turn)* |
| Monitor exits 1 (usage error / no data dir) or 143 (killed by a signal, e.g. the session or host ended) | The monitor stopped without an AC verdict — not resolved, not another instance live. Run `perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-ac-watch.pl" status --data-dir <your data dir>`. If the phase is still `standing-down` or `monitoring`, restart the monitor (same `--data-dir`) — on exit 1 this means the `--data-dir` value itself was missing or wrong; re-read it from the `ac-stand-down` action or the holder's `ACLOSS` context first. If the phase is `reconnected` or `ac` instead, follow the exit-0 resume row. | depends on the restored phase |

> The **governor** verdict (`bp-usage-gate.pl verdict`) that produces a `pause` is fetched INTERNALLY by the director — the session never runs it (Decision #13).
> **Keep-awake** is a director-managed side-effect, never a session action (Decision #7).
> A merely-**stale** token (still refreshable) is recovered **transparently** before any action ever surfaces to the session — the director attempts the refresh on-demand inside `next` the moment the governor reports the token floor, and proceeds silently on success. No session-visible row exists for that path by design; `stop`/`token-refresh-failed` above fires only once that refresh attempt has actually failed.

## Never end a turn with nothing scheduled

**A driver turn may end for exactly three reasons: something will wake the session,
the run is settled, or the action is `pause-long`** (the session is handing off and
ending on purpose; see the `pause-long` row above). Nothing else.

Something will wake you when the turn dispatched a subagent, or started a
`run_in_background` Bash call — both notify you and the loop resumes. A **foreground**
Bash call schedules nothing: it returns into the same turn. So a turn whose last act
was a ledger write, ending with text that promises the next step, is a **dead stop** —
the run halts mid-package while *appearing* finished, and the operator only discovers
it by asking. That is the worst failure an unattended run can have.

The one Stop gate refuses an armed driver's stop unless a holder is waiting on running
work (see Continuity and dispatch), and a foreground call schedules nothing.

- **Do the next thing in the same turn, rather than announcing it.** "Moving on to X"
  followed by a turn end is precisely the shape the gate exists to catch.
- Record the ledger **and then** dispatch, in one turn. The ledger write is not a
  stopping point.

## Wedged workers

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
     --budget-seconds <this dispatch's own expected budget>
```

A wedge is noticed when the holder exits and prints an id as `still running (last activity
<time>)` well past this dispatch's own expected budget, or `unknown`; either, or
`bp-dispatch-log.pl elapsed --id <id>` showing `over_budget: true`, is what triggers the next
step.

**Step 2 — before killing, and before waiting again: interrupt and ask for a
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
escalate is a judgment call that stays with you.

A holder report of `<id> unknown`, or `still running` with a last activity long past where
you have independent reason to believe the worker died, is not a prompt to wait longer. A
wait that has already failed once does not improve by being repeated: **re-dispatch the
wedged worker instead**. And treat an
empty or narration-shaped worker result as a **dead dispatch**, not a finding of
"nothing" — a worker that runs out of turns returns its last narration, which reads
exactly like success.

## Lean-context

> **lean-context** doctrine (Decision #6): the driver reads only ≤15-line worker summaries, ledgers, and the director's JSON. Workers do the heavy reading. The harness auto-summarizes; the run is idempotent — the director is stateless-from-disk, so a summarize or re-invoke resumes losslessly. Old decisions stay decided.

## Batch

> **batch** doctrine (Decision #5): all parks and human decisions accumulate on disk (director-recorded) and surface in ONE final pass at `done`. No mid-run questions except a truly-blocking one. `park` writes `status: parked` and the reason into the blueprint's own blueprint.md (`--needs-operator` also files an inbox item); unparking is `bp-blueprint.pl set-meta --file <blueprint.md> --field status --value audited`, which closes that item.

## Keep-awake (director-managed)

> The director auto-starts the wake-lock when active work or a pending usage-resume begins, and auto-stops it when the run settles. In sandbox, keep-awake is a no-op. The session does nothing (Decision #7/#19).

## Host or sandbox

> Runs identically host OR sandbox — perl + hooks only, no platform-specific spawns in the prompt (Decision #8).

## Commit mechanics

Commits are yours (workers and coordinators are hook-blocked from git): atomic, one commit per coherent deliverable, project CLAUDE.md policy, no `Co-Authored-By`.

## Filing a ccpraxis tooling bug

You dispatch coordinators and read their reports — when the tooling underneath them (a butler
script, hook, template, or skill) misbehaves, blocks legitimate work, or reports success it did not
achieve, file it yourself:

```bash
perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl file \
  --title "one line, names the defect not the symptom" \
  --severity high --area butler \
  --body -   <<'REPORT'
...your report...
REPORT
```

**When NOT to file:** a package's own bug — the feature the blueprint is building — is not a
ccpraxis tooling bug; that is an ordinary defect, fixed through the pipeline's implementer loop,
never filed here. See `plugins/almanac/skills/bug-report/SKILL.md`'s "Before you file" section (is
it actually ccpraxis, is it already filed via `almanac-bug.pl list`, can you fix it yourself)
rather than re-deriving that check.

## Self-modifying blueprints

> **self-modifying** blueprints — blueprints that edit butler's own executor, hooks, or skills — must be driven HERE (interactively), NEVER as a self-modifying dispatch-fleet. The running session keeps its already-loaded instructions, so the mid-run rewrite is safe. Do NOT re-read this SKILL.md file mid-run (Decision #11/#20).

## Idempotent start-or-continue

Re-invoking re-reads the ledgers and the director's on-disk state, skips verified `done` work, and resumes the rest. Old decisions stay decided. There is no separate resume verb.
