---
name: sitrep
description: Reports the CURRENT project in full from what is on disk -- every blueprint's packages, bugs opened and closed, threads, todos, inbox items with their questions, fleets -- plus what changed since the last /sitrep and where the 5-hour/7-day usage went. Use when the operator says "sitrep", "where are we", "what's the state of this project", or checks in after time away. Skip for every project at once (use /pending).
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob
---

# /sitrep

This is the complete state of the CURRENT project, read straight from disk: every blueprint's
packages, threads, todos, open inbox questions, fleets and bugs, rendered as terminal tables — and
the diff since the last `/sitrep`, plus where the 5-hour/7-day usage has moved. It is a report, not
test health, and it is complete by default.

Run the pinned command below exactly as written — it resolves the almanac plugin's `bin/` shim on the
Bash tool's PATH and steps to the sitrep script alongside it, which works on the host and in a
sandbox, at any skill mount depth, for any project:

```bash
perl "$(dirname "$(command -v almanac)")/../scripts/almanac-sitrep.pl" project --session-id "${CLAUDE_SESSION_ID}"
```

If this fails with `Can't open perl script` or `command -v almanac` printed nothing, the almanac
plugin is not enabled in this session — say so, and stop. Do not go hunting for the script by any
other path.

Show the script's output to the operator verbatim. It IS the report — do not summarise it away.

Then, under a heading **Not on disk**, add what no script can see:

- work this session did that never became a durable record (ad-hoc fixes, processes stopped,
  settings edited, things decided in chat);
- any subagent that is live right now, and what it is doing;
- this session's own judgment of what needs the operator and what happens next.

Each inbox item shown above is answered with `almanac inbox answer <id>`.
