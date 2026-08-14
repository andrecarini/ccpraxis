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
  # THE GENERAL RULE this now enforces: scan the raw command byte-by-byte,
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
  # Checked with perl (already required by this hook family) rather than
  # reimplemented as bash arithmetic.
  #
  # This remains a heuristic, not a shell parser: it does not resolve command
  # substitution ($(...)), variable expansion, or backtick spans, so a command
  # that builds the invocation through one of those still slips past -- an
  # accepted residual, in the SAME false-negative direction this trigger is
  # already documented to prefer (spec §1.2 -- "when in doubt, arm" is the
  # driver's bias, this trigger's is the opposite, and this fix does not
  # change that bias, only closes the false-POSITIVE holes redteam found).
  ARMED=$(printf '%s' "$RCMD" | perl -0777 -ne '
      my $s = $_;
      my @c = split //, $s, -1;
      my $n = scalar @c;
      my $filtered = "";
      my $state = "none";      # none | squote | dquote | comment | heredoc
      my $hd = ""; my $hd_tabs = 0; my $hd_pending = 0; my $line = "";
      my $i = 0;
      while ($i < $n) {
        my $ch = $c[$i];
        if ($state eq "heredoc") {
          if ($ch eq "\n") {
            my $chk = $line; $chk =~ s/^\t+// if $hd_tabs;
            $state = "none" if $chk eq $hd;
            $filtered .= (" " x length($line))."\n"; $line = "";
          } else { $line .= $ch }
          $i++; next;
        }
        if ($state eq "comment") {
          $filtered .= ($ch eq "\n" ? "\n" : " ");
          $state = "none" if $ch eq "\n";
          $i++; next;
        }
        if ($state eq "squote") {
          $state = "none" if $ch eq "\x27";
          $filtered .= ($ch eq "\n" ? "\n" : " ");
          $i++; next;
        }
        if ($state eq "dquote") {
          if ($ch eq "\\" && $i+1 < $n) { $filtered .= "  "; $i += 2; next }
          $state = "none" if $ch eq q{"};
          $filtered .= ($ch eq "\n" ? "\n" : " ");
          $i++; next;
        }
        if ($hd_pending && $ch eq "\n") {
          $filtered .= "\n"; $i++; $state = "heredoc"; $hd_pending = 0; $line = ""; next;
        }
        if ($ch eq "\x27") { $state = "squote"; $filtered .= " "; $i++; next }
        if ($ch eq q{"})   { $state = "dquote"; $filtered .= " "; $i++; next }
        if ($ch eq "\\" && $i+1 < $n) { $filtered .= "  "; $i += 2; next }
        if ($ch eq "#") {
          my $p = $filtered; $p =~ s/[ \t]+$//;
          my $last = length($p) ? substr($p, -1) : "";
          if ($last eq "" || $last =~ /[;&|(\n]/) {
            $state = "comment"; $filtered .= " "; $i++; next;
          }
          $filtered .= "#"; $i++; next;
        }
        if ($ch eq "<" && $i+1 < $n && $c[$i+1] eq "<") {
          my $j = $i+2; my $tabs = 0;
          if ($j < $n && $c[$j] eq "-") { $tabs = 1; $j++ }
          $j++ while ($j < $n && $c[$j] =~ /[ \t]/);
          my $q = "";
          if ($j < $n && ($c[$j] eq "\x27" || $c[$j] eq q{"})) { $q = $c[$j]; $j++ }
          my $delim = "";
          $delim .= $c[$j++] while ($j < $n && $c[$j] =~ /[A-Za-z0-9_]/);
          $j++ if (length($q) && $j < $n && $c[$j] eq $q);
          if (length($delim)) {
            $filtered .= (" " x ($j - $i)); $i = $j;
            $hd = $delim; $hd_tabs = $tabs; $hd_pending = 1;
            next;
          }
        }
        $filtered .= $ch; $i++;
      }
      my $armed = 0;
      if ($filtered =~ /bp-watch\.pl[^"]*--arm[^"]*--blueprint\b/) {
        # fixbatch step7 / F1 residual: an UNQUOTED reference (no quoting at
        # all to strip, e.g. `grep -r bp-watch.pl --arm --blueprint foo`)
        # survives the filtering above untouched, because there is nothing
        # quoted to remove. Close it the same way a human reads the command:
        # the SEGMENT containing the match (since the last command separator
        # -- ; & | or newline -- or the start of the string) must not begin
        # with a non-executing READER. A real invocation always starts with
        # the interpreter/script itself (perl, ./bp-watch.pl, bp-watch.pl),
        # never with a command whose whole job is to read or print text.
        my $pre = substr($filtered, 0, $-[0]);
        my $seg = ($pre =~ /.*[;&|\n](.*)$/s) ? $1 : $pre;
        $seg =~ s/^[ \t]+//;
        my ($first) = $seg =~ /^(\S+)/;
        $first = defined($first) ? $first : "";
        $first =~ s{.*/}{};
        $armed = 1 unless $first =~ /^(?:echo|printf|grep|rg|cat|sed|awk)$/;
      }
      print($armed ? "1" : "0");
    ' 2>/dev/null || echo 0)
  if [ "$ARMED" = "1" ]; then
    RSID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
    case "$RSID" in ''|*/*|*\**|.|..|*..*) RSID="" ;; esac
    if [ -n "$RSID" ]; then
      RDIR="${CCPRAXIS_REPORTER_ACTIVE_DIR:-${HOME:-$PWD}/.claude/ccpraxis/.reporter-active}"
      mkdir -p "$RDIR" 2>/dev/null && printf '%s\n' "$DATA" > "$RDIR/$RSID" 2>/dev/null || true
    fi
  fi
fi
# --- end reporter registration block ----------------------------------------

[ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ] || exit 0

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
SID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
if [ "$TOOL" = "Bash" ] && [ -n "$SID" ]; then
  if printf '%s' "$PAYLOAD" | grep -Eq 'bp-drive-next\.pl[^"]*(next|record-order|park)'; then
    if MARK=$(bp_drive_marker "$SID" 2>/dev/null); then
      mkdir -p "$(dirname "$MARK")" 2>/dev/null \
        && printf '%s\n' "$DATA" > "$MARK" 2>/dev/null || true
    fi
  fi
fi

case "$TOOL" in
  Task|Agent)
    : ;;                                  # always a wake-up -- unchanged for Task, NEW for Agent.
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
    printf '%s' "$PAYLOAD" | grep -q '"run_in_background"[[:space:]]*:[[:space:]]*true' || exit 0 ;;
  *)
    exit 0 ;;
esac

mkdir -p "$DATA/.drive-solo" 2>/dev/null || exit 0
printf '%s %s\n' "$TOOL" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
  > "$DATA/.drive-solo/.wakeup-pending" 2>/dev/null || true
exit 0
