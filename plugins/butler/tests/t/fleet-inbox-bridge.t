#!/usr/bin/env perl
# platform: any
# 06-fleet-inbox-bridge oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/where-things-go/specs/06-fleet-inbox-bridge-spec.md
# -- never from any implementation. Covers all 9 done criteria from
# packages/06-fleet-inbox-bridge.md end to end:
#   DC1 product re-tag -> exactly one item w/ question+choices; impl/scoping -> none
#   DC2 answer applied next tick exactly as bp-answer-escalation would; item+escalation close; thread logs
#   DC3 done/dropped package closes escalation+item w/ reason; orphan item closed w/ reason
#   DC4 broken-env resolver-visible (F2); reauth/contract-drift reach inbox directly (F1)
#   DC5 not-mine re-queues as implementation in place, closes item
#   DC6 only auth/contract sites in bp-orchestrator.pl set product/operator-action
#   DC7 standalone sweep --bp-dir: closes settled+orphans, idempotent, no-op while live
#   DC8 resolver bar verbatim; product_question required; apply step rejects a verdict missing it
#   DC9 listed tests green; nothing launches launcher.pl/podman/claude
#
# WRITTEN AGAINST THE CURRENT TREE, WHICH HAS NONE OF THIS YET: BpOrch has no
# inbox_bridge_setup/inbox_link_for/inbox_resolve_link/inbox_close_item/
# inbox_close_orphans/archive_settled_escalation/orchestrator_marker_live/
# _inbox_bridge_tick; bp-resolve.pl's verdict_shape_ok does not require
# product_question; bp-answer-escalation.pl has no not-mine action and no
# `sweep` verb; bp-escalation-resolver.md has no product_question field or
# operator's-bar text. Every failing assertion below is expected
# absence-of-implementation, not a defect in this oracle.
#
# Fixture rules per spec §4: a temp project <P> with
# <P>/.ccpraxis-local-data/blueprints/<bp>/; HOME/ALMANAC_HOME pinned to temp
# dirs (Decision 29 live-vault leak); every launch seam mocked; the almanac
# and the butler CLIs may run as real subprocesses; nothing launches
# launcher.pl, podman or claude.
#
# DELIBERATE SIMPLIFICATIONS (documented, not invented behavior):
#  - Where a scenario's PRECONDITION is itself pre-existing/out-of-write-set
#    machinery (broken-env/reauth/contract-drift trip detection via
#    _enter_pause_manual; package 05's fleet-thread "sent" bookkeeping), the
#    precondition state is constructed directly (the exact record/ledger
#    shape the spec documents) rather than re-derived by re-running that
#    pre-existing machinery, which has its own tests elsewhere. This keeps
#    the oracle targeted at package 06's own deliverables.
#  - AC9's final clause (a live dispatch picking up a not-mine-returned
#    record) is exercised with a bounded, deterministic tick-capped
#    BpOrch::run() probe (same sentinel-die technique
#    orchestrator-loop-simulation.t already uses), not an open-ended loop.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();

# Decision 29: never let a test touch the operator's real vault.
my $FAKE_HOME = tempdir(CLEANUP => 1);
$ENV{HOME} = $FAKE_HOME;
$ENV{ALMANAC_HOME} = $FAKE_HOME;

my $ORCH_SCRIPT    = "$Bin/../../scripts/bp-orchestrator.pl";
my $RESOLVE_SCRIPT = "$Bin/../../scripts/bp-resolve.pl";
my $ANSWER_SCRIPT  = "$Bin/../../scripts/bp-answer-escalation.pl";
my $INBOX_SCRIPT   = "$Bin/../../../almanac/scripts/almanac-inbox.pl";
my $AGENT_FILE     = "$Bin/../../agents/bp-escalation-resolver.md";
my $SELF           = "$Bin/fleet-inbox-bridge.t";

require $ORCH_SCRIPT;    # BpOrch -- exists today
my $RESOLVE_LOADED = eval { require $RESOLVE_SCRIPT; 1 };
my $RESOLVE_ERR = $@;
require $ANSWER_SCRIPT;  # BpAnswer + BpOrch (already loaded)
require $INBOX_SCRIPT;   # Almanac::Inbox

my $J = JSON::PP->new->canonical;

sub run_group {
    my ($label, $code) = @_;
    my $ok = eval { $code->(); 1 };
    fail("$label -- group errored (setup/infra problem, not a per-assertion failure): $@") unless $ok;
}

# ═══════════════════════════════════════════════════════════════════════════
# Scaffolding
# ═══════════════════════════════════════════════════════════════════════════
sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print $fh $c;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }
sub read_json { my ($p) = @_; my $t = slurp($p); return undef unless defined $t; return eval { $J->decode($t) }; }
sub shq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'"; }

my $PN = 0;
sub mk_project {
    my ($bp) = @_;
    $bp //= 'wtg' . (++$PN);
    my $P = tempdir(CLEANUP => 1);
    my $bpdir = "$P/.ccpraxis-local-data/blueprints/$bp";
    make_path("$bpdir/packages");
    make_path("$bpdir/runs/escalations");
    return ($P, $bpdir, $bp);
}

sub write_ledger {
    my ($bpdir, $pkg, $status, %o) = @_;
    my $bp = $o{bp} // 'bp';
    write_file("$bpdir/packages/$pkg.md",
          "---\npackage: $pkg\nblueprint: $bp\nstatus: $status\nwrite_set: p/$pkg/\n"
        . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $pkg\n\n"
        . "## Next action\n\nTBD.\n\n"
        . "## Decisions & attempt log\n\n"
        . "## Pipeline\n\n"
        . "## Outputs\n\n"
        . "## Escalation\n\n");
}
sub ledger_text { my ($bpdir, $pkg) = @_; return slurp("$bpdir/packages/$pkg.md") // ''; }
sub ledger_status { my ($bpdir, $pkg) = @_; my $t = ledger_text($bpdir, $pkg); return ($t =~ /^status:\s*(\S+)/m) ? $1 : undef; }
# flips a ledger's status IN PLACE, after the fact -- used to simulate "the
# package later reached done/dropped" without re-triggering queue_needs_you's
# own done/dropped refusal gate (kind 'stuck-package' refuses to even queue
# against an ALREADY-done/dropped ledger; the escalation here was filed
# earlier, while the package was still live).
sub set_ledger_status {
    my ($bpdir, $pkg, $status) = @_;
    my $f = "$bpdir/packages/$pkg.md";
    my $t = slurp($f) // die "set_ledger_status: no ledger at $f";
    $t =~ s/^status:.*$/status: $status/m;
    write_file($f, $t);
}

sub decision_path { my ($runs, $id) = @_; return "$runs/escalations/$id.json"; }
sub archive_path  { my ($runs, $id) = @_; return "$runs/resolved-escalations/$id.json"; }

# File a fixture queued escalation via the REAL BpOrch::queue_needs_you (not a
# hand-typed JSON file), exactly as resolve-verdict-gates.t's file_decision
# does, so the shape is production-faithful.
sub file_escalation {
    my ($runs, %o) = @_;
    my $rec = {
        package    => $o{pkg},
        blueprint  => $o{bp} // 'bp',
        kind       => $o{kind} // 'stuck-package',
        question   => $o{question} // 'what should happen?',
        context    => $o{context} // 'some context',
        created_at => $o{created_at} // time,
        category   => $o{category} // 'unclassified',
    };
    my $path = BpOrch::queue_needs_you($runs, $rec);
    die "file_escalation: queue_needs_you failed for $o{pkg}" unless $path;
    (my $id = $path) =~ s{.*[\\/]}{}; $id =~ s/\.json$//i;
    my $filed = read_json($path);
    return ($id, $path, $filed);
}

sub setup_ctx {
    my (%o) = @_;
    my $log = $o{log} // "$o{runs}/orchestrator.log";
    my ($ctx, $reason) = BpOrch::inbox_bridge_setup({ blueprint => $o{bp}, bp_dir => $o{bpdir}, runs => $o{runs}, log => $log });
    return ($ctx, $reason);
}

sub tick_bridge {
    my ($ctx, %o) = @_;
    my $status = $o{status} // {};
    my $reg    = $o{reg}    // {};
    my $tun    = { judge_spawn_cap => 3, %{ $o{tunables} // {} } };
    my $answer = $o{answer} // sub { 1 };
    BpOrch::_inbox_bridge_tick($ctx, { status => $status, reg => $reg, tunables => $tun, answer => $answer });
}

# The default answer seam from spec §2.4, built directly in this test (the
# real coderef lives inside run(), not exposed standalone).
sub make_answer_cb {
    my ($bp, $bpdir) = @_;
    return sub {
        my ($a) = @_;
        my @args = ($bp, '--decision', $a->{id}, '--action', $a->{action});
        push @args, '--note', $a->{note} if defined $a->{note};
        push @args, '--bp-dir', $bpdir;
        my $cmd = join ' ', map { shq($_) } ($^X, $ANSWER_SCRIPT, @args);
        `$cmd 2>&1`;
        return $? >> 8;
    };
}
sub run_answer_cli {
    my (@args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $ANSWER_SCRIPT, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}
sub run_inbox_cli {
    my (@args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $INBOX_SCRIPT, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

sub all_items { my ($P) = @_; return Almanac::Inbox::list_items(root => $P); }
sub bp_items  { my ($P, $bp) = @_; return [ grep { defined $_->{fields}{link} && $_->{fields}{link} =~ m{^\Q$bp\E/} } @{ all_items($P) } ]; }
sub open_items { my ($P, $bp) = @_; return [ grep { !exists $_->{fields}{closed_at} } @{ bp_items($P, $bp) } ]; }

# ═══════════════════════════════════════════════════════════════════════════
# DC1 (AC1, AC2, AC18): product re-tag -> exactly one item; impl/scoping -> none
# ═══════════════════════════════════════════════════════════════════════════
run_group('DC1-AC1 (product retag files exactly one item, stable across further ticks)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    write_ledger($bpdir, 'checkout', 'blocked', bp => $bp);
    my ($id, $path, $filed) = file_escalation($runs, pkg => 'checkout', bp => $bp, kind => 'stuck-package',
        category => 'unclassified', question => 'free-text park');
    my $verdict = { category => 'product', confidence => 'low', evidence => 'e',
                     product_question => 'Should checkout keep guest accounts?' };
    my $outcome = BpResolve::apply_verdict($verdict, $filed, $id, { bpdir => $bpdir, runs => $runs, bp => $bp, log => "$runs/orchestrator.log" });
    is($outcome->{outcome}, 'tag-only', 'DC1 setup: resolver verdict landed tag-only/product') or diag(explain_outcome($outcome));

    my ($ctx, $reason) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
    ok($ctx, 'AC1: inbox_bridge_setup succeeds for a well-formed project tree') or diag("reason: " . ($reason // '?'));

    tick_bridge($ctx, status => { checkout => 'blocked' });
    tick_bridge($ctx, status => { checkout => 'blocked' }); # "the consuming tick plus one more"

    my $items = open_items($P, $bp);
    is(scalar @$items, 1, 'AC1: exactly one inbox item is filed') or diag(explain_items($items));
    if (@$items) {
        my $f = $items->[0]{fields};
        is($f->{title}, 'Should checkout keep guest accounts?', 'AC1: title is the product_question verbatim');
        is($f->{link}, "$bp/checkout/$id", 'AC1: link is <bp>/<pkg>/<id>');
        is($f->{choices}, 'relaunch,accept,drop,not-mine', 'AC1: choices are the package-family vocabulary');
        is($f->{status}, 'unanswered', 'AC1: status unanswered');
    }
    tick_bridge($ctx, status => { checkout => 'blocked' });
    tick_bridge($ctx, status => { checkout => 'blocked' });
    is(scalar(@{ open_items($P, $bp) }), 1, 'AC1: two further ticks still exactly one item (no duplicate filing)');
});

run_group('DC1-AC2 (resolver-owned act outcomes -> zero inbox items)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    for my $spec ([ 'pimp', 'implementation', { category => 'implementation', action => 'relaunch', confidence => 'high', evidence => 'e', rationale => 'r' } ],
                  [ 'pscp', 'scoping',        { category => 'scoping', action => 'widen-write-set', confidence => 'high', path => 'p/pscp/', evidence => 'bp-resolve.pl:1', rationale => 'r' } ]) {
        my ($pkg, $cat, $verdict) = @$spec;
        write_ledger($bpdir, $pkg, 'blocked', bp => $bp);
        my ($id, $path, $filed) = file_escalation($runs, pkg => $pkg, bp => $bp, kind => 'stuck-package', category => 'unclassified', question => "q-$pkg");
        my $outcome = BpResolve::apply_verdict($verdict, $filed, $id, { bpdir => $bpdir, runs => $runs, bp => $bp, log => "$runs/orchestrator.log" });
        is($outcome->{outcome}, 'act', "AC2: $cat verdict reaches act (resolver resolved it itself)") or diag(explain_outcome($outcome));
    }
    my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
    tick_bridge($ctx, status => { pimp => 'done', pscp => 'done' });
    tick_bridge($ctx, status => { pimp => 'done', pscp => 'done' });
    is(scalar(@{ bp_items($P, $bp) }), 0, 'AC2: zero inbox items were ever filed for resolver-resolved (implementation/scoping) escalations');
});

run_group('DC1-AC18 (non-ASCII product_question round-trips byte-identically)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    write_ledger($bpdir, 'cafe', 'blocked', bp => $bp);
    my ($id, $path, $filed) = file_escalation($runs, pkg => 'cafe', bp => $bp, kind => 'stuck-package', category => 'unclassified', question => 'q');
    my $q = "Caf\xc3\xa9 checkout?"; # UTF-8 bytes for "Café checkout?"
    my $verdict = { category => 'product', confidence => 'low', evidence => 'e', product_question => $q };
    my $outcome = BpResolve::apply_verdict($verdict, $filed, $id, { bpdir => $bpdir, runs => $runs, bp => $bp, log => "$runs/orchestrator.log" });
    is($outcome->{outcome}, 'tag-only', 'AC18 setup: tag-only landed');
    my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
    tick_bridge($ctx, status => { cafe => 'blocked' });
    my $items = open_items($P, $bp);
    is(scalar @$items, 1, 'AC18: one item filed for the non-ASCII question');
    if (@$items) {
        my ($rc, $out) = run_inbox_cli('show', $items->[0]{id}, '--root', $P);
        is($rc, 0, 'AC18: almanac-inbox.pl show exits 0') or diag($out);
        like($out, qr/\Qtitle: $q\E/, 'AC18: show prints the title byte-identically (UTF-8 bytes preserved)') or diag($out);
    }
});

# ═══════════════════════════════════════════════════════════════════════════
# DC2 (AC3, AC4, AC17): answers applied as bp-answer-escalation would; both
# close; inbox_resolve_link's state machine.
# ═══════════════════════════════════════════════════════════════════════════
sub mk_answered_fixture {
    my (%o) = @_; # pkg, bp, bpdir, runs, choice, note
    write_ledger($o{bpdir}, $o{pkg}, 'blocked', bp => $o{bp});
    my ($id, $path, $filed) = file_escalation($o{runs}, pkg => $o{pkg}, bp => $o{bp}, kind => 'stuck-package',
        category => 'product', question => $o{question} // 'q', );
    # tag the record with product_question directly (bypassing the resolver
    # dispatch, which is out of this package's write set and already exercised
    # in DC1) so the bridge files it.
    my $rec = read_json($path);
    $rec->{product_question} = $o{question} // 'q?';
    write_file($path, $J->encode($rec));
    my $item = Almanac::Inbox::file(root => $o{P}, title => $o{question} // 'q?',
        body => "", link => "$o{bp}/$o{pkg}/$id", choices => 'relaunch,accept,drop,not-mine');
    my ($rc2, $out) = run_inbox_cli('answer', $item->{id}, '--choice', $o{choice}, (defined $o{note} ? ('--note', $o{note}) : ()), '--root', $o{P});
    die "mk_answered_fixture: inbox answer failed rc=$rc2 out=$out" unless $rc2 == 0;
    return ($id, $item->{id});
}

for my $case ([ 'relaunch', 'keep them', 'pending' ], [ 'accept', undef, 'done' ], [ 'drop', undef, 'dropped' ]) {
    my ($choice, $note, $want_status) = @$case;
    run_group("DC2-AC3 (answer $choice applied next tick, both close)", sub {
        my ($P, $bpdir, $bp) = mk_project();
        my $runs = "$bpdir/runs";
        my $pkg = "pkg_$choice";
        my ($id, $item_id) = mk_answered_fixture(P => $P, bpdir => $bpdir, bp => $bp, runs => $runs, pkg => $pkg,
            choice => $choice, note => $note, question => "answer-$choice?");
        my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
        tick_bridge($ctx, status => { $pkg => 'blocked' }, answer => make_answer_cb($bp, $bpdir));

        is(ledger_status($bpdir, $pkg), $want_status, "AC3: ledger status is $want_status after answering $choice");
        if (defined $note) {
            like(ledger_text($bpdir, $pkg), qr/## Human decision \(resolve\)/, 'AC3: ledger carries the Human decision section');
            like(ledger_text($bpdir, $pkg), qr/\Q$note\E/, 'AC3: the note text appears in the ledger');
        }
        ok(!-f decision_path($runs, $id), "AC3: escalation file is gone after $choice is applied");
        ok(!-f archive_path($runs, $id), 'AC3: no archive entry (answer applied, not auto-settled)');

        my $rec = read_json("$runs/orchestrator.log") // {};
        my $log = slurp("$runs/orchestrator.log") // '';
        like($log, qr/inbox_answer_applied/, 'AC3: orchestrator.log records inbox_answer_applied');

        my $item = Almanac::Inbox::read_item($item_id, root => $P);
        is($item->{fields}{status}, 'answered', 'AC3: item status stays answered');
        is($item->{fields}{choice}, $choice, 'AC3: item choice preserved');
        ok(exists $item->{fields}{closed_at}, 'AC3: item carries closed_at');
        is($item->{fields}{closed_by}, 'orchestrator', 'AC3: item closed_by orchestrator');
        is($item->{fields}{closed_reason}, "answer applied: $choice", "AC3: closed_reason is 'answer applied: $choice'");
    });
}

run_group('DC2-AC4 (deferred rc=6 leaves the item open; failed rc=2 closes + refiles)', sub {
    # Each sub-case gets its OWN project/bp: the bridge tick is deliberately
    # whole-project-scoped (spec SS3.1), so sharing one project/bp across these
    # two sub-cases would let the still-open 'deferred' item from the first
    # sub-case get swept up by the second sub-case's blanket answer callback.

    # rc=6: deferred.
    {
        my ($P, $bpdir, $bp) = mk_project();
        my $runs = "$bpdir/runs";
        my $pkg = 'deferred';
        my ($id, $item_id) = mk_answered_fixture(P => $P, bpdir => $bpdir, bp => $bp, runs => $runs, pkg => $pkg, choice => 'relaunch', question => 'q-deferred');
        my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
        my $answer6 = sub { return 6; };
        tick_bridge($ctx, status => { $pkg => 'blocked' }, answer => $answer6);
        my $item = Almanac::Inbox::read_item($item_id, root => $P);
        ok(!exists $item->{fields}{closed_at}, 'AC4: rc=6 leaves the item open (not closed)');
        is($item->{fields}{status}, 'answered', 'AC4: rc=6 leaves the item in answered state');
        ok(-f decision_path($runs, $id), 'AC4: rc=6 leaves the escalation untouched');
        tick_bridge($ctx, status => { $pkg => 'blocked' }, answer => $answer6);
        my $log = slurp("$runs/orchestrator.log") // '';
        my $n = () = ($log =~ /inbox_answer_deferred/g);
        is($n, 1, 'AC4: inbox_answer_deferred logged exactly once across two ticks (once-per-item-per-process)');
    }
    # rc=2: failed -> closed with the failure reason, AND a fresh item is
    # filed in the same tick (the record is still operator-owned).
    {
        my ($P, $bpdir, $bp) = mk_project();
        my $runs = "$bpdir/runs";
        my $pkg = 'failed2';
        my ($id, $item_id) = mk_answered_fixture(P => $P, bpdir => $bpdir, bp => $bp, runs => $runs, pkg => $pkg, choice => 'relaunch', question => 'q-failed2');
        my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
        tick_bridge($ctx, status => { $pkg => 'blocked' }, answer => sub { return 2; });
        my $item = Almanac::Inbox::read_item($item_id, root => $P);
        ok(exists $item->{fields}{closed_at}, 'AC4: rc=2 closes the old item');
        is($item->{fields}{closed_reason}, 'answer relaunch could not be applied (bp-answer-escalation exit 2)',
            'AC4: exact rc=2 closed_reason text');
        ok(-f decision_path($runs, $id), 'AC4: rc=2 leaves the escalation on disk, still operator-owned');
        my $still_open = open_items($P, $bp);
        is(scalar @$still_open, 1, 'AC4: a fresh unanswered item is filed in the SAME tick (still product/operator-owned)');
        is($still_open->[0]{fields}{status}, 'unanswered', 'AC4: the fresh item is unanswered');
    }
});

run_group('DC2-AC17 (inbox_link_for and inbox_resolve_link, the link state machine)', sub {
    my ($P, $bpdir, $bp) = mk_project('wtg');
    my $runs = "$bpdir/runs";

    is(BpOrch::inbox_link_for('wtg', '_fleet', '_fleet--1a'), 'wtg/fleet/fleet--1a', 'AC17: fleet link strips leading underscores from both segments');
    is(BpOrch::inbox_link_for('wtg', '03-x', '03-x--9f'), 'wtg/03-x/03-x--9f', 'AC17: ordinary package link is unchanged');
    is(BpOrch::inbox_link_for('wtg', ('x' x 129), 'id--1'), undef, 'AC17: a 129-byte package segment -> undef');
    is(BpOrch::inbox_link_for('wtg', 'pkg..x', 'id--1'), undef, 'AC17: a package segment containing ".." -> undef');

    write_file("$runs/escalations/pkgA--1.json", $J->encode({ package => 'pkgA', kind => 'stuck-package' }));
    my $found = BpOrch::inbox_resolve_link($runs, 'wtg', 'wtg/pkgA/pkgA--1');
    is($found->{state}, 'found', 'AC17: found when exactly one candidate matches');
    is($found->{id}, 'pkgA--1', 'AC17: found.id is the real escalation id');

    my $gone = BpOrch::inbox_resolve_link($runs, 'wtg', 'wtg/pkgB/pkgB--9');
    is($gone->{state}, 'gone', 'AC17: gone when neither candidate file exists');

    write_file("$runs/escalations/unreadable--1.json", "not json at all");
    my $unread = BpOrch::inbox_resolve_link($runs, 'wtg', 'wtg/unreadable/unreadable--1');
    is($unread->{state}, 'unreadable', 'AC17: unreadable for a non-JSON-object candidate file');

    is(BpOrch::inbox_resolve_link($runs, 'other-bp', 'wtg/pkgA/pkgA--1')->{state}, 'foreign', 'AC17: foreign when seg1 ne bp');
    is(BpOrch::inbox_resolve_link($runs, 'wtg', 'wtg/onlytwo')->{state}, 'foreign', 'AC17: foreign when the link is not 3 segments');

    write_file("$runs/escalations/fleet--1a.json",  $J->encode({ package => 'fleet',  kind => 'reauth' }));
    write_file("$runs/escalations/_fleet--1a.json", $J->encode({ package => '_fleet', kind => 'reauth' }));
    is(BpOrch::inbox_resolve_link($runs, 'wtg', 'wtg/fleet/fleet--1a')->{state}, 'ambiguous', 'AC17: ambiguous when both candidates match');
});

# ═══════════════════════════════════════════════════════════════════════════
# DC3 (AC5, AC6): done/dropped settles escalation+item; orphan item closes.
# ═══════════════════════════════════════════════════════════════════════════
for my $status (qw(done dropped)) {
    run_group("DC3-AC5 (package reaches $status: escalation archived, item closed, even if pre-answered)", sub {
        my ($P, $bpdir, $bp) = mk_project();
        my $runs = "$bpdir/runs";
        my $pkg = "settle_$status";
        write_ledger($bpdir, $pkg, 'blocked', bp => $bp);
        my ($id, $path, $filed) = file_escalation($runs, pkg => $pkg, bp => $bp, kind => 'stuck-package', category => 'product', question => 'q');
        my $item = Almanac::Inbox::file(root => $P, title => 'q', link => "$bp/$pkg/$id", choices => 'relaunch,accept,drop,not-mine');
        # The escalation was filed while the package was still live; it later
        # actually reached $status on disk (flip in place, as set_ledger_status's
        # own doc comment describes, to avoid queue_needs_you's done/dropped
        # refusal gate at filing time).
        set_ledger_status($bpdir, $pkg, $status);
        my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
        tick_bridge($ctx, status => { $pkg => $status }, answer => sub { fail("AC5: answer seam must never be invoked once the package has settled"); return 1; });

        my $arc = read_json(archive_path($runs, $id));
        ok(ref $arc eq 'HASH', "AC5 ($status): an archive record exists") or diag("no archive at " . archive_path($runs, $id));
        if (ref $arc eq 'HASH') {
            is($arc->{resolved_by}, 'auto-settle', "AC5 ($status): resolved_by is auto-settle");
            is($arc->{reason}, "package reached $status", "AC5 ($status): exact settle reason");
        }
        ok(!-f decision_path($runs, $id), "AC5 ($status): escalation file gone");
        my $after = Almanac::Inbox::read_item($item->{id}, root => $P);
        is($after->{fields}{closed_reason}, "escalation $id closed: package reached $status", "AC5 ($status): exact item closed_reason");
        is(ledger_status($bpdir, $pkg), $status, "AC5 ($status): ledger stays $status (an answer never applies to a settled package)");
    });
}

run_group('DC3-AC6 (orphan item: no-archive reason vs archive-derived reason)', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";

    # No archive at all -- deleted by hand.
    {
        my $pkg = 'orphan1';
        write_ledger($bpdir, $pkg, 'blocked', bp => $bp);
        my ($id) = file_escalation($runs, pkg => $pkg, bp => $bp, kind => 'stuck-package', category => 'product', question => 'q');
        my $item = Almanac::Inbox::file(root => $P, title => 'q', link => "$bp/$pkg/$id", choices => 'relaunch,accept,drop,not-mine');
        unlink decision_path($runs, $id);
        my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
        tick_bridge($ctx, status => { $pkg => 'blocked' });
        my $after = Almanac::Inbox::read_item($item->{id}, root => $P);
        is($after->{fields}{closed_reason}, "linked escalation $bp/$pkg/$id no longer exists", 'AC6: exact no-archive reason text');
    }
    # Archived by a resolver act -- no 'reason' key, resolved_by present.
    {
        my $pkg = 'orphan2';
        write_ledger($bpdir, $pkg, 'blocked', bp => $bp);
        my ($id) = file_escalation($runs, pkg => $pkg, bp => $bp, kind => 'stuck-package', category => 'product', question => 'q');
        my $item = Almanac::Inbox::file(root => $P, title => 'q', link => "$bp/$pkg/$id", choices => 'relaunch,accept,drop,not-mine');
        unlink decision_path($runs, $id);
        write_file(archive_path($runs, $id), $J->encode({ original => {}, resolved_by => 'bp-escalation-resolver', applied => JSON::PP::true }));
        my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
        tick_bridge($ctx, status => { $pkg => 'blocked' });
        my $after = Almanac::Inbox::read_item($item->{id}, root => $P);
        is($after->{fields}{closed_reason}, "escalation $id closed: resolved by bp-escalation-resolver", 'AC6: archive-derived reason when resolved_by is present with no reason key');
    }
});

# ═══════════════════════════════════════════════════════════════════════════
# DC4 (AC7, AC8): broken-env is F2 (resolver-unavailable fallback); reauth
# and contract-drift are F1 (already operator-owned, filed directly).
# ═══════════════════════════════════════════════════════════════════════════
run_group('DC4-AC7 (broken-env: unclassified + _fleet -> F2 fallback filing)', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    my ($id) = file_escalation($runs, pkg => '_fleet', bp => $bp, kind => 'broken-env', category => 'unclassified', question => 'The coordinator cannot execute.');
    like($id, qr/^_fleet--/, 'AC7 setup: broken-env id carries the _fleet pseudo-package prefix');
    my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
    tick_bridge($ctx, status => {});
    my $items = open_items($P, $bp);
    is(scalar @$items, 1, 'AC7: broken-env gets exactly one item via F2 (no resolver path for _fleet)');
    if (@$items) {
        my $f = $items->[0]{fields};
        is($f->{choices}, 'resume', 'AC7: fleet-family choices are resume only');
        (my $want_link = "$bp/fleet/" . $id) =~ s/^_fleet--/fleet--/ if 0; # link seg3 strips leading underscore too
        (my $seg3 = $id) =~ s/^_//;
        is($f->{link}, "$bp/fleet/$seg3", 'AC7: link is <bp>/fleet/<id-without-leading-underscore>');
        like($items->[0]{body} // '', qr/The escalation resolver could not triage this escalation\./, 'AC7: F2 body line present');
    }
});

run_group('DC4-AC8 (reauth / contract-drift: already operator-owned, filed F1, no F2 line; answering resume closes)', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    for my $kind (qw(reauth contract-drift)) {
        my ($id) = file_escalation($runs, pkg => '_fleet', bp => $bp, kind => $kind, category => 'operator-action', question => "manual pause ($kind)");
        my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
        tick_bridge($ctx, status => {});
        my $items = open_items($P, $bp);
        my ($mine) = grep { $_->{fields}{link} =~ /\Q$id\E/ || 1 } @$items; # single item expected per kind in this bp
        ok(scalar(@$items) >= 1, "AC8: $kind is filed directly (F1, operator-owned already)");
        my $f = $items->[-1]{fields};
        is($f->{choices}, 'resume', "AC8: $kind choices are resume only");
        unlike($items->[-1]{body} // '', qr/The escalation resolver could not triage/, "AC8: $kind body carries NO F2 line (direct auth/contract path)");

        # Per spec SS3.1 S2, the bridge only invokes the answer seam for an item
        # that is 'found' AND status eq 'answered'; answer it first so the next
        # tick actually exercises that path.
        my ($rc_ans, $out_ans) = run_inbox_cli('answer', $items->[-1]{id}, '--choice', 'resume', '--root', $P);
        is($rc_ans, 0, "AC8: $kind item answered 'resume' via almanac-inbox.pl") or diag($out_ans);

        tick_bridge($ctx, status => {}, answer => sub { return 0; });
        my $after = Almanac::Inbox::read_item($items->[-1]{id}, root => $P);
        is($after->{fields}{closed_reason}, 'answer applied: resume', "AC8: $kind item closes with 'answer applied: resume'");
    }
});

# ═══════════════════════════════════════════════════════════════════════════
# DC5 (AC9, AC10): not-mine requeues in place as implementation; CLI-level
# not-mine semantics.
# ═══════════════════════════════════════════════════════════════════════════
run_group('DC5-AC9 (not-mine requeues in place, closes the item, files nothing new)', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    my $pkg = 'notmine';
    my ($id, $item_id) = mk_answered_fixture(P => $P, bpdir => $bpdir, bp => $bp, runs => $runs, pkg => $pkg,
        choice => 'not-mine', note => 'write set is yours', question => 'q-notmine');
    my ($ctx) = setup_ctx(bp => $bp, bpdir => $bpdir, runs => $runs);
    tick_bridge($ctx, status => { $pkg => 'blocked' }, answer => make_answer_cb($bp, $bpdir));

    my $rec = read_json(decision_path($runs, $id));
    ok(ref $rec eq 'HASH', 'AC9: the escalation file still exists (requeued in place, never deleted)');
    is($rec->{category}, 'implementation', 'AC9: category becomes implementation');
    is($rec->{operator_note}, 'write set is yours', 'AC9: operator_note carries the note');
    is($rec->{returned_by}, 'operator', 'AC9: returned_by operator');
    like($rec->{returned_at} // '', qr/^\d+$/, 'AC9: returned_at is numeric epoch');
    for my $gone_key (qw(resolved_by confidence evidence resolution product_question)) {
        ok(!exists $rec->{$gone_key}, "AC9: $gone_key is removed from the requeued record");
    }
    my $item = Almanac::Inbox::read_item($item_id, root => $P);
    is($item->{fields}{closed_reason}, 'answer applied: not-mine (returned to the escalation resolver)', 'AC9: exact not-mine closed_reason');
    is(scalar(@{ open_items($P, $bp) }), 0, 'AC9: no new item is filed while the record is implementation (not operator-owned)');

    # Continuation: the next unpaused tick's dispatch picks this record up
    # (bounded, deterministic probe -- see file header note).
    my $spawned = run_dispatch_probe(bp => $bp, bpdir => $bpdir, pkg => $pkg);
    ok((grep { ($_->{kind} // '') eq 'escalation-resolve' && ($_->{pkg} // '') eq $pkg } @$spawned),
        'AC9: the requeued record is picked up by the escalation-resolve dispatch on a later tick')
        or diag('spawned: ' . $J->encode($spawned));
    my $decf = slurp("$runs/escalation-resolve/$pkg.decision");
    is($decf, $id, 'AC9: the dispatch names this exact escalation id in its decision file') if defined $decf;
});

sub run_dispatch_probe {
    my (%o) = @_;
    my ($bp, $bpdir, $pkg) = @o{qw(bp bpdir pkg)};
    my $runs = "$bpdir/runs";
    write_file("$bpdir/blueprint.md",
        "# T\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n"
      . "| $pkg | d | \x{2014} | sonnet | blocked |\n");
    write_file("$bpdir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => (time + 100*3600) * 1000, scopes => ['user:inference'], subscriptionType => 'max', rateLimitTier => 'x' } }));
    my @spawned;
    my $clock = time;
    my $tick = 0;
    eval {
        BpOrch::run({
            blueprint => $bp, bp_dir => $bpdir, creds_path => "$bpdir/creds.json",
            tunables => { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>120, watch_tick=>60,
                          keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0, tele_retry=>3,
                          usage_fail=>60, busy_path=>"$bpdir/busy", harvest=>'audit', resolve_cap=>1,
                          corr_cap=>1, judge_to=>100000, judge_spawn_cap=>3 },
            now => sub { $clock }, sleep => sub { $clock += ($_[0] // 0); $tick++; die "PROBE: stop\n" if $tick > 15; },
            http_get => sub { { status => 200, content => $J->encode({ five_hour=>{utilization=>10,resets_at=>'2099-01-01T00:00:00+00:00'}, seven_day=>{utilization=>5,resets_at=>'2099-01-01T12:00:00+00:00'} }) } },
            http_post => sub { { status => 200, content => '{}' } },
            launch => sub { 0 }, pid_alive => sub { 0 },
            spawn_judge => sub { push @spawned, { %{ $_[0] } }; return 0; },
        });
        1;
    };
    return \@spawned;
}

run_group('DC5-AC10 (not-mine CLI semantics)', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    write_ledger($bpdir, 'cliA', 'blocked', bp => $bp);
    my ($id, $path, $filed) = file_escalation($runs, pkg => 'cliA', bp => $bp, kind => 'stuck-package', category => 'product', question => 'q');
    my $before_ledger = ledger_text($bpdir, 'cliA');
    my $before_reg = slurp("$runs/registry.json");

    my ($rc, $out) = run_answer_cli($bp, '--decision', $id, '--action', 'not-mine', '--note', 'n', '--bp-dir', $bpdir);
    is($rc, 0, 'AC10: --decision --action not-mine exits 0') or diag($out);
    my $decoded = eval { $J->decode($out) };
    ok(ref $decoded eq 'HASH', 'AC10: stdout is parseable JSON') or diag($out);
    if (ref $decoded eq 'HASH') {
        ok($decoded->{requeued}, 'AC10: JSON carries requeued:true');
        is($decoded->{action}, 'not-mine', 'AC10: JSON action is not-mine');
        is($decoded->{family}, 'package', 'AC10: JSON family is package');
    }
    is(ledger_text($bpdir, 'cliA'), $before_ledger, 'AC10: ledger bytes unchanged by not-mine');
    is(slurp("$runs/registry.json"), $before_reg, 'AC10: registry bytes unchanged by not-mine');
    ok(!-f "$runs/.paused", 'AC10: .paused untouched (still absent)');

    write_ledger($bpdir, 'cliB', 'blocked', bp => $bp);
    my ($id2) = file_escalation($runs, pkg => 'cliB', bp => $bp, kind => 'stuck-package', category => 'product', question => 'q2');
    my ($rc2, $out2) = run_answer_cli($bp, '--package', 'cliB', '--action', 'not-mine', '--bp-dir', $bpdir);
    is($rc2, 2, 'AC10: --package with --action not-mine exits 2');
    like($out2, qr/\Q--action not-mine requires --decision (it re-queues one escalation)\E/,
        'AC10: the exact 2.7 refusal message for --package + not-mine') or diag($out2);

    my ($id3) = file_escalation($runs, pkg => '_fleet', bp => $bp, kind => 'reauth', category => 'operator-action', question => 'manual');
    my ($rc3, $out3) = run_answer_cli($bp, '--decision', $id3, '--action', 'not-mine', '--bp-dir', $bpdir);
    isnt($rc3, 0, 'AC10: a fleet-kind decision with --action not-mine is refused');

    my $plan = BpAnswer::plan_answer('stuck-package', 'not-mine');
    is_deeply($plan, { ok => 1, family => 'package', action => 'not-mine', requeue => 1, ledger_status => undef,
                        clear_pause => 0, relaunch => 0, reset_attempt => 0, reset_resolve => 0, supersede => 0, clear_session => 0 },
        "AC10: plan_answer('stuck-package','not-mine') returns the exact 2.7 hash");
});

# ═══════════════════════════════════════════════════════════════════════════
# DC6 (AC11): no orchestrator call site files product/operator-action except
# the auth/contract sites; no bare 'product' literal; the broken-env call
# carries unclassified.
# ═══════════════════════════════════════════════════════════════════════════
run_group('DC6-AC11 (comment-stripped source scan: only auth/contract sites set the operator-owned pair)', sub {
    my $src = slurp($ORCH_SCRIPT) // '';
    # Same stripping technique as escalation-categories.t.
    (my $code = $src) =~ s/^\s*#.*$//mg;
    $code =~ s/(?<!['"])#(?![\w-]*['"]).*$//mg;

    my @matches;
    while ($code =~ /category\s*=>\s*['"](product|operator-action|operational)['"]/g) {
        push @matches, { pos => pos($code), val => $1 };
    }
    is(scalar(@matches), 6, 'AC11: exactly 6 call sites set category to product/operator-action/operational')
        or diag('found at positions: ' . join(',', map { "$_->{pos}:$_->{val}" } @matches));
    for my $m (@matches) {
        my $lo = $m->{pos} > 1500 ? $m->{pos} - 1500 : 0;
        my $window = substr($code, $lo, 1500);
        like($window, qr/kind\s*=>\s*['"](reauth|contract-drift)['"]/,
            "AC11: the match at pos $m->{pos} (val=$m->{val}) is inside a reauth/contract-drift call");
    }
    unlike($code, qr/'product'/, "AC11: no bare 'product' string literal anywhere in code");

    while ($code =~ /kind\s*=>\s*['"]broken-env['"]/g) {
        my $pos = pos($code);
        my $lo = $pos > 400 ? $pos - 400 : 0;
        my $hi = ($pos + 400 > length($code)) ? length($code) : $pos + 400;
        my $window = substr($code, $lo, $hi - $lo);
        like($window, qr/category\s*=>\s*['"]unclassified['"]/, 'AC11: the broken-env call carries category=>unclassified');
        unlike($window, qr/category\s*=>\s*['"](product|operator-action)['"]/, 'AC11: the broken-env call does NOT carry product/operator-action');
    }

    while ($code =~ /_block_and_queue\(((?:[^()]|\([^()]*\))*)\)/gs) {
        my $args = $1;
        my @quoted = ($args =~ /['"]([^'"]*)['"]/g);
        my $last = @quoted ? $quoted[-1] : undef;
        ok(!(defined $last && $last =~ /^(product|operator-action|operational)$/),
            "AC11: a _block_and_queue(...) call's last quoted argument is not product/operator-action/operational (got '" . ($last // '') . "')");
    }
});

# ═══════════════════════════════════════════════════════════════════════════
# DC7 (AC12, AC13): standalone sweep.
# ═══════════════════════════════════════════════════════════════════════════
sub snapshot_tree {
    my ($dir) = @_;
    my %snap;
    return \%snap unless -d $dir;
    my @stack = ($dir);
    while (@stack) {
        my $d = pop @stack;
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = "$d/$e";
            if (-d $p) { push @stack, $p; }
            else { $snap{$p} = slurp($p); }
        }
        closedir $dh;
    }
    return \%snap;
}

run_group('DC7-AC12 (sweep closes settled + orphans, idempotent on a second run, no marker)', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";

    write_ledger($bpdir, 'swdone', 'blocked', bp => $bp);
    my ($id_done) = file_escalation($runs, pkg => 'swdone', bp => $bp, kind => 'stuck-package', category => 'product', question => 'q');
    my $item_done = Almanac::Inbox::file(root => $P, title => 'q', link => "$bp/swdone/$id_done", choices => 'relaunch,accept,drop,not-mine');
    set_ledger_status($bpdir, 'swdone', 'done');

    write_ledger($bpdir, 'swdropped', 'blocked', bp => $bp);
    my ($id_drop) = file_escalation($runs, pkg => 'swdropped', bp => $bp, kind => 'stuck-package', category => 'product', question => 'q');
    my $item_drop = Almanac::Inbox::file(root => $P, title => 'q', link => "$bp/swdropped/$id_drop", choices => 'relaunch,accept,drop,not-mine');
    set_ledger_status($bpdir, 'swdropped', 'dropped');

    my $orphan_item = Almanac::Inbox::file(root => $P, title => 'orphan', link => "$bp/gone/gone--1", choices => 'relaunch,accept,drop,not-mine');

    write_ledger($bpdir, 'swpending', 'pending', bp => $bp);
    my ($id_pend) = file_escalation($runs, pkg => 'swpending', bp => $bp, kind => 'stuck-package', category => 'product', question => 'q');
    my $item_pend = Almanac::Inbox::file(root => $P, title => 'q', link => "$bp/swpending/$id_pend", choices => 'relaunch,accept,drop,not-mine');

    my ($rc, $out) = run_answer_cli('sweep', '--bp-dir', $bpdir);
    is($rc, 0, 'AC12: sweep exits 0') or diag($out);
    my $decoded = eval { $J->decode($out) };
    ok(ref $decoded eq 'HASH', 'AC12: sweep prints a JSON object') or diag($out);
    if (ref $decoded eq 'HASH') {
        is($decoded->{swept}, 2, 'AC12: swept=2 (the two settled escalations)');
        is($decoded->{inbox_closed}, 3, 'AC12: inbox_closed=3 (2 settled + 1 orphan)');
    }

    ok(-f archive_path($runs, $id_done), 'AC12: swdone archived');
    ok(-f archive_path($runs, $id_drop), 'AC12: swdropped archived');
    ok(-f decision_path($runs, $id_pend), 'AC12: swpending escalation still queued (untouched)');

    for my $pair ([$item_done, 'swdone'], [$item_drop, 'swdropped'], [$orphan_item, 'orphan']) {
        my ($it, $label) = @$pair;
        my $after = Almanac::Inbox::read_item($it->{id}, root => $P);
        ok(exists $after->{fields}{closed_at}, "AC12: $label item closed");
        is($after->{fields}{closed_by}, 'sweep', "AC12: $label item closed_by sweep");
    }
    my $pend_after = Almanac::Inbox::read_item($item_pend->{id}, root => $P);
    ok(!exists $pend_after->{fields}{closed_at}, 'AC12: the pending package item is untouched');

    my $snap1 = snapshot_tree($runs);
    my ($rc2, $out2) = run_answer_cli('sweep', '--bp-dir', $bpdir);
    is($rc2, 0, 'AC12: a second sweep exits 0');
    my $decoded2 = eval { $J->decode($out2) };
    is($decoded2->{swept}, 0, 'AC12: second run swept=0');
    is($decoded2->{inbox_closed}, 0, 'AC12: second run inbox_closed=0');
    my $snap2 = snapshot_tree($runs);
    is_deeply($snap2, $snap1, 'AC12: a second sweep changes no file under runs/ (byte- and name-identical)');
});

run_group('DC7-AC13 (a live orchestrator marker makes sweep a byte-exact no-op)', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    write_ledger($bpdir, 'live1', 'blocked', bp => $bp);
    my ($id) = file_escalation($runs, pkg => 'live1', bp => $bp, kind => 'stuck-package', category => 'product', question => 'q');
    Almanac::Inbox::file(root => $P, title => 'q', link => "$bp/live1/$id", choices => 'relaunch,accept,drop,not-mine');
    set_ledger_status($bpdir, 'live1', 'done');

    open(my $mfh, '>', "$runs/.orchestrator") or die "marker: $!";
    require Fcntl; Fcntl->import(qw(:flock));
    flock($mfh, Fcntl::LOCK_EX()) or die "flock: $!";

    my $before_runs = snapshot_tree($runs);
    my $before_almanac = snapshot_tree("$P/.ccpraxis-local-data/almanac");
    my ($rc, $out) = run_answer_cli('sweep', '--bp-dir', $bpdir);
    is($rc, 0, 'AC13: sweep still exits 0 while the marker is live');
    chomp(my $line = $out);
    is($line,
       '{"inbox_available":false,"inbox_closed":0,"inbox_ids":[],"ids":[],"orchestrator_live":true,"run_over":false,"swept":0}',
       'AC13: exact live-marker JSON, one line');
    is_deeply(snapshot_tree($runs), $before_runs, 'AC13: no file under runs/ changed');
    is_deeply(snapshot_tree("$P/.ccpraxis-local-data/almanac"), $before_almanac, 'AC13: no almanac-side file changed either (not even migration/absorb)');
    close($mfh);

    # An unlocked marker file does NOT block the sweep.
    open(my $f2, '>', "$runs/.orchestrator") or die $!;
    print $f2 "stale\n"; close $f2;
    my ($rc2, $out2) = run_answer_cli('sweep', '--bp-dir', $bpdir);
    my $decoded2 = eval { $J->decode($out2) };
    ok(ref $decoded2 eq 'HASH' && $decoded2->{swept} == 1,
       'AC13: an unlocked marker file does not block the sweep (live1 gets swept)') or diag($out2);

    # `<bp> --sweep` behaves identically to the verb form.
    my ($P2, $bpdir2, $bp2) = mk_project();
    my $runs2 = "$bpdir2/runs";
    write_ledger($bpdir2, 'v2', 'blocked', bp => $bp2);
    my ($id2) = file_escalation($runs2, pkg => 'v2', bp => $bp2, kind => 'stuck-package', category => 'product', question => 'q');
    Almanac::Inbox::file(root => $P2, title => 'q', link => "$bp2/v2/$id2", choices => 'relaunch,accept,drop,not-mine');
    set_ledger_status($bpdir2, 'v2', 'done');
    my ($rc3, $out3) = run_answer_cli($bp2, '--sweep', '--bp-dir', $bpdir2);
    is($rc3, 0, 'AC13: `<bp> --sweep` form exits 0');
    my $decoded3 = eval { $J->decode($out3) };
    ok(ref $decoded3 eq 'HASH' && $decoded3->{swept} == 1, 'AC13: `<bp> --sweep` performs the same new behaviour as the verb form') or diag($out3);
});

# ═══════════════════════════════════════════════════════════════════════════
# DC8 (AC14, and the AC15/AC16-equivalent checks this write-set constraint
# forces into THIS file rather than resolve-verdict-gates.t /
# resolve-dispatch-and-guards.t): the resolver bar, product_question
# required, apply_verdict's refusal, and chronic-scoping -> unclassified.
# ═══════════════════════════════════════════════════════════════════════════
run_group('DC8-AC14 (bp-escalation-resolver.md carries the bar verbatim + the product_question contract)', sub {
    ok(-f $AGENT_FILE, 'AC14: bp-escalation-resolver.md exists') or diag("not found at $AGENT_FILE");
    SKIP: {
        skip 'agent file does not exist yet', 5 unless -f $AGENT_FILE;
        my $txt = slurp($AGENT_FILE) // '';
        my $bar = q{product decisions or very unexpected findings that would change the product, never technical details within the agent's purview such as "Should package XX change its write set to YYY to satisfy test ZZZ?"};
        ok(index($txt, $bar) >= 0, 'AC14: the operator\'s bar appears byte-for-byte (straight ASCII double quotes)') or diag('bar not found verbatim');
        like($txt, qr/"product_question"/, 'AC14: the output-contract JSON block contains a "product_question" key');
        like($txt, qr/`product_question` is REQUIRED when `category` is `product` or `operator-action`/,
            'AC14: the exact REQUIRED-when sentence appears');
        like($txt, qr/operator_note/, 'AC14: the prompt mentions operator_note (settling a not-mine-returned record itself)');
        unlike($txt, qr/falls back\s+to\s+`product`/, 'AC14: the old "falls back to `product`" wording no longer appears');
    }
});

run_group('DC8-AC15-equiv (verdict_shape_ok/confidence_gate require product_question for the operator-owned pair)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    for my $cat (qw(product operator-action)) {
        my $v = { category => $cat, confidence => 'low', evidence => 'e' };
        my ($ok, $why) = BpResolve::verdict_shape_ok($v);
        ok(!$ok, "DC8: a $cat verdict missing product_question is NOT shape_ok");
        is($why, "missing required key 'product_question' for category=$cat", "DC8: exact refusal message for $cat");
        is(BpResolve::confidence_gate($v), 'refuse', "DC8: confidence_gate refuses $cat missing product_question");

        for my $bad ('', '  ') {
            my $v2 = { %$v, product_question => $bad };
            my ($ok2) = BpResolve::verdict_shape_ok($v2);
            ok(!$ok2, "DC8: $cat with product_question='$bad' is NOT shape_ok");
        }
        my $v2b = { %$v, product_question => [1,2] };
        my ($ok2b) = BpResolve::verdict_shape_ok($v2b);
        ok(!$ok2b, "DC8: $cat with a reference product_question is NOT shape_ok");

        my $v3 = { %$v, product_question => 'Q' };
        my ($ok3, $why3) = BpResolve::verdict_shape_ok($v3);
        ok($ok3, "DC8: $cat with a real product_question IS shape_ok") or diag($why3 // '?');
        is(BpResolve::confidence_gate($v3), 'tag-only', "DC8: confidence_gate -> tag-only once product_question is present");
    }
});

run_group('DC8-AC16-equiv (apply_verdict rejects a missing product_question; tags it when present; chronic-scoping files unclassified)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    write_ledger($bpdir, 'dc8a', 'blocked', bp => $bp);
    my ($id, $path, $filed) = file_escalation($runs, pkg => 'dc8a', bp => $bp, kind => 'stuck-package', category => 'unclassified', question => 'q');
    my $before = slurp($path);
    my $outcome = BpResolve::apply_verdict({ category => 'product', confidence => 'high', evidence => 'e' }, $filed, $id,
        { bpdir => $bpdir, runs => $runs, bp => $bp, log => "$runs/orchestrator.log" });
    is($outcome->{outcome}, 'refuse', 'AC16: a product verdict missing product_question is refused by apply_verdict');
    is(slurp($path), $before, 'AC16: the queue file is byte-identical after the refusal');
    like(slurp("$runs/orchestrator.log") // '', qr/escalation_resolve_refused/, 'AC16: escalation_resolve_refused logged');

    write_ledger($bpdir, 'dc8b', 'blocked', bp => $bp);
    my ($id2, $path2, $filed2) = file_escalation($runs, pkg => 'dc8b', bp => $bp, kind => 'stuck-package', category => 'unclassified', question => 'q2');
    my $outcome2 = BpResolve::apply_verdict({ category => 'product', confidence => 'high', evidence => 'e', product_question => '  Q2  ' }, $filed2, $id2,
        { bpdir => $bpdir, runs => $runs, bp => $bp, log => "$runs/orchestrator.log" });
    is($outcome2->{outcome}, 'tag-only', 'AC16: with product_question present it lands tag-only');
    my $tagged = read_json($path2);
    is($tagged->{product_question}, 'Q2', 'AC16: product_question is trimmed and carried onto the tagged record');

    write_ledger($bpdir, 'dc8c', 'blocked', bp => $bp);
    BpOrch::update_registry_pkg($runs, 'dc8c', { chronic_scoping_count => 2 });
    BpResolve::_bump_chronic_scoping_counter({ package => 'dc8c' }, 'dc8c--prior', { rationale => 'r' }, { runs => $runs, bp => $bp, bpdir => $bpdir });
    opendir(my $dh, "$runs/escalations") or die $!;
    my ($chronic_file) = grep { /^dc8c--/ } readdir $dh;
    closedir $dh;
    ok(defined $chronic_file, 'AC16: the >2 crossing files a chronic-scoping record');
    if (defined $chronic_file) {
        my $rec = read_json("$runs/escalations/$chronic_file");
        is($rec->{kind}, 'chronic-scoping', 'AC16: kind is chronic-scoping');
        is($rec->{category}, 'unclassified', 'AC16: chronic-scoping now files category=unclassified (was product)');
    }
});

# ═══════════════════════════════════════════════════════════════════════════
# DC9 (AC19, AC20): the disabled bridge touches nothing; the suite itself
# never launches launcher.pl/podman/claude.
# ═══════════════════════════════════════════════════════════════════════════
run_group('DC9-AC19 (inbox_bridge disabled: no almanac file, no new %INC entry)', sub {
    my ($P, $bpdir, $bp) = mk_project();
    write_file("$bpdir/blueprint.md",
        "# T\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n"
      . "| only | d | \x{2014} | sonnet | pending |\n");
    write_file("$bpdir/packages/only.md",
        "---\npackage: only\nblueprint: $bp\nstatus: pending\nwrite_set: p/only/\n"
      . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# only\n\n## Next action\n\ngo\n");
    write_file("$bpdir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => (time + 100*3600) * 1000, scopes => ['user:inference'], subscriptionType => 'max', rateLimitTier => 'x' } }));
    my %inc_before = %INC;
    my $clock = time; my $tick = 0;
    eval {
        BpOrch::run({
            blueprint => $bp, bp_dir => $bpdir, creds_path => "$bpdir/creds.json",
            tunables => { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>120, watch_tick=>60,
                          keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0, tele_retry=>3,
                          usage_fail=>60, busy_path=>"$bpdir/busy", harvest=>'audit', resolve_cap=>1,
                          corr_cap=>1, judge_to=>100000, judge_spawn_cap=>3 },
            now => sub { $clock }, sleep => sub { $clock += ($_[0] // 0); $tick++; die "PROBE: stop\n" if $tick > 10; },
            http_get => sub { { status => 200, content => $J->encode({ five_hour=>{utilization=>10,resets_at=>'2099-01-01T00:00:00+00:00'}, seven_day=>{utilization=>5,resets_at=>'2099-01-01T12:00:00+00:00'} }) } },
            http_post => sub { { status => 200, content => '{}' } },
            launch => sub { { my ($a) = @_; BpOrch::update_registry_pkg("$bpdir/runs", $a->{pkg}, { pid=>1, status=>'running', attempt=>1 }); 0; } },
            pid_alive => sub { 0 },
            spawn_judge => sub { 0 },
            # inbox_bridge omitted -> defaults false.
        });
        1;
    };
    my @new_inc = grep { !exists $inc_before{$_} } keys %INC;
    ok(!(grep { /almanac-inbox\.pl/ } @new_inc), 'AC19: run() with inbox_bridge disabled loads no NEW almanac-inbox.pl %INC entry')
        or diag('new INC entries: ' . join(',', @new_inc));
    ok(!-d "$P/.ccpraxis-local-data/almanac", 'AC19: run() with inbox_bridge disabled creates no almanac tree at all');
});

run_group('DC9-AC20 (this suite never actually invokes launcher.pl/podman/claude)', sub {
    my $self = slurp($SELF) // '';
    # Scope the check to the file's EXECUTABLE surface (backtick / system(...)
    # subprocess calls), not its English prose -- this file's own header
    # comments and group labels legitimately quote the spec's own "nothing
    # launches launcher.pl, podman or claude" wording, which a bare substring
    # scan over the whole file would trip on itself. The forbidden tokens are
    # built by concatenation so this very check does not itself contain them
    # as literal substrings either.
    my @exec_lines = grep { /`|\bsystem\s*\(/ } split /\n/, $self;
    my $exec_text = join("\n", @exec_lines);
    my $bad_launcher = 'launcher' . '.pl';
    my $bad_podman   = 'pod' . 'man';
    my $bad_claude   = 'cla' . 'ude';
    unlike($exec_text, qr/\Q$bad_launcher\E/, 'AC20: no subprocess call in this file names launcher.pl');
    unlike($exec_text, qr/\Q$bad_podman\E/i, 'AC20: no subprocess call in this file names podman');
    unlike($exec_text, qr/\Q$bad_claude\E/i, 'AC20: no subprocess call in this file names the claude binary');
});

# ═══════════════════════════════════════════════════════════════════════════
# FIX-BATCH ROUND 1 REGRESSION ORACLE (where-things-go Decision 47, round 1 of
# 2): drives the bridge through a REAL BpOrch::run({inbox_bridge=>1,
# fleet_thread=>1, ...}) per AC1/AC3's own stated intent, instead of calling
# _inbox_bridge_tick directly the way every group above does (reviewer-1.md
# S4: "tests never drive the bridge through run(), so the integration M1
# lives in is untested"). Written BEFORE the round-1 fixes land -- every
# assertion below encodes the CORRECT behavior and is expected to be RED
# against the code on disk today:
#   - reviewer-1.md M1: a bridge-applied relaunch/reset answer is re-escalated
#     by the SAME tick's orphan-reconciliation pass (stale pre-answer $status).
#   - redteam-1.md  M1: the bridge authorizes ANY item carrying a matching
#     `link`, including one it never filed itself -- no check that the item's
#     `choices` match what the bridge would have offered, and no check that
#     the linked escalation is even F1/F2-eligible right now.
# ═══════════════════════════════════════════════════════════════════════════
{
    no warnings 'once';
    require "$Bin/../../../almanac/scripts/Almanac/Thread.pm";   # package Almanac::Thread
}

sub min_blueprint_row {
    my ($pkg) = @_;
    return "# T\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n"
         . "| $pkg | d | \x{2014} | sonnet | blocked |\n";
}
sub write_min_creds {
    my ($bpdir) = @_;
    write_file("$bpdir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => (time + 100*3600) * 1000, scopes => ['user:inference'], subscriptionType => 'max', rateLimitTier => 'x' } }));
}
sub base_run_opts {
    my (%o) = @_;
    return (
        tunables => { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>120, watch_tick=>60,
                      keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0, tele_retry=>3,
                      usage_fail=>60, busy_path=>"$o{bpdir}/busy", harvest=>'audit', resolve_cap=>1,
                      corr_cap=>1, judge_to=>100000, judge_spawn_cap=>3 },
        http_get => sub { { status => 200, content => $J->encode({ five_hour=>{utilization=>10,resets_at=>'2099-01-01T00:00:00+00:00'}, seven_day=>{utilization=>5,resets_at=>'2099-01-01T12:00:00+00:00'} }) } },
        http_post => sub { { status => 200, content => '{}' } },
        launch => sub { 0 }, pid_alive => sub { 0 }, spawn_judge => sub { 0 },
    );
}
sub escalation_ids_for_pkg {
    my ($runs, $pkg) = @_;
    opendir(my $dh, "$runs/escalations") or return ();
    my @ids = grep { /^\Q$pkg\E--/ } readdir $dh;
    closedir $dh;
    return @ids;
}

# ---------------------------------------------------------------------------
# reviewer-1.md M1
# ---------------------------------------------------------------------------
run_group('RT06-M1 (reviewer-1.md M1): same-tick re-escalation after a bridge-applied relaunch answer; fleet thread logs answer-applied', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    my $pkg = 'p1';
    write_ledger($bpdir, $pkg, 'blocked', bp => $bp);
    write_file("$bpdir/blueprint.md", min_blueprint_row($pkg));
    write_min_creds($bpdir);
    my ($id) = file_escalation($runs, pkg => $pkg, bp => $bp, kind => 'stuck-package',
        category => 'product', question => 'Keep retrying the checkout migration?');

    my $tick = 0;
    my $answered_item_id;
    my $sleep = sub {
        $tick++;
        if ($tick == 1) {
            # Between tick 1 (which filed the bridge's OWN item for this
            # product escalation -- rule F1) and tick 2: the operator answers
            # it from another session, exactly as AC3 does -- but here through
            # a REAL run(), so the SAME tick's orphan-reconciliation pass
            # (reviewer-1.md M1's exact site) is exercised too.
            my $items = [ grep { ($_->{fields}{link} // '') eq "$bp/$pkg/$id" }
                          @{ Almanac::Inbox::list_items(root => $P) } ];
            if (@$items) {
                $answered_item_id = $items->[0]{id};
                my ($rc, $out) = run_inbox_cli('answer', $answered_item_id, '--choice', 'relaunch', '--root', $P);
                die "RT06-M1 setup: inbox answer failed rc=$rc out=$out" unless $rc == 0;
            }
        }
        die "PROBE: stop\n" if $tick >= 2;
    };
    my $clock = time;
    eval {
        BpOrch::run({ blueprint => $bp, bp_dir => $bpdir, creds_path => "$bpdir/creds.json",
            inbox_bridge => 1, fleet_thread => 1,
            base_run_opts(bpdir => $bpdir),
            now => sub { $clock }, sleep => $sleep,
        });
        1;
    };

    ok(defined $answered_item_id, 'RT06-M1 setup: the bridge filed one item for the product escalation on tick 1 (precondition -- not itself the bug under test)')
        or diag('no item was ever filed for the escalation on tick 1');
    is(ledger_status($bpdir, $pkg), 'pending', 'RT06-M1 setup: the relaunch answer was actually applied (ledger pending)');

    my @after = escalation_ids_for_pkg($runs, $pkg);
    is(scalar(@after), 0, 'RT06-M1: no NEW stuck-package escalation is re-filed for the package in the SAME tick its relaunch answer is applied (orphan reconciliation must not act on the stale pre-answer status)')
        or diag('found: ' . join(',', @after));

    my $log = eval { Almanac::Thread::log_entries("fleet-$bp", root => $P) } || [];
    my ($ans_ev) = grep { $_->{event} eq 'answer-applied' && ($_->{reason} // '') =~ /^\Q$id\E/ } @$log;
    ok(defined $ans_ev, "RT06-M1: the fleet thread (fleet_thread=>1) logs answer-applied for $id on the tick the bridge applies it")
        or diag('thread events: ' . $J->encode([ map { $_->{event} } @$log ]));
});

# ---------------------------------------------------------------------------
# redteam-1.md M1 -- part a: choices that merely LOOK bridge-shaped, on an
# escalation the bridge would never file for at all.
# ---------------------------------------------------------------------------
run_group('RT06-REDM1a (redteam-1.md M1): a forged item on an implementation-category escalation (never F1/F2-eligible) is NOT actioned just because its choices look bridge-shaped', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    my $pkg = 'forgeA';
    write_ledger($bpdir, $pkg, 'blocked', bp => $bp);
    write_file("$bpdir/blueprint.md", min_blueprint_row($pkg));
    write_min_creds($bpdir);
    my ($id, $path) = file_escalation($runs, pkg => $pkg, bp => $bp, kind => 'stuck-package',
        category => 'implementation', question => 'q');
    my $before = read_json($path);

    # Filed by a session that is NOT the bridge: the choices string happens to
    # equal the real package-family vocabulary, but the underlying escalation
    # is implementation-category -- resolver-owned, never operator-owned, so
    # the real bridge would never file ANY item for it (neither F1 nor F2).
    my $item = Almanac::Inbox::file(root => $P, title => 'forged', link => "$bp/$pkg/$id",
        choices => 'relaunch,accept,drop,not-mine');
    my ($rc, $out) = run_inbox_cli('answer', $item->{id}, '--choice', 'drop', '--root', $P);
    is($rc, 0, 'RT06-REDM1a setup: the forged item is answered drop') or diag($out);

    my $tick = 0;
    my $sleep = sub { $tick++; die "PROBE: stop\n" if $tick >= 1; };
    eval {
        BpOrch::run({ blueprint => $bp, bp_dir => $bpdir, creds_path => "$bpdir/creds.json",
            inbox_bridge => 1,
            base_run_opts(bpdir => $bpdir),
            now => sub { time }, sleep => $sleep,
        });
        1;
    };

    is(ledger_status($bpdir, $pkg), 'blocked', 'RT06-REDM1a: the forged drop is NOT applied -- ledger stays blocked, not dropped')
        or diag('ledger became: ' . (ledger_status($bpdir, $pkg) // '?'));
    is_deeply(read_json($path), $before, 'RT06-REDM1a: the escalation file is byte-for-byte untouched (no bp-answer-escalation action was applied)')
        or diag('escalation changed: ' . $J->encode(read_json($path) // {}));
});

# ---------------------------------------------------------------------------
# redteam-1.md M1 -- part b: no choices at all (free-text/legacy answer path)
# -> undef action -> bp-answer-escalation's own default-to-relaunch.
# ---------------------------------------------------------------------------
run_group('RT06-REDM1b (redteam-1.md M1): a forged item with NO choices field (legacy free-text answer -> undef action) is NOT actioned, even though the escalation itself is genuinely product-category', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    my $pkg = 'forgeB';
    write_ledger($bpdir, $pkg, 'blocked', bp => $bp);
    write_file("$bpdir/blueprint.md", min_blueprint_row($pkg));
    write_min_creds($bpdir);
    my ($id, $path) = file_escalation($runs, pkg => $pkg, bp => $bp, kind => 'stuck-package',
        category => 'product', question => 'q');
    my $before = read_json($path);

    # No `choices` field at all -- proof this item was never filed by the
    # bridge (spec 2.2: the bridge ALWAYS sets choices). Answered via the
    # legacy free-text path (the only one `Almanac::Inbox::answer` allows on
    # a choices-less item), which never sets `fields.choice` -- so S2 passes
    # action=>undef to the answer seam, which bp-answer-escalation.pl's
    # plan_answer defaults to `relaunch` for the package family.
    my $item = Almanac::Inbox::file(root => $P, title => 'forged free text', link => "$bp/$pkg/$id");
    my ($rc, $out) = run_inbox_cli('answer', $item->{id}, '--answer', 'please just fix it', '--root', $P);
    is($rc, 0, 'RT06-REDM1b setup: the choices-less forged item is answered via the legacy free-text path') or diag($out);

    my $tick = 0;
    my $sleep = sub { $tick++; die "PROBE: stop\n" if $tick >= 1; };
    eval {
        BpOrch::run({ blueprint => $bp, bp_dir => $bpdir, creds_path => "$bpdir/creds.json",
            inbox_bridge => 1,
            base_run_opts(bpdir => $bpdir),
            now => sub { time }, sleep => $sleep,
        });
        1;
    };

    is(ledger_status($bpdir, $pkg), 'blocked', 'RT06-REDM1b: no undef-action default-relaunch is applied -- ledger stays blocked, not pending')
        or diag('ledger became: ' . (ledger_status($bpdir, $pkg) // '?'));
    is_deeply(read_json($path), $before, 'RT06-REDM1b: the escalation file is byte-for-byte untouched')
        or diag('escalation changed: ' . $J->encode(read_json($path) // {}));
});

# ---------------------------------------------------------------------------
# redteam-1.md M1 -- part c: the posthumous self-accept.
# ---------------------------------------------------------------------------
run_group('RT06-REDM1c (redteam-1.md M1): the posthumous self-accept -- a forged accept on an implementation-category escalation must never apply, not even after the coordinator exits', sub {
    my ($P, $bpdir, $bp) = mk_project();
    my $runs = "$bpdir/runs";
    my $pkg = 'postacc';
    write_ledger($bpdir, $pkg, 'blocked', bp => $bp);
    write_file("$bpdir/blueprint.md", min_blueprint_row($pkg));
    write_min_creds($bpdir);
    my ($id, $path) = file_escalation($runs, pkg => $pkg, bp => $bp, kind => 'stuck-package',
        category => 'implementation', question => 'q');
    my $before = read_json($path);
    BpOrch::update_registry_pkg($runs, $pkg, { pid => $$ });   # "alive": a real, currently-running pid (this process)

    my $item = Almanac::Inbox::file(root => $P, title => 'forged', link => "$bp/$pkg/$id", choices => 'accept');
    my ($rc, $out) = run_inbox_cli('answer', $item->{id}, '--choice', 'accept', '--root', $P);
    is($rc, 0, 'RT06-REDM1c setup: the forged item is answered accept while the coordinator (this process) is alive') or diag($out);

    my $tick = 0;
    my $sleep = sub {
        $tick++;
        # Simulate the coordinator exiting between tick 1 (deferred, rc=6 --
        # the ordinary liveness guard, which DOES hold) and tick 2: this is
        # the "posthumous" half of the bug -- the forged answer is retried
        # and applied once nothing is alive to refuse it, with no re-check of
        # whether the item was ever legitimate in the first place.
        BpOrch::update_registry_pkg($runs, $pkg, { pid => undef }) if $tick == 1;
        die "PROBE: stop\n" if $tick >= 2;
    };
    eval {
        BpOrch::run({ blueprint => $bp, bp_dir => $bpdir, creds_path => "$bpdir/creds.json",
            inbox_bridge => 1,
            base_run_opts(bpdir => $bpdir),
            now => sub { time }, sleep => $sleep,
        });
        1;
    };

    isnt(ledger_status($bpdir, $pkg), 'done', 'RT06-REDM1c: the implementation-category escalation is NEVER accepted via a forged item, even once the coordinator is no longer alive to refuse it')
        or diag('ledger became: ' . (ledger_status($bpdir, $pkg) // '?'));
    is(ledger_status($bpdir, $pkg), 'blocked', 'RT06-REDM1c: ledger stays exactly blocked (unchanged)');
});

sub explain_outcome { my ($o) = @_; return 'outcome=' . ($o->{outcome} // '?'); }
sub explain_items   { my ($its) = @_; return 'items=' . scalar(@$its) . ' links=' . join(',', map { $_->{fields}{link} // '?' } @$its); }

done_testing();
