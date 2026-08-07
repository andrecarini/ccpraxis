#!/usr/bin/env perl
# 95-watchdog.t — the drive-solo run's dead-man's switch.
#
# WHY A SECOND MECHANISM EXISTS
#
# t/94 covers gate-drive-loop.sh, which catches a driver turn that ends with
# NOTHING SCHEDULED. That is one of two failure modes and the easier one.
#
# The other is WEDGED rather than STOPPED: the driver dispatches a worker, the
# turn legitimately ends (a wake-up WAS scheduled), and the notification never
# arrives — the worker hung, died silently, or is itself waiting on something
# that can never happen. No Stop event fires, so no Stop hook can help. The
# session sits idle indefinitely, looking exactly like a session that is
# working. DAME field report batch-1 #11 is this in the wild: an orphaned
# watcher still looping after seventeen hours, counted as live the whole time.
#
# bp-watchdog.pl is the suspenders to that belt. Armed with run_in_background,
# its own expiry is a wake-up the driver controls, so even if every other
# wake-up in the run is lost the session revives on this one. It converts
# silent death into at most one window of silence.
#
# THE PROPERTY THIS FILE PROTECTS MOST
#
# A watchdog that spins, or waits on a condition that can never be true, is
# just another wedged watcher — the very defect it exists to catch. So the
# structural assertions in section D matter as much as the verdict logic:
# ONE sleep, no loop, no polling, always exit 0, never kills anything.
#
# Runs standalone: perl plugins/butler/tests/t/95-watchdog.t

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $WD = "$Bin/../../scripts/bp-watchdog.pl";

ok(-f $WD, 'A1: bp-watchdog.pl exists');

my $src = do { local (@ARGV, $/) = ($WD); <> };
ok(defined $src && length $src, 'A2: source readable');

# ---------------------------------------------------------------------------
# Fixture: a data dir the watchdog can read. Each case gets its own, so no
# case can observe another's mtimes.
# ---------------------------------------------------------------------------
sub fixture {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $pkgs = "$root/.ccpraxis-local-data/blueprints/x/packages";
    make_path($pkgs);
    my $status = $opt{status} || 'running';
    open my $fh, '>', "$pkgs/p1.md" or die;
    print {$fh} "---\npackage: p1\nstatus: $status\n---\n\nbody\n";
    close $fh;
    return ($root, "$root/.ccpraxis-local-data", $pkgs);
}

sub run_wd {
    my (@args) = @_;
    my $out = `perl "$WD" @args 2>&1`;
    return ($? >> 8, $out);
}

# ---------------------------------------------------------------------------
# B. Snapshot mode — a reading with no wait, so a driver can ask "where are we"
#    without committing to a window.
# ---------------------------------------------------------------------------
{
    my ($root, $data) = fixture();
    my ($rc, $out) = run_wd('--snapshot', '--data', $data);
    is($rc, 0, 'B1: snapshot mode exits 0');
    like($out, qr/SNAPSHOT:/,        'B2: prints a snapshot');
    like($out, qr/statuses=.*running/, 'B3: reads ledger frontmatter status');
    like($out, qr/files=\d+/,        'B4: counts artefacts');
}

# ---------------------------------------------------------------------------
# C. Verdicts. These are the whole point: the driver branches on them.
# ---------------------------------------------------------------------------
{
    my ($root, $data) = fixture();
    my ($rc, $out) = run_wd('--sleep', '2', '--data', $data);
    is($rc, 0, 'C1: armed mode exits 0 even when it has bad news');
    like($out, qr/VERDICT: STALLED/,
         'C2: nothing changed during the window -> STALLED');
    like($out, qr/WHAT TO CHECK/,
         'C3: a STALLED verdict carries a DIAGNOSIS, not just a label — a watchdog '
       . 'that says "something is wrong" without saying what is an alarm, not a tool');
    like($out, qr/marked 'running'/,
         'C4: it names the package that is wedged');
    like($out, qr/ledger untouched/,
         'C5: it reports how long that ledger has been silent — the actual evidence');
    like($out, qr/DEAD dispatch|dies mid-flight/,
         'C6: it warns that a dead worker returns narration that reads like success '
       . '(the coordinator-protocol failure mode), so the reader does not trust it');
}

{
    # Something moves during the window -> PROGRESS.
    my ($root, $data, $pkgs) = fixture();
    my $pid = fork();
    if (defined $pid && $pid == 0) { sleep 1; open my $f, '>', "$pkgs/p2.md"; print {$f} "x\n"; close $f; exit 0 }
    my ($rc, $out) = run_wd('--sleep', '3', '--data', $data);
    waitpid($pid, 0) if defined $pid && $pid > 0;
    is($rc, 0, 'C7: exits 0');
    like($out, qr/VERDICT: PROGRESS/,
         'C8: an artefact appearing during the window -> PROGRESS (re-arm and carry on)');
  SKIP: {
        skip 'fork unavailable', 0 unless defined $pid;
    }
}

# ---------------------------------------------------------------------------
# D. Structural safety. A watchdog that becomes the thing it detects is worse
#    than no watchdog, because its silence reads as "all well".
# ---------------------------------------------------------------------------
{
    # Strip comments before scanning: this file's own header discusses loops and
    # polling at length, and a scan that reads prose would punish the file for
    # documenting its reasoning. Same correction t/94 needed, and t/62's guard.
    my $code = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1;

    # Count sleep CALLS, not the word. The first draft of this assertion matched
    # /\bsleep\b/ and counted the --sleep option name, the $opt{sleep} key and the
    # usage text — 8 "sleeps" for a file containing exactly one. Measuring the
    # wrong thing is how an assertion looks rigorous while asserting nothing;
    # statement position is what actually distinguishes a wait from a mention.
    my $sleep_calls = () = $code =~ /^[ \t]*sleep\b/mg;
    is($sleep_calls, 1, 'D1: EXACTLY ONE sleep call — one wait, then exit. Never a poll '
         . 'loop: wait-shape-guard.sh denies sleep-spin shapes in coordinator sessions, '
         . 'and a watchdog that spins is the very defect it exists to catch');

    unlike($code, qr/while\s*\(\s*1\s*\)/, 'D2: no infinite loop');
    unlike($code, qr/until\s*\(/,          'D3: no until-loop (a condition that can '
                                         . 'never become true is how a watcher wedges)');
    unlike($code, qr/\bkill\b/,            'D4: it never kills anything — it observes and '
                                         . 'reports; remediation is a judgment call and '
                                         . 'stays with the driver');

    like($src, qr/exit 0/,                 'D5: exits 0 on every path');
    unlike($code, qr/\bdie\b/,             'D6: never dies — a watchdog that dies quietly '
                                         . 'is strictly worse than none, because its '
                                         . 'silence is indistinguishable from "all well"');

    # It must not write into a blueprint: an observer that mutates what it
    # observes cannot be trusted about what it saw.
    unlike($code, qr/open\s+my\s+\$\w+\s*,\s*['"]>/,
           'D7: opens nothing for writing — it never mutates the tree it measures');
}

# ---------------------------------------------------------------------------
# E. The doctrine is written down. A mechanism nobody is told to arm is inert.
# ---------------------------------------------------------------------------
{
    my $skill = "$Bin/../../skills/drive-solo/SKILL.md";
    my $s = -f $skill ? do { local (@ARGV, $/) = ($skill); <> } : '';
    like($s, qr/bp-watchdog/,
         'E1: drive-solo tells the driver to arm the watchdog — an unarmed dead-man\'s '
       . 'switch protects nothing');
    like($s, qr/STALLED/,
         'E2: and tells it what to do with the verdict');
}

done_testing();
