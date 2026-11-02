---
name: backup
description: Brings local state in line and backs it up — promotes the ccpraxis dev clone into the live install (asking first), exports the settings Claude Code wrote into ~/.claude, and those each sandbox changed on its own, into the dev clone's payload key by key (asking per key, unless a saved preference answers), commits only those files and promotes again, then syncs every project registered for vault backup (CLAUDE.md, skills, plans, memory, almanac records — global and project). Never talks to GitHub; /steward:upstream-sync does. Resolves vault sync conflicts interactively. If you're in a project that has trackable Claude files but isn't registered for backup, offers to register it. Also surfaces Claude Code binary snapshots taken by /update and supports manual revert. Use when the user wants to sync config, back up settings, promote, sync vault projects, list/revert Claude Code snapshots, or says "backup", "sync config", "sync everything", "back up my work", "revert claude code", "list claude snapshots", "rollback claude".
user-invocable: true
host-only: true
allowed-tools: Bash, AskUserQuestion, Skill
---

This skill is a thin wrapper. Every mechanical step — git, file merges, the vault, the
secret scan, the report — is owned by a driver script. The wrapper's whole job is:
invoke the driver, present its decisions, relay its report, re-invoke with the answers.

Its ccpraxis part is local: promote the dev clone (the live install's `origin`) if it is
ahead, export only the settings keys sent to its payload, commit those files, promote again.
It never fetches, merges or pushes; publishing to GitHub is `/steward:upstream-sync`.

## Modes

Two modes, chosen by intent:

1. **Full sync (default).** Intent like "backup", "sync config", "sync everything",
   "back up my work" — go to **Running the driver**. Pushing to GitHub ("push config",
   "publish") is `/steward:upstream-sync`, not this skill.
2. **Snapshot/revert.** Intent like "revert claude code", "list snapshots", "rollback
   claude code", "restore claude code binary" — go directly to **Snapshot/revert mode**
   and never invoke the driver.

If intent is unclear, ask with `AskUserQuestion` before doing either.

## Running the driver

The full-sync path never touches git, files, or vault contents directly. Every call is
to `perl ~/.claude/ccpraxis/scripts/backup.pl` (the driver — lives at the ccpraxis repo
root, not `${CLAUDE_PLUGIN_ROOT}`). The wrapper's loop is: invoke, branch on the exit
code, answer, re-invoke.

**First invocation** — no `--restart`, no `--resume`:

```
perl ~/.claude/ccpraxis/scripts/backup.pl run --json
```

Exactly one JSON object is written to stdout per invocation. On an error exit the driver
also writes one `backup: <message>` line to stderr — redirect stderr separately, or parse
the JSON line out and ignore that one; do not treat its presence as "stdout did not parse".
Stop and show the raw output verbatim only if no JSON object is present at all — never
guess an exit meaning from text.

| exit | status | what the wrapper does |
|---|---|---|
| 0 | complete | go to **Relaying the report**, then **Follow-up actions**, then stop. |
| 20 | complete_with_failures | go to **Relaying the report** (it surfaces the failures) and **Follow-up actions**, then stop — never report this as a clean backup. |
| 10 | needs_decision | go to **Presenting decisions** for every entry of `decisions[]`, collect one choice per decision, then re-invoke (see the resume form below) with `--resume <resume_token>` and one `--answer <id>=<choice-id>` per decision, all in the same call. Leaving any pending decision unanswered is refused (exit 4, `answer_missing`) — answer them together, never partially. |
| 2 | usage | a wrapper bug: stop, show `error.message`, change nothing. |
| 3 | token error | `token_missing` (no token held — a new session, or a crashed one): report that a paused run exists and ask the operator whether to `--restart` (discard it and start fresh) or stop — never restart silently, that drops pending decisions and re-runs completed phases. `token_malformed` / `token_unknown` / `token_replayed`: stop, show `error.message`, never retry the same token — `token_replayed` is terminal, that token is spent forever; offer `--restart` only as an explicit escape hatch taken on the operator's own word. |
| 4 | answer refused | the wrapper's own bug (`answer_unknown_id`, `answer_duplicate`, `answer_unknown_choice`, `answer_missing`). `consumed_seq` is written only after a successful resume, so on this path it is still unwritten and the resume token is still valid — that makes the run recoverable, but recovery means going back to **Presenting decisions** and asking the operator again for every pending decision, with the same token. `decisions[]` carries the choices that were OFFERED, never the operator's selections, so it cannot be replayed or re-derived into answers — never fabricate an answer from it. A second exit 4 after a genuine re-ask stops the loop and shows `error.message` verbatim. |
| 1 | internal | stop, surface `error.code` and `error.message`; never auto-restart — restarting repeats completed phases. |

**Resume invocation** (exit 10, one `--answer` per pending decision, all in the same call):

```
perl ~/.claude/ccpraxis/scripts/backup.pl run --json --resume <resume_token> --answer <id>=<choice-id> [--answer <id>=<choice-id> ...]
```

**Restart invocation** (exit 3 `token_missing`, only on the operator's own word — discards
the paused run):

```
perl ~/.claude/ccpraxis/scripts/backup.pl run --json --restart
```

**A `--resume` call that hangs or times out with no output.** Do not retry the same token
(it may be consumed, and a replayed token is terminal). Re-invoke with no token,
`perl ~/.claude/ccpraxis/scripts/backup.pl run --json`, which reports the true state:
exit 3 `token_missing` means the run is still paused and the original token is valid, so
retry the same `--resume` call; any other result means the hung call consumed the token and
this call carried the run on, so handle its exit as usual. One case needs the operator first:
if the hung call answered the run's LAST decisions it may have finished the backup, and a
token-less call on a finished run starts a fresh one. Say so and ask before re-invoking.

Repeat the exit-10 branch until a terminal exit. Bound the loop at **20 driver
invocations**; if that bound is hit, stop, say plainly that the backup is **incomplete**
(never summarise it as done), and print the resume token so the operator can continue
this same run in a fresh session rather than restarting it and re-running completed
phases.

## Presenting decisions

The wrapper must never answer, select, or invent a choice on behalf of the operator —
every decision requires the operator's own selection via `AskUserQuestion`, obtained
fresh each time it is needed; synthesizing or guessing one, even from a prior answer
or from `decisions[]` itself, is not allowed. `decisions[]` is a record of the choices
OFFERED, not of anything the operator selected, so it can never stand in for consent.

Every entry of `decisions[]` follows the same shape: `title` is the question text,
`detail` and any `data` payload are shown to the operator BEFORE the question,
`choices[]` become the `AskUserQuestion` options labelled with each choice's `label`,
and the operator's selection is mapped back to that choice's `id` for
`--answer <id>=<choice-id>`. If a decision carries more choices than one
`AskUserQuestion` question can display, split it (narrow first, then choose) or fall
back to free-form text — never silently drop a choice, and never invent one.

For a `kind` not in the table below (a driver newer than this skill), fall back to
the generic presentation: show `title` + `detail` + `choices` verbatim and never
guess a default.

| kind | what it is | how to present it |
|---|---|---|
| promote_pending | the dev clone's `main` has commits the live install lacks | show every commit from detail/data and say that promoting changes the tooling that runs (plugins, hooks, scripts; skills from the next session) and syncs `global-config/` into `~/.claude`; offer `promote` or `skip` (the config export is then skipped too if the payload differs) |
| readme_drift | README.md or docs/repo-layout.md is stale relative to the tree on disk | show the drift detail (missing paths or a stale generated section), offer `acknowledge` (continue anyway) or `treat_as_failure` (fail the run over it) |
| settings_key | one settings unit (a key, or one level of a dotted key) differs between `~/.claude/settings.json` and the dev clone's payload, or exists on one side only | show the key and both values from detail/data; offer the four choices it carries: into the payload (use-live / export-to-repo / remove-from-repo), back into `~/.claude` (use-repo / remove-from-live / add-to-live), skip, or the keep-…-remember preference. Only units sent to the payload are written there; use-live or export-to-repo also settles the key for the container settings (see container_settings_key) |
| marketplace_key | a live-vs-dev-clone known_marketplaces.json entry differs | show the marketplace name and both sides, offer export/add, keep-remember, remove, or skip as fits the discrepancy |
| file_conflict | a synced file differs between live and the dev clone in a way that is not a settings key | show both versions (or a diff) from detail/data, offer use-live, use-export, or merge-manually |
| claude_md_drift | `~/.claude/CLAUDE.md` is not what promotion builds for this host from the live install's payload; such a difference is never exported | show detail verbatim (the lines only in the file, and only in the build); offer `rerender` (rebuild it, after a backup copy in `~/.claude/.promotion-backups/`) or `leave`. Say that a line worth keeping has to be folded by hand into the dev clone's `global-config/CLAUDE.md` or this host's part, then promoted |
| container_settings_key | a global-config-vs-container settings.json key differs, or exists on only one side, and was not already settled by this run's settings_key answer | show the key and both values, offer the choices the decision carries (propagate-to-container, keep-container, keep-different-remember or skip for a differing key; add-to-container, keep-global-only-remember or skip for a global-only key; remove-from-container, keep-container-only-remember or skip for a container-only key). It is not asked for a key the operator answered use-live or export-to-repo on its settings_key decision this run when the container differs from or lacks the global value: the driver writes the global-config value into the container settings and lists the key in the container_followed_global note. A global_vs_container preference in .backup-preferences.json still takes precedence, and a container-only key is always asked |
| sandbox_settings_key | one settings unit a sandbox changed on its own (in its `.ccpraxis-local-data/claude-home/settings.json`) differs from the dev clone's sandbox preset, `plugins/sandbox/container/settings.json`; one decision per unit per sandbox, for every sandbox in this machine's sandbox list | show the sandbox (data.project_name and data.project_path), the key, and both values from detail/data. Offer the four choices it carries: to-preset (the sandbox's value, or its removal, goes into the dev clone's preset and is committed with the export; every sandbox takes it on its next merge), keep-in-sandbox (this time only), keep-in-sandbox-remember (remembered for this project only), or revert-sandbox (the preset's value is written back into that sandbox's settings.json after a backup to its `.launcher/backups/`, and nothing else changes). A unit the preset changed and the sandbox did not is never asked: the sandbox's next merge takes it. A saved container_vs_sandbox preference for that project answers a unit without asking |
| sensitive_finding | the secret scan of the files the export commit will contain found a likely credential | show every finding (file, line, pattern) from detail/data verbatim, offer abort or rescan-after-fixing — never let the operator commit past this decision silently |
| vault_conflict | a vault-registered project has both local and vault changes to the same path since the last sync | show the conflict payload, including data.merge_preview when present (a diff3-style preview of both sides), offer use-local, use-vault, use-merged (only when a clean merge exists), or abort-this-project |
| project_registration | the current directory has trackable Claude files but is not registered for vault backup | show the trackable paths from detail/data, offer register-now, not-now, or dont-ask-again |
| plugin_install | a plugin the config enables that Claude Code cannot load: no install record for user scope or this project, and its marketplace does not serve it in place from a local directory | show the plugin name, marketplace and detail; offer install or skip. Say plainly that installing is a `/plugin install` the operator types at the Claude Code prompt, which neither you nor the driver can run; see Follow-up actions |
| step_failure | a phase hit a mechanical failure it cannot resolve itself and escalated it into a question instead of silently failing the run | render title, then detail/data verbatim, then the choices exactly as given, and tell the operator plainly that a phase turned a mechanical failure into a question |

## Relaying the report

Only exit 0 and exit 20 carry `notes[]`. Take the LAST entry with `key == 'report'`
in that array — it is authoritative (closeout does not promise every prior report note
survives a crash, so a mid-execution kill can leave a stale one behind a fresh one).
If no `report` note is present, report the run's outcome from `phases[]` alone and
say plainly that no report was produced — never fabricate a summary or claim a clean
backup by default.

If `report.degraded` is `true`, report assembly itself threw and some fields may be
`null`: relay what is present, name the missing sections, and treat the run as
problematic regardless of anything else.

`unit_failures` — not `degraded` — decides whether the operator is told something
went wrong: treat the run as problematic when `unit_failures` is non-empty, OR any
entry of `phases[]` has `status: failed`, OR the exit code was 20. `degraded` means
only that report assembly threw; it is `false` on a run that failed real units, so
never read it alone as "everything is fine."

Surface, from the report's fields:

- `ccpraxis_sync` — `live_root` and `dev_clone`; when `export_target.ready` is false,
  its `reason` and `fix` verbatim (a missing dev clone, or "promote first"); `promotion`
  and `promote_after_commit` (relay their `output` verbatim when the promotion ran or
  failed); `merged`, `committed` (the export commit and its files). Alongside it,
  `preferences.applied` / `.ignored` / `.skip_keys_unmatched`. Two checks run every time: `skills` (the skills mirror sync — what changed, if anything) and `claude_md`
  (the global CLAUDE.md status check: `~/.claude/CLAUDE.md` against the build of the
  live install's payload). Mention both; a `claude_md` status other than `in_sync` or `linked` means drift worth surfacing even though nothing failed.
- `container_followed_global` notes in `notes[]` — keys the driver wrote into the container settings without asking (operator answered `use_live`/`export_to_repo` on that key's `settings_key` decision this run; each entry: `key`, `relation` (the container-side global-vs-container relation, not the settings_key one), `answer`); list every one. Same as `ccpraxis_sync.container.followed_global`.
- `ccpraxis_sync.sandboxes` — the sandbox preset compared with each sandbox: per project its `path`, a `skipped` reason when it could not be reached (relay it), and how many units were `asked`, answered by a saved preference (`auto_applied`), or left to the sandbox's next merge (`pending_merge`); then `outcome`: units sent `to_preset`, sandboxes `reverted` (with the backup path), `preferences_saved`, and any unit `refused` because two sandboxes sent it to the preset with different values (a failure: say which).
- `marketplaces` — anything added or changed.
- `vault_projects.projects[]` — per-slug status and class; read the per-project
  files-pushed/pulled counts from the `sync_counts` entries elsewhere in `notes[]`
  (they are not part of this structure).
- `current_project_registration` — whether the offer fired and the operator's choice;
  **always** mention the skip marker (with `skip_marker_path`, and that deleting it
  re-enables the offer) whenever `skip_marker_present` is `true`, even if no offer
  fired this run.
- `plugins` — `missing`, `extra_installed`, `missing_marketplaces`.
- `snapshots` — `count`, `newest_id`, `newest_version`, `newest_corrupt`, and
  `revert_command` — informational only; never offer or perform a revert during a full
  sync. The revert mode is entered by intent (see **Modes**), never from a report.
- `sources` — a phase that never ran is reported as "never ran", never as "found
  nothing".
- `almanac_store_skipped` notes (relay each `message` verbatim) and `global_almanac_failed`
  (treat the run as problematic); mention `global_almanac.committed` / `.pushed` too.

## Follow-up actions

On a terminal exit (0 or 20), walk every entry of `follow_up_actions` and act on its
`action` value. Only these four exist; an unrecognised `action` is reported to the
operator verbatim and not acted on.

- **`invoke_setup_project`** (`action`, `cwd`) — emitted only when the operator
  already answered `register_now` on a `project_registration` decision. **Perform**
  it: invoke the `Skill` tool with `steward:setup-project` against `cwd`.
- **`create_skip_marker`** (`action`, `path`) — emitted only when the operator
  already answered `dont_ask_again`. **Perform** it: use `Bash` to create `path`'s
  parent directory first (`mkdir -p`) — it can be missing, since a bare root
  `CLAUDE.md` alone is enough to trigger the offer — then create the empty marker
  file at `path`. Verify the file actually exists afterward before telling the
  operator it was recorded; if creation failed, say so plainly instead of claiming
  success, and tell the operator where the marker is and that deleting it
  re-enables the offer.
- **`install_plugin`** (`action`, `plugin`, `name`, `marketplace`, `command`) —
  emitted on an `install` answer. **Relay** it, never run it: Claude Code cannot load `plugin` — no
  install record for user scope or this project, and its marketplace does not serve it in place. Tell the
  operator to type `command` at the Claude Code prompt, not in a shell; never report it installed.
- **`add_marketplace`** (`action`, `marketplace`, `plugin`) — emitted unconditionally
  whenever a marketplace is missing; no question gates it. **Inform only**: tell the
  operator the marketplace is missing and needs `/plugin marketplace add
  <owner>/<repo>` — never act on it automatically yourself, since that would be an
  unconsented mutation reaching through the consent channel. It carries no `command`
  key, so there is nothing to fabricate. `marketplace` is a marketplace *name*, not
  necessarily an `owner/repo` (a directory-source marketplace, for example) — show the
  `<owner>/<repo>` placeholder as-is and let the operator supply the real source, never
  substitute `marketplace`'s value into it.

## Snapshot/revert mode

Entered directly from Modes — this mode never invokes the driver. It always calls
`${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl` instead. Behaviour preserved
unchanged from the prior protocol (skill-before.md:516-575).

1. **List.**
   ```
   perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl list
   ```
   Parse the JSON. Show a numbered table — id, version, captured_at_utc, reason (if
   present), mark (if present), corrupt flag — newest first. If `count` is 0, tell the
   operator no snapshots exist (probably `/update` was never run) and stop.

2. **Detect.**
   ```
   perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl detect
   ```
   Surface the current binary's path, version, and SHA-256, so the operator can see
   whether a revert is even needed.

3. **Ask.** Use `AskUserQuestion` to offer: restore the latest snapshot; restore a
   specific snapshot (follow-up: which id, from the list above); verify a snapshot's
   integrity (which id); cancel without changes.

4. **Restore**, if chosen:
   ```
   perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl restore --latest
   ```
   or, for a specific id:
   ```
   perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl restore --snapshot <id>
   ```
   The script takes its own pre-restore snapshot before swapping the binary, so the
   restore is itself reversible. Afterward, run `claude --version` to confirm: if it
   matches the restored version, tell the operator and name the pre-restore snapshot
   id as the escape hatch (in case they need to revert the revert). If it fails,
   surface the error, name the pre-restore snapshot id, and do not attempt further
   restores automatically — let the operator decide.

5. **Verify**, if chosen:
   ```
   perl ${CLAUDE_PLUGIN_ROOT}/scripts/claude-binary-backup.pl verify --snapshot <id>
   ```
   Report the JSON. Exit code 2 means an integrity failure — the snapshot is corrupt
   and cannot safely be restored from. `prune --keep N` auto-removes all corrupt
   entries regardless of the keep-N window; to force-remove a single corrupt snapshot
   without touching others, the operator can delete its directory under
   `~/.claude/backups/claude-code/<id>` manually.
