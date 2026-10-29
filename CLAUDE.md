# ccpraxis — project instructions

You are working **on ccpraxis itself**: the plugins, skills, launchers and scripts that Claude Code
runs. Read `plugins/sandbox/docs/working-on-ccpraxis.md` before changing anything about how the
sandbox launches.

## Where you are, and where you must not be

| path | what it is |
|---|---|
| this repo | your **dev clone** (normally under `~/Projects`). Develop here. Sandbox here. |
| `~/.claude/ccpraxis` | the **live install** — the plugin tree Claude Code is executing. Never develop here. |

`claude-sandbox` refuses to launch against `~/.claude/ccpraxis`, by design. Editing the live install
means editing tooling while it is in use.

GitHub's `main` is fed from the live install: `/steward:backup` merges `origin/main` into it and
pushes from there. Do not push this clone's `main`; the next backup would merge it into the live
install without promotion's global-config sync. The model and the fresh-machine procedure:
`plugins/sandbox/docs/working-on-ccpraxis.md`.

### ⚠ THE MACHINERY YOU ARE USING IS NOT THE MACHINERY YOU ARE EDITING

**A change you just made is NOT in effect in this session.** You edit the clone; Claude Code executes
the **live install**. Promotion is what closes that gap — but *what* it takes to become effective
differs per surface, and guessing has been wrong in both directions:

| surface | how it reaches a sandbox | effective when |
|---|---|---|
| ccpraxis plugin code (`plugins/**`) | **LIVE ro bind mount — of `~/.claude/ccpraxis/plugins`, i.e. THE LIVE INSTALL, _never_ of your clone** — at `/root/.claude/plugins/marketplaces/ccpraxis-local` (`ccpraxis-local` is a `directory`-source marketplace) | **on promotion alone.** No relaunch: a per-call script (`bp-*.pl`) picks it up immediately. Until you promote, the mount keeps serving the OLD code no matter what your clone says |
| skills (`skills/<name>/`) | bind-mounted **per the picker's selection**, fixed at container create | a **full manager launch** (`--session`/`--resume-session` is the *connector* path and skips the picker entirely) |
| other marketplaces (e.g. `claude-plugins-official`) | **copied** into `claude-home`, host-authoritative, re-copied every launch | next launch — and an in-container repair is clobbered by that re-copy |

**The mount is not a shortcut past promotion.** It serves the live install, so it makes *promoted*
work visible instantly — and makes *unpromoted* work invisible just as reliably. "It's all mounts, so
it's probably already here" is only true once the merge has happened.

So: **verify, do not assume.** "Relaunch everything" is as wrong as "it's already live".

**Before claiming any tooling change is usable — or planning work that depends on it — verify against
the tree that actually runs:**

```bash
# what is EXECUTING here (in a sandbox):
M=/root/.claude/plugins/marketplaces/ccpraxis-local
perl $M/butler/scripts/bp-blueprint.pl            # verbs the live copy really has
grep -m1 '^maxTurns:' $M/butler/agents/bp-scout.md
```

If it differs from your clone, the change is **not live**, and saying "the machinery now works" is
false. Say instead: *"fixed in the clone; inert until promoted."*

**Plugin skill TEXT is snapshotted at session start, not at invocation.** The "promotion alone" row
above holds for scripts a skill *runs*, never for the `SKILL.md` a session *reads*. Measured
2026-09-22: a session started at 08:54Z, `beed3b2` was promoted at 09:13Z, and the session's first
`/blueprint:create`, eleven hours later, injected the pre-promotion `SKILL.md` byte for byte
(20/20 body lines matched `2e11059`, the live HEAD at session start), with no stale copy anywhere on
disk. So a promoted skill fix needs a **new session**, even for a skill this session never invoked.
Stale skill text in an old session is this, not a file bug. A **new** `skills/<name>/` is not
mounted at all until a full manager launch.

**Promotion is one command: `perl scripts/promote.pl`**, run from this clone (`--dry-run`
previews and writes nothing). It (1) merges this clone's `main` into the live install
(`git -C ~/.claude/ccpraxis pull --no-rebase --ff --no-edit <clone> main`; the live install has
commits of its own, so this is usually a merge commit), refusing on a dirty live tree; then
(2) syncs the `global-config/` payload into `~/.claude`: `CLAUDE.md` is replaced after a backup
to `~/.claude/.promotion-backups/<ts>/`, and refused, with the offending lines shown, if it holds
a line no committed version of the payload ever had; `settings.json` is merged key by key (the
payload wins only over values it once had, and `.backup-preferences.json` is honoured);
`known_marketplaces.json` is only reported. A bare `git pull` is not a promotion: it leaves
the installed global config at whatever was last copied, which is how `~/.claude/CLAUDE.md` sat
at the Aug 26 payload for a month. `install.pl` only re-wires PATH and plugin registration; it
never copies plugin code, so a clean install run does not mean promotion happened. Full
mechanics: `plugins/sandbox/docs/working-on-ccpraxis.md`.

## Language and runtime

**Everything is Perl.** Install hooks, launchers, the statusline, sync logic. That is deliberate:
Perl ships with macOS, Linux and Git for Windows, so a fresh `git clone` runs everything with no
Node/Python/toolchain installs on the host. Do not introduce another runtime without a decision.

**Never run dev tooling on the host** — no `npm install`, `pip`, `cargo`, build tools. If something
needs a toolchain, it belongs in the sandbox container.

## Tests

Layout: `plugins/<plugin>/tests/t/name.t` (lowercase kebab-case, at least two hyphen-separated
words, no numeric prefix — enforced by `plugins/butler/tests/t/test-naming-hygiene.t`), plain
`Test::More`, no harness config.

**`prove` does not exist on the Git-for-Windows host** — that perl ships no `TAP::Harness`
(`Can't locate TAP/Harness/Env.pm`). Run one file directly and judge by exit code plus `not ok`
count:

```bash
perl plugins/sandbox/tests/t/refuse-in-place.t
```

**For a sweep, use the runner — never a serial `for` loop.** A full sweep is ~70 minutes of CPU
across 330 files; run one at a time that is exactly what it costs, and a suite nobody wants to run
is a suite that stops getting run.

```bash
perl scripts/run-tests.pl --fast            # 317 of 330 files (13 container tests excluded)
perl scripts/run-tests.pl                   # everything
perl scripts/run-tests.pl plugins/sandbox   # one plugin
perl scripts/run-tests.pl --state=failed    # only what failed last sweep
perl scripts/run-tests.pl --nice            # low-impact: caps workers at max(2, cores/4)
perl scripts/run-tests.pl --ledger <ledger> <one .t>  # scoped: runs while another worker is live
```

**The last measured full `--fast` run was 1047s over 308 files.** That figure is a MEASUREMENT,
not a prediction, and the file count has moved since — re-measure rather than quoting it. Counts
here drift every time a test is added, so prefer deriving them:
`ls plugins/*/tests/t/*.t | wc -l` and
`grep -lE 'TestSandbox|podman_run_capture|podman_bin|probe_image' plugins/*/tests/t/*.t | wc -l`.

The work here is dominated by PROCESS CREATION, not CPU — a bare statusline spawn costs ~292ms on
this host — so parallelism buys more than the core count suggests.

**The runner keeps the container tests SERIAL, deliberately** (13 at time of writing — derive it,
do not trust the number). They start real podman containers
against one podman machine, so running them concurrently makes them contend: slower in wall-clock
AND flakier. That is the documented failure signature of this suite (`EXIT=124`/`255` with zero
`not ok` lines — the process died, no assertion failed). They are classified by what they import,
not by a tag, so a new one is handled without anybody remembering to mark it.

Judging a "slowest files" list from a contended run is a trap worth naming: under six-way load
`64-theme-tokens.t` reported 269s and `166-statusline-marker-glyph.t` 134s; run on their own they
are 12s and ~10s. Contention inflates per-file timings, so measure a slow file **alone** before
concluding anything about it.

**Record a baseline before you change anything.** Both suites carry pre-existing red from
in-flight work on other tracks; judge your change by red files *attributable to it*, never by an
absolute count.

**Never let a test spawn `launcher.pl` unguarded.** It will build an image and start a container
inside your test run. Interlock any such test on the behaviour already being wired (grep the
launcher source first) and bound it with `timeout`. This has fired repeatedly.

## Windows landmines

These have each cost real debugging time. Details in the user-global `CLAUDE.md`.

- **Never `> NUL` from bash** — it creates a literal file named `NUL` that Explorer cannot delete.
  Use `/dev/null`. From PowerShell use `$null`.
- **Never reopen STDOUT/STDERR onto an in-memory scalar** — Git-for-Windows perl fails with
  "Bad file descriptor", surfacing as a bare `Died at … line N`. Capture via `File::Temp`.
- **MSYS2 mangles `:`-separated args** passed to native Windows binaries (`podman -v HOST:CONTAINER`
  becomes `HOST;CONTAINER`). Symptom: stray directories ending in `;C`.
  Two fixes, and they are **not** alternatives to pick freely:
  - **Hand-translate** to forward-slash Windows paths (`/c/x` → `C:/x`), which `podman.exe` and
    `git.exe` both accept directly. Correct under *either* conversion state — prefer it. See
    `winify_path` (launcher) and `git_path` (`vault-sync.pl`).
  - **Set `$ENV{MSYS2_ARG_CONV_EXCL} = '*'`** on Windows — but only *together with* the translation
    above. Disabling conversion while still passing bare `/c/...` is its own bug with the opposite
    symptom: Windows resolves the leading `/` against the current drive, so the path is silently
    created at the **drive root** as `C:\c\...`. That cost 576 stray entries on 2026-06-12; see
    `plugins/steward/tests/t/no-drive-root-strays.t`. Never set the variable shell-wide.
- **A pid is only meaningful in the namespace that produced it.** Git-for-Windows perl runs under
  MSYS2, which keeps its **own** pid numbering. `ps -W` prints both columns, and they are different
  numbers for one process:

  ```
     PID    PPID    WINPID   COMMAND
  832282       1    159020   /usr/bin/perl        <- one process, two ids
  ```

  perl's `$$`, `getppid()`, `kill()` and every `.pid` file a perl script writes are **MSYS** pids.
  `Get-CimInstance Win32_Process`, `Get-Process`, `Stop-Process` and `taskkill` take **WINPIDs**.
  **Crossing them does not error — it answers "no such process"**, which reads as a finding rather
  than a bug. Measured 2026-09-17: `Get-Process -Id 832282` reported gone while that process was the
  live launcher, and a whole false theory about orphaned samplers was published on the strength of
  it before `ps -W` settled it. The same mismatch had been live in `scripts/reap-orphans.pl`, which
  collected WINPIDs from CIM and verified its kills with `kill(0, …)`, so **every kill reported
  success** and its `failed` list could never be populated (`13f7c12`, report
  `20260917-033101-c455`). Pick one namespace per code path and stay in it; verify by re-querying
  the source the pid came from, never by asking the other side.

- **`getppid()` is 1 for a detached spawn here**, immediately and while everything is alive — not
  only after a parent dies. It is not a usable owner-liveness signal for anything the launcher
  spawns. Measured, same day, while proposing a fix that depended on it.

- **`-t STDOUT` does not notice a destroyed console.** Measured: eight seconds after the console host
  was killed, a live perl process still reported `-t STDOUT` true and its writes still returned
  success — the bytes are accepted and discarded. `-t` asks whether the handle looks like a
  character device, never whether anything is on the other end. A launcher polling it renders
  happily into nothing (report `20260917-032358-bc45`).

- **Paths contain non-ASCII** (`André`). Nothing may assume ASCII paths. Round-trip registry values
  as UTF-8 bytes; never re-encode something already decoded.
- **`podman machine set --disk-size` fails on WSL machines** (exit 125). Grow via WSL instead:
  `wsl --shutdown`, then `wsl --manage podman-machine-default --resize <bytes>` (grow only; it runs
  `e2fsck`/`resize2fs` itself). Verify with `df -h /` inside the machine — `podman machine list`
  keeps reporting the creation-time size and is not the truth.
- **The WSL VM's memory cap is a real failure mode.** `~/.wslconfig`'s `memory=` is what `vmmem`
  will consume; when the host runs low on commit, Windows terminates the VM and every container in
  it dies at once, with no reap record. A missing `.launcher/last-reap.txt` is the signature of a
  hard kill rather than a graceful reap.

## `.ccpraxis-local-data/` — gitignored, and it does not travel

Holds blueprints, `claude-home` (transcripts, credentials), launcher state, and the
`guidance/` notes indexed below. Git never carries it, nor `deploy_key*`. Most of `.claude/` is
ignored too — but **not** `.claude/settings.json`; see the next section.

On relocation, **`git status --ignored` is the authoritative copy-list** — `.gitignore` lists
patterns, not what exists. Full gotchas, including the `claude-home/.launcher/` container-identity
trap: `plugins/sandbox/docs/working-on-ccpraxis.md`.

## Guidance notes — read on demand

Claude Code's built-in auto-memory is **disabled** (`autoMemoryEnabled: false` in every settings
layer, plus a `permissions.deny` on the memory path). A durable fact is an almanac note
(`plugins/almanac/scripts/almanac-note.pl create`), never a memory; existing memory files are
migrated by `plugins/almanac/scripts/almanac-migrate-memories.pl`. The guidance files below predate
notes and are read only when the trigger applies:

| note | read it when |
|---|---|
| `.ccpraxis-local-data/guidance/push-straight-to-main.md` | pushing, or about to flag a "Bypassed rule violations" warning |
| `.ccpraxis-local-data/guidance/only-the-operator-ends-a-run.md` | about to run `bp-runstate.pl finish`, `butler-continuity off`, or anything else that makes a Stop gate inert. **A run ends when the operator says so in their own message — nothing else.** Background tasks dying, even all at once, is not a stop instruction; it is work to resume |
| `.ccpraxis-local-data/guidance/escalate-product-decisions-only.md` | about to ask the operator anything mid-run |
| `.ccpraxis-local-data/guidance/fix-ccpraxis-defects-in-place.md` | a real defect surfaces outside the current package's write set |
| `docs/design-conventions.md` (tracked) | making a design call — packaging, approval flows, what to enforce in code — or hitting a Windows/Perl oddity that smells environmental |
| `.ccpraxis-local-data/references/tropes.md` | writing prose a human will read — README, docs, skill copy, commit bodies, replies to the operator. Re-check the output against it before sending, not only before writing |

Nothing that a hook already enforces belongs here — the hook is the instruction.

**These paths are gitignored, so a fresh clone starts without them.** That is deliberate — they are
notes, not code — but it means the rows above dangle until restored. `tropes.md` is the one with a
canonical source, so it can simply be re-fetched:

```bash
mkdir -p .ccpraxis-local-data/references
curl -sSL -o .ccpraxis-local-data/references/tropes.md \
  https://gist.githubusercontent.com/ossa-ma/dae6f9571534f3fbd1266a384be00e11/raw
```

(The site is <https://tropes.fyi>. Its `/tropes-md` link renders a single-page app, so fetching that
URL yields the HTML shell rather than the file — use the gist.)

A note on using it: it is a checklist for **generated prose**, not a style ban. Verbatim quotes stay
byte-exact even when they contain something on the list, and a real proper noun is not title case.
The 2026-09-01 README pass left three flagged lines untouched for exactly those reasons.

## `.claude/settings.json` is TRACKED — and that is load-bearing

Claude Code's own model, which this repo now follows rather than fights:

| file | git | holds |
|---|---|---|
| `.claude/settings.json` | **tracked** | shared project config: the `hooks` registration, the declared plugin set |
| `.claude/settings.local.json` | ignored | personal, per-machine: the sandbox picker's per-launch selection |

Precedence is **Local over Project**, so a local entry overrides the shared one — exactly what Claude
Code writes when you disable a project plugin for yourself alone.

**Why it matters.** `plugins/butler/hooks/guard-git-mutations.sh` is registered *only* from
`.claude/settings.json`. That guard exists because a prohibited `git stash` destroyed a completed
fix-batch (`ef272c3`) — its thesis is that a written instruction is not an enforcement mechanism. If
the file is untracked, a fresh clone gets the guard script and never runs it, and the registration
survives only as prose in a commit message: the same mistake, one level up.
Two tests fail if the registration goes missing:
`plugins/sandbox/tests/t/settings-scope-split.t` and
`plugins/butler/tests/t/h01-settings-registration.t`.

**Path-qualify test citations** — `t/NN` collides across plugins, and a bare number has already
produced a confident "no such file exists" about a file that was there.

**Do not re-ignore it.** It was ignored until 2026-08-06 because `skills.pl` Phase B wrote the
picker's machine-local plugin selection into it on every launch. That write now targets
`settings.local.json`; the churn is gone, so the reason is gone. If you find yourself wanting to
ignore it again, the bug is whatever started writing machine state there — fix that instead.

MCP lists (`enabledMcpjsonServers` / `disabledMcpjsonServers`) deliberately still go to
`settings.json`: `discover_mcp` already treats presence there as "project" and presence only in
`settings.local.json` as a promotable "suggestion". Redirecting them would collapse every MCP row to
a permanent suggestion.

## Commits

- Atomic: one commit per coherent deliverable.
- **Never add `Co-Authored-By`** or any co-author trailer.
- Explain *why*, not just what — this repo's history is the main record of its design decisions.
- If a change cannot be made atomic (intermixed in-flight work), say so in the commit message
  rather than pretending otherwise.

## Multi-session work

Substantial initiatives are **blueprints**: `/blueprint:create` authors one under
`.ccpraxis-local-data/blueprints/<name>/`; `/butler:drive-solo <name>` executes it. Blueprints carry
per-package ledgers with write sets and done criteria. If work spans more than one session, prefer a
blueprint over ad-hoc edits.

## Do not confuse these two

- `global-config/CLAUDE.md` — a **payload** of this repo, installed to the user's
  `~/.claude/CLAUDE.md` by `scripts/promote.pl`. Editing it changes what every project sees on
  this machine once promoted.
- **This file** — instructions for working on ccpraxis itself.
