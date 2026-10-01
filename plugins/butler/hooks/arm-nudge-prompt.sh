#!/usr/bin/env bash
# arm-nudge-prompt.sh -- never-halt package 11 (Decision 43, N3). Registered
# on UserPromptSubmit through the sec 2.2 guarded template in hooks.json.
# Contract: .ccpraxis-local-data/blueprints/never-halt/specs/
# 11-arming-nudges-spec.md sec 2.3. Pure bash: it never execs run-hook.sh,
# never starts perl, and uses no command substitution and no pipe. The only
# external command it may start is "mkdir -p" when the prompted/ directory
# is missing. It never writes to stderr and always exits 0.
#
# It records the epoch of every main-thread operator prompt in one
# per-session marker (<state_dir>/prompted/<sid>, read back by
# BpHook::last_prompt_epoch -- the shared formula is BpHook::prompt_marker),
# and on an unarmed operator prompt that signals unattended work (sec
# 2.3.1's phrase list) it injects one line suggesting "butler-continuity
# on". It never blocks and it never arms anything itself.
set -f

# Step 1: a coordinator or judge environment is not an operator prompt.
[ -n "$BP_LEDGER" ] && exit 0

# Step 2: read the payload once, bounded.
IFS= read -r -N 8388608 -t 10 P
[ -n "$P" ] || exit 0

# Step 3: must be a main-thread UserPromptSubmit payload.
[[ $P =~ \"hook_event_name\"[[:space:]]*:[[:space:]]*\"UserPromptSubmit\" ]] || exit 0

# Step 4: a subagent payload is never an operator prompt.
[[ $P =~ \"agent_id\"[[:space:]]*:[[:space:]]*\"[^\"]*\" ]] && exit 0

# Step 5: session id.
if [[ $P =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]]; then
    sid=${BASH_REMATCH[1]}
else
    exit 0
fi
[[ $sid =~ ^[A-Za-z0-9_-]{1,128}$ ]] || exit 0

# Step 6: the prompt text, bounded to the first 4096 characters of the
# payload (the same O(n^2)-avoidance bound the chart reminder's bash claim
# uses).
H=${P:0:4096}
if [[ $H =~ \"prompt\"[[:space:]]*:[[:space:]]*\"(([^\"\\]|\\.)*) ]]; then
    PR=${BASH_REMATCH[1]}
else
    exit 0
fi

# Step 7: a task-notification is not an operator prompt.
case $PR in
    '<task-notification>'*) exit 0 ;;
esac

# Step 8: resolve the continuity state root, identical to run-hook.sh's own
# resolution (lines 166-184).
_bp_is_abs() {
    case $1 in
        /*) return 0 ;;
    esac
    case $1 in
        [A-Za-z]:[\\/]*) return 0 ;;
    esac
    return 1
}

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
[ -n "$root" ] || exit 0

# Step 9: record the prompt epoch. $EPOCHSECONDS is bash >= 5.0; the
# "%(%s)T" printf format is bash >= 4.2. On an older bash, E stays empty and
# nothing is written -- a quiet no-op, never a failure.
E=$EPOCHSECONDS
if [[ ! $E =~ ^[0-9]+$ ]]; then
    E=
    printf -v E '%(%s)T' -1 2>/dev/null
fi
if [[ $E =~ ^[0-9]+$ ]]; then
    [ -d "$root/prompted" ] || mkdir -p "$root/prompted" 2>/dev/null
    { printf '%s\n' "$E" > "$root/prompted/$sid"; } 2>/dev/null
fi

# Step 10: armed -- recorded, no nudge.
[ -e "$root/armed/$sid" ] && exit 0

# Step 11: normalise PR -- fold the common JSON whitespace escapes to a
# single space, and both encodings of a curly apostrophe to an ASCII one, so
# the phrase list below matches regardless of how the prompt was escaped.
PR=${PR//\\n/ }
PR=${PR//\\r/ }
PR=${PR//\\t/ }
PR=${PR//\\u2019/\'}
PR=${PR//\\U2019/\'}
PR=${PR//’/\'}

# Step 12: /drive-solo (with or without the butler: prefix, leading
# whitespace allowed) arms itself; no nudge needed.
[[ $PR =~ ^[[:space:]]*/(butler:)?drive-solo([[:space:]]|\$) ]] && exit 0

# Step 13: the phrase list (sec 2.3.1), matched case-insensitively.
ALT_RE="(^|[^[:alnum:]])(keep[[:space:]]+going|keep[[:space:]]+working|carry[[:space:]]+on|while[[:space:]]+i'?m[[:space:]]+(away|out|gone|asleep)|while[[:space:]]+i[[:space:]]+am[[:space:]]+(away|out|gone|asleep)|i'?ll[[:space:]]+be[[:space:]]+back|i[[:space:]]+will[[:space:]]+be[[:space:]]+back|be[[:space:]]+right[[:space:]]+back|overnight|unattended|until[[:space:]]+(it'?s|it[[:space:]]+is|you'?re|you[[:space:]]+are)[[:space:]]+(done|finished))([^[:alnum:]]|\$)"
shopt -s nocasematch
if [[ $PR =~ $ALT_RE ]]; then
    shopt -u nocasematch
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"This prompt suggests unattended work. If this session should keep working without the operator, arm continuity first: butler-continuity on"}}'
    exit 0
fi
shopt -u nocasematch

exit 0
