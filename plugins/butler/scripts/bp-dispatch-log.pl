#!/usr/bin/env perl
# bp-dispatch-log.pl — the per-dispatch budget record for a driver- or
# coordinator-issued Agent/Task worker dispatch (w02-dispatch-budget-and-
# interrupt).
#
# WHY THIS EXISTS
#
# A coordinator gets max_turns (ledger frontmatter) and BP_ATTEMPT_CAP
# (bp-orchestrator.pl). A worker an interactive driver dispatches via the
# Agent/Task tool gets neither — no wall-clock deadline it can be compared
# against, no elapsed-time signal independent of the worker's own
# self-report. The cost, measured: one dispatch consumed roughly FOUR HOURS
# of wall clock while it self-reported 47 minutes. Any detector built on the
# agent's self-reported duration is built on sand.
#
# THE ONE RULE THIS FILE ENFORCES: elapsed time is measured DRIVER-SIDE,
# from the driver's own clock at launch (Decision 7). Nothing here ever
# reads a worker's own self-reported duration figure or anything shaped
# like it — elapsed_seconds is a plain subtraction of two driver-supplied
# numbers, $now - $started_at.
#
# Follows the family convention exactly (bp-runstate.pl's own shape): a
# pure/injectable-seam library (package BpDispatchLog) with a thin CLI
# (package main, guarded by `unless (caller)`), storage resolved the same
# way bp-runstate.pl::state_dir resolves its own root (CLAUDE_PROJECT_DIR,
# else computed from __FILE__, overridable via --root), atomic
# tmp-then-rename writes copied from bp-runstate.pl::_write, including its
# corrected absolute-path mkdir -p (an earlier version of that pattern
# treated an absolute state dir as relative and left stray dirs under the
# repo root — never repeat that).
#
# --now EPOCH is a TEST-ONLY SEAM on the CLI layer (mirrors bp-watch.pl /
# bp-runstate.pl's own pure functions) — it overrides "the driver's own
# clock" so tests never sleep in real time. The library functions below
# already take $now as a plain argument.
#
# Runs standalone: perl plugins/butler/scripts/bp-dispatch-log.pl <cmd> ...
package BpDispatchLog;
use strict;
use warnings;
use JSON::PP ();
use File::Basename qw(dirname);
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });

# log_dir($root) -> ".../.ccpraxis-local-data/.dispatch-log" — same
# resolution convention as bp-runstate.pl::state_dir, not reinvented.
sub log_dir {
    my ($root) = @_;
    $root //= $ENV{CLAUDE_PROJECT_DIR} // Cwd::abs_path("$DIR/../../..") // '.';
    return "$root/.ccpraxis-local-data/.dispatch-log";
}

sub history_path { return log_dir($_[0]) . '/history.jsonl' }

# record_path($root, $id) -> ".../.dispatch-log/$id.json". $id is validated
# against qr/^[A-Za-z0-9._-]+$/ by the CLI layer BEFORE it ever reaches here
# (path-injection guard) — this function does no validation of its own.
sub record_path {
    my ($root, $id) = @_;
    return log_dir($root) . "/$id.json";
}

# elapsed_seconds($started_at, $now) — PURE. $now - $started_at. Never
# clamped: a clock that moved backward returns a negative number, visible
# as an anomaly rather than silently floored to 0 (which would misreport a
# stalled dispatch as brand new).
sub elapsed_seconds {
    my ($started_at, $now) = @_;
    return $now - $started_at;
}

# is_over_budget($elapsed_seconds, $budget_seconds) — PURE. Strictly
# greater-than; exactly AT budget is not over. budget_seconds undef ->
# always false: "no budget configured" is not the same claim as "over
# budget", and must not silently resolve toward the alarming answer just
# because a number is missing.
sub is_over_budget {
    my ($elapsed, $budget) = @_;
    return '' unless defined $budget;
    return $elapsed > $budget;
}

# median(\@durations) — PURE. Empty -> undef ("no baseline yet", never 0,
# which would read as "this worker type is instant"). Odd count -> the
# numeric-sorted middle value. Even count -> the mean of the two middles.
sub median {
    my ($arr) = @_;
    return undef unless $arr && @$arr;
    my @s = sort { $a <=> $b } @$arr;
    my $n = scalar @s;
    return $s[($n - 1) / 2] if $n % 2;
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2;
}

# read_history($root, $worker_type) -> \@durations — IMPURE: reads
# history.jsonl (append-only, one JSON line per COMPLETED `done` dispatch —
# see "finish" in the CLI below for why interrupted/killed durations are
# excluded), filters to $worker_type, returns the plain seconds list
# median() consumes. A missing/unreadable file is an empty list, not an
# error — no history yet is the normal starting state.
sub read_history {
    my ($root, $worker_type) = @_;
    my $p = history_path($root);
    my @out;
    open my $fh, '<', $p or return \@out;
    while (my $line = <$fh>) {
        chomp $line;
        next unless length $line;
        my $rec = eval { JSON::PP->new->decode($line) };
        next unless ref $rec eq 'HASH';
        next unless defined $rec->{worker_type} && $rec->{worker_type} eq $worker_type;
        next unless defined $rec->{duration_seconds};
        push @out, $rec->{duration_seconds} + 0;
    }
    close $fh;
    return \@out;
}

# _mkdir_p($dir) — copied from bp-runstate.pl::_write's own mkdir -p, not
# reinvented. The leading separator is LOAD-BEARING: starting $cur at '' and
# skipping empty components turns an absolute "/tmp/x/y" into a RELATIVE
# "tmp/x/y" and creates the whole tree under the current working directory
# — the same stray-directory class as the 576 drive-root entries elsewhere
# in this project's history.
sub _mkdir_p {
    my ($d) = @_;
    return 1 if -d $d;
    my $cur = ($d =~ m{^/}) ? '/' : '';
    for my $part (grep { length } split m{/}, $d) {
        $cur = ($cur eq '' || $cur eq '/') ? "$cur$part" : "$cur/$part";
        next if $cur =~ /^[A-Za-z]:$/;      # bare drive letter is not a dir
        unless (-d $cur) { mkdir $cur or return 0 }
    }
    return -d $d;
}

# write_record($root, \%rec) -> 1|0 — IMPURE. Same tmp-file-then-rename
# atomic write as bp-runstate.pl::_write.
sub write_record {
    my ($root, $rec) = @_;
    _mkdir_p(log_dir($root)) or return 0;
    my $p   = record_path($root, $rec->{id});
    my $tmp = "$p.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->encode($rec);
    close $fh;
    rename($tmp, $p) or do { unlink $tmp; return 0 };
    return 1;
}

# read_record($root, $id) -> \%rec | undef — IMPURE.
sub read_record {
    my ($root, $id) = @_;
    my $p = record_path($root, $id);
    open my $fh, '<', $p or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return undef unless defined $raw && length $raw;
    my $rec = eval { JSON::PP->new->decode($raw) };
    return (ref $rec eq 'HASH') ? $rec : undef;
}

# append_history($root, \%line) -> 1|0 — IMPURE. Append-only; one JSON line.
sub append_history {
    my ($root, $line) = @_;
    _mkdir_p(log_dir($root)) or return 0;
    my $p = history_path($root);
    open my $fh, '>>', $p or return 0;
    print {$fh} JSON::PP->new->canonical->encode($line), "\n";
    close $fh;
    return 1;
}

# list_records($root) -> \@ids — IMPURE. Every *.json under log_dir except
# history.jsonl (which is not a per-id record).
sub list_records {
    my ($root) = @_;
    my $dir = log_dir($root);
    my @ids;
    if (opendir my $dh, $dir) {
        for my $f (readdir $dh) {
            next unless $f =~ /^(.+)\.json\z/;
            push @ids, $1;
        }
        closedir $dh;
    }
    return \@ids;
}

package main;
use strict;
use warnings;

my $ID_RE = qr/^[A-Za-z0-9._-]+$/;

sub usage_error {
    my ($msg) = @_;
    print STDERR "bp-dispatch-log: usage error: $msg\n";
    exit 2;
}

unless (caller) {
    my $cmd = shift @ARGV // '';
    my %o;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a eq '--id')             { $o{id}             = shift @ARGV }
        elsif ($a eq '--worker-type')    { $o{worker_type}     = shift @ARGV }
        elsif ($a eq '--budget-seconds') { $o{budget_seconds}  = shift @ARGV }
        elsif ($a eq '--note')           { $o{note}            = shift @ARGV }
        elsif ($a eq '--report')         { $o{report}          = shift @ARGV }
        elsif ($a eq '--status')         { $o{status}          = shift @ARGV }
        elsif ($a eq '--root')           { $o{root}            = shift @ARGV }
        elsif ($a eq '--now')            { $o{now}             = shift @ARGV }
        else { usage_error("unknown option '$a'") }
    }
    my $root = $o{root};
    my $now  = defined $o{now} ? ($o{now} + 0) : time;

    if ($cmd eq 'start') {
        usage_error('--id is required') unless defined $o{id};
        usage_error("--id '$o{id}' has an invalid shape") unless $o{id} =~ $ID_RE;
        usage_error('--worker-type is required') unless defined $o{worker_type};

        my $budget = defined $o{budget_seconds} ? ($o{budget_seconds} + 0) : 1800;

        my $existing = BpDispatchLog::read_record($root, $o{id});
        if ($existing && defined $existing->{status} && $existing->{status} eq 'running') {
            print STDERR "bp-dispatch-log: refused: a running record already exists for --id "
                        . "'$o{id}' (started_at=$existing->{started_at}) — finish it before "
                        . "starting a fresh one under the same id\n";
            exit 3;
        }

        my $rec = {
            id             => $o{id},
            worker_type    => $o{worker_type},
            started_at     => $now,
            budget_seconds => $budget,
            status         => 'running',
            note           => $o{note},
        };
        BpDispatchLog::write_record($root, $rec)
            or do { print STDERR "bp-dispatch-log: could not write record for '$o{id}'\n"; exit 4 };
        print "started $o{id} (worker_type=$o{worker_type} budget_seconds=$budget)\n";
        exit 0;
    }
    elsif ($cmd eq 'elapsed') {
        usage_error('--id is required') unless defined $o{id};
        my $rec = BpDispatchLog::read_record($root, $o{id});
        unless ($rec) {
            print STDOUT "UNVERIFIABLE: no record for $o{id}\n";
            exit 4;
        }
        my $elapsed = BpDispatchLog::elapsed_seconds($rec->{started_at}, $now);
        my $budget  = $rec->{budget_seconds};
        my $over    = BpDispatchLog::is_over_budget($elapsed, $budget);
        my $hist    = BpDispatchLog::read_history($root, $rec->{worker_type});
        my $med     = BpDispatchLog::median($hist);

        print "id: $rec->{id}\n";
        print "worker_type: $rec->{worker_type}\n";
        print "elapsed_seconds: $elapsed\n";
        print 'budget_seconds: ' . (defined $budget ? $budget : 'null') . "\n";
        print 'over_budget: ' . ($over ? 'true' : 'false') . "\n";
        print 'median_seconds: ' . (defined $med ? $med : 'null') . "\n";
        exit 0;
    }
    elsif ($cmd eq 'list') {
        my $ids = BpDispatchLog::list_records($root);
        for my $id (sort @$ids) {
            my $rec = BpDispatchLog::read_record($root, $id) or next;
            next unless defined $rec->{status} && $rec->{status} eq 'running';
            my $elapsed = BpDispatchLog::elapsed_seconds($rec->{started_at}, $now);
            my $budget  = $rec->{budget_seconds};
            my $over    = BpDispatchLog::is_over_budget($elapsed, $budget);
            print "id: $id worker_type: $rec->{worker_type} "
                . 'over_budget: ' . ($over ? 'true' : 'false') . ' '
                . "elapsed_seconds: $elapsed "
                . 'budget_seconds: ' . (defined $budget ? $budget : 'null') . "\n";
        }
        exit 0;
    }
    elsif ($cmd eq 'finish') {
        usage_error('--id is required') unless defined $o{id};
        usage_error('--status is required (done|interrupted|killed)') unless defined $o{status};
        usage_error("--status '$o{status}' must be done|interrupted|killed")
            unless $o{status} =~ /^(done|interrupted|killed)\z/;

        my $rec = BpDispatchLog::read_record($root, $o{id});
        unless ($rec) {
            print STDOUT "UNVERIFIABLE: no record for $o{id}\n";
            exit 4;
        }
        my $duration = BpDispatchLog::elapsed_seconds($rec->{started_at}, $now);
        $rec->{status}           = $o{status};
        $rec->{ended_at}         = $now;
        $rec->{duration_seconds} = $duration;
        $rec->{report}           = $o{report} if defined $o{report};
        $rec->{note}             = $o{note}   if defined $o{note};

        BpDispatchLog::write_record($root, $rec)
            or do { print STDERR "bp-dispatch-log: could not write record for '$o{id}'\n"; exit 4 };

        # Only a COMPLETED `done` dispatch contributes to the median. A
        # duration cut short by intervention (interrupted/killed) is not
        # representative of "how long this kind of work normally takes",
        # and folding it in would silently pull the baseline toward the
        # very failures the median exists to flag.
        if ($o{status} eq 'done') {
            BpDispatchLog::append_history($root, {
                worker_type      => $rec->{worker_type},
                duration_seconds => $duration,
                ended_at         => $now,
            }) or do { print STDERR "bp-dispatch-log: could not append history for '$o{id}'\n"; exit 4 };
        }
        print "finished $o{id} (status=$o{status} duration_seconds=$duration)\n";
        exit 0;
    }
    else {
        print STDERR <<'USAGE';
bp-dispatch-log.pl — the per-dispatch budget record for an Agent/Task worker.

  start  --id <ID> --worker-type <TYPE> [--budget-seconds N] [--note TEXT] [--root DIR] [--now EPOCH]
  elapsed --id <ID> [--root DIR] [--now EPOCH]
  list    [--root DIR] [--now EPOCH]
  finish  --id <ID> --status done|interrupted|killed [--report PATH] [--note TEXT] [--root DIR] [--now EPOCH]

Exit codes: 0 ok · 2 usage error · 3 start refused (a running record already
exists for --id) · 4 elapsed/finish: no record for --id (UNVERIFIABLE).
USAGE
        exit 2;
    }
}
1;
