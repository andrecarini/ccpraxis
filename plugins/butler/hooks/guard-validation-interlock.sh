#!/usr/bin/env bash
# guard-validation-interlock.sh — PreToolUse hook for Bash.
#
# Implements
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/w03-validation-interlock-spec.md
# §2.1. Denies a validation-shaped Bash command (test/build/lint, see
# VALIDATION_DENYLIST below) whenever a write-capable worker's marker is live
# and fresh — headless coordinators via the existing marker_path() (lib.sh),
# interactive drive-solo sessions via a new, identically-shaped
# $DATA/.drive-solo/.active-worker marker (written by track-worker-solo.sh).
#
# DELIBERATELY NOT bp_hook_gate'd: this hook's entire purpose is to also fire
# in an interactive drive-solo session, which is exactly the session
# bp_hook_gate would silently exempt (BP_LEDGER/BP_DIR/BP_PROJECT_ROOT are
# exported only by bp-launch.sh into coordinator processes). Sources lib.sh
# for bp_json_get / marker_path / bp_find_data_dir only — never
# bp_hook_require_jq, which fails closed and would turn every host without
# jq (this one included) into an outage the moment this hook fires.
#
# Fail-open on every ambiguity: no JSON parser, malformed payload, missing
# marker, unresolved data dir — all resolve to "allow". A validation
# interlock that can wedge an interactive session is a worse defect than the
# false-red it exists to prevent.
#
# VALIDATION_DENYLIST scope (spec §2.1.1): a bounded, documented ERE list,
# not a claimed-exhaustive classifier. Covers pnpm/npm/yarn test|build|lint,
# npx vitest|jest|mocha|playwright, pytest/prove, go/cargo/flutter/dart
# test|analyze. Does NOT cover every ecosystem's build tooling (dotnet test,
# mvn test, bundle exec rspec, ...) — extend deliberately if a project needs it.
#
# fixbatch step7 / F2 — THREAT MODEL RULING, made explicit rather than tuned
# around implicitly. Red-team found the same raw-substring VALIDATION_RE both
# FALSE-BLOCKING an ordinary `git commit -m "fix: npm test now passes"` (the
# phrase merely appears in a commit message) and being BYPASSED by shell
# quote-reconstruction (`npm te''st`, `npm tes\t` — bash reconstitutes both
# into the literal command `npm test`, but the literal payload text never
# contains that substring). Tightening the regex worsens the bypass;
# loosening it worsens the false block — they cannot both be fixed by tuning
# one pattern, so this hook's job is decided on the THREAT MODEL, not the
# regex:
#
#   Is this guard defending against an ADVERSARY (something trying to defeat
#   it) or an ACCIDENT (a well-intentioned agent validating out of turn)?
#
# RULING: ACCIDENT. Every dispatcher of a Bash command this hook can see is
# either a butler worker following its own protocol or an interactive driver
# — neither is adversarial, and nothing in this package's scope (§0 of the
# spec) claims otherwise; the incident this whole package exists to prevent
# (sources/2026-08-12-gsa-worker-observability.md Gap C) was an ordinary
# concurrent `flutter test`/`dart analyze`, not an attempt to evade a guard.
# Given that ruling:
#   - The FALSE BLOCK is the real defect: an innocent commit or echo getting
#     denied, with a misleading message about a validation interlock, harms a
#     well-intentioned agent for no reason. FIXED below via
#     bp_strip_shell_noise() (scripts/bp-lib.sh, lifted from mark-wakeup.sh's
#     byte-scanner) — VALIDATION_RE is now matched against the command with
#     every quoted span, comment, and heredoc body blanked out first, so a
#     denylisted phrase sitting inert inside a string or comment can no
#     longer classify the whole command as validation-shaped.
#   - The BYPASS (quote-reconstruction defeating classification) is an
#     ACCEPTED, DOCUMENTED LIMIT, not fixed here: under the accident threat
#     model, nobody is deliberately spelling `npm te''st` to dodge this hook
#     — a well-intentioned worker/driver has no reason to write a command
#     that way, and if the classifier's own false-block fix (above) means
#     ordinary phrasing is never wrongly denied, there is no accidental
#     pressure toward that spelling either. Closing it would require actual
#     shell parsing (out of scope for a bash hook, per §2.1.1's own bounded-
#     denylist framing), so it is named here rather than silently accepted.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
# shellcheck source=../scripts/bp-lib.sh
[ -r "$HOOK_DIR/../scripts/bp-lib.sh" ] && source "$HOOK_DIR/../scripts/bp-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
CMD=$(bp_json_get "$PAYLOAD" tool_input.command 2>/dev/null)
[ -n "$CMD" ] || exit 0

VALIDATION_RE='(^|[;&|[:space:]])(pnpm|npm|yarn)[[:space:]]+(run[[:space:]]+)?(test|build|lint)\b'
VALIDATION_RE="$VALIDATION_RE"'|(^|[;&|[:space:]])npx[[:space:]]+(vitest|jest|mocha|playwright)\b'
VALIDATION_RE="$VALIDATION_RE"'|(^|[;&|[:space:]])(pytest|prove)\b'
VALIDATION_RE="$VALIDATION_RE"'|(^|[;&|[:space:]])(go|cargo|flutter|dart)[[:space:]]+(test|analyze)\b'

# MATCH_TEXT: the quote/comment/heredoc-stripped command when bp_strip_shell_noise
# (and the perl it needs) is available and produces non-empty output; otherwise
# fall back to the RAW command, the pre-fix behavior — an unavailable stripper
# must not silently disable the interlock, only lose its false-block fix.
MATCH_TEXT="$CMD"
if command -v bp_strip_shell_noise >/dev/null 2>&1; then
  STRIPPED=$(printf '%s' "$CMD" | bp_strip_shell_noise)
  [ -n "$STRIPPED" ] && MATCH_TEXT="$STRIPPED"
fi

printf '%s' "$MATCH_TEXT" | grep -Eq "$VALIDATION_RE" || exit 0

MARKER=""
if [ -n "${BP_LEDGER:-}" ] && [ -n "${BP_DIR:-}" ] && [ -n "${BP_PROJECT_ROOT:-}" ]; then
  MARKER=$(marker_path)
else
  CWD=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null); CWD=${CWD:-$PWD}
  DATA=$(bp_find_data_dir "$CWD" 2>/dev/null) || exit 0
  [ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ] || exit 0
  MARKER="$DATA/.drive-solo/.active-worker"
fi

[ -s "$MARKER" ] || exit 0
CURRENT=$(cat "$MARKER" 2>/dev/null || true)
[ -n "$CURRENT" ] || exit 0
case "$CURRENT" in
  *bp-implementer*|*bp-test-writer*|*bp-ui-prober*) : ;;
  *) exit 0 ;;
esac

STALE_MIN="${CCPRAXIS_VALIDATION_STALE_MIN:-180}"
case "$STALE_MIN" in ''|*[!0-9]*) STALE_MIN=180 ;; esac
[ "$STALE_MIN" -gt 0 ] 2>/dev/null || STALE_MIN=180

NOW=$(date +%s 2>/dev/null || echo 0)
MTIME=$(stat -c %Y "$MARKER" 2>/dev/null || echo 0)
if [ "$NOW" -gt 0 ] && [ "$MTIME" -gt 0 ]; then
  AGE_MIN=$(( (NOW - MTIME) / 60 ))
  [ "$AGE_MIN" -lt "$STALE_MIN" ] || exit 0
fi

echo "BLOCKED (validation interlock): a write-capable worker ($CURRENT) is currently in flight -- running \"$CMD\" now can read its live or leftover temp state and report a false red that looks exactly like a real regression. The command was NOT executed. Wait for the worker to return (or for its marker to age out after $STALE_MIN minutes if it has crashed), then re-run." >&2
exit 2
