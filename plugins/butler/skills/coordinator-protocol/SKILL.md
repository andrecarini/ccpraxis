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

#### …but only inside a butler-LAUNCHED coordinator

That sentence is true of *this* session — a coordinator started by `bp-launch.sh` — and false
almost everywhere else. Every butler hook but one begins with `bp_hook_gate` (`hooks/lib.sh:9`),
which **exits 0 (allow) unless `BP_LEDGER`, `BP_DIR` and `BP_PROJECT_ROOT` are all set**. Those are
exported by `bp-launch.sh` only. So in a `/butler:drive-solo` run, in a manually-dispatched
`Task`/Agent subagent, and in any ordinary interactive session, write-set containment, role
separation and the one-write-capable-worker lock are **convention, not enforcement** — nothing will
stop a violation, and nothing will report one.

The single exception is **`guard-git-mutations.sh`**, which deliberately carries no `bp_hook_gate`
and applies everywhere (see its header). It exists because the gate opening in a manual drive is
not hypothetical: a prohibited `git stash` swept away a completed, uncommitted fix-batch that the
ledger had already recorded as done.

**What this means for you:** never infer "a hook would have caught it" from the list above. If you
are driving without the `BP_*` contract, `git status` after every write-capable worker is the only
containment check you actually have.

### `BP_REPORT_DIR` — derive capture output paths, never hardcode one

`BP_REPORT_DIR` is exported by `bp-launch.sh` as `$BP_DIR/reports/$BP_PACKAGE` — absolute, inside `$BP_DIR`, and therefore always in-set. Any capture driver you dispatch (screenshots, generated artifacts, anything a worker writes as evidence) must **derive** its output path from `BP_REPORT_DIR`, never hardcode a literal path string. A hardcoded literal is the actual root cause of a real incident: a package's spec was inherited from a previous blueprint and carried that blueprint's literal reports path, so it outlived the blueprint it belonged to and kept writing into an archived one long after. A path derived from `BP_REPORT_DIR` cannot outlive its blueprint the way a hardcoded one can.

## Ledger discipline — medical chart, not diary

- Update **before** any long or risky operation ("write the chart entry before treating") and **after** every meaningful result.
- `## Next action` is ALWAYS current: the exact instruction your replacement executes first. Update it before starting a step, not after finishing it.
- Status transitions you own (**via `bp-ledger.pl set-status`** — see "Editing the ledger" below; never by hand-editing frontmatter): `pending → running → converging → reviewing → done | blocked | parked`. Note: `converging` is a **ledger-only (coordinator-internal)** status — it signals the implementation loop is iterating; it is never shown in blueprint.md's Package status table at all — that table carries no status column; per-package progress is read from ledgers via `/butler:status`, never authored by you into blueprint.md.
- The Stop hook will refuse to end your session unless status is terminal, the file is fresh, and (for blocked/parked) Next action is concrete. This is by design — satisfy it, don't fight it.
- Append decisions, attempts, and outcomes to `## Decisions & attempt log` with timestamps. The `## Dispatch log (auto)` section is hook-maintained; add narrative elsewhere, never edit that section.

### Editing the ledger — use `bp-ledger.pl`, not `Edit`

**Every structured change to your ledger goes through `plugins/butler/scripts/bp-ledger.pl`.** Free-form `Edit`/`Write` on the ledger is how it gets corrupted: a whole-file rewrite has truncated a ledger to zero bytes in this repo, and hand-edits have landed entries inside fenced code blocks, forged ticked checkboxes, and silently dropped sections. The API is deterministic, atomic (temp + rename), locked, and refuses rather than guesses.

The seven operations:

```
bp-ledger.pl set-status       --ledger P --status S
bp-ledger.pl tick-step        --ledger P --step N
bp-ledger.pl append-attempt   --ledger P (--text T | --text-file F | --text -)
bp-ledger.pl set-next-action  --ledger P --body B
bp-ledger.pl add-output       --ledger P --text T
bp-ledger.pl rotate           --ledger P [--keep N] [--budget BYTES] [--dry-run]
bp-ledger.pl validate         (--ledger P | --stdin | --payload)
```

`set-status` refreshes `last_updated:` for you — do not stamp it yourself, and do not stamp it in the same breath as a hook that also stamps (that double-stamping hazard is real).

Exit codes are meaningful and you should branch on them: **0** ok · **2** the write was *rejected* (it would have corrupted the ledger — read the message, do not retry blindly) · **3** argument fault · **4** I/O · **5** the target section or step was not found.

Why each op exists rather than an `Edit`:

- **`append-attempt`** inserts at the end of `## Decisions & attempt log`, always as exactly one line, always outside any fenced code block. The one-line rule is not cosmetic — it is what makes two forgeries structurally impossible: the entry starts `- <ISO>` so it can never open a fence (which would break the fence-scoped `MEANS-DEVIATION:` guard below), and its `-` is followed by a digit so it can never forge a `- [x]` checkbox.
- **`tick-step`** only ever ticks inside the **Pipeline** section, so no op can emit a `- [x]` anywhere else.
- **`set-next-action`** replaces the `## Next action` body wholesale — the one section that is meant to be rewritten.
- **`add-output`** appends to `## Outputs`, replacing a `_(none yet)_` placeholder if that is all that is there.
- **`rotate`** moves stale `## Decisions & attempt log` entries out to `reports/ledger-history/<pkg>.md` (a path derived from your ledger's own `.../packages/<pkg>.md` shape — never guess a different location: `bp-resume-sweep.sh` and `bp-status.sh` glob `packages/*.md`, so history must never land there or it gets enumerated as a bogus package). See "Context budget" below for when and why to run it.

**What no op may touch, and neither may you:** `## Dispatch log (auto)` is hook-maintained and never agent-edited. `mandated_means:` has no op and none may be added — rewriting the requirement to match what you built is the one move that defeats the whole mechanism.

Prose sections the API does not model (`## Scope`, `## Inputs`, and your own narrative) are still yours to write with `Edit` — but anchor on a unique string, never rewrite the whole file.

### The `TOOLING-BUG-FILED:` marker

Same family as `MEANS-DEVIATION:` above — a marker mandated in prose, counted only inside
`## Decisions & attempt log`, and never inside a fenced code block, so quoting this documentation in
a ledger cannot forge one either:

```
TOOLING-BUG-FILED: id=<almanac report id> why=<one-line: why this is unreachable from this package>
```

Write it once — never before — `almanac-bug.pl file` has actually succeeded and printed a path:
`id=` is the filename it printed, minus `.md`, never guessed ahead of the real filing. `why=` must
be **non-empty**, the same integrity rule as that marker's own `why=`. Write it via `bp-ledger.pl
append-attempt`, never hand-edited — same discipline as every other structured ledger change.

Write it when BOTH hold: (1) the finding is a genuine ccpraxis tooling defect, not your own
package's bug — the same test `plugins/almanac/skills/bug-report/SKILL.md`'s "Before you file"
already asks; (2) it is not fixable inside your own write set — matches
`.ccpraxis-local-data/guidance/fix-ccpraxis-defects-in-place.md`'s own carve-out. If it IS reachable,
that guidance's default applies instead: fix it, file nothing.

A worked example of the quality bar a filed report needs (bug-report's "What makes a report worth
reading" transfers almost verbatim): the registry-path `$PWD` guess still live at
`plugins/butler/hooks/lib.sh:380`, `plugins/butler/hooks/mark-wakeup.sh:214`, and two sites inside
the reporter's own drive-loop gate script — file:line, verified from disk, evidence stated plainly,
exactly the bar this filing needs.

### Context budget — your ledger has one, and a fix when it's blown

Your ledger's `## Decisions & attempt log` is append-only for the life of the package: a fresh
session must be able to replace you at any moment for roughly **~10k tokens**, and unbounded growth
defeats that. `bp-ledger.pl` enforces a single named byte budget (`DEFAULT_BUDGET_BYTES`, **40,000
bytes** — ~10k tokens at this repo's ~4 bytes/token estimate) and makes crossing it **visible rather
than silent**:

- **`append-attempt` never refuses.** If the append would leave the ledger over budget, it still
  performs the append (losing the record is worse than exceeding the budget) but prints one warning
  line to stderr naming the resulting size, the budget, and the fix: `bp-ledger.pl rotate --ledger
  <your ledger>`.
- **`rotate` is the fix.** It moves stale attempt-log entries — verbatim, in original order — to a
  per-package history file at `reports/ledger-history/<pkg>.md`, which is itself append-only and
  nothing else ever reads. Run it as soon as you see the warning; don't let it accumulate across
  several attempts.
- **What can never move, at any budget pressure:**
  - Every entry containing a `MEANS-DEVIATION:` marker, at any age — the whole-blueprint conformance
    gate reads only your ledger (never history), so a rotated-out marker would blind it silently.
  - The most recent `--keep` entries (default **5**) — a hard **floor**, not a target: retention is
    budget-driven (keep newest-first for as long as the whole ledger fits `--budget`), but rotation
    never digs into the floor to reach the number, "however large they are," so a replacement
    coordinator always has recent context.
- **Not a retention rule, a never-bisect rule:** a fenced code block is never *split* across the
  ledger/history boundary. An entry containing a complete fence is an ordinary trim candidate and may
  move as a unit — nothing about a code fence makes an old entry operative. Only the splitting is
  forbidden, because a bisected fence corrupts both halves and can forge a fence boundary.
- If the floor and the retained markers together still exceed budget, `rotate` moves everything it
  legitimately can, exits **0**, and prints one line naming the ledger, the resulting size, and *why*
  it couldn't reach budget. Landing over budget loudly is an honest outcome; dropping an entry to hit
  the number is not an option `rotate` will ever take.
- **Sections `rotate` never touches:** everything except `## Decisions & attempt log` — frontmatter,
  `## Scope`, `## Done criteria`, `## Inputs`, `## Out of scope`, the **Pipeline** section, `## Next action`,
  `## Outputs`, `## Escalation`, `## Dispatch log (auto)`. `--dry-run` reports what would move without
  touching either file; `rotate` is idempotent (a repeat run with the same arguments changes nothing).

## Context economics

- Workers write full reports to `$BP_DIR/reports/$BP_PACKAGE/` and return **≤15 lines**. Hold them to it; if a worker returns a wall of text, use the report file and ignore the excess.
- You read reports from disk selectively. Never paste a full report into the ledger — reference its path.
- Read only YOUR package block from `blueprint.md` (plus Objective/Constraints, and the Decisions table). Other packages are not your business.
- **Decisions are stored as binding statement + pointer.** The table in `blueprint.md` gives you the id and what each decision *rules* — that is what binds you, and it is all you normally need. The full argument (evidence, rejected alternatives, history) lives in `reports/decisions/<ID>.md`. **Follow the pointer only when the ruling alone does not settle your question** — you are the reason the split exists, and re-reading every argument re-imports the cost it removed. When a decision is cited by id in your ledger, the statement is the citation's target; the report is its footnote.

## Disk is truth

Never trust a worker's claim of success. After every write-capable worker returns: confirm the files exist, then **run the validation yourself** (analyzer, targeted tests — the project's CLAUDE.md defines the commands). Record commands + exit codes in `## Outputs`. The same rule protects you after resumption: verify recorded outputs exist before continuing.

### A `write-set` bounds the agent, not the subprocesses it spawns

`guard-writes.sh` intercepts `Edit`/`Write`/`MultiEdit`/`NotebookEdit` **tool calls** — that is the entire enforcement surface. Nothing intercepts a subprocess you launch with `Bash`: a script, a build step, a capture driver can write anywhere on disk the OS permissions allow, completely outside `BP_WRITE_SET`, and no hook will see it. Do not treat write-set containment as absolute — it is a contract on you, not a sandbox around everything you run. `plugins/butler/scripts/bp-containment-audit.pl` exists precisely to make out-of-set subprocess writes **visible** (it reports; it does not block) — run it around steps that spawn subprocesses with real write access, and treat any finding as evidence to investigate, not noise.

### Waiting discipline — the positive pattern

> **This section is for MULTI-TURN sessions only — coordinators and interactive drivers.** It is
> the exact opposite of what a one-shot worker needs. A judge is a fresh headless `claude -p`
> (`bp-judge.sh:8`) with no next turn: when it ends its turn awaiting a background task the process
> EXITS, the notification has nowhere to arrive, and no verdict is ever written. This paragraph was
> copied near-verbatim into `judge-harvest.md` and `judge-resolve.md` and deadlocked both judges in
> a live run — packages parked reading "its outputs don't meet the done-criteria" when no judge had
> assessed anything. If you are writing a prompt for a one-shot process, mandate FOREGROUND
> execution and give it an out for a check too slow to finish (see those templates, and t/113).

You will spend most of your turns either dispatching long-running work or running validation.
Getting the *awaiting* half wrong is how a coordinator burns an entire turn budget producing
nothing: a field package once grep-looped on a sentinel that had existed for over an hour, was
warm-relaunched four times, and its work was already green the whole time.

**The pattern: for coordinators and interactive drivers only (never a one-shot worker or judge —
see above), launch in the background, end the turn, resume on the notification.** When
you start work you cannot get an answer from within a few seconds — a long build, a long-running
script, anything you'd otherwise be tempted to sit and watch — launch it with
`run_in_background`, then **end your turn**. Do not re-invoke a tool to check on it, do not poll
its output, do not watch it grow. The completion notification comes back to you on its own, in a
later turn, and that is when you resume. You are notified when it completes — you never have to
go looking. This is a multi-turn pattern only: a headless one-shot process (a judge, a
Task-dispatched worker) has no later turn, so `gate-headless-background.sh` denies
`run_in_background` mechanically whenever `BP_LEDGER` is set.

**Foreground is the documented default for validation.** Anything that finishes in a couple of
minutes or less — your test suite, `bp-ledger.pl` calls, a lint pass — belongs in the
**foreground**, run inline, its result read once. The arithmetic is why this is the rule rather
than a style preference: a 160s foreground suite run inline costs exactly **one turn** — invoke
it, read the exit code, move on. The identical suite, awaited instead by polling, cost one
coordinator **96 turns of a 100-turn budget** on a repeated `cat .../tasks/<id>.output` against a
target that never changed. One turn versus 96 turns for the same piece of work: foreground when
the wait is short, background-plus-notification when it isn't, and a loop in between is never the
right shape for either.

**The prohibited shapes — named concretely, so you recognize them before you type them:**
- `while [ ! -s <file> ]; do sleep …; done` — a sentinel spin.
- `until grep -q <pattern> <file>; do sleep …; done` — a grep spin.
- `echo "waiting..."` inside any loop.
- any `sleep`-based spin built around a condition.
- repeated `cat` or `TaskOutput` calls against the same output or sentinel file, re-reading it to
  watch it grow.

Every one of these is mechanically DENIED by `b15`'s `wait-shape-guard.sh` hook
(`plugins/butler/hooks/wait-shape-guard.sh`) before it ever runs — you will get a `BLOCKED:`
message back. Learn the boundary from this document, not from that message mid-run: once denied,
the fix is never a cleverer loop, it's launch-and-end-turn instead.

**Check the sentinel once, never in a loop.** Every field instance of this pathology was waiting
on something **already complete** — a sentinel file that had existed for over an hour, artifacts
already sitting on disk, a suite that was already green — the whole time it polled. So: read the
result **once**. If it's there, proceed. If it isn't yet, end the turn and resume on the
completion notification; never check again in the same turn, and never in a loop.

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

## Filing a ccpraxis tooling bug

See `plugins/almanac/skills/bug-report/SKILL.md` for the full doctrine — its "Before you file"
section (is it actually ccpraxis, is it already filed via `almanac-bug.pl list`, can you fix it
yourself) — before filing. When it is a genuine, unreachable tooling defect:

```bash
perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl file \
  --title "one line, names the defect not the symptom" \
  --severity high --area butler \
  --body -   <<'REPORT'
...your report...
REPORT
```

Then record it in your ledger with the `TOOLING-BUG-FILED:` marker (see "The `TOOLING-BUG-FILED:`
marker" above) — never for your OWN package's bug, which is an ordinary implementation defect, fixed
via the normal loop, never filed.

### Prose vs. mechanism

Recognising a finding as a genuine ccpraxis tooling defect — as opposed to your own package's bug,
an ordinary scope note, or a declined nit — is a **judgement** call. No hook makes it, and none
should: a gate on an undetectable condition is worse than none.

Once that judgement is made and a report is filed, the `TOOLING-BUG-FILED:` marker's **integrity**
is **mechanical**: `id=` must resolve to a real, existing report file, and `why=` must be non-empty —
the same shape as the deviation marker documented above.

Two other candidates were considered and are explicitly **not** gated. **CONSTRAINT CONFLICT** is
never gated: the signal does not correlate with "this is a ccpraxis tooling defect" — a surfaced
spec conflict can resolve as correct, and gating it would manufacture false-positive reports.
**ORACLE EDIT** authorisation/decline is likewise never gated: it is test-immutability governance,
not evidence tooling is broken, and layering an unenforced marker onto an already-unenforced
mechanism (the write-set guard) adds prose, not detection.

## Pipeline

Workers are dispatched via Task with `subagent_type` set to the **plugin-namespaced** form `butler:bp-<name>` — i.e. `butler:bp-scout`, `butler:bp-architect`, `butler:bp-test-writer`, `butler:bp-implementer`, `butler:bp-reviewer`, `butler:bp-redteam`, `butler:bp-ui-prober`. (Confirmed working 2026-06-11 in a real installed-plugin coordinator run. A bare `bp-<name>` may also resolve, but the namespaced form is authoritative — use it directly so you never spend a turn on an "unknown agent type" retry.)

1. **Scout** (`bp-scout`, optional). Skip when the package inputs already map the terrain — record the skip and why. Otherwise dispatch with the specific questions you need answered.
2. **Spec** (`bp-architect`). Output: `$BP_DIR/specs/$BP_PACKAGE-spec.md`. Gate it yourself: every package done-criterion must map to at least one acceptance criterion in the spec; conflicts with blueprint Decisions are escalations, not silent resolutions.
3. **Tests** (`bp-test-writer`). Sees the spec, not your implementation files. Sanity-check the returned mapping (criterion → test) against the spec yourself — a cheap read that prevents an expensive convergence on wrong tests. Tests should fail for the right reason before implementation exists.
4. **Implementation loop** (`bp-implementer`). Tests are the immutable oracle (hook-enforced). After each return: validate from disk, feed back the *exact* failing output excerpts with file:line, redispatch. **Cap: 4 attempts on the same failure → `status: blocked`** with a precise escalation; thrashing burns the budget that monitoring is protecting.
5. **Validation suite green from disk.** Full project validation per project CLAUDE.md, run by you, recorded in Outputs.

   ### Validation is scoped to the package's own slice
   This extends SYN-11's per-package "green" doctrine — already defined for *test* reds — explicitly to **lint and build scope** too; it does not amend SYN-11, it applies the same reasoning one layer wider. A package must not fail step 5 because a project-wide lint pass or a project-wide build trips over a sibling package's temporarily-broken in-flight work. Judge your own slice: the files in your write set, the tests that are yours. A project-wide lint/build red attributable to another package in flight is not your red — record it, don't block on it.
   ### Before you set `status: done` — three checks, all required

   A green suite is not evidence that a package works. **Eight packages in one blueprint went green while doing nothing**, and every one was caught by these, never by a test. Do all three and record the result in `## Outputs`.

   **(a) Reachability — what populates this, and who calls it?** Grep for the caller of every new symbol and the writer of every new state key. `b41` shipped an `observe` nothing called; `b46` shipped a `--deep` gate nothing set; `b37`'s panel read a `spend` key nothing wrote — each was one grep away, and each would otherwise have shipped green. If a thing has no caller and no writer, it is inert regardless of its tests.

   **(b) Execute the code, not the suite.** Run the actual function with real inputs and read the output. This is the only check that caught all eight, because it is the only one that tests the claim the oracle *cannot* make. An oracle bound by the zero-real-I/O rule genuinely cannot assert "this appears in the running dashboard" — so you must. Paste the real output into `## Outputs`; a claim without pasted output is not a result.

   **(c) Diff each done-criterion against the oracle's assertions.** Walk the ledger's numbered criteria **one at a time** and name the assertion covering each. `b36` shipped `done` at 62/62 while its criterion 1 demanded three states and the code had two — the criterion had **no assertion at all**. Green plus non-vacuous is *not* complete: an oracle can be rigorous about everything it covers and still cover the wrong set. This is mechanical and needs judgment only once a gap appears.

   **Do not assert the whole shape of a shared artifact.** Heading counts, key sets, table sizes, "exactly N ledgers", and literal values of tunable constants all forbid every later package from extending the thing. Assert *your* package's contribution, or a floor — see `t/64`'s AC-36 for the shape of the fix. `bp-shape-lint.pl` flags candidates; run it over any oracle you author.

6. **Review ∥ red-team** (`bp-reviewer` ∥ `bp-redteam`). Read-only, safe to run in parallel.
7. **Fix-batch.** Consolidate ALL findings from both reports into **one** implementer dispatch — never a sequence of single-finding fixes. Re-validate after. Filing is consolidated the same way: when reviewer and red-team independently name the same tooling defect, file it once — one `TOOLING-BUG-FILED:` marker, never one report per source.
8. **UI pass** (`bp-ui-prober`), only if the package touches UI. Screenshots get read, the visual checklist applied, findings folded into a final fix-batch if needed.

Check off pipeline steps in the ledger as you go. Steps may be skipped only with a recorded reason.

## Worker dispatch contract

**Bracket every `Task`/`Agent` worker dispatch with `bp-dispatch-log.pl start`/
`finish`, foreground, from your own clock — never a worker's self-report** (the
same per-dispatch budget/elapsed-time mechanism `drive-solo/SKILL.md`'s "Arm the
watcher" section documents for the interactive driver; both surfaces share the same
blind spot — a dispatched worker has no elapsed-time signal independent of its own
self-report, regardless of which one dispatched it):

```bash
perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-dispatch-log.pl start \
     --id <bp>-<pkg>-<epoch-or-short-tag> --worker-type <bp-implementer|bp-test-writer|...> \
     --budget-seconds <this dispatch's own expected budget>
...
perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-dispatch-log.pl finish --id <id> --status done
```

**Interrupt-and-report is dispatch-shape-agnostic** — once `bp-dispatch-log.pl
elapsed --id <id>` shows `over_budget: true`, "interrupt" always means "send the
dispatch a message asking it to stop iterating and report," never a process kill,
whether the caller is an interactive driver or a semi-autonomous coordinator. The
canonical prompt is documented once, in `drive-solo/SKILL.md`'s "Arm the watcher"
section (step 4) — read it there rather than duplicating it here, so there is one
canonical wording and one place it can drift out of sync.

Every dispatch prompt contains, explicitly:

```
Scope: <what, precisely>
Files: <paths, file:line where known>
Do NOT: <out-of-scope list, incl. anything tempting nearby>
Acceptance: <how the worker knows it's done>
Report to: $BP_DIR/reports/$BP_PACKAGE/<worker>-<step>.md
            — CREATE THIS FILE EARLY, BEFORE THE INVESTIGATION, AND APPEND AS YOU GO.
              Your final message is NOT a deliverable; the file is.
Return: ≤15 lines — outcome, validation run + result, report path, anything off-spec.
```

Rules:

- **One write-capable worker in flight** (implementer / test-writer / ui-prober) — hook-enforced *inside a `bp-launch.sh` coordinator only* (see "…but only inside a butler-LAUNCHED coordinator" above); elsewhere it is your discipline. Read-only workers may run in parallel.
- A worker that returns garbage or dies: redispatch once with a sharpened prompt. Twice: log the attempt, then either change approach or block — don't loop.
- You may make small glue edits inside your write set yourself (wiring an export, a one-line fix during validation). Anything resembling a step belongs to a worker.

### Turn caps — two fields, one concept, and they are NOT the same field

This has already cost one whole review pass: **eleven of eleven** dispatched workers died having written nothing, ~800–900k tokens, zero output.

| field | lives in | governs |
|---|---|---|
| `max_turns:` | **ledger** frontmatter | headless `claude -p` coordinators, via `bp-launch.sh` |
| `maxTurns:` | **agent** frontmatter, `plugins/*/agents/<name>.md` | **Task subagents** — the workers you dispatch |
| `steps:` | **OpenCode twin**, `plugins/butler/opencode/<name>.md` | the same worker under `worker_backend: opencode` |

There are **three** of them, and the third is easy to miss entirely. `t/81-opencode-worker-runtime.t` keeps `steps:` derived from its Claude twin's `maxTurns:`, so changing a cap without syncing the twin turns that file red — deliberately.

The first two differ only in case and separator. Raising one does **nothing** for the other, and that is not hypothetical: `b23` raised the ledger default 80 → 150 and wrote "`bp-scout` … default 40" into the authoring protocol while `bp-scout.md` kept `maxTurns: 15` — the very number that same paragraph calls known-starving — for another two months.

- **Task exposes no per-dispatch turn override.** You cannot raise a cap from the dispatch call; the agent's own frontmatter is the only control point. So either the cap fits the scope, or the scope must fit the cap.
- **A cap is a runaway backstop, NOT a budget.** This is the whole principle, and getting it wrong is what starved eleven workers. A cap only binds when the agent would otherwise still be working: an agent that finishes in 12 turns costs 12 turns whether its cap is 40 or 800. So a low cap buys you **nothing** on the runs that behave, and costs you the **entire dispatch** on the runs that don't — an asymmetry that always argues upward. Size the cap to stop a pathological loop, not to ration a healthy worker.
- **Spend is controlled elsewhere**, and confusing the two is the trap: scope the worker narrowly, pick the cheapest model that can do the job, set `effort:` deliberately, and bound the run with the token budget. Those throttle cost continuously. A turn cap throttles nothing until it decapitates.
- **Floor: no agent definition may declare `maxTurns:` below `400`.** Enforced by `t/91-agent-worker-doctrine.t`, which reads this number from this sentence and checks every `plugins/*/agents/*.md` — so prose and mechanism cannot drift apart again.
- Caps above the floor are **sized to the role**: bounded read-and-write-one-artifact roles sit at the floor (400); multi-file roles that must *execute* things at 600; convergence loops (implementer, resolve-judge) at 800. For calibration, the ledger `max_turns:` default for a **coordinator** is 150 — a worker auditing a whole subsystem has no business being capped below the thing that dispatches it.
- **If you are tempted to lower one of these, you are reading it as a budget again.** Lower the scope instead.

### Run the checks your write set implies — even when the criteria omit one

Your `test_paths` answers *which tests run*. It does not answer **"is everything my write set can break still working?"** Those are different questions, and the gap between them is where escapes live: one 13-package initiative shipped five defects to its closing gate, each because the check that would have caught it was in **no package's** done-criteria — a production-mode build, a Firestore index declaration, a route load, a lint error latent for weeks, and a workspace unbuildable for five days while every package reported green.

- **Before declaring `done`, run the checks your write set implies** — `perl plugins/butler/scripts/bp-checks.pl derive --blueprint <blueprint.md> --write-set "$BP_WRITE_SET"` lists them. Run them **even if your ledger's criteria omit one**: the criteria are the author's best guess, and the whole failure mode is a check nobody thought to write down.
- **The table is your PROJECT's**, declared as a ```` ```checks-table ```` block in `blueprint.md`. There is no built-in list — this toolchain is stack-agnostic and its own blueprints are pure Perl. A blueprint with no table implies nothing and behaves exactly as before.
- **Record what you ran.** The harvest judge may only read your contracted slice, so a check that left no artefact inside it cannot be verified — see that agent's contract.
- **This does NOT cover the visual class, and nothing here should be read as covering it.** In the same initiative an e2e spec asserted a spinner `toBeVisible()` and passed while it rendered 185px outside a clipped dialog: `toBeVisible()` means "has a layout box", not "a human can see it". A person looking at the screenshot found it. Automated checks do not replace `bp-ui-prober`'s human-read pass — keep it.

### A dead worker is not a worker that found nothing

A worker whose turns run out returns **its last narration as its result**. That reads exactly like a finished agent reporting a clean bill of health, and it is the most dangerous failure mode in this protocol — strictly worse than a crash, because it looks like success.

Correct caps do not fix this; any worker can still die. Therefore:

- **Require the artifact early.** The dispatch prompt must tell the worker to create its report file *before* investigating and **append** as it goes. A death then leaves partial evidence instead of nothing.
- **An empty or narration-shaped result is a FAILURE, not a finding of "nothing".** Treat it as a dead dispatch and redispatch per the rules above.
- **Confirm the artifact exists on disk before accepting any worker's conclusion.** Never record "reviewed, no findings" on the strength of a returned message alone. If the file is absent or stub-sized, the work did not happen — whatever the message says.

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
