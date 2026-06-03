---
name: audit
description: Audit the sandbox backpack — check each item's verify status (is the tool still here?) and flag items missing a rationale. Use periodically when the user says "audit the backpack", "what's stale", "check the backpack", "any cleanup needed", or after a long stretch where the agent has been installing tooling without filling in rationales. Skip on the host.
user-invocable: true
argument-hint: ""
allowed-tools: Bash, Read
related:
  - list
  - add
  - remove
---

# /backpack:audit

Walks every item in `~/.claude/backpack.json` and reports:

- `[v]` — verify passes (tool is present) AND rationale is set — looks healthy.
- `[?]` — verify passes but the rationale is empty — needs documentation. Probably an item added quickly during a busy session.
- `[x]` — verify fails — the tool is gone (container rebuild lost it, or user uninstalled). The install will re-run on the next `/sandbox` rebuild; if you don't want it back, remove it from the backpack.

This is a read-only audit. Nothing in the backpack changes — the next steps after audit (filling in rationale via `/backpack:add` re-declaration, or removing stale items via `/backpack:remove`) are explicit follow-up actions the user/agent decides on.

## Sandbox-only

```bash
[ -n "$CLAUDE_SANDBOX" ] || { echo "ERROR: /backpack:audit is sandbox-only. The launcher sets CLAUDE_SANDBOX=1 inside the container; it's unset on the host."; exit 1; }
```

Outside a sandbox, the `verify` commands (most of which check container-only tools like `dpkg`, `apt`, `npm list -g`) would all fail spuriously — the audit would be meaningless.

## Run

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/backpack.pl" audit "$HOME/.claude/backpack.json"
```

## Report

The script outputs `OK:`, `NO_RATIONALE:`, and `GONE:` counts plus a per-item table. Present it as-is, then add one short follow-up paragraph based on the counts:

- **`GONE > 0`** — call out each `[x]` item by name. For each, propose either: (a) leave it (next rebuild will reinstall), or (b) `/backpack:remove --category <C> --name <N>` if it's no longer needed. Ask the user which.
- **`NO_RATIONALE > 0`** — list each `[?]` item by name. Offer to fill in rationales now via `/backpack:add` re-declaration (which preserves the install/verify and adds the missing `--rationale`). Pull from session history or ask the user if no obvious context.
- **All `[v]`** — confirm the backpack is healthy and silently exit.

## Important

- Audit doesn't run any install commands — it's safe to run repeatedly without side effects.
- An item being `[x]` is not an error condition by itself. It just means the next rebuild will re-install. The audit is informational.
- If audit is run on a brand-new container before any installs have happened, every item might be `[x]` — that's normal, and `/sandbox` will fix it on next launch.
