---
name: sandbox
description: Prepare a project for running Claude Code in an isolated Docker dev container and build the image if needed
user-invocable: true
host-only: true
allowed-tools: Bash, Read, Write, Edit, Glob, AskUserQuestion
---

Prepare the current project for running Claude Code in a sandboxed Docker container.
Do everything end-to-end — build the image, set up the project, configure git access.
Skip any step that is already done. At the end, output the launch command.

The container-config lives at `~/.claude/claude-code-config/container-config/`.
The container has its own CLAUDE.md and settings.json mounted by the launcher scripts — do NOT ask the user about adding container instructions to the project CLAUDE.md.

## Step 1: Verify container-config exists

```bash
ls "$HOME/.claude/claude-code-config/container-config/Dockerfile" 2>/dev/null && echo "OK" || echo "MISSING"
```

If MISSING, tell the user the container config repo hasn't been set up yet (they need to install it first — see the repo README) and **stop**.

## Step 2: Build Docker image if needed

```bash
docker image inspect claude-sandbox:latest > /dev/null 2>&1 && echo "EXISTS" || echo "MISSING"
```

If MISSING, build it:

```bash
HOST_VERSION="$(claude --version 2>/dev/null | awk '{print $1}')"
docker build --build-arg "CLAUDE_VERSION=$HOST_VERSION" -t "claude-sandbox:$HOST_VERSION" -t "claude-sandbox:latest" "$HOME/.claude/claude-code-config/container-config"
```

## Step 3: Create .claude-data directory

```bash
mkdir -p .claude-data
```

## Step 4: Update .gitignore

Check and add entries as needed. Run all checks in parallel:

```bash
grep -q "\.claude-data" .gitignore 2>/dev/null && echo "CLAUDE_DATA_OK" || echo "CLAUDE_DATA_NEEDS"
grep -q "deploy_key" .gitignore 2>/dev/null && echo "DEPLOY_KEY_OK" || echo "DEPLOY_KEY_NEEDS"
```

Append any missing entries to `.gitignore`. Create the file if it doesn't exist.

## Step 5: Git access setup (auto-detect, minimal questions)

The launcher scripts support two auth methods:
- **PAT via GIT_ASKPASS** (for HTTPS remotes) — files: `.claude-data/git-askpass.sh`, `.claude-data/git-pat`
- **Deploy key via GIT_SSH_COMMAND** (for SSH remotes) — file: `deploy_key` in project root

**Check what's already configured:**

```bash
[ -f .claude-data/git-askpass.sh ] && echo "PAT_AUTH_OK" || echo "NO_PAT"
[ -f deploy_key ] && echo "DEPLOY_KEY_OK" || echo "NO_DEPLOY_KEY"
git remote get-url origin 2>/dev/null || echo "NO_REMOTE"
```

**Decision logic:**
- If `PAT_AUTH_OK` or `DEPLOY_KEY_OK` → git auth is configured, **skip entirely**.
- If no auth is configured and the remote is HTTPS:
  - Check if a global PAT exists at `~/.claude/.claude-data/git-pat` or similar locations.
  - If found, copy it and create the askpass script automatically (no questions).
  - If not found, ask the user via AskUserQuestion for their GitHub fine-grained PAT.
  - Create `.claude-data/git-pat` with the token and `.claude-data/git-askpass.sh`:
    ```bash
    #!/bin/bash
    cat /home/claude/.claude/git-pat
    ```
- If no auth is configured and the remote is SSH:
  - Ask the user via AskUserQuestion whether to generate a new deploy key, provide an existing one, or skip.

## Step 6: Add `claude-sandbox` to PATH (first time only)

```bash
command -v claude-sandbox > /dev/null 2>&1 && echo "ON_PATH" || echo "NOT_ON_PATH"
```

If already on PATH, skip.

If NOT_ON_PATH, detect the OS:

```bash
uname -s 2>/dev/null || echo "Windows"
```

**Linux/macOS:**
```bash
mkdir -p ~/.local/bin
ln -sf ~/.claude/claude-code-config/container-config/claude-sandbox.sh ~/.local/bin/claude-sandbox
chmod +x ~/.claude/claude-code-config/container-config/claude-sandbox.sh
```

**Windows (MINGW/MSYS):**
```bash
cp "$HOME/.claude/claude-code-config/container-config/claude-sandbox.cmd" "$HOME/AppData/Local/Microsoft/WindowsApps/claude-sandbox.cmd"
```

## Step 7: Output the launch command

Output:

> ✅ Project is ready for sandboxed Claude. Exit Claude and run:
>
> `claude-sandbox`
>
> (from this project directory)
>
> Claude will start with full autonomy inside an isolated container.
> Only your project files are accessible. Auth is read-only from your host config.
