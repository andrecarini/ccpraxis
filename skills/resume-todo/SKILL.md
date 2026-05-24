---
name: resume-todo
description: Loads a todo note and begins working on whatever it describes. Use when the user says "work on that todo", "pick up the todo", "resume the todo", or wants to act on a previously saved note.
user-invocable: true
argument-hint: <todo-name>
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Glob
related:
  - create-todo
  - manage-todos
---

# Resume Work on a Todo

Load a todo note from `~/.claude/claude-code-vault/todos/` and begin working on whatever it describes. Unlike `/resume-plan` (which creates structured session plans with deliverables), this is lightweight — read the note, understand the context, and help the user act on it.

This skill runs on the main model (no Sonnet override) because the actual work could be complex.

## Arguments

- `$0` — Todo name (filename without `.md`)

If no argument given, list open todos and ask which one.

## Steps

### 1. Ensure the todo repo is ready

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl status
```

If `STATUS: missing`, tell the user there are no todos yet and suggest `/create-todo` to get started (which will handle repo setup).

### 2. Pull latest

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl sync
```

Only report if `STATUS: conflict`.

### 3. Find and read the todo

If `$0` is provided, read `~/.claude/claude-code-vault/todos/$0.md`. If it doesn't exist, list available todos:

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl list
```

Ask the user which one they meant.

### 4. Present the todo

Show the todo's content and ask what the user wants to do:
- Work on what the todo describes
- Add notes to the todo
- Mark it as done
- Something else

### 5. Work

Help the user with whatever the todo describes. This is free-form — there's no structured deliverables or session plan. Just act on the note.

### 6. Update the todo

After working, update the todo file if appropriate:
- Add notes about what was done (append to the body using Edit)
- If the work is complete, mark done and archive via the Perl script:
  ```bash
  perl ~/.claude/ccpraxis/scripts/todo-sync.pl done "$0"
  ```

Sync the changes:

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl sync "Update: $0"
```

## Important

- Keep the todo updated as you work — it's the record of what was done.
- If the user says they're done, mark the todo `status: done` and sync before ending.
- Don't create session plans or deliverables — todos are lighter than plans by design.
