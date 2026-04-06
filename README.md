# Claude Code Config

A custom [Claude Code](https://docs.anthropic.com/en/docs/claude-code) configuration with global instructions, custom slash commands, a rich statusline, config sync tooling, and a Docker sandbox that keeps all development off your host machine.

- **Global instructions** — supply chain security rules, response style, dev tooling restrictions
- **Custom statusline** — model, context usage, token counts, plan rate limits with reset timers
- **Slash commands** — `/backup` (sync + push config), `/create-skill` (create or update skills), `/refresh` (reload instructions), `/sandbox` (containerize a project), `/update` (safe Claude Code updater)
- **Docker sandbox** — isolated containers with full Claude autonomy, blocked install hooks, 7-day package age minimum
- **Config sync** — bidirectional drift detection, AI-assisted conflict merging, secret scanning

## Why the Sandbox

Supply chain attacks in development dependencies are rampant. A single malicious npm `postinstall` hook or pip `setup.py` can steal credentials, SSH keys, browser sessions, and more. This config makes Claude Code refuse to run dev tooling on the host and instead run everything in isolated Docker containers with supply chain protections (blocked install hooks, 7-day minimum package age, non-root user).

## What's Included

```
claude-code-config/
├── global-config/
│   ├── CLAUDE.md                    # Global instructions (supply chain rules, response style)
│   └── settings.json                # Base settings (env, statusline, plugins, effort level)
├── scripts/
│   ├── statusline.pl                # Custom two-line status bar (model, context, rate limits)
│   ├── merge-settings.pl            # Merges repo settings into existing settings.json
│   ├── sync-export.sh               # Detects drift between live config and this repo
│   └── sensitive-check.sh           # Scans for secrets before committing
├── skills/
│   ├── backup/SKILL.md              # /backup       — sync config, scan for secrets, push
│   ├── create-skill/SKILL.md        # /create-skill — create or update a skill
│   ├── refresh/SKILL.md             # /refresh      — reread CLAUDE.md mid-conversation
│   ├── sandbox/SKILL.md             # /sandbox      — set up a project for containerized dev
│   └── update/SKILL.md              # /update       — safe Claude Code updater
└── container-config/
    ├── Dockerfile                   # Docker image: Node 22 + Claude Code CLI + dev tools
    ├── CLAUDE.md                    # Container-specific instructions (full autonomy)
    ├── settings.json                # Container-specific settings
    ├── claude-sandbox.sh            # Launcher script (Linux/macOS)
    └── claude-sandbox.cmd           # Launcher script (Windows)
```

## Installation

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/getting-started) installed
- Git
- Perl 5.14+ (preinstalled on macOS/Linux, included with [Git for Windows](https://gitforwindows.org/))

Optional:
- **Docker** — required for the `/sandbox` containerized development feature

### Setup

Open Claude Code and tell it:

> Install the Claude Code config from `https://github.com/andrecarini/claude-code-config`

Then restart Claude Code.

### Instructions for Claude

When asked to install this repo, follow these steps. Do **not** run npm, pip, or any dev tooling — this is a config-only repo.

**1. Clone the repo:**

```bash
git clone https://github.com/andrecarini/claude-code-config.git ~/.claude/claude-code-config
```

**2. Symlink all skills into `~/.claude/skills/`:**

For each subdirectory in `~/.claude/claude-code-config/skills/`, create a symlink in `~/.claude/skills/` pointing to it. Remove any existing entry first to handle stale copies (e.g. on Windows where `ln -s` falls back to copying). This way new skills are picked up automatically.

```bash
mkdir -p ~/.claude/skills
for skill in ~/.claude/claude-code-config/skills/*/; do
  name="$(basename "$skill")"
  rm -rf ~/.claude/skills/"$name"
  ln -sf "$skill" ~/.claude/skills/"$name"
done
```

**3. Handle CLAUDE.md:**

- If `~/.claude/CLAUDE.md` does not exist: symlink it.
  ```bash
  ln -sf ~/.claude/claude-code-config/global-config/CLAUDE.md ~/.claude/CLAUDE.md
  ```
- If it already exists: read both the existing file and the repo's `global-config/CLAUDE.md`. Ask the user (via AskUserQuestion) whether to replace it with a symlink to the repo version or to merge. If merging, incorporate the repo's rules into the existing file and leave it as a regular file.

**4. Handle settings.json:**

- If `~/.claude/settings.json` does not exist: copy the repo version.
  ```bash
  cp ~/.claude/claude-code-config/global-config/settings.json ~/.claude/settings.json
  ```
- If it already exists: merge using the provided script. This preserves the existing `permissions` block and updates everything else (env, statusline, plugins, effort level) from the repo defaults.
  ```bash
  perl ~/.claude/claude-code-config/scripts/merge-settings.pl ~/.claude/settings.json ~/.claude/claude-code-config/global-config/settings.json > /tmp/merged-settings.json && mv /tmp/merged-settings.json ~/.claude/settings.json
  ```

**5. Install missing plugins:**

Read the `enabledPlugins` from `global-config/settings.json`. For each plugin, check if it's already installed by reading `~/.claude/plugins/installed_plugins.json` (if it exists). For any plugin not found there, inform the user which plugins are missing and offer to install them. Install with:

```
/plugin install <plugin-name>@<marketplace-name>
```

If the marketplace isn't already added, add it first with `/plugin marketplace add`.

**6. Tell the user to restart Claude Code.**

## Features

### Supply Chain Security (CLAUDE.md)

The global `CLAUDE.md` instructs Claude to **never run dev tooling on the host**. This covers npm, pip, cargo, go, dart, flutter, firebase, terraform, and any other SDK or build tool. Claude will refuse and explain why, then offer to set up a Docker sandbox via `/sandbox`.

### Docker Sandbox (`/sandbox`)

The `/sandbox` command prepares any project for containerized Claude Code:

1. Builds the `claude-sandbox` Docker image (if missing)
2. Creates `.claude-data/` for container-side persistence (memories, conversation history)
3. Auto-detects existing git auth (PAT or deploy key) and skips if already configured; only prompts when auth is genuinely missing
4. Adds `claude-sandbox` to PATH
5. Outputs a launch command

Every step is idempotent — running `/sandbox` on an already-configured project just verifies the setup and outputs the launch command.

The container runs `claude --dangerously-skip-permissions` — full autonomy inside the sandbox. The container-specific `CLAUDE.md` tells Claude it can install and run anything, while still enforcing supply chain rules.

### Statusline

Two-line status bar with 24-bit color:

```
my-project | ⌥ main
Opus 4.6 1M  22% |220k 780k| 5h 15%|3h 46m|  7d 12%|4d 22h|
```

**Line 1:** Project name, git branch, ahead/behind counts  
**Line 2:** Model, context %, used/free tokens, plan rate limits with reset timers

- Background `git fetch` every 30 min (non-blocking)
- Plan usage cached 3 min (falls back to stale cache on API errors)
- Wraps to 3 lines if terminal is too narrow
- Requires: curl, git, terminal with 24-bit color (Windows Terminal, iTerm2, WezTerm, Kitty)

### Config Sync (`/backup`)

Bidirectional sync between your live `~/.claude/` config and this repo:

1. Detects drift (identical, live-only, export-only, conflict, settings changes)
2. Merges conflicts with AI assistance and user approval
3. Scans all staged files for secrets (API keys, tokens, credentials, private keys)
4. Commits and pushes (pulls first to avoid conflicts)

### Refresh (`/refresh`)

Re-reads all CLAUDE.md files (global + project) and summarizes key rules. Useful when Claude has drifted from guidelines mid-conversation.

### Update (`/update`)

Safe Claude Code updater that researches releases before installing:

1. Fetches the official changelog and GitHub release dates
2. Calculates release age and risk (< 48h high, 48h–7d medium, > 7d low)
3. Searches GitHub issues for reports of problems with the release
4. Presents a summary with changelog highlights, risk assessment, and community reports
5. Lets you choose: update to latest, pick a safer older version, or stay put

Currently fully implements Windows native install updates. On other platforms, it detects the install method and invokes `/create-skill` to generate the update logic.

## How the Sandbox Works

Each project gets a **persistent Docker container** — installed packages, runtimes, and tools survive between sessions. The container is rebuilt when Claude Code is updated on the host or when the container is older than 7 days.

On every launch, the `claude-sandbox` script:
1. Checks if a container already exists for this project (name stored in `.claude-data/.launcher/container-name`)
2. If it exists, checks for staleness (Claude Code version mismatch or age > 7 days) and offers to rebuild
3. Reattaches to the existing container, or creates a new one

### Mounts

| Mount | Access | What |
|-------|--------|------|
| Your project directory | Read/Write | Code lives at `/project` inside the container |
| `.claude-data/` | Read/Write | Persists memories, conversation history, plans between sessions |
| `.claude-data/.launcher/` | Read-only | Container metadata (version, creation date) — tamper-proof |
| `.credentials.json` | Read-only | Auth tokens from host — container can't modify them |
| `CLAUDE.md`, `settings.json` | Read-only | Container-specific instructions and settings |
| `statusline.pl` | Read-only | Custom statusline |
| Non-host-only skills | Read-only | Skills without `host-only: true` in their frontmatter |

### Skill filtering

Skills with `host-only: true` in their YAML frontmatter are excluded from the container. Currently host-only: `/backup`, `/create-skill`, `/sandbox`, `/update`. Skills like `/refresh` are mounted into the container.

### Security

Inside the container, Claude runs with `--dangerously-skip-permissions` (full autonomy) and can freely install packages, run builds, execute tests. The container itself is the security boundary — if a malicious package runs, it's trapped in the container, not on your machine. Supply chain protections (`npm_config_ignore_scripts=true`, 7-day package age rule) are enforced via environment variables.

## Customization

- **Settings:** Edit `~/.claude/settings.json` for permissions, plugins, and hooks. The repo version is the baseline — `permissions` are always machine-local.
- **Global rules:** Edit `global-config/CLAUDE.md` in the repo (symlinked to `~/.claude/CLAUDE.md`).
- **Container rules:** Edit `container-config/CLAUDE.md` in the repo for in-container behavior.
- **Statusline:** Edit `scripts/statusline.pl` in the repo to customize the status bar output.

## Platforms

Works on Linux, macOS, and Windows (Git Bash / MSYS2). The launcher scripts handle both Unix and Windows environments.
