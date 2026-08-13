#!/usr/bin/env perl
# 136-bp-dispatch-log.t — IMMUTABLE ORACLE for w02-dispatch-budget-and-
# interrupt's per-dispatch budget record (package BpDispatchLog in
# plugins/butler/scripts/bp-dispatch-log.pl — DOES NOT EXIST YET at the time
# this file is written; the test-writer runs before the implementer).
#
# Spec: .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/
#       w02-dispatch-budget-and-interrupt-spec.md §2.2 (pure library),
#       §2.3 (CLI/exit codes), §3 (behaviors 1-8), §4 (AC1 wall-clock half,
#       AC2, AC3, AC7), §5 (edge cases: backward clock, id-collision refusal).
#
# HOUSE PATTERN, lifted from t/133 (require-with-eval) and t/134
# (run_*() refuses to invoke a script that does not exist yet, returning
# undef instead of shelling out to a path perl itself would fail to open).
# Both exist for the SAME reason: perl's own "can't open perl script"
# failure exits 2 on this host, which COINCIDES with this spec's own usage-
# error exit code. Without the guard, every assertion expecting exit 2 would
# PASS on a script that does not exist at all — a false pass for the wrong
# reason, exactly what non-vacuity forbids. run_cli() below therefore
# returns (undef, undef, undef) whenever the script file is absent, so
# every is($rc, N, ...) genuinely fails until the real script exists and
# genuinely returns N.
#
# Runs standalone: perl plugins/butler/tests/t/136-bp-dispatch-log.t
# No real sleeping anywhere — every timestamp is injected via --now / a
# plain $now argument to the pure functions, per spec §2.3's test-only seam.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

my $SCRIPT = "$Bin/../../scripts/bp-dispatch-log.pl";

# ===========================================================================
# 0. Load as a library. package BpDispatchLog must require cleanly and
#    expose exactly the pure functions the spec names (§2.2).
# ===========================================================================
my $REQUIRE_ERROR = '';
my $LOADED = do {
    local $@;
    eval { require $SCRIPT };
    $REQUIRE_ERROR = $@;
    !$@;
};
ok($LOADED, 'A1: bp-dispatch-log.pl requires cleanly as (at least) package BpDispatchLog')
    or diag("require died with: $REQUIRE_ERROR");

for my $sub (qw(record_path elapsed_seconds is_over_budget median read_history write_record)) {
    ok(defined &{"BpDispatchLog::$sub"}, "A2: BpDispatchLog::$sub is defined");
}

# ===========================================================================
# B. PURE FUNCTIONS — zero real sleeping, zero disk I/O for elapsed_seconds/
#    is_over_budget/median. Each has its own falsifiable, separately-named
#    assertion so a partial implementation reads as partial.
# ===========================================================================

# B1: elapsed_seconds is a plain subtraction of two driver-supplied numbers —
# AC2's whole point, pinned at the function-signature level: it takes
# $started_at and $now, nothing shaped like a worker report.
{
    my $got = eval { BpDispatchLog::elapsed_seconds(1000, 1200) };
    is($got, 200, 'B1: elapsed_seconds(1000, 1200) == 200 (plain now-minus-started_at)');
}

# B2 CANONICAL — the edge case §5 calls out by name: a clock that moved
# backward must return a negative number UNCLAMPED, never floored to 0 (which
# would misreport a stalled dispatch as brand new).
{
    my $got = eval { BpDispatchLog::elapsed_seconds(5000, 1000) };
    is($got, -4000,
       'B2 CANONICAL: elapsed_seconds(5000, 1000) == -4000, UNCLAMPED — a backward clock '
     . 'must read as a visible anomaly, never silently floored to 0');
}

# B3: is_over_budget is a plain comparison; strictly greater-than, not >=.
{
    is(eval { BpDispatchLog::is_over_budget(200, 1800) }, !!0,
       'B3: is_over_budget(200, 1800) is false — well under budget');
    is(eval { BpDispatchLog::is_over_budget(2000, 1800) }, !!1,
       'B3: is_over_budget(2000, 1800) is true — over budget');
    is(eval { BpDispatchLog::is_over_budget(1800, 1800) }, !!0,
       'B3: is_over_budget(1800, 1800) is false — exactly AT budget is not OVER budget');
}

# B4 CANONICAL — budget_seconds undef must NOT read as "always within budget
# by omission" collapsing to false-forever, nor as "always over"; the spec is
# explicit: undef budget means "no budget configured", which is-over-budget
# reports as false (never true) because there is nothing to be over.
{
    my $got = eval { BpDispatchLog::is_over_budget(999999, undef) };
    is($got, !!0,
       'B4 CANONICAL: is_over_budget($big, undef) is false — "no budget configured" is not '
     . 'the same claim as "over budget", and must not silently resolve toward the alarming '
     . 'answer just because a number is missing');
}

# B5: median — empty list is undef ("no baseline yet"), never 0 (which would
# misread as "this worker type is instant").
{
    my $got = eval { BpDispatchLog::median([]) };
    ok(!defined $got, 'B5 CANONICAL: median([]) is undef, never 0 — "no baseline yet" must '
                     . 'never be misreadable as "this worker type takes 0 seconds"');
}

# B6: median — odd count is the middle value after numeric sort.
{
    my $got = eval { BpDispatchLog::median([300, 100, 200]) };
    is($got, 200, 'B6: median([300,100,200]) == 200 (numeric-sorted middle)');
}

# B7: median — even count is the arithmetic mean of the two middle values.
{
    my $got = eval { BpDispatchLog::median([100, 200]) };
    is($got, 150, 'B7: median([100,200]) == 150 (mean of the two middles)');
    my $got2 = eval { BpDispatchLog::median([400, 100, 300, 200]) };
    is($got2, 250, 'B7: median([400,100,300,200]) == 250 (sorted 100,200,300,400 -> mean of 200,300)');
}

# B8: record_path — a plain, predictable path under .dispatch-log/, keyed by
# id, ending .json. Not pinning the exact root computation (that is
# bp-runstate.pl::state_dir's convention, reused, not w02's to reinvent) —
# only the shape a caller can rely on.
{
    my $got = eval { BpDispatchLog::record_path('/some/root', 'x1') };
    ok(defined $got, 'B8: record_path returns a defined path');
    like($got, qr{\.dispatch-log[/\\]x1\.json\z},
         'B8: record_path ends ".dispatch-log/<id>.json" — the per-dispatch record slot');
}

# ===========================================================================
# C. CLI SURFACE — bp-dispatch-log.pl start/elapsed/list/finish (spec §2.3).
#    run_cli() refuses to shell out to a missing script (see header) so a
#    coincidental exit-2 from perl's own "can't open script" can never be
#    misread as this spec's own usage-error exit code.
# ===========================================================================
sub run_cli {
    my (@args) = @_;
    return (undef, undef, undef) unless -f $SCRIPT;
    my $tmp = tempdir(CLEANUP => 1);
    my ($out_f, $err_f) = ("$tmp/out", "$tmp/err");
    my $q = sub { my $a = shift; $a =~ s/"/\\"/g; return qq("$a") };
    my $cmd = join(' ', 'perl', $q->($SCRIPT), map { $q->($_) } @args);
    # fixbatch step7 / MEDIUM-2: --now is gated behind this env marker in
    # production (a production caller must never fabricate the driver's own
    # clock); this harness legitimately needs deterministic time in every
    # call below, so it sets the marker itself, exactly as the gate is
    # documented to require. Mechanical adaptation to the new interface,
    # not new test coverage — every assertion below keeps its exact prior
    # meaning.
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

# ---------------------------------------------------------------------------
# Behavior 1: start then elapsed, well under budget.
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc1, $out1) = run_cli('start', '--id', 'x1', '--worker-type', 'test-writer',
                                '--budget-seconds', '1800', '--now', '1000', '--root', $root);
    is($rc1, 0, 'C1: start exits 0');
    ok(-f record_file($root, 'x1'), 'C1: start writes a record file under .dispatch-log/x1.json '
                                   . '(paired with the exit-code check: a missing script fails BOTH)');

    my ($rc2, $out2) = run_cli('elapsed', '--id', 'x1', '--now', '1200', '--root', $root);
    is($rc2, 0, 'C1: elapsed exits 0');
    like($out2, qr/elapsed_seconds:\s*200\b/, 'C1 behavior-1: elapsed_seconds: 200');
    like($out2, qr/budget_seconds:\s*1800\b/, 'C1 behavior-1: budget_seconds: 1800');
    like($out2, qr/over_budget:\s*false\b/,   'C1 behavior-1: over_budget: false');
}

# ---------------------------------------------------------------------------
# Behavior 2: same record, later — now over budget.
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'x1', '--worker-type', 'test-writer',
            '--budget-seconds', '1800', '--now', '1000', '--root', $root);
    my ($rc, $out) = run_cli('elapsed', '--id', 'x1', '--now', '3000', '--root', $root);
    is($rc, 0, 'C2: elapsed exits 0');
    like($out, qr/elapsed_seconds:\s*2000\b/, 'C2 behavior-2: elapsed_seconds: 2000');
    like($out, qr/over_budget:\s*true\b/,     'C2 behavior-2: over_budget: true');
}

# ---------------------------------------------------------------------------
# Behavior 3: elapsed against a nonexistent id — exit 4, UNVERIFIABLE, never
# "elapsed_seconds: 0". This is the one place a coincidental exit-2 from a
# missing script would NOT collide (missing-script exit is always 2, not 4),
# but run_cli()'s undef-guard still applies uniformly.
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc, $out, $err) = run_cli('elapsed', '--id', 'nosuchid', '--root', $root);
    is($rc, 4, 'C3 behavior-3: elapsed on an unknown id exits 4');
    my $both = ($out // '') . ($err // '');
    like($both, qr/UNVERIFIABLE/, 'C3 behavior-3: names it UNVERIFIABLE');
    like($both, qr/nosuchid/,     'C3 behavior-3: names the missing id');
    unlike($both, qr/elapsed_seconds:\s*0\b/,
           'C3 behavior-3: NEVER prints elapsed_seconds: 0 for an unverifiable id — that '
         . 'would misreport "no record" as "a record that says zero"');
}

# ---------------------------------------------------------------------------
# Behavior 4: starting twice without an intervening finish refuses (exit 3),
# and the FIRST record's started_at is unchanged on disk (no clobber).
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'x1', '--worker-type', 'test-writer', '--now', '1000', '--root', $root);
    my $before = _slurp(record_file($root, 'x1'));

    my ($rc, $out, $err) = run_cli('start', '--id', 'x1', '--worker-type', 'test-writer',
                                    '--now', '9999', '--root', $root);
    is($rc, 3, 'C4 behavior-4: a second start on a still-running id exits 3');
    my $after = _slurp(record_file($root, 'x1'));
    is($after, $before,
       'C4 behavior-4: the FIRST record is byte-identical after the refused second start — '
     . 'no silent clobber of started_at');
    unlike(($out // '') . ($err // ''), qr/^\z/,
           'C4 behavior-4: the refusal prints SOMETHING (paired content check — a script that '
         . 'exits 3 by accident, printing nothing, is not this behavior)');
}

# ---------------------------------------------------------------------------
# Behavior 4b: a FINISHED id may be reused by a fresh start (not a permanent
# history entry — an id names a slot).
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'x1', '--worker-type', 'test-writer', '--now', '1000', '--root', $root);
    run_cli('finish', '--id', 'x1', '--status', 'done', '--now', '1100', '--root', $root);
    my ($rc) = run_cli('start', '--id', 'x1', '--worker-type', 'test-writer', '--now', '2000', '--root', $root);
    is($rc, 0, 'C4b: starting a fresh dispatch under a FINISHED id succeeds — an id names a '
             . 'reusable slot, not a permanent history entry');
}

# ---------------------------------------------------------------------------
# Behavior 5: finish --status done appends exactly one history.jsonl line;
# finish --status interrupted does NOT.
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'a1', '--worker-type', 'test-writer', '--now', '1000', '--root', $root);
    my ($rc) = run_cli('finish', '--id', 'a1', '--status', 'done', '--now', '2000', '--root', $root);
    is($rc, 0, 'C5 behavior-5: finish --status done exits 0');
    my $hist = _slurp(history_file($root));
    my @lines = grep { length } split /\n/, $hist;
    is(scalar(@lines), 1, 'C5 behavior-5: history.jsonl has exactly one line after one done finish');
    like($lines[0] // '', qr/"worker_type"\s*:\s*"test-writer"/, 'C5: line names the worker_type');
    like($lines[0] // '', qr/"duration_seconds"\s*:\s*1000\b/,   'C5: duration_seconds is 1000 (2000-1000)');
    like($lines[0] // '', qr/"ended_at"\s*:\s*2000\b/,           'C5: ended_at is 2000');

    run_cli('start', '--id', 'a2', '--worker-type', 'test-writer', '--now', '3000', '--root', $root);
    run_cli('finish', '--id', 'a2', '--status', 'interrupted', '--now', '3500', '--root', $root);
    my $hist2 = _slurp(history_file($root));
    my @lines2 = grep { length } split /\n/, $hist2;
    is(scalar(@lines2), 1,
       'C5 behavior-5: an INTERRUPTED finish adds NO history.jsonl line — a duration cut short '
     . 'by intervention must not pull the baseline toward the failures it exists to flag');
}

# ---------------------------------------------------------------------------
# Behavior 6/7: median_seconds surfaced alongside elapsed/over_budget, and
# "no baseline yet" is distinct from a numeric zero.
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    # Zero history first — behavior 7.
    run_cli('start', '--id', 'z1', '--worker-type', 'test-writer', '--now', '1000', '--root', $root);
    my (undef, $out0) = run_cli('elapsed', '--id', 'z1', '--now', '1100', '--root', $root);
    like($out0, qr/median_seconds:\s*(null|none|no[_ -]?baseline)/i,
         'C6 behavior-7: zero DONE history -> median_seconds reads as "no baseline" (null/'
       . 'none/no-baseline), never a bare number');
    unlike($out0, qr/median_seconds:\s*0\b/,
           'C6 behavior-7: NEVER median_seconds: 0 with no history — that reads as "this '
         . 'worker type is instant", which is a different, false claim');

    # Three completed dispatches of the same worker type -> median 200.
    for my $i (1..3) {
        my $dur = ($i == 1) ? 100 : ($i == 2) ? 200 : 300;
        run_cli('start', '--id', "m$i", '--worker-type', 'test-writer', '--now', '0', '--root', $root);
        run_cli('finish', '--id', "m$i", '--status', 'done', '--now', $dur, '--root', $root);
    }
    run_cli('start', '--id', 'x2', '--worker-type', 'test-writer', '--now', '5000', '--root', $root);
    my (undef, $out1) = run_cli('elapsed', '--id', 'x2', '--now', '5050', '--root', $root);
    like($out1, qr/median_seconds:\s*200\b/,
         'C6 behavior-6: three DONE durations (100,200,300) of the same worker_type -> '
       . 'median_seconds: 200 for a running dispatch of that type');
}

# ---------------------------------------------------------------------------
# Behavior 8: list shows both running records with correct over_budget tags,
# and drops a finished record.
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'r1', '--worker-type', 'test-writer',
            '--budget-seconds', '100', '--now', '0', '--root', $root);   # will be over
    run_cli('start', '--id', 'r2', '--worker-type', 'implementer',
            '--budget-seconds', '10000', '--now', '0', '--root', $root); # will not be over
    run_cli('start', '--id', 'r3', '--worker-type', 'test-writer', '--now', '0', '--root', $root);
    run_cli('finish', '--id', 'r3', '--status', 'done', '--now', '10', '--root', $root);

    my ($rc, $out) = run_cli('list', '--now', '500', '--root', $root);
    is($rc, 0, 'C7 behavior-8: list exits 0');
    like($out, qr/\br1\b/, 'C7 behavior-8: r1 (over budget, running) is listed');
    like($out, qr/\br2\b/, 'C7 behavior-8: r2 (within budget, running) is listed');
    unlike($out, qr/\br3\b/, 'C7 behavior-8: r3 (already finished) does NOT appear in list');

    # Tag correctness: r1's own line/record must say over_budget true, r2's false.
    # Matched loosely against the whole output since the exact line shape is
    # the implementer's to choose; the id-to-tag ASSOCIATION is what's pinned.
    like($out, qr/r1[^\n]*over_budget[^\n]*true|over_budget[^\n]*true[^\n]*r1/i,
         'C7 behavior-8: r1 is tagged over_budget true');
    like($out, qr/r2[^\n]*over_budget[^\n]*false|over_budget[^\n]*false[^\n]*r2/i,
         'C7 behavior-8: r2 is tagged over_budget false');
}

# ---------------------------------------------------------------------------
# Edge case (spec §5): a clock moving backward — elapsed_seconds is negative,
# unclamped, printed RAW so it is visible as an anomaly. over_budget is false
# on a negative elapsed (correct: not over budget), but must not be hidden.
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    run_cli('start', '--id', 'bw1', '--worker-type', 'test-writer',
            '--budget-seconds', '1800', '--now', '5000', '--root', $root);
    my ($rc, $out) = run_cli('elapsed', '--id', 'bw1', '--now', '1000', '--root', $root);
    is($rc, 0, 'C8 edge: elapsed still exits 0 on a backward clock (not an error condition)');
    like($out, qr/elapsed_seconds:\s*-4000\b/,
         'C8 CANONICAL edge: a backward clock prints the RAW negative elapsed_seconds, not a '
       . 'floored/clamped 0 — a stalled dispatch must never read as brand new');
    like($out, qr/over_budget:\s*false\b/, 'C8 edge: over_budget is false on a negative elapsed');
}

# ===========================================================================
# D. AC2 — grep-able absence: nothing in bp-dispatch-log.pl ever reads a
#    worker's self-reported duration_ms. The four-hour-vs-47-minutes gap this
#    whole package exists to close is, by construction, unreachable if this
#    string never appears in the file at all.
# ===========================================================================
{
    my $src;
    if (open my $fh, '<', $SCRIPT) {
        local $/;
        $src = <$fh>;
        close $fh;
    }
    ok(defined $src, 'D1: bp-dispatch-log.pl source is readable (fails until the file exists)');
    if (defined $src) {
        unlike($src, qr/duration_ms/,
               'D2 CANONICAL AC2: bp-dispatch-log.pl never reads/mentions "duration_ms" — '
             . 'elapsed time is measured driver-side from its own $now, never from anything '
             . 'a worker self-reports. A test that read the agent\'s own number to check the '
             . 'driver\'s number would be vacuous; this asserts the input is absent instead.');
    } else {
        fail('D2 CANONICAL AC2: cannot check for duration_ms — source unreadable (file missing)');
    }
}

# ===========================================================================
# E. fixbatch step7 / MEDIUM-1 — path-traversal in --id. The header comment
#    claims $ID_RE guards --id "before it ever reaches" record_path; that
#    was true only for `start`. `elapsed` and `finish` took --id straight
#    into record_path with no shape check at all, so a crafted --id could
#    read (elapsed) or, in a narrower case, write (finish) an arbitrary
#    *.json path reachable from the process's own OS permissions.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $outside = tempdir(CLEANUP => 1);
    open my $fh, '>', "$outside/secret.json" or die $!;
    print {$fh} '{"id":"leaked","worker_type":"sneaky","started_at":1,"budget_seconds":10,'
              . '"status":"running"}';
    close $fh;
    my $traversal = "../../../../../../..$outside/secret";
    # normalize to a relative-looking traversal id targeting the outside dir
    # from inside $root/.ccpraxis-local-data/.dispatch-log/, whatever depth
    # that is on this host — exercised against BOTH read commands that
    # previously skipped validation.
    my ($rc1, $out1, $err1) = run_cli('elapsed', '--id', $traversal, '--root', $root);
    isnt($rc1, 0, 'E1 (MEDIUM-1): elapsed with a path-traversal --id is REFUSED, not silently '
                . 'opening whatever the traversal resolves to');
    like(($err1 // ''), qr/invalid shape/, 'E1: refusal names the shape problem');

    my ($rc2, $out2, $err2) = run_cli('finish', '--id', $traversal, '--status', 'done',
                                       '--root', $root);
    isnt($rc2, 0, 'E2 (MEDIUM-1): finish with a path-traversal --id is REFUSED too — the guard '
                . 'now applies uniformly, not just to start');
    like(($err2 // ''), qr/invalid shape/, 'E2: refusal names the shape problem');

    # Sanity: the guard fires on the shape alone, before any --root/--id path
    # is touched — same refusal for a run whose --root doesn't even exist.
    my ($rc3, undef, $err3) = run_cli('elapsed', '--id', '../etc/passwd', '--root', $root);
    isnt($rc3, 0, 'E3: a simpler ../ traversal in --id is refused on elapsed too');
}

# ===========================================================================
# F. fixbatch step7 / NIT (elevated) — a non-numeric --budget-seconds must
#    not silently coerce to 0 (which would read as "every dispatch is
#    immediately over budget"). Falls back to the documented default (1800)
#    and warns, naming the rejected value.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc, $out, $err) = run_cli('start', '--id', 'badbudget', '--worker-type', 'test-writer',
                                    '--budget-seconds', 'abc', '--now', '1000', '--root', $root);
    is($rc, 0, 'F1 (NIT): a non-numeric --budget-seconds does not refuse the start outright');
    like($out, qr/budget_seconds=1800\b/,
         'F1: falls back to the documented default (1800), not a silent 0');
    like(($err // ''), qr/budget-seconds.*abc/s,
         'F1: warns naming the rejected value');

    my ($rc2, $out2) = run_cli('elapsed', '--id', 'badbudget', '--now', '1100', '--root', $root);
    like($out2, qr/budget_seconds:\s*1800\b/, 'F1: the persisted record carries the default, '
                                             . 'not a coerced 0');
    unlike($out2, qr/budget_seconds:\s*0\b/, 'F1: never a bare 0 budget from bad input');

    # 0 is explicitly NOT given a special "unlimited" meaning — it falls
    # back to the default exactly like any other non-positive value.
    my ($rc3, $out3, $err3) = run_cli('start', '--id', 'zerobudget', '--worker-type',
                                       'test-writer', '--budget-seconds', '0', '--now', '1000',
                                       '--root', $root);
    is($rc3, 0, 'F2: --budget-seconds 0 does not refuse the start outright');
    like($out3, qr/budget_seconds=1800\b/, 'F2: 0 is NOT treated as "unlimited" — it falls back '
                                          . 'to the default like any other invalid value');
    like(($err3 // ''), qr/budget-seconds.*0/s, 'F2: warns naming the rejected value (0)');
}

done_testing();
