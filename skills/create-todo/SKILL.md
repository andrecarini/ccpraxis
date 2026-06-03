---
name: create-todo
description: Creates a new todo note synced to a personal git repo. Use when the user wants to jot down a note, save a reminder, create a todo, or says things like "remind me", "save this for later", "create a todo", "note to self".
user-invocable: true
host-only: true
argument-hint: <todo-name> [content]
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Glob
related:
  - manage-todos
  - resume-todo
---

# Create a Todo Note

Create a new todo note in the personal vault repo (`~/.claude/claude-code-vault/todos/`). Todos are simple markdown notes synced across machines via git.

All file creation goes through the Perl script `todo-sync.pl` — it owns the template format. Never write the frontmatter yourself. The script auto-captures the working directory at creation time (`cwd` field in frontmatter).

## Arguments

- `$0` — Todo name (kebab-case, e.g. `fix-auth-middleware`)
- Remaining arguments — Brief content or description

If no arguments given, ask the user what they want to save.

## Steps

### 1. Ensure the todo repo is ready

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl status
```

- `STATUS: ok` → proceed to step 2
- `STATUS: missing` → ask the user for their todo repo URL (HTTPS or SSH), then initialize:
  ```bash
  perl ~/.claude/ccpraxis/scripts/todo-sync.pl init "<repo-url>"
  ```
  If init fails (auth/URL issue), report the error and let the user try a different URL.

### 2. Pull latest

Sync before creating to avoid conflicts:

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl sync
```

Only report to the user if `STATUS: conflict`. Otherwise proceed silently.

### 3. Create the todo

If the user provided content in the arguments, use it. If they invoked `/create-todo` with no args, ask via AskUserQuestion:
- What should the todo be called? (becomes the filename)
- What do you want to capture? (becomes the content)
- Any tags? (optional)

Pipe content to the script. The script writes the file with the correct template — collision detection is built in:

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl create "$name" --title "$title" --tags "$tags" <<'EOF'
<content from user>
EOF
```

- `STATUS: created` → proceed to step 4
- `STATUS: exists` → warn the user and ask whether to use a different name, then retry

### 4. Sync

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl sync "Add: $name"
```

Only report sync issues if there's a conflict. Otherwise just confirm the todo was created and synced.
