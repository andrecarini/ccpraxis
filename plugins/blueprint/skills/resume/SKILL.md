---
name: resume
description: Resume work on an existing blueprint in THIS interactive session — load its blueprint.md, summarize where it stands (objective, decisions, what's done vs remaining, next actions), and continue working on it. Use when the user wants to pick up, continue, or work on a blueprint, or says "resume the X blueprint", "continue X", "work on the X plan", "pick up where we left off". For headless package execution by detached coordinators, use /butler:launch or /butler:resume instead.
argument-hint: <blueprint-name>
allowed-tools: Read, Glob, Grep, Bash, Edit, Write, AskUserQuestion, Skill, TodoWrite
---

# /blueprint:resume

Load a blueprint and **continue working on it interactively in this session**. This is the working-document resume — the interactive analog of picking a plan back up after a break or a context compaction. It is distinct from `/butler:resume`, which restarts detached *coordinator processes* to execute a butler-packaged blueprint headlessly; this skill is you, in the current session, doing the work.

Data root: `${CCPRAXIS_DATA_DIR:-<project-root>/.ccpraxis-local-data}`; blueprints live at `<data>/blueprints/<name>/blueprint.md` (archived ones under `<data>/blueprints/_archive/<name>/`).

## Steps

1. **Resolve the blueprint.** `$0` is the name. If omitted or it doesn't resolve, Glob `<data>/blueprints/*/blueprint.md` and `<data>/blueprints/_archive/*/blueprint.md`, read each one's `status` from the frontmatter, and present the candidates (name + status + one-line objective) via `AskUserQuestion` so the user picks.

2. **Load it.** Read `<data>/blueprints/<name>/blueprint.md` in full. If it has `packages/<NN>.md` ledgers, read those too. Read any files it points at under "Key references" / "KEY FACTS" so you actually have the context to continue — don't resume on the summary alone.

3. **Summarize where it stands** for the user, tightly: objective, current `status`, the locked decisions, what's **DONE**, what's **REMAINING** (the next concrete actions), and any open questions or constraints (e.g. "don't touch the sandbox"). This re-establishes shared context after a gap.

4. **Confirm the entry point.** Propose the obvious next task from the REMAINING list. If several are independent, use `AskUserQuestion` to let the user pick where to start. Optionally seed a `TodoWrite` list from the remaining tasks to track progress this session.

5. **Continue the work** — execute the chosen task(s) per the blueprint. As you make progress, **keep `blueprint.md` current**: move finished items to DONE (with commit hashes where relevant), update `status` / decisions / `last_updated`. The file is the source of truth across sessions, so a future `/blueprint:resume` (or a fresh context) picks up cleanly.

## Notes
- Interactive only — this skill never spawns butler coordinators. If the blueprint is a butler-executable one (packages with `write_set`) and the user wants unattended execution, point them at `/butler:launch <name>` / `/butler:resume <name>`.
- A blueprint authored as a loose living-document (no packages) is fine here — this skill works whether or not the blueprint was decomposed for butler.
- Keep the blueprint updated as you go; that discipline is what makes the next resume cheap.
