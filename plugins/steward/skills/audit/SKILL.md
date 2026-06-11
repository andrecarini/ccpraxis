---
name: audit
description: Audits the ccpraxis repo itself — fans out read-only subagents (per-system red-team + code review, cross-cutting integration checks, fresh-user persona, fresh-Claude install simulator, sandbox-gated test runner) and aggregates their findings into a dated report at `<repo>/.ccpraxis-local-data/audits/<ISO-timestamp>.md`. User-invocable only (no proactive triggering) — invoke when the user explicitly runs `/steward:audit`, typically as a health check before releasing changes to ccpraxis's skills, plugins, or integration surface.
user-invocable: true
allowed-tools: Bash
---

# /steward:audit

Audits the ccpraxis repo (`~/.claude/ccpraxis/` or wherever the user is working on it) for correctness, drift between docs and code, and onboarding clarity. Read-only by design — the audit must never modify the repo it audits.

## Intended flow (full implementation, not v0)

The persistent plan (migrated to the archived blueprint `.ccpraxis-local-data/blueprints/_archive/steward-plugin/blueprint.md`) is the source of truth. Summary:

1. **Discover subsystems** — enumerate every `skills/*/` and `plugins/*/` from the repo root, parse each one's manifest (`SKILL.md` description, `plugin.json` description, `ccpraxis-install.pl` if present) into a per-subsystem fact sheet.
2. **Detect sandbox** — read the marker (env var or file) set by `claude-sandbox`. If absent (host run), skip the test-runner pass and record a finding instead.
3. **Fan out subagents in parallel** via the `Agent` tool, in a single message with multiple tool calls:
   - **Per-subsystem pair** for each discovered skill/plugin: one red-team subagent, one code-reviewer subagent, scoped to that subsystem's files and declared contract.
   - **Cross-cutting pair** scoped to the integration surface (`settings.json` invariants, README ↔ skill/plugin description drift, `enabledPlugins` ↔ `marketplace.json` consistency, `install.pl` hook discovery, global CLAUDE.md rules vs actual skill behavior).
   - **Fresh-user persona** restricted to README + top-level CLAUDE.md + skill descriptions only — must NOT read implementation files.
   - **Fresh-Claude install simulator** given the README's "Instructions for Claude" section plus a fixture prompt; produces a step-by-step walkthrough WITHOUT running or writing anything.
   - **Test runner** (sandbox-only) discovers and runs any tests in the repo.
4. **Aggregate** — write the combined report to `<repo>/.ccpraxis-local-data/audits/<ISO-timestamp>.md` (machine-local, gitignored, vault-synced — same root as `blueprints/`) and print a one-screen summary with severity counts and section anchors.

All subagents are read-only (no `Edit`/`Write`/destructive `Bash`) except the test runner, which is sandbox-gated.

## v0 behavior (current)

**The orchestrator above is NOT yet implemented.** This skill is currently a scaffolding placeholder so that the slash command, plugin registration, and marketplace plumbing can be verified end-to-end before the audit logic is built.

When invoked, output exactly this message to the user and then stop — do NOT attempt to discover subsystems, spawn subagents, or write a report:

> `/steward:audit` v0 — scaffolding placeholder only. The audit orchestrator (subsystem discovery, parallel subagent fan-out, report aggregation) is not yet implemented. Progress is tracked in the archived `steward-plugin` blueprint (deliverables 2–8). Re-run after a future session lands the orchestrator.
