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
use Scalar::Util qw(looks_like_number);

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });

# ROLE VOCABULARY (D6, locked) -- exactly these three words, in this order.
# No fourth role name may appear anywhere in this script, its tests, or any
# caller-facing message: coordinator (drives a package), worker (does the
# work), judge (evaluates it). @ROLES is the single source of truth other
# packages (05, 06) must import rather than re-declare.
our @ROLES = qw(coordinator worker judge);

# DEFAULT_BUDGET_SECONDS mirrors the CLI's own historical `start` default
# (see below, where --budget-seconds is absent or invalid) -- kept as a
# named constant so stale_after_seconds() falls back to the SAME number the
# CLI already uses, not a second, driftable copy of 1800.
our $DEFAULT_BUDGET_SECONDS = 1800;

# STALE_BUDGET_MULTIPLE (locked at 4x) -- a `running` record is STALE once
# its elapsed time exceeds STALE_BUDGET_MULTIPLE times its own
# budget_seconds (or DEFAULT_BUDGET_SECONDS when budget_seconds is absent or
# invalid). This sits strictly beyond `is_over_budget`'s 1x threshold on
# purpose: "late but alive" (over budget, not yet stale) must stay a
# renderable state, not collapse into the same signal as "abandoned". 4x the
# default budget is 2 hours -- comfortably past any normal overrun, and
# below the one measured pathological case this file exists because of (see
# the header above: ~4h of real wall clock self-reported as 47 minutes).
# Nothing here reads a self-reported duration or a pid — staleness is a
# driver-side clock subtraction only (Decision 2 / Decision 7), exactly like
# elapsed_seconds below.
our $STALE_BUDGET_MULTIPLE = 4;

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

# role_is_valid($role) — PURE. Defined-true/defined-false (never undef, so
# is($got, !!0, ...) works the same as every other predicate in this file).
# Membership in @ROLES only — D6's closed set.
sub role_is_valid {
    my ($role) = @_;
    return '' unless defined $role;
    for my $r (@ROLES) { return 1 if $r eq $role }
    return '';
}

# stale_after_seconds($budget_seconds) — PURE, always returns a defined
# Int. A usable positive budget scales the threshold; anything else
# (undef, 0, negative, non-numeric) falls back to the DEFAULT budget, not to
# "never stale" — an absent/garbage budget must not make staleness
# unreachable.
sub stale_after_seconds {
    my ($budget_seconds) = @_;
    if (defined $budget_seconds && looks_like_number($budget_seconds) && $budget_seconds > 0) {
        return $STALE_BUDGET_MULTIPLE * $budget_seconds;
    }
    return $STALE_BUDGET_MULTIPLE * $DEFAULT_BUDGET_SECONDS;
}

# is_stale($rec, $now) — PURE, no warnings on any input. True iff $rec is a
# HASH ref, status is 'running', started_at is defined+numeric, AND elapsed
# is STRICTLY greater than stale_after_seconds(budget_seconds) — exactly AT
# the threshold is not yet stale, mirroring is_over_budget's own convention.
sub is_stale {
    my ($rec, $now) = @_;
    return '' unless ref $rec eq 'HASH';
    return '' unless defined $rec->{status} && $rec->{status} eq 'running';
    return '' unless defined $rec->{started_at} && looks_like_number($rec->{started_at});
    my $elapsed = elapsed_seconds($rec->{started_at}, $now);
    return $elapsed > stale_after_seconds($rec->{budget_seconds}) ? 1 : '';
}

# is_live($rec, $now) — PURE. True iff the same three evaluability
# conditions as is_stale hold AND is_stale is false. NOT the complement of
# is_stale over ALL inputs — an unevaluable record (not a hash, no status,
# a finished status, a missing/non-numeric started_at) is neither live nor
# stale, deliberately: "cannot evaluate" must never be reported as either
# claim.
sub is_live {
    my ($rec, $now) = @_;
    return '' unless ref $rec eq 'HASH';
    return '' unless defined $rec->{status} && $rec->{status} eq 'running';
    return '' unless defined $rec->{started_at} && looks_like_number($rec->{started_at});
    return is_stale($rec, $now) ? '' : 1;
}

# attribution($rec) -> \%h with EXACTLY the keys blueprint/package/role,
# always present — PURE. Absent, JSON null, and empty-string all collapse to
# a single undef ("unknown"); a non-empty value is returned VERBATIM,
# including an unrecognised role (this function does not validate against
# @ROLES — call role_is_valid for that). From this writer only two on-disk
# states can occur (absent, or a validated non-empty value); the null/empty
# cases only arise from a hand-edited file, and folding them into "unknown"
# is the only honest reading — no consumer should ever need `exists`.
sub attribution {
    my ($rec) = @_;
    my %out;
    for my $k (qw(blueprint package role)) {
        my $v = (ref $rec eq 'HASH' && exists $rec->{$k} && defined $rec->{$k} && length $rec->{$k})
              ? $rec->{$k}
              : undef;
        $out{$k} = $v;
    }
    return \%out;
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
use File::Basename qw(dirname);
use Cwd ();
use Scalar::Util qw(looks_like_number);

my $MAIN_DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
require "$MAIN_DIR/bp-write-guard.pl";   # fixbatch step7 / MEDIUM-3: BpWrite::guarded_write

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
        elsif ($a eq '--blueprint')      { $o{blueprint}       = shift @ARGV }
        elsif ($a eq '--package')        { $o{package}         = shift @ARGV }
        elsif ($a eq '--role')           { $o{role}            = shift @ARGV }
        else { usage_error("unknown option '$a'") }
    }
    my $root = $o{root};

    # fixbatch step7 / MEDIUM-1: validated ONCE, uniformly, for every command
    # that takes --id — not just `start`. The file's own header/comment
    # claims `record_path` is only ever reached with an already-validated
    # id; that was true for `start` and false for `elapsed`/`finish`, which
    # is a path-traversal hole (demonstrated: --id ../../../outside/secret
    # reads an arbitrary *.json file). Checked before ANY --id-derived path
    # is touched, for any command.
    usage_error("--id '$o{id}' has an invalid shape")
        if defined $o{id} && $o{id} !~ $ID_RE;

    # w02-dispatch-record-attribution / spec 2.4: --blueprint and --package
    # reuse the SAME shape guard as --id (path-injection guard — both name a
    # directory/file a future consumer joins into a path, and this host's
    # own paths are non-ASCII), PLUS an explicit reject of exactly '.' or
    # '..' (both otherwise match the character class). Validated at this
    # single writer rather than at every future reader (AC27/AC28).
    for my $opt (qw(blueprint package)) {
        my $v = $o{$opt};
        next unless defined $v;
        usage_error("--$opt '$v' has an invalid shape")
            if $v !~ $ID_RE || $v eq '.' || $v eq '..';
    }

    # --role must be a member of the closed vocabulary (D6) — mirrors the
    # existing --status guard exactly.
    usage_error("--role '$o{role}' must be one of: "
               . join(', ', @BpDispatchLog::ROLES))
        if defined $o{role} && !BpDispatchLog::role_is_valid($o{role});

    # Attribution options are meaningful only on `start` (spec 2.4) — any of
    # --blueprint/--package/--role on another command is a usage error
    # naming the offending option and the word 'start'.
    if ($cmd ne 'start') {
        for my $opt (qw(blueprint package role)) {
            usage_error("--$opt is only valid with the start command")
                if defined $o{$opt};
        }
    }

    # fixbatch step7 / MEDIUM-2: --now is a TEST-ONLY seam (see file header).
    # Nothing previously distinguished a test invocation from a production
    # one, so any caller — including a dispatched worker with Bash access
    # that knows its own --id — could fabricate elapsed time and defeat the
    # one guarantee this file exists to provide (elapsed time is the
    # DRIVER's own clock, never a self-report). Gated behind an explicit env
    # marker rather than removed outright: the pure library functions
    # already take $now as a plain argument (never sleeping in real time is
    # how every test in this family is built), so removing the CLI seam
    # entirely would force every test to fake time some other way for no
    # real security gain — a caller willing to set an env var to fabricate
    # its own clock could just as easily edit history.jsonl directly. The
    # marker's value is that a production call which includes --now BY
    # MISTAKE OR MALICE is rejected instead of silently honored.
    my $now;
    if (defined $o{now}) {
        if (($ENV{CCPRAXIS_DISPATCH_LOG_TEST_NOW} // '') eq '1') {
            $now = $o{now} + 0;
        } else {
            usage_error("--now is a test-only seam gated behind "
                       . "CCPRAXIS_DISPATCH_LOG_TEST_NOW=1 — a production caller must never "
                       . "fabricate the driver's own clock");
        }
    } else {
        $now = time;
    }

    if ($cmd eq 'start') {
        usage_error('--id is required') unless defined $o{id};
        usage_error('--worker-type is required') unless defined $o{worker_type};

        # fixbatch step7 / NIT (elevated to required): a bare `+0` coercion
        # silently turns a non-numeric --budget-seconds into 0, and 0 is not
        # "unlimited" here — every dispatch would read as immediately over
        # budget. This is the identical shape as r01's BP_MIN_RELAUNCH_SECS
        # defect, which a real field incident (7 relaunches in 48s against a
        # cap of 2) traced back to exactly this kind of unvalidated
        # coercion. Require a positive integer; anything else falls back to
        # the documented default and WARNS naming the rejected value, rather
        # than silently becoming a budget of zero.
        my $budget;
        if (defined $o{budget_seconds}) {
            if ($o{budget_seconds} =~ /^\d+$/ && $o{budget_seconds} > 0) {
                $budget = $o{budget_seconds} + 0;
            } else {
                print STDERR "bp-dispatch-log: warning: --budget-seconds '$o{budget_seconds}' "
                           . "is not a positive integer; falling back to the default (1800)\n";
                $budget = 1800;
            }
        } else {
            $budget = 1800;
        }

        # fixbatch step7 / MEDIUM-3: routed through BpWrite::guarded_write
        # (the a01-write-integrity-reread-under-lock primitive) rather than
        # a bare check-then-write. Two racing `start` calls on the same
        # fresh --id could previously both pass the "already running" check
        # (neither sees the other's not-yet-written record) and both
        # proceed to write — the later rename() wins silently, with no
        # error surfaced to either caller. Unlike bp-watch.pl's accepted
        # "no lock, duplicate is wasted cost" stance, this race can RESET a
        # live dispatch's own clock (masking over_budget for a genuinely
        # stalled worker), which is the a01 pattern this primitive exists
        # for — reused here, not reinvented.
        BpDispatchLog::_mkdir_p(BpDispatchLog::log_dir($root))
            or do { print STDERR "bp-dispatch-log: could not create the log directory\n"; exit 4 };
        my $rec_path  = BpDispatchLog::record_path($root, $o{id});
        my $id        = $o{id};
        my $wt        = $o{worker_type};
        my $note      = $o{note};
        my $blueprint = $o{blueprint};
        my $package   = $o{package};
        my $role      = $o{role};
        my $result = BpWrite::guarded_write({
            site  => 'bp-dispatch-log.start',
            path  => $rec_path,
            valid => sub {
                my ($raw) = @_;
                return undef unless defined $raw && length $raw;
                my $existing = eval { JSON::PP->new->decode($raw) };
                if (ref $existing eq 'HASH' && defined $existing->{status}
                    && $existing->{status} eq 'running') {
                    return "a running record already exists for --id '$id' "
                         . "(started_at=$existing->{started_at}) — finish it before starting "
                         . "a fresh one under the same id";
                }
                return undef;
            },
            mutate => sub {
                my $rec = {
                    id             => $id,
                    worker_type    => $wt,
                    started_at     => $now,
                    budget_seconds => $budget,
                    status         => 'running',
                    note           => $note,
                };
                # Attribution fields (spec 2.5): present ONLY when supplied.
                # An option not given means the key is ABSENT from the JSON
                # object — never present-with-null — so backward
                # compatibility (AC22) and subset persistence (AC20) both
                # hold with the same three lines.
                $rec->{blueprint} = $blueprint if defined $blueprint;
                $rec->{package}   = $package   if defined $package;
                $rec->{role}      = $role      if defined $role;
                return JSON::PP->new->canonical->encode($rec);
            },
        });
        unless ($result->{ok}) {
            if (($result->{outcome} // '') eq 'refused') {
                print STDERR "bp-dispatch-log: refused: $result->{reason}\n";
                exit 3;
            }
            print STDERR "bp-dispatch-log: could not write record for '$id': "
                       . ($result->{reason} // 'unknown error') . "\n";
            exit 4;
        }
        print "started $id (worker_type=$wt budget_seconds=$budget)\n";
        exit 0;
    }
    elsif ($cmd eq 'elapsed') {
        usage_error('--id is required') unless defined $o{id};
        my $rec = BpDispatchLog::read_record($root, $o{id});
        unless ($rec) {
            print STDOUT "UNVERIFIABLE: no record for $o{id}\n";
            exit 4;
        }
        # A record whose started_at is absent or non-numeric cannot be evaluated,
        # and elapsed_seconds is a plain subtraction (t/136 B1/B2 pin that
        # deliberately) -- so `$now - undef` would silently print $now, reporting
        # an agent as having run for decades. Refuse instead, reusing the
        # UNVERIFIABLE/exit-4 vocabulary this same branch already uses for a
        # missing record rather than inventing a second marker. The `list` site
        # below already guards this; `elapsed` was missed. Covered by t/178.
        unless (defined $rec->{started_at} && looks_like_number($rec->{started_at})) {
            print STDOUT "UNVERIFIABLE: record for $o{id} has no usable started_at\n";
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
            # A `running` record whose started_at is absent or non-numeric
            # cannot be evaluated (AC34) — skip it silently, exactly as a
            # non-`running` record is already skipped above. Checked BEFORE
            # elapsed_seconds is ever called, so no Perl warning is raised
            # and no fabricated "elapsed_seconds: 0" is printed for a record
            # that has no real answer.
            next unless defined $rec->{started_at} && looks_like_number($rec->{started_at});
            my $elapsed = BpDispatchLog::elapsed_seconds($rec->{started_at}, $now);
            my $budget  = $rec->{budget_seconds};
            my $over    = BpDispatchLog::is_over_budget($elapsed, $budget);
            my $stale   = BpDispatchLog::is_stale($rec, $now);
            print "id: $id worker_type: $rec->{worker_type} "
                . 'over_budget: ' . ($over ? 'true' : 'false') . ' '
                . "elapsed_seconds: $elapsed "
                . 'budget_seconds: ' . (defined $budget ? $budget : 'null') . ' '
                . 'stale: ' . ($stale ? 'true' : 'false') . "\n";
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

  start  --id <ID> --worker-type <TYPE> [--blueprint <NAME>] [--package <NAME>]
         [--role coordinator|worker|judge] [--budget-seconds N] [--note TEXT]
         [--root DIR] [--now EPOCH]
  elapsed --id <ID> [--root DIR] [--now EPOCH]
  list    [--root DIR] [--now EPOCH]
  finish  --id <ID> --status done|interrupted|killed [--report PATH] [--note TEXT] [--root DIR] [--now EPOCH]

--blueprint / --package / --role are optional and valid ONLY with `start`;
--role is a closed vocabulary of exactly coordinator, worker or judge.

Exit codes: 0 ok · 2 usage error · 3 start refused (a running record already
exists for --id) · 4 elapsed/finish: no record for --id (UNVERIFIABLE).

A `running` record is STALE once its elapsed time exceeds 4x its own
budget_seconds; `list` marks it `stale: true` but still shows it.
USAGE
        exit 2;
    }
}
1;
