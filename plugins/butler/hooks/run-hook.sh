#!/usr/bin/env bash
# run-hook.sh -- the bash-only entry wrapper (package 03 of blueprint
# hook-continuity-remake). Contract: specs/03-hook-core-spec.md sec 2.6;
# architecture: plugins/butler/docs/hook-architecture.md "Entry path and
# process budget". Registered by package 16's cutover -- every hooks.json
# and settings.json command that runs a BpHook module goes through this
# file.
#
# Usage: run-hook.sh <Module> [--pre <clause>]... [--] [hook args...]
#
# Bash builtins only on the path to the early exit: no $(...), no bare pipe
# and no external command before the final exec. Exits 0 on every path
# except that the perl process exits 2 only when BpHook::main returned 2.
# NOTE: this file deliberately never uses a literal single "|" character
# (not even inside a case pattern) because hook-core-spawn-budget.t's S6
# greps the stripped source for a bare pipe; every alternation below is
# written as separate case arms or a helper function instead.

# R2-n2/L8: the clause micro-language splits on IFS=, below in three places
# ("for atom in $clause") and that word-splitting is otherwise subject to
# bash's implicit pathname expansion -- an atom like "text:*" would glob
# against the wrapper's cwd instead of staying the literal string the
# operator wrote. Disable globbing for the whole script: nothing here below
# this line relies on filename expansion (case patterns and parameter
# expansion are unaffected by noglob), and exec's argv is passed literally.
set -f

module=$1
[ -n "$module" ] || exit 0
shift

pre_clauses=()
while [ "$1" = "--pre" ]; do
    pre_clauses+=("$2")
    shift
    shift
done
if [ "$1" = "--" ]; then
    shift
fi

r=${BASH_SOURCE[0]}
r=${r//\\//}
case $r in
    */*) ;;
    *) r="./$r" ;;
esac

_bp_is_abs() {
    case $1 in
        /*) return 0 ;;
    esac
    case $1 in
        [A-Za-z]:[\\/]*) return 0 ;;
    esac
    return 1
}

_bp_env_only_clause() {
    local clause=$1 atom
    [ -z "$clause" ] && return 0
    local IFS=,
    for atom in $clause; do
        case $atom in
            ledger) ;;
            coordinator) ;;
            stopfile) ;;
            acstanddown) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# _bp_ac_data_dir() -- package 11, spec 2.9: sets _BP_AC_DATA_DIR to
# CCPRAXIS_DATA_DIR when absolute; otherwise CLAUDE_PROJECT_DIR +
# /.ccpraxis-local-data; otherwise empty. A global, not a return value (no
# $(...) anywhere in this file -- hook-core-spawn-budget.t's S6). Bash
# builtins only; backslashes normalised as every other atom here does.
_BP_AC_DATA_DIR=
_bp_ac_data_dir() {
    _BP_AC_DATA_DIR=
    if [ -n "$CCPRAXIS_DATA_DIR" ] && _bp_is_abs "$CCPRAXIS_DATA_DIR"; then
        _BP_AC_DATA_DIR=${CCPRAXIS_DATA_DIR//\\//}
    elif [ -n "$CLAUDE_PROJECT_DIR" ]; then
        local p=${CLAUDE_PROJECT_DIR//\\//}
        _BP_AC_DATA_DIR="${p%/}/.ccpraxis-local-data"
    fi
}

# _bp_ac_phase_inactive <state-file> -- L6 (todo 20261003-004707-628d0000,
# redteam-1): a marker left behind with ac-state.json in phase ac, grace or
# reconnected (e.g. the session ended after the monitor's exit 0 without a
# resume) is one guard_active() always answers 0 for, so starting perl for
# it on every tool call is pure cost. Succeeds only when the state file is a
# single well-formed-looking JSON object line whose phase is one of those
# three; any other case -- missing, unreadable, odd-shaped, an active phase
# -- fails, so perl runs and BpAcWatch::guard_active() decides (it fails
# closed on an undecodable state). A JSON string value cannot contain the
# unescaped needle, so only the real top-level key can match. Builtins only.
_bp_ac_phase_inactive() {
    local f=$1 line= extra=
    [ -f "$f" ] || return 1
    { IFS= read -r line; IFS= read -r extra; } 2>/dev/null < "$f"
    [ -z "$extra" ] || return 1
    case $line in
        '{'*'}') ;;
        *) return 1 ;;
    esac
    case $line in
        *'"phase":"ac"'*) return 0 ;;
    esac
    case $line in
        *'"phase":"grace"'*) return 0 ;;
    esac
    case $line in
        *'"phase":"reconnected"'*) return 0 ;;
    esac
    return 1
}

_bp_clause_holds() {
    local clause=$1 atom holds_any=0
    if [ -z "$clause" ]; then
        return 0
    fi
    local IFS=,
    for atom in $clause; do
        case $atom in
            ledger)
                [ -n "$BP_LEDGER" ] && holds_any=1
                ;;
            coordinator)
                if [ -n "$BP_LEDGER" ] && { [ -z "$BP_ROLE" ] || [ "$BP_ROLE" = "coordinator" ]; }; then
                    holds_any=1
                fi
                ;;
            stopfile)
                if [ -n "$BP_DIR" ]; then
                    if [ -e "$BP_DIR/runs/.shutdown" ]; then
                        holds_any=1
                    elif [ -e "$BP_DIR/runs/.paused" ]; then
                        holds_any=1
                    elif [ -n "$BP_PACKAGE" ] && [ -e "$BP_DIR/runs/$BP_PACKAGE.force-stop" ]; then
                        holds_any=1
                    fi
                fi
                ;;
            acstanddown)
                _bp_ac_data_dir
                if [ -n "$_BP_AC_DATA_DIR" ] && [ -e "$_BP_AC_DATA_DIR/.drive-solo/ac-standdown.json" ]; then
                    _bp_ac_phase_inactive "$_BP_AC_DATA_DIR/.drive-solo/ac-state.json" || holds_any=1
                fi
                ;;
        esac
    done
    [ "$holds_any" -eq 1 ]
}

# Step 2: env-only clauses first, before stdin is ever read.
for clause in "${pre_clauses[@]}"; do
    if _bp_env_only_clause "$clause"; then
        _bp_clause_holds "$clause" || exit 0
    fi
done

unset -v BP_PAYLOAD BP_PAYLOAD_TRUNCATED

# Step 6's scripts directory, resolved before the read because the reader
# lives there too: ../scripts, or ../../scripts while under next/. Without
# BpHook.pm every path below ends in exit 0 anyway, so leaving now changes
# nothing but the unread stdin.
s=${r%/*}/../scripts
if [ ! -f "$s/BpHook.pm" ]; then
    s=${r%/*}/../../scripts
fi
if [ ! -f "$s/BpHook.pm" ]; then
    exit 0
fi

# The payload is read by scripts/read-payload.sh, the one reader every bash
# hook of this plugin and of almanac shares (sourced: no process). It bounds
# the read by 8 MiB and by BP_PAYLOAD_READ_TIMEOUT (1..10 s, else 10), keeps
# "read -N" on bash >= 4.1 and falls back to a NUL-delimited read on bash
# 3.2 (macOS /bin/bash), where it also tells a timeout from an end of input
# by elapsed time: 3.2's read -t returns 1 for both and drops what it read,
# which once let every --pre text: clause skip perl on a stalled payload.
# A truncated read or a timeout marks the payload truncated, so every
# armed/driver/text: clause below falls through to perl and BpHook treats
# the payload as unusable (load_payload: payload_ok 0); on a timeout the
# library leaves BP_PAYLOAD empty on every bash, so perl sees the same bytes
# on a Mac as on Windows. A missing or broken library is a broken install:
# exit 0, exactly like a missing BpHook.pm.
[ -f "$s/read-payload.sh" ] || exit 0
. "$s/read-payload.sh"
declare -F ccp_read_payload >/dev/null || exit 0
BP_PAYLOAD=
ccp_read_payload BP_PAYLOAD
case $CCP_PAYLOAD_STATE in
    truncated) export BP_PAYLOAD_TRUNCATED=1 ;;
    timeout) export BP_PAYLOAD_TRUNCATED=1 ;;
esac

# RT-M3: bash's "${x#*pat}" shortest-prefix removal is O(p^2) in the offset
# of the match (and O(n^2) over the whole payload when there is no match at
# all). Bound the scan to a fixed-size prefix so a large payload with
# session_id absent, or far from the front, still resolves in linear time;
# fall through to perl (sid unset) when the key is not found in that prefix,
# never treat the bound itself as "not applicable".
sid_head=${BP_PAYLOAD:0:4096}
sid=${sid_head#*\"session_id\":\"}
if [ "$sid" = "$sid_head" ]; then
    sid=
else
    sid=${sid%%\"*}
fi
if [[ ! $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]]; then
    sid=
fi

root=
bsd=$BUTLER_STATE_DIR
if [ -n "$bsd" ]; then
    if _bp_is_abs "$bsd"; then
        bsd=${bsd//\\//}
        bsd=${bsd%/}
        root="$bsd/continuity"
    fi
else
    for var_val in "$HOME" "$USERPROFILE"; do
        [ -n "$root" ] && break
        [ -z "$var_val" ] && continue
        if _bp_is_abs "$var_val"; then
            var_val=${var_val//\\//}
            var_val=${var_val%/}
            root="$var_val/.claude/butler-state/continuity"
        fi
    done
fi

armed_holds=0
driver_holds=0
if [ -z "$sid" ] || [ "$BP_PAYLOAD_TRUNCATED" = "1" ]; then
    armed_holds=1
    driver_holds=1
elif [ -n "$root" ] && [ -e "$root/armed/$sid" ]; then
    armed_holds=1
    IFS= read -r arm_line < "$root/armed/$sid"
    case $arm_line in
        *'"role":"driver"'*) driver_holds=1 ;;
    esac
fi

for clause in "${pre_clauses[@]}"; do
    _bp_env_only_clause "$clause" && continue
    holds=0
    saved_ifs=$IFS
    IFS=,
    for atom in $clause; do
        case $atom in
            armed)
                [ "$armed_holds" -eq 1 ] && holds=1
                ;;
            driver)
                [ "$driver_holds" -eq 1 ] && holds=1
                ;;
            text:*)
                needle=${atom#text:}
                if [ "$BP_PAYLOAD_TRUNCATED" = "1" ]; then
                    holds=1
                else
                    case $BP_PAYLOAD in
                        *"$needle"*) holds=1 ;;
                    esac
                fi
                ;;
            ledger)
                _bp_clause_holds "$atom" && holds=1
                ;;
            coordinator)
                _bp_clause_holds "$atom" && holds=1
                ;;
            stopfile)
                _bp_clause_holds "$atom" && holds=1
                ;;
            "")
                holds=1
                ;;
            *)
                holds=1
                ;;
        esac
    done
    IFS=$saved_ifs
    [ "$holds" -eq 1 ] || exit 0
done

shopt -s execfail
exec perl -I"$s" -e 'our $X = 0; END { $? = $X } my $r = eval { require BpHook; BpHook::main(@ARGV) }; $X = (defined $r && $r == 2) ? 2 : 0; exit $X' "$module" "$@" <<<"$BP_PAYLOAD"
exit 0
