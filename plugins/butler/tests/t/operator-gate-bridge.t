#!/usr/bin/env perl
# platform: any
# The operator gate (fifth judge kind, `operator-gate`) in front of the
# fleet-inbox bridge's filing phase.
#
# The operator, 2026-11-16: "Why not have an agent whose purpose is deciding
# whether a question needs me or not? Some final sanity check before bringing
# it to my attention." Three technical questions held a fleet for 62 hours on
# 2026-11-13; bugs 8d3b, 5b54 and 3692 were all that class.
#
# What this pins, by driving BpOrch::_inbox_bridge_tick (and once BpOrch::run)
# with an injected judge spawner -- nothing here starts a real judge:
#   G1  no item is filed without a gate verdict; without a spawner nothing is filed
#   G2  the gate is fired: decision file BEFORE the spawn, kind operator-gate,
#       one in flight per package
#   G3  `operator` files, the gate's plain question first, the agents' text
#       below it as background
#   G4  `agents` re-tags the record implementation with operator_gate_rejected,
#       logs operator_gate_agents, files nothing, leaves it queued
#   G5  the bound: a record that already came back, or one no resolver can
#       reach, is filed with a one-line note instead of looping
#   G6  malformed verdicts (and timeouts, and a question that fails the
#       plain-language check) are retried, then filed unreviewed with a note
#   G7  a gate verdict is bound to the record's content (basis)
#   G8  a hard-coded operator-action record (reauth) passes the gate too
#   G9  BpOrch::run with inbox_bridge fires the gate and files its question
#
# Fixtures: a temp project <P>/.ccpraxis-local-data/blueprints/<bp>/, HOME and
# ALMANAC_HOME pinned to temp dirs, every launch seam mocked.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $FAKE_HOME = tempdir(CLEANUP => 1);
$ENV{HOME} = $FAKE_HOME;
$ENV{ALMANAC_HOME} = $FAKE_HOME;

my $ORCH_SCRIPT  = "$Bin/../../scripts/bp-orchestrator.pl";
require $ORCH_SCRIPT;
# almanac-inbox.pl is loaded by inbox_bridge_setup itself (requiring it here
# under another path string would load it twice).

my $J = JSON::PP->new->canonical;
my $KIND = 'operator-gate';

sub run_group {
    my ($label, $code) = @_;
    my $ok = eval { $code->(); 1 };
    fail("$label -- group errored: $@") unless $ok;
}
sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "write $p: $!";
    if (utf8::is_utf8($c) && $c =~ /[^\x00-\xff]/) { require Encode; $c = Encode::encode('UTF-8', $c); }
    print $fh $c;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }
sub read_json { my ($p) = @_; my $t = slurp($p); return undef unless defined $t; return eval { $J->decode($t) }; }

my $PN = 0;
sub mk_project {
    my $bp = 'ogb' . (++$PN);
    my $P = tempdir(CLEANUP => 1);
    my $bpdir = "$P/.ccpraxis-local-data/blueprints/$bp";
    make_path("$bpdir/packages", "$bpdir/runs/escalations");
    write_file("$bpdir/blueprint.md", "# T\n\n## Decisions\n\n| # | Decision | Decided |\n|--|--|--|\n| 1 | Keep the CLI | user |\n");
    return ($P, $bpdir, $bp, "$bpdir/runs");
}
sub write_ledger {
    my ($bpdir, $bp, $pkg) = @_;
    write_file("$bpdir/packages/$pkg.md",
          "---\npackage: $pkg\nblueprint: $bp\nstatus: blocked\nwrite_set: p/$pkg/\n"
        . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $pkg\n\n## Next action\n\nTBD.\n\n## Escalation\n\nq\n");
}
sub file_escalation {
    my ($runs, %o) = @_;
    my $path = BpOrch::queue_needs_you($runs, {
        package => $o{pkg}, blueprint => $o{bp}, kind => $o{kind} // 'stuck-package',
        question => $o{question} // 'what should happen?', context => 'ctx',
        created_at => $o{created_at} // time, category => $o{category} // 'product',
        (defined $o{product_question} ? (product_question => $o{product_question}) : ()),
    });
    die "queue_needs_you failed" unless $path;
    (my $id = $path) =~ s{.*[\\/]}{}; $id =~ s/\.json$//i;
    return ($id, $path);
}
sub ctx_for {
    my ($bp, $bpdir, $runs) = @_;
    my ($ctx, $why) = BpOrch::inbox_bridge_setup({ blueprint => $bp, bp_dir => $bpdir, runs => $runs,
                                                   log => "$runs/orchestrator.log" });
    die "inbox_bridge_setup: " . ($why // '?') unless $ctx;
    return $ctx;
}
sub items { my ($P, $bp) = @_;
    return [ grep { ($_->{fields}{link} // '') =~ m{^\Q$bp\E/} && !exists $_->{fields}{closed_at} }
             @{ Almanac::Inbox::list_items(root => $P) } ]; }
sub vpath { my ($runs, $pkg) = @_; return BpOrch::judge_verdict_path($runs, $KIND, $pkg); }
sub log_events {
    my ($runs, $type) = @_;
    my $t = slurp("$runs/orchestrator.log") // '';
    my @e;
    for my $l (split /\n/, $t) { my $o = eval { $J->decode($l) }; push @e, $o if ref $o eq 'HASH' && ($o->{type} // '') eq $type; }
    return @e;
}

# A spawner seam: records every call, and (when $verdict is given) writes it
# to the verdict path before returning 0 -- the shape a very fast judge has.
# $verdict may be a hashref (JSON-encoded), a plain string (written raw) or a
# coderef ($pkg, $decision_id) -> one of those.
sub spawner {
    my ($runs, $calls, $verdict) = @_;
    return sub {
        my ($a) = @_;
        my $named = slurp("$runs/$KIND/$a->{pkg}.decision");
        push @$calls, { %$a, decision_at_spawn => $named };
        return 0 unless ($a->{kind} // '') eq $KIND && defined $verdict;
        my $v = ref $verdict eq 'CODE' ? $verdict->($a->{pkg}, $named) : $verdict;
        return 0 unless defined $v;
        write_file(vpath($runs, $a->{pkg}), ref $v ? $J->encode($v) : $v);
        return 0;
    };
}
sub tick {
    my ($ctx, %o) = @_;
    BpOrch::_inbox_bridge_tick($ctx, {
        status => $o{status} // {}, reg => $o{reg} // {}, answer => sub { 1 },
        tunables => { judge_spawn_cap => 3, %{ $o{tunables} // {} } },
        (exists $o{spawn} ? (spawn_judge => $o{spawn}) : ()),
        pid_alive => $o{pid_alive} // sub { 0 }, now => $o{now} // time,
    });
}

my $TECH_Q  = 'Approve a mode-only exec bit on the protected path tools/run.sh under Decision 2?';
my $PLAIN_Q = 'Should guests be able to check out without creating an account?';

# ═══════════════════════════════════════════════════════════════════════════
run_group('G1 (nothing is filed without a gate verdict)', sub {
    my ($P, $bpdir, $bp, $runs) = mk_project();
    write_ledger($bpdir, $bp, 'p1');
    my ($id) = file_escalation($runs, pkg => 'p1', bp => $bp, question => $TECH_Q, product_question => $PLAIN_Q);
    my $ctx = ctx_for($bp, $bpdir, $runs);

    tick($ctx);   # no spawner at all
    is(scalar @{ items($P, $bp) }, 0, 'G1: with no judge spawner the bridge files nothing (no gate, no item)');
    ok((grep { ($_->{why} // '') =~ /no judge spawner/ } log_events($runs, 'operator_gate_unavailable')),
       'G1: and says why, once, in the log');

    my @calls;
    tick($ctx, spawn => spawner($runs, \@calls));   # a gate that never answers
    tick($ctx, spawn => spawner($runs, \@calls));
    is(scalar @{ items($P, $bp) }, 0, 'G1: a gate in flight with no verdict yet: still nothing filed');
    ok(!exists read_json("$runs/escalations/$id.json")->{operator_gate}, 'G1: the record carries no gate verdict');
});

run_group('G2 (the gate is fired: named first, kind operator-gate, one per package)', sub {
    my ($P, $bpdir, $bp, $runs) = mk_project();
    write_ledger($bpdir, $bp, 'p1');
    my ($id1) = file_escalation($runs, pkg => 'p1', bp => $bp, question => 'q one', created_at => 100);
    my ($id2) = file_escalation($runs, pkg => 'p1', bp => $bp, kind => 'dag-stalled', question => 'q two', created_at => 200);
    my $ctx = ctx_for($bp, $bpdir, $runs);
    my @calls;
    tick($ctx, spawn => spawner($runs, \@calls));
    is(scalar @calls, 1, 'G2: exactly one gate fired for two records of one package (one in flight per package)');
    is($calls[0]{kind}, $KIND, 'G2: the spawn is kind operator-gate');
    is($calls[0]{pkg}, 'p1', 'G2: keyed by the record\'s package');
    ok(defined $calls[0]{decision_at_spawn} && ($calls[0]{decision_at_spawn} eq $id1 || $calls[0]{decision_at_spawn} eq $id2),
       'G2: the record id was written to runs/operator-gate/<pkg>.decision BEFORE the spawn');
    ok(defined BpOrch::judge_inflight($runs, $KIND, 'p1'), 'G2: the gate is marked in flight');
    ok(scalar(log_events($runs, 'operator_gate_fire')), 'G2: operator_gate_fire is logged');
    tick($ctx, spawn => spawner($runs, \@calls));
    is(scalar @calls, 1, 'G2: no second spawn while the first gate is still in flight');
});

run_group('G3 (operator: filed with the plain question first, technical text as background)', sub {
    my ($P, $bpdir, $bp, $runs) = mk_project();
    write_ledger($bpdir, $bp, 'p1');
    my ($id) = file_escalation($runs, pkg => 'p1', bp => $bp, question => $TECH_Q);
    my $ctx = ctx_for($bp, $bpdir, $runs);
    my @calls;
    my $spawn = spawner($runs, \@calls, { verdict => 'operator', question => $PLAIN_Q, reasoning => 'rule 4: what users get' });
    tick($ctx, spawn => $spawn);
    my $its = items($P, $bp);
    is(scalar @$its, 1, 'G3: an operator verdict files exactly one item, in the same tick a ready verdict lands');
    if (@$its) {
        my $f = $its->[0]{fields};
        is($f->{title}, $PLAIN_Q, 'G3: the inbox title is the gate\'s plain question');
        my $body = $its->[0]{body} // '';
        like($body, qr/\A\Q$PLAIN_Q\E/, 'G3: the body leads with the plain question');
        like($body, qr/Background[^\n]*\n\Q$TECH_Q\E/, 'G3: the original technical text follows, marked as background');
        cmp_ok(index($body, $PLAIN_Q), '<', index($body, $TECH_Q), 'G3: plain question before technical text');
        like($body, qr/Escalation: \Q$id\E/, 'G3: the escalation id is still named');
        is($f->{link}, "$bp/p1/$id", 'G3: link unchanged');
    }
    my $rec = read_json("$runs/escalations/$id.json");
    is($rec->{operator_gate}{verdict}, 'operator', 'G3: the record carries the gate verdict');
    is($rec->{operator_gate}{basis}, BpOrch::operator_gate_basis($rec), 'G3: ...bound to its content');
    ok(BpOrch::operator_gate_cleared($rec), 'G3: operator_gate_cleared accepts it');
    ok(!-e vpath($runs, 'p1') && !defined BpOrch::judge_inflight($runs, $KIND, 'p1'), 'G3: the verdict and in-flight marker are cleared');
    ok(glob("$runs/$KIND/archive/*.verdict.json"), 'G3: the verdict is archived');
    tick($ctx, spawn => $spawn);
    is(scalar @{ items($P, $bp) }, 1, 'G3: a further tick files no duplicate');
    is(scalar @calls, 1, 'G3: and fires no second gate');
});

run_group('G4 (agents: re-tagged implementation with operator_gate_rejected; nothing filed)', sub {
    my ($P, $bpdir, $bp, $runs) = mk_project();
    write_ledger($bpdir, $bp, 'p1');
    my ($id, $path) = file_escalation($runs, pkg => 'p1', bp => $bp, question => $TECH_Q);
    my $ctx = ctx_for($bp, $bpdir, $runs);
    my @calls;
    tick($ctx, spawn => spawner($runs, \@calls, { verdict => 'agents', reasoning => 'rule 3: applying Decision 1 technically',
        covering_decision => '1', guidance => 'Set the exec bit; Decision 1 covers it. Relaunch.' }));
    is(scalar @{ items($P, $bp) }, 0, 'G4: an agents verdict files nothing');
    ok(-f $path, 'G4: the record stays queued');
    my $rec = read_json($path);
    is($rec->{category}, 'implementation', 'G4: re-tagged implementation, so the escalation resolver fires again');
    my $r = $rec->{operator_gate_rejected};
    is(ref $r, 'HASH', 'G4: operator_gate_rejected is recorded');
    is($r->{reasoning}, 'rule 3: applying Decision 1 technically', 'G4: ...with the reasoning');
    is($r->{guidance}, 'Set the exec bit; Decision 1 covers it. Relaunch.', 'G4: ...the guidance');
    is($r->{covering_decision}, '1', 'G4: ...the covering decision');
    is($r->{category}, 'product', 'G4: ...the category it arrived with');
    like($r->{at} // '', qr/\A\d{4}-\d\d-\d\dT/, 'G4: ...and when');
    ok(!exists $rec->{operator_gate}, 'G4: no operator verdict is left on it');
    ok(scalar(log_events($runs, 'operator_gate_agents')), 'G4: operator_gate_agents is logged');
    my ($f1, $f2) = BpOrch::_inbox_bridge_eligible_now($rec, {}, { judge_spawn_cap => 3 }, undef);
    ok(!$f1 && !$f2, 'G4: no longer bridge-eligible: it waits for the resolver, not for the operator');
});

run_group('G5 (the bound: an agents verdict is not applied twice, and not to an unreachable record)', sub {
    my ($P, $bpdir, $bp, $runs) = mk_project();
    write_ledger($bpdir, $bp, 'p1');
    my ($id, $path) = file_escalation($runs, pkg => 'p1', bp => $bp, question => $TECH_Q);
    my $rec = read_json($path);
    $rec->{operator_gate_rejected} = { reasoning => 'earlier', guidance => 'g', covering_decision => undef, category => 'product', at => '2026-11-16T00:00:00Z' };
    write_file($path, $J->encode($rec));
    my $ctx = ctx_for($bp, $bpdir, $runs);
    my @calls;
    tick($ctx, spawn => spawner($runs, \@calls, { verdict => 'agents', reasoning => 'still a write-set matter',
        covering_decision => undef, guidance => 'relaunch' }));
    my $its = items($P, $bp);
    is(scalar @$its, 1, 'G5: a record that came back gets an agents verdict again: filed for the operator, no loop');
    like(($its->[0]{body} // ''), qr/ruled this was not yours \(still a write-set matter\)/, 'G5: with a note giving the gate\'s reasoning');
    my @note = grep { /ruled this was not yours/ } split /\n/, ($its->[0]{body} // '');
    is(scalar @note, 1, 'G5: the note is one line');
    my $after = read_json($path);
    is($after->{category}, 'product', 'G5: not re-tagged a second time');
    ok($after->{operator_gate}{bounded}, 'G5: the record\'s gate verdict is marked bounded');
    ok(scalar(log_events($runs, 'operator_gate_bounded')), 'G5: operator_gate_bounded is logged');

    # No resolver can reach a _fleet record: an agents verdict there is filed with a note at once.
    my ($P2, $bpdir2, $bp2, $runs2) = mk_project();
    my ($fid, $fpath) = file_escalation($runs2, pkg => '_fleet', bp => $bp2, kind => 'broken-env', category => 'unclassified',
        question => 'bash cannot be executed');
    my $ctx2 = ctx_for($bp2, $bpdir2, $runs2);
    tick($ctx2, spawn => spawner($runs2, [], { verdict => 'agents', reasoning => 'a retry may fix it', covering_decision => undef, guidance => 'retry' }));
    my $its2 = items($P2, $bp2);
    is(scalar @$its2, 1, 'G5: an unreachable (F2) record with an agents verdict is filed, not handed to a resolver that cannot run');
    like(($its2->[0]{body} // ''), qr/no agent can take it up right now/, 'G5: with its own one-line note');
    ok(!exists read_json($fpath)->{operator_gate_rejected}, 'G5: and is not re-tagged');
});

run_group('G6 (malformed verdicts retry, then fail toward the operator)', sub {
    my ($P, $bpdir, $bp, $runs) = mk_project();
    write_ledger($bpdir, $bp, 'p1');
    my ($id) = file_escalation($runs, pkg => 'p1', bp => $bp, question => $TECH_Q);
    my $ctx = ctx_for($bp, $bpdir, $runs);
    my @bad = ('this is not json',
               { verdict => 'maybe', reasoning => 'r' },
               { verdict => 'operator', reasoning => 'r', question => 'Approve the write set change for `tools/run.sh`?' });
    my @calls;
    for my $n (1 .. 3) {
        tick($ctx, spawn => spawner($runs, \@calls, $bad[$n - 1]));
        is(BpOrch::operator_gate_attempts($runs, $id), $n, "G6: failed attempt $n is counted");
        is(scalar @{ items($P, $bp) }, 0, "G6: nothing is filed after failed attempt $n") if $n < 3;
    }
    is(scalar @calls, 3, 'G6: the gate was retried after each malformed verdict');
    ok(!exists read_json("$runs/escalations/$id.json")->{operator_gate}, 'G6: a malformed verdict is never applied');
    ok((grep { ($_->{why} // '') =~ /plain-language/ } log_events($runs, 'operator_gate_failed')),
       'G6: a question that fails the plain-language check counts as a failed attempt');
    tick($ctx, spawn => spawner($runs, \@calls, 'still not json'));
    my $its = items($P, $bp);
    is(scalar @$its, 1, 'G6: after the attempt bound the record is filed for the operator anyway: nothing is lost');
    like(($its->[0]{body} // ''), qr/reaches you unreviewed/, 'G6: with a note that it was not reviewed');
    is($its->[0]{fields}{title}, BpOrch::fleet_thread_reason($TECH_Q), 'G6: under its own wording, the only wording there is');
    is(scalar @calls, 3, 'G6: no further gate is fired once the bound is reached');
    ok(scalar(log_events($runs, 'operator_gate_exhausted')), 'G6: operator_gate_exhausted is logged');
    is(BpOrch::operator_gate_attempts($runs, $id), 0, 'G6: the count is cleared once the item is filed');

    # A valid verdict resets the count.
    my ($P2, $bpdir2, $bp2, $runs2) = mk_project();
    write_ledger($bpdir2, $bp2, 'p2');
    my ($id2) = file_escalation($runs2, pkg => 'p2', bp => $bp2, question => 'q');
    my $ctx2 = ctx_for($bp2, $bpdir2, $runs2);
    tick($ctx2, spawn => spawner($runs2, [], '{'));
    is(BpOrch::operator_gate_attempts($runs2, $id2), 1, 'G6: one failure counted');
    tick($ctx2, spawn => spawner($runs2, [], { verdict => 'operator', question => $PLAIN_Q, reasoning => 'r' }));
    is(scalar @{ items($P2, $bp2) }, 1, 'G6: a valid verdict on the retry files it');
    is(BpOrch::operator_gate_attempts($runs2, $id2), 0, 'G6: and resets the count');

    # A judge that never writes a verdict times out and counts.
    my ($P3, $bpdir3, $bp3, $runs3) = mk_project();
    write_ledger($bpdir3, $bp3, 'p3');
    my ($id3) = file_escalation($runs3, pkg => 'p3', bp => $bp3, question => 'q');
    my $ctx3 = ctx_for($bp3, $bpdir3, $runs3);
    my @c3;
    my $t0 = time;
    tick($ctx3, spawn => spawner($runs3, \@c3), now => $t0);
    tick($ctx3, spawn => spawner($runs3, \@c3), now => $t0 + 30, tunables => { operator_gate_to => 600 });
    is(BpOrch::operator_gate_attempts($runs3, $id3), 0, 'G6: inside the wall-clock bound a silent gate is still waited for');
    tick($ctx3, spawn => spawner($runs3, \@c3), now => $t0 + 601, tunables => { operator_gate_to => 600 });
    is(BpOrch::operator_gate_attempts($runs3, $id3), 1, 'G6: past the bound it is a failed attempt');
    is(scalar @c3, 2, 'G6: and the gate is fired again');

    # A judge whose pid is known and dead with no verdict counts at once.
    my ($P4, $bpdir4, $bp4, $runs4) = mk_project();
    write_ledger($bpdir4, $bp4, 'p4');
    my ($id4) = file_escalation($runs4, pkg => 'p4', bp => $bp4, question => 'q');
    my $ctx4 = ctx_for($bp4, $bpdir4, $runs4);
    my $spawn4 = sub { my ($a) = @_; write_file(BpOrch::judge_pid_path($runs4, $KIND, $a->{pkg}), "999999\n"); 0 };
    tick($ctx4, spawn => $spawn4);
    is(BpOrch::operator_gate_attempts($runs4, $id4), 1, 'G6: a gate that died without a verdict is a failed attempt immediately, not after the wall-clock bound');
    tick($ctx4, spawn => $spawn4);
    is(BpOrch::operator_gate_attempts($runs4, $id4), 2, 'G6: and the next tick tries again');
});

run_group('G7 (a gate verdict is bound to the record\'s content)', sub {
    my ($P, $bpdir, $bp, $runs) = mk_project();
    write_ledger($bpdir, $bp, 'p1');
    my ($id, $path) = file_escalation($runs, pkg => 'p1', bp => $bp, question => 'first wording');
    my $rec = read_json($path);
    $rec->{operator_gate} = { verdict => 'operator', question => $PLAIN_Q, reasoning => 'r', at => 'x',
                              basis => BpOrch::operator_gate_basis($rec) };
    ok(BpOrch::operator_gate_cleared($rec), 'G7: a matching basis clears');
    $rec->{question} = 'second wording';
    ok(!BpOrch::operator_gate_cleared($rec), 'G7: a changed question does not');
    write_file($path, $J->encode($rec));
    my $ctx = ctx_for($bp, $bpdir, $runs);
    my @calls;
    tick($ctx, spawn => spawner($runs, \@calls));
    is(scalar @{ items($P, $bp) }, 0, 'G7: a stale gate verdict files nothing');
    is(scalar @calls, 1, 'G7: the record is gated again');
    my $c = { category => 'product', kind => 'k', question => 'q' };
    isnt(BpOrch::operator_gate_basis($c), BpOrch::operator_gate_basis({ %$c, category => 'implementation' }),
         'G7: the basis covers the category');
    is(BpOrch::operator_gate_basis($c), BpOrch::operator_gate_basis({ %$c, operator_gate => { x => 1 }, context => 'other' }),
       'G7: ...and not the gate\'s own fields');
});

run_group('G8 (a hard-coded operator-action record passes the gate too)', sub {
    my ($P, $bpdir, $bp, $runs) = mk_project();
    my ($id) = file_escalation($runs, pkg => '_fleet', bp => $bp, kind => 'reauth', category => 'operator-action',
        question => 'token-keeper hit the pause-floor');
    my $ctx = ctx_for($bp, $bpdir, $runs);
    my @calls;
    tick($ctx, spawn => spawner($runs, \@calls));
    is(scalar @calls, 1, 'G8: the gate is fired for a reauth record');
    is($calls[0]{pkg}, '_fleet', 'G8: keyed _fleet (bp-judge.sh needs no ledger for this kind)');
    is(scalar @{ items($P, $bp) }, 0, 'G8: and nothing is filed before it answers');
    write_file(vpath($runs, '_fleet'), $J->encode({ verdict => 'operator', reasoning => 'rule 1: hands',
        question => 'Sign in to Claude again in the sandbox so the paused run can continue.' }));
    tick($ctx, spawn => spawner($runs, \@calls));
    my $its = items($P, $bp);
    is(scalar @$its, 1, 'G8: a verdict landing on a later tick is consumed and filed');
    is($its->[0]{fields}{title}, 'Sign in to Claude again in the sandbox so the paused run can continue.', 'G8: under the plain question');
    is($its->[0]{fields}{choices}, 'resume', 'G8: fleet choices unchanged');
});

run_group('G9 (BpOrch::run with the bridge on fires the gate and files its question)', sub {
    my ($P, $bpdir, $bp, $runs) = mk_project();
    my $pkg = 'p1';
    write_ledger($bpdir, $bp, $pkg);
    write_file("$bpdir/blueprint.md", "# T\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n"
        . "| $pkg | d | \x{2014} | sonnet | blocked |\n");
    write_file("$bpdir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => (time + 100*3600) * 1000, scopes => ['user:inference'], subscriptionType => 'max', rateLimitTier => 'x' } }));
    my ($id) = file_escalation($runs, pkg => $pkg, bp => $bp, question => $TECH_Q);
    my @calls;
    my $tick = 0;
    eval {
        BpOrch::run({ blueprint => $bp, bp_dir => $bpdir, creds_path => "$bpdir/creds.json", inbox_bridge => 1,
            tunables => { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>120, watch_tick=>60,
                          keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0, tele_retry=>3,
                          usage_fail=>60, busy_path=>"$bpdir/busy", harvest=>'audit', resolve_cap=>1,
                          corr_cap=>1, judge_to=>100000, judge_spawn_cap=>3 },
            http_get => sub { { status => 200, content => $J->encode({ five_hour=>{utilization=>10,resets_at=>'2099-01-01T00:00:00+00:00'}, seven_day=>{utilization=>5,resets_at=>'2099-01-01T12:00:00+00:00'} }) } },
            http_post => sub { { status => 200, content => '{}' } },
            launch => sub { 0 }, pid_alive => sub { 0 },
            spawn_judge => spawner($runs, \@calls, { verdict => 'operator', question => $PLAIN_Q, reasoning => 'r' }),
            now => sub { time }, sleep => sub { $tick++; die "PROBE: stop\n" if $tick >= 1; },
        });
        1;
    };
    my @gates = grep { $_->{kind} eq $KIND } @calls;
    is(scalar @gates, 1, 'G9: run() fires the operator gate through its spawn_judge seam');
    my $its = items($P, $bp);
    is(scalar @$its, 1, 'G9: and the bridge files the item');
    is(($its->[0]{fields}{title} // ''), $PLAIN_Q, 'G9: under the gate\'s plain question');
});

done_testing();
