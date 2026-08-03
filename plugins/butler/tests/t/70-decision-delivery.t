#!/usr/bin/env perl
# b18-decision-delivery-and-park-loop oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b18-decision-delivery-and-park-loop-spec.md
# (the scout in section 0, THE RULE in section 1, C1..C7 in section 3).
#
# THE DEFECT (spec section 0): `append_human_decision` in bp-answer-decision.pl appends a
# "## Human decision (resolve)" block at EOF but NOTHING updates "## Next action" --
# `grep -c 'set-next-action\|Next action'` on the script returns 0. The resume prompt (see
# bp-launch.sh's "continue from the 'Next action' section") points a resuming coordinator at
# the section that STILL HOLDS THE STALE PARK TEXT that caused the park in the first place.
# A coordinator re-parked 91 seconds after being answered, reporting "No new owner decision
# arrived" -- the answer and the place the coordinator reads are different parts of the file.
#
# WRITTEN AGAINST THE CURRENT bp-answer-decision.pl, WHICH DOES NOT YET FIX THIS: every
# assertion below that fails is expected to fail because "## Next action" is untouched by
# --note (absence of implementation), never because of a Perl exception, a missing module, or
# a wrong path -- the script exists and runs fine today; it is simply incomplete in exactly
# the way the spec's scout documents.
#
# =====================================================================================
# MANDATORY VACUITY GATE (spec section 3's own standing rule), and how this oracle honours it:
#   - C1/C2 are asserted TOGETHER, on the SAME post-answer ledger read, using a fixture whose
#     Next action starts as a distinctive STALE marker string. "Append the answer beneath the
#     stale text" would satisfy C1 alone (the note is present somewhere) while still failing
#     C2 (the stale text the coordinator would still see is not gone) -- exactly the actual
#     failure mode the spec calls out. Neither assertion alone would catch that shape; together
#     they do.
#   - C4 is negative-only ("no new raw ledger writer"). Before trusting that count, a dedicated
#     block first asserts (positively) that the CLI's answer actually rewrote the ledger file at
#     all -- otherwise "the writer count didn't change" would be true for the trivial and
#     useless reason that nothing happened.
#   - C6 (every action that carries a note: relaunch, reset, accept, drop) is asserted PER
#     ACTION inside a loop, never aggregated -- b17's own oracle proved an aggregate assertion
#     hides exactly this shape of defect (two of four actions silently broken).
#   - C7 reads through BpOrch::ledger_next_action($bpdir, $pkg) -- the REAL function
#     bp-orchestrator.pl itself uses to surface a package's Next action (e.g. into an
#     escalation message) -- not a fixture string and not a hand-rolled regex of this oracle's
#     own. This is "the section the resume prompt names", read the way production code reads it.
#
# NO SKIP appears anywhere below.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $BUTLER = abs_path("$Bin/../..");
my $SCRIPT = "$BUTLER/scripts/bp-answer-decision.pl";

ok(-f $SCRIPT, "subject under test exists: $SCRIPT") or BAIL_OUT("cannot find $SCRIPT");

# Loads BpAnswer + BpOrch (bp-answer-decision.pl requires bp-orchestrator.pl) + installs
# bp-ledger.pl's subs (locate_section, extract_last_updated, ...) into package main --
# bp-ledger.pl declares no package of its own (see that file's own header comment), so its
# subs land directly in main:: exactly like bp-answer-decision.pl's own header documents for
# --widen-write-set. This oracle relies on that same fact to reach into the REAL parser
# (locate_section) rather than reimplementing section-finding with its own regex.
require $SCRIPT;

my $J = JSON::PP->new->canonical;

diag("subject under test: $SCRIPT (present); the Next-action-delivery fix does not exist yet "
   . "-- every assertion below expected to fail now is expected absence-of-implementation "
   . "(stale text still present / guidance absent from '## Next action'), never a crash.");

# =====================================================================================
# Scaffolding (house style per t/69).
# =====================================================================================

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

# mk_bp(%o) -> ($bpdir, $decision_id, $pkg, $stale_text). One package ledger whose
# '## Next action' body is a distinctive, easy-to-grep STALE marker (the "stale park text"
# the spec's scout describes), a registry entry, and (unless no_decision => 1) one queued
# needs-you decision of $kind.
sub mk_bp {
    my (%o) = @_;
    my $pkg    = $o{pkg}       // 'alpha';
    my $kind   = $o{kind}      // 'stuck-package';
    my $wset   = $o{write_set} // "p/$pkg/";
    my $status = $o{status}    // 'blocked';
    my $stale  = $o{stale}     // "STALE-PARK-INSTRUCTION-$pkg: do not act on this once the park is answered.";
    my $bpdir  = tempdir(CLEANUP => 1);
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: bp\nstatus: $status\nwrite_set: $wset\n"
      . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $pkg\n\n"
      . "## Next action\n\n$stale\n\n## Decisions & attempt log\n\n_(none yet)_\n\n"
      . "## Pipeline\n\n- [ ] 1. do it\n\n## Outputs\n\n_(none yet)_\n\n## Escalation\n\n_(none)_\n");
    write_file("$bpdir/runs/registry.json",
        $J->encode({ packages => { $pkg => { status => $status, attempt => 3, pid => 4321 } } }));
    my $id;
    unless ($o{no_decision}) {
        $id = "$pkg--" . ($o{id_suffix} // 'abc123');
        write_file("$bpdir/runs/needs-you/$id.json",
            $J->encode({ package => $pkg, blueprint => 'bp', kind => $kind,
                         question => 'Decide.', context => 'looped', created_at => 10 }));
    }
    return ($bpdir, $id, $pkg, $stale);
}

# next_action_body($ledger_path) -> the '## Next action' section's BODY (not the whole
# file), via bp-ledger.pl's OWN fence-aware locate_section -- the same function the
# sanctioned set-next-action op itself uses. undef if the section cannot be found at all.
sub next_action_body {
    my ($ledger_path) = @_;
    my $B = slurp($ledger_path);
    my $loc = locate_section($B, qr/^## Next action/m);
    return undef unless $loc;
    return substr($B, $loc->{body_start}, $loc->{body_end} - $loc->{body_start});
}

# =====================================================================================
# C1 + C2 + C3 + C6 + C7 -- per action (relaunch, reset, accept, drop), on a fixture whose
# '## Next action' starts as a distinctive stale marker.
# =====================================================================================
for my $case (
    { action => 'relaunch', note => 'Guidance for relaunch: retry against the corrected config path.' },
    { action => 'reset',    note => 'Guidance for reset: clear state and start the package fresh.' },
    { action => 'accept',   note => 'Guidance for accept: ship the current output as-is, no more work needed.' },
    { action => 'drop',     note => 'Guidance for drop: abandon this package, superseded by another.' },
) {
    my ($bpdir, $id, $pkg, $stale) = mk_bp(pkg => "np_$case->{action}", kind => 'stuck-package');
    my $ledger_path = "$bpdir/packages/$pkg.md";

    my $before = slurp($ledger_path);
    ok(index($before, $stale) >= 0,
        "setup ($case->{action}): fixture's stale park text is present in '## Next action' before answering");

    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', $case->{action}, '--note', $case->{note});
    is($rc, 0, "C6 ($case->{action}): --note answer exits 0") or diag($out);

    my $body = next_action_body($ledger_path);
    ok(defined $body, "($case->{action}): '## Next action' section still parses after answering")
        or next;

    # C1: the human's guidance is in the SECTION'S BODY, not merely present somewhere in
    # the file (e.g. only inside the separate '## Human decision' record).
    like($body, qr/\Q$case->{note}\E/,
        "C1 ($case->{action}): '## Next action' body contains the human's guidance");

    # C2: paired with C1. Appending the note BENEATH the stale text would satisfy C1 alone
    # while still misleading a resuming coordinator -- this is the actual failure the spec
    # names, so C1 and C2 are asserted on the SAME $body read.
    unlike($body, qr/\Q$stale\E/,
        "C2 ($case->{action}): the STALE park text is GONE from '## Next action' (paired with C1)");

    # C3: the durable audit-trail record (SYN-10: archive, never delete) still exists and
    # still carries the note.
    my $after_full = slurp($ledger_path);
    like($after_full, qr/^## Human decision \(resolve\)/m,
        "C3 ($case->{action}): the '## Human decision (resolve)' audit record still exists");
    like($after_full, qr/\Q$case->{note}\E/,
        "C3 ($case->{action}): the audit record itself still carries the human's note");

    # C7: the re-park scenario is closed, verified against the REAL ledger-read path --
    # BpOrch::ledger_next_action(), the function bp-orchestrator.pl's own escalation code
    # calls to surface a package's Next action -- not a fixture string of this oracle's own.
    my $real_next = BpOrch::ledger_next_action($bpdir, $pkg);
    ok(defined $real_next, "C7 ($case->{action}): BpOrch::ledger_next_action() returns a value") or next;
    like($real_next, qr/\Q$case->{note}\E/,
        "C7 ($case->{action}): the REAL ledger-read path a resuming coordinator is pointed at surfaces the "
      . "human's guidance -- the re-park loop is closed");
    unlike($real_next, qr/\Q$stale\E/,
        "C7 ($case->{action}): the REAL ledger-read path no longer surfaces the stale park text");
}

# =====================================================================================
# C4 -- no new raw ledger writer appears in bp-answer-decision.pl. Negative-only, so a
# positive gate comes first: prove the CLI's answer actually rewrote the ledger file at
# all, or "the writer count didn't change" would be true for the vacuous reason that
# nothing happened.
# =====================================================================================
{
    my ($bpdir, $id, $pkg) = mk_bp(pkg => 'c4pkg', kind => 'stuck-package');
    my $ledger_path = "$bpdir/packages/$pkg.md";
    my $before = slurp($ledger_path);

    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch',
        '--note', 'C4 guidance: this answer must land through the sanctioned writer.');
    is($rc, 0, 'C4 positive gate: relaunch --note exits 0') or diag($out);

    my $after = slurp($ledger_path);
    ok($after ne $before,
        'C4 positive gate: the ledger file was actually rewritten by the answer -- required before the '
      . 'negative "no new writer" assertion below can mean anything');

    my $src = slurp($SCRIPT);
    my $raw_ledger_writes = () = ($src =~ /open\s*\(?\s*my\s*\$\w+\s*,\s*['"]>:raw['"]/g);
    is($raw_ledger_writes, 1,
        "C4: bp-answer-decision.pl still has exactly ONE raw '>:raw' file writer (the existing corrective-note "
      . "writer) -- Next-action delivery must go through bp-ledger.pl's set-next-action op, never a second, "
      . "independent raw ledger writer of this script's own (b17's own oracle already pins this count at 1)");
}

# =====================================================================================
# C5 -- answering twice leaves exactly ONE '## Human decision' section and one coherent
# '## Next action' -- no stacking.
# =====================================================================================
{
    my ($bpdir, $id, $pkg, $stale) = mk_bp(pkg => 'c5pkg', kind => 'stuck-package');
    my $ledger_path = "$bpdir/packages/$pkg.md";

    my ($rc1, $out1) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch', '--note', 'First answer: do A.');
    is($rc1, 0, 'C5: first answer exits 0') or diag($out1);

    # A second decision for the SAME package -- a human answering again, e.g. after a
    # re-park (direct package mode isn't required here: --decision mode is the common
    # path and is what a reporter actually invokes from runs/needs-you/).
    my $id2 = "$pkg--second";
    write_file("$bpdir/runs/needs-you/$id2.json",
        $J->encode({ package => $pkg, blueprint => 'bp', kind => 'stuck-package',
                     question => 'Decide again.', context => 'looped', created_at => 20 }));
    my ($rc2, $out2) = run_cli($bpdir, '--decision', $id2, '--action', 'relaunch', '--note', 'Second answer: do B instead.');
    is($rc2, 0, 'C5: second answer exits 0') or diag($out2);

    my $ledger = slurp($ledger_path);
    my $human_count = () = ($ledger =~ /^## Human decision \(resolve\)/mg);
    is($human_count, 1, 'C5: answering twice leaves exactly ONE "## Human decision" section -- no stacking');

    my $next_action_heading_count = () = ($ledger =~ /^## Next action\b/mg);
    is($next_action_heading_count, 1,
        'C5: exactly one "## Next action" heading -- the section itself was not duplicated');

    my $body = next_action_body($ledger_path);
    ok(defined $body, 'C5: "## Next action" still parses after two answers') or goto C5_DONE;
    like($body, qr/Second answer: do B instead\./, 'C5: "## Next action" reflects the LATEST guidance');
    unlike($body, qr/First answer: do A\./,
        'C5: "## Next action" does not stack the FIRST answer underneath the second -- one coherent section');
    unlike($body, qr/\Q$stale\E/, 'C5: the original stale park text is gone after two answers');
    C5_DONE:
}

done_testing();
