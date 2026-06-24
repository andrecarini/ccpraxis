---
name: reporter
description: Turn THIS Claude session into the reporter for a blueprint run — sync to current on-disk state, detect and attach to a live unattended run, and surface/relay the decisions that need a human. Use when the user wants to check on, attach to, observe, or talk to a running (or finished) blueprint, asks "how's the run going?", or wants to answer a queued "needs-you" decision. The interactive front door to a deterministic-orchestrator run.
argument-hint: [blueprint]
---

# /butler:reporter

> **Skeleton — full implementation lands in package A7 of the `unattended-run-overhaul` blueprint.**

The **reporter** is the interactive **Claude** front door to an unattended run (Decision #5/#26). It is a
*role*, not a window: a plain Claude session becomes the reporter when the user runs this skill, which
**syncs the session to current state** (reads the blueprint + registry + ledgers + the `runs/needs-you/`
decision-queue — a bounded snapshot, never an accumulating transcript). Two branches:

- **No live run** → list blueprints + statuses; offer to `dispatch-fleet` / `drive-solo`.
- **A live run** → detect it (registry / running-orchestrator marker / busy-lease) and offer to **attach**
  ("there's a run on X — N done, M running, K waiting on you — attach?"). Once attached it answers status
  from disk, surfaces queued human-intent decisions, and writes answers back to unblock packages. It
  arms a token-free blocking watcher (`bp-wait-for-decision`) and auto-announces a freshly-queued
  decision on its return, then re-arms — no token-burning poll loop. Closing the window never affects the
  run; re-running `/butler:reporter` re-attaches.

The reporter does **not** drive the run — the deterministic **orchestrator script** does the watching with
no Claude. The reporter only observes and relays.

**Until A7 lands**, this skill does no work. For run status right now, use `/butler:status`. When invoked,
report that the reporter is not yet implemented and point the user there — do not attempt to attach or
relay from this skeleton.
