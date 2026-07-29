#!/usr/bin/env perl
# b09-judge-starvation-and-verdict-archive: harvest turn-budget scaling
# (BpJudge::harvest_max_turns), immediate starvation/crash detection
# (BpJudge::judge_liveness), the one-fresh-budget escalation ladder + the
# distinct `judge-starved` decision, sibling-red deferral
# (BpJudge::attribute_failures + BpJudge::audit_outcome's new `defer` arm),
# append-only verdict archiving (BpOrch::archive_judge_verdict), and the
# `judge_verdict_malformed` log event.
#
# ORACLE FILE: derived from the spec only. No implementation exists yet for
# any of BpJudge::harvest_max_turns / BpJudge::judge_liveness /
# BpJudge::attribute_failures / BpOrch::archive_judge_verdict /
# BpOrch::judge_terminal_verdict / BpOrch::harvest_initial_max_turns /
# BpOrch::_last_jsonl_obj_path — direct calls to those go through the SC()
# safe-caller below so a missing sub degrades to a clean `not ok`, never a
# die. Orchestrator-level ACs drive the real BpOrch::run({once=>1}) over a
# File::Temp fixture (mirrors t/10-judges.t's harness); since the CURRENT
# bp-orchestrator.pl never calls any of the new subs, those ticks run to
# completion under TODAY's logic and simply fail their new-behavior
# assertions naturally (no die) until the package is implemented.
#
# AC id -> test name mapping is mechanical: every assertion below is tagged
# "AC-N: ..." (or "AC-N(x): ..." for attribute_failures sub-cases). grep
# "AC-N:" to find every assertion for a given criterion. A few supplementary
# "PIN:" assertions pin literals (tunable defaults) beyond the 39 numbered
# ACs; they are not a substitute for any AC.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/../../scripts/bp-judge.pl";
require "$Bin/../../scripts/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;

# ===========================================================================
# Safe-call helpers: never let a call into a not-yet-defined sub die the file.
# ===========================================================================
sub has_sub {
    my ($fq) = @_;
    no strict 'refs';
    return defined &{$fq};
}
sub SC {
    my ($fq, @args) = @_;
    return undef unless has_sub($fq);
    no strict 'refs';
    my $r = eval { &{$fq}(@args) };
    if ($@) { diag("call to $fq died (guarded): $@"); return undef; }
    return $r;
}
# Run an external command via list-form open (never a shell, so quoting is
# a non-issue) and capture combined stdout + exit code.
sub run_capture {
    my (@cmd) = @_;
    open(my $ph, '-|', @cmd) or return (undef, -1);
    local $/;
    my $out = <$ph>;
    close $ph;
    my $rc = $? >> 8;
    return ($out, $rc);
}

my $JUDGE_PL = "$Bin/../../scripts/bp-judge.pl";
my $ORCH_PL  = "$Bin/../../scripts/bp-orchestrator.pl";
my $JUDGE_SH = "$Bin/../../scripts/bp-judge.sh";

# ===========================================================================
# Harness (mirrors t/10-judges.t's shape; reimplemented here since a test
# file cannot `require` another test script as a module).
# ===========================================================================
my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = time;
my $DEAD = 2_000_000_000;   # pinned dead-pid literal, per t/10-judges.t:115

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
# Own tunables builder (NOT a call into t/10-judges.t): pins the b09 defaults
# (harvest_reaudit_cap 2, judge_spawn_cap 3 — both pre-existing — and the NEW
# harvest_defer_cap 2, spec §2.4) on top of the base_tun shape.
sub my_tun {
    my %o = @_;
    return { ceil5=>85,ceil7=>90,drain=>600,max_par=>2,cap=>5,flat=>600,watch_tick=>0,
        keeper_int=>600,keeper_bo=>120,thresh_min=>60,jit_lo=>0,jit_hi=>0,tele_retry=>3,usage_fail=>60,
        busy_path=>"$ROOT/busy.$bpn", harvest=>'audit', resolve_cap=>1, corr_cap=>1, judge_to=>1800,
        judge_spawn_cap=>3, harvest_reaudit_cap=>2, harvest_defer_cap=>2, %o };
}
sub run_once {
    my ($dir, %o) = @_;
    my (@launched, @spawned);
    BpOrch::run({
        blueprint=>'T', bp_dir=>$dir, creds_path=>"$dir/creds.json",
        tunables=>($o{tunables} || my_tun(%{ $o{tun} || {} })),
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
sub seed_verdict { my ($dir,$kind,$pkg,$obj)=@_; my $f=BpOrch::judge_verdict_path("$dir/runs",$kind,$pkg); make_path("$dir/runs/$kind"); open my $w,'>',$f or die; print $w $J->encode($obj); close $w; }
# NEW scaffolding for this package: a judge's own pid file / stream log
# (runs/<kind>/<pkg>.pid, runs/<kind>/<pkg>.jsonl — spec §2.2 judge_pid_path /
# judge_log_path), written directly since bp-judge.sh is never actually run.
sub mk_pid_file { my ($dir,$kind,$pkg,$pid)=@_; make_path("$dir/runs/$kind"); open my $f,'>',"$dir/runs/$kind/$pkg.pid" or die; print $f $pid; close $f; }
sub mk_judge_jsonl { my ($dir,$kind,$pkg,$obj)=@_; make_path("$dir/runs/$kind"); open my $f,'>',"$dir/runs/$kind/$pkg.jsonl" or die; print $f $J->encode($obj)."\n"; close $f; }

# ===========================================================================
# BUDGET SCALING (Ruling 1 / DC5) — AC-1..AC-5
# ===========================================================================

ok(has_sub('BpJudge::harvest_max_turns'), 'AC-1: BpJudge::harvest_max_turns is defined');
for my $case ([1,28],[2,36],[3,44],[4,52],[5,60],[8,60]) {
    my ($n,$exp) = @$case;
    my $ws = join(':', map { "f$_.pl" } 1..$n);
    is(SC('BpJudge::harvest_max_turns', $ws, undef), $exp, "AC-1: harvest_max_turns union-size=$n -> $exp");
}
is(SC('BpJudge::harvest_max_turns', undef, undef), 28, 'AC-1: harvest_max_turns(undef,undef) -> 28');
is(SC('BpJudge::harvest_max_turns', '', ''),        28, "AC-1: harvest_max_turns('','') -> 28");
is(SC('BpJudge::harvest_max_turns', '—', '[]'),     28, "AC-1: harvest_max_turns('—','[]') -> 28");

is(SC('BpJudge::harvest_max_turns', 'a.pl:b.pl', 'b.pl'), 36, 'AC-2: harvest_max_turns de-dup union(a.pl:b.pl,b.pl) -> 36');
is(SC('BpJudge::harvest_max_turns', 'A:B:C:D', 'D'),      52, 'AC-2: harvest_max_turns union(A:B:C:D,D) -> 52');

{
    my ($out, $rc) = run_capture('perl', '-e',
        'require $ARGV[0]; print BpJudge::harvest_max_turns($ARGV[1],$ARGV[2])',
        $JUDGE_PL, 'p/a/', 'p/a/');
    (my $trimmed = $out // '') =~ s/\s+\z//;
    is($trimmed, '28', 'AC-3: the exact §2.6 one-liner prints 28 for write_set=test_paths=p/a/');
    is($rc, 0, 'AC-3: the exact §2.6 one-liner exits 0');
}

{
    my $sh = slurp($JUDGE_SH);
    unlike($sh, qr/BP_HARVEST_MAX_TURNS:-20/, 'AC-4: bp-judge.sh contains no flat BP_HARVEST_MAX_TURNS:-20 default');
    like($sh, qr/harvest_max_turns/, 'AC-4: bp-judge.sh references harvest_max_turns');
    like($sh, qr/\$\{BP_HARVEST_MAX_TURNS:-\}/, 'AC-4: bp-judge.sh still positions BP_HARVEST_MAX_TURNS as the override');
    like($sh, qr/BP_CONFORMANCE_MAX_TURNS:-40/, 'AC-4: BP_CONFORMANCE_MAX_TURNS:-40 unchanged');
    like($sh, qr/BP_RESOLVE_MAX_TURNS:-50/,     'AC-4: BP_RESOLVE_MAX_TURNS:-50 unchanged');
}

{
    my $has = has_sub('BpJudge::harvest_max_turns');
    my $bad = 0;
    if ($has) {
        for my $n (0..40) {
            my $ws = $n ? join(':', map { "g$_.pl" } 1..$n) : '';
            my $v = SC('BpJudge::harvest_max_turns', $ws, undef);
            $bad++ unless defined($v) && $v >= 28 && $v <= 60;
        }
    }
    ok($has && $bad == 0, 'AC-5: harvest_max_turns never <28 or >60 across union sizes 0..40');
}

# ===========================================================================
# IMMEDIATE STARVATION / CRASH DETECTION (Ruling 3 / DC1, DC2) — AC-6..AC-11
# ===========================================================================

ok(has_sub('BpJudge::judge_liveness'), 'AC-6: BpJudge::judge_liveness is defined');
{
    my @rows = (
        [{pid_present=>0, pid_alive=>0, terminal=>undef}, 'unknown', 'row1: pid-file missing -> unknown'],
        [{pid_present=>0, pid_alive=>1, terminal=>{verdict=>'max_turns'}}, 'unknown', 'row1: pid_present=0 dominates regardless of pid_alive/terminal -> unknown'],
        [{pid_present=>1, pid_alive=>1, terminal=>undef}, 'running', 'row2: alive -> running'],
        [{pid_present=>1, pid_alive=>0, terminal=>{verdict=>'max_turns'}}, 'starved', 'row3: dead + max_turns terminal -> starved'],
        [{pid_present=>1, pid_alive=>0, terminal=>{verdict=>'success'}}, 'crashed', 'row4: dead + success terminal (no verdict honoured) -> crashed'],
        [{pid_present=>1, pid_alive=>0, terminal=>{verdict=>'error'}}, 'crashed', 'row5: dead + error terminal -> crashed'],
        [{pid_present=>1, pid_alive=>0, terminal=>{verdict=>'unknown'}}, 'crashed', 'row6: dead + undecodable terminal -> crashed'],
    );
    for my $r (@rows) {
        my ($c, $exp, $desc) = @$r;
        is(SC('BpJudge::judge_liveness', $c), $exp, "AC-6: judge_liveness $desc");
    }
}

{
    my %ALLOWED = map { ($_=>1) } qw(starved crashed running unknown);
    for my $g (undef, [], 'x', {terminal=>'x'}, {pid_present=>1,pid_alive=>0,terminal=>[]}) {
        my $v = SC('BpJudge::judge_liveness', $g);
        ok(defined($v) && $ALLOWED{$v}, 'AC-7: judge_liveness(garbage) never dies, returns one of starved|crashed|running|unknown');
    }
    is(SC('BpJudge::judge_liveness', {pid_present=>1,pid_alive=>0,terminal=>[]}), 'crashed',
       'AC-7: dead pid + non-HASH terminal never reads as starved (coerced to unknown terminal -> crashed)');
}

# ---- AC-8: same-tick starvation detection (no wait for the wall clock) ----
{
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW);
    mk_pid_file($dir, 'harvest', 'solo', $DEAD);
    mk_judge_jsonl($dir, 'harvest', 'solo', { type=>'result', subtype=>'error_max_turns', num_turns=>29, session_id=>'s' });
    my $r = run_once($dir);
    my $log = slurp("$dir/runs/orchestrator.log");
    like($log, qr/"type":"judge_starved"/, 'AC-8: same-tick starvation logs judge_starved');
    unlike($log, qr/"type":"judge_timeout"/, 'AC-8: same-tick starvation does NOT wait for judge_to (no judge_timeout)');
}

# ---- AC-9: a crash (dead pid, no max_turns terminal) takes the reaudit path,
#      no widening ----
{
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW);
    mk_pid_file($dir, 'harvest', 'solo', $DEAD);
    mk_judge_jsonl($dir, 'harvest', 'solo', { type=>'result', subtype=>'error' });
    my $r = run_once($dir);
    my $log = slurp("$dir/runs/orchestrator.log");
    like($log, qr/"type":"judge_crashed"/, 'AC-9: same-tick crash detection logs judge_crashed');
    like($log, qr/"type":"harvest_reaudit"/, 'AC-9: crash takes the existing bounded re-audit path');
    my @h = grep { $_->{kind} eq 'harvest' && $_->{pkg} eq 'solo' } @{ $r->{spawned} };
    ok((@h == 1 && !exists $h[0]{max_turns}), 'AC-9: crash re-fire carries no max_turns key (crash != starvation, no widening)');
}

# ---- AC-10: alive pid -> nothing happens this tick, inflight untouched ----
{
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW);
    mk_pid_file($dir, 'harvest', 'solo', $$);
    mk_judge_jsonl($dir, 'harvest', 'solo', { type=>'result', subtype=>'error_max_turns', num_turns=>29 });
    my $r = run_once($dir);
    my $log = slurp("$dir/runs/orchestrator.log");
    unlike($log, qr/judge_starved/, 'AC-10: alive judge -> no judge_starved');
    unlike($log, qr/judge_crashed/, 'AC-10: alive judge -> no judge_crashed');
    unlike($log, qr/judge_timeout/, 'AC-10: alive judge -> no judge_timeout');
    is(scalar(grep { $_->{kind} eq 'harvest' } @{ $r->{spawned} }), 0, 'AC-10: alive judge -> no harvest judge fired');
    ok(defined BpOrch::judge_inflight("$dir/runs", 'harvest', 'solo'), 'AC-10: inflight marker left in place');
}

# ---- AC-11: no pid file -> today's wall-clock behavior unchanged ----
{
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW-99999);
    my $r = run_once($dir, tun => { judge_to=>10 });
    my $log = slurp("$dir/runs/orchestrator.log");
    like($log, qr/"type":"judge_timeout"/, 'AC-11: no pid file -> wall-clock judge_timeout still fires (unknown liveness falls through)');
    like($log, qr/"type":"harvest_reaudit"/, 'AC-11: no pid file -> today\'s re-audit path (T2 shape) still holds');
    is(reg_of($dir)->{solo}{harvest_reaudit}, 1, 'AC-11: re-audit counter is 1');
}

# ===========================================================================
# ONE FRESH BUDGET, EXEMPT FROM THE GIVE-UP CAP (Ruling 5 / DC2) — AC-12..AC-18
# ===========================================================================

is(BpOrch::widen_max_turns(28,28), 42, 'AC-12: widen_max_turns(28,28) == 42 (1-file starvation widening, pinned)');
is(BpOrch::widen_max_turns(60,60), 90, 'AC-12: widen_max_turns(60,60) == 90 (5-file starvation widening, pinned)');

{
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW);
    mk_pid_file($dir, 'harvest', 'solo', $DEAD);
    mk_judge_jsonl($dir, 'harvest', 'solo', { type=>'result', subtype=>'error_max_turns', num_turns=>29 });
    my $r1 = run_once($dir, tun => { harvest_reaudit_cap=>2 });
    my @h = grep { $_->{kind} eq 'harvest' && $_->{pkg} eq 'solo' } @{ $r1->{spawned} };
    is(scalar(@h), 1, 'AC-12: first starvation re-fires the harvest judge exactly once');
    is_deeply($h[0], { kind=>'harvest', pkg=>'solo', max_turns=>42 },
        'AC-12: re-fire spawn hash is {kind=>harvest,pkg=>solo,max_turns=>42} == widen_max_turns(28,28)');

    my $reg = reg_of($dir);
    is($reg->{solo}{harvest_starve_continuations}, 1, 'AC-13: registry harvest_starve_continuations == 1');
    is($reg->{solo}{harvest_max_turns}, 42, 'AC-13: registry harvest_max_turns == 42');
    is($reg->{solo}{harvest_reaudit}, 1, 'AC-13: registry harvest_reaudit == 1');
    ok(!($reg->{solo}{corrective_attempts}), 'AC-13: corrective_attempts absent/0');
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*done/m, 'AC-13: ledger still reads status: done');
    is(scalar(@{ $r1->{launched} }), 0, 'AC-13: no coordinator was launched');
    is(scalar(()=needs_you($dir)), 0, 'AC-13: runs/needs-you is empty');

    is(BpOrch::effective_attempts(1,1), 0, 'AC-14: effective_attempts(1,1) == 0 (mechanically: the exemption)');

    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW-99999);   # long past, no pid file this time
    my $r2 = run_once($dir, tun => { harvest_reaudit_cap=>2, judge_to=>10 });
    like(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_reaudit"/,
        'AC-14: a subsequent non-starvation timeout tick still re-audits (widened re-fire consumed none of the cap)');
    is(reg_of($dir)->{solo}{harvest_reaudit}, 2, 'AC-14: harvest_reaudit counter advances to 2 past the exempted starvation');
}

# ---- AC-15/16/17/18: second starvation escalates to a distinct decision ----
my ($AC15_dir, @AC15_q);
{
    my $dir = mk_bp([['solo','—','done','p/s/']], { solo=>{ harvest_starve_continuations=>1 } });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW);
    mk_pid_file($dir, 'harvest', 'solo', $DEAD);
    mk_judge_jsonl($dir, 'harvest', 'solo', { type=>'result', subtype=>'error_max_turns', num_turns=>29 });
    my $r = run_once($dir, tun => { harvest_reaudit_cap=>2 });
    my @q = needs_you($dir);
    is(scalar(@q), 1, 'AC-15: exactly one decision queued on the second starvation');
    is(($q[0]{kind} // ''), 'judge-starved', 'AC-15: decision kind == judge-starved');
    is(scalar(grep { $_->{kind} eq 'harvest' } @{ $r->{spawned} }), 0, 'AC-15: no harvest judge re-fired on the second starvation');
    is(scalar(@{ $r->{launched} }), 0, 'AC-15: no coordinator launched');
    is((reg_of($dir)->{solo}{harvest} // ''), 'starved', "AC-15: registry.packages.solo.harvest == 'starved'");
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*done/m, 'AC-15: ledger still reads status: done');
    ok(!-e "$dir/runs/.paused", 'AC-15: runs/.paused does not exist');
    ok(!(reg_of($dir)->{solo}{corrective_attempts}), 'AC-15: corrective_attempts absent/0');
    like(slurp("$dir/runs/orchestrator.log"), qr/"type":"judge_starved_park"/, 'AC-15: logged judge_starved_park');
    ($AC15_dir, @AC15_q) = ($dir, @q);
}
{
    my $q0 = $AC15_q[0] // {};
    like(($q0->{question} // ''), qr/did not complete/, 'AC-16: question says the audit did not complete');
    like(($q0->{question} // ''), qr/AUDIT/, 'AC-16: question names the AUDIT explicitly');
    like(($q0->{question} // ''), qr/BP_HARVEST_MAX_TURNS/, 'AC-16: question names the re-arm env var');
    unlike(($q0->{question} // ''), qr/fail/i, 'AC-16: question contains no case-insensitive match for fail');
    unlike(($q0->{context} // ''),  qr/fail/i, 'AC-16: context contains no case-insensitive match for fail');
    like(($q0->{context} // ''), qr/num_turns=29/, 'AC-16: context cites num_turns=29');
    like(($q0->{context} // ''), qr/No verdict file was ever written/, 'AC-16: context states no verdict file was ever written');
    unlike(($q0->{question} // ''), qr/GATE mode/, 'AC-18: audit-mode decision question does not mention GATE mode');
}
{
    my $r2 = run_once($AC15_dir, tun => { harvest_reaudit_cap=>2 });
    is(scalar(()=needs_you($AC15_dir)), 1, 'AC-17: a second tick over the parked state queues no additional decision (dedupe holds)');
    is(scalar(grep { $_->{kind} eq 'harvest' } @{ $r2->{spawned} }), 0, "AC-17: second tick fires no harvest judge (harvest=='starved' -> want_harvest_audit=0)");
}
{
    my $dirg = mk_bp([['solo','—','done','p/s/']], { solo=>{ harvest_starve_continuations=>1 } });
    BpOrch::mark_judge_inflight("$dirg/runs", 'harvest', 'solo', $NOW);
    mk_pid_file($dirg, 'harvest', 'solo', $DEAD);
    mk_judge_jsonl($dirg, 'harvest', 'solo', { type=>'result', subtype=>'error_max_turns', num_turns=>29 });
    run_once($dirg, tun => { harvest_reaudit_cap=>2, harvest=>'gate' });
    my @qg = needs_you($dirg);
    like((($qg[0]{question}) // ''), qr/GATE mode/, 'AC-18: gate-mode decision question additionally mentions GATE mode');
}

# ===========================================================================
# NO REGRESSION ON THE GENUINE PATH (DC3) — AC-19..AC-21
# ===========================================================================

{
    my $dir = mk_bp([['A','—','done','p/a/']], { A=>{status=>'done',corrective_attempts=>1} });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'fail', reason=>'still broken' });
    my $r = run_once($dir);
    my @q = needs_you($dir);
    is(scalar(@q), 1, 'AC-19: a genuine fail at the corrective cap queues exactly one decision');
    is(($q[0]{kind} // ''), 'harvest-failure', 'AC-19: decision kind == harvest-failure');
    like(slurp("$dir/packages/A.md"), qr/^status:\s*blocked/m, 'AC-19: ledger reads status: blocked');
    like(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_park"/, 'AC-19: logged harvest_park');
    is(scalar(grep { ($_->{kind}//'') eq 'judge-starved' } @q), 0, 'AC-19: no judge-starved record exists');
}
{
    my $dir = mk_bp([['A','—','done','p/a/']], { A=>{status=>'done',corrective_attempts=>0} });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'fail', failures=>['criterion X unmet at p/a/x.pl:3'], reason=>'own bug' });
    my $r = run_once($dir);
    like(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_reopen"/, 'AC-20: logged harvest_reopen');
    like(slurp("$dir/packages/A.md"), qr/^status:\s*pending/m, 'AC-20: ledger reads status: pending');
    is(reg_of($dir)->{A}{corrective_attempts}, 1, 'AC-20: corrective_attempts == 1');
    ok(!(reg_of($dir)->{A}{harvest_defer}), 'AC-20: harvest_defer absent/0 (a package\'s own red is never deferred)');
}
{
    is(BpJudge::audit_outcome({ verdict=>'pass' }), 'accept', 'AC-21: audit_outcome pass -> accept (verbatim t/10-judges.t:91)');
    is(BpJudge::audit_outcome({ verdict=>'fail', corrective_attempts=>0, corrective_cap=>1 }), 'reopen', 'AC-21: audit_outcome fail under cap -> reopen (verbatim :92)');
    is(BpJudge::audit_outcome({ verdict=>'fail', corrective_attempts=>1, corrective_cap=>1 }), 'park', 'AC-21: audit_outcome fail at cap -> park (verbatim :93)');
    is(BpJudge::audit_outcome({ verdict=>'error', corrective_attempts=>0 }), 'reopen', 'AC-21: audit_outcome error (non-pass) under default cap -> reopen (verbatim :94)');
    is(BpJudge::audit_outcome({ verdict=>'error', corrective_attempts=>1 }), 'park', 'AC-21: audit_outcome error at default cap -> park (verbatim :95)');
    is(BpJudge::audit_outcome({ verdict=>'fail', corrective_attempts=>0, deferrable=>0 }), 'reopen', 'AC-21: audit_outcome(fail,deferrable=>0) -> reopen (new shape, default byte-identical)');
}

# ===========================================================================
# SIBLING-RED DEFERRAL (Ruling 2 / DC6) — AC-22..AC-28
# ===========================================================================

ok(has_sub('BpJudge::attribute_failures'), 'AC-22: BpJudge::attribute_failures is defined');
{
    my $base = { package=>'A',
        failures=>['AC-26 forbids plugins/butler/templates/brief.md but it exists'],
        write_sets=>{ A=>'plugins/butler/scripts/bp-a.pl', B=>'plugins/butler/templates/brief.md' },
        status=>{ A=>'done', B=>'pending' } };
    is_deeply(SC('BpJudge::attribute_failures', $base), { attributable=>1, blockers=>['B'], unattributed=>[] },
        'AC-22: attribute_failures base case -> attributable=1, blockers=[B]');

    for my $case ([qw(done),    '(i)'],
                  [qw(blocked), '(ii)'],
                  [qw(parked),  '(iii)']) {
        my ($st, $tag) = @$case;
        my $c = { %$base, status=>{ A=>'done', B=>$st } };
        my $res = SC('BpJudge::attribute_failures', $c);
        is((($res || {})->{attributable}) // 1, 0, "AC-22$tag: attribute_failures attributable=0 when B status=$st (not LIVE)");
    }
    {
        my $c = { %$base, write_sets=>{
            A=>'plugins/butler/scripts/bp-a.pl:plugins/butler/templates/brief.md',
            B=>'plugins/butler/templates/brief.md' } };
        my $res = SC('BpJudge::attribute_failures', $c);
        is((($res || {})->{attributable}) // 1, 0, 'AC-22(iv): cited path also in A\'s own write_set disqualifies -> attributable=0');
    }
    {
        my $c = { %$base, failures=>[] };
        is_deeply(SC('BpJudge::attribute_failures', $c), { attributable=>0, blockers=>[], unattributed=>[] },
            'AC-22(v): empty failures -> {attributable=>0,blockers=>[],unattributed=>[]}');
    }
    {
        my $c = { %$base, failures=>[ @{ $base->{failures} }, 'unowned thing at some/other/path.pl' ] };
        my $res = SC('BpJudge::attribute_failures', $c);
        is((($res || {})->{attributable}) // 1, 0, 'AC-22(vi): a second failure citing an unowned path -> attributable=0');
        is_deeply((($res || {})->{unattributed}) // ['SENTINEL-UNIMPLEMENTED'], ['unowned thing at some/other/path.pl'],
            'AC-22(vi): unattributed names that failure string');
    }
}

is(BpJudge::audit_outcome({ verdict=>'fail', corrective_attempts=>0, corrective_cap=>1, deferrable=>1, defer_attempts=>0, defer_cap=>2 }), 'defer',
    'AC-23: audit_outcome(deferrable, under defer_cap) -> defer');
is(BpJudge::audit_outcome({ verdict=>'fail', corrective_attempts=>0, corrective_cap=>1, deferrable=>1, defer_attempts=>2, defer_cap=>2 }), 'reopen',
    'AC-23: audit_outcome(defer_cap exhausted, corrective budget remains) -> reopen');
is(BpJudge::audit_outcome({ verdict=>'fail', corrective_attempts=>1, corrective_cap=>1, deferrable=>1, defer_attempts=>2, defer_cap=>2 }), 'park',
    'AC-23: audit_outcome(defer_cap AND corrective_cap both exhausted) -> park');

# ---- AC-24: end-to-end AC-26-shape deferral ----
{
    my $dir = mk_bp([
        ['A','—','done',    'plugins/butler/scripts/bp-a.pl'],
        ['B','A','pending', 'plugins/butler/templates/brief.md'],
    ]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'fail',
        failures=>['AC-26 forbids plugins/butler/templates/brief.md but it exists'],
        reason=>'sibling artifact present' });
    my $r = run_once($dir, tun => { harvest_defer_cap=>2 });
    like(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_defer"/, 'AC-24: logged harvest_defer');
    like(slurp("$dir/packages/A.md"), qr/^status:\s*done/m, 'AC-24: A ledger still reads status: done');
    ok(!(reg_of($dir)->{A}{corrective_attempts}), 'AC-24: corrective_attempts absent/0');
    unlike(slurp("$dir/packages/A.md"), qr/Harvest findings \(re-verify\)/, 'AC-24: no findings block written into A.md');
    is(scalar(grep { $_->{pkg} eq 'A' } @{ $r->{launched} }), 0, 'AC-24: A was not launched');
    is(scalar(()=needs_you($dir)), 0, 'AC-24: runs/needs-you is empty');
    is((reg_of($dir)->{A}{harvest} // 'SENTINEL'), '', "AC-24: registry.packages.A.harvest == ''");
    is(reg_of($dir)->{A}{harvest_defer}, 1, 'AC-24: harvest_defer == 1');
    is((reg_of($dir)->{A}{harvest_defer_blockers} // ''), 'B', "AC-24: harvest_defer_blockers == 'B'");
}

# ---- AC-25: while the blocker remains live, section (c) does not re-fire and
#      logs no additional harvest_defer (self-contained fixture: pre-seeded
#      post-defer registry state, so this isolates the HOLD guard itself
#      rather than any incidental inflight lock from a prior tick) ----
{
    my $dir = mk_bp([
        ['A','—','done',    'plugins/butler/scripts/bp-a.pl'],
        ['B','A','pending', 'plugins/butler/templates/brief.md'],
    ], { A=>{ harvest=>'', harvest_defer=>1, harvest_defer_blockers=>'B' } });
    my $r = run_once($dir, tun => { harvest_defer_cap=>2 });
    is(scalar(grep { $_->{kind} eq 'harvest' && $_->{pkg} eq 'A' } @{ $r->{spawned} }), 0,
        'AC-25: harvest_defer_blockers names a still-pending B -> no harvest judge fired for A');
    unlike(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_defer"/,
        'AC-25: no additional harvest_defer logged (the endless re-audit cycle is broken, not merely slowed)');
}

# ---- AC-26: once every blocker is done, the guard lifts and the fire resumes ----
{
    my $dir = mk_bp([
        ['A','—','done', 'plugins/butler/scripts/bp-a.pl'],
        ['B','A','done', 'plugins/butler/templates/brief.md'],
    ], { A=>{ harvest=>'', harvest_defer=>1, harvest_defer_blockers=>'B' } });
    my $r = run_once($dir, tun => { harvest_defer_cap=>2 });
    is(scalar(grep { $_->{kind} eq 'harvest' && $_->{pkg} eq 'A' } @{ $r->{spawned} }), 1,
        'AC-26: with B done, the next tick fires exactly one harvest judge for A');
}

# ---- AC-27: deferral is bounded (defer_cap exhausted -> normal path) ----
{
    my $dir = mk_bp([
        ['A','—','done',    'plugins/butler/scripts/bp-a.pl'],
        ['B','A','pending', 'plugins/butler/templates/brief.md'],
    ], { A=>{ harvest_defer=>2 } });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'fail',
        failures=>['AC-26 forbids plugins/butler/templates/brief.md but it exists'],
        reason=>'sibling artifact present' });
    run_once($dir, tun => { harvest_defer_cap=>2 });
    like(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_reopen"/, 'AC-27: defer_cap exhausted -> normal harvest_reopen path taken instead');
    like(slurp("$dir/packages/A.md"), qr/^status:\s*pending/m, 'AC-27: ledger reads status: pending (deferral is bounded)');
}

# ---- AC-28: a later pass resets all four defer/starve fields; leaves harvest_max_turns ----
{
    my $dir = mk_bp([['A','—','done','p/a/']], { A=>{
        harvest_defer=>2, harvest_defer_blockers=>'B', harvest_starve_continuations=>1,
        harvest_reaudit=>2, harvest_max_turns=>42 } });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'pass' });
    run_once($dir);
    my $reg = reg_of($dir);
    is(($reg->{A}{harvest_defer} // 'X'), 0, 'AC-28: harvest_defer reset to 0 on pass');
    is(($reg->{A}{harvest_defer_blockers} // 'X'), '', 'AC-28: harvest_defer_blockers reset to \'\' on pass');
    is(($reg->{A}{harvest_starve_continuations} // 'X'), 0, 'AC-28: harvest_starve_continuations reset to 0 on pass');
    is(($reg->{A}{harvest_reaudit} // 'X'), 0, 'AC-28: harvest_reaudit reset to 0 on pass (existing :1468 behavior)');
    is($reg->{A}{harvest_max_turns}, 42, 'AC-28: harvest_max_turns is NOT reset, stays 42');
}

# ===========================================================================
# ARCHIVE (Ruling 6 / DC4) — AC-29..AC-36
# ===========================================================================

{
    my $dir = mk_bp([['A','—','done','p/a/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    my $vobj = { verdict=>'pass', extra=>'evidence-marker-29' };
    seed_verdict($dir, 'harvest', 'A', $vobj);
    run_once($dir, now=>sub{$NOW});
    my @arc = glob("$dir/runs/harvest/archive/A-*.verdict.json");
    is(scalar(@arc), 1, 'AC-29: exactly one file matches runs/harvest/archive/A-*.verdict.json');
    my $body = @arc ? $J->decode(slurp($arc[0])) : {};
    is(($body->{schema} // ''), 'judge-verdict-archive/1', 'AC-29: archive schema == judge-verdict-archive/1');
    is(($body->{kind} // ''), 'harvest', 'AC-29: archive kind == harvest');
    is(($body->{package} // ''), 'A', 'AC-29: archive package == A');
    is(($body->{source} // ''), 'runs/harvest/A.verdict.json', 'AC-29: archive source == runs/harvest/A.verdict.json');
    is_deeply($body->{verdict}, $vobj, 'AC-29: archive verdict deep-equals the seeded verdict object');
    ok(!-e BpOrch::judge_verdict_path("$dir/runs", 'harvest', 'A'), 'AC-29: live verdict file does not exist');
    is((reg_of($dir)->{A}{harvest} // ''), 'pass', "AC-29: registry.packages.A.harvest == 'pass'");
}

{
    my $dir = mk_bp([['A','—','done','p/a/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'pass', n=>1 });
    run_once($dir, now=>sub{$NOW});
    my @first = glob("$dir/runs/harvest/archive/A-*.verdict.json");
    is(scalar(@first), 1, 'AC-30: first consume creates one archive file');
    my $first_bytes = @first ? slurp($first[0]) : undef;

    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'pass', n=>2 });
    run_once($dir, now=>sub{$NOW});
    my @second = glob("$dir/runs/harvest/archive/A-*.verdict.json");
    is(scalar(@second), 2, 'AC-30: second consume in the same clock second yields a second archive file');
    is(scalar(grep { /-2\.verdict\.json$/ } @second), 1, 'AC-30: second archive file is suffixed -2.verdict.json');
    is((@first ? slurp($first[0]) : undef), $first_bytes, "AC-30: the first file's bytes are unchanged after the second consume");

    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'pass', n=>3 });
    run_once($dir, now=>sub{$NOW});
    my @third = grep { /-3\.verdict\.json$/ } glob("$dir/runs/harvest/archive/A-*.verdict.json");
    is(scalar(@third), 1, 'AC-30: a third consume yields -3.verdict.json (never overwrites, O_EXCL)');
}

{
    my $dir = mk_bp([['A','—','done','p/a/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'pass' });
    run_once($dir, now=>sub{$NOW});
    (my $ts = BpOrch::_iso($NOW)) =~ tr/://d;
    ok(-e "$dir/runs/harvest/archive/A-$ts.verdict.json", "AC-31: archived filename is exactly A-$ts.verdict.json (colon-stripped _iso(\$NOW))");
    unlike($ts, qr/:/, 'AC-31: the timestamp segment contains no colon');
}

{
    my $dir = mk_bp([['solo','—','pending','p/s/']], { solo=>{attempt=>5,pid=>$DEAD,resolve_attempts=>1,status=>'running'} });
    BpOrch::mark_judge_inflight("$dir/runs", 'resolve', 'solo', $NOW);
    seed_verdict($dir, 'resolve', 'solo', { action=>'relaunch', reason=>'corrected spec', mutated_files=>['p/s/x.pl'] });
    run_once($dir, now=>sub{$NOW});
    my @arc = glob("$dir/runs/resolve/archive/solo-*.verdict.json");
    is(scalar(@arc), 1, 'AC-32: a consumed resolve verdict lands in runs/resolve/archive/');
    my $body = @arc ? $J->decode(slurp($arc[0])) : {};
    is(($body->{kind} // ''), 'resolve', 'AC-32: archive kind == resolve');
    ok(!-e BpOrch::judge_verdict_path("$dir/runs", 'resolve', 'solo'), 'AC-32: live resolve verdict file gone (t/10-judges.t:261 still holds)');
}

{
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW-99999);
    run_once($dir, tun => { judge_to=>10 });
    ok((!-d "$dir/runs/harvest/archive" || !glob("$dir/runs/harvest/archive/*")),
        'AC-33: a timeout-only run archives nothing (a synthetic {_timeout=>1} is never archived)');
}

{
    my $dir = mk_bp([['A','—','done','p/a/']], { A=>{status=>'done',corrective_attempts=>0} });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    make_path("$dir/runs/harvest");
    open my $f, '>', "$dir/runs/harvest/A.verdict.json" or die; print $f '{not json'; close $f;
    run_once($dir, now=>sub{$NOW});
    my @arc = glob("$dir/runs/harvest/archive/A-*.verdict.json");
    is(scalar(@arc), 1, 'AC-34: a malformed verdict file is archived');
    my $body = @arc ? $J->decode(slurp($arc[0])) : {};
    ok(($body->{malformed} // 0), 'AC-34: archive malformed == true');
    like(($body->{raw} // ''), qr/\{not json/, 'AC-34: archive raw contains the malformed bytes');
    ok(!exists($body->{verdict}), 'AC-34: archive has no verdict key');
    ok(!-e BpOrch::judge_verdict_path("$dir/runs", 'harvest', 'A'), 'AC-34: live verdict file does not exist');
    like(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_reopen"/, 'AC-34: outcome unchanged — reopen under the corrective cap');

    # ---- AC-37: the malformed sentinel logs judge_verdict_malformed --------
    like(slurp("$dir/runs/orchestrator.log"), qr/"type":"judge_verdict_malformed"/, 'AC-37: malformed verdict tick logs judge_verdict_malformed');
    like(slurp("$dir/runs/orchestrator.log"), qr/"package":"A"/, 'AC-37: judge_verdict_malformed carries package A');
}
{
    my $dir = mk_bp([['A','—','done','p/a/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'pass' });
    run_once($dir);
    unlike(slurp("$dir/runs/orchestrator.log"), qr/judge_verdict_malformed/, 'AC-37: a normal pass consume does not log judge_verdict_malformed');
}

{
    ok(has_sub('BpOrch::archive_judge_verdict'), 'AC-35: BpOrch::archive_judge_verdict is defined');
    if (has_sub('BpOrch::archive_judge_verdict')) {
        my $dir = tempdir(CLEANUP=>1);
        make_path("$dir/runs");
        my $r1 = SC('BpOrch::archive_judge_verdict', "$dir/runs", 'harvest', 'Z', $NOW, undef);
        ok((!defined($r1) && !glob("$dir/runs/harvest/archive/*")),
            'AC-35: no live verdict file -> returns undef and creates no file');

        make_path("$dir/runs/harvest");
        open my $f, '>', "$dir/runs/harvest/Z.verdict.json" or die; print $f '{"verdict":"pass"}'; close $f;
        my $r2 = SC('BpOrch::archive_judge_verdict', "$dir/runs", 'harvest', 'Z', $NOW, undef);
        open my $f2, '>', "$dir/runs/harvest/Z.verdict.json" or die; print $f2 '{"verdict":"pass"}'; close $f2;
        my $r3 = SC('BpOrch::archive_judge_verdict', "$dir/runs", 'harvest', 'Z', $NOW, undef);
        my @arc = glob("$dir/runs/harvest/archive/Z-*.verdict.json");
        ok((defined($r2) && defined($r3) && $r2 ne $r3 && @arc == 2),
            'AC-35: two live-file calls with the same $now produce two files (second suffixed -2)');
    } else {
        ok(0, 'AC-35: BpOrch::archive_judge_verdict is not yet defined (no-live-file case)');
        ok(0, 'AC-35: BpOrch::archive_judge_verdict is not yet defined (append-only two-call case)');
    }
}

{
    my $sh = slurp($JUDGE_SH);
    my @lines = split /\n/, $sh;
    my ($arc_ln) = grep { $lines[$_] =~ /archive_judge_verdict/ } 0..$#lines;
    my ($rm_ln)  = grep { $lines[$_] =~ /rm -f "\$VERDICT_PATH"/ } 0..$#lines;
    ok((defined($arc_ln) && defined($rm_ln) && $arc_ln < $rm_ln),
        'AC-36: bp-judge.sh archives (archive_judge_verdict) on a line preceding rm -f "$VERDICT_PATH"');
    like($sh, qr/rm -f "\$VERDICT_PATH"/, 'AC-36: rm -f "$VERDICT_PATH" is still present');
}

# ===========================================================================
# SUITE SCOPING (SYN-11) — AC-38, AC-39
# ===========================================================================

{
    # Guard against infinite recursion: the nested self-invocation sets
    # BP_T61_SELFCHECK so the CHILD process skips re-spawning itself, while
    # still running every other assertion in this file top-to-bottom (a
    # single level of nesting, never deeper).
    unless ($ENV{BP_T61_SELFCHECK}) {
        local $ENV{BP_T61_SELFCHECK} = 1;
        my ($out, $rc) = run_capture('perl', $0);
        my $not_ok = () = (($out // '') =~ /^not ok/mg);
        is($rc, 0, 'AC-38: perl plugins/butler/tests/t/61-judge-starvation.t exits 0');
        is($not_ok, 0, 'AC-38: perl plugins/butler/tests/t/61-judge-starvation.t produces zero not-ok lines');
    }
    my ($out10, $rc10) = run_capture('perl', "$Bin/10-judges.t");
    my $not_ok10 = () = (($out10 // '') =~ /^not ok/mg);
    is($rc10, 0, 'AC-38: perl plugins/butler/tests/t/10-judges.t still exits 0');
    is($not_ok10, 0, 'AC-38: perl plugins/butler/tests/t/10-judges.t still produces zero not-ok lines');
}

{
    my $code = 'require $ARGV[0]; require $ARGV[1]; '
             . 'print((defined &BpJudge::harvest_max_turns && defined &BpJudge::judge_liveness '
             . '&& defined &BpJudge::attribute_failures && defined &BpOrch::archive_judge_verdict '
             . '&& defined &BpOrch::judge_terminal_verdict && defined &BpOrch::harvest_initial_max_turns '
             . '&& defined &BpOrch::_last_jsonl_obj_path) ? 1 : 0)';
    my ($out, $rc) = run_capture('perl', '-e', $code, $JUDGE_PL, $ORCH_PL);
    is($out, '1', 'AC-39: load check — every new sub is defined after a bare require');
}

# ===========================================================================
# PINNED LITERALS beyond the numbered ACs (task requirement: assert the exact
# values the spec pins, not a range).
# ===========================================================================

is(BpOrch::_tunables_base()->{harvest_defer_cap}, 2, 'PIN: _tunables_base gains harvest_defer_cap defaulting to 2 (spec §2.4)');
is(BpOrch::_tunables_base()->{harvest_reaudit_cap}, 2, 'PIN: harvest_reaudit_cap default remains 2 (pre-existing, unchanged)');
is(BpOrch::_tunables_base()->{judge_spawn_cap}, 3, 'PIN: judge_spawn_cap default remains 3 (pre-existing, unchanged)');

done_testing();
