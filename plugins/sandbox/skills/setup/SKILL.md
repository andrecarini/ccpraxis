---
name: setup
description: Prepare the current project for running Claude Code in an isolated rootless dev container (Docker or Podman — auto-detected). The full setup flow now lives in the `claude-sandbox` launcher's auto-prompt — invoking this command points the user there. Use when the user wants to containerize a project, set up a sandbox, or says "set up a sandbox", "sandbox this project", "containerize this".
user-invocable: true
host-only: true
allowed-tools: Bash
---

# /sandbox:setup

The actual bootstrap (image build, `.ccpraxis-local-data/` creation, git auth, PATH wiring) lives in `~/.claude/ccpraxis/plugins/sandbox/scripts/bootstrap.pl` and is driven by the `claude-sandbox` launcher itself — the launcher detects no `.ccpraxis-local-data/claude-home/` in the project and auto-prompts to bootstrap on the first run.

## What to tell the user

Confirm whether the project already has a sandbox by checking for the per-project state directory:

```bash
test -d .ccpraxis-local-data/claude-home && echo "ALREADY_SET_UP" || echo "NOT_SET_UP"
```

- If `ALREADY_SET_UP`: tell them `.ccpraxis-local-data/claude-home/` already exists; they should just run `claude-sandbox` to launch a session in the existing sandbox. Don't re-run bootstrap.
- If `NOT_SET_UP`: tell them to exit this Claude session and run `claude-sandbox` from a terminal in this project directory. The launcher will detect no sandbox, prompt them to bootstrap, and run the interactive setup (image build + git auth + PATH wiring). Bootstrap ends in manager mode: this terminal shows the sandbox dashboard and keeps the sandbox alive via its heartbeat. To start a claude session, press **`[c]`** in the dashboard, which opens a new window running the session (Windows Terminal on Windows, Terminal.app on macOS). Without that, open a second terminal in the project directory and run `claude-sandbox --session`. A second bare `claude-sandbox` does **not** start a session: with the sandbox already running it opens another dashboard.

The bootstrap is interactive (it prompts for PAT or SSH key choice) and must run in the terminal that owns the controlling tty. Don't try to drive it from inside this Claude session — Claude can't answer the launcher's stdin prompts.
