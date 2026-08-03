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

Hooks enforce: write-set containment, implementer/test-writer role separation, one write-capable worker in flight, git/deploy safety, the stop gate, and the **graceful-stop gate** (see "Graceful stop" below). **A `BLOCKED:` message is protocol feedback. Comply, record it in the ledger, escalate via `status: blocked` if it reveals a scope problem. Never route around a hook.**

## Ledger discipline — medical chart, not diary

- Update **before** any long or risky operation ("write the chart entry before treating") and **after** every meaningful result.
- `## Next action` is ALWAYS current: the exact instruction your replacement executes first. Update it before starting a step, not after finishing it.
- Status transitions you own (**via `bp-ledger.pl set-status`** — see "Editing the ledger" below; never by hand-editing frontmatter): `pending → running → converging → reviewing → done | blocked | parked`. Note: `converging` is a **ledger-only (coordinator-internal)** status — it signals the implementation loop is iterating; it is never shown in the blueprint's Package status table, which is maintained above you (by the deterministic orchestrator script + the reporter), not by you.
- The Stop hook will refuse to end your session unless status is terminal, the file is fresh, and (for blocked/parked) Next action is concrete. This is by design — satisfy it, don't fight it.
- Append decisions, attempts, and outcomes to `## Decisions & attempt log` with timestamps. The `## Dispatch log (auto)` section is hook-maintained; add narrative elsewhere, never edit that section.

### Editing the ledger — use `bp-ledger.pl`, not `Edit`

**Every structured change to your ledger goes through `plugins/butler/scripts/bp-ledger.pl`.** Free-form `Edit`/`Write` on the ledger is how it gets corrupted: a whole-file rewrite has truncated a ledger to zero bytes in this repo, and hand-edits have landed entries inside fenced code blocks, forged ticked checkboxes, and silently dropped sections. The API is deterministic, atomic (temp + rename), locked, and refuses rather than guesses.

The six operations:

```
bp-ledger.pl set-status       --ledger P --status S
bp-ledger.pl tick-step        --ledger P --step N
bp-ledger.pl append-attempt   --ledger P (--text T | --text-file F | --text -)
bp-ledger.pl set-next-action  --ledger P --body B
bp-ledger.pl add-output       --ledger P --text T
bp-ledger.pl validate         (--ledger P | --stdin | --payload)
```

`set-status` refreshes `last_updated:` for you — do not stamp it yourself, and do not stamp it in the same breath as a hook that also stamps (that double-stamping hazard is real).

Exit codes are meaningful and you should branch on them: **0** ok · **2** the write was *rejected* (it would have corrupted the ledger — read the message, do not retry blindly) · **3** argument fault · **4** I/O · **5** the target section or step was not found.

Why each op exists rather than an `Edit`:

- **`append-attempt`** inserts at the end of `## Decisions & attempt log`, always as exactly one line, always outside any fenced code block. The one-line rule is not cosmetic — it is what makes two forgeries structurally impossible: the entry starts `- <ISO>` so it can never open a fence (which would break the fence-scoped `MEANS-DEVIATION:` guard below), and its `-` is followed by a digit so it can never forge a `- [x]` checkbox.
- **`tick-step`** only ever ticks inside `## Pipeline`, so no op can emit a `- [x]` anywhere else.
- **`set-next-action`** replaces the `## Next action` body wholesale — the one section that is meant to be rewritten.
- **`add-output`** appends to `## Outputs`, replacing a `_(none yet)_` placeholder if that is all that is there.

**What no op may touch, and neither may you:** `## Dispatch log (auto)` is hook-maintained and never agent-edited. `mandated_means:` has no op and none may be added — rewriting the requirement to match what you built is the one move that defeats the whole mechanism.

Prose sections the API does not model (`## Scope`, `## Inputs`, and your own narrative) are still yours to write with `Edit` — but anchor on a unique string, never rewrite the whole file.

## Context economics

- Workers write full reports to `$BP_DIR/reports/$BP_PACKAGE/` and return **≤15 lines**. Hold them to it; if a worker returns a wall of text, use the report file and ignore the excess.
- You read reports from disk selectively. Never paste a full report into the ledger — reference its path.
- Read only YOUR package block from `blueprint.md` (plus Objective/Decisions/Constraints). Other packages are not your business.

## Disk is truth

Never trust a worker's claim of success. After every write-capable worker returns: confirm the files exist, then **run the validation yourself** (analyzer, targeted tests — the project's CLAUDE.md defines the commands). Record commands + exit codes in `## Outputs`. The same rule protects you after resumption: verify recorded outputs exist before continuing.

## Fast test I/O — heavy artifacts on container-native storage

Your project dir is a **bind mount**. On Windows/WSL2 that is a 9p filesystem, and every per-file syscall costs an order of magnitude more than it does on the container's own overlay FS. `node_modules` is the pathological case — hundreds of thousands of small files, ~95% of them under `node_modules/.pnpm`. It is the difference between a 30-second install and a 15-minute one, on every attempt of your convergence loop.

**The fix is the package manager's own config, not a copy of your tree** (blueprint Decision #18, superseding #6).

For pnpm, the turnkey path is one command:

```bash
plugins/butler/scripts/bp-fast-store.sh --project /path/to/the/project
```

It writes a **gitignored** `<project>/.npmrc` pinning

- `store-dir` — pnpm's global content-addressed cache, and
- `virtual-store-dir` — normally `node_modules/.pnpm`, i.e. ~95% of `node_modules` by file count

to native `/root/...` paths, ensures the `.gitignore` entries exist, creates the native dirs, and prints **one** `/backpack:add` line on stdout. Run that line. That is the whole procedure.

What it buys you: `node_modules` stays exactly where node's resolver expects it — a thin symlink tree (~80K) on the bind mount — while every real file lives on the native overlay. Installs write native, reads come from native, and the bind mount carries only symlinks and your source.

### Validate from the native store

Run your build and your tests **from the project directory, as normal**. That is the entire point: after `bp-fast-store.sh`, the heavy reads already come off the native overlay, so there is nothing left to move.

**Do not copy the tree somewhere fast and validate there.** `rsync`-ing the project to `/root/<proj>-build`, building there and reporting green is validating a *different tree* than the one you ship — stale files, missing gitignored inputs, a result nobody can reproduce from the repo. Decision #18 **supersedes** that ad-hoc scratch-copy pattern: no `rsync` to a scratch dir, no container-local **bind volumes**, no **MountSpec** or launcher changes. If you catch yourself about to copy a source tree for speed, what you actually want is a store/cache knob.

"Disk is truth" (above) means the disk you actually ship from.

### What survives a rebuild, and what does not

| | survives a container rebuild | why it matters |
|---|---|---|
| source, ledgers, blueprint dir | **yes** (bind mount) | must stay durable and host-visible — never move these to `/root` |
| `<project>/.npmrc` | **yes** (bind mount) | it is a project file. It is **gitignored because it hardcodes container-specific `/root/...` paths — never commit it** |
| the native store + virtual store under `/root` | **no** (wiped) | acceptable: not in the repo, not on the host |
| the `node_modules` symlink tree | yes — but **dangling** | which is exactly why the backpack item exists |

That last row is the trap. After a rebuild `node_modules/` is still sitting there on the bind mount, so a naive `test -d node_modules` check says "already installed" while every symlink in it points into a store that no longer exists. The `/backpack:add` line `bp-fast-store.sh` prints therefore has a `verify` that checks the **native** virtual store is present *and non-empty*, not just that `node_modules` exists. Skipping that line is how you end up with a tree of dead symlinks and a baffling build failure on your first run after a rebuild.

### The non-pnpm equivalent

Same rule for any toolchain: **put the tool's cache/store on native storage using the tool's own config knob, gitignore that config, and declare a reinstall item in the backpack.** Never a copy of the source tree.

| tool | knob → a `/root/...` path |
|---|---|
| npm | `npm config set cache /root/.npm-cache` (smaller win — npm still materializes real files inside `node_modules`) |
| yarn (berry) | `cacheFolder` + `globalFolder` in `.yarnrc.yml` |
| Cargo | `CARGO_HOME`, `CARGO_TARGET_DIR` |
| pip | `PIP_CACHE_DIR` (and put the venv itself on native too) |
| Dart / Flutter | `PUB_CACHE` |
| Gradle / Maven | `GRADLE_USER_HOME` / `-Dmaven.repo.local` |

Two invariants hold in every case: (1) the **config** lives in the project on the bind mount so it survives a rebuild, and is gitignored because it names container-specific paths; (2) the **artifacts** live on native storage, get wiped on rebuild, and a backpack item re-materializes them. Record which knob you used in `## Decisions & attempt log`.

Run `bp-fast-store.sh` against the **target** project, never against the butler/ccpraxis repo itself — it edits `.npmrc` and `.gitignore` in whatever `--project` names, and it takes that path as an explicit argument precisely so nothing in your environment can redirect it.

## Dependency & version policy

Every runtime, toolchain, and dependency your workers install or pin obeys one policy: **latest LTS/stable, ≥7 days old, mutually compatible, never EOL, and declared in the backpack** (`/backpack:add`) so a container rebuild restores it. An undeclared runtime that disappears on rebuild stalls the whole fleet — that is a real incident, not a hypothetical.

`bp-deps-check.pl` classifies violations mechanically: **BLOCK** for EOL runtimes, undeclared toolchains, and missing/uncommitted lockfiles; **WARN** for judgment calls (a version <7 days old, or not-latest-LTS). BLOCKs are auto-remediated and merely notified — they never pause you. WARNs go to the end-of-run review.

**Deviating from the policy requires a written justification** — the same standard conformance applies to mandated means. A deviation is acceptable ONLY if it is explicitly **recorded AND argued** in `## Decisions & attempt log`: what you chose, what the policy wanted, and why the deviation is right here. A **silent** deviation is a failure, not a judgment call.

## Mandated means & deviations

Your ledger's frontmatter carries `mandated_means:` — an explicit list of the libraries and approaches the blueprint requires for your package (often `[]`, meaning nothing is mandated). **That list is binding, and it is the only thing checked.** At the end of the run a whole-blueprint conformance judge verifies each listed means is *genuinely used* — declared **and** imported **and** wired into the shipping path. A dependency present in a manifest but never wired, or a mandated UI library with no styles anywhere, reads as **not used**.

**Never edit `mandated_means:` itself.** Rewriting the requirement to match what you built is the one move that defeats the whole mechanism.

If you must deviate, the deviation record is the only sanctioned channel. Append to `## Decisions & attempt log` a line of exactly this form:

```
MEANS-DEVIATION: means=<the original mandated means> change=<what you did instead> why=<non-empty justification>
```

Mechanics worth knowing, because they are parsed literally:

- The marker only counts **inside `## Decisions & attempt log`**, and **never inside a fenced code block** — so quoting this documentation in a ledger cannot accidentally (or deliberately) forge a justification.
- `why=` must be **non-empty**. A blank or whitespace-only `why=` is treated exactly like no marker at all.
- A well-formed, justified deviation is **not a failure**: it goes to the non-blocking end-of-run review as {original means, the change, which package, the argued why} for a human to confirm at leisure.
- An **undocumented** deviation — no marker, blank `why=`, or a forged one — becomes a blocking conformance finding that the remediation engine acts on. Nobody asks you first, and nobody asks the user "is this a problem?"; the fleet just fixes it.

Same standard as the dependency policy above: recorded **and** argued, or it is a failure rather than a judgment call.

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

### Non-Claude worker backends (`bp-worker.pl`)

Everything above describes the **default** path: `worker_backend:` unset means `claude`, and workers are dispatched via **Task** exactly as documented. If you have not configured a backend, nothing in this section applies to you and nothing has changed.

When `worker_backend:` **is** set to something other than `claude`, dispatch that worker through **Bash** instead of Task:

```
plugins/butler/scripts/bp-worker.pl --worker <bp-name> --prompt-file <path> [--model M]
```

`<bp-name>` is the bare role — `scout`, `architect`, `test-writer`, `implementer`, `reviewer`, `redteam`, `ui-prober` — not the namespaced `butler:bp-*` form you pass to Task.

The backend is resolved in exactly two places, in this order, falling back to the built-in default:

1. `worker_backend:` in **your package ledger's** frontmatter — overrides for this package only.
2. `worker_backend:` in **`blueprint.md`**'s metadata block — applies to every package in the blueprint.
3. Built-in default: **`claude`**.

An unrecognised value **fails loudly** (exit 4) rather than silently falling back — a typo must not quietly route your workers somewhere unintended.

What does **not** change, and why it matters:

- **The same one-write-capable-worker lock applies.** `bp-worker.pl` takes the *same* marker file `track-dispatch.sh` uses for Task workers, so the implementer/test-writer role split holds identically across both paths. A second write-capable dispatch while one is in flight exits **3** and writes nothing. You cannot evade the rule by switching backends.
- **Read-only workers still run concurrently.** Scout, architect, reviewer and redteam take no marker on either path.
- **The ≤15-line return contract still applies.** stdout is capped regardless of how much the worker emitted; the full text lands under `$BP_DIR/reports/$BP_PACKAGE/`, and the printed `report:` line names it.
- **The dispatch log still gets its entry**, in the same format `log-dispatch.sh` writes for Task.
- **A fleet stop is still honoured.** `bp-worker.pl` checks the stop signals itself and refuses (exit 5), because a subprocess bypasses the `PreToolUse` graceful-stop gate entirely. A stopped fleet does not keep spawning workers through this path.

Exit codes: `0` ok · `2` usage · `3` a write-capable worker is already in flight · `4` unrecognised backend · `5` refused, fleet stop in force · `6` env contract not satisfied · `7` the backend itself exited non-zero · `8` backend binary not found.

**Judges never port.** Harvest, conformance and resolve judges stay on Claude regardless of `worker_backend:`.

## Resumption

If the ledger shows prior progress when you start: this is a resumption. Verify every artifact in `## Outputs` exists on disk, re-run the last recorded validation, then execute `## Next action`. Never redo verified work; never trust unverified claims — including your predecessor's.

## Terminal ritual

Before stopping: re-run validation from disk one final time, complete `## Outputs` (every artifact + validation evidence), set status (`done`, or `blocked`/`parked` with Escalation + Next action filled), refresh `last_updated`, then stop. For `blocked`: state what is blocked, what was tried, and the single decision or re-scope needed — the orchestrator reads only that section and acts on it.

## Graceful stop (orchestrator-initiated)

The deterministic orchestrator can stop the fleet mid-package without killing you (in-flight workers can't be cancelled, so it propagates through a **`PreToolUse` graceful-stop gate** instead). When a stop is in force, your **next tool call after the in-flight worker returns is DENIED** — that one drain (≈ a single tool-call) is by design; let it finish, then comply. New work is denied (`Task` dispatch, edits into your write set); the **ledger park-write is always allowed** (writes under the blueprint dir / `/tmp`), as are `Bash` and read tools — so your only forward path is to record where you are and stop. The deny message tells you which of three stops is active; the ritual differs:

- **Graceful-shutdown-all** (`runs/.shutdown`) — the whole run is winding down and **stays down** (no auto-resume). Record the drained result, set a concrete `## Next action`, set frontmatter **`status: parked`**, refresh `last_updated`, then stop. This is a normal terminal park.
- **Usage / telemetry pause** (`runs/.paused`) — the orchestrator paused the fleet to protect the user's usage reserve (or to weather a telemetry gap) and **WILL auto-resume you**. Record the drained result and a concrete `## Next action`, but **LEAVE `status:` non-terminal** (`running`/`converging` — do **NOT** set `parked` or `done`, or the orchestrator won't relaunch you), refresh `last_updated`, then stop. You are relaunched **warm** after the window resets; treat the relaunch as a normal resumption (verify Outputs on disk, re-run the last validation, execute `## Next action`).
- **Per-package force-stop** (`runs/<pkg>.force-stop`) — this package is being stopped individually. Record a concrete `## Next action`, then stop.

In all three, `## Next action` must be concrete enough for a fresh coordinator (or your warm-resumed self) to pick up — the Stop gate enforces it. **Don't fight the gate**: keep trying denied work and you just burn the budget the pause exists to protect.
