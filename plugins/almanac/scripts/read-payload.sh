# read-payload.sh -- the one hook-payload reader for the bash hooks of the
# almanac and butler plugins. SOURCED, never executed:
#
#     . "<this plugin>/scripts/read-payload.sh"
#     ccp_read_payload P
#
# Sourcing starts no process, and nothing below starts one either: bash
# builtins only, no command substitution, no pipe, no external command. That
# keeps the Windows hook budget (one process creation costs ~300 ms there)
# exactly where it was before this file existed.
#
# TWO COPIES, ONE IMPLEMENTATION. plugins/almanac/scripts/read-payload.sh and
# plugins/butler/scripts/read-payload.sh are byte-identical, and
# plugins/butler/tests/t/read-payload-lib.t goes red the moment they differ.
# Each plugin carries its own copy because every payload-reading hook of that
# plugin goes through it: a hook that sourced it from the sibling plugin's
# tree would read nothing at all wherever the two plugins are not installed
# side by side. Edit both, or neither.
#
# ccp_read_payload NAME [SECONDS]
#   Reads stdin once into the variable NAME, bounded by 8 MiB (8388608
#   characters) and by SECONDS: a whole number from 1 to 10, else
#   BP_PAYLOAD_READ_TIMEOUT when that is one, else 10. Sets
#   CCP_PAYLOAD_STATE to exactly one of:
#     complete   the input ended in time; NAME holds all of it (maybe empty).
#     truncated  the read stopped before the end of the input: NAME holds
#                the first 8 MiB. On bash < 4.1 a NUL byte also stops it
#                there (bash >= 4.1 drops NULs and reads on); a JSON
#                payload never contains a raw NUL.
#     timeout    SECONDS passed before the input ended. NAME is EMPTY.
#   Returns 0 for complete and 1 otherwise (2 for a bad NAME). What a hook
#   does with truncated or timeout is that hook's own contract: a guard
#   that denies writes refuses the call, an advisory hook exits quietly.
#
# WHY A TIMEOUT EMPTIES NAME ON EVERY BASH. bash 4 and later keep what a
# timed-out read had received and return a status above 128. bash 3.2 -- macOS
# /bin/bash, which runs every hook on a Mac -- returns 1, the status of an
# ordinary end of input, and throws the partial input away (NAME keeps its
# old value, which is why NAME is cleared first). A hook that scanned the
# partial text would judge one stalled call one way on Windows and another
# way on a Mac; emptying it everywhere makes them agree. bash 3.2's timeout
# is recognised by elapsed time: its read -t takes whole seconds and
# $SECONDS ticks in whole seconds, so a real timeout always measures at
# least SECONDS. The converse -- an input whose end took more than
# SECONDS-1 seconds to arrive -- reads as a timeout too, which errs toward
# the hook's timeout contract and never toward judging a partial payload.
#
# THE READ ITSELF. bash >= 4.1 keeps "read -N", the bulk read and the
# Windows fast path, byte-for-byte as run-hook.sh always ran it. Older bash
# has no -N (it is an invalid option there, status 2, nothing read -- the
# almanac guards once failed open on exactly that), so it reads with
# "-d ''" (to the end of the input) plus "-n" for the same 8 MiB cap: still
# a builtin, but one byte per read() call, measured at ~0.35 s per MiB on
# macOS, so the cap also bounds it to about 3 s.
#
# This file never contains a lone pipe character, not even in a case
# pattern: run-hook.sh's spawn-budget test greps the sources it runs for one.

ccp_read_payload() {
    local _ccp_t=${2-} _ccp_rc=1 _ccp_t0=0
    CCP_PAYLOAD_STATE=
    case $1 in
        '') return 2 ;;
        [0-9]*) return 2 ;;
        *[!A-Za-z0-9_]*) return 2 ;;
    esac
    [ -n "$_ccp_t" ] || _ccp_t=${BP_PAYLOAD_READ_TIMEOUT-}
    case $_ccp_t in
        '') _ccp_t=10 ;;
        *[!0-9]*) _ccp_t=10 ;;
        ???*) _ccp_t=10 ;;
    esac
    if [ "$_ccp_t" -lt 1 ]; then
        _ccp_t=10
    elif [ "$_ccp_t" -gt 10 ]; then
        _ccp_t=10
    fi
    printf -v "$1" '%s' ''
    if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ]; then
        IFS= read -r -N 8388608 -t "$_ccp_t" "$1"
        _ccp_rc=$?
    elif [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 1 ]; then
        IFS= read -r -N 8388608 -t "$_ccp_t" "$1"
        _ccp_rc=$?
    else
        _ccp_t0=$SECONDS
        IFS= read -r -d '' -n 8388608 -t "$_ccp_t" "$1"
        _ccp_rc=$?
        if [ "$_ccp_rc" -eq 1 ] && [ $((SECONDS - _ccp_t0)) -ge "$_ccp_t" ]; then
            _ccp_rc=142
        fi
    fi
    if [ "$_ccp_rc" -gt 128 ]; then
        printf -v "$1" '%s' ''
        CCP_PAYLOAD_STATE=timeout
        return 1
    fi
    if [ "$_ccp_rc" -eq 0 ]; then
        CCP_PAYLOAD_STATE=truncated
        return 1
    fi
    CCP_PAYLOAD_STATE=complete
    return 0
}
