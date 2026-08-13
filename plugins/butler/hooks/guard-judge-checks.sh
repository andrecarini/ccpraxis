#!/usr/bin/env bash
# guard-judge-checks.sh — PreToolUse hook for Bash, mechanising done
# criterion 6 (h01 spec §2.2).
#
# THE RULE THIS MECHANISES. bp-harvest-judge.md's own Method already says a
# declared `checks:` entry is verified "via a declared artefact, never by
# re-running them" — and all three judge runs in the 2026-08-11 GSA fleet
# incident re-ran `pnpm run lint`, `pnpm run build` and `pnpm test` anyway
# (sources/2026-08-11-gsa-fleet-collapse.md:125). A second, independent
# instance of prose failing to bind in the SAME incident. This hook makes it
# mechanical instead of relying on the judge remembering its own contract.
#
# DELIBERATELY NARROW. This is NOT a general "declared artefact" verifier —
# no such schema exists anywhere in this repo today (bp-harvest-judge.md:23
# says only "a path inside your contracted slice", unspecified further), and
# inventing one is out of scope. It refuses exactly the pnpm/npm/yarn
# (run)? lint|build|test shape named in the incident evidence, and ONLY when
# BP_ROLE=harvest-judge — this rule exists nowhere else (resolve-judge and
# conformance-judge carry no such instruction in their own Method sections).
#
# ORDER IS SAFETY-CRITICAL. BP_LEDGER, then BP_ROLE, and ONLY THEN
# bp_hook_require_jq. jq does NOT exist on this Windows host — calling
# bp_hook_require_jq before the role check would hard-fail-closed on every
# Bash call in every session on this host, including interactive ones,
# whenever this hook happened to be registered. bp_hook_require_jq is safe
# to call ONLY once we already know we are inside a headless harvest-judge
# process, where jq is guaranteed by bp_require_sandbox/the container image.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"

[ -n "${BP_LEDGER:-}" ] || exit 0
[ "${BP_ROLE:-coordinator}" = "harvest-judge" ] || exit 0
bp_hook_require_jq

PAYLOAD=$(cat 2>/dev/null || true)
CMD=$(jq -r '.tool_input.command // empty' <<<"$PAYLOAD" 2>/dev/null)
[ -n "$CMD" ] || exit 0

# Deliberately narrow: the exact re-run shape named in the incident evidence
# (sources/2026-08-11-gsa-fleet-collapse.md:125 — "pnpm run lint, pnpm run
# build and pnpm test"). NOT a general artefact verifier — see header.
#
# Boundary class includes "(" so `result=$(pnpm run lint 2>&1)` (command
# substitution — capturing a check's own output, the exact shape a re-running
# judge would write) is caught. The optional path-prefix group before the
# binary name catches `/usr/bin/pnpm run lint` and
# `./node_modules/.bin/pnpm test` (a judge reaching for an absolute/relative
# path around a PATH problem). Deliberately NOT extended to quote characters
# (`'`/`"`) to also catch `bash -c 'pnpm test'`: that shape requires
# deliberate wrapping (closer to evasion than habit) and adding quotes to the
# boundary class produces false positives on ordinary commands that merely
# mention the words in a quoted string, e.g. a commit message — see h01
# fix-batch step 7 report. Left open per spec §2.2's narrow-by-design scope.
if printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:](])([^[:space:];&|]*/)?(pnpm|npm|yarn)[[:space:]]+(run[[:space:]]+)?(lint|build|test)\b'; then
  echo "BLOCKED: harvest judges verify a declared \`checks:\` entry via its recorded evidence, never by re-running it (bp-harvest-judge.md Method: 'via a declared artefact, never by re-running them'). Command: $CMD. Look for the check's recorded invocation+result inside your contracted slice instead." >&2
  exit 2
fi

exit 0
