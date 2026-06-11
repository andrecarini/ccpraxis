---
package: <NN-slug>
blueprint: <blueprint-name>
status: pending
model: sonnet
max_turns: 80
write_set: <colon-separated patterns, trailing / = prefix>
test_paths: <colon-separated patterns>
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
