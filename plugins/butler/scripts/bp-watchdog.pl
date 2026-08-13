#!/usr/bin/env perl
# bp-watchdog.pl — the drive-solo run's dead-man's switch.
#
# SUPERSEDED by bp-watch.pl (w01-bp-watch), for the drive-solo "wedged
# worker" role this file's own header used to describe below. Neither
# reporter/SKILL.md nor drive-solo/SKILL.md arms this file any more, as of
# that package. Why: snapshot() below (:102-136) has NO subject-scoping
# argument at all -- it walks the ENTIRE .ccpraxis-local-data/blueprints
# tree with File::Find, so a driver's own ledger edit is indistinguishable
# from a worker's progress. That is not historical: it fired live in this
# very repo's session history, reporting VERDICT: PROGRESS three times
# during a real four-hour stall, and it is structurally incapable of being
# fixed by scoping it "a bit better" -- bp-watch.pl's artifact_snapshot()/
# artifact_changed() close the same gap correctly, scoped to exactly the
# paths a caller configures, and additionally poll on a real condition
# rather than a fixed --sleep. This file's CODE below is intentionally
# UNCHANGED (this is a header-only edit) and t/95-watchdog.t stays green,
# byte-for-byte, because nothing it exercises changed -- superseding in
# doctrine is the chosen fix, not a rewrite of internals nothing calls
# again. See .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/
# specs/w01-bp-watch-spec.md §2.3/§3.6 for the full ruling.
#
# WHAT PROBLEM THIS SOLVES, AND WHY THE STOP GATE IS NOT ENOUGH
#
# gate-drive-loop.sh (Stop hook) catches a driver turn that ends with nothing
# scheduled to continue the run. That is one of two failure modes, and it is
# the easier one.
#
# The other is WEDGED rather than STOPPED: the driver dispatches a worker, the
# turn legitimately ends (a wake-up WAS scheduled), and the notification never
# arrives — the worker hung, died silently, or is itself waiting on something
# that will never happen. No Stop event ever fires, so no Stop hook can help.
# The session sits idle, indefinitely, looking exactly like a session that is
# working. The DAME field report's batch-1 #11 is this failure in the wild: an
# orphaned watcher still looping after SEVENTEEN HOURS, counted as live the
# whole time by a liveness probe that matched its own command line.
#
# So this is the suspenders to the Stop gate's belt. It converts "silent death"
# into "at most --sleep seconds of silence".
#
# HOW IT IS USED (the whole protocol)
#
#   1. The driver arms it ONCE, backgrounded:
#        perl bp-watchdog.pl --sleep 1800 --arm
#   2. A backgrounded Bash call notifies the session when it exits. So the
#      watchdog's own expiry IS a wake-up the driver controls. Even if every
#      other wake-up in the run is lost, the session revives on this one.
#   3. On expiry it prints a verdict — SETTLED / PROGRESS / STALLED — plus, when
#      stalled, a diagnosis of WHAT is wedged.
#   4. The driver acts: SETTLED -> stop. PROGRESS -> re-arm. STALLED ->
#      investigate the named cause, then re-arm.
#
# IT MUST NOT BECOME THE THING IT DETECTS
#
# A watchdog that spins, or waits on a condition that can never be true, is
# just another wedged watcher — the exact defect DAME reported. So, by
# construction:
#   * ONE sleep, then exit. No loop, no polling, no condition-waiting. The
#     coordinator protocol forbids sleep-spin shapes and wait-shape-guard.sh
#     mechanically denies them; this file must never grow one.
#   * It never kills anything and never writes into a blueprint. It observes
#     and reports. Remediation is a judgment call and stays with the driver.
#   * Every failure path still prints a verdict and exits 0. A watchdog that
#     dies quietly is strictly worse than none, because its silence is
#     indistinguishable from "all well".
#
# Exit status is ALWAYS 0. The verdict is on stdout, for a human and for the
# driver to read. Do not branch on $?.

use strict;
use warnings;
use File::Find ();

my %opt = (sleep => 1800, data => '', arm => 0, snapshot => 0);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--sleep')    { $opt{sleep} = shift(@ARGV) // 1800 }
    elsif ($a eq '--data')     { $opt{data}  = shift(@ARGV) // '' }
    elsif ($a eq '--arm')      { $opt{arm}   = 1 }
    elsif ($a eq '--snapshot') { $opt{snapshot} = 1 }
    elsif ($a eq '--help')     { usage(); exit 0 }
}
$opt{sleep} = 1800 unless $opt{sleep} =~ /^\d+$/ && $opt{sleep} > 0;

sub usage {
    print <<'USAGE';
usage: bp-watchdog.pl [--sleep SECONDS] [--data DIR] [--arm|--snapshot]

  --arm        take a snapshot, sleep, take another, print a verdict. This is
               the normal mode; run it with run_in_background so its exit
               notifies the session.
  --snapshot   print the current state snapshot and exit (no sleep). For
               testing, and for a driver that wants a reading right now.
  --sleep N    seconds to wait before the second snapshot (default 1800).
  --data DIR   the .ccpraxis-local-data dir; default: discovered upward from cwd.

Always exits 0. The verdict is on stdout: SETTLED | PROGRESS | STALLED.
USAGE
}

# --- locate the data dir, the same way bp-drive-next.pl does ----------------
my $DATA = $opt{data} || $ENV{CCPRAXIS_DATA_DIR} || '';
if (!$DATA) {
    my $d = '.';
    for (1 .. 12) {
        if (-d "$d/.ccpraxis-local-data") { $DATA = "$d/.ccpraxis-local-data"; last }
        $d = "$d/..";
    }
}
if (!$DATA || !-d $DATA) {
    print "VERDICT: UNKNOWN\nreason: no .ccpraxis-local-data found from cwd\n";
    exit 0;
}
my $BP = "$DATA/blueprints";

# --- snapshot ----------------------------------------------------------------
# A cheap, total picture of "has anything moved". Deliberately NOT a semantic
# read of the run: mtimes and statuses are enough to answer the only question
# that matters here, and anything richer would be a second place for the run's
# meaning to be encoded (and to drift).
sub snapshot {
    my %s = (newest_mtime => 0, newest_path => '', files => 0,
             status => {}, running => [], head => '');

    if (-d $BP) {
        File::Find::find({
            no_chdir => 1,
            wanted   => sub {
                my $p = $File::Find::name;
                return unless -f $p;
                # Ignore our own bookkeeping so the watchdog can never see its
                # own writes as progress.
                return if $p =~ m{/\.watchdog};
                $s{files}++;
                my $m = (stat $p)[9] || 0;
                if ($m > $s{newest_mtime}) { $s{newest_mtime} = $m; $s{newest_path} = $p }
                if ($p =~ m{/packages/[^/]+\.md$}) {
                    my $st = ledger_status($p);
                    $s{status}{$st}++ if defined $st;
                    if (defined $st && $st eq 'running') {
                        push @{ $s{running} }, { path => $p, mtime => $m };
                    }
                }
            },
        }, $BP);
    }

    # A commit is progress even when no ledger moved.
    my $head = `git rev-parse --short HEAD 2>/dev/null`;
    $head = '' unless defined $head;
    chomp $head;
    $s{head} = $head;

    return \%s;
}

sub ledger_status {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    my $n = 0;
    my $status;
    while (my $line = <$fh>) {
        last if ++$n > 40;                       # frontmatter only
        $line =~ s/\r?\n\z//;
        last if $n > 1 && $line =~ /^---\s*$/;
        if ($line =~ /^status:\s*(\S+)/) { $status = $1; last }
    }
    close $fh;
    return $status;
}

sub director_action {
    my $script = __FILE__;
    $script =~ s{[^/\\]+$}{bp-drive-next.pl};
    return 'unknown' unless -r $script;
    # Scope the child to OUR data dir -- the one --data / $CCPRAXIS_DATA_DIR /
    # the upward search resolved above. Without this the override stops at
    # snapshot(): the director resolves its own data dir from the CURRENT
    # WORKING DIRECTORY, so the parent reads the directory it was pointed at
    # while the child answers about whatever repo the process happens to be
    # standing in. The two then disagree, and because the 'done' branch below
    # short-circuits ahead of every movement check, the child's answer wins the
    # whole verdict. Observed on 2026-08-08: t/95 built a fixture holding one
    # package marked 'running' and got VERDICT: SETTLED, with the snapshot
    # correctly naming the fixture and the verdict line reporting the real
    # repo's state -- the two halves of one output describing two different
    # trees. Left unfixed this is worse than a wrong answer in a test: an armed
    # watchdog would report SETTLED over a genuinely wedged run, and a
    # dead-man's switch that reports all-clear is the defect it exists to catch.
    #
    # Passed through the ENVIRONMENT, not as an argument, for two reasons.
    # First, the flag names differ -- this script spells it --data, the director
    # spells it --data-dir -- and this repo has repeatedly been bitten by pairs
    # of near-identical names. Second, an absolute data dir on Windows contains
    # a colon, which is exactly the argv shape MSYS2 mangles into a ';'-joined
    # path list. The env var sidesteps both, and it sits above every cwd-derived
    # guess in the director's own resolution order (--data-dir > $CCPRAXIS_DATA_DIR
    # > $BP_PROJECT_ROOT > git toplevel > walk-up > cwd), which is precisely the
    # guess it has to beat.
    #
    # $DATA is forwarded verbatim rather than absolutised: the child inherits
    # this process's working directory, so a relative value resolves to the same
    # place on both sides, and rewriting it risks converting a Windows path into
    # a POSIX one for no gain.
    local $ENV{CCPRAXIS_DATA_DIR} = $DATA;
    my $out = `perl "$script" next 2>/dev/null`;
    return 'unknown' unless defined $out && length $out;
    return ($out =~ /"action"\s*:\s*"([a-z-]+)"/) ? $1 : 'unknown';
}

sub fmt_age {
    my ($secs) = @_;
    return 'unknown' unless defined $secs;
    return sprintf('%dh%02dm', int($secs / 3600), int(($secs % 3600) / 60)) if $secs >= 3600;
    return sprintf('%dm%02ds', int($secs / 60), $secs % 60);
}

sub print_snapshot {
    my ($s, $label) = @_;
    print "$label:\n";
    printf("  files=%d newest=%s (%s ago)\n", $s->{files},
           ($s->{newest_path} || '-'),
           fmt_age($s->{newest_mtime} ? (time - $s->{newest_mtime}) : undef));
    printf("  statuses=%s\n", join(', ', map { "$_=$s->{status}{$_}" } sort keys %{ $s->{status} }) || '(none)');
    printf("  head=%s\n", $s->{head} || '-');
}

# --- snapshot-only mode ------------------------------------------------------
if ($opt{snapshot} && !$opt{arm}) {
    my $s = snapshot();
    print_snapshot($s, 'SNAPSHOT');
    printf("  director=%s\n", director_action());
    exit 0;
}

# --- armed mode --------------------------------------------------------------
my $before = snapshot();
my $t0     = time;

# ONE sleep. Never a loop — see the header. This is the only wait in the file.
sleep $opt{sleep};

my $after   = snapshot();
my $elapsed = time - $t0;
my $action  = director_action();

my $moved =
       ($after->{newest_mtime} != $before->{newest_mtime})
    || ($after->{head}         ne $before->{head})
    || ($after->{files}        != $before->{files})
    || (join('|', map { "$_=$after->{status}{$_}" }  sort keys %{ $after->{status} })
     ne join('|', map { "$_=$before->{status}{$_}" } sort keys %{ $before->{status} }));

print "=== bp-watchdog: ${elapsed}s elapsed ===\n";

if ($action eq 'done') {
    print "VERDICT: SETTLED\n";
    print "The director reports no remaining work. Do not re-arm.\n";
    print_snapshot($after, 'state');
    exit 0;
}

if ($moved) {
    print "VERDICT: PROGRESS\n";
    printf("The run advanced during this window (newest artefact %s ago). Re-arm and carry on.\n",
           fmt_age(time - $after->{newest_mtime}));
    print_snapshot($after, 'state');
    printf("  director=%s\n", $action);
    exit 0;
}

# --- STALLED: nothing moved, and the director still wants work --------------
print "VERDICT: STALLED\n";
printf("Nothing in the blueprint tree changed for %s, and the director still returns '%s'.\n",
       fmt_age($elapsed), $action);
print "\nThis is the failure the Stop gate CANNOT see: a turn that ended with a\n";
print "wake-up scheduled, where the wake-up never arrived. Diagnose before re-arming.\n\n";

print "WHAT TO CHECK, in order:\n";
printf("  1. Newest artefact: %s (%s ago)\n",
       ($after->{newest_path} || '-'),
       fmt_age($after->{newest_mtime} ? (time - $after->{newest_mtime}) : undef));

if (@{ $after->{running} }) {
    print "  2. Package(s) marked 'running' — the likely wedge:\n";
    for my $r (@{ $after->{running} }) {
        printf("       %s (ledger untouched %s)\n", $r->{path}, fmt_age(time - $r->{mtime}));
    }
    print "     A ledger that has not moved for a whole window means its worker is\n";
    print "     not writing. Assume the dispatch is lost rather than slow.\n";
} else {
    print "  2. No package is marked 'running'. If the director still wants work,\n";
    print "     the loop stopped between packages rather than inside one.\n";
}

print "  3. Is a worker genuinely in flight, or was its notification lost?\n";
print "     A dispatched agent that dies mid-flight returns its last narration\n";
print "     as a result, which reads like success — treat an empty or\n";
print "     narration-shaped result as a DEAD dispatch, not a finding of 'nothing'.\n";
print "  4. If a worker is wedged: re-dispatch it. Do not wait longer. A wait\n";
print "     that has already failed once does not improve by being repeated.\n";
print "\n";
print_snapshot($after, 'state');
printf("  director=%s\n", $action);
exit 0;
