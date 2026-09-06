---
name: update
description: Safely updates Claude Code by researching releases before installing. Checks changelog, release age, and community issues, then offers version choices. Use when the user wants to update Claude Code, check for new versions, or says "update", "upgrade", "new version".
user-invocable: true
host-only: true
allowed-tools: Bash, Read, AskUserQuestion, Skill
---

# /steward:update

The research is done by `update-research.pl`, which fetches, merges, caches and classifies. Your job is to present its findings, get a decision, record it, and run the install. **Do not re-derive anything it already computes** — no WebFetch of the changelog, no hand-counting versions, no hand-computing ages.

This division is deliberate. The prose version of this skill made the agent hand-fan eight WebFetches per run, and on 2026-09-06 it was measurably wrong three ways at once: it read the Releases API through a prose summarizer that returned 5 of 100 releases, its version-string issue query matched every issue filed that day, and it re-derived everything on every invocation so declining an update cost as much as taking one.

## Step 1: Research

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/update-research.pl gather
```

Add `--current <version>` only if `claude --version` can't be read. Cold run ≈9s; warm run ≈1s, because release dates and changelog text are immutable and cached forever, and only open issues expire (12h).

Parse the JSON:

| Field | What to do with it |
|---|---|
| `current_version`, `latest_version`, `versions_behind` | The headline |
| `candidates[]` | One row per version, newest first. Each has `version`, `published_at`, `date_source`, `age_days`, `risk`, `risk_reasons[]`, `bullet_count`, `bullets[]`, `issues[]` |
| `runtime_clusters[]` | Active bundled-runtime crash clusters: `runtime`, `reports`, `from_version` |
| `recommendation` | `{version, why}`. `version` is null when nothing qualifies — say so plainly rather than picking the least-bad |
| `decisions[]` | What was chosen before, newest first |
| `warnings[]`, `coverage_ok`, `source_disagreements[]` | Surface all of these; do not silently drop one |
| `network` | Which sources were fetched vs served from cache. Worth one line so the user knows what it cost |

Risk bands, worst-first: `RUNTIME_RISK`, `HIGH`, `NO_CHANGELOG`/`UNKNOWN`, `MEDIUM`, `LOW`. They already account for age, open issues blaming the version, reaction counts, and cluster membership — do not recompute or second-guess them.

## Step 2: Check the decision history first

If `decisions[]` shows a version previously `declined`, look at why. If the issues named in that reason are no longer in that version's `issues[]`, say so — that is a version worth re-offering, and it is the whole reason the log exists. Don't silently re-present a version the user already rejected as though it were new.

## Step 3: Present

A table, one row per version, newest first: version, released, age, risk, and a compact summary of the changes. Use `bullet_count` to say how large each entry is; reproduce `bullets` in full only for versions the user is actually weighing, or when asked. A 100-bullet changelog pasted into chat helps nobody.

**Filter crash reports by platform.** Each issue carries `platforms[]`. A Linux-only glibc segfault cluster is not a reason for a Windows user to stay put, and presenting it as one is the single most misleading thing the old flow did. Say which platform each cluster affects.

State the recommendation and its `why`. If `recommendation.version` is null, say that staying put is the sound choice and why.

## Step 4: Ask

`AskUserQuestion` with the recommended version first (labelled "Recommended"), then a small number of genuine alternatives drawn from `candidates`, then "Stay on `<current>`". Never offer a `RUNTIME_RISK` version as the recommendation; you may still list it, labelled, since the choice is the user's.

## Step 5: Record the decision — always

Whatever they choose, including staying put:

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/update-research.pl record-decision \
  --from "<current>" --to "<chosen-or-current>" \
  --action <installed|declined|deferred> --reason "<why, in one line>"
```

`declined` for "stay on current", `installed` for an update you are about to perform, `deferred` for "not now, ask me later". The `--reason` is what makes the next run useful, so write a real one — name the issue numbers if that is why.

If the store lives in the vault, push it so other machines inherit it:

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/update-research.pl sync "steward: update research"
```

If the user picked "stay", stop here.

## Step 6: Back up, then snapshot the binary

Both, in this order, before touching anything.

**6a.** Invoke `/steward:backup` via the Skill tool and wait for it. If it fails or the user aborts it, **stop** and ask whether to proceed without a backup.

**6b.** Snapshot the live binary:

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl snapshot \
  --reason "pre-install of v<SELECTED>" --mark pre-install
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl prune --keep 4
```

**Check the exit code.** Non-zero means STOP — do not run the installer. Without a snapshot a botched install has no revert path, and that has happened on real installs. Surface the returned `snapshot.id` to the user.

## Step 7: Install the version they chose

Never `claude update` — it fetches the absolute latest, which may not be what was chosen if something shipped during the conversation.

Detect the install method first: a binary at `~/.local/bin/claude` is a native install; one under `node_modules` is npm; one under a Homebrew prefix is brew.

- **Windows native:** `powershell -Command "& ([scriptblock]::Create((irm https://claude.ai/install.ps1))) <SELECTED>"`
- **macOS/Linux native:** `curl -fsSL https://claude.ai/install.sh | bash -s <SELECTED>`
- **npm:** `npm install -g @anthropic-ai/claude-code@<SELECTED>`
- **brew:** no version pinning; tell the user and confirm before proceeding.

## Step 8: Verify, and revert if it broke

Run `claude --version`. If it succeeds and matches the selection, say so and mention the snapshot id.

If it fails — non-zero exit, no output, crash, hang, panic — or reports a different version, the install is broken. Surface the exact error, list snapshots (`claude-binary-backup.pl list`), and offer via `AskUserQuestion`:

- **Revert to the pre-install snapshot (Recommended)** → `claude-binary-backup.pl restore --latest`, then verify `claude --version` works again.
- **Leave it in place** → do nothing.

Either way, tell the user to restart Claude Code.

## Maintenance

```bash
update-research.pl status                 # what's cached, how stale, where it lives
update-research.pl history --limit 20     # past decisions
update-research.pl gather --offline       # full analysis from cache, no network
update-research.pl gather --force         # ignore TTLs and conditional GETs
update-research.pl prune                  # dry run; --apply to delete
```

`prune` clears artifacts from a retired approach that cached a 3.6 MB rendered page per run and never removed one — 38 MB of it was still present when this was written.

## Manual revert, any time

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl list
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl restore --latest
perl ~/.claude/ccpraxis/plugins/steward/scripts/claude-binary-backup.pl restore --snapshot <id>
```

Snapshots live in `~/.claude/backups/claude-code/`; the newest 4 are kept, and a fresh "pre-restore" snapshot is taken before any restore, so restores are themselves reversible.
