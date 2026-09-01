# Install protocol for Claude

**This page is written for Claude, not for you.** When you ask Claude to install
ccpraxis, it reads this file and follows the steps below. It is kept separate
from the README so that the human-facing docs do not have to carry machine-facing
instructions — and so this can be edited without touching the front page.

If you are installing by hand, [the README's quick start](../README.md#quick-start)
is the version meant for a person.

## Install protocol for Claude

Claude reads this section during a fresh install to know what to do. When asked to install ccpraxis, follow these steps. Do **not** run npm, pip, or any dev tooling — this is a config-only repo.

**1. Collect the two repo URLs you'll need.**

Before doing anything else, gather both URLs from the user. If the user already supplied them in their install message, use those; otherwise ask, making the distinction explicit:

- **A. Their ccpraxis fork URL** *(required)*. ccpraxis is configuration the user owns and customizes, so they install from their own fork, not the upstream. If they haven't forked yet, ask them to fork `https://github.com/andrecarini/ccpraxis` on GitHub and then give you the URL of their fork. Public or private — their choice; this repo holds no secrets, so privacy is not load-bearing.

- **B. Their private vault repo URL** *(optional but strongly recommended)*. This is a *separate* git repo (typical name: `claude-code-vault`) that holds personal Claude state across machines: todos, persistent plans, and per-project Claude files (CLAUDE.md, project skills, plans, memory). **It MUST be private** — it contains your personal working state and is the kind of data you do not want public. Any git host works (GitHub, GitLab, Gitea, self-hosted). If they don't already have one, tell them to create an empty **private** repo (e.g. `https://github.com/<user>/claude-code-vault`) and then give you the URL. If they decline to set this up now, that's fine — proceed without it; they can run `vault-sync.pl init` later.

Once you have URL A (and optionally URL B), clone ccpraxis:

```bash
git clone <ccpraxis-fork-url> ~/.claude/ccpraxis
```

**2. Link every skill into `~/.claude/skills/`:**

Delegate to the helper — it handles Linux/macOS symlinks AND Windows directory junctions (`mklink /J`) correctly, idempotently. Do NOT roll a `ln -sf` loop yourself: on Windows, Git Bash's `ln -s` silently falls back to a **file copy**, which means the user's `~/.claude/skills/` won't pick up upstream skill updates after a `git pull`.

```bash
perl ~/.claude/ccpraxis/scripts/install-skills.pl plan
# Review the plan with the user, then:
perl ~/.claude/ccpraxis/scripts/install-skills.pl apply
```

The script is idempotent — re-runs converge from any prior state (plain copy, stale symlink, missing). Junctions on Windows need no Developer Mode and no admin privilege.

**3. Back up whatever config the user already has — BEFORE steps 4 and 5 touch it.**

Steps 4 and 5 replace `~/.claude/CLAUDE.md` with a symlink (or merge into it) and copy or key-merge `~/.claude/settings.json`. Both are shown to the user first, but a reviewed diff is not a rollback: once accepted, the file they had is gone. Copy it aside while it still exists.

```bash
perl ~/.claude/ccpraxis/scripts/backup-user-config.pl
```

Idempotent and safe on a fresh machine: a file that does not exist is skipped rather than created, an existing backup is never overwritten, and a `CLAUDE.md` that is already a ccpraxis symlink is left alone rather than archived as though it were the user's own. Report the paths it prints — that is the user's undo, and it is the only one they get, since there is no automated uninstaller.

**4. Handle CLAUDE.md:**

- If `~/.claude/CLAUDE.md` does not exist: symlink it.
  ```bash
  ln -sf ~/.claude/ccpraxis/global-config/CLAUDE.md ~/.claude/CLAUDE.md
  ```
- If it already exists: read both the existing file and the repo's `global-config/CLAUDE.md`. Ask the user (via AskUserQuestion) whether to replace it with a symlink to the repo version or to merge. If merging, incorporate the repo's rules into the existing file and leave it as a regular file.

**5. Handle settings.json:**

- If `~/.claude/settings.json` does not exist: copy the repo version.
  ```bash
  cp ~/.claude/ccpraxis/global-config/settings.json ~/.claude/settings.json
  ```
- If it already exists: run the semantic diff to compare, then present each difference to the user interactively:
  ```bash
  perl ~/.claude/ccpraxis/plugins/steward/scripts/json-diff.pl ~/.claude/settings.json ~/.claude/ccpraxis/global-config/settings.json
  ```
  For each key in `only_right` (in repo but not live) or `diverged` (different values), ask the user whether to adopt the repo value or keep their existing value. Keys in `only_left` (in live but not repo) are the user's own additions — keep them.

After adopting (or copying), substitute `~` in path-valued fields with the user's home directory. Most JSON config consumers in Claude Code don't expand `~`. Specifically the `extraKnownMarketplaces.ccpraxis-local.source.path` field must be a real absolute path for the local ccpraxis plugin marketplace to resolve. Rewrite that field to the on-disk absolute path of `~/.claude/ccpraxis/plugins` on this machine (Windows users can use forward slashes, e.g. `C:/Users/<name>/.claude/ccpraxis/plugins`, since Node accepts both forms).

**6. Add missing marketplaces (must complete before step 7):**

Read `global-config/known_marketplaces.json` (if it exists). Compare against `~/.claude/plugins/known_marketplaces.json` — on a fresh Claude Code install both `installed_plugins.json` and `known_marketplaces.json` are created on first launch, so absence means treat as empty. For each marketplace in the repo but not installed locally, inform the user and offer to add it with `/plugin marketplace add <owner>/<repo>` (for GitHub sources) or the appropriate URL. The marketplaces must land **before** step 7, since step 7 installs plugins **from** these marketplaces.

**7. Install missing plugins (depends on step 6):**

Read the `enabledPlugins` from `global-config/settings.json`. For each plugin, check if it's already installed by reading `~/.claude/plugins/installed_plugins.json` (if it exists). For any plugin not found there, inform the user which plugins are missing and offer to install them. Install with:

```
/plugin install <plugin-name>@<marketplace-name>
```

**8. Wire ccpraxis's host launchers into PATH (`claude-sandbox`, and anything else any plugin ships):**

The install orchestrator is a two-phase Perl script. First run = plan only (prints what would change, exits without touching anything). Re-run with `--confirm` to apply.

```bash
perl ~/.claude/ccpraxis/install.pl
```

Review the plan with the user. The orchestrator detects it's running under Claude Code (via `$CLAUDECODE`) and prints Claude-specific guidance to confirm with the user before continuing. Once the user has agreed:

```bash
perl ~/.claude/ccpraxis/install.pl --confirm
```

The user must restart their terminal (or open a new one) for the PATH/PATHEXT changes to take effect.

Internally the orchestrator runs every `ccpraxis-install.pl` discovered under `plugins/<name>/` and `skills/<name>/`. Each hook is idempotent — re-runs are safe no-ops. On Windows only User-scope `PATH`/`PATHEXT` are touched (no admin required).

**9. Add `upstream` remote for future updates:**

```bash
cd ~/.claude/ccpraxis
git remote add upstream https://github.com/andrecarini/ccpraxis.git
```

**10. (If user provided a vault URL) Initialize the vault repo:**

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/vault-sync.pl init --url "<vault-url>"
```

The init is cwd-agnostic — it clones to a fixed location (`~/.claude/claude-code-vault/`) regardless of where you run it from. If the vault is empty, the init scaffolds `README.md`, `.gitignore` (locks, journal, tmps, machine-local registry), `.gitattributes` (`* -text` to defeat CRLF normalization), and `todos/.gitkeep`, then commits and pushes. It does NOT pre-create `projects/<slug>/` — that lands lazily on first use (a `/steward:setup-project` will materialize it). If the vault is already populated (e.g. from another machine), the clone preserves its contents.

If the user didn't provide a vault URL, skip this step — they can run the init later.

**11. Tell the user to restart Claude Code.**
