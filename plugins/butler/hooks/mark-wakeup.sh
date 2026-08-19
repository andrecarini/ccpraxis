#!/usr/bin/env bash
# mark-wakeup.sh — PreToolUse hook for Task, Agent and Bash, in a DRIVE-SOLO
# DRIVER session (never in a coordinator).
#
# Records that this turn started something that will wake the session up again:
#   * any Task or Agent dispatch (a subagent; its completion notification
#     comes back), or
#   * a Bash call with run_in_background=true (its exit notification comes back).
#
# gate-drive-loop.sh (Stop) CONSUMES this marker. The pair encodes one rule:
#
#     A driver turn may end EITHER because something will wake it,
#     OR because the director says the run is settled. Never for any
#     other reason.
#
# Why this exists. /butler:drive-solo describes the driver as "a thin loop over
# the director": call `bp-drive-next.pl next`, dispatch the action it returns,
# call `next` again. That is prose, and prose decays over a long context. The
# observed failure — three times in one 12-hour run on 2026-08-07 — is a turn
# that ends right after a ledger write, with text promising the next step and
# nothing scheduled to perform it. A dispatched agent notifies; a finished Bash
# call does not. So the run dies silently, mid-package, looking finished.
#
# This is the same argument gate-stop.sh already makes for coordinators ("converts
# ledger discipline from a prompt rule (which decays over long contexts) into a
# mechanical gate"), and the same one guard-git-mutations.sh makes in this repo's
# CLAUDE.md: a written instruction is not an enforcement mechanism.
#
# NEVER blocks anything: it only writes a marker. Exit 0 on every path.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
# shellcheck source=../scripts/bp-lib.sh
[ -r "$HOOK_DIR/../scripts/bp-lib.sh" ] && source "$HOOK_DIR/../scripts/bp-lib.sh"

# bp_wakeup_arm_check REGEX -- d03-one-shell-noise-stripper (almanac report
# 20260814-093113-34a0). Reads a raw (pre-strip) shell command on stdin.
# Prints "1" if REGEX matches inside the LIVE portion of the command (outside
# any quoted span, comment, or heredoc body -- see bp_strip_shell_noise,
# scripts/bp-lib.sh) AND the matching SEGMENT's first word is not a
# non-executing reader (echo|printf|grep|rg|cat|sed|awk). Prints "0"
# otherwise, including on empty input. Never exits non-zero; never writes to
# stderr -- this hook's own contract is "exit 0 on every path" (see header).
#
# Kept LOCAL to this file, not lifted into bp-lib.sh: bp_strip_shell_noise's
# contract is pure stripping, and its only other consumer
# (guard-validation-interlock.sh) neither wants nor uses a reader-check.
# Adding the veto to the shared helper would silently widen that file's
# matching behaviour for no benefit to it -- keeping this local keeps
# bp_strip_shell_noise provably unchanged.
#
# 2026-08-19 d03-one-shell-noise-stripper fixbatch step7, FIX 1 + FIX 2
# (redteam-step6.md CRITICAL-1/CRITICAL-2, both confirmed regressions against
# the pre-fbe7f6e raw-payload grep). The single-shot "leftmost match, then
# look at the text right before it" veto had two independent false-negative
# holes:
#   FIX 1 -- the veto anchored on the LEFTMOST occurrence of the base regex
#     in the WHOLE command, not on the occurrence that actually matched. An
#     early, harmless mention (`grep bp-drive-next.pl README.md`) vetoed a
#     later, genuine invocation in the same compound command
#     (`; perl .../bp-drive-next.pl next`), because [^"]* in the base regex
#     happily spans `;`, `&`, `|` and newline once quotes are blanked.
#   FIX 2 -- $(...), backticks and <(...) genuinely execute regardless of the
#     outer word (`echo $(perl ... next)` really runs the director; `echo`
#     does not "read" it), but the veto only ever looked at the OUTER
#     command's first word and vetoed on it.
#
# THE FIX, one mechanism for both: split the (stripped) text into SEGMENTS at
# every real command separator (`;` `&` `|` newline) AND at every
# command/process-substitution opener (`$(` backtick `<(` `>(`), then judge
# EACH segment independently -- arm if ANY non-reader segment matches. A
# reader segment can now only veto ITSELF, never a sibling segment, and
# substitution content is its own segment rather than inheriting the outer
# word's verdict. (Double-quoted $(...)/backtick content -- e.g.
# `printf "%s" "$(perl ... next)"` -- reaches this split as LIVE text too:
# see bp_strip_shell_noise's dquote handling in scripts/bp-lib.sh, which
# stopped blanking it for the same reason -- it executes regardless of the
# surrounding quotes.) This does not resolve NESTED substitutions perfectly
# (a `)` inside a further-nested string can end a segment early) -- an
# accepted heuristic limit, same class as the ones already documented below,
# and it only ever costs a potential false ARM on a pathological nesting, not
# a missed real invocation.
#
# Degrades in three independent, false-negative-averse directions (never
# toward silently missing a real invocation):
#   - bp_strip_shell_noise unavailable or empty output (perl missing,
#     bp-lib.sh unreadable) -> matches against the UNSTRIPPED extracted
#     command instead of failing closed (mirrors guard-validation-
#     interlock.sh's own bp_strip_shell_noise fallback).
#   - the extracted command exceeds $BP_WAKEUP_MAX_STRIP_BYTES -> the
#     (expensive, O(n) char-by-char) stripper is skipped entirely and the
#     RAW command is matched instead. See the size check below for why and
#     the chosen threshold.
#   - perl itself unavailable for the regex+segment-veto step -> the base
#     regex match still runs via bash grep; the segment veto is skipped
#     (never applied), which can only ARM more often, never less. NOTE
#     (fixbatch step7, FIX 5 / reviewer S1): this branch is untested on this
#     host -- bp_json_get (lib.sh) itself requires perl, and there is no jq
#     here (repo constraint), so a PATH with perl removed breaks command
#     EXTRACTION before this branch is ever reached. Reasoned-but-unexercised,
#     not verified by any test in this repo; a container with jq present
#     could isolate it, this host cannot.
bp_wakeup_arm_check() {
  regex="$1"
  cmd=$(cat)
  text="$cmd"
  # fixbatch step7 / FIX 3 (redteam HIGH): bp_strip_shell_noise is an O(n)
  # char-by-char perl scan; measured on this host: 100KB->4.5s, 500KB->9.1s,
  # 1000KB->14.9s (this hook's own documented 15s external timeout -- see the
  # header's dirname-loop story), 2000KB->times out, i.e. NEVER ARMS. That is
  # a size-triggered instance of exactly the false-negative failure mode this
  # file exists to prevent, reachable by ordinary large-command accidents
  # (writing a big file via heredoc, an inline script), no adversary needed.
  # Every real bp-drive-next.pl invocation shape enumerated in AC8 (bare,
  # absolute path, --scope flags, cd-prefixed, piped) is a few hundred bytes
  # at most -- nowhere near this threshold. 8000 bytes is chosen as
  # comfortably (>10x) above any real invocation shape yet far below where
  # stripping cost becomes material (100KB is already ~4.5s). Above the
  # threshold, skip the stripper and match the RAW command instead: this can
  # only OVER-match (a mention sitting inside a huge quoted/commented span
  # could false-positive-arm) rather than under-match, which is this file's
  # stated bias throughout ("when in doubt, arm").
  : "${BP_WAKEUP_MAX_STRIP_BYTES:=8000}"
  if [ -n "$cmd" ] && [ "${#cmd}" -le "$BP_WAKEUP_MAX_STRIP_BYTES" ] \
     && command -v bp_strip_shell_noise >/dev/null 2>&1; then
    stripped=$(printf '%s' "$cmd" | bp_strip_shell_noise)
    [ -n "$stripped" ] && text="$stripped"
  fi
  [ -n "$text" ] || { echo 0; return; }
  printf '%s' "$text" | grep -Eq "$regex" || { echo 0; return; }
  if command -v perl >/dev/null 2>&1; then
    printf '%s' "$text" | perl -0777 -e '
        my $regex = shift @ARGV;
        my $filtered = do { local $/; <STDIN> };
        my $armed = 0;
        # FIX 1 + FIX 2: segment on real separators AND substitution
        # openers, then judge each segment on its own -- see the block
        # comment above this function for the full rationale.
        my @segs = split /(?:[;&|\n]|\$\(|`|<\(|>\()/, $filtered;
        SEG: for my $seg (@segs) {
          while ($seg =~ /$regex/g) {
            my $pre = substr($seg, 0, $-[0]);
            $pre =~ s/^[ \t]+//;
            my ($first) = $pre =~ /^(\S+)/;
            $first = defined($first) ? $first : "";
            $first =~ s{.*/}{};
            unless ($first =~ /^(?:echo|printf|grep|rg|cat|sed|awk)$/) {
              $armed = 1; last SEG;
            }
          }
        }
        print($armed ? "1" : "0");
      ' "$regex" 2>/dev/null
  else
    echo 1
  fi
}

# Coordinator sessions are gate-stop.sh's business, not ours. BP_LEDGER is
# exported only into coordinator processes, so its ABSENCE is what identifies
# an interactive driver.
[ -n "${BP_LEDGER:-}" ] && exit 0

PAYLOAD=$(cat 2>/dev/null || true)

# Resolve the drive-solo state dir exactly as bp-drive-next.pl does: an explicit
# CCPRAXIS_DATA_DIR wins, else <project>/.ccpraxis-local-data. No .drive-solo dir
# means no drive-solo run is in progress here and this hook is irrelevant.
#
# ⚠ bp_find_data_dir, NOT a local while-loop. The loop that used to live here
# did not terminate on Windows: dirname("C:") is "C:", which is neither empty
# nor "/", so any session whose cwd had no .ccpraxis-local-data ancestor spun
# until the 15s hook timeout — on EVERY Bash call and EVERY Task dispatch, in
# every unrelated project on the machine. See bp_find_data_dir in lib.sh.
CWD=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null || true); CWD=${CWD:-$PWD}
DATA=$(bp_find_data_dir "$CWD" 2>/dev/null || true)

TOOL=$(bp_json_get "$PAYLOAD" tool_name 2>/dev/null || true)

# ---------------------------------------------------------------------------
# REPORTER REGISTRATION (g03-reporter-stop-gate). A reporter session never
# calls the director, so the driver-arm regex below can never see it -- see
# the package spec §1.2 for why the trigger is exactly this shape. It keys
# off the exact Bash command `bp-watch.pl --arm ... --blueprint <bp>` (Mode
# B), which is PROVABLY DISJOINT from the driver's own `--package` shape:
# bp-watch.pl's own arg parser refuses --package and --blueprint together
# (pinned by 142-reporter-registration.t section B), so the flag that
# selects Mode B cannot appear in a driver's own invocation.
#
# MUST run BEFORE the `.drive-solo` early-exit below: a project where
# drive-solo has never run (the common case for a reporter-only project)
# would otherwise never reach this block at all (spec §2.1's load-bearing
# ordering note).
#
# Mirrors bp_drive_marker's shape (lib.sh) but inlined -- lib.sh is outside
# this package's write set. The match requires the literal invocation, not
# merely the string: a Read of reporter/SKILL.md, a grep for bp-watch.pl, or
# an echoed/greped command naming it never executes it, so none of those
# arm a session -- same discipline the driver's own regex below already
# relies on (a command that merely NAMES the script does not run it).
#
# Uses bp_json_get throughout, like the rest of this file -- the house idiom,
# reliable on a correctly-escaped payload (verified: 142-reporter-registration.t
# builds every fixture with a real JSON encoder, not string interpolation).
#
# fixbatch step7 / F2: guarded on $DATA up front. Registration cannot write a
# marker without a resolved data dir anyway, so nothing is lost by checking
# first -- and this restores the short-circuit for a session in a project with
# no .ccpraxis-local-data at all, without needing $DATA/.drive-solo to exist
# (a reporter-only project has no .drive-solo dir; see the ordering note above).
if [ "$TOOL" = "Bash" ] && [ -n "$DATA" ]; then
  RCMD=$(bp_json_get "$PAYLOAD" tool_input.command 2>/dev/null || true)
  # fixbatch step7 / F1 (HIGH). A plain 'bp-watch.pl[^"]*--arm[^"]*--blueprint'
  # substring match is not enough on its own -- see the driver's own regex
  # below for the identical, unfixed problem. The FIRST version of this check
  # (a bare "-count parity test on the text before "bp-watch.pl") is ALSO not
  # enough: it counts only DOUBLE quotes, so it is defeated by any of a bash
  # COMMENT ("# ... bp-watch.pl --arm --blueprint ..."), a SINGLE-quoted
  # string ('bp-watch.pl --arm --blueprint'), or a HEREDOC BODY naming the
  # invocation without ever running it -- verified live against the shipped
  # hook (redteam-step6.md HIGH-1, three independent reproductions). None of
  # those are "one case standing in for a general rule"; they are three
  # DIFFERENT ways of getting the literal text into the command without
  # executing it, and a parity count over one quote character catches none of
  # them.
  #
  # THE GENERAL RULE this enforces: scan the raw command byte-by-byte,
  # tracking whether the current position is inside a single-quoted span, a
  # double-quoted span, a '#' comment (only when '#' starts a new word --
  # i.e. is preceded by whitespace, a command separator, or the start of the
  # string, exactly like bash's own lexer), or a heredoc body (from a <<[-]
  # operator's introducer line to its terminator line, honouring <<- 's
  # leading-tab stripping and an optional quoted delimiter). Every character
  # in any of those spans is replaced with whitespace before the substring
  # regex ever runs, so "bp-watch.pl --arm --blueprint" can only match text
  # that is actually part of the command bash would execute -- never text
  # that is quoted, commented out, or sitting inert inside a heredoc body.
  #
  # 2026-08-19 d03-one-shell-noise-stripper (almanac report
  # 20260814-093113-34a0): this used to be an 85-line inline copy of the
  # state machine, plus an inline reader-segment check. Both now live in one
  # place -- bp_strip_shell_noise (scripts/bp-lib.sh) for the stripping, and
  # bp_wakeup_arm_check (this file, defined once above, shared with the
  # driver-arm block below) for the strip -> match -> reader-veto sequence.
  # This block's observable behaviour is unchanged; only the implementation
  # collapsed from a third independent copy to a call into the one shared
  # definition.
  #
  # This remains a heuristic, not a shell parser: it does not resolve command
  # substitution ($(...)), variable expansion, or backtick spans, so a command
  # that builds the invocation through one of those still slips past -- an
  # accepted residual, in the SAME false-negative direction this trigger is
  # already documented to prefer (spec §1.2 -- "when in doubt, arm" is the
  # driver's bias, this trigger's is the opposite, and this fix does not
  # change that bias, only closes the false-POSITIVE holes redteam found).
  ARMED=$(printf '%s' "$RCMD" | bp_wakeup_arm_check 'bp-watch\.pl[^"]*--arm[^"]*--blueprint\b')
  if [ "$ARMED" = "1" ]; then
    RSID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
    case "$RSID" in ''|*/*|*\**|.|..|*..*) RSID="" ;; esac
    if [ -n "$RSID" ]; then
      if RDIR=$(bp_reporter_active_dir 2>/dev/null); then
        mkdir -p "$RDIR" 2>/dev/null && printf '%s\n' "$DATA" > "$RDIR/$RSID" 2>/dev/null || true
      else
        echo "butler reporter-registration: registry path unresolved (HOME and USERPROFILE both unset) -- reporter marker NOT written for session $RSID" >&2
      fi
    fi
  fi
fi
# --- end reporter registration block ----------------------------------------

# ---------------------------------------------------------------------------
# ARMING: this hook is what registers a session as a drive-solo DRIVER.
#
# A driver is not "a session in a directory where drive-solo once ran" — that
# was the old, wrong test, and it armed the Stop gate permanently for every
# session in the tree. A driver is a session that CALLS THE DIRECTOR. Nothing
# else does, and a session that never calls it is not driving no matter where
# it is running. So: see bp-drive-next.pl in a Bash command, register this
# session id; gate-drive-loop.sh then gates exactly that session and no other.
#
# Self-arming, so no skill or script has to remember to do it, and impossible
# to arm a session that never drove. The marker holds the data dir so the Stop
# hook needs no path walk of its own.
# The match requires the script AND one of its subcommands, so a command that
# merely NAMES the file -- a grep for it, an ls of the scripts dir, a sed over
# the source -- does not arm a session that is only reading about the director.
# The script rejects an empty subcommand ("usage: next|record-order|park"), so
# every real invocation carries one and nothing is lost by requiring it.
#
# The bias is deliberate and one-directional: a false POSITIVE arms a session
# that is not driving, which costs it one director call per stop and then
# disarms itself the moment the director answers 'done'. A false NEGATIVE
# leaves a real driver ungated, which is the silent mid-run death this whole
# pair exists to prevent. When in doubt, arm.
#
# 2026-08-19 d03-one-shell-noise-stripper (almanac report 20260814-093113-34a0),
# extending the bias statement above with what THIS fix specifically does and
# does not change: it closes false POSITIVES -- a MENTION of the invocation
# (echoed, commented-out, single- or double-quoted, heredoc-embedded, or bare/
# unquoted) that is never actually executed -- via bp_strip_shell_noise plus
# the reader-segment veto below. It adds NO new requirement on how a genuine
# invocation may be shaped: subcommand choice (next|record-order|park), exact
# script path (relative, absolute, or quoted), a `cd ... &&` prefix, extra CLI
# flags before or after the subcommand, and a trailing pipe all continue to
# arm, exactly as before (see AC8 in the package spec for the enumerated
# shapes this is pinned against).
#
# THREAT MODEL, ruled explicitly (same ruling as w03 for
# guard-validation-interlock.sh, mirrored here rather than re-derived):
# ACCIDENT, not ADVERSARY. Nothing in this repo's design treats a driver
# session as trying to defeat its own gate -- every dispatcher of the Bash
# command this block can see is a butler worker or an interactive driver
# following its own protocol, not an attacker.
#
# ACCEPTED RESIDUALS, not fixed here:
#   - 2026-08-19 fixbatch step7: the previous bullet here claimed $(...) and
#     backtick spans were unresolved and could slip an invocation past this
#     block. That is no longer true (FIX 1 / FIX 2 above; redteam-step6.md
#     CRITICAL-1/CRITICAL-2) -- $(...), backticks and <(...) are now treated
#     as segment boundaries, and their content (including inside double
#     quotes -- bp_strip_shell_noise no longer blanks it) is judged like any
#     other executing segment. Inherited from bp_strip_shell_noise itself
#     (scripts/bp-lib.sh), the ONLY remaining residual of this shape is
#     VARIABLE EXPANSION: a command that builds the invocation text through a
#     variable (`X="bp-drive-next.pl next"; eval "$X"`) still slips past,
#     because nothing here evaluates shell variables. Same direction every
#     existing caller of that helper already accepts.
#   - The driver-arm-specific equivalent of `npm te''st`-style reconstitution:
#     a determined caller could still build `bp-drive-next.pl` plus a
#     subcommand through string concatenation, `eval`, a variable, or a
#     sourced function and arm (or dodge arming) without the literal
#     substring ever appearing in tool_input.command. Accepted for the same
#     reason w03 accepted its analogue: nobody has a reason to spell the
#     director's own invocation that way under the ACCIDENT threat model, and
#     the false-negative bias above means this residual leans toward ARMING a
#     hard-to-classify command, not silently missing a driver.
#
# g01: this block, and its own .drive-solo gate, are UNTOUCHED in effect
# (spec §2.4) -- a drive-solo run must already have an order dir before a
# director call can register a driver here. Only the wake-up-write section
# below (post-ARMING) is restructured to add an independent, unconditional
# continuity write.
if [ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ]; then
  SID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
  if [ "$TOOL" = "Bash" ] && [ -n "$SID" ]; then
    # d03-one-shell-noise-stripper: extract tool_input.command FIRST and
    # match against THAT -- never the raw JSON $PAYLOAD blob. Grepping the
    # raw payload was the root defect this package closes: JSON's own
    # structural double quotes are not shell quotes, and bp_strip_shell_noise
    # is a shell quote-state machine, so feeding it JSON text parses the
    # wrong quoting language. `if [ "$TOOL" = "Bash" ]` above already
    # guarantees a Bash tool_input, so tool_input.command is the right, and
    # only, field to read.
    # fixbatch step7 / FIX 4 (redteam SHOULD-FIX): a JSON object with a
    # DUPLICATE "command" key resolves to whichever bp_json_get's
    # JSON::PP decode keeps -- LAST-WRITE-WINS, which is JSON::PP's own
    # deterministic (not "whichever happens to") decode order, mirroring
    # the RFC 8259 guidance that consumer behaviour on duplicate names is
    # implementation-defined. Left as-is rather than "fixed": bp_json_get
    # lives in hooks/lib.sh, outside this package's write set, so any change
    # to the decode itself is out of scope here. Documenting instead: Claude
    # Code's own tool_input encoder has no reason to ever emit a duplicate
    # "command" key (it is a single Perl/JS hash key, structurally exclusive
    # of duplicates on the producing side) -- this is a defensive concern
    # about a malformed/adversarial payload shape, not one reachable by a
    # normal session, and JSON::PP's last-write-wins is at least
    # deterministic rather than order-random. If this ever needs a
    # false-negative-averse fix, the right owner is bp_json_get itself (e.g.
    # unioning all "command" values rather than picking one), not a
    # workaround duplicated here.
    DCMD=$(bp_json_get "$PAYLOAD" tool_input.command 2>/dev/null || true)
    if [ "$(printf '%s' "$DCMD" | bp_wakeup_arm_check 'bp-drive-next\.pl[^"]*(next|record-order|park)')" = "1" ]; then
      if MARK=$(bp_drive_marker "$SID" 2>/dev/null); then
        mkdir -p "$(dirname "$MARK")" 2>/dev/null \
          && printf '%s\n' "$DATA" > "$MARK" 2>/dev/null || true
      elif ! bp_drive_active_dir >/dev/null 2>&1; then
        echo "butler drive-solo-arm: registry path unresolved (HOME and USERPROFILE both unset) -- driver marker NOT written for session $SID" >&2
      fi
    fi
  fi
fi
# --- end ARMING block --------------------------------------------------------

# ---------------------------------------------------------------------------
# WAKE-UP DETECTION (g01-explicit-continuity-arming, spec §2.4). Computed
# ONCE, unconditionally -- no longer gated behind .drive-solo existing --
# then branched into two INDEPENDENT writes. A session that is simultaneously
# driving AND continuity-armed gets both writes from the same event.
is_wakeup=0
case "$TOOL" in
  Task|Agent)
    is_wakeup=1 ;;                        # always a wake-up -- unchanged for Task, NEW for Agent.
                                           # Deliberately reads NO field off the payload (e.g. no
                                           # subagent_type): that field is verified present for
                                           # Task (track-dispatch.sh:24 and others) but UNVERIFIED
                                           # for Agent (h01 spec §2.3/§6), so this arm is a wake-up
                                           # purely by virtue of the tool name matching.
  Bash)
    # Only a BACKGROUNDED Bash call schedules a wake-up. A foreground command
    # returns into the same turn and schedules nothing, so it must not count.
    #
    # Matched with a raw regex rather than bp_json_get: run_in_background is a
    # JSON *boolean*, and bp_json_get returns EMPTY for booleans (verified
    # 2026-08-07 — it resolves string scalars only). Using it here would have
    # silently classified every backgrounded Bash call as foreground, so the
    # gate would have blocked turns that legitimately scheduled a wake-up.
    if printf '%s' "$PAYLOAD" | grep -q '"run_in_background"[[:space:]]*:[[:space:]]*true'; then
      is_wakeup=1
    fi ;;
esac

[ "$is_wakeup" = 1 ] || exit 0

# --- existing path, UNCHANGED IN EFFECT -- still requires .drive-solo -------
if [ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ]; then
  mkdir -p "$DATA/.drive-solo" 2>/dev/null && \
    printf '%s %s\n' "$TOOL" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
      > "$DATA/.drive-solo/.wakeup-pending" 2>/dev/null || true
fi

# --- NEW path -- independent of .drive-solo, keyed by THIS session's own ---
# continuity marker. Written ONLY if that session is already armed (the
# marker file exists) -- this hook never arms continuity itself.
CSID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
if [ -n "$CSID" ]; then
  if CMARK=$(bp_continuity_marker "$CSID" 2>/dev/null); then
    [ -f "$CMARK" ] && : > "$CMARK.wakeup-pending" 2>/dev/null || true
  fi
fi

exit 0
