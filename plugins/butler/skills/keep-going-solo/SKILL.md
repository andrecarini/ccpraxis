---
name: keep-going-solo
description: Execute EVERY audited blueprint (or a given set) back-to-back in THIS interactive session as a single self-governing driver — host-safe, no sandbox, no detached coordinators. Wraps /butler:drive-solo in an outer loop that holds the machine awake, polls usage and sleeps below the ceiling to survive usage-limit windows, batches every parked decision to the end, and is idempotent start-or-continue. Use when the user wants to walk away and have all blueprints driven to done (or to a batched set of decisions) on the host, or says "keep going", "run all the blueprints", "do them all while I'm gone".
argument-hint: "[blueprint ...]  (default: all audited/non-terminal blueprints)"
---

# /butler:keep-going-solo

You are the **persistent solo driver**. `/butler:drive-solo` drives ONE blueprint and stops; **keep-going-solo drives them ALL, in order, without stopping** — holding the machine awake, governing its own usage so it survives 5h/7d limit windows, and deferring every human decision to a single batch at the end. It is the host-safe, single-session answer to "run everything unattended while I'm gone" — the sandbox-free counterpart to the fleet's deterministic orchestrator.

**Read first (in this order):**
1. `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-protocol/SKILL.md` — the **Cast**, so you know precisely how this differs from the fleet.
2. `${CLAUDE_PLUGIN_ROOT}/skills/drive-solo/SKILL.md` — the per-blueprint driver you are looping.
3. `${CLAUDE_PLUGIN_ROOT}/skills/coordinator-protocol/SKILL.md` — the **8-step pipeline, ledger discipline, worker-dispatch contract, disk-is-truth** you follow per package.

keep-going-solo adds exactly three things on top of drive-solo: **(A) an outer multi-blueprint loop**, **(B) a keep-awake lifetime**, and **(C) in-session usage governance with sleep-through-the-limit**. Everything about how a single package is scouted/spec'd/tested/implemented/reviewed is unchanged — inherit it from drive-solo/coordinator-protocol verbatim.

## What this is NOT (the honest boundary)

- **NOT detached, NOT headless, NOT skip-permissions.** All work is `bp-*` `Task` workers in THIS interactive session, under normal permissions / the auto-mode classifier. That is the containment on the host (the write-set **hooks are inert in an interactive session** — `lib.sh:bp_hook_gate` only arms inside a `bp-launch.sh` coordinator process; solo containment = scoped worker prompts + your disk-is-truth verification + the permission layer). A blueprint that must run truly hands-off and machine-durable belongs in the sandbox via `/butler:dispatch-fleet`.
- **NOT machine-durable.** This run lives only as long as THIS session/terminal. A reboot, a terminal close, or the Claude process dying ends it. Recovery is not automatic — someone must re-run `/butler:keep-going-solo` (idempotent; it resumes). For crash-durable unattended runs, that is `dispatch-fleet`.
- **NOT a token-keeper.** It cannot refresh the OAuth token in-session. If the token drops under the floor it stops cleanly and asks for a re-login (RELOGIN below).

**Preconditions for an unattended run (state them to the user if you are starting one):** the terminal stays open; the machine is on **AC with the lid open** (keep-awake asserts `ES_DISPLAY_REQUIRED` but cannot beat a lid-close, power-button, or battery policy); and the session permission posture actually lets workers act without a human (otherwise it will stall on a prompt — which becomes a park, not a crash).

## Steps

### 0. Preflight + resolve the set
1. Run `perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-preflight.pl"`. Non-zero → stop and surface its report (the host itself is supported; do not start on an unsupported environment — Decision #29).
2. Resolve the blueprint set. `$ARGUMENTS` (if given) is a space/comma list of blueprint names, driven **in that order**. If empty: Glob `<data>/blueprints/*/blueprint.md` (skip `_archive/`), read each `status`, and take every blueprint that is **`audited` or has any non-terminal package** (skip `done`/`archived`). Present the resolved order to the user before starting.
3. **Ordering.** Blueprints run strictly one at a time, so correctness never depends on order (a later blueprint that touches a file an earlier one changed simply builds on the earlier commit). Absent an explicit arg order, prefer **smallest / lowest-risk first** so early completions bank durable progress before any long pole.

### 1. Start keep-awake (once)
- PID file: `<data>/.keep-going-solo/keepawake.pid` (`mkdir -p` its dir first).
- If the file exists and names a live process, reuse it. Otherwise launch the sandbox wake-lock, **detached so it survives across your tool calls** — start it as a background process:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<repo>/plugins/sandbox/scripts/keep-awake.ps1" -PidFile "<data>/.keep-going-solo/keepawake.pid"` (launch with the Bash tool's `run_in_background`).
- The wake-lock releases automatically when that process is killed (`ES_CONTINUOUS` is thread-tied). You are responsible for killing it at teardown (Step 4).

### 2. The outer loop — for each blueprint, in order
For each blueprint:

  **a. Usage gate — the hard rule.** Run `perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-usage-gate.pl"` **immediately before dispatching EACH `bp-*` worker `Task`** (scout, architect, test-writer, implementer, reviewer, redteam, ui-prober) — not once per blueprint, not once per package. This **overrides `drive-solo`'s silence on usage**: a single package can dispatch a dozen workers and burn several percent, so gating only at package/blueprint boundaries is exactly how the hard wall gets hit mid-package. The check is a sub-second local poll; call it every time. Branch on the verdict:
  - **OK** → proceed with the dispatch.
  - **PAUSE** (`window=… resets_at_epoch=… estimated=… …`) → you are over the **soft ceiling** (5h 80% / 7d 85%, below the fleet's 85/90 hard walls). **Do not dispatch; wait token-cheaply until the window resets, then re-gate and resume.** Wait via a low-cost mechanism — NEVER a busy-poll, NEVER by pushing past the ceiling: use the **Monitor** tool with an until-condition that re-runs the gate and returns when it prints `OK` (equivalently, when now ≥ `resets_at_epoch`); if this run is wrapped in `/loop`, `ScheduleWakeup` to `resets_at_epoch` (+ small jitter) instead. `estimated=1` means the reset time was unparseable and the epoch is a conservative `now+3600` — treat it identically (sleep to it, then re-gate); it self-corrects. The soft-ceiling headroom is what keeps these tiny wake-checks from ever hitting the wall. Log the pause + reset to the run-log.
  - **RELOGIN** (`token_life_h=…`) → the OAuth token is under the floor and you cannot refresh it in-session. **Hard stop:** park the current package with a concrete Next action, tear down keep-awake (Step 4), and put "re-login required (`claude` / `/login`), then re-run `/butler:keep-going-solo`" at the top of the batched report.
  - **UNAVAILABLE** / **CREDS** → telemetry unreachable / creds unreadable. Governance is **degraded, not fatal**. Retry the gate **up to 3 times, ~30 s apart** (a transient `000`/`429` is common). If it still fails after 3 retries, **proceed degraded for the rest of this blueprint** — log it once, and do **not** retry again until the next blueprint boundary. Record in the final report that this stretch ran without the sleep-through net (it could hit a hard wall unguarded).

  **b. Drive the blueprint** exactly as `/butler:drive-solo <bp>` prescribes: re-establish context, compute the ready set off the DAG, drive packages one at a time in dependency order following `coordinator-protocol`; disk is truth (verify every worker's outputs and re-run its validation yourself); honor the 4-attempts-on-the-same-failure cap → `blocked`; **park (never guess)** genuine user-intent decisions.

  **c. Never global-halt on a park (Decision #13).** A parked/blocked package does not stop the run: record it and move to the next ready package. When a blueprint has no more progressable packages (all remaining are parked/blocked or gated behind one), move to the **next blueprint**. Accumulate **every** park/block across **every** blueprint for the end batch.

  **d. On blueprint completion** (all packages `done`): harvest-verify each ledger's Outputs on disk, flip the blueprint `status: done`, refresh `last_updated`, add a one-line closing note. Commits are yours (project CLAUDE.md; atomic, one per coherent deliverable, **no `Co-Authored-By`**).

### 3. Durable run-log
Maintain `<data>/.keep-going-solo/run.md` as you go: start time, keep-awake PID, resolved blueprint order, and an appended line for each **pause** (window + reset), each **package terminal transition**, each **park**, and each **governance-degraded** event. This is the trail the user reads on return even if your context was summarized mid-run.

### 4. Termination + the single batch
Stop when every blueprint in the set is `done` **or** has only parked/blocked packages left (nothing progressable without a human), or on a RELOGIN/preflight hard-stop. Then:
1. **Tear down keep-awake:** `taskkill //PID <pid> //F` (Git-Bash double-slash) using `<data>/.keep-going-solo/keepawake.pid`, then remove the file. Confirm the lock is released.
2. **Present ONE batched report** — this is the "batch user input to the end" contract:
   - per-blueprint **done/total**;
   - the **full list of accumulated parks/blocks**, each with its one-line decision, its ledger `## Next action`, and a verify command;
   - any **governance-degraded** windows and any **RELOGIN**.
   The user answers all queued decisions in one pass, then re-runs `/butler:keep-going-solo` to continue.

## Idempotent start-or-continue
Re-running `/butler:keep-going-solo` re-reads every ledger, **skips verified `done` work** (Outputs confirmed on disk), resumes non-terminal packages from their Next action, and re-raises only still-open parks. Old decisions stay decided; keep-awake and the run-log are reused if already live. There is no separate resume verb.

## Self-modifying blueprints (Decision #22)
A blueprint that edits butler's own executor/hooks must run **here or in a plain interactive session — never as a self-modifying `dispatch-fleet`**. keep-going-solo (like drive-solo) is a sanctioned path for that case: you are the driver, so a mid-run edit to butler's scripts does not rewrite a live orchestrator out from under itself. (These blueprints edit the **sandbox** plugin, not butler — so this is a note, not a constraint here.)
