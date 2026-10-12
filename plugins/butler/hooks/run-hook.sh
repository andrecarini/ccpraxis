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
                    holds_any=1
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

t=$BP_PAYLOAD_READ_TIMEOUT
if [[ $t =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le 10 ]; then
    :
else
    t=10
fi

# RT-M2: "read -N" was added in bash 4.1. On an older bash (stock macOS
# /bin/bash 3.2) it is an invalid option returning rc 2, which is neither 0
# nor above 128, so the wrapper would continue with an empty BP_PAYLOAD.
# Exiting 0 there instead would make every hook a silent no-op on that
# host -- continuity would quietly never fire. So an old bash reads with
# -d '' instead: a builtin, slower on large input, but correct. Its return
# codes line up with the -N mapping below: 1 at a normal EOF, >128 on
# timeout, and 0 only if it stopped early at a NUL (never valid JSON), which
# is treated as truncated.
read_n=0
if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ]; then
    read_n=1
fi
if [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 1 ]; then
    read_n=1
fi
if [ "$read_n" -eq 1 ]; then
    IFS= read -r -N 8388608 -t "$t" BP_PAYLOAD
    rc=$?
else
    IFS= read -r -d '' -t "$t" BP_PAYLOAD
    rc=$?
fi
if [ "$rc" -eq 0 ] || [ "$rc" -gt 128 ]; then
    export BP_PAYLOAD_TRUNCATED=1
fi

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

s=${r%/*}/../scripts
if [ ! -f "$s/BpHook.pm" ]; then
    s=${r%/*}/../../scripts
fi
if [ ! -f "$s/BpHook.pm" ]; then
    exit 0
fi

shopt -s execfail
exec perl -I"$s" -e 'our $X = 0; END { $? = $X } my $r = eval { require BpHook; BpHook::main(@ARGV) }; $X = (defined $r && $r == 2) ? 2 : 0; exit $X' "$module" "$@" <<<"$BP_PAYLOAD"
exit 0
