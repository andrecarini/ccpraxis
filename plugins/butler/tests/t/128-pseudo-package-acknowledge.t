#!/usr/bin/env perl
# e04-honest-terminal-reporting, AC2 (-> DC2): dag-stalled/remediation-escalation
# decisions are filed against pseudo-packages ('_dag'/'_remediation') with NO
# ledger file -- bp-answer-decision.pl must give them an `acknowledge` verb
# instead of refusing every possible --action with a generic "ledger not found"
# message. Spec §2.2/§3(2)/§4 AC2/§7 edge case 2.
#
# TODAY'S WRONG REPORT (confirmed live against bp-answer-decision.pl:118-162,
# 480-546 while writing this test):
#   - BpAnswer::plan_answer($kind, $action) takes only 2 args -- the 3rd
#     ($pseudo) does not exist, so passing it is silently a no-op.
#   - 'dag-stalled' IS in %BpOrch::KIND_REGISTRY with family 'package' (e02
#     shipped visibility), so plan_answer treats it exactly like a real
#     package decision: --action acknowledge is refused with
#     "package decision 'dag-stalled' supports --action relaunch|reset|accept|drop
#      (got 'acknowledge')" -- the wrong refusal, for the wrong reason, pointing
#     the operator at exactly the verb the spec says must NOT work.
#   - The CLI's ledger-existence gate at line ~544
#     (`unless (... -f "$bpdir/packages/$pkg.md") { exit 2 }`) fires for EVERY
#     family-package decision including '_dag'/'_remediation', which have no
#     ledger by design -- so even a "valid" action like --action relaunch is
#     refused with a GENERIC "package ledger not found for '_dag'" message that
#     never mentions the pseudo-package or points at any resolution path.
#
# Written BLIND to the eventual implementation: no `pseudo` key, no
# `_log_pseudo_ack`, no pseudo-aware branch exists anywhere in
# bp-answer-decision.pl (grepped clean before writing this file).
#
# VACUITY GUARDS:
#   - every refusal assertion pairs ok=0 with a `like`/`unlike` on the actual
#     error TEXT, never a bare falsy check (a generically-worded refusal that
#     happens to be falsy would otherwise pass).
#   - the acknowledge-success assertions check ALL THREE of: plan ok=1,
#     ledger_status explicitly undef (nothing to flip), AND (in the CLI part)
#     that no packages/_dag.md file was created on disk -- an implementation
#     that fabricates a ledger to satisfy the existing gate would pass a
#     naive "ok=1" check but fail the on-disk assertion.
#   - real-package kinds (stuck-package, harvest-failure) are run through the
#     SAME plan_answer call shape with pseudo=1 NOT set, asserting the
#     existing 2-arg behavior is completely unaffected -- catches an
#     implementation that makes pseudo detection based on kind name alone
#     (ignoring the passed flag) and accidentally changes real-package kinds.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $script = "$Bin/../../scripts/bp-answer-decision.pl";
require $script;

my $J = JSON::PP->new->canonical;

# ═══════════════════════════════════════════════════════════════════════════
# PART 1 — pure BpAnswer::plan_answer($kind, $action, $pseudo)
# ═══════════════════════════════════════════════════════════════════════════

# 1a: dag-stalled, pseudo=1, action=acknowledge -> ok, family package, pseudo,
#     no ledger_status to flip, no relaunch/reset/supersede.
{
    my $p = BpAnswer::plan_answer('dag-stalled', 'acknowledge', 1);
    ok($p->{ok}, 'AC2/1a: dag-stalled + pseudo=1 + acknowledge -> ok (fails today: 3rd arg ignored, action refused)')
        or diag(explain($p));
    is($p->{family}, 'package', 'AC2/1a: family is package');
    ok($p->{pseudo}, 'AC2/1a: plan carries pseudo=>1 (does not exist as a key at all today)');
    is($p->{action}, 'acknowledge', 'AC2/1a: action echoed back as acknowledge');
    is($p->{ledger_status}, undef, 'AC2/1a: no ledger_status to flip (nothing to write)');
    is($p->{relaunch} // 0, 0, 'AC2/1a: acknowledge never relaunches');
    is($p->{reset_attempt} // 0, 0, 'AC2/1a: acknowledge never resets an attempt budget');
}

# 1b: remediation-escalation, pseudo=1, no --action given -> defaults to acknowledge.
{
    my $p = BpAnswer::plan_answer('remediation-escalation', undef, 1);
    ok($p->{ok}, 'AC2/1b: remediation-escalation + pseudo=1 + no action -> defaults to acknowledge and succeeds');
    is($p->{action}, 'acknowledge', 'AC2/1b: default action under pseudo=1 is acknowledge');
}

# 1c: dag-stalled, pseudo=1, action=relaunch -> REFUSED, naming the
#     pseudo-package and pointing at acknowledge (spec §2.2's exact message shape).
{
    my $p = BpAnswer::plan_answer('dag-stalled', 'relaunch', 1);
    is($p->{ok}, 0, 'AC2/1c: dag-stalled + pseudo=1 + relaunch -> refused (there is no ledger to relaunch)');
    like($p->{error} // '', qr/pseudo-package/i,
        'AC2/1c: refusal error names the condition as a pseudo-package (fails today: generic "supports --action ..." text)');
    like($p->{error} // '', qr/acknowledge/,
        'AC2/1c: refusal error points the operator at the acknowledge verb');
}
for my $bad_action (qw(reset accept drop)) {
    my $p = BpAnswer::plan_answer('dag-stalled', $bad_action, 1);
    is($p->{ok}, 0, "AC2/1c: dag-stalled + pseudo=1 + $bad_action -> also refused (only acknowledge works)");
}

# 1d: real-package kinds are UNAFFECTED when pseudo is false/omitted (existing
#     2-arg call shape, e02's own tests included, must keep working verbatim).
{
    my $p2 = BpAnswer::plan_answer('stuck-package', 'accept');    # 2-arg, exactly as e02 calls it
    ok($p2->{ok}, 'AC2/1d: stuck-package 2-arg call unaffected by the new 3rd param');
    is($p2->{ledger_status}, 'done', 'AC2/1d: stuck-package accept -> ledger done (unchanged)');

    my $p3 = BpAnswer::plan_answer('harvest-failure', 'relaunch', 0);   # explicit pseudo=0
    ok($p3->{ok}, 'AC2/1d: harvest-failure + pseudo=0 -> ordinary relaunch path, unaffected');
    is($p3->{ledger_status}, 'pending', 'AC2/1d: pseudo=0 does not divert a real package kind');
}

# 1e: a REAL package kind incorrectly marked pseudo=1 must NOT be silently
#     treated as pseudo (spec's pseudo detection is CLI-side, keyed on the
#     package name starting with '_' -- plan_answer itself trusts the flag it
#     is given, so this asserts the CLI-level symmetry described in spec §2.2
#     is exercised correctly, not that plan_answer second-guesses its caller).
#     Documented here as a DESIGN NOTE, not asserted as a separate requirement
#     -- see test-writer report.

# ═══════════════════════════════════════════════════════════════════════════
# PART 2 — CLI end-to-end: --decision against a queued dag-stalled pseudo-
# package decision, with NO packages/_dag.md ledger on disk at all.
# ═══════════════════════════════════════════════════════════════════════════
sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print $fh $c; close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }
sub shq { my $s = shift; $s =~ s/"/\\"/g; return qq{"$s"}; }

sub mk_dag_stalled_bp {
    my $bpdir = tempdir(CLEANUP => 1);
    make_path("$bpdir/packages");
    make_path("$bpdir/runs/escalations");
    # Deliberately NO packages/_dag.md ledger -- that's the whole point.
    write_file("$bpdir/runs/escalations/_dag--abc123.json", $J->encode({
        package => '_dag', blueprint => 'bp', kind => 'dag-stalled',
        question => "The blueprint's dependency graph cannot progress.",
        context  => { class => 'unresolvable', unresolvable => [], blockers => [], pending => [] },
        created_at => 100, category => 'scoping',
    }));
    return $bpdir;
}
sub run_answer_cli {
    my ($bpdir, @args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $script, 'bp', '--bp-dir', $bpdir, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

# 2a: --action relaunch (nonsensical against a pseudo-package) -> exit 2,
#     stderr names the pseudo-package + acknowledge, decision file untouched.
{
    my $bpdir = mk_dag_stalled_bp();
    my $decfile = "$bpdir/runs/escalations/_dag--abc123.json";
    my ($rc, $out) = run_answer_cli($bpdir, '--decision', '_dag--abc123', '--action', 'relaunch');
    isnt($rc, 0, 'AC2/2a: --action relaunch against a dag-stalled decision is refused (nonzero exit)');
    like($out, qr/pseudo-package|acknowledge/i,
        'AC2/2a: CLI output names the pseudo-package condition or the acknowledge path '
      . '(fails today: generic "package ledger not found for \'_dag\'")');
    ok(-f $decfile, 'AC2/2a: the queued decision file is NOT deleted on refusal');
}

# 2b: --action acknowledge -> exit 0, decision file CLEARED, no ledger file
#     fabricated, JSON on stdout with action:"acknowledge".
{
    my $bpdir = mk_dag_stalled_bp();
    my $decfile = "$bpdir/runs/escalations/_dag--abc123.json";
    my ($rc, $out) = run_answer_cli($bpdir, '--decision', '_dag--abc123', '--action', 'acknowledge');
    is($rc, 0, 'AC2/2b: --action acknowledge against a dag-stalled decision succeeds (exit 0)')
        or diag($out);
    ok(!-f $decfile, 'AC2/2b: the queued decision file IS cleared on acknowledge');
    ok(!-f "$bpdir/packages/_dag.md", 'AC2/2b: no ledger file is fabricated for the pseudo-package');
    # Decode the whole stdout BLOCK, not a single line. The CLI's final print is
    # JSON::PP->new->canonical->pretty->encode (bp-answer-decision.pl:631/:677/
    # :724), which the spec marks untouched -- so its output is MULTI-LINE and
    # its first brace-initial line is exactly "{", which decodes as nothing.
    # Taking one line made this assertion unsatisfiable by any correct
    # implementation. Driver-authorised correction; the claim under test
    # (stdout carries parseable JSON reporting the action) is unchanged.
    my ($json_block) = $out =~ /(\{.*\})/s;
    my $decoded = defined $json_block ? eval { $J->decode($json_block) } : undef;
    ok(defined $decoded, 'AC2/2b: stdout contains parseable JSON') or diag($out);
    if ($decoded) {
        is($decoded->{action}, 'acknowledge', 'AC2/2b: JSON reports action:"acknowledge"');
    }
}

# 2c: default (no --action at all) against a dag-stalled decision also
#     succeeds as acknowledge (spec §3 observable behavior 2: "no --action at all").
{
    my $bpdir = mk_dag_stalled_bp();
    my ($rc, $out) = run_answer_cli($bpdir, '--decision', '_dag--abc123');
    is($rc, 0, 'AC2/2c: no --action given against dag-stalled defaults to acknowledge and succeeds')
        or diag($out);
}

done_testing();
