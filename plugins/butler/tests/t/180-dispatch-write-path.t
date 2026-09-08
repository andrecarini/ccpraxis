#!/usr/bin/env perl
# 180-dispatch-write-path.t -- IMMUTABLE ORACLE for agent-telemetry/03-dispatch-write-path.
#
# Spec: .ccpraxis-local-data/blueprints/agent-telemetry/specs/03-dispatch-write-path-spec.md
# Package ledger (Decisions & attempt log): .ccpraxis-local-data/blueprints/agent-telemetry/
#       packages/03-dispatch-write-path.md
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. At the time this file is authored,
# track-dispatch.sh reads the payload and enforces the single-writer interlock
# but writes NO dispatch record; log-dispatch.sh appends to the ledger and
# clears the marker but never touches the JSON dispatch-log; bp-orchestrator.pl's
# mark_judge_inflight/clear_judge_inflight/BpOrch::judge_worker_type/
# judge_blueprint_token/dispatch_log_id/dispatch_log_root do not exist. Every
# assertion below that depends on the new write path is expected to fail on
# MISSING BEHAVIOUR -- a missing record, an undefined sub, or a record shape
# that never appears -- not on a harness error.
#
# THREE DRIVER RULINGS THIS FILE ENCODES (package ledger, 2026-09-08 entries):
#   1. Write set amended: plugins/butler/hooks/log-dispatch.sh (PostToolUse
#      counterpart) is now in scope alongside track-dispatch.sh, so a Task
#      worker's record can be `finish`ed instead of sitting `running` for 2h.
#      NOTE: neither the spec nor the ledger amendment defines HOW the
#      PostToolUse hook is meant to correlate to the PreToolUse-hook-written
#      record (track-dispatch.sh's id is randomly generated -- hk-...-$$-
#      $RANDOM -- and persisted nowhere log-dispatch.sh could read it). This
#      file therefore tests only what is safely inferable by extension of
#      already-stated rules (the observer discipline, the gate, bash -n) for
#      log-dispatch.sh, and does NOT pin a specific id-correlation mechanism.
#      See the report for the flagged gap.
#   2. bp_hook_gate (lib.sh:9-13) is a plain three-var non-empty check with no
#      other logic. Verified empirically: with BP_LEDGER/BP_DIR/BP_PROJECT_ROOT
#      all unset, EVERY hook here exits 0 having done nothing. So every test
#      that expects a hook to DO something exports all three; the negative
#      (unset -> nothing written, exit 0) is pinned explicitly, for BOTH hooks,
#      because it is what keeps them free in unrelated sessions.
#   3. The self-modification risk is narrower than first claimed: a SYNTAX
#      error (or any failure at/before the gate) is the residual risk, and
#      `checks: bash-syntax` already covers it -- pinned as AC33 and for
#      log-dispatch.sh below.
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
# CCPRAXIS_DISPATCH_LOG_TEST_NOW var (mirrors t/09-gate.t, t/155's own
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
my $LOGDISPATCH = "$HOOKS/log-dispatch.sh";
my $LIB         = "$HOOKS/lib.sh";
my $DISPATCHLOG = "$SCRIPTS/bp-dispatch-log.pl";
my $ORCH        = "$SCRIPTS/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;

plan skip_all => 'track-dispatch.sh not found' unless -f $TRACK;
plan skip_all => 'lib.sh not found'             unless -f $LIB;

my $have_bash = do {
    my $out = `bash -c 'echo ok' 2>&1`;
    (defined $out && $out =~ /ok/) ? 1 : 0;
};
plan skip_all => 'no usable bash' unless $have_bash;

my $HAVE_JQ = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };

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
    my $ti = "$ROOT/run$caseN";
    make_path($ti);
    my ($pf, $out_f, $err_f) = ("$ti/payload.json", "$ti/out", "$ti/err");
    write_file($pf, defined $payload ? $payload : '{}');
    local %ENV = (%CLEAN_ENV, %env,
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
for my $h ([$TRACK, 'track-dispatch.sh'], [$LOGDISPATCH, 'log-dispatch.sh']) {
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
        # Ruling AT-2 (driver, 2026-09-09): asserted note is UNDEF, not ABSENT.
        # bp-dispatch-log.pl's `start` emits "note => $note" unconditionally (:485)
        # while `finish` conditions it (:634), so every record carries "note":null.
        # That asymmetry is NOT a bug to fix: package 02's AC22 pins byte-identity
        # INCLUDING note:null, because pre-change records have it. The INTENT here --
        # payload text must never reach the record -- is preserved exactly.
        ok(exists $rec->{note} && !defined $rec->{note},
           'AC2: note is null, never payload text (payload text never reaches argv)');
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
        # Ruling AT-2: see AC2 above -- note is null by design, not absent.
        ok(ref $rec eq 'HASH' && exists $rec->{note} && !defined $rec->{note},
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
# AC26-29 -- degradation: a stubbed sibling logger, copied hooks/lib.sh.
# Per the spec's own instruction: no production env override is used or added.
# ===========================================================================
sub mk_stub_env {
    my (%o) = @_;
    $caseN++;
    my $stub_root = "$ROOT/stub$caseN";
    make_path("$stub_root/hooks");
    write_file("$stub_root/hooks/track-dispatch.sh", read_file($TRACK));
    write_file("$stub_root/hooks/lib.sh", read_file($LIB));
    unless (($o{logger} // '') eq 'missing') {
        make_path("$stub_root/scripts");
        my $content =
              ($o{logger} eq 'usage2')
            ? "#!/usr/bin/env perl\nprint STDERR \"bp-dispatch-log: usage error: --role rejected\\n\"; exit 2;\n"
            : ($o{logger} eq 'usage3both')
            ? "#!/usr/bin/env perl\nprint STDOUT \"noise on stdout\\n\"; print STDERR \"noise on stderr\\n\"; exit 3;\n"
            : ($o{logger} eq 'slow')
            ? "#!/usr/bin/env perl\nsleep 2;\nexec(\$^X, '$DISPATCHLOG', \@ARGV) or exit 1;\n"
            : die "unknown stub logger mode $o{logger}";
        write_file("$stub_root/scripts/bp-dispatch-log.pl", $content);
    }
    my $proj = "$ROOT/stubproj$caseN"; make_path($proj);
    my $bp_dir = "$ROOT/stubbp$caseN"; make_path("$bp_dir/runs");
    my %env = (
        BP_LEDGER       => fwd("$bp_dir/packages/p.md"),
        BP_DIR          => fwd($bp_dir),
        BP_PROJECT_ROOT => fwd($proj),
        BP_BLUEPRINT    => 'agent-telemetry',
        BP_PACKAGE      => 'p03',
    );
    return ("$stub_root/hooks/track-dispatch.sh", \%env, $bp_dir, $proj);
}
{
    my ($hookpath, $env, $bp_dir, $proj) = mk_stub_env(logger => 'missing');
    my $logdir = logdir_of($proj);
    my ($exit, $out, $err) = run_hook($hookpath, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC26: missing sibling logger -> exit 0');
    is(scalar(json_record_files($logdir)), 0, 'AC26: no record');
    is($err, '', 'AC26: empty stderr (child failure swallowed by >/dev/null 2>&1)');
    ok(-f marker_of($bp_dir), 'AC26: marker still written for a writer type');
}
{
    my ($hookpath, $env, $bp_dir, $proj) = mk_stub_env(logger => 'usage2');
    my ($exit, $out, $err) = run_hook($hookpath, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC27: stub exits 2 with a usage error -> hook exit 0');
    is($out, '', 'AC27: hook stdout empty');
    is($err, '', 'AC27: hook stderr empty (child stderr swallowed)');
}
{
    my ($hookpath, $env, $bp_dir, $proj) = mk_stub_env(logger => 'usage3both');
    my ($exit, $out, $err) = run_hook($hookpath, task_payload('butler:bp-implementer'), %$env);
    is($exit, 0, 'AC28: stub writes to both streams and exits 3 -> hook exit 0');
    is($out, '', 'AC28: hook stdout empty');
    is($err, '', 'AC28: hook stderr empty');
}
{
    my ($hookpath, $env, $bp_dir, $proj) = mk_stub_env(logger => 'slow');
    my $logdir = logdir_of($proj);
    my $start = time;
    my ($exit) = run_hook($hookpath, task_payload('butler:bp-implementer'), %$env, __wall => 20);
    my $elapsed = time - $start;
    is($exit, 0, 'AC29: slow (2s) real logger -> hook still exits 0');
    is(scalar(json_record_files($logdir)), 1, 'AC29: the record exists (the slow logger really wrote it)');
    cmp_ok($elapsed, '<', 15, "AC29: returns well inside the test's alarm bound ($elapsed s elapsed)");
}

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
    my @types = qw(bp-implementer bp-test-writer bp-ui-prober bp-scout bp-architect);
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
# AC33 -- bash -n clean.
# ===========================================================================
{
    my $out = `bash -n "$TRACK" 2>&1`;
    is($? >> 8, 0, "AC33: bash -n $TRACK exits 0") or diag($out);
}

# ===========================================================================
# AC34 -- t/175 stays green, unmodified.
# ===========================================================================
{
    my $f175 = "$Bin/175-hook-payload-read-bound.t";
    my $out = `perl "$f175" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC34: t/175-hook-payload-read-bound.t exits 0, unmodified') or diag($out);
}

# ===========================================================================
# AC35 -- t/175's own patterns still match track-dispatch.sh specifically.
# ===========================================================================
{
    my $src = read_file($TRACK);
    like($src, qr/^\s*bp_read_payload\s+open\s*$/m,
        'AC35: track-dispatch.sh still calls bp_read_payload open bare, on its own line');
    unlike($src, qr/^\s*[A-Za-z_][A-Za-z0-9_]*=\$\(\s*cat\s*(?:[)|]|\d?>)/m,
        'AC35: track-dispatch.sh has no argument-less $(cat)');
}

# ===========================================================================
# AC36 -- t/09-gate.t and t/155 pass unmodified.
# ===========================================================================
for my $f ('09-gate.t', '155-worker-backend-dispatcher.t') {
    my $path = "$Bin/$f";
    my $out = `perl "$path" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, "AC36: $f exits 0, unmodified") or diag(substr($out, -2000));
}

# ===========================================================================
# AC37 -- no word other than coordinator/worker/judge appears as a --role
# value in track-dispatch.sh or bp-orchestrator.pl, AND --role is actually
# used at least once in each (a file that never mentions --role would
# vacuously "pass" a closed-set check without exercising it).
# ===========================================================================
for my $f ($TRACK, $ORCH) {
    my $src = read_file($f);
    my @matches = $src =~ /--role\W+['"]?([A-Za-z][A-Za-z0-9_-]*)/g;
    ok(scalar(@matches) >= 1, "AC37: $f actually passes --role at least once (non-vacuous)");
    my @bad = grep { $_ !~ /^(coordinator|worker|judge)$/ } @matches;
    is_deeply(\@bad, [], "AC37: ${f}'s --role values are all in {coordinator,worker,judge}")
        or diag("offending values: @bad");
}

# ===========================================================================
# log-dispatch.sh -- the finish side (write-set amendment). Only safely
# inferable behaviour is pinned: bash -n, the gate, and the observer
# discipline (never fails the dispatch on a broken/missing logger). The
# id-correlation mechanism itself is NOT pinned -- see header note and report.
# ===========================================================================
{
    my $out = `bash -n "$LOGDISPATCH" 2>&1`;
    is($? >> 8, 0, "log-dispatch.sh: bash -n exits 0 (DC5/checks: bash-syntax now covers this file too)") or diag($out);
}
{
    # Observer discipline, extended by the same reasoning as track-dispatch.sh's
    # governing rule (SS1.1): a broken/missing sibling logger must not turn a
    # PostToolUse hook into a blocked/erroring one.
    my ($env, $bp_dir, $proj) = fresh_env();
    make_path("$bp_dir/runs");
    make_path("$bp_dir/packages");
    write_file("$bp_dir/packages/p.md", "# p\n\n## Dispatch log (auto)\n");
    write_file(marker_of($bp_dir), 'butler:bp-implementer');
    my $payload = task_payload('butler:bp-implementer');
    my ($exit, $out, $err) = run_hook($LOGDISPATCH, $payload, %$env);
    is($exit, 0, 'log-dispatch.sh: PostToolUse for a writer type -> exit 0 (never fails the dispatch)');

    SKIP: {
        skip 'jq not available on this host -- log-dispatch.sh requires it (bp_hook_require_jq is NOT called by this hook; it exits 0 at :14 without jq)', 1
            unless $HAVE_JQ;
        ok(!-f marker_of($bp_dir) || read_file(marker_of($bp_dir)) ne 'butler:bp-implementer',
            'log-dispatch.sh: pre-existing marker-clear behaviour for a matching type is undisturbed');
    }
}

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
# adapted from t/10-judges.t's own mk_bp/write_creds/run_once pattern.
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
# AC49 -- perl -c clean; existing judge suites pass unmodified.
# ===========================================================================
{
    my $out = `perl -c "$ORCH" 2>&1`;
    is($? >> 8, 0, "AC49: perl -c $ORCH exits 0") or diag($out);
}
for my $f ('61-judge-starvation.t', '82-orphaned-judge-recovery.t', '24-conformance-gate.t', '173-escalation-resolve-wiring.t') {
    my $path = "$Bin/$f";
    if (!-f $path) { fail("AC49: $f exists at $path"); next; }
    my $out = `perl "$path" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, "AC49: $f exits 0, unmodified") or diag(substr($out, -2000));
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
