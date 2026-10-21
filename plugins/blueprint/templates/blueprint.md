# <Blueprint Title>

> **Living document, single source of truth for this initiative.** The orchestrator updates it on every state change. If `last_updated` lags the latest event, the orchestrator has fallen behind.

```
blueprint: <kebab-name>
created: <ISO date>
last_updated: <ISO date>
status: drafting        # drafting | audited | parked | archived -- running/done are computed
                         # (BpState::blueprint_lifecycle), never written here
```

## Objective

<What we're building and why. 2–3 sentences. What does "done" look like for the whole initiative?>

## Decisions

Locked answers from the user. Coordinators treat these as constraints, not suggestions. Append-only; never silently rewrite a decision — add a superseding entry.

| # | Decision | Decided | Date |
|---|----------|---------|------|
| 1 | <e.g. dual-path migration, old reads kept until TTL> | user | <date> |

## Package status

| pkg | deliverable | depends_on | model |
|-----|-------------|------------|-------|
| 01-<slug> | <one line> | — | sonnet |

_All packages default to `sonnet` in the `model` column above -- coordinators measured 84-95% of
blueprint cost across 4 blueprints, Opus runs 4.7x Sonnet's per-call cost, and a coordinator's own
work is overwhelmingly non-reasoning shell activity. Override a single package's cell only when
that package's own coordinator work needs deeper reasoning. Basis: report 20260917-172750-285a._

## Packages


One subsection per package. `write_set`, `test_paths`, `model` and `max_turns` are copied into each package ledger's **frontmatter** by `/blueprint:create` — the ledger copy is what scripts and hooks read at launch time. `scope`, `done_criteria`, `inputs` and `out_of_scope` are copied into the ledger's **body** sections.

**`depends_on` is not among them, and must never be written into a ledger.** The DAG lives in the package-status table above and nowhere else. `bp-ledger.pl` refuses *every* write to a ledger whose frontmatter carries `depends_on:` — including `set-status`, the only sanctioned way a coordinator reaches a terminal state, so such a ledger cannot be finished, blocked or parked and its coordinator burns its turn budget on a write that can never succeed (reports `20260916-185610-8ee1`, `20260917-063908-db14`). A ledger that already carries the key is repaired with `bp-ledger.pl migrate-depends-on --ledger <path>`, which moves the edge into a `## Dependency edges` section.

### 01-<slug> — <title>

- **scope:** <what this package builds; 2–4 sentences>
- **done_criteria:** <testable; e.g. "callable X returns 403 for role Y; suite test/x_test.dart green; screenshot of state Z reviewed">
- **write_set:** `lib/<area>/:functions/src/<area>/`        <!-- colon-separated; trailing / = prefix; * crosses / -->
- **test_paths:** `test/<area>/:integration_test/`
- **model:** sonnet    <!-- coordinator model; opus for gnarly packages. Deliberate default:
  coordinators are 84-95% of measured blueprint cost (4 blueprints), Opus is 4.7x Sonnet's per-call
  cost, and a coordinator's own work is overwhelmingly non-reasoning shell activity (one sampled
  coordinator: 704 of 1,561 calls were Bash, 473 `cd`). Basis: report 20260917-172750-285a. -->
- **max_turns:** 800

<!-- OPTIONAL: this project's check vocabulary. Delete the block if you have none —
     a blueprint without it implies no checks and behaves exactly as before. Each row
     maps a write-set pattern to a check name YOU define: trailing `/` matches by path
     prefix, `*` globs one path segment, anything else is a substring match. A package
     whose write_set matches a row must name that check in its `checks:` frontmatter,
     or `bp-checks.pl audit` (run by bp-auditor) fails the blueprint at authoring time.

```checks-table
*.ts        => typecheck
*.ts        => lint
functions/  => prod-build
*.rules     => rules-emulator
```
-->

- **inputs:** <files, decisions (#), docs the coordinator needs; inline file:line where known>
- **out_of_scope:** <explicit DO-NOT list>

## Constraints & known hazards

<Project-wide constraints relevant to this initiative; pointers into project CLAUDE.md sections rather than copies.>

## Key references

<Files, source locations, URLs — anything needed to resume from zero context.>

## Harvest log

Orchestrator-only. One row per package completion: what was verified ON DISK before flipping the status row.

| pkg | verified outputs | verified by | date |
|-----|------------------|-------------|------|
| | | | |

## Incidents

<Anything that destroyed work, surprised us, or changed the rules. Append-only.>
