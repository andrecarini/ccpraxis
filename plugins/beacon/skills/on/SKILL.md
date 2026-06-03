---
name: on
description: Marks the current Claude Code session as ongoing meaningful work so it can be resumed later via `claude-beacon`. Use proactively when the session involves a multi-step task, a plan, multi-file edits, or anything the user would want to return to after a restart. Skip for one-off questions, trivial lookups, or single-file quick fixes. Re-invoking is idempotent (refreshes last_active_at and updates the label).
user-invocable: true
argument-hint: [label]
allowed-tools: Bash
related:
  - off
  - resume-plan
---

# /beacon:on

Mark this session as ongoing work so the user can resume it later from a fresh terminal via `claude-beacon`. The mark survives session resets, terminal crashes, and full system restarts (it lives in the vault, not in process memory).

## Arguments

- `$ARGUMENTS` — optional human-readable label (e.g. `payments-bugfix`, `refactor auth flow`). Omit for an unlabeled beacon.

## Steps

### 1. Light the beacon

Base command (no label). `${CLAUDE_SKILL_DIR}` is the documented Claude Code substitution that points at this skill's directory. The shared `beacon.pl` lives two levels up at `<plugin-root>/scripts/`. Same path on host and inside a sandbox (the sandbox-skills TUI mounts the whole plugin):

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/beacon.pl" light --session-id ${CLAUDE_SESSION_ID}
```

If `$ARGUMENTS` is non-empty, append `--label '<label>'`. **Always wrap the label in single quotes** and escape any internal `'` as `'\''`. Never use double quotes around the label, and never splice raw `"$ARGUMENTS"` into the bash command — labels may contain `$`, backticks, `;`, or `'` that bash would otherwise interpret or that would break the quoting.

Examples (the value to the right of `--label` is what you should emit verbatim into bash):

- Label `payments-bugfix` → `--label 'payments-bugfix'`
- Label `refactor "auth" flow` → `--label 'refactor "auth" flow'`
- Label `don't break this` → `--label 'don'\''t break this'`

### 2. Parse the result

The script emits `KEY: value` lines on stdout:

- `STATUS: lit` → success. Capture `SLUG:` (project, may be empty) and `SCOPE:` (`host` or `sandbox`).
- `STATUS: error` followed by `ERROR: …` → report the error verbatim and stop.

### 3. Confirm to the user

One short sentence. Mention scope, slug (when present), and that the beacon survives restarts. If a label was set, mention it.

Examples:

> Beacon lit for `ccpraxis` (host). Resume from any terminal with `claude-beacon`.

> Beacon lit for `flutter-app` (sandbox), labeled `payments-bugfix`. Resume with `claude-beacon`.

Re-invoking on an already-lit session is fine — the script touches `last_active_at` and updates the label in place.
