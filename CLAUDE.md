# ccpraxis — project instructions

You are working **on ccpraxis itself**: the plugins, skills, launchers and scripts that Claude Code
runs. Read `plugins/sandbox/docs/working-on-ccpraxis.md` before changing anything about how the
sandbox launches.

## Where you are, and where you must not be

| path | what it is |
|---|---|
| this repo | your **clone**. Develop here. Sandbox here. |
| `~/.claude/ccpraxis` | the **live install** — the plugin tree Claude Code is executing. Never develop here. |

`claude-sandbox` refuses to launch against `~/.claude/ccpraxis`, by design. Editing the live install
means editing tooling while it is in use.

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

A skill already loaded this session was read at invocation time, so a fix on disk — even a promoted
one — may not be what you are currently following. A **new** `skills/<name>/` is not mounted at all
until a full manager launch.

**Promotion is a merge:** `git -C ~/.claude/ccpraxis pull <this-clone> main`. `install.pl` only
re-wires PATH and plugin registration; it never copies plugin code, so a clean install run does not
mean promotion happened. Full mechanics: `plugins/sandbox/docs/working-on-ccpraxis.md`.

## Language and runtime

**Everything is Perl.** Install hooks, launchers, the statusline, sync logic. That is deliberate:
Perl ships with macOS, Linux and Git for Windows, so a fresh `git clone` runs everything with no
Node/Python/toolchain installs on the host. Do not introduce another runtime without a decision.

**Never run dev tooling on the host** — no `npm install`, `pip`, `cargo`, build tools. If something
needs a toolchain, it belongs in the sandbox container.

## Tests

Layout: `plugins/<plugin>/tests/t/NN-name.t`, plain `Test::More`, no harness config.

**`prove` does not exist on the Git-for-Windows host** — that perl ships no `TAP::Harness`
(`Can't locate TAP/Harness/Env.pm`). Run files directly and judge by exit code plus `not ok` count:

```bash
perl plugins/sandbox/tests/t/42-refuse-in-place.t
```

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
    `plugins/steward/tests/t/09-no-drive-root-strays.t`. Never set the variable shell-wide.
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

Holds blueprints, `claude-home` (transcripts, credentials, beacons), launcher state, and the
`guidance/` notes indexed below. Git never carries it, nor `deploy_key*`. Most of `.claude/` is
ignored too — but **not** `.claude/settings.json`; see the next section.

On relocation, **`git status --ignored` is the authoritative copy-list** — `.gitignore` lists
patterns, not what exists. Full gotchas, including the `claude-home/.launcher/` container-identity
trap: `plugins/sandbox/docs/working-on-ccpraxis.md`.

## Guidance notes — read on demand

Claude Code's built-in auto-memory is **disabled** (`autoMemoryEnabled: false` in every settings
layer, plus a `permissions.deny` on the memory path). Durable guidance lives here instead, read only
when the trigger applies:

| note | read it when |
|---|---|
| `.ccpraxis-local-data/guidance/push-straight-to-main.md` | pushing, or about to flag a "Bypassed rule violations" warning |
| `.ccpraxis-local-data/guidance/escalate-product-decisions-only.md` | about to ask the operator anything mid-run |
| `.ccpraxis-local-data/guidance/fix-ccpraxis-defects-in-place.md` | a real defect surfaces outside the current package's write set |
| `docs/design-conventions.md` (tracked) | making a design call — packaging, approval flows, what to enforce in code — or hitting a Windows/Perl oddity that smells environmental |

Nothing that a hook already enforces belongs here — the hook is the instruction.

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
`plugins/sandbox/tests/t/61-settings-scope-split.t` and
`plugins/butler/tests/t/112-subagent-stall-guard.t`.

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
  `~/.claude/CLAUDE.md`. Editing it changes what every project sees on this machine.
- **This file** — instructions for working on ccpraxis itself.
