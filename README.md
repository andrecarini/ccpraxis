# **PRAXIS for Claude Code**
## **P**rompts, **R**ules, **A**gents, e**X**tensions, **I**ntegrations & **S**kills.

A curated [Claude Code](https://docs.anthropic.com/en/docs/claude-code) configuration: global instructions, custom slash commands, a rich statusline, bidirectional config sync, cross-machine personal-state vault, and a Docker-or-Podman sandbox that keeps all development off your host machine.

- **Global instructions** — supply chain security rules, response style, dev tooling restrictions
- **Custom statusline** — model, context usage, token counts, plan rate limits with reset timers
- **Config sync** (`/steward:backup`) — bidirectional drift detection, AI-assisted conflict merging, secret scanning
- **Vault sync** — a private `claude-code-vault` git repo backs up todos and project-scoped Claude files (CLAUDE.md, skills, blueprints, memory) across machines, with 3-way merge, locking, journaling, atomic staging, and a pre-rename secret scan
- **Docker/Podman sandbox** (`claude-sandbox`) — isolated containers (Docker or Podman, auto-detected) with full Claude autonomy, interactive skill selection, blocked install hooks, 7-day package age minimum
- **Backpack plugin** — per-project declarative manifest of tools/runtimes/setup commands that's replayed on every container rebuild
- **Beacon plugin** — mark sessions as ongoing work and resume them across restarts, terminal crashes, and context switches

**ccpraxis is meant to be forked.** Everything here — skills, settings, instructions — is configuration you'll want to own, tweak, and carry across machines. Fork the repo so your edits live in your own GitHub account, then pull upstream periodically to grab new skills and fixes.

**Why the sandbox.** Supply chain attacks in development dependencies are rampant — a single malicious npm `postinstall` hook or pip `setup.py` can steal credentials, SSH keys, browser sessions, and more. ccpraxis instructs Claude to refuse to run dev tooling on the host and instead run everything in isolated containers (Docker or Podman, auto-detected) with supply chain protections (blocked install hooks, 7-day minimum package age, user-namespace isolation from the host when using rootless Podman).

---

## Instructions

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/getting-started) installed
- Git
- Perl 5.14+ (usually already installed on macOS/Linux; on Windows it's included with [Git for Windows](https://gitforwindows.org/))

Optional:
- **Docker OR Podman** — either runtime works for the `claude-sandbox` containerized development feature. The launcher auto-detects which is installed (prefers Docker if both present).
  - **Docker**: install [Docker Desktop](https://www.docker.com/products/docker-desktop) on macOS/Windows, or Docker Engine on Linux. On Windows, Docker Desktop uses WSL2 by default since 2021 — keep it that way.
  - **Podman**: install [Podman Desktop](https://podman-desktop.io/) on macOS/Windows, or `apt-get install podman` / `dnf install podman` / `brew install podman` on Linux/macOS. On Windows and macOS, after installing run `podman machine init --provider wsl && podman machine start` once.
  - The launcher's first-launch bootstrap (`claude-sandbox` in a project root) prints clear setup guidance if neither runtime is reachable.
  - **⚠ On Windows, DO NOT use the Hyper-V backend** — Microsoft's `Plan9FileServer` silently breaks `O_APPEND` and `utimensat`, which fails `claude --resume` and wedges Bun's lock manager. The bootstrap actively refuses `podman + hyperv`. WSL2 backend only.

> **Note on Perl.** All of ccpraxis's internals — install hooks, the statusline, the launchers, sync logic — are Perl. It's the only language that ships preinstalled on macOS/Linux and inside Git for Windows, which means a fresh `git clone` is enough to run everything; no Node/Python/etc. installs on the host (which is the point — see "Why the sandbox" above). You don't need to know Perl to use ccpraxis; you'd only touch it to customize the internals.

### Installation

**Fork first, then install from your fork.** ccpraxis is configuration you'll want to own and customize — forking means your edits live in *your* repo and you can still pull upstream updates when you want them.

1. **Fork ccpraxis on GitHub** (`https://github.com/andrecarini/ccpraxis`) under your own account. Public or private is up to you — this repo holds no secrets, so the choice is purely about whether you want your customizations visible.
2. **(Optional but strongly recommended) Create a private vault repo for personal backups.** This is a *separate* git repo that holds your todos, persistent plans, beacons, and per-project Claude files (CLAUDE.md, skills, plans, memory) — it stays out of any project repo and syncs your personal state across machines. **It MUST be private** — it carries content you don't want public: project-scoped CLAUDE.md files (which often describe internal architecture, conventions, ongoing initiatives), persistent plan documents (active work-in-progress notes), todo notes (personal reminders), and session memory/labels (which can mention people, paths, decisions in flight). Any git host works (GitHub, GitLab, Gitea, self-hosted); create an empty private repo there, e.g. `https://github.com/<your-user>/claude-code-vault`.
3. Open Claude Code and tell it:

    > Install ccpraxis from `https://github.com/<your-user>/ccpraxis`. My vault repo is `git@github.com:<your-user>/claude-code-vault.git`.

   (You can skip the vault URL if you don't want personal backups yet — set it up later via `perl ~/.claude/ccpraxis/plugins/steward/scripts/vault-sync.pl init --url <repo-url>`.)
4. **Stay at the terminal during install.** Claude will hit two confirmation gates that need your input: a settings-diff prompt (if you already have a `~/.claude/settings.json`) and an install-plan review for PATH changes. Both take a few seconds each.
5. Then restart Claude Code.

After install, `/steward:backup` keeps everything in sync. To track a specific project's Claude files in the vault, `cd` into it and run `/steward:setup-project` (or accept the prompt that `/steward:backup` shows when you're inside an unregistered project with Claude files).

### Daily use

Once installed, here's what you'll actually type day-to-day, grouped by job:

**Syncing your config and personal state across machines.** Run `/steward:backup` from anywhere. It pushes drift between your live `~/.claude/` and the ccpraxis repo, then iterates every registered vault project and syncs them too. If you're inside a project that has Claude files but isn't tracked yet, it offers to register it.

**Adding a new project to your personal vault.** `cd` into the project and run `/steward:setup-project`. The skill picks a slug, lets you confirm which files to track, and does an initial sync. On a fresh machine, the same command surfaces vault-only "orphan" projects so you can link the local directory back to existing vault state.

**Starting work in a new project that needs dev tooling.** Exit Claude, then run `claude-sandbox` from a terminal in the project root. On first launch it walks you through bootstrap interactively (image build, git auth, `.ccpraxis-local-data/` setup) then drops you into a containerized Claude session. From inside an existing Claude session, `/sandbox:setup` does the same check and tells you what to do next — it can't run the bootstrap itself because the prompts need the controlling tty.

**Marking a session to resume later.** Run `/beacon:on [label]`. Claude also self-invokes this when the session has substantive ongoing work (a plan, multi-file edits, a multi-step task). When you're done, `/beacon:off` removes the current session's mark.

**Resuming a beaconed session from anywhere.** Run `claude-beacon` from a terminal on the host. It opens a TUI listing every live beacon sorted by last activity; Enter execs `claude --resume <uuid>` for host sessions or `claude-sandbox --resume-session <uuid> <project>` for sandbox sessions.

**Browsing or cleaning up beacons.** `/beacon:list` renders them as a Markdown table, `/beacon:view <id>` shows one full record, `/beacon:delete <id>` removes any beacon by ID-or-prefix (with confirmation).

**Planning a multi-session initiative.** `/blueprint:create` interrogates the objective and decomposes it into scoped packages — a durable on-disk *blueprint* — then gates it through a fresh-context auditor; `/blueprint:manage` lists, views, audits, archives, or deletes them. The `blueprint` plugin is plan-only. Inside a sandbox, the `butler` plugin executes a blueprint: `/butler:dispatch-fleet` starts a deterministic, token-free orchestrator script (no Claude) that watches, launches, relaunches, and usage-governs detached coordinator agents (one per package, with hook-enforced scope/git/ledger discipline) and auto-resumes across usage/token limits; `/butler:drive-solo` is the host-safe single-session alternative; `/butler:reporter` is the interactive front door you talk to; `/butler:status` reports. Both execute verbs are idempotent start-or-continue (there is no separate resume).

**Capturing a todo.** `/todo:create` saves a note, `/todo:resume` loads one to work on, `/todo:manage` does CRUD. Todos sync via the vault.

**Recording tooling for sandbox rebuild.** Inside a sandbox, when you install a tool/runtime, the agent gets a pre-filled `/backpack:add` invocation from the auto-declare hook — fill in the rationale and run it. `/backpack:list`, `/backpack:remove`, `/backpack:install`, and `/backpack:audit` round out the surface. On the next container rebuild the launcher replays everything in the backpack automatically.

**Driving a browser.** `/launch-chrome-puppet` opens a CDP-controlled Chrome via the included pure-Perl client.

**Extending or changing ccpraxis.** `/steward:ccpraxis-extend` is the single entrypoint — describe what you want and it decides whether to scaffold a new skill/plugin (applying the packaging rule) or change an existing one, then wires it in (related links, settings, marketplace, README, live mirror).

**Updating Claude Code.** `/steward:update` researches releases (changelog, age, GitHub issues) and presents a risk summary before installing the exact version you pick (backing everything up first).

**Re-reading instructions mid-conversation.** `/refresh` re-reads CLAUDE.md (global + project) and summarizes the key rules. Useful when Claude has drifted from guidelines.

### Customizing

- **Settings:** Edit `~/.claude/settings.json` for permissions, plugins, and hooks. The repo version is the baseline — all keys including `permissions` are synced.
- **Global rules:** Edit `global-config/CLAUDE.md` in the repo (symlinked to `~/.claude/CLAUDE.md`).
- **Container rules:** Edit `plugins/sandbox/container/CLAUDE.md` in the repo for in-container behavior.
- **Statusline:** Edit `scripts/statusline.pl` in the repo to customize the status bar output.

For tweaking what `/steward:setup-project` offers by default, see Vault sync in the Reference Manual.

### Staying up to date

Once installed, add this repo as an `upstream` remote so you can pull in new skills and fixes without losing your local customizations:

```bash
cd ~/.claude/ccpraxis
git remote add upstream https://github.com/andrecarini/ccpraxis.git
git fetch upstream
git merge upstream/main   # or: git rebase upstream/main
```

Run `/steward:backup` afterwards to resync your live `~/.claude/` with any settings changes.

---

## Reference Manual

### Repo layout

<!-- BEGIN-FILE-TREE -->
```
ccpraxis/
├── global-config/
│   ├── CLAUDE.md                            # Global instructions (supply chain rules, response style)
│   ├── known_marketplaces.json              # Marketplace selections (synced across machines)
│   └── settings.json                        # Base settings (env, statusline, plugins, effort level)
├── install.pl                               # Top-level setup orchestrator — discovers and runs every surface's ccpraxis-install.pl. Two-phase: bare run = plan only, --confirm = apply.
├── plugins/                                 # Local plugin marketplace ("ccpraxis-local")
│   ├── .claude-plugin/
│   │   └── marketplace.json                 # Lists the plugins below; loaded via extraKnownMarketplaces in settings.json
│   ├── backpack/                            # Backpack plugin — declarative tool/runtime/setup manifest for sandbox containers
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json
│   │   ├── hooks/
│   │   │   └── auto-declare.pl              # PostToolUse hook on Bash — detects install commands and proposes /backpack:add
│   │   ├── scripts/
│   │   │   └── backpack.pl                  # Core helper: validate / list / install / add / remove / audit
│   │   └── skills/
│   │       ├── add/
│   │       │   └── SKILL.md                 # /backpack:add     — register a new item (with rationale)
│   │       ├── audit/
│   │       │   └── SKILL.md                 # /backpack:audit   — surface items missing rationale or whose verify no longer passes
│   │       ├── install/
│   │       │   └── SKILL.md                 # /backpack:install — replay install pass (no container rebuild needed)
│   │       ├── list/
│   │       │   └── SKILL.md                 # /backpack:list    — show contents grouped by category
│   │       └── remove/
│   │           └── SKILL.md                 # /backpack:remove  — drop an item
│   ├── beacon/                              # Beacon plugin — bundles the /beacon:* skills, the UserPromptSubmit completion-nudge hook, the shared beacon scripts, and the claude-beacon host launcher
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json
│   │   ├── bin/                             # User-invoked CLI lives here; shell-native wrappers are required so users can type `claude-beacon` from any terminal.
│   │   │   ├── claude-beacon.ps1            # Thin wrapper (Windows/PowerShell)
│   │   │   └── claude-beacon.sh             # Thin wrapper that execs into claude-beacon.pl (Linux/macOS)
│   │   ├── ccpraxis-install.pl              # Install hook — wires plugins/beacon/bin/ into user PATH (delegates to _install-bin-helper.pl)
│   │   ├── hooks/
│   │   │   ├── completion-nudge.pl          # UserPromptSubmit hook — nudges Claude to offer /beacon:off when the user signals session completion (only if a beacon exists for the current session_id)
│   │   │   └── hooks.json                   # Auto-registers the UserPromptSubmit hook when the plugin is enabled (shell-form command, path via ${CLAUDE_PLUGIN_ROOT}, runs through Git Bash on Windows so `perl` resolves correctly)
│   │   ├── scripts/
│   │   │   ├── beacon.pl                    # Core helper: light/unbeacon/list/get/update-activity/count-{project,global}/sync-vault/scan-sandboxes
│   │   │   ├── claude-beacon.pl             # TUI launcher (logic for `claude-beacon` on the host)
│   │   │   └── test-encoding.pl             # automated encoding test suite for the beacon plugin.
│   │   └── skills/
│   │       ├── delete/
│   │       │   └── SKILL.md                 # /beacon:delete — delete any beacon by id-or-prefix (with confirmation)
│   │       ├── list/
│   │       │   └── SKILL.md                 # /beacon:list   — render every beacon as a Markdown table (read-only)
│   │       ├── off/
│   │       │   └── SKILL.md                 # /beacon:off    — remove the current session's beacon (with confirmation)
│   │       ├── on/
│   │       │   └── SKILL.md                 # /beacon:on     — mark this session as ongoing work
│   │       └── view/
│   │           └── SKILL.md                 # /beacon:view   — show one beacon's full record by id-or-prefix (read-only)
│   ├── blueprint/                           # Authors and manages durable blueprints: /blueprint:create interrogates + decomp…
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json                  # Plugin manifest for blueprint (name, version, description, author).
│   │   ├── agents/
│   │   │   └── bp-auditor.md                # bp-auditor agent - fresh-context completeness auditor; reads only the blueprint files and returns gaps as questions before the blueprint is handed to butler.
│   │   ├── scripts/
│   │   │   ├── bp-init.sh                   # ensure the ccpraxis local data root exists and self-gitignores.
│   │   │   ├── bp-lib.sh                    # shared helpers for the blueprint (authoring) plugin.
│   │   │   └── bp-migrate-plans.pl          # deterministically migrate legacy .claude-plans/*.md
│   │   ├── skills/
│   │   │   ├── authoring-protocol/
│   │   │   │   └── SKILL.md                 # Operating protocol for the blueprint author — the interactive Claude Code ses…
│   │   │   ├── create/
│   │   │   │   └── SKILL.md                 # Create a new blueprint — a durable multi-package initiative with per-package …
│   │   │   ├── manage/
│   │   │   │   └── SKILL.md                 # Manage blueprint lifecycle — list all blueprints with status, view one, re-ru…
│   │   │   └── resume/
│   │   │       └── SKILL.md                 # Resume work on an existing blueprint in THIS interactive session — load its b…
│   │   └── templates/
│   │       ├── blueprint.md                 # Template for a blueprint's top-level file (objective, decisions, package status table, package blocks); instantiated by /blueprint:create.
│   │       └── package-ledger.md            # Template for a per-package ledger; its frontmatter (status/model/max_turns/write_set/test_paths) is the contract butler reads at launch.
│   ├── butler/                              # Executes blueprints: launches detached headless coordinator sessions (one per p…
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json                  # Plugin manifest for butler (name, version, description, author).
│   │   ├── agents/
│   │   │   ├── bp-architect.md              # bp-architect worker (opus) - writes the package spec that tests and implementation build from. Report-only.
│   │   │   ├── bp-implementer.md            # bp-implementer worker - converges code on the immutable tests within the package write_set. Hook-blocked from test files.
│   │   │   ├── bp-redteam.md                # bp-redteam worker (opus) - adversarial pass over the package. Report-only.
│   │   │   ├── bp-reviewer.md               # bp-reviewer worker - spec-conformance and conventions review. Report-only.
│   │   │   ├── bp-scout.md                  # bp-scout worker (haiku) - terrain map with file:line for the package. Report-only.
│   │   │   ├── bp-test-writer.md            # bp-test-writer worker - writes the immutable test oracle from the spec. May only touch the package test_paths.
│   │   │   └── bp-ui-prober.md              # bp-ui-prober worker - finder-based UI scenarios and screenshot reads for packages that touch UI.
│   │   ├── hooks/
│   │   │   ├── gate-stop.sh                 # Stop hook inside coordinator sessions.
│   │   │   ├── guard-bash.sh                # PreToolUse hook for Bash inside coordinator sessions.
│   │   │   ├── guard-writes.sh              # PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
│   │   │   ├── hooks.json                   # Hook registration for butler: PreToolUse (guard-writes/guard-bash/track-dispatch), PostToolUse (log-dispatch), Stop (gate-stop).
│   │   │   ├── lib.sh                       # shared helpers for butler hooks.
│   │   │   ├── log-dispatch.sh              # PostToolUse hook for Task inside coordinator sessions.
│   │   │   └── track-dispatch.sh            # PreToolUse hook for Task inside coordinator sessions.
│   │   ├── scripts/
│   │   │   ├── bp-init.sh                   # ensure the ccpraxis local data root exists and self-gitignores.
│   │   │   ├── bp-launch.sh                 # launch (or resume) a headless coordinator session for one package.
│   │   │   ├── bp-lib.sh                    # butler's copy of the shared base helpers PLUS sandbox-only execution helpers.
│   │   │   ├── bp-resume-sweep.sh           # find interrupted coordinators and resume them economically.
│   │   │   └── bp-status.sh                 # one-line-per-package rollup across blueprints.
│   │   ├── skills/
│   │   │   ├── coordinator-protocol/
│   │   │   │   └── SKILL.md                 # Binding operating protocol for butler coordinators — the headless Claude Code…
│   │   │   ├── launch/
│   │   │   │   └── SKILL.md                 # Launch a blueprint's ready packages as detached headless coordinator sessions a…
│   │   │   ├── orchestrator-protocol/
│   │   │   │   └── SKILL.md                 # Operating protocol for the butler orchestrator (the interactive Claude Code ses…
│   │   │   ├── resume/
│   │   │   │   └── SKILL.md                 # Resume a blueprint after an interruption — session compaction, usage-limit pa…
│   │   │   └── status/
│   │   │       └── SKILL.md                 # Show the state of one or all blueprints — package statuses, live coordinator …
│   │   └── templates/
│   │       └── dispatch-prompt.md           # Coordinator bootstrap-prompt template; bp-launch.sh fills the placeholders and feeds it to the detached claude -p coordinator.
│   ├── sandbox/                             # Sandbox plugin — bundles the claude-sandbox host launcher, the container blueprint, the bootstrap routine, and the /sandbox:setup redirect skill
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json
│   │   ├── bin/                             # User-invoked CLI lives here; shell-native wrappers are required so users can type `claude-sandbox` from any terminal.
│   │   │   ├── claude-sandbox.ps1           # Thin shim — locates Perl + execs launcher.pl (Windows/PowerShell)
│   │   │   └── claude-sandbox.sh            # Thin shim — execs into plugins/sandbox/scripts/launcher.pl (Linux/macOS)
│   │   ├── ccpraxis-install.pl              # Install hook — wires plugins/sandbox/bin/ into user PATH (delegates to _install-bin-helper.pl)
│   │   ├── container/                       # Container blueprint — files that get baked into or mounted into the sandbox container
│   │   │   ├── CLAUDE.md                    # Container-specific instructions (full autonomy)
│   │   │   ├── Containerfile                # OCI container image: Debian bookworm + Claude Code CLI + dev tools (runs as root; works with Docker or rootless Podman)
│   │   │   ├── claude.json                  # Onboarding bypass for containers
│   │   │   └── settings.json                # Container-specific settings
│   │   ├── scripts/
│   │   │   ├── MountSpec.pm
│   │   │   ├── bootstrap.pl                 # First-launch setup invoked by launcher.pl when .ccpraxis-local-data/claude-home is missing. 6 steps: verify container blueprint, build image, mkdir .ccpraxis-local-data/claude-home, self-gitignore via inner .gitignore, git auth (HTTPS PAT / SSH deploy-key), invoke ccpraxis-install.pl. Fully interactive over the launcher's tty.
│   │   │   ├── launcher.pl                  # The actual claude-sandbox launcher: arg parsing, bootstrap detection, lock + dead-PID cleanup, image build, TUI selector orchestration, staleness check, mount assembly, container create-or-reattach. Wrappers in bin/ are tiny shims that exec into this.
│   │   │   ├── select-session.pl            # TUI session picker for the claude-sandbox launcher.
│   │   │   └── skills.pl                    # Discovery/selection backend for the launcher: enumerates custom + plugin skills + plugins + MCP servers, drives the interactive TUI picker, writes selection state and diff reports the launcher consumes.
│   │   ├── skills/
│   │   │   ├── setup/
│   │   │   │   └── SKILL.md                 # /sandbox:setup — confirms .ccpraxis-local-data/claude-home state and tells the user to exit Claude and run `claude-sandbox`
│   │   │   └── test/
│   │   │       └── SKILL.md                 # Run the sandbox plugin's verification suite — proves the bind-mount honors O_…
│   │   └── tests/
│   │       ├── lib/
│   │       │   └── TestSandbox.pm
│   │       ├── manual/
│   │       │   └── longrun-freeze-check.sh  # Long-running empirical test: spins up a container with the current bind-mount architecture, drives claude with periodic keystrokes via socat for 8 minutes, and confirms it stayed alive throughout. Destructive — needs a real container runtime. See file header for usage.
│   │       ├── run-tests.pl                 # Test runner for plugins/sandbox/tests/t/.
│   │       └── t/
│   │           ├── 01-bind-honors-append-and-utimensat.t
│   │           ├── 02-launcher-bind-mount-shape.t
│   │           ├── 03-claude-json-file-bind.t
│   │           ├── 04-runtime-detection.t
│   │           ├── 06-launcher-ro-protection.t
│   │           ├── 07-mountspec-volume-vs-bind.t
│   │           ├── 08-launcher-loads-from-any-cwd.t
│   │           ├── 09-no-stdin-after-podman-start.t
│   │           ├── 10-select-session-empty-dir.t
│   │           ├── 11-select-session-parses.t
│   │           ├── 12-keepalive-heartbeat.t
│   │           ├── 13-install-pass-heartbeat.t
│   │           ├── 18-multi-session-shared-state.t
│   │           ├── 21-select-session-multiple.t
│   │           └── 22-mountspec-edge-cases.t
│   ├── steward/                             # Meta-plugin that maintains ccpraxis and owns its backup, onboarding, and self-e…
│   │   ├── .claude-plugin/
│   │   │   └── plugin.json
│   │   ├── scripts/
│   │   │   ├── ccpraxis-helpers.pl          # Deterministic subcommands for /backup (sync-skills, etc.) — replaces several LLM-driven prose steps with scripted ones; emits JSON the skill consumes
│   │   │   ├── check-plugins.pl             # Detects missing or stale plugins vs settings.json
│   │   │   ├── claude-binary-backup.pl      # Snapshot / list / restore / prune / verify / detect for the Claude Code binary — gives /steward:update a deterministic safety net before any installer runs
│   │   │   ├── filter-diff.pl               # Filters json-diff output through saved preferences
│   │   │   ├── json-diff.pl                 # Semantic JSON diff (--deep-exclude, structured report)
│   │   │   ├── onboard.pl                   # deterministically prepare a project to use the ccpraxis blueprint
│   │   │   ├── save-preference.pl           # Records "remember this divergence" decisions
│   │   │   ├── sensitive-check.pl           # Scans the public ccpraxis repo for secrets before committing
│   │   │   ├── sync-export.pl               # Detects drift between live config and this repo
│   │   │   └── vault-sync.pl                # Central engine for claude-code-vault project backups.
│   │   ├── skills/
│   │   │   ├── audit/
│   │   │   │   └── SKILL.md                 # Audits the ccpraxis repo itself — fans out read-only subagents (per-system re…
│   │   │   ├── backup/
│   │   │   │   └── SKILL.md                 # Syncs everything personal between the live host and your private repos — ccpr…
│   │   │   ├── ccpraxis-extend/
│   │   │   │   └── SKILL.md                 # THE single entrypoint for changing ccpraxis or adding new functionality to it.
│   │   │   ├── setup-project/
│   │   │   │   └── SKILL.md                 # Onboard the current project to the ccpraxis system — create the local data di…
│   │   │   └── update/
│   │   │       └── SKILL.md                 # Safely updates Claude Code by researching releases before installing.
│   │   └── tests/
│   │       ├── lib/
│   │       │   └── StewardTest.pm           # StewardTest — minimal test harness for the steward vault engine.
│   │       ├── run-tests.pl                 # runner for the steward vault test suite.
│   │       └── t/
│   │           ├── 01-encoding.t
│   │           ├── 02-host-memory-roundtrip.t
│   │           ├── 03-second-machine-link.t
│   │           ├── 04-conflict.t
│   │           ├── 05-hard-exclude.t
│   │           ├── 06-refresh-idempotent.t
│   │           └── 07-vault-metadata-rot.t
│   └── todo/                                # Personal todo notes synced to your private vault repo.
│       ├── .claude-plugin/
│       │   └── plugin.json
│       └── skills/
│           ├── create/
│           │   └── SKILL.md                 # /todo:create          — save a todo note
│           ├── manage/
│           │   └── SKILL.md                 # /todo:manage          — list / view / edit / delete / done
│           └── resume/
│               └── SKILL.md                 # /todo:resume          — load a todo and work on it
├── references/
│   ├── extending-ccpraxis.md                # Extension contract — how plugins/skills/standalone surfaces plug into ccpraxis and what each must provide
│   └── skill-writing-guide.md               # Shared skill authoring guide (folder structure, progressive disclosure, writing tips)
├── scripts/                                 # ccpraxis-wide utility scripts (shared across surfaces)
│   ├── _install-bin-helper.pl               # Shared PATH/PATHEXT wiring (idempotent). Branches on $^O. Used by per-surface ccpraxis-install.pl hooks.
│   ├── gen-readme-tree.pl                   # Generates the file-tree section of README.md from disk, using per-module metadata (.about > plugin.json > SKILL.md > script header). --check mode wires into /backup as a pre-flight; --bootstrap is a one-shot for adopting on an existing README.
│   ├── hooks/                               # Host-side PreToolUse hooks installed via global-config/settings.json
│   │   └── block-nul-redirect.pl            # Blocks bash `> nul` redirects on Windows — without this hook, scripts that target /dev/null on Unix create a stray `nul` file in the cwd, polluting the repo
│   ├── install-skills.pl                    # Symlinks (Unix) or junctions (Windows: `mklink /J`) every skills/<name>/ into ~/.claude/skills/. plan/apply modes. Called from the install protocol — handles Windows where `ln -s` silently falls back to a file copy.
│   ├── lint-msys2-guard.pl                  # Pre-flight for /backup: walks every .pl that invokes podman natively and asserts the MSYS2_ARG_CONV_EXCL=* guard is set (the bug it prevents: `;C`-suffixed bind-mount targets on Windows)
│   ├── lint-readme-paths.allow              # Allowlist for lint-readme-paths.pl — backtick contents that look like ccpraxis paths but are intentional non-host paths (e.g. container-internal)
│   ├── lint-readme-paths.pl                 # Pre-flight for /backup: verifies every backtick-quoted ccpraxis path in README.md exists on disk
│   ├── statusline.pl                        # Custom two-line status bar (model, context, rate limits)
│   ├── todo-sync.pl                         # Vault todos: list/create/done/sync (git ops scoped to todos/)
│   ├── update-bootstrap-monitor.pl          # /steward:update support: versioned archive + drift check for upstream bootstrap.ps1
│   ├── update-install.pl                    # /steward:update support: direct-binary install pipeline (detect / manifest / install / verify)
│   └── update-research.pl                   # /steward:update support: fetches GitHub releases + changelog presence + symptom searches against issues
└── skills/
    ├── launch-chrome-puppet/                # /launch-chrome-puppet — CDP browser automation
    │   ├── SKILL.md
    │   └── scripts/
    │       ├── chrome-puppet.pl             # Subcommand dispatcher (launch, navigate, text, etc.)
    │       └── lib/
    │           └── CDPClient.pm             # Pure-Perl WebSocket + CDP client
    └── refresh/
        └── SKILL.md                         # /refresh              — reread CLAUDE.md mid-conversation
```
<!-- END-FILE-TREE -->

### Install contract

Per-surface `ccpraxis-install.pl` hooks let each plugin/skill own its install-time setup (PATH wiring, registry edits, etc.). Each hook is a Perl script; the top-level `install.pl` orchestrator discovers and runs them all in sequence. New plugins drop in their own `ccpraxis-install.pl` and get picked up automatically — no edits to ccpraxis core needed.

The orchestrator is two-phase: a bare run prints the plan and exits without touching anything; re-running with `--confirm` applies it. Each hook is idempotent — re-runs are safe no-ops. On Windows only User-scope `PATH`/`PATHEXT` are touched (no admin required).

### Shell-script policy

`.sh` and `.ps1` files exist only for **commands the user runs directly outside Claude** (`claude-sandbox`, `claude-beacon`). Everything else — install logic, plugin internals, statusline rendering — is Perl. One source of truth for host-side code.

Two deliberate exceptions: the `butler` and `blueprint` plugins each carry a small set of `.sh` scripts (`bp-lib.sh`, `bp-init.sh`, `bp-launch.sh`, `bp-status.sh`, `bp-resume-sweep.sh`, and hook shell scripts). These run **inside the Linux sandbox container**, where Bash is the right tool (POSIX process management, `flock`, `kill`, background jobs). `bp-lib.sh` is intentionally NOT byte-identical across the two plugins — the butler copy is a superset of the blueprint copy, adding sandbox-execution helpers that the blueprint (host-only) side has no need for.

### Slash commands

**Config and sync**
- `/steward:backup` — sync ccpraxis config + every registered vault project (drift detection, AI-assisted conflict merge, secret scan, push). `host-only`.
- `/steward:setup-project` — bootstrap a project for vault backup (orphan discovery, slug pick, initial sync). `host-only`.
- `/refresh` — re-read all CLAUDE.md files and summarize key rules.

**Planning and todos**
- `/blueprint:create` — author a durable multi-package blueprint (interrogate → decompose → auditor gate)
- `/blueprint:manage` — list, view, audit, archive, or delete blueprints (the blueprint plugin is plan-only)
- `/butler:dispatch-fleet` — execute a blueprint as a headless fleet: start the deterministic, token-free orchestrator script that drives detached coordinator agents and auto-resumes across usage/token limits (sandbox-only)
- `/butler:drive-solo` — execute a blueprint in the current interactive session with a flat worker layer (host-safe); `/butler:reporter` observes/relays a run, `/butler:status` reports. Both execute verbs are start-or-continue (no resume verb)
- `/todo:create` — save a todo note
- `/todo:manage` — CRUD for personal todos
- `/todo:resume` — load a todo and work on it

**Extending ccpraxis**
- `/steward:ccpraxis-extend` — single entrypoint to add a new skill/plugin or change an existing one; decides the shape (packaging rule) and wires it in. `host-only`.

**Sandbox**
- `/sandbox:setup` — confirm `.ccpraxis-local-data/claude-home/` state and direct the user to run `claude-sandbox` from a terminal. `host-only`.

**Beacons** (`beacon@ccpraxis-local` plugin)
- `/beacon:on [label]` — mark the current session as ongoing work (idempotent — re-invoking refreshes the activity timestamp)
- `/beacon:off` — remove the current session's mark (Claude asks first only when invoking proactively; direct user invocation needs no confirmation)
- `/beacon:list` — render every visible beacon as a Markdown table (read-only)
- `/beacon:view <id-or-prefix>` — show one beacon's full record (read-only)
- `/beacon:delete <id-or-prefix>` — delete any beacon by ID after confirmation

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
- `claude-beacon` — TUI to resume any beaconed session

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

### /steward:backup flow

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
10. **Syncs vault-root beacons** — commits and pushes `beacons/<uuid>.json` records (ingesting any pending sandbox beacons first), with the same secret-scan defense as project content; see the Beacon plugin below for the lifecycle
11. **Offers registration for the current project** if it has Claude files but isn't tracked yet — `Yes` invokes `/steward:setup-project`, `Not now` defers, `Don't ask again` writes a `.claude/backup-skip` opt-out marker

### Vault sync

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
- Secret-scanning is intentionally **not** applied to the private vault — it's a personal backup, so it stores project/beacon content (CLAUDE.md, blueprints) verbatim. Secret-scanning is the *public* ccpraxis repo's job only (`sensitive-check.pl`, backup Step 4). The vault scan hooks (`scan_files_for_secrets`, the `sensitive_check` journal phase) remain in code but are disabled by policy — re-enable by restoring `scan_files_for_secrets`
- File-modified-during-sync rollback (re-hash before final rename)
- Path safety (no `..`, no absolute paths, no backslashes; symlinks skipped via `File::Find` preprocess)

**Restore on a fresh machine:** clone ccpraxis, run vault init, then `/steward:setup-project` inside a project. The skill calls `list-orphans` first; if a slug already exists in the vault from another machine, it offers to link this directory to it — first sync then pulls all vault content locally.

### Sandbox

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

### Backpack plugin

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

### Beacon plugin

`beacon@ccpraxis-local` marks Claude Code sessions as "ongoing meaningful work" so they can be resumed across restarts, terminal crashes, and context switches. Beacon state lives in the vault (host sessions) or `<project>/.ccpraxis-local-data/claude-home/beacons/` (sandbox sessions, ingested into the vault by a background sync), survives Claude wiping its own session data, and shows up as two counters on the statusline (project-local + global).

The system is packaged as a local Claude Code **plugin**, bundling every skill with the shared scripts at a stable `${CLAUDE_PLUGIN_ROOT}` path. Enable it once via `enabledPlugins` in `~/.claude/settings.json` (already wired in this repo's `global-config/settings.json`). Slash commands all live under the `/beacon:*` namespace; one verb per skill.

**Lifecycle (current session):**
- **`/beacon:on [label]`** — light the current session, optional human-readable label. Idempotent (re-invoking refreshes the activity timestamp). Claude also self-invokes when the session has substantive ongoing work — a plan, multi-file edits, or a multi-step task.
- **`/beacon:off`** — remove the **current session's** mark. Claude offers it when the user signals the session's work is finished ("done", "shipped", "merged", "PR opened", "let's call it", "lgtm", ...) — the plugin's completion-nudge hook (below) surfaces these signals reliably. Skip-signals like "done with that step, now X" or "done reading" are explicitly excluded in the skill's anti-trigger guidance. Confirmation rule: when Claude offers `/beacon:off` proactively, it asks first via `AskUserQuestion`; when the user types `/beacon:off` directly, the slash command is the consent and the skill removes immediately — no second prompt.

**Housekeeping (by session ID, conversational — no TUI):**
- **`/beacon:list`** — render every beacon visible from here as a Markdown table (`#`, scope, slug, label/summary, last active, 8-char session-id prefix), plus a count summary. Read-only.
- **`/beacon:view <id-or-prefix>`** — show one beacon's full record (all 15 fields). Accepts a full UUID or a hex prefix (≥4 chars); halts unambiguously if a prefix matches multiple beacons.
- **`/beacon:delete <id-or-prefix>`** — delete **any** beacon by ID after mandatory `AskUserQuestion` confirmation. Distinct from `/beacon:off`, which only removes the current session's mark. Halts on ambiguous prefix (never guesses).

**Resume (TUI):**
- **`claude-beacon`** — host CLI. Wrappers live in `plugins/beacon/bin/` and the plugin's own `ccpraxis-install.pl` wires that dir into PATH (the install orchestrator picks it up automatically — same pattern as the `claude-sandbox` launcher). Opens a TUI listing every live beacon, sorted by last activity, and on Enter execs `claude --resume <uuid>` (host beacons) or `claude-sandbox --resume-session <uuid> <project>` (sandbox beacons). `u` removes the highlighted beacon inline; `r` re-syncs and reloads; `q`/Esc quits. Non-TTY callers get a numbered-prompt fallback. **Runs on the host**, not inside a sandbox — sandbox beacons are reached by spawning a new `claude-sandbox` session.

**Completion-nudge hook — propose, don't auto-act.** `plugins/beacon/hooks/completion-nudge.pl` is registered as a `UserPromptSubmit` hook via the plugin's `hooks/hooks.json` — auto-enabled on host and (when the user selects the beacon plugin in the claude-sandbox TUI) inside the sandbox; no `settings.json` edit needed on either surface. The registration uses shell form (`"command": "perl \"${CLAUDE_PLUGIN_ROOT}/hooks/completion-nudge.pl\""`) rather than exec form: exec form's libuv-based `uv_spawn` does NOT enumerate PATHEXT on Windows, so a bare `perl` can't resolve to `perl.exe`; shell form runs through Git Bash, which handles the extension correctly. Same pattern as the backpack `auto-declare` hook. On every prompt the user submits, the hook does a cheap word-boundary regex over the prompt text against the completion-signal list documented in `/beacon:off`'s SKILL.md description ("done", "shipped", "merged", "deployed", "landed", "PR opened", "lgtm", "looks good", "let's call it", ...). If no signal is present, the hook exits silently — no subprocess spawn, just the perl cold start + a regex match. If a signal IS present AND a beacon exists for the current `session_id`, the hook shells out to sibling `beacon.pl get` via `IPC::Open3` with stdout/stderr drained (otherwise the script's pretty-printed JSON record would leak into the hook's own stdout and Claude Code would silently misread it as plain-text `additionalContext`) and emits a `hookSpecificOutput.additionalContext` nudging Claude to evaluate sub-task-vs-session completion against the SKILL.md anti-trigger examples and offer `/beacon:off`. The hook **never** calls `beacon.pl unbeacon` itself — the `AskUserQuestion` Claude asks BEFORE invoking `/beacon:off` proactively (per the skill description's "ALWAYS confirm" clause) is what gates removal. Direct user invocation of `/beacon:off` skips that ask since the slash command itself is the consent. Same propose-only design as the backpack `auto-declare` hook: cost of a missed signal is one extra cleanup pass via `claude-beacon` or `/beacon:delete`, so the hook casts wide and Claude does the fine-grained call with full conversation context. Always exits 0 — a hook failure must not block the user's prompt.

**Cross-machine sync:** `/steward:backup` includes vault-root `beacons/` in its push step (`vault-sync.pl sync-beacons` — pre-flight sandbox ingestion, secret scan, commit, push), so beacon state survives across machines just like project content.

### Platforms

The launcher logic and every install hook are written in Perl 5.14+ (see prerequisites). The `.sh` / `.ps1` files under `plugins/*/bin/` are thin shims that locate Perl and exec the corresponding Perl script — they exist only so the user can type `claude-sandbox` / `claude-beacon` directly from their shell.

- **Linux/macOS:** `claude-sandbox.sh` (Bash) execs `plugins/sandbox/scripts/launcher.pl`. No Bash version requirement beyond what comes with any modern distribution.
- **Windows:** `claude-sandbox.ps1` (PowerShell) locates Perl (PATH, Git for Windows, Strawberry, ActiveState) and execs `plugins/sandbox/scripts/launcher.pl`. PATH and `.PS1` PATHEXT wiring is handled by `perl install.pl --confirm` — no manual environment-variable edits required.

### Install protocol for Claude

Claude reads this section during a fresh install to know what to do. When asked to install ccpraxis, follow these steps. Do **not** run npm, pip, or any dev tooling — this is a config-only repo.

**1. Collect the two repo URLs you'll need.**

Before doing anything else, gather both URLs from the user. If the user already supplied them in their install message, use those; otherwise ask, making the distinction explicit:

- **A. Their ccpraxis fork URL** *(required)*. ccpraxis is configuration the user owns and customizes, so they install from their own fork, not the upstream. If they haven't forked yet, ask them to fork `https://github.com/andrecarini/ccpraxis` on GitHub and then give you the URL of their fork. Public or private — their choice; this repo holds no secrets, so privacy is not load-bearing.

- **B. Their private vault repo URL** *(optional but strongly recommended)*. This is a *separate* git repo (typical name: `claude-code-vault`) that holds personal Claude state across machines: todos, persistent plans, beacons, and per-project Claude files (CLAUDE.md, project skills, plans, memory). **It MUST be private** — it contains your personal working state and is the kind of data you do not want public. Any git host works (GitHub, GitLab, Gitea, self-hosted). If they don't already have one, tell them to create an empty **private** repo (e.g. `https://github.com/<user>/claude-code-vault`) and then give you the URL. If they decline to set this up now, that's fine — proceed without it; they can run `vault-sync.pl init` later.

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

**3. Handle CLAUDE.md:**

- If `~/.claude/CLAUDE.md` does not exist: symlink it.
  ```bash
  ln -sf ~/.claude/ccpraxis/global-config/CLAUDE.md ~/.claude/CLAUDE.md
  ```
- If it already exists: read both the existing file and the repo's `global-config/CLAUDE.md`. Ask the user (via AskUserQuestion) whether to replace it with a symlink to the repo version or to merge. If merging, incorporate the repo's rules into the existing file and leave it as a regular file.

**4. Handle settings.json:**

- If `~/.claude/settings.json` does not exist: copy the repo version.
  ```bash
  cp ~/.claude/ccpraxis/global-config/settings.json ~/.claude/settings.json
  ```
- If it already exists: run the semantic diff to compare, then present each difference to the user interactively:
  ```bash
  perl ~/.claude/ccpraxis/plugins/steward/scripts/json-diff.pl ~/.claude/settings.json ~/.claude/ccpraxis/global-config/settings.json
  ```
  For each key in `only_right` (in repo but not live) or `diverged` (different values), ask the user whether to adopt the repo value or keep their existing value. Keys in `only_left` (in live but not repo) are the user's own additions — keep them.

After adopting (or copying), substitute `~` in path-valued fields with the user's home directory. Most JSON config consumers in Claude Code don't expand `~`. Specifically the `extraKnownMarketplaces.ccpraxis-local.source.path` field must be a real absolute path for the local `beacon` plugin marketplace to resolve. Rewrite that field to the on-disk absolute path of `~/.claude/ccpraxis/plugins` on this machine (Windows users can use forward slashes, e.g. `C:/Users/<name>/.claude/ccpraxis/plugins`, since Node accepts both forms).

**5. Add missing marketplaces (must complete before step 6):**

Read `global-config/known_marketplaces.json` (if it exists). Compare against `~/.claude/plugins/known_marketplaces.json` — on a fresh Claude Code install both `installed_plugins.json` and `known_marketplaces.json` are created on first launch, so absence means treat as empty. For each marketplace in the repo but not installed locally, inform the user and offer to add it with `/plugin marketplace add <owner>/<repo>` (for GitHub sources) or the appropriate URL. The marketplaces must land **before** step 6, since step 6 installs plugins **from** these marketplaces.

**6. Install missing plugins (depends on step 5):**

Read the `enabledPlugins` from `global-config/settings.json`. For each plugin, check if it's already installed by reading `~/.claude/plugins/installed_plugins.json` (if it exists). For any plugin not found there, inform the user which plugins are missing and offer to install them. Install with:

```
/plugin install <plugin-name>@<marketplace-name>
```

**7. Wire ccpraxis's host launchers into PATH (`claude-sandbox`, `claude-beacon`, and anything else any plugin ships):**

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

**8. Add `upstream` remote for future updates:**

```bash
cd ~/.claude/ccpraxis
git remote add upstream https://github.com/andrecarini/ccpraxis.git
```

**9. (If user provided a vault URL) Initialize the vault repo:**

```bash
perl ~/.claude/ccpraxis/plugins/steward/scripts/vault-sync.pl init --url "<vault-url>"
```

The init is cwd-agnostic — it clones to a fixed location (`~/.claude/claude-code-vault/`) regardless of where you run it from. If the vault is empty, the init scaffolds `README.md`, `.gitignore` (locks, journal, tmps, machine-local registry), `.gitattributes` (`* -text` to defeat CRLF normalization), and `todos/.gitkeep`, then commits and pushes. It does NOT pre-create `beacons/` or `projects/<slug>/` — those land lazily on first use (a `/beacon:on` will materialize `beacons/`; a `/steward:setup-project` will materialize `projects/<slug>/`). If the vault is already populated (e.g. from another machine), the clone preserves its contents.

If the user didn't provide a vault URL, skip this step — they can run the init later.

**10. Tell the user to restart Claude Code.**
