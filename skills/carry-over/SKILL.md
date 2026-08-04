---
name: carry-over
description: Ends a long session by writing a self-contained handover PROMPT for a fresh session that continues the SAME work, asks the user anything genuinely unresolved, then presents it in plan mode so "accept plan and clear context" carries it over in one step. Use when context is filling up mid-task and the work is NOT finished — the user says "carry over", "hand this off", "we're running out of context", "start a fresh session on this", or asks for a handover instead of a /compact. Skip when the work is DONE (nothing to continue), when the session has barely used context, or when the user wants a summary of what happened rather than instructions for what happens next.
user-invocable: true
allowed-tools: Read, Grep, Glob, Bash, AskUserQuestion, EnterPlanMode, ExitPlanMode
---

# /carry-over

**What this is for, and it is narrow: shedding used-up context WITHOUT losing the thread of work
that is still in progress.** You write a prompt that a brand-new session — one that has never seen
this conversation — can act on immediately and correctly. Then you present it in plan mode, so the
user's "accept plan and clear context" does the copy → new session → paste → submit in one keystroke.

**What this is NOT:**

| not this | use instead |
|---|---|
| a summary of what happened | just answer; or `/compact` |
| wrapping up finished work | `/beacon:off` |
| a durable multi-session initiative with ledgers | `/blueprint:create` |
| a mechanical context squeeze that keeps this session alive | `/compact` |

`/compact` compresses **this** conversation and continues in it. `/carry-over` **ends** this
conversation and starts a clean one holding only what the next step needs. Prefer `/carry-over` when
the useful state is small relative to the transcript — which, late in a working session, it usually
is.

---

## THE ONE FAILURE MODE THIS EXISTS TO PREVENT

The user's own words: *"a few times we tried this and I always had to go back and tell the session
about things it forgot."*

Every rule below exists because of that. The handover is judged by exactly one question:

> **Could a competent stranger, with only this text and the repo, do the next step correctly —
> without asking the user anything you already knew?**

Two specific ways handovers fail, both observed:

1. **A conclusion travels without its provenance, and the next session applies it wrongly.** A real
   case: a handover said *"Caps are now 400."* True — of one mechanism. The next session applied it
   to a different one with a nearly identical name, and eleven workers died silently because of it.
   A bare claim cannot be re-checked. **Carry the claim, its source, and how to verify it — or do
   not carry it.**
2. **State drifts between writing and reading.** Anything you assert about the repo may be stale by
   the time it is read. So assert less, and **carry the commands that re-establish state** instead.
   A handover that makes the next session re-derive its footing in 30 seconds beats one that tells
   it a hundred facts it must take on faith.

---

## Procedure

### 1. Take stock — from disk, not from memory

Your recollection of this session is the least reliable input you have. Before writing anything,
re-establish the facts you intend to carry:

- `git status --short` and `git log --oneline -N` — what is committed, what is dirty, whose is it
- the current state of whatever tracks the work (ledger, plan file, issue, TODO)
- the last test/build/lint result — **re-run it if it is more than a few steps old**; do not carry a
  remembered green
- anything you asserted earlier in the conversation that you have not personally verified

If a check is slow, still do the cheap ones. A handover built on stale claims is the failure mode.

### 2. Ask the user — only what genuinely blocks the next step

Use `AskUserQuestion` for decisions the next session would otherwise have to guess at, where guessing
wrong wastes real work: an unresolved fork in approach, an ambiguous priority, whether an in-flight
change should be kept or dropped.

**Do not** ask what you can determine yourself, and do not ask for permission to write the handover.
If nothing is genuinely open, skip this step entirely — a pointless question is worse than none.

### 3. Write the handover AS A PROMPT

Address the next session directly and in the imperative. It is an instruction, not a report:
"Continue X. Start by running Y." — never "In this session we explored…".

Use these sections. Drop any that would be empty; do not pad.

```
# <Imperative task title, with position> e.g. "Finish the auth migration — 4 of 6 files done"

## Your task
One paragraph: the goal, and what "done" looks like. Concrete enough to act on.

## Re-orient first — run these before touching anything
The 2–5 commands that re-establish state, each with EXPECTED output.
This is the most valuable section. It makes every claim below self-correcting.

## Where things stand
What is done, and how it was verified. What is in flight. What is untouched.
Mark anything you did NOT verify this session as unverified — explicitly.

## Next action
The single concrete next step. Not a menu.

## Decisions already made — do not re-litigate
Each with its WHY. This is what stops the next session redoing settled arguments,
and it is the section users most often have to supply by hand when it is missing.

## Open questions
Genuinely undecided. If the user answered something in step 2, it belongs above, not here.

## Reserved for the user — do NOT action
Things awaiting their call. Say plainly that these must not be started.

## Constraints and traps
Blocked commands, tools that do not exist here, conventions that bit us, near-identical
names that have already been confused. Each one earns its place by having cost something.

## Claims to distrust
Anything inherited, assumed, or asserted-but-unverified — with what would settle it.
An empty section here is a claim in itself; only omit it if genuinely nothing qualifies.
```

### 4. Present it in plan mode

If the session is not already in plan mode, call `EnterPlanMode`. Then call `ExitPlanMode` with the
**entire handover as the plan body**.

**The plan text is the only thing that survives.** Everything else — this conversation, your
reasoning, any file you read — is gone the moment the user accepts. So the plan must not say "see
above", "as established", or "the file I mentioned": there is no above. If it is not in the plan
body, it does not exist.

Then tell the user, in one line, that accepting with **"accept plan and clear context"** starts the
fresh session on this prompt.

Do not also paste the handover into your chat reply. It is already in the plan, and duplicating it
just burns the context this command exists to reclaim.

---

## Rules that decide the quality of the output

- **Self-contained.** No reference to "earlier", "as discussed", "the file I mentioned". Name every
  path, symbol and command in full. The reader has none of your context.
- **Provenance on every load-bearing claim.** `verified from disk this session` /
  `inherited, unverified` / `the user decided this`. Unlabelled assertions get applied blindly, and
  that is how the "caps are now 400" failure happened.
- **Commands over claims.** Prefer "run X, expect Y" to "X is true".
- **Carry the traps, not the narrative.** What went wrong matters only where it would go wrong again.
  Nobody needs the story of how you found it.
- **Do not carry solved detail.** Finished work belongs in one line plus its commit hash. The whole
  point is to leave context behind.
- **Name near-identical things explicitly.** Two settings one underscore apart, two similar paths,
  two same-named files in different trees — say which is which and which one governs. This is a
  recurring source of silent, expensive mistakes.
- **If work is uncommitted, say so first**, and say whether the next session should commit it. A
  handover that silently strands dirty state is worse than no handover.
- **Length follows the work, not the transcript.** A one-step continuation is short. Do not inflate
  it to look thorough, and do not compress a genuinely complex state into bullets that lose it.
