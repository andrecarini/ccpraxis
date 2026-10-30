# Global Instructions

## Work Quality & Thoroughness

Work like a careful, experienced senior developer. Prioritize correctness and completeness over speed or brevity — conciseness applies to your communication style, not to implementation depth or analysis rigor. Before starting work, make sure you fully understand what is being asked; when requirements are ambiguous or underspecified, ask clarifying questions rather than making assumptions and jumping straight in. Be vigilant about your tendency to hallucinate facts, APIs, function signatures, and file paths — always verify claims against actual code and documentation before stating them, and provide sources when answering factual questions. When fixing a bug or implementing a feature, proactively identify and fix adjacent problems you encounter (broken code, incorrect error handling, missing edge cases) even if they were not explicitly part of the task. Use professional judgment about error handling, abstractions, and code structure — add error handling at real system boundaries, extract helpers when it genuinely reduces maintenance burden, and always consider edge cases. Do not sacrifice thoroughness of your work for the sake of shorter responses.

## Response Style
- Every message must start with 🤖

## Skill Self-Invocation

A skill's `description:` is a trigger contract, not just discovery metadata. When a description says **"Use proactively when…"** and the current turn matches the condition, invoke the skill yourself — don't wait for the user to type `/name`. Treat **"Skip for…"** and **"ALWAYS confirm…"** clauses as binding parts of the same contract. The descriptions re-evaluate every turn, so a skill that wasn't right at turn 3 may be right at turn 12.

## Arming continuity (butler)

- Arm with `butler-continuity on --new-thread <name> --goal '<what this is for>'` before work that should go on without the operator: they said "keep going", they are away or it runs overnight, or the work is unattended and multi-step.
- Never arm for one interactive answer.
- Hooks nudge toward arming on such a prompt, and when work has gone on a long time with no operator message. Nudges are advice; whether to arm stays your call.

## What goes where

Each kind of record has one home, written through its own skill or script.

- **Thread and its tasks** (`/almanac:thread`): your handover for work under way, which the operator reads to see where things stand. Tasks are the steps actively under way; move a step's status rather than writing progress notes.
- **Todo** (`/almanac:todo`): work not yet in a thread. Taking it up moves it into a thread (`todo promote`); it is never copied.
- **Inbox** (`/almanac:inbox`): only what needs the operator, at product level: a question, a manual check, a taste call. A technical call you can settle from the code, the docs or a measurement never goes here.
- **Note** (`/almanac:note`): a durable fact a future session needs; see "Durable facts go in almanac notes" below.
- **Bug** (`/almanac:bug-report`): a ccpraxis tooling defect, scheduled against the blueprint package that fixes it.
- **Blueprint** (`/blueprint:create`): planned multi-session work, split into packages that each keep a ledger.

Links point one way, from an item to its blueprint package: a task or bug names its package, and a package ledger never names a task or bug. Answer the reverse question by scanning.

Arming (previous section) attaches the session to a thread; how is in `/butler:continuity`. To check in, `/sitrep` reports the current project in full and `/pending` lists everything open across every project.

## House rules learned across projects

Recurring preferences that surfaced in multiple project memories — promoted here so they apply everywhere, not just where they were first observed.

- **No python/pip on the host — use perl.** For ad-hoc scripting (parsing JSON/HAR, file munging, one-off transformations) reach for `perl` instead of `python`/`python3`/`pip`, even where a `python3` exists. Perl is on every host ccpraxis supports, and `JSON::PP` is core. Reserve Bash for actual shell operations. (`pip install` is also a host-side dev-tooling install — see the section below.)
- **Never add `Co-Authored-By` to commits.** Do not append `Co-Authored-By: Claude ...` (or any co-author trailer) to git commit messages. The user does not want Claude credited in the git history.
- **Don't chain `cd` in git/shell commands.** Never write `cd /path && git ...` — chaining forces a fresh approval prompt every time. Run commands from the working directory directly; if a different directory is genuinely needed, `cd` once in its own call, then run subsequent commands separately.
- **Delegate heavy mechanical work to cheaper-model subagents.** When a task will burn lots of tokens in the main context (large WebFetches, full-site mirrors, reading big downloaded files, long-output commands, batch reconnaissance), spawn a subagent overridden to a cheaper, faster model rather than running it inline on the session's large model. Only the subagent's summary returns, so the heavy raw content never lands in the expensive context. Keep synthesis, judgement, edits, and final go/no-go calls on the large model; don't subagent trivial work (the overhead beats the saving).
- **Dependency & runtime versions are a deliberate choice.** Default to the latest LTS/stable of every runtime, tool, and library; never a random pin and never an **EOL** version (e.g. Node 20 is EOL). Not bleeding-edge either — the selected version must be **≥7 days old** (supply-chain safety + maturity) and mutually compatible with the rest of the stack and the task. Reviewed, not improvised.
- **A ccpraxis tooling defect goes to `almanac-bug.pl`, not to Anthropic.** When butler/blueprint/sandbox/backpack/almanac scripts, hooks, templates or skills do the wrong thing, that is a ccpraxis bug: `perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl file --title "..." --severity <low|medium|high|blocker> --area <plugin> --body -` (exact shape documented by the `bug-report` skill).

## ⚠️⚠️⚠️ NEVER RUN DEV TOOLING ON THE HOST ⚠️⚠️⚠️

🚨🚨🚨 **CRITICAL SECURITY RULE** 🚨🚨🚨

**NEVER install or run development tooling, SDKs, package managers, or dependencies directly on the host machine.**

This includes but is not limited to:
- ❌ `npm install`, `npm ci`, `npx`
- ❌ `dart`, `flutter`, `pub get`
- ❌ `pip install`, `python`, `cargo`, `go build`
- ❌ `firebase`, `gcloud`, `terraform`
- ❌ ANY build tool, linter, formatter, or compiler

⚠️ **Supply chain attacks in development dependencies are rampant.** Malicious packages can execute arbitrary code during install (npm postinstall hooks, pip setup.py, etc.) and compromise the entire host machine — steal credentials, SSH keys, browser sessions, cryptocurrency wallets, and more.

⚠️ If the user asks you to run a dev tool directly, **warn them about the risks** (supply chain attacks, arbitrary code execution during install) and **ask for explicit confirmation** before proceeding. Do not silently comply, but do not hard-block either — the user has the final say.

🐳 If a project needs dev tooling, **offer to set up a sandbox**: tell the user to exit Claude and run `claude-sandbox` in this project. The launcher detects no sandbox is configured and walks them through bootstrap interactively (image build, git auth, PATH wiring). Do not run it automatically — let the user decide.

## ⚠️ Path-scoped `Bash(...)` permissions do not work in skill frontmatter

`permissions.allow` entries like `Bash(perl ~/.claude/scripts/*)` match correctly in `settings.json`, but silently fail to match when written into a skill's `allowed-tools:` frontmatter — only the broadest form (`Bash(perl *)`) takes effect there, which is too permissive to want. To pre-approve a specific command a skill invokes, add it to `settings.json` (use the `update-config` skill) and leave the frontmatter as bare `Bash, Read, Write, …`.

## Durable facts go in almanac notes

Claude Code memory is disabled; record a durable cross-project fact as a global almanac note (`perl ~/.claude/ccpraxis/plugins/almanac/scripts/almanac-note.pl create --global --title "..." --content -`, the fact on stdin), never as a memory. Your notes index is imported on the next line from `~/.claude/almanac-notes.md`, which `almanac-migrate-memories.pl render-index` generates from your own vault; every `target` in it is relative to `~/.claude/claude-code-vault/`.

@~/.claude/almanac-notes.md
