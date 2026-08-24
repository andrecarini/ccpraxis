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
# shellcheck source=../scripts/bp-lib.sh
# Sourced ONLY for bp_strip_shell_noise, used by the new heredoc-only branch
# of git_scan_target below (t09). Conditional/tolerant, like mark-wakeup.sh's
# own sourcing of this same file -- if unreadable, the branch degrades to
# TODAY's raw-fallback behavior (AC17), never to unconditional allow.
[ -r "$HOOK_DIR/../scripts/bp-lib.sh" ] && source "$HOOK_DIR/../scripts/bp-lib.sh"

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
  # t09 (guard-hooks-stripping). THREAT MODEL: ACCIDENT, not ADVERSARY -- the
  # same ruling already on record for this hook family (see
  # guard-validation-interlock.sh's header, and mark-wakeup.sh's own
  # bp_strip_shell_noise consumption); not re-derived here because nothing
  # about it is in tension. Nothing in this branch needs to survive a
  # deliberate bypass attempt, only ordinary prose/quoting/heredoc accidents
  # -- the confirmed live incident (a heredoc report body that merely NAMES
  # "git stash"/"git reset --hard" in prose, with no git invocation anywhere
  # in the command) is exactly that shape. A false positive (blocking
  # legitimate report-writing) is THIS hook's real defect to fix; a false
  # negative (a real mutation slipping through) must not be introduced --
  # hence the carrier/shellword re-check below, and the backslash/'#' branch
  # staying on the untouched raw fallback.
  #
  # RESIDUAL LEFT UNFIXED, KNOWINGLY: the backslash/'#'-comment-adjacent raw
  # fallback immediately below is UNCHANGED -- prose containing a literal
  # backslash or '#' still forces a fully-raw scan, exactly as before this
  # package. Only the heredoc-only ('<<', no backslash/'#') trigger gains a
  # narrower, safer path.
  case "$cmd" in
    *'\'*|*'#'*)
      RAW_KIND=escape
      SCAN_OUT="$cmd"
      return 0
      ;;
  esac

  # Heredoc marker present, and NEITHER a backslash NOR a '#' (those stay on
  # the raw fallback above, untouched): this is the ONE case
  # bp_strip_shell_noise already handles and git_scan_target's own three-
  # state walk cannot (no comment/heredoc state at all -- see the header
  # above). Reuse bp_strip_shell_noise UNMODIFIED; do not re-derive heredoc
  # parsing here (ledger criterion 2: one stripping implementation).
  case "$cmd" in
    *'<<'*)
      # TRUST THE STRIP ONLY WHERE THE STRIPPER'S HEREDOC PARSE CAN KEEP UP.
      #
      # Added after this package's own red-team found, and the driver confirmed
      # by running the PRE- and POST-change hooks side by side, that two
      # ordinary shapes desync bp_strip_shell_noise's terminator matching. In
      # both, it runs past the terminator, blanks the REST of the command --
      # including a real trailing mutation -- and returns something that looks
      # clean, so this branch allowed a command that the pre-change hook denied:
      #
      #   cat > f <<'EOF!' ... EOF!   <newline>   <a real mutation>
      #   the same command with CRLF line endings
      #
      # That is a false NEGATIVE in a guard that exists because a prohibited
      # history-discarding command once destroyed a completed fix-batch here.
      # Escalating instead costs a false POSITIVE, which is this hook's
      # acceptable failure and merely restores the behaviour that shipped
      # before the heredoc branch existed.
      #
      # Deliberately NOT fixed by teaching bp_strip_shell_noise more bash: it
      # is shared with other callers, and widening a parser to close a guard
      # hole is how the next hole gets opened. Detect what it cannot model and
      # decline to trust it there.
      #
      # `<<-` also escalates. The predicate below cannot distinguish the `-` of
      # a tab-stripping heredoc from punctuation in a delimiter, and the
      # red-team flagged `<<-` as an untested shape in its own right -- so it
      # takes the safe path rather than the clever one.
      case "$cmd" in
        *$'\r'*)
          RAW_KIND=escape
          SCAN_OUT="$cmd"
          return 0
          ;;
      esac
      if printf '%s' "$cmd" | grep -Eq "<<-?[[:space:]]*['\"]?[A-Za-z0-9_]*[^A-Za-z0-9_'\"[:space:]]"; then
        RAW_KIND=escape
        SCAN_OUT="$cmd"
        return 0
      fi
      HD_STRIPPED=""
      if command -v bp_strip_shell_noise >/dev/null 2>&1; then
        HD_STRIPPED=$(printf '%s' "$cmd" | bp_strip_shell_noise)
      fi
      if [ -z "$HD_STRIPPED" ]; then
        # perl / scripts/bp-lib.sh unavailable, or stripping produced empty
        # output: fall back to TODAY's behavior exactly. Never treat "could
        # not strip" as "no heredoc" -- that would silently narrow the scan.
        RAW_KIND=escape
        SCAN_OUT="$cmd"
        return 0
      fi
      # Re-run git_scan_target's OWN carrier / shellword checks -- unmodified
      # regex text, new input -- before trusting the stripped text. Both must
      # still escalate to fully raw, exactly as the main walk already does
      # for these two cases below. bp_strip_shell_noise leaves a bare or
      # double-quoted $(...)/backtick verbatim in its output (it must -- both
      # genuinely execute), so a heredoc-triggered command that ALSO contains
      # an unquoted carrier or a `bash -c "..."` wrapper outside the heredoc
      # must still escalate, exactly as the un-heredoc'd walk already does.
      if printf '%s' "$HD_STRIPPED" | grep -Eq '`|\$\('; then
        RAW_KIND=carrier
        SCAN_OUT="$cmd"
        return 0
      fi
      if printf '%s' "$HD_STRIPPED" | grep -Eq '(^|[;&|[:space:]])(bash|sh|zsh|ksh|dash|eval|xargs)([[:space:]]|$)'; then
        RAW_KIND=shellword
        SCAN_OUT="$cmd"
        return 0
      fi
      RAW_KIND=heredoc
      SCAN_OUT="$HD_STRIPPED"
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
# `(` and `{` are in the BASE class, not only the widened ones. almanac
# 20260819-164901-52d3, verified by running this hook: `(git stash push -m wip)`
# and `x=1; {git stash push -m wip; }` were both ALLOWED. A subshell or brace
# group opens a COMMAND POSITION -- the verb immediately after it runs, exactly
# as it would after a `;` -- so their absence here was a false NEGATIVE, which is
# the dangerous direction for a guard: a prohibited command executed.
#
# This does not reintroduce MINOR-7's false-positive class, and the distinction
# is the reason the widened classes stay separate. That class was about QUOTES:
# a quote is never itself a reason the shell will execute what it encloses, so
# treating it as a boundary makes a quoted MENTION look like an invocation. `(`
# and `{` are the opposite -- they mean "a command starts here" and nothing
# else. And this class is applied to the STRIPPED scan target, where quoted
# spans are already blanked, so a `(` inside prose cannot reach it.
case "$RAW_KIND" in
  shellword) ANCHOR_CLASS='[;&|[:space:]'\''"`({]' ;;
  carrier)   ANCHOR_CLASS='[;&|[:space:]`({]' ;;
  *)         ANCHOR_CLASS='[;&|[:space:]({]' ;;
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
