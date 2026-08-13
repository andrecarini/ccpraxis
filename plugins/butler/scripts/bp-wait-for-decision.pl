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

# fresh_decisions(\@decisions, \%seen, \%category_filter) -> \@fresh   (THE decision function)
# Of the decisions currently in the queue, the ones the reporter has not yet
# announced (id not in seen). Returned in a stable announce order: oldest
# created_at first, ties broken by id, so the reporter announces in the order
# the orchestrator queued them and the order is deterministic for tests. Pure.
#
# e02 §2.6: optional 3rd arg $category_filter (hashref of wanted category
# values). Omitted/empty -> NO filtering, today's behavior, byte-identical --
# every existing caller (the reporter skill) passes no 3rd arg and is
# unaffected. Matching rule: a decision matches only if its `category` is
# DEFINED and present in the filter -- a legacy (no-category) record never
# matches ANY filter, regardless of the values requested (the concrete
# backward-tolerance mechanism, spec §2.8/criterion 6). This deliberately does
# NOT default a missing category to anything, so it can never be swept into a
# category-scoped watch on the strength of a field it never had.
sub fresh_decisions {
    my ($decisions, $seen, $category_filter) = @_;
    $seen ||= {};
    my @fresh = grep { !$seen->{ $_->{id} // '' } } @{ $decisions || [] };
    if ($category_filter && %$category_filter) {
        @fresh = grep { defined $_->{category} && $category_filter->{ $_->{category} } } @fresh;
    }
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
            # e02 §2.6: surfaced as-is -- undef/absent for a legacy record
            # (written before this change), NEVER defaulted to any real value.
            category  => $rec->{category},
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
    # e02 §2.6: optional; omitted/empty -> no filtering (unchanged behavior).
    my $category_filter = $a->{category_filter};

    my $start = $now->();
    while (1) {
        my $fresh = fresh_decisions($scan->(), $seen, $category_filter);
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

# ---------------------------------------------------------------------------
# b24-reporter-autonomy — cadence, idle, progress-table and decide/escalate
# classification. See plugins/butler/skills/reporter/SKILL.md for the doctrine
# these implement; this is the pure, testable call surface (t/76 pins it).
# ---------------------------------------------------------------------------

# The prompt-cache TTL is a property of the model provider, not this machine
# (spec b24 sec.2) -- it cannot be discovered at runtime, so it is a single-
# sourced NAMED input, injected as an argument everywhere it is used rather
# than hardcoded as the literal cap. Callers that don't know a specific TTL
# use this default (today's known TTL, 60 minutes).
use constant DEFAULT_TTL_MINUTES => 60;

# The margin subtracted from the TTL to get the safe cadence cap, so cadence
# never collides with a cache-write boundary.
use constant CADENCE_TTL_MARGIN_MINUTES => 5;

# The reporter's default poll cadence when nothing more specific is requested.
use constant DEFAULT_CADENCE_MINUTES => 50;

# cadence_cap_minutes($ttl_minutes) -> cap, DERIVED as $ttl_minutes - margin.
# Never the literal 55 -- injecting a different TTL must observably change
# the cap (t/76 C6). Pure.
sub cadence_cap_minutes {
    my ($ttl_minutes) = @_;
    $ttl_minutes = DEFAULT_TTL_MINUTES unless defined $ttl_minutes;
    return $ttl_minutes - CADENCE_TTL_MARGIN_MINUTES;
}

# resolve_cadence_minutes(\%opts) -> { minutes => N, clamped => bool }
# opts: requested_min (optional), reason (optional), ttl_min (default 60).
#  - No request -> the default (50 minutes).
#  - A request above the derived cap is CLAMPED to the cap (clamped => 1),
#    never honoured as-is.
#  - A request below the default is honoured ONLY when a `reason` is given
#    (a recorded reason is what stops "shorter" being an unaccountable escape
#    hatch, spec b24 sec.2); with no reason it falls back to the default.
#  - A request within [default, cap] is honoured as requested.
# Pure.
sub resolve_cadence_minutes {
    my ($opts) = @_;
    $opts ||= {};
    my $ttl_min = defined $opts->{ttl_min} ? $opts->{ttl_min} : DEFAULT_TTL_MINUTES;
    my $cap     = cadence_cap_minutes($ttl_min);
    my $default = DEFAULT_CADENCE_MINUTES;
    my $requested = $opts->{requested_min};

    return { minutes => $default, clamped => 0 } unless defined $requested;

    if ($requested > $cap) {
        return { minutes => $cap, clamped => 1 };
    }
    if ($requested < $default) {
        my $has_reason = defined $opts->{reason} && length $opts->{reason};
        return { minutes => $requested, clamped => 0 } if $has_reason;
        return { minutes => $default, clamped => 0 };
    }
    return { minutes => $requested, clamped => 0 };
}

# Statuses treated as terminal (blueprint sec.3 I1) -- matches bp-judge.pl /
# bp-orchestrator.pl's existing terminal vocabulary.
my %TERMINAL_STATUS = map { $_ => 1 } qw(done dropped);

# Statuses treated as "parked awaiting a queued human decision" (sec.3 I2).
my %AWAITING_DECISION_STATUS = map { $_ => 1 } qw(blocked parked);

# blueprint_terminal(\@packages) -> bool (I1): every package done/dropped.
# An empty list counts as terminal (vacuously, nothing left to do). Pure.
sub blueprint_terminal {
    my ($packages) = @_;
    for my $pkg (@{ $packages || [] }) {
        my $status = $pkg->{status} // '';
        return 0 unless $TERMINAL_STATUS{$status};
    }
    return 1;
}

# all_awaiting_decision(\@packages) -> bool (I2): every NON-terminal package
# is waiting on a queued decision (blocked/parked). Terminal packages are
# ignored -- this is asked only once blueprint_terminal is already false, and
# a blueprint made entirely of terminal packages is I1's case, not I2's, so
# an all-terminal list here does NOT count as "awaiting decision" (there is
# nothing non-terminal to be awaiting anything). Pure.
sub all_awaiting_decision {
    my ($packages) = @_;
    my $saw_non_terminal = 0;
    for my $pkg (@{ $packages || [] }) {
        my $status = $pkg->{status} // '';
        next if $TERMINAL_STATUS{$status};
        $saw_non_terminal = 1;
        return 0 unless $AWAITING_DECISION_STATUS{$status};
    }
    return $saw_non_terminal ? 1 : 0;
}

# watcher_armed(\@packages) -> bool: NOT I1 and NOT I2. A watcher is armed
# only when work is genuinely in flight -- the paired positive gate (sec.3)
# that stops an implementation which never arms anything from trivially
# satisfying I1/I2. Pure.
sub watcher_armed {
    my ($packages) = @_;
    return 0 if blueprint_terminal($packages);
    return 0 if all_awaiting_decision($packages);
    return 1;
}

# progress_table(\@packages) -> { done_count => N, rows => [ {id,status} ] }
# done packages collapse to a count (sec.4); every non-terminal package is
# listed individually with its actual state. `dropped` (also terminal) is
# listed individually too, since only `done` is the "collapse to a summary"
# case the spec names -- a dropped package is still worth a row to explain
# why it isn't progressing. Pure.
sub progress_table {
    my ($packages) = @_;
    my @rows;
    my $done_count = 0;
    for my $pkg (@{ $packages || [] }) {
        my $status = $pkg->{status} // '';
        if ($status eq 'done') {
            $done_count++;
            next;
        }
        push @rows, { id => $pkg->{id}, status => $status };
    }
    return { done_count => $done_count, rows => \@rows };
}

# classify_decision(\%case) -> 'escalate' | 'decide'
# case: action_kind, contradicts_recorded_ruling, groundable_in_disk_evidence,
# clearly_better_option. The three escalation classes (E1/E2/E3) are a
# DISJUNCTION evaluated FIRST -- any one forces escalation regardless of how
# clear the better option looks, including when it is both obviously-better
# AND irreversible (E1 wins, spec sec.1.2/§5 C3). Pure.
sub classify_decision {
    my ($case) = @_;
    $case ||= {};

    # E1 -- irreversible/destructive: the concrete accept/drop actions.
    my $action = $case->{action_kind} // '';
    return 'escalate' if $action eq 'accept' || $action eq 'drop';

    # E2 -- contradicts a recorded operator ruling.
    return 'escalate' if $case->{contradicts_recorded_ruling};

    # E3 -- not groundable in disk evidence.
    return 'escalate' unless $case->{groundable_in_disk_evidence};

    # None of E1-E3 held. Decide only when there is a clear better option.
    return $case->{clearly_better_option} ? 'decide' : 'escalate';
}

# autonomous_decision_record(\%case) -> record hashref, or undef if 'escalate'.
# The durable record (spec sec.1.3): reasoning, disk evidence, cost of
# waiting, and an awaiting-confirmation marker. Absent entirely for an
# escalated case -- "always writes a record" is explicitly wrong (§5 C4
# vacuity gate). Pure.
sub autonomous_decision_record {
    my ($case) = @_;
    $case ||= {};
    return undef unless classify_decision($case) eq 'decide';
    return {
        reasoning             => $case->{reasoning},
        disk_evidence         => $case->{disk_evidence},
        cost_of_waiting       => $case->{cost_of_waiting},
        awaiting_confirmation => 1,
    };
}

package main;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

unless (caller) {
    require JSON::PP;
    my ($runs, $bp, $bpdir, $seen_csv, $timeout, $poll, $category_csv);
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
        elsif ($arg eq '--category'){ $category_csv = $need->('--category'); }
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

    # e02 §2.6: --category cat1,cat2,... (comma-separated, parsed like --seen).
    # Omitted (flag not given at all) -> no filtering, byte-identical to today.
    # fixbatch step7 / red-team NIT 1: a flag that IS given but CSV-splits to
    # only empty tokens (e.g. "--category ,," or "--category ,") must not
    # silently degrade to "no filtering" -- that fails a deliberate filter
    # request open (the caller sees everything, not the narrowed set they
    # asked for). Only a genuinely-omitted flag keeps the "no filtering"
    # meaning; a present-but-empty-after-parsing value is a loud error naming
    # the valid categories, sourced from BpOrch::@CATEGORIES (the single
    # definition, e02 spec §2.1) rather than duplicated here.
    my $category_filter;
    if (defined $category_csv) {
        $category_filter = { map { $_ => 1 } grep { length } split /,/, $category_csv };
        unless (%$category_filter) {
            my $dir = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
            require "$dir/bp-orchestrator.pl";
            no warnings 'once';   # cross-package global, referenced exactly once here
            print STDERR "bp-wait-for-decision: --category '$category_csv' has no usable "
                . "category value; valid categories are: "
                . join(', ', @BpOrch::CATEGORIES) . "\n";
            exit 2;
        }
    }

    my $res = BpWait::wait_loop({
        dir     => "$runs/needs-you",
        seen    => BpWait::parse_seen($seen_csv),
        timeout => (defined $timeout ? $timeout + 0 : 0),
        poll    => (defined $poll ? $poll + 0 : undef),
        category_filter => $category_filter,
    });

    print JSON::PP->new->canonical->pretty->encode($res);
    exit($res->{status} eq 'decision' ? 0 : 3);
}
1;
