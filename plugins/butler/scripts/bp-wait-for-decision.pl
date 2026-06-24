#!/usr/bin/env perl
# bp-wait-for-decision.pl — the reporter's TOKEN-FREE blocking watcher (A7).
#
# The /butler:reporter skill (interactive Claude) arms this as a detached
# background process. It blocks — burning ZERO Claude tokens, just a cheap
# filesystem poll — until a *fresh* human-intent decision appears in the
# orchestrator's queue (`runs/needs-you/<pkg>--<shortid>.json`, the schema A3
# owns), then prints that decision and exits. The reporter reads the printed
# decision, auto-announces it to the user, and re-arms the watcher with the new
# decision added to its "seen" set — so a decision is announced exactly once and
# there is no token-burning poll loop (Decision #27). Closing the reporter
# window kills this watcher and never touches the run; re-running the reporter
# re-arms it.
#
# "Fresh" is decided against a caller-supplied seen-set (the decision IDs the
# reporter has already announced) rather than "is the queue non-empty", because
# a decision stays in the queue from when it is queued until the human ANSWERS
# it (the reporter deletes the file then). Identity is the file's basename
# (`<pkg>--<shortid>`, shortid derived from created_at+pid) — unique and stable;
# a re-park of the same package+kind after an answer gets a new shortid, so it
# is correctly seen as fresh again.
#
# DESIGN (mirrors bp-orchestrator.pl / bp-judge.pl): the decision is a PURE
# function (fresh_decisions) and the blocking loop takes injectable now/sleep/
# scan seams, so t/12 can exhaust the matrix — immediate-return, block-then-
# return, timeout, seen-filtering, announce-ordering — with a fake clock and a
# scripted directory, no real sleeping and no real `claude`.
#
# require:  require "<path>/bp-wait-for-decision.pl"; BpWait::fresh_decisions(...)
# CLI:      bp-wait-for-decision.pl (--runs DIR | <blueprint> [--bp-dir DIR])
#                                   [--seen id1,id2,...] [--timeout SECS]
#                                   [--poll SECS]
#           exit 0 = a fresh decision was printed; 3 = timed out (nothing fresh);
#           2 = usage error.

package BpWait;
use strict;
use warnings;

# decision_id($path_or_name) -> '<pkg>--<shortid>'
# The stable identity of a queue entry: its filename with any directory prefix
# and the trailing '.json' removed. Pure.
sub decision_id {
    my ($p) = @_;
    return '' unless defined $p;
    (my $base = $p) =~ s{.*[\\/]}{};   # strip dir (both separators, for Windows)
    $base =~ s/\.json$//i;
    return $base;
}

# parse_seen($csv) -> { id => 1, ... }
# The reporter passes the decisions it has already announced as a comma-separated
# list of IDs. Tolerates undef/empty/whitespace. Pure.
sub parse_seen {
    my ($csv) = @_;
    my %seen;
    return \%seen unless defined $csv && length $csv;
    for my $id (split /,/, $csv) {
        $id =~ s/^\s+//; $id =~ s/\s+$//;
        $seen{$id} = 1 if length $id;
    }
    return \%seen;
}

# fresh_decisions(\@decisions, \%seen) -> \@fresh   (THE decision function)
# Of the decisions currently in the queue, the ones the reporter has not yet
# announced (id not in seen). Returned in a stable announce order: oldest
# created_at first, ties broken by id, so the reporter announces in the order
# the orchestrator queued them and the order is deterministic for tests. Pure.
sub fresh_decisions {
    my ($decisions, $seen) = @_;
    $seen ||= {};
    my @fresh = grep { !$seen->{ $_->{id} // '' } } @{ $decisions || [] };
    return [ sort {
        ($a->{created_at} // 0) <=> ($b->{created_at} // 0)
            or ($a->{id} // '') cmp ($b->{id} // '')
    } @fresh ];
}

# scan($dir) -> \@decisions   (the real, I/O-touching scanner — the loop's seam)
# Read every `<pkg>--<shortid>.json` in the needs-you dir into a decision record.
# Skips dotfiles (e.g. a future reporter cursor), non-.json files, and anything
# that doesn't parse to a JSON object — a half-written file (the orchestrator
# writes then the reader races) is simply ignored this tick and picked up next
# tick once complete; it is never mistaken for a decision. A missing dir (the
# orchestrator creates needs-you/ lazily on the first park) yields [] so the
# watcher just keeps waiting.
sub scan {
    my ($dir) = @_;
    return [] unless defined $dir && -d $dir;
    opendir my $dh, $dir or return [];
    my @files = grep { /\.json$/ && !/^\./ } readdir $dh;
    closedir $dh;
    require JSON::PP;
    my @out;
    for my $f (sort @files) {
        my $id = decision_id($f);
        next unless length $id;                  # a bare/degenerate name has no identity
        my $path = "$dir/$f";
        open my $fh, '<:raw', $path or next;
        local $/; my $raw = <$fh>; close $fh;
        next unless defined $raw && length $raw;
        my $rec = eval { JSON::PP->new->decode($raw) };
        next unless ref $rec eq 'HASH';
        push @out, {
            id        => $id,
            path      => $path,
            package   => $rec->{package},
            blueprint => $rec->{blueprint},
            kind      => $rec->{kind},
            question  => $rec->{question},
            context   => $rec->{context},
            created_at=> $rec->{created_at},
        };
    }
    return \@out;
}

# wait_loop(\%a) -> { status => 'decision', decisions => \@fresh }
#                 | { status => 'timeout',  waited => SECS }
# The blocking watch. Checks IMMEDIATELY on entry (so a decision that arrived in
# the gap between the reporter's last announce and this re-arm is never missed),
# then polls at `poll`-second cadence until a fresh decision appears or the
# optional `timeout` elapses. timeout 0/undef = block forever (the default — the
# watcher returns ONLY when there is something to announce). Seams (all default
# to real impls): now, sleep, scan.
sub wait_loop {
    my ($a) = @_;
    my $dir     = $a->{dir};
    my $seen    = $a->{seen} || {};
    my $poll    = (defined $a->{poll} && $a->{poll} > 0) ? $a->{poll} : 5;
    my $timeout = $a->{timeout} || 0;          # 0 = infinite
    my $now     = $a->{now}   || sub { time };
    my $sleep   = $a->{sleep} || sub { select(undef, undef, undef, $_[0]) };
    my $scan    = $a->{scan}  || sub { scan($dir) };

    my $start = $now->();
    while (1) {
        my $fresh = fresh_decisions($scan->(), $seen);
        return { status => 'decision', decisions => $fresh } if @$fresh;
        if ($timeout > 0) {
            my $waited = $now->() - $start;
            return { status => 'timeout', waited => $waited } if $waited >= $timeout;
            # Never oversleep past the deadline: when poll exceeds the time
            # remaining, sleep only the remainder so a bounded watcher returns
            # its heartbeat promptly (a decision arriving right at the deadline
            # is still caught by the next iteration's scan).
            my $remaining = $timeout - $waited;
            $sleep->($poll < $remaining ? $poll : $remaining);
        } else {
            $sleep->($poll);
        }
    }
}

package main;
use strict;
use warnings;

unless (caller) {
    require JSON::PP;
    my ($runs, $bp, $bpdir, $seen_csv, $timeout, $poll);
    my @pos;
    # Consume an option's value, rejecting a missing value or one that is itself
    # a flag (so `--seen --timeout 60` errors loudly instead of silently eating
    # `--timeout` as the seen-list and mis-parsing the rest).
    my $need = sub {
        my ($flag) = @_;
        my $v = shift @ARGV;
        unless (defined $v && $v !~ /^--/) {
            print STDERR "bp-wait-for-decision: $flag requires a value\n"; exit 2;
        }
        return $v;
    };
    while (@ARGV) {
        my $arg = shift @ARGV;
        if    ($arg eq '--runs')    { $runs    = $need->('--runs'); }
        elsif ($arg eq '--bp-dir')  { $bpdir   = $need->('--bp-dir'); }
        elsif ($arg eq '--seen')    { $seen_csv= $need->('--seen'); }
        elsif ($arg eq '--timeout') { $timeout = $need->('--timeout'); }
        elsif ($arg eq '--poll')    { $poll    = $need->('--poll'); }
        elsif ($arg =~ /^--/)       { print STDERR "bp-wait-for-decision: unknown option $arg\n"; exit 2; }
        else  { push @pos, $arg; }
    }
    $bp = shift @pos if @pos;

    # Numeric guards: a negative/garbled timeout must fail loudly, not silently
    # become an infinite block (timeout 0 is the documented way to block forever).
    for my $pair (['--timeout', $timeout], ['--poll', $poll]) {
        my ($flag, $val) = @$pair;
        next unless defined $val;
        unless ($val =~ /^\d+(?:\.\d+)?$/) {
            print STDERR "bp-wait-for-decision: $flag must be a non-negative number\n"; exit 2;
        }
    }

    # Resolve the needs-you directory. Either point straight at runs/ (--runs),
    # or give a blueprint (+ --bp-dir or CCPRAXIS_DATA_DIR) the way the
    # orchestrator does, in which case runs = <bpdir>/runs.
    unless (defined $runs) {
        unless (defined $bp && length $bp) {
            print STDERR "usage: bp-wait-for-decision.pl (--runs DIR | <blueprint> [--bp-dir DIR]) [--seen ids] [--timeout SECS] [--poll SECS]\n";
            exit 2;
        }
        unless (defined $bpdir) {
            my $data = $ENV{CCPRAXIS_DATA_DIR};
            unless (defined $data) {
                print STDERR "bp-wait-for-decision: set --runs, or --bp-dir, or CCPRAXIS_DATA_DIR\n";
                exit 2;
            }
            $bpdir = "$data/blueprints/$bp";
        }
        $runs = "$bpdir/runs";
    }

    my $res = BpWait::wait_loop({
        dir     => "$runs/needs-you",
        seen    => BpWait::parse_seen($seen_csv),
        timeout => (defined $timeout ? $timeout + 0 : 0),
        poll    => (defined $poll ? $poll + 0 : undef),
    });

    print JSON::PP->new->canonical->pretty->encode($res);
    exit($res->{status} eq 'decision' ? 0 : 3);
}
1;
