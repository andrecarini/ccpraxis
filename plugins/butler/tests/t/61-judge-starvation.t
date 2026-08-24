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
sub needs_you { my $d=shift."/runs/escalations"; return () unless -d $d; opendir my $h,$d; my @j=map { JSON::PP->new->decode(slurp("$d/$_")) } grep {/\.json$/} readdir $h; closedir $h; @j }
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
for my $case ([1,112],[2,144],[3,176],[4,208],[5,240],[8,240]) {
    my ($n,$exp) = @$case;
    my $ws = join(':', map { "f$_.pl" } 1..$n);
    is(SC('BpJudge::harvest_max_turns', $ws, undef), $exp, "AC-1: harvest_max_turns union-size=$n -> $exp");
}
is(SC('BpJudge::harvest_max_turns', undef, undef), 112, 'AC-1: harvest_max_turns(undef,undef) -> 112');
is(SC('BpJudge::harvest_max_turns', '', ''),        112, "AC-1: harvest_max_turns('','') -> 112");
is(SC('BpJudge::harvest_max_turns', '—', '[]'),     112, "AC-1: harvest_max_turns('—','[]') -> 112");

is(SC('BpJudge::harvest_max_turns', 'a.pl:b.pl', 'b.pl'), 144, 'AC-2: harvest_max_turns de-dup union(a.pl:b.pl,b.pl) -> 144');
is(SC('BpJudge::harvest_max_turns', 'A:B:C:D', 'D'),      208, 'AC-2: harvest_max_turns union(A:B:C:D,D) -> 208');

{
    my ($out, $rc) = run_capture('perl', '-e',
        'require $ARGV[0]; print BpJudge::harvest_max_turns($ARGV[1],$ARGV[2])',
        $JUDGE_PL, 'p/a/', 'p/a/');
    (my $trimmed = $out // '') =~ s/\s+\z//;
    is($trimmed, '112', 'AC-3: the exact §2.6 one-liner prints 112 for write_set=test_paths=p/a/');
    is($rc, 0, 'AC-3: the exact §2.6 one-liner exits 0');
}

{
    my $sh = slurp($JUDGE_SH);
    unlike($sh, qr/BP_HARVEST_MAX_TURNS:-20/, 'AC-4: bp-judge.sh contains no flat BP_HARVEST_MAX_TURNS:-20 default');
    like($sh, qr/harvest_max_turns/, 'AC-4: bp-judge.sh references harvest_max_turns');
    like($sh, qr/\$\{BP_HARVEST_MAX_TURNS:-\}/, 'AC-4: bp-judge.sh still positions BP_HARVEST_MAX_TURNS as the override');
    # RETARGETED 2026-08-04. These pinned the literal defaults 40 and 50, which
    # froze a TUNABLE in a sibling's oracle -- the same antipattern that had four
    # oracles pinning launcher.pl's poll cadence. What AC-4 protects is that each
    # judge kind still routes through an overridable env var, not what today's
    # number happens to be.
    like($sh, qr/\$\{BP_CONFORMANCE_MAX_TURNS:-\d+\}/, 'AC-4: conformance turns come from an overridable BP_CONFORMANCE_MAX_TURNS default');
    like($sh, qr/\$\{BP_RESOLVE_MAX_TURNS:-\d+\}/,     'AC-4: resolve turns come from an overridable BP_RESOLVE_MAX_TURNS default');
}

{
    my $has = has_sub('BpJudge::harvest_max_turns');
    my $bad = 0;
    if ($has) {
        for my $n (0..40) {
            my $ws = $n ? join(':', map { "g$_.pl" } 1..$n) : '';
            my $v = SC('BpJudge::harvest_max_turns', $ws, undef);
            $bad++ unless defined($v) && $v >= 112 && $v <= 240;
        }
    }
    ok($has && $bad == 0, 'AC-5: harvest_max_turns never <112 or >240 across union sizes 0..40');
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
    is_deeply($h[0], { kind=>'harvest', pkg=>'solo', max_turns=>168 },
        'AC-12: re-fire spawn hash is {kind=>harvest,pkg=>solo,max_turns=>168} == widen_max_turns(112,112)');

    my $reg = reg_of($dir);
    is($reg->{solo}{harvest_starve_continuations}, 1, 'AC-13: registry harvest_starve_continuations == 1');
    is($reg->{solo}{harvest_max_turns}, 168, "AC-13: registry harvest_max_turns == 168");
    is($reg->{solo}{harvest_reaudit}, 1, 'AC-13: registry harvest_reaudit == 1');
    ok(!($reg->{solo}{corrective_attempts}), 'AC-13: corrective_attempts absent/0');
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*done/m, 'AC-13: ledger still reads status: done');
    is(scalar(@{ $r1->{launched} }), 0, 'AC-13: no coordinator was launched');
    is(scalar(()=needs_you($dir)), 0, 'AC-13: runs/escalations is empty');

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
    is(scalar(()=needs_you($dir)), 0, 'AC-24: runs/escalations is empty');
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
        harvest_reaudit=>2, harvest_max_turns=>168 } });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict=>'pass' });
    run_once($dir);
    my $reg = reg_of($dir);
    is(($reg->{A}{harvest_defer} // 'X'), 0, 'AC-28: harvest_defer reset to 0 on pass');
    is(($reg->{A}{harvest_defer_blockers} // 'X'), '', 'AC-28: harvest_defer_blockers reset to \'\' on pass');
    is(($reg->{A}{harvest_starve_continuations} // 'X'), 0, 'AC-28: harvest_starve_continuations reset to 0 on pass');
    is(($reg->{A}{harvest_reaudit} // 'X'), 0, 'AC-28: harvest_reaudit reset to 0 on pass (existing :1468 behavior)');
    is($reg->{A}{harvest_max_turns}, 168, "AC-28: harvest_max_turns is NOT reset, stays 168");
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


# ===========================================================================
# STEP-7 REGRESSION GUARDS (added by the coordinator, 2026-07-30)
#
# These guard the step-7 fix-batch against silent reversion. They are NOT new
# acceptance criteria -- every AC above still stands unchanged. They exist
# because step 6 found two defects that a 168-assertion green suite could not
# see, and both are the kind that revert quietly.
#
# The first is the important one and it is deliberately a SOURCE-GREP, in the
# same style as AC-4 and AC-36 above. The default $spawn_judge closure cannot
# be exercised without spawning a real `claude`, and t/61 (by design, mirroring
# t/10-judges.t) always injects its own spawn_judge. That is exactly why the
# headline blocker survived an entire session undetected: the injected seam
# asserted the orchestrator->launcher CONTRACT (the max_turns payload key) and
# nothing at all asserted that the DEFAULT closure honours it. A source grep is
# the only hermetic way to assert the shipping path here.
# ===========================================================================
{
    my $orch = slurp($ORCH_PL);

    # -- item 8: the default closure must actually hand the widened budget to
    #    the child. Before the fix, BP_HARVEST_MAX_TURNS appeared in this file
    #    three times and NONE was a write, so the computed budget was dropped.
    like($orch, qr/local\s+\$ENV\{BP_HARVEST_MAX_TURNS\}\s*=/,
        'REGRESSION item 8: bp-orchestrator.pl WRITES $ENV{BP_HARVEST_MAX_TURNS} (widened budget reaches the child)');
    like($orch, qr/local\s+\$ENV\{BP_HARVEST_MAX_TURNS\}\s*=\s*\$mt\s*\n\s*if\s+\$a->\{kind\}\s+eq\s+'harvest'/,
        'REGRESSION item 8: the export is guarded on the harvest kind (spec 2.5 shape, not an unconditional local)');
    like($orch, qr/\$mt\s*=~\s*\/\^\\d\+\$\//,
        'REGRESSION item 8: the export validates max_turns as digits before trusting it');

    # -- the export must live INSIDE the default spawn closure, ahead of the
    #    system() that launches bp-judge.sh -- a `local` anywhere else would be
    #    out of scope by the time the child is spawned, i.e. green grep, dead code.
    my ($closure) = $orch =~ /\$opt->\{spawn_judge\}\s*\|\|\s*sub\s*\{(.*?)\n    \};/s;
    ok(defined $closure, 'REGRESSION item 8: the default spawn_judge closure is still locatable by pattern');
    like(($closure // ''), qr/local\s+\$ENV\{BP_HARVEST_MAX_TURNS\}/,
        'REGRESSION item 8: the export is INSIDE the default spawn_judge closure');
    if (defined $closure) {
        my $ienv = index($closure, 'local $ENV{BP_HARVEST_MAX_TURNS}');
        my $isys = index($closure, 'system(@cmd)');
        ok($ienv >= 0 && $isys > $ienv,
            'REGRESSION item 8: the export precedes system(@cmd), so it is in scope for the child');
    }

    # -- item 9: the second-starvation park must require a second starvation.
    #    Without the $hs >= 1 conjunct a FIRST starvation whose ordinary
    #    re-audit budget was already spent by unrelated crashes lands in the
    #    "ran out of turns twice ... on a widened one" branch, telling the
    #    operator a widen was tried when none ever was.
    like($orch, qr/\$jstate\s+eq\s+'starved'\s*&&\s*\$st\s+eq\s+'done'\s*&&\s*\$hs\s*>=\s*1/,
        'REGRESSION item 9: the second-starvation park is gated on $hs >= 1');

    # -- items 9+10 wording: neither park branch may tell an operator the
    #    package failed (done-criterion 1), and the first-starvation branch
    #    must not claim a widened retry happened.
    # COMMENTS STRIPPED. This is a PROXIMITY heuristic over raw source, and it
    # was matching a comment, not decision text: the %DECISION_VALIDITY block's
    # explanation of why judge-starved is deliberately absent from that table
    # sits within 400 characters of the DATA KEY 'harvest-failure'. Neither is
    # operator-facing wording, which is the only thing this assertion is about.
    #
    # Verified pre-existing -- the collision is present at b5e1a5d, before any of
    # 2026-08-24's work -- and it had turned the whole file red (5 not-ok,
    # because the file also re-runs itself and asserts its own exit code).
    #
    # %KIND_REGISTRY's own comment records that its key ORDER was arranged to
    # dodge this same heuristic. That is the tell: when source has to be laid out
    # to avoid an oracle, the oracle is reading the wrong thing. Stripping
    # comments fixes the class instead of rearranging around it.
    #
    # Same defect as t/26's backtick scan, t/65, t/66, t/115 and t/145.
    (my $orch_code = $orch) =~ s/^\s*#.*$//mg;
    unlike($orch_code, qr/judge-starved[\s\S]{0,400}?\bfail(?:ed|ure|s)?\b/i,
        'REGRESSION items 9+10: no judge-starved decision text says the package failed');
}

{
    # -- item 1 (CRITICAL, batch 1): want_harvest_gate must withhold a re-fire
    #    for ANY non-empty harvest value, not only 'pass'. The starvation park
    #    writes harvest => 'starved' precisely so the audit stops re-firing;
    #    with the old `eq 'pass'` test, GATE mode re-spawned a real judge every
    #    tick forever and nothing bounded it (judge_spawn_cap counts only
    #    spawns that FAIL to launch).
    is(BpJudge::want_harvest_gate({ mode=>'gate', status=>'done', harvest=>'starved' }), 0,
        'REGRESSION item 1: gate mode does NOT re-fire a judge for harvest => starved');
    is(BpJudge::want_harvest_gate({ mode=>'gate', status=>'done', harvest=>'pass' }), 0,
        'REGRESSION item 1: gate mode still withholds on pass (unchanged)');
    is(BpJudge::want_harvest_gate({ mode=>'gate', status=>'done', harvest=>'' }), 1,
        'REGRESSION item 1: gate mode still FIRES on an empty harvest (no over-correction)');
    is(BpJudge::want_harvest_gate({ mode=>'gate', status=>'done' }), 1,
        'REGRESSION item 1: gate mode still fires when harvest is absent entirely');

    # -- item 2 (batch 1): attribution is AND-over-tokens, so one sibling-owned
    #    path in a multi-path failure string cannot launder a genuine red.
    my $ws = { A => 'plugins/butler/scripts/bp-a.pl', B => 'plugins/butler/templates/brief.md' };
    my $st = { A => 'done', B => 'pending' };
    my $ok1 = BpJudge::attribute_failures({ package=>'A', write_sets=>$ws, status=>$st,
        failures=>['AC-26 forbids plugins/butler/templates/brief.md but it exists'] });
    is($ok1->{attributable}, 1,
        'REGRESSION item 2: a single live-sibling-owned path is still attributable (b05/b07 shape preserved)');
    my $bad = BpJudge::attribute_failures({ package=>'A', write_sets=>$ws, status=>$st,
        failures=>['not ok 4 - plugins/butler/templates/brief.md and plugins/butler/scripts/unowned.pl both wrong'] });
    is($bad->{attributable}, 0,
        'REGRESSION item 2: a sibling path PLUS an unowned path is NOT attributable (no laundering)');
    my $own = BpJudge::attribute_failures({ package=>'A', write_sets=>$ws, status=>$st,
        failures=>['not ok 5 - plugins/butler/templates/brief.md vs plugins/butler/scripts/bp-a.pl'] });
    is($own->{attributable}, 0,
        'REGRESSION item 2: a sibling path PLUS the audited package own file is NOT attributable');

    # -- item 3 (batch 1): path normalisation, without weakening the boundary
    #    guard that stops foo/bar owning foo/bar2.
    ok(BpJudge::_owns('plugins/butler/templates/brief.md', '/project/plugins/butler/templates/brief.md'),
        'REGRESSION item 3: an absolute cited path matches a relative write-set entry');
    ok(!BpJudge::_owns('foo/bar', 'foo/bar2'),
        'REGRESSION item 3: the trailing-slash boundary still stops foo/bar owning foo/bar2');
    ok(!BpJudge::_owns('a/bp-judge', 'a/bp-judge.pl'),
        'REGRESSION item 3: a/bp-judge still does not own a/bp-judge.pl');
}

{
    # -- items 4/5/6 (batch 1, bp-judge.sh): all three are shell-side and are
    #    asserted by source grep, as AC-4/AC-36 above already do for this file.
    my $sh = slurp($JUDGE_SH);

    # item 4: the archive failure must be observable, and the rm must stay
    # unconditional (gating it would let a stale verdict be read as fresh --
    # a false pass, which the package's scope forbids outright).
    like($sh, qr/orchestrator\.log/,
        'REGRESSION item 4: the archive step routes diagnostics to orchestrator.log, not /dev/null');
    unlike($sh, qr{>/dev/null 2>&1 \|\| true\s*\nrm -f},
        'REGRESSION item 4: the archive no longer discards all diagnostics immediately before the rm');
    like($sh, qr/rm -f "\$VERDICT_PATH"/,
        'REGRESSION item 4: rm -f "$VERDICT_PATH" remains UNCONDITIONAL (stale verdicts must never be re-read as fresh)');

    # item 5: the BP_HARVEST_MAX_TURNS override must be validated too, not just
    # the computed value -- this package's own decision text tells an operator
    # to raise that variable, so a bad value there is directly reachable.
    like($sh, qr/case "\$MAXT" in[^\n]*\|0\)/,
        'REGRESSION item 5: the MAXT sanity guard rejects 0 as well as non-numeric');

    # item 6: a re-fire must not destroy the previous judge stream log, because
    # the starvation-park decision tells the operator to read exactly that file.
    like($sh, qr/\$PKG\.\$n\.jsonl|\$PKG\.\d+\.jsonl/,
        'REGRESSION item 6: an existing judge jsonl is rotated to a numbered backup rather than truncated');
}

# ===========================================================================
# ITEM 14 / ITEM 15 REGRESSION GUARDS (added by the coordinator, 2026-08-03)
#
# b09's step-7 batch 2b landed items 11-13 and then died on its turn cap
# mid-item-14; items 14 and 15 (both HIGH from the package's own step-6
# red-team) were specified in full in this package's ## Next action and
# implemented in a later session. These guards are NOT new acceptance
# criteria -- every AC and STEP-7 guard above stands unchanged. Conventions
# follow the STEP-7 block above: positive assertion before every negative
# one, no SKIP gated on the failure state, every count re-grepped from disk
# rather than trusted from ledger prose (the ledger's own item-14/15 counts
# drifted mid-session for exactly that reason).
# ===========================================================================

require POSIX;

# ---- shared harness for item 15: forwards the pid_alive / judge_pid_identity_ok
#      seams that run_once (above) does not, since it predates this package's
#      item 15 work.
sub run_seams {
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
        pid_alive => $o{pid_alive},
        judge_pid_identity_ok => $o{judge_pid_identity_ok},
    });
    return { launched=>\@launched, spawned=>\@spawned };
}

# A harmless, session-leading dummy process this test can safely signal: it
# only sleeps, touches nothing, and is its own process group (setsid) so
# kill_pid's `kill SIG, -$pid` (the whole GROUP) can never reach anything
# else. POSIX::_exit bypasses Perl's normal exit path (END blocks, DESTROY,
# Test::More's own plan bookkeeping) so the fork never emits stray TAP output.
sub spawn_dummy_judge {
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        eval { POSIX::setsid() };
        sleep 60;
        POSIX::_exit(0);
    }
    return $pid;
}
sub pid_gone_within {
    my ($pid, $secs) = @_;
    # A killed-but-unreaped child is a zombie: plain kill(0,...) still reports
    # it as present, so use the same zombie-aware liveness check production
    # uses (BpOrch::pid_alive) rather than a raw signal probe.
    for (1 .. int($secs*20)) {
        return 1 unless BpOrch::pid_alive($pid);
        select(undef, undef, undef, 0.05);
    }
    return !BpOrch::pid_alive($pid);
}
# Best-effort cleanup: never leave a sleeping dummy behind, whether or not the
# assertions around it passed.
sub reap_dummy {
    my ($pid) = @_;
    return unless defined $pid;
    kill('KILL', $pid) if kill(0, $pid);
    waitpid($pid, 0);
}

# ---------------------------------------------------------------------------
# ITEM 14a: mark_judge_inflight's discarded return -> unbounded refire. The
# defect: a failed marker write (full/read-only runs/) leaves a judge running
# but unmarked, so the next tick sees inflight=>0 and fires ANOTHER judge,
# every tick, unbounded, because $rc==0 each time never trips the ordinary
# spawn-fail cap. Guarded at all FIVE mark_judge_inflight call sites by
# routing a failed marker through that site's existing cap-bounded fail path.
# End-to-end proof on ONE representative site (the ordinary harvest-fire path,
# bp-orchestrator.pl ~:2444-2467) plus a source check that the same routing
# literal appears once per call site (so a site silently dropping the routing
# would be caught by the count, not just by this one behavioral path).
# ---------------------------------------------------------------------------
{
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    make_path("$dir/runs/harvest");
    # Block EVERY future mark_judge_inflight rename for this package:
    # rename(2) onto an existing directory always fails (EISDIR) regardless
    # of uid/permissions, so this is deterministic even running as root,
    # unlike a chmod-based trick.
    mkdir("$dir/runs/harvest/solo.inflight") or die "mkdir: $!";

    my $r1 = run_seams($dir, tun => { judge_spawn_cap => 2 });
    is(scalar(grep { $_->{kind} eq 'harvest' && $_->{pkg} eq 'solo' } @{ $r1->{spawned} }), 1,
        'ITEM 14a: tick 1 fires the harvest judge (positive: the spawn actually happens)');
    # canonical JSON key order is alphabetical, not insertion order, so "rc"
    # sorts BEFORE "type" -- check the fields, not an assumed order.
    my ($sf1_line) = grep { /"type":"judge_spawn_failed"/ } split /\n/, slurp("$dir/runs/orchestrator.log");
    ok(defined $sf1_line, 'ITEM 14a: tick 1 logs judge_spawn_failed (routed as a spawn failure, not swallowed)');
    like(($sf1_line // ''), qr/"rc":"inflight_marker_failed"/,
        'ITEM 14a: ...with rc inflight_marker_failed');
    is(reg_of($dir)->{solo}{harvest_spawn_fail}, 1,
        'ITEM 14a: harvest_spawn_fail counted to 1 even though $rc==0 (the cap-bounding fix)');
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*done/m,
        'ITEM 14a: tick 1 -- package not yet parked (cap not reached)');
    is(scalar(()=needs_you($dir)), 0, 'ITEM 14a: tick 1 -- no decision queued yet');

    my $r2 = run_seams($dir, tun => { judge_spawn_cap => 2 });
    is(scalar(grep { $_->{kind} eq 'harvest' && $_->{pkg} eq 'solo' } @{ $r2->{spawned} }), 1,
        'ITEM 14a: tick 2 fires the harvest judge again (still under cap)');
    is(reg_of($dir)->{solo}{harvest_spawn_fail}, 2, 'ITEM 14a: harvest_spawn_fail advances to 2 (== cap)');
    like(slurp("$dir/packages/solo.md"), qr/^status:\s*blocked/m,
        'ITEM 14a: tick 2 -- cap reached -> package PARKED, not silently retried forever');
    is(scalar(()=needs_you($dir)), 1, 'ITEM 14a: tick 2 -- exactly one decision queued at the cap');

    my $r3 = run_seams($dir, tun => { judge_spawn_cap => 2 });
    is(scalar(grep { $_->{kind} eq 'harvest' && $_->{pkg} eq 'solo' } @{ $r3->{spawned} }), 0,
        'ITEM 14a: tick 3 -- NO further harvest judge fired (the unbounded-refire defect does NOT happen)');
}
{
    my $orch = slurp($ORCH_PL);
    my $n_sites  = () = ($orch =~ /mark_judge_inflight\(\$runs,/g);
    my $n_routed = () = ($orch =~ /'inflight_marker_failed'/g);
    # THE INVARIANT IS THE 1:1 PAIRING, not the literal five.
    #
    # The defect this guards is a mark_judge_inflight call site whose failed
    # return is discarded: the judge runs unmarked, the next tick sees
    # inflight=>0 and fires another, forever, because $rc==0 never trips the
    # spawn-fail cap. What proves that cannot happen is that EVERY call site has
    # a matching 'inflight_marker_failed' route -- a property that holds at five
    # sites, six, or twenty.
    #
    # Pinning the literal 5 made ADDING a correctly-guarded judge kind a
    # regression. There have been six sites since escalation-resolve was added,
    # and this assertion has been red for it -- verified pre-existing at
    # b5e1a5d, before 2026-08-24's work. Being red for a correct change is how
    # an oracle stops being read.
    #
    # A floor plus the equality keeps both halves: sites cannot be LOST (which
    # would mean a guard was deleted), and none can go unrouted.
    cmp_ok($n_sites, '>=', 5,
        'ITEM 14a: at least the original five mark_judge_inflight($runs, ...) call sites remain '
      . '(re-grepped, not trusted from ledger prose) -- losing one means a guard was deleted');
    is($n_routed, $n_sites,
        "ITEM 14a: EVERY call site routes a failed marker through 'inflight_marker_failed' "
      . "(1:1 with the call-site count, whatever that count is) -- an unrouted site is the "
      . "unbounded-refire defect");
}

# ---------------------------------------------------------------------------
# ITEM 14b: mark_judge_inflight must check print/close, not only open/rename.
# Its own comment used to claim temp+rename made a zero-length marker
# impossible; that is false under ENOSPC, where the write fails at
# print/close but the (empty) tmp file still exists to be renamed atomically
# into place. Simulated via /dev/full, which always fails writes with
# ENOSPC -- no need for an actually-full disk or a root-defeating chmod.
# ---------------------------------------------------------------------------
{
    ok(-e '/dev/full', 'ITEM 14b: precondition -- /dev/full exists on this host (ENOSPC simulator)');

    # Positive first: an ordinary call actually marks inflight (proves the
    # sub still works at all before we go looking for its failure path).
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    my $ok = BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'good', $NOW);
    ok($ok, 'ITEM 14b: a normal mark_judge_inflight call returns true');
    ok(-e BpOrch::judge_inflight_path("$dir/runs", 'harvest', 'good'), 'ITEM 14b: ...and creates the live marker file');
    is(BpOrch::judge_inflight("$dir/runs", 'harvest', 'good'), $NOW, 'ITEM 14b: ...with the correct stored epoch');

    # Negative: force the print-or-close half of the write to fail. The tmp
    # path is deterministic ("$f.tmp.$$") since this call runs in-process (no
    # fork), so $$ is known ahead of time -- pre-seed a symlink there
    # pointing at /dev/full before calling the sub.
    make_path("$dir/runs/harvest");
    my $f   = BpOrch::judge_inflight_path("$dir/runs", 'harvest', 'bad');
    my $tmp = "$f.tmp.$$";
    symlink('/dev/full', $tmp) or die "symlink: $!";
    my $rc = BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'bad', $NOW);
    is($rc, 0, 'ITEM 14b: mark_judge_inflight returns 0 when the write fails at print/close (ENOSPC), not just open/rename');
    ok(!-e $f, 'ITEM 14b: no zero-length marker was renamed into place -- the live path does not exist at all');
    ok(!-e $tmp && !-l $tmp, 'ITEM 14b: the tmp symlink was cleaned up (unlinked), not left behind');
}

# ---------------------------------------------------------------------------
# ITEM 15: the three judge kill sites must verify pid IDENTITY before
# signalling a process GROUP, because `.pid`/`.inflight` deliberately survive
# an orchestrator restart while a fresh container restarts the pid namespace
# -- a recycled number can belong to the token keeper, a sibling coordinator,
# or a socat bridge (SYN-19 records a real truncated-ledger instance from
# exactly this). Proven on real (harmless, session-led, sleeping) child
# processes so "was it actually killed" is an observable OS fact rather than
# an inference -- kill_pid itself is deliberately NOT injectable (shared with
# b01/b11 coordinator callers), so the seam under test is
# judge_pid_identity_ok, exactly as this package's Next action specifies.
# ---------------------------------------------------------------------------
{
    # Positive: identity check PASSES -> the judge pid IS killed.
    my $good_pid = spawn_dummy_judge();
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW - 99999);   # old marker -> wall-clock timeout path
    mk_pid_file($dir, 'harvest', 'solo', $good_pid);
    ok(kill(0, $good_pid), 'ITEM 15: precondition -- the dummy judge process is alive before the tick');
    run_seams($dir, tun => { judge_to => 10 },
        pid_alive => sub { my $p = shift; return $p == $good_pid ? 1 : BpOrch::pid_alive($p) },
        judge_pid_identity_ok => sub { 1 });
    ok(pid_gone_within($good_pid, 2), 'ITEM 15: identity_ok=>1 -> kill_pid actually terminated the (real) process group');
    reap_dummy($good_pid);
}
{
    # Negative: identity check FAILS (recycled-pid shape) -> NOT killed, and
    # the refusal is logged so an operator can see why nothing happened.
    my $bad_pid = spawn_dummy_judge();
    my $dir = mk_bp([['solo','—','done','p/s/']]);
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW - 99999);
    mk_pid_file($dir, 'harvest', 'solo', $bad_pid);
    ok(kill(0, $bad_pid), 'ITEM 15: precondition -- the dummy judge process is alive before the tick');
    run_seams($dir, tun => { judge_to => 10 },
        pid_alive => sub { my $p = shift; return $p == $bad_pid ? 1 : BpOrch::pid_alive($p) },
        judge_pid_identity_ok => sub { 0 });
    # zombie-aware, not a plain kill(0,...): a killed-but-unreaped child still
    # answers kill(0,...) truthfully as "present" (it's a zombie, not gone),
    # which would silently hide a bypassed identity check -- caught by the
    # mutation audit below, which is why this is BpOrch::pid_alive and not a
    # raw signal probe.
    ok(BpOrch::pid_alive($bad_pid), 'ITEM 15: identity_ok=>0 -> the process is NOT killed (still genuinely alive, not a zombie, after the tick)');
    my ($refusal_line) = grep { /"type":"judge_kill_refused"/ } split /\n/, slurp("$dir/runs/orchestrator.log");
    ok(defined $refusal_line, 'ITEM 15: a judge_kill_refused event was logged');
    like(($refusal_line // ''), qr/"pid":"?$bad_pid"?\b/, 'ITEM 15: ...naming the refused pid');
    reap_dummy($bad_pid);
}
{
    # Source check: exactly three judge-site kill_pid($jp2) calls remain,
    # each still gated on judge_pid_identity_ok and each with a paired
    # judge_kill_refused log line on the refusal branch -- re-grepped here
    # rather than trusted from ledger prose, per the ledger's own warning
    # that this exact count drifted once already this session.
    my $orch = slurp($ORCH_PL);
    my $n_kill    = () = ($orch =~ /kill_pid\(\$jp2\)/g);
    my $n_guarded = () = ($orch =~ /if\s*\(\s*\$judge_pid_identity_ok->\(\$jp2,\s*\$jpidf\)\s*\)\s*\{/g);
    my $n_refused = () = ($orch =~ /judge_kill_refused/g);
    is($n_kill, 3, 'ITEM 15: exactly three kill_pid($jp2) judge sites remain');
    is($n_guarded, 3, 'ITEM 15: all three are gated on judge_pid_identity_ok($jp2, $jpidf)');
    is($n_refused, 3, 'ITEM 15: all three carry a paired judge_kill_refused log line on refusal');
}

done_testing();
