# <Blueprint Title>

> **Living document, single source of truth for this initiative.** The orchestrator updates it on every state change. If `last_updated` lags the latest event, the orchestrator has fallen behind.

```
blueprint: <kebab-name>
created: <ISO date>
last_updated: <ISO date>
status: drafting        # drafting | audited | running | done | archived
# worker_backend: claude              <!-- optional blueprint-level default; b32 -->
# worker_models:                      <!-- optional blueprint-level default/per-role fallback ladder;
#   b35. Same shape as the package-ledger key (see templates/package-ledger.md); a package ledger's
#   own worker_models: (role or default entry) always wins over this. Absent/empty falls through to
#   the built-in (opencode/big-pickle). Never overloads `model:` (coordinator's Claude model).
#   worker_models:
#     default: [opencode/big-pickle]
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

## Packages

One subsection per package. These fields are copied into each package ledger's frontmatter by `/blueprint:create` — the ledger copy is what scripts and hooks read at launch time.

### 01-<slug> — <title>

- **scope:** <what this package builds; 2–4 sentences>
- **done_criteria:** <testable; e.g. "callable X returns 403 for role Y; suite test/x_test.dart green; screenshot of state Z reviewed">
- **depends_on:** <— | pkg ids>
- **write_set:** `lib/<area>/:functions/src/<area>/`        <!-- colon-separated; trailing / = prefix; * crosses / -->
- **test_paths:** `test/<area>/:integration_test/`
- **model:** sonnet                                          <!-- coordinator model; opus for gnarly packages -->
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
