#!/usr/bin/env perl
# A3 orchestrator LOOP scenarios — drive the real BpOrch::run({once=>1}) through
# the survivability paths end-to-end with injected clock/registry/transport/launch
# (no live network, no real claude). This complements t/06 (pure decisions + one
# happy --once tick) by exercising the loop's crash/block/pause/resume/telemetry/
# drift/shutdown branches against the actual assembled loop. (Proto-A6.)
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-orchestrator.pl";

plan tests => 23;

my $J   = JSON::PP->new;
my $ROOT = tempdir(CLEANUP => 1);
# Use real "now" so a freshly-written ledger's mtime is within the warm-resume
# window (S1). Fixtures that must sit in the future relative to now (a usage
# pause's resets_at) use a far-future date so the pause holds (S3).
my $NOW = time;
my $DEAD_PID = 2_000_000_000;   # out of range -> kill 0 fails -> not alive

sub write_creds {
    my ($path) = @_;
    open my $f, '>:raw', $path or die;
    print $f $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-SCN-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-SCNREF-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 5*3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } });
    close $f;
}

# build a blueprint dir: pkgs = [ [name, deps_str, status, write_set], ... ]
my $bpn = 0;
sub mk_bp {
    my ($pkgs, $registry) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    for my $p (@$pkgs) { print $b "| $p->[0] | d | $p->[1] | sonnet | $p->[2] |\n"; }
    close $b;
    for my $p (@$pkgs) {
        open my $l, '>', "$dir/packages/$p->[0].md" or die;
        print $l "---\npackage: $p->[0]\nblueprint: T$bpn\nstatus: $p->[2]\nwrite_set: $p->[3]\ntest_paths: $p->[3]\nlast_updated: 2026-06-24T00:00:00Z\n---\n# $p->[0]\n\n## Next action\n\ngo\n";
        close $l;
    }
    if ($registry) {
        open my $r, '>', "$dir/runs/registry.json" or die;
        print $r $J->encode({ packages => $registry }); close $r;
    }
    write_creds("$dir/creds.json");
    return $dir;
}

# low-usage 200 body (no pause); a fixed resets_at.
my $USAGE_OK   = $J->encode({ five_hour=>{utilization=>10, resets_at=>'2026-06-22T05:59:59+00:00'},
                              seven_day=>{utilization=>5,  resets_at=>'2026-06-22T17:59:59+00:00'} });
# resets_at far in the future so the derived pause's relaunch_at stays ahead of
# real `now` (otherwise it would auto-resume in the same tick).
my $USAGE_HIGH = $J->encode({ five_hour=>{utilization=>86, resets_at=>'2099-01-01T00:00:00+00:00'},
                              seven_day=>{utilization=>5,  resets_at=>'2099-01-01T12:00:00+00:00'} });
my $USAGE_BAD  = $J->encode({ five_hour=>{utilization=>'x'}, seven_day=>{} });

sub base_tunables {
    my %o = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>600, watch_tick=>0,
             keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
             tele_retry=>3, usage_fail=>60, busy_path=>"$ROOT/busy.$bpn", %o };
}

sub run_once {
    my ($dir, %o) = @_;
    my @launched;
    my $bget = $o{usage} // $USAGE_OK;
    BpOrch::run({
        blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
        tunables => ($o{tunables} || base_tunables()),
        once => 1, now => sub { $NOW }, sleep => sub { },
        http_get  => ($o{http_get}  || sub { { status => 200, content => $bget } }),
        http_post => sub { { status => 200, content => '{}' } },
        launch    => sub { push @launched, $_[0]; 0 },
    });
    return \@launched;
}

sub slurp { local $/; open my $f,'<',shift or return ''; <$f> }
sub needs_you_count { my $d=shift."/runs/needs-you"; return 0 unless -d $d; opendir my $h,$d; my @j=grep{/\.json$/}readdir $h; closedir $h; scalar @j }

# --- S1: crashed coordinator (dead pid, attempt>0, ledger still 'pending') -> warm relaunch
{
    my $dir = mk_bp([['solo','—','pending','p/s/']],
                    { solo => { attempt=>1, pid=>$DEAD_PID, session_id=>'sid-x', status=>'running' } });
    my $l = run_once($dir);
    is(scalar @$l, 1, 'S1 crash: exactly one relaunch');
    is($l->[0]{pkg}, 'solo', 'S1 crash: relaunched the crashed package');
    is($l->[0]{kind}, 'warm', 'S1 crash: warm resume (fresh ledger + session id)');
    is_deeply($l->[0]{args}, ['--resume-session','sid-x'], 'S1 crash: warm passes --resume-session');
    like(slurp("$dir/runs/orchestrator.log"), qr/watchdog_relaunch/, 'S1 crash: logged watchdog_relaunch');
}

# --- S2: serial failer at the attempt cap -> block + queue, no relaunch
{
    my $dir = mk_bp([['solo','—','pending','p/s/']],
                    { solo => { attempt=>5, pid=>$DEAD_PID, session_id=>'sid-x', status=>'running' } });
    my $l = run_once($dir);
    is(scalar @$l, 0, 'S2 loop-guard: no relaunch past the cap');
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*blocked/m, 'S2 loop-guard: ledger marked blocked');
    is(needs_you_count($dir), 1, 'S2 loop-guard: a needs-you decision queued');
    like(slurp("$dir/runs/orchestrator.log"), qr/watchdog_block/, 'S2 loop-guard: logged watchdog_block');
}

# --- S3: usage at/over the ceiling -> derived pause, no launch
{
    my $dir = mk_bp([['solo','—','pending','p/s/']]);
    my $l = run_once($dir, usage => $USAGE_HIGH);
    is(scalar @$l, 0, 'S3 usage-pause: nothing launched while pausing');
    my $p = BpOrch::read_paused("$dir/runs");
    ok($p && $p->{reason} eq 'usage', 'S3 usage-pause: runs/.paused written with reason usage');
    ok(defined $p->{resets_at}, 'S3 usage-pause: resets_at recorded (epoch)');
    like(slurp("$dir/runs/orchestrator.log"), qr/"reason":"usage".*"type":"pause"/, 'S3 usage-pause: logged pause');
}

# --- S4: a usage pause whose relaunch_at has passed -> auto-resume + launch
{
    my $dir = mk_bp([['solo','—','pending','p/s/']]);
    BpOrch::write_paused("$dir/runs", { reason=>'usage', manual=>0, resets_at=>$NOW-600, relaunch_at=>$NOW-10, created_at=>$NOW-600 });
    my $l = run_once($dir);
    ok(!-e "$dir/runs/.paused", 'S4 auto-resume: .paused cleared after relaunch_at');
    is(scalar @$l, 1, 'S4 auto-resume: work resumes (package launched)');
    like(slurp("$dir/runs/orchestrator.log"), qr/auto_resume/, 'S4 auto-resume: logged auto_resume');
}

# --- S5: telemetry loss -> fail-safe pause (tele_retry=1), no launch
{
    my $dir = mk_bp([['solo','—','pending','p/s/']]);
    my $l = run_once($dir, tunables => base_tunables(tele_retry=>1),
                     http_get => sub { { status=>500, content=>'oops' } });
    is(scalar @$l, 0, 'S5 telemetry-loss: nothing launched');
    my $p = BpOrch::read_paused("$dir/runs");
    ok($p && $p->{reason} eq 'telemetry', 'S5 telemetry-loss: graceful telemetry pause written');
}

# --- S6: usage contract drift -> manual pause + queued decision, no launch
{
    my $dir = mk_bp([['solo','—','pending','p/s/']]);
    my $l = run_once($dir, usage => $USAGE_BAD);
    is(scalar @$l, 0, 'S6 contract-drift: nothing launched');
    my $p = BpOrch::read_paused("$dir/runs");
    ok($p && $p->{manual}, 'S6 contract-drift: manual (no auto-resume) pause');
    is(needs_you_count($dir), 1, 'S6 contract-drift: a needs-you decision queued');
}

# --- S7: fleet shutdown signal -> no launch, clean wind-down
{
    my $dir = mk_bp([['solo','—','pending','p/s/']]);
    open my $s, '>', "$dir/runs/.shutdown" or die; close $s;
    my $l = run_once($dir);
    is(scalar @$l, 0, 'S7 shutdown: nothing launched under the shutdown signal');
    like(slurp("$dir/runs/orchestrator.log"), qr/shutdown_complete/, 'S7 shutdown: logged clean wind-down');
}
