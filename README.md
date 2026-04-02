# Claude Code Config

Personal [Claude Code](https://docs.anthropic.com/en/docs/claude-code) configuration — global instructions, custom statusline, slash commands, and sync tooling.

## Quick Start

```bash
git clone <this-repo> ~/.claude/claude-code-config
cd ~/.claude/claude-code-config
./install.sh
```

Restart Claude Code to pick up changes.

## What's Included

```
├── CLAUDE.md              # Global instructions (loaded every conversation)
├── settings.json          # Base settings (sanitized — no secrets/permissions)
├── statusline.pl          # Custom two-line status bar
├── skills/
│   ├── refresh/SKILL.md   # /refresh — reread CLAUDE.md mid-conversation
│   └── backup/SKILL.md    # /backup  — sync + commit + push config
├── sync-export.sh         # Detects drift between live config and this repo
├── sensitive-check.sh     # Scans files for secrets before committing
└── install.sh             # Copies files to ~/.claude/
```

## Slash Commands

### `/refresh`

Re-reads all CLAUDE.md files (global + project) and summarizes the key rules. Use when Claude has drifted from guidelines mid-conversation.

### `/backup`

Syncs live `~/.claude/` config into this repo, scans for sensitive data, and pushes:

1. **Detect** — compares live files vs repo, reports identical/conflict/missing
2. **Merge** — AI reads both versions of conflicts, proposes a merge, asks for approval
3. **Scan** — checks all staged files for secrets (API keys, tokens, credentials)
4. **Push** — commits and pushes (pulls first to avoid conflicts)

## Statusline

Two-line status bar with 24-bit color:

```
my-project ｜ ⌥ main
Opus 4.6 1M　22% ｜220k 780k｜ 5h 15%｜3h 46m｜　7d 12%｜4d 22h｜
```

**Line 1:** Project name, git branch, ahead/behind counts (↑↓)
**Line 2:** Model, context window size, usage %, used/free tokens, plan rate limits with reset timers

Features:
- Background `git fetch` every 30 minutes (non-blocking)
- Plan usage cached for 3 minutes (falls back to stale cache on API errors)
- Wraps to 3 lines if terminal is too narrow
- Smart number formatting (`1M` not `1.0M`, `190k`)

## Requirements

- **Perl 5.14+** with core modules only (`JSON::PP`, `Time::Piece`, `File::Basename`)
- **curl** (for plan usage API)
- **git** (for branch info + background fetch)
- Terminal with 24-bit color (Windows Terminal, iTerm2, WezTerm, Kitty)

Works on Linux, macOS, and Windows (Git Bash).

## Global Instructions (CLAUDE.md)

The included `CLAUDE.md` enforces supply chain security:

- **Never run dev tooling on the host** — all SDKs, package managers, and build tools run inside hardened Docker containers
- Containers use non-root users, bridge networking, `ignore-scripts`, and block packages younger than 7 days

## Customization

After installing, edit `~/.claude/settings.json` to add project-specific permissions, plugins, or hooks. The `settings.json` in this repo is a sanitized baseline — it won't overwrite your local one if it already exists.