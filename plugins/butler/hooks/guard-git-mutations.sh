#!/usr/bin/env bash
# guard-git-mutations.sh — PreToolUse hook denying git working-tree mutations
# in ANY session, including manually-driven Task subagents.
#
# WHY THIS EXISTS SEPARATELY FROM guard-bash.sh
#
# guard-bash.sh already denies exactly these commands — and it did not fire,
# three times in one session, because lib.sh's bp_hook_gate() exits 0 (allow)
# unless BP_LEDGER, BP_DIR and BP_PROJECT_ROOT are all set. Those are exported
# by bp-launch.sh, so guard-bash.sh only enforces inside a butler-LAUNCHED
# coordinator session.
#
# A manual drive dispatches workers with the Agent/Task tool instead. Those
# subagents inherit none of the BP_* contract, so the gate opened and the
# prohibition survived only as text in the dispatch prompt. It was violated
# three times, and at least once it cost real work: the b25 fix-batch
# (R8-R11, R13, R18) was written, swept into a stash by a prohibited
# `git stash`, never restored, and never committed — while the ledger recorded
# step 7 as complete. A written instruction is not an enforcement mechanism.
#
# So this hook deliberately has NO bp_hook_gate: it applies everywhere.
#
# SCOPE. Only working-tree/history mutations that can DESTROY uncommitted work.
# Read-only git is untouched, because agents legitimately need it to inspect
# their own diffs — and pushing them toward `git stash` to "see what changed"
# is part of how this happened.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# Sourced for bp_json_get ONLY -- NO bp_hook_gate here, by design (see above).
source "$HOOK_DIR/lib.sh"

PAYLOAD=$(cat)

# See lib.sh:bp_json_get. This used to hard-require jq, which the Windows host
# does not have and -- per this repo's Perl-only doctrine -- is never going to
# get. The result was that it blocked EVERY Bash call on the host instead of
# guarding anything. Only the absence of BOTH parsers still fails closed.
CMD=$(bp_json_get "$PAYLOAD" tool_input.command) || {
  echo "guard-git-mutations: BLOCKED -- no JSON parser available (neither jq nor perl+JSON::PP); blocking to avoid unenforced operation." >&2
  exit 2
}
[ -n "$CMD" ] || exit 0

deny() { echo "BLOCKED: $1 Command: $CMD" >&2; exit 2; }

# a02 defect 6 (spec §2.7): the two mutation regexes below used to grep the WHOLE
# raw command string, so prose that merely QUOTES/mentions a prohibited command
# (e.g. a --text argument) was blocked exactly like a real invocation. Both
# regexes are kept byte-identical below in what they look for; what changed is
# the STRING they scan -- a quote-masked copy of CMD, with the CONTENTS of
# quoted spans replaced by 'X' (quote characters themselves retained, length
# preserved). Both deny() messages and the printed "Command: $CMD" always show
# the RAW command -- the operator must see what they actually typed.
MASK_MAX=8192

# git_scan_target — echoes the string the mutation regexes must scan: CMD with
# quoted-span CONTENTS masked to 'X', or CMD UNCHANGED whenever masking would be
# unsafe (see the four raw-fallback conditions below). Single left-to-right pass,
# three-state machine (NONE/SINGLE/DOUBLE). Every failure mode of this walk
# degrades to the RAW string, never to "treat as allowed" -- a bug here must
# fail the way today's hook already does, not open a new hole.

# RAW_KIND — set by git_scan_target to record WHY it returned raw (or that it
# didn't). step-6 red-team MINOR-7: the anchor class was widened (below) to
# reach quoted invocations like `bash -c "git stash"` / `` `git stash` `` /
# `$(git reset --hard)`, all of which land on a RAW-fallback path -- but
# applying that widened class to EVERY raw fallback also matches a merely
# QUOTED MENTION whenever the SAME command independently trips an unrelated
# fallback (e.g. an unquoted `$(date +%s)` elsewhere forces the carrier
# fallback for the whole string, and the widened class then matches
# `'git reset --hard'` inside a `--text` argument that never runs as code).
# The widened class is only ever actually NEEDED for two of the five
# fallback reasons -- see the RAW_KIND-keyed anchor selection below.
RAW_KIND=masked

git_scan_target() {
  local cmd="$CMD"
  local len=${#cmd}
  # 1. Over-long command: raw fallback without even walking it.
  if [ "$len" -gt "$MASK_MAX" ]; then
    RAW_KIND=toolong
    SCAN_OUT="$cmd"
    return 0
  fi
  # 0. A backslash, a '#', or a heredoc marker ('<<') ANYWHERE in the command:
  #    raw fallback.
  #
  # The three-state walk below models bash QUOTING only. It has no notion of
  # three other contexts where bash does NOT treat a quote character as a
  # delimiter, and all three were demonstrated (step-6 reviewer B1, red-team
  # BLOCKER-1) to silently mask a REAL, executable, unquoted mutation as
  # "allowed":
  #   - backslash escapes (`\"`, `\'`, and ANSI-C `$'...'` bodies) can flip the
  #     walk's quote-parity so a later escaped quote "re-balances" a span that
  #     was never actually open/closed the way the walk believes;
  #   - `#` starts a bash COMMENT (to end-of-line), where an apostrophe is
  #     just a literal character, not a quote delimiter -- the walk has no
  #     comment state at all, so `# don't ... # that's` toggles SINGLE->NONE
  #     around a genuinely unquoted, in-between command;
  #   - a heredoc body (`<<EOF ... EOF`) is verbatim text, not shell syntax --
  #     an apostrophe inside it (`it's fine`) is just a character, but the
  #     walk still toggles SINGLE on it, and a second apostrophe in a later
  #     heredoc body can "re-balance" the parity around a genuinely unquoted
  #     mutation sitting between the two heredocs.
  # Rather than add ESCAPE/COMMENT/HEREDOC sub-states to the walk (more
  # surface to get subtly wrong a second time), take the same raw-fallback
  # degrade the other three failure modes already use. This can only make the
  # scan MORE conservative (raw string still gets the anchor regexes applied
  # to it), so it cannot turn any existing DENY into an ALLOW, and per
  # N1/MINOR-7 in the step-6 reports, degrading to raw is the documented
  # "fails toward deny" direction -- never a security concern, only a
  # possible extra false positive on prose that itself contains a literal
  # backslash, '#', or '<<'.
  case "$cmd" in
    *'\'*|*'#'*|*'<<'*)
      RAW_KIND=escape
      SCAN_OUT="$cmd"
      return 0
      ;;
  esac

  local state=NONE   # NONE | SINGLE | DOUBLE
  local carrier=0
  local out="" c next
  local i=0
  while [ "$i" -lt "$len" ]; do
    c=${cmd:$i:1}
    case "$state" in
      NONE)
        case "$c" in
          "'") state=SINGLE; out+="'" ;;
          '"') state=DOUBLE; out+='"' ;;
          '`') carrier=1; out+='`' ;;
          '$')
            next=${cmd:$((i+1)):1}
            [ "$next" = "(" ] && carrier=1
            out+='$' ;;
          *) out+="$c" ;;
        esac ;;
      SINGLE)
        case "$c" in
          "'") state=NONE; out+="'" ;;
          *)   out+="X" ;;
        esac ;;
      DOUBLE)
        case "$c" in
          '"') state=NONE; out+='"' ;;
          '`') carrier=1; out+="X" ;;
          '$')
            next=${cmd:$((i+1)):1}
            [ "$next" = "(" ] && carrier=1
            out+="X" ;;
          *)   out+="X" ;;
        esac ;;
    esac
    i=$((i+1))
  done

  # 2. Unbalanced quoting (walk never returned to NONE): raw fallback.
  if [ "$state" != "NONE" ]; then
    RAW_KIND=unbalanced
    SCAN_OUT="$cmd"
    return 0
  fi
  # 3. An unquoted backtick or $( anywhere in NONE/DOUBLE: the shell would
  #    evaluate the enclosed text as CODE, so it is not a mere "mention" --
  #    raw fallback so the carried text is still scanned.
  if [ "$carrier" -eq 1 ]; then
    RAW_KIND=carrier
    SCAN_OUT="$cmd"
    return 0
  fi
  # 4. A shell/eval/xargs in command position (checked on the MASKED string,
  #    precisely so the same words appearing INSIDE someone's quoted prose do
  #    not trigger this): it re-interprets its own quoted argument as code, so
  #    e.g. `bash -c "git stash"` must still be denied. Raw fallback.
  if printf '%s' "$out" | grep -Eq '(^|[;&|[:space:]])(bash|sh|zsh|ksh|dash|eval|xargs)([[:space:]]|$)'; then
    RAW_KIND=shellword
    SCAN_OUT="$cmd"
    return 0
  fi

  SCAN_OUT="$out"
}

# NOTE: called WITHOUT command substitution -- $(...) would run
# git_scan_target in a SUBSHELL, silently discarding its RAW_KIND assignment
# (and any other global it sets) once the subshell exits. It communicates its
# result via the global SCAN_OUT instead, precisely so RAW_KIND survives into
# the anchor-selection logic below.
SCAN_OUT=
git_scan_target
SCAN=$SCAN_OUT

# Anchor widened (a02 driver-verified bypass, beyond the scout's original seven):
# a quoted invocation of a prohibited verb -- e.g. `bash -c "git stash"` or
# `` `git stash` `` or `$(git reset --hard)` -- lands on the RAW-fallback path
# above with the preceding character being a quote/backtick/paren, none of
# which the original anchor `(^|[;&|[:space:]])` recognised as a boundary.
#
# step-6 red-team MINOR-7: applying the FULL widened class (quotes included)
# to every raw fallback also matches a merely QUOTED MENTION of a prohibited
# verb whenever the command independently trips an UNRELATED fallback (e.g.
# an unquoted `$(date +%s)` elsewhere forces fallback 3 for the whole
# string, and the quote-inclusive class then matches `'git reset --hard'`
# inside an unrelated `--text` argument that never runs as code). Only two of
# the five fallback reasons actually NEED the widened class:
#   - carrier (fallback 3, an unquoted backtick/`$(` somewhere): the verb can
#     sit immediately after that backtick/`(`, e.g. `` echo `git stash` `` --
#     needs backtick+`(` as boundary chars, but NOT quotes (a quote here is
#     never itself the reason the shell will execute the enclosed text).
#   - shellword (fallback 4, `bash`/`sh`/... in command position): the verb
#     can sit inside the shell's OWN quoted argument, e.g.
#     `bash -c "git stash"` -- needs quotes+backtick+`(` since the shell
#     re-interprets whatever it's quoted with as code.
# Every other reason (masked/toolong/escape/unbalanced) keeps the ORIGINAL
# narrow anchor: none of t/106's real-mutation fixtures for those paths sit
# immediately after a quote/backtick/paren (they follow a space/`;`/newline/
# start, already matched), so narrowing there costs no existing DENY while
# closing the false-positive class above.
case "$RAW_KIND" in
  shellword) ANCHOR_CLASS='[;&|[:space:]'\''"`(]' ;;
  carrier)   ANCHOR_CLASS='[;&|[:space:]`(]' ;;
  *)         ANCHOR_CLASS='[;&|[:space:]]' ;;
esac
STASH_RE="(^|${ANCHOR_CLASS})git[[:space:]]+stash\\b"
STASH_RO_RE='git[[:space:]]+stash[[:space:]]+(list|show)\b'
MUT_RE="(^|${ANCHOR_CLASS})git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(checkout|switch|restore|reset|clean)\\b"

# stash: list/show are read-only and explicitly allowed.
if grep -Eq "$STASH_RE" <<<"$SCAN" && \
   ! grep -Eq "$STASH_RO_RE" <<<"$SCAN"; then
  deny "git stash is forbidden: it silently removes uncommitted work from the tree and has already cost a completed fix-batch in this repo. To inspect your own changes use 'git diff' (read-only). 'git stash list' and 'git stash show' are allowed."
fi

# checkout/switch/restore/reset/clean: overwrite or delete uncommitted work.
# `git checkout -b` / `git switch -c` create a branch without touching content,
# but are still orchestrator-only here, so they are denied with the rest.
if grep -Eq "$MUT_RE" <<<"$SCAN"; then
  deny "git checkout/switch/restore/reset/clean are forbidden: each can discard uncommitted work. Change files only via Edit/Write. Use 'git diff' or 'git status' to inspect state."
fi

exit 0
