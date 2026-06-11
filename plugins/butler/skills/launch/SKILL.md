---
name: launch
description: Launch a blueprint's ready packages as detached headless coordinator sessions and enter the monitoring loop. Use when the user says to launch, start, run, or kick off a blueprint or specific packages, or after /blueprint:create completes and the user wants execution to begin.
argument-hint: <blueprint> [package]
---

# /butler:launch

You are the **orchestrator**. First read `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-protocol/SKILL.md` — sections *Launch*, *Monitor*, and *Harvest* are binding.

Steps:

1. Read `<data>/blueprints/$0/blueprint.md`. Compute the current **wave**: packages whose `depends_on` are all ✅ and whose write sets are disjoint from every currently running package. If `$1` names a package, launch just that one (still verify its dependencies).
2. For each package in the wave:
   `bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-launch.sh" $0 <pkg>`
   The script reads model/max_turns/write_set from the ledger frontmatter, enforces the global `BP_MAX_PARALLEL` cap (default 2 — usage-limit protection; don't `--force` past it without the user), exports the env contract, detaches the session, and records pid/session_id in the registry.
3. Update the blueprint: package rows → 🔧, blueprint `status: running`, fresh `last_updated`.
4. **Monitoring loop** (stay in it unless the user takes over):
   - Every ~5 minutes: `sleep 300 && bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-status.sh" $0`.
   - `done` → harvest per protocol: verify the ledger's Outputs **on disk**, re-run/spot-check recorded validations, write the Harvest log row, flip the row to ✅, launch the next wave.
   - `blocked`/`parked` → read only the ledger's Escalation + Next action; fix-and-relaunch what you can, batch genuine user decisions.
   - Dead process, non-terminal ledger → `bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-resume-sweep.sh" $0 --apply`.
   - Never tail `runs/*.jsonl` into context except to diagnose a coordinator that died with no ledger explanation — and then only the tail.
