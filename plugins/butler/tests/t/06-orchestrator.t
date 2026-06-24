#!/usr/bin/env perl
# A3 orchestrator process-management (bp-orchestrator.pl): every DETERMINISTIC
# decision the loop makes, plus the disk/marker/queue helpers and the assembled
# --once tick — all with an injected clock / registry / transport / launch seam,
# no live network and no real `claude` (Decision #25).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use Time::Local qw(timegm);

require "$Bin/../../scripts/bp-orchestrator.pl";

plan tests => 105;

my $J = JSON::PP->new;
sub near { my ($a,$b,$msg,$eps)=@_; $eps//=1e-6; ok(abs($a-$b) < $eps, $msg) or diag("got $a want $b"); }

# ---- progress_verdict (#14: jsonl growth = free liveness) -----------------
is(BpOrch::progress_verdict(100, 1000, undef, 1000, 600), 'growing', 'progress: first observation -> growing');
is(BpOrch::progress_verdict(undef, undef, 50, 1000, 600), 'growing', 'progress: no jsonl yet -> growing (give it time)');
is(BpOrch::progress_verdict(120, 1000, 100, 1000, 600), 'growing', 'progress: grew since last look -> growing');
is(BpOrch::progress_verdict(100, 100, 100, 1000, 600), 'flat',    'progress: no growth + quiet 900s -> flat');
is(BpOrch::progress_verdict(100, 900, 100, 1000, 600), 'growing', 'progress: no growth but quiet only 100s -> growing');

# ---- deps_met -------------------------------------------------------------
is(BpOrch::deps_met([], {}), 1, 'deps: empty deps always met');
is(BpOrch::deps_met(['a','b'], {a=>'done', b=>'done'}), 1, 'deps: all done -> met');
is(BpOrch::deps_met(['a','b'], {a=>'done', b=>'running'}), 0, 'deps: one not done -> unmet');
is(BpOrch::deps_met(['a'], {}), 0, 'deps: missing status -> unmet');

# ---- write_sets_overlap (conservative path-prefix) ------------------------
ok( BpOrch::write_sets_overlap('plugins/butler/scripts/', 'plugins/butler/scripts/bp-x.pl'), 'ws: dir prefix of file -> overlap');
ok( BpOrch::write_sets_overlap('a/b:c/d', 'x/y:c/d/e'),  'ws: shared subtree across lists -> overlap');
ok(!BpOrch::write_sets_overlap('plugins/a/', 'plugins/b/'), 'ws: sibling dirs -> disjoint');
ok(!BpOrch::write_sets_overlap('plugins/butler/', 'plugins/butler-extra/'), 'ws: prefix-but-not-ancestor (butler vs butler-extra) -> disjoint');
ok( BpOrch::write_sets_overlap('plugins/butler/scripts/x.pl', 'plugins/butler/scripts/x.pl'), 'ws: identical file -> overlap');
ok( BpOrch::write_sets_overlap('plugins/butler/scripts/*.pl', 'plugins/butler/scripts/bp.pl'), 'ws: glob reduces to dir prefix -> overlap');

# ---- ready_packages / pick_launch_batch / cap_slots -----------------------
my $meta = {
    A => { deps => [],        write_set => 'p/a/' },
    B => { deps => ['A'],     write_set => 'p/b/' },
    C => { deps => [],        write_set => 'p/c/' },
    D => { deps => [],        write_set => 'p/a/sub/' },   # overlaps A
};
{
    my @r = BpOrch::ready_packages($meta, { A=>'pending', B=>'pending', C=>'pending', D=>'pending' }, []);
    is_deeply([sort @r], ['A','C','D'], 'ready: pending + deps-met, B excluded (dep A not done)');
}
{
    my @r = BpOrch::ready_packages($meta, { A=>'done', B=>'pending', C=>'done', D=>'pending' }, []);
    is_deeply([sort @r], ['B','D'], 'ready: B now ready (A done); done packages excluded');
}
{
    my @r = BpOrch::ready_packages($meta, { A=>'running', B=>'pending', C=>'pending', D=>'pending' }, ['A']);
    is_deeply([sort @r], ['C'], 'ready: D excluded (write-set clashes with running A)');
}
{
    my @b = BpOrch::pick_launch_batch(['A','D','C'], $meta, [], 3);
    is_deeply([@b], ['A','C'], 'batch: D dropped (overlaps A picked earlier in the batch)');
    my @b2 = BpOrch::pick_launch_batch(['A','C'], $meta, [], 1);
    is_deeply([@b2], ['A'], 'batch: honors slot cap of 1');
}
is(BpOrch::cap_slots(0, 2), 2, 'slots: 0 running of 2 -> 2 free');
is(BpOrch::cap_slots(2, 2), 0, 'slots: full -> 0 free');
is(BpOrch::cap_slots(5, 2), 0, 'slots: over cap -> floored at 0');

# ---- watchdog_verdict -----------------------------------------------------
is(BpOrch::watchdog_verdict({alive=>1, progress=>'growing', attempts=>1, cap=>5}), 'none',          'watchdog: alive+growing -> none');
is(BpOrch::watchdog_verdict({alive=>1, progress=>'flat',    attempts=>1, cap=>5}), 'cold-relaunch', 'watchdog: alive+flat under cap -> cold-relaunch');
is(BpOrch::watchdog_verdict({alive=>1, progress=>'flat',    attempts=>5, cap=>5}), 'block',         'watchdog: alive+flat at cap -> block');
is(BpOrch::watchdog_verdict({alive=>0,                      attempts=>2, cap=>5}), 'relaunch',      'watchdog: dead under cap -> relaunch');
is(BpOrch::watchdog_verdict({alive=>0,                      attempts=>5, cap=>5}), 'block',         'watchdog: dead at cap -> block');

# ---- resume_mode (warm/cold economics) ------------------------------------
is(BpOrch::resume_mode(30, 'sid-123', 60), 'warm', 'resume: fresh + sid -> warm');
is(BpOrch::resume_mode(90, 'sid-123', 60), 'cold', 'resume: stale gap -> cold');
is(BpOrch::resume_mode(10, '',        60), 'cold', 'resume: no session id -> cold');
is(BpOrch::resume_mode(undef, 'sid',  60), 'cold', 'resume: unknown age -> cold');

# ---- usage_decision (#8/#9 wiring) ----------------------------------------
{
    my $usage = {
        five_hour => { utilization => 10, resets_at => '2026-06-22T05:59:59+00:00' },
        seven_day => { utilization => 5,  resets_at => '2026-06-22T17:59:59+00:00' },
    };
    my $d = BpOrch::usage_decision($usage, [[0,9],[100,10]], [[0,4],[100,5]], {ceil5=>85,ceil7=>90,drain=>600});
    is($d->{action}, 'ok', 'usage: low utilization -> ok');
    ok($d->{cadence} >= 60 && $d->{cadence} <= 1800, 'usage: cadence within clamp');
}
{
    my $usage = {
        five_hour => { utilization => 81, resets_at => '2026-06-22T05:59:59+00:00' },
        seven_day => { utilization => 5,  resets_at => '2026-06-22T17:59:59+00:00' },
    };
    # burn 0.02%/s over 600s drain => 81 + 12 = 93 >= 85 -> pause
    my $d = BpOrch::usage_decision($usage, [[0,79],[100,81]], [[0,4],[100,5]], {ceil5=>85,ceil7=>90,drain=>600});
    is($d->{action}, 'pause-usage', 'usage: projected post-drain peak crosses 5h ceiling -> pause');
    is($d->{window}, 'five_hour', 'usage: pause attributed to the five_hour window');
    is($d->{resets_at}, timegm(59,59,5,22,5,2026), 'usage: resets_at converted ISO->epoch');
}
{
    my $d = BpOrch::usage_decision({ five_hour => { utilization => 'x' } }, [], [], {ceil5=>85,ceil7=>90,drain=>600});
    is($d->{action}, 'pause-contract', 'usage: drifted shape -> pause-contract');
    ok(@{$d->{problems}} > 0, 'usage: drift names problems');
}

# ---- choose_jitter / paused_payload / resume_ready (#12) ------------------
is(BpOrch::choose_jitter(300, 900, 0),    300, 'jitter: rand 0 -> low bound');
is(BpOrch::choose_jitter(300, 900, 0.5),  600, 'jitter: rand 0.5 -> midpoint');
ok(BpOrch::choose_jitter(300, 900, 0.999) < 900, 'jitter: stays below high bound');
{
    my $pp = BpOrch::paused_payload(1000, 500, 420, 'usage');
    is($pp->{relaunch_at}, 1420, 'paused: relaunch_at = resets_at + jitter');
    is($pp->{reason}, 'usage', 'paused: reason recorded');
    is(BpOrch::resume_ready($pp, 1419), 0, 'resume: not yet (before relaunch_at)');
    is(BpOrch::resume_ready($pp, 1420), 1, 'resume: ready at relaunch_at');
    is(BpOrch::resume_ready({manual=>1, relaunch_at=>0}, 9e9), 0, 'resume: manual pause never auto-resumes');
    is(BpOrch::resume_ready({reason=>'telemetry'}, 9e9), 0, 'resume: no relaunch_at (telemetry) -> not time-based');
}

# ---- should_touch_busy / run_complete / has_progressable_work (#16) -------
ok( BpOrch::should_touch_busy({any_running=>1}), 'busy: running -> touch');
ok( BpOrch::should_touch_busy({outstanding=>1}), 'busy: outstanding work -> touch');
ok( BpOrch::should_touch_busy({resume_pending=>1}), 'busy: auto-resume pending -> touch');
ok(!BpOrch::should_touch_busy({any_running=>1, shutdown=>1}), 'busy: shutting down -> never touch');
ok(!BpOrch::should_touch_busy({}), 'busy: idle / only parked-for-human -> no touch');
ok( BpOrch::run_complete({}), 'complete: nothing running/outstanding/paused -> done');
ok(!BpOrch::run_complete({any_running=>1}), 'complete: running -> not done');
ok(!BpOrch::run_complete({paused=>1}), 'complete: paused -> not done');
ok( BpOrch::has_progressable_work({A=>{deps=>[]}}, {A=>'running'}), 'progress: a running package is progressable');
ok( BpOrch::has_progressable_work({A=>{deps=>[]}, B=>{deps=>['A']}}, {A=>'done', B=>'pending'}), 'progress: pending with done dep is progressable');
ok(!BpOrch::has_progressable_work({A=>{deps=>[]}, B=>{deps=>['A']}}, {A=>'blocked', B=>'pending'}), 'progress: pending blocked by a blocked dep -> not progressable');
ok(!BpOrch::has_progressable_work({A=>{deps=>[]}}, {A=>'done'}), 'progress: all terminal -> none');

# ---- parse_dag ------------------------------------------------------------
{
    my $md = <<'MD';
# Blueprint

## Package status

| pkg | deliverable | depends_on | model | status |
|-----|-------------|------------|-------|--------|
| A0  | spike       | —          | sonnet | ✅ done |
| A1  | rename      | A0         | opus   | 🔧 running |
| A3  | core        | A0, A1     | opus   | 🔧 running |

## Next section (not a table row)
MD
    my $dag = BpOrch::parse_dag($md);
    is_deeply($dag->{A0}, [], 'dag: em-dash depends_on -> no deps');
    is_deeply($dag->{A1}, ['A0'], 'dag: single dep parsed');
    is_deeply([sort @{$dag->{A3}}], ['A0','A1'], 'dag: comma+space dep list parsed');
    is(scalar keys %$dag, 3, 'dag: stops at the end of the table');
}

# ---- IO: marker (PID + flock) ---------------------------------------------
my $dir = tempdir(CLEANUP => 1);
{
    my $mk = "$dir/.orchestrator";
    my $fh = BpOrch::acquire_marker($mk);
    ok($fh, 'marker: first acquire succeeds');
    is(BpOrch::read_marker_pid($mk), $$, 'marker: records our PID');
    my $fh2 = BpOrch::acquire_marker($mk);
    ok(!$fh2, 'marker: second acquire is refused (flock held)');
    BpOrch::release_marker($fh, $mk);
    ok(!-e $mk, 'marker: release removes the file');
}

# ---- IO: paused round-trip ------------------------------------------------
{
    my $runs = "$dir/runs1"; mkdir $runs;
    is(BpOrch::read_paused($runs), undef, 'paused: absent -> undef');
    BpOrch::write_paused($runs, { reason=>'usage', relaunch_at=>1234, manual=>0 });
    my $p = BpOrch::read_paused($runs);
    is($p->{relaunch_at}, 1234, 'paused: round-trips relaunch_at');
    BpOrch::clear_pause($runs);
    is(BpOrch::read_paused($runs), undef, 'paused: cleared');
}

# ---- IO: needs-you queue (schema + dedupe) --------------------------------
{
    my $runs = "$dir/runs2"; mkdir $runs;
    my $f = BpOrch::queue_needs_you($runs, { package=>'A3', blueprint=>'bp', kind=>'stuck-package', question=>'q?', context=>'c', created_at=>100 });
    ok(-e $f, 'needs-you: file written');
    like($f, qr{needs-you/A3--[0-9a-f]+\.json$}, 'needs-you: filename pattern <pkg>--<shortid>.json');
    my $rec = $J->decode(do { local $/; open my $r,'<',$f or die; <$r> });
    is($rec->{package}, 'A3', 'needs-you: package field');
    is($rec->{kind}, 'stuck-package', 'needs-you: kind field');
    ok(exists $rec->{question} && exists $rec->{context} && exists $rec->{created_at}, 'needs-you: full schema');
    my $f2 = BpOrch::queue_needs_you($runs, { package=>'A3', blueprint=>'bp', kind=>'stuck-package', question=>'again', context=>'c2', created_at=>200 });
    is($f2, $f, 'needs-you: same package+kind deduped to the existing file');
    opendir my $dh, "$runs/needs-you"; my @j = grep { /\.json$/ } readdir $dh; closedir $dh;
    is(scalar @j, 1, 'needs-you: dedupe leaves exactly one file');
}

# ---- transport: fetch_usage with an injected http_get ---------------------
sub write_creds {
    my ($path, $exp_ms) = @_;
    open my $f, '>:raw', $path or die;
    print $f $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-TESTTESTTESTTESTTESTTEST', refreshToken => 'sk-ant-REFREFREFREFREFREFREFREF',
        expiresAt => $exp_ms, scopes => ['user:inference'], subscriptionType => 'max', rateLimitTier => 'x' } });
    close $f;
}
{
    my $c = "$dir/creds-usage.json"; write_creds($c, 9_000_000_000_000);
    my $log = "$dir/usage.log";
    my $body = $J->encode({
        five_hour => { utilization => 42, resets_at => '2026-06-22T05:59:59+00:00' },
        seven_day => { utilization => 7,  resets_at => '2026-06-22T17:59:59+00:00' },
    });
    my @calls;
    my $get = sub { push @calls, { url=>$_[0], hdr=>$_[1] }; return { status=>200, content=>$body }; };
    my $u = BpOrch::fetch_usage({ creds_path=>$c, http_get=>$get, log_path=>$log });
    is($u->{action}, 'ok', 'fetch_usage: 200 + valid -> ok');
    is($u->{usage}{five_hour}{utilization}, 42, 'fetch_usage: returns parsed usage');
    is(scalar @calls, 1, 'fetch_usage: exactly one GET');
    like($calls[0]{hdr}{'Authorization'}, qr/^Bearer sk-ant-/, 'fetch_usage: sends Bearer token');
    is($calls[0]{hdr}{'anthropic-beta'}, 'oauth-2025-04-20', 'fetch_usage: sends oauth beta header');
    my $logtxt = do { local $/; open my $r,'<',$log or die; <$r> };
    like($logtxt, qr/"type":"usage_poll"/, 'fetch_usage: logs usage_poll');
    unlike($logtxt, qr/sk-ant-/, 'fetch_usage: NO token in the log');
}
{
    my $c = "$dir/creds-429.json"; write_creds($c, 9_000_000_000_000);
    my $u = BpOrch::fetch_usage({ creds_path=>$c, http_get=>sub { { status=>429, content=>'{}' } } });
    is($u->{action}, 'unavailable', 'fetch_usage: 429 -> telemetry unavailable');
    is($u->{status}, 429, 'fetch_usage: surfaces the status');
}
{
    my $c = "$dir/creds-bad.json"; open my $f,'>:raw',$c; print $f '{"claudeAiOauth":{"accessToken":"x"}}'; close $f;
    my $u = BpOrch::fetch_usage({ creds_path=>$c, http_get=>sub { die "should not be called" } });
    is($u->{action}, 'pause-contract', 'fetch_usage: bad creds shape -> pause-contract (no network)');
}
{
    my $u = BpOrch::fetch_usage({ creds_path=>"$dir/nope.json", http_get=>sub { die "no" } });
    is($u->{action}, 'pause-creds', 'fetch_usage: missing creds -> pause-creds');
}

# ---- ASSEMBLY: one --once tick with mocked launch + transports ------------
{
    my $bpdir = "$dir/bp"; mkdir $bpdir; mkdir "$bpdir/packages"; mkdir "$bpdir/runs";
    open my $b, '>', "$bpdir/blueprint.md" or die;
    print $b <<'MD';
# T

## Package status

| pkg | deliverable | depends_on | model | status |
|-----|-------------|------------|-------|--------|
| pkgA | thing A | — | sonnet | ⬜ pending |
| pkgB | thing B | pkgA | sonnet | ⬜ pending |
MD
    close $b;
    for my $p (['pkgA','p/a/'], ['pkgB','p/b/']) {
        open my $l, '>', "$bpdir/packages/$p->[0].md" or die;
        print $l "---\npackage: $p->[0]\nblueprint: T\nstatus: pending\nmodel: sonnet\nmax_turns: 80\nwrite_set: $p->[1]\ntest_paths: $p->[1]\nlast_updated: 2026-06-24T00:00:00Z\n---\n\n# $p->[0]\n";
        close $l;
    }
    my $NOW = 1_900_000_000;
    my $creds = "$dir/creds-loop.json"; write_creds($creds, ($NOW + 5*3600) * 1000);  # 5h life -> keeper 'ok'
    my $busy = "$dir/busy-loop";
    my $usage_body = $J->encode({
        five_hour => { utilization => 10, resets_at => '2026-06-22T05:59:59+00:00' },
        seven_day => { utilization => 5,  resets_at => '2026-06-22T17:59:59+00:00' },
    });
    my @launched; my @posts;
    my $t = {
        ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>0,
        keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>300, jit_hi=>900,
        tele_retry=>3, usage_fail=>60, busy_path=>$busy,
    };
    BpOrch::run({
        blueprint => 'T', bp_dir => $bpdir, creds_path => $creds, tunables => $t,
        once => 1, now => sub { $NOW }, sleep => sub { },
        http_get  => sub { { status=>200, content=>$usage_body } },
        http_post => sub { push @posts, 1; { status=>200, content=>'{}' } },
        launch    => sub { push @launched, $_[0]{pkg}; 0 },
    });
    is(scalar @launched, 1, 'loop: exactly one launch this tick');
    is($launched[0], 'pkgA', 'loop: launches the ready package (pkgA), not the dep-blocked pkgB');
    is(scalar @posts, 0, 'loop: keeper made no refresh call (token life ok)');
    ok(-e $busy, 'loop: busy-lease touched (work active)');
    ok(!-e "$bpdir/runs/.orchestrator", 'loop: marker removed on clean exit');
    my $log = do { local $/; open my $r,'<',"$bpdir/runs/orchestrator.log" or die; <$r> };
    like($log, qr/"type":"orchestrator_start"/, 'loop: logged start');
    like($log, qr/"type":"usage_poll"/, 'loop: logged a usage poll');
    like($log, qr/"package":"pkgA".*"type":"launch"/, 'loop: logged the launch');
    like($log, qr/"type":"orchestrator_stop"/, 'loop: logged stop');
}

# ---- manual pause never clobbers a prior manual reason (review Finding 5) --
{
    my $runs = "$dir/runs3"; mkdir $runs;
    BpOrch::_enter_pause_manual($runs, undef, 'token-floor',
        { package=>'_fleet', blueprint=>'bp', kind=>'reauth', question=>'re-login', context=>'floor', created_at=>10 });
    BpOrch::_enter_pause_manual($runs, undef, 'usage-contract',
        { package=>'_fleet', blueprint=>'bp', kind=>'contract-drift', question=>'drift', context=>'c', created_at=>20 });
    my $p = BpOrch::read_paused($runs);
    is($p->{reason}, 'token-floor', 'manual pause: first reason preserved (no clobber)');
    ok($p->{manual}, 'manual pause: stays manual');
    opendir my $dh, "$runs/needs-you"; my @j = grep { /\.json$/ } readdir $dh; closedir $dh;
    is(scalar @j, 2, 'manual pause: both decisions queued (distinct kinds, not suppressed)');
}

# ---- a FAILED launch does not get counted as a live slot (review Finding 1) -
{
    my $bpdir = "$dir/bp2"; mkdir $bpdir; mkdir "$bpdir/packages"; mkdir "$bpdir/runs";
    open my $b, '>', "$bpdir/blueprint.md" or die;
    print $b "# T2\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n| solo | x | — | sonnet | pending |\n";
    close $b;
    open my $l, '>', "$bpdir/packages/solo.md" or die;
    print $l "---\npackage: solo\nblueprint: T2\nstatus: pending\nwrite_set: p/s/\ntest_paths: p/s/\nlast_updated: 2026-06-24T00:00:00Z\n---\n# solo\n";
    close $l;
    my $NOW = 1_900_000_000;
    my $creds = "$dir/creds-fail.json"; write_creds($creds, ($NOW + 5*3600) * 1000);
    my $ub = $J->encode({ five_hour=>{utilization=>10, resets_at=>'2026-06-22T05:59:59+00:00'},
                          seven_day=>{utilization=>5,  resets_at=>'2026-06-22T17:59:59+00:00'} });
    my $t = { ceil5=>85,ceil7=>90,drain=>600,max_par=>2,cap=>5,flat=>600,watch_tick=>0,
              keeper_int=>600,keeper_bo=>120,thresh_min=>60,jit_lo=>300,jit_hi=>900,
              tele_retry=>3,usage_fail=>60,busy_path=>"$dir/busy2" };
    my @tries;
    BpOrch::run({ blueprint=>'T2', bp_dir=>$bpdir, creds_path=>$creds, tunables=>$t,
        once=>1, now=>sub{$NOW}, sleep=>sub{},
        http_get=>sub{ {status=>200, content=>$ub} }, http_post=>sub{ {status=>200,content=>'{}'} },
        launch=>sub{ push @tries, $_[0]{pkg}; 1 } });   # 1 = launch failure
    is(scalar @tries, 1, 'loop(fail): launch attempted once');
    my $log = do { local $/; open my $r,'<',"$bpdir/runs/orchestrator.log" or die; <$r> };
    like($log, qr/"type":"launch_failed"/, 'loop(fail): logs launch_failed');
    unlike($log, qr/"type":"launch"/, 'loop(fail): no success-launch event logged');
    ok(!-e "$bpdir/runs/.orchestrator", 'loop(fail): marker cleaned on exit');
}
