#!/usr/bin/env perl
# bp-watch.pl — the general, condition-driven watcher for both interactive
# surfaces (/butler:reporter, /butler:drive-solo), armed ALONGSIDE each
# surface's existing mechanism, never replacing it.
#
# WHY THIS EXISTS
#
# Neither interactive surface can tell a healthy run from a dead one.
# Reporter blocks only on bp-wait-for-decision.pl, which wakes on a QUEUED
# decision -- the orchestrator dying, the container being reaped, a clean
# idle-exit with everything done, or a single package flipping to done never
# queue one, so none of them was ever noticed ({"status":"timeout"} returned
# twice against a dead orchestrator and zero coordinators, and would have
# forever). Drive-solo's bp-watchdog.pl is a single 30-minute timer whose
# progress scan walks the WHOLE blueprints tree with no subject-scoping
# argument at all, so a driver's own ledger edit reads as the worker's
# progress -- it reported VERDICT: PROGRESS three times during a real
# four-hour stall. bp-watch.pl closes both gaps: it exits on a named
# CONDITION (seconds, not up to thirty minutes), it is subject-scoped, and
# one arm covers a whole dispatch (--max-seconds sized to it, required, no
# default) instead of a universal timer requiring dozens of forgettable
# re-arms across one long run (2026-08-06 #11).
#
# THE FOUR INVARIANTS. Each was earned by a real shipped bug, and each is
# enforced here structurally, not by comment:
#
#   1. is_terminal_status() allowlists the TERMINAL set only
#      (done|dropped|blocked|parked). A first version allowlisted the LIVE
#      set instead, so free-text `converging` a coordinator actually wrote
#      into its frontmatter read as settled.
#   2. read_packages_dir() reads packages/*.md, NEVER runs/registry.json --
#      the registry only knows LAUNCHED packages. With 2 of 5 launched,
#      "all registry entries terminal" was reachable with three never run.
#   3. Liveness is PID-scoped via BpRunState::pid_alive (bp-runstate.pl,
#      kill(0)-then-tasklist), reused rather than reinvented. The shipped bug
#      was `ps -eo args | grep -c '[c]laude'`, which matched every bash
#      tool-call process through the shell-snapshot path -- the headline
#      death-detection feature could NEVER have fired.
#   4. artifact_snapshot()/artifact_changed() are scoped to the caller's
#      explicit @paths only, never a tree-wide mtime walk -- bp-watchdog.pl's
#      LIVE defect (snapshot(), bp-watchdog.pl:102-136), which let a driver's
#      own ledger writes manufacture false PROGRESS verdicts during a real
#      stall. bp-watchdog.pl is SUPERSEDED by this file for that role (see
#      its own header), not fixed in place.
#
# THE UMBRELLA RULE, stated once and inherited by all four: a watcher's
# errors must never resolve toward "finished"; uncertainty resolves to LIVE.
# resolve_condition() is where this is enforced in code: every axis that
# cannot positively confirm its condition (undef status, undef pids_alive
# because no PID axis is configured, artifact_changed false) is treated as
# absent evidence, never as a synonym for "confirmed" -- in particular,
# pids_alive => undef must never misread as pids_alive => 0 via bare Perl
# truthiness, which is exactly the trap the `defined` checks below exist to
# avoid.
#
# SHAPE. Mirrors bp-wait-for-decision.pl / bp-runstate.pl: a `package
# BpWatch;` block of pure, injectable-seam functions, `require`-able with
# zero real sleeping/filesystem writes to exercise the decision logic, and a
# `package main;` CLI behind `unless (caller)`.
#
# EXIT CODES ARE THE SIGNAL (unlike bp-watchdog.pl's always-0 convention) --
# a gate-drive-loop.sh-style consumer needs a cheap $?:
#   0  TERMINAL/SETTLED   subject (or whole blueprint, Mode B) reached the
#                         invariant-1 allowlist. Does not imply "never re-arm".
#   1  BOUND              --max-seconds elapsed, nothing resolved. Liveness
#                         is UNKNOWN -- never treat as dead or done.
#   2  WORKERS-GONE       every configured pid confirmed dead, no terminal
#                         status observed. Likely crash; investigate.
#   3  ARTIFACT           a watched path's mtime advanced, or it appeared.
#   4  STATUS-CHANGE      ledger status changed to a NON-terminal value (a
#                         terminal value takes exit 0 instead).
#   64 USAGE ERROR
#   65 UNVERIFIABLE       data dir / blueprint / package not found, or a
#                         check itself failed. MUST be read as LIVE, never 0.
#
# --max-seconds is REQUIRED, no default -- bp-watchdog.pl's universal 1800s
# default is exactly the habit that produced dozens of forgettable 30-minute
# re-arms across one long dispatch. Sizing the bound to the actual dispatch
# is deliberate friction, not an oversight.
#
# --pid-file is RE-READ ON EVERY POLL TICK, never cached at arm time, so a
# marker that disappears (clean exit) or is replaced (a new orchestrator, a
# different pid) is picked up live.
#
# --keepawake (drive-solo only, opt-in) refreshes the EXISTING
# bp-keepawake.pl lease (the same .drive-solo/keepawake.pid bp-drive-next.pl
# already manages) once per poll tick -- it does not create a second lock.
# Closes the gap where that lease (900s) is refreshed only when the director
# runs, and the director is skipped whenever a wakeup is already pending, so
# a long watch window can outlive its own lease.

package BpWatch;
use strict;
use warnings;

# The single allowlist. Everything else -- pending, running, reviewing,
# unknown free text a coordinator wrote -- is LIVE. INVARIANT 1. A POSITIVE
# allowlist, not a denylist of today's known-bad words (see t/133 B5).
my %TERMINAL = map { $_ => 1 } qw(done dropped blocked parked);

sub is_terminal_status {
    my ($status) = @_;
    return 0 unless defined $status && length $status;
    return $TERMINAL{$status} ? 1 : 0;
}

# ledger_status($path) -- the exact frontmatter-only regex shape as
# bp-watchdog.pl:138-151's ledger_status(), reused in SHAPE (not by
# requiring that file, which is superseded doctrine, not a library this
# file should depend on).
sub _ledger_status {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    my $n = 0;
    my $status;
    while (my $line = <$fh>) {
        last if ++$n > 40;                # frontmatter only
        $line =~ s/\r?\n\z//;
        last if $n > 1 && $line =~ /^---\s*$/;
        if ($line =~ /^status:\s*(\S+)/) { $status = $1; last }
    }
    close $fh;
    return $status;
}

# read_packages_dir($blueprint_dir) -> \@[{id, status}]  IMPURE.
# INVARIANT 2: the denominator. Globs packages/*.md ONLY -- NEVER
# runs/registry.json, which knows only LAUNCHED packages. A ledger that
# fails to parse still produces an entry, with status => undef (unparseable
# reads as LIVE, never silently dropped from the denominator).
sub read_packages_dir {
    my ($bpdir) = @_;
    my $dir = defined $bpdir ? "$bpdir/packages" : undef;
    return [] unless defined $dir && -d $dir;
    opendir my $dh, $dir or return [];
    my @files = grep { /\.md$/ } readdir $dh;
    closedir $dh;
    my @out;
    for my $f (sort @files) {
        (my $id = $f) =~ s/\.md$//;
        push @out, { id => $id, status => _ledger_status("$dir/$f") };
    }
    return \@out;
}

# blueprint_settled(\@packages) -> bool. PURE. Empty list -> true
# (vacuous), same convention as bp-wait-for-decision::blueprint_terminal,
# but with the WIDER 4-value invariant-1 allowlist (a different question --
# see spec §3.7).
sub blueprint_settled {
    my ($packages) = @_;
    for my $p (@{ $packages || [] }) {
        return 0 unless is_terminal_status($p->{status});
    }
    return 1;
}

# all_pids_alive(\@pids, $pid_alive_fn) -> 1 | 0 | undef.  PURE (given the
# injected callback). INVARIANT 3: reused liveness, never reimplemented --
# the caller MUST pass BpRunState::pid_alive (bp-runstate.pl:59-69) in
# production; this function defines no liveness primitive of its own.
# undef ("not applicable") iff the pid list is empty -- an empty list must
# never be read as "confirmed alive". 0 the MOMENT any one pid is dead.
sub all_pids_alive {
    my ($pids, $pid_alive_fn) = @_;
    return undef unless $pids && @$pids;
    for my $p (@$pids) {
        return 0 unless $pid_alive_fn->($p);
    }
    return 1;
}

# artifact_snapshot(\@paths) -> { path => mtime_or_undef, ... }  IMPURE.
# INVARIANT 4: scoped to exactly the paths handed in, never a tree-wide
# scan. A missing path -> undef, NEVER 0 (0 would collide with a real
# epoch-0 mtime and read as "always changed").
sub artifact_snapshot {
    my ($paths) = @_;
    my %snap;
    for my $p (@{ $paths || [] }) {
        my @st = stat($p);
        $snap{$p} = @st ? $st[9] : undef;
    }
    return \%snap;
}

# artifact_changed(\%before, \%after) -> bool.  PURE. True iff ANY path's
# mtime differs, including undef -> defined ("appeared").
sub artifact_changed {
    my ($before, $after) = @_;
    $before ||= {};
    $after  ||= {};
    for my $k (keys %$after) {
        my $b = $before->{$k};
        my $a = $after->{$k};
        next if !defined $b && !defined $a;
        return 1 if !defined $b || !defined $a;
        return 1 if $b != $a;
    }
    return 0;
}

# resolve_condition(\%signal) -> 'terminal' | 'workers-gone' | 'artifact'
#   | 'status-change' | 'bound' | undef
#
# THE UMBRELLA RULE (§0), enforced in code. \%signal:
#   status, prior_status, pids_alive (1|0|undef), artifact_changed (bool),
#   bound_hit (bool)
#
# Priority, evaluated in this exact order, first match wins:
#   1. status defined && is_terminal_status(status)     -> 'terminal'
#   2. pids_alive is DEFINED && == 0                     -> 'workers-gone'
#   3. artifact_changed                                  -> 'artifact'
#   4. status defined && prior_status defined && differ   -> 'status-change'
#   5. bound_hit                                          -> 'bound'
#   else                                                  -> undef (keep polling)
#
# pids_alive == undef must NEVER reach rule 2 -- bare Perl truthiness would
# treat undef as false and misfire there; the `defined` check is load-bearing.
sub resolve_condition {
    my ($sig) = @_;
    $sig ||= {};
    my $status       = $sig->{status};
    my $prior        = $sig->{prior_status};
    my $pids_alive   = $sig->{pids_alive};
    my $art_changed  = $sig->{artifact_changed};
    my $bound_hit    = $sig->{bound_hit};

    return 'terminal' if defined $status && is_terminal_status($status);
    return 'workers-gone' if defined $pids_alive && $pids_alive == 0;
    return 'artifact' if $art_changed;
    return 'status-change'
        if defined $status && defined $prior && $status ne $prior;
    return 'bound' if $bound_hit;
    return undef;
}

# format_change_line(\%prev, \%cur) -> $line | undef.  PURE. Compares
# status/pids_alive/artifact_changed_flag field by field; undef iff nothing
# differs -- criterion 4, "one line per state CHANGE, not per poll".
sub format_change_line {
    my ($prev, $cur) = @_;
    $prev ||= {};
    $cur  ||= {};
    my @diffs;
    for my $k (qw(status pids_alive artifact_changed_flag)) {
        my $p = $prev->{$k};
        my $c = $cur->{$k};
        my $pd = defined $p ? $p : '(undef)';
        my $cd = defined $c ? $c : '(undef)';
        push @diffs, "$k: $pd -> $cd" if $pd ne $cd;
    }
    return @diffs ? join('; ', @diffs) : undef;
}

package main;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });

sub usage {
    print STDERR <<'USAGE';
usage: bp-watch.pl --arm --max-seconds N (--package BP/PKGID | --blueprint BP)
                    [--pid-file PATH | --expect-pids P1,P2,...]
                    [--artifact PATH[:PATH...]] [--poll SECS] [--data DIR]
                    [--keepawake]

--max-seconds is REQUIRED, no default.

Exit codes:
  0 TERMINAL/SETTLED  1 BOUND  2 WORKERS-GONE  3 ARTIFACT  4 STATUS-CHANGE
  64 USAGE ERROR      65 UNVERIFIABLE (data/blueprint/package not found)
USAGE
}

# _split_artifact_paths($csv) -> @paths
# Splits on ':', but a single-letter segment immediately followed by
# another segment is a Windows drive letter ("C" + "/Users/...") and is
# glued back together -- ':' is both the spec's separator AND the character
# every Windows absolute path contains right after its drive letter, so a
# naive split would shred "C:/Users/x/p1.md" into "C" and "/Users/x/p1.md".
sub _split_artifact_paths {
    my ($csv) = @_;
    return () unless defined $csv && length $csv;
    my @segs = split /:/, $csv, -1;
    my @out;
    my $i = 0;
    while ($i < @segs) {
        my $seg = $segs[$i];
        if ($seg =~ /^[A-Za-z]$/ && $i + 1 < @segs) {
            $seg = "$seg:" . $segs[$i + 1];
            $i++;
        }
        push @out, $seg;
        $i++;
    }
    return @out;
}

sub _read_pidfile {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open my $fh, '<', $path or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    return ($line =~ /(\d+)/) ? $1 : undef;
}

unless (caller) {
    my %opt = (poll => 5);
    my @unknown;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a eq '--arm')         { $opt{arm} = 1 }
        elsif ($a eq '--package')     { $opt{package}     = shift @ARGV }
        elsif ($a eq '--blueprint')   { $opt{blueprint}    = shift @ARGV }
        elsif ($a eq '--max-seconds') { $opt{max_seconds}  = shift @ARGV }
        elsif ($a eq '--pid-file')    { $opt{pid_file}     = shift @ARGV }
        elsif ($a eq '--expect-pids') { $opt{expect_pids}  = shift @ARGV }
        elsif ($a eq '--artifact')    { $opt{artifact}     = shift @ARGV }
        elsif ($a eq '--poll')        { $opt{poll}         = shift @ARGV }
        elsif ($a eq '--data')        { $opt{data}         = shift @ARGV }
        elsif ($a eq '--keepawake')   { $opt{keepawake}    = 1 }
        else                          { push @unknown, $a }
    }
    if (@unknown) {
        print STDERR "bp-watch: unknown option(s): @unknown\n";
        usage();
        exit 64;
    }

    unless (defined $opt{max_seconds} && $opt{max_seconds} =~ /^\d+(?:\.\d+)?$/
            && $opt{max_seconds} > 0) {
        print STDERR "bp-watch: --max-seconds is REQUIRED and must be a positive number "
                    . "(no default -- sizing the bound to the dispatch is deliberate)\n";
        usage();
        exit 64;
    }
    my $max_seconds = $opt{max_seconds} + 0;

    my $mode;
    my ($bpname, $pkgid);
    if (defined $opt{package} && defined $opt{blueprint}) {
        print STDERR "bp-watch: pass exactly one of --package or --blueprint, not both\n";
        exit 64;
    }
    elsif (defined $opt{package}) {
        $mode = 'package';
        ($bpname, $pkgid) = split m{/}, $opt{package}, 2;
        unless (defined $bpname && length $bpname && defined $pkgid && length $pkgid) {
            print STDERR "bp-watch: --package expects BLUEPRINT/PACKAGE-ID\n";
            exit 64;
        }
    }
    elsif (defined $opt{blueprint}) {
        $mode = 'blueprint';
        $bpname = $opt{blueprint};
    }
    else {
        print STDERR "bp-watch: one of --package BP/PKGID or --blueprint BP is required\n";
        exit 64;
    }

    my $poll = (defined $opt{poll} && $opt{poll} =~ /^\d+(?:\.\d+)?$/ && $opt{poll} > 0)
             ? $opt{poll} + 0 : 5;

    my @expect_pids;
    if (defined $opt{expect_pids}) {
        @expect_pids = grep { /^\d+$/ } split /,/, $opt{expect_pids};
    }

    my @art_paths = defined $opt{artifact} ? _split_artifact_paths($opt{artifact}) : ();

    # --- data dir resolution: matches bp-watchdog.pl:83-90 /
    #     bp-wait-for-decision.pl:396-404 verbatim, for consistency. ---
    my $DATA = $opt{data} || $ENV{CCPRAXIS_DATA_DIR} || '';
    if (!$DATA) {
        my $d = '.';
        for (1 .. 12) {
            if (-d "$d/.ccpraxis-local-data") { $DATA = "$d/.ccpraxis-local-data"; last }
            $d = "$d/..";
        }
    }
    unless ($DATA && -d $DATA) {
        print "UNVERIFIABLE: no .ccpraxis-local-data found -- liveness unknown, never treat as done\n";
        exit 65;
    }

    my $bpdir = "$DATA/blueprints/$bpname";
    unless (-d $bpdir) {
        print "UNVERIFIABLE: blueprint '$bpname' not found under $DATA/blueprints -- "
            . "liveness unknown, never treat as done\n";
        exit 65;
    }

    if ($mode eq 'package') {
        my $pkgs = BpWatch::read_packages_dir($bpdir);
        my ($entry) = grep { $_->{id} eq $pkgid } @$pkgs;
        unless ($entry) {
            print "UNVERIFIABLE: package '$pkgid' not found in $bpname/packages -- "
                . "liveness unknown, never treat as done\n";
            exit 65;
        }
    }

    # INVARIANT 3: reused, not reimplemented. BpRunState::pid_alive is the
    # ONLY liveness primitive this file calls.
    require "$DIR/bp-runstate.pl";

    my $art_before = @art_paths ? BpWatch::artifact_snapshot(\@art_paths) : {};

    my $t0 = time;
    my $prior_status;

    while (1) {
        my $elapsed   = time - $t0;
        my $bound_hit = ($elapsed >= $max_seconds) ? 1 : 0;

        my $status;
        if ($mode eq 'package') {
            my $pkgs = BpWatch::read_packages_dir($bpdir);
            my ($entry) = grep { $_->{id} eq $pkgid } @$pkgs;
            $status = $entry ? $entry->{status} : undef;
        }
        else {
            my $pkgs = BpWatch::read_packages_dir($bpdir);
            $status = BpWatch::blueprint_settled($pkgs) ? 'done' : undef;
        }

        # --pid-file is RE-READ every tick (never cached at arm time).
        my @cur_pids;
        if (defined $opt{pid_file}) {
            my $p = _read_pidfile($opt{pid_file});
            @cur_pids = defined $p ? ($p) : ();
        }
        elsif (@expect_pids) {
            @cur_pids = @expect_pids;
        }
        my $pids_alive = BpWatch::all_pids_alive(\@cur_pids, \&BpRunState::pid_alive);

        my $art_changed = 0;
        if (@art_paths) {
            my $art_after = BpWatch::artifact_snapshot(\@art_paths);
            $art_changed = BpWatch::artifact_changed($art_before, $art_after) ? 1 : 0;
        }

        my $cond = BpWatch::resolve_condition({
            status           => $status,
            prior_status     => $prior_status,
            pids_alive       => $pids_alive,
            artifact_changed => $art_changed,
            bound_hit        => $bound_hit,
        });

        if (defined $cond) {
            if ($cond eq 'terminal') {
                if ($mode eq 'package') {
                    print "TERMINAL: package $bpname/$pkgid reached status '"
                        . (defined $status ? $status : '') . "'\n";
                }
                else {
                    print "TERMINAL (SETTLED): blueprint $bpname -- every package/*.md "
                        . "entry reached a terminal status\n";
                }
                exit 0;
            }
            elsif ($cond eq 'workers-gone') {
                print "WORKERS-GONE: a watched pid is confirmed dead and no terminal status "
                    . "was observed. Likely crash -- investigate before re-arming.\n";
                exit 2;
            }
            elsif ($cond eq 'artifact') {
                print "ARTIFACT: a watched path changed (@art_paths)\n";
                exit 3;
            }
            elsif ($cond eq 'status-change') {
                print "STATUS-CHANGE: $bpname/$pkgid status changed from '"
                    . (defined $prior_status ? $prior_status : '(none)') . "' to '"
                    . (defined $status ? $status : '') . "' (non-terminal)\n";
                exit 4;
            }
            elsif ($cond eq 'bound') {
                print "BOUND: --max-seconds elapsed with nothing resolved. Subject liveness "
                    . "is UNKNOWN -- never treat as dead or done.\n";
                exit 1;
            }
        }

        if ($opt{keepawake}) {
            eval {
                require "$DIR/bp-keepawake.pl";
                BpKeepAwake::apply('active', "$DATA/.drive-solo", {});
            };
        }

        $prior_status = $status if $mode eq 'package';

        select(undef, undef, undef, $poll);
    }
}

1;
