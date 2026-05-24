---
name: manage-todos
description: Lists, views, creates, updates, and deletes personal todo notes. Use when the user wants to see their todos, check todo status, edit a todo, create a new todo, delete old todos, mark todos as done, or says things like "show my todos", "list todos", "delete the todo", "mark that todo done".
user-invocable: true
argument-hint: [list|create|view|update|delete|done] [todo-name]
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion, Glob
related:
  - create-todo
  - resume-todo
---

# Manage Todo Notes

CRUD operations for personal todo notes in `~/.claude/claude-code-vault/todos/`.

All file creation goes through the Perl script `todo-sync.pl` — it owns the template format. Never write the frontmatter yourself. The script auto-captures the working directory at creation time (`cwd` field in frontmatter).

## Arguments

- `$0` — Operation: `list`, `create`, `view`, `update`, `delete`, or `done`. Defaults to `list` if omitted.
- `$1` — Todo name (required for all operations except `list`)

## Steps

### 1. Ensure the todo repo is ready

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl status
```

- `STATUS: ok` → proceed
- `STATUS: missing` → ask the user for their todo repo URL (HTTPS or SSH), then run:
  ```bash
  perl ~/.claude/ccpraxis/scripts/todo-sync.pl init "<repo-url>"
  ```
- `CAN_FETCH: no` → warn about connectivity but proceed with local data

### 2. Pull latest

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl sync
```

Only report if `STATUS: conflict`. Otherwise proceed silently.

### 3. Route to operation

---

### Operation: `list` (default)

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl list
```

Display the output as a formatted table. If empty, suggest `/create-todo`.

---

### Operation: `create`

Delegate to the Perl script — the script owns the template:

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl create "$name" --title "$title" --tags "$tags" <<'EOF'
<content>
EOF
```

If `$1` was provided, use it as the name. Otherwise ask the user for name, content, and optional tags. After creation:

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl sync "Add: $name"
```

---

### Operation: `view`

Read `~/.claude/claude-code-vault/todos/$1.md` and display:
- Title and status
- Tags and created date
- Full content

Suggest `/resume-todo $1` to work on it, or `/manage-todos update $1` to edit.

---

### Operation: `update`

Read the todo file and ask the user what they want to change:
- Edit content
- Change tags
- Update status

Use the Edit tool for surgical changes to the file. After editing:

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl sync "Update: $1"
```

---

### Operation: `delete`

Read the todo's title and status, then confirm with the user:

> Delete todo `$1`? (<title>, status: <status>)

If confirmed:

```bash
rm ~/.claude/claude-code-vault/todos/$1.md
perl ~/.claude/ccpraxis/scripts/todo-sync.pl sync "Delete: $1"
```

---

### Operation: `done`

Mark the todo as done and archive it. The Perl script handles updating the status and moving the file to `archive/`:

```bash
perl ~/.claude/ccpraxis/scripts/todo-sync.pl done "$1"
perl ~/.claude/ccpraxis/scripts/todo-sync.pl sync "Done: $1"
```

If `STATUS: archived`, confirm to the user that the todo was completed and archived.

## Important

- Always pull before reading and sync after writing.
- Only bother the user about sync issues if there's an actual conflict. Routine syncs are silent.
- This skill is for managing todos directly. To work *on* what a todo describes, use `/resume-todo`.
