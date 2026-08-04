#!/usr/bin/env perl
# bp-progress.pl — b11-progress-heuristic-turns-backstop: a semantic liveness check
# for a coordinator, returning one of progressing | looping | stuck, each with a
# one-line reason.
#
# WHY THIS EXISTS (spec §0): the two existing signals are the wrong shape.
# BpOrch::progress_verdict measures stream-log BYTE GROWTH — a coordinator firing
# the same command in a loop produces MORE bytes than one thinking carefully, so
# the runaway reads as maximally healthy. BpOrch::snapshot_progressed counts ledger
# checkbox/status changes — a coordinator can do forty turns of genuine work inside
# one pipeline step and register zero progress under that signal. Measured on this
# run: 12 of 27 packages hit error_max_turns at least once; the turn cap was the
# PRIMARY control loop, not a backstop.
#
# THE ASYMMETRY (spec §2 — read twice, it is the opposite of the obvious guess):
# killing a healthy coordinator is far more expensive than letting a looper run one
# more turn. A wrongly-killed coordinator loses its in-flight work AND pays a full
# context re-ingest at cache-WRITE rates on relaunch (cache read+write is 89% of
# measured fleet cost); a looper that survives one extra cadence costs one cadence
# of tokens. So UNCERTAINTY MUST RETURN "progressing" — never looping/stuck. Every
# ambiguous input (unparseable transcript, absent transcript, empty tail,
# unavailable/misconfigured model, an already-held concurrency lock, an internal
# error) resolves to "progressing" with a stated reason and defers to the turn cap.
# This is the OPPOSITE direction from b41-cache-state-tracking's uncertainty-biases-
# cold: there a missed warm resume was the expensive error; here a wrongful kill is.
# Both packages state their direction because "fail safe" is not a fixed direction —
# it is "fail toward the cheaper mistake", and that depends on the decision.
#
# LAYERING (spec §1): hook first (b10's mechanical repeat guard, zero tokens, acts
# at the repeat) -> semantic check second (THIS script, catches varied commands
# going nowhere) -> turn cap last (a backstop, not the control loop). looping/stuck
# act IMMEDIATELY rather than waiting for the cap; reaching the cap anyway means
# THE HEURISTIC FAILED — a distinct, logged condition about the guard, never queued
# as a package failure (b09 drew the same line for judges; this is the coordinator
# equivalent).
#
# TAIL ONLY: transcripts here reach 10,351,554 bytes (b41's measurement). This
# script NEVER slurps one. It reuses BpOrch::_tail_jsonl_objs (bp-orchestrator.pl),
# itself built on _last_nonempty_line's seek-from-end discipline — a second reader
# is the exact divergence this blueprint keeps paying for, so none is written here.
#
# THROTTLED + NEVER-CONCURRENT: the check costs tokens (a model reads the tail), so
# it runs on a cadence (runs/<pkg>.progress-state.json remembers the last verdict)
# and never twice at once for the same package (an atomic O_EXCL lock file at
# runs/<pkg>.progress.lock — a lock already held defers to "progressing" for that
# tick rather than blocking or guessing).
#
# MODEL SEAM: BP_PROGRESS_MODEL_CMD names a shell command. This script writes the
# JSON-encoded transcript tail (an array of decoded jsonl objects) to the command's
# stdin and reads back exactly one "VERDICT\tREASON" line from its stdout. Unset,
# non-executing, or malformed-output all count as the model being UNAVAILABLE, which
# is itself one of the uncertain cases above (-> progressing). NO network, no real
# model call — this seam is what lets the oracle run offline and deterministically.
#
# CLI:
#   bp-progress.pl verdict <bp> <pkg> [--now=EPOCH] [--repeat-flagged=0|1]
#   bp-progress.pl capped  <bp> <pkg> [--now=EPOCH]
#
# <bp>/<pkg> resolve exactly like bp-cache-state.pl's own convention (itself
# mirroring bp-lib.sh's bp_dir/bp_ledger layout):
#   $CCPRAXIS_DATA_DIR/blueprints/<bp>/{packages/<pkg>.md, runs/<pkg>.jsonl,
#                                        runs/registry.json}
#
# `verdict` NEVER dies and ALWAYS exits 0 — classifying is this script's entire
# job, so even a maximally broken input must still produce a verdict line.
#
# `capped` logs a DISTINCT condition (type containing "heuristic") to
# runs/orchestrator.log via the house BpLog::event logger (bp-log.pl, already
# required transitively through bp-orchestrator.pl below) and never touches the
# package's ledger or registry.json — reaching the cap is a signal about the
# guard, not a package failure (spec §2/§3 C7).
#
# require: require "<path>/bp-progress.pl";
#          BpProgress::verdict($root, $bp, $pkg, $now, $repeat_flagged)
#          BpProgress::capped($root, $bp, $pkg, $now)

package BpProgress;
use strict;
use warnings;
use JSON::PP;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use File::Basename qw(dirname);
use Cwd qw(abs_path getcwd);

# Absolute script dir so `require "$DIR/..."` resolves no matter how this script
# is invoked (relative CLI path, absolute, or `require`d from a test) — the same
# convention bp-orchestrator.pl / bp-cache-state.pl already use.
my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });

# Reuse bp-orchestrator.pl's bounded seek-from-end tail reader
# (BpOrch::_tail_jsonl_objs, itself built on _last_nonempty_line's discipline) and,
# transitively, bp-log.pl's BpLog::event — NEITHER is reimplemented here (C4).
require "$DIR/bp-orchestrator.pl";

# ===========================================================================
# Path helpers -- mirror bp-cache-state.pl's _data_dir/_project_root/_runs_dir
# convention exactly (itself bp-lib.sh's bp_dir/bp_ledger convention).
# ===========================================================================
sub _project_root {
    return $ENV{BP_PROJECT_ROOT} if defined $ENV{BP_PROJECT_ROOT} && length $ENV{BP_PROJECT_ROOT};
    my $top = eval { `git rev-parse --show-toplevel 2>/dev/null` };
    $top = '' unless defined $top;
    chomp $top;
    return $top if length $top;
    my $d = getcwd();
    while (defined $d && length $d) {
        return $d if -d "$d/.ccpraxis-local-data";
        my $parent = dirname($d);
        last if $parent eq $d;
        $d = $parent;
    }
    return getcwd();
}

sub _data_dir {
    return $ENV{CCPRAXIS_DATA_DIR} if defined $ENV{CCPRAXIS_DATA_DIR} && length $ENV{CCPRAXIS_DATA_DIR};
    return _project_root() . '/.ccpraxis-local-data';
}

sub _runs_dir { my ($root, $bp) = @_; return "$root/blueprints/$bp/runs" }

# ===========================================================================
# Small on-disk JSON read/write helpers for the throttle-state file. A corrupt
# or missing state file is NEVER fatal — it is treated as "no prior check",
# which only ever makes the NEXT call proceed (never manufactures a verdict).
# ===========================================================================
sub _read_json_file {
    my ($f) = @_;
    return undef unless defined $f && -f $f;
    open my $fh, '<:raw', $f or return undef;
    local $/;
    my $txt = <$fh>;
    close $fh;
    return undef unless defined $txt && length $txt;
    return eval { JSON::PP->new->decode($txt) };
}

sub _write_json_file {
    my ($f, $data) = @_;
    (my $d = $f) =~ s{[\\/][^\\/]+$}{};
    if (length $d && !-d $d) { eval { require File::Path; File::Path::make_path($d) }; }
    my $ok = eval {
        open my $fh, '>:raw', $f or die "open: $!";
        print $fh JSON::PP->new->canonical->encode($data);
        close $fh or die "close: $!";
        1;
    };
    return $ok ? 1 : 0;
}

# ===========================================================================
# Cadence (BP_PROGRESS_CADENCE_SEC, integer seconds, default 300). An explicit
# "0" disables caching (used by fixtures that need every call to hit the seam);
# anything unset/non-numeric falls back to the default (never negative).
# ===========================================================================
sub _cadence_sec {
    my $raw = $ENV{BP_PROGRESS_CADENCE_SEC};
    return 300 unless defined $raw && length $raw;
    return 300 unless $raw =~ /^\d+$/;
    return $raw + 0;
}

# ===========================================================================
# The model seam. $cmd is a shell command (may itself contain quoted args, as
# built by the test's stub or by a real invocation); the transcript tail is fed
# on stdin as JSON, one "VERDICT\tREASON" line is read back from stdout. undef
# on ANY failure (missing cmd, spawn failure, no output) — the caller treats
# undef exactly like an unavailable model (C3d/C3e).
# ===========================================================================
sub _invoke_model {
    my ($cmd, $payload) = @_;
    return undef unless defined $cmd && length $cmd;
    my $out = eval {
        require File::Temp;
        my ($fh, $tmp) = File::Temp::tempfile('bp-progress-inXXXXXX', TMPDIR => 1, UNLINK => 1);
        print {$fh} $payload;
        close $fh;
        my $result = `$cmd <"$tmp" 2>/dev/null`;
        $result;
    };
    return undef if $@;
    return undef unless defined $out && length $out;
    my ($line) = split /\n/, $out, 2;
    return $line;
}

# ===========================================================================
# The actual (costly) semantic check: read the bounded tail, hand it to the
# model seam, classify its answer. Called ONLY once the lock is held and the
# cadence window has elapsed — never directly by callers outside this file.
# ===========================================================================
sub _semantic_check {
    my ($runs, $pkg) = @_;
    my $file = "$runs/$pkg.jsonl";
    my $objs = eval { BpOrch::_tail_jsonl_objs($file) };
    $objs = [] if $@ || ref $objs ne 'ARRAY';
    unless (@$objs) {
        return ('progressing',
            'transcript absent, empty, or unparseable — deferring to the turn cap (C3 uncertainty rule)');
    }

    my $cmd = $ENV{BP_PROGRESS_MODEL_CMD};
    unless (defined $cmd && length $cmd) {
        return ('progressing',
            'model seam unavailable (BP_PROGRESS_MODEL_CMD unset) — deferring to the turn cap');
    }

    my $payload = eval { JSON::PP->new->canonical->encode($objs) };
    $payload = '[]' unless defined $payload;

    my $line = _invoke_model($cmd, $payload);
    unless (defined $line && $line =~ /^(progressing|looping|stuck)\t(.+)\z/) {
        return ('progressing',
            'model seam returned invalid or unparseable output — deferring to the turn cap');
    }
    return ($1, $2);
}

# ===========================================================================
# verdict_from_runs — the public decision. Order of gates, cheapest first:
#   1. b10's repeat signal (--repeat-flagged): "looping", no lock, no model call
#      (C6) — the mechanical guard already did the (free) classification.
#   2. cadence cache: a call inside BP_PROGRESS_CADENCE_SEC of the last real
#      check replays the cached verdict, no model call (C5 "not every tick").
#   3. concurrency lock (runs/<pkg>.progress.lock, acquired via O_EXCL — atomic,
#      no TOCTOU window): a lock already held for this package defers to
#      "progressing" for this tick, no model call (C5 "never concurrently").
#   4. otherwise: the real (costly) check, then the throttle state is updated
#      and the lock released.
# NEVER dies; any internal failure resolves to "progressing" (the uncertainty
# rule applies to the process itself, not just the semantics).
# ===========================================================================
sub verdict_from_runs {
    my ($runs, $pkg, $now, $repeat_flagged) = @_;
    $now = time unless defined $now;

    if ($repeat_flagged) {
        return ('looping',
            "b10's mechanical repeat guard already flagged this package as looping — "
            . 'consuming that signal rather than re-deriving it with a fresh semantic call');
    }

    my $state_path = "$runs/$pkg.progress-state.json";
    my $lock_path  = "$runs/$pkg.progress.lock";
    my $cadence    = _cadence_sec();

    my $state = _read_json_file($state_path);
    if (ref $state eq 'HASH'
        && defined $state->{last_checked_at} && $state->{last_checked_at} =~ /^-?\d+(?:\.\d+)?$/
        && defined $state->{last_verdict}    && $state->{last_verdict} =~ /^(?:progressing|looping|stuck)$/) {
        my $elapsed = $now - $state->{last_checked_at};
        if ($elapsed >= 0 && $elapsed < $cadence) {
            return ($state->{last_verdict}, $state->{last_reason} // 'cached verdict within the cadence window');
        }
    }

    (my $lock_dir = $lock_path) =~ s{[\\/][^\\/]+$}{};
    if (length $lock_dir && !-d $lock_dir) { eval { require File::Path; File::Path::make_path($lock_dir) }; }

    unless (sysopen(my $lfh, $lock_path, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
        return ('progressing',
            'a concurrency lock for this package is already held — deferring rather than checking twice at once');
    } else {
        print {$lfh} "$$\n";
        close $lfh;
    }

    my ($v, $r) = eval { _semantic_check($runs, $pkg) };
    if ($@ || !defined $v || $v !~ /^(?:progressing|looping|stuck)$/) {
        ($v, $r) = ('progressing', 'internal error during the semantic check — deferring to the turn cap');
    }
    $r = 'no reason given' unless defined $r && length $r;

    unlink $lock_path;
    _write_json_file($state_path, { last_checked_at => $now, last_verdict => $v, last_reason => $r });

    return ($v, $r);
}

sub verdict {
    my ($root, $bp, $pkg, $now, $repeat_flagged) = @_;
    return verdict_from_runs(_runs_dir($root, $bp), $pkg, $now, $repeat_flagged);
}

# ===========================================================================
# capped — the turn cap was reached. Per spec §2/§3 C7 this now means "the
# heuristic failed to classify this package before the cap did", a signal
# about the GUARD, not the package: a distinct log event (type contains
# "heuristic"), and it must NEVER touch the package's ledger or registry.json
# (those are the package-failure surfaces; this call writes to neither).
# ===========================================================================
sub capped_from_runs {
    my ($runs, $pkg, $now) = @_;
    $now = time unless defined $now;
    my $log = "$runs/orchestrator.log";
    eval {
        BpLog::event($log, 'progress_heuristic_capped', {
            package => $pkg,
            reason  => 'coordinator reached its turn cap before the semantic progress heuristic reached a '
                     . 'confident looping/stuck verdict — this is a signal about the guard, not a package failure',
        }, $now);
    };
    return 1;
}

sub capped {
    my ($root, $bp, $pkg, $now) = @_;
    return capped_from_runs(_runs_dir($root, $bp), $pkg, $now);
}

# ===========================================================================
# CLI
# ===========================================================================
package main;
use strict;
use warnings;

unless (caller) {
    my ($verb, $bp, $pkg, @rest) = @ARGV;
    my $usage = "usage: bp-progress.pl <verdict|capped> <bp> <pkg> [--now=EPOCH] [--repeat-flagged=0|1]\n";
    unless (defined $verb && $verb =~ /^(?:verdict|capped)$/
            && defined $bp && length $bp && defined $pkg && length $pkg) {
        print STDERR $usage;
        print "progressing\tmissing or malformed CLI arguments\n" if defined $verb && $verb eq 'verdict';
        exit 0;
    }

    my ($now, $repeat_flagged);
    for (@rest) {
        if (/^--now=(\d+)$/)              { $now = $1 + 0; }
        elsif (/^--repeat-flagged=([01])$/) { $repeat_flagged = $1 + 0; }
    }

    my $root = eval { BpProgress::_data_dir() };
    $root = '.' unless defined $root && length $root;

    if ($verb eq 'verdict') {
        my ($v, $r) = eval { BpProgress::verdict($root, $bp, $pkg, $now, $repeat_flagged) };
        if ($@ || !defined $v || $v !~ /^(?:progressing|looping|stuck)$/) {
            ($v, $r) = ('progressing', 'internal error computing verdict — deferring to the turn cap');
        }
        $r = 'no reason given' unless defined $r && length $r;
        $r =~ s/[\t\r\n]+/ /g;
        print "$v\t$r\n";
        exit 0;
    } elsif ($verb eq 'capped') {
        eval { BpProgress::capped($root, $bp, $pkg, $now) };
        exit 0;   # capped is a best-effort log write: never blocks or fails the caller
    }
}
1;
