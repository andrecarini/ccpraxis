#!/usr/bin/env bash
# guard-git-mutations.sh — PreToolUse hook denying git working-tree mutations
# in ANY session, including manually-driven Task subagents.
#
# WHY THIS EXISTS SEPARATELY FROM guard-bash.sh
#
# guard-bash.sh already denies exactly these commands — and it did not fire,
# three times in one session, because lib.sh's bp_hook_gate() exits 0 (allow)
# unless BP_LEDGER, BP_DIR and BP_PROJECT_ROOT are all set. Those are exported
# by bp-launch.sh, so guard-bash.sh only enforces inside a butler-LAUNCHED
# coordinator session.
#
# A manual drive dispatches workers with the Agent/Task tool instead. Those
# subagents inherit none of the BP_* contract, so the gate opened and the
# prohibition survived only as text in the dispatch prompt. It was violated
# three times, and at least once it cost real work: the b25 fix-batch
# (R8-R11, R13, R18) was written, swept into a stash by a prohibited
# `git stash`, never restored, and never committed — while the ledger recorded
# step 7 as complete. A written instruction is not an enforcement mechanism.
#
# So this hook deliberately has NO bp_hook_gate: it applies everywhere.
#
# SCOPE. Only working-tree/history mutations that can DESTROY uncommitted work.
# Read-only git is untouched, because agents legitimately need it to inspect
# their own diffs — and pushing them toward `git stash` to "see what changed"
# is part of how this happened.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# Sourced for bp_json_get ONLY -- NO bp_hook_gate here, by design (see above).
source "$HOOK_DIR/lib.sh"

PAYLOAD=$(cat)

# See lib.sh:bp_json_get. This used to hard-require jq, which the Windows host
# does not have and -- per this repo's Perl-only doctrine -- is never going to
# get. The result was that it blocked EVERY Bash call on the host instead of
# guarding anything. Only the absence of BOTH parsers still fails closed.
CMD=$(bp_json_get "$PAYLOAD" tool_input.command) || {
  echo "guard-git-mutations: BLOCKED -- no JSON parser available (neither jq nor perl+JSON::PP); blocking to avoid unenforced operation." >&2
  exit 2
}
[ -n "$CMD" ] || exit 0

deny() { echo "BLOCKED: $1 Command: $CMD" >&2; exit 2; }

# stash: list/show are read-only and explicitly allowed.
if grep -Eq '(^|[;&|[:space:]])git[[:space:]]+stash\b' <<<"$CMD" && \
   ! grep -Eq 'git[[:space:]]+stash[[:space:]]+(list|show)\b' <<<"$CMD"; then
  deny "git stash is forbidden: it silently removes uncommitted work from the tree and has already cost a completed fix-batch in this repo. To inspect your own changes use 'git diff' (read-only). 'git stash list' and 'git stash show' are allowed."
fi

# checkout/switch/restore/reset/clean: overwrite or delete uncommitted work.
# `git checkout -b` / `git switch -c` create a branch without touching content,
# but are still orchestrator-only here, so they are denied with the rest.
if grep -Eq '(^|[;&|[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(checkout|switch|restore|reset|clean)\b' <<<"$CMD"; then
  deny "git checkout/switch/restore/reset/clean are forbidden: each can discard uncommitted work. Change files only via Edit/Write. Use 'git diff' or 'git status' to inspect state."
fi

exit 0
