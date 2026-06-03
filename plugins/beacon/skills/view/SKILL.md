---
name: view
description: Shows one beacon's full record (all fields — scope, slug, cwd, label, summary, tags, timestamps, host machine, sandbox container, etc.) without resuming the session. Use when the user wants the full details on a specific beacon — says things like "view that beacon", "show me beacon abc1234", "details for the ccpraxis beacon", "what's in that beacon record". Read-only. To browse all beacons use `/beacon:list`; to delete use `/beacon:delete`.
user-invocable: true
argument-hint: <session-id-or-prefix>
allowed-tools: Bash
related:
  - on
  - off
  - list
  - delete
---

# /beacon:view

Display one beacon record as a structured Markdown block. Read-only.

## Arguments

- `$1` — Session ID (full UUID) or hex prefix (≥4 chars) to look up. Required.

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
  - **2+ matches** → list every candidate as `<8-char-prefix>…  slug:<slug>  label:<label-or-summary-or-—>  last:<relative>`, then ask the user (plain prose, not `AskUserQuestion`) to re-run with a longer prefix or the full UUID. Stop. **Do not guess** — never proceed with the most-recent or any other heuristic pick; ambiguity must always halt.

### 2. Fetch the record

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/beacon.pl" get --session-id <uuid>
```

Branch on exit code and the `STATUS:` line:

- **Exit 0** (stdout is valid JSON, no `STATUS:` prefix line) → success. Parse the JSON. If stdout is empty or fails to parse despite exit 0, treat it as the error branch (`Beacon get returned exit 0 but no parseable record`) and stop.
- **Exit 2** with `STATUS: not_found` → `Beacon <uuid> not found.` Stop.
- **Exit 1** with `STATUS: error` + `ERROR: …` → report the verbatim `ERROR:` line. Stop.

### 3. Display the record

Render as a structured Markdown block. Order matters (most-identifying fields first):

- **session id** — full UUID
- **scope** — `host` / `sandbox`
- **project slug** — `project_slug` or `—`
- **git root** — `git_root` or `—`
- **cwd** — `cwd`
- **label** — or `—`
- **summary** — or `—`
- **tags** — comma-joined, or `—`
- **created at** — `created_at` (ISO-8601 UTC) + relative (e.g. `2026-06-01T03:38:29Z (1d ago)`)
- **last active at** — `last_active_at` + relative
- **host machine** — `host_machine`
- **sandbox container** — `sandbox_container` or `—`
- **auto-lit** — `auto_lit` (`yes`/`no`)
- **schema version** — `schema_version`
- **host project path** — `host_project_path` (only show if present — legacy records may omit it)

### 4. Sanitize for display

Every user-supplied / Claude-supplied string field — `label`, `summary`, `project_slug`, `tags` entries, anything that could carry control chars — must be stripped of escape sequences before rendering. Strip:

- CSI sequences: `\x1B\[[0-9;?]*[A-Za-z]`
- OSC sequences: `\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)`
- Other ESC + one byte: `\x1B[^\[\]]`
- C0 controls and DEL: `[\x00-\x1F\x7F]`

Strip is **display only** — never mutate the record on disk.

### 5. Suggest next actions

Close with one short line:

> Resume with `claude-beacon`, or delete with `/beacon:delete <8-char-prefix>`.

## Important

- This skill is read-only. It does not modify the record or trigger a resume.
- Ambiguity always halts. When a prefix matches multiple beacons, list the candidates and ask the user to pick — never default to "most recent" or any heuristic.
