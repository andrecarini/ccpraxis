# PRAXIS for Claude Code

A layer you install on top of Claude Code, for engineers running several projects at once.

Each project gets its own container, with its own toolchain, dependencies and configuration, so a malicious package reaches that project and stops there. On top of that sits the machinery to plan work too large for one session, drive it to completion unattended, keep it inside your usage budget, and carry your setup between machines.

[![Perl 5.14+](https://img.shields.io/badge/runtime-Perl%205.14%2B-39457E?logo=perl&logoColor=white)](https://www.perl.org/)
[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20Windows-blue)](#platforms)
[![Install: git clone](https://img.shields.io/badge/install-git%20clone-success)](#quick-start)
[![License](https://img.shields.io/badge/license-Apache%202.0-green)](LICENSE)
[![Stars](https://img.shields.io/github/stars/andrecarini/ccpraxis?style=flat)](https://github.com/andrecarini/ccpraxis/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/andrecarini/ccpraxis)](https://github.com/andrecarini/ccpraxis/commits/main)

---

## Contents

- [Problems it addresses](#problems-it-addresses)
- [Capabilities](#capabilities)
  - [A container per project](#a-container-per-project)
  - [Plans that outlive one session](#plans-that-outlive-one-session)
  - [Finishing without being watched](#finishing-without-being-watched)
  - [Hooks for the mistakes that are not worth repeating](#hooks-for-the-mistakes-that-are-not-worth-repeating)
  - [Your setup, synced across machines](#your-setup-synced-across-machines)
  - [A statusline worth the two lines it costs](#a-statusline-worth-the-two-lines-it-costs)
  - [Choosing when Claude Code updates](#choosing-when-claude-code-updates)
  - [No dependency tree of its own](#no-dependency-tree-of-its-own)
- [On your machine](#on-your-machine)
- [See it](#see-it)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Layout and documentation](#layout-and-documentation)
- [Platforms](#platforms)
- [Compared with alternatives](#compared-with-alternatives)
- [Fork it](#fork-it)

---

## Problems it addresses

| Problem | What ccpraxis does about it |
|---|---|
| **Project dependencies run on your machine.** One `npm install` executes code from hundreds of packages, with your SSH keys and tokens a `postinstall` away. | Runs that project's session in a container instead, if you opt in for that project. Install scripts are disabled for npm and pnpm, and pnpm additionally refuses any package published in the last 7 days. |
| **A long task can lose its thread.** When a session is compacted or restarted, what you decided and why can go with it. | Keeps the plan, the scope of each chunk of work, and the decisions behind them in files on disk, so the next session reads them instead of trying to remember. |
| **An agent can stop early**, reporting a plan or summarising what it would do, then ending the turn with the work unfinished. | An opt-in Stop hook refuses to let the turn end unless something is scheduled to resume the work, or you say you are done. It gives way after three refusals, so it nags rather than traps. |
| **Some commands destroy finished work.** `git stash` and friends discard uncommitted changes, and telling an agent not to run them is not a mechanism. | Hooks refuse a fixed list of those commands before they run. That list is specific and known in advance; this does not make arbitrary rules you write enforceable. |
| **Your setup does not travel.** Instructions, skills and project notes live outside the project repo, so a new machine starts empty. | Syncs your `~/.claude/` against your own fork, and keeps project-scoped files in a private vault repository you create and control. |

---

## Capabilities

### A container per project

`claude-sandbox` starts a project's Claude session inside its own container. That project's toolchain, dependencies and configuration live there and nowhere else, so a package that turns out to be malicious reaches one project and stops. Nothing is shared between projects except a base image.

Everything the agent installs is recorded in a **backpack**: a manifest of tools, runtimes and setup commands that is replayed whenever the container is rebuilt. The agent declares what it needs, and a rebuild returns to that state rather than to a blank image. One base image, a per-project layer on top, and a container you can throw away without losing the setup.

Inside the container, install scripts are disabled for npm and pnpm, and pnpm additionally refuses any package published in the last 7 days. Neither control applies to your host, because nothing installs there.

It is opt-in per project. Without it Claude Code runs on your machine exactly as it does today.

### Plans that outlive one session

`/blueprint:create` turns an objective into a **blueprint**: a plan on disk rather than held in the conversation, split into **packages**, bounded chunks of work, each with a **write set** (the files it may touch), dependencies, and pass/fail criteria specific enough to check mechanically, then audited by an agent that never sat in the conversation that produced it. Each package keeps a **ledger**, an on-disk record of what was decided and why, so a compacted or restarted session picks up from the file instead of from memory that's gone.

**butler** is the plugin that executes a blueprint once it exists. `/butler:dispatch-fleet` runs one unattended, and the packages are what make that parallel. Dependencies between them form a graph, and every package declares the files it may write, so the orchestrator can launch several at once: those whose dependencies are met and whose write sets do not overlap. Two agents never edit the same file, because the plan already established they cannot. Each gets its own Claude session, up to a concurrency cap you set.

The orchestrator itself is a plain script rather than an agent, so watching, launching and relaunching costs no tokens. It notices a session that died and restarts it, and a session that is alive but has stopped producing output, which it kills and restarts cold.

It runs inside the sandbox, which is what makes unattended work practical: permission prompts have nothing to stop, because the blast radius is already the container.

It is also usage-aware, which matters more than it sounds. Rather than driving until your limit is hit and everything stops mid-package, it watches burn rate and pauses at a trip point **below** the ceiling, leaving budget for you. When the window resets it resumes on its own.

`/butler:drive-solo` runs the same execution one package at a time in your own session, on the host or in the sandbox, when you would rather watch.

Not every long task earns a blueprint. When a session is filling up mid-task, `/carry-over` writes the handover for the next one: what the work is, what has been decided and why, which claims are verified and which are assumed, and what to do first. Where something is genuinely unresolved, it asks you. It arrives as a plan, so accepting it clears the context and opens the fresh session already holding that prompt. A `/compact` summarises what happened; this is written to be acted on.

### Finishing without being watched

Arm a session with `/butler:continuity on` and a hook blocks a turn from ending unless something is scheduled to resume the work or you've explicitly disarmed it; reporting a plan without doing the work does not satisfy it. It is a persistent nag rather than an absolute gate: it yields after three consecutive blocks, and you can override it for a single turn with a marker file or for a whole session with an environment variable.

### Hooks for the mistakes that are not worth repeating

Some failures are deterministic: the same command breaks the same thing every time. Those get a hook that refuses the call rather than a line in a document asking nicely.

Installed for every project you open:

- `> NUL` from Bash on Windows, which creates a file Explorer cannot delete
- non-ASCII in a `.ps1`, which PowerShell 5.1 reads as CP1252 so one stray byte becomes a string delimiter and the parse error lands far from the real line
- orphaned processes from ended sessions, swept at session start after one outlived its session by nine days

Scoped to where they apply:

- `git stash`, `reset`, `checkout` and `clean`, refused outright, matched even inside quoted or nested commands. Registered in this repo's own `.claude/settings.json`, so it covers work on ccpraxis; add the same registration to another project to get it there
- direct edits to bug reports and blueprints, which must go through an API that validates them
- inside a blueprint run: write-set containment, ledger freshness, single-writer

This is a fixed list of known failures, not a mechanism for enforcing rules you write.

### Your setup, synced across machines

**steward** is the plugin that looks after ccpraxis itself. Its `/steward:backup` syncs your live `~/.claude/` configuration against this repo, diffing semantically and scanning for secrets before anything is pushed.

Most of what accumulates around a project should not ship with it. Blueprints, todos, session notes and project-specific instructions are yours, not the codebase's, and committing them to a repo other people pull is the wrong answer. They go to a **vault** instead: a private git repository you create and control, synced with three-way merge and a pre-push secret scan, which never deletes a local file it has never held.

`/todo:create` writes a note without derailing what you are doing, and `/todo:resume` picks one back up later. They ride along in the vault, so the note you left on one machine is there on the next. `/steward:setup-project` is what enrols a project: it finds the Claude files worth keeping, proposes a name, and either registers them fresh or links the project back to a slug an earlier machine already pushed, which is how a clone on new hardware gets its notes back.

Two more of steward's commands are worth knowing about. `/steward:usage-audit` reads every transcript on the machine — the host plus each project's sandbox home, nested subagent transcripts included — separates what you spent talking to Claude from what unattended runs spent on your behalf, and prices the total against Anthropic's list rates and several cheaper providers. If a week disappeared, that report says where. And `/steward:ccpraxis-extend` is the single door for changing ccpraxis itself: it works out whether you're asking for something new or a change to something that exists, does the work, and then wires it in — the plugin registration, the settings entry, the skill link. That wiring is the part that's easy to skip by hand, and skipping it leaves a skill sitting on disk that nothing ever loads.

### A statusline worth the two lines it costs

Claude Code gives you a couple of rows at the bottom of the terminal. This puts everything you would otherwise interrupt yourself to check into them:

```text
○ HOST ｜ ccpraxis ｜ ⌥ main ↑3 ↓22 ｜ ⧉ 2  ⋮ 14
Opus 5 200k 59% 118k 82k ｜ 5h 34% 3h 35m｜7d 12% 4d 4h
/c/Development/ccpraxis
```

Reading across: this session is on the **host** rather than in a sandbox, in the `ccpraxis` project, on `main` with 3 commits to push and 22 to pull, with 2 blueprints and 14 todos outstanding. Then the model, a 200k context window at 59% with 118k used and 82k left, and both usage windows: 34% of the 5-hour spent and 3h35m until it resets, 12% of the weekly and 4d4h to go.

The usage figures are the ones that change behaviour. Knowing you are at 34% with three hours to reset is the difference between starting a long run and regretting it.

It collapses to a single row when the terminal is wide enough, drops fields by priority as it narrows, and never lets a truncation cost you the context readout.

### Choosing when Claude Code updates

Claude Code ships often, sometimes several times a day, and an update that breaks your setup arrives on its schedule rather than yours. `/steward:update` puts that back under your control: it reads the changelog for every version newer than yours, weighs release age, checks community issues for the versions in range, and presents the risk before you pick one. It snapshots the current binary first, so an update that goes wrong is one command to undo.

### No dependency tree of its own

All of it is Perl — installer, launcher, orchestrator, statusline, sync logic, the tests — and only modules that ship with the interpreter. No CPAN, no npm, no pip, no build step, no lockfile. Perl is already on macOS and Linux, and Git for Windows carries its own, so on most machines the clone is the install.

That is partly portability and partly the whole argument. Something whose job is to keep other people's package code off your machine should not start by running some of it.

---

## On your machine

Installing clones this repo to `~/.claude/ccpraxis`, symlinks (junctions on Windows) every skill into `~/.claude/skills/`, creates or merges `~/.claude/CLAUDE.md` and `~/.claude/settings.json`, installs the plugins listed there, and puts `claude-sandbox` on your PATH: on Windows via the User-scope `PATH`/`PATHEXT` registry values (no admin needed), on macOS/Linux by appending one line to your shell rc. If given a vault URL it also clones that repo to `~/.claude/claude-code-vault/`. It prints a plan of every change first and only touches your system once you re-run it with `--confirm`.

There's no automated uninstaller. To back out by hand: delete `~/.claude/ccpraxis`, remove the PATH entry (Windows: User Environment Variables in System Properties; macOS/Linux: the appended shell rc line), remove the symlinks/junctions under `~/.claude/skills/`, and restore `~/.claude/CLAUDE.md`/`settings.json` from the backup the install took before it touched them: both are copied to `<file>.pre-ccpraxis.<timestamp>` in `~/.claude/`, and the paths are printed during the install. Your vault repo is untouched either way.

---

## See it

The launcher opens a live dashboard. Real output, 80 columns:

```text
[⣄ running] ccpraxis sandbox · ccpraxis · claude-ccpraxis-8f21ab3
─ Run ──────────────────────────────────────────────────────────────────────────
heartbeat     <1m ago
uptime        3h02m
busy-lease    none (no active run)
keep-awake    released (PC may sleep)
machine       running (podman-machine-default)
podman        imgs 2.8 GB  ctrs 15.0 GB  vols 429.5 MB

─ Resources ────────────────────────────────────────────────────────────────────
snapshot      fresh, <1m old
ctr mem       ━━━━──────  36%    4.0 GB used |   7.1 GB free |  11.2 GB total
ctr cpu       ━━━───────  30%
host ram      ━─────────  10%    2.7 GB used |  24.6 GB free |  27.4 GB total
host disk     ━━━───────  28%   76.6 GB used | 197.0 GB free | 273.6 GB total
host cpu      ━━━━━━━━━─  85%

─ Providers ────────────────────────────────────────────────────────────────────
Claude Code
  access      expires in 7h17m
 the resources sampler has not written a snapshot for 4 minutes  [d] dismiss
 host disk above 90% -- podman image pulls will start failing  [d] dismiss
────────────────────────────────────────────────────────────────────────────────
 [c] launch Claude Code  [s] stop runs  [x] shutdown  [r] reload  [q] quit
```

<!-- SCREENSHOT: the sandbox TUI running in a real terminal -->
<!-- SCREENSHOT: /steward:backup resolving a settings conflict -->

---

## Quick start

**Fork first.** ccpraxis is configuration you'll want to own; forking means your edits are yours and you can still pull upstream.

1. Fork [`andrecarini/ccpraxis`](https://github.com/andrecarini/ccpraxis).
2. *(Recommended)* Create an empty **private** repo for your vault, e.g. `claude-code-vault`.
3. Open Claude Code and say:
   > Install ccpraxis from `https://github.com/<you>/ccpraxis`. My vault repo is
   > `git@github.com:<you>/claude-code-vault.git`.
4. Stay at the terminal for the two confirmation gates (a settings diff, then the install
plan described above), then restart Claude Code.

**Requirements:** Claude Code, Git, and Perl 5.14+ (already present on macOS/Linux and inside Git for Windows), plus Docker or Podman if you want the sandbox. Claude follows [`docs/install-protocol.md`](docs/install-protocol.md) to do the install; that page is the same procedure step by step if you'd rather drive it yourself.

---

## Commands

| Command | Purpose |
|---|---|
| `claude-sandbox` | Launch the container + dashboard (run from a terminal, not inside Claude) |
| `/steward:backup` | Sync config and every registered vault project |
| `/steward:setup-project` | Track this project's Claude files in your vault |
| `/blueprint:create` | Turn an objective into an audited, on-disk plan |
| `/butler:dispatch-fleet` | Execute a blueprint with detached sessions per package (sandbox only) |
| `/butler:drive-solo` | Execute one interactively, on the host or in the sandbox |
| `/butler:continuity on` | Refuse to end a turn with work outstanding |
| `/carry-over` | Hand this session's work to a fresh one |
| `/backpack:add` | Record a tool so container rebuilds restore it |
| `/steward:usage-audit` | Price what you actually consumed, here and in every sandbox |
| `/steward:ccpraxis-extend` | Add to or change ccpraxis, wired in properly |

The rest, including `/todo` and `/almanac`, are listed with every other surface in [`docs/reference.md`](docs/reference.md).

---

## Layout and documentation

Plugins live under `plugins/<name>/` (`sandbox`, `backpack`, `blueprint`, `butler`, `steward`, `todo`, `almanac`); skills under `skills/`; the `CLAUDE.md` and `settings.json` this installs to `~/.claude/` under `global-config/`.

| Page | For |
|---|---|
| [Reference](docs/reference.md) | How each surface works: install contract, commands, statusline, backup, vault sync, sandbox, backpack |
| [Repo layout](docs/repo-layout.md) | Every file, annotated and generated from disk |
| [Design conventions](docs/design-conventions.md) | Packaging, approval flows, and what gets enforced in code |

## Platforms

macOS, Linux, and Windows are all supported; on Windows the launcher is PowerShell and locates Perl itself.

> **Windows: use the WSL2 backend, not Hyper-V.** Microsoft's `Plan9FileServer` silently
> breaks `O_APPEND` and `utimensat`, which fails `claude --resume` and wedges Bun's lock
> manager. The bootstrap refuses `podman + hyperv` outright.

---

## Compared with alternatives

### The sandbox, versus Claude Code's own isolation options

Claude Code ships [several isolation approaches](https://code.claude.com/docs/en/sandbox-environments) that solve a different problem than the sandbox above does. The **[sandboxed Bash tool](https://code.claude.com/docs/en/sandboxing)** is a permission boundary, not an environment: it confines what Bash commands may read, write and reach, but leaves you in whatever environment you're already in, covers only Bash (*"Built-in file tools, MCP servers, and hooks still run directly on your host"*), and has no native Windows support (*"On Windows, run Claude Code inside a WSL2 distribution"*). **[Dev containers](https://code.claude.com/docs/en/devcontainer)** do isolate the full environment, genuinely equivalent to the sandbox above; the difference is what surrounds it:

|  | Dev container | ccpraxis |
|---|---|---|
| Who drives it | an editor that supports the spec | a terminal launcher |
| Rebuilds | edit the Dockerfile, then rebuild | the backpack replays every declared install |
| Auth across rebuilds | *"the container's home directory is discarded on rebuild"* unless you mount a volume yourself | handled by the launcher |
| Supply chain | whatever your image does | install scripts disabled for npm/pnpm; a 7-day minimum package age for pnpm |

[Docker Sandboxes](https://docs.docker.com/ai/sandboxes/) gives each agent a microVM with *"its own Docker daemon, filesystem, and network"*, which is stronger isolation than a container. The catch is what it demands of your machine. It requires **Windows 11** with the Windows Hypervisor Platform enabled, or **macOS Sonoma on Apple silicon**, or **Ubuntu 24.04+** with KVM — and Docker *"does not test or support Docker Sandboxes on Ubuntu derivatives, such as Linux Mint and Pop!\_OS."* Windows 10 is out. Intel Macs are out. Most Linux distributions are out. Inside a VM or VDI you also need nested virtualization, and every sandbox pays a microVM boot of a few seconds.

ccpraxis asks for a container runtime you probably already have, Docker or Podman, auto-detected. That buys weaker isolation than a microVM and much wider reach.

The other difference is what the isolation knows about. Docker Sandboxes is agent-agnostic, so your Claude skills, plugins, credentials, per-project instructions and the state of a half-finished plan are outside its remit, and its documentation does not say whether what an agent installs survives a rebuild. ccpraxis only isolates Claude Code, and in exchange the container knows what it is running: the backpack replays the toolchain, the vault carries the config, and butler can drive work inside it.

Anthropic's own warning about dev containers applies here too: *"dev containers do not prevent a malicious project from exfiltrating anything accessible inside the container, including the Claude Code credentials stored in `~/.claude`."* A container bounds the blast radius; it does not make hostile code safe to run.

### Continuity, versus `/goal`

[`/goal`](https://code.claude.com/docs/en/goal) sets a completion condition and keeps Claude working toward it (*"After each turn, a small fast model checks whether the condition holds"*) and needs no setup. Its check runs after each turn, so it depends on a next turn happening at all, which doesn't help a session wedged on a command with no timeout. Continuity ends only when you disarm it, and for unattended blueprint runs the watchdog sits outside the session entirely: `bp-orchestrator.pl`, a plain script spending no tokens, detects a session that's alive but producing no output and kills and relaunches it rather than waiting for a turn that will never come.

---

## Fork it

ccpraxis is meant to be forked. The rules here are opinions, and yours will differ.

`~/.claude/ccpraxis` is a clone of *your* fork, so changes you make there are yours to commit and push. The install already added `upstream` pointing at this repo, so pulling fixes is:

```bash
git -C ~/.claude/ccpraxis fetch upstream
git -C ~/.claude/ccpraxis merge upstream/main
```

Two things that are easy to get wrong:

**That directory is the code Claude Code is running.** Merging into it changes the tooling underneath a live session, so restart Claude Code afterwards rather than carrying on in the session that was open.

**A merge can bring new surfaces with it.** New skills need linking into `~/.claude/skills/`, new plugins need installing, and settings may have gained keys. Run `perl ~/.claude/ccpraxis/install.pl` to see what a merge changed, re-run it with `--confirm` to apply, then `/steward:backup` to resync config and relink skills. A merge alone leaves new skills present on disk and invisible to Claude.

If you have customised heavily, expect conflicts in `global-config/` and `.claude/settings.json` — those are the files both sides edit.

Once your fork has diverged, `/steward:audit` is the health check before you rely on it: read-only agents go over each plugin for defects and for what an attacker could do with it, check the seams between them, walk the install as a first-time user, and run the test suite. The findings land in a dated report under `.ccpraxis-local-data/audits/`.
