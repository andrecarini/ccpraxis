---
name: upstream-sync
description: The GitHub side of ccpraxis, for the dev clone only — fetches your fork (origin), integrates origin/main into the dev clone's main (fast-forward or a merge commit; stops cleanly on a conflict or when the merge would touch your uncommitted files), scans what the push would send for secrets, and pushes main after you confirm the exact list of outgoing commits. Reports how far the dev clone is ahead of the live install. Never touches the live install or ~/.claude; /steward:backup brings changes live. Use when the user wants to pull other machines' ccpraxis changes, publish ccpraxis commits, or says "upstream sync", "push ccpraxis", "pull ccpraxis", "sync with github", "publish my config". ALWAYS confirm via AskUserQuestion when invoked proactively.
user-invocable: true
host-only: true
allowed-tools: Bash, AskUserQuestion
---

This skill is a thin wrapper. Every git operation is owned by one script; the wrapper's
whole job is: run it, present its decision, relay its result, re-run with the answer.
It never runs git itself, and never answers a decision for the operator.

## Running the script

```
perl ${CLAUDE_PLUGIN_ROOT}/scripts/upstream-sync.pl run --json
```

Exactly one JSON object is written to stdout. The script keeps no state between calls:
each call fetches again and finds an integration it already did, so re-running is always
safe.

| exit | status | what the wrapper does |
|---|---|---|
| 0 | complete | relay the result (**Relaying the result**), then stop. |
| 10 | needs_decision | present the one decision in `decisions[]` (**The push decision**), then re-run with `--answer <id>=<choice-id>`. |
| 20 | stopped | something needs the operator: show `stop.reason` and `stop.fix` verbatim, relay what else happened (a fetch, an integration), and stop. Never try to fix it yourself — no stash, no reset, no hand merge. |
| 2 | usage | a wrapper bug: show `error.message` and stop. |
| 4 | answer refused | the choice id was not one the decision offered: go back to the operator with the same decision. A second refusal stops the loop. |
| 1 | internal | show `error.message` and stop. |

## The push decision

There is only one kind, `push_confirmation`. Show `detail` verbatim before asking: it names
the remote and lists EVERY commit the push would send — the operator's own unpushed work and
any merge commit included. Offer the two choices exactly as given: `push_<sha>` (push these
commits; the id carries the commit that was shown) and `abort`. Never pick one for the
operator, and never reuse an earlier answer: the operator answers each time.

Re-run with the answer, for example:

```
perl ${CLAUDE_PLUGIN_ROOT}/scripts/upstream-sync.pl run --json --answer upstream.push_confirmation=push_0123456789ab
```

If `main` moved between the question and the answer, the script does not push; it asks
again with the new list (exit 10, explained in `notes`). Present the new decision the same
way.

## Relaying the result

Say, in plain terms:

- `integration.action` — `none`, `fast_forward` or `merge`, with the incoming commits from
  `integration.commits`; on a stop, the conflicting files from `integration.conflicts`.
- `push.status` — `nothing` (nothing to send), `pushed` (and that the remote was checked to
  have it: `push.remote_sha`), `aborted`, `rejected` (with `push.error`), or `not_reached`.
  Never turn a `push.warnings` line such as a protected-branch bypass notice into a failure.
- `scan` — when it is not clean, the findings verbatim (each names the outgoing commit and file;
  a credential removed in a later commit still counts, because the push sends every commit);
  nothing was pushed.
- `live.hint` — how far the dev clone's `main` is ahead of the live install, and that
  `/steward:backup` (which promotes it, asking first) brings it live. This skill never
  changes the live install.
