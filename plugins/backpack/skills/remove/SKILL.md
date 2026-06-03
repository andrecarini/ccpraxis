---
name: remove
description: Drop an item from the sandbox backpack so it stops being installed on rebuild. Use when the user says "remove X from the backpack", "stop tracking X", "drop X", "unpack X", or after deciding a tool is no longer needed. Skip on the host.
user-invocable: true
argument-hint: "[--category C --name N]"
allowed-tools: Bash, Read, AskUserQuestion
related:
  - add
  - list
---

# /backpack:remove

Drops an item from `~/.claude/backpack.json`. Idempotent — removing a non-existent item is a no-op, not an error.

## Sandbox-only

```bash
[ -n "$CLAUDE_SANDBOX" ] || { echo "ERROR: /backpack:remove is sandbox-only. The launcher sets CLAUDE_SANDBOX=1 inside the container; it's unset on the host."; exit 1; }
```

## Arguments

`$ARGUMENTS` should contain `--category C --name N`. Two paths:

1. **Both flags provided** — pass straight through.
2. **Missing flags** — first run `/backpack:list` (or call the underlying `list` subcommand) to show what's there, then ask the user via `AskUserQuestion` which entry to remove. Build up to 4 options from the list output; if more than 4 entries exist, instead ask the user to type the category/name pair.

## Run

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/backpack.pl" remove "$HOME/.claude/backpack.json" \
  --category "<C>" \
  --name     "<N>"
```

## Report

- `STATUS: removed` → done. Mention the new TOTAL.
- `STATUS: noop` → no entry matched. Show the user the current backpack (`list`) and ask them to pick again — they probably typed the wrong category or name.

## Important

- Removing an item doesn't uninstall the tool from the current running container. It just stops the item from being installed on the next rebuild. If they want it gone now too, mention they'd need to run an explicit uninstall (e.g. `apt-get remove -y X`).
