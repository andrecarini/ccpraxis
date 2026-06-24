---
name: drive-solo
description: Execute a blueprint in THIS interactive session as a single driver with one flat layer of bp-* worker subagents (no detached coordinators) — idempotent start-or-continue, runnable on host or sandbox. Use when the user wants to run, continue, drive, or work through a blueprint's packages interactively in the current session (the host-safe / single-session alternative to the headless dispatch-fleet). Absorbs the old interactive blueprint:resume role.
argument-hint: <blueprint> [package]
---

# /butler:drive-solo

> **Skeleton — full implementation lands in package A2 of the `unattended-run-overhaul` blueprint.**

`drive-solo` is butler's **single-session** execute verb (Decision #2/#4): it loads a blueprint's
ledgers and works packages to terminal states **in this very session**, dispatching the `bp-*`
workers as a flat, one-level `Task` layer — no detached `claude -p` coordinators, so it needs no
sandbox skip-permissions and runs **host or sandbox**. It is *start-or-continue* (the warm/cold
sweep folds in); there is no separate `resume`.

It is the counterpart to **`/butler:dispatch-fleet`** (the headless multi-coordinator fleet, sandbox-only).
Two verbs exist only because of the subagent-depth limit: `dispatch-fleet` gets depth via detached
coordinators; `drive-solo` accepts a flat one-level worker tree and runs anywhere. It absorbs the old
interactive `/blueprint:resume` working-document role (which has been removed — `blueprint` is now
plan-only).

**Until A2 lands**, this skill does no work. When invoked, report that drive-solo is not yet implemented.
For headless execution right now use `/butler:dispatch-fleet <name>` inside the sandbox, or
`/butler:status <name>` to inspect state — do not attempt to execute packages from this skeleton.
