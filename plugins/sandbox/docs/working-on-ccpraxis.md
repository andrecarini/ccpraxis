# Working on ccpraxis itself

Every machine has two checkouts of your ccpraxis fork, and Claude Code runs only one of them.

| checkout | where | what it is for |
|---|---|---|
| **dev clone** | a folder you choose, normally under `~/Projects` (`~/Projects/ccpraxis` on macOS; the original Windows machine used `C:/Development/ccpraxis`) | editing, committing, running the tests, launching `claude-sandbox`. Nothing here is in effect until it is promoted. |
| **live install** | `~/.claude/ccpraxis` | the plugins, skills, hooks, statusline and launchers Claude Code executes. Never edited by hand; `claude-sandbox` refuses to sandbox it. |

**Promotion** moves a change from the dev clone into the live install: `perl scripts/promote.pl`,
run from the dev clone. It does not copy files over the live install. It git-merges the dev clone's
`main` into `~/.claude/ccpraxis`, then syncs the `global-config/` payload into `~/.claude` under
per-file rules, with backups ([Promoting to live](#promoting-to-live)).

**GitHub is fed from the live install.** `/steward:backup` runs in `~/.claude/ccpraxis`: it fetches
`origin`, merges `origin/main` into the live install, commits the config it exports and pushes
`main`. The fork's `main` therefore holds what was promoted, plus the backup commits and promotion
merge commits the live install made itself.

```text
dev clone  --(perl scripts/promote.pl: merge + global-config sync)-->  live install  --(/steward:backup: push)-->  GitHub fork
           <--(git pull live main)------------------------------------
```

So do not push the dev clone's `main` to the fork. The next `/steward:backup` would merge it into
the live install without promote.pl, and the code would go live while `~/.claude/CLAUDE.md` and
`~/.claude/settings.json` stayed at the old payload. In the other direction, pull the live
install's own commits back with `git pull live main` in the dev clone, at least before editing
`global-config/`: backup exports land in the live install first, and promoting an older copy of the
same file can conflict.

## Setting up a machine

The commands use `~/Projects/ccpraxis` for the dev clone and `<you>` for your GitHub account. On
Windows run them in Git Bash, where `~` is `C:/Users/<name>`. Claude follows the same steps, with
confirmation gates, when you ask it to install ccpraxis
([`docs/install-protocol.md`](../../../docs/install-protocol.md)).

**1. Prerequisites.** Claude Code, installed, signed in and started once (which creates
`~/.claude/`). Git and Perl 5.14 or newer:

- macOS: Perl ships with the OS (`/usr/bin/perl`, 5.34 on macOS 27). Git comes with the Xcode
  Command Line Tools: `xcode-select --install`, or accept the prompt the first `git` call raises.
- Windows: Git for Windows, which carries its own Perl and bash.

**2. Clone the dev clone.**

```bash
git clone https://github.com/<you>/ccpraxis.git ~/Projects/ccpraxis
git -C ~/Projects/ccpraxis remote add upstream https://github.com/andrecarini/ccpraxis.git   # forks only
```

Promotion takes the dev clone's `main` branch, never the checked-out branch or uncommitted edits.
Whatever should go live has to be committed on `main` first.

**3. Create the live install**, from the fork rather than from the dev clone, so its `origin` is
the fork that `/steward:backup` pushes to:

```bash
git clone https://github.com/<you>/ccpraxis.git ~/.claude/ccpraxis
```

**4. Give the dev clone a `live` remote**, so the live install's own commits can be pulled back:

```bash
git -C ~/Projects/ccpraxis remote add live ~/.claude/ccpraxis
```

**5. Back up the config you already have, and make sure a settings file exists.**

```bash
perl ~/.claude/ccpraxis/scripts/backup-user-config.pl
[ -e ~/.claude/settings.json ] || printf '{}\n' > ~/.claude/settings.json
```

The backup copies `~/.claude/CLAUDE.md` and `~/.claude/settings.json` to
`<file>.pre-ccpraxis.<timestamp>`. There is no uninstaller, so that copy is the undo. The second
line matters because promote.pl merges into an existing `settings.json` and skips a missing one.

**6. Promote for the first time**, from the dev clone:

```bash
perl ~/Projects/ccpraxis/scripts/promote.pl --dry-run
perl ~/Projects/ccpraxis/scripts/promote.pl
```

On a fresh machine expect `merge: up-to-date` (a fast-forward if the dev clone is ahead of the
fork), `claude-md: installed`, `settings: updated (N changes)`, and, once Claude Code has recorded
its marketplaces, a `missing-live <name>` line for each marketplace still to add. The payload's `ccpraxis-local` marketplace path is a placeholder, and
promote.pl writes this machine's `~/.claude/ccpraxis/plugins` in its place; there is nothing to
edit by hand. Act on these lines if the report shows them:

- `claude-md: refused-local-edit`: your existing `~/.claude/CLAUDE.md` has lines no version of the
  payload ever had, and they are listed. Fold them into `global-config/CLAUDE.md` in the dev clone,
  commit, and promote again, or delete them from `~/.claude/CLAUDE.md` (step 5 kept a copy).
- `kept-local <key>`: a setting where your own value was kept. Change it by hand if you want the
  payload's.

`~/.claude/CLAUDE.md` is a copy that every promotion refreshes. Do not replace it with a symlink:
promote.pl refuses one unless it points at `~/.claude/ccpraxis/global-config/CLAUDE.md`, and Git
Bash's `ln -s` on Windows makes a plain copy anyway.

**7. Wire skills and PATH, from the live install.**

```bash
perl ~/.claude/ccpraxis/scripts/install-skills.pl plan
perl ~/.claude/ccpraxis/scripts/install-skills.pl apply
perl ~/.claude/ccpraxis/install.pl              # prints the plan, changes nothing
perl ~/.claude/ccpraxis/install.pl --confirm
git -C ~/.claude/ccpraxis status --porcelain    # must print nothing
```

Run the live install's copies, never the dev clone's: the skill links and PATH entries must point
into `~/.claude/ccpraxis`. `install-skills.pl` links every `skills/<name>/` into `~/.claude/skills/`
(symlinks on macOS and Linux, directory junctions on Windows). `install.pl` runs each plugin's
`ccpraxis-install.pl`: on macOS and Linux that appends one `export PATH=...` line per plugin `bin/`
directory to `~/.zshrc` when `$SHELL` is zsh (the macOS default), otherwise to `~/.bashrc` if it
exists or `~/.profile`; on Windows it edits the User-scope `PATH` and `PATHEXT` registry values.

The status check guards the next promotion, which refuses a live install with any modified or
untracked file. The launcher aliases (`claude-sandbox`, `ccpraxis`, the `bp-*` commands) are
tracked files and every script is committed executable, so a clean install leaves the tree clean.
If something does appear, find what wrote it instead of committing it in the live install.

**8. Marketplaces and plugins.** Start a new Claude Code session so it reads the promoted settings.
Add each marketplace step 6 reported as `missing-live` (`/plugin marketplace add <owner>/<repo>`),
then install every plugin enabled in `global-config/settings.json` that `/plugin` does not list as
installed (`/plugin install <plugin>@<marketplace>`). `ccpraxis-local` needs no adding: settings
declare it as a `directory` marketplace at `~/.claude/ccpraxis/plugins`.

**9. Vault** (optional, recommended).

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/vault-sync.pl init --url <vault-url>
```

That clones your private vault to `~/.claude/claude-code-vault/`. Then run `/steward:setup-project`
in a Claude Code session opened in the dev clone. If an earlier machine registered its dev clone,
link this one to the same slug: the first sync restores the gitignored `.ccpraxis-local-data/`
(blueprints, guidance notes, references) that git never carries.

**10. Container runtime**, for the sandbox only.

- Windows: Podman with the WSL2 backend (`podman machine init`, then `podman machine start`), never
  Hyper-V; the README's Platforms section says why.
- macOS: `brew install podman`, then `podman machine init` and `podman machine start`. Keep the
  machine rootless, which is the default: do not pass `--rootful`.

**11. Restart and verify.** Open a new terminal, which reads the new PATH lines, and start a new
Claude Code session: its Bash tool runs from a shell snapshot taken at session start, and plugin
skill text is read at session start as well.

```bash
git -C ~/.claude/ccpraxis status --porcelain             # empty
perl ~/Projects/ccpraxis/scripts/promote.pl --dry-run    # merge: up-to-date, claude-md: unchanged, settings: unchanged
command -v claude-sandbox                                # macOS/Linux; in PowerShell: Get-Command claude-sandbox
```

In Claude Code, `/plugin` should list the `@ccpraxis-local` plugins as installed, and the
statusline should show its two rows.

**A machine that already has a live install but no dev clone** needs only steps 2 and 4, then
`git -C ~/Projects/ccpraxis pull live main`. If you clone from the live install's path instead of
from GitHub, pass `--no-hardlinks`: a local `git clone` hardlinks the object store by default,
which silently re-couples the clone to the live install.

## The loop

From a terminal in the dev clone:

```bash
git pull live main                          # pick up backup exports and promotion merges
claude-sandbox                              # optional: work inside the project's container
perl scripts/run-tests.pl --fast plugins/<plugin>
git commit ...                              # on main, or merge your branch into main
perl scripts/promote.pl --dry-run
perl scripts/promote.pl
```

Then start a new Claude Code session before relying on the change. A session that was already open
keeps the `SKILL.md` text it read at start, even though the scripts those skills run are already
the promoted ones. Inside a sandbox, plugin code is live on promotion and skills need a full manager
launch; the repo `CLAUDE.md` has the per-surface table.

`install.pl` and `install-skills.pl` are only for wiring changes
([below](#when-you-additionally-need-installpl)). `/steward:backup`, run whenever you want the fork
updated, pushes the live install to GitHub.

**Pulling upstream fixes into a fork** follows the same path: `git fetch upstream` and
`git merge upstream/main` in the dev clone, run the tests, promote. Expect conflicts in
`global-config/` and `.claude/settings.json`, which both sides edit.

Inside the container, `git -C /project status` works. That is the whole point of the clone model:
the clone's `.git` is a real directory, so git functions normally in-container, and the container
cannot reach the live install because the live object store simply is not there. The isolation is
structural, not policy-enforced.

## Promoting to live

```bash
perl scripts/promote.pl --dry-run    # from the dev clone; previews the merge and payload sync, writes nothing
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
| `global-config/CLAUDE.md` | `~/.claude/CLAUDE.md` | installed when missing; replaced if every live line appears in some committed version of the payload; otherwise refused with those lines listed. A symlink is left alone if it points at the live install's own `global-config/CLAUDE.md`, and refused otherwise |
| `global-config/settings.json` | `~/.claude/settings.json` | per key (one-level dotted units, as `settings-export-merge`): payload keys added, payload wins over a value it once had, a never-seen live value is kept and reported, live-only keys kept, `.backup-preferences.json` honoured. Skipped when the live file does not exist. The `ccpraxis-local` marketplace path is a portable placeholder in the payload: promote.pl writes this machine's `~/.claude/ccpraxis/plugins` in its place, and `/steward:backup` exports the placeholder back, never a machine path. `env.CLAUDE_CODE_USE_POWERSHELL_TOOL` is applied on Windows hosts only |
| `global-config/known_marketplaces.json` | `~/.claude/plugins/known_marketplaces.json` | reported only; add with `/plugin marketplace add` |

Exit codes: 0 ok, 1 a file refused, 2 refused/failed, 3 usage.

### When you additionally need install.pl

Only when the *wiring* changed, not the code: a new plugin with its own `bin/` directory, a changed
`ccpraxis-install.pl` hook, or a PATH/PATHEXT adjustment. A new bare skill under `skills/` is
linked by `install-skills.pl apply`, or by the next `/steward:backup`, which mirrors `skills/` as
well. Both scripts are idempotent and harmless to re-run, and both run from the live install:

```bash
perl ~/.claude/ccpraxis/install.pl             # plan only
perl ~/.claude/ccpraxis/install.pl --confirm   # apply
perl ~/.claude/ccpraxis/scripts/install-skills.pl apply
```

> **Do not treat `install.pl` as the promotion step.** It discovers and runs each surface's
> `ccpraxis-install.pl` hook; it does not copy or refresh plugin code. Treating it as the promotion
> step lets a successful-looking install mask a merge that never happened.

**Verify the promotion took:** the report's `result: ok` line, alongside:

```bash
git -C ~/.claude/ccpraxis log --oneline -1     # your commit, or a merge of it, is at HEAD
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
  (agent memory, session transcripts, credentials) move only by file copy or through the vault. So
  do `deploy_key`, `deploy_key.pub` and `.claude/`. If you ever relocate a project, copy those
  explicitly — `git status --ignored` is the authoritative list, not `.gitignore`.
- **The clone is not a registered marketplace**, so it is not protected and launches normally. If
  you ever register it as one, `claude-sandbox` will start refusing it — by design.
- **The container's Claude Code version tracks the HOST's — it is not insulated from it.** At build
  time `bootstrap.pl` reads the host's `claude --version` and passes it as `--build-arg
  CLAUDE_VERSION`; the `Containerfile` installs exactly that; `launcher.pl` marks a container stale
  on a version mismatch and rebuilds. So any runtime risk tied to the bundled Claude/Bun version
  reaches the in-container butler fleet too. One caveat when comparing reports: the container runs
  the Linux build of Bun, the host the Windows or macOS one, so platform-specific symptoms can
  differ.

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

A fork can also list host names its containers must not reach in `@BLOCKED_HOSTS`; each is pinned
to `0.0.0.0` in the container's `/etc/hosts` at create time (`--add-host`). Entries that are not
plain DNS names are dropped. It is a guardrail, not a wall: root in the container can edit
`/etc/hosts`. ccpraxis itself blocks nothing.
