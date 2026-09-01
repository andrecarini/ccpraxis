# Reference

The mechanics behind ccpraxis: what each surface does, how the pieces talk to
each other, and the contracts they hold to. Start at the
[README](../README.md) if you want the overview instead.

## Contents

- [Install contract](#install-contract)
- [Shell-script policy](#shell-script-policy)
- [Slash commands](#slash-commands)
- [Statusline](#statusline)
- [/steward:backup flow](#stewardbackup-flow)
- [Vault sync](#vault-sync)
- [Sandbox](#sandbox)
- [Backpack plugin](#backpack-plugin)
- [Platforms](#platforms)

## Install contract

Per-surface `ccpraxis-install.pl` hooks let each plugin/skill own its install-time setup (PATH wiring, registry edits, etc.). Each hook is a Perl script; the top-level `install.pl` orchestrator discovers and runs them all in sequence. New plugins drop in their own `ccpraxis-install.pl` and get picked up automatically — no edits to ccpraxis core needed.

The orchestrator is two-phase: a bare run prints the plan and exits without touching anything; re-running with `--confirm` applies it. Each hook is idempotent — re-runs are safe no-ops. On Windows only User-scope `PATH`/`PATHEXT` are touched (no admin required).

## Shell-script policy

`.sh` and `.ps1` files exist only for **commands the user runs directly outside Claude** (`claude-sandbox`). Everything else — install logic, plugin internals, statusline rendering — is Perl. One source of truth for host-side code.

Two deliberate exceptions: the `butler` and `blueprint` plugins each carry a small set of `.sh` scripts (`bp-lib.sh`, `bp-init.sh`, `bp-launch.sh`, `bp-status.sh`, `bp-resume-sweep.sh`, and hook shell scripts). These run **inside the Linux sandbox container**, where Bash is the right tool (POSIX process management, `flock`, `kill`, background jobs). `bp-lib.sh` is intentionally NOT byte-identical across the two plugins — the butler copy is a superset of the blueprint copy, adding sandbox-execution helpers that the blueprint (host-only) side has no need for.

## Slash commands

**Config and sync**
- `/steward:backup` — sync ccpraxis config + every registered vault project (drift detection, AI-assisted conflict merge, secret scan, push). `host-only`.
- `/steward:setup-project` — bootstrap a project for vault backup (orphan discovery, slug pick, initial sync). `host-only`.
- `/refresh` — re-read all CLAUDE.md files and summarize key rules.

**Planning and todos**
- `/blueprint:create` — author a durable multi-package blueprint (interrogate → decompose → auditor gate)
- `/blueprint:manage` — list, view, audit, archive, or delete blueprints (the blueprint plugin is plan-only)
- `/butler:dispatch-fleet` — execute a blueprint as a headless fleet: start the deterministic, token-free orchestrator script that drives detached coordinator agents and auto-resumes across usage/token limits (sandbox-only)
- `/butler:drive-solo` — drive one blueprint, a named set, or all audited blueprints to done in one interactive session (host or sandbox) as a thin loop over the perl director `bp-drive-next.pl`, with a flat worker layer; `/butler:reporter` observes/relays a run, `/butler:status` reports. Both execute verbs are start-or-continue (no resume verb)
- `/todo:create` — save a todo note
- `/todo:manage` — CRUD for personal todos
- `/todo:resume` — load a todo and work on it

**Extending ccpraxis**
- `/steward:ccpraxis-extend` — single entrypoint to add a new skill/plugin or change an existing one; decides the shape (packaging rule) and wires it in. `host-only`.

**Sandbox**
- `/sandbox:setup` — confirm `.ccpraxis-local-data/claude-home/` state and direct the user to run `claude-sandbox` from a terminal. `host-only`.

**Backpack** (`backpack@ccpraxis-local` plugin; sandbox-only — guarded by the `CLAUDE_SANDBOX=1` env var the launcher injects via `podman create -e`)
- `/backpack:add` — register a new item with a rationale
- `/backpack:remove` — drop an item
- `/backpack:list` — show contents grouped by category
- `/backpack:install` — replay the install pass without a container rebuild
- `/backpack:audit` — surface items missing rationale or whose verify no longer passes

**Browser automation**
- `/launch-chrome-puppet` — CDP browser automation via the included pure-Perl client

**Updater**
- `/steward:update` — safe Claude Code updater (researches releases, backs everything up, then installs the version you pick). `host-only`.

**Host CLIs (not slash commands — typed in a terminal):**
- `claude-sandbox` — launch or reattach to a project's sandbox container

## Statusline

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

## /steward:backup flow

Bidirectional sync between your live `~/.claude/` config and your ccpraxis repo:

1. Detects drift (identical, live-only, export-only, conflict, settings, marketplace, and container settings changes)
2. Creates timestamped backups of live settings before any modifications
3. Three-way settings sync: live host ↔ global-config ↔ plugins/sandbox/container (semantic JSON comparison — ignores key order)
4. Saves user preferences for intentionally-divergent keys so the same questions aren't re-asked across syncs
5. Syncs marketplace selections across machines (strips machine-specific paths)
6. Merges conflicts with AI assistance and user approval
7. Scans all staged files for secrets (API keys, tokens, credentials, private keys)
8. Commits and pushes (pulls first to avoid conflicts)
9. **Iterates every registered vault project** — runs the full sync engine for each (see Vault Sync below), surfacing conflicts interactively
10. **Offers registration for the current project** if it has Claude files but isn't tracked yet — `Yes` invokes `/steward:setup-project`, `Not now` defers, `Don't ask again` writes a `.claude/backup-skip` opt-out marker

## Vault sync

Your private `claude-code-vault` repo holds personal Claude state across machines: todos and project-scoped Claude files. Per-project tracking is opt-in.

**Layout (in the vault repo):**

```
claude-code-vault/
├── todos/                    # personal todo notes
├── projects/<slug>/
│   ├── metadata.json         # slug, file manifest, source notes per machine
│   └── files/                # mirror of tracked files (byte-exact via `* -text`)
├── .registry-local.json      # gitignored: slug → absolute project path on this machine
├── .gitignore
├── .gitattributes
└── README.md
```

**Default tracked-on per project** (confirmed at registration; user can opt out of any):

- `CLAUDE.md` (project root) and `.claude/CLAUDE.md`
- `.claude/skills/`, `.claude/agents/`, `.claude/hooks/`, `.claude/commands/`, `.claude/plans/`
- `<.claude-plans/>` (legacy persistent plans, if any remain in a project)
- `.ccpraxis-local-data/blueprints/` (authored blueprints — see Blueprint plugin; the machine-local `runs/` execution state is hard-excluded)
- `.ccpraxis-local-data/claude-home/projects/-project/memory/` (in-sandbox memory; the path where Claude Code lands memory under the `.ccpraxis-local-data/claude-home:/root/.claude` bind) and `.ccpraxis-local-data/claude-home/plans/` (sandbox state)
- `_host-memory` (synthetic path resolving to `~/.claude/projects/<encoded-project-cwd>/memory/` on each machine — backs up the host-side Claude memory for this project)
- `.ccpraxis-local-data/claude-home/backpack.json` (per-project sandbox backpack — see Backpack plugin)

**Hard-excluded (never offered):** `.claude/settings.local.json`, `.ccpraxis-local-data/claude-home/git-pat`, `.ccpraxis-local-data/claude-home/git-askpass.sh`, `.ccpraxis-local-data/claude-home/git-ssh-command.sh`, `deploy_key`, `.ccpraxis-local-data/blueprints/<name>/runs/`.

To change what's offered by default, edit `@DEFAULT_TRACKABLE` and `%HARD_EXCLUDE_EXACT` / `@HARD_EXCLUDE_PREFIXES` at the top of `plugins/steward/scripts/vault-sync.pl`. Per-project selection is captured at registration time in `<project>/.ccpraxis-local-data/backup-metadata.json → tracked_paths`.

**Sync algorithm (per file):** 3-way comparison using `.ccpraxis-local-data/backup-cache/<path>` as the merge BASE (mirror of last-synced content). Auto-applies one-sided changes (push/pull/cache-only). Conflicts go through `git merge-file --diff3`; the user resolves each via `AskUserQuestion` with **Use local / Use vault / Show diff / Use merged / Abort sync** — no skip, no remember.

**Robustness:**
- Two-level locking (vault `.lock` + per-project `.lock`) with PID+ISO-timestamp and 10-min stale reclaim
- Atomic `.vault-sync.tmp` staging + batch-rename of staged files
- Journal at `<vault>/projects/<slug>/.sync-journal.json` with phases (`staging` → `awaiting_resolution` → `renaming` → `sensitive_check` → `committing`); reconciliation on every sync start so an interrupted sync recovers cleanly
- Secret-scanning is intentionally **not** applied to the private vault — it's a personal backup, so it stores project content (CLAUDE.md, blueprints) verbatim. Secret-scanning is the *public* ccpraxis repo's job only (`sensitive-check.pl`, backup Step 4). The vault scan hooks (`scan_files_for_secrets`, the `sensitive_check` journal phase) remain in code but are disabled by policy — re-enable by restoring `scan_files_for_secrets`
- File-modified-during-sync rollback (re-hash before final rename)
- Path safety (no `..`, no absolute paths, no backslashes; symlinks skipped via `File::Find` preprocess)

**Restore on a fresh machine:** clone ccpraxis, run vault init, then `/steward:setup-project` inside a project. The skill calls `list-orphans` first; if a slug already exists in the vault from another machine, it offers to link this directory to it — first sync then pulls all vault content locally.

## Sandbox

The canonical entry point is the **`claude-sandbox` host launcher**. The global `CLAUDE.md` instructs Claude to never run dev tooling on the host — when a project needs it, Claude offers to set up a sandbox and tells the user to exit the session and run `claude-sandbox` in the project.

**`/sandbox:setup` (from inside Claude) does NOT run any of this.** It's a thin skill that checks for `.ccpraxis-local-data/claude-home/` and, depending on state, tells the user to either (a) exit Claude and run `claude-sandbox` from a terminal, or (b) just run `claude-sandbox` since a sandbox is already configured. The actual bootstrap is interactive (it prompts for PAT or SSH key choice) and must own the controlling tty — Claude can't answer the prompts from inside a session.

**Lifecycle.** Each project gets a **persistent container** (Docker or Podman, auto-detected by the launcher) — installed packages, runtimes, and tools survive between sessions. On every launch, `plugins/sandbox/scripts/launcher.pl`:

1. **First-time bootstrap** — if `.ccpraxis-local-data/claude-home/` doesn't exist, prompts `Set up a new sandbox for this project? [Y/n]` and on confirm runs `plugins/sandbox/scripts/bootstrap.pl` (deterministic, perl-driven; no Claude session involved). The bootstrap verifies `plugins/sandbox/container/`, confirms Docker or Podman is reachable (and prints platform-specific install guidance if not), builds the image if missing, creates `.ccpraxis-local-data/claude-home/` (self-gitignored via an inner `.gitignore = *`), sets up git auth interactively (HTTPS → PAT, SSH → deploy key; skipped if `git-askpass.sh` or `deploy_key` is already present), and runs the PATH install hook. After it returns, the launcher continues with the rest of the flow in the same invocation.
2. **Image build** — builds the `claude-sandbox` image if it doesn't exist yet (no-op when bootstrap already built it).
3. **Skill selection** — on every manager-mode launch, discovers available skills (custom + plugin) and plugins/MCPs, and presents an interactive arrow-keys+space TUI picker (`skills.pl select-interactive`). Selections are saved per project; if nothing changed since last launch the TUI is still shown but the previous selection is pre-loaded.
4. **Staleness check** — detects conditions that may warrant a rebuild:
   - Claude Code version mismatch (host was updated since container was created)
   - Container age > 7 days (base OS packages may be outdated)
   - Containerfile changed since last build
   - Launcher scripts changed since container was created
   - Container-blueprint CLAUDE.md or settings.json drift since last sandbox refresh (plugins/sandbox/container/)
   - Skill / plugin / plugin-path drift since the container was created
5. **Create or reattach** — creates a new container (with the full skill, plugin, MCP, credential, and git-auth mount set) or reattaches to an existing one. On fresh creation, if `.ccpraxis-local-data/claude-home/backpack.json` exists, the launcher prompts to run the backpack install pass before handing off to Claude.

Container names are deterministic per project path (hash-based), stored in `.ccpraxis-local-data/claude-home/.launcher/container-name`.

The container runs `claude --dangerously-skip-permissions` as root — full autonomy inside the sandbox. With rootless Podman, container root is mapped to the unprivileged host user via the kernel's user namespace, so files written to `/project` come out owned by the host user (no chown dance) and a container escape lands as the unprivileged host user, not host root. Docker Desktop uses a similar VM-isolation model on Windows/macOS. The container-specific `CLAUDE.md` tells Claude it can install and run anything, while still enforcing supply chain rules.

**Mounts:**

| Mount | Access | What |
|-------|--------|------|
| Project directory | Read/Write | Code lives at `/project` inside the container |
| `.ccpraxis-local-data/claude-home/` → `/root/.claude/` | Read/Write | Persists memories, conversation history, plans between sessions (bulk bind) |
| `.ccpraxis-local-data/claude-home/.claude.json` → `/root/.claude.json` | Read/Write | Claude settings (onboarding bypass, UI hints) — single-file bind outside `/root/.claude/` |
| `.ccpraxis-local-data/claude-home/.launcher/` → `/root/.claude/.launcher/` | Read-only | Launcher-managed metadata (hashes, snapshots, blueprint canonicals, container-name) — overlaid RO on top of the bulk bind |
| `.ccpraxis-local-data/claude-home/.launcher/.credentials.json` → `/root/.claude/.credentials.json` | Read/Write | Auth tokens; container writes here so `mcpOAuth.*` tokens persist across rebuilds — single-file RW bind over the RO `.launcher/` overlay |
| `CLAUDE.md`, `settings.json` | Read/Write | Blueprint copies in `.ccpraxis-local-data/claude-home/.launcher/` (written on first create; RW via the bulk bind above); the container can freely modify them — drift from upstream is detected via stored hash |
| `statusline.pl` | Read-only | Custom statusline script (from the ccpraxis repo, not `.ccpraxis-local-data/claude-home/`) |
| Selected skills | Read-only | Skills chosen via the interactive picker |
| `git-askpass.sh`, `git-pat` | Read-only | PAT-based git auth (if configured) |
| `git-ssh-command.sh` | Read-only | SSH deploy key wrapper (if configured) |

**Interactive skill selection.** On every manager-mode launch, the launcher presents an arrow-keys+space TUI picker (`skills.pl select-interactive`). Navigate with arrow keys, toggle with Space, confirm with Enter:

```
Available skills for this sandbox:
  [x] refresh (custom)
  [ ] frontend-design (plugin:frontend-design@ccpraxis-local)
  [ ] chrome-devtools (plugin:chrome-devtools-mcp)
```

- Skills with `host-only: true` in their YAML frontmatter are excluded (e.g. `/steward:backup`, `/steward:ccpraxis-extend`, `/sandbox:setup`, `/steward:update`)
- Both custom skills and plugin skills (and MCP servers) are discovered automatically
- Selections are saved per project in `.ccpraxis-local-data/claude-home/.launcher/selected-skills.json` and pre-loaded on the next launch

**Network.** Two ranges are mapped 1:1 to the host. **9010–9019** are published but not bridged — bind `0.0.0.0:N` directly for dev servers/emulators (the common case; nothing squats them). **9000–9009** are published *and* socat-bridged (`0.0.0.0:N → 127.0.0.1:N`) so loopback-bound listeners like Claude Code's OAuth callback receiver are reachable from the host; a wildcard-binding server here collides with the bridge and must evict it first. The user accesses either range at `http://localhost:N` from the host browser.

The container uses the runtime's default networking. Services listening on the host machine are reachable from inside the container via `host.docker.internal` (Docker) or `host.containers.internal` (Podman). Both route through the runtime's WSL2 VM on Windows or Linux VM on macOS. This means:

- A database running on the host (e.g. Postgres on port 5432) is accessible from the container at `host.containers.internal:5432`
- Chrome DevTools debugging on the host can be reached from the container
- Any other host service bound to `0.0.0.0` or `127.0.0.1` is reachable

**What the container can NOT access:**

- The host filesystem outside the project directory
- Other projects, `~/.ssh`, browser profiles, password managers
- Host processes (can't read memory, inject code, or kill processes)
- Other containers (unless on the same network)
- USB devices, clipboard, display

Container runtimes do not support fine-grained "allow only port X" rules at the container level. Network access is all-or-nothing: the container either has bridge networking (with full host access via `host.containers.internal` / `host.docker.internal`) or `--network none` (no network at all). For projects that don't need network access, the Containerfile or launcher could be modified to use `--network none`.

**Security.** Inside the container, Claude runs with `--dangerously-skip-permissions` (full autonomy) and can freely install packages, run builds, execute tests. The container itself is the security boundary:

- **Contained:** If a malicious package runs, it is trapped in the container. It cannot access the host filesystem (beyond the mounted project), steal SSH keys, browser sessions, or credentials from other applications. With rootless Podman, container root is mapped via the kernel's user namespace to the unprivileged host user, so even an in-container privilege escalation lands as the regular host user — never actual host root — if it ever escapes. Docker Desktop provides equivalent isolation via its VM boundary.
- **Exposed:** The container can reach host network services (see Network above) and has read/write access to `.credentials.json` (needed for `mcpOAuth.*` token writes). A compromised container could modify project files (it has read/write access to `/project`), attempt to attack network services listening on the host, and read or write Claude API credentials — but writing here affects only in-container MCP OAuth tokens, not the host user's primary API key (which is passed via environment variable, not credentials file).
- **Supply chain hardening:** `npm_config_ignore_scripts=true` is baked into the container image to block npm postinstall hooks. The container CLAUDE.md enforces a 7-day minimum package age rule. These protections apply even with full autonomy enabled.

## Backpack plugin

`backpack@ccpraxis-local` gives every sandbox project a declarative record of what tools, runtimes, and project-setup commands it needs — so on every container rebuild, the inside-sandbox environment is restored automatically without the agent reinstalling everything from scratch.

**Where it lives.** `<project>/.ccpraxis-local-data/claude-home/backpack.json` on the host. Inside the sandbox container, that's `~/.claude/backpack.json` (which is `/root/.claude/backpack.json` — `.ccpraxis-local-data/claude-home/` is bind-mounted at `/root/.claude/`). Per-project, host-side, durable across container destruction. Cross-machine sync via vault-sync's `@DEFAULT_TRACKABLE` (added in a follow-up patch); the sibling `.ccpraxis-local-data/claude-home/.launcher/backpack-trusted-hash` is intentionally *not* tracked so a new machine hits the loud first-time warning on the next rebuild.

**Schema (v2).** Validated by `backpack.pl validate`. Top-level:

- `version` (integer == 2)
- `items` (array)

Each item:
- **Required strings:** `category`, `name`, `install`, `verify`
- **Optional strings:** `rationale` (free-text "why is this in the backpack?"), `added` (ISO date, auto-set on first add)

> There is **no per-item `version` field** — pin a version inside the `install` command itself (`apt-get install -y jq=1.6`, `npm install -g prettier@3.2.5`), which is the single source of truth; the `verify` command (`X --version`) reflects the live version. A separate stored field duplicated that pin and could silently drift, so it was removed. Existing files that still carry a per-item `version` are tolerated (it's stripped on read and dropped on the next write); `add --version` is rejected with a pointer to install-pinning.

Uniqueness key: `(category, name)`. `add` on an existing key updates in place; updating without `--rationale` preserves the prior rationale (don't blow away context). Allowed categories (warnings on unknown, not errors): `apt`, `npm-global`, `pip`, `cargo`, `gem`, `go-install`, `curl-script`, `snap`, `project-setup`, `other`. v1 files are rejected with a one-line migration message ("rename `tools` to `items`, bump `version` to 2").

The `project-setup` category handles project-level setup commands (e.g. `npm ci --ignore-scripts`) whose `verify` checks whether the work is materialized (e.g. `test -d /project/node_modules`) — one unified `items[]` covers both tool installs and setup steps.

**Auto-declare hook — propose, don't auto-add.** `plugins/backpack/hooks/auto-declare.pl` is registered as a `PostToolUse` hook on the Bash tool inside the sandbox (via `plugins/sandbox/container/settings.json`). It parses executed commands for install patterns:

- `apt-get install -y X [Y…]` / `apt install …`
- `npm install -g X[@v]` / `npm i -g …`
- `pnpm add -g …`
- `yarn global add …`
- `pip install X[==v]` / `pip3 install …` / `python -m pip install …` (skipped when `-r`/`-e`/`-c`/`--requirement` points at a file)
- `cargo install X[@v]` (also `--version V X`)
- Leading `sudo` is stripped per-segment (sandbox runs as root, so `sudo` isn't installed; the strip is defensive parsing for the case where an agent prepends it out of habit)
- Compound commands (`A && B`) are split on `&&`/`;`/`||`; each segment is matched independently

The hook **does not write to backpack.json**. It detects install-shape commands, filters out items already in the backpack, and emits a `hookSpecificOutput.additionalContext` block with pre-filled `/backpack:add` invocations and `<WHY>` placeholders for the rationale. Claude decides per-item whether to commit (replacing `<WHY>` with a real one-line reason) or skip (one-off install). If skipped, no pollution lands; if the agent installs the same thing again later, they get re-prompted. The retry cost is near-zero, the pollution problem (one-off `apt-get install -y jq` to inspect a JSON, then never needed again) is structurally avoided. A safe-name regex `^[\@a-zA-Z0-9][a-zA-Z0-9._/+\-]*$` rejects parsed tokens that don't look like real package names. The hook always exits 0 — failures must not disrupt Claude.

**Trust-hash defense.** `.ccpraxis-local-data/claude-home/.launcher/backpack-trusted-hash` (host-side, `:ro`-mounted into the container so it's tamper-evident) defends against two attack scenarios: a backpack.json supplied by a third-party project clone, or one overwritten by a compromised in-container agent. Both would otherwise run `install`/`verify` commands as root on the next launcher pass. On every launch:

- **No stored hash** → loud "FIRST TIME — may have shipped with the project" warning, prompt defaults to `[y/N]`
- **Stored but mismatched** → soft "changed since last approval" notice, default `[Y/n]` (legitimate in-session adds)
- **Matched** → trusted, normal flow

The hash is written only on user approval.

**Launcher integration.** On every container create (fresh first-time setup OR rebuild), if `<project>/.ccpraxis-local-data/claude-home/backpack.json` exists, the launcher:

1. Validates the schema with `backpack.pl validate` (bails cleanly to the exec hand-off if the schema is bad)
2. Shows the contents with `backpack.pl list`
3. Prompts: `Install backpack items now? [Y/n/select]:` (with trust-hash logic above)
4. On confirm: `apt-get update` once, then `backpack.pl install` against `/root/.claude/backpack.json` (the base Containerfile clears `/var/lib/apt/lists/*`, so apt installs would otherwise fail on first run)
5. Failures don't abort: shows them, hands off to Claude anyway, lets the agent fix in-session

The install pass runs after `release_lock`. In manager mode the launcher then enters the heartbeat loop (it never `exec`s into claude directly — a second terminal's `claude-sandbox` handles the actual session attach). So a second-terminal launcher arriving during the install prompt can safely fast-path attach to the running container once the manager signals readiness.

**Slash commands** — all sandbox-only, guarded by `[ -n "$CLAUDE_SANDBOX" ]` (the launcher injects `CLAUDE_SANDBOX=1` via `podman create -e`):

- `/backpack:add` — register a new item (with rationale)
- `/backpack:remove` — drop an item
- `/backpack:list` — show contents grouped by category
- `/backpack:install` — replay install pass (no container rebuild needed)
- `/backpack:audit` — surface items missing rationale or whose `verify` no longer passes

## Platforms

The launcher logic and every install hook are written in Perl 5.14+ (see prerequisites). The `.sh` / `.ps1` files under `plugins/*/bin/` are thin shims that locate Perl and exec the corresponding Perl script — they exist only so the user can type `claude-sandbox` directly from their shell.

- **Linux/macOS:** `claude-sandbox.sh` (Bash) execs `plugins/sandbox/scripts/launcher.pl`. No Bash version requirement beyond what comes with any modern distribution.
- **Windows:** `claude-sandbox.ps1` (PowerShell) locates Perl (PATH, Git for Windows, Strawberry, ActiveState) and execs `plugins/sandbox/scripts/launcher.pl`. PATH and `.PS1` PATHEXT wiring is handled by `perl install.pl --confirm` — no manual environment-variable edits required.
