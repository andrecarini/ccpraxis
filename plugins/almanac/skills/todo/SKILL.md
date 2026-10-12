---
name: todo
description: Record, list and close deferred work an agent can do later, as project todos for this repo or global todos for anything cross-project. Use proactively when the operator says "remind me", "for later" or "add a todo", or names follow-up work this session will not finish, and use when asked what is outstanding. Skip for steps of the current task, which go in /almanac:thread, and for questions only the operator can answer, which go in /almanac:inbox.
allowed-tools: Bash, Read
---

# Todos that outlive a session

A todo is one file: work worth remembering that nobody is doing right now, something the operator
will not finish this session, or a follow-up they name in passing.

Storage: `<project>/.ccpraxis-local-data/almanac/todo/<id>.md` for a project todo, and
`~/.claude/claude-code-vault/almanac/todo/<id>.md` for a global one.

Project is the default; add `--global` for anything cross-project. Inside a sandbox only project
scope is reachable; a `--global` call there is refused by the store itself.

## See what's outstanding

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo list
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo list --global
```

## Add one

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo create --title "one line" \
  --tags a,b --body -   <<'TODO'
...detail...
TODO
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo create --title "cross-project follow-up" --global
```

## Work it

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo show <id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo edit <id> --title "..."
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo complete <id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo reopen <id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo delete <id>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo promote <id> --thread <thread>
```

Add `--json` to `list`/`show` for machine-readable output.
