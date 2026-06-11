# Skill Writing Guide

Shared reference for authoring Claude Code skills. Read this when designing or reviewing skills in `/steward:ccpraxis-extend`.

## Table of Contents

- [Skill Anatomy — Folder Structure](#skill-anatomy--folder-structure)
- [Progressive Disclosure — 3-Level Loading](#progressive-disclosure--3-level-loading)
- [Writing Effective Descriptions](#writing-effective-descriptions)
- [Frontmatter Fields Reference](#frontmatter-fields-reference)
- [Available Tools for allowed-tools](#available-tools-for-allowed-tools)
- [String Substitutions](#string-substitutions)
- [Writing Style](#writing-style)

---

## Skill Anatomy — Folder Structure

Every skill is a directory with `SKILL.md` as the entrypoint. Supporting files are optional and organized however makes sense for the skill.

**Simple skill** (most skills need only this):
```
my-skill/
└── SKILL.md
```

**Skill with supporting files:**
```
my-skill/
├── SKILL.md              # Main instructions (required)
├── reference.md          # Detailed docs (loaded when needed)
├── examples.md           # Usage examples (loaded when needed)
└── scripts/
    └── validate.sh       # Utility script (executed, not loaded)
```

**Domain-organized skill** (multiple variants):
```
bigquery-skill/
├── SKILL.md              # Overview and navigation
└── reference/
    ├── finance.md        # Revenue, billing metrics
    ├── sales.md          # Opportunities, pipeline
    └── product.md        # API usage, features
```

Claude reads only the relevant reference file based on the user's request.

### Key rules

- **One level deep:** All supporting files must be referenced directly from SKILL.md. Don't chain references (SKILL.md → advanced.md → details.md). Claude may partially read deeply nested files.
- **Name files descriptively:** `form_validation_rules.md`, not `doc2.md`. Names should indicate content.
- **Organize for discovery:** Structure directories by domain or feature, not generically.
- **Use `${CLAUDE_SKILL_DIR}`** in bash commands to reference bundled files regardless of working directory.
- **Forward slashes only:** Even on Windows, use `scripts/helper.py`, not `scripts\helper.py`.

---

## Progressive Disclosure — 3-Level Loading

Skills use a three-level loading system that keeps context usage efficient:

| Level | What | When loaded | Size guidance |
|-------|------|-------------|---------------|
| 1. Metadata | `name` + `description` | Always in context at startup | ~100 words. Front-load the key use case. |
| 2. SKILL.md body | Main instructions | When the skill triggers | <500 lines ideal. Overview + pointers. |
| 3. Supporting files | References, scripts, assets | On demand when Claude needs them | Unlimited. Scripts execute without loading. |

### Rules

- **Keep SKILL.md under 500 lines.** If approaching this limit, move detailed reference material to supporting files and add pointers from SKILL.md.
- **For reference files >100 lines,** include a table of contents at the top so Claude can see the full scope even when previewing.
- **Scripts are executed, not loaded** into context — only the script's output consumes tokens. Prefer scripts for deterministic/repetitive operations.
- **Make execution intent clear** in SKILL.md:
  - "Run `validate.sh` to check fields" → execute the script
  - "See `validate.sh` for the validation algorithm" → read as reference

### Skill content lifecycle

Once a skill is loaded, its content stays in the conversation for the session. During auto-compaction, Claude Code re-attaches the most recent invocation of each skill (first 5,000 tokens per skill, 25,000 token combined budget across all skills). If a skill stops influencing behavior, strengthen the description and instructions, or re-invoke it.

---

## Writing Effective Descriptions

The `description` field is the primary mechanism that determines whether Claude invokes a skill. Claude sees all skill descriptions at startup and uses them to decide which skill to load for a given task.

### Rules

- **Write in third person.** The description is injected into the system prompt. Inconsistent point-of-view causes discovery problems.
  - Good: "Processes Excel files and generates reports"
  - Avoid: "I can help you process Excel files"
  - Avoid: "You can use this to process Excel files"
- **Include WHAT and WHEN.** Describe what the skill does AND the specific contexts/triggers for when to use it.
- **Be slightly pushy.** Claude tends to undertrigger — it won't use a skill even when it's clearly relevant unless the description makes the match obvious.
- **Front-load the key use case.** Descriptions longer than 250 characters are truncated in the skill listing. Put the most important information first.
- **Max 1024 characters** in frontmatter. No XML tags allowed.

### Examples

**Good:**
```yaml
description: Extracts text and tables from PDF files, fills forms, merges documents. Use when working with PDF files or when the user mentions PDFs, forms, or document extraction.
```

**Good:**
```yaml
description: Generates descriptive commit messages by analyzing git diffs. Use when the user asks for help writing commit messages or reviewing staged changes.
```

**Bad:**
```yaml
description: Helps with documents
```

### Naming conventions

- **Gerund form:** `processing-pdfs`, `analyzing-spreadsheets`, `managing-databases`
- **Action-oriented:** `process-pdfs`, `analyze-spreadsheets`
- **Avoid:** `helper`, `utils`, `tools`, `documents`, `data` (too vague)
- Must be lowercase letters, numbers, and hyphens only. Max 64 characters. Cannot contain reserved words: "anthropic", "claude".

---

## Frontmatter Fields Reference

All fields are optional. Only `description` is recommended.

### Official fields

| Field | Description |
|-------|-------------|
| `name` | Display name. Defaults to directory name. Lowercase, numbers, hyphens only. Max 64 chars. No reserved words ("anthropic", "claude"). |
| `description` | What the skill does and when to use it. Write in third person. Max 1024 chars, truncated at ~250 in listings. No XML tags. |
| `argument-hint` | Hint shown in autocomplete, e.g. `[issue-number]` or `[filename]`. |
| `user-invocable` | `false` = hidden from `/` menu, only Claude can invoke. Default: `true`. |
| `disable-model-invocation` | `true` = Claude won't auto-load this skill. Manual-only via `/name`. Default: `false`. |
| `allowed-tools` | Tools available without per-use permission when skill is active. Space-separated string or YAML list. Does not restrict other tools. |
| `model` | Model override when this skill is active (e.g. `claude-sonnet-4-6`). |
| `effort` | Effort level override: `low`, `medium`, `high`, `max` (Opus only). |
| `context` | `fork` = run in an isolated subagent context. |
| `agent` | Subagent type when `context: fork` (e.g. `Explore`, `Plan`, `general-purpose`, or custom agent name). |
| `paths` | Glob patterns limiting when the skill auto-activates. Comma-separated string or YAML list. |
| `hooks` | Hooks scoped to this skill's lifecycle. See [Hooks in skills and agents](https://code.claude.com/docs/en/hooks#hooks-in-skills-and-agents). |
| `shell` | Shell for inline commands: `bash` (default) or `powershell`. Requires `CLAUDE_CODE_USE_POWERSHELL_TOOL=1`. |

### Custom fields (this config repo)

These are not in the official spec but work in practice:

| Field | Description |
|-------|-------------|
| `host-only` | `true` = skill is excluded from sandbox container skill selection. |
| `related` | YAML list of skill names that should be reviewed together when this skill is updated. Links are followed transitively by `/steward:ccpraxis-extend` when changing a skill. |

---

## Available Tools for `allowed-tools`

Core tools: `Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `WebFetch`, `WebSearch`, `Agent`, `Skill`, `AskUserQuestion`

Patterns: `Bash(*)` (all bash), `Bash(npm *)` (only npm commands), `Bash(git add *)` (only git add), `MCP(*)` (all MCP tools)

Permission syntax for skill invocation control: `Skill(name)` (exact match), `Skill(name *)` (prefix match with any arguments).

---

## String Substitutions

| Variable | Description |
|----------|-------------|
| `$ARGUMENTS` | Full argument string — everything the user typed after the skill name. If not present in content, arguments are appended as `ARGUMENTS: <value>`. |
| `$ARGUMENTS[N]` | Access a specific argument by 0-based index. Uses shell-style quoting — wrap multi-word values in quotes. |
| `$N` | Shorthand for `$ARGUMENTS[N]`. `$0` = first argument, `$1` = second, etc. |
| `${CLAUDE_SESSION_ID}` | Current session ID. Useful for logging or session-specific files. |
| `${CLAUDE_SKILL_DIR}` | Directory containing this skill's SKILL.md. Use in bash commands to reference bundled files regardless of working directory. |

**Example:** `/my-skill "hello world" second` makes `$0` = `hello world`, `$1` = `second`, `$ARGUMENTS` = `"hello world" second`.

---

## Writing Style

### Default assumption: Claude is already very smart

Only add context Claude doesn't already have. Challenge each piece of information:
- "Does Claude really need this explanation?"
- "Can I assume Claude knows this?"
- "Does this paragraph justify its token cost?"

### Guidelines

- **Explain the WHY** behind instructions, not heavy-handed MUSTs. Claude has good theory of mind — when it understands the reasoning, it can handle edge cases you didn't anticipate.
- **Generalize, don't overfit.** Write skills that work across many prompts, not ones narrowly tied to the example that inspired them.
- **Prefer imperative form:** "Run X", "Read Y", "Ask the user Z".
- **Include examples** with Input/Output pairs where the skill's behavior might be ambiguous.
- **Use consistent terminology.** Pick one term and stick with it throughout — don't alternate between "API endpoint", "URL", "route", and "path".
- **Match specificity to fragility.** High freedom for heuristic tasks (code review, analysis), low freedom for fragile operations (database migrations, deployments).
- **Draft, then re-read.** After writing, look at it with fresh eyes — would another agent follow this correctly? Remove anything that isn't pulling its weight.
