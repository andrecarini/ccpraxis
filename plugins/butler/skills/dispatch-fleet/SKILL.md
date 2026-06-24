---
name: dispatch-fleet
description: Execute a blueprint as a headless multi-coordinator FLEET (sandbox-only) — start the deterministic, token-free orchestrator script that watches, launches, relaunches, governs usage, keeps the OAuth token alive, and auto-resumes, then hand off to /butler:reporter to observe and answer decisions. Use when the user wants to run, start, kick off, dispatch, or continue a blueprint unattended at scale, or after /blueprint:create when execution should begin. Idempotent start-or-continue (no separate resume). The host-safe single-session alternative is /butler:drive-solo.
argument-hint: <blueprint>
---

# /butler:dispatch-fleet

Start (or continue) the **headless fleet** for a blueprint. First read `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-protocol/SKILL.md` — the **Cast** and **Dispatch a fleet** sections are binding.

The model: a **deterministic, token-free orchestrator script** (`bp-orchestrator.pl`) does ALL of the driving — it watches coordinators, launches newly-ready packages off the DAG, relaunches crashed/wedged ones, polls usage and pauses *below* the ceiling, keeps the OAuth token alive, and auto-resumes after a reset. **You do not run a monitoring loop**; there is no "you are the orchestrator" session anymore. Your job here is just to *start* it and hand the user to the reporter.

Sandbox-only: the fleet is detached `claude -p` coordinators (`setsid`/`nohup`/`flock`), which only work inside the rootless-Podman sandbox. `bp-orchestrate.sh` refuses on the host.

## Steps

1. **Prerequisite — a blueprint exists, audited, with real ledgers.** Confirm `<data>/blueprints/$0/blueprint.md` plus `packages/<pkg>.md` ledgers exist with non-empty `write_set` frontmatter. If it is missing, unaudited, or has empty write sets, stop and send the user to `/blueprint:create` (or `/blueprint:manage audit`) — never launch an unscoped fleet.

2. **Start (or continue) the orchestrator:**
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-orchestrate.sh" $0
   ```
   It is **idempotent start-or-continue**: it refuses on the host, detaches the deterministic orchestrator, and — if one is already live (its `runs/.orchestrator` marker PID is alive) — just reports that and exits. The orchestrator's own resume-sweep folds in warm/cold recovery of any interrupted coordinators, so there is **no separate resume verb**.

3. **Record the launch** in `blueprint.md`: set `status: running`, refresh `last_updated`. (The per-package status rows are now maintained by the orchestrator + harvest-judge; you set the blueprint-level fields.)

4. **Hand off to the reporter.** Tell the user the fleet is running **unattended** and that they observe progress and answer queued decisions via:
   ```
   /butler:reporter $0
   ```
   Closing this session does **not** stop the run — the orchestrator is detached and survives on the container's dashboard heartbeat. Recovery after a container restart is automatic on the next `bp-orchestrate.sh` (it continues, never duplicates).

> **Not this verb?** For a single interactive session with a flat worker layer (host-safe, no detached coordinators), use `/butler:drive-solo $0`. To just check state without touching anything, `/butler:status`.
