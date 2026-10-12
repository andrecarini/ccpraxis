#!/usr/bin/env perl
# platform: any
# Genuine OS-process serialization over one shared record: two independent
# writers both land their change (in some order, neither lost), mutual
# exclusion is observable in a trace rather than merely inferred from a final
# count, and a lock file is never removed from any product code path -- with
# a deliberate demonstration of the two-simultaneous-holders outcome when one
# IS removed, so the reason for that rule is not just asserted but shown.
# Also covers the "shape by grep" checks that pin cas_write's continuing role
# as the second layer and confirm the bypass-refusal behaviour it must keep.
#
# Covers AC-1 .. AC-4, AC-13, AC-14, AC-19, AC-22 of
# specs/01-lock-primitive-spec.md.
#
# This file deliberately never mentions the load-modify-write race-test env
# var, and never calls the suspend/resume test seam -- the concurrency below
# is real OS processes, not that seam. AC-3 asserts this about itself.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes ();
use Fcntl qw(:flock);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $A       = "$S/almanac-bug.pl";
my $LOCK_PM = "$S/Almanac/Lock.pm";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');
ok(-f $LOCK_PM, 'Almanac::Lock module file exists at plugins/almanac/scripts/Almanac/Lock.pm')
    or diag('Almanac::Lock.pm is not present yet -- assertions below that depend on it are '
          . 'expected to fail for exactly that reason.');

# --- live-store sanity (house convention, spec section 6.3) -----------------
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIVE_STORE = "$REPO/.ccpraxis-local-data/bug-reports";
sub count_reports_in {
    my ($dir) = @_;
    return 0 unless -d $dir;
    opendir(my $dh, $dir) or return 0;
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return scalar @f;
}
my $live_before = count_reports_in($LIVE_STORE);
# Decision 120(c): presence in the real gitignored live store is never REQUIRED -- only that this suite leaves its count unchanged (checked below).

# =============================================================================
# Scaffolding
# =============================================================================

sub slurp_or {
    my ($path) = @_;
    return '(missing)' unless -e $path;
    open(my $fh, '<', $path) or return "(unreadable: $!)";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

sub bounded_wait_for_file {
    my ($path, $deadline_s) = @_;
    my $t0 = Time::HiRes::time();
    my $deadline = $t0 + $deadline_s;
    while (!-e $path) {
        return 0 if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.02);
    }
    return 1;
}

# run_barrier_pair($workdir, $child_pl, \@argv1, \@argv2) -> \%result | undef
#
# Spawns TWO real, separate OS processes of $child_pl, argv = (workdir, n,
# @{$argvN}), backgrounded via the POSIX-shell "&" this host's perl already
# relies on (spec section 6.1). Waits (bounded) for both to signal readiness
# via ready.<n>, releases the start barrier by creating "go", then waits
# (bounded) for both done.<n> sentinels. NEVER uses wait/waitpid -- these
# children are not this process's children (they were shell-backgrounded).
sub run_barrier_pair {
    my ($workdir, $child_pl, $argv1, $argv2) = @_;
    my %argv_by_n = (1 => $argv1, 2 => $argv2);
    for my $n (1, 2) {
        my @argv = ($workdir, $n, @{ $argv_by_n{$n} });
        my $argstr = join(' ', map { qq{"$_"} } @argv);
        system(qq{perl "$child_pl" $argstr > "$workdir/spawn-log.$n" 2>&1 &});
    }
    my %pids;
    for my $n (1, 2) {
        my $ready = "$workdir/ready.$n";
        unless (bounded_wait_for_file($ready, 30)) {
            fail("barrier: child $n never signalled ready within 30s");
            diag("spawn-log.$n: " . slurp_or("$workdir/spawn-log.$n"));
            return undef;
        }
        chomp(my $pid = slurp_or($ready));
        $pids{$n} = $pid;
    }
    open(my $gf, '>', "$workdir/go") or die "cannot write go sentinel: $!";
    close $gf;
    my %done;
    for my $n (1, 2) {
        my $donefile = "$workdir/done.$n";
        unless (bounded_wait_for_file($donefile, 60)) {
            fail("barrier: child $n never signalled done within 60s");
            diag("spawn-log.$n: " . slurp_or("$workdir/spawn-log.$n"));
            return undef;
        }
        $done{$n} = slurp_or($donefile);
    }
    return { pids => \%pids, done => \%done };
}

# A generic barrier-respecting child that, once released, runs a given
# command line (perl + arguments) through the shell and records its exit
# code. Used by AC-1 to run two real `almanac-bug.pl append` invocations.
sub write_cli_child {
    my ($path) = @_;
    open my $fh, '>', $path or die "fixture: cannot write $path: $!";
    print {$fh} <<'CLICHILD';
#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes ();
$| = 1;
my ($workdir, $n, $home, @cmd) = @ARGV;
open(my $rf, '>', "$workdir/ready.$n") or die "child $n: cannot write ready: $!";
print {$rf} $$;
close $rf;
my $barrier_deadline = time() + 30;
while (!-e "$workdir/go") {
    if (time() > $barrier_deadline) {
        open(my $df, '>', "$workdir/done.$n"); print {$df} "TIMEOUT-WAITING-FOR-GO\n"; close $df;
        exit 1;
    }
    Time::HiRes::sleep(0.01);
}
local $ENV{ALMANAC_HOME} = $home;
my $cmdstr = join(' ', map { qq{"$_"} } @cmd) . " > \"$workdir/cli-out.$n\" 2>&1";
system($cmdstr);
my $rc = $? >> 8;
open(my $df, '>', "$workdir/done.$n") or exit 1;
print {$df} "RC=$rc\n";
close $df;
exit 0;
CLICHILD
    close $fh;
}

# A barrier-respecting child that performs $cycles lock-protected
# read-modify-write cycles against a shared counter file through
# Almanac::Lock directly (require'd at RUNTIME, inside eval, so a missing
# module fails this child's very first cycle instead of failing to compile
# -- the child still reaches the barrier and reports promptly either way).
sub write_lock_cycle_child {
    my ($path) = @_;
    open my $fh, '>', $path or die "fixture: cannot write $path: $!";
    print {$fh} <<'CYCLECHILD';
#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes ();
$| = 1;
my ($workdir, $n, $scripts_dir, $counterfile, $tracefile, $cycles) = @ARGV;
open(my $rf, '>', "$workdir/ready.$n") or die "child $n: cannot write ready: $!";
print {$rf} $$;
close $rf;
my $barrier_deadline = time() + 30;
while (!-e "$workdir/go") {
    if (time() > $barrier_deadline) {
        open(my $df, '>', "$workdir/done.$n"); print {$df} "TIMEOUT-WAITING-FOR-GO\n"; close $df;
        exit 1;
    }
    Time::HiRes::sleep(0.01);
}
my $self_destruct = time() + 45;
my ($successes, $timeouts, $other_errors) = (0, 0, 0);
for my $i (1 .. $cycles) {
    if (time() > $self_destruct) {
        open(my $df, '>', "$workdir/done.$n");
        print {$df} "TIMEOUT-MID-RUN successes=$successes timeouts=$timeouts other_errors=$other_errors\n";
        close $df;
        exit 1;
    }
    local @INC = ($scripts_dir, @INC);
    my ($lock, $err) = eval {
        require Almanac::Lock;
        Almanac::Lock->acquire($counterfile, timeout_ms => 10000, verb => 'race-test');
    };
    if (!defined $lock) {
        if (ref $err eq 'HASH' && (($err->{kind} // '') eq 'timeout')) { $timeouts++ }
        else { $other_errors++ }
        next;
    }
    $successes++;

    open(my $tf, '>>', $tracefile) or die "child $n: cannot append trace: $!";
    print {$tf} sprintf("BEGIN %d %.6f\n", $$, Time::HiRes::time());
    close $tf;

    my $val = 0;
    if (open(my $cf, '<', $counterfile)) {
        local $/;
        my $c = <$cf>;
        close $cf;
        $val = defined($c) ? ($c + 0) : 0;
    }
    Time::HiRes::sleep(0.002); # widen the window -- a missing lock loses this reliably
    eval { Almanac::Lock::write_atomic($counterfile, ($val + 1) . "\n") };

    open(my $tf2, '>>', $tracefile) or die "child $n: cannot append trace: $!";
    print {$tf2} sprintf("END %d %.6f\n", $$, Time::HiRes::time());
    close $tf2;

    eval { $lock->release };
}
open(my $df, '>', "$workdir/done.$n") or exit 1;
print {$df} "successes=$successes timeouts=$timeouts other_errors=$other_errors\n";
close $df;
exit 0;
CYCLECHILD
    close $fh;
}

my $WORK14 = tempdir(CLEANUP => 1);
$WORK14 =~ s{\\}{/}g;

# =============================================================================
# AC-1 (DC1) -- two concurrent OS processes both land their change.
# =============================================================================
my ($ac1_pid1, $ac1_pid2);
{
    my $WORKDIR = tempdir(CLEANUP => 1);
    $WORKDIR =~ s{\\}{/}g;
    my $HOME = tempdir(CLEANUP => 1);
    my $PROJ = tempdir(CLEANUP => 1);
    $PROJ =~ s{\\}{/}g;

    my $cmd0 = qq{ALMANAC_HOME="$HOME" perl "$A" file --project "$PROJ" --title "AC1 shared target" --body "seed body"};
    chomp(my $path = `$cmd0 2>&1`);
    my ($id) = $path =~ m{/([^/]+)\.md$};
    ok(-f $path, 'AC-1 fixture: the shared target report was created') or diag("cmd0 output: $path");

    my $bodyA = "$WORKDIR/body-A.txt";
    my $bodyB = "$WORKDIR/body-B.txt";
    open(my $fa, '>', $bodyA) or die; print {$fa} "AC1-MARKER-CHILD-A this is child A's appended text\n"; close $fa;
    open(my $fb, '>', $bodyB) or die; print {$fb} "AC1-MARKER-CHILD-B this is child B's appended text\n"; close $fb;

    my $cli_child = "$WORKDIR/cli-child.pl";
    write_cli_child($cli_child);

    my $result = run_barrier_pair(
        $WORKDIR, $cli_child,
        [$HOME, 'perl', $A, 'append', $id, '--project', $PROJ, '--body-file', $bodyA],
        [$HOME, 'perl', $A, 'append', $id, '--project', $PROJ, '--body-file', $bodyB],
    );

    if ($result) {
        $ac1_pid1 = $result->{pids}{1};
        $ac1_pid2 = $result->{pids}{2};
        ok(defined($ac1_pid1) && defined($ac1_pid2) && $ac1_pid1 ne $ac1_pid2
           && $ac1_pid1 != $$ && $ac1_pid2 != $$,
           'AC-1/AC-3: the two children are distinct real OS processes (pids differ from each other and from $$)');

        my ($rc1) = $result->{done}{1} =~ /^RC=(-?\d+)/m;
        my ($rc2) = $result->{done}{2} =~ /^RC=(-?\d+)/m;
        ok(defined($rc1) && $rc1 == 0, 'AC-1: child A (append) exits 0') or diag("done.1: $result->{done}{1}");
        ok(defined($rc2) && $rc2 == 0, 'AC-1: child B (append) exits 0') or diag("done.2: $result->{done}{2}");

        my $raw = slurp_or($path);
        my ($final_body) = $raw =~ /\A---\r?\n.*?\r?\n---\r?\n(.*)\z/s;
        $final_body //= '';
        like($final_body, qr/AC1-MARKER-CHILD-A/, "AC-1: the final body contains child A's marker");
        like($final_body, qr/AC1-MARKER-CHILD-B/, "AC-1: the final body contains child B's marker -- BOTH landed, in some order");

        my ($updated_at) = $raw =~ /^updated_at:\s*(.+)$/m;
        ok(defined($updated_at) && length($updated_at), 'AC-1: updated_at is present on the final report');

        my $verify_cmd = qq{ALMANAC_HOME="$HOME" perl "$A" verify --project "$PROJ" 2>&1};
        my $vout = `$verify_cmd`;
        my $vrc = $? >> 8;
        is($vrc, 0, 'AC-1: verify on the scratch project exits 0') or diag($vout);
    } else {
        fail('AC-1: both children signalled ready and done (see diagnostics above)') for 1 .. 6;
    }
}

# =============================================================================
# AC-3 (DC1) -- the concurrency is genuine, not a seam.
# =============================================================================
{
    my $own_src = slurp_or($0);
    # Deliberately built with concatenation so this line of source text never
    # contains the literal env-var name as a contiguous token, which would
    # make this very check trivially fail against itself.
    my $seam_env_var = 'ALMANAC_RACE' . '_TEST_HOOK';
    ok($own_src !~ /\Q$seam_env_var\E/, 'AC-3: this file never mentions the load-modify-write race-test hook env var');
    ok($own_src !~ /->\s*suspend\b/,    'AC-3: this file never calls the suspend method');
    ok($own_src !~ /->\s*resume\b/,     'AC-3: this file never calls the resume method');
    my $di_word = 'on_' . 'rename';
    ok($own_src !~ /\Q$di_word\E/,      'AC-3: this file never mentions the rename dependency-injection hook');

    ok(defined($ac1_pid1) && defined($ac1_pid2) && $ac1_pid1 ne $ac1_pid2
       && $ac1_pid1 != $$ && $ac1_pid2 != $$,
       'AC-3: the two AC-1 children were genuinely separate OS processes, both observed alive (via their own ready sentinels) before the barrier was released');
}

# =============================================================================
# AC-2 (DC1) -- no lost update under repetition; AC-4 (DC1) -- mutual
# exclusion is observable, not merely inferred.
# =============================================================================
{
    my $WORKDIR = tempdir(CLEANUP => 1);
    $WORKDIR =~ s{\\}{/}g;
    my $counterfile = "$WORKDIR/counter.txt";
    open(my $cf, '>', $counterfile) or die; print {$cf} "0\n"; close $cf;
    my $tracefile = "$WORKDIR/trace.log";
    open(my $tf, '>', $tracefile) or die; close $tf;

    my $cycle_child = "$WORKDIR/lock-cycle-child.pl";
    write_lock_cycle_child($cycle_child);

    my $CYCLES = 50;
    my $argv = [$S, $counterfile, $tracefile, $CYCLES];
    my $result = run_barrier_pair($WORKDIR, $cycle_child, $argv, $argv);

    if ($result) {
        ok(defined $result->{pids}{1} && defined $result->{pids}{2}
           && $result->{pids}{1} ne $result->{pids}{2},
           'AC-2/AC-4: the two counter-cycling children are distinct real OS processes');

        my %summary;
        for my $n (1, 2) {
            my $d = $result->{done}{$n};
            if ($d =~ /successes=(\d+)\s+timeouts=(\d+)\s+other_errors=(\d+)/) {
                $summary{$n} = { successes => $1, timeouts => $2, other_errors => $3 };
            } else {
                $summary{$n} = { successes => 0, timeouts => 0, other_errors => 0 };
            }
        }
        for my $n (1, 2) {
            is($summary{$n}{successes}, $CYCLES, "AC-2: child $n reports $CYCLES successful acquisitions")
                or diag("done.$n: $result->{done}{$n}");
            is($summary{$n}{timeouts}, 0, "AC-2: child $n reports zero timeouts")
                or diag("done.$n: $result->{done}{$n}");
        }

        my $final_counter = -1;
        if (open(my $f, '<', $counterfile)) {
            local $/;
            my $v = <$f>;
            close $f;
            $final_counter = ($v // '') =~ /(\d+)/ ? $1 : -1;
        }
        is($final_counter, $CYCLES * 2,
           'AC-2: the shared counter reaches exactly ' . ($CYCLES * 2) . ' -- no update was lost to the race');

        open(my $trf, '<', $tracefile) or die;
        my @lines = <$trf>;
        close $trf;
        chomp @lines;
        my ($good, $pairs, $current) = (1, 0, undef);
        for my $line (@lines) {
            if ($line =~ /^BEGIN (\d+) /) {
                if (defined $current) { $good = 0; last }
                $current = $1;
            } elsif ($line =~ /^END (\d+) /) {
                unless (defined $current && $current == $1) { $good = 0; last }
                $current = undef;
                $pairs++;
            } else {
                $good = 0;
                last;
            }
        }
        $good = 0 if defined $current;
        unless (ok($good, 'AC-4: every BEGIN in the trace is immediately followed by its own END -- no interleaving observed')) {
            diag('trace had ' . scalar(@lines) . ' line(s); first few: ' . join(' | ', @lines[0 .. ($#lines < 4 ? $#lines : 4)]));
        }
        is($pairs, $CYCLES * 2, 'AC-4: the trace contains exactly ' . ($CYCLES * 2) . ' non-interleaved BEGIN/END pairs');
    } else {
        fail('AC-2/AC-4: both counter-cycling children completed (see diagnostics above)') for 1 .. 5;
    }
}

# =============================================================================
# AC-13 (DC4) -- no code path unlinks a lock file, by grep.
# =============================================================================
{
    my @lockpm_hits;
    if (-f $LOCK_PM) {
        open(my $fh, '<', $LOCK_PM) or die;
        my $n = 0;
        while (my $line = <$fh>) {
            $n++;
            next if $line =~ /^\s*#/;
            push @lockpm_hits, "$LOCK_PM:$n: $line" if $line =~ /\bunlink\b/;
        }
        close $fh;
    }
    unless (ok(@lockpm_hits == 0, 'AC-13 scan1: Lock.pm contains no unlink at all')) {
        diag($_) for @lockpm_hits;
    }

    my @bug_bad;
    {
        open(my $fh, '<', $A) or die;
        my $n = 0;
        while (my $line = <$fh>) {
            $n++;
            next if $line =~ /^\s*#/;
            if ($line =~ /\bunlink\b/ && $line !~ /\bunlink\s+\$tmp\b/) {
                push @bug_bad, "$A:$n: $line";
            }
        }
        close $fh;
    }
    unless (ok(@bug_bad == 0, 'AC-13 scan1: every unlink in almanac-bug.pl targets $tmp, nothing else')) {
        diag($_) for @bug_bad;
    }

    # Scan 2 -- nothing in the write set unlinks anything whose name mentions
    # a lock, except the ONE deliberate demonstration below (AC-14). Built
    # from split fragments so THIS regex-construction line can never itself
    # be counted as a hit by the very scan it defines.
    my $word_unlink = 'unl' . 'ink';
    my $word_lock   = 'loc' . 'k';
    my $re2 = qr/^[^#]*\b\Q$word_unlink\E\b[^;]*\Q$word_lock\E/i;

    my @WRITESET = ($LOCK_PM, $A, $0,
                     "$Bin/almanac-lock-bounded-acquire.t",
                     "$Bin/almanac-lock-rename-retry.t");
    my @scan2_hits;
    for my $f (@WRITESET) {
        next unless -f $f;
        open(my $fh, '<', $f) or next;
        my $n = 0;
        while (my $line = <$fh>) {
            $n++;
            next if $line =~ /^\s*#/;
            push @scan2_hits, "$f:$n: $line" if $line =~ $re2;
        }
        close $fh;
    }
    is(scalar(@scan2_hits), 1, 'AC-13 scan2: exactly one line removes a file whose name mentions a lock')
        or diag($_) for @scan2_hits;
    if (@scan2_hits == 1) {
        like($scan2_hits[0], qr/DELIBERATE-UNLINK-DEMO/,
             'AC-13 scan2: ...and it is the marked deliberate demonstration line (AC-14, below)');
    } else {
        fail('AC-13 scan2: ...and it is the marked deliberate demonstration line (AC-14, below)');
    }
}

# =============================================================================
# AC-14 (DC4) -- the two-holders outcome, demonstrated.
# =============================================================================
{
    my $ac14_holder_pl = "$WORK14/ac14-holder.pl";
    open(my $hfh, '>', $ac14_holder_pl) or die "fixture: cannot write $ac14_holder_pl: $!";
    print {$hfh} <<'HOLDER14';
#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(:flock);
use Time::HiRes ();
$| = 1;
my ($lockpath, $hold_s, $readypath, $releasedpath) = @ARGV;
open(my $fh, '>', $lockpath) or do {
    open(my $rf, '>', $readypath); print {$rf} "OPEN-FAIL $!"; close $rf; exit 1;
};
flock($fh, LOCK_EX) or do {
    open(my $rf, '>', $readypath); print {$rf} "FLOCK-FAIL $!"; close $rf; exit 1;
};
open(my $rf, '>', $readypath) or exit 1;
print {$rf} $$;
close $rf;
Time::HiRes::sleep($hold_s || 0);
close $fh;
open(my $df, '>', $releasedpath) or exit 1;
print {$df} "RELEASED\n";
close $df;
exit 0;
HOLDER14
    close $hfh;

    my $t14         = "$WORK14/ac14-target.md";
    open(my $sfh, '>', $t14) or die; print {$sfh} "seed\n"; close $sfh;
    my $lockpath14  = "$t14.lock";
    my $ready14     = "$WORK14/ac14-ready";
    my $released14  = "$WORK14/ac14-released";
    my $log14       = "$WORK14/ac14-log";

    system(qq{perl "$ac14_holder_pl" "$lockpath14" "3" "$ready14" "$released14" > "$log14" 2>&1 &});
    ok(bounded_wait_for_file($ready14, 10), 'AC-14: the holder child signalled ready')
        or diag('holder log: ' . slurp_or($log14));

    # 1. Baseline: the lock is genuinely held.
    {
        open(my $probe, '>', $lockpath14) or die "AC-14: cannot open $lockpath14: $!";
        my $got = flock($probe, LOCK_EX | LOCK_NB) ? 1 : 0;
        close $probe;
        ok(!$got, 'AC-14: baseline -- a fresh non-blocking flock against the held lock FAILS');
    }

    # 2. Unlink the held lock file. This line is the deliberate demonstration
    #    AC-13's scan2 expects to find exactly once, marked so the scan does
    #    not mistake it for a regression.
    my $unlinked = unlink($lockpath14); # DELIBERATE-UNLINK-DEMO
    ok($unlinked, 'AC-14: unlinking the still-held lock file SUCCEEDS (this is exactly why C4 forbids it)');

    # 3. A fresh open at the same path is a NEW inode, immediately lockable.
    {
        open(my $probe2, '>', $lockpath14) or die "AC-14: cannot re-open $lockpath14: $!";
        my $got2 = flock($probe2, LOCK_EX | LOCK_NB) ? 1 : 0;
        ok($got2, 'AC-14: a fresh open at the SAME path (a new inode) is immediately lockable -- a second holder now exists');
        flock($probe2, LOCK_UN) if $got2;
        close $probe2;
    }

    # 4. The original holder has not released -- it is STILL holding.
    ok(!-e $released14, 'AC-14: the ORIGINAL holder has not released yet -- both it and the fresh lock above are simultaneous holders');

    diag('AC-14 conclusion: two processes now hold "the lock" at the same time, because unlinking a '
       . 'flock lock FILE does not release the KERNEL lock (bound to the open file description) -- it '
       . 'only clears the directory entry, so a fresh open() at the same path gets an uncontended new '
       . 'inode. This is why C4 forbids unlinking a lock file from any product code path, and why '
       . 'flock needs no reaping: there is nothing to reap, only something that must never be removed.');

    ok(bounded_wait_for_file($released14, 10), 'AC-14: fixture cleanup -- the holder eventually finishes on its own');
}

# =============================================================================
# AC-19 (DC4, DC6, DC7) -- the shape of almanac-bug.pl after the change, by grep.
# =============================================================================
{
    open(my $fh, '<', $A) or die;
    my @lines = <$fh>;
    close $fh;
    my $src = join('', @lines);

    my ($calls, $defs) = (0, 0);
    for my $line (@lines) {
        next if $line =~ /^\s*#/;
        $calls++ while $line =~ /\bcas_write\s*\(/g;
        $defs++ if $line =~ /^\s*sub\s+cas_write\b/;
    }
    # Four mutating verbs, plus where-things-go package 07's reconcile, which
    # rewrites a report's status under its own lock (see the 'reconcile'
    # acquire site below).
    is($calls, 5, 'AC-19: cas_write is called exactly five times (four mutating verbs + reconcile)');
    is($defs, 1, 'AC-19: cas_write is defined exactly once');

    if ($src =~ /^sub cas_write \{(.*?)^\}/ms) {
        my $body = $1;
        ok($body !~ /\bacquire\b/, 'AC-19: cas_write body contains no acquire');
        ok($body !~ /\bflock\b/,   'AC-19: cas_write body contains no flock');
        ok($body !~ /\brelease\b/, 'AC-19: cas_write body contains no release');
        ok($body !~ /\bsuspend\b/, 'AC-19: cas_write body contains no suspend');
        ok($body !~ /\bresume\b/,  'AC-19: cas_write body contains no resume');
    } else {
        fail("AC-19: cas_write's body must not contain $_") for qw(acquire flock release suspend resume);
    }

    my (@acquire_lines, @load_lines);
    for my $i (0 .. $#lines) {
        push @acquire_lines, $i if $lines[$i] =~ /Almanac::Lock->acquire\s*\(/;
        push @load_lines,    $i if $lines[$i] =~ /AlmanacBug::load\s*\(/;
    }

    # Decision 36 / package 09: claim_report_path (verb => 'file') and
    # verify's tampered/unreadable re-check (verb => 'verify') both take a
    # real Almanac::Lock->acquire with no corresponding AlmanacBug::load --
    # neither verb reads a report through load(). Package 12 added a fourth
    # mutating verb, 'takeover' (claiming a bug under triaging with a
    # hook-issued ticket), with its own acquire() pinned above its load()
    # just like the original three. Classify every acquire site by its own
    # verb=>'...' argument: the four mutating verbs
    # (update/append/set-status/takeover) stay pinned above their load();
    # 'file' and 'verify' are the two allowed extras; anything else is not
    # permitted.
    my (@mutating_acquire, @extra_acquire, @other_acquire);
    for my $i (@acquire_lines) {
        if ($lines[$i] =~ /verb\s*=>\s*['"](?:update|append|set-status|takeover)['"]/) {
            push @mutating_acquire, $i;
        } elsif ($lines[$i] =~ /verb\s*=>\s*['"](?:file|verify|reconcile)['"]/) {
            push @extra_acquire, $i;
        } else {
            push @other_acquire, $i;
        }
    }
    unless (ok(scalar(@other_acquire) == 0, 'AC-19: no acquire() site outside the seven named verbs')) {
        diag("line " . ($_ + 1) . ": $lines[$_]") for @other_acquire;
    }
    is(scalar(@mutating_acquire), 4,
        'AC-19: Almanac::Lock->acquire appears exactly four times for the mutating verbs (update/append/set-status/takeover)');
    is(scalar(@extra_acquire), 3,
        "AC-19: exactly three extra acquire sites, verb => 'file' (claim_report_path), 'verify' (verify's re-check) and 'reconcile'");

    # where-things-go package 07: reconcile runs before EVERY verb, so its lock
    # must never wait (timeout_ms => 0, a busy report is skipped), and since its
    # pre-lock load() is only a cheap filter, it must re-load under the lock
    # before deciding anything -- otherwise it would write a stale view.
    my ($rec_i) = grep { $lines[$_] =~ /verb\s*=>\s*['"]reconcile['"]/ } @extra_acquire;
    ok(defined $rec_i && $lines[$rec_i] =~ /timeout_ms\s*=>\s*0\b/,
        "AC-19: reconcile's acquire never waits (timeout_ms => 0)");
    ok(defined $rec_i && (grep { $lines[$_] =~ /\bload\s*\(/ } ($rec_i + 1) .. ($rec_i + 8)),
        "AC-19: reconcile re-loads the report under its lock");
    ok((grep { $lines[$_] =~ /verb\s*=>\s*['"]file['"]/ } @extra_acquire),
        "AC-19: one extra acquire site names verb => 'file'");
    ok((grep { $lines[$_] =~ /verb\s*=>\s*['"]verify['"]/ } @extra_acquire),
        "AC-19: one extra acquire site names verb => 'verify'");

    my $all_above = (@mutating_acquire == 4 && @load_lines == 4) ? 1 : 0;
    if ($all_above) {
        for my $i (0 .. 3) {
            $all_above = 0 unless $mutating_acquire[$i] < $load_lines[$i];
        }
    }
    ok($all_above, "AC-19: each mutating-verb acquire() occurs ABOVE its verb's load() call");

    my ($susp, $res) = (0, 0);
    for my $line (@lines) {
        next if $line =~ /^\s*#/;
        $susp++ if $line =~ /->\s*suspend\b/;
        $res++  if $line =~ /->\s*resume\b/;
    }
    is($susp, 1, 'AC-19: suspend appears exactly once');
    is($res,  1, 'AC-19: resume appears exactly once');
    if ($src =~ /sub _race_test_hook \{(.*?)^\}/ms) {
        my $hookbody = $1;
        my $seam_env_var = 'ALMANAC_RACE' . '_TEST_HOOK';
        like($hookbody, qr/\Q$seam_env_var\E/, 'AC-19: _race_test_hook begins with its env-var guard');
        ok(($hookbody =~ /->\s*suspend\b/) && ($hookbody =~ /->\s*resume\b/),
           'AC-19: suspend and resume both live inside _race_test_hook');
    } else {
        fail('AC-19: _race_test_hook begins with its env-var guard');
        fail('AC-19: suspend and resume both live inside _race_test_hook');
    }

    my $di_word = 'on_' . 'rename';
    ok($src !~ /\Q$di_word\E/, 'AC-19: the rename dependency-injection hook does not appear anywhere in almanac-bug.pl');

    my $wrong_claim = 'no portable, trustworthy OS-level lock';
    ok($src !~ /\Q$wrong_claim\E/, 'AC-19: the wrong "no portable lock" claim no longer appears');
    for my $tok ('bp-blueprint.pl:425', '2026-09-11', 'flock works here', 'LAYER TWO') {
        ok($src =~ /\Q$tok\E/, "AC-19: the replacement comment carries the token '$tok'");
    }

    if (-f $LOCK_PM) {
        open(my $lfh, '<', $LOCK_PM) or die;
        my @luses;
        while (my $line = <$lfh>) {
            push @luses, $line if $line =~ /^\s*(use|require)\s+/;
        }
        close $lfh;
        my @allowed = (
            qr/^\s*use\s+strict\b/,       qr/^\s*use\s+warnings\b/,
            qr/^\s*use\s+Fcntl\b/,        qr/^\s*use\s+Time::HiRes\b/,
            qr/^\s*use\s+Errno\b/,        qr/^\s*use\s+JSON::PP\b/,
            qr/^\s*use\s+Sys::Hostname\b/,
        );
        my @bad_imports = grep { my $l = $_; !grep { $l =~ $_ } @allowed } @luses;
        unless (ok(@bad_imports == 0, 'AC-19: Lock.pm imports nothing outside the six documented core modules')) {
            diag($_) for @bad_imports;
        }
        my @forbidden = grep { /butler|BpResumption|use lib|FindBin/ } @luses;
        ok(@forbidden == 0, 'AC-19: Lock.pm never mentions butler/BpResumption/use lib/FindBin');
    } else {
        fail('AC-19: Lock.pm must exist to verify its import list is exactly the six documented modules');
        fail('AC-19: Lock.pm must exist to verify it never mentions butler/BpResumption/use lib/FindBin');
    }
}

# =============================================================================
# AC-22 (DC7) -- cas_write still refuses a writer that bypassed the lock.
# =============================================================================
{
    my $PROJ22 = tempdir(CLEANUP => 1);
    (my $proj22 = $PROJ22) =~ s{\\}{/}g;
    my $HOME22 = tempdir(CLEANUP => 1);

    my $cmd = qq{ALMANAC_HOME="$HOME22" perl "$A" file --project "$proj22" --title "AC22 target" --body "original"};
    chomp(my $path = `$cmd 2>&1`);
    ok(-f $path, 'AC-22 fixture: a report was created') or diag("path=[$path]");

    # In-process via `do $A`, per house convention (frontmatter-injection.t
    # uses the same trick -- `unless (caller)` makes it safe here since `do
    # FILE` sets caller() for code inside FILE, so the CLI dispatch is never
    # entered).
    do $A;
    die "AC-22: could not load almanac-bug.pl in-process: $@" if $@;

    my $rep = AlmanacBug::load($path);
    ok(defined $rep, 'AC-22: AlmanacBug::load succeeds on the fixture report');

    # Mutate the file DIRECTLY on disk, with no lock taken at all -- exactly
    # a writer that bypassed the lock.
    open(my $bp, '>>', $path) or die "AC-22: cannot append to $path: $!";
    print {$bp} "BYPASS-WRITER-APPENDED\n";
    close $bp;
    my $bypassed_bytes = slurp_or($path);

    my ($cas_ok, $cas_why) = AlmanacBug::cas_write($rep, "should never land");
    ok(!$cas_ok, 'AC-22: cas_write refuses when the file changed on disk since load()');
    like($cas_why, qr/changed on disk/i, 'AC-22: ...and the refusal says why');
    my $after_bytes = slurp_or($path);
    is($after_bytes, $bypassed_bytes, "AC-22: cas_write wrote NOTHING -- the bypassing writer's bytes are untouched");

    # End-to-end: the same bypass-then-update sequence through the real CLI,
    # with no hook and no seam. A SEQUENTIAL bypass-then-update would NOT
    # reproduce this -- `update` would simply load the already-bypassed
    # bytes as its own baseline and see no change at all. The race has to
    # land INSIDE update's own load-modify-write window, which `--body -`
    # gives us for free (`_slurp_arg` blocks on STDIN, and load() already
    # happened before that block): spawn update reading its body from a
    # pipe we hold open, wait long enough that it can only be blocked on
    # that read (a process spawn plus one small file read, against a
    # multi-hundred-millisecond buffer), perform the bypass write, THEN
    # supply the body and close the pipe to unblock it. No hook, no seam --
    # a genuine second writer's bytes land between this process's load()
    # and its write.
    my $WORKDIR22 = tempdir(CLEANUP => 1);
    $WORKDIR22 =~ s{\\}{/}g;
    my $cmd2 = qq{ALMANAC_HOME="$HOME22" perl "$A" file --project "$proj22" --title "AC22b target" --body "orig2"};
    chomp(my $path2 = `$cmd2 2>&1`);
    my ($id2) = $path2 =~ m{/([^/]+)\.md$};

    my $out2file = "$WORKDIR22/e2e-out.txt";
    my $cmd4 = qq{ALMANAC_HOME="$HOME22" perl "$A" update $id2 --project "$proj22" --replace --body - > "$out2file" 2>&1};
    my $rc4;
    {
        local $SIG{PIPE} = 'IGNORE';
        if (open(my $ch, '|-', $cmd4)) {
            # Wait until the child is INSIDE its window: it writes the lock's
            # holder sidecar naming verb "update" on acquire, which comes after
            # the automatic reconcile (where-things-go 07) and before load().
            # A fixed 0.8s sleep raced that reconcile under a parallel sweep: the
            # bypass then landed BEFORE load(), so there was nothing to detect
            # and update rightly exited 0. Bounded at 20s; the short trailing
            # sleep covers acquire -> load() -> the blocking STDIN read.
            my $holder = "$path2.lock.holder";
            my $deadline = Time::HiRes::time() + 20;
            until (Time::HiRes::time() > $deadline) {
                last if (slurp_or($holder) // '') =~ /"verb"\s*:\s*"update"/;
                Time::HiRes::sleep(0.05);
            }
            Time::HiRes::sleep(0.3);
            open(my $bp2, '>>', $path2) or die "AC-22: cannot append to $path2: $!";
            print {$bp2} "BYPASS-WRITER-2\n";
            close $bp2;
            print {$ch} "new body via pipe\n";
            close $ch; # waits for the child; unblocked the instant we wrote above
            $rc4 = $? >> 8;
        } else {
            fail("AC-22: could not spawn the end-to-end update child: $!");
        }
    }
    my $out4 = slurp_or($out2file);
    is($rc4, 2, 'AC-22: end-to-end -- update after a bypass landing inside its load-modify-write window exits 2')
        or diag("stdout+stderr: $out4");
    like($out4, qr/changed on disk/i, 'AC-22: end-to-end -- ...and STDOUT/STDERR names it');
}

# =============================================================================
# Live-store sanity, again, at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "live store's report count is unchanged by this suite ($live_before before, $live_after after)");
}

done_testing();
