#!/bin/bash
# ccpraxis.sh -- thin dispatcher shim for steward's host-side scripts.
#
# WHY THIS EXISTS. The skills that drive these scripts spell out a 70-character
# absolute path on every invocation:
#
#   perl ~/.claude/ccpraxis/plugins/steward/scripts/update-research.pl gather
#
# That works, and the skill file carries it so nothing is being remembered --
# but it is brittle prose. Any move of the tree edits every skill that names it,
# and a typo surfaces as "file not found" rather than anything diagnosable.
# One shim, one PATH entry, and the paths live in exactly one place.
#
#   ccpraxis research gather --current 2.1.219
#   ccpraxis vault-sync reports "message"
#   ccpraxis usage-audit
#   ccpraxis binary list
#
# Passthrough: everything after the subcommand goes to the script untouched.
set -e

CCPRAXIS_ROOT="${HOME}/.claude/ccpraxis"
STEWARD="${CCPRAXIS_ROOT}/plugins/steward/scripts"

usage() {
  cat >&2 <<'EOF'
ccpraxis -- dispatcher for ccpraxis host-side tools

  ccpraxis research     <args>   update-research.pl      (release research + store)
  ccpraxis vault-sync   <args>   vault-namespace-sync.pl (commit+push one vault namespace)
  ccpraxis usage-audit  <args>   usage-audit.pl          (token spend across transcripts)
  ccpraxis binary       <args>   claude-binary-backup.pl (binary snapshots / restore)
  ccpraxis sensitive    <args>   sensitive-check.pl      (secret scan)

Anything after the subcommand is passed through unchanged.
EOF
  exit 2
}

case "${1:-}" in
  research)    shift; SCRIPT="$STEWARD/update-research.pl" ;;
  vault-sync)  shift; SCRIPT="$STEWARD/vault-namespace-sync.pl" ;;
  usage-audit) shift; SCRIPT="$STEWARD/usage-audit.pl" ;;
  binary)      shift; SCRIPT="$STEWARD/claude-binary-backup.pl" ;;
  sensitive)   shift; SCRIPT="$STEWARD/sensitive-check.pl" ;;
  ''|-h|--help|help) usage ;;
  *) echo "ccpraxis: unknown subcommand '$1'" >&2; usage ;;
esac

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found." >&2
  echo "       Re-run the ccpraxis installer (perl ~/.claude/ccpraxis/install.pl --confirm)." >&2
  exit 1
fi

exec perl "$SCRIPT" "$@"
