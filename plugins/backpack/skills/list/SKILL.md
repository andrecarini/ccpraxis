---
name: list
description: Show what's currently packed in the sandbox backpack. Use when the user asks "what's in the backpack", "list the backpack", "show me what I packed", "show backpack contents", or when they want a quick audit of what'll be restored on the next rebuild. Skip on the host.
user-invocable: true
argument-hint: ""
allowed-tools: Bash, Read
related:
  - add
  - remove
  - install
---

# /backpack:list

Pretty-prints the contents of `~/.claude/backpack.json`, grouped by category. Read-only.

## Sandbox-only

```bash
[ -n "$CLAUDE_SANDBOX" ] || { echo "ERROR: /backpack:list is sandbox-only. The launcher sets CLAUDE_SANDBOX=1 inside the container; it's unset on the host."; exit 1; }
```

## Run

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/backpack.pl" list "$HOME/.claude/backpack.json"
```

## Report

Display the output as-is (it's already formatted as a grouped-by-category table).

**Empty backpack** (`ITEMS: 0` or the file doesn't exist):

> Backpack is empty. The next rebuild will start from the bare Containerfile. Use `/backpack:add` after installing something to start tracking.

**Items with empty `rationale`** (line shows `rationale: (none — agent should fill in)`):

After displaying, mention how many items lack a rationale and gently nudge the user (or self-prompt as the agent) to fill them in via `/backpack:add` — the rationale is what makes the backpack auditable months later.

**Items present**:

Close with one short line about what'll happen: re-running `/sandbox` will replay every entry on the next container rebuild (skipping items whose `verify` already passes).
