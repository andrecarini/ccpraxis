---
name: delete
description: Deletes ANY beacon record by session ID or hex prefix, after mandatory user confirmation. Use when the user wants to remove a specific beacon by ID (one they identified via `/beacon:list` or `claude-beacon`) — says things like "delete the abc1234 beacon", "remove beacon X", "delete that old ccpraxis beacon". NOT for removing the current session's mark — that's `/beacon:off`. ALWAYS confirm via AskUserQuestion before removal.
user-invocable: true
argument-hint: <session-id-or-prefix>
allowed-tools: Bash, AskUserQuestion
related:
  - on
  - off
  - list
  - view
---

# /beacon:delete

Delete a specific beacon by session ID. **Confirmation is mandatory** — a beacon represents work the user might still want to resume, so removal must be intentional, not a side effect of pattern-matching on a word.

This skill is for removing a beacon **other than the current session's**. To remove the current session's mark, use `/beacon:off`.

## Arguments

- `$1` — Session ID (full UUID) or hex prefix (≥4 chars) to delete. Required.

## Steps

### 1. Resolve `$1` to a full UUID

`${CLAUDE_SKILL_DIR}` is the documented Claude Code substitution that points at this skill's directory. The shared `beacon.pl` lives two levels up at `<plugin-root>/scripts/`.

If `$1` is missing, empty, or malformed (not hex, or fewer than 4 chars), tell the user what's wrong and suggest `/beacon:list` to see what's available. Stop.

- **Full UUID** — if `$1` matches `^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`, use it as-is.
- **Prefix** — otherwise, treat `$1` as a hex prefix (`^[0-9a-fA-F]{4,}$`). Run:

  ```bash
  perl "${CLAUDE_SKILL_DIR}/../../scripts/beacon.pl" list --format json --scope all
  ```

  Find every record whose `session_id` starts (case-insensitive) with `$1`:

  - **0 matches** → `No beacon found with prefix '<$1>'. Run /beacon:list to see what's available.` Stop.
  - **1 match** → use that record's `session_id`.
  - **2+ matches** → list every candidate as `<8-char-prefix>…  slug:<slug>  label:<label-or-summary-or-—>  last:<relative>`, then ask the user (plain prose, not `AskUserQuestion`) to re-run with a longer prefix or the full UUID. Stop. **Do not guess** — never proceed with the most-recent or any other heuristic pick. **A wrong-deletion is unrecoverable from this skill's perspective; a re-prompt is cheap.**

### 2. Look up the record (for the confirmation summary)

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/beacon.pl" get --session-id <uuid>
```

Branch on exit code:

- **Exit 0** with valid JSON on stdout → parse it; extract `project_slug`, `label`, `summary`, `last_active_at` for the confirmation prompt. If stdout is empty or fails to parse despite exit 0, stop with `Beacon get returned exit 0 but no parseable record` — do not proceed to confirmation.
- **Exit 2** (`STATUS: not_found`) → `Beacon <uuid> not found (already gone). Nothing to delete.` Stop.
- **Exit 1** (`STATUS: error`) → report the verbatim `ERROR:` line. Stop.

### 3. Confirm with the user — MANDATORY

Use `AskUserQuestion`. **Never skip this step. Never assume yes.** Sanitize displayed strings (label / summary / slug) the same way as step 5 below.

- Question: `Delete beacon <slug-or-8-char-uuid-prefix> (<label-or-summary-or-—>, last active <relative>)?`
- Options:
  - `Yes — delete` — description: `Removes the JSON record. Cannot be undone from here (the session itself stays in Claude's history; only the beacon mark goes away).`
  - `No, keep it` — description: `Beacon stays. You can still resume it from claude-beacon.`

If the user picks `No, keep it`, report `Beacon kept.` and stop. **Do not call** `beacon.pl unbeacon`.

### 4. Remove

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/beacon.pl" unbeacon --session-id <uuid>
```

Branch on exit code and the `STATUS:` line:

- **Exit 0** with `STATUS: removed` → `Deleted beacon <8-char-prefix>.`
- **Exit 2** with `STATUS: not_found` → `Already gone — nothing to delete.` (Can happen if a concurrent `/beacon:off` or sandbox removal beat us. Friendly, not an error.)
- **Exit 1** with `STATUS: error` + `ERROR: …` → report the verbatim `ERROR:` line.

### 5. Sanitize for display

Every user-supplied / Claude-supplied string field in the confirmation prompt (label, summary, slug) and in candidate lists during prefix-resolution must be stripped of escape sequences before being placed into the prompt or table. Strip:

- CSI sequences: `\x1B\[[0-9;?]*[A-Za-z]`
- OSC sequences: `\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)`
- Other ESC + one byte: `\x1B[^\[\]]`
- C0 controls and DEL: `[\x00-\x1F\x7F]`

Strip is **display only** — never mutate the record on disk.

## Important

- Confirmation is mandatory. Pattern-matching on the word "delete" is not consent — the `AskUserQuestion` step gates the actual `unbeacon` call.
- For removing the **current session's** beacon, use `/beacon:off` instead. This skill is for cleaning up beacons identified by ID from a list (typically via `/beacon:list` or `claude-beacon`).
- Ambiguity always halts. When a prefix matches multiple beacons, list the candidates and ask the user to pick — never default to "most recent" or any heuristic.
