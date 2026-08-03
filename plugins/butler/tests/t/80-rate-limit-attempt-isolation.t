#!/usr/bin/env perl
# t/80-rate-limit-attempt-isolation.t — immutable oracle for b29-rate-limit-attempt-isolation.
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b29-rate-limit-attempt-isolation-spec.md
# (C1..C6) and the incident quoted in
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/packages/b29-rate-limit-attempt-isolation.md
# (the b12-ledger-write-integrity 2026-07-29 outage: 0 -> 5 attempts in 56 seconds against a
# rejecting API, the fleet's usage window already exhausted).
#
# WRITTEN BLIND TO THE FIX. Today `BpOrch::effective_attempts($attempts, $turn_continuations)` knows
# nothing about rate-limit rejections (grepped: `rate_limit_event` is read nowhere in
# plugins/butler/scripts/) so every launch this file replays counts fully against the cap. Every
# assertion below is expected to fail on WRONG BEHAVIOUR (a package wrongly blocked, or a discount
# log record that was never written), never on a Perl exception, a missing module, or a wrong
# require path. This file calls ONLY functions that exist on disk today
# (BpOrch::run/effective_attempts/watchdog_verdict/read_registry, BpGovern's already-shipped
# b30 detector is not called directly here — see the note below) so a failure can never be
# "Undefined subroutine".
#
# Style follows t/06 and t/20 (mk_bp / go() loop-driving the REAL BpOrch::run tick, not a
# reimplementation of the watchdog's cap decision).
#
# SYN-23: nothing below cites a bp-orchestrator.pl / bp-govern.pl line number; everything is
# grepped by pattern.
#
# =====================================================================================
# MANDATORY VACUITY GATE (spec's own standing rule): C1 ("five b12-shaped launches must not reach
# watchdog_block") and C2 ("a genuine failure still blocks at the cap") are OPPOSITES, and each is
# trivially satisfiable alone -- a `effective_attempts` that always discounts everything passes C1
# but fails C2 (nothing would EVER block, defeating the give-up cap entirely); the CURRENT,
# unfixed implementation (discounts nothing) passes C2 but fails C1. Both blocks below drive the
# identical harness (same mk_bp/go/tun/cap=5 plumbing, same BpOrch::run tick, same
# BpOrch::effective_attempts + BpOrch::watchdog_verdict call sites inside it) and differ ONLY in
# the shape of the coordinator's own jsonl stream -- so no constant-returning discount policy can
# satisfy both. The explicit cross-check block after C2 demonstrates this directly.
# C3 asserts the POSITIVE (a discount log record actually exists, naming the package and evidence)
# strictly before asserting the package was not blocked, per the spec's own C3 ordering rule.
# =====================================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

my $ORCH = "$Bin/../../scripts/bp-orchestrator.pl";
require $ORCH;   # also requires bp-govern.pl (BpGovern) as a side effect -- see bp-orchestrator.pl:52

diag("subject under test: $ORCH (+ bp-govern.pl, required transitively)");

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = time;
my $DEAD_PID = 2_000_000_000;   # out of range -> kill 0 fails -> not alive (t/06/t/20 convention)

# ── fixture plumbing, copied verbatim from the house style (t/06, t/20) ────────────────
sub spit       { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f; return $p }
sub slurp_raw  { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $c = <$f>; close $f; return $c }

my $bpn = 0;
sub mk_bp {
    my ($pkgs, $registry) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->[0] | d | $_->[1] | sonnet | $_->[2] |\n" for @$pkgs;
    close $b;
    write_ledger($dir, @$_) for @$pkgs;
    if ($registry) { spit("$dir/runs/registry.json", $J->encode({ packages => $registry })); }
    spit("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-SCN-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-SCNREF-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 5*3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
    return $dir;
}
sub write_ledger {
    my ($dir, $name, $deps, $status, $ws, $extra_fm, $body) = @_;
    $ws //= "p/$name/"; $extra_fm //= ''; $body //= '';
    open my $l, '>', "$dir/packages/$name.md" or die;
    print $l "---\npackage: $name\nblueprint: T\nstatus: $status\nwrite_set: $ws\ntest_paths: $ws\n"
           . $extra_fm . "last_updated: 2026-06-24T00:00:00Z\n---\n# $name\n\n## Next action\n\ngo\n" . $body;
    close $l;
}
my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });
sub tun {
    my ($dir, %o) = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>0,
             keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
             tele_retry=>3, usage_fail=>60, busy_path=>"$dir/busy",
             harvest=>'audit', resolve_cap=>1, corr_cap=>1, judge_to=>100000, judge_spawn_cap=>3, %o };
}
sub go {
    my (%o) = @_;
    my $dir = $o{dir};
    my (@L, $err);
    my $rcs = $o{rcs};
    my $i   = 0;
    my $seam = sub {
        my ($a) = @_;
        push @L, { pkg => $a->{pkg}, kind => $a->{kind}, args => [ @{ $a->{args} || [] } ] };
        return $o{launch}->($a) if $o{launch};
        return 0 unless $rcs;
        my $rc = defined $rcs->[$i] ? $rcs->[$i] : $rcs->[-1];
        $i++;
        return $rc;
    };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            (exists $o{tunables}      ? (tunables      => $o{tunables})      : ()),
            (exists $o{tunables_file} ? (tunables_file => $o{tunables_file}) : ()),
            once      => (exists $o{once} ? $o{once} : 1),
            now       => ($o{now}   || sub { $NOW }),
            sleep     => ($o{sleep} || sub { }),
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            spawn_judge => ($o{spawn_judge} || sub { 0 }),   # NEVER let a watchdog_block reach the real
                                                              # bp-judge.sh subprocess (house convention:
                                                              # every test that can trip _escalate_stuck
                                                              # injects this -- t/06, t/10, t/21, t/22, t/61).
            ($o{no_launch} ? () : (launch => $seam)),
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
sub log_of { my ($dir, $type) = @_; return grep { ($_->{type} // '') eq $type } log_events($dir) }
sub reg_of { my ($dir, $pkg)  = @_; my $r = eval { BpOrch::read_registry("$dir/runs") } || {};
             return (ref($r->{$pkg}) eq 'HASH' ? $r->{$pkg} : {}) }
sub spit_lines { my ($dir, $pkg, @objs) = @_; spit("$dir/runs/$pkg.jsonl", join('', map { $J->encode($_) . "\n" } @objs)) }
sub ledger_status { my ($dir, $pkg) = @_; my $t = slurp_raw("$dir/packages/$pkg.md") // '';
                     return ($t =~ /^status:\s*(\S+)/m) ? $1 : '' }

# ── the b12 incident, replayed verbatim (ledger's own quoted stream) ───────────────────
# rate_limit_event (status "rejected") -> a <synthetic> assistant turn -> a result record
# carrying is_error:true, num_turns:1, terminal_reason:"api_error", duration_api_ms:0.
sub b12_stream {
    my ($pkg) = @_;
    return (
        { type => 'rate_limit_event', rate_limit_info => { status => 'rejected', resetsAt => 1785370800,
              rateLimitType => 'five_hour', overageStatus => 'rejected', overageDisabledReason => 'org_level_disabled' } },
        { type => 'assistant', session_id => "sid-$pkg",
          message => { content => [ { type => 'text', text => "<synthetic> You've hit your usage limit until 5pm." } ] } },
        { type => 'result', is_error => JSON::PP::true, num_turns => 1, terminal_reason => 'api_error',
          duration_api_ms => 0, subtype => 'error_other', session_id => "sid-$pkg" },
    );
}
# a genuine failure: the coordinator ran real turns and then died on an ordinary error --
# no rate_limit_event anywhere, num_turns well above 1, non-zero duration_api_ms.
sub genuine_failure_stream {
    my ($pkg) = @_;
    return (
        { type => 'assistant', session_id => "sid-$pkg", message => { content => [ { type => 'text', text => 'turn 1: editing file' } ] } },
        { type => 'assistant', session_id => "sid-$pkg", message => { content => [ { type => 'text', text => 'turn 2: running tests' } ] } },
        { type => 'result', is_error => JSON::PP::true, num_turns => 15, terminal_reason => 'error',
          duration_api_ms => 52_000, subtype => 'error_other', session_id => "sid-$pkg" },
    );
}
# signature A alone: a rate_limit_event IS present, but the terminal result looks superficially
# like a genuine failure (num_turns=15, duration_api_ms=5000) -- proving the marker wins
# "regardless of what else the stream contains" (spec/ledger wording, verbatim).
sub signature_a_only_stream {
    my ($pkg) = @_;
    return (
        { type => 'rate_limit_event', rate_limit_info => { status => 'rejected', resetsAt => 1785370800,
              rateLimitType => 'five_hour', overageStatus => 'rejected', overageDisabledReason => 'org_level_disabled' } },
        { type => 'assistant', session_id => "sid-$pkg", message => { content => [ { type => 'text', text => 'turn 1' } ] } },
        { type => 'result', is_error => JSON::PP::true, num_turns => 15, terminal_reason => 'error',
          duration_api_ms => 5_000, subtype => 'error_other', session_id => "sid-$pkg" },
    );
}
# signature B alone: NO rate_limit_event anywhere, but the terminal result is the
# api_error / num_turns<=1 / duration_api_ms:0 shape b12 actually produced.
sub signature_b_only_stream {
    my ($pkg) = @_;
    return (
        { type => 'assistant', session_id => "sid-$pkg",
          message => { content => [ { type => 'text', text => '<synthetic> session limit reached' } ] } },
        { type => 'result', is_error => JSON::PP::true, num_turns => 1, terminal_reason => 'api_error',
          duration_api_ms => 0, subtype => 'error_other', session_id => "sid-$pkg" },
    );
}

# a shared driver: launches a package repeatedly (bp-launch.sh's own unconditional attempt-bump,
# simulated by the closure exactly as t/06 AC-15 does), writing the given stream as the just-died
# coordinator's jsonl after each launch, for N rounds. Returns the blueprint dir.
sub replay {
    my ($pkg, $stream_sub, $rounds, $cap) = @_;
    my $dir = mk_bp([[$pkg, '-', 'pending', "$pkg/", '']]);
    for my $n (1 .. $rounds) {
        # resolve_cap=>0 forces BpJudge::escalation_verdict straight to 'park' (never
        # 'resolve') the moment the watchdog blocks, so a blocked package is asserted
        # as blocked=blocked -- not diverted into a 'resolving' resolve-judge cycle,
        # which would make the C2/C1 ledger-status assertions test the WRONG thing.
        my ($L, $err) = go(dir => $dir, tunables => tun($dir, cap => $cap, resolve_cap => 0), launch => sub {
            my $att = (reg_of($dir, $pkg)->{attempt} // 0) + 1;
            BpOrch::update_registry_pkg("$dir/runs", $pkg,
                { attempt => $att, pid => $DEAD_PID, status => 'running', session_id => "sid-$pkg" });
            0;
        });
        is($err, '', "replay($pkg) tick $n completes without dying");
        spit_lines($dir, $pkg, $stream_sub->($pkg));
    }
    return $dir;
}

# =====================================================================================
# C1 — the incident, replayed. Five b12-shaped launches must NOT reach watchdog_block.
# One extra tick (6 total go() calls: 1 fresh launch + 5 watchdog assessments) is driven so the
# 5th launch's death is actually ASSESSED against the cap -- matching the real incident's own
# log, where watchdog_block fired on the tick that assessed the 5th attempt, not the 5th launch
# itself. Asserted against BpOrch::run's REAL tick (effective_attempts + watchdog_verdict +
# _log, unmodified), not a reimplementation.
# =====================================================================================
my $dir_c1 = replay('ratesim', \&b12_stream, 6, 5);
{
    my @blk = log_of($dir_c1, 'watchdog_block');
    is(scalar @blk, 0, 'C1: five b12-incident relaunches never reach watchdog_block')
        or diag('watchdog_block fired: ' . join(', ', map { 'attempts=' . ($_->{attempts} // '?') } @blk));
    isnt(ledger_status($dir_c1, 'ratesim'), 'blocked', 'C1: package ledger status is not blocked');
}

# =====================================================================================
# C2 — a genuine failure still counts, and still blocks at the cap. Same harness, same cap,
# same tick machinery -- only the jsonl shape differs (real turns, ordinary error, no
# rate-limit marker anywhere).
# =====================================================================================
my $dir_c2 = replay('genuine', \&genuine_failure_stream, 6, 5);
{
    my @blk = log_of($dir_c2, 'watchdog_block');
    ok(scalar(@blk) >= 1, 'C2: a genuinely-failing package (real turns, ordinary error) DOES reach watchdog_block')
        or diag('no watchdog_block ever fired for the genuine-failure replay -- the cap has been defeated entirely');
    is(ledger_status($dir_c2, 'genuine'), 'blocked', 'C2: package ledger status IS blocked');
}

# =====================================================================================
# VACUITY CROSS-CHECK. C1 and C2 drive the byte-identical harness (mk_bp/go/tun/cap=5/replay),
# differing ONLY in the coordinator stream's content, and must produce OPPOSITE watchdog_block
# outcomes. A discount policy that always discounts (e.g. a constant `effective_attempts` stub
# returning 0) would pass C1 but leave C2's package count at 0 blocks -- fails here. A discount
# policy that never discounts (today's actual code) passes C2 but leaves C1 blocked -- fails here
# too. Demonstrated directly:
# =====================================================================================
{
    my $c1_blocks = scalar log_of($dir_c1, 'watchdog_block');
    my $c2_blocks = scalar log_of($dir_c2, 'watchdog_block');
    isnt($c1_blocks == 0 ? 'none' : 'blocked', $c2_blocks == 0 ? 'none' : 'blocked',
        'VACUITY GATE: identical harness, identical cap, opposite outcomes on b12-shaped vs genuine-failure streams '
      . '-- no constant-returning discount (always-discount or never-discount) can satisfy both C1 and C2')
        or diag("c1 blocks=$c1_blocks c2 blocks=$c2_blocks -- these must differ for the discount to be real");
}

# =====================================================================================
# C3 — the discount is VISIBLE. Each discounted launch must emit a distinct log record
# (`attempt_discounted_rate_limit`) naming the package and the evidence that classified it.
# Positive assertion FIRST (a discount record actually exists), per the spec's own ordering rule,
# strictly before re-confirming (already shown above) that the package was not blocked.
# =====================================================================================
{
    my @disc = log_of($dir_c1, 'attempt_discounted_rate_limit');
    ok(scalar(@disc) >= 1, 'C3 (positive): at least one attempt_discounted_rate_limit event was logged for the b12 replay')
        or diag('no attempt_discounted_rate_limit event was ever logged -- the discount is not implemented, or is silent');
    if (@disc) {
        is($disc[0]{package}, 'ratesim', 'C3: the discount record names the package');
        ok(length($disc[0]{evidence} // ''), 'C3: the discount record names the evidence that classified it')
            or diag('attempt_discounted_rate_limit carried no evidence field -- a silent discount would hide a genuine thrash');
    }
    # Re-assert the C1 outcome here too, so C3's positive and the "not blocked" negative are pinned
    # in the same block as the spec's ordering rule requires.
    isnt(ledger_status($dir_c1, 'ratesim'), 'blocked', 'C3 (then negative): ... and the package was not blocked');
}

# =====================================================================================
# C4 — either signature independently suffices. Two single-cycle fixtures (one fresh launch,
# one watchdog assessment of its death) isolate EACH signature so neither alone is required to
# lean on the other.
# =====================================================================================
{
    my $dirA = replay('sigaonly', \&signature_a_only_stream, 2, 5);
    my @discA = log_of($dirA, 'attempt_discounted_rate_limit');
    ok(scalar(@discA) >= 1, 'C4: signature A alone (rate_limit_event present, terminal result looks like a real failure) triggers the discount')
        or diag('rate_limit_event alone did not trigger a discount -- signature A is not independently sufficient');
    like($discA[0]{evidence} // '', qr/rate.?limit/i, 'C4: signature A evidence names the rate_limit_event marker')
        if @discA;

    my $dirB = replay('sigbonly', \&signature_b_only_stream, 2, 5);
    my @discB = log_of($dirB, 'attempt_discounted_rate_limit');
    ok(scalar(@discB) >= 1, 'C4: signature B alone (api_error / num_turns<=1 / duration_api_ms:0, no rate_limit_event) triggers the discount')
        or diag('the api_error/zero-duration shape alone did not trigger a discount -- signature B is not independently sufficient');
    like($discB[0]{evidence} // '', qr/api_error|duration/i, 'C4: signature B evidence names the api_error/zero-duration marker')
        if @discB;
}

# =====================================================================================
# C5 — effective_attempts remains the SINGLE place the cap is discounted. Structural guard: read
# the actual source and assert (a) exactly one sub definition, and (b) every call site that feeds
# watchdog_verdict's `attempts` field routes through it -- i.e. no second, parallel cap-evaluation
# path was added elsewhere in the file.
# =====================================================================================
{
    my $src = do { open my $fh, '<', $ORCH or die "cannot read $ORCH: $!"; local $/; <$fh> };
    my @defs = ($src =~ /^\s*sub\s+effective_attempts\b/mg);
    is(scalar @defs, 1, 'C5: exactly one sub effective_attempts definition exists in bp-orchestrator.pl');

    my @feeds = ($src =~ /attempts\s*=>\s*effective_attempts\s*\(/g);
    my @watchdog_calls = ($src =~ /watchdog_verdict\s*\(\s*\{/g);
    ok(scalar(@feeds) >= 2, 'C5: at least the two known watchdog_verdict call sites source attempts via effective_attempts(...)');
    is(scalar(@feeds), scalar(@watchdog_calls),
        'C5: EVERY watchdog_verdict({...}) call site sources its attempts field via effective_attempts(...) -- no bypass')
        or diag("watchdog_verdict call sites=" . scalar(@watchdog_calls) . " but only " . scalar(@feeds) . " route through effective_attempts()");
}

# =====================================================================================
# C6 — orchestrator-protocol/SKILL.md states the rule, citing the same reasoning as the 529 rule
# (an overloaded/rejecting endpoint is not a misdiagnosis, so it must not consume the convergence
# cap).
# =====================================================================================
{
    my $skill = "$Bin/../../skills/orchestrator-protocol/SKILL.md";
    ok(-f $skill, "C6: $skill exists") or diag('cannot assert C6 text against a missing file');
    my $txt = slurp_raw($skill) // '';
    like($txt, qr/rate.?limit/i, 'C6: SKILL.md mentions rate-limit rejections at all');
    like($txt, qr/(?:convergence|attempt)\s+cap/i, 'C6: SKILL.md mentions the convergence/attempt cap');
    ok(($txt =~ /rate.?limit/i && $txt =~ /(?:does not|doesn't|never|not charged|not count)/i
        && $txt =~ /(?:cap|attempt)/i),
       'C6: SKILL.md states rate-limit rejections do NOT count against the cap')
        or diag('SKILL.md does not yet state the rate-limit / attempt-cap exemption');
    like($txt, qr/529|misdiagnos/i,
        'C6: SKILL.md cites the same reasoning as the established 529 doctrine (misdiagnosis / overloaded endpoint)')
        or diag('SKILL.md does not cite the 529 precedent/reasoning this rule generalises');
}

done_testing();
