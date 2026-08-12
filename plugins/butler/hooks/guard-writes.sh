#!/usr/bin/env bash
# guard-writes.sh — PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
#
# Enforces, inside coordinator sessions only:
#   1. All writes stay inside the package's declared scope
#      (BP_WRITE_SET ∪ BP_TEST_PATHS), the blueprint dir, or /tmp.
#   2. Role separation while a write-capable worker is in flight:
#        bp-implementer  may NOT touch BP_TEST_PATHS (tests are the immutable oracle)
#        bp-test-writer  may ONLY touch BP_TEST_PATHS (and the blueprint dir)
#        bp-ui-prober    may ONLY touch BP_TEST_PATHS (and the blueprint dir) —
#                        its screenshots/artifacts are written by test runs (Bash),
#                        not Edit/Write, so this is safe
#
# Exit 0 = allow. Exit 2 = block; stderr is fed back to the model.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate
bp_hook_require_jq

# longest_glob_match REL PATTERNS
#   PATTERNS: colon-separated, same dialect as lib.sh:match_any
#             (trailing '/' = prefix match; otherwise a bash glob whose '*' crosses '/')
#   Sets LGM_LEN = character length of the LONGEST pattern that matches REL, or -1 if none.
#   Sets LGM_PAT = that pattern, or '' when LGM_LEN is -1.
#   No subshell, no output; globals only. Never exits.
longest_glob_match() {
  local p="$1" pats="$2" pat
  LGM_LEN=-1
  LGM_PAT=''
  [ -n "$pats" ] || return 0
  local IFS=':'
  # step-6 red-team MINOR-10: $pats is unquoted below (required, so ':'-split
  # words re-split on IFS) but that also subjects each word to pathname
  # expansion against the hook's cwd -- a '*' entry then silently stops
  # covering brand-new files once run from a directory containing matches.
  # set -f for the duration of the loop only, restored unconditionally after.
  set -f
  # shellcheck disable=SC2086
  for pat in $pats; do
    [ -n "$pat" ] || continue
    local hit=0
    case "$pat" in
      */) if [[ "$p" == "$pat"* || "$p/" == "$pat" ]]; then hit=1; fi ;;
      *)  # shellcheck disable=SC2053
          if [[ "$p" == $pat ]]; then hit=1; fi ;;
    esac
    if [ "$hit" -eq 1 ] && [ "${#pat}" -gt "$LGM_LEN" ]; then
      LGM_LEN=${#pat}
      LGM_PAT=$pat
    fi
  done
  set +f
  return 0
}

PAYLOAD=$(cat)
FP=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$PAYLOAD")
[ -n "$FP" ] || exit 0
CWD=$(jq -r '.cwd // empty' <<<"$PAYLOAD"); CWD=${CWD:-$PWD}

case "$FP" in
  /*) ABS="$FP" ;;
  *)  ABS="$CWD/$FP" ;;
esac
ABS=$(realpath -m "$ABS")

# Always allowed: the blueprint's own dir (ledger, reports, specs) and /tmp.
case "$ABS" in
  "$BP_DIR"/*|/tmp/*) exit 0 ;;
esac

REL=$(realpath -m --relative-to="$BP_PROJECT_ROOT" "$ABS")
case "$REL" in
  ../*)
    echo "BLOCKED: $ABS is outside the project root ($BP_PROJECT_ROOT). Coordinator sessions may only write inside the project, the blueprint dir, or /tmp." >&2
    exit 2 ;;
esac

longest_glob_match "$REL" "${BP_TEST_PATHS:-}"; T_LEN=$LGM_LEN; T_PAT=$LGM_PAT
longest_glob_match "$REL" "${BP_WRITE_SET:-}";  W_LEN=$LGM_LEN
IN_TESTS=1
if [ "$T_LEN" -ge 0 ] && [ "$T_LEN" -ge "$W_LEN" ]; then IN_TESTS=0; fi

# step-6 red-team MAJOR-2/MINOR-8: a write_set entry naming a REAL test file
# (this repo's immutable-oracle shape, documented in CLAUDE.md's "Tests"
# section: plugins/<plugin>/tests/t/NN-name.t) must never win a specificity
# race against a test_paths prefix that already covers it -- an implementer
# could otherwise edit the very file it is being judged by, silently,
# whenever write_set happens to name that file more specifically (character-
# length-wise) than the test_paths prefix, including via the sanctioned
# --widen-write-set unblock. This is deliberately narrower than "any
# write_set entry nested under test_paths" -- AC-1's legitimate non-test
# scripts/bp-blueprint.pl is ALSO textually nested under a broad
# test_paths='plugins/butler/' prefix, so nesting alone cannot be the signal.
# It targets the actual test-FILE shape, not mere directory containment.
if [ "$T_LEN" -ge 0 ]; then
  case "$REL" in
    */tests/t/*.t|tests/t/*.t) IN_TESTS=0 ;;
  esac
fi

WORKER=""
MARKER=$(marker_path)
[ -f "$MARKER" ] && WORKER=$(cat "$MARKER" 2>/dev/null || true)

if [ "$IN_TESTS" -eq 0 ] && [[ "$WORKER" == *bp-implementer* ]]; then
  echo "BLOCKED: bp-implementer may not modify test files ($REL; matched test_paths pattern '$T_PAT'). Tests are the immutable oracle for this package. If a test is wrong, finish what you can, then report the exact test, why it contradicts the spec, and your evidence — the coordinator decides." >&2
  exit 2
fi

if [ "$IN_TESTS" -ne 0 ] && [[ "$WORKER" == *bp-test-writer* ]]; then
  echo "BLOCKED: bp-test-writer may only write under the package's test paths ($BP_TEST_PATHS), not $REL. If implementation scaffolding is genuinely required, report it back instead of writing it." >&2
  exit 2
fi

if [ "$IN_TESTS" -ne 0 ] && [[ "$WORKER" == *bp-ui-prober* ]]; then
  echo "BLOCKED: bp-ui-prober may only write under the package's test paths ($BP_TEST_PATHS), not $REL. Prober artifacts (screenshots, fixtures) are produced by test *runs*, not by Edit/Write. If something else genuinely must change, report it back instead of writing it." >&2
  exit 2
fi

if [ "$IN_TESTS" -eq 0 ]; then exit 0; fi
if match_any "$REL" "${BP_WRITE_SET:-}"; then exit 0; fi

echo "BLOCKED: $REL is outside this package's write set. write_set=$BP_WRITE_SET test_paths=${BP_TEST_PATHS:-—}. If this file genuinely must change, that is a scope problem: record it in the ledger under 'Next action' / escalation, set status to blocked or finish without it — the orchestrator re-scopes packages, coordinators do not." >&2
exit 2
