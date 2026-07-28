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
git -C ~/.claude/ccpraxis status --short          # must be clean
git -C ~/.claude/ccpraxis pull /c/Development/ccpraxis main
```

**That is the whole promotion.** Because `~/.claude/ccpraxis` *is* the installed plugin tree — the
`ccpraxis-local` marketplace is a `directory` source whose `installLocation` is
`~/.claude/ccpraxis/plugins`, and `~/.claude/ccpraxis/plugins/*/bin` is what sits on your `PATH` —
the merge lands the new code exactly where Claude Code reads it. There is **no separate "installed"
copy** to refresh.

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

**Verify the promotion took:**

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
- **`.ccpraxis-local-data/` is gitignored and never travels via git.** Blueprints, `claude-home`
  (agent memory, session transcripts, credentials, beacons) move only by file copy. So do
  `deploy_key`, `deploy_key.pub` and `.claude/`. If you ever relocate a project, copy those
  explicitly — `git status --ignored` is the authoritative list, not `.gitignore`.
- **The clone is not a registered marketplace**, so it is not protected and launches normally. If
  you ever register it as one, `claude-sandbox` will start refusing it — by design.
