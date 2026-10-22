# Butler hook architecture

The design for butler's hooks, written by package 02 of blueprint `hook-continuity-remake` and
implemented by packages 03-16. Package 16 owns this file and its coverage test
(`plugins/butler/tests/t/hook-architecture-coverage.t`) and keeps both in step with `hooks/`.

The system in one paragraph: every hook is a short shell file that execs one wrapper, and the wrapper
either exits in bash (the hook does not apply to this session) or execs one perl process that loads
`BpHook.pm` inside an exit-0 guard and parses the payload once. Continuity is one per-session file,
written by three commands and one hook. The Stop gate blocks only when that file exists and there is
no live holder and no silence. When it blocks, the agent sees 7 lines, or 5 without the silence line
while work is running, and those lines carry a single-use stop token the gate itself minted. With
that token, `butler-hold`, `butler-continuity off` and `butler-continuity silence` work even if every
other hook has failed. There are no override files.

## Harness facts and what they decided

Evidence: `plugins/butler/docs/harness-facts.md` (Claude Code 2.1.280). Each fact below changed a choice.

| fact | what it forced |
|---|---|
| A missing perl script exits 2, and 2 is the blocking code on every event (Method). Measured by red-team: `perl -MX` where X fails to load also exits 2 | Every registration is guarded. `run-hook.sh` checks `BpHook.pm` exists, and perl loads it with `require` inside `eval`, never with `-M` or `use`. An END block forces the exit code to 0 unless the hook deliberately returned 2. |
| (a) Stop payloads carry `background_tasks` (entries with `id`, `type` `subagent` or `shell`, `status`), not `agent_id`. Tool payloads carry `tool_use_id`, plus `agent_id`/`agent_type` inside a subagent. SubagentStop is a separate event | A holder counts only while one of its held ids is `running` in `background_tasks`. Dispatch binding keys on `tool_use_id`. Subagent context is "payload has `agent_id`". Only `Stop` is registered, so a subagent's own stop is never gated and never mints a token. |
| (b) A subagent's tool calls carry the parent's `session_id` | Subagents share the session's arm state and are told apart by `agent_id` alone. Forks were not measured (see Session roles). |
| (c) `agent-<id>.meta.json` exists before a background subagent's first PreToolUse. Foreground dispatch was not measured | Write guards resolve a subagent's package through `meta.json` `toolUseId`. An unresolvable binding with two or more packages in flight is refused, not widened. |
| (d) `/clear` allocates a new `session_id`. `--resume` and headless `/compact` keep it. In-process env behaviour is open (D-1..D-3) | All state is keyed by the payload `session_id`. No component reads `$CLAUDE_CODE_SESSION_ID`. Commands learn their session from a hook-written ticket or a gate-minted stop token. |
| (e) Background Bash (normal exit or killed) and background Agent completions wake an idle interactive session. A killed task is reported as `failed with exit code 143`. Headless `-p` kills a running background Bash a few seconds after its final result | The holder is a background Bash task whose exit at the deadline is the wake-up. Re-invocation extends, never replaces. A headless coordinator's holder counts only alongside a running background subagent (see Holder protocol). |
| (f) Stop exit 2 feeds stderr back as a synthetic user message and forces a paid turn. `stop_hook_active` is not a counter. No retry cap was observed | The denial is 7 lines. The gate never keys on `stop_hook_active`. There is no block cap (Decisions 6 and 45). The way out that depends on no other hook is the stop token (see Constraint conflicts). |
| (g) Bash hook floor ~30.6 ms, one perl parse adds ~47 ms | Every hook has a bash-only early exit that spawns nothing, and env-only prefilters run before stdin is read. Decision 33's target is ~131 ms for the applies path. |
| (h) In one headless run each, `.claude/settings.json` hot-reloaded and plugin `hooks.json` did not | Settings changes land in the same commit as the files they point at. The no-shim verdict rests on exit 127 being non-blocking; (h) only supports it (see Shims). |
| Method: `--max-turns` is absent from `claude --help` in 2.1.280 | Nothing in this design relies on a turn cap, for coordinators or anyone else. |
| 7417f0c: `/proc/<pid>/stat` costs 45-70 ms per read on this host; `cmdline`, `cwd`, `exename` and `ppid` cost under 1 ms | Holder liveness reads a pid and `/proc/<pid>/cmdline` only, never `stat` or `status`. |

## Inventory

Every regular file directly in `plugins/butler/hooks/` and every hook registration in
`plugins/butler/hooks/hooks.json` and `.claude/settings.json` has one row below (Decision 14). Package 16
flattened the new hooks from its pre-cutover staging tree (a top-level batch and a `guards/`
sub-batch) straight into `hooks/` (Decision 40)
and rewrote both registration files to the guarded command form, leaving exactly one Stop entry across
both files (Decision 5) and dropping every retired script (Decision 6). Every row below carries a
"keep" verdict now that the flatten and the registration rewrite have both landed (Decision 38: each
registered command's script exists, passes `bash -n`, and exits 0 or 2 on an empty payload).

Retired outright (Decision 6): `.reporter-stop-ok`, `.subagent-guard/force-stop`,
`.drive-solo/.stop-ok`, `.drive-solo/.run-finished`, the continuity `MARK.stop-ok`,
`CCPRAXIS_DRIVE_STOP_OK`, `CCPRAXIS_REPORTER_STOP_OK`, `CCPRAXIS_CONTINUITY_STOP_OK`, and
`MAX_BLOCKS=3` (Decision 45). Also retired: the three machine registries (`.drive-solo-active`,
`.reporter-active`, `.continuity-active`), both watchers (`bp-watch.pl --arm`, `bp-continuity.pl hold`)
and the wakeup-pending markers. Decision 4 keeps only the fleet files `runs/.paused`, `runs/.shutdown`
and `runs/<pkg>.force-stop`.

**Target registrations after the cutover** (Decision 5: exactly one Stop entry across both files):

| source | event | matcher | hook |
|---|---|---|---|
| hooks.json | PreToolUse | Bash | guard-bash.sh, guard-git-mutations.sh --only-during-butler-run, arm-on-entry.sh, continuity-off-check.sh |
| hooks.json | PreToolUse | Edit\|Write\|MultiEdit\|NotebookEdit | guard-writes.sh, ledger-guard.sh, guard-blueprint-write.sh |
| hooks.json | PreToolUse | Edit\|Write\|MultiEdit\|NotebookEdit\|Task\|Agent | gate-shutdown.sh |
| hooks.json | PreToolUse | Task\|Agent | bind-dispatch.sh, track-dispatch.sh, guard-fork.sh |
| hooks.json | PreToolUse | Task\|Agent\|Bash | context-ceiling.sh |
| hooks.json | PreToolUse | (none) | wait-shape-guard.sh |
| hooks.json | PreToolUse | AskUserQuestion | guard-ask-operator.sh |
| hooks.json | PostToolUse | Task\|Agent | track-dispatch.sh |
| hooks.json | PostToolUse | Task\|Agent\|Bash | context-ceiling.sh |
| hooks.json | SubagentStop | (none) | track-dispatch.sh |
| hooks.json | Stop | (none) | stop-gate.sh |
| hooks.json | Notification | permission_prompt | record-prompt.sh |
| hooks.json | PermissionDenied | (none) | record-denial.sh |
| hooks.json | PreToolUse | (none) | denial-breaker.sh |
| hooks.json | PreToolUse | (none) | ac-standdown-gate.sh |
| hooks.json | PostToolUse | (none) | denial-breaker.sh |
| hooks.json | PostToolUseFailure | (none) | denial-breaker.sh |
| hooks.json | SessionStart | (none) | denial-breaker.sh |
| hooks.json | UserPromptSubmit | (none) | arm-nudge-prompt.sh |
| hooks.json | SessionStart | (none) | session-start-nudge.sh |
| settings.json | PreToolUse | Bash | guard-git-mutations.sh (sec 2.2 settings form) |

This is 27 hooks.json commands and 1 settings.json command, every one in the guarded registration form
of spec 16's section 2.2 (`unset BASH_ENV; f=...; w=.../run-hook.sh; [ -f "$f" ] && [ -f "$w" ] || exit 0;
bash -n "$f" && bash -n "$w" || exit 0; exec env -u SHELLOPTS bash "$f"`), so a missing or broken script
or wrapper never blocks (RT-M1), and neither BASH_ENV nor SHELLOPTS reach the hook's own bash (RT-L7).
SubagentStop carries track-dispatch.sh alone, added per package 16's carried note so a subagent's own
completion still clears its writer marker.

### file: arm-on-entry.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree, in batch B; it still arms the calling session on a real director call, unchanged from package 03's build.

### file: bind-dispatch.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree; it still records or denies the tool_use_id binding for Task and Agent dispatch, unchanged from package 12's build.

### file: context-ceiling.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree's guards sub-batch; it still runs the merged hard-ceiling and soft-ceiling guard for coordinators on both PreToolUse and PostToolUse.

### file: continuity-off-check.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree; it still writes the ticket for a real butler-continuity or butler-hold invocation, unchanged from package 04's build.

### file: gate-shutdown.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree's guards sub-batch; it still denies new work and worksite edits under a fleet stop file, on the merged edit-tools-plus-dispatch matcher.

### file: guard-ask-operator.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree's guards sub-batch; it still refuses AskUserQuestion while unattended work runs and files the question as an almanac pending decision.

### file: guard-bash.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree's guards sub-batch; it still carries the merged coordinator, headless-background, judge-checks and validation-interlock Bash denials in one process.

### file: guard-blueprint-write.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree's guards sub-batch; it still denies direct blueprint.md edits and hand-written package ledgers, plus the case and 8.3-alias rule package 16 added in batch A.

### file: guard-fork.sh
verdict: keep
reason: Package 19 adds this file (Decision 64/90): a PreToolUse guard on Task/Agent that denies every dispatch whose subagent_type is the literal string fork, overridable once per session by butler-fork-ok.

### file: guard-git-mutations.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree's guards sub-batch; it still denies destructive git under the same two registrations this repo has always run, hooks.json and settings.json.

### file: guard-writes.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree; it still checks write-set containment and role separation for the driver and each bound subagent, unchanged from package 13's build.

### file: hooks.json
verdict: keep
reason: It remains the plugin's hook registry, rewritten by package 16 to the target registration table in this section with every command in the guarded 2.2 form and exactly one Stop entry.

### file: ledger-guard.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree; it still validates the resulting content of a package-ledger write, unchanged from package 13's build.

### file: run-hook.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree; it stays the one bash-only entry wrapper every hook execs, unchanged from package 03's build, and its own relative script lookup already resolves from the flattened hooks/ directory.

### file: stop-gate.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree; it remains the one Stop gate for the whole plugin, unchanged from package 06's build, now the only Stop registration in either file.

### file: track-dispatch.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree's guards sub-batch; it still tracks the one write-capable worker for coordinators and armed drivers, now also registered on SubagentStop per package 16's carried note.

### file: wait-shape-guard.sh
verdict: keep
reason: Package 16 flattened this file from the pre-cutover staging tree's guards sub-batch; it still denies the four polling pathologies for coordinators, with the repeat detector folded in from package 14's build.

### file: ac-standdown-gate.sh
verdict: keep
reason: Package 11 (tooling-backlog) added this file; it denies every subagent tool call while an AC-loss stand-down is active, registered with no matcher so it runs for every tool. Exempts `SendMessage` and `SubagentHandback` (fix-batch H2) so a denied worker can still deliver the report its own denial text asks for -- the same two tools `BpHook::DenialBreaker`'s `@CLASSIFIER_EXEMPT_TOOLS` already exempts, for the identical reason. A marker older than `BpAcWatch::STALE_AFTER` (30 minutes) with no live monitor self-heals to phase `ac` instead of refusing forever (fix-batch H3).

### registration: hooks.json PreToolUse [Bash] guard-bash.sh
verdict: keep
reason: The merged Bash guard's own registration, in the guarded 2.2 command form, unchanged in matcher from the pre-cutover table.

### registration: hooks.json PreToolUse [Bash] guard-git-mutations.sh
verdict: keep
reason: Re-registered on Bash with the same --only-during-butler-run argument in the guarded 2.2 form, now meaning this session is armed or is a coordinator.

### registration: hooks.json PreToolUse [Bash] arm-on-entry.sh
verdict: keep
reason: The arming check's own Bash registration in the guarded 2.2 form, replacing the old mark-wakeup.sh entry on the same matcher.

### registration: hooks.json PreToolUse [Bash] continuity-off-check.sh
verdict: keep
reason: The ticket-writing check's own Bash registration in the guarded 2.2 form, replacing the old guard-run-finish.sh entry on the same matcher, and (package 28, Decision 105) the one writer of butler-continuity, butler-hold and butler-fork-ok tickets.

### registration: hooks.json PreToolUse [Edit|Write|MultiEdit|NotebookEdit] guard-writes.sh
verdict: keep
reason: Re-registered on the same four edit tools in the guarded 2.2 command form, at the flattened path this file has always kept.

### registration: hooks.json PreToolUse [Edit|Write|MultiEdit|NotebookEdit] ledger-guard.sh
verdict: keep
reason: Re-registered on the same four edit tools in the guarded 2.2 command form, at the flattened path this file has always kept.

### registration: hooks.json PreToolUse [Edit|Write|MultiEdit|NotebookEdit] guard-blueprint-write.sh
verdict: keep
reason: Becomes the one registration of the merged blueprint write guard on the four edit tools, in the guarded 2.2 form, also carrying the ledger-creation rule.

### registration: hooks.json PreToolUse [Edit|Write|MultiEdit|NotebookEdit|Task|Agent] gate-shutdown.sh
verdict: keep
reason: Folded into the single gate-shutdown registration whose matcher covers the four edit tools plus Task and Agent, in the guarded 2.2 form.

### registration: hooks.json PreToolUse [Task|Agent] bind-dispatch.sh
verdict: keep
reason: The dispatch-binding check's own Task and Agent registration in the guarded 2.2 form, unchanged in matcher from package 12's build.

### registration: hooks.json PreToolUse [Task|Agent] track-dispatch.sh
verdict: keep
reason: Becomes the PreToolUse Task|Agent registration of the merged tracker, in the guarded 2.2 form, absorbing the drive-solo tracker's old registration on the same tools.

### registration: hooks.json PreToolUse [Task|Agent] guard-fork.sh
verdict: keep
reason: Package 28 (Decision 105) re-registered this off Bash: it moved into the Task|Agent group because its Bash half only wrote butler-fork-ok tickets, and that write now lives in continuity-off-check.sh.

### registration: hooks.json PreToolUse [Task|Agent|Bash] context-ceiling.sh
verdict: keep
reason: Becomes the PreToolUse Task|Agent|Bash registration of the merged context-ceiling guard, in the guarded 2.2 form, denying a dispatch or a Bash call past the hard ceiling.

### registration: hooks.json PreToolUse [] wait-shape-guard.sh
verdict: keep
reason: Becomes the single matcher-less registration of the merged wait-shape guard, in the guarded 2.2 command form, folding the repeat detector in.

### registration: hooks.json PreToolUse [AskUserQuestion] guard-ask-operator.sh
verdict: keep
reason: Re-registered on AskUserQuestion in the guarded 2.2 form; the successor lands at the same flattened path package 09 later re-points at the almanac store.

### registration: hooks.json PostToolUse [Task|Agent] track-dispatch.sh
verdict: keep
reason: Becomes the PostToolUse Task|Agent registration of the merged tracker, in the guarded 2.2 form, appending the ledger line and resolving the dispatch record in one process.

### registration: hooks.json PostToolUse [Task|Agent|Bash] context-ceiling.sh
verdict: keep
reason: Becomes the PostToolUse Task|Agent|Bash registration of the merged context-ceiling guard, in the guarded 2.2 form, attaching the soft-ceiling guidance.

### registration: hooks.json SubagentStop [] track-dispatch.sh
verdict: keep
reason: Added per package 16's carried note from package 14, so a subagent's own SubagentStop still clears the writer marker that PostToolUse alone would miss for an async dispatch.

### registration: hooks.json Stop [] stop-gate.sh
verdict: keep
reason: The one Stop registration left in either file (Decision 5), in the guarded 2.2 form, pointing at the same stop-gate.sh this section's file row describes.

### registration: settings.json PreToolUse [Bash] guard-git-mutations.sh
verdict: keep
reason: This repo keeps its unconditional protection against destructive git, run from the clone by $CLAUDE_PROJECT_DIR, now rewritten to the guarded 2.2 settings form by package 16's batch B.

### file: record-denial.sh
verdict: keep
reason: Added by never-halt package 06; it records each auto-mode classifier denial to denials.jsonl for a driver or coordinator session, prints nothing and never blocks.

### file: record-prompt.sh
verdict: keep
reason: Added by never-halt package 06; it records each permission prompt to prompts.jsonl for a driver or coordinator session, so the holder can wake the driver.

### registration: hooks.json Notification [permission_prompt] record-prompt.sh
verdict: keep
reason: Registered on Notification with the permission_prompt matcher in the guarded 2.2 form; Notification output is discarded, so the hook only records.

### registration: hooks.json PermissionDenied [] record-denial.sh
verdict: keep
reason: Registered without a matcher on PermissionDenied in the guarded 2.2 form; it prints nothing, so it never asks the model to retry.

### file: denial-breaker.sh
verdict: keep
reason: Added by never-halt package 07; a deny-only circuit breaker that refuses a driver or coordinator agent's classifier-bound call once its auto-mode denial counts reach 2 consecutive or 17 total, and records per-call reset points on PostToolUse and PostToolUseFailure.

### registration: hooks.json PreToolUse [] denial-breaker.sh
verdict: keep
reason: Registered without a matcher in the guarded 2.2 form; it denies or abstains, never emits a decision on stdout.

### registration: hooks.json PreToolUse [] ac-standdown-gate.sh
verdict: keep
reason: Package 11 (tooling-backlog) added this registration with no matcher, so every tool call is checked, but the acstanddown env-only atom keeps it a pure bash no-op (no perl spawn) whenever the stand-down marker is absent.

### registration: hooks.json PostToolUse [] denial-breaker.sh
verdict: keep
reason: Registered without a matcher in the guarded 2.2 form; it records the agent's reset point and prints nothing.

### registration: hooks.json PostToolUseFailure [] denial-breaker.sh
verdict: keep
reason: Registered without a matcher in the guarded 2.2 form; an allowed call that fails still reset auto mode's consecutive count, so it records the same reset point and prints nothing.

### registration: hooks.json SessionStart [] denial-breaker.sh
verdict: keep
reason: Added by never-halt package 07 (FIX-3); registered without a matcher in the guarded 2.2 form so it fires on every SessionStart, resetting the per-session total_since offset so a resumed session isn't permanently falsely tripped.

### file: arm-nudge-prompt.sh
verdict: keep
reason: Added by never-halt package 11 (Decision 43, N3); pure bash, it records each operator prompt's epoch and suggests arming on an unarmed prompt that signals unattended work.

### registration: hooks.json UserPromptSubmit [] arm-nudge-prompt.sh
verdict: keep
reason: Registered without a matcher on UserPromptSubmit in the guarded 2.2 form; it never blocks and prints at most one additionalContext line.

### file: session-start-nudge.sh
verdict: keep
reason: Added by never-halt package 12 (Decision 43, N6 and N1-now), extended by blueprint where-things-go package 10 (specs/10-gatherer-and-digest-spec.md sec 2.6): SessionStart runs one route on every source: re-attach, then the project digest, then the armed nudges.

### registration: hooks.json SessionStart [] session-start-nudge.sh
verdict: keep
reason: Registered without a matcher on SessionStart in the guarded 2.2 form, beside denial-breaker.sh; it never blocks, writes nothing, and prints at most one additionalContext line, on every source armed or not.

## BpHook core API

Package 03 builds `plugins/butler/scripts/BpHook.pm` and `plugins/butler/hooks/run-hook.sh`.
The core is the only code that decides "is this session running butler work" (Decision 3). Every
hook reads that answer through it, and none asks whether any drive is active in the project, which
was the defect behind bug 20260922-210421-0468. Everything below is tested in-process in
`plugins/butler/tests/t/hook-core-api.t`, with `BUTLER_STATE_DIR` pointed at a tempdir and payloads
passed as hashes (Decision 12).

`BpHook::prompt_marker` (never-halt package 11) builds the path to the per-session prompt marker
arm-nudge-prompt.sh writes, and `BpHook::last_prompt_epoch` and `BpHook::operator_off` are the
readers of that marker's contents and of the off record's actor, used by the chart reminder's N5
nudge to decide how long the session has gone without an operator message and whether an operator
turned continuity off.

### Entry path and process budget

Harness-facts records the rule that each perl hook is registered guarded, as
`[ -f "$f" ] || exit 0; exec perl "$f"`, because `perl <missing file>` exits 2 and 2 blocks. In this
design every registered command runs bash, and the one perl exec is guarded inside the wrapper.
Registration form, with spaces around each `;`. The coverage test takes the first token that ends in
`.sh` as the script name, and a token ending in `;` would hide it:

```
f="${CLAUDE_PLUGIN_ROOT}/hooks/stop-gate.sh" ; [ -f "$f" ] || exit 0 ; exec bash "$f"
```

Each per-hook file (stop-gate.sh, arm-on-entry.sh, the guards, and the rest) is exactly this shape,
with its own module name and its own prefilter clauses (see Guard message budgets). The file belongs
to the package that owns the hook, so a package changes its own prefilter without touching 03's files:

```
#!/usr/bin/env bash
# stop-gate.sh -- the one Stop gate. Logic in BpHook/StopGate.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" StopGate --pre ledger,armed -- "$@"
```

`run-hook.sh <Module> [--pre <clause>]... -- [hook args]` uses bash builtins only. It never uses
`$(...)`, a pipe or an external command on the path to the early exit. A clause is a comma-separated
list of atoms and holds when any atom holds. The hook applies only when every clause holds. The atoms
are a closed set owned by 03:

| atom | holds when |
|---|---|
| `ledger` | `BP_LEDGER` is non-empty |
| `coordinator` | `BP_LEDGER` is non-empty and `BP_ROLE` is empty or `coordinator` |
| `stopfile` | `BP_DIR` is set and `runs/.shutdown`, `runs/.paused` or `runs/$BP_PACKAGE.force-stop` exists under it |
| `armed` | `armed/<sid>` exists, or the session id could not be extracted |
| `driver` | the first line of `armed/<sid>` contains `"role":"driver"`, or the session id could not be extracted |
| `text:<s>` | the raw payload contains `<s>` |

Steps:

1. `r=${BASH_SOURCE[0]}` (this file's own path). Parse the `--pre` clauses up to `--`.
2. Evaluate every clause made only of env atoms (`ledger`, `coordinator`, `stopfile`). If one fails,
   `exit 0` before reading stdin, as today's hooks already do.
3. Bulk read: `IFS= read -r -N 8388608 -t 10 BP_PAYLOAD`. Never `$(cat)`, which hung forever on an
   inherited pipe (bug 20260828-095201-7c1e), and never `read -d ''`, which reads a pipe one byte per
   syscall (red-team measured 5.7 s for 200 KB). A status above 128 (timeout), or a payload of exactly
   the cap, sets `BP_PAYLOAD_TRUNCATED=1`.
4. Extract the session id without forking: `sid=${BP_PAYLOAD#*\"session_id\":\"}; sid=${sid%%\"*}`,
   kept only if `[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]]`. If extraction fails, `armed` and `driver`
   count as holding, so the wrapper falls through to perl and never exits on a guess.
5. Evaluate the remaining clauses. When one fails, `exit 0`. That path costs one bash process and no perl.
6. `s=${r%/*}/../scripts`, and if `$s/BpHook.pm` is missing, `s=${r%/*}/../../scripts` (while under
   `next/`). If it is still missing, `exit 0`. Then:

```
exec perl -I"$s" -e 'our $X = 0; END { $? = $X } my $r = eval { require BpHook; BpHook::main(@ARGV) }; $X = (defined $r && $r == 2) ? 2 : 0; exit $X' "$module" "$@" <<<"$BP_PAYLOAD"
```

The module is loaded by `require` inside `eval`, so a missing dependency, a compile error or a `die`
at load time becomes exit 0. `main` loads the per-hook module (`BpHook::<Module>`) with `require`
inside its own `eval`, never with `use`. The END block overrides `$?`, so even a module that calls
`exit` itself cannot produce anything but 0, unless `main` returned 2. For the Stop gate, exit 0 means
the stop is allowed. That is the gate's fail direction, and it is what makes a broken promotion fail
open instead of looping. `hook-core-spawn-budget.t` includes one case where `BpHook.pm` `require`s a
missing module, and asserts exit 0.

Registration shell, hook file, wrapper and perl form one `exec` chain, so an invocation is one
process. That meets Decision 33's budget (the wrapper plus at most one perl, payload parsed once) and
Decision 20's at-most-one-perl rule. `plugins/butler/tests/t/hook-core-spawn-budget.t` proves it with
the PATH shim, and times a 30 KB and a 200 KB payload alone for the ledger. The wall-time target is
harness-facts (g)'s floor plus 100 ms, about 131 ms, measured alone and recorded in the ledger, never
asserted in the sweep.

### Perl API (`BpHook.pm`)

```
main($module, @args)          -> exit code. Reads STDIN once, in bulk (binmode, sysread loop), decodes
                                 once, requires and calls BpHook::<Module>::run($payload, @args) inside
                                 eval. Returns 2 only when run() returned 2; any exception -> 0, plus
                                 one line appended to <state>/hook-errors.log (rolled at 256 KiB).
                                 Modules never call exit.
payload()                     -> the decoded hashref; {} if the JSON is bad or BP_PAYLOAD_TRUNCATED.
payload_ok()                  -> false when payload() had to return {}. Fail-closed hooks deny on it.
session_id($p)                -> payload session_id if it matches ^[A-Za-z0-9_-]{1,128}$, else undef.
agent_id($p)                  -> undef when the payload has no agent_id (main thread). When present:
                                 the id if it matches ^[A-Za-z0-9_-]{1,64}$, else '?'. Defined means a
                                 subagent is calling; '?' is never used to build a path.
role($p)                      -> 'coordinator' | 'judge' | 'driver' | 'reporter' | 'manual'.
is_armed($sid)                -> true for a coordinator; else armed/<sid> exists. No age test.
arm($sid, role=>R, by=>B, transcript_path=>T)  -> under flock armlock/<sid>: writes armed/<sid>,
                                 removes off/<sid> only when B is 'on'.
disarm($sid, actor=>A, reason=>T) -> under flock armlock/<sid>: removes armed/<sid>, silence/<sid>,
                                 running/<sid>, holder/<sid>.json and the session's stop token;
                                 writes off/<sid>.
latest_is_off($sid)           -> off/<sid> exists (Decision 36).
set_silence($sid, reason=>T)  -> writes silence/<sid>. Only butler-continuity.pl calls it.
take_silence($sid)            -> 1 iff silence/<sid> parses, names this sid, carries a reason of 2+
                                 words and "by":"butler-continuity", and this call unlinked it. A
                                 malformed file (for example one made by touch) is unlinked and ignored.
holder($sid)                  -> holder record hashref or undef.
holder_live($sid, $p)         -> the liveness rule of the "Liveness at Stop" section (Decision 130).
running_work($sid, $p)        -> list of {id, type}: the payload's running background_tasks (valid ids
                                 only, payload order; non-subagent entries dropped while a live holder
                                 runs, since that holder is itself a shell task) united with -- ONLY
                                 while the holder is dead (Decision 130, M1+S3) -- the holder record's
                                 items whose agent-<id>.jsonl or cached .output changed within 60 s
                                 (Decision 129). Deduped. Stats only, no process. `butler-continuity
                                 silence` also calls this directly, with no background_tasks, to
                                 refuse on the holder's dead-holder evidence even before any Stop.
set_running_snapshot($sid, \@work) -> writes running/<sid> atomically:
                                 {"session_id":sid,"at":iso,"work":[{"id":..,"type":..},...]}.
clear_running_snapshot($sid)  -> unlinks running/<sid>.
running_snapshot($sid)        -> arrayref of {id, type}, or undef when the file is missing,
                                 unparsable, names another session or holds no valid entry.
log_reason($sid, $actor, $verb, $text, $project) -> appends one reason-log line.
invocations($command, $name)  -> list of argv arrayrefs, one per REAL invocation of $name.
write_ticket($p, $name, \@argv, operator=>0|1, background=>0|1) -> command binding (below).
take_ticket($name, \@argv)    -> the ticket hashref, undef (none), or the string 'ambiguous'.
mint_stop_token($sid)         -> a fresh token string, or undef when it cannot be stored.
revoke_stop_token($sid)       -> removes this session's token, if any.
take_stop_token($token)       -> the session id the token was minted for, or undef. Single use.
gc_sessions()                 -> removes state of sessions whose recorded transcript file is gone.
state_dir()                   -> continuity state root, or undef (then nothing is armed). The one
                                 resolver: hooks, commands and the statusline all call it.
data_dir($p)                  -> the project's .ccpraxis-local-data, or undef.
deny(@lines)                  -> prints the lines to STDERR, returns 2.
context($text)                -> prints {"hookSpecificOutput":{"hookEventName":...,
                                 "additionalContext":$text}} to STDOUT, returns 0.
```

### Session roles

The payload's `session_id` is authoritative (Constraints H6, harness-facts (b) and (d)). The role is
resolved per invocation, in this order:

| role | how it is known | armed |
|---|---|---|
| coordinator | `BP_LEDGER` is set in the hook's environment and `BP_ROLE` is empty or `coordinator` | by construction (Decision 2). There is no file, and it can never be turned off or silenced (Decision 25). |
| judge | `BP_LEDGER` is set and `BP_ROLE` is anything else (harvest, resolve or conformance judge) | never. A one-shot process must be free to end. |
| driver | `armed/<sid>` exists with `"role":"driver"` (written by arm-on-entry at the director call, or by the drive-solo skill's first step `butler-continuity on --role driver`) | yes |
| reporter | `armed/<sid>` exists with `"role":"reporter"` (`butler-continuity on --role reporter`, the reporter skill's first step, Decision 24) | yes |
| manual | anything else, including an armed session with `"role":"manual"` (`/butler:continuity on` or agent self-arm) | only when the file exists |

Role `reporter` changes no gate or guard behaviour. It is recorded so that `status` shows what armed
the session, and it keeps the four roles apart for the done criteria of package 03.

**Subagents and forks.** A subagent's tool calls carry its parent's `session_id` (harness-facts (b)),
so it shares the session's role and arm state, and `agent_id` is how it is told apart. A **fork** is a
subagent dispatched with `subagent_type: fork`. It inherits the parent's whole conversation, including
a driver's live task state and instructions. It is not a second session, has no role of its own, and
is never the driver. The core does not rely on `agent_type` being `fork`. Every rule below applies to
any payload that carries an `agent_id`. Bug 20260922-205201-f421 (Decision 46) is closed by three such
rules. A subagent's director call arms nothing and is denied in a driving session (arm-on-entry). A
subagent's dispatch is denied in a driving session (bind-dispatch). A subagent's
`butler-continuity on|off|silence` and `butler-hold` are refused when its ticket carries an `agent_id`.

Harness-facts (a) measured `agent_id` only for `general-purpose` subagents, not for forks. Package 03
measured this before any rule relied on it, capturing one fork's PreToolUse with
`plugins/butler/scripts/bp-hook-probe.pl` in a nested `claude -p` in a scratch project (the Decision 28
method): `agent_id` is present, so the rules above stand unconditionally.

### Command binding: tickets and stop tokens

A Bash command is never told its session, and `$CLAUDE_CODE_SESSION_ID` is unverified in-process after
`/compact` or `/clear` (D-1, D-2). A hook is told. Two bindings exist, and the escape path needs only
the second.

**Tickets** (any time, for example arming when no stop is pending). The PreToolUse hook
`continuity-off-check.sh` writes one ticket per real, predictable invocation of `butler-continuity`,
`butler-hold`, `butler-fork-ok` (package 28, Decision 105) or `almanac-bug` (package 12,
12-bug-claimant-and-triaging) -- it is the one and only writer of all four names. `guard-fork.sh`
writes none: its Bash-branch ticket write moved into `continuity-off-check.sh` so a second writer
never produces two tickets for one call:

- Key: `k` = lowercase hex SHA-1 (core `Digest::SHA`) of `join("\0", $name, @argv)`, where `$name` is
  normalised to `butler-continuity`, `butler-hold`, `butler-fork-ok` or `almanac-bug`. The command computes the same
  `k` from its own `@ARGV`, so a ticket is found only for the exact same command.
- File: `<state>/tickets/<k>/<session_id>.<tool_use_id>.json`, for example
  `{"session_id":"abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10","tool_use_id":"toolu_01HG32t2hGKSSJK7U3qVvWJm","agent_id":null,"operator":false,"background":true,"transcript_path":"C:/Users/André/.claude/projects/C--Development-ccpraxis/abb7e549-....jsonl","cwd":"C:/Development/ccpraxis","at":1790212345}`.
- `take_ticket` reads the one directory `tickets/<k>/`, deletes entries older than 30 s, and then:
  none left returns undef; exactly one entry left is claimed by an atomic rename, read and deleted.
  Two or more left are ambiguous ONLY when they span more than one `session_id`, or one `session_id`
  with differing `agent_id` (undef counts as its own value; a main-thread call and a subagent call
  never merge) -- that case returns `'ambiguous'` and claims nothing. Two sessions that issue the
  same command inside 30 s get a refusal, never each other's binding. Same-session, same-agent
  duplicates (task 50: a `butler-hold` call denied by another `PreToolUse` guard leaves its ticket,
  and an identical retry adds another) instead bind: every one of them is claimed (rename, read,
  delete; an entry another process claimed first is skipped, not fatal), and one hashref is built
  from all of them -- base record = the claimed entry with the greatest `at` (ties broken by file
  name, lexically last); `operator` true only if every claimed entry has `operator` true (a stale
  ticket can never upgrade a call to operator); `background` = the base record's value, except that
  another claimed entry sharing the SAME greatest `at` with a different `background` forces the
  conservative `false`. A ticket orphaned by a refused permission prompt or a sibling hook's deny
  dies within 30 s.
- Residual, stated rather than hidden: if this call's own hook wrote nothing (a hook failure) while
  another session's identical, never-run call left the only live ticket in the same 30 s, the command
  takes that ticket. That needs two independent faults, and it affects one command.
- The 30 s window covers the gap between hook and command. If a permission prompt outlasts it, the
  command refuses in one line and the agent runs it again.

The argv prediction is a bash-compatible splitter for a small subset, not `Text::ParseWords` (which
drops a backslash before any character inside double quotes, unlike bash). Unquoted words with `\`
escapes, single-quoted strings (literal), and double-quoted strings without `$`, backtick or `\` are
split exactly as bash splits them. A word with an expansion outside single quotes (`$`, backtick, `*`,
`?`, `[`, `{`, or a leading `~`) cannot be predicted, and the hook writes no ticket for that
invocation. The command then refuses unless it carries a valid stop token. This is why every
agent-facing template quotes the reason in single quotes.

**Stop tokens** (only when the gate denies a stop). The Stop gate itself mints a token each time it
denies, and prints it in the denial text:

- Format: 8 lowercase hex characters, from 4 bytes of `/dev/urandom` (fallback: SHA-1 of time, pid
  and `rand`). Files: `<state>/stop-tokens/<token>` holding `{"session_id":...,"minted_at":...}`, and
  `<state>/stop-tokens/<sid>.current` holding the token. A name that already exists is re-minted.
- Bound to (session_id, that Stop event): every Stop gate run for the session starts with
  `revoke_stop_token($sid)`, so a token dies at the next Stop, which is the end of the turn the
  denial forced. `disarm` also revokes it. There is no wall-clock expiry, so a long turn keeps its
  way out.
- `take_stop_token($t)`: `$t` must match `^[0-9a-f]{8}$`. The command claims `stop-tokens/<t>` by
  rename, reads the session id, checks that `<sid>.current` still names `$t`, and deletes both. Any
  failure returns undef. The lookup is one file open, never a scan.
- Only the `Stop` event mints. SubagentStop is not registered, and the gate also refuses to mint for
  any payload that carries an `agent_id` or whose `hook_event_name` is not `Stop`.
- A token proves the session, never the operator. It is accepted by `butler-continuity off`,
  `butler-continuity silence` and `butler-hold`, and by nothing else.

`butler-fork-ok.pl` uses the same ticket API for its own binding, but has no `--token` path of its
own (Decision 91 scope: stop tokens are accepted by `butler-continuity off|silence` and `butler-hold`
only) and refuses outright when no ticket resolves. On success it writes its own one-shot record,
`fork-ok/<session_id>.json`, consumed by `guard-fork.sh`'s next fork dispatch of that session.

**How a command resolves its binding** (`butler-continuity.pl` and `butler-hold.pl` alike):

1. Parse and validate the arguments first (verb, reason, ids, token format). A bad argument refuses
   in one line and consumes nothing.
2. `take_ticket`. If it returns one ticket: that is the binding. If `--token` is also given and valid
   for a different session, refuse. If the token is valid for the same session, it is consumed. An
   invalid token next to a good ticket is ignored.
3. Otherwise (no ticket, or ambiguous), a valid `--token` is the binding, with `agent_id` unknown
   (treated as the main thread), `operator` false, and `background` unknown (treated as true).
4. Otherwise refuse, in one line, and change nothing.

A fork that inherited the denial text could use the token only when its own ticket is missing,
because a ticket with an `agent_id` refuses first. That is a double fault inside one turn, and it is
accepted.

`invocations($command, $name)` is the shared "a real invocation, never a mention" matcher (84ae5a1).
It splits the command into segments at `;` `&` `|` and newline, outside single and double quotes only,
so a reason such as `'tests & docs done'` stays one word. It opens a new segment at `$(`, backtick,
`<(` and `>(`. Heredoc bodies are skipped. A segment is an invocation when its command word, after
leading `VAR=value` words, after the transparent prefixes `timeout <duration>`, `env [VAR=value]...`,
`nice [-n N]`, `nohup`, `command` and `exec`, and after an interpreter (`perl`, `bash`, `sh`) plus its
options, has a basename matching `^$name(\.sh|\.pl)?$`. A segment whose first word is a reader (`echo`,
`printf`, `grep`, `rg`, `cat`, `sed`, `awk`, `head`, `tail`) is not an invocation, and neither is a
quoted string. Packages 04 (ticketing), 07 (director calls) and 14 (the headless-background exemption)
all use it. Its tests cover reasons containing `; & | $ !`, a newline and non-ASCII text.

### Paths and bytes

Payload strings used as paths are converted to UTF-8 byte strings (`utf8::encode` only if
`utf8::is_utf8`), and backslashes are turned into `/`. Git-for-Windows perl opens `C:/...` directly.
Nothing re-encodes a string that is already bytes, because `André` would come out as `AndrÃ©`.
`data_dir($p)` returns `CCPRAXIS_DATA_DIR` if absolute. Otherwise it uses `BpProjectRoot.pm` (reused,
not copied) from `CLAUDE_PROJECT_DIR` or the payload `cwd`. The upward walk stops when `dirname`
returns its own input, because a drive-letter path reaches the fixed point `C:`, and that is the
25-second hang `hook-path-walk-and-scope.t` recorded. `hook-core-api.t` re-expresses that case.
The only pids the core reads are holder pids, which perl's `$$` wrote and which are read back through
`/proc` in the same MSYS namespace. Liveness never compares an MSYS pid with a WINPID.

## Arm state storage and format

One store, one writer module (BpHook.pm), keyed by the payload `session_id` (Decision 2; harness-facts
(d)). Every reader goes through `BpHook::is_armed` or the documented bash `-f` test in `run-hook.sh`,
which is part of the core.

arm-state-path: ~/.claude/butler-state/continuity/armed/<session_id>

The root is `$BUTLER_STATE_DIR/continuity` when `BUTLER_STATE_DIR` is set and absolute, otherwise
`$HOME/.claude/butler-state/continuity` (`$USERPROFILE` if `HOME` is unset). A root that is not
absolute counts as nothing armed, which fails open, and writers refuse in one line. `BpHook::state_dir()`
is the only resolver: the hooks, both commands and the statusline (package 10) call it, and
`plugins/butler/tests/t/continuity-statusline-badge.t` asserts that the statusline resolves the same
root as the core. The store is machine-level, not per project. Session ids are globally unique, the
wake-lock lease must see every armed session in one directory scan, and the statusline reads it knowing
only the session id. It lives outside the live-install git tree. Inside a sandbox, `$HOME/.claude` is
the project's claude-home, so container sessions have their own store and their own busy-lease.

```
continuity/
  armed/<sid>             exists iff armed. One JSON line. mtime = last Stop gate run.
  armlock/<sid>           flock target for arm and disarm.
  off/<sid>               exists iff the latest continuity event is an off (Decision 36).
  silence/<sid>           exists iff one stop is to be let through.
  running/<sid>           exists iff the latest armed, non-coordinator Stop of the session was denied
                          while work was running. Holds that work; `silence` reads it (package 38).
  holder/<sid>.json       the session's holder record (Holder protocol).
  holder/<sid>.lock       flock target for become, extend and holder exit.
  tickets/<k>/            command-binding tickets for one exact command.
  stop-tokens/            gate-minted stop tokens and one <sid>.current pointer per session.
  fork-ok/<sid>.json      package 19's one-shot fork override token, minted by butler-fork-ok.
  prompted/<sid>          epoch of the session's last operator prompt (never-halt 11). Written in bash by arm-nudge-prompt.sh, read through BpHook::prompt_marker; not collected by gc_sessions.
  reasons.log             the Decision 7 reason log.
  hook-errors.log         internal errors caught by BpHook::main.
```

Formats, one JSON object per file, written to a same-directory temp file and renamed:

```
armed/abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10
{"session_id":"abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10","role":"driver","by":"arm-on-entry","transcript_path":"C:/Users/André/.claude/projects/C--Development-ccpraxis/abb7e549-....jsonl","at":"2026-09-24T01:02:03Z"}

off/abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10
{"session_id":"abb7e549-...","actor":"agent","reason":"all packages done; nothing left to run","at":"2026-09-24T05:00:00Z"}

silence/abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10
{"session_id":"abb7e549-...","by":"butler-continuity","reason":"reporting results to the operator","at":"2026-09-24T03:10:00Z"}
```

**Who arms (Decision 1 triggers):**

| trigger | mechanism | role written |
|---|---|---|
| `/butler:continuity on` by the operator | the skill runs `butler-continuity on` | manual |
| drive-solo start | the drive-solo skill's first step `butler-continuity on --role driver`, which also clears an earlier off | driver |
| every later director call | arm-on-entry.sh on a real `bp-drive-next.pl next` from the main thread, skipped when `latest_is_off` | driver |
| reporter start | the reporter skill's first step `butler-continuity on --role reporter` (Decision 24) | reporter |
| agent self-arm per the continuity skill's prose | `butler-continuity on` | manual |
| fleet coordinator | `BP_LEDGER` in the environment; no file | coordinator |

The skill's first step makes an operator-fired drive-solo arm even after an earlier off, because "drive
solo is fired" is one of the operator's arm triggers. The director-call re-arm keeps honouring an off
(Decision 36), and arm-on-entry is then a refresh rather than the only arming path.

**Who disarms: exactly the three operator-allowed paths.** `butler-continuity off` in its operator
form (`/butler:continuity off`), `butler-continuity off --reason` from an agent, and
`butler-continuity silence --reason` for one stop. Nothing else removes `armed/<sid>` or turns a live
session off. There is no age-based expiry: `is_armed` is "the file exists". A coordinator cannot be
disarmed or silenced (Decision 25). The command refuses, and the gate ignores any file for a
coordinator. `arm` and `disarm` serialise on `armlock/<sid>`, so parallel `on` and `off` calls in one
message leave either an arm file or an off file, never both.

**Off is permanent until on (Decision 36).** `off` writes `off/<sid>`. arm-on-entry does not arm a
session that has it. Only `butler-continuity on`, from the operator's `/butler:continuity on`, an agent,
or the drive-solo and reporter first steps, deletes it.

**Garbage collection, which is not a disarm.** `gc_sessions()` deletes every state file of a session
(`armed`, `off`, `silence`, `holder`, its stop token) only when the arm or off record carries a
`transcript_path` and that file no longer exists on disk. A session whose transcript is gone can never
stop again, so nothing is disarmed. Each removal appends one line to the reason log with actor `gc`,
verb `gc` and the reason `transcript gone: <path>`. Records without a `transcript_path` are never
collected. The lease daemon runs it at most once an hour. `fork-ok/<sid>.json` is the one exception:
a fork token is never collected, because `take_token` (not GC) is what removes it, and a token has no
`transcript_path` to key GC off of.

**Resumed sessions.** `--resume` keeps the session id and its transcript file (harness-facts (d)), so
the arm file, an off file and the reason history all carry over untouched and GC never touches them. A
holder record left by the previous process fails the pid check at once, so the first stop after the
resume is gated normally and the agent holds again.

**New session ids.** SessionStart with `source=clear` (and, per D-3, a carry-over clear) is the point
where the id changes. The new id is a new session and starts unarmed, because state is keyed by id and
nothing is carried across. That is Decision 2 as written: drive-solo re-arms at its first director call,
a reporter at its first step, and any other session "only via /butler:continuity on or agent
self-arm". For a manual session after the operator's own `/clear`, the operator re-arms with
`/butler:continuity on`. After a carry-over, the carry-over skill prose tells the fresh session to run
`butler-continuity on` when the work was armed. The old id's arm file is not a live session. It stays
until its transcript is gone, and it stops holding the wake-lock once its transcript has gone an hour
with no activity (Decision 53). Two SessionStart hooks are registered, and neither carries state across a new id: denial-breaker.sh (never-halt 07) moves its own per-agent counting offset, and session-start-nudge.sh (blueprint where-things-go, package 10) runs its one route on every source, both of which keep the id. SessionStart runs one route on every source: re-attach, then the project digest, then the armed nudges. No SessionEnd hook is registered.

**Wake-lock (Decision 18, Decision 53).** `BpContinuityLease.pm` (package 04, rewired by package 16) holds the lock
while an armed session's transcript was written in the last hour. It no longer reads the old
`.continuity-active` registry, which package 16 retired. The one-hour window is safe because the
holder's fixed 50-minute timeout wakes a waiting session (which writes its transcript) before the hour
runs out; it is only the lease's view of activity: it never deletes a file and never changes what
`is_armed` answers. Its refresher daemon becomes the internal verb
`butler-continuity lease --daemon`, which also runs `gc_sessions()`. `keep-awake.ps1` is untouched.

**Statusline contract (package 10).** `scripts/statusline.pl` resolves the root through
`BpHook::state_dir()`, then reads `off/<sid>` (a badge when `"actor":"agent"`) and `silence/<sid>` (a
badge when present), with no subprocess.

## Holder protocol

Decision 1: one command, one or more items, fixed 50 minutes, no timeout parameter. Decision 9: at
most one live holder per session, and re-invocation never leaves the session with zero live holders.

holder-reinvocation: extend

**Why extend, from the evidence.** Item (e) of harness-facts.md shows that every exit of a background
Bash task, normal or killed, wakes an idle interactive session. It also shows a killed task reaches
the agent as `failed with exit code 143`. Replacing would kill the old holder on every re-invocation,
producing a "failed" notification the agent may try to repair, and a two-process handover whose
ordering has to be proven to never reach zero holders. Extending keeps the one process running.
Re-invocation only rewrites its record, and the extending call exits 0 at once. Zero live holders
cannot happen, because the live process never stops, and stacking (bug 20260922-213451-6382) cannot
happen by construction. The holder exists because a background exit is a wake-up: at the deadline its
own exit wakes the session and the gate asks again.

**Command.** `butler-hold [--token <token>] <id> [<id> ...]`, run as a Bash tool call with
`run_in_background: true`. An id is a subagent id (for example `a2f2aacc903afc6ac`) or a background
task id (for example `bsp949ih1`), matching `^[A-Za-z0-9_-]{1,64}$`. `--token` is the stop token from
a denial. Any other argument starting with `-` is refused with
`butler-hold: takes ids only, plus --token from a stop message; the hold is always 50 minutes.`
(exit 1). Files: `plugins/butler/scripts/butler-hold.pl` and the extensionless shim
plugins/butler/bin/butler-hold (Decision 47).

**Binding.** As in "Command binding" above: a ticket, or the stop token. The hook never denies a
foreground call. With neither binding, it prints
`butler-hold: no session binding; use the --token from the stop message, or quote ids plainly.` and
exits 1. If the ticket carries an `agent_id`, it prints
`butler-hold: only the main session holds; a subagent may not.` and exits 1.

**Become or extend** (under `flock` on `holder/<sid>.lock`):

- A holder is running when the record's deadline is in the future and its process passes the pid
  check below. Then the command sets `items` to the old items plus the new ones (order kept, no
  duplicates), `held` to the old `held` (or old `items`, when a record has neither field yet) plus
  any ids not already in it (order kept, never pruned -- it is every id this holder instance was
  ever asked to hold, used only for the exit report), `ext_seq` to (old `ext_seq` // 0) + 1, and
  `deadline` to now + 3000 s, rewrites the record, and prints, from the EXTENDING process's own
  stdout, exactly one line:
  `extended the running holder (pid 832282) until 20:20 (18:20Z); this call exits now, the holder
  keeps waiting`, then exits 0. Extending works from a foreground call too -- indeed the skills tell
  an agent to extend in the foreground while a holder is already running, and background only to
  start the first one (`butler-continuity status` shows `holder: none`).
- Otherwise this process becomes the holder, unless its ticket says `"background":false`, in which
  case it prints `butler-hold: start it with run_in_background: true.` and exits 1. It writes the
  record with a fresh random `token`, its own `pid` (`$$`) and `fp`, the SHA-1 of the bytes of
  `/proc/$$/cmdline` read right after start, `items` = `held` = the argv ids, `ext_seq` = 0, and
  prints `20:20 (18:20Z) holding session abb7e549 until 20:35 (18:35Z): a2f2aacc903afc6ac,
  bsp949ih1`. Then it loops.

```
holder/abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10.json
{"session_id":"abb7e549-...","token":"9f2c41d07ab3e855","pid":832282,"fp":"3b1f...e09a",
 "items":["a2f2aacc903afc6ac","bsp949ih1"],"held":["a2f2aacc903afc6ac","bsp949ih1"],"ext_seq":0,
 "started_at":1790212345,"deadline":1790215345,
 "transcript_path":"C:/Users/André/.claude/projects/C--Development-ccpraxis/abb7e549-....jsonl"}
```

**Every time the running holder prints is a pair, `HH:MM (HH:MMZ)`** -- `BpHook::local_utc_hhmm`
(package 23): local half from `localtime`, UTC half from `gmtime`, both from the same integer
epoch, both evaluated at print time. No zone is hard-coded, `$ENV{TZ}` is never assigned, and no
zone NAME/abbreviation (`%Z`) is ever printed (Git for Windows derives an abbreviation from the
Windows zone name, which is how "W. Europe Standard Time" became "WEST").

**The running holder is not silent between become and exit.** Every 30 s it re-reads the record and,
in order: (1) if `ext_seq` advanced since its last report, one coalesced line
`<T> extended until <D>; added: <ids>` (or `; no new ids`); (2) for every id in `items` whose status
(evidence below) is now `finished`, under the lock, one line each
`<T> finished: <id>; still waiting on: <remaining ids>` (or `: nothing`), and those ids are removed
from `items` (never from `held`) so `butler-continuity status` stops listing them; a quiet tick (no
extension, no finish) writes nothing, so the record file stays byte-identical. It exits when
`items` is empty after pruning, or at the deadline, or when the record is gone (`off`) or carries
another token (superseded), or on SIGTERM/SIGINT/SIGHUP.

**Exit.** It prints `<T> released: <reason>` where `<reason>` is exactly one of `deadline reached`,
`every held item finished`, `continuity is off`, `superseded by another holder`, `killed by a
signal`, then one line per id of `held` (fallback `items`, for a record written before this field
existed), in `held` order, and exits. On `deadline reached` or `every held item finished` it removes
the record first. On `continuity is off` or `superseded by another holder` the record is already
gone or already someone else's. On SIGTERM/SIGINT/SIGHUP it exits 143 and leaves the record in
place: the pid check makes the record dead for an interactive session, and a headless coordinator
keeps the record it needs (see Headless coordinators). Item lines:

```
a2f2aacc903afc6ac finished
bsp949ih1 still running (last activity 2026-09-25T01:51:00Z)
bq7x2 unknown
```

"Finished" depends on the kind of item (package 38). A **subagent** item is one with
`<dirname(transcript_path)>/<session_id>/subagents/agent-<id>.jsonl` or `.meta.json` (harness-facts
(c)). Its events are read from the session transcript (`transcript_path`, tail-read, at most 8 MiB) in
byte order: a `<task-notification>` naming the id (its first `<status>`: `running` is live, anything
else terminal), and a SendMessage resume marker `"resumedAgentId":"<id>"`, plain or JSON-escaped,
which is live. A resume writes no notification, so the marker is the live event. The item is
finished only when its last event is terminal and none of its activity files (`agent-<id>.jsonl`, the
cached output file) changed within QUIET, two ticks (60 s). A crashed agent with no terminal event is
held until the deadline, because a quiet file alone never makes an item finished. A **task** item keeps the plain rule: finished when the
latest notification naming it has a terminal status. "Still running" carries the newest activity
mtime; for a background task it is the mtime of its output file when that path appears in the
transcript. An id that resolves to neither is `unknown`, and the command never fails on it. The scan
is linear: lines without the id are skipped, and each marker is checked by one anchored match.

**Liveness at Stop**, `holder_live($sid, $p)`. Coordinator and non-coordinator sessions diverge here
(Decision 130, M1+S3).

For a **coordinator**, all of these must hold:

1. `holder/<sid>.json` parses, names this session, and `deadline` > now.
2. Held work is running: the payload carries a `background_tasks` array with at least one entry
   whose `"status":"running"`, `"type":"subagent"` and `id` is one of the record's `items`. A held id
   that is finished, mistyped or invented counts for nothing. A missing `background_tasks` array
   fails this check, which leaves the coordinator its ledger path.

For a **non-coordinator** (interactive) session, all of these must hold (Decision 131 extends this:
it holds even when the held id reads completed, is absent from the payload, or only unheld work is
running):

1. `holder/<sid>.json` parses, names this session, and `deadline` > now.
2. The record's `items` is non-empty. `background_tasks` is not consulted at all: the fixed holder
   already prunes finished items on its own and holds a SendMessage-resumed agent whether or not the
   harness lists it as running, so a non-empty items list IS the evidence (this closes the deny loop
   a resumed agent used to hit when `background_tasks` omitted it — reports/38-review.md M1). An
   empty items record never counts, and another session's holder record never counts.
3. The process is alive. With `/proc` (MSYS on Windows, Linux in the sandbox): `/proc/<pid>/cmdline`
   is readable and its SHA-1 equals `fp`. A killed holder fails at once, a reused pid fails because
   its command line differs, and nothing waits out a heartbeat. Without `/proc` (a macOS host):
   `kill 0, $pid` succeeds. A dead holder never passes, regardless of its items.

The cost is one small JSON read, one read of `/proc/<pid>/cmdline` (under 1 ms, 7417f0c) and a field of
a payload that is already parsed. Never `stat` or `status`, which cost 45-70 ms each, and never a
WINPID. An orphaned process from a killed dispatch can no longer count (bug 20260922-211901-2cad),
because it holds no record for this session. `plugins/butler/tests/t/continuity-holder.t` (package 05)
asserts that the fingerprint matches a live holder and fails once the holder is killed without cleanup,
and records the read cost in the ledger.

**Test seams (package 05 only).** `BUTLER_HOLD_TEST_SECONDS` (1..3000) and `BUTLER_HOLD_TEST_TICK`
(seconds) are honoured only when `BUTLER_STATE_DIR` is also set. They can only shorten the hold, and
no skill or message mentions them.

**Prior art (Decision 44).** The stopped almanac-records session left a prototype, an untracked
bp-hold.pl beside butler's scripts. It was removed from the working tree on 2026-09-24; its only
copy is `reports/evidence/prior-art/bp-hold.pl`, which package 05 reads. Its debounce-and-reset idea is the extend
choice here. Its `/proc/<pid>/stat` fingerprinting is replaced by the cheap cmdline fingerprint, and its
exit-on-first-item is not carried over.

**Headless coordinators (Decision 4).** A fleet coordinator is `claude -p`. Harness-facts (e) shows
headless kills a still-running background Bash task a few seconds after its final result, and that a
background Agent keeps the process alive and wakes it. So for a coordinator the wake-up is the Agent's
completion, not the holder's exit, and a live holder alone never lets a coordinator stop. The gate
allows a coordinator stop on a holder only when the record is unexpired and a held id is a `running`
`subagent` in the Stop payload's `background_tasks`. It does not check the holder's process, and the
holder keeps its record when it is killed. Whatever headless does to the holder, that gives the same
answer:

- The holder survives while the Agent runs: the record is valid, the stop is allowed, and the Agent's
  completion wakes the coordinator.
- The holder is killed and its kill wakes the coordinator: the record is still valid and the Agent
  still runs, so that one extra stop is allowed at once. No re-hold loop starts.
- The holder is killed silently: the Agent's completion still wakes the coordinator.

A coordinator holding an id that is not a running background subagent is refused, and the process
cannot end with a non-terminal ledger that way. **Package 08 obligation:** measure this once in a
nested `claude -p` (the Decision 28 method): a background Agent plus a background `butler-hold`, then
end the turn, and record whether the holder is killed and whether its kill wakes the session. Cite the
result in 08's ledger. `plugins/butler/tests/t/fleet-holder-integration.t` exercises the gate and holder
contract in-process for all three outcomes. The merged Bash guard exempts a command that is exactly one
`butler-hold` invocation from the headless no-background rule.

A holder also exits early, with exit code 3 and the single line `PROMPT <agent_id>: <message>`, when
any prompt in its own session is recorded after the holder's start or latest extension (never-halt
Decision 9; filtered on session_id alone, never agent_id — Decision 40).

## Reason log

Decision 7: every off and silence reason goes into one log the operator can read, with session, time
and text.

reason-log: ~/.claude/butler-state/continuity/reasons.log

This is the same root as the arm state (`$BUTLER_STATE_DIR/continuity/reasons.log` when overridden).
One tab-separated line per event, appended with `O_APPEND` by `butler-continuity.pl`, by
`butler-fork-ok.pl` (package 19) for its own recordings, and by `gc_sessions()` for its own removals:

```
2026-09-24T05:00:00Z	abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10	agent	off	C:/Development/ccpraxis	all packages done; nothing left to run
2026-09-24T03:10:00Z	abb7e549-0e1f-4c1b-9a53-0d3b5a3c7f10	agent	silence	C:/Development/ccpraxis	reporting results to the operator
2026-09-24T06:00:00Z	7d8355c7-3202-461f-b319-c85a3402d87c	operator	off	C:/Development/ccpraxis	(operator)
2026-09-25T07:00:00Z	0409cb25-7656-418b-99f3-e9402646f33a	gc	gc	-	transcript gone: C:/Users/André/.claude/projects/x/0409cb25-....jsonl
```

Fields: ISO-8601 UTC time, session id, actor (`agent`, `operator` or `gc`), verb (`off`, `silence`,
`gc` or `fork-ok`), project root, and reason. For `off` and `silence` this is the ticket `cwd`
resolved through `data_dir`, or `-` when the binding was a stop token or GC. For `fork-ok`,
`butler-fork-ok.pl` (package 19, Decision 64) logs the raw ticket `cwd` (or `-` if unset) each time
it records a fork override, without the `data_dir` resolution the other verbs apply. Tabs and
newlines in the reason become spaces. The reason is capped at 300 characters. An agent reason must
hold at least two whitespace-separated words, so it is never empty and never a single word.
Otherwise the command prints
`butler-continuity: --reason needs at least two words saying why.` and exits 1, and nothing is logged.
An operator off without a reason logs `(operator)`. The log rolls to `reasons.log.1` past 1 MiB. The
statusline badge (package 10) reads the per-session `off/` and `silence/` files, not this log.

## Stop gate denial text

One Stop hook (Decision 5): `plugins/butler/hooks/stop-gate.sh`, logic in
`plugins/butler/scripts/BpHook/StopGate.pm` (package 06). The ways past it are a live holder, or
the off and silence commands, each with a reason (Decision 1, Decision 6), plus the two break-glass
last resorts described under "Break glass" below. The text is built from the
session's running work (Decision 128). Exact text when an armed non-coordinator session stops with no
live holder, no silence and nothing running (Decision 8: at most 8 lines, the three commands, nothing
else, no history). `<token>` is replaced by the token this denial minted, in all four places:

```
Continuity is on for this session and no holder is running. Stop token: <token>
Waiting on a subagent or background task? Hold it, as a background Bash tool call:
  butler-hold --token <token> <id> [<id> ...]
All work done? Turn continuity off, as a Bash tool call:
  butler-continuity off --reason '<what is done>' --token <token>
Escape hatch, only when a stop is truly necessary, e.g. to talk with an operator who is present:
  butler-continuity silence --reason '<why this stop>' --token <token>
```

When the payload's `background_tasks` lists running work (`running_work`), silence is not offered:

```
Continuity is on for this session and work is still running: <ids><more>. Stop token: <token>
Hold it, as a background Bash tool call; the holder wakes this session when the work finishes:
  butler-hold --token <token> <ids>
If that work is no longer needed and everything is done, turn continuity off, as a Bash tool call:
  butler-continuity off --reason '<what is done>' --token <token>
```

`<ids>` is the first 8 ids, joined with `, ` on line 1 and with spaces on line 3; `<more>` is empty for
8 or fewer, else `, and <N> more`. While the holder is alive, `holder_live` already allows at G8 for
any non-empty held item, so running work never needs the 60 s window there; when the holder is dead,
running work also counts a held id whose agent transcript or output changed within 60 s, because a
SendMessage-resumed agent may be missing from `background_tasks` (Decision 129, amended by Decision
130). The gate records that work in `running/<sid>`, so a `silence` run anyway explains and points at
hold instead of setting a silence -- and the command refuses on the same evidence even before any
Stop (Decision 130 S1).

The text is written to stderr with exit 2, and Claude Code feeds it back verbatim (harness-facts (f)).
Silence is the escape hatch for talking with a present operator: use it sparingly, and only when a
stop is truly necessary, because the operator's reply starts the next turn and the gate is back in
force, whereas an off would stay off. A persistent process nobody is waiting on (a dev server, a
`tail -f`) is not work to hold; if nothing else is pending, turn continuity off with a reason instead.
Reasons are in single quotes so bash expands nothing in them.

Coordinator variant (off and silence refuse there, Decision 25). `<reason>` is exactly one of: the
ledger does not exist; status '<s>' is not terminal; the ledger is <n>m stale (limit 15m);
'## Next action' is empty or a placeholder; a fleet pause is active and status '<s>' is terminal; the
held ids are not running background subagents. If no token could be minted, the holder line omits
`--token <token>`; the ledger path needs no token.

```
Coordinator stop refused: <reason>. Stop token: <token>
Waiting on a background subagent? Hold it, as a background Bash tool call:
  butler-hold --token <token> <id> [<id> ...]
Otherwise finish or park the ledger: status done|blocked|parked, a concrete '## Next action' when blocked or parked, last_updated from iso_now.
```

**Algorithm** (`StopGate::run`, after the wrapper's prefilter has let the invocation through):

```
if hook_event_name(p) ne 'Stop' or agent_id(p) defined -> allow   (never mints)
sid = session_id(p)                      ; undef -> allow
bg = take_break_glass(sid, p)            ; G2b: read and unlink, BEFORE the token it names dies
revoke_stop_token(sid)                   ; the previous turn's token dies here
if role is coordinator:
    runs/<pkg>.force-stop exists         -> unlink, allow
    runs/.paused and not runs/.shutdown  -> paused rules (non-terminal status, Next action, fresh)
                                            -> stamp last_updated, allow | deny(coordinator text)
    ledger terminal, fresh (15m), Next action when blocked|parked
                                         -> sync runs/registry.json, stamp last_updated, allow
    holder_live(sid, p)                  -> allow   (coordinator rule: running subagent held)
    deny(coordinator text, mint_stop_token(sid))
if role is judge                         -> allow
if not is_armed(sid)                     -> clear streak, allow
if bg valid                              -> clear streak, disarm if action off, log, allow  (G6b)
touch armed/<sid>                        ; activity for the wake-lock lease
clear_running_snapshot(sid)              ; G7b: the snapshot describes only the latest Stop
holder_live(sid, p)                      -> clear streak, allow   (checked first, so a silence is not wasted)
take_silence(sid)                        -> clear streak, allow   (consumed by exactly this stop)
streak = bump_streak(sid, p)             ; G9b: >= REFUSAL_CAP -> clear, log, allow
t = mint_stop_token(sid)                 ; undef -> allow, one hook-errors.log line
work = running_work(sid, p)              ; G11
if work: set_running_snapshot(sid, work) ; deny(running text with t)
else:    deny(idle text with t, plus the break-glass lines when offered)
```

`stop_hook_active` is never read. It resets after a wake and is not a block counter (harness-facts
(f)). If `take_silence` cannot unlink the silence file, the stop is treated as not silenced, because a
file that survives would let more than one stop through. If the gate cannot store a token, it allows
the stop rather than print a denial whose way out would not work. The same holds for any exception:
the gate fails open.

### Break glass

Bug `20261021-202419-bf19`: a session armed with continuity lost its shell, because a PreToolUse
hook pointed at a deleted script and failed every Bash and PowerShell call. Every way past the gate
is a shell command, so it refused more than a hundred stops in a row before a human noticed. The
operator's ruling (2026-10-21) was both of the following, as last resorts for when the tooling
itself is broken:

- **Refusal cap** (G9b). `$BpHook::StopGate::REFUSAL_CAP` (5) consecutive refusals with no tool
  call succeeding in between, and the gate lets the stop through. It writes a `refusal-cap` line to
  `reasons.log` and one to `hook-errors.log`, and does not disarm: the next stop starts a fresh
  streak. The streak lives in `stop-refusals/<sid>` as `{count, offset, shell_failed}`; each
  would-be refusal reads only the transcript bytes appended since `offset`. Any `tool_result`
  without `is_error` resets the count to 1. A failed result whose `tool_use` was Bash or PowerShell
  sets `shell_failed`. Without a readable `transcript_path` the cap is inert, because "stuck" cannot
  be told from "busy". It counts in the running-work branch too, so a stale running record cannot
  loop forever. A live holder, a silence, a break-glass file or a disarm clears the streak.
- **Break-glass file** (G2b, G6b). A silence or off request written with the Write tool, which
  keeps working when the shell does not, at
  `<project>/.ccpraxis-local-data/butler-break-glass/<sid>.json`. When the project has no data
  directory it goes at `<state>/break-glass/<sid>.json` instead, because Claude Code guards writes
  under `~/.claude` and the project path is the one more likely to be writable. The contents are
  `{"token":"<token>","action":"silence"|"off","reason":"<two words or more>"}`, and the token must
  be the one the last refusal printed, so the file is exactly as bound to this session and turn as
  the shell commands are. The gate reads it before revoking that token and unlinks it whether or
  not it is valid, so a stale file never acts on a later stop. A refused file is named, with its
  reason, in the next refusal.

The idle refusal offers the file only once the shell has visibly failed: a shell call errored since
the previous refusal, or this is at least the `$BREAK_GLASS_HINT_AT` (2) refusal in a row with
nothing succeeding. A healthy session never sees it, so it cannot become the habitual way out.
The idle text is 7 lines without them, 12 with them, and 13 when a refused file is named, which
is why stop-gate.sh's budget below is 13 rather than Decision 8's 8.
The running-work refusal never offers it: while work runs the way out is a hold (Decision 128), and
a session that cannot hold still reaches the cap. The lines appended to the idle text are:

```
No shell command can run? Last resort: create this file with the Write tool:
  <path>
  containing {"token":"<token>","action":"silence","reason":"<why this stop>"}
  ("action":"off" instead when all work is done).
After 5 refusals in a row with no tool call succeeding, the gate lets the stop through by itself.
```

Oracle: `plugins/butler/tests/t/stop-gate-break-glass.t`.

## Operator off versus agent off

Package 04 owns both halves (Decision 37). The check is a hook, not something the agent can supply
as an argument:

off-check: plugins/butler/hooks/continuity-off-check.sh

Its logic lives in the module BpHook::ContinuityOffCheck, at plugins/butler/scripts/BpHook/ContinuityOffCheck.pm,
which is a re-scope request for package 04 (see Re-scope requests), in line with Decision 35's one
module per hook package.

**Mechanism.** `continuity-off-check.sh` is a PreToolUse Bash hook with the prefilter
`--pre text:butler-continuity,text:butler-hold,text:butler-fork-ok,text:almanac` (package 28,
Decision 105; `text:almanac` added by package 12, 12-bug-claimant-and-triaging): it exits when the
payload text contains none of the four names. It writes the tickets described under Command
binding.
For each real invocation of `butler-continuity off`, with or without `--reason`, from a payload
without `agent_id`, it reads the tail (at most 1 MiB) of the payload's `transcript_path` and finds the
latest genuine operator record, walking back past everything that is not one:

- It must be a `"type":"user"` record that is not `isMeta`, not `isSynthetic` and not
  `isCompactSummary`, has no `toolUseResult`, and whose content is text rather than `tool_result`
  blocks. Records that start with `<task-notification>` or `Stop hook feedback` are skipped.
- The operator flag is set only when that record's whole trimmed text is the slash-command shape and
  nothing else: an optional `<command-message>...</command-message>`, then
  `<command-name>/butler:continuity</command-name>`, then `<command-args>off</command-args>` (arguments
  trimmed). A literal `/butler:continuity off` inside other text, a compaction summary that quotes an
  earlier off, a carry-over plan, or any message with more text never qualifies.

If the latest genuine operator record qualifies, the ticket is written with `"operator":true`. The hook
never denies. It only records who asked. This is the transcript technique `guard-run-finish.sh` already
uses, and 04 reads that parser rather than extending it.

**Package 04 obligation: the agent-invoked Skill.** How Claude Code records a model's own Skill-tool
invocation of `/butler:continuity` with argument `off` has not been measured. 04 measures it before it
ever sets `"operator":true`: in a nested `claude -p` in a scratch project (the Decision 28 method), one
run where the prompt is the slash command and one where the model is asked to invoke the skill through
the Skill tool. It records both transcript records in its ledger. The design covers both outcomes:

- **Distinguishable** (the model's record is `isMeta`, carries a field such as `sourceToolUseID`, or
  otherwise differs from the operator's record in a way the filter above can test): 04 adds that test
  to the filter and ships the operator form as described.
- **Indistinguishable:** 04 never sets `"operator":true`. A reasonless `off` always refuses, and the
  continuity skill's operator branch runs
  `butler-continuity off --reason 'operator ran /butler:continuity off'`, logged with actor `agent`.
  The operator loses the reasonless form and sees a badge for their own off, but no agent can ever be
  logged as the operator.

`plugins/butler/tests/t/continuity-command-verbs.t` covers: an agent Skill-tool record of the measured
shape leaves `"operator":false`; a quoted mention, a compaction summary and a synthetic record leave it
false; the operator's whole-message record sets it.

**The command decides** (`plugins/butler/scripts/butler-continuity.pl`):

| call | binding says | result |
|---|---|---|
| `off --reason '<2+ words>'` | ticket or token, main thread | off, actor `agent` (actor `operator` if the ticket says `"operator":true`), reason logged |
| `off` (no reason) | ticket with `"operator":true` | off, actor `operator`, logged as `(operator)` |
| `off` (no reason) | anything else | refused: `butler-continuity: off needs --reason '<why>' unless the operator typed /butler:continuity off.`, exit 1 |
| any of on, off, silence | ticket with `agent_id` set | refused: `butler-continuity: only the main session changes continuity; a subagent may not.`, exit 1 |
| off or silence | `BP_LEDGER` set in the command's environment | refused: `butler-continuity: a coordinator cannot turn continuity off; it stops when its ledger is terminal.`, exit 1 (Decision 25) |
| off, silence, status | no ticket (or two) and no valid token | refused: `butler-continuity: no session binding; use the --token from the stop message, or quote arguments in single quotes.`, exit 1 |
| on | no ticket, or two | refused: `butler-continuity: no session binding for on; run it again as a plain Bash tool call.`, exit 1 |
| silence | armed, and running work is present at invocation (`running/<sid>` names work from the last Stop, OR `BpHook::running_work` reports work directly, checked with no subprocess -- Decision 130 S1) | not silenced: four lines on stderr naming the work (8-id rule) and pointing at `butler-hold <ids>`, or at `off` if the work is no longer needed; exit 1, no silence file, no reason line. A given `--token` is still consumed |
| silence | armed, no running/snapshot work, but this session's own live holder holds non-empty items (Decision 133) | not silenced: two lines on stderr naming the held ids and saying the turn can simply end, since the Stop gate already allows it while the holder runs; exit 1, no silence file, no reason line |

There is no `--session` option and no environment variable that names a session. No argument, flag,
token or environment variable produces `"operator":true`. Only the hook sets it, from a transcript
record the agent cannot write. As everywhere in this repo, the threat model is accident, not adversary:
an agent that hand-writes a ticket file or reads another session's token out of the state directory is
outside the model, and so is one that edits the hook. An off by either actor is permanent until `on`
(Decision 36). Package 10 shows the badge only for `"actor":"agent"`, so the operator sees when an
agent has turned continuity off or silenced it.

Other verbs, each printing one line unless noted: `on [--role driver|reporter]`,
`silence --reason '<2+ words>' [--token <token>]` (marked `(escape hatch: use sparingly)` in the
usage line), `status` (at most 4 lines: arm state and role, the
holder and its items and deadline, any pending silence; holder read through `BpHook::holder`),
`ask --text '<question>'` (files a pending decision in the almanac decision store via
`Almanac::Decision::file`), `questions`, `answer --id <id> --answer '<text>'`, and the internal
`lease --daemon`. `silence` on an unarmed session prints
`continuity is off for this session; nothing to silence.`, exits 0 and records nothing. The command
honours `CCPRAXIS_NO_WAKELOCK` exactly as `bp-continuity.pl` does, so tests never take the real lock.

## Concurrency binding store and switch

Decision 16: the director tracks a set of in-flight packages, every dispatch is bound to one package by
`tool_use_id`, and write guards apply the package of the subagent making the edit. Decision 31: the
director hands out further disjoint ready packages.

binding-store: <project>/.ccpraxis-local-data/.drive-solo/bindings/<tool_use_id>.json
concurrency-switch: none (removed by package 16; concurrent hand-out is unconditional)

**The switch (Decision 19), removed by package 16.** Before the cutover, an environment variable
`BUTLER_CONCURRENCY` gated concurrent hand-out: on only when it equalled `1`, off otherwise. Four
places read it, not three: `plugins/butler/scripts/bp-drive-next.pl` (package 11: concurrent
hand-out), `plugins/butler/scripts/bp-orchestrator.pl` and `plugins/butler/scripts/bp-launch.sh`
(package 08: the fleet holder path), and `BpHook/BindDispatch.pm` (the switch-off "bind the first
member instead of denying" branch). No hook reads it now. The one-ledger dispatch rule only bites
when more than one package is in flight, and only concurrent hand-out can make that happen. Package
16 deleted the off branches and the variable from all four readers, so the concurrent path is now
unconditional, and the old fleet path and `current.json` are gone with them.

**In-flight set (package 11):** `<data>/.drive-solo/inflight.json`, written only by the director,
atomically:

```
{"packages":[{"blueprint":"hook-continuity-remake","package":"03-hook-core",
  "ledger":".ccpraxis-local-data/blueprints/hook-continuity-remake/packages/03-hook-core.md",
  "since":1790212345}],"updated_at":1790212345}
```

A package is added on `run-package`. It is removed by the first director call that finds its ledger
terminal (done, blocked, parked or dropped). The file is project-level, so it survives a new session
id. One driving session per project is the supported configuration. A package whose driver crashed
stays in flight until its ledger turns terminal, which is correct, because the next driver resumes it.
The director never creates, reads or removes `current.json`; package 16 deleted that path along with
the switch. `ready_packages` receives the real in-flight set instead of `[]`, and a further ready
package is handed out when `write_sets_overlap` is false against every in-flight one.

**Binding store (package 12).** One lookup file per dispatch, `bindings/<tool_use_id>.json`, written
atomically, so a write guard's lookup is one file open, never a scan. The `tool_use_id` must match
`^[A-Za-z0-9_-]{1,128}$` before it names a file. Each binding is also appended with `O_APPEND` to the
history `bindings.jsonl` beside it, in the same shape as today's `.dispatch-log/attribution.jsonl`, so
`bp-spend.pl report-session` reads both histories with one parser, de-duplicated by `tool_use_id` with
the binding record preferred. The history rolls to `bindings.jsonl.1` past 8 MiB. Lookup files older
than 7 days are removed by bind-dispatch when it writes a new one.

```
{"tool_use_id":"toolu_01HG32t2hGKSSJK7U3qVvWJm","blueprint":"hook-continuity-remake","package":"03-hook-core","subagent_type":"bp-implementer","session_id":"abb7e549-...","source":"bind-dispatch","at":1790212400}
```

**Dispatch rule** (`plugins/butler/hooks/bind-dispatch.sh`, PreToolUse Task|Agent):

- Coordinator: bind to `BP_BLUEPRINT`/`BP_PACKAGE`, never deny.
- Armed driver, main thread. With 0 in flight, allow and record nothing. With 1, bind to it. With 2 or
  more, `tool_input.prompt` must name exactly one in-flight ledger: after turning `\` into `/`, it
  contains `blueprints/<bp>/packages/<pkg>.md`. If it does, bind. If not, deny:
  ```
  With 2 packages in flight a dispatch prompt must name exactly one ledger path:
    .ccpraxis-local-data/blueprints/hook-continuity-remake/packages/03-hook-core.md
    .ccpraxis-local-data/blueprints/hook-continuity-remake/packages/11-director-inflight-set.md
  ```
  (one header line, at most 4 ledgers, then `  ...and <n> more`).
- Any other session: allow, record nothing. A denial never happens in an unarmed or non-driving
  session.
- If `inflight.json` is missing or does not parse, the in-flight set is empty (package 16 deleted the
  `current.json` fallback along with the switch).

**Write-guard resolution (package 13)**, for `guard-writes.sh` and `ledger-guard.sh` under `next/`:

1. `BP_LEDGER` set: today's `BP_WRITE_SET`/`BP_TEST_PATHS`/role rules, unchanged.
2. Armed driver and `agent_id` present: read `toolUseId` from
   `<dirname(transcript_path)>/<session_id>/subagents/agent-<agent_id>.meta.json` (harness-facts (c)),
   open `bindings/<toolUseId>.json`, and check the edit against that package's ledger `write_set` +
   `test_paths` + the blueprint dir + `/tmp`. The refusal names the package and the file.
3. Armed driver, `agent_id` present, and no resolvable binding (no `meta.json`, which a foreground
   dispatch may lack, a malformed `agent_id`, or no binding file): with 1 package in flight, that
   package's set. With 2 or more, deny with one line,
   `No package binding for this subagent; with <n> packages in flight its edits are refused.`
   Decision 16 is not weakened to a union.
4. Armed driver, main thread (no `agent_id`): with 1 package in flight, that package's set. With 2 or
   more, the union, and the refusal names every in-flight package. With 0, allow.
5. Anything else: allow.

**Fleet (package 08).** `bp-launch.sh` starts coordinators with `plugins/butler/bin` on `PATH`
unconditionally (package 16 removed the `BUTLER_CONCURRENCY` export along with the switch), so
`butler-hold` resolves. The coordinator then waits through the holder and stops through the one gate,
under the coordinator rule of the Holder protocol section. The orchestrator's `runs/.paused`,
`runs/.shutdown` and `runs/<pkg>.force-stop` behaviour is unchanged. Neither file calls `bp-watch.pl`
today. Fleet use of watchers lives in coordinator-protocol prose, which package 15 rewrote.

## Guard message budgets and early exits

One row per surviving hook: the most message lines it may print on any path, and the `--pre` clauses
its wrapper passes to `run-hook.sh`, under which it exits 0 in bash before perl starts (Decision 12,
Decision 20, Decision 33). Every hook exits 0 or 2 and nothing else (exit 2 only for a deliberate
deny). Every message line is at most 160 characters. A command echoed back is cut to 80 characters
with `...`. No message names a retired mechanism or says how to disable the guard, with one named
exception: `guard-fork.sh`'s deny text names `butler-fork-ok --reason` (Decision 64). That is not a
disable path for the guard -- it records a one-shot, logged override that is consumed by exactly the
next fork dispatch, and the guard denies again after it. Decision 3 applies throughout: every
"armed" below is THIS session's `armed/<session_id>`, never "any session in the project".

| stop-gate.sh | 13 | --pre ledger,armed : exits when BP_LEDGER is unset and armed/<session_id> is absent |
| arm-on-entry.sh | 1 | --pre text:bp-drive-next : exits when the payload text does not contain bp-drive-next |
| continuity-off-check.sh | 0 | --pre text:butler-continuity,text:butler-hold,text:butler-fork-ok,text:almanac : exits when the payload text contains none of the four names |
| bind-dispatch.sh | 6 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| guard-writes.sh | 3 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| ledger-guard.sh | 1 | --pre text:/packages/ --pre ledger,driver : exits when the payload text lacks /packages/, or when BP_LEDGER is unset and the session is not an armed driver |
| guard-bash.sh | 2 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| guard-git-mutations.sh | 2 | --pre text:git, plus --pre ledger,armed when its argument is --only-during-butler-run : exits when the payload text lacks git, or for that registration when BP_LEDGER is unset and the session is unarmed |
| wait-shape-guard.sh | 2 | --pre ledger : exits when BP_LEDGER is unset |
| context-ceiling.sh | 2 | --pre coordinator : exits when BP_LEDGER is unset or BP_ROLE is set to anything but coordinator |
| gate-shutdown.sh | 2 | --pre ledger --pre stopfile : exits when BP_LEDGER is unset or none of runs/.shutdown, runs/.paused, runs/<pkg>.force-stop exists under BP_DIR |
| guard-blueprint-write.sh | 2 | --pre text:blueprint : exits when the payload text does not contain blueprint |
| guard-ask-operator.sh | 4 | --pre ledger,armed : exits when BP_LEDGER is unset and armed/<session_id> is absent |
| track-dispatch.sh | 1 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| guard-fork.sh | 3 | --pre text:fork : exits when the payload text does not contain fork |
| record-prompt.sh | 0 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| record-denial.sh | 0 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| denial-breaker.sh | 3 | --pre ledger,driver : exits when BP_LEDGER is unset and the session is not an armed driver |
| arm-nudge-prompt.sh | 1 | no run-hook.sh and no --pre (pure bash, never starts perl) : exits when BP_LEDGER is set, the payload is not a main-thread UserPromptSubmit, or the prompt is a task-notification |
| session-start-nudge.sh | 1 | no --pre (runs on every source, armed or not) : exits only when [ -f run-hook.sh ] fails |
| ac-standdown-gate.sh | 2 | --pre acstanddown : exits when the AC-loss stand-down marker is absent (env-only, no session file read) |

**Who each rule applies to.** A fork counts as a subagent everywhere.

- stop-gate: the main thread's Stop only. SubagentStop is not registered.
- arm-on-entry: a main-thread director call arms. A subagent's director call arms nothing and, in a
  driving session, is denied.
- continuity-off-check: any caller. The ticket records the `agent_id`, and the commands refuse a
  subagent.
- bind-dispatch: coordinator (binds); armed driver main thread (binds, or denies an ambiguous
  dispatch); armed driver subagent (denied).
- guard-writes and ledger-guard: coordinator; armed driver main thread (its package or the union);
  armed driver subagent (its own binding, refused when unresolvable with 2+ in flight).
- guard-bash: the coordinator denials and the headless-background deny apply only when `BP_LEDGER` is
  set, never to an armed driver, so a driver can still commit. Judge checks apply only when `BP_ROLE`
  is `harvest-judge`. The validation interlock applies to coordinators and to every caller in an armed
  driver session, except a payload whose `agent_id` owns a worker marker, so the worker can run its
  own tests.
- guard-git-mutations with `--only-during-butler-run`: coordinator, or any caller in an armed session.
  The settings.json registration: everyone.
- wait-shape-guard, context-ceiling and gate-shutdown: coordinators only.
- guard-blueprint-write: every session and caller.
- guard-ask-operator: coordinator, or any caller in an armed session.
- track-dispatch: coordinator, and an armed driver's main thread.
- guard-fork: every session and caller (Decision 64).
- arm-nudge-prompt: the main thread's operator prompts only; a task-notification, a subagent payload
  or a BP_LEDGER environment is skipped before anything is written.
- session-start-nudge: every main-thread session, on every source (startup, resume, clear, compact),
  armed or not -- it always re-attaches and prints the project digest; the never-halt-12 nudge text
  itself still only speaks on an armed session's compact or resume. A subagent payload or a
  BP_LEDGER environment is quiet.

Behaviour kept by package 14, and which existing tests each rebuild re-expresses in the
`plugins/butler/tests/t/guards-remake-*.t` family (one file per merged guard; Decision 26:
assertions about a Decision 6 override are exempt and listed in 14's ledger). Merged guards run
each old rule behind its old applicability test, inside one process:

- guard-bash.sh: coordinator denials (git checkout, switch, restore, reset, clean, rebase, merge,
  commit, push and stash except list/show; rm -rf outside /tmp, BP_DIR and screenshots; deploys;
  BP_BASH_EXTRA_DENY). Headless background deny when `BP_LEDGER` is set, exempting a command that is
  exactly one `butler-hold` invocation (so `butler-hold x; sleep 3000` is still denied). Harvest-judge
  pnpm/npm/yarn lint, build and test. Validation interlock while a fresh writer marker exists. Sources:
  `plugins/butler/tests/t/guard-bash-quote-strip.t` (those four deletion-list sources landed in it
  and were removed from the tree in package 16's batch B).
- guard-git-mutations.sh: stash (except list/show), checkout, switch, restore, reset and clean, with
  today's quote masking, heredoc and carrier rules. Sources:
  `plugins/butler/tests/t/git-mutation-guard-reach.t`,
  `plugins/butler/tests/t/guard-git-mutations-heredoc-strip.t`,
  `plugins/butler/tests/t/guard-git-mutations-quote-mask.t`,
  `plugins/butler/tests/t/guard-prose-not-invocation.t`.
- wait-shape-guard.sh: wait-loop, false-green pipe, task-output poll, repeated TaskOutput, and the
  identical-call repeat detector (fires once per run). Sources: `plugins/butler/tests/t/wait-shape-guard.t`,
  `plugins/butler/tests/t/wait-shape-guard-quote-strip.t` (the repeat-detector's own deletion-list
  source landed in these two and was removed from the tree in package 16's batch B).
- context-ceiling.sh: hard-ceiling deny of dispatch and non-flush Bash, bounded to 5 flush turns, plus
  soft-ceiling guidance through `context()`. The flush and guidance deletion-list sources landed here
  and were removed from the tree in package 16's batch B; the merged guard's own coverage lives in
  `plugins/butler/tests/t/guards-remake-context-ceiling.t`.
- gate-shutdown.sh: deny dispatch and worksite edits under a fleet stop, and allow the ledger
  park-write. Source: `plugins/butler/tests/t/orchestrate-shutdown-clear.t` (its graceful-stop-gate
  shutdown-assertion sibling was removed from the tree in package 16's batch B).
- guard-blueprint-write.sh: blueprint.md edits denied, and hand-written package ledgers denied with
  the evidence-gated `ledger-write-override`. Sources: `plugins/butler/tests/t/blueprint-write-api.t`,
  `plugins/butler/tests/t/blueprint-guard-exempts-template.t` (the ledger-creation deletion-list source
  landed here and was removed from the tree in package 16's batch B).
- guard-ask-operator.sh: deny and queue only when THIS session is armed or a coordinator. Source:
  `plugins/butler/tests/t/no-halt-for-questions.t`.
- track-dispatch.sh: one write-capable worker at a time for coordinators, as today. For armed drivers,
  one marker per write-capable dispatch at `.drive-solo/workers/<tool_use_id>` (carrying the session
  and the subagent type), removed at its PostToolUse, so two concurrent writers never clear each
  other's marker. Running and done dispatch records, and the ledger dispatch line. Source:
  `plugins/butler/tests/t/dispatch-tracking-hook.t` (its validation-interlock tracker-assertion sibling
  was removed from the tree in package 16's batch B).

Fail direction per hook, applied only after the early exit has let the call through. Fail open
(exit 0) for everything except coordinator `guard-writes.sh`, `ledger-guard.sh` and `gate-shutdown.sh`
under an active stop signal. Those three fail closed with one line, as today, and that includes a
payload `payload_ok()` rejects (unparseable, or truncated past the 8 MiB read cap). A guard that wedges
an interactive session costs more than the mistake it prevents. A coordinator's write discipline has
failed closed since b12, and one retry with a diagnostic is cheap there. A missing perl, a missing
`BpHook.pm` or a module that fails to load fails open everywhere, because the wrapper's guard and the
eval-require run before any hook logic. That differs from today's destructive-git guard, which failed
closed when no JSON parser existed, and the difference is accepted: perl ships with every supported
host.

## Skill line budgets

Each `SKILL.next.md` that package 15 writes (Decision 19, Decision 24) puts all of its stop and
continuity guidance inside one block delimited by the lines `<!-- continuity:begin -->` and
`<!-- continuity:end -->`. The budget is the number of non-blank lines inside that block.
`plugins/butler/tests/t/continuity-prose-budget.t` fails if a file lacks exactly one such block,
exceeds its budget, mentions `butler-hold`, `butler-continuity` or `silence` outside the block, or
mentions a retired mechanism anywhere.

| plugins/butler/skills/continuity/SKILL.next.md | 40 |
| plugins/butler/skills/drive-solo/SKILL.next.md | 12 |
| plugins/butler/skills/reporter/SKILL.next.md | 4 |
| plugins/butler/skills/coordinator-protocol/SKILL.next.md | 12 |
| plugins/butler/skills/orchestrator-protocol/SKILL.next.md | 6 |
| plugins/butler/skills/dispatch-fleet/SKILL.next.md | 4 |
| skills/carry-over/SKILL.next.md | 3 |

What each block must carry, in the fewest words. Continuity: when to self-arm (background work
expected to outlive the turn, unattended multi-step work), when off and silence are acceptable and
what a reason must say (off when all work is done; silence, a sparing escape hatch, only when a stop is
truly necessary, e.g. to talk with an operator who is present),
reasons in single quotes, the stop token from a denial, how to call the holder (once, backgrounded,
re-run to add ids), and the operator branch that 04's Skill-tool measurement decides. Drive-solo: first
step `butler-continuity on --role driver`, hold on dispatched ids, the one-ledger dispatch rule, and
never dispatch a fork during a drive. Reporter: first step `butler-continuity on --role reporter`.
Coordinator-protocol: the ledger stop rule, and that a hold counts only for a running background
subagent. Orchestrator-protocol: the three fleet files. Dispatch-fleet: the holder line. Carry-over:
re-arm the fresh session with `butler-continuity on` when the work was armed.

## Deletion list

Package 16 deletes exactly these (Decision 34 lets it widen its write set to fix what the deletions
break). Its no-reference grep exempts this file, `plugins/butler/docs/harness-facts.md`, everything
under `.ccpraxis-local-data/`, and the allowlist in `plugins/butler/tests/t/tests-never-run-tests.t`,
whose entries 16 removes as it deletes their files (Decision 21). Assertions that pin a Decision 6
override are exempt from re-expression and listed by file and name in the relevant ledgers (Decision
26). Decision 43 is decided here: both `reporter-gate-regression.t` and `arming-binds-or-reports.t`
are deleted. Neither survives the cutover, so neither needs its sibling re-run fixed. Batches A and B
have already landed (the hooks/ flatten, the registration rewrite and the first round of script and
test deletions); this list is trimmed after each batch to name only what is still on disk and still
pending a later batch (C-E1), so it stays the coverage test's exact to-do list rather than a permanent
historical record.

All scripts, shims and tests on this list have been deleted (batches A through E1).

Runtime state is not in git and is not deleted by 16. Once the files above are gone nothing reads it:
the three machine registries, the `.subagent-guard/<session>` stall state, the `.watchers/`
arm registry, `.drive-solo/.stop-ok`, `.run-finished`, and the old continuity markers.

## Cutover obligations

What package 16 changes rather than deletes, so the "exact list" above stays exact:

- Kept, with the reason: `plugins/butler/scripts/bp-watch-child.pl`, the fleet child parent that
  `bp-launch.sh` uses for exit status. It is not a watcher. `plugins/butler/scripts/BpResumption.pm`,
  whose `pid_alive` the coordinator protocol names as a liveness proof. `plugins/butler/scripts/BpSession.pm`,
  whose transcript discovery `plugins/butler/scripts/bp-feedback.pl` uses.
  `plugins/butler/scripts/BpContinuityLease.pm`, which 16 rewires to read the new store only.
- Tests that keep running against a same-path successor or an updated file, where 16 fixes whatever
  goes red (Decision 34): `plugins/butler/tests/t/guard-bash-quote-strip.t`,
  `plugins/butler/tests/t/git-mutation-guard-reach.t`,
  `plugins/butler/tests/t/guard-git-mutations-heredoc-strip.t`,
  `plugins/butler/tests/t/guard-git-mutations-quote-mask.t`,
  `plugins/butler/tests/t/guard-prose-not-invocation.t`, `plugins/butler/tests/t/wait-shape-guard.t`,
  `plugins/butler/tests/t/wait-shape-guard-quote-strip.t`, `plugins/butler/tests/t/ledger-guard.t`,
  `plugins/butler/tests/t/guard-writes-specificity.t`,
  `plugins/butler/tests/t/write-set-refusal-diagnoses-itself.t`,
  `plugins/butler/tests/t/dispatch-tracking-hook.t`, `plugins/butler/tests/t/blueprint-write-api.t`,
  `plugins/butler/tests/t/blueprint-guard-exempts-template.t`,
  `plugins/butler/tests/t/no-halt-for-questions.t`, `plugins/butler/tests/t/orchestrate-shutdown-clear.t`,
  `plugins/butler/tests/t/hooks-selftest.t`, `plugins/butler/tests/t/hooks-json-route-registration.t`,
  `plugins/butler/tests/t/h01-settings-registration.t`, `plugins/sandbox/tests/t/settings-scope-split.t`,
  `plugins/butler/tests/t/hooks-reach-non-ccpraxis-project.t`,
  `plugins/butler/tests/t/continuity-lease-liveness.t`, `plugins/butler/tests/t/resumption-contract.t`, and `plugins/butler/tests/t/bp-commands-on-path.t` (the
  bp-watch.sh and bp-continuity.sh shims go).
- Two tests would otherwise go quietly inert. `plugins/butler/tests/t/dispatch-write-path.t` does
  `skip_all` unless `hooks/lib.sh` exists, so after the deletion it is green by skipping. 16 re-points
  it at the merged tracker or removes the dead cases, and never leaves it skipping.
  `plugins/butler/tests/t/test-wakelock-hygiene.t` names only `bp-continuity.pl` and
  `gate-continuity.sh` in its `$ACTUATORS` pattern. 16 adds `butler-continuity.pl` and `stop-gate.sh`,
  so new tests that drive the new command are checked for `CCPRAXIS_NO_WAKELOCK`.
- `plugins/butler/scripts/bp-containment-audit.pl` mirrors lib.sh's `match_any`. Package 16 re-points
  the comment to `BpHook/WriteGuards.pm`, which keeps the same colon-separated dialect.
- `.claude/settings.json`: the two `guard-subagent-stall.sh` entries are removed in the same commit
  that deletes the script. The `guard-git-mutations.sh` entry is untouched. A settings commit must
  never point at a file that is not yet on disk (Decision 10), whether or not a running session re-reads
  it (harness-facts (h)).
- The Decision 19 switch is removed, as described under the concurrency switch.

## Constraint conflicts

- **No Stop block cap, and a way out that depends on no other hook.** Harness-facts (f), design
  constraint 1, recommends a per-session hard cap on Stop retries. Decisions 6 and 45 retire
  `MAX_BLOCKS=3` and forbid any way past the gate except a holder, off or silence. This design follows
  the Decisions and removes the dead end a different way. Every denial carries a stop token minted and
  stored by the gate itself. `butler-hold`, `butler-continuity off` and `butler-continuity silence`
  accept it as proof of session, so the three documented exits work even when the ticket hook has
  failed. If the gate cannot store a token, or anything in it throws, or its module cannot load, it
  allows the stop. What remains is one paid turn per refused stop while an agent ignores a 7-line
  instruction, and the case where the command scripts themselves are broken, which every package's
  `perl-compile` check guards. There is no turn cap to fall back on: `--max-turns` does not exist in
  2.1.280.
- **Headless coordinators and the holder.** Decision 4 puts coordinators under the holder. Headless
  `-p` kills background Bash tasks shortly after the final result (harness-facts (e)), and
  gate-headless-background forbids background Bash in coordinators. The design answers it without
  depending on the unmeasured case: a coordinator's hold counts only alongside a running background
  subagent it names, and a killed holder keeps its record. Package 08 measures the behaviour once.
- **The wake-lock's one-hour window (Decision 53).** Decision 18 ties the wake-lock to the armed
  state. With disarm-on-timeout gone, an arm file can outlive its session (a closed terminal, the old
  id after `/clear`). The lease therefore counts only an armed session whose transcript was written in
  the last hour, safe because the holder's fixed 50-minute timeout wakes a waiting session before the
  hour runs out. That is only the lease's view of activity; it never disarms anything.
- **Manual sessions after /clear.** Not a conflict: Decision 2 re-arms drive-solo and reporter sessions
  automatically and leaves every other session to `/butler:continuity on` or self-arm. A new id is a
  new session, so nothing is disarmed.
- **Command names.** The denial text must name `butler-continuity off --reason` (Decision 8 and the
  coverage test). Decision 47 settles the spelling: the commands are extensionless files.

## NEEDS-OPERATOR forks

Harness-facts lists three items only an interactive session can settle (Decision 13: measured, never
assumed). The design works under either answer to each (Decision 32), because no component reads
`$CLAUDE_CODE_SESSION_ID`. Commands bind through hook-written tickets or gate-minted stop tokens, and
all state is keyed by the payload `session_id`. Each assumption leans toward the outcome that does not
depend on the variable.

### D-1
question: Does /compact change the session id in-process?
if yes: The compacted session starts with an unarmed id. A drive-solo session re-arms at its next director call, a reporter or manual session must run butler-continuity on again, and the old id's arm file stays until its transcript is gone, no longer holding the wake-lock once its transcript has gone an hour with no activity (Decision 53).
if no: nothing changes; arm state, holder and silence stay attached to the unchanged id.
assumed: no

### D-2
question: Does the in-process $CLAUDE_CODE_SESSION_ID follow the new id after /clear?
if yes: nothing changes; no component reads the variable, and commands bind to the session through tickets written by a hook that sees the payload session_id, or through a stop token the gate minted for that session.
if no: nothing changes, for the same reason; a stale variable cannot misdirect an arm, off, silence or holder.
assumed: no

### D-3
question: Does a carry-over-style clear allocate a new session id?
if yes: The fresh id starts unarmed. drive-solo re-arms at its first director call (Decision 2), and the carry-over prose tells a reporter or manual session to run butler-continuity on. The old id's arm file stays until its transcript is gone, no longer holding the wake-lock once its transcript has gone an hour with no activity (Decision 53).
if no: nothing changes; the arm state carries over under the unchanged id and the re-arm call is an idempotent refresh.
assumed: yes

## Re-scope requests

For the driving session to apply (Decisions 29 and 35):

1. **Applied as Decision 47.** Package 04 ships plugins/butler/bin/butler-continuity and package 05
   ships plugins/butler/bin/butler-hold, both extensionless, in place of the `.sh` shims their write
   sets named. No `.sh` shim for either command is created. The denial text and skill prose name the
   commands as agents type them.
2. **04-continuity-command: add plugins/butler/scripts/BpHook/ContinuityOffCheck.pm.** Every hook file
   runs `run-hook.sh <Module>`, which calls `BpHook::<Module>::run`, and Decision 35 gives each hook
   package one module of its own. The logic of `continuity-off-check.sh` (ticket writing, the
   operator-record filter) needs that home, or 04 would have to edit 03's `BpHook.pm`. The shared
   ticket and stop-token functions stay in `BpHook.pm` (03), because the Stop gate (06) and both
   commands (04, 05) use them. The path is written here without code formatting until the write set
   is amended, because the coverage test's rule C13 checks formatted paths against blueprint.md.
