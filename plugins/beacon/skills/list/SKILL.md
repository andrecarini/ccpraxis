---
name: list
description: Lists every beacon record visible from here (host vault + every registered sandbox project, or just the local project's beacons inside a sandbox). Use when the user wants to see what beacons exist — says things like "show my beacons", "list beacons", "what beacons do I have", "what's beaconed". Read-only — does not resume or modify anything. For full details on one beacon use `/beacon:view`; for the TUI with resume use `claude-beacon`.
user-invocable: true
allowed-tools: Bash
related:
  - on
  - off
  - view
  - delete
---

# /beacon:list

Print every beacon as a Markdown table. Non-interactive — no resume, no deletion.

## Steps

### 1. Fetch records

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/beacon.pl" list --format json --scope all
```

`${CLAUDE_SKILL_DIR}` is the documented Claude Code substitution that points at this skill's directory. The shared `beacon.pl` lives two levels up at `<plugin-root>/scripts/`. Same path on host and inside a sandbox (the sandbox-skills TUI mounts the whole plugin).

The script emits a JSON array sorted by `last_active_at` descending. Parse it.

### 2. Handle empty

If the array is empty, print exactly:

> No beacons. Use `/beacon:on` to mark a session.

Stop. Do not render an empty table.

### 3. Render the table

Columns (in this order):

| # | scope | slug | label / summary | last active | session id |

For each row:
- `#` — 1-based index in the array (so the user can refer to "the 3rd beacon").
- `scope` — `host` or `sandbox` from the record.
- `slug` — `project_slug` (or `—` if empty).
- `label / summary` — prefer `label`; fall back to `summary`; `—` if neither is set.
- `last active` — relative time from `last_active_at` (`just now`, `5m ago`, `3d ago`). The timestamp is ISO-8601 UTC.
- `session id` — first 8 characters of `session_id` followed by `…` (full UUID is too wide; the prefix is enough for the user to pass back to `/beacon:view` or `/beacon:delete`).

### 4. Sanitize for display

Every string field that came from a beacon record — `label`, `summary`, `project_slug`, anything user-or-Claude-supplied — must be stripped of control sequences before being placed into a table cell. Strip:

- CSI sequences: `\x1B\[[0-9;?]*[A-Za-z]`
- OSC sequences: `\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)`
- Other ESC + one byte: `\x1B[^\[\]]`
- C0 controls and DEL: `[\x00-\x1F\x7F]`

This matches `sanitize_display` in `plugins/beacon/scripts/claude-beacon.pl`. The strip is for **display only** — never mutate the record on disk.

### 5. Summary footer

One line after the table:

> N beacons (X host, Y sandbox).

Counts derived from the same array. If X or Y is 0, still show both (e.g. `3 beacons (3 host, 0 sandbox).`).

## Important

- This skill is read-only. To resume a beaconed session use `claude-beacon` (interactive TUI). To delete a beacon use `/beacon:delete <id-or-prefix>`. To see one beacon's full record use `/beacon:view <id-or-prefix>`.
- Inside a sandbox, the vault doesn't exist — `beacon.pl list --scope all` falls back to the project's local `.ccpraxis-local-data/claude-home/beacons/` only. The empty-state message is the same in either environment.
