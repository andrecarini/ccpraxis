#!/usr/bin/env perl
# platform: windows
# 186 — ONE answer to "will anything bring this back?"
#
# WHY THIS FILE EXISTS. Two guards were answering that question separately:
# bp-runstate.pl for a RUN, stop-gate.sh for a SESSION. The scopes are
# genuinely different and stay separate. The MECHANISM was duplicated, and the
# duplication was not free -- the run side had already learned two things the
# session side had not:
#
#   * kill(0) reports a healthy NATIVE Windows process as dead, so liveness
#     needs a fallback;
#   * A LIVE PID IS NOT THE SAME PID. Both a `hold` and a watcher EXIT when
#     their wait ends -- that is their purpose -- and the OS then reuses the
#     number. The run side's red-team demonstrated this concretely (an unrelated
#     `sleep &` on the recorded pid made a pause read as verified); the session
#     side then shipped a liveness check with exactly that hole.
#
# BpResumption.pm is now the single implementation, and the old resumption CLI is how
# the bash gate reaches it -- shell cannot compute a process fingerprint, so
# translating the rules into shell a second time could only reproduce the gap.
#
# AC1  a marker written by `hold` verifies as a real promise
# AC2  a LIVE pid with a foreign identity is refused (the recycled-pid case)
# AC3  a dead pid is refused
# AC4  an unbounded marker is refused however fresh
# AC5  a passed deadline is refused however alive
# AC6  a marker with no pid, or no identity, is refused as UNVERIFIABLE
# AC7  REMOVED (reason DEL, package 16 batch E1): the old resumption CLI, the CLI
#      this compared the module against, is on the deletion list. The module
#      behaviour AC7 exercised through the CLI is still pinned directly, via
#      AC1-AC6 against BpResumption.pm itself.
# AC8  bp-runstate and the continuity gate use the SAME implementation
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK. This file drives butler-continuity /
# bp-runstate.pl / stop-gate.sh, which hold the machine awake for an armed
# session -- and they do it as SUBPROCESSES, where bp-keepawake.pl's `$0 =~ /\.t\z/`
# guard cannot reach (its $0 is the .pl). CCPRAXIS_NO_WAKELOCK is the supported
# opt-out and IS inherited across exec. Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);

my $SCRIPTS = "$Bin/../../scripts";
my $MOD     = "$SCRIPTS/BpResumption.pm";
ok(-f $MOD, 'BpResumption.pm exists') or BAIL_OUT('module missing');
require $MOD;

# A process that is alive for the duration of this test, to stand in for a live
# hold. Its identity is real, so AC1/AC2 differ ONLY in the recorded fingerprint.
my $live = fork();
if (defined $live && $live == 0) { sleep 60; exit 0 }
SKIP: {
    skip 'fork unavailable', 16 unless defined $live && $live > 0;
    ok(BpResumption::pid_alive($live), 'fixture: the stand-in process is alive');
    my $fp = BpResumption::pid_fingerprint($live);
    ok(defined $fp, 'fixture: and it can be fingerprinted');

    # ── AC1 — the real thing ───────────────────────────────────────────────
    {
        my $line = BpResumption::marker_line(deadline => time() + 600, pid => $live);
        my ($ok, $why) = BpResumption::verify_line($line);
        ok($ok, 'AC1 a marker for a live, fingerprinted process with a future deadline verifies')
            or diag("refused: " . ($why // ''));
    }

    # ── AC2 — THE ONE THAT MATTERS: a recycled pid ────────────────────────
    {
        # Same live pid, an identity that is not its own. Indistinguishable
        # from the OS having handed this number to something else after the
        # holder exited -- which is the ORDINARY case here, since `hold` exits
        # at its deadline by design.
        my $line = BpResumption::marker_line(
            deadline => time() + 600, pid => $live, fingerprint => 'proc:111111111');
        my ($ok, $why) = BpResumption::verify_line($line);
        ok(!$ok, 'AC2 CANONICAL: a LIVE pid whose identity does not match is REFUSED');
        like($why // '', qr/recycled/i, 'AC2 and the refusal names the reason');
    }

    # ── AC4/AC5 — bounded, and still ahead ────────────────────────────────
    {
        my $unbounded = time() . " Bash\n";
        my ($ok, $why) = BpResumption::verify_line($unbounded);
        ok(!$ok, 'AC4 an unbounded marker is refused however fresh');
        like($why // '', qr/not bounded/, 'AC4 named');

        my $past = BpResumption::marker_line(deadline => time() - 5, pid => $live);
        my ($ok2, $why2) = BpResumption::verify_line($past);
        ok(!$ok2, 'AC5 a passed deadline is refused however alive the process is');
        like($why2 // '', qr/deadline/, 'AC5 named');
    }

    # ── AC6 — unverifiable is not trusted ─────────────────────────────────
    {
        my $now = time();
        my $no_pid = "$now bounded " . ($now + 600) . "\n";
        my ($ok, $why) = BpResumption::verify_line($no_pid);
        ok(!$ok, 'AC6 a marker with no pid is refused');
        like($why // '', qr/no pid/, 'AC6 named');

        my $no_fp = "$now bounded " . ($now + 600) . " $live -\n";
        my ($ok2, $why2) = BpResumption::verify_line($no_fp);
        ok(!$ok2, 'AC6 a marker with no recorded identity is refused -- a recycled pid '
                . 'could not be told from the original');
        like($why2 // '', qr/identity/, 'AC6 named');
    }

    # ── AC3 — a dead pid ───────────────────────────────────────────────────
    {
        my $dead = fork();
        if (defined $dead && $dead == 0) { exit 0 }
        waitpid($dead, 0) if defined $dead && $dead > 0;
        SKIP: { skip 'fork unavailable', 2 unless defined $dead && $dead > 0;
            my $line = BpResumption::marker_line(
                deadline => time() + 600, pid => $dead, fingerprint => 'proc:1');
            my ($ok, $why) = BpResumption::verify_line($line);
            ok(!$ok, 'AC3 a dead process is refused');
            like($why // '', qr/not running|identity/, 'AC3 named');
        }
    }

    kill 'TERM', $live;
    waitpid($live, 0);
}

# AC8 (the consumers of BpResumption.pm carry no pid_alive/pid_fingerprint
# copy of their own) is retired with its last subject: bp-worker.pl went with
# the OpenCode worker backend, and no script loads the module directly now.
# The coordinator protocol still names BpResumption::pid_alive as a liveness
# proof, which AC1-AC6 above keep honest.

done_testing();
