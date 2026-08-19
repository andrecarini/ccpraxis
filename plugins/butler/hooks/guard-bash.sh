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
# shellcheck source=../scripts/bp-lib.sh
# Sourced ONLY for bp_strip_shell_noise (t09 guard-hooks-stripping). Tolerant:
# unreadable degrades the block below to raw matching, never to allow.
[ -r "$HOOK_DIR/../scripts/bp-lib.sh" ] && source "$HOOK_DIR/../scripts/bp-lib.sh"

PAYLOAD=$(cat)
CMD=$(jq -r '.tool_input.command // empty' <<<"$PAYLOAD")
[ -n "$CMD" ] || exit 0

# t09 (guard-hooks-stripping). THREAT MODEL: ACCIDENT, not ADVERSARY -- same
# ruling already on record for mark-wakeup.sh/guard-validation-interlock.sh,
# not re-derived here. This hook's real defect is a FALSE POSITIVE: a
# forbidden verb merely quoted inside an argument (a --text flag, a commit
# message) reads identically to a real invocation under a raw grep. The
# residual left knowingly unfixed: a BARE, unquoted MENTION (no reader-veto
# is added -- spec SS6 rules that out-of-scope pending a confirmed instance).
# Fail direction: above BP_GUARD_MAX_STRIP_BYTES, or when bp_strip_shell_noise
# is unavailable/empty, MATCH_TEXT stays the RAW command -- never skip the
# match itself. Raw-matching is this guard's own pre-existing, already
# load-bearing behavior; falling back to it costs nothing new and never
# opens a hole for a BLOCKING guard.
MATCH_TEXT="$CMD"
: "${BP_GUARD_MAX_STRIP_BYTES:=8000}"
case "$BP_GUARD_MAX_STRIP_BYTES" in
  ''|*[!0-9]*) BP_GUARD_MAX_STRIP_BYTES=8000 ;;
esac
#
# CARRIER RE-CHECK -- do NOT trust a strip when the raw command hides an
# invocation inside a shellword or a command substitution.
#
# bp_strip_shell_noise blanks quoted spans, so `bash -c "<mutation>"` strips to
# `bash -c` and a genuinely executable mutation disappears before any matcher
# below sees it. Measured, not theorised:
#
#   raw  bash -c "<mutation>"   ->  stripped  bash -c
#   raw  sh -c '<mutation>'     ->  stripped  sh -c
#
# guard-git-mutations.sh already re-checks for exactly this before trusting its
# own strip. That protection was applied there and NOT here when stripping was
# introduced -- the insight was applied to one hook instead of to the class,
# which is this repo's most frequently repeated mistake. This hook needs it
# most: it uniquely covers rebase/merge/commit/push, rm -rf, and deploy and
# publish actions, with no other guard behind it.
#
# When a carrier is present, match the RAW text. That reinstates the false
# positive the stripping was meant to remove, for those commands only, which is
# the correct trade for a hook whose job is to BLOCK: a false positive costs a
# reworded command, a false negative costs the work the guard exists to protect.
if [ "${#CMD}" -le "$BP_GUARD_MAX_STRIP_BYTES" ] && command -v bp_strip_shell_noise >/dev/null 2>&1; then
  STRIPPED=$(printf '%s' "$CMD" | bp_strip_shell_noise)
  if [ -n "$STRIPPED" ] \
     && ! grep -Eq '(^|[;&|[:space:]])(ba|z|k|da)?sh[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-c\b' <<<"$CMD" \
     && ! grep -Eq '`|\$\(' <<<"$CMD"; then
    MATCH_TEXT="$STRIPPED"
  fi
fi

deny() { echo "BLOCKED: $1 Command: $CMD" >&2; exit 2; }

# --- git working-tree mutations / history rewrites / publishing -------------
if grep -Eq '(^|[;&|[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(checkout|switch|restore|reset|clean|rebase|merge|commit|push)\b' <<<"$MATCH_TEXT"; then
  deny "git working-tree/history mutations are reserved for the orchestrator. Coordinators and workers change files only via Edit/Write; commits happen after harvest."
fi
if grep -Eq '(^|[;&|[:space:]])git[[:space:]]+stash\b' <<<"$MATCH_TEXT" && \
   ! grep -Eq 'git[[:space:]]+stash[[:space:]]+(list|show)\b' <<<"$MATCH_TEXT"; then
  deny "git stash mutations are forbidden in coordinator sessions (list/show are fine)."
fi

# --- rm -rf outside scratch areas -------------------------------------------
if grep -Eq '(^|[;&|[:space:]])rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f|(^|[;&|[:space:]])rm[[:space:]]+-[a-zA-Z]*f[a-zA-Z]*r' <<<"$MATCH_TEXT"; then
  if ! grep -Eq "(/tmp/|${BP_DIR}|integration_test/screenshots)" <<<"$MATCH_TEXT"; then
    deny "rm -rf is only allowed under /tmp, the blueprint dir, or the test screenshot dir. If you found unexpected state, STOP and record it in the ledger rather than cleaning up."
  fi
fi

# --- deploys / publishing ----------------------------------------------------
if grep -Eq '(^|[;&|[:space:]])firebase[[:space:]]+deploy\b|(^|[;&|[:space:]])gcloud[[:space:]][^;|&]*deploy\b|(^|[;&|[:space:]])npm[[:space:]]+publish\b' <<<"$MATCH_TEXT"; then
  deny "deploys and publishing never happen from coordinator sessions (CI-only by project policy)."
fi

# --- project-specific extra denials ------------------------------------------
if [ -n "${BP_BASH_EXTRA_DENY:-}" ] && grep -Eq "$BP_BASH_EXTRA_DENY" <<<"$MATCH_TEXT"; then
  deny "matched BP_BASH_EXTRA_DENY policy."
fi

exit 0
