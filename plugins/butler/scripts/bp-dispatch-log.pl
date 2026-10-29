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
# (package main, guarded by `unless (caller)`), storage under the project
# root (--root, else BpProjectRoot::resolve -- see log_dir), atomic
# tmp-then-rename writes copied from bp-runstate.pl::_write, including its
# corrected absolute-path mkdir -p (an earlier version of that pattern
# treated an absolute state dir as relative and left stray dirs under the
# repo root — never repeat that).
#
# --now EPOCH is a TEST-ONLY SEAM on the CLI layer (mirrors butler-hold /
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
require "$DIR/BpProjectRoot.pm" unless grep { m{(?:^|/)BpProjectRoot\.pm$} } keys %INC;

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

# RATIO_DEFAULT / RATIO_ENV -- coordinator-context-discipline/
# 03-dispatch-discipline-enforcement §2.1, the canonical threshold table. The
# ONLY places either number is written in code -- neither the CLI nor the
# nudge hook holds a second copy. min_calls is a floor (below it the ratio is
# never computed, so a handful of calls at session start never fires);
# min_ratio is a multiplier a well-behaved coordinator's own call volume
# should stay well under. Both gates must hold; see the spec's own worked
# table for why 200/40.
our %RATIO_DEFAULT = ( min_calls => 200, min_ratio => 40 );
our %RATIO_ENV     = ( min_calls => 'BP_DISPATCH_RATIO_MIN_CALLS',
                       min_ratio => 'BP_DISPATCH_RATIO_MIN' );
our $RATIO_MAX_LINES     = 100_000;      # lines examined in one transcript scan
our $RATIO_MAX_LINE_BYTES = 1024 * 1024; # a longer line is skipped, never decoded

# log_dir($root) -> ".../.ccpraxis-local-data/.dispatch-log". With no root
# (undef or empty), the project comes from BpProjectRoot::resolve -- never
# from this script's own location. The old fallback,
# abs_path("$DIR/../../.."), named the INSTALL whenever a driver's Bash call
# lacked CLAUDE_PROJECT_DIR (a driver's Bash tool does not carry it), and 21
# records from Sep 11-16 were found inside the live install's own data dir.
# An empty --root, which wait-shape-guard.sh and
# context-ceiling.sh pass when BP_PROJECT_ROOT is unset, used to
# resolve to "/.ccpraxis-local-data"; it now means "resolve it".
sub log_dir {
    my ($root) = @_;
    $root = BpProjectRoot::resolve() unless defined $root && length $root;
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

# MAX_BUDGET_SECONDS (fixbatch 02-redteam / H1) -- the ceiling
# stale_after_seconds honors before scaling a caller-supplied budget. 7 days
# (604800s). Every real dispatch budget observed on this run tops out at
# 3000s, so this is nowhere near a real ceiling being hit by accident; it
# exists only to stop a budget the CLI's own /^\d+$/ guard admits (e.g.
# --budget-seconds 999999999999999999999, which JSON round-trips as
# 1e+21) from scaling stale_after_seconds() past any clock this process
# will ever see, which is how a `running` record was made permanently
# is_live/never-stale through the SANCTIONED CLI (H1). A non-finite value
# (Inf/NaN, reachable only via a hand-edited record since the CLI's regex
# already excludes them) is caught by the same `<=` comparison: Inf is
# never <= MAX_BUDGET_SECONDS, NaN never satisfies any comparison, so both
# fall through to the same default-budget path as 0/-5/'abc'/''.
our $MAX_BUDGET_SECONDS = 7 * 24 * 60 * 60;

# stale_after_seconds($budget_seconds) — PURE, always returns a defined
# Int. A usable positive budget AT OR BELOW MAX_BUDGET_SECONDS scales the
# threshold; anything else (undef, 0, negative, non-numeric, non-finite, or
# an absurdly large budget — see MAX_BUDGET_SECONDS above) falls back to
# the DEFAULT budget, not to "never stale" — an absent/garbage/oversized
# budget must not make staleness unreachable.
sub stale_after_seconds {
    my ($budget_seconds) = @_;
    if (defined $budget_seconds && looks_like_number($budget_seconds)
        && $budget_seconds > 0 && $budget_seconds <= $MAX_BUDGET_SECONDS) {
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

# ---------------------------------------------------------------------------
# RETENTION -- bug 20260908-225444-b9db.
#
# The store only ever GREW. `start` writes one record per dispatch and nothing
# ever removed one. Hook-written worker records USED TO be never `finish`ed at
# all: track-dispatch.sh's PostToolUse side had no correlation key by which it
# could identify which record to close (the id is hk-...-$$-$RANDOM, persisted
# nowhere), so those records sat at status `running` forever, aged into
# `stale`, and stayed.
#
# coordinator-context-discipline/01-deterministic-dispatch-tracking closed
# that blocker: track-dispatch.sh's PostToolUse half now recomputes the same
# `dispatch_key` the start half stamped and calls `resolve` (below), which
# DOES close the record. Retention still matters for two residuals this
# package deliberately leaves alone: B8 (a dispatch whose PostToolUse never
# fires at all -- a crashed process, a killed container -- still sits
# `running` forever; there is no timeout, by design) and any pre-existing
# record written before this package shipped.
#
# Two consumers then degrade SILENTLY at different thresholds, and the LOWER
# one bites first:
#
#   store >  512  the dashboard's agent detail vanishes wholesale
#                 ($RunState::MAX_DISPATCH_RECORDS, plugins/sandbox/scripts/
#                 RunState.pm -- an unbounded per-tick read is its own hazard,
#                 so standing aside is the correct LOCAL decision)
#   store > 2000  track-dispatch.sh stops recording entirely (its own bounded
#                 scan cap; standing aside over-cap is likewise correct locally)
#
# Neither cap is wrong. Both are the right answer to an unbounded store -- which
# is why the fix belongs HERE, in the thing that grows. With retention in place
# neither threshold is ever approached, and an operator never has to notice that
# agent rows quietly stopped appearing.
#
# WHY ONLY THE *LIVE* RECORDS ARE PROTECTED. A merely-STALE `running` record
# must be prunable: unfinished `running` records are the entire population that
# fills this directory, so protecting all of them would make retention a no-op
# that looks like a fix. is_live (running AND inside 4x its own budget) is
# protected unconditionally, whatever the count -- that is precisely what the
# dashboard is rendering right now, and what the hook's 120s dedup window
# matches against. Everything else is history, and history is what we trim.

# $RETENTION_KEEP -- how many non-live records survive a prune. Deliberately
# well under the 512 reader cap rather than merely under the 2000 writer cap:
# the panel this telemetry exists to feed goes blank at the LOWER number, so
# sizing to the higher one would leave the visible failure in place.
our $RETENTION_KEEP = 256;

# $RETENTION_HIGH_WATER -- prune only once the store exceeds this. Hysteresis,
# not decoration: with no gap between trigger and target, every `start` past the
# line would re-scan and re-sort the whole directory to delete a single file.
# With it, the full pass runs once per (HIGH_WATER - KEEP) dispatches.
our $RETENTION_HIGH_WATER = 320;

# $READER_CAP mirrors $RunState::MAX_DISPATCH_RECORDS (plugins/sandbox/scripts/
# RunState.pm). Duplicated across a plugin boundary on purpose -- butler must not
# load a sandbox module in order to write a log -- and the duplication is
# guarded: butler t/182 reads RunState.pm and fails if the two ever drift apart.
our $READER_CAP = 512;

# prune_plan(\@entries, $now, $keep) -> \@ids_to_delete -- PURE.
#
# @entries is [ { id => $id, rec => \%rec|undef }, ... ]. Three classes:
#
#   NOT OURS    rec is not a hash, or carries no worker_type. Left alone
#               entirely. `start` requires --worker-type, so every record this
#               writer has ever produced has one; anything else in the directory
#               is a foreign file, and deleting it would be this function
#               exceeding its remit.
#   PROTECTED   is_live -- never returned, at any count.
#   PRUNABLE    everything else, newest-first by started_at; the first $keep
#               survive and the rest are returned.
#
# A record whose started_at is absent or non-numeric sorts as OLDEST (key -1)
# rather than being skipped: `elapsed` and `list` both already refuse to
# evaluate such a record, so it informs no consumer and is the first thing that
# should go. Ties break on id ascending, so the plan is deterministic for a
# given input -- a prune that depended on readdir order would be untestable.
sub prune_plan {
    my ($entries, $now, $keep) = @_;
    $keep = $RETENTION_KEEP unless defined $keep && looks_like_number($keep) && $keep >= 0;
    my @prunable;
    for my $e (@{ $entries || [] }) {
        next unless ref $e eq 'HASH' && defined $e->{id};
        my $rec = $e->{rec};
        next unless ref $rec eq 'HASH' && defined $rec->{worker_type};   # not ours
        next if is_live($rec, $now);                                     # protected
        my $key = (defined $rec->{started_at} && looks_like_number($rec->{started_at}))
                ? $rec->{started_at} + 0 : -1;
        push @prunable, { id => $e->{id}, key => $key };
    }
    my @sorted = sort { $b->{key} <=> $a->{key} || $a->{id} cmp $b->{id} } @prunable;
    return [] unless @sorted > $keep;
    return [ map { $_->{id} } @sorted[ $keep .. $#sorted ] ];
}

# $ALARM_MAX_BYTES / alarm_path / note_alarm -- the report's point (c).
#
# A cap that is hit silently is a permanent stop nobody can discover. Retention
# should mean neither cap is ever reached, so a line in this file means
# retention ITSELF failed -- which is exactly the moment the evidence has to
# already be on disk rather than inferable. The file is not named *.json, so it
# is invisible to list_records, to the hook's scan, and to its own count.
#
# Truncated (not rotated) past 64 KiB: this file exists to be found, not to
# become the next unbounded thing in a directory that is here because something
# grew without bound.
our $ALARM_MAX_BYTES = 64 * 1024;
sub alarm_path { return log_dir($_[0]) . '/retention-alarm.log' }
sub note_alarm {
    my ($root, $msg, $now) = @_;
    return 0 unless defined $msg && length $msg;
    _mkdir_p(log_dir($root)) or return 0;
    my $p    = alarm_path($root);
    my $size = (-f $p) ? (-s $p) : 0;
    my $mode = (defined $size && $size > $ALARM_MAX_BYTES) ? '>' : '>>';
    open my $fh, $mode, $p or return 0;
    $msg =~ s/\s+/ /g;
    print {$fh} (defined $now ? $now : time) . " $msg\n";
    close $fh;
    return 1;
}

# prune_records($root, $now, %opt) -> \%summary -- IMPURE. opt: keep, force.
#
# Best-effort by contract: every failure path degrades to "pruned fewer than
# hoped", never to an error a caller must handle. `start`'s job is to record a
# dispatch; retention riding along must not be able to fail it.
#
# Also sweeps ORPHANED LOCK FILES. BpWrite::guarded_write leaves a
# "$id.json.lock" beside every record it writes and nothing removed those
# either. They are invisible to list_records and to the hook (neither matches
# *.json.lock) so they never counted toward any cap -- but they are half of
# every readdir this directory serves, and a lock whose record is gone protects
# nothing.
sub prune_records {
    my ($root, $now, %opt) = @_;
    $now = time unless defined $now;
    my $keep = (defined $opt{keep} && looks_like_number($opt{keep}) && $opt{keep} >= 0)
             ? int($opt{keep}) : $RETENTION_KEEP;
    my $dir  = log_dir($root);
    my $ids  = list_records($root);
    my %sum  = (scanned => scalar(@$ids), pruned => 0, locks => 0, failed => 0, skipped => 0);

    unless ($opt{force} || @$ids > $RETENTION_HIGH_WATER) {
        $sum{skipped}   = 1;
        $sum{remaining} = $sum{scanned};
        return \%sum;
    }

    my @entries = map { { id => $_, rec => read_record($root, $_) } } @$ids;
    my $doomed  = prune_plan(\@entries, $now, $keep);
    for my $id (@$doomed) {
        if (unlink "$dir/$id.json") { $sum{pruned}++ } else { $sum{failed}++ }
        $sum{locks}++ if unlink "$dir/$id.json.lock";
    }

    # Orphaned locks left by earlier runs: records pruned by hand, or writes
    # that never produced a record at all.
    if (opendir my $dh, $dir) {
        for my $f (readdir $dh) {
            next unless $f =~ /^(.+\.json)\.lock\z/;
            next if -e "$dir/$1";
            $sum{locks}++ if unlink "$dir/$f";
        }
        closedir $dh;
    }

    $sum{remaining} = $sum{scanned} - $sum{pruned};
    if ($sum{remaining} > $READER_CAP) {
        note_alarm($root, "retention ran but the store still holds $sum{remaining} records, "
                        . "over the $READER_CAP reader cap, so the dashboard is rendering no "
                        . "agent detail. Either too many records are LIVE to prune, or unlink "
                        . "is failing ($sum{failed} failures this pass).", $now);
    }
    return \%sum;
}

# _norm_attr($v) -- PURE. undef if $v is undef, JSON null (already undef by
# the time it reaches Perl) or an empty string; the value verbatim otherwise.
# The exact collapse attribution() already applies to blueprint/package/role,
# generalised here for resolve_plan's criteria matching (worker_type is
# never optional there, but blueprint/package/dispatch_key all are).
sub _norm_attr {
    my ($v) = @_;
    return undef unless defined $v && length $v;
    return $v;
}

# resolve_plan(\@entries, \%crit) -> $id | undef -- PURE (§2.4).
#
# @entries is [ { id => $id, rec => \%rec|undef }, ... ], the same shape
# prune_plan takes. %crit keys: worker_type (required to match anything),
# blueprint, package, dispatch_key (each optional). No warnings on any
# input, including non-hash entries and hand-edited records -- every access
# below is guarded by a `ref eq 'HASH'`/`defined` check before use.
#
# fixbatch (MF-1/MEDIUM-3, revert): attribution matching is UNCONDITIONAL --
# norm(rec.X) eq_or_both_undef norm(crit.X) for both blueprint and package,
# with no `exists` gate. Spec-literal (§2.4). track-dispatch.sh's start and
# completion halves derive BPTOK/PKGTOK identically from the same
# BP_BLUEPRINT/BP_PACKAGE env vars, so when unset BOTH halves omit the key --
# the record carries no `blueprint`/`package` field and neither does crit,
# so strict eq_or_both_undef (both undef) still matches. The `exists` gate
# solved a problem the hook's own real usage never has, while opening a
# genuine cross-blueprint steal-close bug (MF-1/MEDIUM-3 in review).
#
# Two-tier selection: tier1 is an EXACT dispatch_key match; tier2 is every
# candidate with NO dispatch_key at all (the pre-this-change / no-key-given
# fallback). tier1 wins whenever it is non-empty. [Amended post-redteam,
# HIGH-2] tier2 is reached ONLY when the CALLER supplied no dispatch_key at
# all (crit.dispatch_key undef) -- a resolve call that DID supply a key and
# found no tier1 match returns undef outright, never falling through to
# steal-close an unrelated keyless record. Within the chosen tier, FIFO:
# oldest started_at first (absent/non-numeric sorts as -1, oldest --
# prune_plan's own convention), ties broken by id ascending for a
# deterministic result.
sub resolve_plan {
    my ($entries, $crit) = @_;
    $crit ||= {};
    my $wt = $crit->{worker_type};
    return undef unless defined $wt;

    my $cb = _norm_attr($crit->{blueprint});
    my $cp = _norm_attr($crit->{package});
    my $ck = _norm_attr($crit->{dispatch_key});

    my @candidates;
    for my $e (@{ $entries || [] }) {
        next unless ref $e eq 'HASH' && defined $e->{id};
        my $rec = $e->{rec};
        next unless ref $rec eq 'HASH';
        next unless defined $rec->{status} && $rec->{status} eq 'running';
        next unless defined $rec->{worker_type} && $rec->{worker_type} eq $wt;

        my $rb = _norm_attr($rec->{blueprint});
        next unless (!defined $rb && !defined $cb) || (defined $rb && defined $cb && $rb eq $cb);
        my $rp = _norm_attr($rec->{package});
        next unless (!defined $rp && !defined $cp) || (defined $rp && defined $cp && $rp eq $cp);

        push @candidates, { id => $e->{id}, rec => $rec };
    }

    my @tier1 = grep {
        my $rk = _norm_attr($_->{rec}{dispatch_key});
        defined $rk && defined $ck && $rk eq $ck
    } @candidates;
    my @tier2 = grep { !defined _norm_attr($_->{rec}{dispatch_key}) } @candidates;
    my @chosen = @tier1 ? @tier1 : (defined $ck ? () : @tier2);
    return undef unless @chosen;

    my @sorted = sort {
        my $ak = (defined $a->{rec}{started_at} && looks_like_number($a->{rec}{started_at}))
               ? $a->{rec}{started_at} + 0 : -1;
        my $bk = (defined $b->{rec}{started_at} && looks_like_number($b->{rec}{started_at}))
               ? $b->{rec}{started_at} + 0 : -1;
        $ak <=> $bk || $a->{id} cmp $b->{id}
    } @chosen;
    return $sorted[0]{id};
}

# ratio_thresholds() -> \%thresh -- PURE apart from reading %ENV and warning
# on stderr. Same validation convention as _ctx_ceiling_env/
# _min_relaunch_secs elsewhere in this family: an UNSET env var is quiet (not
# a mistake); a SET-but-malformed one falls back to the default and warns,
# naming the offending value, one logical sentence, stderr only. Never falls
# back to 0 -- an absent/garbage threshold must not make the gate trivially
# easy to cross.
sub ratio_thresholds {
    my %out;
    for my $k (qw(min_calls min_ratio)) {
        my $env = $RATIO_ENV{$k};
        unless (exists $ENV{$env}) {
            $out{$k} = $RATIO_DEFAULT{$k};
            next;
        }
        my $raw = $ENV{$env} // '';
        if ($raw =~ /^[0-9]+$/ && $raw > 0) {
            $out{$k} = $raw + 0;
        } else {
            warn "bp-dispatch-log: $env='$raw' is not a positive integer -- falling back to the default ($RATIO_DEFAULT{$k}).\n";
            $out{$k} = $RATIO_DEFAULT{$k};
        }
    }
    return \%out;
}

# scan_transcript_counts($path [, $max_lines]) -> \%counts | undef -- READER.
# The one bounded pass over the transcript (spec §2.3). undef (never a
# zeroed hash) when $path is undef/empty/a directory or cannot be opened --
# "not measured" must never render as "measured zero". Coordinator-owned
# records only (no parent_tool_use_id -- D-B, the whole point of this file).
# Deduped by tool_use id, or by (line, position) when a block carries none.
#
# fixbatch (review M-1): the dispatch tool is serialized into a real
# `bp-launch.sh` (--output-format stream-json) transcript as "Agent", never
# "Task" -- measured against real transcripts on disk, zero "name":"Task"
# matches anywhere. Both names are counted as a dispatch (`counts{tasks}`)
# so this reader matches the tool this system actually emits, not only the
# one the original spec pseudocode assumed.
sub scan_transcript_counts {
    my ($path, $max_lines) = @_;
    return undef unless defined $path && length $path;
    return undef if -d $path;
    $max_lines = $RATIO_MAX_LINES
        unless defined $max_lines && $max_lines =~ /^[0-9]+$/ && $max_lines > 0;
    open my $fh, '<:raw', $path or return undef;
    my %counts = (bash => 0, read => 0, edit => 0, grep => 0, self => 0,
                  tasks => 0, lines => 0, truncated => 0);
    my %seen;
    while (my $line = <$fh>) {
        # fixbatch (review N-2): the bound check runs BEFORE the increment, so
        # `lines` reflects exactly the count of lines examined -- a
        # `$max_lines` of 10 leaves `lines == 10`, not 11.
        if ($counts{lines} >= $max_lines) { $counts{truncated} = 1; last }
        $counts{lines}++;
        next if length($line) > $RATIO_MAX_LINE_BYTES;   # never decode an unbounded line
        next unless $line =~ /"name"\s*:\s*"(?:Bash|Read|Edit|Grep|Task|Agent)"/;   # cheap prefilter
        my $rec = eval { JSON::PP->new->decode($line) };
        next unless ref $rec eq 'HASH';
        next unless defined $rec->{type} && $rec->{type} eq 'assistant';
        next if defined $rec->{parent_tool_use_id};   # the coordinator/worker split (D-B)
        my $msg = $rec->{message};
        next unless ref $msg eq 'HASH';
        my $content = $msg->{content};
        next unless ref $content eq 'ARRAY';
        for my $i (0 .. $#$content) {
            my $b = $content->[$i];
            next unless ref $b eq 'HASH';
            next unless defined $b->{type} && $b->{type} eq 'tool_use';
            next unless defined $b->{name} && !ref $b->{name};
            my $key = (defined $b->{id} && !ref $b->{id} && length $b->{id})
                    ? "id:" . $b->{id}
                    : "pos:" . $counts{lines} . ":" . $i;
            next if $seen{$key}++;   # count each tool_use ONCE
            if    ($b->{name} eq 'Task' || $b->{name} eq 'Agent') { $counts{tasks}++ }
            elsif ($b->{name} eq 'Bash') { $counts{bash}++; $counts{self}++ }
            elsif ($b->{name} eq 'Read') { $counts{read}++; $counts{self}++ }
            elsif ($b->{name} eq 'Edit') { $counts{edit}++; $counts{self}++ }
            elsif ($b->{name} eq 'Grep') { $counts{grep}++; $counts{self}++ }
        }
    }
    close $fh;
    return \%counts;
}

# ratio_verdict(\%counts, $recorded, \%thresh) -> \%v -- PURE, no I/O, no
# warnings on any input including undef and non-hashrefs (spec §2.4). D-D:
# the LARGER of the transcript's own Task count and the store's recorded
# total wins as the denominator -- over-reporting dispatches can only
# suppress the nudge. The gate is integer multiplication compared to self,
# never a division compared to a float, so the boundary is exact.
sub ratio_verdict {
    my ($counts, $recorded, $thresh) = @_;
    return { verdict => 'unknown' } unless ref $counts eq 'HASH';
    my $self  = $counts->{self}  // 0;
    my $tasks = $counts->{tasks} // 0;

    # fixbatch (review SHOULD-3): §2.4 promises "no I/O, no warnings on any
    # input including undefs and non-hashrefs" -- the guard previously
    # covered $counts only. A non-hashref/incomplete $thresh must default
    # from %RATIO_DEFAULT rather than warn (and, worse, let
    # `$self >= undef` evaluate as `$self >= 0`, true -- turning a missing
    # threshold into a false "imbalance").
    my $min_calls = (ref $thresh eq 'HASH' && looks_like_number($thresh->{min_calls}))
                   ? $thresh->{min_calls} + 0 : $RATIO_DEFAULT{min_calls};
    my $min_ratio = (ref $thresh eq 'HASH' && looks_like_number($thresh->{min_ratio}))
                   ? $thresh->{min_ratio} + 0 : $RATIO_DEFAULT{min_ratio};

    # A non-numeric $recorded must not warn or participate in the `>`
    # comparison -- treat it the same as "absent".
    $recorded = undef unless defined $recorded && looks_like_number($recorded);

    my $den = $tasks;
    $den = $recorded if defined $recorded && $recorded > $den;
    my $eff = $den < 1 ? 1 : $den;   # never divide by zero
    my $ratio = $self / $eff;
    my $verdict = ($self >= $min_calls && $self >= $min_ratio * $eff)
                ? 'imbalance' : 'proportional';
    return { verdict => $verdict, denominator => $den, effective => $eff, ratio => $ratio };
}

# dispatch_totals($root, \%crit) -> \%totals -- READER (spec §2.5). Counts
# dispatch RECORDS (any status) matching optional blueprint/package criteria,
# using the SAME filter semantics `outstanding` already uses (_norm_attr): an
# omitted criterion does not filter, a supplied one requires the record's own
# value to equal it exactly -- a record missing the field never matches a
# supplied criterion. history.jsonl is deliberately never read (it carries no
# id and no attribution -- spec §2.5's own reasoning). An absent store
# directory is an EMPTY store (readable=>1, zero counts) and creates nothing;
# a path that exists but cannot be opened as a directory is genuinely
# unreadable (readable=>0, every count undef).
sub dispatch_totals {
    my ($root, $crit) = @_;
    $crit ||= {};
    my $dir = log_dir($root);
    my %totals = (readable => 1, total => 0, running => 0, closed => 0, unreadable => 0);
    my $cb = _norm_attr($crit->{blueprint});
    my $cp = _norm_attr($crit->{package});
    if (opendir my $dh, $dir) {
        for my $f (readdir $dh) {
            next unless $f =~ /^(.+)\.json\z/;
            my $id  = $1;
            my $rec = read_record($root, $id);
            unless (ref $rec eq 'HASH') {
                $totals{total}++;
                $totals{unreadable}++;
                next;
            }
            if (defined $cb) {
                my $rb = _norm_attr($rec->{blueprint});
                next unless defined $rb && $rb eq $cb;
            }
            if (defined $cp) {
                my $rp = _norm_attr($rec->{package});
                next unless defined $rp && $rp eq $cp;
            }
            $totals{total}++;
            (defined $rec->{status} && $rec->{status} eq 'running')
                ? $totals{running}++ : $totals{closed}++;
        }
        closedir $dh;
    } elsif (-e $dir) {
        $totals{readable} = 0;
        $totals{total}    = undef;
        $totals{running}  = undef;
        $totals{closed}   = undef;
    }
    return \%totals;
}

package main;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();
use Scalar::Util qw(looks_like_number);

my $MAIN_DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
# fixbatch step7 / MEDIUM-3: BpWrite::guarded_write -- required LAZILY, only
# by the two commands that actually call it (start; resolve, via
# _close_record's use_guard path), not at module-load time. A query verb
# has no business requiring a writer dependency it never invokes: `ratio`
# (03-dispatch-discipline-enforcement), `list`, `elapsed`, `outstanding` and
# `finish` (which closes a record via a bare write_record, not the guard)
# never call BpWrite at all, so loading it unconditionally would give every
# one of them a hard dependency on a module none of them use.

# fixbatch 02-redteam / M1: \z, not $ -- in Perl, $ matches BEFORE a
# trailing newline, so "..\n" matches this class AND is not eq '..',
# defeating both halves of the :348 guard below (and, independently,
# loosening what --id itself accepts at :337+). \z anchors to the true end
# of the string, no exception.
my $ID_RE = qr/^[A-Za-z0-9._-]+\z/;

sub usage_error {
    my ($msg) = @_;
    print STDERR "bp-dispatch-log: usage error: $msg\n";
    exit 2;
}

# _close_record($root, $id, \%rec, $status, $now, \%opt) -> \%result -- the
# ONE mutation both `finish` and `resolve` apply (§2.5: "resolve and finish
# must share one implementation of that mutation; two copies of it would
# drift"). \%rec is the record as READ FROM DISK; nothing is mutated on it,
# and write_record is never called, until every re-validation below has
# passed -- so a refusal leaves the on-disk record byte-identical (H2d,
# extended here to dispatch_key).
#
# \%opt: report, note (both optional, passed through verbatim).
#
# Returns a hash with:
#   ok            => 1 on success, '' on any refusal/failure
#   field_error   => set (only on failure) when a record field's shape was
#                    the reason -- the caller wraps it in usage_error() and
#                    prepends which command refused, mirroring `start`'s own
#                    "--opt 'val' has an invalid shape" phrasing
#   id, duration  => set on success; duration is undef when the record had
#                    no usable started_at (still closed, per H2b)
#   warn          => set (only on success) when duration/history were
#                    skipped for that reason -- caller decides how/whether
#                    to surface it
#   history_failed=> true if append_history failed on an otherwise-ok close
sub _close_record {
    my ($root, $id, $rec, $status, $now, $opt) = @_;
    $opt ||= {};

    # fixbatch 02-redteam / H2d, extended: a SECOND writer of the
    # attribution fields `start` validates must not re-persist an
    # unvalidated (e.g. hand-edited) value verbatim -- refuse loudly
    # instead, naming the field, before ANYTHING is written.
    for my $f (qw(blueprint package)) {
        my $v = $rec->{$f};
        next unless defined $v;
        if ($v !~ $ID_RE || $v eq '.' || $v eq '..') {
            return { ok => '', field_error => "record field '$f' ('$v') has an invalid shape "
                . "-- refusing to re-persist an unvalidated attribution value" };
        }
    }
    if (defined $rec->{role} && !BpDispatchLog::role_is_valid($rec->{role})) {
        return { ok => '', field_error => "record field 'role' ('$rec->{role}') must be one of: "
            . join(', ', @BpDispatchLog::ROLES)
            . " -- refusing to re-persist an unvalidated attribution value" };
    }
    if (defined $rec->{dispatch_key}) {
        my $v = $rec->{dispatch_key};
        if ($v !~ /^[a-z0-9-]{1,48}\z/) {
            return { ok => '', field_error => "record field 'dispatch_key' ('$v') has an invalid shape "
                . "-- refusing to re-persist an unvalidated attribution value" };
        }
    }

    # H2b: a record with no usable started_at must not have a duration
    # FABRICATED via `$now - undef`. Still close it -- stranding it as
    # `running` forever is worse -- but neither a duration_seconds nor a
    # history.jsonl line.
    my $has_duration = defined $rec->{started_at} && looks_like_number($rec->{started_at});
    my $duration;
    my $warn;
    if ($has_duration) {
        $duration = BpDispatchLog::elapsed_seconds($rec->{started_at}, $now);
    } else {
        $warn = "record for '$id' has no usable started_at -- closing it without a duration_seconds "
              . "and without appending a history.jsonl line";
    }

    $rec->{status}   = $status;
    $rec->{ended_at} = $now;
    $rec->{duration_seconds} = $duration      if defined $duration;
    $rec->{report}           = $opt->{report} if defined $opt->{report};
    $rec->{note}             = $opt->{note}   if defined $opt->{note};

    # fixbatch MEDIUM-4: `resolve` (never `finish`, a single administrative
    # call) routes the actual write through BpWrite::guarded_write -- the
    # same race-safe lock -> re-read-under-lock -> validate -> write
    # primitive `start` already uses (comment above, :822-832). Two racing
    # PostToolUse hooks (e.g. an L1-collapsed dispatch pair's two
    # completions) could otherwise both pass this function's own
    # already-in-hand $rec, both compute a duration, and both append a
    # history.jsonl line for the same close. The `valid` callback re-checks,
    # UNDER THE LOCK, that the record is still 'running' -- if something else
    # already closed it between our caller's read and this write, we refuse
    # rather than double-close and double-append.
    if ($opt->{use_guard}) {
        my $path    = BpDispatchLog::record_path($root, $id);
        my $encoded = JSON::PP->new->canonical->encode($rec);
        my $result  = BpWrite::guarded_write({
            site  => 'bp-dispatch-log.resolve',
            path  => $path,
            valid => sub {
                my ($raw) = @_;
                return "no record exists for '$id' to close" unless defined $raw && length $raw;
                my $cur = eval { JSON::PP->new->decode($raw) };
                return "record for '$id' is no longer 'running' -- already closed by a concurrent resolve"
                    unless ref $cur eq 'HASH' && defined $cur->{status} && $cur->{status} eq 'running';
                return undef;
            },
            mutate => sub { return $encoded; },
        });
        return { ok => '' } unless $result->{ok};
    } else {
        BpDispatchLog::write_record($root, $rec) or return { ok => '' };
    }

    # Only a COMPLETED `done` dispatch with a real duration contributes to
    # the median (interrupted/killed are not representative; an unevaluable
    # duration is not representative of anything).
    my $history_failed = '';
    if ($status eq 'done' && defined $duration) {
        BpDispatchLog::append_history($root, {
            worker_type      => $rec->{worker_type},
            duration_seconds => $duration,
            ended_at         => $now,
        }) or $history_failed = 1;
    }

    return { ok => 1, id => $id, duration => $duration, warn => $warn, history_failed => $history_failed };
}

unless (caller) {
    my $cmd = shift @ARGV // '';
    require "$MAIN_DIR/bp-write-guard.pl" if $cmd eq 'start' || $cmd eq 'resolve';
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
        elsif ($a eq '--dispatch-key')   { $o{dispatch_key}    = shift @ARGV }
        elsif ($a eq '--keep')           { $o{keep}            = shift @ARGV }
        elsif ($a eq '--force')          { $o{force}           = 1 }
        elsif ($a eq '--transcript')     { $o{transcript}      = shift @ARGV }
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

    # fixbatch MEDIUM-6: --worker-type reaches `outstanding`'s line-oriented
    # stdout unvalidated otherwise, so a maliciously-named worker_type (e.g.
    # containing an embedded newline) could inject a fake extra line (a
    # forged "outstanding_count: 0"). Held to the SAME shape guard as --id/
    # --blueprint/--package, on every verb that accepts it (start, resolve,
    # outstanding all parse it the same way above).
    usage_error("--worker-type '$o{worker_type}' has an invalid shape")
        if defined $o{worker_type} && $o{worker_type} !~ $ID_RE;

    # --role must be a member of the closed vocabulary (D6) — mirrors the
    # existing --status guard exactly.
    usage_error("--role '$o{role}' must be one of: "
               . join(', ', @BpDispatchLog::ROLES))
        if defined $o{role} && !BpDispatchLog::role_is_valid($o{role});

    # Attribution options are meaningful only on `start` (spec 2.4) — any of
    # --blueprint/--package/--role on another command is a usage error
    # naming the offending option and the word 'start'.
    #
    # §2.3 widens --blueprint/--package alone to `resolve` (query criteria)
    # and `outstanding` (filter criteria) — strictly widening, and scoped so
    # every OTHER command's behavior does not move. --role stays start-only,
    # unchanged: neither new verb ever writes a role.
    if ($cmd ne 'start' && $cmd ne 'resolve' && $cmd ne 'outstanding' && $cmd ne 'ratio') {
        for my $opt (qw(blueprint package)) {
            usage_error("--$opt is only valid with the start command")
                if defined $o{$opt};
        }
    }
    if ($cmd ne 'start') {
        usage_error("--role is only valid with the start command")
            if defined $o{role};
    }

    # §2.3: --dispatch-key is new. Accepted on `start` (stamps the record)
    # and `resolve` (query criteria) only; the shape guard is the same one
    # the record field itself is held to (§2.2).
    if (defined $o{dispatch_key}) {
        usage_error('--dispatch-key is only valid with the start or resolve command')
            if $cmd ne 'start' && $cmd ne 'resolve';
        usage_error("--dispatch-key '$o{dispatch_key}' has an invalid shape")
            if $o{dispatch_key} !~ /^[a-z0-9-]{1,48}\z/;
    }

    # --keep / --force are retention options and belong to `prune` alone --
    # the same shape as the start-only guard above, for the same reason: an
    # option silently ignored on the wrong command is how a caller comes to
    # believe it asked for something it did not.
    if ($cmd ne 'prune') {
        for my $opt (qw(keep force)) {
            usage_error("--$opt is only valid with the prune command")
                if defined $o{$opt};
        }
    }
    usage_error("--keep '$o{keep}' must be a non-negative integer")
        if defined $o{keep} && $o{keep} !~ /^\d+\z/;

    # §2.6: --transcript is new, accepted on `ratio` only -- a path is
    # attacker-shaped text in a line-oriented protocol (MEDIUM-6), so its
    # value is validated here (shape only, never printed) and never echoed
    # on stdout by any verb.
    if (defined $o{transcript}) {
        usage_error('--transcript is only valid with the ratio command')
            if $cmd ne 'ratio';
        usage_error('--transcript must name a path')
            unless length $o{transcript};
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
        # error surfaced to either caller. Unlike butler-hold's accepted
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
        my $dispatch_key = $o{dispatch_key};
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
                $rec->{dispatch_key} = $dispatch_key if defined $dispatch_key;
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
        # Retention rides on `start` because `start` is the only thing that
        # grows the store (bug 20260908-225444-b9db). Gated by its own
        # high-water mark, so the common call costs one extra readdir and
        # nothing else; the full read-and-sort pass runs about once per
        # (HIGH_WATER - KEEP) dispatches. Wrapped in eval and its result
        # ignored on failure: recording the dispatch is this command's job,
        # trimming history is housekeeping, and housekeeping must never be
        # able to fail the job.
        my $trim = eval { BpDispatchLog::prune_records($root, $now) } || {};
        if (($trim->{pruned} || 0) > 0) {
            print STDERR "bp-dispatch-log: retention pruned $trim->{pruned} record(s) and "
                       . "$trim->{locks} stale lock file(s); $trim->{remaining} remain\n";
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
    elsif ($cmd eq 'prune') {
        # Explicit prune: always does the full pass. `start`'s automatic call
        # is gated on the high-water mark because it runs on every dispatch;
        # an operator who typed `prune` has already made that decision.
        my $trim = BpDispatchLog::prune_records($root, $now,
                                                keep => $o{keep}, force => 1);
        print "scanned: $trim->{scanned}\n";
        print "pruned: $trim->{pruned}\n";
        print "locks_removed: $trim->{locks}\n";
        print "remaining: $trim->{remaining}\n";
        print "unlink_failures: $trim->{failed}\n";
        exit($trim->{failed} ? 4 : 0);
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

        my $result = _close_record($root, $o{id}, $rec, $o{status}, $now,
                                    { report => $o{report}, note => $o{note} });
        unless ($result->{ok}) {
            usage_error("finish: $result->{field_error}") if defined $result->{field_error};
            print STDERR "bp-dispatch-log: could not write record for '$o{id}'\n";
            exit 4;
        }
        print STDERR "bp-dispatch-log: warning: $result->{warn}\n" if $result->{warn};
        if ($result->{history_failed}) {
            print STDERR "bp-dispatch-log: could not append history for '$o{id}'\n";
            exit 4;
        }
        print "finished $o{id} (status=$o{status} duration_seconds="
            . (defined $result->{duration} ? $result->{duration} : 'unknown') . ")\n";
        exit 0;
    }
    elsif ($cmd eq 'resolve') {
        usage_error('--worker-type is required') unless defined $o{worker_type};
        usage_error('--status is required (done|interrupted|killed)') unless defined $o{status};
        usage_error("--status '$o{status}' must be done|interrupted|killed")
            unless $o{status} =~ /^(done|interrupted|killed)\z/;

        my $ids = BpDispatchLog::list_records($root);
        my @entries = map { { id => $_, rec => BpDispatchLog::read_record($root, $_) } } @$ids;
        my %crit = (worker_type => $o{worker_type});
        $crit{blueprint}    = $o{blueprint}    if defined $o{blueprint};
        $crit{package}      = $o{package}      if defined $o{package};
        $crit{dispatch_key} = $o{dispatch_key} if defined $o{dispatch_key};

        my $id = BpDispatchLog::resolve_plan(\@entries, \%crit);
        unless (defined $id) {
            print 'NO-MATCH: no running record matched worker_type=' . $o{worker_type}
                . ' package=' . (defined $o{package} ? $o{package} : '-')
                . ' dispatch_key=' . (defined $o{dispatch_key} ? $o{dispatch_key} : '-') . "\n";
            exit 5;
        }

        # fixbatch MEDIUM-4: re-check, right before closing, that the record
        # resolve_plan selected is STILL 'running' -- something else (a
        # racing resolve, an L1-collapsed dispatch's other completion) may
        # already have closed it between the scan above and here. Not
        # running any more is treated the same as never having matched:
        # NO-MATCH, exit 5, never a silent double-close.
        my $rec = BpDispatchLog::read_record($root, $id);
        unless (ref $rec eq 'HASH' && defined $rec->{status} && $rec->{status} eq 'running') {
            print 'NO-MATCH: no running record matched worker_type=' . $o{worker_type}
                . ' package=' . (defined $o{package} ? $o{package} : '-')
                . ' dispatch_key=' . (defined $o{dispatch_key} ? $o{dispatch_key} : '-') . "\n";
            exit 5;
        }

        my $result = _close_record($root, $id, $rec, $o{status}, $now,
                                    { report => $o{report}, note => $o{note}, use_guard => 1 });
        unless ($result->{ok}) {
            usage_error("resolve: $result->{field_error}") if defined $result->{field_error};
            print STDERR "bp-dispatch-log: could not write record for '$id'\n";
            exit 4;
        }
        print STDERR "bp-dispatch-log: warning: $result->{warn}\n" if $result->{warn};
        if ($result->{history_failed}) {
            print STDERR "bp-dispatch-log: could not append history for '$id'\n";
            exit 4;
        }
        print "resolved $id (worker_type=$o{worker_type} status=$o{status} duration_seconds="
            . (defined $result->{duration} ? $result->{duration} : 'unknown') . ")\n";
        exit 0;
    }
    elsif ($cmd eq 'ratio') {
        usage_error('--transcript is required') unless defined $o{transcript};
        usage_error('--transcript must name a path') unless length $o{transcript};

        my $thresh = BpDispatchLog::ratio_thresholds();
        my $counts = BpDispatchLog::scan_transcript_counts($o{transcript});

        my %totals_crit;
        $totals_crit{blueprint} = $o{blueprint} if defined $o{blueprint};
        $totals_crit{package}   = $o{package}   if defined $o{package};
        my $totals = BpDispatchLog::dispatch_totals($root, \%totals_crit);
        my $store_readable = (ref $totals eq 'HASH' && $totals->{readable}) ? 1 : 0;
        my $recorded = $store_readable ? $totals->{total} : undef;

        my $v = BpDispatchLog::ratio_verdict($counts, $recorded, $thresh);
        my $have_counts = (ref $counts eq 'HASH') ? 1 : 0;

        my ($self, $bash, $read, $edit, $grep, $disp_t, $trunc, $ratio_str, $disp, $verdict, $summary);
        if ($have_counts) {
            $self   = $counts->{self};
            $bash   = $counts->{bash};
            $read   = $counts->{read};
            $edit   = $counts->{edit};
            $grep   = $counts->{grep};
            $disp_t = $counts->{tasks};
            $trunc  = $counts->{truncated} ? 'true' : 'false';
            $disp      = $v->{denominator};
            $ratio_str = sprintf('%.1f', $v->{ratio});
            $verdict   = $v->{verdict};
            if ($verdict eq 'imbalance') {
                $summary = "$self of the coordinator's own direct tool calls (Bash, Read, Edit, Grep) are recorded in "
                         . "this transcript against $disp dispatch(es), a ratio of about $ratio_str own calls per dispatch, at "
                         . "or above the $thresh->{min_ratio} this check is set to notice; this is a pattern observed in what the "
                         . "stream recorded, not a judgment that any of that work belonged to a worker.";
            } else {
                $summary = "$self own direct tool calls against $disp dispatch(es) were observed, below the ratio this "
                         . "check is set to notice; this reflects what the transcript records, not a guarantee that "
                         . "every step was dispatched.";
            }
        } else {
            $self = $bash = $read = $edit = $grep = $disp_t = $disp = $ratio_str = $trunc = 'unknown';
            $verdict = 'unknown';
            $summary = 'the transcript could not be read, so the ratio of own tool calls to dispatches was not determined.';
        }

        my $disp_r = $store_readable ? $totals->{total} : 'unknown';

        # fixbatch (review SHOULD-4/item 3): an entry that fails to decode as
        # a HASH is counted toward `total`/`unreadable` BEFORE the
        # blueprint/package filters run (spec §2.5, dispatch_totals), so an
        # unrelated corrupt record can inflate a differently-scoped query's
        # denominator while this sentence still claims the count is "scoped
        # to this blueprint and package" -- false when unreadable > 0. Kept
        # §2.5's counting rule intact (the smaller of the review's two
        # options) and instead drop the "scoped" claim from THIS sentence
        # when it would be dishonest; the mandated byte-for-byte sentence is
        # unchanged for the (overwhelmingly common) unreadable == 0 case.
        my $dispatch_note;
        if ($store_readable && $totals->{unreadable}) {
            $dispatch_note = "$disp_r dispatch records are recorded in the dispatch log (running or closed), "
                . "but $totals->{unreadable} of the scanned entries could not be read and are included in "
                . "that count regardless of blueprint/package scope; this reflects what is recorded on disk, "
                . "not a guarantee that each one ran to completion or that the count is accurately scoped.";
        } elsif ($store_readable) {
            $dispatch_note = "$disp_r dispatch records scoped to this blueprint and package are recorded in the dispatch "
                . "log (running or closed); this reflects what is recorded on disk, not a guarantee that "
                . "each one ran to completion.";
        } else {
            $dispatch_note = 'the dispatch log could not be read, so how many dispatches are recorded on disk was not determined.';
        }

        print "self_tool_calls: $self\n";
        print "self_bash_calls: $bash\n";
        print "self_read_calls: $read\n";
        print "self_edit_calls: $edit\n";
        print "self_grep_calls: $grep\n";
        print "dispatches_transcript: $disp_t\n";
        print "dispatches_recorded: $disp_r\n";
        print "dispatches: $disp\n";
        print "ratio: $ratio_str\n";
        print "min_calls: $thresh->{min_calls}\n";
        print "min_ratio: $thresh->{min_ratio}\n";
        print "scan_truncated: $trunc\n";
        print "verdict: $verdict\n";
        print "summary: $summary\n";
        print "dispatch_note: $dispatch_note\n";
        exit 0;
    }
    elsif ($cmd eq 'outstanding') {
        my $dir = BpDispatchLog::log_dir($root);
        my $readable = 1;
        my @ids;
        # fixbatch LOW-2: a QUERY must not create the store as a side effect.
        # Try opendir directly rather than checking -d first and _mkdir_p-ing
        # on miss: a path that does not exist at all is simply an EMPTY store
        # (B9's zero) -- readable stays true, @ids stays empty, nothing is
        # created. A path that DOES exist but cannot be opened as a readable
        # directory (permission denied, or -- as AC18/AC17's fixture plants
        # -- a plain FILE sitting where the store dir would be) is the one
        # case that is genuinely unreadable (B15).
        if (opendir my $dh, $dir) {
            # N-2: duplicates list_records' own opendir/readdir loop rather
            # than calling it, so an unreadable directory can be
            # distinguished from a readable-but-empty one (B15 vs B9) --
            # list_records collapses both to an empty list.
            for my $f (readdir $dh) {
                next unless $f =~ /^(.+)\.json\z/;
                push @ids, $1;
            }
            closedir $dh;
        } elsif (-e $dir) {
            $readable = '';
        }

        unless ($readable) {
            print "outstanding_count: unknown\n";
            print "live_count: unknown\n";
            print "stale_count: unknown\n";
            print "unevaluable_count: unknown\n";
            print "unreadable_count: unknown\n";
            print "summary: the dispatch log could not be read, so whether anything is outstanding "
                . "was not determined.\n";
            exit 4;
        }

        # N-1: reuse the library's own norm() rather than a duplicate closure.
        my $norm = \&BpDispatchLog::_norm_attr;

        my @rows;
        my ($live, $stale, $uneval, $unreadable) = (0, 0, 0, 0);
        for my $id (@ids) {
            my $rec = BpDispatchLog::read_record($root, $id);
            unless (ref $rec eq 'HASH') {
                # fixbatch MEDIUM-5: the *.json file exists (it was in the
                # directory listing) but could not be read/decoded as a JSON
                # object -- dropping it silently would be an UNDER-report
                # (the unsafe direction, per the governing bias: over-report
                # outstanding, never under-report). It cannot be proven NOT
                # outstanding, so it counts, with every other field unknown.
                $unreadable++;
                push @rows, {
                    id => $id, sortkey => -1, worker_type => undef, blueprint => undef,
                    package => undef, dispatch_key => undef, elapsed => undef, stale => 'unknown',
                };
                next;
            }
            next unless defined $rec->{status} && $rec->{status} eq 'running';

            if (defined $o{worker_type}) {
                my $v = $norm->($rec->{worker_type});
                next unless defined $v && $v eq $o{worker_type};
            }
            if (defined $o{blueprint}) {
                my $v = $norm->($rec->{blueprint});
                next unless defined $v && $v eq $o{blueprint};
            }
            if (defined $o{package}) {
                my $v = $norm->($rec->{package});
                next unless defined $v && $v eq $o{package};
            }

            my $evaluable = defined $rec->{started_at} && looks_like_number($rec->{started_at});
            my ($elapsed, $stale_flag);
            if ($evaluable) {
                $elapsed = BpDispatchLog::elapsed_seconds($rec->{started_at}, $now);
                $stale_flag = BpDispatchLog::is_stale($rec, $now) ? 1 : 0;
                $stale_flag ? $stale++ : $live++;
            } else {
                $uneval++;
            }
            push @rows, {
                id           => $id,
                sortkey      => $evaluable ? ($rec->{started_at} + 0) : -1,
                worker_type  => $rec->{worker_type},
                blueprint    => $norm->($rec->{blueprint}),
                package      => $norm->($rec->{package}),
                dispatch_key => $norm->($rec->{dispatch_key}),
                elapsed      => $evaluable ? $elapsed : undef,
                stale        => $evaluable ? ($stale_flag ? 'true' : 'false') : 'unknown',
            };
        }

        my @sorted = sort { $a->{sortkey} <=> $b->{sortkey} || $a->{id} cmp $b->{id} } @rows;
        my $total  = scalar @sorted;

        print "outstanding_count: $total\n";
        print "live_count: $live\n";
        print "stale_count: $stale\n";
        print "unevaluable_count: $uneval\n";
        print "unreadable_count: $unreadable\n";
        for my $r (@sorted) {
            print 'outstanding: id=' . $r->{id}
                . ' worker_type=' . (defined $r->{worker_type} ? $r->{worker_type} : '-')
                . ' blueprint='   . (defined $r->{blueprint}   ? $r->{blueprint}   : '-')
                . ' package='    . (defined $r->{package}      ? $r->{package}     : '-')
                . ' dispatch_key=' . (defined $r->{dispatch_key} ? $r->{dispatch_key} : '-')
                . ' elapsed_seconds=' . (defined $r->{elapsed} ? $r->{elapsed} : 'unknown')
                . " stale=$r->{stale}\n";
        }

        my $summary;
        if ($total == 0) {
            $summary = 'summary: no outstanding dispatch was detected in the dispatch log '
                     . '(0 running records matched); this reflects what is recorded on disk, '
                     . 'not a guarantee that nothing is running.';
        } elsif ($total == 1) {
            $summary = 'summary: 1 dispatch appears to be outstanding (recorded as running, not yet '
                     . 'resolved); this reflects what is recorded on disk, not a guarantee that it is '
                     . 'still alive.';
        } else {
            $summary = "summary: $total dispatches appear to be outstanding (recorded as running, not "
                     . 'yet resolved); this reflects what is recorded on disk, not a guarantee that '
                     . 'they are still alive.';
        }
        print "$summary\n";
        if ($stale > 0) {
            print "note: $stale of them are past 4x their own budget, which may mean the dispatch died "
                . "without its completion being observed; the record stays outstanding rather than "
                . "clearing on age.\n";
        }
        exit($total > 0 ? 1 : 0);
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
  prune   [--keep N] [--root DIR] [--now EPOCH]
  resolve --worker-type <TYPE> --status done|interrupted|killed [--dispatch-key <TOKEN>]
          [--blueprint <NAME>] [--package <NAME>] [--report PATH] [--note TEXT] [--root DIR] [--now EPOCH]
  outstanding [--worker-type <TYPE>] [--blueprint <NAME>] [--package <NAME>] [--root DIR] [--now EPOCH]
  ratio   --transcript <PATH> [--blueprint <NAME>] [--package <NAME>] [--root DIR]

--blueprint / --package are optional, valid with `start`, `resolve`, `outstanding` and `ratio`. --role is optional and valid ONLY with `start`; it is a closed vocabulary of exactly coordinator, worker or judge. --dispatch-key is optional and valid ONLY with `start` (stamps the record) and `resolve` (query criteria); shape /^[a-z0-9-]{1,48}$/. --transcript is required and valid ONLY with `ratio` -- the path to the coordinator's own runs transcript; its value is never printed on stdout.

`ratio` prints self_tool_calls/self_bash_calls/self_read_calls/self_edit_calls/self_grep_calls/dispatches_transcript/dispatches_recorded/dispatches/ratio/min_calls/min_ratio/scan_truncated/verdict/summary/dispatch_note, one bounded scan of --transcript plus one scoped read of the dispatch store, never writes anything. min_calls/min_ratio default to 200/40 (BpDispatchLog::%RATIO_DEFAULT) and are overridable via BP_DISPATCH_RATIO_MIN_CALLS / BP_DISPATCH_RATIO_MIN.

Exit codes: 0 ok · 2 usage error · 3 start refused (a running record already exists for --id) · 4 elapsed/finish/resolve: no record, or the store could not be read/written · 5 resolve: no running record matched the criteria (not an error).

A `running` record is STALE once its elapsed time exceeds 4x its own budget_seconds; `list` marks it `stale: true` but still shows it.

`outstanding`'s stdout prints outstanding_count/live_count/stale_count/unevaluable_count/unreadable_count, in that order, then one `outstanding:` line per counted record. unreadable_count counts a *.json file that exists but failed to parse as a JSON object -- it cannot be proven NOT outstanding, so it is folded into outstanding_count too (with every other field on its `outstanding:` line reported as `-`/unknown); the invariant `live_count + stale_count + unevaluable_count == outstanding_count` holds exactly when unreadable_count is 0, and is short by unreadable_count otherwise.

RETENTION. `start` prunes automatically once the store passes its high-water mark, keeping the 256 most recent non-live records (bug 20260908-225444-b9db -- before this the store only ever grew, and two consumers went silently dark at 512 and at 2000 records). LIVE records are never pruned, whatever the count. `prune` does the same pass on demand, ignoring the high-water gate. If a prune leaves the store still over the 512 reader cap, one line is written to .dispatch-log/retention-alarm.log: a cap reached silently is a permanent stop nobody can discover.
USAGE
        exit 2;
    }
}
1;
