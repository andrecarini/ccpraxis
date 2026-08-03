#!/usr/bin/env perl
# t/81-usage-poll-cadence.t — immutable oracle for b30-usage-poll-cadence-floor.
#
# Derived from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b30-usage-poll-cadence-floor-spec.md
# sections 0, 2 and 4 (C1..C7). Exercises the REAL BpGovern functions
# (plugins/butler/scripts/bp-govern.pl) with injected samples — no live API, no sleeping,
# no wall clock. `window_cadence` currently (pre-fix) reads:
#
#     return 1800 if !defined $burn || $burn <= 0;
#     return clamp(($headroom / $burn) * 0.5, 60, 1800);
#
# which is fail-UNSAFE on unknown burn (returns the SLOW floor instead of the fast one), treats a
# flat burn as automatically safe regardless of proximity to the ceiling, and has no ceiling-
# proximity cap at all. This file is written BLIND to the fix — every C1/C2/C3 assertion below is
# expected to fail on the CURRENT wrong return value, never on a Perl exception, a missing module,
# or a wrong require path.
#
# SYN-23: nothing here cites a bp-govern.pl / bp-orchestrator.pl line number; locate by grep pattern.
#
# MANDATORY VACUITY GATE (spec §4's own standing rule): C3 (unknown burn -> FAST) and C4 (idle flat
# burn -> SLOW/MAX) are opposites, and each is trivially satisfiable alone: an implementation that
# always returns CADENCE_MIN_S passes C3 but fails C4; one that always returns CADENCE_MAX_S passes
# C4 but fails C3. Both blocks below assert POSITIVE, CONCRETE, DIFFERENT numeric outcomes
# (CADENCE_MIN_S vs CADENCE_MAX_S) from inputs that differ ONLY in the one dimension the rule cares
# about (span-under-minimum / dt<=0 / too-few-samples vs. a long flat span) — so no constant-
# returning implementation of window_cadence can pass both C3 and C4 in this file: C3 requires the
# return to equal CADENCE_MIN_S (and explicitly NOT CADENCE_MAX_S) on three fixtures, C4 requires
# the return to equal CADENCE_MAX_S (and explicitly NOT CADENCE_MIN_S) on a fourth. A hardcoded-fast
# implementation fails C4's "== CADENCE_MAX_S" assertions; a hardcoded-slow implementation fails
# C3's "== CADENCE_MIN_S" / "!= CADENCE_MAX_S" assertions. This is verified explicitly in the C3/C4
# block below via a direct cross-check (asserting the two outcomes are NOT equal to each other).

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $GOVERN = "$Bin/../../scripts/bp-govern.pl";
require $GOVERN;

diag("subject under test: $GOVERN");

my $SRC = do {
    open my $fh, '<', $GOVERN or die "cannot read $GOVERN: $!";
    local $/;
    <$fh>;
};

# ── named-constant helpers ──────────────────────────────────────────────────
# Spec table (§2): CADENCE_MIN_S=60, CADENCE_MAX_S=1800, CADENCE_NEAR_CEIL_UTIL=75,
# CADENCE_NEAR_CEIL_MAX_S=120, BURN_MIN_SPAN_S=180. These must appear as NAMED CONSTANTS in
# bp-govern.pl, not as bare literals scattered through window_cadence's expression body.
sub named_const_count {
    my ($name, $value) = @_;
    my @m = ($SRC =~ /\b\Q$name\E\b\s*(?:=>|=)\s*\Q$value\E\b/g);
    return scalar @m;
}

# Fallback numeric values used to drive the fixtures below even while the fix (and hence the named
# constants) doesn't exist yet — pinned from the spec table, §2.
use constant {
    CADENCE_MIN_S           => 60,
    CADENCE_MAX_S           => 1800,
    CADENCE_NEAR_CEIL_UTIL  => 75,
    CADENCE_NEAR_CEIL_MAX_S => 120,
    BURN_MIN_SPAN_S         => 180,
};

my $TRIP = 85;   # the 85% ceiling from the real incident / spec §0.

# =====================================================================================
# C1 — the regression, literally. Real logged five-hour utilisation samples (spec §0/§4):
#   20:03:05=21, 20:33:08=31, 21:03:06=41, 21:33:07=58, 21:52:06=72, 21:56:03=74,
#   22:01:59=78, 22:03:04=78
# Offsets below are seconds-since-midnight for each HH:MM:SS, added to an arbitrary fixed base
# epoch so only the real deltas (verified against the logged clock times) matter.
# =====================================================================================
{
    my $BASE = 1_700_000_000;
    my @raw = (
        [72185, 21],   # 20:03:05
        [73988, 31],   # 20:33:08  (+1803s)
        [75786, 41],   # 21:03:06  (+1798s)
        [77587, 58],   # 21:33:07  (+1801s)
        [78726, 72],   # 21:52:06  (+1139s)
        [78963, 74],   # 21:56:03  (+237s)
        [79319, 78],   # 22:01:59  (+356s)
        [79384, 78],   # 22:03:04  (+65s)  <-- the exact incident pair
    );
    my @samples = map { [ $BASE + $_->[0], $_->[1] ] } @raw;

    # Sanity on the fixture itself: the incident-defining gap is 65s, both readings 78%.
    is($samples[7][0] - $samples[6][0], 65, 'C1 FIXTURE-SANITY: the last two samples are 65s apart');
    is($samples[7][1], 78, 'C1 FIXTURE-SANITY: last sample is 78%');
    is($samples[6][1], 78, 'C1 FIXTURE-SANITY: second-to-last sample is 78%');

    # No scheduled gap spans the trip point across the RISING portion of the replay: for every
    # step with positive burn, the projected utilisation at the next scheduled poll (current +
    # burn*cadence) must stay below the trip point -- the schedule must not itself license a jump
    # across 85%.
    for my $i (1 .. $#samples - 1) {
        my $prefix  = [ @samples[0 .. $i] ];
        my $burn    = BpGovern::burn_per_sec($prefix);
        next unless defined $burn && $burn > 0;
        my $cadence = BpGovern::window_cadence($prefix, $TRIP);
        my $current = $samples[$i][1];
        my $projected = $current + $burn * $cadence;
        ok($projected < $TRIP,
            "C1: step $i (util=$current, burn=" . sprintf('%.5f', $burn) . ", cadence=${cadence}s) "
            . "does not project across the 85% trip point (projected=" . sprintf('%.2f', $projected) . ")")
            or diag("burn=$burn cadence=$cadence current=$current projected=$projected");
    }

    # THE assertion: after the two 78% samples 65s apart, the next poll must be scheduled in
    # MINUTES, not 1800s. current=78 >= CADENCE_NEAR_CEIL_UTIL(75), burn==0 -> ceiling-proximity
    # rule must cap the interval at CADENCE_NEAR_CEIL_MAX_S regardless of the (zero) burn.
    my $last_pair   = [ @samples[6, 7] ];
    my $burn_last   = BpGovern::burn_per_sec($last_pair);
    my $cadence_last = BpGovern::window_cadence($last_pair, $TRIP);

    is($burn_last, 0, 'C1: burn between the two 78% samples is exactly zero (flat reads as safe, defect a)');
    diag("CURRENT (pre-fix) window_cadence(78%,78% / 65s apart, trip=85) = $cadence_last  "
       . "[expected post-fix: <= " . CADENCE_NEAR_CEIL_MAX_S . "]");

    ok($cadence_last <= CADENCE_NEAR_CEIL_MAX_S,
        "C1: the incident-defining pair (78%, 78%, 65s apart) schedules the next poll at or under "
        . CADENCE_NEAR_CEIL_MAX_S . "s (ceiling-proximity cap), not the 1800s the real system used")
        or diag("got cadence=$cadence_last");
    ok($cadence_last < 900,
        'C1: the next poll after the incident pair is scheduled in MINUTES, not 1800s (< 15min)')
        or diag("got cadence=$cadence_last");
    isnt($cadence_last, 1800,
        'C1: the next poll after the incident pair is explicitly NOT the old 1800s (30min) value');
}

# =====================================================================================
# C2 — ceiling proximity, burn-independent. Burn EXACTLY ZERO, current above
# CADENCE_NEAR_CEIL_UTIL: the interval must be <= CADENCE_NEAR_CEIL_MAX_S regardless of burn. A
# burn-proportional implementation (e.g. one that only caps when burn is positive) would satisfy a
# naive proximity check by accident on a rising sequence but must still cap HERE, where burn is
# precisely zero. Also asserts the governing thresholds are named constants, not bare literals.
# =====================================================================================
{
    my $t0 = 1_800_000_000;
    my $samples = [ [ $t0, 80 ], [ $t0 + 600, 80 ] ];   # perfectly flat at 80%, burn == 0 exactly

    my $burn = BpGovern::burn_per_sec($samples);
    is($burn, 0, 'C2 FIXTURE-SANITY: burn is exactly zero for the flat-at-80 fixture');
    ok(80 >= CADENCE_NEAR_CEIL_UTIL, 'C2 FIXTURE-SANITY: current (80) is above the near-ceiling threshold (75)');

    my $cadence = BpGovern::window_cadence($samples, $TRIP);
    diag("CURRENT (pre-fix) window_cadence(80%,80% flat, trip=85) = $cadence  "
       . "[expected post-fix: <= " . CADENCE_NEAR_CEIL_MAX_S . "]");
    ok($cadence <= CADENCE_NEAR_CEIL_MAX_S,
        'C2: burn EXACTLY ZERO with current above the near-ceiling threshold still caps the '
        . 'interval at CADENCE_NEAR_CEIL_MAX_S (burn-independent proximity rule)')
        or diag("got cadence=$cadence (expected <= " . CADENCE_NEAR_CEIL_MAX_S . ")");

    # Named constants: each of the five threshold constants from spec §2 must appear as a named
    # definition (use constant, or `my $NAME = VALUE`) in bp-govern.pl -- not merely as bare
    # literals floating in window_cadence's expression body.
    for my $c (
        [ CADENCE_MIN_S           => 60   ],
        [ CADENCE_MAX_S           => 1800 ],
        [ CADENCE_NEAR_CEIL_UTIL  => 75   ],
        [ CADENCE_NEAR_CEIL_MAX_S => 120  ],
        [ BURN_MIN_SPAN_S         => 180  ],
    ) {
        my ($name, $value) = @$c;
        my $n = named_const_count($name, $value);
        ok($n >= 1,
            "C2: $name => $value is defined as a NAMED CONSTANT in bp-govern.pl (found $n occurrence(s))")
            or diag("bp-govern.pl does not yet define $name -- expected pre-implementation");
    }

    # window_cadence's own body should reference the near-ceiling constants BY NAME, not as bare
    # numeric literals (75 / 120) inside the expression.
    my ($body) = ($SRC =~ /sub\s+window_cadence\s*\{(.*?)\n\}/s);
    $body //= '';
    unlike($body, qr/\b75\b/, 'C2: window_cadence body does not hardcode the bare literal 75 (must use CADENCE_NEAR_CEIL_UTIL)');
    unlike($body, qr/\b120\b/, 'C2: window_cadence body does not hardcode the bare literal 120 (must use CADENCE_NEAR_CEIL_MAX_S)');
}

# =====================================================================================
# C3 / C4 — the vacuity-gated pair. C3: unknown burn (fewer than 2 samples, dt<=0, span under the
# minimum) each yield the FAST cadence (CADENCE_MIN_S), explicitly NOT CADENCE_MAX_S. C4: a
# genuinely idle fleet at low utilisation with a LONG FLAT SPAN does reach CADENCE_MAX_S. Both are
# below CADENCE_NEAR_CEIL_UTIL so the ceiling-proximity rule cannot be the thing producing the
# result -- only the unknown-vs-known-flat distinction can.
# =====================================================================================

my %c3_results;

{
    # (a) fewer than two samples.
    my $samples = [ [ 1_800_000_000, 50 ] ];
    my $cadence = BpGovern::window_cadence($samples, $TRIP);
    $c3_results{fewer_than_2} = $cadence;
    diag("CURRENT (pre-fix) window_cadence(1 sample) = $cadence  [expected post-fix: == " . CADENCE_MIN_S . "]");
    is($cadence, CADENCE_MIN_S, 'C3a: fewer than 2 samples -> FAST cadence (CADENCE_MIN_S)');
    isnt($cadence, CADENCE_MAX_S, 'C3a: fewer than 2 samples -> explicitly NOT CADENCE_MAX_S (fail-safe direction)');
}
{
    # (b) dt <= 0 (two samples, non-positive time delta -- clock skew / duplicate poll).
    my $t = 1_800_000_000;
    my $samples = [ [ $t, 50 ], [ $t, 55 ] ];   # dt == 0
    my $burn = BpGovern::burn_per_sec($samples);
    is($burn, undef, 'C3b FIXTURE-SANITY: burn_per_sec is undef when dt<=0');
    my $cadence = BpGovern::window_cadence($samples, $TRIP);
    $c3_results{dt_le_0} = $cadence;
    diag("CURRENT (pre-fix) window_cadence(dt=0) = $cadence  [expected post-fix: == " . CADENCE_MIN_S . "]");
    is($cadence, CADENCE_MIN_S, 'C3b: dt<=0 -> FAST cadence (CADENCE_MIN_S)');
    isnt($cadence, CADENCE_MAX_S, 'C3b: dt<=0 -> explicitly NOT CADENCE_MAX_S (fail-safe direction)');
}
{
    # (c) span under BURN_MIN_SPAN_S (180s) -- a "short flat sample window" (the ledger's own
    # phrase): two samples 90s apart. burn_per_sec must ALSO treat this span as unknown (undef),
    # not compute a numeric (mis)leadingly-precise slope from too little data.
    my $t = 1_800_000_000;
    my $samples = [ [ $t, 50 ], [ $t + 90, 52 ] ];   # dt=90 < BURN_MIN_SPAN_S(180)
    ok(($samples->[1][0] - $samples->[0][0]) < BURN_MIN_SPAN_S,
        'C3c FIXTURE-SANITY: the sample span (90s) is under BURN_MIN_SPAN_S (180s)');

    # CORRECTED BY THE COORDINATOR (2026-08-03), and the correction makes the system SAFER.
    #
    # This originally asserted `is($burn, undef)` -- that burn_per_sec ITSELF treats a short span as
    # unknown. That is fail-UNSAFE, because burn_per_sec is shared: should_pause does
    # `$burn = 0 if !defined $burn`, so an "unknown" burn is read as ZERO burn, i.e. "do not pause".
    # Putting the span rule inside burn_per_sec therefore made the governor MORE likely to miss a
    # pause -- the exact incident this package exists to prevent -- while fixing the cadence path.
    # It was caught by t/06's usage_decision fixture (samples 100s apart) ceasing to trip a pause.
    #
    # "Unknown" means opposite things to the two callers: to the CADENCE it means poll fast (safe);
    # to should_pause it means do not pause (unsafe). So the span rule belongs to window_cadence
    # alone, and burn_per_sec stays a pure slope. should_pause's undef handling is pinned by t/18
    # and is deliberately not touched.
    my $burn = BpGovern::burn_per_sec($samples);
    ok(defined $burn && $burn > 0,
        'C3c: burn_per_sec stays a PURE slope over a short span -- the span rule must not leak into '
      . 'should_pause, which reads undef as zero burn and would then decline to pause');

    my $cadence = BpGovern::window_cadence($samples, $TRIP);
    $c3_results{short_span} = $cadence;
    diag("CURRENT (pre-fix) window_cadence(span=90s) = $cadence  [expected post-fix: == " . CADENCE_MIN_S . "]");
    is($cadence, CADENCE_MIN_S, 'C3c: span under BURN_MIN_SPAN_S -> FAST cadence (CADENCE_MIN_S)');
    isnt($cadence, CADENCE_MAX_S, 'C3c: short span -> explicitly NOT CADENCE_MAX_S (fail-safe direction)');
}

my $c4_result;
{
    # C4 — genuinely idle fleet: low utilisation (well below CADENCE_NEAR_CEIL_UTIL), a LONG flat
    # span (>= BURN_MIN_SPAN_S, in fact much larger), burn == 0. This is the case the ledger's
    # "efficiency property" refers to: it MUST relax all the way to CADENCE_MAX_S, or the fix
    # degenerates to "poll every minute forever".
    my $t = 1_800_000_000;
    my $samples = [ [ $t, 20 ], [ $t + 3600, 20 ] ];   # flat at 20% for a full hour
    ok(($samples->[1][0] - $samples->[0][0]) >= BURN_MIN_SPAN_S,
        'C4 FIXTURE-SANITY: the sample span (3600s) is well above BURN_MIN_SPAN_S');
    ok(20 < CADENCE_NEAR_CEIL_UTIL, 'C4 FIXTURE-SANITY: current (20) is well below the near-ceiling threshold');

    my $burn = BpGovern::burn_per_sec($samples);
    is($burn, 0, 'C4 FIXTURE-SANITY: burn is exactly zero for the long flat span');

    my $cadence = BpGovern::window_cadence($samples, $TRIP);
    $c4_result = $cadence;
    diag("CURRENT (pre-fix) window_cadence(20%,20% / 1h flat span) = $cadence  [expected post-fix: == " . CADENCE_MAX_S . "]");
    is($cadence, CADENCE_MAX_S, 'C4: a genuinely idle fleet with a long flat span DOES reach CADENCE_MAX_S');
    isnt($cadence, CADENCE_MIN_S, 'C4: idle-fleet case is explicitly NOT the fast cadence');
}

# VACUITY CROSS-CHECK: no constant-returning window_cadence can pass both blocks above. Each C3
# fixture asserted == CADENCE_MIN_S and != CADENCE_MAX_S; C4 asserted == CADENCE_MAX_S and !=
# CADENCE_MIN_S. Demonstrate directly that the two groups of outcomes are forced apart.
for my $case (sort keys %c3_results) {
    isnt($c3_results{$case}, $c4_result,
        "VACUITY GATE: C3 case '$case' (fast, unknown burn) and C4 (slow, idle-known-flat) "
        . 'produce DIFFERENT cadences -- no constant-returning window_cadence can satisfy both')
        or diag("c3.$case=$c3_results{$case} c4=$c4_result -- a constant-returning stub would make these equal");
}

# =====================================================================================
# C5 — rate_limit_event with status "rejected" is an immediate pause trigger, independent of the
# poll schedule (spec §3). No prior art exists for this in bp-govern.pl (grepped: absent) or
# anywhere else in plugins/butler -- this PINS the interface the fix must satisfy: a pure function
# taking only the observed coordinator-stream events (no clock, no samples, no cadence) and
# returning true iff ANY event is a rejected rate_limit_event. Its independence from the schedule
# is structural: the function never consults window_cadence/next_cadence/samples at all.
# =====================================================================================
{
    my @rejected_stream = (
        { type => 'rate_limit_event', status => 'ok' },
        { type => 'other_event',      status => 'rejected' },   # wrong type -- must NOT trip
        { type => 'rate_limit_event', status => 'rejected' },   # the real trigger
    );
    my $tripped = eval { BpGovern::immediate_pause_trigger(\@rejected_stream) };
    diag("BpGovern::immediate_pause_trigger error: $@") if $@;
    ok($tripped, 'C5: a rate_limit_event with status "rejected" anywhere in the stream trips an immediate pause')
        or diag('BpGovern::immediate_pause_trigger did not return true -- expected pre-implementation (interface pinned by this oracle)');

    my @clean_stream = (
        { type => 'rate_limit_event', status => 'ok' },
        { type => 'rate_limit_event', status => 'ok' },
    );
    my $clean = eval { BpGovern::immediate_pause_trigger(\@clean_stream) };
    ok(!$clean, 'C5: no rejected rate_limit_event anywhere -> no immediate pause trigger')
        or diag('BpGovern::immediate_pause_trigger returned true with no rejection present');

    ok(!eval { BpGovern::immediate_pause_trigger([]) },
        'C5: an empty stream never trips an immediate pause');
}

# =====================================================================================
# C6 — pause fires strictly before utilisation reaches 100 in the replay. Using the real burn
# trend established by the last two DISTINCT (non-flat) replay samples (74% -> 78%, 356s apart),
# project the next checkpoint at the corrected cadence (the real window_cadence output for the
# incident pair) and confirm should_pause trips there, at a projected utilisation strictly below
# 100 -- i.e. the corrected schedule catches the climb well short of the ceiling the real incident
# overshot.
# =====================================================================================
{
    my $BASE = 1_700_000_000;
    my $prev  = [ $BASE + 78963, 74 ];   # 21:56:03 = 74%
    my $last  = [ $BASE + 79319, 78 ];   # 22:01:59 = 78%
    my $trend_samples = [ $prev, $last ];
    my $burn_trend = BpGovern::burn_per_sec($trend_samples);
    ok($burn_trend > 0, 'C6 FIXTURE-SANITY: the 74%->78% trend has positive burn') or diag("burn_trend=$burn_trend");

    my $incident_pair = [ $last, [ $BASE + 79384, 78 ] ];   # the 78/78, 65s-apart incident pair
    my $cadence = BpGovern::window_cadence($incident_pair, $TRIP);

    my $projected_current = $last->[1] + $burn_trend * $cadence;
    ok($projected_current < 100,
        "C6: the checkpoint scheduled by window_cadence ($cadence" . "s out) projects to "
        . sprintf('%.2f', $projected_current) . "%, strictly below 100")
        or diag("cadence=$cadence burn_trend=$burn_trend projected=$projected_current");

    my $drain = 600;
    my $paused = BpGovern::should_pause($projected_current, $burn_trend, $drain, $TRIP);
    ok($paused, 'C6: should_pause trips at the projected checkpoint (pause fires before 100)')
        or diag("projected_current=$projected_current burn_trend=$burn_trend drain=$drain trip=$TRIP");
}

# =====================================================================================
# C7 — orchestrator-protocol/SKILL.md states the ceiling-proximity floor and the unknown-burn
# fail-safe direction, in the usage-governance bullet.
# =====================================================================================
{
    my $skill_path = "$Bin/../../skills/orchestrator-protocol/SKILL.md";
    ok(-f $skill_path, 'C7 FIXTURE-SANITY: orchestrator-protocol/SKILL.md exists') or diag($skill_path);
    my $skill_src = do {
        local $/;
        open my $fh, '<', $skill_path or die "cannot read $skill_path: $!";
        <$fh>;
    };

    like($skill_src, qr/ceiling.proximity/i,
        'C7: SKILL.md states the ceiling-proximity floor')
        or diag('SKILL.md does not yet mention ceiling-proximity -- expected pre-implementation');

    like($skill_src, qr/unknown burn/i,
        'C7: SKILL.md names "unknown burn" explicitly')
        or diag('SKILL.md does not yet mention "unknown burn" -- expected pre-implementation');

    ok(($skill_src =~ /unknown burn[^.\n]{0,200}\b(fast|min(?:imum)?)\b/i)
        || ($skill_src =~ /\b(fast|min(?:imum)?)\b[^.\n]{0,200}unknown burn/i),
        'C7: SKILL.md states the unknown-burn fail-safe DIRECTION (fast/minimum, never the slow floor)')
        or diag('SKILL.md does not yet pair "unknown burn" with the fast/fail-safe direction -- expected pre-implementation');
}

done_testing();
