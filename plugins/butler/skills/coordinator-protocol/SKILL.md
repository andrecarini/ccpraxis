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

#### Write-guard reach

- In a coordinator (`BP_LEDGER` set), write-set containment, role separation and the
  one-write-capable-worker lock all apply, hook-enforced, exactly as this protocol describes.
- In an armed drive-solo session the write-set and ledger guards apply to the driver and its
  subagents (the one-writer lock does not; see `drive-solo/SKILL.md`): a subagent may write only
  its bound package's write set (test paths only as the test-writer), its own ledger, and its
  own blueprint dir except a sibling package's ledger, and temp; with two or more packages in
  flight, an unbound subagent's edits are refused.
- In any other session (a manually-dispatched subagent, an ordinary interactive session), no
  butler write guard applies, except `guard-git-mutations.sh` and `guard-blueprint-write.sh`,
  which apply everywhere. `guard-git-mutations.sh` exists because an unguarded manual drive is
  not hypothetical: a prohibited `git stash` swept away a completed, uncommitted fix-batch that
  the ledger had already recorded as done.

**What this means for you:** never infer "a hook would have caught it" from the list above. If you
are outside a guarded session, `git status` after every write-capable worker is the only
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

The eight operations:

```
bp-ledger.pl set-status       --ledger P --status S
bp-ledger.pl tick-step        --ledger P --step N
bp-ledger.pl append-attempt   --ledger P (--text T | --text-file F | --text -)
bp-ledger.pl set-next-action  --ledger P --body B
bp-ledger.pl add-output       --ledger P --text T
bp-ledger.pl set-escalation   --ledger P (--text T | --text-file F | --text -)
bp-ledger.pl rotate           --ledger P [--keep N] [--budget BYTES] [--dry-run]
bp-ledger.pl validate         (--ledger P | --stdin | --payload)
```

`set-status` refreshes `last_updated:` for you — do not stamp it yourself, and do not stamp it in the same breath as a hook that also stamps (that double-stamping hazard is real).

Exit codes are meaningful and you should branch on them: **0** ok · **2** the write was *rejected* (it would have corrupted the ledger — read the message, do not retry blindly) · **3** argument fault · **4** I/O · **5** the target section or step was not found.

Why each op exists rather than an `Edit`:

- **`append-attempt`** inserts at the end of `## Decisions & attempt log`, always as exactly one line, always outside any fenced code block. The one-line rule is not cosmetic — it is what makes two forgeries structurally impossible: the entry starts `- <ISO>` so it can never open a fence (which would break the fence-scoped `MEANS-DEVIATION:` guard below), and its `-` is followed by a digit so it can never forge a `- [x]` checkbox.
- **`tick-step`** only ever ticks inside `## Pipeline`, so no op can emit a `- [x]` anywhere else. `tick-step --step 5` additionally takes `--reaccept-oracle <path> --reaccept-reason '<why>'` (repeatable `--reaccept-oracle`) to record an intended change to a test file's oracle since step 3. Tick step 5 now prints a notice naming any unaccepted change. A SHRINK — fewer assertions, or any test description that vanished (a renamed description counts as vanished) — is never cleared by a reaccept and gates the package at harvest, so keep existing descriptions stable.
- **`set-next-action`** replaces the `## Next action` body wholesale — the one section that is meant to be rewritten.
- **`add-output`** appends to `## Outputs`, replacing a `_(none yet)_` placeholder if that is all that is there.
- **`set-escalation`** replaces the `## Escalation` body: what decision or re-scope a `blocked` or `parked` package needs. The orchestrator, the escalation resolver and the reporter read it.
- **`rotate`** moves stale `## Decisions & attempt log` entries out to `reports/ledger-history/<pkg>.md` (a path derived from your ledger's own `.../packages/<pkg>.md` shape — never guess a different location: `bp-resume-sweep.sh` and `bp-status.sh` glob `packages/*.md`, so history must never land there or it gets enumerated as a bogus package). See "Context budget" below for when and why to run it.

**What no op may touch, and neither may you:** `## Dispatch log (auto)` is hook-maintained and never agent-edited. `mandated_means:` has no op and none may be added — rewriting the requirement to match what you built is the one move that defeats the whole mechanism.

A direct `Edit` or `Write` of a ledger is refused outright by the write guard, so there is no prose section left to hand-edit. `## Scope`, `## Done criteria`, `## Inputs` and `## Out of scope` change only through `bp-ledger.pl set-section` (a rescope, Decision 84); your own narrative goes in `append-attempt` entries.

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
reading" transfers almost verbatim): the registry-path `$PWD` guess — file:line, verified from
disk, evidence stated plainly, exactly the bar this filing needs.

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
  `## Scope`, `## Done criteria`, `## Inputs`, `## Out of scope`, `## Pipeline`, `## Next action`,
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
Task-dispatched worker) has no later turn, so `guard-bash.sh` denies `run_in_background`
mechanically whenever `BP_LEDGER` is set, except the continuity holder (see "Waiting on a
background subagent").

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

### Every wait names its subject and its liveness proof

A butler-launched coordinator has no completion-notification resumption available for an ordinary
background Bash job (`guard-bash.sh` denies `run_in_background` whenever `BP_LEDGER` is set,
except the continuity holder, as this same file states above), so the "Check the sentinel once"
paragraph's notification branch does not apply to a background Bash job. Only a background
subagent, held by the continuity holder, resumes a coordinator. Name a subject and a liveness
proof instead.

Three coordinators in about twenty minutes each blocked or parked on work that had already died or
finished (`20260917-003158-949e`), and each queued a human decision that did not need one.

**A wait is legal only if you can name two things: the SUBJECT and the LIVENESS PROOF.** The
subject is the exact process, file or ledger you are waiting on. The liveness proof is a check that
asks a live process, not one that reads bookkeeping. **A pid you recorded, a sentinel path and a
report filename are bookkeeping; none of them is evidence that anything is still running.**

**If you cannot name a liveness proof, the wait is not legal.** Do one of these instead, in order:
(1) run the work in the FOREGROUND and read its result in this turn; (2) re-dispatch the subject so
the wait has a live subject again; (3) write a concrete `## Next action` and stop. **Never park, and
never queue a human decision, on a wait whose subject you never checked.**

The `liveness proof` cell below draws only from this closed vocabulary:

| token | means |
|---|---|
| `Task return` | the Task tool returned; the dispatch is over by construction |
| `completion notification` | the completion notification of a `run_in_background` Bash job (interactive drivers) or of a held background subagent (coordinators and drivers) |
| `foreground exit code` | you ran it inline and read `$?` in the same turn |
| `pid_alive` | `BpResumption::pid_alive`, called directly |
| `NONE` | no liveness proof exists for this shape — legal **only** on a `BANNED` row |

The wait-shape table's columns are fixed:

```
| wait shape | subject | liveness proof | ruling |
```

The sanctioned and banned shapes:

| wait shape | subject | liveness proof | ruling |
|---|---|---|---|
| Task worker dispatch, synchronous | the dispatched subagent | `Task return` | SANCTIONED |
| backgrounded Bash job resumed on notification (interactive drivers only) | the backgrounded job | `completion notification` | SANCTIONED |
| a background subagent dispatch held by the holder (coordinators and drivers) | the dispatched subagent | `completion notification` | SANCTIONED |
| foreground validation run | the command you ran | `foreground exit code` | SANCTIONED |
| a recorded pid, checked live | the process that pid names | `pid_alive` | SANCTIONED |
| naked existence read as completion — test -f on a dispatch report | the worker you dispatched | `NONE` | BANNED |
| naked sentinel wait — an absent sentinel read as "still running" | the process that must write the sentinel | `NONE` | BANNED |
| naked pid-file read — a recorded pid read as a live process | the process that pid named | `NONE` | BANNED |

The three `BANNED` rows come from real cases: the report-stub row is `06-l1-reaudit`, the sentinel
row is `03-scorer-rich`, and the pid-file row is `02-rich-extraction`.

#### Waiting on a background subagent

<!-- continuity:begin -->
You are armed by construction. You stop only on a terminal, fresh ledger with a concrete
`## Next action` when blocked or parked, or while a hold covers a running background subagent.
To wait: dispatch the worker in the background, run `butler-hold <agent id>` with
`run_in_background: true` only when `butler-continuity status` shows `holder: none` (otherwise
run it in the foreground, which extends the holder), and end the turn; its completion wakes you.
A hold on anything that is not a running background subagent counts for nothing.
`butler-continuity off` and `silence` refuse in a coordinator.
A denied stop prints a stop token for the holder line above; use it as printed.
<!-- continuity:end -->

#### Existence is not completion

The worker dispatch contract itself mandates the report file be **created before the investigation
and appended to as it goes** (`SKILL.md`, "CREATE THIS FILE EARLY, BEFORE THE INVESTIGATION, AND
APPEND AS YOU GO"). So at dispatch start **every** report file already exists. `test -f <report>`
therefore proves only that the dispatch *started*.

A wait on a dispatch report ends only when the worker has returned and the report has advanced
past its stub — never on bare existence. This extends, and does not replace, the existing
"Confirm the artifact exists on disk before accepting any worker's conclusion … If the file is
absent or stub-sized, the work did not happen" rule (`SKILL.md`, the worker dispatch contract's
rules): that one governs *accepting a conclusion*; this one governs *ending a wait*.

**A sentinel is the same rule with the polarity flipped:** a *missing* sentinel is not evidence that
work is still running. Pair every sentinel wait with the writer's pid.

#### Fail OPEN means the wait CONTINUES

**A wait is not a gate, and it is bounded by the holder's 50 minutes**, so continuing one cannot
wedge anything: the worst case is that the hold runs out and you make a recorded decision then.
The `pid_alive` row is a single check, not a loop: one call, then decide. The two errors are
therefore not symmetric:

- Treating an **unverifiable** subject as **dead** ends the wait and triggers a re-dispatch of work
  that may still be running — two write-capable workers in one write set, and a live worker
  abandoned moments before it would have written its report.
- Treating it as **alive** costs at most the remainder of one hold.

So: **an undeterminable subject is ALIVE, and the wait continues.** Unknown is never dead.

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

Once that judgement is made and a report is filed, the `TOOLING-BUG-FILED:` marker's **integrity** is
**defined and mechanically checkable**: `id=` must resolve to a real, existing report file whose own
frontmatter `id:` matches, and `why=` must be non-empty — the same shape as the deviation marker
documented in "Mandated means & deviations" above. **Say exactly what that buys you today, not
more:** this grammar is proven by an exercised test (`t/tooling-bug-filing.t`), and any reader can
apply it by hand — but, unlike that deviation marker, it is **not yet wired into any live hook or into
the remediation engine** that acts on it automatically. A forged or missing `id=` today produces no
automatic finding and blocks nothing — nobody acts on it until a human, or a future package, wires
this check into a `PreToolUse` hook or the conformance judge (named explicit follow-up, out of this
package's write set). Until then, a defined, tested, checkable-by-hand grammar is still worth more
than free prose with no shared marker — just not the same thing as that other marker's automatic
enforcement.

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
self-report, regardless of which one dispatched it). **This manual bracket is what
gives you `--budget-seconds`/`elapsed`/the over-budget-interrupt-loop signal below —
`track-dispatch.sh`'s automatic hook tracking (see "Checking what is outstanding"
further down) does NOT provide that; it gives you `outstanding` instead, a
different, weaker check.** If you bracket a dispatch manually here, do not also
assume the hook leaves it alone: `track-dispatch.sh`'s `PostToolUse` half tries to
resolve a matching `running` record automatically the moment the `Task` call
returns, which fires **before** your own next turn's `finish` call ever runs — so
by the time you call `finish`, the hook has typically already closed the record to
`done`. `finish` does not check that a record is still `running` before closing
it, so it re-closes the already-`done` record anyway: `ended_at`/`duration_seconds`
get overwritten with a second, near-identical measurement, and a second
`history.jsonl` line gets appended for the same dispatch. This is not a correctness
problem for the record's final `done` state, but it IS a duplicate history entry —
know that this double-bracketing is what produces it, rather than treating it as a
bug in either mechanism.

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
canonical prompt is documented once, in `drive-solo/SKILL.md`'s "Wedged workers"
section — read it there rather than duplicating it here, so there is one
canonical wording and one place it can drift out of sync.

Every dispatch prompt contains, explicitly:

```
Scope: <what, precisely>
Ledger: .ccpraxis-local-data/blueprints/<blueprint>/packages/<package>.md
Files: <paths, file:line where known>
Do NOT: <out-of-scope list, incl. anything tempting nearby>
Acceptance: <how the worker knows it's done>
Report to: $BP_DIR/reports/$BP_PACKAGE/<worker>-<step>.md
            — CREATE THIS FILE EARLY, BEFORE THE INVESTIGATION, AND APPEND AS YOU GO.
              Your final message is NOT a deliverable; the file is.
Return: ≤15 lines — outcome, validation run + result, report path, anything off-spec.
```

drive-solo needs the `Ledger:` line to bind the dispatch; in a fleet coordinator it is
informational.

Rules:

- **One write-capable worker in flight** (implementer / test-writer / ui-prober) — hook-enforced *inside a `bp-launch.sh` coordinator only* (see "Write-guard reach" above); elsewhere it is your discipline. Read-only workers may run in parallel.
- A worker that returns garbage or dies: redispatch once with a sharpened prompt. Twice: log the attempt, then either change approach or block — don't loop.
- You may make small glue edits inside your write set yourself (wiring an export, a one-line fix during validation). Anything resembling a step belongs to a worker.
- **Never dispatch with `subagent_type: fork`; launch a fresh subagent with a self-contained
  prompt instead.**

### Turn caps — two fields, one concept, and they are NOT the same field

This has already cost one whole review pass: **eleven of eleven** dispatched workers died having written nothing, ~800–900k tokens, zero output.

| field | lives in | governs |
|---|---|---|
| `max_turns:` | **ledger** frontmatter | headless `claude -p` coordinators, via `bp-launch.sh` |
| `maxTurns:` | **agent** frontmatter, `plugins/*/agents/<name>.md` | **Task subagents** — the workers you dispatch |

The two differ only in case and separator. Raising one does **nothing** for the other, and that is not hypothetical: `b23` raised the ledger default 80 → 150 and wrote "`bp-scout` … default 40" into the authoring protocol while `bp-scout.md` kept `maxTurns: 15` — the very number that same paragraph calls known-starving — for another two months.

- **Task exposes no per-dispatch turn override.** You cannot raise a cap from the dispatch call; the agent's own frontmatter is the only control point. So either the cap fits the scope, or the scope must fit the cap.
- **A cap is a runaway backstop, NOT a budget.** This is the whole principle, and getting it wrong is what starved eleven workers. A cap only binds when the agent would otherwise still be working: an agent that finishes in 12 turns costs 12 turns whether its cap is 40 or 800. So a low cap buys you **nothing** on the runs that behave, and costs you the **entire dispatch** on the runs that don't — an asymmetry that always argues upward. Size the cap to stop a pathological loop, not to ration a healthy worker.
- **Spend is controlled elsewhere**, and confusing the two is the trap: scope the worker narrowly, pick the cheapest model that can do the job, set `effort:` deliberately, and bound the run with the token budget. Those throttle cost continuously. A turn cap throttles nothing until it decapitates.
- **Floor: no agent definition may declare `maxTurns:` below `400`.** Enforced by `t/agent-worker-doctrine.t`, which reads this number from this sentence and checks every `plugins/*/agents/*.md` — so prose and mechanism cannot drift apart again.
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

### Checking what is outstanding, without asserting the answer

`track-dispatch.sh`'s `PostToolUse` half resolves a worker's dispatch record automatically the
moment its `Task` call returns — for a `Task` dispatch tracked only through the hook (i.e. not also
manually bracketed per the "Worker dispatch contract" section above), you do not need to call
`finish`/`resolve` yourself. The START half's `dispatch_key` correlation is what lets the completion
half find the right record; see `track-dispatch.sh`'s own header comment (in this repo, not the
blueprint's gitignored spec, which does not travel to a fresh clone) if you need the mechanism. What
you get for free is a check, not a guarantee:

```bash
perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-dispatch-log.pl outstanding \
     --root "$BP_PROJECT_ROOT" --blueprint "$BP_BLUEPRINT" --package "$BP_PACKAGE"
```

**Always scope with `--blueprint`/`--package` like this when the answer feeds an automated
decision** (a stop, a gate, anything beyond an operator-facing report) — both env vars are already
exported into your process. The unfiltered, whole-store form (omitting both flags) reports every
outstanding record across every blueprint and package ever run against this store, including
pre-existing keyless records this mechanism can never resolve; an unscoped automated stop condition
built on it is permanently true. The unfiltered form stays useful for an operator-facing audit — just
never as the input to an automatic decision.

Read `outstanding_count:` from its stdout. If the line is absent or reads `unknown`, the answer is
**unknown** — never treat that as zero. Every `summary:` line this verb can print is hedged
deliberately: a dispatch **appears** to be outstanding, or none was detected — it is never asserted
as settled, because the check only reflects what is recorded on disk, not whether a process is
actually still alive. A crashed dispatch whose `PostToolUse` never fired stays outstanding forever;
`outstanding` has no timeout that clears it. Use this to catch a false "nothing left to do" before
you park or checkpoint — not to prove a negative on its own.

**What this signal cannot claim (L1):** two dispatches identical in `subagent_type`, package and
`dispatch_key` within 120 seconds of each other collapse to ONE record (the start half's own
pre-existing dedup window, which cannot tell a double-stamped single dispatch from two genuinely
concurrent same-key ones). `outstanding` can therefore read zero while a second, genuinely-running
dispatch of that exact shape still exists — narrow, but real. See the "Worker dispatch contract"
section above for the manual-bracket alternative this signal does not replace.

## Resumption

If the ledger shows prior progress when you start: this is a resumption. Verify every artifact in `## Outputs` exists on disk, re-run the last recorded validation, then execute `## Next action`. Never redo verified work; never trust unverified claims — including your predecessor's.

## Terminal ritual

Before stopping: re-run validation from disk one final time, complete `## Outputs` (every artifact + validation evidence), set status (`done`, or `blocked`/`parked` with `## Escalation` filled via `set-escalation` and `## Next action` via `set-next-action`), refresh `last_updated`, then stop. For `blocked`: state what is blocked, what was tried, and the single decision or re-scope needed — the orchestrator reads only that section and acts on it.

## Graceful stop (orchestrator-initiated)

The deterministic orchestrator can stop the fleet mid-package without killing you (in-flight workers can't be cancelled, so it propagates through a **`PreToolUse` graceful-stop gate** instead). When a stop is in force, your **next tool call after the in-flight worker returns is DENIED** — that one drain (≈ a single tool-call) is by design; let it finish, then comply. New work is denied (`Task` dispatch, edits into your write set); the **ledger park-write is always allowed** (writes under the blueprint dir / `/tmp`), as are `Bash` and read tools — so your only forward path is to record where you are and stop. The deny message tells you which of three stops is active; the ritual differs:

- **Graceful-shutdown-all** (`runs/.shutdown`) — the whole run is winding down and **stays down** (no auto-resume). Record the drained result, set a concrete `## Next action`, set frontmatter **`status: parked`**, refresh `last_updated`, then stop. This is a normal terminal park.
- **Usage / telemetry pause** (`runs/.paused`) — the orchestrator paused the fleet to protect the user's usage reserve (or to weather a telemetry gap) and **WILL auto-resume you**. Record the drained result and a concrete `## Next action`, but **LEAVE `status:` non-terminal** (`running`/`converging` — do **NOT** set `parked` or `done`, or the orchestrator won't relaunch you), refresh `last_updated`, then stop. You are relaunched **warm** after the window resets; treat the relaunch as a normal resumption (verify Outputs on disk, re-run the last validation, execute `## Next action`).
- **Per-package force-stop** (`runs/<pkg>.force-stop`) — this package is being stopped individually. Record a concrete `## Next action`, then stop.

In all three, `## Next action` must be concrete enough for a fresh coordinator (or your warm-resumed self) to pick up — the Stop gate enforces it. **Don't fight the gate**: keep trying denied work and you just burn the budget the pause exists to protect.

## Context-growth checkpoint

This is now a **two-tier, mostly mechanical** ritual (coordinator-context-discipline/02), not
something you compute by hand. The canonical numbers live in exactly one place in code —
`bp-orchestrator.pl`'s `%CTX_CEILING_DEFAULT` — and this section is a restatement of it, not a
second source of truth: **soft = 250,000 tokens**, **hard = 350,000 tokens**. An operator overrides
either independently via `BP_CONTEXT_CEILING_SOFT_TOKENS` / `BP_CONTEXT_CEILING_HARD_TOKENS` (the
old single-ceiling variable this superseded no longer exists — superseded, not aliased).

You no longer measure your own context by hand — the old line-count-plus-tail recipe is gone. Two
hooks do the measurement for you, from the same bounded tail-read of `runs/<pkg>.jsonl` the
orchestrator itself uses:

- **`context-ceiling.sh`** (`PostToolUse` on `Task`/`Bash`) — at or above the **soft**
  ceiling, this attaches a short **guidance** reminder to a tool result you were already going to
  receive. It is purely informational and blocks nothing: no new tool call is made on your behalf,
  and the reminder rides on an existing turn rather than manufacturing one. It re-injects at most
  once every 15 minutes while you stay at/above soft (so a single mention doesn't read as
  "resolved"), and resets the moment you drop back below soft. The reminder's own dispatch-status
  line quotes `bp-dispatch-log.pl outstanding` (scoped to your blueprint and package) verbatim — it
  is not your own guess about what's still running.
- **`context-ceiling.sh`** (`PreToolUse` on `Task`/`Bash`) — at or above the **hard** ceiling,
  this is the mandatory **flush**: it denies `Task` dispatch outright and denies any `Bash` command
  that isn't exactly flush work. The allow-list is `bp-ledger.pl set-status|set-next-action|
  tick-step|append-attempt|add-output|set-escalation|validate` and `bp-dispatch-log.pl outstanding` — `Read`,
  `Edit`, `Grep` and `Write` are never gated by this hook at all, so you can still re-read your ledger freely, and `set-escalation` writes the
  `## Escalation` prose. The flush is capped at **5 turns**: use them
  to run the scoped `bp-dispatch-log.pl outstanding` check, write a concrete `## Next action` with
  `bp-ledger.pl set-next-action`, leave `status:` non-terminal, and stop — exactly the same stop
  shape as the usage/telemetry pause above (`## Graceful stop (orchestrator-initiated)`, "Usage /
  telemetry pause" bullet). If you cannot finish within 5 turns, the overrun is recorded to disk and
  becomes visible to the orchestrator; at that point set `status: blocked` with a filled
  `## Escalation` naming what is preventing completion, then stop — the established stuck-coordinator
  path, not a new one.

You write no signal file at either tier: a soft-tier checkpoint exits cleanly (structurally identical
to an ordinary turn-end), exactly as the old ritual did. The orchestrator independently re-derives
the **soft** check from your own transcript at relaunch time — if your last coordinator-owned usage
record was at or above the soft ceiling, it forces a **COLD** relaunch regardless of how fresh the
cache looks, exactly like its existing `max_turns` override (`bp-orchestrator.pl`, the
`watchdog_relaunch` site). Checking soft (not just hard) here is deliberate: soft subsumes hard (any
usage at/above hard is also at/above soft), so a flushed coordinator relaunching cold holds by
construction — without that, a same-session, seconds-old checkpoint could resume WARM, `--resume`d
back into the exact context you just tried to discard.

**If a worker turn itself grows context past a ceiling before returning**: the guidance/flush check
happens only after that worker returns, on its next `Task`/`Bash` call — you cannot interrupt an
in-flight worker (matching the usage-pause ritual's own "in-flight workers can't be cancelled"
stance). You may therefore be noticeably above a ceiling for one tool call before either hook fires;
that's expected, not a defect (the figure the guidance hook reports may lag your true current context
by up to one turn for the same reason).

**If this trigger and the usage/telemetry pause condition are both true at the same boundary**: no
ordering is prescribed — either one produces the identical stop mechanics, so firing "both" collapses
to firing the ritual once. Don't try to satisfy two separate stop procedures.
