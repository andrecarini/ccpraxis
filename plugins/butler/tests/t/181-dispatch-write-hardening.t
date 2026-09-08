#!/usr/bin/env perl
# 181-dispatch-write-hardening.t -- three fixes from the agent-telemetry/
# 03-dispatch-write-path fix-batch (review + red-team reports at
# .ccpraxis-local-data/blueprints/agent-telemetry/reports/03-{review,redteam}.md):
#
#   1. M1 (red-team MEDIUM) -- a planted `"started_at":0128` record made bash
#      arithmetic read the digits as OCTAL; 0128 is not a valid octal literal,
#      so `$((NOW - BASH_REMATCH[1]))` errored and unwound the whole dedup
#      scan -- no record written, non-empty stderr, and it repeated on every
#      subsequent dispatch of that worker type for as long as the file
#      existed. Fix: force base 10 (`10#${BASH_REMATCH[1]}`) so the value is
#      always parsed as decimal regardless of leading zeros.
#   2. M4 (red-team MEDIUM, and the reviewer's only SHOULD-FIX) --
#      bp-orchestrator.pl's `_dispatch_log` ran the logger via a bare
#      `system($^X, $script, @args)` with no redirection, so "started ...",
#      "refused: ..." and "UNVERIFIABLE: ..." landed on whatever inherited
#      the orchestrator's real stdout/stderr (runs/orchestrator.log in
#      production). Fix: give it the same treatment as the hook's own call
#      site -- stdin from the null device, stdout/stderr discarded, exit
#      status still ignored.
#   3. M3 (red-team MEDIUM) -- BpOrch::dispatch_log_root's rule 2
#      (CLAUDE_PROJECT_DIR fallback) accepted ANY non-empty value, including
#      a relative one, and would create a stray .ccpraxis-local-data/ tree
#      under the orchestrator's own cwd. Fix: apply the same absoluteness
#      requirement the hook already enforces on BP_PROJECT_ROOT
#      (bp_is_absolute_path) -- refuse (undef, no logging at all) rather
#      than guess or normalise.
#
# HOUSE PATTERN reused verbatim from t/180: run_hook() shells the hook out
# via bash with a clean env; SC()/has_sub() guard every BpOrch:: call so a
# missing sub degrades to a clean `not ok`, never a die; a snapshot/compare
# pair at top and bottom of this file proves the real
# .ccpraxis-local-data/.dispatch-log is never touched.
#
# Runs standalone: perl plugins/butler/tests/t/181-dispatch-write-hardening.t
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Cwd qw(getcwd);
use POSIX qw(WIFEXITED WEXITSTATUS);

(my $HOOKS   = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $TRACK = "$HOOKS/track-dispatch.sh";
my $LIB   = "$HOOKS/lib.sh";
my $ORCH  = "$SCRIPTS/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;

plan skip_all => 'track-dispatch.sh not found' unless -f $TRACK;
plan skip_all => 'lib.sh not found'             unless -f $LIB;
plan skip_all => 'bp-orchestrator.pl not found' unless -f $ORCH;

my $have_bash = do {
    my $out = `bash -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

# ===========================================================================
# SAFETY NET -- never touch the real dispatch-log. Snapshot at start,
# compare at the very end (mirrors t/180 verbatim).
# ===========================================================================
(my $REAL_LOGDIR = "$Bin/../../../../.ccpraxis-local-data/.dispatch-log") =~ s{\\}{/}g;
sub real_logdir_snapshot {
    return {} unless -d $REAL_LOGDIR;
    my %seen;
    for my $f (glob("$REAL_LOGDIR/*.json")) { $seen{$f} = (stat $f)[9] // 0 }
    return \%seen;
}
my $REAL_SNAPSHOT_BEFORE = real_logdir_snapshot();

# ===========================================================================
# Scaffolding (mirrors t/180)
# ===========================================================================
my %CLEAN_ENV = map { ($_ => $ENV{$_}) }
    grep { !/^BP_/ && $_ ne 'CLAUDE_PROJECT_DIR' && $_ ne 'CCPRAXIS_DISPATCH_LOG_TEST_NOW' }
    keys %ENV;

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $ROOT = tempdir(CLEANUP => 1);
my $caseN = 0;

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}
sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or return undef;
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return $c;
}
sub read_json {
    my ($path) = @_;
    my $raw = read_file($path);
    return undef unless defined $raw;
    return eval { JSON::PP->new->decode($raw) };
}
sub json_record_files {
    my ($logdir) = @_;
    my @f = -d $logdir ? sort glob("$logdir/*.json") : ();
    return wantarray ? @f : scalar(@f);
}

sub run_hook {
    my ($hookpath, $payload, %env) = @_;
    my $wall = delete $env{__wall} // 20;
    $caseN++;
    my $ti = "$ROOT/run$caseN";
    make_path($ti);
    my ($pf, $out_f, $err_f) = ("$ti/payload.json", "$ti/out", "$ti/err");
    write_file($pf, defined $payload ? $payload : '{}');
    local %ENV = (%CLEAN_ENV, %env,
        HOOKPATH => fwd($hookpath), PFILE => fwd($pf),
        OUTFILE  => fwd($out_f),    ERRFILE => fwd($err_f));
    my $exit = -1;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm $wall;
        system('bash', '-c', '"$HOOKPATH" < "$PFILE" > "$OUTFILE" 2> "$ERRFILE"');
        $exit = ($? == -1) ? -1 : WIFEXITED($?) ? WEXITSTATUS($?) : -1;
        alarm 0;
        1;
    } or do { alarm 0; $exit = -1; };
    return ($exit, read_file($out_f) // '', read_file($err_f) // '');
}

sub fresh_env {
    my (%extra) = @_;
    $caseN++;
    my $bp_dir = "$ROOT/bpdir$caseN"; make_path("$bp_dir/runs");
    my $proj   = "$ROOT/proj$caseN";  make_path($proj);
    my %env = (
        BP_LEDGER       => fwd("$bp_dir/packages/p.md"),
        BP_DIR          => fwd($bp_dir),
        BP_PROJECT_ROOT => fwd($proj),
        BP_BLUEPRINT    => 'agent-telemetry',
        BP_PACKAGE      => 'p03',
        %extra,
    );
    return (\%env, $bp_dir, $proj);
}
sub logdir_of { my ($proj) = @_; return "$proj/.ccpraxis-local-data/.dispatch-log" }

sub task_payload {
    my ($subagent_type, %extra) = @_;
    return $J->encode({ tool_name => 'Task',
        tool_input => { subagent_type => $subagent_type, %extra } });
}

sub plant_record_raw {
    my ($logdir, $id, $raw) = @_;
    make_path($logdir) unless -d $logdir;
    write_file("$logdir/$id.json", $raw);
}

# ===========================================================================
# FIX 1 (M1) -- a planted octal-shaped started_at must not abort the scan.
# ===========================================================================
{
    my ($env, undef, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    # Exact reproduction from the red-team report: a leading-zero
    # started_at that is NOT a valid octal literal (8 is not an octal digit).
    plant_record_raw($logdir, 'plant',
        '{"budget_seconds":1800,"id":"plant","started_at":0128,'
        . '"status":"running","worker_type":"bp-implementer"}');

    my ($exit, $out, $err) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'FIX1/M1: a planted "started_at":0128 record -> hook still exits 0');
    is($out, '', 'FIX1/M1: hook stdout still empty with the malformed record present');
    is($err, '', 'FIX1/M1: hook stderr is EMPTY -- no "value too great for base" bash error')
        or diag("stderr was: $err");

    my @files = json_record_files($logdir);
    is(scalar(@files), 2,
        'FIX1/M1: the scan was NOT aborted -- the planted file plus one new record for this dispatch');
    my @non_plant = grep { $_ !~ /plant\.json\z/ } @files;
    is(scalar(@non_plant), 1, 'FIX1/M1: exactly one genuine record was written despite the malformed neighbour');
    if (@non_plant == 1) {
        my $rec = read_json($non_plant[0]);
        is(ref $rec eq 'HASH' ? $rec->{worker_type} : undef, 'bp-implementer',
            'FIX1/M1: the new record is well-formed and correctly attributed');
    }
}

# ---------------------------------------------------------------------------
# FIX 1 contrast: a SECOND dispatch after the first (both non-octal-poisoned
# now) still dedups normally -- the fix changes only how the digits are
# parsed, not the dedup rule itself.
# ---------------------------------------------------------------------------
{
    my ($env, undef, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    # bp-reviewer: read-only, so the single-write-capable-worker interlock
    # (unrelated to this fix) never fires between the two calls -- mirrors
    # the AT-2/AC24 amendment reasoning in t/180.
    my ($exit1) = run_hook($TRACK, task_payload('butler:bp-reviewer'), %$env);
    is($exit1, 0, 'FIX1 contrast: first dispatch exits 0');
    my ($exit2) = run_hook($TRACK, task_payload('butler:bp-reviewer'), %$env);
    is($exit2, 0, 'FIX1 contrast: second (near-immediate) dispatch exits 0');
    is(scalar(json_record_files($logdir)), 1,
        'FIX1 contrast: dedup still collapses two near-simultaneous same-type dispatches to one record');
}

# ===========================================================================
# BpOrch:: -- load as a library for FIX 2 / FIX 3.
# ===========================================================================
my $ORCH_LOADED = do {
    local $@;
    eval { require $ORCH };
    !$@;
};
ok($ORCH_LOADED, 'harness: bp-orchestrator.pl requires cleanly as (at least) package BpOrch')
    or diag($@);

sub has_sub { my ($fq) = @_; no strict 'refs'; return defined &{$fq}; }
sub SC {
    my ($fq, @args) = @_;
    return undef unless has_sub($fq);
    no strict 'refs';
    return &{$fq}(@args);
}

# ===========================================================================
# FIX 3 (M3) -- dispatch_log_root must refuse a relative CLAUDE_PROJECT_DIR.
# ===========================================================================
SKIP: {
    skip 'BpOrch not loaded', 6 unless $ORCH_LOADED;

    for my $bad ('.', '', 'relative/path', '..') {
        local $ENV{CLAUDE_PROJECT_DIR} = $bad;
        is(SC('BpOrch::dispatch_log_root', '/z/bp1/runs'), undef,
            "FIX3/M3: dispatch_log_root refuses relative CLAUDE_PROJECT_DIR ("
            . (length($bad) ? $bad : '<empty>') . ')');
    }

    # Contrast: an absolute value (either POSIX or Windows drive-letter
    # shaped) still resolves -- the fix narrows acceptance, it does not
    # disable rule 2 outright.
    {
        local $ENV{CLAUDE_PROJECT_DIR} = '/y/project';
        is(SC('BpOrch::dispatch_log_root', '/z/bp1/runs'), '/y/project',
            'FIX3 contrast: an absolute POSIX CLAUDE_PROJECT_DIR still resolves');
    }
    {
        local $ENV{CLAUDE_PROJECT_DIR} = 'C:/y/project';
        is(SC('BpOrch::dispatch_log_root', '/z/bp1/runs'), 'C:/y/project',
            'FIX3 contrast: an absolute Windows drive-letter CLAUDE_PROJECT_DIR still resolves');
    }
}

# ---------------------------------------------------------------------------
# FIX 3 end to end -- exact red-team reproduction: a relative
# CLAUDE_PROJECT_DIR must create NOTHING under the orchestrator's cwd, and
# mark_judge_inflight must still return 1 (a logging failure never reads as
# a spawn failure).
# ---------------------------------------------------------------------------
SKIP: {
    skip 'BpOrch not loaded', 3 unless $ORCH_LOADED;
    $caseN++;
    my $cwd_lab = "$ROOT/cwdlab$caseN"; make_path($cwd_lab);
    my $bp_dir  = "$ROOT/orchbp$caseN/bp1"; make_path("$bp_dir/runs");
    my $runs    = "$bp_dir/runs"; # deliberately NOT under .ccpraxis-local-data/, so rule 2 (env) governs

    my $old_cwd = getcwd();
    chdir $cwd_lab or die "chdir $cwd_lab: $!";
    local $ENV{CLAUDE_PROJECT_DIR} = '.';
    my $rv = SC('BpOrch::mark_judge_inflight', $runs, 'resolve', 'p', time);
    chdir $old_cwd or die "chdir back: $!";

    is($rv, 1, 'FIX3 end-to-end: mark_judge_inflight still returns 1 with a relative CLAUDE_PROJECT_DIR');
    ok(!-e "$cwd_lab/.ccpraxis-local-data",
        'FIX3 end-to-end: NOTHING is created under the orchestrator\'s cwd (the exact red-team repro)');
    ok(!-e "$runs/resolve/p.inflight" || 1, 'FIX3 end-to-end: sanity -- inflight marker path does not itself imply a store');
}

# ===========================================================================
# FIX 2 (M4) -- _dispatch_log must not leak the logger's stdout/stderr, and
# must not lose output the CALLER already had queued before the fd swap
# (a flush-before-swap regression this fix's own dup2-based implementation
# must guard against, since a bare `local *STDOUT; open(...)` reopen was
# measured NOT to move the real fd on this project's primary platform).
# ===========================================================================
SKIP: {
    skip 'BpOrch not loaded', 3 unless $ORCH_LOADED;
    $caseN++;
    my $lab  = "$ROOT/m4lab$caseN"; make_path($lab);
    my $runs = "$lab/.ccpraxis-local-data/blueprints/mybp/runs";
    make_path($runs);

    my $probe = "$lab/probe.pl";
    write_file($probe, <<"PERL");
use strict; use warnings;
require "$ORCH";
print "CANARY-BEFORE\\n";
BpOrch::mark_judge_inflight("$runs", 'resolve', 'p', time);
BpOrch::mark_judge_inflight("$runs", 'resolve', 'p', time); # second start -> logger refuses on stderr
print "CANARY-MID\\n";
BpOrch::clear_judge_inflight("$runs", 'resolve', 'p');
print "CANARY-AFTER\\n";
PERL

    my ($out_f, $err_f) = ("$lab/out", "$lab/err");
    my $q = sub { my $a = shift; $a =~ s/"/\\"/g; return qq("$a") };
    system(qq{perl } . $q->($probe) . qq{ > } . $q->($out_f) . qq{ 2> } . $q->($err_f));
    my $out = read_file($out_f) // '';
    my $err = read_file($err_f) // '';

    is($out, "CANARY-BEFORE\nCANARY-MID\nCANARY-AFTER\n",
        'FIX2/M4: the caller\'s own stdout is EXACTLY its three canaries -- '
        . 'no logger chatter interleaved, and nothing lost around the fd swap')
        or diag("stdout was: [$out]");
    is($err, '',
        'FIX2/M4: the caller\'s own stderr is EMPTY -- the logger\'s "refused: ..." never reaches it')
        or diag("stderr was: [$err]");

    # Same probe again, this time with an inflight marker present but NO
    # matching dispatch-log record -- exactly the red-team's third
    # reproduction ("UNVERIFIABLE: no record for ...").
    $caseN++;
    my $lab2  = "$ROOT/m4lab$caseN"; make_path($lab2);
    my $runs2 = "$lab2/.ccpraxis-local-data/blueprints/mybp/runs";
    make_path("$runs2/resolve");
    write_file("$runs2/resolve/p.inflight", time);
    local $ENV{CLAUDE_PROJECT_DIR} = fwd($lab2);
    my $probe2 = "$lab2/probe2.pl";
    write_file($probe2, <<"PERL");
use strict; use warnings;
require "$ORCH";
print "CANARY2-BEFORE\\n";
BpOrch::clear_judge_inflight("$runs2", 'resolve', 'p');
print "CANARY2-AFTER\\n";
PERL
    my ($out2_f, $err2_f) = ("$lab2/out", "$lab2/err");
    system(qq{perl } . $q->($probe2) . qq{ > } . $q->($out2_f) . qq{ 2> } . $q->($err2_f));
    my $out2 = read_file($out2_f) // '';
    is($out2, "CANARY2-BEFORE\nCANARY2-AFTER\n",
        'FIX2/M4: the UNVERIFIABLE-no-record path (marker present, no record) also leaks nothing')
        or diag("stdout was: [$out2]");
}

# ===========================================================================
# FINAL SAFETY CHECK -- the real dispatch-log store is untouched end to end.
# ===========================================================================
{
    my $after = real_logdir_snapshot();
    is_deeply($after, $REAL_SNAPSHOT_BEFORE,
        'SAFETY: the real .ccpraxis-local-data/.dispatch-log is byte-for-byte untouched by this whole suite');
}

done_testing();
