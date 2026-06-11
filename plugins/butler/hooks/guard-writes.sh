#!/usr/bin/env bash
# guard-writes.sh — PreToolUse hook for Edit|Write|MultiEdit|NotebookEdit.
#
# Enforces, inside coordinator sessions only:
#   1. All writes stay inside the package's declared scope
#      (BP_WRITE_SET ∪ BP_TEST_PATHS), the blueprint dir, or /tmp.
#   2. Role separation while a write-capable worker is in flight:
#        bp-implementer  may NOT touch BP_TEST_PATHS (tests are the immutable oracle)
#        bp-test-writer  may ONLY touch BP_TEST_PATHS (and the blueprint dir)
#
# Exit 0 = allow. Exit 2 = block; stderr is fed back to the model.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate
bp_hook_require_jq

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

IN_TESTS=1
match_any "$REL" "${BP_TEST_PATHS:-}" && IN_TESTS=0

WORKER=""
MARKER=$(marker_path)
[ -f "$MARKER" ] && WORKER=$(cat "$MARKER" 2>/dev/null || true)

if [ "$IN_TESTS" -eq 0 ] && [[ "$WORKER" == *bp-implementer* ]]; then
  echo "BLOCKED: bp-implementer may not modify test files ($REL). Tests are the immutable oracle for this package. If a test is wrong, finish what you can, then report the exact test, why it contradicts the spec, and your evidence — the coordinator decides." >&2
  exit 2
fi

if [ "$IN_TESTS" -ne 0 ] && [[ "$WORKER" == *bp-test-writer* ]]; then
  echo "BLOCKED: bp-test-writer may only write under the package's test paths ($BP_TEST_PATHS), not $REL. If implementation scaffolding is genuinely required, report it back instead of writing it." >&2
  exit 2
fi

if [ "$IN_TESTS" -eq 0 ]; then exit 0; fi
if match_any "$REL" "${BP_WRITE_SET:-}"; then exit 0; fi

echo "BLOCKED: $REL is outside this package's write set. write_set=$BP_WRITE_SET test_paths=${BP_TEST_PATHS:-—}. If this file genuinely must change, that is a scope problem: record it in the ledger under 'Next action' / escalation, set status to blocked or finish without it — the orchestrator re-scopes packages, coordinators do not." >&2
exit 2
