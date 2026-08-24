#!/usr/bin/env perl
# e04-honest-terminal-reporting, AC1 (-> DC1): a crashed harvest judge (verdict
# 'error') must not be reported with the same operator text as a real failed
# verdict ('fail') -- byte-identical today, per
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/
# e04-honest-terminal-reporting-spec.md §2.1/§3(1)/§4 AC1/§7 edge case 1.
#
# TODAY'S WRONG REPORT (confirmed live against bp-orchestrator.pl:2968-2974
# while writing this test): the harvest-park branch queues ONE fixed question
# text regardless of whether $hv (BpJudge::normalize_harvest's result) is
# 'error' or 'fail':
#   "Package '$pkg' failed its harvest audit after a corrective relaunch --
#    its outputs don't meet the done-criteria. Inspect and decide: fix,
#    re-scope, or accept."
# This is FALSE for the 'error' case: no verdict was ever rendered, so nobody
# "inspected" anything and there is nothing that "doesn't meet the
# done-criteria" -- the whole sentence asserts an assessment that never
# happened. There is also no `harvest_error_count` field anywhere in
# bp-orchestrator.pl (grepped clean) to source a render-failure count from.
#
# Written BLIND to the eventual implementation shape (no `harvest_error_count`
# read/write logic exists yet to imitate) -- only against BpJudge::normalize_harvest
# / BpJudge::audit_outcome (already correct, tested in t/10-judges.t Part 1) and
# the spec's own required text shape.
#
# VACUITY GUARDS:
#   - error/fail text assertions are POSITIVE content checks (`like`/`unlike`
#     PAIRED with an exit/queue-count check first), never bare existence checks
#     on a value that could be undef -- `needs_you()` count is asserted ==1
#     before ever indexing into $q[0].
#   - the 'fail' control scenario asserts the text is BYTE-IDENTICAL to today's
#     string (a positive control that passes now AND after the fix -- if an
#     implementer's refactor accidentally also rewrites the 'fail' text, this
#     catches it).
#   - the counter assertions use a package name distinct per scenario so a
#     shared-registry bug (e.g. a global rather than per-package counter)
#     cannot hide behind fixture reuse.
#   - the "second render failure" scenario pre-seeds harvest_error_count=1 in
#     the registry and asserts it becomes exactly 2 (not "truthy" / not
#     "at least 1") -- catches an implementation that resets to 1 every time
#     instead of incrementing.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

require "$Bin/../../scripts/bp-judge.pl";
require "$Bin/../../scripts/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;

# ═══════════════════════════════════════════════════════════════════════════
# Scaffolding — lifted verbatim in shape from t/10-judges.t (house convention:
# a real BpOrch::run({once=>1}) tick against an on-disk fixture + stubbed judge
# spawn, no real `claude`).
# ═══════════════════════════════════════════════════════════════════════════
my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = time;
my $bpn  = 0;

sub write_creds {
    my ($p) = @_;
    open my $f, '>:raw', $p or die;
    print $f $J->encode({ claudeAiOauth => {
        accessToken=>'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken=>'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt=>($NOW+5*3600)*1000, scopes=>['user:inference'], subscriptionType=>'max', rateLimitTier=>'x' } });
    close $f;
}

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
sub needs_you {
    my $d = shift."/runs/escalations";
    return () unless -d $d;
    opendir my $h, $d or return ();
    my @j = map { JSON::PP->new->decode(slurp("$d/$_")) } grep { /\.json$/ } readdir $h;
    closedir $h;
    return @j;
}
sub seed_verdict {
    my ($dir, $kind, $pkg, $obj) = @_;
    my $f = BpOrch::judge_verdict_path("$dir/runs", $kind, $pkg);
    require File::Path; File::Path::make_path("$dir/runs/$kind");
    open my $w, '>', $f or die; print $w $J->encode($obj); close $w;
}

my $TODAYS_WRONG_TEXT_FRAGMENT = qr/don't meet the done-criteria/;

# ═══════════════════════════════════════════════════════════════════════════
# 1. FAIL control: a real 'fail' verdict at the corrective cap -> park with the
#    EXISTING, unchanged text (byte-identical control -- must pass both before
#    and after the fix; a regression here means the fix touched the wrong branch).
# ═══════════════════════════════════════════════════════════════════════════
{
    my $dir = mk_bp([['FAILPKG','—','done','p/f/']], { FAILPKG=>{status=>'done',corrective_attempts=>1} });
    BpOrch::mark_judge_inflight("$dir/runs",'harvest','FAILPKG',$NOW);
    seed_verdict($dir,'harvest','FAILPKG',{ verdict=>'fail', reason=>'still broken' });
    run_once($dir);
    my @q = needs_you($dir);
    is(scalar @q, 1, 'AC1/fail-control: exactly one decision queued') or diag(explain(\@q));
    is($q[0]{kind}, 'harvest-failure', 'AC1/fail-control: kind is harvest-failure');
    is($q[0]{question},
       "Package 'FAILPKG' failed its harvest audit after a corrective relaunch — its outputs don't meet the done-criteria. Inspect and decide: fix, re-scope, or accept.",
       'AC1/fail-control: fail-path question text is byte-identical to today (unchanged by the fix, spec §2.1)');
}

# ═══════════════════════════════════════════════════════════════════════════
# 2. ERROR case: a crashed/malformed judge (no `verdict` key at all --
#    BpJudge::normalize_harvest({}) => 'error', already pinned in t/10-judges.t)
#    at the corrective cap -> park.
#    THE DEFECT: today this produces the SAME text as the fail-control above
#    (confirmed live while writing this test). The fix must diverge it.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $dir = mk_bp([['ERRPKG','—','done','p/e/']], { ERRPKG=>{status=>'done',corrective_attempts=>1} });
    BpOrch::mark_judge_inflight("$dir/runs",'harvest','ERRPKG',$NOW);
    seed_verdict($dir,'harvest','ERRPKG',{});   # no verdict key -> normalize_harvest => 'error'
    run_once($dir);
    my @q = needs_you($dir);
    is(scalar @q, 1, 'AC1/error: exactly one decision queued') or diag(explain(\@q));
    is($q[0]{kind}, 'harvest-failure', 'AC1/error: kind is still harvest-failure (not a new kind, spec §2.1)');
    my $text = $q[0]{question} // '';
    unlike($text, $TODAYS_WRONG_TEXT_FRAGMENT,
        "AC1/error: question text does NOT claim the work \"doesn't meet the done-criteria\" — nobody assessed it "
      . "(fails today: the text is byte-identical to the fail-control above)");
    like($text, qr/\bnot\b.*\bassessed\b|\bnever\b.*\bassessed\b/i,
        'AC1/error: question text states the work has NOT been assessed (spec §2.1/§3(1))');
    like($text, qr/1\s*time\(s\)/,
        'AC1/error: question text names the render-failure count (1, the floor per spec §2.1 "floor 1: we are IN an error right now")');
    my $rec_after = reg_of($dir);
    is($rec_after->{ERRPKG}{harvest_error_count}, 1,
        'AC1/error: registry harvest_error_count is incremented to 1 (field does not exist at all today)');
}

# ═══════════════════════════════════════════════════════════════════════════
# 3. Counter must INCREMENT, not reset-and-restate: a package already at
#    harvest_error_count=1 that errors again at the cap must reach 2 and say so.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $dir = mk_bp([['ERR2PKG','—','done','p/e2/']],
        { ERR2PKG=>{status=>'done',corrective_attempts=>1,harvest_error_count=>1} });
    BpOrch::mark_judge_inflight("$dir/runs",'harvest','ERR2PKG',$NOW);
    seed_verdict($dir,'harvest','ERR2PKG',{ _malformed => 1 });   # still no `verdict` key -> error
    run_once($dir);
    my @q = needs_you($dir);
    is(scalar @q, 1, 'AC1/error-second: exactly one decision queued');
    like(($q[0]{question} // ''), qr/2\s*time\(s\)/,
        'AC1/error-second: question text names the ACCUMULATED count (2), not reset to 1');
    my $rec_after = reg_of($dir);
    is($rec_after->{ERR2PKG}{harvest_error_count}, 2,
        'AC1/error-second: registry harvest_error_count increments 1 -> 2 (not reset, not left at 1)');
}

# ═══════════════════════════════════════════════════════════════════════════
# 4. A pass must reset the counter to 0 (spec §2.1: "Reset to 0 alongside the
#    existing pass-path resets ... Never reset on 'fail'").
# ═══════════════════════════════════════════════════════════════════════════
{
    my $dir = mk_bp([['PASSPKG','—','done','p/p/']],
        { PASSPKG=>{status=>'done',harvest_error_count=>3} });
    BpOrch::mark_judge_inflight("$dir/runs",'harvest','PASSPKG',$NOW);
    seed_verdict($dir,'harvest','PASSPKG',{ verdict=>'pass' });
    run_once($dir);
    my $rec_after = reg_of($dir);
    is($rec_after->{PASSPKG}{harvest_error_count}, 0,
        'AC1/pass-resets: a pass verdict resets harvest_error_count to 0 (spec §2.1) -- field does not exist at all today');
}

# ═══════════════════════════════════════════════════════════════════════════
# 5. Edge case (spec §7 criterion 1): a 'fail' park must NEVER touch/create
#    harvest_error_count at all -- it is scoped entirely to the error path.
# ═══════════════════════════════════════════════════════════════════════════
{
    my $dir = mk_bp([['FAILNOCT','—','done','p/fn/']], { FAILNOCT=>{status=>'done',corrective_attempts=>1} });
    BpOrch::mark_judge_inflight("$dir/runs",'harvest','FAILNOCT',$NOW);
    seed_verdict($dir,'harvest','FAILNOCT',{ verdict=>'fail', reason=>'still broken' });
    run_once($dir);
    my $rec_after = reg_of($dir);
    ok(!exists($rec_after->{FAILNOCT}{harvest_error_count}) || !defined($rec_after->{FAILNOCT}{harvest_error_count}),
        'AC1/fail-untouched: a fail-path park never sets harvest_error_count at all (spec §7 edge case, criterion 1)');
}

done_testing();
