#!/usr/bin/env perl
# 177-dispatch-record-attribution.t -- IMMUTABLE ORACLE for
# agent-telemetry/02-dispatch-record-attribution.
#
# Spec: .ccpraxis-local-data/blueprints/agent-telemetry/specs/
#       02-dispatch-record-attribution-spec.md
#
# Subject: plugins/butler/scripts/bp-dispatch-log.pl (package BpDispatchLog).
# t/136-bp-dispatch-log.t is a SEPARATE immutable oracle for the earlier
# package (w02-dispatch-budget-and-interrupt) and is NOT modified here. This
# file re-checks a couple of its guarantees only where this spec explicitly
# calls for a regression re-check (AC29 on --id, AC45 running t/136 itself).
#
# HOUSE PATTERN reused verbatim from t/136: run_cli() refuses to shell out
# to a missing script (returns (undef,undef,undef) instead of shelling out
# to a path perl itself would fail to open) so perl's own "can't open
# script" exit-2 can never be mistaken for this spec's own usage-error
# exit-2. CCPRAXIS_DISPATCH_LOG_TEST_NOW=1 gates --now, exactly as t/136
# requires. No test sleeps; every timestamp is injected.
#
# Runs standalone: perl plugins/butler/tests/t/177-dispatch-record-attribution.t
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP ();
use Config;

my $SCRIPT = "$Bin/../../scripts/bp-dispatch-log.pl";

# ===========================================================================
# 0. Load as a library (AC1, AC2).
# ===========================================================================
my $REQUIRE_ERROR = '';
my $LOADED = do {
    local $@;
    eval { require $SCRIPT };
    $REQUIRE_ERROR = $@;
    !$@;
};
ok($LOADED, 'AC1: bp-dispatch-log.pl requires cleanly as (at least) package BpDispatchLog')
    or diag("require died with: $REQUIRE_ERROR");

for my $sub (qw(role_is_valid stale_after_seconds is_stale is_live attribution)) {
    ok(defined &{"BpDispatchLog::$sub"}, "AC1: BpDispatchLog::$sub is defined");
}
ok(scalar(@BpDispatchLog::ROLES) > 0,
   'AC1: @BpDispatchLog::ROLES is defined/populated');
ok(defined $BpDispatchLog::DEFAULT_BUDGET_SECONDS,
   'AC1: $BpDispatchLog::DEFAULT_BUDGET_SECONDS is defined');
ok(defined $BpDispatchLog::STALE_BUDGET_MULTIPLE,
   'AC1: $BpDispatchLog::STALE_BUDGET_MULTIPLE is defined');

is_deeply(\@BpDispatchLog::ROLES, ['coordinator', 'worker', 'judge'],
    'AC2: @BpDispatchLog::ROLES is exactly (coordinator, worker, judge) in that order');
is($BpDispatchLog::STALE_BUDGET_MULTIPLE, 4, 'AC2: $STALE_BUDGET_MULTIPLE == 4');
is($BpDispatchLog::DEFAULT_BUDGET_SECONDS, 1800, 'AC2: $DEFAULT_BUDGET_SECONDS == 1800');

# ===========================================================================
# AC3 -- role_is_valid: closed-set membership, defined-false (not undef) for
# non-members.
# ===========================================================================
for my $r (qw(coordinator worker judge)) {
    is(eval { BpDispatchLog::role_is_valid($r) }, !!1, "AC3: role_is_valid('$r') is true");
}
for my $r ('', undef, 'Coordinator', 'workers', 'orchestrator', 'agent', 'reviewer') {
    my $label = defined($r) ? "'$r'" : 'undef';
    is(eval { BpDispatchLog::role_is_valid($r) }, !!0,
       "AC3: role_is_valid($label) is false (defined-false, not undef)");
}

# ===========================================================================
# AC4 -- stale_after_seconds: the fallback-to-default boundary.
# ===========================================================================
for my $case ([undef, 7200], [0, 7200], [-5, 7200], ['abc', 7200], ['', 7200],
              [1800, 7200], [100, 400]) {
    my ($in, $exp) = @$case;
    my $label = defined($in) ? "'$in'" : 'undef';
    is(eval { BpDispatchLog::stale_after_seconds($in) }, $exp,
       "AC4: stale_after_seconds($label) == $exp");
}

# ===========================================================================
# AC5 CANONICAL -- is_stale, strictly-greater-than boundary at 4x budget.
# ===========================================================================
{
    my $rec = { status => 'running', started_at => 1000, budget_seconds => 1800 };
    is(eval { BpDispatchLog::is_stale($rec, 8199) }, !!0,
       'AC5 CANONICAL: is_stale at elapsed 7199 (below threshold) is false');
    is(eval { BpDispatchLog::is_stale($rec, 8200) }, !!0,
       'AC5 CANONICAL: is_stale at elapsed EXACTLY 7200 (at the threshold) is false -- not strictly greater');
    is(eval { BpDispatchLog::is_stale($rec, 8201) }, !!1,
       'AC5 CANONICAL: is_stale at elapsed 7201 (past the threshold) is true');
}

# ===========================================================================
# AC6 -- is_live is the exact complement of AC5 across the same boundary.
# ===========================================================================
{
    my $rec = { status => 'running', started_at => 1000, budget_seconds => 1800 };
    is(eval { BpDispatchLog::is_live($rec, 8199) }, !!1, 'AC6: is_live at 8199 is true');
    is(eval { BpDispatchLog::is_live($rec, 8200) }, !!1,
       'AC6: is_live at 8200 (exactly at the threshold) is true');
    is(eval { BpDispatchLog::is_live($rec, 8201) }, !!0,
       'AC6: is_live at 8201 is false -- exact complement of AC5 across the boundary');
}

# ===========================================================================
# AC7 -- the threshold is derived from THIS record's own budget, not a fixed
# constant.
# ===========================================================================
{
    my $rec = { status => 'running', started_at => 1000, budget_seconds => 100 };
    is(eval { BpDispatchLog::is_stale($rec, 1400) }, !!0,
       'AC7: is_stale at elapsed 400 (== 4x100) is false');
    is(eval { BpDispatchLog::is_stale($rec, 1401) }, !!1,
       'AC7: is_stale at elapsed 401 is true');
}

# ===========================================================================
# AC8 -- budget_seconds absent falls back to the default budget, not to
# "never stale".
# ===========================================================================
{
    my $rec = { status => 'running', started_at => 1000 };
    is(eval { BpDispatchLog::is_stale($rec, 8200) }, !!0,
       'AC8: is_stale with budget_seconds ABSENT, elapsed 7200, is false');
    is(eval { BpDispatchLog::is_stale($rec, 8201) }, !!1,
       'AC8: is_stale with budget_seconds ABSENT, elapsed 7201, is true');
}

# ===========================================================================
# AC9 -- over-budget and stale are independent claims; must never collapse.
# ===========================================================================
{
    my $rec = { status => 'running', started_at => 1000, budget_seconds => 1800 };
    my $now = 4000;
    my $elapsed = BpDispatchLog::elapsed_seconds($rec->{started_at}, $now);
    is(eval { BpDispatchLog::is_over_budget($elapsed, $rec->{budget_seconds}) }, !!1,
       'AC9: over-running (elapsed 3000 > budget 1800) reads is_over_budget TRUE');
    is(eval { BpDispatchLog::is_stale($rec, $now) }, !!0,
       'AC9: ...but the SAME record at the SAME $now reads is_stale FALSE -- over-running and '
     . 'abandoned must never collapse into one signal');
}

# ===========================================================================
# AC10 -- a finished record is never stale, however old, for every terminal
# status.
# ===========================================================================
for my $status (qw(done interrupted killed)) {
    my $rec = { status => $status, started_at => 0, budget_seconds => 1800,
                ended_at => 10, duration_seconds => 10 };
    is(eval { BpDispatchLog::is_stale($rec, 10_000_000) }, !!0,
       "AC10: a finished record (status=$status) is never stale, however old");
    is(eval { BpDispatchLog::is_live($rec, 10_000_000) }, !!0,
       "AC10: a finished record (status=$status) is never live");
}

# ===========================================================================
# AC11 -- a backward clock is not stale, and reads live.
# ===========================================================================
{
    my $rec = { status => 'running', started_at => 5000 };
    is(eval { BpDispatchLog::is_stale($rec, 1000) }, !!0,
       'AC11: a backward clock (now < started_at) is not stale');
    is(eval { BpDispatchLog::is_live($rec, 1000) }, !!1,
       'AC11: ...and reads live -- a backward clock must not silently mass-expire live agents');
}

# ===========================================================================
# AC12 CANONICAL / AC13 -- unevaluable records are NEITHER live nor stale,
# and evaluating them raises zero Perl warnings.
# ===========================================================================
{
    my @cases = (
        ['undef',                                    undef],
        ['arrayref []',                               []],
        ['empty hashref {}',                          {}],
        ["{status=>'running'} (no started_at)",        { status => 'running' }],
        ["{status=>'running', started_at=>'soon'}",    { status => 'running', started_at => 'soon' }],
        ['{started_at=>1000} (no status)',             { started_at => 1000 }],
    );
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $now = 10_000_000;
    for my $c (@cases) {
        my ($label, $rec) = @$c;
        is(eval { BpDispatchLog::is_live($rec, $now) }, !!0,
           "AC12 CANONICAL: is_live($label) is false (unevaluable)");
        is(eval { BpDispatchLog::is_stale($rec, $now) }, !!0,
           "AC12 CANONICAL: is_stale($label) is false (unevaluable) -- neither live nor stale");
    }
    is(scalar(@warnings), 0,
       'AC13: evaluating every AC12 input emits NO Perl warnings on STDERR')
        or diag('warnings seen: ' . join(' | ', @warnings));
}

# ===========================================================================
# AC14 CANONICAL -- attribution collapses absent/null/empty to one undef
# state.
# ===========================================================================
{
    my @cases = (
        ['{}',                                            {}],
        ['{blueprint=>undef,package=>undef,role=>undef}', { blueprint => undef, package => undef, role => undef }],
        ["{blueprint=>'',package=>'',role=>''}",           { blueprint => '', package => '', role => '' }],
        ['undef',                                          undef],
        ['arrayref []',                                    []],
    );
    for my $c (@cases) {
        my ($label, $rec) = @$c;
        my $got = eval { BpDispatchLog::attribution($rec) };
        ok(ref($got) eq 'HASH', "AC14 CANONICAL: attribution($label) returns a hashref")
            or diag('got: ' . (defined $got ? $got : 'undef'));
        next unless ref($got) eq 'HASH';
        is_deeply([sort keys %$got], ['blueprint', 'package', 'role'],
            "AC14 CANONICAL: attribution($label) has exactly the keys blueprint/package/role");
        is($got->{blueprint}, undef, "AC14 CANONICAL: attribution($label)->{blueprint} is undef");
        is($got->{package}, undef, "AC14 CANONICAL: attribution($label)->{package} is undef");
        is($got->{role}, undef, "AC14 CANONICAL: attribution($label)->{role} is undef");
    }
}

# ===========================================================================
# AC15 -- a half-populated record returns the two supplied keys verbatim and
# undef for the omitted one.
# ===========================================================================
{
    my $got = eval { BpDispatchLog::attribution({ blueprint => 'agent-telemetry', role => 'judge' }) };
    is(ref($got), 'HASH', 'AC15: attribution returns a hashref');
    is($got->{blueprint}, 'agent-telemetry', 'AC15: half-populated record -- blueprint verbatim');
    is($got->{role}, 'judge', 'AC15: half-populated record -- role verbatim');
    is($got->{package}, undef, 'AC15: half-populated record -- package (never supplied) is undef');
}

# ===========================================================================
# AC16 -- values round-trip verbatim, hyphens and dots intact.
# ===========================================================================
{
    my $rec = { blueprint => 'agent-telemetry', package => '02-dispatch-record-attribution',
                role => 'worker' };
    my $got = eval { BpDispatchLog::attribution($rec) };
    is($got->{blueprint}, 'agent-telemetry', 'AC16: blueprint round-trips verbatim, hyphens intact');
    is($got->{package}, '02-dispatch-record-attribution',
       'AC16: package round-trips verbatim, hyphens and dots intact');
    is($got->{role}, 'worker', 'AC16: role round-trips verbatim');
}

# ===========================================================================
# AC17 -- an unrecognised stored role is returned VERBATIM, not nulled;
# attribution does not validate.
# ===========================================================================
{
    my $got = eval { BpDispatchLog::attribution({ role => 'overseer' }) };
    is($got->{role}, 'overseer', 'AC17: an unrecognised stored role is returned verbatim, not nulled');
    is(eval { BpDispatchLog::role_is_valid('overseer') }, !!0,
       "AC17: ...while role_is_valid('overseer') is false -- attribution does not validate against the closed set");
}

# ===========================================================================
# C. CLI SURFACE -- run_cli() harness lifted VERBATIM from t/136 (see header
# for why the missing-script guard exists).
# ===========================================================================
sub run_cli {
    my (@args) = @_;
    return (undef, undef, undef) unless -f $SCRIPT;
    my $tmp = tempdir(CLEANUP => 1);
    my ($out_f, $err_f) = ("$tmp/out", "$tmp/err");
    my $q = sub { my $a = shift; $a =~ s/"/\\"/g; return qq("$a") };
    my $cmd = join(' ', 'perl', $q->($SCRIPT), map { $q->($_) } @args);
    system(qq{CCPRAXIS_DISPATCH_LOG_TEST_NOW=1 $cmd > "$out_f" 2> "$err_f"});
    my $rc = ($? == -1) ? undef : ($? >> 8);
    my $out = _slurp($out_f);
    my $err = _slurp($err_f);
    return ($rc, $out, $err);
}
sub _slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined($c) ? $c : '';
}
sub record_file {
    my ($root, $id) = @_;
    return "$root/.ccpraxis-local-data/.dispatch-log/$id.json";
}
sub history_file {
    my ($root) = @_;
    return "$root/.ccpraxis-local-data/.dispatch-log/history.jsonl";
}
sub _decode_record_file {
    my ($path) = @_;
    return undef unless defined($path) && -f $path;
    my $raw = _slurp($path);
    return eval { JSON::PP->new->decode($raw) };
}

# BpDispatchLog::read_record (AC23) is a PRE-EXISTING, non-pure (file I/O)
# helper this spec names by exact symbol but does not give a signature for
# -- section 2.2's "new pure functions" list excludes it by definition (I/O
# disqualifies "pure"), and it is not among the already-existing functions
# enumerated for this test-writer either. record_path($root,$id) establishes
# "a path" as this script's existing addressing convention, so a
# path-taking signature is tried first; ($root,$id) (symmetric with
# record_path's own signature) is tried second. This is ONLY a
# calling-convention probe -- it never changes what is asserted about the
# DECODED content once a call succeeds.
sub _call_read_record {
    my ($root, $id, $path) = @_;
    # Both signature guesses are wrapped in a local warning-collector: a
    # wrong guess legitimately triggers an uninitialized-value warning
    # inside the real function (e.g. a missing $id) -- that is expected
    # noise from THIS PROBE, not a signal about the real read_record's
    # correctness, so it must not leak onto the test run's own STDERR.
    my $rec;
    { local $SIG{__WARN__} = sub {}; $rec = eval { BpDispatchLog::read_record($path) }; }
    return $rec if ref($rec) eq 'HASH';
    { local $SIG{__WARN__} = sub {}; $rec = eval { BpDispatchLog::read_record($root, $id) }; }
    return $rec if ref($rec) eq 'HASH';
    return undef;
}

# ===========================================================================
# AC18 CANONICAL -- the motivating case: blueprint/package are NOT
# recoverable from the id by any rule, so they must be persisted verbatim
# from explicit options.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $id = 'agent-telemetry-02-dispatch-record-attribution-1725800000';
    my ($rc) = run_cli('start', '--id', $id, '--worker-type', 'bp-implementer',
        '--blueprint', 'agent-telemetry', '--package', '02-dispatch-record-attribution',
        '--role', 'worker', '--budget-seconds', '1800', '--now', '1000', '--root', $root);
    is($rc, 0, 'AC18 CANONICAL: start with all three attribution options exits 0');
    my $rec = _decode_record_file(record_file($root, $id));
    ok(defined $rec, 'AC18: the record file decodes as JSON');
    if (defined $rec) {
        is($rec->{blueprint}, 'agent-telemetry',
           'AC18 CANONICAL: blueprint verbatim -- not recoverable from the id by any rule');
        is($rec->{package}, '02-dispatch-record-attribution',
           'AC18 CANONICAL: package verbatim -- not recoverable from the id by any rule');
    }
}

# ===========================================================================
# AC19 CANONICAL -- byte-equal record with all three attribution fields.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc) = run_cli('start', '--id', 'x1', '--worker-type', 'wt',
        '--blueprint', 'agent-telemetry', '--package', '02-dispatch-record-attribution',
        '--role', 'worker', '--budget-seconds', '1800', '--now', '1000', '--root', $root);
    is($rc, 0, 'AC19: start exits 0');
    my $raw = _slurp(record_file($root, 'x1'));
    is($raw,
       '{"blueprint":"agent-telemetry","budget_seconds":1800,"id":"x1","note":null,'
     . '"package":"02-dispatch-record-attribution","role":"worker","started_at":1000,'
     . '"status":"running","worker_type":"wt"}',
       'AC19 CANONICAL: record file content is byte-equal to the canonical-order JSON');
}

# ===========================================================================
# AC20 -- subset persistence: a supplied key is present, an omitted key is
# ABSENT (not present-as-null).
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc) = run_cli('start', '--id', 'j1', '--worker-type', 'bp-resolve-judge',
        '--blueprint', 'agent-telemetry', '--role', 'judge', '--now', '1000', '--root', $root);
    is($rc, 0, 'AC20: subset start (blueprint+role, no package) exits 0');
    my $rec = _decode_record_file(record_file($root, 'j1'));
    ok(defined $rec, 'AC20: the record file decodes as JSON');
    if (defined $rec) {
        is_deeply([sort keys %$rec],
                  ['blueprint', 'budget_seconds', 'id', 'note', 'role', 'started_at', 'status', 'worker_type'],
                  'AC20: exact key set -- package key absent entirely');
        ok(!exists $rec->{package}, "AC20: exists \$rec->{package} is FALSE, not merely undef");
    }
}

# ===========================================================================
# AC21 -- each of the three role words is accepted and lands verbatim.
# ===========================================================================
for my $role (qw(coordinator worker judge)) {
    my $root = tempdir(CLEANUP => 1);
    my $id = "role-$role";
    my ($rc) = run_cli('start', '--id', $id, '--worker-type', 'wt', '--role', $role,
                        '--now', '1000', '--root', $root);
    is($rc, 0, "AC21: start --role $role exits 0");
    my $rec = _decode_record_file(record_file($root, $id));
    is($rec ? $rec->{role} : undef, $role, "AC21: role '$role' lands verbatim in the record");
}

# ===========================================================================
# AC22 CANONICAL -- backward compatibility: no attribution options -> a
# byte-equal record to the pre-change shape. Absence is absence, never
# "blueprint":null.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc) = run_cli('start', '--id', 'x1', '--worker-type', 'test-writer',
                        '--now', '1000', '--root', $root);
    is($rc, 0, 'AC22: start with no attribution options exits 0');
    my $raw = _slurp(record_file($root, 'x1'));
    is($raw,
       '{"budget_seconds":1800,"id":"x1","note":null,"started_at":1000,"status":"running","worker_type":"test-writer"}',
       'AC22 CANONICAL: unattributed record is byte-equal to the pre-change shape -- no '
     . '"blueprint":null anywhere, note\'s null preserved');
}

# ===========================================================================
# AC23 -- the unattributed record, read back via BpDispatchLog::read_record,
# has exactly the pre-change key set and attributes as all-undef.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'x1', '--worker-type', 'test-writer', '--now', '1000', '--root', $root);
    my $path = record_file($root, 'x1');
    my $rec = _call_read_record($root, 'x1', $path);
    ok(defined $rec, 'AC23: BpDispatchLog::read_record decodes the pre-change-shape record')
        or diag('read_record adapter could not decode via either ($path) or ($root,$id) signature');
    if (defined $rec) {
        is_deeply([sort keys %$rec],
                  ['budget_seconds', 'id', 'note', 'started_at', 'status', 'worker_type'],
                  'AC23: exact key set via read_record -- no attribution keys present');
        my $attr = eval { BpDispatchLog::attribution($rec) };
        is($attr->{blueprint}, undef, 'AC23: attribution on the unattributed record -- blueprint undef');
        is($attr->{package}, undef, 'AC23: attribution on the unattributed record -- package undef');
        is($attr->{role}, undef, 'AC23: attribution on the unattributed record -- role undef');
    }
}

# ===========================================================================
# AC24 -- a record hand-written in the pre-change shape is fully usable by
# every downstream command; no path requires the new fields.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data/.dispatch-log");
    open my $fh, '>', record_file($root, 'x1') or die "open: $!";
    print {$fh} '{"budget_seconds":1800,"id":"x1","note":null,"started_at":1000,"status":"running","worker_type":"test-writer"}';
    close $fh;

    my ($rc1, $out1) = run_cli('elapsed', '--id', 'x1', '--now', '1200', '--root', $root);
    is($rc1, 0, 'AC24: elapsed on a hand-written pre-change-shape record exits 0');
    like($out1, qr/elapsed_seconds:\s*200\b/, 'AC24: elapsed_seconds: 200');
    like($out1, qr/budget_seconds:\s*1800\b/, 'AC24: budget_seconds: 1800');
    like($out1, qr/over_budget:\s*false\b/,   'AC24: over_budget: false');

    my ($rc2, $out2) = run_cli('list', '--now', '1200', '--root', $root);
    is($rc2, 0, 'AC24: list on the pre-change-shape record exits 0');
    like($out2, qr/\bx1\b/, 'AC24: list shows the record');
    like($out2, qr/stale:\s*false\b/, 'AC24: list marks it stale: false');

    my ($rc3) = run_cli('finish', '--id', 'x1', '--status', 'done', '--now', '2000', '--root', $root);
    is($rc3, 0, 'AC24: finish on the pre-change-shape record exits 0');
}

# ===========================================================================
# AC25 CANONICAL -- finish preserves blueprint/package/role untouched.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'x1', '--worker-type', 'wt', '--blueprint', 'bp', '--package', 'pk',
            '--role', 'judge', '--budget-seconds', '1800', '--now', '1000', '--root', $root);
    my ($rc) = run_cli('finish', '--id', 'x1', '--status', 'done', '--now', '2000', '--root', $root);
    is($rc, 0, 'AC25: finish on an attributed record exits 0');
    my $raw = _slurp(record_file($root, 'x1'));
    is($raw,
       '{"blueprint":"bp","budget_seconds":1800,"duration_seconds":1000,"ended_at":2000,"id":"x1",'
     . '"note":null,"package":"pk","role":"judge","started_at":1000,"status":"done","worker_type":"wt"}',
       'AC25 CANONICAL: finish preserves attribution untouched, byte-equal result');
}

# ===========================================================================
# AC26 -- an invalid --role is refused at the CLI, mirroring the --status
# guard exactly; no record file is written.
# ===========================================================================
for my $bad ('boss', 'Worker', '', 'orchestrator') {
    my $root = tempdir(CLEANUP => 1);
    my ($rc, $out, $err) = run_cli('start', '--id', 'x1', '--worker-type', 'wt', '--role', $bad,
                                    '--now', '1000', '--root', $root);
    is($rc, 2, "AC26: start --role '$bad' exits 2");
    my $e = $err // '';
    like($e, qr/--role/,        "AC26: stderr for --role '$bad' names --role");
    like($e, qr/coordinator/,   "AC26: stderr for --role '$bad' lists coordinator");
    like($e, qr/worker/,        "AC26: stderr for --role '$bad' lists worker");
    like($e, qr/judge/,         "AC26: stderr for --role '$bad' lists judge");
    ok(!-f record_file($root, 'x1'), "AC26: no record file exists after refused start (--role '$bad')");
}

# ===========================================================================
# AC27 -- bad shapes for --blueprint / --package are refused; no record, no
# stray file/dir anywhere including outside --root.
# ===========================================================================
{
    my @bad_shapes = ('', '../etc', '../../x', 'a/b', 'a\\b', '.', '..', "cafe\x{0301}");
    for my $opt (qw(blueprint package)) {
        for my $bad (@bad_shapes) {
            my $root = tempdir(CLEANUP => 1);
            my $outside = tempdir(CLEANUP => 1);
            my $sentinel = "$outside/secret.json";
            open my $fh, '>', $sentinel or die "open: $!";
            print {$fh} 'SENTINEL-UNCHANGED';
            close $fh;
            my $before = _slurp($sentinel);

            my ($rc, $out, $err) = run_cli('start', '--id', 'x1', '--worker-type', 'wt',
                "--$opt", $bad, '--now', '1000', '--root', $root);
            my $label = ($bad eq '') ? 'EMPTY'
                      : ($bad =~ /[^\x00-\x7f]/) ? 'NON-ASCII'
                      : $bad;
            is($rc, 2, "AC27: start --$opt '$label' exits 2");
            my $e = $err // '';
            like($e, qr/invalid shape/, "AC27: stderr for --$opt '$label' says 'invalid shape'");
            like($e, qr/--\Q$opt\E/,    "AC27: stderr for --$opt '$label' names --$opt");
            ok(!-f record_file($root, 'x1'), "AC27: no record file exists after refused --$opt '$label'");

            my $logdir = "$root/.ccpraxis-local-data/.dispatch-log";
            my $logdir_empty = !-d $logdir || do {
                opendir(my $dh, $logdir) or die "opendir: $!";
                my @entries = grep { !/^\.\.?$/ } readdir($dh);
                closedir($dh);
                scalar(@entries) == 0;
            };
            ok($logdir_empty, "AC27: log dir is empty or absent after refused --$opt '$label' -- no stray file");
            is(_slurp($sentinel), $before,
               "AC27: sentinel file outside --root is unmodified after refused --$opt '$label'");
        }
    }
}

# ===========================================================================
# AC28 -- ordinary punctuation in --blueprint/--package is ACCEPTED; the
# guard rejects traversal, not hyphens/dots/underscores.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc1) = run_cli('start', '--id', 'x1', '--worker-type', 'wt', '--blueprint', 'a.b',
                         '--now', '1000', '--root', $root);
    is($rc1, 0, 'AC28: --blueprint a.b (ordinary punctuation, not traversal) exits 0');
    my $rec1 = _decode_record_file(record_file($root, 'x1'));
    is($rec1 ? $rec1->{blueprint} : undef, 'a.b', 'AC28: --blueprint a.b persists verbatim');

    my ($rc2) = run_cli('start', '--id', 'x2', '--worker-type', 'wt', '--package', '01-x_y',
                         '--now', '1000', '--root', $root);
    is($rc2, 0, 'AC28: --package 01-x_y exits 0');
    my $rec2 = _decode_record_file(record_file($root, 'x2'));
    is($rec2 ? $rec2->{package} : undef, '01-x_y', 'AC28: --package 01-x_y persists verbatim');

    my ($rc3) = run_cli('start', '--id', 'x3', '--worker-type', 'wt', '--blueprint', 'A-B_c.d',
                         '--now', '1000', '--root', $root);
    is($rc3, 0, 'AC28: --blueprint A-B_c.d exits 0');
    my $rec3 = _decode_record_file(record_file($root, 'x3'));
    is($rec3 ? $rec3->{blueprint} : undef, 'A-B_c.d', 'AC28: --blueprint A-B_c.d persists verbatim');
}

# ===========================================================================
# AC29 -- regression guard: --id's own guard is unchanged (t/136 E1-E3), for
# start, elapsed AND finish.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    for my $bad ('../etc/passwd', "id\x{0301}") {
        # Label for TEST NAMES only -- never the wide char itself, which
        # trips "Wide character in print" from the TAP formatter and is
        # pure output noise, not a signal about the assertion.
        my $label = ($bad =~ /[^\x00-\x7f]/) ? 'NON-ASCII' : $bad;
        my @call_sets = (
            ['start',   '--id', $bad, '--worker-type', 'wt', '--now', '1000', '--root', $root],
            ['elapsed', '--id', $bad, '--now', '1000', '--root', $root],
            ['finish',  '--id', $bad, '--status', 'done', '--now', '1000', '--root', $root],
        );
        for my $call (@call_sets) {
            my ($rc, $out, $err) = run_cli(@$call);
            isnt($rc, 0, "AC29: --id '$label' rejected on '$call->[0]' (regression guard on t/136 E1-E3)");
            like(($err // ''), qr/invalid shape/, "AC29: --id '$label' refusal on '$call->[0]' says 'invalid shape'");
        }
    }
}

# ===========================================================================
# AC30 -- --blueprint / --package / --role on any command other than start
# is refused, naming the offending option and the word "start".
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'x1', '--worker-type', 'wt', '--now', '1000', '--root', $root);
    my $before = _slurp(record_file($root, 'x1'));

    my @cases = (
        [['elapsed', '--id', 'x1', '--role', 'worker', '--root', $root], qr/--role/],
        [['list', '--blueprint', 'bp', '--root', $root],                 qr/--blueprint/],
        [['finish', '--id', 'x1', '--status', 'done', '--package', 'pk', '--root', $root], qr/--package/],
    );
    for my $c (@cases) {
        my ($args, $opt_re) = @$c;
        my ($rc, $out, $err) = run_cli(@$args);
        is($rc, 2, "AC30: '@$args' (attribution option on a non-start command) exits 2");
        my $e = $err // '';
        like($e, $opt_re, "AC30: stderr for '@$args' names the offending option");
        like($e, qr/start/, "AC30: stderr for '@$args' names 'start'");
    }
    my $after = _slurp(record_file($root, 'x1'));
    is($after, $before, 'AC30: the record started beforehand is byte-identical after all three refusals');
}

# ===========================================================================
# AC31 -- list's stale token flips at the boundary via the CLI.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 's1', '--worker-type', 'wt', '--budget-seconds', '1800',
            '--now', '1000', '--root', $root);
    my (undef, $out1) = run_cli('list', '--now', '8200', '--root', $root);
    like($out1, qr/\bs1\b[^\n]*stale:\s*false\b/, 'AC31: list at now=8200 shows s1 stale: false');
    my (undef, $out2) = run_cli('list', '--now', '8201', '--root', $root);
    like($out2, qr/\bs1\b[^\n]*stale:\s*true\b/, 'AC31: list at now=8201 shows s1 stale: true');
}

# ===========================================================================
# AC32 CANONICAL -- the list line is byte-equal, stale appended last, every
# pre-existing token in its original position and spelling.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 's1', '--worker-type', 'wt', '--budget-seconds', '1800',
            '--now', '1000', '--root', $root);
    my (undef, $out) = run_cli('list', '--now', '8200', '--root', $root);
    my @lines = map { my $l = $_; $l =~ s/\r\z//; $l } split /\n/, ($out // '');
    my ($line) = grep { /\bs1\b/ } @lines;
    is($line,
       'id: s1 worker_type: wt over_budget: true elapsed_seconds: 7200 budget_seconds: 1800 stale: false',
       'AC32 CANONICAL: list line for s1 is byte-equal -- over_budget:true and stale:false coexist (AC9)');
}

# ===========================================================================
# AC33 -- a stale record is STILL listed, not hidden.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 's1', '--worker-type', 'wt', '--budget-seconds', '1800',
            '--now', '1000', '--root', $root);
    my (undef, $out) = run_cli('list', '--now', '8201', '--root', $root);
    like($out, qr/\bs1\b/, 'AC33: a stale record is still listed at now=8201, not hidden');
}

# ===========================================================================
# AC34 -- a running record with missing/non-numeric started_at is skipped by
# list, silently (no warning), without suppressing a good sibling record.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data/.dispatch-log");
    open my $fh1, '>', record_file($root, 'bad1') or die "open: $!";
    print {$fh1} '{"id":"bad1","worker_type":"wt","status":"running","budget_seconds":1800}';
    close $fh1;
    open my $fh2, '>', record_file($root, 'bad2') or die "open: $!";
    print {$fh2} '{"id":"bad2","worker_type":"wt","status":"running","started_at":"soon","budget_seconds":1800}';
    close $fh2;
    run_cli('start', '--id', 'good1', '--worker-type', 'wt', '--now', '1000', '--root', $root);

    my ($rc, $out, $err) = run_cli('list', '--now', '2000', '--root', $root);
    is($rc, 0, 'AC34: list exits 0 despite malformed records present');
    is(($err // ''), '', 'AC34: list emits no Perl warning (stderr empty) for the malformed records');
    unlike($out, qr/\bbad1\b/, 'AC34: the started_at-missing record is skipped (not listed)');
    unlike($out, qr/\bbad2\b/, 'AC34: the non-numeric started_at record is skipped (not listed)');
    like($out, qr/\bgood1\b/,
         'AC34: a valid record in the same directory is still listed -- one bad record must not '
       . 'suppress the good ones');
}

# ===========================================================================
# AC35 CANONICAL -- read_history golden fixture: extra keys ignored, a
# stringified number numified, malformed/empty/array/scalar lines skipped
# without dying, file order preserved.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data/.dispatch-log");
    open my $fh, '>', history_file($root) or die "open: $!";
    print {$fh} join("\n",
        '{"worker_type":"A","duration_seconds":100,"ended_at":10}',
        '{"worker_type":"A","duration_seconds":150,"ended_at":20,"blueprint":"bp","package":"pk","role":"worker"}',
        '{"worker_type":"B","duration_seconds":999,"ended_at":30}',
        '',
        '   ',
        '{not json',
        '[1,2,3]',
        '{"worker_type":"A","ended_at":40}',
        '{"worker_type":"A","duration_seconds":"250","ended_at":50}',
        '"just a string"',
    ) . "\n";
    close $fh;

    is_deeply(eval { BpDispatchLog::read_history($root, 'A') }, [100, 150, 250],
        'AC35 CANONICAL: read_history golden fixture -- worker_type A -> [100,150,250] in file '
      . 'order, extra keys ignored, stringified number numified');
    is_deeply(eval { BpDispatchLog::read_history($root, 'B') }, [999],
        'AC35: worker_type B -> [999]');
    is_deeply(eval { BpDispatchLog::read_history($root, 'C') }, [],
        'AC35: worker_type C (absent from the file) -> []');
}

# ===========================================================================
# AC36 -- read_history with no history.jsonl returns []; median([]) is
# undef.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    is_deeply(eval { BpDispatchLog::read_history($root, 'A') }, [],
        'AC36: read_history on a root with no history.jsonl returns [] (unchanged)');
    is(eval { BpDispatchLog::median([]) }, undef, 'AC36: median([]) is undef (unchanged)');
}

# ===========================================================================
# AC37 CANONICAL -- no attribution leaks into history.jsonl.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'a1', '--worker-type', 'test-writer', '--blueprint', 'agent-telemetry',
            '--package', '02-dispatch-record-attribution', '--role', 'worker', '--now', '1000',
            '--root', $root);
    run_cli('finish', '--id', 'a1', '--status', 'done', '--now', '2000', '--root', $root);
    my $raw = _slurp(history_file($root));
    is($raw, "{\"duration_seconds\":1000,\"ended_at\":2000,\"worker_type\":\"test-writer\"}\n",
       'AC37 CANONICAL: history.jsonl is byte-equal -- exactly one line, exactly three keys, '
     . 'no attribution field anywhere');
}

# ===========================================================================
# AC38 -- end-to-end median is unchanged for attributed dispatches.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    for my $i (1 .. 3) {
        my $dur = ($i == 1) ? 100 : ($i == 2) ? 200 : 300;
        run_cli('start', '--id', "m$i", '--worker-type', 'test-writer', '--blueprint', 'agent-telemetry',
                '--role', 'worker', '--now', '0', '--root', $root);
        run_cli('finish', '--id', "m$i", '--status', 'done', '--now', $dur, '--root', $root);
    }
    run_cli('start', '--id', 'x2', '--worker-type', 'test-writer', '--now', '5000', '--root', $root);
    my (undef, $out) = run_cli('elapsed', '--id', 'x2', '--now', '5050', '--root', $root);
    like($out, qr/median_seconds:\s*200\b/,
         'AC38: end-to-end median unchanged with attributed dispatches (100,200,300) -> 200 '
       . '(identical to t/136 C6\'s result for the unattributed case)');
}

# ===========================================================================
# AC39 -- finish --status interrupted on an attributed record still appends
# no history line.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'a1', '--worker-type', 'test-writer', '--blueprint', 'bp',
            '--package', 'pk', '--role', 'worker', '--now', '1000', '--root', $root);
    run_cli('finish', '--id', 'a1', '--status', 'interrupted', '--now', '2000', '--root', $root);
    my $raw = _slurp(history_file($root));
    is($raw, '', 'AC39: finish --status interrupted on an attributed record appends NO history line');
}

# ===========================================================================
# AC40 -- a second start on a still-running attributed id is still refused
# (exit 3); the first record is byte-identical afterwards.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'x1', '--worker-type', 'wt', '--blueprint', 'bp', '--package', 'pk',
            '--role', 'worker', '--now', '1000', '--root', $root);
    my $before = _slurp(record_file($root, 'x1'));
    my ($rc) = run_cli('start', '--id', 'x1', '--worker-type', 'wt', '--now', '9999', '--root', $root);
    is($rc, 3, 'AC40: a second start on a still-running attributed id is refused (exit 3)');
    my $after = _slurp(record_file($root, 'x1'));
    is($after, $before, 'AC40: the first (attributed) record is byte-identical afterwards');
}

# ===========================================================================
# AC41 -- N (>=4) concurrent start calls on distinct ids: every resulting
# record parses complete, no *.tmp.* residue, list names all N ids. Asserts
# ONLY this -- no ordering claim (spec is explicit that ordering/durability
# are out of scope here).
# ===========================================================================
subtest 'AC41: concurrent start on distinct ids' => sub {
    plan skip_all => 'no fork/pseudofork available on this perl/platform'
        unless $Config{d_fork} || $Config{d_pseudofork};
    unless (-f $SCRIPT) {
        fail('AC41: script does not exist -- cannot exercise concurrency');
        done_testing();
        return;
    }

    my $root = tempdir(CLEANUP => 1);
    my $K = 4;
    my @ids = map { "conc-$_" } (1 .. $K);
    my @pids;
    for my $i (0 .. $#ids) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            $ENV{CCPRAXIS_DISPATCH_LOG_TEST_NOW} = 1;
            open(STDIN,  '<', File::Spec->devnull) or die "reopen STDIN: $!";
            open(STDOUT, '>', File::Spec->catfile($root, "child-$i.out")) or die "reopen STDOUT: $!";
            open(STDERR, '>', File::Spec->catfile($root, "child-$i.err")) or die "reopen STDERR: $!";
            exec($^X, $SCRIPT, 'start', '--id', $ids[$i], '--worker-type', 'wt',
                 '--now', '1000', '--root', $root);
            exit 97; # exec itself failed to launch
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;

    my $logdir = "$root/.ccpraxis-local-data/.dispatch-log";
    for my $id (@ids) {
        my $rec = _decode_record_file("$logdir/$id.json");
        ok(defined $rec, "AC41: $id.json parses as complete JSON");
        if (defined $rec) {
            is_deeply([sort keys %$rec],
                      ['budget_seconds', 'id', 'note', 'started_at', 'status', 'worker_type'],
                      "AC41: $id.json has a complete key set");
        }
    }
    my @tmp_residue;
    if (opendir(my $dh, $logdir)) {
        @tmp_residue = grep { /\.tmp\.\S+/ } readdir($dh);
        closedir($dh);
    }
    is(scalar(@tmp_residue), 0, 'AC41: no *.tmp.* file remains in the log dir');

    my (undef, $out) = run_cli('list', '--now', '2000', '--root', $root);
    for my $id (@ids) {
        like(($out // ''), qr/\Q$id\E/, "AC41: list names $id");
    }
    done_testing();
};

# ===========================================================================
# AC42 -- documentation: STALE_BUDGET_MULTIPLE and the staleness rule are
# stated in prose in a comment block.
# ===========================================================================
{
    my $src = _slurp($SCRIPT);
    ok(length($src) > 0, 'AC42: script source is readable');
    my @lines = split /\n/, $src;
    my @hit_idx = grep { $lines[$_] =~ /STALE_BUDGET_MULTIPLE/ } (0 .. $#lines);
    ok(scalar(@hit_idx) > 0, 'AC42: source mentions STALE_BUDGET_MULTIPLE');
    my $found = 0;
    for my $i (@hit_idx) {
        my $lo = ($i - 40 < 0) ? 0 : $i - 40;
        my $hi = ($i + 40 > $#lines) ? $#lines : $i + 40;
        for my $j ($lo .. $hi) {
            if ($lines[$j] =~ /#.*stale/i) { $found = 1; last; }
        }
        last if $found;
    }
    ok($found,
       'AC42: within 40 lines of a STALE_BUDGET_MULTIPLE mention, a "#" comment states the rule (/stale/i)');
}

# ===========================================================================
# AC43 -- USAGE text mentions the new options, the role vocabulary, and the
# staleness rule.
# ===========================================================================
{
    my ($rc, $out, $err) = run_cli('bogus-command-that-does-not-exist');
    is($rc, 2, 'AC43: an unknown command prints usage and exits 2 (unchanged)');
    my $both = ($out // '') . ($err // '');
    like($both, qr/--blueprint/, 'AC43: usage mentions --blueprint');
    like($both, qr/--package/,   'AC43: usage mentions --package');
    like($both, qr/--role/,      'AC43: usage mentions --role');
    like($both, qr/coordinator/, 'AC43: usage lists coordinator');
    like($both, qr/worker/,      'AC43: usage lists worker');
    like($both, qr/judge/,       'AC43: usage lists judge');
    like($both, qr/stale/i,      'AC43: usage matches /stale/i');
}

# ===========================================================================
# AC44 (DC5) -- perl -c is clean.
# ===========================================================================
{
    my $out = `perl -c "$SCRIPT" 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, 'AC44: perl -c exits 0');
    like($out, qr/syntax OK/, 'AC44: perl -c reports syntax OK');
    my @lines = grep { length } split /\n/, $out;
    my @non_syntax_ok = grep { $_ !~ /syntax OK/ } @lines;
    is(scalar(@non_syntax_ok), 0,
       'AC44: perl -c produces no warnings other than the syntax OK line')
        or diag("perl -c output:\n$out");
}

# ===========================================================================
# AC45 (DC6) -- t/136-bp-dispatch-log.t passes unmodified.
# ===========================================================================
{
    my $t136 = "$Bin/136-bp-dispatch-log.t";
    ok(-f $t136, 'AC45: t/136-bp-dispatch-log.t exists (immutable oracle for the earlier package)');
    if (-f $t136) {
        my $out = `perl "$t136" 2>&1`;
        my $rc = $? >> 8;
        is($rc, 0, 'AC45 (DC6): t/136-bp-dispatch-log.t passes unmodified -- exits 0');
        unlike($out, qr/^not ok/m, 'AC45: t/136 output contains no "not ok" line')
            or diag("t/136 output:\n$out");
    }
}

# ===========================================================================
# AC46 (D2 guard) -- no self-reported time field, no pid-based liveness,
# anywhere in the source.
# ===========================================================================
{
    my $src = _slurp($SCRIPT);
    unlike($src, qr/duration_ms/,    'AC46 (D2 guard): source never mentions duration_ms (t/136 D2, re-pinned)');
    unlike($src, qr/self_report/,    'AC46: source never mentions self_report');
    unlike($src, qr/reported_ms/,    'AC46: source never mentions reported_ms');
    unlike($src, qr/agent_duration/, 'AC46: source never mentions agent_duration');
    unlike($src, qr/kill\s*\(?\s*0/, 'AC46: source contains no pid-based liveness via kill 0');
    unlike($src, qr{/proc/},         'AC46: source contains no /proc/ pid-based liveness check');
}

done_testing();
