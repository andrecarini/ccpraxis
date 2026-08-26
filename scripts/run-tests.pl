#!/usr/bin/env perl
# run-tests.pl -- the repo-wide test runner. Parallel where that is safe,
# serial where it is not.
#
# WHY THIS EXISTS. A full sweep was ~70 minutes of CPU across 243 files, run
# one at a time, and a suite nobody wants to run is a suite that stops getting
# run. Measured on this host: 4190s of CPU, 915s wall at six-way parallelism.
# The work is dominated by PROCESS CREATION -- a bare statusline spawn costs
# ~292ms here -- not by CPU, so parallelism buys more than the core count
# suggests.
#
# `prove` is not an option: the Git-for-Windows perl ships no TAP::Harness
# (see the repo CLAUDE.md). This runs each .t as its own process and judges it
# by exit code plus `not ok` count, which is the same rule the project already
# applies by hand.
#
# CONTAINER TESTS RUN SERIALLY, and that is not a limitation to remove later.
# They start real podman containers against ONE podman machine, so running them
# concurrently makes them contend for the same resource -- slower in wall-clock
# AND flakier, which is the documented failure signature of this suite
# (EXIT=124/255 with no failing assertion). They are detected by what they
# import rather than by a tag, so a new one is classified correctly without
# anybody remembering to mark it.
#
# Usage:
#   perl scripts/run-tests.pl                    # everything
#   perl scripts/run-tests.pl --fast             # skip the container tests
#   perl scripts/run-tests.pl --jobs 8           # override parallelism
#   perl scripts/run-tests.pl plugins/sandbox    # limit to a plugin or a glob
use strict;
use warnings;
use FindBin qw($Bin);
use File::Basename qw(basename);
use POSIX qw(:sys_wait_h);

my $ROOT = "$Bin/..";

my ($fast, $jobs, @targets) = (0, 0);
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--fast')            { $fast = 1 }
    elsif ($a eq '--jobs')            { $jobs = shift(@ARGV) || 0 }
    elsif ($a =~ /^--jobs=(\d+)$/)    { $jobs = $1 }
    elsif ($a eq '--help' || $a eq '-h') { print _usage(); exit 0 }
    else                              { push @targets, $a }
}
sub _usage { return <<'USAGE' }
usage: perl scripts/run-tests.pl [--fast] [--jobs N] [PATH-OR-GLOB ...]
  --fast    skip tests that start real containers
  --jobs N  parallelism for non-container tests (default: cores - 2)
USAGE

# --- collect ---------------------------------------------------------------
my @files;
if (@targets) {
    for my $t (@targets) {
        my @m = glob($t);
        @m = glob("$t/tests/t/*.t")  if !@m || -d $t;
        @m = glob("$ROOT/$t")        unless @m;
        @m = glob("$ROOT/$t/tests/t/*.t") unless @m;
        push @files, grep { /\.t$/ && -f $_ } @m;
    }
} else {
    push @files, glob("$ROOT/plugins/*/tests/t/*.t");
}
@files = sort @files;
unless (@files) { print STDERR "no test files matched\n"; exit 2 }

# CLASSIFY BY WHAT THE FILE IMPORTS, not by a tag someone has to remember.
my (@serial, @parallel);
for my $f (@files) {
    open my $fh, '<', $f or next;
    my $src = do { local $/; <$fh> };
    close $fh;
    if ($src =~ /TestSandbox|podman_run_capture|podman_bin|probe_image/) { push @serial, $f }
    else                                                                { push @parallel, $f }
}
@serial = () if $fast;

if (!$jobs) {
    my $cores = _cores();
    $jobs = $cores > 3 ? $cores - 2 : 1;
}
$jobs = scalar(@parallel) if $jobs > @parallel && @parallel;
$jobs = 1 if $jobs < 1;

sub _cores {
    return $ENV{NUMBER_OF_PROCESSORS} if $ENV{NUMBER_OF_PROCESSORS} && $ENV{NUMBER_OF_PROCESSORS} =~ /^\d+$/;
    if (open my $c, '<', '/proc/cpuinfo') {
        my $n = grep { /^processor\s*:/ } <$c>;
        close $c;
        return $n if $n;
    }
    return 4;
}

# run_one($file) -> \%result. The judgement rule the project already uses by
# hand: non-zero exit is red, and the `not ok` count says whether it was a
# failed assertion or the process dying (EXIT != 0 with NOTOK == 0 is the
# signature of a timeout or a kill, not a broken expectation).
sub run_one {
    my ($f) = @_;
    my $t0  = time;
    my $out = `perl "$f" 2>&1`;
    my $rc  = $? >> 8;
    $out = '' unless defined $out;
    my $notok = () = $out =~ /^not ok/mg;
    return { file => $f, rc => $rc, notok => $notok, secs => time - $t0, out => $out };
}

my $start = time;
my @results;

# --- parallel phase --------------------------------------------------------
# fork/waitpid with a result file per child: the MSYS2 perl on this host has a
# real fork, but no shared memory, so children report through the filesystem.
if (@parallel) {
    require File::Temp;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my (%pid_of, @queue);
    @queue = @parallel;
    my $i = 0;
    my %slot;

    my $spawn = sub {
        my $f = shift @queue or return 0;
        my $id = $i++;
        my $pid = fork();
        if (!defined $pid) { unshift @queue, $f; return 0 }
        if ($pid == 0) {
            my $r = run_one($f);
            open my $o, '>', "$dir/$id" or exit 1;
            print {$o} join("\x1f", $r->{rc}, $r->{notok}, $r->{secs}, $r->{file}), "\x1e", $r->{out};
            close $o;
            exit 0;
        }
        $slot{$pid} = $id;
        return 1;
    };

    $spawn->() for 1 .. $jobs;
    while (%slot) {
        my $pid = waitpid(-1, 0);
        last if $pid <= 0;
        my $id = delete $slot{$pid};
        if (defined $id && open my $in, '<', "$dir/$id") {
            my $raw = do { local $/; <$in> };
            close $in;
            my ($head, $out) = split /\x1e/, (defined $raw ? $raw : ''), 2;
            my ($rc, $notok, $secs, $file) = split /\x1f/, (defined $head ? $head : ''), 4;
            push @results, { file => $file // '?', rc => $rc // 1, notok => $notok // 0,
                             secs => $secs // 0, out => $out // '' };
        }
        $spawn->();
    }
}

# --- serial phase ----------------------------------------------------------
push @results, run_one($_) for @serial;

# --- report ----------------------------------------------------------------
my $wall = time - $start;
my @red  = grep { $_->{rc} != 0 } @results;

printf "\n%d files  %ds wall  (%d parallel at -j%d, %d serial)\n",
    scalar(@results), $wall, scalar(@parallel), $jobs, scalar(@serial);

if (@red) {
    print "\nRED:\n";
    for my $r (sort { $a->{file} cmp $b->{file} } @red) {
        printf "  %-52s exit=%-3d notok=%d%s\n", basename($r->{file}), $r->{rc}, $r->{notok},
            ($r->{notok} == 0 ? '   <- died, no failing assertion' : '');
        for my $line (grep { /^not ok/ } split /\n/, $r->{out}) {
            print "      $line\n";
        }
    }
} else {
    print "all green\n";
}

my @slow = (sort { $b->{secs} <=> $a->{secs} } @results)[0 .. ($#results < 4 ? $#results : 4)];
print "\nslowest:\n";
printf "  %5ds  %s\n", $_->{secs}, basename($_->{file}) for grep { defined } @slow;

exit scalar(@red);
