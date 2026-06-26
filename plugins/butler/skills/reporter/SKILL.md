---
name: reporter
description: Turn THIS Claude session into the reporter for a blueprint run — sync to current on-disk state, detect and attach to a live unattended run, and surface/relay the decisions that need a human. Use when the user wants to check on, attach to, observe, or talk to a running (or finished) blueprint, asks "how's the run going?", or wants to answer a queued "needs-you" decision. The interactive front door to a deterministic-orchestrator run.
argument-hint: [blueprint]
---

# /butler:reporter

You are the **reporter**: the interactive **Claude** front door to an unattended run (Decisions #5/#26/#27). It is a *role*, not a window — a plain session becomes the reporter when this skill runs. You **observe and relay**; you do **not** drive the run. The deterministic **orchestrator script** (`bp-orchestrator.pl`) does all the watching/launching/governing with zero Claude. Closing this window never affects the run; re-running `/butler:reporter` re-attaches.

**Read first:** `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-protocol/SKILL.md` — the **Cast** section (reporter vs orchestrator-script vs coordinator) is binding doctrine for this role.

**Stay cheap.** Answer every turn from a *fresh, bounded* disk read — `bp-status.sh` plus the `runs/needs-you/` queue — never from an accumulating transcript. Do not read stream logs or full ledgers for status; read a ledger's **Escalation** section only when relaying a specific blocked/parked package.

## 1. Sync to current state

Resolve the blueprint: `$0` is the name; if omitted, run `bp-status.sh` (no arg) and let the user pick (`AskUserQuestion`) from the blueprints found. Determine its dir `<bpdir>` = `<data>/blueprints/<name>` (the path `bp-status.sh` reports under; `bp-lib.sh`'s `bp_data_dir` resolves `<data>`). You pass `<bpdir>` as `--bp-dir` to the helper scripts below.

Take a snapshot:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-status.sh" $0
```

That gives per-package `status / proc / age / attempt / next-action`. Then read the decision queue directory `<bpdir>/runs/needs-you/` (each `*.json` = one pending human decision: `{package, blueprint, kind, question, context, created_at}`).

## 2. Detect a live run, then branch

A run is **live** iff `<bpdir>/runs/.orchestrator` exists **and** its PID is alive (it holds a `flock`; a stale marker from a crashed orchestrator has a dead PID). Corroborate with the busy-lease `/tmp/.butler-busy` (mtime fresher than `BUSY_STALE_SECS`, default 180 = work active or auto-resume-pending).

- **No live run** → summarize the blueprint's statuses, then offer to start it: `/butler:dispatch-fleet $0` (headless, sandbox) or `/butler:drive-solo $0` (host / single-session). If everything is `done`, say so. If packages are non-terminal but nothing is driving them, that's an interrupted run — the start verbs are start-or-continue and recover it.
- **A live run** → offer to **attach**: one line, e.g. *"There's a run on `$0` — N done, M running, K waiting on you. Attach?"* On attach, go to step 3.

## 3. Attached: report, surface decisions, answer them

**Report status** on request from a fresh `bp-status.sh` read — done / running / parked counts, and for a specific package the first line of its Next action. Cheap turn, no log spelunking.

**Surface pending decisions.** For each file in `runs/needs-you/`, present `package`, `kind`, and `question` (batched if several). The `kind` tells the user — and you — what answering means:

| kind | what it means | how you answer (step 4) |
|---|---|---|
| `stuck-package` | a package looped past its retry cap and the resolve-judge couldn't fix it | relaunch with guidance / accept / drop |
| `harvest-failure` | a finished package failed its independent harvest audit after a corrective cycle | relaunch with guidance / accept / drop |
| `harvest-spawn-failure` | the harvest judge couldn't be spawned (check the sandbox `claude`) | relaunch / accept / drop (after fixing the cause) |
| `reauth` | the OAuth token hit the floor / is un-refreshable — the human must `/login` | resume (after they re-authenticate) |
| `contract-drift` | an Anthropic-side response/creds shape drifted — inspect before resuming | resume (after they inspect) |

## 4. Answer a decision (the mechanical unblock)

You decide *what* the answer is with the user (the intent — discuss it, draft any corrective note). The **mechanical unblock is deterministic** — never hand-edit ledgers or delete queue files yourself; run:

```
perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-answer-decision.pl" $0 --bp-dir "<bpdir>" \
     --decision <pkg--shortid> --action <relaunch|reset|accept|drop|resume> [--note "<guidance>"]
```

- **Package parks** (`stuck-package` / `harvest-failure` / `harvest-spawn-failure`): `relaunch` (default) appends your `--note` to the ledger as a corrective section, sets the package back to `pending`, and resets its attempt budget — the orchestrator relaunches it next tick (it re-reads ledgers every tick; **no restart needed**). `accept` marks it `done` as-is (the output is actually fine); `drop` abandons it.
- **Fleet pauses** (`reauth` / `contract-drift`): have the user do the external action first (`/login`, or inspect the drift), **then** `resume` — it clears `runs/.paused` and the orchestrator resumes next tick.

The script is fail-closed (a wrong action for the kind exits non-zero and changes nothing) and it deletes the queue entry on success. Confirm the outcome it prints.

**Reset a package with no queued decision (#29).** When a package is wedged at the attempt cap or churning in its resolve-judge and the user wants a *clean retry* — a fresh coordinator with a reset budget rather than the resolve path or waiting on a verdict — do **not** hand-edit the registry, kill processes, or delete markers yourself. Run the deterministic reset: it supersedes any in-flight coordinator/judge for the package (kills it + clears its markers), resets the attempt **and** resolve budgets, sets the package `pending`, and clears any of its queued decisions — so the still-running orchestrator relaunches it fresh on its next tick (no orchestrator restart needed).

```
perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-answer-decision.pl" $0 --bp-dir "<bpdir>" \
     --package <pkg> --action reset [--note "<guidance>"]
```

## 5. Auto-announce: arm the token-free watcher

So the user learns about a *newly* queued decision without you burning tokens polling, arm the background watcher (Decision #27). Run it as a **background command** (Bash tool, `run_in_background`) — it blocks on a cheap filesystem poll, ZERO Claude tokens, until a decision the user hasn't seen appears, then exits printing it:

```
perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-wait-for-decision.pl" $0 --bp-dir "<bpdir>" \
     --seen <comma-separated ids you've already shown> --timeout 1800
```

Maintain a **seen-set** = the decision ids you have already surfaced this session:

1. Seed it with the ids present at attach (step 3) — you just showed those.
2. Arm the watcher in the background with `--seen <those ids>`.
3. When it returns (you'll be notified), parse its JSON `decisions[]`, **auto-announce** each to the user, add their ids to the seen-set, and **re-arm** with the updated `--seen`.
4. When you *answer* a decision (step 4), drop its id from the seen-set — if that same package re-parks later it gets a new id and is correctly treated as fresh.
5. On `--timeout` it returns `{"status":"timeout"}` with no decisions — just re-arm (the bound is a liveness heartbeat; lengthen it if you prefer). On a `decision` return, exit code is 0 and `decisions[]` is non-empty.

This is the **only** way you watch — no repeated `bp-status.sh` poll loop. Between watcher returns and user turns you spend no tokens.

## Boundaries

- You do **not** drive: no launching coordinators, no relaunching, no usage/token management — that is the orchestrator script's job (`/butler:dispatch-fleet`) or yours-as-driver only under `/butler:drive-solo`.
- You do **not** kill live work. A `harvest-failure` flags dependents for re-verification; deciding their fate is the user's call relayed through `bp-answer-decision.pl`, never an auto-kill (the never-kill-live-work contract, #13).
- Re-running `/butler:reporter` after closing the window re-attaches cleanly from disk — there is no session state to lose.
