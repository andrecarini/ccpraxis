#!/usr/bin/env perl
# platform: any
# Bug 20261112-132220-5b54: an answer applied by the escalation resolver must never
# read, in the ledger, as the operator's.
#
# bp-resolve.pl applies a `relaunch` verdict by running bp-answer-escalation.pl with the
# verdict's rationale as --note. That script wrote every note as
# "## Human decision (resolve)" / "A human reviewed this package's park", and put the same
# words into "## Next action". The orchestrator's orphan reconciler then copied Next action
# into the next escalation's context, and the next resolver read its predecessor's guidance
# as an operator ruling: on acxpraxis-step-2 package 15 it overruled a coordinator's
# explicit product escalation ("make check stays red repo-wide") citing "the operator
# already ruled", when the operator never had.
#
# Asserted here:
#   A1  the default answer (the operator's) is worded exactly as before;
#   A2  --answered-by escalation-resolver writes "## Agent decision (resolve)" and an
#       agent-attributed Next action, and no "human" wording anywhere in the ledger;
#   A3  an operator answer after an agent answer leaves exactly one decision block, the
#       operator's (the strip covers both headings, so they never stack);
#   A4  an unknown --answered-by is refused (exit 2) and the ledger is untouched;
#   A5  bp-resolve.pl's relaunch call passes --answered-by escalation-resolver;
#   A6  the resolver prompt says a previous resolver answer is never an operator ruling.
# A2 and A5 together are the fix; each alone would leave the bug in place.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $BUTLER  = abs_path("$Bin/../..");
my $SCRIPT  = "$BUTLER/scripts/bp-answer-escalation.pl";
my $RESOLVE = "$BUTLER/scripts/bp-resolve.pl";
my $AGENT   = "$BUTLER/agents/bp-escalation-resolver.md";

ok(-f $SCRIPT, "subject exists: $SCRIPT") or BAIL_OUT("cannot find $SCRIPT");
require $SCRIPT;   # loads BpOrch, for the real ledger_next_action reader

my $J = JSON::PP->new->canonical;

sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "$p: $!";
    print $fh $c;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }
sub shq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'"; }
sub run_cli {
    my ($bpdir, @args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $SCRIPT, 'bp', '--bp-dir', $bpdir, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

# One blocked package and one queued stuck-package escalation for it.
sub mk_bp {
    my (%o) = @_;
    my $pkg   = 'alpha';
    my $bpdir = tempdir(CLEANUP => 1);
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: bp\nstatus: blocked\nwrite_set: p/$pkg/\n"
      . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $pkg\n\n"
      . "## Next action\n\nSTALE-PARK-TEXT\n\n## Decisions & attempt log\n\n_(none yet)_\n\n"
      . "## Pipeline\n\n- [ ] 1. do it\n\n## Outputs\n\n_(none yet)_\n\n## Escalation\n\n_(none)_\n");
    write_file("$bpdir/runs/registry.json",
        $J->encode({ packages => { $pkg => { status => 'blocked', attempt => 3, pid => 4321 } } }));
    return ($bpdir, $pkg);
}
sub queue {
    my ($bpdir, $pkg, $suffix) = @_;
    my $id = "$pkg--$suffix";
    write_file("$bpdir/runs/escalations/$id.json",
        $J->encode({ package => $pkg, blueprint => 'bp', kind => 'stuck-package',
                     question => 'Decide.', context => 'parked', created_at => 10 }));
    return $id;
}

my $HUMAN_HEAD = qr/^## Human decision \(resolve\)$/m;
my $AGENT_HEAD = qr/^## Agent decision \(resolve\)$/m;

# ---- A1: the operator's answer is worded exactly as before --------------------------
{
    my ($bpdir, $pkg) = mk_bp();
    my $id = queue($bpdir, $pkg, 'a1');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch', '--note', 'OPERATOR-NOTE-A1');
    is($rc, 0, 'A1: operator relaunch exits 0') or diag($out);
    my $l = slurp("$bpdir/packages/$pkg.md");
    like($l, $HUMAN_HEAD, 'A1: default answer writes the Human decision heading');
    like($l, qr/A human reviewed this package's park and chose to \*\*relaunch\*\* it with this guidance:\n\nOPERATOR-NOTE-A1/,
         'A1: default audit wording unchanged');
    unlike($l, $AGENT_HEAD, 'A1: no Agent decision heading for an operator answer');
    my $na = BpOrch::ledger_next_action($bpdir, $pkg) // '';
    like($na, qr/\AA human reviewed this package's park and chose to \*\*relaunch\*\* it\. Their guidance:/,
         'A1: default Next action wording unchanged');
}

# ---- A2: the resolver's answer is attributed to the resolver ------------------------
my $agent_bpdir;
{
    my ($bpdir, $pkg) = mk_bp();
    $agent_bpdir = $bpdir;
    my $id = queue($bpdir, $pkg, 'a2');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch',
                             '--note', 'RESOLVER-NOTE-A2', '--answered-by', 'escalation-resolver');
    is($rc, 0, 'A2: resolver relaunch exits 0') or diag($out);
    my $l = slurp("$bpdir/packages/$pkg.md");
    like($l, $AGENT_HEAD, 'A2: resolver answer writes the Agent decision heading');
    unlike($l, $HUMAN_HEAD, 'A2: and no Human decision heading');
    unlike($l, qr/a human reviewed/i, 'A2: no "a human reviewed" wording anywhere in the ledger');
    like($l, qr/RESOLVER-NOTE-A2/, 'A2: the guidance itself is delivered');
    my $na = BpOrch::ledger_next_action($bpdir, $pkg) // '';
    like($na, qr/\AThe escalation resolver, an agent and not the operator,/,
         'A2: Next action (what an orphan escalation copies onward) names the resolver first');
    like($na, qr/not an operator ruling/, 'A2: Next action says it is not an operator ruling');
    like($na, qr/RESOLVER-NOTE-A2/, 'A2: Next action carries the guidance');
    unlike($na, qr/STALE-PARK-TEXT/, 'A2: the stale park text is replaced, as for an operator answer');
}

# ---- A3: operator after agent -> one block, the operator's --------------------------
{
    my $pkg = 'alpha';
    # back to blocked so a second answer applies
    my $f = "$agent_bpdir/packages/$pkg.md";
    my $l0 = slurp($f); $l0 =~ s/^status: \w+$/status: blocked/m; write_file($f, $l0);
    my $id = queue($agent_bpdir, $pkg, 'a3');
    my ($rc, $out) = run_cli($agent_bpdir, '--decision', $id, '--action', 'relaunch', '--note', 'OPERATOR-NOTE-A3');
    is($rc, 0, 'A3: operator answer after a resolver answer exits 0') or diag($out);
    my $l = slurp($f);
    my $blocks = () = ($l =~ /^## (?:Human|Agent) decision \(resolve\)$/mg);
    is($blocks, 1, 'A3: exactly one decision block remains (no stacking across answerers)');
    like($l, $HUMAN_HEAD, 'A3: and it is the operator\'s');
    unlike($l, qr/RESOLVER-NOTE-A2/, 'A3: the superseded resolver block is gone');
}

# ---- A4: an unknown answerer is refused --------------------------------------------
{
    my ($bpdir, $pkg) = mk_bp();
    my $id = queue($bpdir, $pkg, 'a4');
    my $before = slurp("$bpdir/packages/$pkg.md");
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch',
                             '--note', 'X', '--answered-by', 'someone-else');
    is($rc, 2, 'A4: unknown --answered-by exits 2');
    like($out, qr/--answered-by must be one of/, 'A4: and says what is allowed');
    is(slurp("$bpdir/packages/$pkg.md"), $before, 'A4: the ledger is untouched');
    ok(-f "$bpdir/runs/escalations/$id.json", 'A4: the decision stays queued');
}

# ---- A5: bp-resolve.pl attributes its relaunch to the resolver ----------------------
{
    my $src = slurp($RESOLVE);
    ok(length $src, "A5: read $RESOLVE");
    my ($call) = $src =~ /(_run_quiet\([^;]*?'--action', 'relaunch'[^;]*;)/s;
    ok(defined $call, 'A5: found the relaunch call to bp-answer-escalation.pl');
    like($call // '', qr/'--answered-by',\s*'escalation-resolver'/,
         'A5: it passes --answered-by escalation-resolver');
}

# ---- A6: the resolver prompt refuses to treat its own past answers as rulings -------
{
    my $txt = slurp($AGENT);
    like($txt, qr/A previous resolver's answer is never an operator ruling/,
         'A6: the resolver prompt states the rule');
    like($txt, qr/## Agent decision\s*\(resolve\)/, 'A6: and names the Agent decision block');
    like($txt, qr/runs\/escalation-resolve\/archive/, 'A6: and how to tell old mislabelled blocks apart');
}

done_testing();
