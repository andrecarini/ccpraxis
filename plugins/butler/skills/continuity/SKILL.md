---
name: continuity
description: Toggle or check whether THIS session is armed to keep going. While armed, the one
  Stop gate refuses to end a turn unless something confirmed still running is waited on. This
  works for any session, not only a drive-solo run or the reporter. Arming keeps the machine
  awake automatically, with nothing for the agent to manage. Use when the operator asks, or
  before starting open-ended unattended work.
argument-hint: "[on|off|status]  (default: status)"
user-invocable: true
allowed-tools: Bash
---

# /butler:continuity

Explicit continuity arming for the current session. While armed, the one Stop gate refuses to end
a turn unless a holder is waiting on running work — this applies to any session, including one
that is not a drive-solo run or the reporter.

## Arming also keeps the machine awake — automatically

An armed session is unattended work, so the two things that end it silently are held off for as long
as the arm stands:

| where | what is held | what it stops |
|---|---|---|
| host (Windows) | the wake-lock (`keep-awake.ps1`) | the machine entering connected standby mid-run |
| inside a sandbox | the busy-lease (`/tmp/.butler-busy`) | `heartbeat.sh` reaping the container — and, through the launcher dashboard's probe of that same file, the host sleeping behind it |

`on` starts a detached refresher that re-asserts this every 60s; `off` releases it. **Nothing here
needs you to run anything** — do not take out a lock by hand, and do not treat holding it as one of
your responsibilities.

Two details worth knowing rather than re-deriving:

- It is machine-level, not per-session. Two armed sessions share one lock and the **last** `off`
  releases it.
- `status` prints a `wake-lock:` line that reports what is actually asserted. An armed session
  whose transcript has been idle for more than one hour stops holding the machine awake (Decision
  53) — say so rather than glossing it when the two disagree.

## Using continuity

<!-- continuity:begin -->
Run these as plain Bash tool calls, arguments in single quotes.

- **Arguments:** `on` -> `butler-continuity on --new-thread <name>` to start a thread, or `butler-continuity on --thread <name>` to resume
  a handed-off one (or take over one whose owner is dead). `off` -> `butler-continuity off`. `status` or
  empty -> `butler-continuity status`. A refusal prints one `butler-continuity: ...` line; report it word for word.
- **Operator branch:** a reasonless `off` works only when the operator's own message was
  `/butler:continuity off`. If it refuses, the agent started the off itself and needs a `--reason`.
- **Output:** `on` prints `continuity on for session <sid> (role <role>, thread <name>)` and a line to chart that thread. `off` prints
  `continuity off for session <sid> (actor ...); reason logged`, then that the thread was handed off. `status` prints an armed/off/not
  armed line, a `thread:` line (name, bar, doing, next), a `holder:` line, an optional `silence:` line, and a `wake-lock:` line. `silence`
  prints `continuity silenced for one stop of session <sid>; reason logged`.
- **Self-arm triggers:** arm and attach a thread (`butler-continuity on --new-thread <name>`) before starting background work you expect to
  outlive the turn, or before unattended multi-step work — for example when the operator is away
  or said "keep going". Do not self-arm for one interactive answer. Hooks nudge toward arming; arming stays your call.
- **Off** (`butler-continuity off --reason '<what is done>'`) is right only when all work is done
  or the operator ended it. It hands the thread off with the reason in its log, and refuses while a task of the thread is doing: set each done, pending or blocked first. It stays off until an explicit `on`; a later director call does not
  re-arm it. A persistent process nobody is waiting on (a dev server, `tail -f`) is not work to hold; if nothing else is pending, off with a reason is the right move.
- **Silence** (`butler-continuity silence --reason '<why this stop>'`) is an escape hatch: use it
  sparingly, only when a stop is truly necessary, e.g. to talk with an operator who is present or to
  wait for the operator's answer. It lets one stop through; the gate applies again next stop. It is
  not offered while work is running, and refuses then: hold the work instead.
- **A reason** is at least two words (at most 200 bytes for off) and says what is done (off) or why this stop (silence). Quote
  it in single quotes; it is logged for the operator.
- **Holder:** `butler-hold <id> [<id> ...]` with `run_in_background: true`, but only when
  `butler-continuity status` shows `holder: none`. Ids are the agent id a background dispatch
  returns, or a background Bash task id. The hold is fixed at 50 minutes, or sooner once every
  id has finished. A dispatch alone does not let an armed session stop; a running holder does.
  There is one holder per session: while one is running, call `butler-hold <new id>` in the
  foreground instead, which extends the holder and returns at once -- it never starts a second holder.
  Call it once, when a turn ends with work running -- not after every dispatch and not for ids
  already held. The running holder prints its own line at each extension, each id finishing, and
  on release; the extending call's own foreground line only says it extended and exits. Its stop
  token runs its three commands with `--token <token>` as printed. It counts only while one of its
  ids is still running. On release it wakes the session and prints each id as `<id> finished`,
  `<id> still running (last activity <time>)` or `<id> unknown`. Act on that, then hold again
  only for ids still running.
- **New session id:** after `/clear` or a carry-over, the session is unarmed — run
  `butler-continuity on --thread <name>` again (hand the thread off with off before a `/clear`, or the old id still owns it). `--resume` keeps the arm.
- **Questions:** file one with `/almanac:inbox` (`almanac inbox file --title '<question>'`) and
  keep working; the operator answers it there, from any session.
- **Subagents:** cannot turn continuity on, off or silence it, or hold; those refuse.
<!-- continuity:end -->

## If you have a question for the operator

File it. Do NOT end the turn for it — see the `Questions` line in "Using continuity".

An armed session IS unattended work — that is what arming means — so a turn that
ends to ask something stops the work for an answer nobody is there to give. The
question becomes an inbox item in the project, the statusline's ⚑ N counts
how many are waiting, and they are answered when the work stops for a reason
that is actually about the work.

Meanwhile: decide it yourself if it is not a product call
(`.ccpraxis-local-data/guidance/escalate-product-decisions-only.md`), and carry
on with everything that does not depend on the answer. If nothing can proceed,
the honest report is that the work is finished pending an answer — turn
continuity off with a reason (see "Using continuity") and say so.

## Confirm to the user

One short sentence confirming the new state to the user.

Examples:

> Continuity is on for this session — I'll keep going until the work is done or you end it.

> Continuity is off for this session.

> This session is not currently armed.
