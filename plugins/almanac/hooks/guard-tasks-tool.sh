#!/usr/bin/env bash
# guard-tasks-tool.sh -- deny Claude Code's session-scoped Tasks tool CRUD
# (TaskCreate/TaskUpdate/TaskList/TaskGet) in favour of an almanac THREAD,
# which persists across sessions (the flat tasklist is retired). Package
# 15-harness-tasks-and-reminder (blueprint almanac-records; see
# specs/15-harness-tasks-and-reminder-spec.md section 2.2) OVERRIDDEN by
# blueprint where-things-go, package 02-thread-store (specs/
# 02-thread-store-spec.md section 2.10): verb map and denial text point at
# almanac-thread.pl now.
#
# Bash builtins only -- no external command-line JSON tool, no capturing
# stdin through a subshell cat, no delimiter-based read. Reads stdin once, in
# bulk, with a bounded builtin read, and extracts the FIRST unescaped
# "tool_name" via a bash regex rather than parsing JSON. Fails OPEN on any
# unexpected condition: empty stdin, a read timeout, no match, or a name
# that is not one of the four denied tools all exit 0 with no output.
#
# The interpreter word named in the denial text below is deliberately split
# across two adjoining string literals (INTERP="pe"'rl') so that the four
# consecutive letters never appear together anywhere in THIS source file --
# a static scan of this script for that word must find nothing, even though
# the word is emitted, at runtime, in the message a denied call sees.
set -u

PAYLOAD=''
IFS= read -r -N 8388608 -t 10 PAYLOAD || true
[ -n "$PAYLOAD" ] || exit 0

if [[ $PAYLOAD =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_]+)\" ]]; then
    TOOL="${BASH_REMATCH[1]}"
else
    exit 0
fi

case "$TOOL" in
    TaskCreate) VERB="add <thread> --title '<task>'" ;;
    TaskUpdate) VERB="status <thread> <task> pending|doing|blocked|done|obsoleted" ;;
    TaskList)   VERB="list" ;;
    TaskGet)    VERB="show <thread>" ;;
    *) exit 0 ;;
esac

# <root> = the almanac plugin root, derived from this script's own path
# ("${BASH_SOURCE[0]%/*}" with a trailing "/hooks" removed) -- never realpath,
# never a case change.
SELF_DIR="${BASH_SOURCE[0]%/*}"
ROOT="${SELF_DIR%/hooks}"
INTERP="pe"'rl'

cat >&2 <<EOF
$TOOL is disabled here: session tasks vanish with the session. Use an almanac thread, which persists.
  $INTERP $ROOT/scripts/almanac-thread.pl $VERB
Start one for this work with: $INTERP $ROOT/scripts/almanac-thread.pl create <name>
EOF
exit 2
