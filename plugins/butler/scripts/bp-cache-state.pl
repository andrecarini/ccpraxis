#!/usr/bin/env perl
# bp-cache-state.pl — b41-cache-state-tracking: the ONE place that decides whether
# a package's coordinator can be resumed against a warm prompt cache, or must be
# cold-started. This replaces two independent, drifting copies of that policy
# (bp-resume-sweep.sh's `file_age_min "$LEDGER"` and bp-orchestrator.pl's
# ledger-mtime-based resume path) with a single transcript-derived measurement.
#
# THE DEFECT THIS FIXES (spec b41 §1): the ledger (packages/<pkg>.md) is touched
# by humans, reporters and judges — its mtime has nothing to do with when the
# coordinator last talked to the API. The transcript (runs/<pkg>.jsonl) is that
# record. They diverge both ways, and the outcomes are asymmetric: a missed warm
# resume re-ingests a multi-MB transcript at cache-WRITE rates (expensive); an
# unnecessary cold start merely re-seeds from a small ledger (cheap). So
# uncertainty must bias COLD, never warm — every ambiguous signal below (absent
# transcript, unparseable transcript, missing session id, absent observation)
# resolves to cold.
#
# CLI:
#   bp-cache-state.pl last_activity <bp> <pkg> [--now=EPOCH]   # epoch of last API event
#   bp-cache-state.pl observe       <bp> <pkg> [--now=EPOCH]   # record cache hit/miss
#   bp-cache-state.pl verdict       <bp> <pkg> [--now=EPOCH]   # -> "warm" | "cold"
#
# <bp>/<pkg> resolve exactly like bp-lib.sh's bp_dir/bp_ledger convention:
#   $CCPRAXIS_DATA_DIR/blueprints/<bp>/{packages/<pkg>.md, runs/<pkg>.jsonl, runs/registry.json}
# (CCPRAXIS_DATA_DIR is the existing env seam bp_data_dir() already reads.)
#
# require: require "<path>/bp-cache-state.pl";
#          BpCacheState::verdict_from_runs($runs, $pkg, $now)   # $runs already resolved
#          BpCacheState::verdict($root, $bp, $pkg, $now)        # CLI/root convention
#
# READING TRANSCRIPTS: they reach 10+ MB. last_activity reuses bp-orchestrator.pl's
# `_last_nonempty_line` (a backwards, 64KB-chunk, seek-from-end reader with a 1MB
# line cap) rather than slurping or reimplementing a second reader. A truncated or
# corrupt final line is the NORMAL state of a transcript whose coordinator was
# killed mid-write: it is classified cold, never dies, never yields warm.
#
# `observe` never mutates the transcript — it only ever opens it for reading.

package BpCacheState;
use strict;
use warnings;
use JSON::PP;
use Time::Local qw(timegm);
use File::Basename qw(dirname);
use Cwd qw(abs_path getcwd);

# Absolute script dir so `require "$DIR/..."` resolves no matter how this script
# is invoked (relative CLI path, absolute, or `require`d from a test) — the same
# convention bp-orchestrator.pl / bp-answer-decision.pl / bp-blueprint.pl already use.
my $DIR = dirname(abs_path(__FILE__));

# Reuse bp-orchestrator.pl's seek-from-end reader (BpOrch::_last_nonempty_line) and
# its atomic, locked registry writer (BpOrch::update_registry_pkg). This require is
# unconditional and TOP-LEVEL here; the reverse direction (bp-orchestrator.pl
# consuming THIS file) is deliberately kept LAZY / inside a sub body there, so the
# two files never race to load each other (see bp-orchestrator.pl's resume_mode).
require "$DIR/bp-orchestrator.pl";

# ===========================================================================
# THE POLICY CONSTANTS — named exactly once. No other file in this repo may
# hardcode the cache window as a bare literal; both bp-resume-sweep.sh and
# bp-orchestrator.pl are required to consume these via this module.
# ===========================================================================
use constant CACHE_TTL_MIN => 60;             # ENABLE_PROMPT_CACHING_1H's window (operator-ruled; never re-open here)
use constant CACHE_SAFETY_MARGIN_MIN => 10;   # margin so a boundary decision on a stale clock never lands wrong

# effective_threshold_min() -- strictly BELOW the raw TTL (50, not 60).
sub effective_threshold_min { return CACHE_TTL_MIN - CACHE_SAFETY_MARGIN_MIN }

# ===========================================================================
# ISO8601 <-> epoch (transcript timestamps carry milliseconds: "...T..:..:..NNNZ";
# fixtures may omit them). Never dies; undef on anything unrecognized.
# ===========================================================================
sub _epoch_of_iso {
    my ($s) = @_;
    return undef unless defined $s && length $s;
    if ($s =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z?$/) {
        my ($Y,$M,$D,$h,$mi,$se) = ($1,$2,$3,$4,$5,$6);
        my $e = eval { timegm($se+0, $mi+0, $h+0, $D+0, $M-1, $Y+0) };
        return $e;
    }
    return $s+0 if $s =~ /^\d{9,}$/;   # already-epoch, defensive
    return undef;
}

# ===========================================================================
# Path helpers -- mirror bp-lib.sh's bp_dir/bp_ledger convention exactly.
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
# Registry read (small, ad hoc JSON read — the shared atomic WRITE path below
# reuses BpOrch::update_registry_pkg rather than re-implementing locking).
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

sub read_registry_pkg_from_runs {
    my ($runs, $pkg) = @_;
    my $doc = _read_json_file("$runs/registry.json");
    return {} unless ref $doc eq 'HASH' && ref $doc->{packages} eq 'HASH';
    return ref $doc->{packages}{$pkg} eq 'HASH' ? $doc->{packages}{$pkg} : {};
}

# ===========================================================================
# last_activity — epoch of the LAST API event, derived ONLY from the transcript
# (runs/<pkg>.jsonl), NEVER the ledger. undef on: transcript absent, unreadable,
# empty/all-blank, a final line that doesn't decode as JSON, or one with no usable
# timestamp. A truncated/corrupt final line (a coordinator killed mid-write) is
# the NORMAL case here and must classify this way, not die.
# ===========================================================================
sub last_activity_from_runs {
    my ($runs, $pkg) = @_;
    my $file = "$runs/$pkg.jsonl";
    return undef unless -f $file;
    my $line = BpOrch::_last_nonempty_line($file);
    return undef unless defined $line && $line =~ /\S/;
    return undef if length($line) > $BpOrch::MAX_JSONL_LINE;
    my $obj = eval { JSON::PP->new->decode($line) };
    return undef unless ref $obj eq 'HASH';
    return _epoch_of_iso($obj->{timestamp});
}

# ===========================================================================
# verdict — "warm" | "cold". Uncertainty biases cold (spec §1/§3 C7): absent
# transcript, unparseable transcript, missing session_id, and absent observation
# history all yield cold. A history of repeat MISSES at the current age forces
# cold regardless of how fresh the transcript looks (the feedback loop, C6).
# Only a genuinely fresh, session-identified, hit-observed package within the
# safety margin (effective_threshold_min, strictly below the raw TTL) is warm.
# NEVER reads the ledger's mtime or contents (C3: mutating only the ledger
# between two calls never changes the verdict).
# ===========================================================================
sub verdict_from_runs {
    my ($runs, $pkg, $now) = @_;
    $now = time unless defined $now;

    my $epoch = last_activity_from_runs($runs, $pkg);
    return 'cold' unless defined $epoch;

    my $reg = read_registry_pkg_from_runs($runs, $pkg);
    my $sid = $reg->{session_id};
    return 'cold' unless defined $sid && length $sid;

    my $obs = $reg->{cache_observations};
    return 'cold' unless ref $obs eq 'ARRAY' && @$obs;

    my $age = int(($now - $epoch) / 60);
    $age = 0 if $age < 0;   # a clock skew never manufactures a negative (falsely-fresh) age

    # The feedback loop: only observations recorded at (about) this same age
    # count as evidence for THIS decision (spec §2 "classified cold at that age").
    my @matched = grep { defined $_->{age_min} && abs($_->{age_min} - $age) <= 1 } @$obs;
    return 'cold' unless @matched;
    return 'cold' if grep { !$_->{hit} } @matched;   # any observed miss at this age forces cold

    return ($age <= effective_threshold_min()) ? 'warm' : 'cold';
}

# ===========================================================================
# observe — read the transcript's FIRST assistant response's cache_read/creation
# token fields and append ONE {age_min, hit, ...} entry to the registry's
# packages.<pkg>.cache_observations array (never clobbering sibling fields —
# reuses BpOrch::update_registry_pkg's locked shallow-merge, the house pattern).
# NEVER mutates the transcript (opened '<:raw' only). Forward line-scan (not the
# backwards reader): the first assistant response is expected near the top of
# the file, so this never needs to read past it.
# ===========================================================================
sub _first_assistant_usage {
    my ($file) = @_;
    return undef unless -f $file;
    open my $fh, '<:raw', $file or return undef;
    my $found;
    while (my $line = <$fh>) {
        $line =~ s/[\r\n]+\z//;
        next unless $line =~ /\S/;
        next if length($line) > $BpOrch::MAX_JSONL_LINE;
        my $obj = eval { JSON::PP->new->decode($line) };
        next unless ref $obj eq 'HASH';
        next unless defined $obj->{type} && $obj->{type} eq 'assistant';
        next unless ref $obj->{message} eq 'HASH' && ref $obj->{message}{usage} eq 'HASH';
        $found = $obj;
        last;
    }
    close $fh;
    return $found;
}

sub observe_from_runs {
    my ($runs, $pkg, $now) = @_;
    $now = time unless defined $now;

    my $obj = _first_assistant_usage("$runs/$pkg.jsonl");
    return 0 unless defined $obj;

    my $usage       = $obj->{message}{usage};
    my $read_tok    = $usage->{cache_read_input_tokens}     // 0;
    my $create_tok  = $usage->{cache_creation_input_tokens} // 0;
    my $hit         = ($read_tok > 0) ? JSON::PP::true : JSON::PP::false;
    my $epoch       = _epoch_of_iso($obj->{timestamp});
    my $age_min     = defined $epoch ? int(($now - $epoch) / 60) : 0;
    $age_min = 0 if $age_min < 0;

    my $existing = read_registry_pkg_from_runs($runs, $pkg);
    my @obs = (ref $existing->{cache_observations} eq 'ARRAY') ? @{ $existing->{cache_observations} } : ();
    push @obs, {
        age_min                     => $age_min,
        hit                         => $hit,
        cache_read_input_tokens     => $read_tok,
        cache_creation_input_tokens => $create_tok,
        observed_at                 => $now,
    };

    return BpOrch::update_registry_pkg($runs, $pkg, { cache_observations => \@obs }) ? 1 : 0;
}

# ===========================================================================
# CLI / root+bp+pkg convention wrappers.
# ===========================================================================
sub last_activity { my ($root, $bp, $pkg) = @_; return last_activity_from_runs(_runs_dir($root, $bp), $pkg) }
sub verdict        { my ($root, $bp, $pkg, $now) = @_; return verdict_from_runs(_runs_dir($root, $bp), $pkg, $now) }
sub observe        { my ($root, $bp, $pkg, $now) = @_; return observe_from_runs(_runs_dir($root, $bp), $pkg, $now) }

# ===========================================================================
# CLI
# ===========================================================================
package main;
use strict;
use warnings;

unless (caller) {
    my ($verb, $bp, $pkg, @rest) = @ARGV;
    my $usage = "usage: bp-cache-state.pl <last_activity|observe|verdict> <bp> <pkg> [--now=EPOCH]\n";
    unless (defined $verb && $verb =~ /^(?:last_activity|observe|verdict)$/
            && defined $bp && length $bp && defined $pkg && length $pkg) {
        print STDERR $usage;
        exit 2;
    }
    my $now;
    for (@rest) {
        if (/^--now=(\d+)$/) { $now = $1 + 0; }
    }
    my $root = BpCacheState::_data_dir();

    if ($verb eq 'last_activity') {
        my $epoch = eval { BpCacheState::last_activity($root, $bp, $pkg) };
        unless (defined $epoch) { exit 1; }
        print "$epoch\n";
        exit 0;
    } elsif ($verb eq 'verdict') {
        my $v = eval { BpCacheState::verdict($root, $bp, $pkg, $now) };
        $v = 'cold' unless defined $v && ($v eq 'warm' || $v eq 'cold');   # never die, never fake-warm
        print "$v\n";
        exit 0;
    } elsif ($verb eq 'observe') {
        eval { BpCacheState::observe($root, $bp, $pkg, $now) };
        exit 0;   # best-effort telemetry: never blocks or fails the caller
    }
}
1;
