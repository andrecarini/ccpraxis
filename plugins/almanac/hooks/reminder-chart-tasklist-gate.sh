#!/usr/bin/env bash
# reminder-chart-tasklist-gate.sh -- sampling gate for the chart-reminder nudge
# (reminder-chart-tasklist.pl). Fires on every Bash PostToolUse call; exits
# early unless this is a real session's 20th-sampled Bash call, then hands off
# to the perl script. Extracted out of hooks.json's inline "command" string
# (bug 20261012-001738-1ec6): the logic uses bash-only syntax ([[ =~ ]],
# (( )), ${BASH_REMATCH}, <<<), which only runs correctly under bash -- the
# two sibling hooks in this file already route through
# `exec env -u SHELLOPTS bash "$f"`; this one originally didn't, and broke
# under the sandbox's /bin/sh (dash), which rejects that syntax outright.
set -u

f="${CLAUDE_PLUGIN_ROOT}/hooks/reminder-chart-tasklist.pl"
[ -f "$f" ] || exit 0

H="${ALMANAC_HOME:-${HOME:-$USERPROFILE}}"
[ -n "$H" ] || exit 0
case "$H" in /*|[A-Za-z]:/*) ;; *) exit 0 ;; esac

# The payload is read by scripts/read-payload.sh, the one reader the bash hooks
# of almanac and butler share (sourced, so no process): "read -N" on bash
# >= 4.1, a NUL-delimited read on macOS /bin/bash 3.2, where -N is an
# invalid option (it once read nothing and, with `set -u`, made the next
# line an exit-1 error on EVERY PostToolUse call). The reminder is advisory,
# so every failure is silence: a timeout leaves P empty on every bash and
# the gate exits; a payload over 8 MiB is still sampled from its first part,
# as before; a missing library exits.
case "${BASH_SOURCE[0]//\\//}" in
    */*) _rp_dir="${BASH_SOURCE[0]//\\//}"; _rp_dir="${_rp_dir%/*}" ;;
    *)   _rp_dir=. ;;
esac
[ -f "$_rp_dir/../scripts/read-payload.sh" ] || exit 0
. "$_rp_dir/../scripts/read-payload.sh"
declare -F ccp_read_payload >/dev/null || exit 0
P=''
ccp_read_payload P
[ -n "$P" ] || exit 0

[[ $P =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"PostToolUse\" ]] || exit 0
[[ $P =~ \"agent_id\"[[:space:]]*:[[:space:]]*\"[^\"]*\" ]] && exit 0
if [[ $P =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]]; then
    SID="${BASH_REMATCH[1]}"
else
    exit 0
fi

D="$H/.claude/almanac-state/chart-reminder/$SID.t"
[ -d "$D" ] || { mkdir -p "$D" 2>/dev/null || exit 0; }
[ -d "$D" ] || exit 0

WM=0
read -r WM 2>/dev/null < "$D/.watermark" || WM=0
[[ $WM =~ ^[0-9]+$ ]] || WM=0

MAX=0
for t in "$D"/*; do
    b="${t##*/}"
    [[ $b =~ ^[0-9]+$ ]] || continue
    (( b > MAX )) && MAX=$b
done
BASE=$MAX
(( WM > BASE )) && BASE=$WM

N=0
i=1
while (( i <= 1000 )); do
    cand=$(( BASE + i ))
    set -C
    : > "$D/$cand" 2>/dev/null
    ok=$?
    set +C
    if [ "$ok" -eq 0 ]; then
        N=$cand
        break
    fi
    i=$(( i + 1 ))
done
[ "$N" -gt 0 ] || exit 0

(( N % 20 == 0 )) || exit 0

exec env -u SHELLOPTS perl "$f" "$N" "$SID" <<< "$P"
exit 0
