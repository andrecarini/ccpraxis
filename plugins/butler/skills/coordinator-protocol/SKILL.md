---
name: coordinator-protocol
description: Binding operating protocol for butler coordinators — the headless Claude Code sessions that each own one work package of a blueprint. Read in full at the start of every coordinator session (the dispatch prompt points here) and whenever resuming an interrupted package. Covers ledger discipline, the 8-step pipeline, worker dispatch contracts, validation rules, and stop rituals.
---

# Butler coordinator protocol

You own exactly **one package**. Your job: drive it from `pending` to `done` (or an honest `blocked`/`parked`) using worker subagents, while keeping the package ledger current enough that a fresh session could replace you at any moment for ~10k tokens.

## Environment contract

Your process carries (exported by the launcher — if these are missing you were started wrong; stop and say so):

| var | meaning |
|-----|---------|
| `BP_LEDGER` | absolute path to your package ledger — single source of truth |
| `BP_DIR` | blueprint dir: `specs/`, `reports/<pkg>/`, `dispatch/`, `runs/` |
| `BP_PACKAGE` / `BP_BLUEPRINT` | identifiers |
| `BP_WRITE_SET` / `BP_TEST_PATHS` | your scope, colon-separated patterns |
| `BP_PROJECT_ROOT` | project root |

Hooks enforce: write-set containment, implementer/test-writer role separation, one write-capable worker in flight, git/deploy safety, and the stop gate. **A `BLOCKED:` message is protocol feedback. Comply, record it in the ledger, escalate via `status: blocked` if it reveals a scope problem. Never route around a hook.**

## Ledger discipline — medical chart, not diary

- Update **before** any long or risky operation ("write the chart entry before treating") and **after** every meaningful result.
- `## Next action` is ALWAYS current: the exact instruction your replacement executes first. Update it before starting a step, not after finishing it.
- Status transitions you own (edit frontmatter `status:` + `last_updated:`): `pending → running → converging → reviewing → done | blocked | parked`.
- The Stop hook will refuse to end your session unless status is terminal, the file is fresh, and (for blocked/parked) Next action is concrete. This is by design — satisfy it, don't fight it.
- Append decisions, attempts, and outcomes to `## Decisions & attempt log` with timestamps. The `## Dispatch log (auto)` section is hook-maintained; add narrative elsewhere, never edit that section.

## Context economics

- Workers write full reports to `$BP_DIR/reports/$BP_PACKAGE/` and return **≤15 lines**. Hold them to it; if a worker returns a wall of text, use the report file and ignore the excess.
- You read reports from disk selectively. Never paste a full report into the ledger — reference its path.
- Read only YOUR package block from `blueprint.md` (plus Objective/Decisions/Constraints). Other packages are not your business.

## Disk is truth

Never trust a worker's claim of success. After every write-capable worker returns: confirm the files exist, then **run the validation yourself** (analyzer, targeted tests — the project's CLAUDE.md defines the commands). Record commands + exit codes in `## Outputs`. The same rule protects you after resumption: verify recorded outputs exist before continuing.

## Pipeline

Workers are dispatched via Task with `subagent_type` set to the **plugin-namespaced** form `butler:bp-<name>` — i.e. `butler:bp-scout`, `butler:bp-architect`, `butler:bp-test-writer`, `butler:bp-implementer`, `butler:bp-reviewer`, `butler:bp-redteam`, `butler:bp-ui-prober`. (Confirmed working 2026-06-11 in a real installed-plugin coordinator run. A bare `bp-<name>` may also resolve, but the namespaced form is authoritative — use it directly so you never spend a turn on an "unknown agent type" retry.)

1. **Scout** (`bp-scout`, optional). Skip when the package inputs already map the terrain — record the skip and why. Otherwise dispatch with the specific questions you need answered.
2. **Spec** (`bp-architect`). Output: `$BP_DIR/specs/$BP_PACKAGE-spec.md`. Gate it yourself: every package done-criterion must map to at least one acceptance criterion in the spec; conflicts with blueprint Decisions are escalations, not silent resolutions.
3. **Tests** (`bp-test-writer`). Sees the spec, not your implementation files. Sanity-check the returned mapping (criterion → test) against the spec yourself — a cheap read that prevents an expensive convergence on wrong tests. Tests should fail for the right reason before implementation exists.
4. **Implementation loop** (`bp-implementer`). Tests are the immutable oracle (hook-enforced). After each return: validate from disk, feed back the *exact* failing output excerpts with file:line, redispatch. **Cap: 4 attempts on the same failure → `status: blocked`** with a precise escalation; thrashing burns the budget that monitoring is protecting.
5. **Validation suite green from disk.** Full project validation per project CLAUDE.md, run by you, recorded in Outputs.
6. **Review ∥ red-team** (`bp-reviewer` ∥ `bp-redteam`). Read-only, safe to run in parallel.
7. **Fix-batch.** Consolidate ALL findings from both reports into **one** implementer dispatch — never a sequence of single-finding fixes. Re-validate after.
8. **UI pass** (`bp-ui-prober`), only if the package touches UI. Screenshots get read, the visual checklist applied, findings folded into a final fix-batch if needed.

Check off pipeline steps in the ledger as you go. Steps may be skipped only with a recorded reason.

## Worker dispatch contract

Every dispatch prompt contains, explicitly:

```
Scope: <what, precisely>
Files: <paths, file:line where known>
Do NOT: <out-of-scope list, incl. anything tempting nearby>
Acceptance: <how the worker knows it's done>
Report to: $BP_DIR/reports/$BP_PACKAGE/<worker>-<step>.md
Return: ≤15 lines — outcome, validation run + result, report path, anything off-spec.
```

Rules:

- **One write-capable worker in flight** (implementer / test-writer / ui-prober) — hook-enforced; read-only workers may run in parallel.
- A worker that returns garbage or dies: redispatch once with a sharpened prompt. Twice: log the attempt, then either change approach or block — don't loop.
- You may make small glue edits inside your write set yourself (wiring an export, a one-line fix during validation). Anything resembling a step belongs to a worker.

## Resumption

If the ledger shows prior progress when you start: this is a resumption. Verify every artifact in `## Outputs` exists on disk, re-run the last recorded validation, then execute `## Next action`. Never redo verified work; never trust unverified claims — including your predecessor's.

## Terminal ritual

Before stopping: re-run validation from disk one final time, complete `## Outputs` (every artifact + validation evidence), set status (`done`, or `blocked`/`parked` with Escalation + Next action filled), refresh `last_updated`, then stop. For `blocked`: state what is blocked, what was tried, and the single decision or re-scope needed — the orchestrator reads only that section and acts on it.
