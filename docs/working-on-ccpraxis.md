# Working on ccpraxis itself

Every machine has two checkouts of your ccpraxis fork, and Claude Code runs only one of them.

| checkout | where | what it is for |
|---|---|---|
| **dev clone** | a folder you choose, normally `~/Projects/ccpraxis` (the original Windows machine uses `C:/Development/ccpraxis`) | editing, committing, running the tests, launching `claude-sandbox`. Its `origin` is your GitHub fork, and it is the only checkout that talks to GitHub. Nothing here is in effect until it is promoted. |
| **live install** | `~/.claude/ccpraxis` | the plugins, skills, hooks, statusline and launchers Claude Code executes. Produced by promotion and nothing else: the first promotion creates it, later ones move it forward, and its `origin` is the dev clone. Never edited, committed in, pulled into or pushed from. `claude-sandbox` refuses to sandbox it. |

```text
GitHub fork  <--(git pull / git push)-->  dev clone  --(perl scripts/promote.pl)-->  live install + ~/.claude
```

**Promotion** is `perl scripts/promote.pl`, run from the dev clone. It fast-forwards the live install
to the dev clone's `main` (cloning it from the dev clone the first time), then syncs the
`global-config/` payload into `~/.claude` under per-file rules, with backups
([Promoting to live](#promoting-to-live)). Because the live install only ever receives commits this
way, it never has commits of its own; if it does, it was changed some other way, and promote.pl
refuses and prints the command that brings those commits into the dev clone.

Two steward commands keep the three places consistent, and only one of them touches GitHub:

- **`/steward:backup`** is local. It promotes the dev clone's unpromoted commits (asking once,
  since that changes running tooling); then, for every setting Claude Code changed in `~/.claude`
  (a permission you allowed, a plugin you enabled), it applies your saved preference or asks you,
  one setting at a time: take your value into the dev clone's `global-config/`, put the payload's
  value back into `~/.claude`, skip it this time, or remember an answer. What you send to the
  payload is committed in the dev clone (only those files) and promoted, so the live install and
  the dev clone end up at the same commit. It also syncs every registered project with your
  private vault.
- **`/steward:upstream-sync`** is the GitHub side of the dev clone: it fetches your fork, brings
  its `main` into the dev clone's (stopping cleanly on a conflict), and pushes the dev clone's
  `main` after listing every commit that would go out. It never touches the live install; what it
  pulls in goes live through `/steward:backup` or `scripts/promote.pl`.

## Setting up a machine

The commands use `~/Projects/ccpraxis` for the dev clone and `<you>` for your GitHub account. On
Windows run them in Git Bash, where `~` is `C:/Users/<name>`. Claude follows the same steps, with
confirmation gates, when you ask it to install ccpraxis
([`install-protocol.md`](install-protocol.md)).

**1. Prerequisites.** Claude Code, installed, signed in and started once (which creates
`~/.claude/`). Git and Perl 5.14 or newer:

- macOS: Perl ships with the OS (`/usr/bin/perl`, 5.34 on macOS 27). Git comes with the Xcode
  Command Line Tools: `xcode-select --install`, or accept the prompt the first `git` call raises.
- Windows: Git for Windows, which carries its own Perl and bash.

**2. Clone the dev clone from GitHub.**

```bash
git clone https://github.com/<you>/ccpraxis.git ~/Projects/ccpraxis
git -C ~/Projects/ccpraxis remote add upstream https://github.com/andrecarini/ccpraxis.git   # forks only
```

Promotion takes the dev clone's `main` branch, never the checked-out branch or uncommitted edits.
Whatever should go live has to be committed on `main` first.

**3. Back up the config you already have, and make sure a settings file exists.**

```bash
perl ~/Projects/ccpraxis/scripts/backup-user-config.pl
[ -e ~/.claude/settings.json ] || printf '{}\n' > ~/.claude/settings.json
```

The backup copies `~/.claude/CLAUDE.md` and `~/.claude/settings.json` to
`<file>.pre-ccpraxis.<timestamp>`. There is no uninstaller, so that copy is the undo. The second
line matters because promote.pl merges into an existing `settings.json` and skips a missing one.

**4. Promote for the first time**, from the dev clone. This creates the live install.

```bash
perl ~/Projects/ccpraxis/scripts/promote.pl --dry-run
perl ~/Projects/ccpraxis/scripts/promote.pl
```

Expect `merge: created ~/.claude/ccpraxis from the clone's main at <sha>`, `claude-md: installed`,
`settings: updated (N changes)`, and, once Claude Code has recorded its marketplaces, a
`missing-live <name>` line for each marketplace still to add. `~/.claude/CLAUDE.md` is built for
this operating system: the shared `global-config/CLAUDE.md` plus `CLAUDE.windows.md` or
`CLAUDE.macos.md`, never both. The payload's `ccpraxis-local` marketplace path is a placeholder that
promote.pl fills in with this machine's `~/.claude/ccpraxis/plugins`. Act on these lines if the
report shows them:

- `claude-md: refused-local-edit`: your existing `~/.claude/CLAUDE.md` has lines no version of the
  payload ever had, and they are listed. Fold them into `global-config/CLAUDE.md` (every machine)
  or this OS's part in the dev clone, commit, and promote again, or delete them from
  `~/.claude/CLAUDE.md` (step 3 kept a copy).
- `kept-local <key>`: a setting where your own value was kept. Change it by hand if you want the
  payload's.

**5. Wire skills and PATH, from the live install.**

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
directory to your shell's rc file (`~/.zshrc` on a default Mac); on Windows it edits the
User-scope `PATH` and `PATHEXT` registry values.

The status check guards the next promotion, which refuses a live install with any modified or
untracked file. The launcher aliases (`claude-sandbox`, `ccpraxis`, the `bp-*` commands) are
tracked files and every script is committed executable, so a clean install leaves the tree clean.
If something does appear, find what wrote it instead of committing it in the live install.

**6. Marketplaces and plugins.** Start a new Claude Code session so it reads the promoted settings.
Add each marketplace step 4 reported as `missing-live` (`/plugin marketplace add <owner>/<repo>`),
then install every plugin enabled in `global-config/settings.json` that `/plugin` does not list as
installed (`/plugin install <plugin>@<marketplace>`). Settings declare `ccpraxis-local` as a
`directory` marketplace at `~/.claude/ccpraxis/plugins`; if `/plugin` does not list it, add it with
`claude plugin marketplace add ~/.claude/ccpraxis/plugins`. Claude Code loads those plugins in
place from that folder, so a promotion reaches them without reinstalling.

**7. Vault** (optional, recommended).

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/vault-sync.pl init --url <vault-url>
```

That clones your private vault to `~/.claude/claude-code-vault/`. Then run `/steward:setup-project`
in a Claude Code session opened in the dev clone. If an earlier machine registered its dev clone,
link this one to the same slug: the first sync restores the gitignored `.ccpraxis-local-data/`
(blueprints, guidance notes, almanac records) that git never carries.

**8. Container runtime**, for the sandbox only.

- Windows: Podman with the WSL2 backend (`podman machine init`, then `podman machine start`), never
  Hyper-V; the README's Platforms section says why.
- macOS: `brew install podman`, then create the machine with
  `perl ~/.claude/ccpraxis/plugins/sandbox/scripts/podman-machine.pl apply --confirm` (run it
  without `--confirm` first to see the plan). It makes a rootful machine with 6 CPUs and 12 GiB that
  shares only what the sandbox mounts, and no project yet: share one with `add-project <dir>
  --confirm`. The machine runs as your user and needs no admin rights. Details:
  `plugins/sandbox/docs/podman-machine.md`.

**9. Restart and verify.** Open a new terminal, which reads the new PATH lines, and start a new
Claude Code session: its Bash tool runs from a shell snapshot taken at session start, and plugin
skill text is read at session start as well.

```bash
git -C ~/.claude/ccpraxis status --porcelain             # empty
git -C ~/.claude/ccpraxis remote get-url origin          # the dev clone's path
perl ~/Projects/ccpraxis/scripts/promote.pl --dry-run    # merge: up-to-date, claude-md: unchanged, settings: unchanged
command -v claude-sandbox                                # macOS/Linux; in PowerShell: Get-Command claude-sandbox
```

In Claude Code, `/plugin` should list the `@ccpraxis-local` plugins as installed, and the
statusline should show its two rows.

## Moving a machine from the old workflow

Until 2026-10-30 the live install was cloned from GitHub and `/steward:backup` committed in it and
pushed from it. A machine set up that way (the Windows host) moves over once, in this order:

1. **Do not run `/steward:backup` on it until step 4 is done.** The old backup code fetches GitHub's
   `main` into the live install and keeps running its own, older code against the new payload. If
   it then offers to "use the repo value" for the `ccpraxis-local` marketplace and that is accepted,
   it writes the unexpanded `${CCPRAXIS_LIVE}` placeholder into `~/.claude/settings.json`, and every
   ccpraxis plugin disappears until the path is fixed by hand.
2. **Bring the live install's own commits into the dev clone, then GitHub's.** From the dev clone:

   ```bash
   git pull --no-rebase ~/.claude/ccpraxis main   # backup exports and merge commits only the live install has
   git pull --no-rebase origin main               # everything other machines pushed
   perl scripts/run-tests.pl --fast
   ```

3. **Promote.** `perl scripts/promote.pl --dry-run`, then `perl scripts/promote.pl`. The live
   install fast-forwards, its `origin` is re-pointed from GitHub to the dev clone
   (`origin: set to the dev clone ... (was https://github.com/...)`), and `~/.claude/CLAUDE.md` is
   rebuilt for this operating system.
4. **Push from the dev clone:** `/steward:upstream-sync` (or `git push origin main`). From now on
   GitHub is the dev clone's remote only. The dev clone's old `live` remote is no longer needed
   (`git remote remove live`).

If step 3 reports `refused-live-only-commits`, step 2's first pull was skipped or the live install
gained a commit since; run the pull it prints, then promote again.

## The loop

From a terminal in the dev clone:

```bash
git pull                                    # what other machines pushed (or /steward:upstream-sync)
claude-sandbox                              # optional: work inside the project's container
perl scripts/run-tests.pl --fast plugins/<plugin>
git commit ...                              # on main, or merge your branch into main
perl scripts/promote.pl --dry-run
perl scripts/promote.pl
git push                                    # or /steward:upstream-sync
```

Then start a new Claude Code session before relying on the change. A session that was already open
keeps the `SKILL.md` text it read at start, even though the scripts those skills run are already
the promoted ones. Inside a sandbox, plugin code is live on promotion and skills need a full manager
launch; the repo `CLAUDE.md` has the per-surface table.

**Pulling upstream fixes into a fork** follows the same path: `git fetch upstream` and
`git merge upstream/main` in the dev clone, run the tests, promote, push. Expect conflicts in
`global-config/` and `.claude/settings.json`, which both sides edit.

## Promoting to live

```bash
perl scripts/promote.pl --dry-run    # from the dev clone; previews everything, writes nothing
perl scripts/promote.pl              # apply
```

The live install is moved first, then the payload is synced from it:

| state of `~/.claude/ccpraxis` | what promote.pl does |
|---|---|
| missing | clones the dev clone there (`merge: created`); its `origin` is the dev clone |
| at the dev clone's `main` | nothing (`merge: up-to-date`) |
| behind the dev clone's `main` | fast-forwards it (`merge: fast-forward a..b (N commits)`) |
| has commits the dev clone lacks | refuses, lists them, prints the pull that brings them into the dev clone (`merge: refused-live-only-commits`, exit 2) |
| has modified or untracked files | refuses (`merge: refused-dirty`, exit 2) |
| `origin` is not the dev clone | re-points it, dropping the old remote-tracking refs (`origin: set to the dev clone ... (was ...)`) |

`~/.claude/ccpraxis` *is* the installed plugin tree: the `ccpraxis-local` marketplace is a
`directory` source at `~/.claude/ccpraxis/plugins`, Claude Code loads those plugins in place, and
`~/.claude/ccpraxis/plugins/*/bin` is what sits on your `PATH`, so there is no separate installed
copy to refresh. Then the three `global-config/` files, with backups under
`~/.claude/.promotion-backups/<ts>/`:

| payload | live | rule |
|---|---|---|
| `global-config/CLAUDE.md` + this OS's `CLAUDE.windows.md` / `CLAUDE.macos.md` | `~/.claude/CLAUDE.md` | built, not copied: the shared file, a blank line, then this OS's part (Linux has none). Installed when missing; replaced if every live line appears in some committed version of some part; otherwise refused with those lines listed. A symlink to the live install's own `global-config/CLAUDE.md` is replaced by the built file when this OS has a part; any other symlink is refused |
| `global-config/settings.json` | `~/.claude/settings.json` | per key (one-level dotted units, as `settings-export-merge`): payload keys added, payload wins over a value it once had, a never-seen live value is kept and reported, live-only keys kept, `.backup-preferences.json` honoured. Skipped when the live file does not exist. The `ccpraxis-local` marketplace path is a portable placeholder in the payload: promote.pl writes this machine's `~/.claude/ccpraxis/plugins` in its place, and `/steward:backup` exports the placeholder back, never a machine path. `env.CLAUDE_CODE_USE_POWERSHELL_TOOL` is applied on Windows hosts only |
| `global-config/known_marketplaces.json` | `~/.claude/plugins/known_marketplaces.json` | reported only; add with `/plugin marketplace add` |

Exit codes: 0 ok, 1 a file refused, 2 refused/failed, 3 usage.

### When you additionally need install.pl

Only when the *wiring* changed, not the code: a new plugin with its own `bin/` directory, a changed
`ccpraxis-install.pl` hook, or a PATH/PATHEXT adjustment, and a new bare skill under `skills/`,
which `install-skills.pl apply` links. Both scripts are idempotent and harmless to re-run, and both
run from the live install:

```bash
perl ~/.claude/ccpraxis/install.pl             # plan only
perl ~/.claude/ccpraxis/install.pl --confirm   # apply
perl ~/.claude/ccpraxis/scripts/install-skills.pl apply
```

> **Do not treat `install.pl` as the promotion step.** It discovers and runs each surface's
> `ccpraxis-install.pl` hook; it does not copy or refresh plugin code. Treating it as the promotion
> step lets a successful-looking install mask a promotion that never happened.

**Verify the promotion took:** the report's `result: ok` line, alongside:

```bash
git -C ~/.claude/ccpraxis log --oneline -1     # the dev clone's main
```

Then exercise whatever you changed. For launcher changes specifically, running `claude-sandbox`
from `~/.claude/ccpraxis` should print the in-place refusal and exit non-zero; that path is a
useful smoke test precisely because it is supposed to fail.

## The sandbox and your checkouts

How `claude-sandbox` treats the two checkouts (why it refuses the live install, which checkout's
tooling a launch uses, and the `.launcher/` state you must never copy between projects) is in
[`plugins/sandbox/docs/sandbox-checkouts.md`](../plugins/sandbox/docs/sandbox-checkouts.md).

## What git does not carry

`.ccpraxis-local-data/` is gitignored and never travels through git: blueprints, almanac records,
guidance notes, and the sandbox's `claude-home` (session transcripts, credentials). Neither do
`deploy_key`, `deploy_key.pub` and most of `.claude/`. They move through the vault
(`/steward:setup-project`, then `/steward:backup`) or by explicit file copy. If you relocate a
project, `git status --ignored` is the authoritative list of what to copy, not `.gitignore`.
