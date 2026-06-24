#!/usr/bin/env perl
# A5 judges: the pure decision core (BpJudge::) exhaustively, then the orchestrator
# seam end-to-end via the real BpOrch::run({once=>1}) with a stubbed judge spawn +
# on-disk verdicts (no real `claude`). Covers the harvest knob (audit/gate), the
# escalation ladder (resolve fire/relaunch/park/cap/hold), failed-audit handling
# (reopen/park + dependent re-flag), and the crashed-judge timeout fail-safe.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-judge.pl";
require "$Bin/../../scripts/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;

# ===========================================================================
# PART 1 — pure BpJudge:: decisions
# ===========================================================================

# ---- harvest_mode (#15 default audit; unknown -> audit) --------------------
is(BpJudge::harvest_mode(undef),   'audit', 'harvest_mode: undef -> audit');
is(BpJudge::harvest_mode(''),      'audit', 'harvest_mode: empty -> audit');
is(BpJudge::harvest_mode('audit'), 'audit', 'harvest_mode: audit -> audit');
is(BpJudge::harvest_mode('gate'),  'gate',  'harvest_mode: gate -> gate');
is(BpJudge::harvest_mode('GATE'),  'gate',  'harvest_mode: case-insensitive gate');
is(BpJudge::harvest_mode('bogus'), 'audit', 'harvest_mode: unrecognized -> audit (never wedges)');

# ---- gate_admits ----------------------------------------------------------
is(BpJudge::gate_admits('audit','done',undef),  1, 'gate_admits: audit+done -> admit (async verify)');
is(BpJudge::gate_admits('gate','done','pass'),  1, 'gate_admits: gate+done+pass -> admit');
is(BpJudge::gate_admits('gate','done','fail'),  0, 'gate_admits: gate+done+fail -> hold');
is(BpJudge::gate_admits('gate','done',undef),   0, 'gate_admits: gate+done+no-verdict -> hold');
is(BpJudge::gate_admits('gate','running','pass'),0,'gate_admits: not done -> never admit');
is(BpJudge::gate_admits('audit','running',undef),0,'gate_admits: audit+not-done -> not admit');

# ---- effective_status -----------------------------------------------------
{
    my $st = { A=>'done', B=>'running', C=>'done' };
    my $eff = BpJudge::effective_status('audit', $st, { A=>undef, C=>undef });
    is_deeply($eff, $st, 'effective_status: audit is an identity passthrough');
    my $g = BpJudge::effective_status('gate', $st, { A=>'pass', C=>undef });
    is($g->{A}, 'done',       'effective_status: gate keeps done+pass as done');
    is($g->{C}, 'harvesting', 'effective_status: gate demotes done-without-pass to harvesting');
    is($g->{B}, 'running',    'effective_status: gate leaves non-done untouched');
    isnt($g, $st, 'effective_status: gate returns a copy, does not mutate input');
}

# ---- escalation_verdict (#13 ladder gate) ---------------------------------
is(BpJudge::escalation_verdict({resolve_attempts=>0, resolve_cap=>1}), 'resolve', 'escalation: under cap -> resolve');
is(BpJudge::escalation_verdict({resolve_attempts=>1, resolve_cap=>1}), 'park',    'escalation: at cap -> park');
is(BpJudge::escalation_verdict({resolve_attempts=>0, resolve_cap=>0}), 'park',    'escalation: zero budget -> park');
is(BpJudge::escalation_verdict({resolve_attempts=>2, resolve_cap=>3}), 'resolve', 'escalation: budget remaining -> resolve');
is(BpJudge::escalation_verdict({resolve_attempts=>0}),                 'resolve', 'escalation: default cap 1, first try -> resolve');
is(BpJudge::escalation_verdict({resolve_attempts=>1}),                 'park',    'escalation: default cap 1, second -> park');

# ---- normalize_resolve (fail-closed to park) ------------------------------
{
    my $r = BpJudge::normalize_resolve({ action=>'relaunch', reason=>'fixed path', mutated_files=>['a.pl'] });
    is($r->{action}, 'relaunch', 'normalize_resolve: relaunch action');
    is_deeply($r->{mutated_files}, ['a.pl'], 'normalize_resolve: mutated_files preserved');
    my $p = BpJudge::normalize_resolve({ action=>'park', reason=>'ambiguous', needs_you=>{question=>'Which?'} });
    is($p->{action}, 'park', 'normalize_resolve: park action');
    is($p->{needs_you}{question}, 'Which?', 'normalize_resolve: needs_you surfaced');
    is(BpJudge::normalize_resolve({ action=>'PARK' })->{action}, 'park', 'normalize_resolve: case-insensitive');
    is(BpJudge::normalize_resolve({ action=>'frobnicate' })->{action}, 'park', 'normalize_resolve: unknown action -> park');
    like(BpJudge::normalize_resolve({ action=>'frobnicate' })->{reason}, qr/unrecognized/, 'normalize_resolve: unknown reason explains');
    is(BpJudge::normalize_resolve(undef)->{action}, 'park', 'normalize_resolve: undef -> park');
    is(BpJudge::normalize_resolve({})->{action}, 'park', 'normalize_resolve: no action -> park');
    is(BpJudge::normalize_resolve({ _timeout=>1 })->{action}, 'park', 'normalize_resolve: timeout sentinel -> park');
# L2: needs_you must come back a hashref (or undef), never a bare scalar that would
# crash the orchestrator's needs_you->{question} deref.
is(BpJudge::normalize_resolve({ action=>'park', needs_you=>'just a string' })->{needs_you}{question}, 'just a string', 'normalize_resolve: scalar needs_you coerced to {question}');
is(BpJudge::normalize_resolve({ action=>'park' })->{needs_you}, undef, 'normalize_resolve: missing needs_you stays undef');
is(ref BpJudge::normalize_resolve({ action=>'park', needs_you=>{question=>'q',kind=>'k'} })->{needs_you}, 'HASH', 'normalize_resolve: hashref needs_you preserved');
}

# ---- normalize_harvest (fail-closed to error) -----------------------------
is(BpJudge::normalize_harvest({ verdict=>'pass' }), 'pass',  'normalize_harvest: pass');
is(BpJudge::normalize_harvest({ verdict=>'PASS' }), 'pass',  'normalize_harvest: case-insensitive pass');
is(BpJudge::normalize_harvest({ verdict=>'fail' }), 'fail',  'normalize_harvest: fail');
is(BpJudge::normalize_harvest({ result=>'pass' }),  'pass',  'normalize_harvest: result alias');
is(BpJudge::normalize_harvest({}),                  'error', 'normalize_harvest: no verdict -> error');
is(BpJudge::normalize_harvest(undef),               'error', 'normalize_harvest: undef -> error');
is(BpJudge::normalize_harvest({ _timeout=>1 }),     'error', 'normalize_harvest: timeout sentinel -> error');
is(BpJudge::normalize_harvest({ verdict=>'weird' }),'error', 'normalize_harvest: unrecognized -> error (never silent pass)');

# ---- audit_outcome (Q2) ---------------------------------------------------
is(BpJudge::audit_outcome({ verdict=>'pass' }), 'accept', 'audit_outcome: pass -> accept');
is(BpJudge::audit_outcome({ verdict=>'fail', corrective_attempts=>0, corrective_cap=>1 }), 'reopen', 'audit_outcome: fail under cap -> reopen');
is(BpJudge::audit_outcome({ verdict=>'fail', corrective_attempts=>1, corrective_cap=>1 }), 'park',   'audit_outcome: fail at cap -> park');
is(BpJudge::audit_outcome({ verdict=>'error', corrective_attempts=>0 }), 'reopen', 'audit_outcome: error (non-pass) under default cap -> reopen');
is(BpJudge::audit_outcome({ verdict=>'error', corrective_attempts=>1 }), 'park',   'audit_outcome: error at default cap -> park');

# ---- want_harvest_audit / want_harvest_gate -------------------------------
is(BpJudge::want_harvest_audit({ mode=>'audit', status=>'done' }), 1, 'want_audit: audit+done -> fire');
is(BpJudge::want_harvest_audit({ mode=>'audit', status=>'done', harvest=>'pass' }), 0, 'want_audit: already verdicted -> no');
is(BpJudge::want_harvest_audit({ mode=>'audit', status=>'done', inflight=>1 }), 0, 'want_audit: already in flight -> no');
is(BpJudge::want_harvest_audit({ mode=>'audit', status=>'running' }), 0, 'want_audit: not done -> no');
is(BpJudge::want_harvest_audit({ mode=>'gate', status=>'done' }), 0, 'want_audit: gate mode -> no (gate path handles it)');
is(BpJudge::want_harvest_gate({ mode=>'gate', status=>'done' }), 1, 'want_gate: gate+done -> fire');
is(BpJudge::want_harvest_gate({ mode=>'gate', status=>'done', harvest=>'pass' }), 0, 'want_gate: passed -> no');
is(BpJudge::want_harvest_gate({ mode=>'gate', status=>'done', inflight=>1 }), 0, 'want_gate: in flight -> no');
is(BpJudge::want_harvest_gate({ mode=>'gate', status=>'running' }), 0, 'want_gate: not done -> no');
is(BpJudge::want_harvest_gate({ mode=>'audit', status=>'done' }), 0, 'want_gate: audit mode -> no');

# ===========================================================================
# PART 2 — orchestrator seam end-to-end (BpOrch::run --once, stubbed judges)
# ===========================================================================

my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = time;
my $DEAD = 2_000_000_000;

sub write_creds {
    my ($p) = @_;
    open my $f, '>:raw', $p or die;
    print $f $J->encode({ claudeAiOauth => {
        accessToken=>'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken=>'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt=>($NOW+5*3600)*1000, scopes=>['user:inference'], subscriptionType=>'max', rateLimitTier=>'x' } });
    close $f;
}
my $bpn = 0;
# pkgs = [ [name, deps_str, status, write_set], ... ]
sub mk_bp {
    my ($pkgs, $registry) = @_;
    my $dir = "$ROOT/bp".(++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->[0] | d | $_->[1] | sonnet | $_->[2] |\n" for @$pkgs;
    close $b;
    for my $p (@$pkgs) {
        open my $l, '>', "$dir/packages/$p->[0].md" or die;
        print $l "---\npackage: $p->[0]\nblueprint: T$bpn\nstatus: $p->[2]\nwrite_set: $p->[3]\ntest_paths: $p->[3]\nlast_updated: 2026-06-24T00:00:00Z\n---\n# $p->[0]\n\n## Next action\n\ngo\n";
        close $l;
    }
    if ($registry) { open my $r, '>', "$dir/runs/registry.json" or die; print $r $J->encode({ packages=>$registry }); close $r; }
    write_creds("$dir/creds.json");
    return $dir;
}
my $USAGE_OK = $J->encode({ five_hour=>{utilization=>10, resets_at=>'2099-01-01T00:00:00+00:00'},
                            seven_day=>{utilization=>5,  resets_at=>'2099-01-01T12:00:00+00:00'} });
sub base_tun { my %o=@_; return { ceil5=>85,ceil7=>90,drain=>600,max_par=>2,cap=>5,flat=>600,watch_tick=>0,
    keeper_int=>600,keeper_bo=>120,thresh_min=>60,jit_lo=>0,jit_hi=>0,tele_retry=>3,usage_fail=>60,
    busy_path=>"$ROOT/busy.$bpn", harvest=>'audit', resolve_cap=>1, corr_cap=>1, judge_to=>1800, %o }; }

# run one tick; returns { launched=>[...], spawned=>[...] }
sub run_once {
    my ($dir, %o) = @_;
    my (@launched, @spawned);
    BpOrch::run({
        blueprint=>'T', bp_dir=>$dir, creds_path=>"$dir/creds.json",
        tunables=>($o{tunables} || base_tun(%{ $o{tun} || {} })),
        once=>1, now=>($o{now} || sub { $NOW }), sleep=>sub {},
        http_get  => sub { { status=>200, content=>$USAGE_OK } },
        http_post => sub { { status=>200, content=>'{}' } },
        launch    => sub { push @launched, $_[0]; 0 },
        spawn_judge => ($o{spawn_judge} || sub { push @spawned, $_[0]; 0 }),
    });
    return { launched=>\@launched, spawned=>\@spawned };
}
sub slurp { local $/; open my $f,'<',shift or return ''; <$f> }
sub reg_of { my $d=shift; my $r=BpOrch::read_registry("$d/runs"); $r }
sub needs_you { my $d=shift."/runs/needs-you"; return () unless -d $d; opendir my $h,$d; my @j=map { JSON::PP->new->decode(slurp("$d/$_")) } grep {/\.json$/} readdir $h; closedir $h; @j }
sub seed_verdict { my ($dir,$kind,$pkg,$obj)=@_; my $f=BpOrch::judge_verdict_path("$dir/runs",$kind,$pkg); require File::Path; File::Path::make_path("$dir/runs/$kind"); open my $w,'>',$f or die; print $w $J->encode($obj); close $w; }

# ---- A1: audit mode fires a harvest spot-audit on a finished package, and
#         dependents launch immediately (throughput) ---------------------------
{
    my $dir = mk_bp([['A','—','done','p/a/'], ['B','A','pending','p/b/']]);
    my $r = run_once($dir);
    is(scalar(grep { $_->{kind} eq 'harvest' && $_->{pkg} eq 'A' } @{$r->{spawned}}), 1, 'A1: harvest audit fired for finished A');
    is_deeply([map { $_->{pkg} } @{$r->{launched}}], ['B'], 'A1: dependent B launched immediately (audit favors throughput)');
    ok(defined BpOrch::judge_inflight("$dir/runs",'harvest','A'), 'A1: harvest inflight marker written');
    like(slurp("$dir/runs/orchestrator.log"), qr/harvest_fire/, 'A1: logged harvest_fire');
}

# ---- A2: a PASS audit verdict is recorded; no escalation ---------------------
{
    my $dir = mk_bp([['A','—','done','p/a/']]);
    BpOrch::mark_judge_inflight("$dir/runs",'harvest','A',$NOW);
    seed_verdict($dir,'harvest','A',{ verdict=>'pass' });
    run_once($dir);
    is(reg_of($dir)->{A}{harvest}, 'pass', 'A2: harvest=pass recorded in registry');
    ok(!-e BpOrch::judge_verdict_path("$dir/runs",'harvest','A'), 'A2: verdict file consumed');
    ok(!defined BpOrch::judge_inflight("$dir/runs",'harvest','A'), 'A2: inflight cleared');
    like(slurp("$dir/runs/orchestrator.log"), qr/harvest_pass/, 'A2: logged harvest_pass');
}

# ---- A3: a FAIL audit reopens (non-terminal) with findings; a done dependent
#         is FLAGGED for re-verification, not killed ---------------------------
{
    my $dir = mk_bp([['A','—','done','p/a/'], ['B','A','done','p/b/']],
                    { A=>{status=>'done',corrective_attempts=>0}, B=>{status=>'done',harvest=>'pass'} });
    BpOrch::mark_judge_inflight("$dir/runs",'harvest','A',$NOW);
    seed_verdict($dir,'harvest','A',{ verdict=>'fail', failures=>['criterion X unmet at a.pl:3'], reason=>'X missing' });
    my $r = run_once($dir);
    like(slurp("$dir/packages/A.md"), qr/^status:\s*pending/m, 'A3: A reopened non-terminal (pending)');
    is(reg_of($dir)->{A}{corrective_attempts}, 1, 'A3: corrective_attempts incremented');
    like(slurp("$dir/packages/A.md"), qr/Harvest findings \(re-verify\)/, 'A3: audit findings written into the ledger');
    like(slurp("$dir/packages/A.md"), qr/criterion X unmet/, 'A3: the specific failure is in the ledger');
    is(reg_of($dir)->{B}{harvest}, '', 'A3: done dependent B flagged for re-verification (harvest cleared)');
    is_deeply([map { $_->{pkg} } @{$r->{launched}}], ['A'], 'A3: A relaunched for the corrective cycle');
    like(slurp("$dir/runs/orchestrator.log"), qr/harvest_reopen/, 'A3: logged harvest_reopen');
}

# ---- A4: a FAIL audit at the corrective cap parks + alarms (no relaunch) -----
{
    my $dir = mk_bp([['A','—','done','p/a/']], { A=>{status=>'done',corrective_attempts=>1} });
    BpOrch::mark_judge_inflight("$dir/runs",'harvest','A',$NOW);
    seed_verdict($dir,'harvest','A',{ verdict=>'fail', reason=>'still broken' });
    my $r = run_once($dir);
    like(slurp("$dir/packages/A.md"), qr/^status:\s*blocked/m, 'A4: A parked (blocked) after the corrective cap');
    my @q = needs_you($dir);
    is(scalar @q, 1, 'A4: a needs-you decision queued');
    is($q[0]{kind}, 'harvest-failure', 'A4: queued as a harvest-failure alarm');
    is(scalar @{$r->{launched}}, 0, 'A4: not relaunched');
    like(slurp("$dir/runs/orchestrator.log"), qr/harvest_park/, 'A4: logged harvest_park');
}

# ---- G1: gate mode HOLDS dependents until the gate passes --------------------
{
    my $dir = mk_bp([['A','—','done','p/a/'], ['B','A','pending','p/b/']]);
    my $r = run_once($dir, tun => { harvest=>'gate' });
    is(scalar @{$r->{launched}}, 0, 'G1: gate holds dependent B (A not yet harvest-passed)');
    is(scalar(grep { $_->{kind} eq 'harvest' } @{$r->{spawned}}), 1, 'G1: gate fired the harvest judge for A');
}

# ---- G2: gate mode ADMITS dependents once the gate passed --------------------
{
    my $dir = mk_bp([['A','—','done','p/a/'], ['B','A','pending','p/b/']], { A=>{status=>'done',harvest=>'pass'} });
    my $r = run_once($dir, tun => { harvest=>'gate' });
    is_deeply([map { $_->{pkg} } @{$r->{launched}}], ['B'], 'G2: gate admits B once A harvest=pass');
    is(scalar @{$r->{spawned}}, 0, 'G2: no harvest re-fired for an already-passed A');
}

# ---- R1: a stuck package fires the resolve-judge (escalation ladder) ---------
{
    my $dir = mk_bp([['solo','—','pending','p/s/']], { solo=>{attempt=>5,pid=>$DEAD,session_id=>'s',status=>'running'} });
    my $r = run_once($dir);
    is_deeply([map { "$_->{kind}:$_->{pkg}" } @{$r->{spawned}}], ['resolve:solo'], 'R1: resolve-judge fired for the stuck package');
    is(reg_of($dir)->{solo}{resolve_attempts}, 1, 'R1: resolve_attempts incremented');
    ok(defined BpOrch::judge_inflight("$dir/runs",'resolve','solo'), 'R1: resolve inflight marker written');
    is(scalar @{$r->{launched}}, 0, 'R1: not relaunched while resolving');
    unlike(slurp("$dir/packages/solo.md"), qr/^status:\s*blocked/m, 'R1: not parked yet (judge is trying)');
    like(slurp("$dir/runs/orchestrator.log"), qr/resolve_fire/, 'R1: logged resolve_fire');
}

# ---- R2: a resolve RELAUNCH verdict gives a fresh budget + relaunch ----------
{
    my $dir = mk_bp([['solo','—','pending','p/s/']], { solo=>{attempt=>5,pid=>$DEAD,resolve_attempts=>1,status=>'running'} });
    BpOrch::mark_judge_inflight("$dir/runs",'resolve','solo',$NOW);
    seed_verdict($dir,'resolve','solo',{ action=>'relaunch', reason=>'corrected spec', mutated_files=>['p/s/x.pl'] });
    my $r = run_once($dir);
    is_deeply([map { $_->{pkg} } @{$r->{launched}}], ['solo'], 'R2: solo relaunched after the fix');
    is(reg_of($dir)->{solo}{attempt}, 0, 'R2: coordinator attempt budget reset to 0');
    ok(!defined BpOrch::judge_inflight("$dir/runs",'resolve','solo'), 'R2: resolve inflight cleared');
    ok(!-e BpOrch::judge_verdict_path("$dir/runs",'resolve','solo'), 'R2: verdict consumed');
    like(slurp("$dir/runs/orchestrator.log"), qr/resolve_relaunch/, 'R2: logged resolve_relaunch');
}

# ---- R3: a resolve PARK verdict parks the branch with the judge's question ---
{
    my $dir = mk_bp([['solo','—','pending','p/s/']], { solo=>{attempt=>5,pid=>$DEAD,resolve_attempts=>1,status=>'running'} });
    BpOrch::mark_judge_inflight("$dir/runs",'resolve','solo',$NOW);
    seed_verdict($dir,'resolve','solo',{ action=>'park', reason=>'ambiguous requirement', needs_you=>{question=>'Should X be Y or Z?', kind=>'ambiguous-requirement'} });
    my $r = run_once($dir);
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*blocked/m, 'R3: solo parked (blocked)');
    my @q = needs_you($dir);
    is(scalar @q, 1, 'R3: a decision queued');
    like($q[0]{question}, qr/Should X be Y or Z\?/, 'R3: the judge\'s own question is surfaced verbatim');
    is(scalar @{$r->{launched}}, 0, 'R3: not relaunched on park');
    like(slurp("$dir/runs/orchestrator.log"), qr/resolve_park/, 'R3: logged resolve_park');
}

# ---- R4: cap exhausted -> park directly, no resolve-judge spent --------------
{
    my $dir = mk_bp([['solo','—','pending','p/s/']], { solo=>{attempt=>5,pid=>$DEAD,resolve_attempts=>1,status=>'running'} });
    my $r = run_once($dir);   # resolve_cap defaults to 1, already spent
    is(scalar @{$r->{spawned}}, 0, 'R4: no resolve-judge fired past the cap');
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*blocked/m, 'R4: parked directly');
    is(scalar(needs_you($dir)), 1, 'R4: a decision queued');
}

# ---- R5: while a resolve-judge is in flight, the package is held (no relaunch,
#         no re-fire) ----------------------------------------------------------
{
    my $dir = mk_bp([['solo','—','pending','p/s/']], { solo=>{attempt=>5,pid=>$DEAD,resolve_attempts=>1,status=>'running'} });
    BpOrch::mark_judge_inflight("$dir/runs",'resolve','solo',$NOW);   # in flight, no verdict yet
    my $r = run_once($dir);
    is(scalar @{$r->{spawned}}, 0, 'R5: no second resolve-judge fired (already in flight)');
    is(scalar @{$r->{launched}}, 0, 'R5: not relaunched while the judge holds the ledger');
    unlike(slurp("$dir/packages/solo.md"), qr/^status:\s*blocked/m, 'R5: not parked while the judge is working');
    ok(defined BpOrch::judge_inflight("$dir/runs",'resolve','solo'), 'R5: still in flight');
}

# ---- T1: a crashed/hung judge (no verdict past the timeout) fails safe -------
{
    my $dir = mk_bp([['solo','—','pending','p/s/']], { solo=>{attempt=>5,pid=>$DEAD,resolve_attempts=>1,status=>'running'} });
    BpOrch::mark_judge_inflight("$dir/runs",'resolve','solo',$NOW-99999);   # fired long ago, never returned
    my $r = run_once($dir, tun => { judge_to=>10 });
    like(slurp("$dir/runs/orchestrator.log"), qr/judge_timeout/, 'T1: judge timeout detected');
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*blocked/m, 'T1: timed-out resolve fails safe to park');
    ok(!defined BpOrch::judge_inflight("$dir/runs",'resolve','solo'), 'T1: inflight cleared on timeout');
}

# ---- C1: a garbled (zero-length) inflight marker must NOT instant-timeout -----
{
    my $dir = mk_bp([['solo','—','pending','p/s/']], { solo=>{attempt=>5,pid=>$DEAD,resolve_attempts=>1,status=>'running'} });
    require File::Path; File::Path::make_path("$dir/runs/resolve");
    open my $m,'>',BpOrch::judge_inflight_path("$dir/runs",'resolve','solo') or die; close $m;  # zero-length -> epoch 0
    my $r = run_once($dir, tun => { judge_to=>10 });
    unlike(slurp("$dir/runs/orchestrator.log"), qr/judge_timeout/, 'C1: garbled marker (epoch 0) does NOT false-timeout');
    unlike(slurp("$dir/packages/solo.md"), qr/^status:\s*blocked/m, 'C1: package not parked on a garbled marker');
    ok(defined BpOrch::judge_inflight("$dir/runs",'resolve','solo'), 'C1: still treated as in flight (awaits a real verdict)');
}

# ---- C2: an inflight harvest judge keeps the run alive (no premature idle-exit
#         in audit mode, where a finished package is otherwise terminal) ---------
{
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    BpOrch::mark_judge_inflight("$dir/runs",'harvest','solo',$NOW);   # audit in flight, no verdict
    my $r = run_once($dir);
    unlike(slurp("$dir/runs/orchestrator.log"), qr/idle_exit/, 'C2: does not idle-exit while a harvest judge is in flight');
    ok(-e "$ROOT/busy.$bpn", 'C2: busy-lease kept while a judge runs');
    is(scalar @{$r->{spawned}}, 0, 'C2: no duplicate harvest fired (already in flight)');
}

# ---- H2: a persistently failing harvest spawn is bounded -> park + alarm -------
{
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    my $r = run_once($dir, tun => { judge_spawn_cap=>1 }, spawn_judge => sub { 1 });  # spawn always fails
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*blocked/m, 'H2: parked after the spawn-failure cap');
    my @q = needs_you($dir);
    is(scalar @q, 1, 'H2: a decision queued');
    is($q[0]{kind}, 'harvest-spawn-failure', 'H2: queued as a harvest-spawn-failure alarm');
    like(slurp("$dir/runs/orchestrator.log"), qr/judge_spawn_failed/, 'H2: logged the spawn failure');
}

done_testing();
