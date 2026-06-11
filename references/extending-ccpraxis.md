# Extending ccpraxis

How to add new functionality to a ccpraxis install — as a plugin, a standalone skill, or (rarely) a standalone surface — and the contract each extension is expected to follow.

For writing the Markdown body of a skill itself (frontmatter, prose, substitutions), see `skill-writing-guide.md`. This guide is about how skills, plugins, and other surfaces *plug into ccpraxis* — not how to write the skill content.

---

## Repo map

```
ccpraxis/
├── install.pl                       # Top-level install orchestrator
├── scripts/                         # ccpraxis-wide utility scripts (shared across surfaces)
│   ├── _install-bin-helper.pl       # Shared "add a bin/ to PATH" logic
│   ├── statusline.pl
│   ├── vault-sync.pl
│   ├── todo-sync.pl
│   └── update-{research,install,bootstrap-monitor}.pl
├── plugins/                         # Local plugin marketplace
│   ├── .claude-plugin/marketplace.json
│   ├── sandbox/                     # claude-sandbox launcher + container blueprint + /sandbox:setup
│   ├── beacon/                      # claude-beacon launcher + /beacon:* skills + completion-nudge hook
│   ├── backpack/                    # /backpack:* skills + auto-declare hook
│   └── <plugin-name>/...            # New plugins drop in here
├── skills/                          # ccpraxis-managed standalone skills
│   └── <skill-name>/...
├── global-config/                   # Repo-side baseline of ~/.claude/{CLAUDE.md, settings.json}
├── references/                      # Authoring guides (this file lives here)
└── ...
```

Three places an extension can live:

- **Plugin** — `plugins/<name>/`. Discoverable via the local marketplace; loaded by Claude Code's plugin loader. Bundles skills + scripts + bin + container blueprints + install hook under one `enabledPlugins` entry. This is the default for almost everything new — the sandbox itself is a plugin (`plugins/sandbox/`).
- **Skill** — `skills/<name>/`. A ccpraxis-managed standalone skill, not owned by a plugin. Used when the skill is genuinely cross-cutting (e.g. `/backup` operates across every other surface).
- **Standalone surface** — a top-level dir at the repo root (sibling of `plugins/`, `skills/`, etc.). Reserved for things tightly coupled to ccpraxis that don't fit the plugin/skill mold. None currently exist — the Podman sandbox used to be one (`container-config/`) before being absorbed into `plugins/sandbox/`. Prefer "make it a plugin" unless you have a specific reason not to.

Each of these can optionally ship a `ccpraxis-install.pl` install hook.

---

## The install pattern

Setup runs as a Perl pipeline:

```
install.pl  (orchestrator at repo root)
   │  discovers and runs every ccpraxis-install.pl,
   │  passing "plan" by default or "apply" with --confirm
   ▼
<surface>/ccpraxis-install.pl  (per-surface hook)
   │  most just delegate to the shared helper with the surface's bin/ dir
   ▼
scripts/_install-bin-helper.pl  (shared logic for the common case)
```

Two-phase by design. Bare `perl install.pl` previews every change and exits without touching anything. `perl install.pl --confirm` applies the plan. This gives Claude room to summarize the diff to the user and get explicit consent before mutating system state.

The orchestrator detects whether it's being run under Claude Code (via `$ENV{CLAUDECODE}`) and prints a tailored "what to do next" guidance block accordingly:

- **Under Claude**: instructions to review the plan with the user and ask for explicit consent.
- **Run by a human**: instructions to inspect any unfamiliar hook before continuing.

### Discovery rules

The orchestrator looks in exactly two places:

1. `plugins/*/ccpraxis-install.pl` (glob)
2. `skills/*/ccpraxis-install.pl` (glob)

A new plugin or skill that drops a `ccpraxis-install.pl` in its dir is picked up automatically — no edits to ccpraxis core required.

A new standalone surface (a sibling of `plugins/`, `skills/`, etc.) does require adding it to an explicit list in `install.pl`. This is intentional friction: a new top-level dir is a bigger architectural change than a plugin and should be reviewed deliberately rather than auto-discovered. At time of writing no standalone surfaces exist.

---

## The `ccpraxis-install.pl` contract

A hook is a Perl script that follows seven rules.

**1. First positional arg is `plan` or `apply`.** Default to `plan` if none given.

**2. In `plan` mode**: print every change the hook *would* make to the user's environment, one per line. Make NO side effects — no file writes, no registry edits, no network calls that mutate anything. Exit 0.

**3. In `apply` mode**: make the changes. Print what was done in the same format as `plan` so the orchestrator's output stays consistent. Be idempotent: re-running on already-applied state must be a no-op that prints "already" rather than re-applying. Exit 0 on success, non-zero only on a true failure.

**4. Stay in User scope on Windows.** No admin-required registry edits, no Machine-scope PATH/PATHEXT writes. If you genuinely need admin, refuse and exit with a clear error explaining why.

**5. Be cross-platform.** Branch on `$^O`. Treat `MSWin32`, `cygwin`, and `msys` as Windows (Git Bash's Perl reports `cygwin` even though the host is real Windows). Everything else is Unix-ish. If you only support one platform, detect the other and exit with a clear "not supported" message — never silently succeed.

**6. No shell metacharacter interpretation.** Use Perl's list-form `system`, `exec`, and `IPC::Open3`. Never `qx//`, `system "string"`, or backticks with user-influenced data. For PowerShell on Windows, base64-encode values before passing them in to dodge console-codepage and quoting issues entirely.

**7. Print descriptive output the orchestrator can pass through.** Convention: `  KEY: human description` (two-space indent, colon-separated). For example:

```
  PATH: would prepend C:\foo\bin to user PATH
  PATHEXT: .PS1 already present
```

The two-space indent makes hook output visually nest under the orchestrator's numbered hook list.

---

## The shared install helper

For the very common case "add a `bin/` to PATH (and ensure `.PS1` in PATHEXT on Windows)", use `scripts/_install-bin-helper.pl`:

```bash
perl scripts/_install-bin-helper.pl <plan|apply> <abs-bindir>
```

It handles:

- **Linux/macOS**: `chmod +x` for `*.sh` files in the bindir; create extensionless symlinks (so `claude-foo` works alongside `claude-foo.sh`); append `export PATH="$HOME/<bindir-rel>:$PATH"` to the user's shell rc (picks `.zshrc` if zsh, else `.bashrc`, else `.profile`).
- **Windows**: prepend the dir to `HKCU\Environment\Path`; if `.PS1` is missing from `HKCU\Environment\PATHEXT`, add it (seeded from the Machine PATHEXT so the user doesn't accidentally narrow what runs).

Idempotent. Two-phase (`plan`/`apply`). Uses base64-encoded values when talking to `powershell.exe` so usernames with non-ASCII characters round-trip correctly through the console codepage.

Most per-surface hooks are 5-line delegations to this helper.

---

## Extension types

### Plugin

A plugin lives at `plugins/<name>/`, gets registered in `plugins/.claude-plugin/marketplace.json`, and is enabled via `enabledPlugins` in settings.json.

**Minimal layout:**

```
plugins/myplugin/
└── .claude-plugin/
    └── plugin.json
```

**`plugin.json`:**

```json
{
  "name": "myplugin",
  "version": "0.1.0",
  "description": "What it does in one sentence.",
  "author": {"name": "Your name or org"}
}
```

**Register in the local marketplace** — `plugins/.claude-plugin/marketplace.json`:

```json
{
  "name": "ccpraxis-local",
  "plugins": [
    ...,
    {"name": "myplugin", "source": "./myplugin", "description": "..."}
  ]
}
```

**Enable** — add `"myplugin@ccpraxis-local": true` to `enabledPlugins` in both `~/.claude/settings.json` and the repo's `global-config/settings.json`.

**Optional subdirs:**

- `scripts/` — internal helper scripts. Use Perl by convention; matches the rest of the repo.
- `skills/<skill-name>/SKILL.md` — skills the plugin contributes. They surface as `/<plugin>:<skill>` in Claude Code's slash menu (e.g. `/beacon:on`). The slash-command body references shared scripts two equivalent ways, both of which resolve correctly **inside a bash code block**:
  - **`${CLAUDE_PLUGIN_ROOT}/scripts/foo.pl`** — `CLAUDE_PLUGIN_ROOT` is a shell environment variable Claude Code sets to the plugin root when a plugin skill runs; bash expands it at execution time. Depth-independent (doesn't care how deeply the skill is nested), so it's the form steward/butler/blueprint use, and the preferred form for new plugin skills.
  - **`${CLAUDE_SKILL_DIR}/../../scripts/foo.pl`** — `CLAUDE_SKILL_DIR` (and `${CLAUDE_SESSION_ID}`) are Claude Code *template substitutions*, replaced in SKILL.md content before it runs; the relative `../../` climbs from the skill dir to the plugin root. Used by beacon/backpack.

  The distinction only bites outside a bash block: in plain prose (no shell to expand env vars) only the template substitutions resolve, so reference a path in prose with `${CLAUDE_SKILL_DIR}`, not `${CLAUDE_PLUGIN_ROOT}`.
- `bin/` — user-invocable CLI wrappers. Shell-native (`.sh` + `.ps1`). Tiny shims that exec into Perl logic in `scripts/`.
- `ccpraxis-install.pl` — only if the plugin needs install-time work (most often: wire `bin/` into PATH).

### Skill (standalone)

A skill lives at `skills/<name>/`. (Plugin-contributed skills live inside their plugin's `skills/`.)

**Minimal:**

```
skills/myskill/
└── SKILL.md
```

See `skill-writing-guide.md` for frontmatter and body conventions.

**Optional:**

- `scripts/` — helper scripts the skill body invokes. Reference them with `${CLAUDE_SKILL_DIR}/scripts/foo.pl`.
- `ccpraxis-install.pl` — only if the skill needs system setup (e.g. it ships a CLI binary that should land on PATH).

### Standalone surface

A top-level directory at the repo root (sibling of `plugins/`, `skills/`, etc.). For things tightly coupled to ccpraxis that don't fit the plugin or skill model. **None currently exist**: the Podman sandbox used to be one (`container-config/`) before being folded into `plugins/sandbox/`. Default to making things plugins unless you have a concrete reason not to — the plugin/marketplace/skill story is what Claude Code itself understands natively.

If you do add one, edit `install.pl` to add the explicit path to the discovery list. There's no glob for standalone surfaces.

---

## Shell-script policy

`.sh` and `.ps1` files exist only for **commands the user runs directly outside Claude** — e.g. `claude-sandbox`, `claude-beacon`. Everything else (install hooks, internal helpers, plugin logic, statusline rendering) is Perl. One source of truth, no cross-shell duplication.

**Why we still need the wrappers for user CLIs:** the user types `claude-foo` in their shell; the shell needs to find an executable. Linux honors shebangs on extensionless scripts; Windows doesn't natively run `.pl` files without a registry `ftype`/`assoc` setup that IS gated by admin. Two tiny shims is cheaper than every alternative.

**Wrapper pattern:**

```bash
#!/bin/bash
# claude-foo — thin wrapper that execs into claude-foo.pl
exec perl "$HOME/.claude/ccpraxis/plugins/foo/scripts/claude-foo.pl" "$@"
```

For the PowerShell counterpart, see `plugins/beacon/bin/claude-beacon.ps1` — it includes a `Get-PerlPath` fallback that finds Perl in Git for Windows, Strawberry, or ActiveState when it's not on the bare PowerShell PATH.

---

## Conventions

- **Naming**: kebab-case for everything user-facing — plugin names, skill slugs, file names.
- **Idempotency**: every install hook must be safe to re-run any number of times. Detect "already done" state and short-circuit.
- **Cross-platform Perl**: branch on `$^O`. Treat `MSWin32`, `cygwin`, and `msys` as Windows.
- **No admin**: hooks operate in User scope only. PATH/PATHEXT edits go to `HKCU\Environment`, not Machine.
- **No silent failure**: if a hook can't do its job on the current platform/state, print a clear error and exit non-zero. Don't half-succeed.
- **Byte-mode stdout**: `binmode STDOUT, ':raw'` in install scripts. Paths from Git Bash arrive as UTF-8 bytes; a `:utf8` layer would double-encode them.

---

## Trust model

ccpraxis treats the operator (you) as trusted. The orchestrator does NOT sandbox per-surface install hooks — they run as your normal user, with whatever permissions Perl + powershell.exe have. A hostile hook *could* do anything Perl can do (modify your shell rc, write to the registry under HKCU, read your home dir).

The intended defense is the two-phase plan/apply flow: `perl install.pl` shows you (and Claude) every change before any side effect. If you ship third-party plugins into your `plugins/` tree, **read their `ccpraxis-install.pl` before `--confirm`** — it's a small Perl file, you can audit it in seconds.

Beyond install hooks: any Perl in `plugins/*/scripts/` or `skills/*/scripts/` runs whenever the relevant feature is used. The trust surface is "everything in this repo," not "just install hooks." If you don't trust the upstream, fork and audit before pulling.

---

## Worked example: adding a new plugin with a CLI on PATH

Imagine a plugin `flux` that ships a host CLI `claude-flux`.

**1. Create the tree:**

```
plugins/flux/
├── .claude-plugin/plugin.json
├── ccpraxis-install.pl
├── scripts/
│   ├── flux.pl                # plugin's internal helper
│   └── claude-flux.pl         # CLI logic (TUI, dispatcher, whatever)
├── bin/
│   ├── claude-flux.sh
│   └── claude-flux.ps1
└── skills/
    └── default/SKILL.md       # surfaces as /flux:default
```

**2. `plugin.json`:**

```json
{"name": "flux", "version": "0.1.0", "description": "..."}
```

**3. `ccpraxis-install.pl`** (5-line delegation):

```perl
#!/usr/bin/env perl
use strict; use warnings; use FindBin qw($Bin);
my $mode = $ARGV[0] // 'plan';
exec $^X, "$Bin/../../scripts/_install-bin-helper.pl", $mode, "$Bin/bin"
    or die "exec helper failed: $!\n";
```

**4. `bin/claude-flux.sh`:**

```bash
#!/bin/bash
exec perl "$HOME/.claude/ccpraxis/plugins/flux/scripts/claude-flux.pl" "$@"
```

**5. `bin/claude-flux.ps1`** — mirror `plugins/beacon/bin/claude-beacon.ps1` (Perl locator + `& $PerlExe $Script @args`).

**6. Register the plugin** in `plugins/.claude-plugin/marketplace.json` and enable it in `settings.json` under `enabledPlugins`.

**7. Run `perl install.pl`** — orchestrator discovers the new hook, plans the PATH edit; `--confirm` applies.

That's the whole loop. No edits to `install.pl`. No edits to anything in ccpraxis core. The plugin is self-contained.

---

## When the contract doesn't fit

If your install work is something other than "add a bin/ to PATH" (e.g. a config file write, an external service call, a registry edit beyond PATH/PATHEXT), write the logic directly in your `ccpraxis-install.pl` — don't try to extend `_install-bin-helper.pl`. The helper is intentionally narrow.

Your hook still has to satisfy the seven rules above: two-phase, idempotent, User-scope, cross-platform, list-form subprocesses, descriptive output. As long as you keep the contract, the orchestrator doesn't care what the hook does internally.

If you find yourself wanting to weaken the contract (e.g. "but I really need admin"), step back and consider whether the work belongs in a one-shot install hook at all. Often it's better to make the user run a separate Setup step manually, or to defer the work to first-use of the feature.
