#!/usr/bin/env perl
# A7 unblock: bp-answer-decision.pl — the mechanical, atomic unblock the reporter
# runs once a human has answered a runs/needs-you/ decision. Part 1 exhausts the
# pure plan_answer/kind_family matrix (per-kind allowed actions, fail-closed on a
# bad pair). Part 2 drives the CLI end-to-end against a temp blueprint dir: a
# package park relaunch/accept/drop and a fleet-pause resume, asserting the ledger
# status, the corrective note, the registry reset, the pause clear, and the queue
# entry deletion.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $script = "$Bin/../../scripts/bp-answer-decision.pl";
require $script;   # also loads BpOrch (the CLI requires bp-orchestrator.pl)

my $J = JSON::PP->new->canonical;

# ===========================================================================
# PART 1 — pure plan_answer / kind_family
# ===========================================================================

is(BpAnswer::kind_family('reauth'),         'fleet',   'kind_family: reauth -> fleet');
is(BpAnswer::kind_family('contract-drift'), 'fleet',   'kind_family: contract-drift -> fleet');
is(BpAnswer::kind_family('stuck-package'),  'package', 'kind_family: stuck-package -> package');
is(BpAnswer::kind_family('harvest-failure'),'package', 'kind_family: harvest-failure -> package');
is(BpAnswer::kind_family('harvest-spawn-failure'),'package','kind_family: harvest-spawn-failure -> package');
is(BpAnswer::kind_family(undef),            'package', 'kind_family: undef -> package (conservative)');

# package: default action relaunch
{
    my $p = BpAnswer::plan_answer('stuck-package', undef);
    ok($p->{ok}, 'plan: stuck-package default ok');
    is($p->{action}, 'relaunch',      'plan: default action is relaunch');
    is($p->{ledger_status}, 'pending','plan: relaunch -> ledger pending');
    is($p->{relaunch}, 1,             'plan: relaunch flag set');
    is($p->{reset_attempt}, 1,        'plan: relaunch resets the attempt budget');
    is($p->{clear_pause}, 0,          'plan: package never clears the fleet pause');
}
is(BpAnswer::plan_answer('stuck-package','accept')->{ledger_status}, 'done',    'plan: accept -> done');
is(BpAnswer::plan_answer('stuck-package','accept')->{relaunch},      0,         'plan: accept does not relaunch');
is(BpAnswer::plan_answer('harvest-failure','drop')->{ledger_status}, 'dropped', 'plan: drop -> dropped');
{
    my $bad = BpAnswer::plan_answer('stuck-package','frobnicate');
    is($bad->{ok}, 0, 'plan: unknown package action -> not ok');
    like($bad->{error}, qr/relaunch\|accept\|drop/, 'plan: error lists the valid actions');
}

# fleet: default resume; anything else rejected
{
    my $p = BpAnswer::plan_answer('reauth', undef);
    ok($p->{ok}, 'plan: reauth default ok');
    is($p->{action}, 'resume',  'plan: fleet default action is resume');
    is($p->{clear_pause}, 1,    'plan: resume clears the pause');
    is($p->{ledger_status}, undef, 'plan: fleet touches no ledger');
}
is(BpAnswer::plan_answer('contract-drift', undef)->{action}, 'resume', 'plan: contract-drift -> resume');
{
    my $bad = BpAnswer::plan_answer('reauth','relaunch');
    is($bad->{ok}, 0, 'plan: a package action on a fleet decision -> not ok');
    like($bad->{error}, qr/only supports --action resume/, 'plan: fleet error is specific');
}

# ===========================================================================
# PART 2 — CLI end-to-end against a temp blueprint dir
# ===========================================================================

sub write_file { my ($p,$c)=@_; my $d=$p; $d=~s{[\\/][^\\/]+$}{}; make_path($d) unless -d $d; open my $fh,'>:raw',$p or die "$p: $!"; print $fh $c; close $fh; }
sub slurp { my ($p)=@_; open my $fh,'<:raw',$p or return ''; local $/; my $c=<$fh>; close $fh; $c }

# Build a blueprint dir with one package ledger (status blocked), a registry, and
# a queued decision of $kind. Returns ($bpdir, $decision_id).
sub mk_bp {
    my (%o) = @_;
    my $pkg  = $o{pkg}  // 'alpha';
    my $kind = $o{kind} // 'stuck-package';
    my $bpdir = tempdir(CLEANUP => 1);
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nstatus: blocked\nwrite_set: p/$pkg/\n---\n\n# $pkg\n\n## Next action\n\nResolve the park.\n");
    write_file("$bpdir/runs/registry.json",
        $J->encode({ packages => { $pkg => { status=>'blocked', attempt=>3, pid=>4321 } } }));
    my $id = "$pkg--abc123";
    write_file("$bpdir/runs/needs-you/$id.json",
        $J->encode({ package=>$pkg, blueprint=>'bp', kind=>$kind,
                     question=>'Decide.', context=>'looped', created_at=>10 }));
    write_file("$bpdir/runs/.paused",
        $J->encode({ reason=>'token-floor', manual=>JSON::PP::true, created_at=>10 })) if $o{paused};
    return ($bpdir, $id, $pkg);
}

# shell-quote each arg (the suite runs under sh on both host and sandbox) so a
# multi-word --note value reaches the CLI as a single argument.
sub shq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'"; }
sub run_cli {
    my ($bpdir, @args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $script, 'bp', '--bp-dir', $bpdir, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

# --- relaunch: ledger->pending + note + registry reset + queue cleared ----------
{
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'stuck-package');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch', '--note', 'Re-scope to use the existing helper.');
    is($rc, 0, 'relaunch: exit 0') or diag($out);
    like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*pending/m, 'relaunch: ledger status -> pending');
    like(slurp("$bpdir/packages/$pkg.md"), qr/## Human decision \(resolve\)/, 'relaunch: corrective section appended');
    like(slurp("$bpdir/packages/$pkg.md"), qr/Re-scope to use the existing helper\./, 'relaunch: the human note is in the ledger');
    ok(!-f "$bpdir/runs/needs-you/$id.json", 'relaunch: queue entry deleted');
    my $reg = JSON::PP->new->decode(slurp("$bpdir/runs/registry.json"));
    is($reg->{packages}{$pkg}{status}, 'pending', 'relaunch: registry status -> pending');
    is($reg->{packages}{$pkg}{attempt}, 0, 'relaunch: registry attempt reset to 0 (fresh budget)');
    is($reg->{packages}{$pkg}{pid}, 4321, 'relaunch: registry merge preserved other fields');
    my $res = eval { JSON::PP->new->decode($out) };
    is($res->{action}, 'relaunch', 'relaunch: JSON action');
    ok($res->{ok}, 'relaunch: JSON ok=true');
}

# --- accept: ledger->done, no relaunch note, queue cleared ----------------------
{
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'harvest-failure');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'accept');
    is($rc, 0, 'accept: exit 0') or diag($out);
    like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*done/m, 'accept: ledger status -> done');
    unlike(slurp("$bpdir/packages/$pkg.md"), qr/## Human decision/, 'accept: no corrective note (not a relaunch)');
    ok(!-f "$bpdir/runs/needs-you/$id.json", 'accept: queue entry deleted');
}

# --- drop: ledger->dropped, queue cleared ---------------------------------------
{
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'stuck-package');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'drop');
    is($rc, 0, 'drop: exit 0') or diag($out);
    like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*dropped/m, 'drop: ledger status -> dropped');
    ok(!-f "$bpdir/runs/needs-you/$id.json", 'drop: queue entry deleted');
}

# --- fleet resume: clears runs/.paused + queue, leaves ledgers alone ------------
{
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'reauth', paused => 1);
    ok(-f "$bpdir/runs/.paused", 'resume: precondition .paused present');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id);   # default action resume
    is($rc, 0, 'resume: exit 0') or diag($out);
    ok(!-f "$bpdir/runs/.paused", 'resume: runs/.paused cleared');
    ok(!-f "$bpdir/runs/needs-you/$id.json", 'resume: queue entry deleted');
    like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*blocked/m, 'resume: package ledger untouched');
    my $res = eval { JSON::PP->new->decode($out) };
    is($res->{family}, 'fleet', 'resume: JSON family=fleet');
}

# --- guards: wrong action for kind, missing decision ----------------------------
{
    my ($bpdir, $id) = mk_bp(kind => 'reauth', paused => 1);
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch');
    is($rc, 2, 'guard: package action on a fleet decision -> exit 2') or diag($out);
    ok(-f "$bpdir/runs/.paused", 'guard: a rejected answer leaves the pause in place');
    ok(-f "$bpdir/runs/needs-you/$id.json", 'guard: a rejected answer leaves the queue entry');
}
{
    my ($bpdir) = mk_bp();
    my ($rc, $out) = run_cli($bpdir, '--decision', 'nope--000');
    is($rc, 2, 'guard: missing decision -> exit 2');
}
{
    my ($bpdir, $id) = mk_bp(kind => 'stuck-package');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'frobnicate');
    is($rc, 2, 'guard: unknown package action -> exit 2');
    ok(-f "$bpdir/runs/needs-you/$id.json", 'guard: bad action leaves the queue entry');
}

done_testing();
