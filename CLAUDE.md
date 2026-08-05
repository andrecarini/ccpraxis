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

This is not a subtle distinction and it is not rare — it bit three times in a single session:

- agent `maxTurns` caps were raised and **stayed inert**, so a fan-out would still have died at the
  old cap;
- a new `skills/<name>/` was added and **was not mounted** (skills are bind-mounted per the picker's
  selection, and a `--session`/`--resume-session` *connector* launch skips the picker entirely);
- `bp-blueprint.pl` gained verbs that the executing copy **did not have**, so the very command about
  to be run would have failed exactly as before.

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

**Skills and prose have their own trap.** A `SKILL.md` under `plugins/**` rides the live mount like
any other file — but a skill already loaded into the running session was read at invocation time, and
a **new** `skills/<name>/` directory is not mounted at all until a full manager launch. So a
correction can be on disk, live, and still not be what the current session is following.

**Promotion is a merge, not an install:**

```bash
git -C ~/.claude/ccpraxis pull <this-clone> main
```

`~/.claude/ccpraxis` *is* the installed plugin tree (the `ccpraxis-local` marketplace is a
`directory` source pointing at its `plugins/`, which is also what is on `PATH`), so the merge alone
promotes. Run `install.pl` **only** when PATH wiring or the set of plugins changed — it runs each
surface's `ccpraxis-install.pl` hook and does not copy plugin code. Never treat it as the promotion
step: a successful-looking install can otherwise mask a merge that never happened.

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
  becomes `HOST;CONTAINER`). Any perl script spawning a native binary must set
  `$ENV{MSYS2_ARG_CONV_EXCL} = '*'` on Windows — *or* hand-translate to forward-slash Windows paths,
  which `podman.exe` and `git.exe` both accept directly. Symptom: stray directories ending in `;C`.
- **Paths contain non-ASCII** (`André`). Nothing may assume ASCII paths. Round-trip registry values
  as UTF-8 bytes; never re-encode something already decoded.
- **`podman machine set --disk-size` does not work here** — it exits 125 with *"changing disk size
  not supported for WSL machines"*. The machine's disk is the WSL distro's `ext4.vhdx`, so growing it
  is a WSL operation:
  ```powershell
  wsl --shutdown
  wsl --manage podman-machine-default --resize 32212254720   # bytes; 30 GiB. Grow only.
  ```
  It runs `e2fsck` + `resize2fs` itself, so the filesystem comes up already grown — verify with
  `wsl -d podman-machine-default --exec df -h /`. Afterwards `podman machine list` still reports the
  **original** size: that field is podman's own creation-time record, which podman declines to update
  for WSL machines. It is stale, not wrong-in-a-way-that-matters — trust `df`, not `podman machine
  list`. The vhdx is sparse and never shrinks, so its on-disk size tracks the high-water mark rather
  than current usage; check host free space before growing.

## `.ccpraxis-local-data/` — gitignored, and it does not travel

Holds blueprints, `claude-home` (agent memory, session transcripts, credentials, beacons), launcher
state. Git never carries it. Nor does it carry `deploy_key`, `deploy_key.pub` or `.claude/`.

If you relocate a project, **`git status --ignored` is the authoritative list of what to copy — not
`.gitignore`**, which lists patterns rather than what actually exists.

**Never copy `claude-home/.launcher/` between project locations.** It encodes container identity
(`container-name`, `port-base`, `containerfile-hash`); a copied `container-name` makes the launcher
attach to another project's container and mount the wrong directory at `/project`. It is derived
state — delete it and it regenerates.

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
