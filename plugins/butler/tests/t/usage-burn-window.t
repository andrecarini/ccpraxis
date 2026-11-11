#!/usr/bin/env perl
# platform: any
# The fleet usage governor estimates burn over a WINDOW of samples, not from the last two
# points, and a pause tripped only by the burn PROJECTION re-evaluates within minutes
# instead of sleeping until the window resets.
#
# Incident (2026-11-11, acxpraxis-step-2): the 5h window sat flat at 27% for 30+ minutes,
# polled every ~64s. One poll then read 33% (13:29:45 -> 13:30:49), almost certainly the
# operator's other interactive session (usage is account-wide). The two-point estimator read
# that as a sustained 6%/64s, projected 33 + (6/64)*600 = 89 >= 85, paused, and slept until the
# 17:01 local reset: ~3.5h idle at 33% utilisation.
#
# Covered here:
#   (a) the replayed real sequence does NOT pause (pure functions, usage_decision, and run())
#   (b) a sustained +1%/min burn from 60 DOES pause, before 85
#   (c) short sample history behaves conservatively (as documented in bp-govern.pl)
#   (d) a projection pause re-evaluates and resumes when the burn subsides; a ceiling pause
#       still waits for the reset
#   (e) the pause log carries the trigger kind
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-orchestrator.pl";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = time;
my $CEIL5 = 85;
my $DRAIN = 600;

# Resolved at call time so a run against the PRE-fix code (non-vacuity check) reports the
# missing estimator as failures and still reaches the loop-level assertions.
sub pbps  { defined &BpGovern::pause_burn_per_sec ? BpGovern::pause_burn_per_sec(@_) : undef }
sub ptrig { defined &BpGovern::pause_trigger      ? BpGovern::pause_trigger(@_)      : undef }
ok(defined &BpGovern::pause_burn_per_sec, "BpGovern::pause_burn_per_sec exists (windowed estimator)");
ok(defined &BpGovern::pause_trigger,      "BpGovern::pause_trigger exists (ceiling vs projection)");

sub slurp { local $/; open my $f, '<', shift or return ''; <$f> }
sub iso_at { my @t = gmtime($_[0]); sprintf "%04d-%02d-%02dT%02d:%02d:%02d+00:00", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]; }
sub log_events {
    my ($log, $type) = @_;
    my @ev;
    for my $line (split /\n/, $log) {
        my $r = eval { $J->decode($line) } or next;
        push @ev, $r if ($r->{type} // '') eq $type;
    }
    return @ev;
}

# The real poll sequence, read from the incident's orchestrator.log: 12:58:28 .. 13:29:45 all
# at 27%, then 13:30:49 at 33%. Offsets are seconds from 12:58:28Z; the spacing is the real one.
my @INCIDENT_OFFSETS = (0, 64, 130, 195, 260, 324, 377, 442, 506, 570, 634, 698, 762, 826, 890,
                        955, 1019, 1083, 1147, 1211, 1275, 1339, 1402, 1466, 1531, 1596, 1660,
                        1724, 1789, 1853, 1917, 1981);
my $T0 = 1_794_000_000;
my @INCIDENT = map { [ $T0 + $_, 27 ] } @INCIDENT_OFFSETS;
push @INCIDENT, [ $T0 + 1981 + 64, 33 ];

# ============================================================================
# (a) the replayed sequence does NOT pause
# ============================================================================
{
    my $last2 = [ @INCIDENT[-2, -1] ];
    is(BpGovern::should_pause(33, BpGovern::burn_per_sec($last2), $DRAIN, $CEIL5), 1,
        '(a) FIXTURE-SANITY: the two-point slope of the last pair projects past 85 (this is the incident)');

    my $usage = { five_hour => { utilization => 33, resets_at => iso_at($NOW + 3.5 * 3600) },
                  seven_day => { utilization => 18, resets_at => iso_at($NOW + 3 * 86400) } };
    my @s7 = map { [ $_->[0], 18 ] } @INCIDENT;
    my $d = BpOrch::usage_decision($usage, [ @INCIDENT ], \@s7, { ceil5 => $CEIL5, ceil7 => 90, drain => $DRAIN });
    is($d->{action}, 'ok', '(a) usage_decision: one 6-point jump after 30 flat minutes does NOT pause');

    # The samples the orchestrator actually keeps must still carry the window: a 5-sample
    # cap (the pre-fix retention) would leave only ~4 minutes of history.
    if (defined &BpGovern::trim_samples) {
        my @kept = BpGovern::trim_samples([ @INCIDENT ]);
        cmp_ok($kept[-1][0] - $kept[0][0], '>=', BpGovern::BURN_WINDOW_S(),
            '(a) trim_samples keeps at least one burn window of history');
        my $d2 = BpOrch::usage_decision($usage, \@kept, \@s7, { ceil5 => $CEIL5, ceil7 => 90, drain => $DRAIN });
        is($d2->{action}, 'ok', '(a) usage_decision on the RETAINED samples does not pause either');
    } else {
        fail('(a) BpGovern::trim_samples exists (sample retention covers the burn window)');
    }
}

# ============================================================================
# (b) a sustained +1%/min burn from 60 pauses before 85
# ============================================================================
{
    my @s = map { [ $T0 + 60 * $_, 60 ] } 0 .. 20;          # 20 flat minutes at 60
    my $paused_at;
    for my $k (1 .. 30) {                                    # then +1% per minute
        push @s, [ $s[-1][0] + 60, 60 + $k ];
        my $u = 60 + $k;
        my $usage = { five_hour => { utilization => $u, resets_at => iso_at($NOW + 3 * 3600) },
                      seven_day => { utilization => 10, resets_at => iso_at($NOW + 3 * 86400) } };
        my @s7 = map { [ $_->[0], 10 ] } @s;
        my $d = BpOrch::usage_decision($usage, [ @s ], \@s7, { ceil5 => $CEIL5, ceil7 => 90, drain => $DRAIN });
        if ($d->{action} eq 'pause-usage') { $paused_at = $u; last; }
    }
    ok(defined $paused_at, '(b) a sustained +1%/min burn DOES pause');
    cmp_ok($paused_at // 999, '<', $CEIL5, '(b) ... while utilisation is still below the 85 ceiling')
        and diag("(b) paused at $paused_at%");
    cmp_ok($paused_at // 999, '<=', 76, '(b) ... at the Decision #9 trip point (85 - 1%/min * 10min = 75), not later');

    # a FAST sustained onset is caught within two polls, not diluted by the window.
    my @f = map { [ $T0 + 60 * $_, 60 ] } 0 .. 20;
    push @f, [ $f[-1][0] + 60, 63 ], [ $f[-1][0] + 120, 66 ];
    my $b = pbps(\@f);
    is(BpGovern::should_pause(66, $b, $DRAIN, $CEIL5), 1,
        '(b) a 3%/min onset trips after two consecutive fast intervals (66 + 30 >= 85)');
}

# ============================================================================
# (c) short sample history right after start
# ============================================================================
{
    is(pbps([[0, 50]]), undef, '(c) one sample: no rate is computable');
    is(BpGovern::should_pause(85, pbps([[0, 85]]), $DRAIN, $CEIL5), 1,
        '(c) one sample at the ceiling still trips on current alone');
    is(ptrig(85, undef, $DRAIN, $CEIL5), 'ceiling', '(c) current >= ceiling is a CEILING trigger');

    # Two samples: the slope of the only interval is used UNDILUTED (no short-span discount),
    # which is exactly the pre-fix estimator -- unknown never collapses to zero burn.
    my $b2 = pbps([[0, 60], [64, 66]]);
    ok(defined $b2 && abs($b2 - 6/64) < 1e-9, '(c) two samples: the single interval slope, undiluted');
    is(BpGovern::should_pause(66, $b2, $DRAIN, $CEIL5), 1, '(c) a fast first interval after start still pauses');
    is(ptrig(66, $b2, $DRAIN, $CEIL5), 'projection', '(c) ... as a PROJECTION trigger (cheap to undo)');

    # A short history with a 65s span (the b30 incident shape) is not "unknown = zero".
    my $b3 = pbps([[0, 78], [65, 80]]);
    ok(defined $b3 && $b3 > 0, '(c) a 65s span still yields a usable (positive) rate, not undef');

    # Span shorter than the window, more samples: rate measured over what we have (from the
    # oldest), so a single step is diluted only by the history that really exists.
    my $b4 = pbps([[0, 27], [64, 27], [128, 27], [192, 33]]);
    ok(defined $b4 && abs($b4 - 6/192) < 1e-9, '(c) span < window: slope from the OLDEST sample');
    is(BpGovern::should_pause(33, $b4, $DRAIN, $CEIL5), 0, '(c) ... which does not pause on one step at 33%');
    is(pbps([[5, 50], [5, 60]]), undef, '(c) zero dt: undef');
}

# ============================================================================
# Loop harness: drive the REAL BpOrch::run with a fake clock and a scripted usage feed.
# ============================================================================
my $bpn = 0;
sub mk_bp {
    my $dir = "$ROOT/bp" . (++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n| A | d | — | sonnet | pending |\n";
    close $b;
    open my $l, '>', "$dir/packages/A.md" or die;
    print $l "---\npackage: A\nblueprint: T$bpn\nstatus: pending\nwrite_set: p/a/\ntest_paths: p/a/\nlast_updated: 2026-06-24T00:00:00Z\n---\n# A\n\n## Next action\n\ngo\n";
    close $l;
    open my $c, '>:raw', "$dir/creds.json" or die;
    print $c $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 100 * 3600) * 1000, scopes => ['user:inference'], subscriptionType => 'max', rateLimitTier => 'x' } });
    close $c;
    return $dir;
}
sub _grow { my ($runs, $clock) = @_; my $f = "$runs/A.jsonl";
    my @t = gmtime($clock);
    my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000Z', $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
    open my $w, '>>', $f or return;
    print $w $J->encode({ type => 'assistant', timestamp => $iso,
                          message => { usage => { cache_read_input_tokens => 4096, cache_creation_input_tokens => 0 } } }), "\n";
    close $w; utime $clock, $clock, $f; }

# run_feed(\@utils, %o): one usage reading per poll (last one repeats). Package A is a
# coordinator that stays alive and keeps writing. Stops after max_ticks.
#   o: resets5 (epoch), max_ticks, tun (overrides)
sub run_feed {
    my ($utils, %o) = @_;
    my $dir  = mk_bp();
    my $runs = "$dir/runs";
    my $tun = { ceil5 => $CEIL5, ceil7 => 90, drain => $DRAIN, max_par => 2, cap => 5, flat => 100000, watch_tick => 60,
        keeper_int => 600, keeper_bo => 120, thresh_min => 60, jit_lo => 0, jit_hi => 0, tele_retry => 3, usage_fail => 60,
        busy_path => "$ROOT/busy.$bpn", harvest => 'audit', resolve_cap => 1, corr_cap => 1, judge_to => 100000,
        judge_spawn_cap => 3, %{ $o{tun} || {} } };
    my $clock = $NOW; my $tick = 0; my $max = $o{max_ticks} // 60;
    my %alive; my $pidn = 910000; my $polls = 0; my @poll_clock; my @snaps;   # [fake clock, .paused decoded or undef] per tick
    my $resets5 = $o{resets5} // ($NOW + 4 * 3600);
    my $err;
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json", tunables => $tun,
            now => sub { $clock },
            sleep => sub {
                my $pf = "$runs/.paused";
                push @snaps, [ $clock, (-e $pf ? eval { $J->decode(slurp($pf)) } : undef) ];
                $clock += ($_[0] // 0); $tick++;
                die "SIM: stop\n" if $tick > $max;
                _grow($runs, $clock) if %alive; },
            http_get => sub {
                my $u = $utils->[ $polls < @$utils ? $polls : $#$utils ]; $polls++; push @poll_clock, $clock;
                { status => 200, content => $J->encode({
                    five_hour => { utilization => $u,  resets_at => iso_at($resets5) },
                    seven_day => { utilization => 10, resets_at => iso_at($NOW + 3 * 86400) } }) } },
            http_post => sub { { status => 200, content => '{}' } },
            launch => sub {
                my $pid = ++$pidn; $alive{$pid} = 1;
                BpOrch::update_registry_pkg($runs, 'A', { pid => $pid, status => 'running', attempt => 1, session_id => 'sid-A' });
                _grow($runs, $clock); return 0; },
            pid_alive => sub { (defined $_[0] && $alive{$_[0]}) ? 1 : 0 },
            spawn_judge => sub { 0 },
        });
        1;
    } or $err = $@;
    $err = undef if defined $err && $err eq "SIM: stop\n";
    return { err => $err, log => slurp("$runs/orchestrator.log"), polls => $polls, runs => $runs, start => $NOW, snaps => \@snaps };
}

# (a) through the loop: 30 flat polls at 27, then the incident's observed tail.
{
    my @feed = ((27) x 31, 33, 33, 34, 34, 35, 35, 36, 36, 36);
    my $r = run_feed(\@feed, max_ticks => 45);
    is($r->{err}, undef, '(a) loop: ran without error');
    cmp_ok($r->{polls}, '>=', 40, '(a) loop: the replay was actually polled through the 33% sample and beyond');
    my @p = log_events($r->{log}, 'pause');
    is(scalar(@p), 0, '(a) loop: the replayed incident sequence produces NO pause')
        or diag(join "\n", map { $J->encode($_) } @p);
}

# (d)+(e) projection pause: a fast burn trips the projection, then subsides -> resume in minutes.
{
    my $resets5 = $NOW + 4 * 3600;
    my @feed = ((60) x 6, 63, 66, 69, (69) x 80);
    my $r = run_feed(\@feed, resets5 => $resets5, max_ticks => 40);
    is($r->{err}, undef, '(d) projection loop: ran without error');
    my @p = log_events($r->{log}, 'pause');
    ok(@p >= 1, '(d) projection loop: the fast burn paused the fleet');
    is($p[0]{trigger}, 'projection', '(e) the pause log names its trigger: projection');
    cmp_ok($p[0]{util}{five}, '<', $CEIL5, '(d) ... with current utilisation still below the ceiling');
    # Log ts is WALL time (BpLog stamps its own clock), so timing is read from the .paused
    # snapshots the harness takes on the FAKE clock, one per tick.
    my ($first) = grep { $_->[1] } @{ $r->{snaps} };
    my $pts = $first ? $first->[1]{created_at} : 0;
    my $recheck = $first ? $first->[1]{relaunch_at} - $first->[1]{created_at} : 9e99;
    cmp_ok($recheck, '<=', 600, '(d) a projection pause re-evaluates within minutes, not at the reset');
    cmp_ok($p[0]{relaunch_at}, '<', $resets5, '(d) ... its relaunch_at is well before resets_at');
    my @res = log_events($r->{log}, 'auto_resume');
    ok(@res >= 1, '(d) the fleet auto-resumed once the burn subsided');
    # Read @res BEFORE indexing it: $res[0]{...} autovivifies an element and would make an
    # empty list look non-empty to the timing checks below.
    my ($cleared) = grep { !$_->[1] && $first && $_->[0] > $first->[0] } @{ $r->{snaps} };
    my $res_at = $cleared ? $cleared->[0] : 9e99;
    is(@res ? $res[0]{trigger} : undef, 'projection', '(e) the resume log names the trigger it ended');
    cmp_ok($res_at, '<', $resets5, '(d) ... long before the window reset');
    cmp_ok($res_at - $pts, '<=', 900, '(d) ... within 15 minutes of the pause');
}

# (d)+(e) ceiling pause: current >= ceiling waits for the reset.
{
    my $resets5 = $NOW + 2 * 3600;
    my @feed = ((60) x 3, (86) x 200);
    my $r = run_feed(\@feed, resets5 => $resets5, max_ticks => 70);
    is($r->{err}, undef, '(d) ceiling loop: ran without error');
    my @p = log_events($r->{log}, 'pause');
    ok(@p >= 1, '(d) ceiling loop: utilisation at 86 paused the fleet');
    is($p[0]{trigger}, 'ceiling', '(e) the pause log names its trigger: ceiling');
    is($p[0]{relaunch_at}, $resets5, '(d) a ceiling pause still sleeps until resets_at (+0 jitter here)');
    my @res = log_events($r->{log}, 'auto_resume');
    is(scalar(@res), 0, '(d) a ceiling pause does NOT resume early (70 minutes observed)');
}

# Pure pieces of (d): payload and resume timing.
{
    my $pp = BpOrch::paused_payload(10_000, 1_000, 420, 'usage', 'projection', 300);
    is($pp->{trigger}, 'projection', '(d) paused_payload records the trigger');
    is($pp->{relaunch_at}, 1_300, '(d) projection: relaunch_at = now + recheck (no jitter, no reset)');
    is($pp->{resets_at}, 10_000, '(d) projection: resets_at is still recorded');
    is(BpOrch::resume_ready($pp, 1_299), 0, '(d) projection: not ready before the recheck');
    is(BpOrch::resume_ready($pp, 1_300), 1, '(d) projection: ready at the recheck');
    my $pc = BpOrch::paused_payload(10_000, 1_000, 420, 'usage', 'ceiling', 300);
    is($pc->{relaunch_at}, 10_420, '(d) ceiling: relaunch_at = resets_at + jitter, unchanged');
    my $legacy = BpOrch::paused_payload(10_000, 1_000, 420, 'usage');
    is($legacy->{relaunch_at}, 10_420, '(d) no trigger given: today\'s reset-based relaunch');
}

done_testing();
