#!/usr/bin/env bash
# guard-bash.sh — PreToolUse hook for Bash inside coordinator sessions.
#
# Denies working-tree mutations and deploy/publish actions that belong to the
# orchestrator (or to nobody). This is the mechanical form of the HARD RULES:
# a batch-fix agent once ran `git checkout` and wiped ~300 lines of review-fix
# work — that class of incident becomes a denied tool call here.
#
# Extension point: BP_BASH_EXTRA_DENY may hold an additional ERE.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate
bp_hook_require_jq

PAYLOAD=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<<"$PAYLOAD")
[ -n "$CMD" ] || exit 0

deny() { echo "BLOCKED: $1 Command: $CMD" >&2; exit 2; }

# --- git working-tree mutations / history rewrites / publishing -------------
if grep -Eq '(^|[;&|[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(checkout|switch|restore|reset|clean|rebase|merge|commit|push)\b' <<<"$CMD"; then
  deny "git working-tree/history mutations are reserved for the orchestrator. Coordinators and workers change files only via Edit/Write; commits happen after harvest."
fi
if grep -Eq '(^|[;&|[:space:]])git[[:space:]]+stash\b' <<<"$CMD" && \
   ! grep -Eq 'git[[:space:]]+stash[[:space:]]+(list|show)\b' <<<"$CMD"; then
  deny "git stash mutations are forbidden in coordinator sessions (list/show are fine)."
fi

# --- rm -rf outside scratch areas -------------------------------------------
if grep -Eq '(^|[;&|[:space:]])rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f|(^|[;&|[:space:]])rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r' <<<"$CMD"; then
  if ! grep -Eq "(/tmp/|${BP_DIR}|integration_test/screenshots)" <<<"$CMD"; then
    deny "rm -rf is only allowed under /tmp, the blueprint dir, or the test screenshot dir. If you found unexpected state, STOP and record it in the ledger rather than cleaning up."
  fi
fi

# --- deploys / publishing ----------------------------------------------------
if grep -Eq '(^|[;&|[:space:]])firebase[[:space:]]+deploy\b|(^|[;&|[:space:]])gcloud[[:space:]][^;|&]*deploy\b|(^|[;&|[:space:]])npm[[:space:]]+publish\b' <<<"$CMD"; then
  deny "deploys and publishing never happen from coordinator sessions (CI-only by project policy)."
fi

# --- project-specific extra denials ------------------------------------------
if [ -n "${BP_BASH_EXTRA_DENY:-}" ] && grep -Eq "$BP_BASH_EXTRA_DENY" <<<"$CMD"; then
  deny "matched BP_BASH_EXTRA_DENY policy."
fi

exit 0
