# Claude Code Config

A custom [Claude Code](https://docs.anthropic.com/en/docs/claude-code) configuration with global instructions, custom slash commands, a rich statusline, config sync tooling, and a Docker sandbox that keeps all development off your host machine.

- **Global instructions** — supply chain security rules, response style, dev tooling restrictions
- **Custom statusline** — model, context usage, token counts, plan rate limits with reset timers
- **Slash commands** — `/backup` (sync + push config), `/create-skill` (create or update skills), `/refresh` (reload instructions), `/sandbox` (containerize a project), `/update` (safe Claude Code updater)
- **Docker sandbox** — isolated containers with full Claude autonomy, interactive skill selection, blocked install hooks, 7-day package age minimum
- **Config sync** — bidirectional drift detection, AI-assisted conflict merging, secret scanning

## Why the Sandbox

Supply chain attacks in development dependencies are rampant. A single malicious npm `postinstall` hook or pip `setup.py` can steal credentials, SSH keys, browser sessions, and more. This config makes Claude Code refuse to run dev tooling on the host and instead run everything in isolated Docker containers with supply chain protections (blocked install hooks, 7-day minimum package age, non-root user).

## What's Included

```
claude-code-config/
├── global-config/
│   ├── CLAUDE.md                    # Global instructions (supply chain rules, response style)
│   ├── known_marketplaces.json      # Marketplace selections (synced across machines)
│   └── settings.json                # Base settings (env, statusline, plugins, effort level)
├── scripts/
│   ├── statusline.pl                # Custom two-line status bar (model, context, rate limits)
│   ├── json-diff.pl                 # Semantic JSON diff (ignores key order, structured report)
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
    ├── Dockerfile                   # Docker image: Debian bookworm + Claude Code CLI + dev tools
    ├── CLAUDE.md                    # Container-specific instructions (full autonomy)
    ├── claude.json                  # Onboarding bypass for containers
    ├── settings.json                # Container-specific settings
    └── bin/
        ├── claude-sandbox.sh        # Launcher script (Linux/macOS)
        └── claude-sandbox.ps1       # Launcher script (Windows/PowerShell)
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

**5. Add missing marketplaces:**

Read `global-config/known_marketplaces.json` (if it exists). Compare against `~/.claude/plugins/known_marketplaces.json` (if it exists). For each marketplace in the repo but not installed locally, inform the user and offer to add it with `/plugin marketplace add <owner>/<repo>` (for GitHub sources) or the appropriate URL.

**6. Install missing plugins:**

Read the `enabledPlugins` from `global-config/settings.json`. For each plugin, check if it's already installed by reading `~/.claude/plugins/installed_plugins.json` (if it exists). For any plugin not found there, inform the user which plugins are missing and offer to install them. Install with:

```
/plugin install <plugin-name>@<marketplace-name>
```

**7. Tell the user to restart Claude Code.**

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
- Wraps to 3 lines if terminal is too narrow
- Requires: git, terminal with 24-bit color (Windows Terminal, iTerm2, WezTerm, Kitty)

### Config Sync (`/backup`)

Bidirectional sync between your live `~/.claude/` config and this repo:

1. Detects drift (identical, live-only, export-only, conflict, settings, marketplace, and container settings changes)
2. Creates timestamped backups of live settings before any modifications
3. Three-way settings sync: live host ↔ global-config ↔ container-config (semantic JSON comparison — ignores key order)
4. Syncs marketplace selections across machines (strips machine-specific paths)
5. Merges conflicts with AI assistance and user approval
6. Scans all staged files for secrets (API keys, tokens, credentials, private keys)
7. Commits and pushes (pulls first to avoid conflicts)

### Refresh (`/refresh`)

Re-reads all CLAUDE.md files (global + project) and summarizes key rules. Useful when Claude has drifted from guidelines mid-conversation.

### Update (`/update`)

Safe Claude Code updater that researches releases before installing:

1. Fetches the official changelog and GitHub release dates
2. Calculates release age and risk (< 48h high, 48h–7d medium, > 7d low)
3. Flags versions without published changelogs
4. Searches GitHub issues for reports of problems with the release
5. Presents a summary with changelog highlights, risk assessment, and community reports
6. Lets you choose: update to latest, pick a safer older version, or stay put
7. Always installs the exact version you selected (version-pinned, never drifts to a newer release)

Currently fully implements Windows native install updates. On other platforms, it detects the install method and invokes `/create-skill` to generate the update logic.

## How the Sandbox Works

Each project gets a **persistent Docker container** — installed packages, runtimes, and tools survive between sessions.

### Lifecycle

On every launch, the `claude-sandbox` launcher script:
1. **First-time setup** — if `.claude-data/` doesn't exist, launches Claude on the host to run `/sandbox` interactively
2. **Image build** — builds the `claude-sandbox` Docker image if it doesn't exist yet
3. **Staleness check** — detects four conditions that may warrant a rebuild:
   - Claude Code version mismatch (host was updated since container was created)
   - Container age > 7 days (base OS packages may be outdated)
   - Dockerfile changed since last build
   - Launcher scripts changed since container was created
4. **Skill selection** — discovers available skills (custom + plugin), presents an interactive picker, saves selections per project (re-prompts only when new skills appear)
5. **Ownership fix** — ensures project files are owned by the container's `claude` user (UID 1000) to avoid permission errors
6. **Create or reattach** — creates a new container or reattaches to an existing one

Container names are deterministic per project path (hash-based), stored in `.claude-data/.launcher/container-name`.

### Mounts

| Mount | Access | What |
|-------|--------|------|
| Project directory | Read/Write | Code lives at `/project` inside the container |
| `.claude-data/` | Read/Write | Persists memories, conversation history, plans between sessions |
| `.claude-data/.claude.json` | Read/Write | Claude settings (onboarding bypass, UI hints) |
| `.claude-data/.launcher/` | Read-only | Container metadata (version, creation date, skill selection) |
| `.credentials.json` | Read-only | Auth tokens from host — container can't modify them |
| `CLAUDE.md`, `settings.json` | Read-only | Container-specific instructions and settings |
| `statusline.pl` | Read-only | Custom statusline script |
| Selected skills | Read-only | Skills chosen via the interactive picker |
| `git-askpass.sh`, `git-pat` | Read-only | PAT-based git auth (if configured) |
| `git-ssh-command.sh` | Read-only | SSH deploy key wrapper (if configured) |

### Interactive Skill Selection

On first launch (or when new skills become available), the launcher presents a picker:

```
Available skills for this sandbox:
  [ ] 1. refresh (custom)
  [ ] 2. frontend-design (plugin:frontend-design)
  [ ] 3. chrome-devtools (plugin:chrome-devtools-mcp)

Toggle by number (comma-separated), 'a' for all, Enter to confirm:
```

- Skills with `host-only: true` in their YAML frontmatter are excluded (e.g. `/backup`, `/create-skill`, `/sandbox`, `/update`)
- Both custom skills and plugin skills are discovered automatically
- Selections are saved per project in `.claude-data/.launcher/selected-skills.json`
- The picker only re-appears when new skills are detected; otherwise it uses the saved selection

### Network

**Ports 9000–9009** are mapped 1:1 to the host. When Claude serves a web app, dev server, or any other network service inside the container, it should bind to one of these ports. The user can then access it at `http://localhost:9000` from the host browser.

**Host access:** The container uses Docker's default bridge network. Services listening on the host machine are reachable from inside the container via `host.docker.internal`. This means:

- A database running on the host (e.g. Postgres on port 5432) is accessible from the container at `host.docker.internal:5432`
- Chrome DevTools debugging on the host can be reached from the container
- Any other host service bound to `0.0.0.0` or `127.0.0.1` is reachable (Docker Desktop on Windows/macOS routes through its VM)

**What the container can NOT access:**

- The host filesystem outside the project directory
- Other projects, `~/.ssh`, browser profiles, password managers
- Host processes (can't read memory, inject code, or kill processes)
- Other Docker containers (unless on the same network)
- USB devices, clipboard, display

Docker does not support fine-grained "allow only port X" rules at the container level. Network access is all-or-nothing: the container either has bridge networking (with full host access via `host.docker.internal`) or `--network none` (no network at all). For projects that don't need network access, the Dockerfile or launcher could be modified to use `--network none`.

### Security

Inside the container, Claude runs with `--dangerously-skip-permissions` (full autonomy) and can freely install packages, run builds, execute tests. The container itself is the security boundary:

**Contained:** If a malicious package runs, it is trapped in the container. It cannot access the host filesystem (beyond the mounted project), steal SSH keys, browser sessions, or credentials from other applications.

**Exposed:** The container can reach host network services (see [Network](#network) above) and has read-only access to Claude API credentials. A compromised container could:
- Modify project files (it has read/write access to `/project`)
- Attempt to attack network services listening on the host
- Read (but not modify) Claude API credentials

**Supply chain hardening:** `npm_config_ignore_scripts=true` is baked into the Docker image to block npm postinstall hooks. The container CLAUDE.md enforces a 7-day minimum package age rule. These protections apply even with full autonomy enabled.

## Customization

- **Settings:** Edit `~/.claude/settings.json` for permissions, plugins, and hooks. The repo version is the baseline — all keys including `permissions` are synced.
- **Global rules:** Edit `global-config/CLAUDE.md` in the repo (symlinked to `~/.claude/CLAUDE.md`).
- **Container rules:** Edit `container-config/CLAUDE.md` in the repo for in-container behavior.
- **Statusline:** Edit `scripts/statusline.pl` in the repo to customize the status bar output.

## Platforms

- **Linux/macOS:** `claude-sandbox.sh` (Bash). Requires Bash 4+ for associative arrays (skill selection).
- **Windows:** `claude-sandbox.ps1` (PowerShell). Invoked directly or via `claude-sandbox` after adding `bin/` to PATH and `.PS1` to PATHEXT.
