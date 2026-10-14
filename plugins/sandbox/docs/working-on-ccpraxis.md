# Working on ccpraxis itself

ccpraxis is installed at `~/.claude/ccpraxis` and **that repo is the live plugin tree** — the
launcher, skills and scripts Claude Code is executing right now. You therefore do not edit it
directly, and `claude-sandbox` refuses to sandbox it in place.

Instead: **work in a clone, promote by merging.**

```
~/.claude/ccpraxis        the LIVE install. Claude runs this. Don't develop here.
C:/Development/ccpraxis   your working clone. Develop and sandbox here.
```

## One-time setup

```bash
git clone --no-hardlinks ~/.claude/ccpraxis /c/Development/ccpraxis
cd /c/Development/ccpraxis
git remote rename origin live      # so a reflexive `git pull` doesn't target the install
```

**`--no-hardlinks` is not optional.** A local `git clone` hardlinks the object store by default,
which silently re-couples the clone to the live install and reintroduces exactly the coupling this
setup exists to remove.

Renaming the remote to `live` is deliberate: you keep a path back for promotion, but `origin` no
longer points at your own installation.

## The loop

```bash
cd /c/Development/ccpraxis
claude-sandbox                     # launches normally — an ordinary project
# ...work, commit...
```

Inside the container, `git -C /project status` works. That is the whole point of the clone model:
the clone's `.git` is a real directory, so git functions normally in-container, and the container
cannot reach the live install because the live object store simply is not there. The isolation is
structural, not policy-enforced.

## Promoting to live

```bash
cd /c/Development/ccpraxis
perl scripts/promote.pl --dry-run    # preview: merge + payload sync, writes nothing
perl scripts/promote.pl              # apply
```

The script merges this clone's `main` into `~/.claude/ccpraxis` (refusing on a dirty live tree,
aborting cleanly on a conflict), which lands plugin code where Claude Code reads it — because
`~/.claude/ccpraxis` *is* the installed plugin tree, the `ccpraxis-local` marketplace is a
`directory` source whose `installLocation` is `~/.claude/ccpraxis/plugins`, and
`~/.claude/ccpraxis/plugins/*/bin` is what sits on your `PATH`, so there is **no separate
"installed" copy** to refresh. It also syncs the three `global-config/` files below, with backups
under `~/.claude/.promotion-backups/<ts>/`:

| payload | live | rule |
|---|---|---|
| `global-config/CLAUDE.md` | `~/.claude/CLAUDE.md` | replaced if every live line appears in some committed version of the payload; otherwise refused with those lines listed |
| `global-config/settings.json` | `~/.claude/settings.json` | per key (one-level dotted units, as `settings-export-merge`): payload keys added, payload wins over a value it once had, a never-seen live value is kept and reported, live-only keys kept, `.backup-preferences.json` honoured |
| `global-config/known_marketplaces.json` | `~/.claude/plugins/known_marketplaces.json` | reported only; add with `/plugin marketplace add` |

Exit codes: 0 ok, 1 a file refused, 2 refused/failed, 3 usage.

**When you additionally need `install.pl`:** only when the *wiring* changed, not the code — a new
plugin with its own `bin/` directory, a changed `ccpraxis-install.pl` hook, or a PATH/PATHEXT
adjustment. It is idempotent and harmless to run:

```bash
cd ~/.claude/ccpraxis && perl install.pl            # plan only
cd ~/.claude/ccpraxis && perl install.pl --confirm  # apply
```

> **Do not treat `install.pl` as the promotion step.** It discovers and runs each surface's
> `ccpraxis-install.pl` hook; it does not copy or refresh plugin code. Treating it as the promotion
> step lets a successful-looking install mask a merge that never happened.

**Verify the promotion took:** the report's `result: ok` line, alongside:

```bash
git -C ~/.claude/ccpraxis log --oneline -1     # your commit is at HEAD
```

Then exercise whatever you changed. For launcher changes specifically, running `claude-sandbox`
from `~/.claude/ccpraxis` should print the in-place refusal and exit non-zero — that path is a
useful smoke test precisely because it is supposed to fail.

## Why in-place is refused

Sandboxing `~/.claude/ccpraxis` would mean editing the tooling while it is running. The previous
answer to this was a git *worktree* of the live repo, which turned out to be unworkable: a worktree
shares the live object store and puts its admin files in the live repo, so creating it was already
a write to live — and `/project/.git` became a pointer to a Windows path meaningless to Linux,
killing git in-container entirely. Worse, the provisioning logic could silently overwrite blueprint
ledgers with pristine copies from live.

That model was deleted. See `migration-record.md` for the one-time migration that replaced it, and
the `sandbox-refuse-in-place` blueprint for the full reasoning.

## Gotchas

- **Never copy `.ccpraxis-local-data/claude-home/.launcher/` between project locations.** It holds
  machine- and container-specific identity (`container-name`, `port-base`, `containerfile-hash`).
  A copied `container-name` makes the launcher attach to *another project's* container and mount the
  wrong directory at `/project`. It is derived state — delete it and it regenerates.
- **`.launcher/last-transcript.txt`** is a one-line, best-effort pointer `launcher.pl` writes on every
  launch (immediately after opening the launch transcript), holding the in-container path to that
  launch's raw console transcript (`/root/.claude/sandbox-logs/launch-<id>.transcript.log`).
  `.launcher/` is RO-overlaid inside the container while `sandbox-logs/` is not, so an agent that
  inspects only `.launcher/` and finds no log there would otherwise reasonably (but wrongly) conclude
  none was kept — this pointer exists to redirect it to the real, writable location (BPK-07).
- **`.ccpraxis-local-data/` is gitignored and never travels via git.** Blueprints, `claude-home`
  (agent memory, session transcripts, credentials) move only by file copy. So do
  `deploy_key`, `deploy_key.pub` and `.claude/`. If you ever relocate a project, copy those
  explicitly — `git status --ignored` is the authoritative list, not `.gitignore`.
- **The clone is not a registered marketplace**, so it is not protected and launches normally. If
  you ever register it as one, `claude-sandbox` will start refusing it — by design.
- **The container's Claude Code version tracks the HOST's — it is not insulated from it.** At build
  time `bootstrap.pl` reads the host's `claude --version` and passes it as `--build-arg
  CLAUDE_VERSION`; the `Containerfile` installs exactly that; `launcher.pl` marks a container stale
  on a version mismatch and rebuilds. So any runtime risk tied to the bundled Claude/Bun version
  reaches the in-container butler fleet too. One caveat when comparing reports: the container runs
  Linux-x64 Bun against the host's Windows-x64, so platform-specific symptoms can differ.

## The launcher serves the checkout it runs from

`launcher.pl`, `bootstrap.pl` and `skills.pl` find their own tooling through
`plugins/sandbox/scripts/SandboxIdentity.pm`, never through a hard-coded `~/.claude/ccpraxis`:

- **`install_root()`** is the checkout the scripts were loaded from. The container template,
  statusline, backpack scripts, custom `skills/` dir, the image-build lock and the `ccpraxis-local`
  plugin tree bind-mounted into the container all come from it. Through the `claude-sandbox` shims
  that is the live install, the same directory as before. Run `perl plugins/sandbox/scripts/launcher.pl`
  straight from a clone and you get the clone's tooling.
- **Identity** (`$ID`, `$CONTAINER_PREFIX`) names the image (`claude-sandbox:latest`), the
  containers (`claude-<project>-<hash>`), the in-container hostname and the id presented to
  refusal markers.

This is what lets a **fork** ship a second launcher next to `claude-sandbox`: change the two
identity lines in `SandboxIdentity.pm`, add shims that point at the fork's checkout, and the fork's
command builds its own image, names its own containers and serves the fork's plugins, without
colliding with `claude-sandbox`. The port allocator recognises every family's container names, so
two launchers never hand out the same port block. Both share one Windows Terminal profile
(`WtProfile.pm`), which is harmless: the content is identical.
