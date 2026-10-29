# Install protocol for Claude

**This page is written for Claude, not for you.** When you ask Claude to install
ccpraxis, it reads this file and follows the steps below. It is kept separate
from the README so that the human-facing docs do not have to carry machine-facing
instructions — and so this can be edited without touching the front page.

If you are installing by hand, follow
[Setting up a machine](../plugins/sandbox/docs/working-on-ccpraxis.md#setting-up-a-machine):
the same steps, without the confirmation gates below.

## Install protocol for Claude

The procedure, its commands and the model behind it live in
[`plugins/sandbox/docs/working-on-ccpraxis.md`](../plugins/sandbox/docs/working-on-ccpraxis.md).
Read that whole file first. An install creates two checkouts of the user's fork: a **dev clone**
where they develop, and the **live install** at `~/.claude/ccpraxis` that Claude Code executes.
`scripts/promote.pl`, run from the dev clone, is what brings the live install and `~/.claude` up to
date, on the first install and on every update after it.

Then run the steps of its "Setting up a machine" section in order, with the additions below. Do
**not** run npm, pip, or any dev tooling: this is a config-only repo. Run each command as its own
call, with absolute paths or `git -C`, never `cd <dir> && ...`. On Windows the Bash tool is Git
Bash, so the commands work as written.

**Before step 1: collect what you need.** If the user's install message already supplied these, use
them; otherwise ask, making the distinction explicit:

- **A. Their ccpraxis fork URL** *(required)*. ccpraxis is configuration the user owns and customizes, so they install from their own fork, not the upstream. If they haven't forked yet, ask them to fork `https://github.com/andrecarini/ccpraxis` on GitHub and then give you the URL of their fork. Public or private — their choice; this repo holds no secrets, so privacy is not load-bearing.
- **B. Their private vault repo URL** *(optional but strongly recommended)*. This is a *separate* git repo (typical name: `claude-code-vault`) that holds personal Claude state across machines: todos, persistent plans, and per-project Claude files (CLAUDE.md, project skills, plans, memory). **It MUST be private** — it contains your personal working state and is the kind of data you do not want public. Any git host works (GitHub, GitLab, Gitea, self-hosted). If they don't already have one, tell them to create an empty **private** repo (e.g. `https://github.com/<user>/claude-code-vault`) and then give you the URL. If they decline to set this up now, that's fine — proceed without it; they can run `vault-sync.pl init` later.
- **C. Where the dev clone goes.** Default `~/Projects/ccpraxis`; any folder outside `~/.claude`
  works. Use the answer wherever the procedure says `~/Projects/ccpraxis`.

**Step 1, prerequisites.** Check `git --version` and `perl -e 'print $]'` (5.014 or newer). On
macOS a missing git means the Xcode Command Line Tools are not installed; `xcode-select --install`
opens an installer window, so ask the user to run it rather than running it yourself.

**Steps 2 to 4, the clones and the `live` remote.** Run them as written, with URL A in place of
`https://github.com/<you>/ccpraxis.git`. Skip the `upstream` remote when URL A is
`andrecarini/ccpraxis` itself. If `~/.claude/ccpraxis` already exists, stop: it is a live install
from an earlier setup. Tell the user, and follow the procedure's paragraph on a machine that
already has a live install, after they agree.

**Step 5, backup.** Report the paths `backup-user-config.pl` prints. They are the user's undo, and
the only one they get, since there is no automated uninstaller.

**Step 6, the first promotion.** Run `--dry-run`, show the user its report, and get their go-ahead
with AskUserQuestion before the real run. Then act on what it reports:

- `claude-md: would-refresh`: their existing `~/.claude/CLAUDE.md` will be replaced by the payload
  (promote.pl keeps a copy under `~/.claude/.promotion-backups/<ts>/`). Say so before applying.
- `claude-md: refused-local-edit`: show the listed lines and ask whether to fold them into the dev
  clone's `global-config/CLAUDE.md` (edit, commit on `main`, promote again) or drop them (delete
  them from `~/.claude/CLAUDE.md`; step 5's copy still has them). Never replace the file with a
  symlink.
- `kept-local <key>`: the user's own value was kept. For each, show both values (`perl
  ~/.claude/ccpraxis/plugins/steward/scripts/json-diff.pl --host-live ~/.claude/ccpraxis
  ~/.claude/settings.json ~/Projects/ccpraxis/global-config/settings.json` lists them under
  `diverged`; `--host-live` makes it compare the settings as they apply to this machine, so the
  marketplace-path placeholder and another platform's keys are not reported) and ask whether to
  keep theirs or take the repo's. Apply a "take the repo's" answer by editing that key in
  `~/.claude/settings.json`.

Do not edit `extraKnownMarketplaces.ccpraxis-local.source.path` by hand: promote.pl writes this
machine's path there.

**Step 7, skills and PATH.** Show the user each plan (`install-skills.pl plan`, then a bare
`install.pl`) and get their agreement before `apply` and `--confirm`. `install.pl` notices it runs
under Claude Code (`$CLAUDECODE`) and prints guidance for you; follow it. Never replace
`install-skills.pl` with your own `ln -s` loop: on Windows, Git Bash's `ln -s` silently makes a copy,
which would never see a skill update. If `git -C ~/.claude/ccpraxis status --porcelain` prints
anything afterwards, stop and report it. The next promotion would refuse, and the fix is to find
what wrote the file, not to commit it.

**Step 8, marketplaces and plugins.** Slash commands are the user's to type, so tell them what to
run. Compare `global-config/known_marketplaces.json` with `~/.claude/plugins/known_marketplaces.json`
(absent on a Claude Code that never started a session: treat it as empty) and give a
`/plugin marketplace add <owner>/<repo>` line for each marketplace missing locally. Then compare the
`enabledPlugins` in `global-config/settings.json` with `~/.claude/plugins/installed_plugins.json`
and give a `/plugin install <plugin>@<marketplace>` line for each plugin not installed. Marketplaces
first: the plugins install from them.

**Step 9, vault**, only if the user gave URL B:

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/vault-sync.pl init --url "<vault-url>"
```

The init is cwd-agnostic — it clones to a fixed location (`~/.claude/claude-code-vault/`) regardless of where you run it from. If the vault is empty, the init scaffolds `README.md`, `.gitignore` (locks, journal, tmps, machine-local registry), `.gitattributes` (`* -text` to defeat CRLF normalization), and `todos/.gitkeep`, then commits and pushes. It does NOT pre-create `projects/<slug>/` — that lands lazily on first use (a `/steward:setup-project` will materialize it). If the vault is already populated (e.g. from another machine), the clone preserves its contents. Tell the user that `/steward:setup-project`, in a session opened in the dev clone, links it to an earlier machine's slug.

**Step 10, container runtime**, only if the user wants the sandbox. Give them the commands for
their platform and run them only on their explicit go-ahead: `brew install` and
`podman machine init` install software and download a VM image on the host.

**Step 11, restart.** Tell the user to open a new terminal and start a new Claude Code session.
On macOS the PATH lines went to `~/.zshrc`, which a running shell does not re-read; on Windows the
registry `PATH` reaches only processes started afterwards. This session cannot see the new PATH
either, because its Bash tool runs from a snapshot of the shell taken when the session started, so
`command -v claude-sandbox` fails here until a new session. The step's verification commands are
for that new session.
