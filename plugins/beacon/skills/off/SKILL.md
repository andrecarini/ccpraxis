---
name: off
description: Removes the beacon mark from the current Claude Code session. Use proactively when the user signals that the session's work is finished — phrases like "done", "shipped", "merged", "deployed", "landed", "committed", "PR opened", "let's call it", "wrapping up", "ship it", "all good", "looks good", "lgtm", "finished", "we're good", "that's it for today". Skip when the signal is scoped to a sub-task or step ("done with that step, now X"), to reading or thinking ("done reading", "okay, thought about it"), or when substantive work is clearly still in progress. **If you're invoking this proactively (the user didn't explicitly type `/beacon:off`), ALWAYS confirm with `AskUserQuestion` BEFORE invoking the skill.** A direct user invocation needs no further confirmation — the slash command is the user's consent.
user-invocable: true
allowed-tools: Bash
related:
  - on
---

# /beacon:off

Remove the beacon mark from this session.

## When to trigger (proactive invocation only)

Distinguish **session-complete** signals (the work this session was about is done) from **phase-complete** signals (one sub-task done, more coming). Only the former warrants offering `/beacon:off`.

- ✅ Trigger: *"Shipped it, PR is up — that's a wrap."* → the session's work has landed; offer to unbeacon.
- ✅ Trigger: *"Merged, let's call it for today."* → explicit session-end signal.
- ❌ Skip: *"Done with the helper refactor, now let's tackle the API."* → phase done, session continues.
- ❌ Skip: *"Done reading that file — interesting."* → meta-activity, not work completion.
- ❌ Skip: *"Looks good, what next?"* → review acknowledgment with the session continuing.

When unsure, lean toward NOT offering — a missed signal is cheap (user can `/beacon:off` manually or clean up via `claude-beacon` / `/beacon:delete`), but an unwanted prompt is friction.

When you do offer proactively, ask via `AskUserQuestion` BEFORE invoking the skill (e.g. *"Remove the beacon from this session?"* with `Yes — remove` / `No, keep it` options). If the user says no, do not invoke. **Direct user invocation (typed `/beacon:off`) skips this — the slash command itself is the consent.**

## Steps

### 1. Remove the beacon

`${CLAUDE_SKILL_DIR}` is the documented Claude Code substitution that points at this skill's directory. The shared `beacon.pl` lives two levels up at `<plugin-root>/scripts/`. Same path on host and inside a sandbox (the sandbox-skills TUI mounts the whole plugin):

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/beacon.pl" unbeacon --session-id ${CLAUDE_SESSION_ID}
```

Parse the KV output and the exit code:

- `STATUS: removed` (exit 0) → success.
- `STATUS: not_found` (exit 2) → this session was never beaconed. Friendly no-op, not an error.
- `STATUS: error` + `ERROR: …` (exit 1) → report the error verbatim.

### 2. Confirm to the user

One short sentence:

- On `removed`: `Beacon removed.`
- On `not_found`: `This session wasn't beaconed — nothing to remove.`
- On `error`: report the verbatim `ERROR:` line.
