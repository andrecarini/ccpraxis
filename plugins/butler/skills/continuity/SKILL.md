---
name: continuity
description: Toggle or check explicit continuity arming for THIS session — a Stop gate that blocks
  ending a turn with nothing scheduled to resume it, for sessions doing unattended work with no
  blueprint, drive-solo run, or reporter involved. `on` arms, `off` disarms, no argument or
  `status` reports current state. Use when the operator asks to be "watched" or to arm/disarm
  continuity, or when the agent is about to start open-ended unattended work with no blueprint.
argument-hint: "[on|off|status]  (default: status)"
user-invocable: true
allowed-tools: Bash
---

# /butler:continuity

Explicit continuity arming for the current session. Once armed, `gate-continuity.sh` (a Stop hook)
blocks a turn from ending with nothing scheduled to resume this session — unless the arm is
explicitly lifted with `off`. This is independent of `/butler:drive-solo` and the reporter; it exists
for unattended work that involves neither.

## Arguments

- `$ARGUMENTS` — one of `on`, `off`, `status`. Empty defaults to `status`.

## Steps

### 1. Run the script

`${CLAUDE_SKILL_DIR}` is the documented Claude Code substitution for this skill's own directory; the
canonical script lives two levels up at `<plugin-root>/scripts/`.

- `on` →
  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/bp-continuity.pl" arm --session "${CLAUDE_SESSION_ID}" --by operator
  ```
- `off` →
  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/bp-continuity.pl" disarm --session "${CLAUDE_SESSION_ID}"
  ```
- `status` (or no argument) →
  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/bp-continuity.pl" status --session "${CLAUDE_SESSION_ID}"
  ```

### 2. Parse the result

The script emits `KEY: value` lines on stdout:

- `STATUS: armed` → success (arm or status-while-armed). `ARMED_BY:` and `SINCE:` are present.
- `STATUS: disarmed` → disarm succeeded.
- `STATUS: not_armed` → disarm on a session that was not armed (not a failure — report it plainly).
- `STATUS: unarmed` → status on a session that is not armed.
- `STATUS: error` followed by `ERROR: …` → report the error verbatim and stop.

### 3. Confirm to the user

One short sentence, mirroring `/beacon:on`/`/beacon:off`'s confirm-to-user step.

Examples:

> Continuity armed for this session — I'll be blocked from ending a turn with nothing scheduled to
> resume it, until you run `/butler:continuity off`.

> Continuity disarmed for this session.

> This session is not currently armed.
