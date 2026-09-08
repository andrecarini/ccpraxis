#!/usr/bin/env perl
# 176-mark-wakeup-quoted-script-path.t — toolfix-drivesolo-arm.
#
# THE LIVE DEFECT THIS PINS, OBSERVED THIS SESSION, NOT HYPOTHESISED. A real
# /butler:drive-solo driver session's own Bash invocation quoted its (non-ASCII,
# "Andr\x{e9}") script path defensively:
#
#   perl "C:/Users/Andr\x{e9}/.claude/ccpraxis/plugins/butler/scripts/bp-drive-next.pl" next --scope backup-driver
#
# bp_wakeup_arm_check (mark-wakeup.sh) runs bp_strip_shell_noise (bp-lib.sh)
# on the raw command before matching. That helper blanks EVERY character
# inside a quoted span, quoted program path or not, so the literal text
# "bp-drive-next.pl" is gone from the stripped text before the arming regex
# ever runs. The registry marker under .drive-solo-active/<session_id> was
# never written; both consumers of it were silently inert:
#   1. gate-drive-loop.sh (the Stop gate) never fired for this session at all.
#   2. the statusline's "driving" badge (scripts/statusline.pl) never showed.
# The operator noticed the missing badge; the disarmed gate was the more
# serious half, discovered only by inspecting mark-wakeup.sh's own logic.
#
# THE FIX: mark-wakeup.sh's own bp_unquote_script_paths (local to this file,
# not a change to bp_strip_shell_noise itself — that helper is shared with
# guard-validation-interlock.sh for an unrelated job) un-quotes a quoted span
# BEFORE the strip pipeline runs, but ONLY when the span's entire content is
# a bare path ending ".pl" with no whitespace or shell metacharacter inside.
# Everything else — including a quoted span that merely CONTAINS the
# substring amid other words — is left exactly as bp_strip_shell_noise would
# have found it.
#
# THIS FILE PROVES THREE THINGS TOGETHER, not just "it now arms":
#   A/B. the two real quoted-path shapes (double- and single-quoted) now arm
#        the DRIVER registry, where before this fix (git HEAD at the time
#        this test was authored) neither did — verified by hand against a
#        copy of the pre-fix hook, see the report for the exact commands run.
#   C.   the REPORTER's own arm site (bp-watch.pl --arm --blueprint, quoted
#        the same way) shares the fix, not just the driver's regex.
#   D/E. the two counter-fixtures that prove the detector still VETOES an
#        inert mention -- the whole reason bp_strip_shell_noise exists. If a
#        broader fix had simply stopped blanking quotes altogether, these
#        would fail.
#   F.   the plain unquoted invocation still arms -- no regression.
#
# Runs standalone: perl plugins/butler/tests/t/176-mark-wakeup-quoted-script-path.t

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";

ok(-f $MARK, 'A0: mark-wakeup.sh exists') or BAIL_OUT('hook missing');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub new_drive_solo_root {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data/.drive-solo");
    return $root;
}

# run_mark PAYLOAD, DRIVE_ACTIVE_DIR, REPORTER_ACTIVE_DIR -> (rc, stdout+stderr)
# Both registries are redirected to temp dirs via the documented override
# vars (bp_drive_active_dir / bp_reporter_active_dir, hooks/lib.sh) — this
# test must never write into the real machine-level
# ~/.claude/ccpraxis/.drive-solo-active or .reporter-active.
sub run_mark {
    my ($payload, $active, $rdir) = @_;
    my $out = `CCPRAXIS_DRIVE_ACTIVE_DIR='$active' CCPRAXIS_REPORTER_ACTIVE_DIR='$rdir' bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

# bash_payload CWD SID COMMAND -> JSON tool_input payload for a Bash call,
# encoded with a real JSON encoder (not string interpolation) so an embedded
# double quote in COMMAND is escaped exactly as the real harness escapes it.
sub bash_payload {
    my ($cwd, $sid, $cmd) = @_;
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
}

# check LABEL, COMMAND, SID, EXPECT_DRIVER_ARM, EXPECT_REPORTER_ARM
sub check {
    my ($label, $cmd, $sid, $want_driver, $want_reporter) = @_;
    my $root   = new_drive_solo_root();
    my $active = tempdir(CLEANUP => 1);
    my $rdir   = tempdir(CLEANUP => 1);
    my ($rc, $out) = run_mark(bash_payload($root, $sid, $cmd), $active, $rdir);
    is($rc, 0, "$label: mark-wakeup.sh never blocks (exit 0)") or diag("out: $out");
    my $got_driver   = -f "$active/$sid" ? 1 : 0;
    my $got_reporter = -f "$rdir/$sid"   ? 1 : 0;
    is($got_driver, $want_driver,
       "$label: driver registry marker "
     . ($want_driver ? 'IS' : 'is NOT') . ' written')
        or diag("cmd: $cmd\nout: $out");
    is($got_reporter, $want_reporter,
       "$label: reporter registry marker "
     . ($want_reporter ? 'IS' : 'is NOT') . ' written')
        or diag("cmd: $cmd\nout: $out");
}

# ASCII stand-in for the real path component ("André"). The defect is about
# QUOTING THE WHOLE PROGRAM PATH, not about the specific byte that motivated
# it -- a non-ASCII directory name is why a real session quoted it, but the
# stripping bug this file pins fires on any fully-quoted .pl path regardless
# of what characters are inside. Using an ASCII stand-in here keeps the test
# free of this host's own backtick/heredoc byte-encoding behaviour, which is
# not what this file is testing.
my $USR = "testuser";

# ===========================================================================
# A. THE LIVE REPRODUCTION -- fully DOUBLE-quoted program path. Fails
#    without the fix: confirmed by hand-running this exact command through
#    a copy of the pre-fix hook (git HEAD at authoring time) with the same
#    CCPRAXIS_DRIVE_ACTIVE_DIR override -- the marker was NOT written there.
#    See the report for the exact verification transcript.
# ===========================================================================
check('A (double-quoted path, THE live defect)',
      qq{perl "C:/Users/$USR/.claude/ccpraxis/plugins/butler/scripts/bp-drive-next.pl" next --scope backup-driver},
      'sess-a', 1, 0);

# ===========================================================================
# B. Same defect, SINGLE-quoted path -- must be caught the same way.
# ===========================================================================
check('B (single-quoted path)',
      qq{perl 'C:/Users/$USR/.claude/ccpraxis/plugins/butler/scripts/bp-drive-next.pl' next --scope backup-driver},
      'sess-b', 1, 0);

# ===========================================================================
# C. THE REPORTER'S OWN ARM SITE (bp-watch.pl --arm --blueprint), quoted the
#    identical way, shares the fix -- not just the driver's own regex.
# ===========================================================================
check('C (bp-watch.pl --arm --blueprint, double-quoted path)',
      qq{perl "C:/Users/$USR/.claude/ccpraxis/plugins/butler/scripts/bp-watch.pl" --arm --blueprint bp-x --pid-file bp-x/runs/.orchestrator --max-seconds 1800},
      'sess-c', 0, 1);

# ===========================================================================
# D. COUNTER-FIXTURE -- an inert MENTION (first-word veto). Proves the
#    detector still vetoes; a fix that simply stopped blanking quotes
#    altogether would arm on this too.
# ===========================================================================
check('D (inert mention, grep)',
      'grep bp-drive-next.pl README.md',
      'sess-d', 0, 0);

# ===========================================================================
# E. COUNTER-FIXTURE -- a genuinely inert QUOTED string that merely contains
#    the substring amid other words (not "just a path ending .pl"). This is
#    the honest boundary of the chosen fix: the quoted content here is
#    "perl /x/bp-drive-next.pl next" -- it has an internal space and does not
#    end ".pl" at the closing quote, so bp_unquote_script_paths leaves the
#    quotes in place and bp_strip_shell_noise blanks it exactly as before
#    this fix. Still vetoed.
# ===========================================================================
check('E (inert quoted echo)',
      q{echo "perl /x/bp-drive-next.pl next"},
      'sess-e', 0, 0);

# ===========================================================================
# F. REGRESSION GUARD -- the plain, unquoted invocation (the documented
#    canonical shape) must still arm exactly as before this fix.
# ===========================================================================
check('F (unquoted invocation, no regression)',
      'perl /c/x/bp-drive-next.pl next --scope backup-driver',
      'sess-f', 1, 0);

done_testing();
