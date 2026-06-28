# Global Instructions

## Work Quality & Thoroughness

Work like a careful, experienced senior developer. Prioritize correctness and completeness over speed or brevity — conciseness applies to your communication style, not to implementation depth or analysis rigor. Before starting work, make sure you fully understand what is being asked; when requirements are ambiguous or underspecified, ask clarifying questions rather than making assumptions and jumping straight in. Be vigilant about your tendency to hallucinate facts, APIs, function signatures, and file paths — always verify claims against actual code and documentation before stating them, and provide sources when answering factual questions. When fixing a bug or implementing a feature, proactively identify and fix adjacent problems you encounter (broken code, incorrect error handling, missing edge cases) even if they were not explicitly part of the task. Use professional judgment about error handling, abstractions, and code structure — add error handling at real system boundaries, extract helpers when it genuinely reduces maintenance burden, and always consider edge cases. Do not sacrifice thoroughness of your work for the sake of shorter responses.

## Response Style
- Every message must start with 🤖

## Skill Self-Invocation

A skill's `description:` is a trigger contract, not just discovery metadata. When a description says **"Use proactively when…"** and the current turn matches the condition, invoke the skill yourself — don't wait for the user to type `/name`. Treat **"Skip for…"** and **"ALWAYS confirm…"** clauses as binding parts of the same contract. The descriptions re-evaluate every turn, so a skill that wasn't right at turn 3 may be right at turn 12.

Specifically for the beacon system (if the `beacon` plugin is mounted into this sandbox):
- **`/beacon:on`** — light proactively when the session has substantive ongoing work: a plan, multi-file edits, or a multi-step task. Skip for one-off questions, trivial lookups, or single-file quick fixes. Idempotent — re-invoking just refreshes the activity timestamp. Sandbox beacons land in `/project/.ccpraxis-local-data/claude-home/beacons/` (host-visible).
- **`/beacon:off`** — offer when the user signals the session's work is finished ("done", "shipped", "merged", "deployed", "landed", "committed", "PR opened", "let's call it", "wrapping up", "ship it", "lgtm", "all good", "looks good", "finished", "we're good", "that's it for today"). Skip when the signal is scoped to a sub-task ("done with X, now Y"), to thinking/reading ("done reading"), or when substantive work is clearly still in progress. When invoking proactively, ALWAYS ask first via `AskUserQuestion` BEFORE invoking the skill. A direct user invocation (the user typed `/beacon:off`) needs no confirmation — the slash command is the consent.

Specifically for the backpack system (if the `backpack` plugin is mounted into this sandbox):
- After you run a successful install command (`apt-get install`, `npm install -g`, `pnpm add -g`, `yarn global add`, `pip install`, `pip3 install`, `python -m pip install`, `cargo install`), a PostToolUse hook injects an `additionalContext` block on your next turn with one pre-filled `/backpack:add` invocation per detected package. **Decide for each whether it should persist to the next container rebuild.**
  - **Yes (persist)** — replace the `<WHY: …>` placeholder with a real one-line rationale (what's the tool for, why this version, what alternative did you consider) and run the command. Pull the rationale from session context if it's obvious; ask the user if it isn't.
  - **No (throwaway)** — skip. The next time anyone installs the same package, you'll be prompted again. Better to skip and be re-prompted than to pollute the backpack with one-offs.
- The hook is silent for items already in the backpack — re-installing a tracked tool doesn't re-prompt.
- For installs the hook can't parse (`curl … | bash`, custom shell pipelines, archive extraction, `dart pub global activate`, etc.), invoke `/backpack:add` manually with a sensible `--install` and `--verify` pair.
- Other backpack commands:
  - **`/backpack:list`** — show current contents grouped by category.
  - **`/backpack:audit`** — surface items missing a rationale or whose `verify` no longer passes (will reinstall on next rebuild). Run periodically when the user asks "what's stale" or after a busy session of installs.
  - **`/backpack:remove`** — drop a stale entry. Use when the audit flags something or when you've decided a previously-tracked tool is no longer needed.
  - **`/backpack:install`** — manually replay the install pass without rebuilding. Useful after a hand-edit, after `/backpack:add`ing several items, or to recover from a partial install failure.
- The backpack file lives at `~/.claude/backpack.json` (host-bind-mounted, persistent across rebuilds). **Never edit it directly** — always go through the slash commands. The schema is enforced by `~/.claude/backpack.pl validate`.
- On every container creation (incl. rebuild), the launcher prompts the user to install everything in the backpack before handing the shell off to you. If items fail at that pass, the user is told to fix them in-session via `/backpack:add` / `/backpack:remove` / `/backpack:install` — that's your job when they ask.

## ✅ YOU ARE INSIDE A SANDBOXED CONTAINER — FULL AUTONOMY

You are running inside an isolated dev container (Docker or Podman — auto-detected), as root. The project folder is at `/project`.
You have full autonomy. No permission prompts. Go fast.

**You CAN and SHOULD install and run dev tooling directly:**
- ✅ `apt-get install -y …` for system packages and runtimes (Node.js, Python, etc.) — runs as root, no `sudo` needed (and `sudo` isn't installed; the container IS root)
- ✅ `npm install`, `npm ci`, `npx`
- ✅ `dart`, `flutter`, `pub get`
- ✅ `pip install`, `python`, `cargo`, `go build`
- ✅ `firebase`, `gcloud`, `terraform`
- ✅ ANY build tool, linter, formatter, or compiler

There is no host machine to protect — this container IS the sandbox. Under rootless Podman, container root is mapped via Podman's user namespace to the unprivileged host user; under Docker Desktop, a similar isolation boundary applies. Either way, a compromise stays contained even with full in-container root.
Worst case, the container gets recreated. Project files are bind-mounted and git-recoverable.

## ⚠️ SUPPLY CHAIN SECURITY (still applies inside the container)

Even inside a container, supply chain attacks can exfiltrate project source code and credentials. Minimize the attack surface:

- **`npm_config_ignore_scripts=true` is set as an environment variable.** This blocks npm postinstall hooks globally. Do NOT override it with `--ignore-scripts=false` unless explicitly told to by the user. If a package requires postinstall scripts to function, inform the user and let them decide.
- **When installing any package manager**, set its equivalent security protections (e.g. pip `--no-build-isolation` where appropriate).
- **Never pull packages published < 7 days ago** — applies to fresh installs from a lockfile AND when upgrading/adding dependencies to a lockfile. If you notice a dependency was published very recently, flag it.
- **Prefer well-established packages** with many downloads, known maintainers, and active maintenance over obscure alternatives.
- Same caution applies to `pip install`, `cargo install`, `pub get`, etc.

## Git

- Local git operations (add, commit, diff, log, status, branch, etc.) work normally
- **HTTPS push/pull/fetch to GitHub authenticate automatically.** `/sandbox` configures a git credential helper that reads the PAT mounted at `~/.claude/git-pat`. Just run `git push` / `git pull` — no environment setup needed.
  - This works **even though Claude Code's Bash tool strips `GIT_ASKPASS`** from the environment (a credential-exfiltration safeguard added in v2.1.128). Do **not** try to roll your own askpass or re-export `GIT_ASKPASS` — it will be scrubbed and won't help; the credential helper already covers it. The PAT itself is readable at `~/.claude/git-pat` if you need it for `gh`/`curl`.
  - On a `403`, the PAT is simply missing a permission. Name the exact GitHub permission needed so the user can update the token and re-run `/sandbox`.
- For SSH remotes with a deploy key in the project folder, `GIT_SSH_COMMAND` is set for you when the key is present:
  `GIT_SSH_COMMAND="ssh -i /project/deploy_key -o StrictHostKeyChecking=no" git push`

## Network / Ports

Two port ranges are published 1:1 to the host. **Anything you want reachable from the host browser must bind to a port in one of them** — no other ports are forwarded.

- **9010–9019 — published, NOT bridged. Prefer these for dev servers and emulators.** Nothing listens on them at startup, so a server can bind `0.0.0.0:N` directly and it's immediately host-reachable. No socat, nothing to evict. This is the common case — reach for this range first.
- **9000–9009 — published AND socat-bridged.** At container startup a `socat` forwarder is listening on `0.0.0.0:N` for each port here, forwarding to `127.0.0.1:N` (see the OAuth section below for why). Two consequences:
  - Use these when a service binds **loopback** (`127.0.0.1:N`) and needs to be reached from the host — chiefly Claude Code's OAuth callback receiver. The bridge carries the host→loopback hop.
  - A server that binds the **wildcard** `0.0.0.0:N` here will collide with the squatting socat (`EADDRINUSE`, since socat uses `SO_REUSEADDR`, not `SO_REUSEPORT`). You'd have to kill that port's socat first (`pkill -f "TCP-LISTEN:N"`). Avoid the hassle — put wildcard-binding servers on **9010–9019** instead.

### Sharing the URL with the user

When you print the URL for the user to open, prefer `$SANDBOX_HOST_IP` if it's set:

```bash
HOST=${SANDBOX_HOST_IP:-localhost}
echo "Open http://${HOST}:9000"
```

The launcher auto-injects `SANDBOX_HOST_IP` on Windows+Podman, where the host's `localhost:<port>` mirror via WSL2's `wslrelay.exe` is unreliable — it sometimes registers only an IPv6 listener, so IPv4 connects from Firefox/Chrome silently fail even though the container is healthy. The injected value is the WSL distro's directly-reachable IPv4 address and always reaches the published port. On Linux/macOS hosts, or under Docker on any host, the env var is unset and the fallback to `localhost` works as normal.

The env var is captured at container-create time, so if the user runs `wsl --shutdown` or reboots and then re-attaches to an existing sandbox, the value may be stale — a fresh `claude-sandbox` launch (which re-creates if needed) refreshes it.

Example: serve a Flutter web build on port 9000:
```bash
dhttpd --port 9000 --path build/web
```

### OAuth Callbacks for MCP Servers

When an MCP server requires OAuth authentication, Claude Code starts a local callback listener on `127.0.0.1:<port>` and opens the OAuth provider's URL in the host browser. The provider then redirects to `http://localhost:<port>/callback?code=...` — which must reach the listener inside this container.

A `socat` bridge runs at container startup forwarding `0.0.0.0:9000-9009` → `127.0.0.1:9000-9009`. So any OAuth listener Claude Code starts on a port in 9000–9009 receives the callback from the host browser via the Podman port map; listeners on any other port do not.

- **`claude mcp add` (manually-added MCPs)**: pass `--callback-port 9000` (or any port in 9000–9009) to pin the listener onto a bridged port. Example:
  ```bash
  claude mcp add notion --transport http --callback-port 9000 https://mcp.notion.com/mcp
  ```
- **Plugin-installed MCPs**: the callback port is chosen randomly by Claude Code and **cannot be overridden** today. If the random port happens to fall in 9000–9009 the auth flow works; otherwise it times out. Workaround: re-`/auth` until you get a lucky port, or remove the plugin's MCP entry and re-add it manually with `claude mcp add ... --callback-port 9000`.

### Installing plugins

You can install plugins **inside this sandbox** — `claude plugin marketplace add <name>` then `claude plugin install <plugin>@<marketplace>` — and they **persist across relaunches**. They land under `~/.claude/plugins/` (a real RW dir carried in through the `claude-home` bind), separate from the host-selected plugins the launcher copies in. The launcher reconciles the host-tier to your selection each launch but **never touches** plugins you installed in here. Your host's `~/.claude/plugins` is never modified — host plugins are only ever copied *in*. If a plugin ships an MCP server, authenticate it in here per the OAuth notes above (host MCP OAuth is intentionally not propagated).

OAuth tokens authenticated inside this container are written to `~/.claude/.credentials.json` under `mcpOAuth.<key>` and **persist across container rebuilds** — the file is a real file at `<project>/.ccpraxis-local-data/claude-home/.credentials.json` on the host, carried in through the `claude-home` directory bind (NOT a single-file mount). That matters: a single-file bind rejected `rename()` over the mountpoint, so an in-container token refresh (which Claude Code and the butler keeper persist via an atomic temp+rename) could never be saved and the token went stale. As a real file in the directory bind, both your Claude account token refresh AND `mcpOAuth` writes land and persist. The host's own `~/.claude/.credentials.json` is never modified by anything you do in here.

The rest of `<project>/.ccpraxis-local-data/claude-home/.launcher/` (hashes, snapshots, blueprint canonicals, container metadata) is overlaid as RO at `/root/.claude/.launcher/` — you can read it, but writes return EROFS. That's by design: tampering with `backpack-trusted-hash` would bypass approval, and tampering with snapshots would corrupt the launcher's selection logic on next run.

### Accessing Host Services

Services running on the user's host machine (databases, Chrome DevTools, APIs, etc.) are reachable from inside this container via a special hostname. The exact name depends on which container runtime is hosting you:

- **Docker** (Docker Desktop on Windows/macOS, Docker Engine on Linux): `host.docker.internal`
- **Podman** (Podman Desktop / Podman Machine): `host.containers.internal`

For example, a Postgres instance on the host on port 5432:
- Under docker: `host.docker.internal:5432`
- Under podman: `host.containers.internal:5432`

Both names should work transparently on most modern setups (Podman often aliases `host.docker.internal` for compatibility, and Docker sometimes provides `host.containers.internal`), but the canonical name for each runtime is the safer choice. If unsure which runtime is hosting you, try `getent hosts host.docker.internal host.containers.internal` to see which resolves.

Use one of these names instead of `localhost` or `127.0.0.1` when connecting to host services. `localhost` inside the container refers to the container itself, not the host.

## Persistence

- **This container is persistent** — it survives between sessions. Installed packages (apt, npm global, pip global, runtimes) persist across sessions.
- File changes in `/project` persist (bind-mounted to host)
- Your memories, conversation history, and plans persist in `/project/.ccpraxis-local-data/claude-home/`
- Auth tokens: your Claude account token (`claudeAiOauth`) is **seeded as a copy from the host at launch** (manager mode re-seeds it when the container is created/restarted), and thereafter this sandbox refreshes its OWN copy in-session — that refresh now persists to disk with no relaunch (Fix 1). Don't hand-edit it. MCP plugin OAuth tokens (`mcpOAuth.*`) are sandbox-owned, written by the standard `claude` / `claude mcp add` auth flow, and persist across container rebuilds. The host's own `.credentials.json` is never touched. If you ever see a loud "the sandbox's OWN OAuth refresh was REJECTED (4xx) / grants DIVERGED" alert, that's the keeper telling you the copied token was rejected — surface it; it's the signal to revisit the copy-token model, not a routine re-login.
- The container may be rebuilt if it becomes stale (Claude Code version mismatch or > 7 days old, Containerfile changed, etc.). The `backpack` plugin handles re-installing tools/runtimes on rebuild — see above. Project-specific files in `/project` persist across rebuilds via the bind mount.
