---
name: bug-report
description: File a ccpraxis tooling bug report from whatever project you are working in. Use when ccpraxis tooling itself misbehaves — a butler/blueprint/sandbox/backpack script, hook, template or skill does the wrong thing, blocks legitimate work, reports success it did not achieve, or cannot be worked around. Also use when the user says "file a bug", "report this to ccpraxis", or "that's a ccpraxis bug". Do NOT use for bugs in the project you are building — those belong in that project's own tracker.
allowed-tools: Bash, Read, Grep, Glob
---

# Filing a ccpraxis bug report

You are working in some project; ccpraxis tooling got in the way. That observation is worth
keeping, and right now it dies with your session unless you file it here.

Reports live in the project you are working in, one file per report:

```
<project>/.ccpraxis-local-data/bug-reports/<id>.md
```

## File it

```bash
perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl file \
  --title "one line, names the defect not the symptom" \
  --severity high --area butler \
  --body -   <<'REPORT'
...your report...
REPORT
```

`--area` is free text; use the plugin name (`butler`, `sandbox`, `blueprint`, `backpack`,
`steward`, `beacon`, `almanac`). `--severity`: `low` | `medium` | `high` | `blocker`, or
`unknown` — which is what the script records when `--severity` is omitted. The list is now
enforced as a closed enum, so a value outside it is rejected rather than written.

**Never create or edit the file directly.** A PreToolUse hook denies Edit/Write on that directory.
The script is the only writer, because a report freezes once ccpraxis picks it up and a direct edit
would sail past both the state machine and the digest recorded at freeze time.

## What makes a report worth reading

The reports that got fixed had these; the ones that got lost did not.

- **Where, exactly.** `file:line` of the offending code or prose. "The judge crashes" is a symptom;
  `judge-harvest.md:17-21` is a defect.
- **Evidence from the run.** The log lines, the exit code, the error verbatim. Quote it.
- **Why it happens**, if you worked it out — and say plainly when you did not. A confident wrong
  mechanism costs more than an honest "undetermined": two diagnoses of one backpack bug were
  refuted in sequence before anyone checked the falsifier.
- **What you already ruled out.** Saves the next person re-deriving it.
- **Whether you could work around it**, and whether the workaround is safe to repeat.
- **Blast radius.** Does it hit one package, every judge, every run?

Keep it to what a reader must know to reproduce and fix. This is a defect record, not a narrative.

## One report per file

Two defects found together are two reports. They get triaged, frozen and resolved independently,
and a combined report cannot be half-fixed.

## Revising

While the status is `open`, revise freely:

```bash
almanac-bug.pl update <id> --body - <<'REPORT'
...
REPORT
```

Once it reaches `reviewing` it is **frozen** — that is what lets a reviewer read it without you
rewriting it underneath them, and what makes `taken` mean something. If you learn more after that,
file a follow-up and reference the original id. The refusal message says so too.

Check where things stand with `almanac-bug.pl list`.

## Before you file

- **Is it actually ccpraxis?** A failing test in the project you are building is not a ccpraxis bug.
- **Is it already filed?** `almanac-bug.pl list` — if an open report covers it, `update` that one
  with your new evidence rather than filing a second.
- **Can you fix it yourself?** Usually not: plugin content is mounted read-only inside a sandbox
  (you will get `EROFS`), and that is deliberate. Reporting *is* the contribution. Say in the report
  that you attempted the fix and what stopped you — that tells the maintainer it needs to land
  upstream and be promoted.
