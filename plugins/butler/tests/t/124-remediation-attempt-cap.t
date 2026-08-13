#!/usr/bin/env perl
# t/119-remediation-attempt-cap.t — oracle for r01-remediation-attempt-cap.
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/r01-remediation-attempt-cap-spec.md
# (sections 0-6) plus the confirmed root cause in
# reports/r01-remediation-attempt-cap/scout-step1.md. WRITTEN BLIND TO THE FIX.
#
# TWO STRUCTURALLY INDEPENDENT DEFECTS ARE PINNED SEPARATELY, ON PURPOSE, SO A
# PARTIAL FIX SHOWS AS PARTIAL:
#
#   DEFECT 1 (§2.1, Fix A's %att half) — _load_state builds %att only from
#   `keys %$dag` (blueprint.md's table). remediation_merge adds a remediation-
#   queue package into %meta/%status strictly AFTER that read, and never
#   touches %att. So a remediation package's attempt count is undef forever,
#   effective_attempts clamps it to 0, and BP_ATTEMPT_CAP never trips.
#   Blocks A and B below pin this half, via the watchdog_relaunch/watchdog_block
#   JSONL record's `attempts` field carrying an EXACT, registry-seeded integer
#   — never merely "defined", because effective_attempts(undef,...) already
#   returns 0 today, so `ok(defined $attempts)` or `$attempts >= 0` would pass
#   identically before and after the fix (spec §0.3's named vacuity trap).
#
#   DEFECT 2 (§2.1, Fix A's %pid half — found by the architect, NOT the scout)
#   — %pid/%sid have the IDENTICAL ordering bug. A remediation package's pid is
#   undef forever, so pid_alive(undef) always reports dead, and a genuinely
#   alive, progressing coordinator is treated as dead on EVERY watchdog tick.
#   Block C below pins this half independently: it forces the "already
#   launched" gate to be TRUE via the queue entry's pkg_status (decoupled from
#   the attempt/pid backfill under test — see its own comment for why), so the
#   only thing that can make the assertion pass or fail is whether %pid was
#   correctly backfilled.
#
# Also pinned: the min_relaunch interval guard (§2.2, Fix B) — Block D — and
# its DELIBERATE non-persistence across orchestrator restarts (§5) — Block E,
# which exists specifically to catch a future implementer "durability-
# hardening" %last_relaunch_at into the registry, which the spec says would
# silently break t/68-exit-reason-classification.t's C4 oracle (four SEPARATE
# go() calls at a FIXED $now, simulating four restarts).
#
# THE t/68 C1 LANDMINE (read before touching anything here): t/68's C1 block
# asserts, as CORRECT, that a success-subtype exit on a NON-terminal package
# produces a watchdog_relaunch. Nothing in this file asserts the opposite —
# Block B proves only that a `success` exit_reason does not let a package
# dodge the attempt cap forever, which is a claim about repeated occurrences
# past BP_ATTEMPT_CAP, not about any single success exit being refused.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

my $ORCH = "$Bin/../../scripts/bp-orchestrator.pl";
require $ORCH;   # package BpOrch; also requires bp-remediate.pl (BpRemediate) transitively

diag("subject under test: $ORCH — _load_state / remediation_merge ordering, "
   . "the watchdog relaunch/block sites, and the (not-yet-existing) min_relaunch guard");

my $J = JSON::PP->new->canonical;

# =====================================================================================
# Scaffolding — File::Temp only, house style copied from t/68-exit-reason-classification.t.
# =====================================================================================
my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = 2_100_000_000;
my $DEAD_PID = 2_100_000_001;   # out of range -> kill 0 fails -> not alive (t/06/t/61/t/68 convention)

ok(!kill(0, $DEAD_PID), "fixture sanity: DEAD_PID=$DEAD_PID is verified dead via kill 0");
ok(kill(0, $$), "fixture sanity: \$\$=$$ (this process) is verified ALIVE via kill 0 -- "
    . 'the pid Block C seeds as a genuinely live coordinator');

sub spit      { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f; return $p }
sub slurp_raw { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $c = <$f>; close $f; return $c }

sub iso_of {
    my ($e) = @_;
    my @g = gmtime($e);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1], $g[0]);
}

my $bpn = 0;
# $pkgs: DAG (blueprint.md-table) packages ONLY -- [] for every fixture in this
# file, because every fixture under test is deliberately a remediation-queue-
# only package (spec §0 trap #2: "present in remediation-queue.json's entries,
# absent from blueprint.md's table" — a package merely NAMED like one but
# listed in blueprint.md exercises the wrong, already-working code path).
sub mk_bp {
    my ($pkgs, $registry) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->[0] | d | $_->[1] | sonnet | $_->[2] |\n" for @$pkgs;
    close $b;
    if ($registry) { spit("$dir/runs/registry.json", $J->encode({ packages => $registry })); }
    spit("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-SCN-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-SCNREF-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 5*3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
    return $dir;
}

# a remediation package's own ledger -- real remediation packages DO get one
# (bp-remediate.pl's author_ledger), and _block_and_queue's _set_ledger_status
# needs valid frontmatter to record 'blocked' -- so fixtures that exercise the
# cap's escalation path get a real ledger file, matching production shape.
sub write_ledger {
    my ($dir, $name, $status) = @_;
    mkdir "$dir/packages" unless -d "$dir/packages";
    open my $l, '>', "$dir/packages/$name.md" or die;
    print $l "---\npackage: $name\nblueprint: T\nstatus: $status\nwrite_set: p/$name/\n"
           . "test_paths: p/$name/\nlast_updated: 2026-06-24T00:00:00Z\n---\n# $name\n\n## Next action\n\ngo\n";
    close $l;
}

# a schema-valid remediation-queue.json with ONE entry, per bp-remediate.pl's
# own @ENTRY_MANDATORY_KEYS (bp-remediate.pl:423-427) -- every mandatory key
# present, so merge_queue's queue_ok-style consumers never fail-closed on a
# malformed fixture and mask the defect under test.
sub write_queue {
    my ($dir, %o) = @_;
    my $id = $o{id};
    my $entry = {
        id             => $id,
        finding_key    => $o{finding_key} // 'r01-test-finding',
        round          => 1,
        max_rounds     => 2,
        source         => 'conformance',
        action         => 'remediate-conformance',
        disposition    => 'auto',
        state          => 'queued',                    # never resolved on-disk -> stays queued
        pkg_status     => $o{pkg_status} // 'running',  # see Block C for why this is NOT 'pending'
        ledger_path    => "packages/$id.md",
        write_set      => "p/$id/",
        test_paths     => "p/$id/",
        deps           => [],
        model          => 'sonnet',
        max_turns      => 60,
        mandated_means => [],
        signature      => 'sig-r01-test',
        finding        => { kind => 'conformance-deviation', subject => 'r01', detail => 'test fixture',
                             evidence => {}, remedy => { action => 'remediate-conformance' } },
        created_at     => iso_of($NOW),
        updated_at     => iso_of($NOW),
        history        => [ { round => 1, at => iso_of($NOW), event => 'authored', signature => 'sig-r01-test' } ],
        escalation_reason => undef,
    };
    my $queue = {
        schema => 'remediation-queue/1', generated_at => iso_of($NOW), project => 'T',
        rounds_used => 0, rounds_cap => 6, gate_firings => 0, last_verdict => undef,
        entries => [ $entry ], escalated => [], notes => [],
    };
    spit("$dir/runs/remediation-queue.json", $J->encode($queue));
    return $entry;
}

sub result_line {
    my (%o) = @_;
    my %base = (type => 'result', timestamp => iso_of($o{epoch}), session_id => $o{sid} // 'sid-x',
                num_turns => $o{num_turns} // 40);
    if ($o{reason} eq 'success') { return { %base, is_error => JSON::PP::false, subtype => 'success' } }
    if ($o{reason} eq 'error')   { return { %base, is_error => JSON::PP::true,  subtype => 'error_other', terminal_reason => 'error' } }
    die "result_line: unknown reason $o{reason}";
}
sub jline { return $J->encode($_[0]) . "\n" }
sub transcript_path { my ($dir, $pkg) = @_; return "$dir/runs/$pkg.jsonl" }

my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });

# resolve_cap => 0: BpJudge::escalation_verdict({resolve_attempts=>0, resolve_cap=>0})
# returns 'park' immediately (0 < 0 is false) -- every fixture in this file goes
# straight from "past the cap" to _block_and_queue in one tick, with no
# resolve-judge spawn in between. That machinery is out of scope here (r01's
# own spec §1 "what this spec does NOT change") and is exercised elsewhere
# (t/26, t/10-judges.t).
sub tun {
    my (%o) = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>10, cap=>5, flat=>600, watch_tick=>0,
             keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
             tele_retry=>3, usage_fail=>60, busy_path=>"$ROOT/busy" . (++$bpn),
             harvest=>'audit', resolve_cap=>0, corr_cap=>1, judge_to=>600, judge_spawn_cap=>3,
             turn_starved_thresh => 100,
             %o };
}

sub go {
    my (%o) = @_;
    my $dir = $o{dir};
    my (@L, $err);
    my $seam = sub {
        my ($a) = @_;
        push @L, { pkg => $a->{pkg}, kind => $a->{kind}, args => [ @{ $a->{args} || [] } ] };
        return $o{launch} ? $o{launch}->($a) : 0;
    };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            tunables => $o{tunables}, once => 1,
            now => ($o{now} || sub { $NOW }), sleep => sub {},
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            spawn_judge => sub { 0 },
            launch => $seam,
        });
        1;
    } or $err = $@;
    return (\@L, ($err // ''));
}

sub log_events {
    my ($dir) = @_;
    my $c = slurp_raw("$dir/runs/orchestrator.log");
    return () unless defined $c;
    return map { eval { $J->decode($_) } || {} } grep { /\S/ } split /\n/, $c;
}
sub log_of     { my ($dir, $type) = @_; return grep { ($_->{type} // '') eq $type } log_events($dir) }
sub log_of_pkg { my ($dir, $type, $pkg) = @_; return grep { ($_->{package} // '') eq $pkg } log_of($dir, $type) }
sub explain_log { my ($dir) = @_; return join("\n", map { $J->encode($_) } log_events($dir)) }
sub fmt_offsets { my ($a) = @_; return join(',', @$a) }

# =====================================================================================
# BLOCK A — Defect 1's %att half, plus AC-7's exact ordering scenario (§2.1, §4
# AC-1/AC-2/AC-7). A remediation-queue-only package, registry attempt seeded ONE
# BELOW the cap, so tick 1 relaunches (proving effective_attempts resolves a
# real, registry-derived number, not 0/undef) and, after the registry is bumped
# to the cap exactly the way bp-launch.sh's own increment would, tick 2 blocks.
# =====================================================================================
{
    my $pkg = 'rem-capwalk';
    my $reg = { $pkg => { attempt => 4, pid => $DEAD_PID, status => 'pending', session_id => 'sid-capwalk' } };
    my $dir = mk_bp([], $reg);
    write_ledger($dir, $pkg, 'running');
    write_queue($dir, id => $pkg, pkg_status => 'running');
    spit(transcript_path($dir, $pkg), jline(result_line(reason => 'error', epoch => $NOW - 300, sid => 'sid-capwalk')));

    my ($L1, $err1) = go(dir => $dir, tunables => tun());
    is($err1, '', 'BLOCK A tick 1: go() ran without a Perl exception') or diag($err1);

    my ($relaunch1) = log_of_pkg($dir, 'watchdog_relaunch', $pkg);
    ok($relaunch1, 'AC-1/AC-7 tick 1: a remediation-queue-only package (never in blueprint.md) got a '
        . 'watchdog_relaunch at all -- proves the ordering fix reads the merged-in package, not just '
        . 'confirms a number') or diag(explain_log($dir));
    is($relaunch1 && $relaunch1->{attempts}, 4,
        'AC-1/AC-2: watchdog_relaunch.attempts is the EXACT registry-seeded integer 4 -- not 0, not '
      . 'undef/null (JSON null), and not merely `defined` (effective_attempts(undef,...) already '
      . 'returns 0 today, so a defined-only check would pass identically before and after the fix; '
      . '0 seeded here would be indistinguishable from the undef-clamped-to-0 defect, so 4 is load-bearing)');
    is($relaunch1 && $relaunch1->{exit_reason}, 'error',
        'BLOCK A tick 1 fixture sanity: exit_reason classified as a genuine crash (not the success '
      . 'path Block B exercises separately)');
    is(scalar(log_of_pkg($dir, 'watchdog_block', $pkg)), 0,
        'AC-7: NOT yet blocked at attempt 4 < cap 5 -- the cap has not tripped early');

    # Simulate bp-launch.sh's own attempt increment (bp-launch.sh:110) exactly as
    # it happens on a real relaunch, keeping the pid dead (still DEAD_PID) so the
    # SAME package is rediscovered dead on the next tick -- this is what "relaunched
    # past the cap" means operationally: attempt count crossed BP_ATTEMPT_CAP between
    # two watchdog observations of the same package.
    BpOrch::update_registry_pkg("$dir/runs", $pkg, { attempt => 5 });

    my ($L2, $err2) = go(dir => $dir, tunables => tun());
    is($err2, '', 'BLOCK A tick 2: go() ran without a Perl exception') or diag($err2);

    my ($block2) = log_of_pkg($dir, 'watchdog_block', $pkg);
    ok($block2, 'AC-1/AC-7: a remediation-queue-only package IS blockable once its (registry-derived) '
        . 'attempt count reaches BP_ATTEMPT_CAP -- proves the cap comparison actually trips for a '
        . 'package that was never in blueprint.md\'s DAG at any point in this test') or diag(explain_log($dir));
    is($block2 && $block2->{attempts}, 5,
        'AC-2: watchdog_block.attempts is the exact integer 5 (net of zero continuation/rate-limit '
      . 'discounts in this fixture) -- never null');
    is(scalar(log_of_pkg($dir, 'watchdog_relaunch', $pkg)), 1,
        'AC-7: exactly ONE relaunch happened before the block (tick 1) -- the package did not relaunch '
      . 'again on tick 2 once past the cap');
    is(BpOrch::ledger_fm($dir, $pkg, 'status'), 'blocked',
        'AC-1: the cap actually STOPS the package -- its ledger status is flipped to blocked, not '
      . 'merely logged as blocked with the coordinator left to relaunch again next tick');
}

# =====================================================================================
# BLOCK B — Criterion 3 / AC-3: a remediation package whose coordinator reports
# exit_reason=success on every one of its (simulated) deaths is STILL blocked
# once BP_ATTEMPT_CAP is reached. Deliberately NOT a "success is refused" test —
# see the t/68 C1 landmine note at the top of this file and spec §2.3's verdict:
# a single success exit on a non-terminal package legitimately continues.
# =====================================================================================
{
    my $pkg = 'rem-successloop';
    my $reg = { $pkg => { attempt => 4, pid => $DEAD_PID, status => 'pending', session_id => 'sid-success' } };
    my $dir = mk_bp([], $reg);
    write_ledger($dir, $pkg, 'running');
    write_queue($dir, id => $pkg, pkg_status => 'running');
    spit(transcript_path($dir, $pkg), jline(result_line(reason => 'success', epoch => $NOW - 300, sid => 'sid-success')));

    my ($L1, $err1) = go(dir => $dir, tunables => tun());
    is($err1, '', 'BLOCK B tick 1: go() ran without a Perl exception') or diag($err1);
    my ($relaunch1) = log_of_pkg($dir, 'watchdog_relaunch', $pkg);
    ok($relaunch1, 'BLOCK B tick 1: relaunched (legitimate -- attempt 4 < cap 5, same as t/68 C1\'s '
        . 'own success_warm fixture)') or diag(explain_log($dir));
    is($relaunch1 && $relaunch1->{exit_reason}, 'success', 'BLOCK B tick 1: exit_reason logged success');

    BpOrch::update_registry_pkg("$dir/runs", $pkg, { attempt => 5 });
    my ($L2, $err2) = go(dir => $dir, tunables => tun());
    is($err2, '', 'BLOCK B tick 2: go() ran without a Perl exception') or diag($err2);

    my ($block2) = log_of_pkg($dir, 'watchdog_block', $pkg);
    ok($block2, "AC-3: exit_reason=success on EVERY death does not exempt a remediation package from "
        . 'BP_ATTEMPT_CAP -- once attempts reach the cap it is blocked exactly like any other exit '
        . 'reason') or diag(explain_log($dir));
    is($block2 && $block2->{attempts}, 5, 'AC-3: blocked with the exact attempt count 5, not null');
    is(scalar(log_of_pkg($dir, 'watchdog_relaunch', $pkg)), 1,
        'AC-3: success did not buy this package a SECOND relaunch past the cap');
}

# =====================================================================================
# BLOCK C — Defect 2 (%pid's identical ordering bug), AC-4: a remediation
# package whose coordinator is GENUINELY ALIVE (real, live pid = $$, this test
# process) must be routed to the alive/progress branch, never phantom-relaunched
# as if dead.
#
# NON-VACUITY: pkg_status is seeded 'running' (not 'pending'), which forces the
# watchdog's own $launched gate TRUE via the `$status ne 'pending'` disjunct
# (bp-orchestrator.pl:3033) REGARDLESS of whether %att/%pid are backfilled --
# so this assertion cannot pass merely because the package was skipped as
# "never launched". The only thing that can make it pass or fail is whether
# pid_alive() ever sees the real pid, i.e. whether %pid was correctly
# backfilled. attempt is seeded 1 (nowhere near the cap of 5), so Defect 1's
# fix (or its absence) cannot itself explain a pass/fail here either --
# isolating Defect 2 from Defect 1.
# =====================================================================================
{
    my $pkg = 'rem-alive';
    my $reg = { $pkg => { attempt => 1, pid => $$, status => 'running', session_id => 'sid-alive' } };
    my $dir = mk_bp([], $reg);
    write_ledger($dir, $pkg, 'running');
    write_queue($dir, id => $pkg, pkg_status => 'running');
    spit(transcript_path($dir, $pkg), jline(result_line(reason => 'success', epoch => $NOW - 300, sid => 'sid-alive')));

    my ($L, $err) = go(dir => $dir, tunables => tun());
    is($err, '', 'BLOCK C: go() ran without a Perl exception') or diag($err);

    is(scalar(log_of_pkg($dir, 'watchdog_relaunch', $pkg)), 0,
        "AC-4: a remediation package with a GENUINELY LIVE coordinator (real pid \$\$=$$, verified "
      . 'alive via kill 0 at the top of this file) produces NO watchdog_relaunch -- if %pid is not '
      . "backfilled, pid_alive(undef) reports dead every tick and this WILL fire (the field bug's "
      . 'actual mechanism, per the driver-corrected root cause: liveness misclassification, not merely '
      . 'the cap)') or diag(explain_log($dir));
    ok(!(grep { $_->{pkg} eq $pkg } @$L),
        'AC-4: the launch seam itself was never invoked for this package -- no coordinator was '
      . 'launched on top of the one that is actually still running');
    is(scalar(log_of_pkg($dir, 'watchdog_kill_wedged', $pkg)), 0,
        'AC-4 sanity: not even routed through the ALIVE-but-wedged branch -- first observation always '
      . 'reads "growing" (progress_verdict\'s own rule), so a correctly-alive package is silently '
      . 'healthy, not killed-and-restarted');
}

# =====================================================================================
# BLOCK D — Fix B / AC-5: the min_relaunch interval guard makes "N relaunches in
# under min_relaunch seconds" impossible by construction, for a package whose
# coordinator is (mis)discovered dead on EVERY tick. Requires a genuine
# multi-tick SINGLE run() invocation -- per spec §5's explicit warning, a test
# built from separate once=>1 calls (t/68 C4's own pattern) can never observe
# this guard, by design, and must not be used to claim this AC.
# =====================================================================================
{
    my $pkg = 'rem-storm';
    my $reg = { $pkg => { attempt => 1, pid => $DEAD_PID, status => 'running', session_id => 'sid-storm' } };
    my $dir = mk_bp([], $reg);
    write_ledger($dir, $pkg, 'running');
    write_queue($dir, id => $pkg, pkg_status => 'running');
    spit(transcript_path($dir, $pkg), jline(result_line(reason => 'error', epoch => $NOW - 300, sid => 'sid-storm')));

    # 7 ticks, ~8s apart (deliberately faster than min_relaunch=30 -- mirrors the
    # field run's ~10-20s watchdog cadence), spanning 48s of simulated time.
    my @offsets = (0, 8, 16, 24, 32, 40, 48);
    my $tick = 0;
    my (@L, $err);
    my $seam = sub {
        my ($a) = @_;
        push @L, { pkg => $a->{pkg}, kind => $a->{kind}, at_offset => $offsets[$tick] };
        return 0;   # every actual launch attempt "succeeds"
    };
    my $now_fn   = sub { return $NOW + ($offsets[$tick] // $offsets[-1]) };
    my $sleep_fn = sub {
        $tick++;
        if ($tick >= scalar(@offsets)) { spit("$dir/runs/.shutdown", ''); }
    };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            tunables => tun(min_relaunch => 30),
            now => $now_fn, sleep => $sleep_fn,
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            spawn_judge => sub { 0 },
            launch => $seam,
        });
        1;
    } or $err = $@;
    is($err // '', '', 'BLOCK D: multi-tick go() ran without a Perl exception') or diag($err);

    my @relaunches = log_of_pkg($dir, 'watchdog_relaunch', $pkg);

    is(scalar(@relaunches), 2,
        'AC-5/AC-6: across 7 ticks spanning 48s (a package that is discovered dead EVERY tick, and '
      . 'whose attempt count never approaches the cap), the min_relaunch=30s guard permits exactly 2 '
      . 'actual relaunches (t=0 and t=32) -- not one per tick. Without this guard, a package this dead '
      . 'relaunches on every eligible tick, reproducing the field\'s "4 in ~30s" storm exactly')
        or diag(explain_log($dir));

    my @launch_offsets = map { $_->{at_offset} } grep { $_->{pkg} eq $pkg } @L;
    my @within_first_30s = grep { $_ < 30 } @launch_offsets;
    is(scalar(@within_first_30s), 1,
        'AC-5: within the FIRST 30 seconds (offsets 0/8/16/24 -- exactly the field\'s "4 relaunches in '
      . 'about 30 seconds"), only ONE actual launch reaches the seam -- "4 in 30s" is impossible by '
      . 'construction, not merely improbable') or diag(fmt_offsets(\@launch_offsets));
    is_deeply(\@launch_offsets, [0, 32],
        'AC-5: the two actual launches land exactly at t=0 (unconditional first relaunch) and t=32 '
      . '(the first tick at or past the 30s floor since the last actual launch) -- proves the guard '
      . 'measures from the LAST LAUNCH, not from a fixed schedule');

    my @deferred = log_of_pkg($dir, 'relaunch_deferred', $pkg);
    my @min_interval_deferred = grep { ($_->{reason} // '') eq 'min_interval' } @deferred;
    is(scalar(@min_interval_deferred), 5,
        'AC-5: the 5 ticks that did NOT launch (t=8,16,24,40,48) are explicitly logged as deferred with '
      . "reason 'min_interval' (the contract's own promised reason string, §2.2) -- not silently "
      . 'dropped and not conflated with the pre-existing "parallel cap full" deferral reason')
        or diag(explain_log($dir));

}

# =====================================================================================
# BLOCK E — §5's load-bearing non-persistence requirement: %last_relaunch_at is
# LOOP-SCOPE, never written to registry.json. Two SEPARATE go() (once=>1)
# invocations, 5 seconds apart by the injected `now`, for a package that is
# rediscovered dead both times, MUST BOTH relaunch. If a future implementer
# "durability-hardens" the guard into the registry, the second call would see
# now-last==5 < 30 and defer -- this assertion would then fail, exactly
# mirroring the mechanism the spec says would silently break t/68 C4's
# is_deeply(['cold','cold','cold','cold']) oracle (four SEPARATE go() calls at
# a FIXED $now).
# =====================================================================================
{
    my $pkg = 'rem-restart';
    my $reg = { $pkg => { attempt => 1, pid => $DEAD_PID, status => 'running', session_id => 'sid-restart' } };
    my $dir = mk_bp([], $reg);
    write_ledger($dir, $pkg, 'running');
    write_queue($dir, id => $pkg, pkg_status => 'running');
    spit(transcript_path($dir, $pkg), jline(result_line(reason => 'error', epoch => $NOW - 300, sid => 'sid-restart')));

    my ($L1, $err1) = go(dir => $dir, tunables => tun(min_relaunch => 30), now => sub { $NOW });
    is($err1, '', 'BLOCK E call 1: go() ran without a Perl exception') or diag($err1);
    my ($r1) = log_of_pkg($dir, 'watchdog_relaunch', $pkg);
    ok($r1, 'BLOCK E call 1: relaunched') or diag(explain_log($dir));

    my ($L2, $err2) = go(dir => $dir, tunables => tun(min_relaunch => 30), now => sub { $NOW + 5 });
    is($err2, '', 'BLOCK E call 2: go() ran without a Perl exception') or diag($err2);
    my @r2 = log_of_pkg($dir, 'watchdog_relaunch', $pkg);

    is(scalar(@r2), 2,
        'AC (§5 non-persistence): a SECOND, SEPARATE process (fresh go()/run() invocation, "now" only '
      . '5s later -- well inside min_relaunch=30) still relaunches the package. %last_relaunch_at does '
      . 'NOT survive across orchestrator restarts by design -- if a future implementer persists it to '
      . 'registry.json, this second call would be deferred instead, and this count would read 1, not 2')
        or diag(explain_log($dir));
}

# =====================================================================================
# BLOCK F — the min_relaunch tunable itself: default 30, env-overridable via
# BP_MIN_RELAUNCH_SECS, exactly the house convention already used by every
# other _tunables_base() key (t/21 AC-16's ckpt_int test is the direct model).
# =====================================================================================
{
    delete local $ENV{BP_MIN_RELAUNCH_SECS};
    is(BpOrch::_tunables_base()->{min_relaunch}, 30,
        'BLOCK F: _tunables_base()->{min_relaunch} defaults to 30 with no env override');
}
{
    local $ENV{BP_MIN_RELAUNCH_SECS} = 7;
    is(BpOrch::_tunables_base()->{min_relaunch}, 7,
        'BLOCK F: BP_MIN_RELAUNCH_SECS=7 makes _tunables_base()->{min_relaunch} 7');
}
{
    delete local $ENV{BP_MIN_RELAUNCH_SECS};
    is(BpOrch::_tunables_base()->{min_relaunch}, 30,
        'BLOCK F: reverts to the 30 default once the env override is removed (not sticky/cached)');
}

# =====================================================================================
# BLOCK G — fixbatch-step7 item 1: BP_MIN_RELAUNCH_SECS is the ONE
# _tunables_base() key that must NOT be silently defeatable -- the red-team
# reproduced the field storm exactly via min_relaunch=0 (7 launches in 48s,
# vs 2 at the documented default). Every malformed form falls back to the
# documented default (30) AND warns, naming the rejected value. 0 is
# deliberately NOT special-cased as "disabled".
# =====================================================================================
for my $bad ('0', '-1', '', 'abc', '0.5', ' 5', '5 ') {
    local $ENV{BP_MIN_RELAUNCH_SECS} = $bad;
    my $warned;
    local $SIG{__WARN__} = sub { $warned = $_[0]; };
    my $got = BpOrch::_tunables_base()->{min_relaunch};
    is($got, 30, "BLOCK G: BP_MIN_RELAUNCH_SECS='$bad' falls back to the default (30), not accepted/clamped");
    like($warned // '', qr/\Q$bad\E/, "BLOCK G: BP_MIN_RELAUNCH_SECS='$bad' emits a warning naming the rejected value")
        or diag("no warning captured for '$bad'");
}
{
    local $ENV{BP_MIN_RELAUNCH_SECS} = '12';
    my $warned;
    local $SIG{__WARN__} = sub { $warned = $_[0]; };
    is(BpOrch::_tunables_base()->{min_relaunch}, 12,
        'BLOCK G: a valid positive integer (12) is honoured exactly');
    ok(!defined $warned, 'BLOCK G: a valid positive integer emits NO warning');
}

# =====================================================================================
# BLOCK H — fixbatch-step7 item 2: a %last_relaunch_at entry that is AHEAD of
# $now (a forward clock jump, then a correction back to normal cadence) must
# NOT wedge the package forever waiting for real time to catch up to the
# stale future value -- the inverse failure of the storm (never relaunching).
# Multi-tick, single run() invocation, same house pattern as BLOCK D. The
# jump (3000s) is kept well under the fixture's credential expiry window
# (5h) so it does not also trip an unrelated token-floor refresh/pause path.
# =====================================================================================
{
    my $pkg = 'rem-clockjump';
    my $reg = { $pkg => { attempt => 1, pid => $DEAD_PID, status => 'running', session_id => 'sid-jump' } };
    my $dir = mk_bp([], $reg);
    write_ledger($dir, $pkg, 'running');
    write_queue($dir, id => $pkg, pkg_status => 'running');
    spit(transcript_path($dir, $pkg), jline(result_line(reason => 'error', epoch => $NOW - 300, sid => 'sid-jump')));

    # t=0 (unconditional first relaunch, sets last=0), t=3000 (a forward jump --
    # unconditionally past min_relaunch=30, sets last=3000), then a CORRECTED
    # clock walking t=40..96 -- all strictly LESS than the stale last=3000, so
    # $now - $last is negative throughout this window. A buggy guard treats a
    # negative delta as "< min_relaunch" (true) and defers every one of these
    # ticks forever; the fix treats last > now as stale and relaunches at the
    # first corrected tick.
    my @offsets = (0, 3000, 40, 48, 56, 64, 72, 80, 88, 96);
    my $tick = 0;
    my (@L, $err);
    my $seam = sub {
        my ($a) = @_;
        push @L, { pkg => $a->{pkg}, at_offset => $offsets[$tick] };
        return 0;
    };
    my $now_fn   = sub { return $NOW + ($offsets[$tick] // $offsets[-1]) };
    my $sleep_fn = sub {
        $tick++;
        if ($tick >= scalar(@offsets)) { spit("$dir/runs/.shutdown", ''); }
    };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            tunables => tun(min_relaunch => 30),
            now => $now_fn, sleep => $sleep_fn,
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            spawn_judge => sub { 0 },
            launch => $seam,
        });
        1;
    } or $err = $@;
    is($err // '', '', 'BLOCK H: multi-tick go() ran without a Perl exception') or diag($err);

    my @launch_offsets = map { $_->{at_offset} } grep { $_->{pkg} eq $pkg } @L;
    ok((grep { $_ > 40 - 1 && $_ < 3000 } @launch_offsets) || (grep { $_ >= 40 && $_ <= 96 } @launch_offsets),
        'BLOCK H: at least one relaunch reaches the seam DURING the corrected-clock window (t=40..96) -- '
      . 'the future-dated last_relaunch_at does not wedge the package until real time catches up to it')
        or diag('launch offsets: ' . fmt_offsets(\@launch_offsets));
    ok(!(grep { $_ < 0 } @launch_offsets), 'BLOCK H sanity: no launch recorded at a negative/impossible offset');
}

done_testing();
