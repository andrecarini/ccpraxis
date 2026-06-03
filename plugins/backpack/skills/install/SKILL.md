---
name: install
description: Manually trigger the backpack install pass — runs verify for each item and installs the ones missing. Use when the user says "install the backpack", "replay the backpack", "set up tooling from the backpack", or after they've hand-edited backpack.json and want to apply changes without rebuilding. Skip on the host. The /sandbox launcher calls this automatically on every container creation; this command exists for the manual case.
user-invocable: true
argument-hint: ""
allowed-tools: Bash, Read
related:
  - add
  - list
---

# /backpack:install

Runs the install pass: for each item in the backpack, runs `verify`; if it exits 0 the item is skipped ("already present"), else the `install` command runs and `verify` is re-run to confirm. Reports per-item status and an overall summary.

This is normally invoked by the `/sandbox` launcher on every container creation. The manual command is here for:

- After hand-editing `~/.claude/backpack.json` to apply changes without rebuilding the container.
- After `/backpack:add`ing several items, to install them in the current session without waiting for the next rebuild.
- Recovery: if a previous install pass partially failed, re-running picks up where it left off.

## Sandbox-only

```bash
[ -n "$CLAUDE_SANDBOX" ] || { echo "ERROR: /backpack:install is sandbox-only. The launcher sets CLAUDE_SANDBOX=1 inside the container; it's unset on the host."; exit 1; }
```

## Run

The container runs as root already, so no elevation is needed:

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/backpack.pl" install "$HOME/.claude/backpack.json"
```

## Report

The script emits per-item lines plus a summary:

- `SKIP: <category>:<name> (already present)` — verify passed, no install needed.
- `INSTALL: <category>:<name>` — verify failed, install starting.
- `OK: <category>:<name>` — install + reverify succeeded.
- `FAIL: <category>:<name> — install <reason>` — install command exited non-zero.
- `FAIL: <category>:<name> — verify after install <reason>` — install succeeded but verify still fails.
- Summary: `INSTALLED: <n>`, `SKIPPED: <n>`, `FAILED: <n>`.

If `FAILED > 0`, surface the failing items prominently and ask the user how to proceed — usually the `install` or `verify` command needs a small fix via `/backpack:add` (re-adding overwrites the entry).

## Important

- Do not run this from outside a sandbox — the install commands assume the Debian Bookworm container environment.
- If `apt-get install` entries fail with "Unable to locate package", the apt cache may be empty (the base Containerfile clears `/var/lib/apt/lists/*`). Prefix apt installs with `apt-get update &&` in the backpack entry, or run `apt-get update` once before invoking install.
