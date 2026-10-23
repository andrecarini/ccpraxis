---
name: pending
description: Lists EVERYTHING pending across every registered project -- for each statusline counter the items behind it (unanswered inbox questions, blueprints' unfinished packages, threads' open tasks, open todos per project and global), then every open bug -- and names the projects that are clear. Use when the operator asks "what's pending", "what's open everywhere", or about the statusline counts. Skip for one project in depth (use /sitrep).
user-invocable: true
allowed-tools: Bash, Read
---

# /pending

This is every item behind every statusline counter, across every project registered on this
machine: unanswered inbox questions, blueprints' unfinished packages, threads' open tasks, open
todos (per project and global), then every open bug — plus which projects have nothing pending at
all.

Run the pinned command below exactly as written — it resolves the almanac plugin's `bin/` shim on
the Bash tool's PATH and steps to the sitrep script alongside it, which works on the host and in a
sandbox, at any skill mount depth:

```bash
perl "$(dirname "$(command -v almanac)")/../scripts/almanac-sitrep.pl" pending
```

If this fails with `Can't open perl script` or `command -v almanac` printed nothing, the almanac
plugin is not enabled in this session — say so, and stop. Do not go hunting for the script by any
other path.

Show the script's output to the operator verbatim. It IS the report — do not summarise it away.
This command only reads: never act on another project's stores from here.
