#!/usr/bin/env perl
# platform: any
# 180 -- IMMUTABLE ORACLE for agent-telemetry/03.
#
# Spec: .ccpraxis-local-data/blueprints/agent-telemetry/specs/03-spec.md
# Package ledger (Decisions & attempt log): .ccpraxis-local-data/blueprints/agent-telemetry/
#       packages/03.md
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. At the time this file is authored,
# track-dispatch.sh reads the payload and enforces the single-writer interlock
# but writes NO dispatch record; the old separate PostToolUse finish hook
# appends to the ledger and clears the marker but never touches the JSON
# dispatch-log; bp-orchestrator.pl's
# mark_judge_inflight/clear_judge_inflight/BpOrch::judge_worker_type/
# judge_blueprint_token/dispatch_log_id/dispatch_log_root do not exist. Every
# assertion below that depends on the new write path is expected to fail on
# MISSING BEHAVIOUR -- a missing record, an undefined sub, or a record shape
# that never appears -- not on a harness error.
#
# THREE DRIVER RULINGS THIS FILE ENCODES (package ledger, 2026-09-08 entries):
#   1. Write set amended: the old separate PostToolUse finish hook is now in
#      scope alongside track-dispatch.sh, so a Task worker's record can be
#      `finish`ed instead of sitting `running` for 2h. NOTE: neither the spec
#      nor the ledger amendment defines HOW the PostToolUse hook is meant to
#      correlate to the PreToolUse-hook-written record (track-dispatch.sh's
#      id is randomly generated -- hk-...-$$-$RANDOM -- and persisted nowhere
#      that finish hook could read it). This file therefore tests only what
#      is safely inferable by extension of already-stated rules (the
#      observer discipline, the gate, bash -n) for it, and does NOT pin a
#      specific id-correlation mechanism. See the report for the flagged gap.
#      [Package 16 batch B/E2 update: that separate finish hook is now
#      merged into track-dispatch.sh; see the AC26-29 and GATE-NEG DEL notes
#      below.]
#   2. bp_hook_gate (the old shared bash guard library) is a plain three-var
#      non-empty check with no other logic. Verified empirically: with
#      BP_LEDGER/BP_DIR/BP_PROJECT_ROOT all unset, EVERY hook here exits 0
#      having done nothing. So every test that expects a hook to DO
#      something exports all three; the negative (unset -> nothing written,
#      exit 0) is pinned explicitly, for BOTH hooks, because it is what
#      keeps them free in unrelated sessions.
#   3. The self-modification risk is narrower than first claimed: a SYNTAX
#      error (or any failure at/before the gate) is the residual risk, and
#      `checks: bash-syntax` already covers it -- pinned as AC33 and for
#      the old finish hook below.
#
# TWO TRAPS THE ARCHITECT FLAGGED, each with a dedicated assertion:
#   - PreToolUse stdout is a protocol channel. AC1/AC2/etc assert the hook's
#     OWN stdout is EMPTY on every allow path (captured separately from
#     stderr -- a merged capture could hide a bare stdout leak).
#   - `--now` is gated behind CCPRAXIS_DISPATCH_LOG_TEST_NOW=1. AC46 runs
#     mark_judge_inflight with that var explicitly UNSET (deleted, not just
#     falsy) and asserts a record is produced -- an implementation that
#     passes --now unconditionally gets exit 2 from the logger and silently
#     writes nothing, which this assertion catches directly.
#
# SAFETY: every fixture lives under File::Temp. This file NEVER reads or
# writes .ccpraxis-local-data/.dispatch-log under the real repo root -- the
# real store holds ~150 live records for the run that dispatched this very
# agent. A snapshot/compare pair at top and bottom of this file is the
# enforcement, not just a comment.
#
# HOUSE PATTERN: %CLEAN_ENV strips every ambient BP_*/CLAUDE_PROJECT_DIR/
# CCPRAXIS_DISPATCH_LOG_TEST_NOW var (mirrors the retired graceful-stop-gate coverage, t/155's own
# rationale -- this suite is itself run inside a coordinator/worker session
# that may have these exported, and an inherited value would produce a false
# pass or a false red). SC()/has_sub() (mirrors t/61) guard every call into a
# not-yet-defined BpOrch sub so a missing sub degrades to a clean `not ok`,
# never a die that aborts the rest of the file. done_testing(), not a
# hand-counted plan -- too many loop-generated cases to keep a plan in sync.
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
my $TRACK       = "$HOOKS/track-dispatch.sh";
my $ORCH        = "$SCRIPTS/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;

plan skip_all => 'track-dispatch.sh not found' unless -f $TRACK;

my $have_bash = do {
    my $out = `bash -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

# ===========================================================================
# SAFETY NET -- never touch the real dispatch-log. Snapshot at start,
# compare at the very end.
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
# Scaffolding
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

# run_hook(HOOKPATH, PAYLOAD_JSON_OR_UNDEF, %env) -> ($exit, $stdout, $stderr)
# %env may include __wall (alarm seconds, default 20) and __cwd (chdir target).
sub run_hook {
    my ($hookpath, $payload, %env) = @_;
    my $wall = delete $env{__wall} // 20;
    my $cwd  = delete $env{__cwd};
    $caseN++;
    # $$ as well as $caseN: AC32 forks five children that each call this with
    # the SAME inherited $caseN, so without the pid they all wrote one
    # payload.json and raced on it -- a child could run the hook on a
    # sibling's payload, two hooks then saw one worker type, the second was
    # deduplicated as already claimed, and AC32 counted fewer than five
    # records (seen on macOS, where fork+exec is slow enough to interleave).
    my $ti = "$ROOT/run$caseN-$$";
    make_path($ti);
    my ($pf, $out_f, $err_f) = ("$ti/payload.json", "$ti/out", "$ti/err");
    write_file($pf, defined $payload ? $payload : '{}');
    local %ENV = (%CLEAN_ENV, BUTLER_STATE_DIR => fwd("$ROOT/butler-state"), %env,
        HOOKPATH => fwd($hookpath), PFILE => fwd($pf),
        OUTFILE  => fwd($out_f),    ERRFILE => fwd($err_f));
    my $old_cwd;
    if ($cwd) { $old_cwd = getcwd(); chdir $cwd or die "chdir $cwd: $!"; }
    my $exit = -1;
    eval {
        local $SIG{ALRM} = sub { die "alarm\n" };
        alarm $wall;
        system('bash', '-c', '"$HOOKPATH" < "$PFILE" > "$OUTFILE" 2> "$ERRFILE"');
        $exit = ($? == -1) ? -1 : WIFEXITED($?) ? WEXITSTATUS($?) : -1;
        alarm 0;
        1;
    } or do { alarm 0; $exit = -1; };
    chdir $old_cwd if $old_cwd;
    return ($exit, read_file($out_f) // '', read_file($err_f) // '');
}

# fresh_env(%extra) -> (%env hash ready for run_hook) with fresh BP_DIR/
# BP_PROJECT_ROOT tempdirs and default BP_BLUEPRINT/BP_PACKAGE, plus the
# plain (unforwarded, for Perl-side fs ops) dirs.
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
sub marker_of { my ($bp_dir, $pkg) = @_; $pkg //= 'p03'; return "$bp_dir/runs/$pkg.active-worker" }

sub task_payload {
    my ($subagent_type, %extra) = @_;
    return $J->encode({ tool_name => 'Task',
        tool_input => { subagent_type => $subagent_type, %extra } });
}

sub plant_record {
    my ($logdir, $id, $fields) = @_;
    make_path($logdir) unless -d $logdir;
    write_file("$logdir/$id.json", $J->encode($fields));
}

# ===========================================================================
# DRIVER FINDING #2 -- the negative gate, pinned explicitly for BOTH hooks.
# With BP_LEDGER/BP_DIR/BP_PROJECT_ROOT all unset, the hook must write
# nothing and exit 0, having read nothing.
# ===========================================================================
# The old separate finish hook's own GATE-NEG row DEL (package 16 batch
# B/E2, code DEL): it was merged into track-dispatch.sh; the gate-unset case for
# the merged hook is exercised below via $TRACK alone, and re-expressed for
# the PostToolUse direction specifically by guards-remake-track-dispatch.t's
# TD-7 (stop-signal/gate cases).
for my $h ([$TRACK, 'track-dispatch.sh']) {
    my ($path, $label) = @$h;
    my ($proj_dir) = "$ROOT/gateneg" . (++$caseN);
    my ($exit, $out, $err) = run_hook($path, task_payload('butler:bp-implementer'));
    is($exit, 0, "GATE-NEG: $label with BP_LEDGER/BP_DIR/BP_PROJECT_ROOT unset -> exit 0");
    is($out, '', "GATE-NEG: $label with the gate unset -> stdout empty");
    ok(!-d "$proj_dir/.ccpraxis-local-data", "GATE-NEG: $label with the gate unset -> no store created anywhere reachable");
}

# ===========================================================================
# AC1-3 -- basic recording. subagent_type: butler:bp-implementer.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $t0 = time;
    my ($exit, $out, $err) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC1: butler:bp-implementer dispatch -> hook exit 0');
    is($out, '', 'AC1: hook stdout is empty (PreToolUse stdout is a protocol channel)');
    is($err, '', 'AC1: hook stderr is empty on the allow path');
    my @files = json_record_files($logdir);
    is(scalar @files, 1, 'AC1: exactly one new *.json record under LOGDIR');

    SKIP: {
        skip 'AC1 did not produce a record file; AC2/AC3 have nothing to decode', 11 unless @files == 1;
        my $rec = read_json($files[0]);
        ok(ref $rec eq 'HASH', 'AC2: the record decodes as a JSON object');
      SKIP: {
        skip 'record did not decode as JSON', 10 unless ref $rec eq 'HASH';
        is($rec->{status},      'running',       'AC2: status=running');
        is($rec->{role},        'worker',        'AC2: role=worker');
        is($rec->{worker_type}, 'bp-implementer','AC2: worker_type normalized to bp-implementer');
        is($rec->{blueprint},   'agent-telemetry','AC2: blueprint=$BP_BLUEPRINT');
        is($rec->{package},     'p03',           'AC2: package=$BP_PACKAGE');
        is($rec->{budget_seconds}, 1800,         'AC2: budget_seconds=1800 (logger default, never a second copy)');
        ok(defined $rec->{started_at} && $rec->{started_at} =~ /^\d+$/, 'AC2: started_at is numeric');
        ok(defined $rec->{started_at} && abs($rec->{started_at} - $t0) <= 120,
            'AC2: started_at is within 120s of the test\'s own clock');
        # Ruling AT-2 (driver, 2026-09-09) originally required note:UNDEF, not
        # ABSENT, because bp-dispatch-log.pl's own `start` CLI verb emitted it
        # unconditionally. Package 14's guards-remake changed the mechanism:
        # TrackDispatch.pm now builds this record IN-PROCESS and never calls
        # that CLI verb at all, so it never sets a `note` key -- absent, not
        # null. The INTENT this AC actually guards -- payload text must never
        # reach the record -- holds either way, so the shape is widened to
        # accept both rather than pinning a CLI code path this hook no longer
        # takes.
        ok(!exists($rec->{note}) || !defined($rec->{note}),
           'AC2: note is absent or null, never payload text (payload text never reaches the record)');
        like($rec->{id}, qr/^hk-[A-Za-z0-9._-]+$/, 'AC3: id matches ^hk-[A-Za-z0-9._-]+$');
      }
        if (ref $rec eq 'HASH') {
            like($rec->{id}, qr/^[A-Za-z0-9._-]+\z/, "AC3: id also matches the logger's own ID shape guard");
            like($rec->{id}, qr/p03/,           'AC3: id contains the $BP_PACKAGE token');
            like($rec->{id}, qr/bp-implementer/,'AC3: id contains the bp-implementer token');
        }
    }
}

# ===========================================================================
# AC4 -- one record per type, normalized, for all seven butler agent types.
# ===========================================================================
for my $base (qw(bp-implementer bp-test-writer bp-ui-prober bp-scout bp-architect bp-reviewer bp-red-team)) {
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my ($exit) = run_hook($TRACK, task_payload("butler:$base"), %$env);
    is($exit, 0, "AC4 ($base): hook exit 0");
    my @files = json_record_files($logdir);
    is(scalar @files, 1, "AC4 ($base): exactly one record");
    if (@files == 1) {
        my $rec = read_json($files[0]);
        is(ref $rec eq 'HASH' ? $rec->{worker_type} : undef, $base,
            "AC4 ($base): worker_type normalized (stripped through the LAST ':')");
    }
}

# ===========================================================================
# AC5 -- a bare (unprefixed) subagent_type normalizes the same way.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my ($exit) = run_hook($TRACK, task_payload('bp-implementer'), %$env);
    is($exit, 0, 'AC5: bare bp-implementer -> hook exit 0');
    my @files = json_record_files($logdir);
    is(scalar @files, 1, 'AC5: exactly one record for the bare form');
    if (@files == 1) {
        my $rec = read_json($files[0]);
        is(ref $rec eq 'HASH' ? $rec->{worker_type} : undef, 'bp-implementer',
            'AC5: worker_type identical to the prefixed-form record');
    }
}

# ===========================================================================
# AC6 -- non-butler types are never recorded.
# ===========================================================================
for my $type ('general-purpose', 'Explore') {
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my ($exit) = run_hook($TRACK, task_payload($type), %$env);
    is($exit, 0, "AC6 ($type): hook exit 0");
    is(scalar(json_record_files($logdir)), 0, "AC6 ($type): zero record files");
    ok(!-e marker_of($bp_dir), "AC6 ($type): no marker (non-writer AND non-butler)");
}

# ===========================================================================
# AC7 -- tool_input present, no subagent_type.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $payload = $J->encode({ tool_name => 'Task', tool_input => {} });
    my ($exit) = run_hook($TRACK, $payload, %$env);
    is($exit, 0, 'AC7: missing subagent_type -> exit 0');
    is(scalar(json_record_files($logdir)), 0, 'AC7: no record');
    ok(!-e marker_of($bp_dir), 'AC7: no marker');
}

# ===========================================================================
# AC8 -- malformed JSON.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my ($exit) = run_hook($TRACK, '{"tool_input":', %$env);
    is($exit, 0, 'AC8: malformed JSON -> exit 0');
    is(scalar(json_record_files($logdir)), 0, 'AC8: no record');
    ok(!-e marker_of($bp_dir), 'AC8: no marker');
}

# ===========================================================================
# AC9 -- enormous payload (>=1MiB prompt), bounded.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $huge = 'x' x (1024 * 1024 + 100);
    my $payload = $J->encode({ tool_name => 'Task',
        tool_input => { subagent_type => 'butler:bp-implementer', prompt => $huge } });
    my $start = time;
    my ($exit, $out, $err) = run_hook($TRACK, $payload, %$env, __wall => 25);
    my $elapsed = time - $start;
    is($exit, 0, 'AC9: >=1MiB prompt -> exit 0');
    cmp_ok($elapsed, '<', 20, "AC9: returns promptly ($elapsed s elapsed, bounded)");
    my @files = json_record_files($logdir);
    is(scalar @files, 1, 'AC9: exactly one record');
    if (@files == 1) {
        my $rec = read_json($files[0]);
        # Ruling AT-2, widened per AC2 above -- note is absent or null, never text.
        ok(ref $rec eq 'HASH' && (!exists($rec->{note}) || !defined($rec->{note})),
           'AC9: note is null, never payload text (payload text never reaches the record)');
    }
    unlike($J->encode({}) . $out . $err, qr/\Q$huge\E/, 'AC9: the giant prompt text does not leak into hook output');
}

# ===========================================================================
# AC10 -- kill switch BP_DISPATCH_LOG_OFF=1.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env(BP_DISPATCH_LOG_OFF => '1');
    my $logdir = logdir_of($proj);
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC10: BP_DISPATCH_LOG_OFF=1 -> exit 0');
    is(scalar(json_record_files($logdir)), 0, 'AC10: no record written');
    my $mk = marker_of($bp_dir);
    ok(-f $mk, 'AC10: marker STILL written for a writer type (interlock is untouched by the kill switch)');
    is(read_file($mk), 'butler:bp-implementer', 'AC10: marker bytes identical to the non-killed path');
}

# ===========================================================================
# AC11 -- interlock marker bytes, frozen (guards t/155 A7).
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    my $mk = marker_of($bp_dir);
    ok(-f $mk, 'AC11: marker file created for a writer type');
    my $bytes = read_file($mk);
    is($bytes, 'butler:bp-implementer', 'AC11: marker contains exactly the raw subagent_type bytes');
    unlike($bytes, qr/\n\z/, 'AC11: marker carries no trailing newline');
}

# ===========================================================================
# AC12 -- interlock block: writer while marker holds another writer.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $mk = marker_of($bp_dir);
    make_path("$bp_dir/runs");
    write_file($mk, 'butler:bp-implementer');
    my ($exit, $out, $err) = run_hook($TRACK, task_payload('butler:bp-test-writer'), %$env);
    is($exit, 2, 'AC12: second writer dispatch while marker holds a writer -> exit 2');
    like($err, qr/BLOCKED: a write-capable worker \(/, 'AC12: stderr carries the pre-existing BLOCKED message');
    like($err, qr/butler:bp-implementer/, 'AC12: stderr names the current marker value');
    is(read_file($mk), 'butler:bp-implementer', 'AC12: marker byte-unchanged');
    is(scalar(json_record_files($logdir)), 0, 'AC12: zero records -- the blocked dispatch never launches');
}

# ===========================================================================
# AC13 -- writer while marker holds a non-writer -> allowed, overwritten, recorded.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $mk = marker_of($bp_dir);
    make_path("$bp_dir/runs");
    write_file($mk, 'butler:bp-reviewer');
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC13: writer over a non-writer marker -> exit 0');
    is(read_file($mk), 'butler:bp-implementer', 'AC13: marker overwritten with the new raw type');
    is(scalar(json_record_files($logdir)), 1, 'AC13: one record written');
}

# ===========================================================================
# AC14 -- read-only type: no marker, one record.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-reviewer'), %$env);
    is($exit, 0, 'AC14: read-only type -> exit 0');
    ok(!-e marker_of($bp_dir), 'AC14: no marker file created');
    is(scalar(json_record_files($logdir)), 1, 'AC14: one record written');
}

# ===========================================================================
# AC15 -- stop signals: .paused, .shutdown, <pkg>.force-stop.
# ===========================================================================
for my $sig (
    { label => '.paused',            file => sub { my $bp=shift; "$bp/runs/.paused" } },
    { label => '.shutdown',          file => sub { my $bp=shift; "$bp/runs/.shutdown" } },
    { label => '<pkg>.force-stop',   file => sub { my $bp=shift; "$bp/runs/p03.force-stop" } },
) {
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    make_path("$bp_dir/runs");
    write_file($sig->{file}->($bp_dir), '');
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, "AC15 ($sig->{label}): exit 0");
    ok(!-e marker_of($bp_dir), "AC15 ($sig->{label}): no marker");
    is(scalar(json_record_files($logdir)), 0, "AC15 ($sig->{label}): no record");
}

# ===========================================================================
# AC16 -- BP_ROLE=judge.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env(BP_ROLE => 'judge');
    my $logdir = logdir_of($proj);
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC16: BP_ROLE=judge -> exit 0');
    ok(!-e marker_of($bp_dir), 'AC16: no marker');
    is(scalar(json_record_files($logdir)), 0, 'AC16: no record');
}

# ===========================================================================
# AC17 -- BP_LEDGER unset (gate fails).
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    delete $env->{BP_LEDGER};
    my $logdir = logdir_of($proj);
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC17: BP_LEDGER unset -> exit 0');
    is(scalar(json_record_files($logdir)), 0, 'AC17: no record');
}

# ===========================================================================
# AC18-24 -- deduplication.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $t0 = time;
    plant_record($logdir, 'coord-issued-1',
        { id => 'coord-issued-1', worker_type => 'bp-implementer', started_at => $t0 - 5,
          budget_seconds => 1800, status => 'running' });
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC18: dedup suppresses -> exit 0');
    is(scalar(json_record_files($logdir)), 1, 'AC18: file count unchanged (only the planted record)');
}
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $t0 = time;
    plant_record($logdir, 'coord-issued-2',
        { id => 'coord-issued-2', worker_type => 'bp-implementer', started_at => $t0 - 125,   # Ruling AT-3: same clock-jitter reasoning; keeps the
        # OUTSIDE-the-window property under test with slack.
          budget_seconds => 1800, status => 'running' });
    run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is(scalar(json_record_files($logdir)), 2, 'AC19: started_at=now-121 (outside window) -> a new record IS written');
}
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $t0 = time;
    plant_record($logdir, 'coord-boundary-in',
        { id => 'coord-boundary-in', worker_type => 'bp-implementer', started_at => $t0 - 118,   # Ruling AT-3: was the EXACT 120s boundary. The test
        # captures $t0 with Perl time(); the hook computes its own now with `date
        # +%s`. A second ticking over between them pushes elapsed to 121, outside
        # the window, and a second record is written -- a false red with no defect
        # behind it. The test-writer predicted this jitter and used the literal
        # boundary anyway. The hook has no clock seam (unlike the CLI's --now) and
        # deliberately should not grow one, so the exact boundary is untestable
        # here; 118 keeps the INSIDE-the-window property under test with slack.
          budget_seconds => 1800, status => 'running' });
    run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is(scalar(json_record_files($logdir)), 1, 'AC19 boundary: started_at=now-120 -> suppresses');
}
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $t0 = time;
    plant_record($logdir, 'coord-other-pkg',
        { id => 'coord-other-pkg', worker_type => 'bp-implementer', started_at => $t0 - 5,
          budget_seconds => 1800, status => 'running', package => 'other-package' });
    run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is(scalar(json_record_files($logdir)), 2, 'AC20: a DIFFERENT present package -> a new record IS written');
}
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $t0 = time;
    plant_record($logdir, 'coord-done',
        { id => 'coord-done', worker_type => 'bp-implementer', started_at => $t0 - 5,
          budget_seconds => 1800, status => 'done' });
    run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is(scalar(json_record_files($logdir)), 2, 'AC21: a non-running status -> a new record IS written');
}
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    my $t0 = time;
    plant_record($logdir, 'coord-prefixed',
        { id => 'coord-prefixed', worker_type => 'butler:bp-implementer', started_at => $t0 - 5,
          budget_seconds => 1800, status => 'running' });
    run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is(scalar(json_record_files($logdir)), 1, 'AC22: a PREFIXED worker_type on the planted side still suppresses (normalized both sides)');
}
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    make_path($logdir);
    for my $i (1 .. 2001) {
        write_file("$logdir/noise-$i.json", '{"status":"done"}');
    }
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC23: over-cap (2001 files) -> exit 0');
    is(scalar(json_record_files($logdir)), 2001, 'AC23: no new record written -- file count unchanged');
}
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    # Ruling AT-2: the fixture used bp-implementer + bp-test-writer, but
    # is_writer() (track-dispatch.sh:30) matches BOTH, so the single-writer
    # interlock -- whose behaviour AC12 pins as UNCHANGED -- blocks the second
    # dispatch with exit 2 before the write-step runs, and only one record can
    # exist. Expecting two contradicted this oracle's own AC12. Switched to two
    # NON-writer types, which is the case the spec's own 2.3 names: "the common
    # parallel case -- review || red-team -- is two different worker types".
    run_hook($TRACK, task_payload('butler:bp-reviewer'), %$env);
    run_hook($TRACK, task_payload('butler:bp-scout'), %$env);
    my @files = json_record_files($logdir);
    is(scalar @files, 2, 'AC24: two DIFFERENT butler types within the window -> two records');
    if (@files == 2) {
        my @ids = map { (read_json($_) // {})->{id} // '' } @files;
        isnt($ids[0], $ids[1], 'AC24: the two records have distinct ids');
        ok((grep { /running/ } map { (read_json($_) // {})->{status} // '' } @files) == 2,
            'AC24: both records are running');
    }
}

# ===========================================================================
# AC25 -- absent store: .ccpraxis-local-data does not exist beforehand.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    ok(!-d "$proj/.ccpraxis-local-data", 'AC25 precondition: no .ccpraxis-local-data before the dispatch');
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC25: exit 0');
    my $logdir = logdir_of($proj);
    ok(-d $logdir, 'AC25: the directory tree now exists');
    is(scalar(json_record_files($logdir)), 1, 'AC25: exactly one record exists');
}

# ===========================================================================
# AC26-29 -- DEL (package 16 batch B/E2, code DEL). This block simulated a
# "stubbed sibling logger" by copying ONLY hooks/track-dispatch.sh (plus the
# retired shared bash guard library it used to source) into a fresh stub root and swapping
# in a fake scripts/bp-dispatch-log.pl next to it, relying on the OLD
# track-dispatch.sh finding its sibling logger by a RELATIVE shell path.
# That premise is gone twice over: (1) the current track-dispatch.sh is a
# thin wrapper that first looks for hooks/run-hook.sh NEXT TO ITSELF and
# exits 0 doing nothing if it is missing -- copying the one file without
# run-hook.sh and the rest of hooks/ never reaches the guard at all; (2) even
# with run-hook.sh copied too, BpHook::Guards::TrackDispatch now `require`s
# bp-dispatch-log.pl IN-PROCESS by a path relative to ITS OWN install
# location ($SELF_DIR/../../bp-dispatch-log.pl), never the stub root, so a
# stubbed sibling script would simply never be reached. No test yet exercises
# the real degradation seam (TrackDispatch.pm's $DISPATCH_LOG_OK eval-require
# failing) -- flagged as an open gap, not fabricated here.
# ===========================================================================

# ===========================================================================
# AC30 -- non-absolute BP_PROJECT_ROOT.
# ===========================================================================
{
    my ($env, $bp_dir) = fresh_env(BP_PROJECT_ROOT => '.');
    my $cwd_dir = "$ROOT/ac30cwd"; make_path($cwd_dir);
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env, __cwd => $cwd_dir);
    is($exit, 0, 'AC30: BP_PROJECT_ROOT="." -> exit 0');
    ok(!-d "$cwd_dir/.ccpraxis-local-data", 'AC30: no .ccpraxis-local-data created under the hook\'s cwd');
}

# ===========================================================================
# AC31 -- bad attribution is omitted, not guessed.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env(BP_BLUEPRINT => '../evil', BP_PACKAGE => '');
    my $logdir = logdir_of($proj);
    my ($exit) = run_hook($TRACK, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC31: bad attribution -> exit 0, still records');
    my @files = json_record_files($logdir);
    is(scalar @files, 1, 'AC31: a record is still written');
    if (@files == 1) {
        my $rec = read_json($files[0]);
        ok(ref $rec eq 'HASH' && !exists $rec->{blueprint}, 'AC31: no blueprint key');
        ok(ref $rec eq 'HASH' && !exists $rec->{package},   'AC31: no package key');
        like($rec->{id}, qr/nobp/,  'AC31: id contains nobp');
        like($rec->{id}, qr/nopkg/, 'AC31: id contains nopkg');
    }
}

# ===========================================================================
# AC32 -- concurrency. Mirrors t/155's own bg_supported gate: fork/kill is
# only exercised on Linux/Darwin in this codebase's own convention.
# ===========================================================================
my $bg_supported = ($^O eq 'linux' || $^O eq 'darwin') ? 1 : 0;
SKIP: {
    skip "this OS ($^O) does not support the fork protocol AC32 uses (matches t/155's own gate)", 3
        unless $bg_supported;
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    # ONE write-capable type only. TrackDispatch's writer interlock (pinned by
    # guards-remake-track-dispatch.t, "a write-capable worker ... is already
    # in flight") denies a second concurrent writer by design, so the old
    # list -- implementer, test-writer and ui-prober side by side -- made
    # this a race over which writer won, never a test of the record path.
    my @types = qw(bp-implementer bp-scout bp-architect bp-reviewer bp-redteam);
    my @pids;
    for my $t (@types) {
        my $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            run_hook($TRACK, task_payload("butler:$t"), %$env);
            exit 0;
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;
    my @files = json_record_files($logdir);
    is(scalar @files, 5, 'AC32: five concurrent hooks, five distinct worker types -> five records');
    my @ids = grep { defined } map { (read_json($_) // {})->{id} } @files;
    my %uniq = map { ($_ => 1) } @ids;
    is(scalar(keys %uniq), 5, 'AC32: five distinct ids');
    ok((grep { !defined($_) } map { read_json($_) } @files) == 0, 'AC32: every record decodes as valid JSON');
}

# ===========================================================================
# AC32b -- the race AC32 can only hit by chance, made deterministic: another
# hook creates <proj>/.ccpraxis-local-data between this hook's -d check and
# its own mkdir, so that mkdir fails with EEXIST. The record must still be
# written. BpDispatchLog::_mkdir_p gives up on that first EEXIST, and before
# TrackDispatch retried it the record write went to a directory that did
# not exist yet and was lost without a trace (no stderr, rc 0). Runs the
# module in a perl child, the way run-hook.sh does, with a CORE::GLOBAL
# mkdir that plays the other hook exactly once. Any OS: no fork.
# ===========================================================================
{
    my ($env, $bp_dir, $proj) = fresh_env();
    my $logdir = logdir_of($proj);
    $caseN++;
    my $ti = "$ROOT/run$caseN-race";
    make_path($ti);
    my ($pf, $out_f, $err_f) = ("$ti/payload.json", "$ti/out", "$ti/err");
    write_file($pf, task_payload('butler:bp-scout'));
    my $code = <<'PERL';
use Errno ();
BEGIN {
    my $raced = 0;
    *CORE::GLOBAL::mkdir = sub {
        my ($d, @mode) = @_;
        if (!$raced && defined $d && $d =~ m{/\.ccpraxis-local-data\z}) {
            $raced = 1;
            CORE::mkdir($d);            # the concurrent hook wins the race
            $! = Errno::EEXIST();
            return 0;
        }
        return @mode ? CORE::mkdir($d, $mode[0]) : CORE::mkdir($d);
    };
}
require BpHook;
my $r = BpHook::main('Guards::TrackDispatch');
exit((defined $r && $r == 2) ? 2 : 0);
PERL
    local %ENV = (%CLEAN_ENV, BUTLER_STATE_DIR => fwd("$ROOT/butler-state"), %$env,
        RACECODE => $code, SCRIPTSDIR => $SCRIPTS, PFILE => fwd($pf),
        OUTFILE => fwd($out_f), ERRFILE => fwd($err_f));
    system('bash', '-c', 'perl -I"$SCRIPTSDIR" -e "$RACECODE" < "$PFILE" > "$OUTFILE" 2> "$ERRFILE"');
    my $exit = WIFEXITED($?) ? WEXITSTATUS($?) : -1;
    is($exit, 0, 'AC32b: a log dir another hook created mid-mkdir -> exit 0');
    ok(-d "$proj/.ccpraxis-local-data", 'AC32b: fixture sanity -- the simulated racer did create the data dir');
    is(scalar(json_record_files($logdir)), 1,
       'AC32b: the record is still written when the first mkdir of the log dir hits EEXIST')
        or diag('stderr: ' . (read_file($err_f) // ''));
}

# ===========================================================================
# AC33 -- bash -n clean.
# ===========================================================================
{
    my $out = `bash -n "$TRACK" 2>&1`;
    is($? >> 8, 0, "AC33: bash -n $TRACK exits 0") or diag($out);
}

# ===========================================================================
# AC35 -- DEL (package 16 batch B/E2, code DEL). This pinned bp_read_payload
# being called bare, on its own line, directly inside track-dispatch.sh --
# a bash-monolith-era shape. Package 16 batch B flattened every hook to a
# 5-line exec shim (`d=...; exec bash "$d/run-hook.sh" TrackDispatch -- "$@"`)
# that reads no payload itself at all; bp_read_payload does not exist
# anywhere in the current tree (the old shared bash guard library, its home, is on the deletion
# list). The underlying safety concern -- no argument-less $(cat) reading
# stdin unbounded -- is now generic to run-hook.sh (the one shared entry
# every hook execs), not specific to track-dispatch.sh, and is NOT yet
# re-expressed as a dedicated assertion anywhere; flagged as an open gap
# rather than fabricated here.
# ===========================================================================

# ===========================================================================
# AC37 ($TRACK half) -- DEL (package 16 batch B/E2, code DEL). track-dispatch.sh
# no longer shells `--role` to bp-dispatch-log.pl at all -- it is a 5-line
# exec shim now, and BpHook::Guards::TrackDispatch.pm sets its dispatch-log
# record's role directly as a perl literal (role => 'worker'), never via a
# CLI flag, so the "--role\W+..." regex this AC used has nothing left to
# match in that file. TrackDispatch.pm also compares an UNRELATED "role"
# concept (BpHook::role($p), the session's driver/reporter role) that is not
# part of the coordinator/worker/judge closed set this AC polices, so
# broadening the pattern to catch perl-literal roles risks conflating the
# two. The $ORCH half below is unaffected and still runs for real.
# ===========================================================================
{
    my $src = read_file($ORCH);
    my @matches = $src =~ /--role\W+['"]?([A-Za-z][A-Za-z0-9_-]*)/g;
    ok(scalar(@matches) >= 1, "AC37: $ORCH actually passes --role at least once (non-vacuous)");
    my @bad = grep { $_ !~ /^(coordinator|worker|judge)$/ } @matches;
    is_deeply(\@bad, [], "AC37: ${ORCH}'s --role values are all in {coordinator,worker,judge}")
        or diag("offending values: @bad");
}

# ===========================================================================
# The old separate log-dispatch hook's finish-side coverage above -- DEL
# (package 16 batch B/E2, code DEL): that hook is on package 16's deletion
# list, merged into track-dispatch.sh by package 14's guards-remake
# (BpHook::Guards::TrackDispatch). Its jq-shelled implementation is gone
# too, so the whole "bash -n / gate / observer discipline for the SEPARATE
# finish hook" premise no longer applies. Re-expressed by:
#   - bash -n on the merged hook: AC33 above, and guards-remake-track-
#     dispatch.t's SH-1.
#   - PostToolUse never fails the dispatch, and the ledger/marker-clear
#     behaviour on finish: guards-remake-track-dispatch.t's TD-5/TD-6, and
#     this file's own AC1-AC24 track-dispatch.sh coverage.
# NOT re-expressed anywhere yet (flagged, not fabricated): the OLD
# subprocess-logger "broken/missing sibling" degradation no longer applies
# either -- the current TrackDispatch guard requires bp-dispatch-log.pl
# IN-PROCESS ($DISPATCH_LOG_OK, TrackDispatch.pm) rather than shelling to a
# sibling script, and no test yet exercises that require failing.
# ===========================================================================

# ===========================================================================
# BpOrch:: -- load as a library.
# ===========================================================================
my $ORCH_LOADED = do {
    local $@;
    eval { require $ORCH };
    !$@;
};
ok($ORCH_LOADED, 'bp-orchestrator.pl requires cleanly as (at least) package BpOrch');

sub has_sub { my ($fq) = @_; no strict 'refs'; return defined &{$fq}; }
sub SC {
    my ($fq, @args) = @_;
    return undef unless has_sub($fq);
    no strict 'refs';
    my $r = eval { &{$fq}(@args) };
    if ($@) { diag("call to $fq died (guarded): $@"); return undef; }
    return $r;
}

# ===========================================================================
# AC38 -- BpOrch::judge_worker_type mapping.
# ===========================================================================
is(SC('BpOrch::judge_worker_type', 'resolve'),            'bp-resolve-judge',     'AC38: resolve -> bp-resolve-judge');
is(SC('BpOrch::judge_worker_type', 'harvest'),             'bp-harvest-judge',     'AC38: harvest -> bp-harvest-judge');
is(SC('BpOrch::judge_worker_type', 'conformance'),         'bp-conformance-judge', 'AC38: conformance -> bp-conformance-judge');
is(SC('BpOrch::judge_worker_type', 'escalation-resolve'),  'bp-escalation-resolver','AC38: escalation-resolve -> bp-escalation-resolver');

# ===========================================================================
# PIN (SS2.4 pure helpers) -- judge_blueprint_token / dispatch_log_id /
# dispatch_log_root, unit-tested without a filesystem. Supplementary to the
# numbered ACs; supports AC39/AC45/AC47.
# ===========================================================================
is(SC('BpOrch::judge_blueprint_token', '/x/bp1/runs'), 'bp1',
    'PIN: judge_blueprint_token basename(dirname($runs)) for a normal path');
is(SC('BpOrch::judge_blueprint_token', '/x/../runs'), undef,
    'PIN: judge_blueprint_token rejects ".." as the blueprint token');
is(SC('BpOrch::dispatch_log_id', '/x/bp1/runs', 'resolve', 'p'), 'jd-bp1-resolve-p',
    'PIN: dispatch_log_id for a normal blueprint/kind/pkg');
is(SC('BpOrch::dispatch_log_id', '/x/bp1/runs', 'conformance', '_run'), 'jd-bp1-conformance-_run',
    'PIN: dispatch_log_id -- "_run" is a legal package token');
is(SC('BpOrch::dispatch_log_id', '/x/bp1/runs', 'resolve', '..'), undef,
    'PIN: dispatch_log_id rejects ".." as the package token');
is(SC('BpOrch::dispatch_log_root', '/x/.ccpraxis-local-data/blueprints/bp1/runs'), '/x',
    'PIN: dispatch_log_root -- rule 1, prefix before /.ccpraxis-local-data/');
{
    local $ENV{CLAUDE_PROJECT_DIR} = '/y/project';
    is(SC('BpOrch::dispatch_log_root', '/z/bp1/runs'), '/y/project',
        'PIN: dispatch_log_root -- rule 2, CLAUDE_PROJECT_DIR when no data-dir segment is present');
}
{
    local $ENV{CLAUDE_PROJECT_DIR};
    delete $ENV{CLAUDE_PROJECT_DIR};
    is(SC('BpOrch::dispatch_log_root', '/z/bp1/runs'), undef,
        'PIN: dispatch_log_root -- rule 3, undef when neither resolves');
}

# ===========================================================================
# AC39/40 -- mark_judge_inflight writes a judge record; return value unchanged.
# ===========================================================================
{
    $caseN++;
    my $data_root = "$ROOT/orchdata$caseN"; make_path($data_root);
    my $bp_dir = "$ROOT/orchbp$caseN/bp1"; make_path("$bp_dir/runs");
    my $runs = "$bp_dir/runs";
    local $ENV{CLAUDE_PROJECT_DIR} = fwd($data_root);
    my $now = time;
    my $rv = SC('BpOrch::mark_judge_inflight', $runs, 'resolve', 'p', $now);
    is($rv, 1, 'AC40: mark_judge_inflight still returns 1');
    my $inflight = SC('BpOrch::judge_inflight', $runs, 'resolve', 'p');
    is($inflight, $now, 'AC40: inflight marker still contains the epoch, byte-identical to today');

    my $logdir = logdir_of($data_root);
    my @files = json_record_files($logdir);
    is(scalar @files, 1, 'AC39: exactly one dispatch-log record for the judge');
    if (@files == 1) {
        my $rec = read_json($files[0]);
        is(ref $rec eq 'HASH' ? $rec->{id} : undef, 'jd-bp1-resolve-p', 'AC39: id is jd-<bp>-resolve-p');
        is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'judge', 'AC39: role=judge');
        is(ref $rec eq 'HASH' ? $rec->{worker_type} : undef, 'bp-resolve-judge', 'AC39: worker_type=bp-resolve-judge');
        is(ref $rec eq 'HASH' ? $rec->{package} : undef, 'p', 'AC39: package=p');
        is(ref $rec eq 'HASH' ? $rec->{blueprint} : undef, 'bp1', 'AC39: blueprint=bp1 (basename of dirname($runs))');
        is(ref $rec eq 'HASH' ? $rec->{status} : undef, 'running', 'AC39: status=running');
        ok(ref $rec eq 'HASH' && defined $rec->{started_at} && $rec->{started_at} =~ /^\d+$/,
            'AC39: started_at is numeric');
    }
}

# ===========================================================================
# AC41 -- mark twice without a clear: still one record, started_at unchanged.
# ===========================================================================
{
    $caseN++;
    my $data_root = "$ROOT/orchdata$caseN"; make_path($data_root);
    my $bp_dir = "$ROOT/orchbp$caseN/bp2"; make_path("$bp_dir/runs");
    my $runs = "$bp_dir/runs";
    local $ENV{CLAUDE_PROJECT_DIR} = fwd($data_root);
    my $now1 = time;
    # Ruling AT-3 (driver, 2026-09-09): this block asserted started_at == $now1, a
    # clock the logger NEVER RECEIVES. The orchestrator deliberately does not
    # forward --now, because --now is gated behind CCPRAXIS_DISPATCH_LOG_TEST_NOW=1
    # and passing it would exit 2 and write nothing (the trap AC46 guards). So
    # started_at is the LOGGER's own time(), and the old assertion held only when
    # two unsynchronised clocks landed in the same second. Captured after the first
    # call and compared after the second instead, which tests the property actually
    # under test -- the second start is refused, so started_at does not move.
    my $logdir_ac41 = logdir_of($data_root);
    my $rv1 = SC('BpOrch::mark_judge_inflight', $runs, 'harvest', 'q', $now1);
    my @f1_ac41 = json_record_files($logdir_ac41);
    my $first_started = (@f1_ac41 == 1 && ref(read_json($f1_ac41[0])) eq 'HASH')
                        ? read_json($f1_ac41[0])->{started_at} : undef;
    my $now2 = $now1 + 50;
    my $rv2 = SC('BpOrch::mark_judge_inflight', $runs, 'harvest', 'q', $now2);
    is($rv1, 1, 'AC41: first mark_judge_inflight returns 1');
    is($rv2, 1, 'AC41: second mark_judge_inflight (armed twice, no clear) also returns 1');
    my $logdir = logdir_of($data_root);
    my @files = json_record_files($logdir);
    is(scalar @files, 1, 'AC41: still exactly one record file');
    if (@files == 1) {
        my $rec = read_json($files[0]);
        is(ref $rec eq 'HASH' ? $rec->{started_at} : undef, $first_started,
            'AC41: started_at is unchanged from the FIRST call (logger refuses the second start)');
    }
}

# ===========================================================================
# AC42-44 -- clear_judge_inflight settle behaviour.
# ===========================================================================
{
    $caseN++;
    my $data_root = "$ROOT/orchdata$caseN"; make_path($data_root);
    my $bp_dir = "$ROOT/orchbp$caseN/bp3"; make_path("$bp_dir/runs");
    my $runs = "$bp_dir/runs";
    local $ENV{CLAUDE_PROJECT_DIR} = fwd($data_root);
    my $now = time;
    SC('BpOrch::mark_judge_inflight', $runs, 'resolve', 'r', $now);
    my $verdict_path = SC('BpOrch::judge_verdict_path', $runs, 'resolve', 'r');
    if (defined $verdict_path) { make_path("$runs/resolve"); write_file($verdict_path, '{"action":"relaunch"}'); }
    SC('BpOrch::clear_judge_inflight', $runs, 'resolve', 'r');

    my $logdir = logdir_of($data_root);
    my @files = json_record_files($logdir);
    is(scalar @files, 1, 'AC42: still exactly one record file after settle');
    my $rec42 = @files ? read_json($files[0]) : undef;
    is(ref $rec42 eq 'HASH' ? $rec42->{status} : undef, 'done', 'AC42: status=done when a verdict file is present');
    ok(ref $rec42 eq 'HASH' && exists $rec42->{ended_at}, 'AC42: ended_at present');
    ok(ref $rec42 eq 'HASH' && exists $rec42->{duration_seconds}, 'AC42: duration_seconds present');
    my $hist_path = "$logdir/history.jsonl";
    my @hist_lines_1 = -f $hist_path ? split /\n/, (read_file($hist_path) // '') : ();
    is(scalar(grep { /\S/ } @hist_lines_1), 1, 'AC42: history.jsonl gained exactly one line');
    if (@hist_lines_1) {
        my $h = eval { JSON::PP->new->decode($hist_lines_1[0]) };
        is(ref $h eq 'HASH' ? $h->{worker_type} : undef, 'bp-resolve-judge', 'AC42: history line names worker_type=bp-resolve-judge');
    }
    my $rec42_bytes = @files ? read_file($files[0]) : undef;

    # AC44, chained: clear_judge_inflight again -- no inflight marker exists now
    # (the previous clear removed it) -- the already-settled record must be
    # byte-unchanged and history.jsonl must gain no further line.
    SC('BpOrch::clear_judge_inflight', $runs, 'resolve', 'r');
    my @files_after = json_record_files($logdir);
    is(scalar @files_after, 1, 'AC44: still exactly one record file (no second finish)');
    is(read_file($files_after[0] // ''), $rec42_bytes, 'AC44: the already-settled record is byte-unchanged');
    my @hist_lines_2 = -f $hist_path ? split /\n/, (read_file($hist_path) // '') : ();
    is(scalar(grep { /\S/ } @hist_lines_2), scalar(grep { /\S/ } @hist_lines_1),
        'AC44: history.jsonl gains no additional line');
}
{
    $caseN++;
    my $data_root = "$ROOT/orchdata$caseN"; make_path($data_root);
    my $bp_dir = "$ROOT/orchbp$caseN/bp4"; make_path("$bp_dir/runs");
    my $runs = "$bp_dir/runs";
    local $ENV{CLAUDE_PROJECT_DIR} = fwd($data_root);
    my $now = time;
    SC('BpOrch::mark_judge_inflight', $runs, 'harvest', 's', $now);
    # deliberately NO verdict file
    SC('BpOrch::clear_judge_inflight', $runs, 'harvest', 's');
    my $logdir = logdir_of($data_root);
    my @files = json_record_files($logdir);
    my $rec = @files ? read_json($files[0]) : undef;
    is(ref $rec eq 'HASH' ? $rec->{status} : undef, 'interrupted', 'AC43: no verdict file -> status=interrupted');
    my $hist_path = "$logdir/history.jsonl";
    my @hist_lines = -f $hist_path ? split /\n/, (read_file($hist_path) // '') : ();
    is(scalar(grep { /\S/ } @hist_lines), 0, 'AC43: no history.jsonl line for an interrupted judge');
}

# ===========================================================================
# AC45 -- conformance kind, package "_run".
# ===========================================================================
{
    $caseN++;
    my $data_root = "$ROOT/orchdata$caseN"; make_path($data_root);
    my $bp_dir = "$ROOT/orchbp$caseN/bp5"; make_path("$bp_dir/runs");
    my $runs = "$bp_dir/runs";
    local $ENV{CLAUDE_PROJECT_DIR} = fwd($data_root);
    my $now = time;
    SC('BpOrch::mark_judge_inflight', $runs, 'conformance', '_run', $now);
    my $logdir = logdir_of($data_root);
    my @files = json_record_files($logdir);
    is(scalar @files, 1, 'AC45: exactly one record for the conformance judge');
    if (@files == 1) {
        my $rec = read_json($files[0]);
        is(ref $rec eq 'HASH' ? $rec->{id} : undef, 'jd-bp5-conformance-_run', 'AC45: id=jd-<bp>-conformance-_run');
        is(ref $rec eq 'HASH' ? $rec->{package} : undef, '_run', 'AC45: package=_run');
        is(ref $rec eq 'HASH' ? $rec->{worker_type} : undef, 'bp-conformance-judge', 'AC45: worker_type=bp-conformance-judge');
    }
}

# ===========================================================================
# AC46 -- THE TRAP. CCPRAXIS_DISPATCH_LOG_TEST_NOW explicitly UNSET (deleted,
# not merely falsy). An implementation that passes --now unconditionally gets
# exit 2 from the logger and silently writes NOTHING -- this assertion is
# what would catch that.
# ===========================================================================
{
    $caseN++;
    my $data_root = "$ROOT/orchdata$caseN"; make_path($data_root);
    my $bp_dir = "$ROOT/orchbp$caseN/bp6"; make_path("$bp_dir/runs");
    my $runs = "$bp_dir/runs";
    local $ENV{CLAUDE_PROJECT_DIR} = fwd($data_root);
    local $ENV{CCPRAXIS_DISPATCH_LOG_TEST_NOW};
    delete $ENV{CCPRAXIS_DISPATCH_LOG_TEST_NOW};
    my $now = time;
    my $rv = SC('BpOrch::mark_judge_inflight', $runs, 'resolve', 't', $now);
    is($rv, 1, 'AC46: mark_judge_inflight returns 1 with the test-now seam unset');
    my $logdir = logdir_of($data_root);
    is(scalar(json_record_files($logdir)), 1,
        'AC46 TRAP: a record IS produced with CCPRAXIS_DISPATCH_LOG_TEST_NOW unset -- '
      . 'this fails if the implementation passes --now, which the logger rejects with exit 2');
}

# ===========================================================================
# AC47 -- unresolvable root: CLAUDE_PROJECT_DIR unset, $runs not under a
# .ccpraxis-local-data segment -> no record anywhere, no die, return 1.
# ===========================================================================
{
    $caseN++;
    my $bp_dir = "$ROOT/orchbp$caseN/bp7"; make_path("$bp_dir/runs");
    my $runs = "$bp_dir/runs";
    local $ENV{CLAUDE_PROJECT_DIR};
    delete $ENV{CLAUDE_PROJECT_DIR};
    my $before = real_logdir_snapshot();
    my $now = time;
    my $rv = eval { SC('BpOrch::mark_judge_inflight', $runs, 'resolve', 'u', $now) };
    ok(!$@, 'AC47: mark_judge_inflight does not die when the log root is unresolvable') or diag($@);
    is($rv, 1, 'AC47: mark_judge_inflight still returns 1');
    ok(!-d "$ROOT/orchbp$caseN/.ccpraxis-local-data", 'AC47: no store created under the fixture root');
    my $after = real_logdir_snapshot();
    is_deeply($after, $before, 'AC47: the REAL project .ccpraxis-local-data/.dispatch-log is untouched');
}

# ===========================================================================
# AC48 -- one full BpOrch::run tick, judge fired via an injected spawn_judge,
# produces exactly one dispatch-log record for that judge. Minimal harness
# adapted from t/judge-decision-core.t's own mk_bp/write_creds/run_once pattern.
# ===========================================================================
SKIP: {
    skip 'BpOrch::run not loaded', 1 unless $ORCH_LOADED;
    $caseN++;
    my $data_root = "$ROOT/orchdata$caseN"; make_path($data_root);
    my $dir = "$ROOT/orchtick$caseN/T"; make_path("$dir/packages"); make_path("$dir/runs");
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| A | d | - | sonnet | done |\n";
    close $b;
    open my $l, '>', "$dir/packages/A.md" or die;
    print $l "---\npackage: A\nblueprint: T\nstatus: done\nwrite_set: p/a/\ntest_paths: p/a/\nlast_updated: 2026-06-24T00:00:00Z\n---\n# A\n\n## Next action\n\ngo\n";
    close $l;
    my $NOW = time;
    open my $c, '>:raw', "$dir/creds.json" or die;
    print $c $J->encode({ claudeAiOauth => {
        accessToken=>'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken=>'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt=>($NOW+5*3600)*1000, scopes=>['user:inference'], subscriptionType=>'max', rateLimitTier=>'x' } });
    close $c;
    my $USAGE_OK = $J->encode({ five_hour=>{utilization=>10, resets_at=>'2099-01-01T00:00:00+00:00'},
                                seven_day=>{utilization=>5,  resets_at=>'2099-01-01T12:00:00+00:00'} });
    my $tun = { ceil5=>85,ceil7=>90,drain=>600,max_par=>2,cap=>5,flat=>600,watch_tick=>0,
        keeper_int=>600,keeper_bo=>120,thresh_min=>60,jit_lo=>0,jit_hi=>0,tele_retry=>3,usage_fail=>60,
        busy_path=>"$data_root/busy", harvest=>'audit', resolve_cap=>1, corr_cap=>1, judge_to=>1800 };
    my @spawned;
    local $ENV{CLAUDE_PROJECT_DIR} = fwd($data_root);
    SC('BpOrch::run', {
        blueprint=>'T', bp_dir=>$dir, creds_path=>"$dir/creds.json",
        tunables=>$tun, once=>1, now=>sub { $NOW }, sleep=>sub {},
        http_get  => sub { { status=>200, content=>$USAGE_OK } },
        http_post => sub { { status=>200, content=>'{}' } },
        launch    => sub { 0 },
        spawn_judge => sub { push @spawned, $_[0]; 0 },
    });
    ok(scalar(grep { $_->{kind} eq 'harvest' && $_->{pkg} eq 'A' } @spawned) >= 1,
        'AC48 precondition: the tick actually fired a harvest judge for A') or skip('judge never fired -- AC48 vacuous', 1);
    my $logdir = logdir_of($data_root);
    my @recfiles = json_record_files($logdir);
    my @judge_recs = grep { ref($_) eq 'HASH' && ($_->{role} // '') eq 'judge' }
                     map { read_json($_) } @recfiles;
    is(scalar @judge_recs, 1, 'AC48: exactly one dispatch-log record for the fired judge');
}

# ===========================================================================
# AC49 -- perl -c clean.
# ===========================================================================
{
    my $out = `perl -c "$ORCH" 2>&1`;
    is($? >> 8, 0, "AC49: perl -c $ORCH exits 0") or diag($out);
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
