---
name: bug-triage
description: Collect and triage ccpraxis bug reports filed from every project on this machine, and move them through triaging → scheduled → fixed/dropped. Use when working ON ccpraxis and the user asks what bugs have been reported, wants to review the queue, or says "collect the bug reports", "what's been filed", "triage the bugs". Host-side, ccpraxis-repo work. Skip for filing a new report, which is /almanac:bug-report.
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

# Triaging ccpraxis bug reports

Agents working in other projects file reports when ccpraxis tooling fails them. They land in each
project's own `.ccpraxis-local-data/bug-reports/`, and `collect` finds them through steward's
project registry so you never have to guess project paths from Claude Code's lossy slugs.

## See the queue

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug collect
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug collect --status open
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug collect --json
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug verify
```

`collect` (with no filter) walks this project and every project registered for backup; `--status
open` narrows to the untriaged; `--json` is for processing. `verify` reports whether frozen bodies
still match their digests, by re-reading each file from disk rather than trusting the index.

## The states

```
open  ->  triaging  ->  scheduled  ->  fixed | dropped
 |           |            |
 |           |            +----->  fixed  (reconcile, once the package is done)
 |           +-------->  open         (hand it back: "not ready, keep editing")
 |           +-------->  fixed        (--no-package, an in-place fix with no package)
 +-------------------->  dropped      (with a reason)
```

`triaging -> dropped` is also legal — a report can be dropped without ever being scheduled.
`triaging -> fixed` is legal too (Decision 66), but ONLY via `--no-package --note "<what fixed
it>"` — see "An in-place fix with no package" below. `fixed` is never reachable by hand from
`scheduled`: a scheduled report fixes only via reconcile, once its package is done.

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug set-status <id> --to triaging
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug set-status <id> --to scheduled --package <blueprint>/<package>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug set-status <id> --to fixed --no-package --note "<what fixed it>"
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug set-status <id> --to dropped --note "<why>"
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug takeover <id>
```

Leaving `open` **freezes the body** and records its digest. From then on the filer cannot revise it
— deliberately. Send it back to `open` if it genuinely needs more from them.

Moving a report to `triaging` **claims it for your session** (and your agent id, if you are a
subagent) — the identity comes from a ticket butler itself issues, never from a flag, so the command
must be written literally (no `$variables`) in a session with the butler plugin enabled. From then
on **only you can move it on or back to `open`**; anyone else is refused and told who holds it.
`list`/`collect` flag a claim as stale when its session has no transcript on this machine, or when
its session shows no recent activity — `bug takeover <id>` recovers a stale claim for your own
session.

`scheduled` needs a package whose ledger exists, live or archived, under
`.ccpraxis-local-data/blueprints/` — run the `set-status --to scheduled` call from the project that
owns the blueprint (ledgers never name bugs; the link lives on the report). A scheduled report
becomes `fixed` once its package ledger says `done`: every `almanac bug` call reconciles the
project's reports first, recording the package and, if the ledger's `## Outputs` section has a
`commit: <sha>` line, the commit too. `list`/`collect` flag a scheduled report whose package is
parked, dropped or missing, and a leftover `taken` report (from before this rename) that could not
be migrated automatically. Run the explicit form with
`perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" bug reconcile` to reconcile on demand rather
than waiting for the next verb to do it silently.

Existing `taken`/`resolved`/`declined` reports migrate automatically, on the next call: `resolved`
becomes `fixed`; `declined` becomes `dropped`; a `taken` report whose note says something like
"Scheduled as `<blueprint> <package>`" becomes `scheduled` against that link when it resolves to
exactly one package, and otherwise stays `taken`, flagged.

## Triaging well

**Move it to `triaging` before you start reading**, not after. The freeze exists so the text cannot
change while you assess it; claiming it afterwards defeats the point.

**Verify the claim from disk before believing it.** Reports are written by agents mid-run, under
pressure, and they are wrong often enough to matter — of the diagnoses filed against one backpack
defect, the filer's and the first replacement were both refuted. Read the `file:line` it names.
Reproduce the evidence. A report can be completely right about the *symptom* and wrong about the
*mechanism*; fix what is actually broken, not what the report guessed.

**`dropped` is a real outcome and needs a reason.** Not-a-bug, working-as-intended, or duplicate —
say which, in `--note`. A silently ignored report teaches every future agent that filing is
pointless.

**Duplicates carry information.** The same defect reported twice from different projects is
evidence of blast radius, not noise. Drop the second with a pointer to the first, and let that
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
- If the fix belongs to a blueprint package, schedule the report against it:
  `bug set-status <id> --to scheduled --package <blueprint>/<package>`, and write `commit: <sha>`
  under that package ledger's `## Outputs` section when the fix lands. The report becomes `fixed`
  by itself, the next time any `almanac bug` call reconciles.
- If the fix is an **in-place, ad-hoc fix with no blueprint package** — a small, direct patch made
  outside any package pipeline — move it straight from `triaging` to `fixed` by hand instead:
  `bug set-status <id> --to fixed --no-package --note "<what fixed it>"` (Decision 66). The note is
  the one piece of evidence reconcile would otherwise have supplied (a package link and its
  commits), so say what actually fixed it. This edge is reachable only from `triaging` — it cannot
  bypass a `scheduled` report's package-done requirement.

Filing a new report, rather than triaging existing ones, is /almanac:bug-report; see
`plugins/almanac/skills/bug-report/SKILL.md`.
