---
name: add
description: Record an item in the sandbox backpack so it's restored on every container rebuild. Use when (a) the auto-declare hook's additionalContext surfaces a pre-filled invocation after a successful install — decide whether to run it (with a real rationale) or skip the install as a one-off; (b) the user says "add to the backpack", "declare X", "pack X", "persist this install"; (c) you installed something via an unusual shape the hook can't parse (curl-pipe-bash, custom script) and want to record it manually. Also use to fill in a missing rationale on an existing entry — re-running add with the same category+name updates in place. Skip on the host.
user-invocable: true
argument-hint: "[--category C --name N --install I --verify V --rationale R]"
allowed-tools: Bash, Read, AskUserQuestion
related:
  - remove
  - list
  - audit
  - install
---

# /backpack:add

Adds (or updates) one item in the sandbox's backpack at `~/.claude/backpack.json`. Delegates all file I/O to the shared `backpack.pl` — never edit the JSON directly.

## How this is normally invoked

The PostToolUse hook on Bash (`auto-declare.pl`) doesn't write to the backpack itself — it proposes. After a successful install command, the hook emits an `additionalContext` block on your next turn that looks like:

```
[backpack] Detected 1 install-shape item in that Bash call that isn't tracked yet. …
  /backpack:add --category 'apt' --name 'jq' --install 'apt-get install -y jq' --verify 'dpkg -s jq >/dev/null 2>&1' --rationale '<WHY: one line — what this is for, why this version>'
```

Your job is to decide: was this install meant to persist?

- **Yes** — replace `<WHY: …>` with a real one-line rationale (what's this for, why this version, what's the alternative) and run the command. Pull the rationale from session context if it's obvious; ask the user otherwise.
- **No, one-off** — skip. If you ever install the package again, you'll be prompted again.

The hook also filters out (category, name) pairs already in the backpack, so re-installing a tracked item is silent.

## Sandbox-only

Run a sanity check first:

```bash
[ -n "$CLAUDE_SANDBOX" ] || { echo "ERROR: /backpack:add is sandbox-only. The backpack lives at ~/.claude/backpack.json inside a /sandbox container."; exit 1; }
```

`CLAUDE_SANDBOX=1` is injected by the launcher via `podman create -e` only inside the sandbox container; it's unset on the host. Reliable, path-independent marker.

If outside a sandbox, stop and explain — don't try to fall back to host paths (there's no canonical per-project backpack from the host's perspective without context this skill doesn't have).

## Arguments

`$ARGUMENTS` is a free-form string. Three shapes are common:

1. **Proactive invocation by the agent right after an install** — the agent assembles the flags itself based on what it just installed. Pass straight through.
2. **User typed `/backpack:add` bare** — interactive mode: gather everything via `AskUserQuestion`.
3. **Partial flags** — gather only the missing ones interactively.

Required for any item: `category`, `name`, `install`, `verify`. Optional: `rationale`.

## Interactive gather (when flags are missing)

Ask via `AskUserQuestion`:

- **category** — one of: `apt`, `npm-global`, `pip`, `cargo`, `gem`, `go-install`, `curl-script`, `snap`, `project-setup`, `other`. Pick the closest fit. `project-setup` is for project-level steps like `npm ci`, `flutter pub get`, `bundle install` — they have a `verify` that checks if the work is already materialized (e.g. `test -d /project/node_modules`). `other` is the escape hatch.
- **name** — human-readable identifier (e.g. `postgresql-client`, `firebase-tools`, `flutter`, `npm-deps`). Together with category, it's the uniqueness key.
- **install command** — the exact shell command that should be replayed on rebuild. Pin specific versions; never `latest`. Will run via `bash -c` as root inside the container.
- **verify command** — fast shell command that exits 0 if the item is already in place, non-zero otherwise. Used to skip re-installing on rebuilds where the state was preserved. For tools: `command -v X` or `X --version`. For project-setup: check the result (e.g. `test -d /project/node_modules`).
- **rationale** (optional but strongly preferred) — one-line "why is this in the backpack? why this specific version? what would the alternative be?" Future-you and the next agent will thank you. **If the install was just performed at the user's request, capture the user's stated reason verbatim.**

## Run

```bash
perl "${CLAUDE_SKILL_DIR}/../../scripts/backpack.pl" add "$HOME/.claude/backpack.json" \
  --category  "<C>" \
  --name      "<N>" \
  --install   "<I>" \
  --verify    "<V>" \
  --rationale "<R>"   # only if provided
```

To pin a version, bake it into the **install** command (e.g. `apt-get install -y jq=1.6`, `npm install -g prettier@3.2.5`) — that's the single source of truth. There is no separate `--version` field; the verify command (`X --version`) reflects the live version.

**Quoting reminder**: `--install` and `--verify` values are shell strings — quote them in the bash invocation so `$`, backticks, and `;` inside them don't get interpreted by the calling shell. The Perl helper rejects embedded newlines.

## Report

Echo the resulting status line:

- `STATUS: added` → new entry created.
- `STATUS: updated` → existing entry replaced (same category+name). Note that re-declaring is idempotent — that's correct behavior, not an error.

If `RATIONALE_SET: no`, gently flag to the user that the rationale is empty and offer to fill it in — even one short sentence helps future debugging.

## Special case — auto-declared by the Bash hook

If you notice an existing entry with empty `rationale` that was clearly auto-seeded by the PostToolUse hook (the install command exactly matches what was just typed), prompt the user once for the rationale and call `/backpack:add` again with the same category+name plus `--rationale` to fill it in. The update is idempotent.

## Important

- Never edit `~/.claude/backpack.json` directly — always go through this command.
- `(category, name)` is the uniqueness key. Same key = update, different key = new entry.
- The item's `install`/`verify` commands run inside the container with full root privileges on rebuild. Do not include `sudo` — it's not present and not needed.
