---
name: resume
description: Resume a blueprint after an interruption — session compaction, usage-limit pause, container restart, killed coordinators, or simply the next day. Applies the warm-resume vs cold-start economics automatically. Use whenever the user says to resume, continue, pick up, or recover a blueprint or its packages.
argument-hint: [blueprint]
---

# /butler:resume

You are the **orchestrator**. First read `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator-protocol/SKILL.md` — section *Resume* is binding.

Steps:

1. Dry run: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/bp-resume-sweep.sh" $0` — show the user the plan (RUNNING / DONE / NEEDS ATTENTION / PENDING / DEAD→warm-resume / DEAD→cold-start).
2. Apply: rerun with `--apply`. The economics are baked into the sweep: warm `--resume` only within `BP_RESUME_THRESHOLD_MIN` (default 60) of the last ledger touch — beyond the cache window, resuming replays the entire transcript at full cost, so a ledger cold-start is an order of magnitude cheaper. Don't override the policy "to be safe"; the ledger is the safety.
3. NEEDS-ATTENTION rows: read those ledgers' Escalation + Next action sections, fix what's yours (re-scope, corrected relaunch), batch genuine decisions to the user. Old decisions stay decided — only new blockers get raised.
4. PENDING rows are wave-scheduling, not recovery: hand them to `/butler:launch` logic if their dependencies are met.
5. Re-enter the monitoring loop from `/butler:launch`.
