---
name: feedback
description: Turns a batch of raw operator feedback into verified, sourced, basis-marked findings — capture verbatim, decompose, ask every clarifying question in ONE round, then have a fresh-context agent diff raw against decomposed to find what was dropped. Use whenever feedback arrives that is long, multi-part, or ambiguous enough that items could be silently lost, typically after testing what a blueprint run produced; the operator invokes it by prefixing the feedback itself with /butler:feedback. It is **not** for short, direct feedback handled immediately in the same conversation — file that with a quick fix, not this flow.
argument-hint: "[paste your raw feedback — or a batch name to resume one]"
---

# Feedback

## Invariants

Four properties hold across every phase. They are listed first because each one
was learned by losing something.

1. **Modality is preserved in both directions.** A mandate never becomes a
   suggestion, and a tentative proposal never becomes a mandate. "These are all
   things that need to be done" is binding; "a better design could just be…?" is
   a candidate. Softening the first is the error that a decomposition is most
   likely to make and least likely to notice, because the result still reads as
   reasonable.
2. **`REPORTED` is sufficient basis to schedule the work.** When the operator
   says something is broken, it is. Reproduction establishes the *mechanism*;
   it never decides whether the item exists. A failed reproduction downgrades
   confidence in the cause, not the finding.
3. **Authorship is tracked separately from evidence.** A basis marker says what
   a claim rests on. It does not say *whose* claim it is. A finding the agent
   added itself is marked as such and carries no claim of the operator's
   authority.
4. **Prefer a check that can fail.** The count invariant, the measured
   evidence, the fresh-context verifier — each exists so that being wrong is
   visible rather than merely possible.

## Two ways in

**A — the operator pastes a batch.** `/butler:feedback <the whole message>`.
Capture is the first action of the turn, before any interpretation, and the
bytes are lifted straight out of the session transcript rather than retyped:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-feedback.pl" \
  --from-session "${CLAUDE_SESSION_ID}" --command butler:feedback
```

Claude Code records a typed slash command with its arguments already separated
into a `<command-args>` payload, stored unescaped and untruncated — so this
route is byte-exact by construction. Nothing about the capture depends on an
agent copying a long message correctly. If the transcript cannot be found the
tool says so on STDERR and falls back to the argument text; a capture that fell
back is recorded as `Source: chat`, not `Source: transcript`, so the weaker
provenance is visible in the file rather than assumed away.

If the argument is a bare batch name (`batch-3`) rather than prose, nothing is
captured — resume that batch's decomposition instead.

(This file deliberately contains no argument placeholder token. Claude Code
substitutes such a token *in place*, which would splice the operator's whole
batch into the middle of these instructions; with none present the arguments
are appended once at the end instead, which is where the argv fallback wants
them anyway.)

**B — an agent captures feedback mid-task.** One command, no prompt, no editor,
no interpretation, and it returns to what it was doing:

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-feedback.pl" "the operator's exact words"
some-command | perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-feedback.pl"
```

`bp-feedback.pl` prints one line — the path it wrote — and exits. Everything
below happens LATER, in a separate pass, never inline with the agent that
captured the feedback.

## Phase 1 — Batch

Raw material accumulates untouched under `corrections/<batch>/`. Every capture
is one new file, `feedback-<n>.txt`, numbered from 1 and left numerically
unpadded — never `feedback-01.txt`. Raw files are never edited; they are
evidence of what the operator actually said, kept exactly as captured.

A batch that has a `DECOMPOSED.md` is **closed**: a decomposed batch is closed,
and new feedback opens the next batch, never joins a closed one. This is a
correctness property, not a style preference — a decomposition must cover
exactly its batch, and a verifier's "I read all N raw files" coverage claim has
to stay true after the fact. Appending an eighth raw file into a batch whose
`DECOMPOSED.md` already claims "read all seven" would falsify that claim
silently, while the artifact still looks complete.

**Capture the whole message, not the defects in it.** Praise, process
instructions, and asides are part of the batch. Praise in particular carries a
scope worth preserving: approval of *the screenshots* is not approval of the
app, and recording only "he liked it" has already turned a narrow compliment
into a general pass once.

## Phase 2 — Decompose

One output file, `DECOMPOSED.md`. The decomposition is a single file: every
finding gets a stable ID
(`<AREA>-<NN>`), its source file(s), and a basis marker — every claim states
whether it was independently verified in code this session (`VERIFIED`),
asserted by the filer with evidence (`REPORTED`), or explicitly flagged by the
filer as unreproducible (`REPORTED (self-caveated)`). The basis vocabulary is
open, not a closed list: findings may also carry `operator instruction` or
`operator testimony` when that is what the claim actually rests on. What is
required is that a basis marker is present on every claim, never that it comes
from a fixed set.

IDs are never renumbered once assigned. An insertion keeps its neighbours' IDs
stable, so numbering is not monotonic by design (`WAIT-08a` before `WAIT-08` is
correct, not a bug) — renumbering would silently invalidate every existing
citation to those IDs.

Attribution belongs on every finding that has a raw source. Where a finding has
no raw source at all, or states its attribution inline in its own heading
instead of a `**Source:**` field, that is legitimate; the basis marker remains
the only field required on every finding.

Beyond attribution, each finding carries:

- **The operator's words, verbatim and inline** — a `**Verbatim:**` quote, not
  only a file citation. A citation lets a reader go look; an inline quote means
  they cannot proceed without the actual words in front of them. Most of the
  failures this phase is guarding against are drift between what was said and
  what was recorded, so this is cheap and load-bearing.
- **Their scope and quantity words** — "but that's for the mobile view", "at
  least 5 variants". These bound the deliverable. Dropping them silently
  changes it.
- **An agent-originated flag** where it applies. An agent's own good idea
  acquires the operator's authority by sitting next to his — say plainly which
  items are additions of yours.
- **Measured evidence, not recollection** — `file:line`, pixel spans at named
  viewports, actual output. And when one mechanism appears to explain several
  symptoms, label that as an **inference** and require per-symptom
  re-verification. A tidy unified cause is exactly when a decomposition is most
  likely to be wrong and least likely to be questioned.

**An interrogative is a finding.** "Regressions?", "have you thought about
these edge cases?", "have you introduced any design tokens?" — each is work,
and each is owed a *written answer*, not silent absorption into whatever fix
seemed adjacent. Track it as an item whose done-criterion is that answer.

**Three dispositions, not two.** Feedback batches routinely mix product defects
with instructions about how to work. Both are captured; only one becomes
package work. The third disposition is **tracked, out of scope, with the
reason** — recorded in the decomposition and explicitly excluded from the
blueprint, so it is neither dropped nor smuggled into a package.

**Count yourself, mechanically.** End with a declared total, a per-group
breakdown that sums to it, and the command that checks both
(`grep -c '^### ' DECOMPOSED.md`). A completeness document that cannot count
its own items is not a completeness check.

The decomposition also carries these standing sections, matched by the
artifact's own heading text: `## How to read this`,
`## Operator rulings collected while decomposing`,
`## Overlap map — in-flight packages`, `## Proposed package grouping`,
`## Open items — not resolved by this decomposition`, and `## Audit trail`.

Also required: dedup across drafts, an overlap analysis against in-flight
packages, and a proposed package grouping — see the next two sections.

## Phase 2.5 — Question

Ask every disambiguating question in **ONE batched round** via
`AskUserQuestion`, after the decomposition exists and before it is finalized.
The operator's model is *"I answer for two minutes, then agents work for
hours"* — so a question that arrives mid-flight is a defect, not diligence.
This is the same batched-interrogation contract `blueprint:authoring-protocol`
uses, applied one stage earlier.

`AskUserQuestion` takes at most four questions per call, and a real batch
routinely raises more. More than four is still ONE round — issue the calls
back to back, with no decomposition work, file writes or tool detours between
them. What makes a round a round is that the operator answers everything in a
single sitting; it is not a count of tool calls. Rank by consequence so that if
attention runs out, the answers you did get are the ones that change the work.

Prefer options over open prose: the operator picks in seconds, and a chosen
option is unambiguous in a way a free-text reply often isn't. Where the choice
is between concrete shapes (two groupings, two readings of a defect), put them
in the option `preview` so the comparison is visible rather than described.
Never invent a default for an unanswered question — mark it `[Q]` and carry it
into `## Open items — not resolved by this decomposition`.

Mark each open question `[Q]` in place on the finding it belongs to, and
`[Q→resolved]` once answered, so an unanswered question is syntactically
distinguishable rather than a matter of reading comprehension. Land the answers
in a provenance table — Item / Question / Operator's answer — so the basis for
a resolution is still auditable months later.

A second round is a process failure. If one is genuinely unavoidable, say so
and say why.

## Overlap with in-flight packages

When a finding overlaps a package that is already running, the decomposition
does not edit that package: it must never edit a running package's criteria.
Instead it should note the overlap and propose a follow-on package that covers
the gap. Track it in a small per-package table:

| package | covers | gap for a follow-on |
|---|---|---|
| ... | what the running package already handles | what this finding needs that it does not |

## Deduplication discipline

Multiple raw files often describe the same thing from different angles. Merge
duplicate drafts, but uniques are named explicitly — material that is genuinely
unique to one draft is called out by name, not folded silently into the merged
text. Where two drafts disagree outright,
the divergence is recorded rather than silently resolved: pick neither side by
fiat, write the contradiction up
as its own finding, and let phase 3 or the operator settle it. A close
paraphrase (one draft is a précis of a fuller one) can be merged once verified
assertion-by-assertion; a narrower draft that only partially overlaps a fuller
one is not a strict subset and must not be described as one without checking
every claim.

## Phase 3 — Verify

Dispatch the verifier via Task with `subagent_type: butler:bp-feedback-verifier`
(the plugin-namespaced form is authoritative). The agent is fresh,
context-less and read-only — and read-only *structurally*: it is given no
Write, Edit or Bash tool, so "report, don't fix" is enforced rather than
requested. It must not be the
agent that wrote the decomposition, nor one handed that agent's context, which
satisfies "different agent" nominally while defeating the entire point. Its job
is framed as a *diff*: compare the raw files against the decomposition and find
what was lost.

### Verifier brief

Give it the batch directory and this brief, close to verbatim:

> Read **all** raw feedback files in this batch, in full. Re-verify every claim
> marked `Basis: VERIFIED` against the code or artifact it cites — do not trust
> the decomposer's word for it. Report; do not fix anything yourself. Return
> exactly these eight parts:
>
> - **Verdict** — overall: does the decomposition hold up as written?
> - **Omissions** — real material from the raw files the decomposition dropped.
> - **Distortions** — claims the decomposition mischaracterizes.
> - **Modality drift** — anything required recorded as optional, or tentative
>   recorded as settled; and any scope or quantity bound that was dropped.
> - **Fabrications** — claims with no support in the raw files or the code.
> - **Deduplication errors** — merges that lost unique material, or
>   subset/superset claims that do not hold.
> - **Traceability gaps** — findings whose source citation cannot actually be
>   followed back to the claim.
> - **Coverage — what I did NOT check** — state explicitly what was out of
>   scope for this pass, so a gap is visible rather than assumed away.

### Why phase 3 exists — the argument from what actually happened

This is not an abstract precaution. `batch-1`'s own decomposition was put
through exactly this pass: an independent, context-less agent read all seven
raw files in full and re-verified every `Basis: VERIFIED` claim against code.
Verdict: **CHANGES REQUIRED**, 12 omissions and 5 distortions, all applied in a
single pass — restored items included a dropped evidence case, a dropped impact
bullet, and both reproduction recipes; corrected items included a refuted
"strict subset" dedup claim and a stale line-number citation. Confirmed: zero
fabrications. The decomposition looked complete to the agent that wrote it, and
it was not — a self-reviewer does not reliably catch its own blind spots; a
fresh reader does.

The same pass surfaced a narrower lesson worth carrying forward. The
`b25-feedback-intake` package ledger records that the decomposer had **defined**
the basis class `REPORTED (self-caveated)` — the definition is at
`DECOMPOSED.md:16` — and had not applied it to the item that was its own
archetype for the class. That statement is the ledger's, not the artifact's:
`DECOMPOSED.md`'s own `## Audit trail` does not contain that statement. On disk
the class is now applied to two findings besides its definition, so whatever
the miss originally was, this verification pass closed it. That is the whole
argument for phase 3: not that decomposers are careless, but that even a
careful one defines a class and then forgets to reach for it on the one case it
was defined for.

The `Modality drift` bucket has the same provenance. In batch 3 the operator
wrote *"These are all things that needs to be done"*, and the decomposition
dropped it and substituted an invented gloss — "refinement, not rejection" —
which an auditor caught. That failure is neither an omission nor a distortion
of any single claim: it inverts the *batch's* modality while every individual
finding still reads correctly. Without its own bucket it has nowhere to be
reported.

## Phase 4 — Author

Packages are authored from the decomposition, never from the raw files — phase
4 reads `DECOMPOSED.md`, not `feedback-N.txt`. Then, before anything is
dispatched:

1. **Run `blueprint:bp-auditor` on the blueprint.** A mandatory gate, not a
   formality — it is the gate that caught the modality inversion above.
2. **Dispatch only when the operator says so.** He may explicitly say "don't
   launch the fleet." Nothing in phases 1–3 writes a package on its own, and
   phase 4 stays operator-approved.

## Where this lives, and what is not backing it up

Everything the flow produces sits under `<project>/.ccpraxis-local-data/corrections/`,
which is gitignored. Git never carries it, so no push has ever backed it up.
`/steward:backup` does sync it to the vault — that is the only copy off this
machine. Say so rather than letting a green `git status` imply the evidence is safe.

## When NOT to use this skill

This flow is for accumulated, ambiguous, or multi-part feedback that needs
decomposing, sourcing and independent verification before it turns into package
work. It is not for short, direct feedback handled immediately — an operator
correction you can act on in the same turn does not need a batch, a
decomposition file or a verifier pass; just fix it and say so. Reach for this
skill when feedback needs to survive past the current conversation, not when it
doesn't.

This skill documents judgement work; it automates only the capture. It does not
decompose feedback itself, does not auto-author packages, and does not describe
a UI, a queue, or a web form. Phase 2 stays a human/agent judgement call and
phase 4 stays operator-approved.
