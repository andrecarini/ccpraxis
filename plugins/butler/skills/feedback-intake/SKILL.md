---
name: feedback-intake
description: Four-phase flow (Batch, Decompose, Verify, Author) that turns raw operator feedback into verified, sourced, basis-marked findings before any package is authored, plus bp-feedback.pl, the one-command capture CLI that feeds it. Use whenever operator feedback needs decomposing into package-ready findings, or when a human invokes /butler:feedback-intake directly to drive that decomposition. It is **not** for short, direct feedback handled immediately in the same conversation — file that with a quick fix, not this flow.
argument-hint: [batch]
---

# Feedback intake

## Capture first

Capturing a piece of operator feedback costs the firing agent exactly one command and nothing else — no prompt, no editor, no sub-task, no interpretation of what was said:

    perl plugins/butler/scripts/bp-feedback.pl "the operator's exact words"
    # or, for anything with structure (multi-line, code, logs):
    some-command | perl plugins/butler/scripts/bp-feedback.pl

`bp-feedback.pl` prints one line — the path it wrote — and exits. The agent
returns to whatever it was doing before firing it. Everything below this
point happens LATER, in a separate pass, never inline with the agent that
captured the feedback.

## Phase 1 — Batch

Raw material accumulates untouched under `corrections/<batch>/`. Every
capture is one new file, `feedback-<n>.txt`, numbered from 1 and left
numerically unpadded — never `feedback-01.txt`. Raw files are never edited;
they are evidence of what the operator actually said, kept exactly as
captured.

A batch that has a `DECOMPOSED.md` is **closed**: a decomposed batch is closed,
and new feedback opens the next batch, never joins a closed one.
This is a correctness property, not a style preference — a decomposition
must cover exactly its batch, and a verifier's "I read all N raw files"
coverage claim has to stay true after the fact. Appending an eighth raw
file into a batch whose `DECOMPOSED.md` already claims "read all seven"
would falsify that claim silently, while the artifact still looks complete.

## Phase 2 — Decompose

One output file, `DECOMPOSED.md`. The decomposition is a single file: every
finding gets a stable ID (`<AREA>-<NN>`), its source file(s), and a basis
marker — every claim states whether it was independently verified in code
this session (`VERIFIED`), asserted by the filer with evidence (`REPORTED`),
or explicitly flagged by the filer as unreproducible
(`REPORTED (self-caveated)`). The basis vocabulary is open, not a closed list:
besides those three, findings may also carry `operator instruction` or
`operator testimony` when that is what the claim actually rests on. What is
required is that a basis marker is present on every claim, never that it
comes from a fixed set.

IDs are never renumbered once assigned. An insertion keeps its neighbours'
IDs stable, so numbering is not monotonic by design (`WAIT-08a` before
`WAIT-08` is correct, not a bug) — renumbering would silently invalidate
every existing citation to those IDs.

Attribution belongs on every finding that has a raw source. Where a finding
has no raw source at all, or states its attribution inline in its own
heading instead of a `**Source:**` field, that is legitimate; the basis
marker remains the only field required on every finding.

The decomposition also carries these standing sections, matched by the
artifact's own heading text: `## How to read this`,
`## Operator rulings collected while decomposing`,
`## Overlap map — in-flight packages`, `## Proposed package grouping`,
`## Open items — not resolved by this decomposition`, and `## Audit trail`.

Also required: dedup across drafts, an overlap analysis against in-flight
packages, and a proposed package grouping — see the next two sections.

## Overlap with in-flight packages

When a finding overlaps a package that is already running, the
decomposition does not edit that package: it must never edit a running package's criteria.
Instead it should note the overlap and propose a follow-on package that
covers the gap. Track it in a small per-package table:

| package | covers | gap for a follow-on |
|---|---|---|
| ... | what the running package already handles | what this finding needs that it does not |

## Deduplication discipline

Multiple raw files often describe the same thing from different angles.
Merge duplicate drafts, but uniques are named explicitly — material that is
genuinely unique to one draft is called out by name, not folded silently
into the merged text. Where two drafts disagree outright, the divergence is recorded rather than silently resolved:
pick neither side by fiat, write
the contradiction up as its own finding, and let phase 3 or the operator
settle it. A close paraphrase (one draft is a précis of a fuller one) can
be merged once verified assertion-by-assertion; a narrower draft that only
partially overlaps a fuller one is not a strict subset and must not be
described as one without checking every claim.

## Phase 3 — Verify

A fresh, context-less and read-only agent — someone who did not write the
decomposition — reads every raw file in the batch in full and re-verifies
every `VERIFIED` claim against the actual code or artifact. It reports; it
does not fix anything itself.

## Verifier brief

Give the verifier this brief, close to verbatim:

> Read **all** raw feedback files in this batch, in full. Re-verify every
> claim marked `Basis: VERIFIED` against the code or artifact it cites — do
> not trust the decomposer's word for it. Report; do not fix anything
> yourself. Return exactly these seven parts:
>
> - **Verdict** — overall: does the decomposition hold up as written?
> - **Omissions** — real material from the raw files the decomposition dropped.
> - **Distortions** — claims the decomposition mischaracterizes.
> - **Fabrications** — claims with no support in the raw files or the code.
> - **Deduplication errors** — merges that lost unique material, or
>   subset/superset claims that do not hold.
> - **Traceability gaps** — findings whose source citation cannot actually
>   be followed back to the claim.
> - **Coverage — what I did NOT check** — state explicitly what was out of
>   scope for this pass, so a gap is visible rather than assumed away.

### Why phase 3 exists — the argument from what actually happened

This is not an abstract precaution. `batch-1`'s own decomposition was put
through exactly this pass: an independent, context-less agent read all
seven raw files in full and re-verified every `Basis: VERIFIED` claim
against code. Verdict: **CHANGES REQUIRED**, 12 omissions and 5 distortions,
all applied in a single pass — restored items included a
dropped evidence case, a dropped impact bullet, and both reproduction
recipes; corrected items included a refuted "strict subset" dedup claim and
a stale line-number citation. Confirmed: zero fabrications. The
decomposition looked complete to the agent that wrote it, and it was not —
a self-reviewer does not reliably catch its own blind spots; a fresh reader
does.

The same pass surfaced a narrower lesson worth carrying forward. The
`b25-feedback-intake` package ledger records that the decomposer had
**defined** the basis class `REPORTED (self-caveated)` — the definition is
at `DECOMPOSED.md:16` — and had not applied it to the item that was its own
archetype for the class. That statement is the ledger's, not the
artifact's: `DECOMPOSED.md`'s own `## Audit trail` does not contain that statement.
On disk the class is now applied to two findings besides its
definition, so whatever the miss originally was, this verification pass
closed it. That is the whole argument for phase 3: not that decomposers
are careless, but that even a careful one defines a class and then forgets
to reach for it on the one case it was defined for.

## Phase 4 — Author

Packages are authored from the decomposition, never from the raw files —
phase 4 reads `DECOMPOSED.md`, not `feedback-N.txt`, and stays
operator-approved: nothing in phases 1-3 writes a package on its own.

## When NOT to use this skill

This flow is for accumulated, ambiguous, or multi-part feedback that needs
decomposing, sourcing and independent verification before it turns into
package work. It is not for short, direct feedback handled immediately —
an operator correction you can act on in the same turn does not need a
batch, a decomposition file or a verifier pass; just fix it and say so.
Reach for this skill when feedback needs to survive past the current
conversation, not when it doesn't.

This skill documents judgement work; it does not automate any of it. It
does not decompose feedback itself, does not auto-author packages, and
does not describe a UI, a queue, or a web form. Phase 2 stays a
human/agent judgement call and phase 4 stays operator-approved.
