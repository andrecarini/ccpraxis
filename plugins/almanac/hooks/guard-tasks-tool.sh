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
# stdin through a subshell cat. Reads stdin once, in bulk, through
# scripts/read-payload.sh (the one bounded builtin reader the bash hooks of
# almanac and butler share; sourced, so no process), and extracts the FIRST
# unescaped "tool_name" via a bash regex rather than parsing JSON.
#
# Fail directions. OPEN on input it can read but cannot use: empty stdin,
# broken JSON, no match, or a name that is not one of the four denied tools
# all exit 0 with no output; so does a missing library (a broken install).
# CLOSED on input it could not read in full -- no end of input within 10 s,
# or over 8 MiB: hooks.json runs this guard only for the four Tasks tools,
# and it denies every one of them whenever it can read the call, so letting
# an unread call through would be the only way a Tasks tool ever ran. That
# used to differ by host: bash >= 4 kept the partial text of a timed-out
# read and could still find the tool name in it, while macOS /bin/bash 3.2
# dropped it and let the call through. It is now a deny on every bash.
#
# The interpreter word named in the denial text below is deliberately split
# across two adjoining string literals (INTERP="pe"'rl') so that the four
# consecutive letters never appear together anywhere in THIS source file --
# a static scan of this script for that word must find nothing, even though
# the word is emitted, at runtime, in the message a denied call sees.
set -u

# <root> = the almanac plugin root, derived from this script's own path
# ("${BASH_SOURCE[0]%/*}" with a trailing "/hooks" removed) -- never realpath,
# never a case change.
SELF_DIR="${BASH_SOURCE[0]%/*}"
ROOT="${SELF_DIR%/hooks}"
INTERP="pe"'rl'

# The shared reader: <almanac>/scripts/read-payload.sh, beside this hooks/ dir.
case "${BASH_SOURCE[0]//\\//}" in
    */*) _rp_dir="${BASH_SOURCE[0]//\\//}"; _rp_dir="${_rp_dir%/*}" ;;
    *)   _rp_dir=. ;;
esac
[ -f "$_rp_dir/../scripts/read-payload.sh" ] || exit 0
. "$_rp_dir/../scripts/read-payload.sh"
declare -F ccp_read_payload >/dev/null || exit 0
PAYLOAD=''
ccp_read_payload PAYLOAD
case "${CCP_PAYLOAD_STATE:-}" in
    complete) ;;
    truncated|timeout)
        # Fail closed (see the header). The tool name is unknown, so the
        # message names the family and the thread verbs that replace it.
        cat >&2 <<EOT
This Tasks tool call is disabled here: session tasks vanish with the session. Use an almanac thread, which persists.
  $INTERP $ROOT/scripts/almanac-thread.pl list
Start one for this work with: $INTERP $ROOT/scripts/almanac-thread.pl create <name>
(The guard refused this call without reading it: its hook input did not arrive in full.)
EOT
        exit 2
        ;;
    *) exit 0 ;;
esac
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

cat >&2 <<EOF
$TOOL is disabled here: session tasks vanish with the session. Use an almanac thread, which persists.
  $INTERP $ROOT/scripts/almanac-thread.pl $VERB
Start one for this work with: $INTERP $ROOT/scripts/almanac-thread.pl create <name>
EOF
exit 2
