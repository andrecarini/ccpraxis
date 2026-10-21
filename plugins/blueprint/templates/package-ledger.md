---
package: <NN-slug>
blueprint: <blueprint-name>
status: pending
model: sonnet
effort: medium
# coordinator model/effort -- deliberate defaults, not accidental.
# Basis: coordinators are 84-95% of measured blueprint cost
# across 4 blueprints (jrm-ux-correctness $1014.56/95%,
# sourcing-hardening $515.91/94%, fleet-tick-harness
# $276.43/85%, author-prefix-audit $203.51/84%); Opus runs
# $0.218/call vs Sonnet's $0.046 (4.7x); a coordinator's own
# work is overwhelmingly non-reasoning shell activity (one
# sampled coordinator: 704 of 1,561 calls were Bash, 473 `cd`).
# Override per-package here (model: opus and/or effort: high|xhigh)
# ONLY when THIS package's coordinator work itself is
# reasoning-heavy, with the reason recorded as a Decision.
# Basis: report 20260917-172750-285a (fleet-cost-accounting b04).
max_turns: 800
write_set: <colon-separated patterns, trailing / = prefix>
test_paths: <colon-separated patterns>
checks: <colon-separated check names this write set can break — see below>
#   `test_paths` is a SCOPE limiter: WHICH tests run. `checks` is a KIND list:
#   what sorts of verification this write set can break. They are different
#   questions, and the gap between them is where escapes live — five defects
#   reached one initiative's closing gate because the check that would have
#   caught each was in no package's criteria (a production-mode build, a
#   Firestore index, a route load, a lint error latent for weeks, and a
#   workspace unbuildable for five days while every package reported green).
#
#   The names come from YOUR PROJECT's `checks-table` in blueprint.md. There is
#   no built-in list: this tool is stack-agnostic, and a blueprint with no table
#   implies nothing. Derive with:
#       bp-checks.pl derive --blueprint <blueprint.md> --write-set <SET>
#   and audit the whole blueprint with `bp-checks.pl audit --blueprint ...`.
last_updated: <ISO timestamp>
---

# Package <NN-slug> — <title>

> **Medical chart, not a diary.** The coordinator updates this BEFORE risky/long operations (write the chart entry before treating) and AFTER every meaningful result. The Stop hook will refuse to let the session end unless `status` is terminal (done | blocked | parked), the file is fresh, and — for blocked/parked — "Next action" is concrete. A fresh coordinator must be able to resume from this file alone.

## Scope

<Copied from the blueprint package block at create time. The contract — do not expand it.>

## Done criteria

<Testable, copied from blueprint. Every item gets verified ON DISK before status: done.>

## Inputs

<Files (with line refs where known), decision numbers from the blueprint, docs.>

## Pipeline

- [ ] 1. Scout (skip if scope already maps cleanly — record the skip)
- [ ] 2. Spec written to specs/<NN-slug>-spec.md and checked against done criteria
- [ ] 3. Tests written from spec (bp-test-writer) and sanity-checked against spec
- [ ] 4. Implementation converged (bp-implementer; tests immutable; loop ≤ 4 attempts)
- [ ] 5. Validation suite green from disk (commands + exit codes recorded below)
- [ ] 6. Review ∥ red-team complete (report paths below)
- [ ] 7. Fix-batch applied (single dispatch) and re-validated
- [ ] 8. UI pass (only if package touches UI) — screenshots read, checklist applied

## Decisions & attempt log

Append-only, newest last. Every attempt, result, and judgment call with timestamp.

- <ISO> — <event / decision / outcome>

## Next action

<ALWAYS current. The exact instruction a fresh coordinator executes first. Updated before any long-running step, not after. Placeholder counts as empty — the Stop gate rejects it for blocked/parked.>

## Outputs

<Spec path, test files, impl files, report paths, validation commands + exit codes, screenshot paths. Only things that exist on disk.>

## Escalation (when status: blocked)

<What is blocked, what was tried, what decision or re-scope is needed from the orchestrator/user.>

## Dispatch log (auto)
