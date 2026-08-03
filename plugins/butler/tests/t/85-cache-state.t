#!/usr/bin/env perl
# b41-cache-state-tracking oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b41-cache-state-tracking-spec.md
# section 3 (C1..C11) plus the measured s07 numbers frozen in section 0/1 of that spec.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION: plugins/butler/scripts/bp-cache-state.pl does not exist on
# disk yet. Every assertion below is expected to fail on ABSENCE OF THE SCRIPT (perl's own "Can't
# open perl script ... No such file or directory" from the `system()`/backtick call), never on a
# bug, missing module, or wrong path in THIS file.
#
# =====================================================================================
# INTERFACE CONTRACT ASSUMED BY THIS ORACLE -- bp-cache-state.pl does not exist, so nothing here
# is "confirmed against real source" (unlike t/90's bp-pin.pl precedent); this section PINS the
# interface bp-cache-state.pl must satisfy. The implementer's job is to match this, not the other
# way around.
#
#   CLI: perl bp-cache-state.pl <last_activity|observe|verdict> <bp> <pkg> [--now=EPOCH]
#
#   - <bp>/<pkg> resolve exactly like bp-lib.sh's bp_dir/bp_ledger convention already in this repo
#     (plugins/butler/scripts/bp-lib.sh): $CCPRAXIS_DATA_DIR/blueprints/<bp>/packages/<pkg>.md,
#     .../runs/<pkg>.jsonl, .../runs/registry.json. CCPRAXIS_DATA_DIR is the existing env-var seam
#     bp_data_dir() already reads (bp-lib.sh:28-30) -- this is the ONE new thing this oracle adds:
#     an injectable --now=EPOCH clock, mirroring bp-pin.pl's own --now=ISO precedent (t/90), because
#     without it C1's exact measured skew cannot be reproduced against a moving wall clock.
#   - last_activity prints the derived epoch (a plain integer) to stdout, exit 0, when derivable;
#     prints nothing meaningful to stdout and exits non-zero when it cannot be derived.
#   - verdict prints exactly "warm" or "cold" (bare, newline-terminated) to stdout, exit 0.
#   - observe reads the transcript's FIRST assistant response's cache_read_input_tokens /
#     cache_creation_input_tokens (spec section 2) and appends ONE entry to
#     runs/registry.json -> packages.<pkg>.cache_observations (an array), each entry at minimum
#     {age_min, hit} where hit is true iff cache_read_input_tokens > 0 at that response. This is
#     the registry shape this oracle requires; it is a design decision pinned here because no
#     prior art fixes it -- registry_merge's existing shallow-merge convention (bp-lib.sh:106) is
#     the house pattern this must follow (append to the array, never clobber sibling fields).
#   - verdict is cold whenever ANY of: transcript absent, transcript unparseable, session_id
#     missing, or cache_observations absent for the package (C7) -- and, given a fresh transcript-
#     derived age within the safety margin AND a favorable (hit) observation history at that same
#     age, warm; a history of MISSES at that age forces cold regardless of age (C6).
#
# SYN-23: nothing below cites a line number in bp-orchestrator.pl, bp-resume-sweep.sh or
# bp-cache-state.pl. Everything is located by grep pattern.
#
# MANDATORY VACUITY GATE (spec section 3's own standing rule, restated in the coordinator brief):
# C3, C7, C9, C10 and C11 are negative-only ("unchanged", "never warm", "never mutates") and would
# pass trivially against a `verdict` that always returns "cold" or an `observe` that does nothing.
# Each below carries a POSITIVE assertion FIRST:
#   - C3: the two verdict calls are asserted to be "warm" (not merely equal) before the ledger-only
#     mutation is asserted not to change them.
#   - C7: the SAME fixture with the one uncertainty factor removed is asserted "warm" immediately
#     before/after each of the four "cold" assertions.
#   - C9: last_activity is asserted to return a real, correct epoch (bytes read, timestamp
#     extracted) from a well-formed fixture, before the 10.3MB no-slurp/reader-identity checks.
#   - C10: a byte-identical WELL-FORMED twin of the truncated fixture is asserted "warm" in the
#     same harness before the truncated fixture is asserted "cold, does not die".
#   - C11: the registry is asserted to have GAINED an observation entry (observe actually wrote)
#     before the transcript byte-compare is asserted unchanged.
# No SKIP appears anywhere in this file. Absence is always a FAILURE, never a skip.
#
# HARDCODED-COLD CHECK (the single most important property of this file): every one of the
# "verdict must be cold" assertions above is paired, in the SAME test file, with a companion
# fixture asserting "verdict must be warm" through the identical code path (last_activity /
# verdict CLI, same registry/transcript shapes, differing only in the one dimension under test).
# A bp-cache-state.pl that hardcodes `print "cold"` satisfies every "must be cold" assertion here
# but FAILS every paired "must be warm" one (C1's own harness fixture, C2, C3's baseline, C4's
# age=45 case, C6's hit-history case, C7's baseline, C9's baseline, C10's well-formed twin) --
# so a hardcoded-cold implementation cannot pass this oracle.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir tempfile);
use File::Copy qw(copy);
use JSON::PP;
use Time::Local qw(timegm);
use Digest::SHA qw(sha256_hex);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS  = fwd("$Bin");
my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $PROJ   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");

my $SCRIPT        = "$BUTLER/scripts/bp-cache-state.pl";
my $ORCH_SCRIPT   = "$BUTLER/scripts/bp-orchestrator.pl";
my $SWEEP_SCRIPT  = "$BUTLER/scripts/bp-resume-sweep.sh";
my $REAL_TRANSCRIPT = "$PROJ/.ccpraxis-local-data/blueprints/sandbox-butler-overhaul/runs/b25-feedback-intake.jsonl";

diag("subject under test: $SCRIPT " . (-e $SCRIPT ? "(present)" : "(ABSENT -- every C1..C11 assertion below is expected to fail)"));

my $J = JSON::PP->new->canonical;

# =====================================================================================
# Scaffolding
# =====================================================================================

sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

sub write_file {
    my ($path, $content) = @_;
    (my $d = $path) =~ s{[\\/][^\\/]+$}{};
    require File::Path; File::Path::make_path($d) unless -d $d;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

sub write_json { my ($path, $data) = @_; return write_file($path, $J->encode($data)) }

sub iso_of { # epoch -> ISO8601 Z string
    my ($e) = @_;
    my @g = gmtime($e);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1], $g[0]);
}

# jsonl_line(\%fields) -> one compact JSON object text (no trailing newline)
sub jsonl_line { my ($h) = @_; return $J->encode($h) }

# A minimal but well-formed "assistant response with usage" event, as the last non-empty line
# of a transcript -- the shape bp-cache-state.pl's last_activity/verdict must be able to read.
sub assistant_event {
    my (%o) = @_;
    my $read   = $o{cache_read}     // 0;
    my $create = $o{cache_creation} // 0;
    return {
        type      => 'assistant',
        timestamp => iso_of($o{epoch}),
        session_id=> $o{session_id} // 'sess-fixture',
        message   => {
            role  => 'assistant',
            usage => {
                input_tokens              => 2,
                cache_read_input_tokens   => $read,
                cache_creation_input_tokens => $create,
                output_tokens             => 1,
            },
        },
    };
}

# ---- fixture-root builder ----------------------------------------------------------
# Returns ($root, $bp, $pkg). $root becomes CCPRAXIS_DATA_DIR; layout mirrors bp-lib.sh's
# bp_dir/bp_ledger convention exactly (blueprints/<bp>/packages/<pkg>.md, runs/<pkg>.jsonl,
# runs/registry.json).
my $bp_counter = 0;
sub new_bp_root {
    my $root = tempdir(CLEANUP => 1);
    my $bp   = 'tbp';
    $bp_counter++;
    my $pkg  = "pkg$bp_counter";
    write_file("$root/blueprints/$bp/packages/$pkg.md",
        "---\npackage: $pkg\nstatus: running\nwrite_set: p/$pkg/\n---\n\n# $pkg\n\n## Next action\n\nIn flight.\n");
    return ($root, $bp, $pkg);
}

sub transcript_path { my ($root,$bp,$pkg) = @_; return "$root/blueprints/$bp/runs/$pkg.jsonl" }
sub registry_path    { my ($root,$bp,$pkg) = @_; return "$root/blueprints/$bp/runs/registry.json" }
sub ledger_path      { my ($root,$bp,$pkg) = @_; return "$root/blueprints/$bp/packages/$pkg.md" }

sub write_registry {
    my ($root, $bp, $pkg, %fields) = @_;
    write_json(registry_path($root,$bp,$pkg), { packages => { $pkg => \%fields } });
}

sub read_registry_pkg {
    my ($root, $bp, $pkg) = @_;
    my $txt = read_file(registry_path($root,$bp,$pkg));
    return {} unless defined $txt && length $txt;
    my $doc = eval { JSON::PP->new->decode($txt) };
    return {} unless ref $doc eq 'HASH';
    return $doc->{packages}{$pkg} // {};
}

# run_cs($verb, $root, $bp, $pkg, %opt) -> ($rc, $stdout, $stderr)
# Subprocess invocation ONLY (per t/90's own house idiom for CLI scripts) -- real fd-backed temp
# files for stdout/stderr, never an in-memory scalar filehandle (Windows landmine, see CLAUDE.md).
sub run_cs {
    my ($verb, $root, $bp, $pkg, %opt) = @_;
    my ($ofh, $opath) = tempfile('t85-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('t85-errXXXXXX', TMPDIR => 1); close $efh;

    my @args = ($verb, $bp, $pkg);
    push @args, "--now=$opt{now}" if defined $opt{now};

    local %ENV = %ENV;
    $ENV{CCPRAXIS_DATA_DIR} = $root;

    my @cmd = (qq{"$^X"}, qq{"$SCRIPT"}, map { qq{"$_"} } @args);
    my $cmd = join(' ', @cmd) . qq{ >"$opath" 2>"$epath"};
    system($cmd);
    my $rc = $? >> 8;

    my $out = read_file($opath) // '';
    my $err = read_file($epath) // '';
    unlink $opath, $epath;
    $out =~ s/\s+\z//;
    return ($rc, $out, $err);
}

# no-crash-signature check: a graceful "cold"/error classification is not a language-level death.
sub not_crashed {
    my ($err) = @_;
    return $err !~ /\bDied\b|Can't (?:locate|call)|Undefined subroutine|panic:|Segmentation fault/;
}

# =====================================================================================
# C1 -- the measured s07 case: ledger 71h NEWER than the transcript. Exact epochs from the spec
# scout (section 0/1): ledger 1785613986, transcript 1785358404 (skew +4259.7 min / 71.0h).
# "now" is pinned just after the ledger touch (+14s) -- the moment the sweep would actually run --
# so a ledger-mtime-based calculation (the OLD, buggy policy) would see ~0 min gap and call it
# warm, while the correct transcript-derived calculation sees the full 71h gap and must call it
# cold. This is the exact defect bp-resume-sweep.sh:73 / bp-cache-state.pl exists to fix.
# =====================================================================================
{
    my ($root, $bp, $pkg) = new_bp_root();
    my $LEDGER_EPOCH     = 1785613986;
    my $TRANSCRIPT_EPOCH = 1785358404;
    my $NOW              = $LEDGER_EPOCH + 14;   # sweep runs 14s after the ledger touch

    write_file(transcript_path($root,$bp,$pkg),
        jsonl_line(assistant_event(epoch => $TRANSCRIPT_EPOCH)) . "\n");
    utime($TRANSCRIPT_EPOCH, $TRANSCRIPT_EPOCH, transcript_path($root,$bp,$pkg));
    utime($LEDGER_EPOCH, $LEDGER_EPOCH, ledger_path($root,$bp,$pkg));
    write_registry($root, $bp, $pkg, session_id => 'sess-s07');

    my ($rc_v, $out_v, $err_v) = run_cs('verdict', $root, $bp, $pkg, now => $NOW);
    is($rc_v, 0, 'C1: verdict exits 0 for the s07 fixture') or diag("stderr=$err_v");
    is($out_v, 'cold',
        'C1: s07 case (ledger 71h NEWER than transcript) yields cold -- the ledger-mtime-fooled '
        . 'bug this package fixes')
        or diag("stdout=[$out_v] stderr=$err_v");

    my ($rc_a, $out_a, $err_a) = run_cs('last_activity', $root, $bp, $pkg, now => $NOW);
    is($rc_a, 0, 'C1: last_activity exits 0 for the s07 fixture') or diag("stderr=$err_a");
    is($out_a, $TRANSCRIPT_EPOCH,
        'C1: last_activity derives from the TRANSCRIPT epoch (1785358404), never the ledger epoch '
        . '(1785613986) -- proves the mechanism, not just the final verdict')
        or diag("stdout=[$out_a] stderr=$err_a");
}

# =====================================================================================
# C2 -- reverse skew: transcript far NEWER than the ledger (ledger stale/never-touched-since,
# transcript active minutes ago). Correct answer is warm; this is also this file's general
# "warm is reachable via a genuinely stale ledger" reachability proof.
# =====================================================================================
{
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    my $recent_epoch = $NOW - 5*60;          # transcript active 5 min ago
    my $stale_ledger_epoch = $NOW - 300_000*60;  # ledger untouched for ~208 days

    write_file(transcript_path($root,$bp,$pkg),
        jsonl_line(assistant_event(epoch => $recent_epoch, cache_read => 500)) . "\n");
    utime($recent_epoch, $recent_epoch, transcript_path($root,$bp,$pkg));
    utime($stale_ledger_epoch, $stale_ledger_epoch, ledger_path($root,$bp,$pkg));
    write_registry($root, $bp, $pkg,
        session_id => 'sess-c2',
        cache_observations => [ { age_min => 5, hit => JSON::PP::true } ]);

    my ($rc, $out, $err) = run_cs('verdict', $root, $bp, $pkg, now => $NOW);
    is($rc, 0, 'C2: verdict exits 0') or diag("stderr=$err");
    is($out, 'warm',
        'C2: reverse skew (transcript far newer than an ancient ledger) yields warm -- proves '
        . 'verdict genuinely ignores ledger mtime')
        or diag("stdout=[$out] stderr=$err");
}

# =====================================================================================
# C3 -- mutating ONLY the ledger between two verdict calls never changes the verdict.
# Vacuity gate: BOTH calls are asserted "warm" (not merely equal to each other) first.
# =====================================================================================
{
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    my $age_epoch = $NOW - 20*60;

    write_file(transcript_path($root,$bp,$pkg),
        jsonl_line(assistant_event(epoch => $age_epoch, cache_read => 900)) . "\n");
    utime($age_epoch, $age_epoch, transcript_path($root,$bp,$pkg));
    write_registry($root, $bp, $pkg,
        session_id => 'sess-c3',
        cache_observations => [ { age_min => 20, hit => JSON::PP::true } ]);

    my ($rc1, $v1, $e1) = run_cs('verdict', $root, $bp, $pkg, now => $NOW);
    is($rc1, 0, 'C3: first verdict call exits 0') or diag($e1);
    is($v1, 'warm', 'C3 POSITIVE GATE: the first verdict call is warm (a real, non-arbitrary answer)')
        or diag("stdout=[$v1]");

    # Mutate ONLY the ledger: touch its mtime far into the future and rewrite its status/body.
    utime($NOW + 999_999, $NOW + 999_999, ledger_path($root,$bp,$pkg));
    write_file(ledger_path($root,$bp,$pkg),
        "---\npackage: $pkg\nstatus: blocked\nwrite_set: p/$pkg/\n---\n\n# $pkg\n\nledger mutated.\n");

    my ($rc2, $v2, $e2) = run_cs('verdict', $root, $bp, $pkg, now => $NOW);
    is($rc2, 0, 'C3: second verdict call (after ledger-only mutation) exits 0') or diag($e2);
    is($v2, 'warm', 'C3 POSITIVE GATE: the second call is STILL warm (a real answer both times)')
        or diag("stdout=[$v2]");
    is($v1, $v2, 'C3: mutating only the ledger between two verdict calls never changes the verdict');
}

# =====================================================================================
# C4 -- the effective threshold is STRICTLY BELOW the TTL (60), with a 10-minute safety margin
# (effective 50). Behavioral proof: age=45 (below margin) -> warm; age=55 (above margin, still
# below the raw TTL of 60) -> cold; age=65 (above the TTL too) -> cold. Each fixture is otherwise
# maximally favorable (session id + matching hit history at that exact age) so ONLY the age
# dimension is under test.
# =====================================================================================
sub mk_age_fixture {
    my ($age_min, $hit) = @_;
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    my $epoch = $NOW - $age_min*60;
    write_file(transcript_path($root,$bp,$pkg),
        jsonl_line(assistant_event(epoch => $epoch, cache_read => ($hit ? 700 : 0))) . "\n");
    utime($epoch, $epoch, transcript_path($root,$bp,$pkg));
    write_registry($root, $bp, $pkg,
        session_id => 'sess-age',
        cache_observations => [ { age_min => $age_min, hit => ($hit ? JSON::PP::true : JSON::PP::false) } ]);
    return ($root, $bp, $pkg, $NOW);
}
{
    my ($r45,$bp45,$pkg45,$now45) = mk_age_fixture(45, 1);
    my (undef, $v45) = run_cs('verdict', $r45, $bp45, $pkg45, now => $now45);
    is($v45, 'warm', 'C4: age=45min (below the 50min effective threshold) yields warm');

    my ($r55,$bp55,$pkg55,$now55) = mk_age_fixture(55, 1);
    my (undef, $v55) = run_cs('verdict', $r55, $bp55, $pkg55, now => $now55);
    is($v55, 'cold',
        'C4: age=55min is ABOVE the 50min effective threshold but still below the raw 60min TTL -- '
        . 'cold proves the safety margin is enforced, not just the bare TTL');

    my ($r65,$bp65,$pkg65,$now65) = mk_age_fixture(65, 1);
    my (undef, $v65) = run_cs('verdict', $r65, $bp65, $pkg65, now => $now65);
    is($v65, 'cold', 'C4: age=65min (past the raw TTL too) yields cold');
}
# Mechanism: the TTL (60) is named exactly once, as a constant, in bp-cache-state.pl; no file
# hardcodes the window as a bare literal outside that one named-constant definition.
{
    my $src = read_file($SCRIPT) // '';
    my @ttl_defs = ($src =~ /CACHE_TTL_MIN\s*(?:=>|=)\s*60\b/g);
    is(scalar(@ttl_defs), 1,
        'C4: CACHE_TTL_MIN => 60 (or = 60) appears exactly once as a named constant in bp-cache-state.pl')
        or diag('occurrences found: ' . scalar(@ttl_defs));

    my @margin_defs = ($src =~ /CACHE_SAFETY_MARGIN_MIN\s*(?:=>|=)\s*10\b/g);
    is(scalar(@margin_defs), 1,
        'C4: CACHE_SAFETY_MARGIN_MIN => 10 appears exactly once as a named constant in bp-cache-state.pl');

    # No OTHER file hardcodes a bare "60" in a threshold-shaped comparison that bypasses the named
    # constant. Scoped to the two files the spec itself names as carrying (or risking) a SECOND
    # copy of the cache-window policy -- bp-resume-sweep.sh:36 (`${BP_RESUME_THRESHOLD_MIN:-60}`)
    # and bp-orchestrator.pl's resume_mode (`$threshold_min //= 60`) -- rather than every bare "60"
    # in the whole scripts/ tree, which would false-positive on unrelated numeric literals (e.g.
    # bp-judge.pl's turn-count clamp `return 60 if $n > 60`, which has nothing to do with the cache
    # TTL and would make this check red forever even after a correct fix).
    my @offenders;
    for my $f ($SWEEP_SCRIPT, $ORCH_SCRIPT) {
        my $t = read_file($f) // '';
        push @offenders, $f if $t =~ /:-\s*60\b|\/\/=\s*60\b|<=?\s*60\b|<\s*60\b|>\s*60\b|-le\s+60\b|-lt\s+60\b/;
    }
    is(scalar(@offenders), 0,
        'C4: neither bp-resume-sweep.sh nor bp-orchestrator.pl hardcodes a bare 60-minute threshold '
        . 'literal outside bp-cache-state.pl\'s named constant')
        or diag('offending files: ' . join(', ', @offenders));
}

# =====================================================================================
# C5 -- cache hit/miss observed from the token fields and recorded, asserted against the REAL
# transcript fixture (runs/b25-feedback-intake.jsonl, 10,351,554 bytes, 1,217 lines carrying
# cache_read_input_tokens). COPIED into the fixture root; the original under
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/runs/ is never opened for writing.
# Its FIRST assistant response (confirmed by direct inspection of the real file) carries
# cache_read_input_tokens=18196, cache_creation_input_tokens=18065 -- an unambiguous hit.
# =====================================================================================
{
    my ($root, $bp, $pkg) = new_bp_root();
    ok(-f $REAL_TRANSCRIPT && -s $REAL_TRANSCRIPT == 10_351_554,
        'C5 FIXTURE-SANITY: the real b25-feedback-intake.jsonl is present and exactly 10,351,554 bytes')
        or diag("real transcript missing or resized: $REAL_TRANSCRIPT");
    require File::Path; File::Path::make_path("$root/blueprints/$bp/runs") unless -d "$root/blueprints/$bp/runs";
    copy($REAL_TRANSCRIPT, transcript_path($root,$bp,$pkg))
        or die "failed to copy real transcript fixture: $!";
    write_registry($root, $bp, $pkg, session_id => 'sess-c5');

    my ($rc, $out, $err) = run_cs('observe', $root, $bp, $pkg);
    is($rc, 0, 'C5: observe exits 0 against the real 10.3MB transcript') or diag("stderr=$err");

    my $pkg_reg = read_registry_pkg($root, $bp, $pkg);
    my $obs = $pkg_reg->{cache_observations};
    ok(ref $obs eq 'ARRAY' && @$obs >= 1,
        'C5: observe recorded at least one cache_observations entry in the registry')
        or diag('registry pkg entry: ' . $J->encode($pkg_reg));

    my $last = (ref $obs eq 'ARRAY' && @$obs) ? $obs->[-1] : {};
    ok($last->{hit} ? 1 : 0,
        "C5: the recorded observation is a HIT (cache_read_input_tokens=18196 on the real "
        . "transcript's first assistant response)")
        or diag('recorded entry: ' . $J->encode($last));
}

# =====================================================================================
# C6 -- the feedback loop: a warm-eligible resume whose OBSERVED history shows repeat MISSES at
# a given age is classified cold at that age, despite an otherwise-favorable time-based signal.
# Vacuity gate: the identical fixture with the history flipped to HITS at the same age is warm --
# proving the cold verdict comes from the miss history, not an incidental property of the fixture.
# =====================================================================================
{
    my $AGE = 30;
    my ($root_miss, $bp_m, $pkg_m) = new_bp_root();
    my $NOW = 2_000_000_000;
    my $epoch = $NOW - $AGE*60;
    write_file(transcript_path($root_miss,$bp_m,$pkg_m),
        jsonl_line(assistant_event(epoch => $epoch, cache_read => 0)) . "\n");  # this launch missed
    utime($epoch, $epoch, transcript_path($root_miss,$bp_m,$pkg_m));
    write_registry($root_miss, $bp_m, $pkg_m,
        session_id => 'sess-c6-miss',
        cache_observations => [
            { age_min => $AGE, hit => JSON::PP::false },
            { age_min => $AGE, hit => JSON::PP::false },
        ]);
    my ($rc_m, $v_m, $err_m) = run_cs('verdict', $root_miss, $bp_m, $pkg_m, now => $NOW);
    is($rc_m, 0, 'C6: verdict exits 0 against the miss-history fixture') or diag($err_m);

    # Vacuity gate: the SAME shape, history flipped to hits, is warm.
    my ($root_hit, $bp_h, $pkg_h) = new_bp_root();
    write_file(transcript_path($root_hit,$bp_h,$pkg_h),
        jsonl_line(assistant_event(epoch => $epoch, cache_read => 700)) . "\n");
    utime($epoch, $epoch, transcript_path($root_hit,$bp_h,$pkg_h));
    write_registry($root_hit, $bp_h, $pkg_h,
        session_id => 'sess-c6-hit',
        cache_observations => [
            { age_min => $AGE, hit => JSON::PP::true },
            { age_min => $AGE, hit => JSON::PP::true },
        ]);
    my ($rc_h, $v_h, $err_h) = run_cs('verdict', $root_hit, $bp_h, $pkg_h, now => $NOW);
    is($rc_h, 0, 'C6 POSITIVE GATE: verdict exits 0 against the hit-history twin') or diag($err_h);
    is($v_h, 'warm',
        'C6 POSITIVE GATE: identical age/time signal with a HIT history yields warm (proves warm '
        . 'is reachable through this exact code path)')
        or diag("stdout=[$v_h]");

    is($v_m, 'cold',
        "C6: the SAME age ($AGE min, otherwise time-eligible) with a history of repeat MISSES "
        . 'yields cold -- the observed feedback loop overrides the time-based signal')
        or diag("stdout=[$v_m]");

    # The feedback loop also has a write side: observe must be able to APPEND a miss to history
    # from a real (synthetic-but-well-formed) transcript showing cache_read_input_tokens=0, and
    # that miss must be VISIBLE to the next verdict decision (spec: "recorded ... and visible to
    # the next decision").
    my ($root_o, $bp_o, $pkg_o) = new_bp_root();
    write_file(transcript_path($root_o,$bp_o,$pkg_o),
        jsonl_line(assistant_event(epoch => $epoch, cache_read => 0)) . "\n");
    utime($epoch, $epoch, transcript_path($root_o,$bp_o,$pkg_o));
    write_registry($root_o, $bp_o, $pkg_o, session_id => 'sess-c6-observe');
    run_cs('observe', $root_o, $bp_o, $pkg_o, now => $NOW);
    my $reg_after = read_registry_pkg($root_o, $bp_o, $pkg_o);
    my $obs_after = $reg_after->{cache_observations};
    ok(ref $obs_after eq 'ARRAY' && @$obs_after >= 1 && !$obs_after->[-1]{hit},
        'C6: observe recorded the MISS from a real cache_read_input_tokens=0 response, visible in the registry')
        or diag('registry after observe: ' . $J->encode($reg_after));
}

# =====================================================================================
# C7 -- uncertainty biases cold: absent transcript, unparseable transcript, missing session id,
# and absent observation each yield cold. Vacuity gate: the SAME baseline fixture with the one
# uncertainty factor REMOVED is asserted warm immediately alongside each cold assertion.
# =====================================================================================
sub mk_c7_baseline {
    my ($root, $bp, $pkg) = new_bp_root();
    my $NOW = 2_000_000_000;
    my $epoch = $NOW - 15*60;
    write_file(transcript_path($root,$bp,$pkg),
        jsonl_line(assistant_event(epoch => $epoch, cache_read => 400)) . "\n");
    utime($epoch, $epoch, transcript_path($root,$bp,$pkg));
    write_registry($root, $bp, $pkg,
        session_id => 'sess-c7',
        cache_observations => [ { age_min => 15, hit => JSON::PP::true } ]);
    return ($root, $bp, $pkg, $NOW);
}
{
    # Positive gate for the whole block: the untouched baseline is warm.
    my ($rb, $bpb, $pkgb, $nowb) = mk_c7_baseline();
    my (undef, $vb) = run_cs('verdict', $rb, $bpb, $pkgb, now => $nowb);
    is($vb, 'warm', 'C7 POSITIVE GATE: the untouched baseline fixture is warm');
}
{
    # (a) absent transcript
    my ($root, $bp, $pkg, $now) = mk_c7_baseline();
    unlink transcript_path($root,$bp,$pkg);
    my ($rc, $v, $err) = run_cs('verdict', $root, $bp, $pkg, now => $now);
    is($rc, 0, 'C7a: verdict exits 0 with the transcript absent') or diag($err);
    is($v, 'cold', 'C7a: absent transcript yields cold');
    ok(not_crashed($err), 'C7a: no crash signature on stderr');
}
{
    # (b) unparseable transcript (binary garbage, no valid JSON line at all)
    my ($root, $bp, $pkg, $now) = mk_c7_baseline();
    write_file(transcript_path($root,$bp,$pkg), "\x00\x01\xFF not json at all {{{\n\x02\x03");
    my ($rc, $v, $err) = run_cs('verdict', $root, $bp, $pkg, now => $now);
    is($rc, 0, 'C7b: verdict exits 0 with an unparseable transcript') or diag($err);
    is($v, 'cold', 'C7b: unparseable transcript yields cold');
    ok(not_crashed($err), 'C7b: no crash signature on stderr');
}
{
    # (c) missing session id
    my ($root, $bp, $pkg, $now) = mk_c7_baseline();
    write_registry($root, $bp, $pkg, cache_observations => [ { age_min => 15, hit => JSON::PP::true } ]);
    my ($rc, $v, $err) = run_cs('verdict', $root, $bp, $pkg, now => $now);
    is($rc, 0, 'C7c: verdict exits 0 with session_id missing') or diag($err);
    is($v, 'cold', 'C7c: missing session_id yields cold');
}
{
    # (d) absent observation history entirely
    my ($root, $bp, $pkg, $now) = mk_c7_baseline();
    write_registry($root, $bp, $pkg, session_id => 'sess-c7');   # no cache_observations key at all
    my ($rc, $v, $err) = run_cs('verdict', $root, $bp, $pkg, now => $now);
    is($rc, 0, 'C7d: verdict exits 0 with cache_observations absent') or diag($err);
    is($v, 'cold', 'C7d: absent observation history yields cold');
}

# =====================================================================================
# C8 -- bp-resume-sweep.sh and bp-orchestrator.pl reach the SAME verdict for identical inputs by
# calling the SHARED entry point -- asserted as the shared call being present, never as two
# outputs merely matching (which a coincidence or a double-hardcode could fake).
# =====================================================================================
{
    my $sweep_src = read_file($SWEEP_SCRIPT) // '';
    like($sweep_src, qr/bp-cache-state\.pl/,
        'C8: bp-resume-sweep.sh invokes bp-cache-state.pl (the shared entry point), not a second '
        . 'copy of the warm/cold policy')
        or diag('bp-resume-sweep.sh does not yet reference bp-cache-state.pl -- expected pre-implementation');

    my $orch_src = read_file($ORCH_SCRIPT) // '';
    like($orch_src, qr/bp-cache-state\.pl|BpCacheState\b/,
        "C8: bp-orchestrator.pl's resume_mode path calls into bp-cache-state.pl / BpCacheState, "
        . 'not a second copy of the warm/cold policy')
        or diag('bp-orchestrator.pl does not yet reference bp-cache-state.pl/BpCacheState -- expected pre-implementation');
}

# =====================================================================================
# C9 -- reading is seek-from-end: (1) POSITIVE GATE -- last_activity actually reads bytes and
# extracts a real timestamp from a well-formed fixture; (2) the 10.3MB real transcript is
# processed without a slurp (peak-RSS delta bounded, well under the file's own 10.3MB size);
# (3) _last_nonempty_line (bp-orchestrator.pl:807) is the reader actually used, not a second
# reimplementation.
# =====================================================================================
{
    # (1) Positive gate: a small well-formed fixture with a known timestamp.
    my ($root, $bp, $pkg) = new_bp_root();
    my $epoch = 1_800_000_000;
    write_file(transcript_path($root,$bp,$pkg), jsonl_line(assistant_event(epoch => $epoch)) . "\n");
    my ($rc, $out, $err) = run_cs('last_activity', $root, $bp, $pkg);
    is($rc, 0, 'C9 POSITIVE GATE: last_activity exits 0 against a well-formed transcript') or diag($err);
    is($out, $epoch,
        'C9 POSITIVE GATE: last_activity actually read bytes and extracted the real timestamp '
        . "($epoch), not a placeholder")
        or diag("stdout=[$out]");
}
{
    # (2) Mechanism: bp-cache-state.pl reuses _last_nonempty_line rather than reimplementing it.
    my $src = read_file($SCRIPT) // '';
    like($src, qr/_last_nonempty_line/,
        'C9: bp-cache-state.pl references _last_nonempty_line (bp-orchestrator.pl:807) -- the '
        . 'shared reader')
        or diag('bp-cache-state.pl does not reference _last_nonempty_line -- expected pre-implementation');
    unlike($src, qr/sub\s+_last_nonempty_line\s*\{/,
        'C9: bp-cache-state.pl does NOT redefine its own _last_nonempty_line (reuse, not a second reader)');
}
{
    # (3) Bounded peak read against the REAL 10.3MB transcript: measure the peak RSS delta of the
    # subprocess between a tiny fixture and the full 10.3MB copy. A slurp (`local $/; <$fh>`) would
    # add >=10MB of resident memory for the file content alone; seek-from-end chunked reading
    # (64KB chunks per bp-orchestrator.pl's own reader) adds only tens of KB regardless of file size.
    my ($root, $bp, $pkg) = new_bp_root();
    write_file(transcript_path($root,$bp,$pkg), jsonl_line(assistant_event(epoch => 1_800_000_000)) . "\n");

    my ($root_big, $bp_big, $pkg_big) = new_bp_root();
    ok(-f $REAL_TRANSCRIPT && -s $REAL_TRANSCRIPT == 10_351_554,
        'C9 FIXTURE-SANITY: the real 10.3MB transcript is present for the bounded-read check');
    require File::Path; File::Path::make_path("$root_big/blueprints/$bp_big/runs") unless -d "$root_big/blueprints/$bp_big/runs";
    copy($REAL_TRANSCRIPT, transcript_path($root_big,$bp_big,$pkg_big))
        or die "failed to copy real transcript fixture: $!";

    sub peak_rss_kb {
        my ($verb, $root, $bp, $pkg) = @_;
        my ($ofh, $opath) = tempfile('t85-rss-outXXXXXX', TMPDIR => 1); close $ofh;
        local %ENV = %ENV;
        $ENV{CCPRAXIS_DATA_DIR} = $root;
        my $pid = fork();
        if (!defined $pid) { return undef }
        if ($pid == 0) {
            open(STDOUT, '>', $opath) or exit 1;
            open(STDERR, '>', '/dev/null');
            exec($^X, $SCRIPT, $verb, $bp, $pkg) or exit 1;
        }
        my $peak = 0;
        my $tries = 0;
        while (1) {
            my $r = waitpid($pid, 1); # WNOHANG
            if (-r "/proc/$pid/status") {
                if (open(my $sfh, '<', "/proc/$pid/status")) {
                    local $/;
                    my $t = <$sfh>; close $sfh;
                    if ($t && $t =~ /VmRSS:\s*(\d+)\s*kB/) { $peak = $1 if $1 > $peak }
                }
            }
            last if $r == $pid;
            $tries++;
            last if $tries > 200_000; # safety valve, never an infinite loop
        }
        waitpid($pid, 0) if $pid;
        unlink $opath;
        return $peak;
    }

    # Run each several times and keep the max sample seen, to reduce the chance that a very fast
    # process is never caught mid-flight by the polling loop.
    my ($small_peak, $big_peak) = (0, 0);
    for (1..5) {
        my $s = peak_rss_kb('last_activity', $root, $bp, $pkg);
        $small_peak = $s if defined $s && $s > $small_peak;
        my $b = peak_rss_kb('last_activity', $root_big, $bp_big, $pkg_big);
        $big_peak = $b if defined $b && $b > $big_peak;
    }
    ok($small_peak > 0 && $big_peak > 0,
        'C9 HARNESS: peak RSS was actually sampled for both the tiny and the 10.3MB fixture')
        or diag("small_peak=$small_peak big_peak=$big_peak (sampling may have missed a very fast process)");

    my $delta_kb = $big_peak - $small_peak;
    cmp_ok($delta_kb, '<', 6_000,
        'C9: peak RSS delta between the tiny fixture and the 10.3MB real transcript is well under '
        . '6MB -- proves the read is bounded (seek-from-end), not a slurp of the whole file '
        . "(small_peak=${small_peak}KB big_peak=${big_peak}KB delta=${delta_kb}KB)");
}

# =====================================================================================
# C10 -- a truncated/corrupt final line (the normal state of a transcript killed mid-write) never
# dies and never yields warm. Vacuity gate: a byte-identical WELL-FORMED twin (same content, intact
# final line) is warm in the same harness.
# =====================================================================================
{
    my $NOW = 2_000_000_000;
    my $epoch = $NOW - 10*60;

    # Well-formed twin: warm reachability proof.
    my ($rw, $bpw, $pkgw) = new_bp_root();
    write_file(transcript_path($rw,$bpw,$pkgw),
        jsonl_line(assistant_event(epoch => $epoch, cache_read => 800)) . "\n");
    utime($epoch, $epoch, transcript_path($rw,$bpw,$pkgw));
    write_registry($rw, $bpw, $pkgw,
        session_id => 'sess-c10-good',
        cache_observations => [ { age_min => 10, hit => JSON::PP::true } ]);
    my ($rc_w, $v_w, $err_w) = run_cs('verdict', $rw, $bpw, $pkgw, now => $NOW);
    is($rc_w, 0, 'C10 POSITIVE GATE: the well-formed twin exits 0') or diag($err_w);
    is($v_w, 'warm', 'C10 POSITIVE GATE: the well-formed twin (intact final line) is warm')
        or diag("stdout=[$v_w]");

    # Truncated/corrupt: the same event's JSON cut off mid-object, no trailing newline -- exactly
    # what a coordinator process killed mid-write leaves behind.
    my ($rt, $bpt, $pkgt) = new_bp_root();
    my $full_line = jsonl_line(assistant_event(epoch => $epoch, cache_read => 800));
    my $truncated = substr($full_line, 0, int(length($full_line) / 2));  # cut mid-object, no \n
    write_file(transcript_path($rt,$bpt,$pkgt), $truncated);
    write_registry($rt, $bpt, $pkgt,
        session_id => 'sess-c10-bad',
        cache_observations => [ { age_min => 10, hit => JSON::PP::true } ]);

    my ($rc_v, $v_v, $err_v) = run_cs('verdict', $rt, $bpt, $pkgt, now => $NOW);
    is($rc_v, 0, 'C10: verdict exits 0 (cleanly classified, not a crash) against a truncated final line')
        or diag("stdout=[$v_v] stderr=$err_v");
    is($v_v, 'cold', 'C10: a truncated/corrupt final line never yields warm') or diag("stdout=[$v_v]");
    ok(not_crashed($err_v), 'C10: no crash signature (Died/panic/uncaught exception) on stderr')
        or diag("stderr=$err_v");

    my ($rc_a, $out_a, $err_a) = run_cs('last_activity', $rt, $bpt, $pkgt, now => $NOW);
    ok(not_crashed($err_a), 'C10: last_activity also does not die against the truncated final line')
        or diag("stderr=$err_a");
}

# =====================================================================================
# C11 -- observe NEVER mutates the transcript. POSITIVE GATE FIRST: observe actually wrote an
# observation to the registry (otherwise "never mutates the transcript" would pass vacuously
# against a do-nothing observe). Uses the REAL 10.3MB transcript for a maximally strong
# byte-identity proof.
# =====================================================================================
{
    my ($root, $bp, $pkg) = new_bp_root();
    require File::Path; File::Path::make_path("$root/blueprints/$bp/runs") unless -d "$root/blueprints/$bp/runs";
    copy($REAL_TRANSCRIPT, transcript_path($root,$bp,$pkg))
        or die "failed to copy real transcript fixture: $!";
    write_registry($root, $bp, $pkg, session_id => 'sess-c11');

    my $before_bytes = read_file(transcript_path($root,$bp,$pkg));
    my $before_sha    = sha256_hex($before_bytes);
    my $before_size   = length($before_bytes);
    my $before_mtime  = (stat(transcript_path($root,$bp,$pkg)))[9];

    my $reg_before = read_registry_pkg($root, $bp, $pkg);
    ok(!(ref $reg_before->{cache_observations} eq 'ARRAY' && @{$reg_before->{cache_observations}}),
        'C11 setup: no cache_observations exist before observe runs');

    my ($rc, $out, $err) = run_cs('observe', $root, $bp, $pkg);
    is($rc, 0, 'C11: observe exits 0 against the real 10.3MB transcript') or diag($err);

    my $reg_after = read_registry_pkg($root, $bp, $pkg);
    my $obs_after = $reg_after->{cache_observations};
    ok(ref $obs_after eq 'ARRAY' && @$obs_after >= 1,
        'C11 POSITIVE GATE: observe actually WROTE an observation entry to the registry')
        or diag('registry after observe: ' . $J->encode($reg_after));

    my $after_bytes = read_file(transcript_path($root,$bp,$pkg));
    my $after_sha    = sha256_hex($after_bytes // '');
    my $after_size   = length($after_bytes // '');

    is($after_size, $before_size, 'C11: transcript byte-length is unchanged after observe');
    is($after_sha, $before_sha, 'C11: transcript sha256 is byte-identical before/after observe (never mutated)');
}

done_testing();
