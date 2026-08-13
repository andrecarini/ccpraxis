---
name: bug-triage
description: Collect and triage ccpraxis bug reports filed from every project on this machine, and move them through reviewing → taken → resolved/declined. Use when working ON ccpraxis and the user asks what bugs have been reported, wants to review the queue, or says "collect the bug reports", "what's been filed", "triage the bugs". Host-side, ccpraxis-repo work.
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

# Triaging ccpraxis bug reports

Agents working in other projects file reports when ccpraxis tooling fails them. They land in each
project's own `.ccpraxis-local-data/bug-reports/`, and every write is indexed machine-wide so you
never have to guess project paths from Claude Code's lossy slugs.

## See the queue

```bash
A=plugins/almanac/scripts/almanac-bug.pl
perl $A collect                    # every project
perl $A collect --status open      # just the untriaged
perl $A collect --json             # for processing
perl $A verify                     # frozen bodies still match their digests?
```

`collect` re-reads each file from disk rather than trusting the index, and flags any report whose
body no longer matches the sha256 recorded when it froze.

## The states

```
open  ->  reviewing  ->  taken  ->  resolved | declined
             |
             +-------->  open        (hand it back: "not ready, keep editing")
```

```bash
perl $A set-status <id> --to reviewing
perl $A set-status <id> --to taken
perl $A set-status <id> --to resolved --note "fixed in <sha>"
perl $A set-status <id> --to declined --note "<why>"
```

Leaving `open` **freezes the body** and records its digest. From then on the filer cannot revise it
— deliberately. Send it back to `open` if it genuinely needs more from them.

## Triaging well

**Move it to `reviewing` before you start reading**, not after. The freeze exists so the text cannot
change while you assess it; claiming it afterwards defeats the point.

**Verify the claim from disk before believing it.** Reports are written by agents mid-run, under
pressure, and they are wrong often enough to matter — of the diagnoses filed against one backpack
defect, the filer's and the first replacement were both refuted. Read the `file:line` it names.
Reproduce the evidence. A report can be completely right about the *symptom* and wrong about the
*mechanism*; fix what is actually broken, not what the report guessed.

**`declined` is a real outcome and needs a reason.** Not-a-bug, working-as-intended, or duplicate —
say which, in `--note`. A silently ignored report teaches every future agent that filing is
pointless.

**Duplicates carry information.** The same defect reported twice from different projects is
evidence of blast radius, not noise. Decline the second with a pointer to the first, and let that
raise the first's priority.

## Turning a report into a fix

Fix it here, in the ccpraxis repo — a sandboxed reporter usually *cannot*, because plugin content is
mounted read-only (`EROFS`). That read-only mount is deliberate, so "the reporter should have fixed
it" is not a fair response to any report.

Then, in the same pass:

- **A test, not just a fix.** Prose defects need pinning too — a template that tells a one-shot
  process to wait for a notification is a defect, and it took a test over the template text to stop
  it drifting back.
- **Verify the test is non-vacuous.** Run it against the pre-fix content (`git show HEAD:<path>`)
  and confirm it fails.
- **Remember promotion.** A fix in this clone is inert until merged into `~/.claude/ccpraxis`. The
  reporter's sandbox is serving the *live install*, so until you promote, their next run hits the
  same defect and may re-file it.
- Then `set-status <id> --to resolved --note "<sha>"`.

## Do not edit report files directly

A PreToolUse hook denies Edit/Write on `bug-reports/`. Use the verbs. If you find yourself wanting
to hand-edit a report, what you actually want is either `set-status … --to open` (hand it back) or a
follow-up report.
