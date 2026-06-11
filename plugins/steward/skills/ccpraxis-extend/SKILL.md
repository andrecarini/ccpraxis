---
name: ccpraxis-extend
description: THE single entrypoint for changing ccpraxis or adding new functionality to it. Decides whether the request is NEW (scaffold a skill, plugin, or plugin-skill — applying the packaging rule) or a CHANGE (locate the existing skill/plugin/script and edit it), then does the work and wires it in (related links, settings perms, marketplace, README, live mirror). Use proactively whenever the user wants to add, build, create, scaffold, or design a new skill / plugin / slash command / capability for ccpraxis, OR change, fix, improve, refactor, rename, or extend an existing ccpraxis skill, plugin, or script. Use when the user says "add a skill", "make a plugin", "new slash command", "extend ccpraxis", "change the X skill", "update the Y plugin", or describes a capability they want ccpraxis to have. Host-only.
argument-hint: [what you want to add or change]
user-invocable: true
host-only: true
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Glob, Grep, Skill
---

# /steward:ccpraxis-extend

The one tool for evolving ccpraxis. The user does **not** pick "create vs update" or "skill vs plugin" — they describe what they want in their own words and this skill figures out the shape. It absorbs what used to be `/create-skill` and `/update-skill`, generalized beyond a single skill to **skills, plugins, plugin-skills, and scripts**.

Repo root is `~/.claude/ccpraxis` (this is a host-only skill that edits the repo, then refreshes the live install). The request: `$ARGUMENTS` — if empty, ask the user what they want to add or change.

**Take your time.** Extending ccpraxis is a design task. Read the references, understand the request, propose the shape, and confirm before writing anything. Don't rush to deliver.

## Step 0 — Load the references (always)

Two docs are load-bearing. Read both before scaffolding or editing:

- **`references/extending-ccpraxis.md`** — where extensions live (plugin / standalone skill / standalone surface), the packaging rule, plugin layout, the `ccpraxis-install.pl` contract, marketplace + `enabledPlugins` wiring, and a worked plugin example.
- **`references/skill-writing-guide.md`** — frontmatter fields, progressive disclosure, description-writing, string substitutions, and style for the SKILL.md body itself.

```bash
cat ~/.claude/ccpraxis/references/extending-ccpraxis.md
cat ~/.claude/ccpraxis/references/skill-writing-guide.md
```

Everything below assumes you've internalized them — this skill is the *process*; those docs are the *conventions*. Don't duplicate their detail here; defer to them.

## Step 1 — Understand the request, classify NEW vs CHANGE

Parse `$ARGUMENTS` (or ask). Decide which it is:

- **NEW** — the capability doesn't exist yet ("I want something that does X"). → Step 2.
- **CHANGE** — modify/fix/refactor/rename/remove something that already exists ("change the backup skill to…", "the X plugin should also…"). → Step 3.

If genuinely ambiguous (e.g. "make the todo thing also sync on close" — is that a new skill or a change to an existing one?), don't guess — ask the user with `AskUserQuestion`, framing both readings. When the request names an existing surface, it's almost always a CHANGE. When in doubt, a quick `Glob`/`Grep` over `plugins/` and `skills/` tells you whether the thing already exists.

## Step 2 — NEW: pick the shape, propose, scaffold

### 2a. Apply the packaging rule

This is the rule the skill exists to enforce (memory `feedback_packaging_multi_op`). Analyze the request: **how many distinct user-facing operations, on how many domain objects, with how much shared state?**

| Situation | Shape | Where |
|-----------|-------|-------|
| 1 operation, or operations with no shared domain object | **standalone skill** | `skills/<name>/SKILL.md` |
| 2+ user-facing operations on **one** domain object | **new plugin**, one verb per skill | `plugins/<name>/` + `.claude-plugin/plugin.json` + `skills/<verb>/` |
| Adding an operation that belongs to an **existing** plugin's domain | **new skill inside that plugin** | `plugins/<existing>/skills/<verb>/` |

Standalone surfaces (top-level dirs) are reserved and rare — see the reference. Default to plugin/skill.

### 2b. Propose the shape, then confirm

State the chosen shape with a **one-line justification**, and confirm before scaffolding (memory `feedback_propose_vs_auto` — propose + decide, don't silently choose):

> This is 2 operations (`pack`, `unpack`) on one domain object (a backpack item), so I'll make it a **plugin** `backpack/` with `skills/pack/` and `skills/unpack/`. Sound right?

If it could legitimately go two ways, use `AskUserQuestion` with both options and the tradeoff (memory `feedback_design_conversation`) rather than asserting one. Only scaffold after the user agrees.

### 2c. Gather requirements + design

For each skill being created, settle: name (kebab-case, no "claude"/"anthropic"), one-line purpose, trigger conditions, `user-invocable` vs internal, needed `allowed-tools`, `host-only`?, whether it needs supporting files or a backing script, and how multiple skills divide responsibility. Ask follow-ups when the description is thin. Then present the full design (frontmatter + step outline + folder structure + `related` wiring) and get approval — see `create`-flow detail in `references/extending-ccpraxis.md` and the guide.

### 2d. Scaffold

Write the files into the **repo** (never directly into `~/.claude/skills` or a live plugin):

- **Standalone skill:** `skills/<name>/SKILL.md` (+ any one-level-deep supporting files / `scripts/`).
- **New plugin:** `plugins/<name>/.claude-plugin/plugin.json` (no `displayName` — the validator rejects it), `skills/<verb>/SKILL.md` per verb, optional `scripts/`, `bin/` (+ `ccpraxis-install.pl` only if it ships a CLI that must land on PATH — delegate to `scripts/_install-bin-helper.pl`). Reference bundled scripts from a skill body via `${CLAUDE_PLUGIN_ROOT}/scripts/...` in bash blocks (the env var bash expands at runtime), matching the other steward/beacon skills.
- **Skill inside an existing plugin:** just `plugins/<existing>/skills/<verb>/SKILL.md`.

Then go to Step 4 (wiring).

## Step 3 — CHANGE: locate, scope, edit

### 3a. Detect the target's shape

Find what the user named and classify it, because the edit + rewiring differ:

```bash
ls -d ~/.claude/ccpraxis/skills/<name> ~/.claude/ccpraxis/plugins/<name> \
      ~/.claude/ccpraxis/plugins/*/skills/<name> 2>/dev/null
```

- **bare skill** → `skills/<name>/`
- **plugin** → `plugins/<name>/` (a change may touch its `plugin.json`, several skills, scripts, hooks)
- **plugin-skill** → `plugins/<plugin>/skills/<name>/`
- **script** → a `.pl`/`.sh` under `scripts/` or a plugin's `scripts/`

If the name is unfamiliar, `Grep` for it before assuming it's missing. If it truly doesn't exist, this is really a NEW request — switch to Step 2.

### 3b. Expand the working set via `related` (skills only)

For skill targets, read the `related:` list in frontmatter and take the **transitive closure** — follow each related skill's `related` until the set stops growing. These siblings are pulled in for **consistency review**, not necessarily modification; tell the user which were added and why. (This is the old `/update-skill` behavior, preserved.)

### 3c. Read everything in scope, design, confirm

Read the full SKILL.md / script of every target + sibling and the guide, so you understand current behavior, frontmatter rationale, edge cases, and the 500-line budget before touching anything. Present the planned changes per file (what changes, what's preserved, ripple effects on README/settings/related skills, edge cases) and get approval via `AskUserQuestion`.

### 3d. Edit surgically

Use `Edit` for targeted changes (preserve everything the user didn't ask to change); reserve `Write`/full-rewrite for when a rewrite is genuinely cleaner. Keep the existing style, numbering, and frontmatter field order. If the change is a **rename or removal**, treat it as a change plus the reverse of the relevant wiring in Step 4 (move/delete the dir, drop the `Skill(...)` perm, drop the marketplace/`enabledPlugins` entry for a removed plugin, remove the live mirror), then regen the README.

Then go to Step 4 (wiring).

## Step 4 — Wire it in (both paths)

Only the steps that apply to what you touched:

1. **`related` frontmatter.** Skills created together link to each other; a new skill that pairs with an existing one is added to both `related` lists. Keep links symmetric.

2. **Settings permission.** For a user-invocable skill, add an allow entry so it doesn't prompt — `Skill(<name>)` for a bare skill, `Skill(<plugin>:<verb>)` for a plugin skill — to the repo source `global-config/settings.json` (and the live `~/.claude/settings.json` so it takes effect now). Keep the list alphabetical.

3. **New plugin only:** register it in `plugins/.claude-plugin/marketplace.json` (`{"name","source":"./<name>","description"}`) and enable it — add `"<name>@ccpraxis-local": true` to `enabledPlugins` in **both** `global-config/settings.json` and `~/.claude/settings.json`. If you added a skill to an existing plugin, update that plugin's `plugin.json` description so it stays accurate.

4. **README.** It's generated — never hand-edit the file tree. Run, in order:
   ```bash
   perl ~/.claude/ccpraxis/scripts/gen-readme-tree.pl --write
   perl ~/.claude/ccpraxis/scripts/gen-readme-tree.pl --check
   perl ~/.claude/ccpraxis/scripts/lint-readme-paths.pl
   ```
   The tree comment comes from a `.about` sidecar if present, else `plugin.json`, else the SKILL.md `description` — so a good frontmatter description is usually enough; add a `<name>.about` one-liner only to override. If you changed hand-written prose (the intro bullets, Features, or host-only examples) to mention the new/renamed command, edit those by hand, then re-run `--check` + lint until clean.

5. **Live mirror.** Bare skills are mirrored to `~/.claude/skills/`; refresh after any create/edit/delete:
   ```bash
   perl ${CLAUDE_PLUGIN_ROOT}/scripts/ccpraxis-helpers.pl sync-skills
   ```
   Plugins load live from the repo via the marketplace — no mirror. A **new plugin** or newly-enabled plugin only registers after `/reload-plugins` or a restart; tell the user.

## Step 5 — Validate + self-review

- **Plugin manifest** (if you created/changed a plugin): validate in a throwaway container —
  ```bash
  export MSYS2_ARG_CONV_EXCL='*'
  podman run --rm --entrypoint claude \
    -v "$(cygpath -m ~/.claude/ccpraxis/plugins/<name>):/work/p:ro" \
    localhost/claude-sandbox:latest plugin validate /work/p
  ```
- **Read back** every file you wrote or edited and self-review against the guide: third-person description with triggers, steps unambiguous, under 500 lines, supporting files one level deep, `related` symmetric, cross-references correct, works on Windows + Unix.

## Step 6 — Report

Tell the user: what was created/changed and its shape; the slash command(s) now available (and whether a `/reload-plugins`/restart is needed for a new plugin); how `related`/settings/marketplace were wired; that the README regenerated clean; and that changes sync to their private repos on the next **`/steward:backup`** (which also relinks bare skills on other machines after pulling).
