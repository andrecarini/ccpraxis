#!/usr/bin/env perl
# A6 simulation harness: drive the REAL BpOrch::run (NOT --once) across MANY ticks
# with a fake clock + a scripted fake world — coordinators that progress / finish /
# crash / wedge on cue, and judges that return verdicts on cue — and assert the
# full unattended choreography end-to-end. This is the layer t/06 (pure decisions)
# and t/10 (single-tick seam) can't reach: the loop's tick-to-tick state (the %seen
# progress tracker, launch-on-completion event-drive, the judge consume-then-fire
# across ticks, C2's "wait for an in-flight judge before idle-exit"). "Passes the
# simulation" is an A5/A6 done-criterion (Decision #25).
#
# Mechanics: run() with injected now/sleep/launch/pid_alive/spawn_judge. The fake
# clock is the single source of time; `sleep` advances it AND ticks the fake world
# once. A coordinator is a fake live pid + a per-launch behavior script; its jsonl
# growth + mtime are written against the FAKE clock so progress_verdict is faithful.
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

sub slurp { local $/; open my $f,'<',shift or return ''; <$f> }
sub write_creds {
    # expiry pinned far out so the token-keeper never enters its refresh band during
    # a (possibly long) sim — these scenarios test the loop, not the keeper (t/05 does).
    my ($p) = @_; open my $f,'>:raw',$p or die;
    print $f $J->encode({ claudeAiOauth => {
        accessToken=>'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken=>'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt=>($NOW+100*3600)*1000, scopes=>['user:inference'], subscriptionType=>'max', rateLimitTier=>'x' } });
    close $f;
}
# build an ISO8601 resets_at relative to $NOW (for a pause that actually resumes).
sub iso_at { my @t=gmtime($_[0]); sprintf "%04d-%02d-%02dT%02d:%02d:%02d+00:00", $t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]; }
my $bpn = 0;
sub mk_bp {
    my ($pkgs, $registry) = @_;
    my $dir = "$ROOT/bp".(++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b,'>',"$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->[0] | d | $_->[1] | sonnet | $_->[2] |\n" for @$pkgs;
    close $b;
    for my $p (@$pkgs) {
        open my $l,'>',"$dir/packages/$p->[0].md" or die;
        print $l "---\npackage: $p->[0]\nblueprint: T$bpn\nstatus: $p->[2]\nwrite_set: $p->[3]\ntest_paths: $p->[3]\nlast_updated: 2026-06-24T00:00:00Z\n---\n# $p->[0]\n\n## Next action\n\ngo\n";
        close $l;
    }
    if ($registry) { open my $r,'>',"$dir/runs/registry.json" or die; print $r $J->encode({ packages=>$registry }); close $r; }
    write_creds("$dir/creds.json");
    return $dir;
}
my $USAGE_OK   = $J->encode({ five_hour=>{utilization=>10, resets_at=>'2099-01-01T00:00:00+00:00'},
                              seven_day=>{utilization=>5,  resets_at=>'2099-01-01T12:00:00+00:00'} });
my $USAGE_HIGH = $J->encode({ five_hour=>{utilization=>86, resets_at=>'2099-01-01T00:00:00+00:00'},
                              seven_day=>{utilization=>5,  resets_at=>'2099-01-01T12:00:00+00:00'} });
sub base_tun { my %o=@_; return { ceil5=>85,ceil7=>90,drain=>600,max_par=>2,cap=>5,flat=>120,watch_tick=>60,
    keeper_int=>600,keeper_bo=>120,thresh_min=>60,jit_lo=>0,jit_hi=>0,tele_retry=>3,usage_fail=>60,
    busy_path=>"$ROOT/busy.$bpn", harvest=>'audit', resolve_cap=>1, corr_cap=>1, judge_to=>100000,
    judge_spawn_cap=>3, %o }; }

# --- fake-world helpers -----------------------------------------------------
sub _grow_jsonl { my ($runs,$pkg,$clock)=@_; my $f="$runs/$pkg.jsonl";
    open my $w,'>>',$f or return; print $w "x"; close $w; utime $clock,$clock,$f; }
sub _set_status { my ($dir,$pkg,$st)=@_; my $f="$dir/packages/$pkg.md"; my $t=slurp($f);
    $t =~ s/^status:.*$/status: $st/m; open my $w,'>:raw',$f or return; print $w $t; close $w; }
sub _seed_verdict { my ($dir,$kind,$pkg,$obj)=@_; require File::Path; File::Path::make_path("$dir/runs/$kind");
    open my $w,'>',BpOrch::judge_verdict_path("$dir/runs",$kind,$pkg) or die; print $w $J->encode($obj); close $w; }
sub _beh { my ($spec,$pkg,$n)=@_; my $b=$spec->{$pkg}; return { runs=>1, then=>'done' } unless defined $b;
    return $b unless ref $b eq 'ARRAY'; my $i=$n-1; $i=$#$b if $i>$#$b; return $b->[$i]; }

# run_sim(\%spec) -> { dir, launched, spawned, ticks, err, reg, log }
#   pkgs  => [[name,deps,write_set],...]   reg => {seed}
#   coord => { pkg => {runs=>N,then=>'done'|'crash'|'wedge'} | [ per-launch behaviors ] }
#   harvest => { pkg => 'pass'|'fail' }    resolve => { pkg => {action=>...} }
#   tun => {...}  http_get => sub  max_ticks => N  verdict_delay => ticks
sub run_sim {
    my ($spec) = @_;
    my $dir  = mk_bp($spec->{pkgs}, $spec->{reg});
    my $runs = "$dir/runs";
    my $tun  = base_tun(%{ $spec->{tun} || {} });
    my $clock = $NOW;
    my $tick = 0; my $max = $spec->{max_ticks} // 300;
    my $vdelay = $spec->{verdict_delay} // 2;
    my (%alive, %coord, %lcount, %vdue, @launched, @spawned);
    my $pidn = 900000;

    my $launch = sub {
        my ($a) = @_; my $pkg = $a->{pkg};
        push @launched, { %$a, clock => $clock };
        my $pid = ++$pidn; $alive{$pid} = 1;
        my $att = (BpOrch::read_registry($runs)->{$pkg}{attempt} // 0) + 1;
        BpOrch::update_registry_pkg($runs, $pkg, { pid=>$pid, status=>'running', attempt=>$att, session_id=>"sid-$pkg" });
        my $n = ++$lcount{$pkg};
        $coord{$pkg} = { pid=>$pid, ran=>0, beh=>_beh($spec->{coord}, $pkg, $n) };
        _grow_jsonl($runs, $pkg, $clock);
        return 0;
    };
    my $advance = sub {
        $clock += ($_[0] // 0); $tick++;
        die "SIM: exceeded $max ticks\n" if $tick > $max;
        for my $pkg (sort keys %coord) {
            my $c = $coord{$pkg}; next unless $alive{$c->{pid}};
            $c->{ran}++;
            if ($c->{ran} < ($c->{beh}{runs} // 1)) { _grow_jsonl($runs,$pkg,$clock); next; }
            my $then = $c->{beh}{then} // 'done';
            if    ($then eq 'done')  { _set_status($dir,$pkg,'done'); delete $alive{$c->{pid}}; }
            elsif ($then eq 'crash') { delete $alive{$c->{pid}}; }              # ledger stays non-terminal
            elsif ($then eq 'wedge') { }                                        # alive, jsonl frozen -> flat
        }
        for my $key (sort keys %vdue) {
            next if $clock < $vdue{$key};
            my ($kind,$pkg) = split /:/, $key, 2;
            my $obj = $kind eq 'harvest'
                ? { verdict => ($spec->{harvest}{$pkg} // 'pass') }
                : ($spec->{resolve}{$pkg} // { action=>'park', reason=>'sim default', needs_you=>{question=>'?'} });
            _seed_verdict($dir,$kind,$pkg,$obj);
            delete $vdue{$key};
        }
    };
    my $spawn = sub {
        my ($a) = @_; push @spawned, { %$a, clock=>$clock };
        $vdue{"$a->{kind}:$a->{pkg}"} = $clock + $vdelay * $tun->{watch_tick};
        return 0;
    };

    my $err;
    eval {
        BpOrch::run({
            blueprint=>'T', bp_dir=>$dir, creds_path=>"$dir/creds.json", tunables=>$tun,
            now=>sub { $clock }, sleep=>sub { $advance->($_[0]) },
            http_get=>($spec->{http_get} || sub { { status=>200, content=>$USAGE_OK } }),
            http_post=>sub { { status=>200, content=>'{}' } },
            launch=>$launch, pid_alive=>sub { (defined $_[0] && $alive{$_[0]}) ? 1 : 0 },
            spawn_judge=>$spawn,
        });
        1;
    } or $err = $@;
    return { dir=>$dir, launched=>\@launched, spawned=>\@spawned, ticks=>$tick, err=>$err,
             reg=>BpOrch::read_registry($runs), log=>slurp("$runs/orchestrator.log") };
}
sub launched_pkgs { my $r=shift; [ map { $_->{pkg} } @{$r->{launched}} ] }

# ===========================================================================
# SIM-1: happy path with harvest — A progresses, finishes, harvest audits PASS,
# dependent B launches, finishes, audits PASS, run completes cleanly.
# ===========================================================================
{
    my $r = run_sim({
        pkgs  => [['A','—','pending','p/a/'], ['B','A','pending','p/b/']],
        coord => { A => {runs=>2,then=>'done'}, B => {runs=>2,then=>'done'} },
        harvest => { A=>'pass', B=>'pass' },
    });
    is($r->{err}, undef, 'SIM-1: loop terminated cleanly (no max-tick blowout)');
    is_deeply([sort @{launched_pkgs($r)}], ['A','B'], 'SIM-1: both A and B launched exactly once each');
    is($r->{reg}{A}{harvest}, 'pass', 'SIM-1: A harvest audit recorded pass');
    is($r->{reg}{B}{harvest}, 'pass', 'SIM-1: B harvest audit recorded pass');
    is($r->{launched}[0]{pkg}, 'A', 'SIM-1: A launched first');
    is($r->{launched}[1]{pkg}, 'B', 'SIM-1: B launched second — only after A finished (event-driven dependency)');
    cmp_ok($r->{launched}[1]{clock}, '>', $r->{launched}[0]{clock}, 'SIM-1: B launched at a strictly later tick than A');
    like($r->{log}, qr/idle_exit/, 'SIM-1: ended via idle_exit, not a stall');
    # C2 in a flow: the loop must not have idle-exited while A/B harvest judges were
    # still in flight (it waited for the pass verdicts before completing).
    is(scalar(grep { $_->{kind} eq 'harvest' } @{$r->{spawned}}), 2, 'SIM-1: one harvest judge per finished package');
}

# ===========================================================================
# SIM-2: a coordinator crashes once, is relaunched (warm), then finishes.
# ===========================================================================
{
    my $r = run_sim({
        pkgs  => [['A','—','pending','p/a/']],
        coord => { A => [ {runs=>1,then=>'crash'}, {runs=>2,then=>'done'} ] },
        harvest => { A=>'pass' },
    });
    is($r->{err}, undef, 'SIM-2: terminated cleanly');
    is(scalar @{$r->{launched}}, 2, 'SIM-2: A launched twice (initial + relaunch)');
    is($r->{launched}[1]{kind}, 'warm', 'SIM-2: the relaunch was warm (fresh ledger + session id)');
    like($r->{log}, qr/watchdog_relaunch/, 'SIM-2: logged watchdog_relaunch');
    is($r->{reg}{A}{harvest}, 'pass', 'SIM-2: A eventually finished and passed harvest');
}

# ===========================================================================
# SIM-3: a coordinator wedges (alive, log flat) -> kill + cold-relaunch -> done.
# ===========================================================================
{
    my $r = run_sim({
        pkgs  => [['A','—','pending','p/a/']],
        coord => { A => [ {runs=>1,then=>'wedge'}, {runs=>2,then=>'done'} ] },
        harvest => { A=>'pass' },
        max_ticks => 100,
    });
    is($r->{err}, undef, 'SIM-3: terminated cleanly');
    like($r->{log}, qr/watchdog_kill_wedged/, 'SIM-3: detected the wedge and killed it');
    cmp_ok(scalar @{$r->{launched}}, '>=', 2, 'SIM-3: A cold-relaunched after the wedge');
    is($r->{reg}{A}{harvest}, 'pass', 'SIM-3: A finished after the cold-relaunch');
}

# ===========================================================================
# SIM-4: a package fails past the attempt cap -> resolve-judge fires -> verdict
# relaunch (fresh budget) -> succeeds. The whole escalation ladder, across ticks.
# ===========================================================================
{
    my $r = run_sim({
        pkgs  => [['A','—','pending','p/a/']],
        coord => { A => [ {runs=>1,then=>'crash'}, {runs=>1,then=>'crash'}, {runs=>2,then=>'done'} ] },
        resolve => { A => { action=>'relaunch', reason=>'sim: corrected', mutated_files=>['p/a/x'] } },
        harvest => { A=>'pass' },
        tun => { cap=>2 },
        max_ticks => 120,
    });
    is($r->{err}, undef, 'SIM-4: terminated cleanly');
    like($r->{log}, qr/watchdog_block/, 'SIM-4: hit the attempt cap');
    is(scalar(grep { $_->{kind} eq 'resolve' } @{$r->{spawned}}), 1, 'SIM-4: resolve-judge fired exactly once');
    like($r->{log}, qr/resolve_relaunch/, 'SIM-4: resolve verdict drove a relaunch');
    is($r->{reg}{A}{harvest}, 'pass', 'SIM-4: A succeeded after the resolve-driven relaunch');
}

# ===========================================================================
# SIM-5: a package fails past the cap, resolve-judge PARKS -> the branch parks +
# queues a decision, and an INDEPENDENT package still completes (park-the-branch,
# never global-halt — Decision #13).
# ===========================================================================
{
    my $r = run_sim({
        pkgs  => [['A','—','pending','p/a/'], ['C','—','pending','p/c/']],
        coord => { A => {runs=>1,then=>'crash'}, C => {runs=>2,then=>'done'} },
        resolve => { A => { action=>'park', reason=>'sim: ambiguous', needs_you=>{question=>'Which way?',kind=>'ambiguous-requirement'} } },
        harvest => { C=>'pass' },
        tun => { cap=>1 },
        max_ticks => 120,
    });
    is($r->{err}, undef, 'SIM-5: terminated cleanly (parked branch did not stall the run)');
    like(slurp("$r->{dir}/packages/A.md"), qr/^status:\s*blocked/m, 'SIM-5: A parked (blocked)');
    is($r->{reg}{C}{harvest}, 'pass', 'SIM-5: independent C completed despite A parking');
    my $nd = "$r->{dir}/runs/needs-you"; my @q; if (-d $nd) { opendir my $h,$nd; @q=grep {/\.json$/} readdir $h; closedir $h; }
    is(scalar @q, 1, 'SIM-5: a needs-you decision was queued for the parked branch');
}

# ===========================================================================
# SIM-6: usage crosses the trip point -> derived pause; after resets_at + jitter,
# auto-resume and the work launches. Pause + resume across ticks, one run() call.
# ===========================================================================
{
    # First poll is over the ceiling with a NEAR resets_at, so the derived pause's
    # relaunch_at (resets_at + 0 jitter) is only ~2 ticks ahead and the loop actually
    # auto-resumes; subsequent polls are OK so it doesn't immediately re-pause.
    my $usage_high_near = $J->encode({ five_hour=>{utilization=>86, resets_at=>iso_at($NOW+120)},
                                       seven_day=>{utilization=>5,  resets_at=>iso_at($NOW+600)} });
    my $polls = 0;
    my $r = run_sim({
        pkgs  => [['A','—','pending','p/a/']],
        coord => { A => {runs=>2,then=>'done'} },
        harvest => { A=>'pass' },
        http_get => sub { $polls++; { status=>200, content=>($polls <= 1 ? $usage_high_near : $USAGE_OK) } },
        max_ticks => 200,
    });
    is($r->{err}, undef, 'SIM-6: terminated cleanly');
    like($r->{log}, qr/"reason":"usage"/, 'SIM-6: a usage pause was entered on the high poll');
    like($r->{log}, qr/auto_resume/, 'SIM-6: auto-resumed after the pause window');
    is_deeply(launched_pkgs($r), ['A'], 'SIM-6: A launched after resume');
    is($r->{reg}{A}{harvest}, 'pass', 'SIM-6: A completed after the pause/resume cycle');
}

# ===========================================================================
# SIM-7: cold-read proxy. The true cost of a mid-worker cold resume is Claude
# tokens (only measurable live/attended), but a deterministic host proxy is the
# size of what a cold resume re-reads: the ledger. This must stay BOUNDED and not
# grow per relaunch/reopen — i.e. the loop must not accumulate cruft in the ledger
# across cycles. Drive repeated reopens (corr_cap=2 -> two corrective cycles then
# park) and assert the harvest-findings block is replaced idempotently (exactly one),
# the ledger stays small, and the package parks cleanly. (Decision #25: measure.)
{
    my $r = run_sim({
        pkgs  => [['A','—','pending','p/a/']],
        coord => { A => {runs=>1,then=>'done'} },   # finishes every launch; harvest keeps failing
        harvest => { A => 'fail' },
        tun => { corr_cap=>2 },
        max_ticks => 150,
    });
    is($r->{err}, undef, 'SIM-7: terminated cleanly across repeated reopen cycles');
    my $led = slurp("$r->{dir}/packages/A.md");
    my $blocks = () = ($led =~ /## Harvest findings \(re-verify\)/g);
    is($blocks, 1, 'SIM-7: harvest findings written idempotently — exactly one block after repeated reopens');
    cmp_ok(length($led), '<', 4096, 'SIM-7: cold-read proxy — ledger stays bounded (<4KB), no per-cycle bloat');
    like($led, qr/^status:\s*blocked/m, 'SIM-7: parked after the corrective cap (two reopens then park)');
    is($r->{reg}{A}{corrective_attempts}, 2, 'SIM-7: exactly corr_cap corrective cycles were spent');
}

done_testing();
