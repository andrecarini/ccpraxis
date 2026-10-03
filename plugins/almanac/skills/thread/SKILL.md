---
name: thread
description: A project's threads, which persist across sessions. A thread's tasks hold steps of work actively under way now, each with a status or a one-way link to a package, plus a typed log of what happened to the thread itself. Use proactively when starting multi-step work, when a step changes state, or when attaching to or handing off a piece of work, and use when the operator asks where the work stands. Skip for one-step requests, for deferred work nobody is doing now, which goes in /almanac:todo, and for questions only the operator can answer, which go in /almanac:inbox.
allowed-tools: Bash, Read
---

# Threads: a project's handover unit

A thread is metadata (name, state, owner), a typed log of what happened to the thread, and one ordered task list. A task is either unlinked (its own status: `pending`, `doing`, `blocked`, `done`, `obsoleted`) or linked one-way to a package (`<blueprint>/<package>`) -- a linked task's status is its package's, read from the package's ledger, never its own field. Status notes and progress logs do not belong in a thread's tasks; move the step's status instead, or append a typed log event for the thread itself.

## See where things stand

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread list
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread show <thread>
```

## Start one and add steps

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread create <name>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread add <thread> --title "one step"
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread add <thread> --link <blueprint>/<package>
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread add-packages <thread> <blueprint>
```

## Move them along

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread status <thread> <task> doing
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread status <thread> <task> done
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread move <thread> <task> --first
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread edit <thread> <task> --title "..."
```

## Hand the thread itself off

```bash
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread event <thread> --event handed-off --reason "why"
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread event <thread> --event resumed
perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" thread archive <thread>
```

A thread with at least one task, all done, archives automatically the next time any verb touches
it; a thread with no tasks never auto-archives. Move a todo into a thread (completing the todo
with a pointer) with `perl "${CLAUDE_PLUGIN_ROOT}/scripts/almanac.pl" todo promote <id> --thread <thread>`.
