#!/usr/bin/env bash
# open-loops-gate.sh -- bash gate in front of scripts/almanac-open-loops.pl,
# for two registrations in hooks.json:
#
#   PreCompact    -> almanac-open-loops.pl precompact
#   SessionStart  -> almanac-open-loops.pl session-start, source "compact" only
#
# SessionStart fires on every startup, resume and clear in every session, and
# a perl spawn costs ~300 ms on the Windows host, so the event and source are
# checked here with builtins only and perl starts only when there is work.
#
# Silent no-op (exit 0, no output) when:
#   CCPRAXIS_OPEN_LOOPS_EXTRACTOR=1   we are inside the headless extractor that
#                                     this very hook launched; never recurse
#   CCPRAXIS_OPEN_LOOPS=0|off|false|no  the operator opted out
#   BP_LEDGER or BP_ROLE set          a butler fleet session, not an operator chat
#
# Fails open on everything: a missing script, an unreadable or timed-out
# payload, an unexpected event. It never exits 2 and never prints a decision,
# so it can never block a compaction. Bash 3.2 safe (macOS /bin/bash): the
# payload goes through the shared read-payload.sh reader; [[ =~ ]] and <<<
# both exist in 3.2.
set -u

[ "${CCPRAXIS_OPEN_LOOPS_EXTRACTOR-}" = 1 ] && exit 0
case "${CCPRAXIS_OPEN_LOOPS-}" in
    0|off|OFF|Off|false|FALSE|False|no|NO|No) exit 0 ;;
esac
[ -n "${BP_LEDGER-}" ] && exit 0
[ -n "${BP_ROLE-}" ] && exit 0

f="${CLAUDE_PLUGIN_ROOT-}/scripts/almanac-open-loops.pl"
[ -f "$f" ] || exit 0

case "${BASH_SOURCE[0]//\\//}" in
    */*) _rp_dir="${BASH_SOURCE[0]//\\//}"; _rp_dir="${_rp_dir%/*}" ;;
    *)   _rp_dir=. ;;
esac
[ -f "$_rp_dir/../scripts/read-payload.sh" ] || exit 0
. "$_rp_dir/../scripts/read-payload.sh"
declare -F ccp_read_payload >/dev/null || exit 0
P=''
ccp_read_payload P
[ "${CCP_PAYLOAD_STATE-}" = complete ] || exit 0
[ -n "$P" ] || exit 0

if [[ $P =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"PreCompact\" ]]; then
    verb=precompact
elif [[ $P =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"SessionStart\" ]]; then
    [[ $P =~ \"source\"[[:space:]]*:[[:space:]]*\"compact\" ]] || exit 0
    verb=session-start
else
    exit 0
fi

env -u SHELLOPTS perl "$f" "$verb" <<< "$P"
exit 0
