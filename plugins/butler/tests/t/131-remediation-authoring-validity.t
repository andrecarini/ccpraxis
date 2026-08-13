#!/usr/bin/env perl
# 131-remediation-authoring-validity.t — r02-remediation-authoring-validity
#
# Oracle for specs/r02-remediation-authoring-validity-spec.md §4 (AC-1..AC-16).
# bp-remediate.pl must REFUSE to author a remediation package that cannot be
# satisfied (unresolved test_paths, empty write_set/means, a dag-stall kind
# routed as a defect, or a cited originating verdict that does not exist on
# disk), instead of authoring one with butler's own dev paths and an empty
# write set (sources/2026-08-11-gsa-fleet-collapse.md Bug 3).
#
# TDD-RED BY DESIGN for every DC1/DC2/DC3/DC4 assertion below: the gates this
# file exercises do not exist yet on disk (measured this session against
# bp-remediate.pl, per scout-step1.md). AC-7's regression guard and the
# "happy path still authors" control are expected to be GREEN from the start
# — they pin behaviour that must NOT change while the refusal gates land.
#
# No shared helper module (repo convention, scout §6/§7): fixtures below are
# copied/adapted from 26-auto-remediation-engine.t and 60-dag-integrity.t's
# own shapes, not required from them.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $BPR_OK = eval { require "$Bin/../../scripts/bp-remediate.pl"; 1 };
my $BPR_ERR = $@;
diag("bp-remediate.pl did not load: $BPR_ERR") unless $BPR_OK;
ok($BPR_OK, 'bp-remediate.pl is loadable') or BAIL_OUT('cannot proceed without BpRemediate');

my $ROOT = tempdir(CLEANUP => 1);
my $ISO  = '2026-08-13T00:00:00Z';

sub try1 {
    my ($code) = @_;
    my $r = eval { $code->() };
    return { _died => "$@" } if $@;
    return $r;
}
sub died { my $r = shift; return (ref $r eq 'HASH' && exists $r->{_died}) ? $r->{_died} : undef }
sub slurp { local $/; open my $f, '<', shift or return undef; <$f> }

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

sub mk_finding {
    my (%o) = @_;
    return {
        kind     => (exists $o{kind}     ? $o{kind}     : 'conformance-deviation'),
        subject  => (exists $o{subject}  ? $o{subject}  : 'b03'),
        detail   => (exists $o{detail}   ? $o{detail}   : 'means libX not evidenced'),
        evidence => (exists $o{evidence} ? $o{evidence} : { means => 'libX', files => ['src/chat/Bubble.tsx'] }),
        remedy   => (exists $o{remedy}   ? $o{remedy}   : { action => 'remediate-conformance', package => 'b03', means => 'libX' }),
    };
}

sub mk_ctx {
    my (%o) = @_;
    return {
        now => 1_800_000_000, iso => $ISO, blueprint => 'T',
        rounds => (exists $o{rounds} ? $o{rounds} : 2),
        cap    => (exists $o{cap}    ? $o{cap}    : 6),
        pkg_write_sets => ($o{pkg_write_sets} // {}),
        model     => ($o{model} // 'sonnet'),
        max_turns => ($o{max_turns} // 60),
        (exists $o{test_paths} ? (test_paths => $o{test_paths}) : (test_paths => 'plugins/some-project/tests/')),
        backpack_path => $o{backpack_path},
    };
}

sub mk_entry {
    my (%o) = @_;
    my $id      = $o{id} // 'remediation-test-r1';
    my $finding = $o{finding} // mk_finding();
    return {
        id => $id, finding_key => $o{finding_key} // 'test-finding', round => $o{round} // 1,
        max_rounds => $o{max_rounds} // 2, source => $o{source} // 'conformance',
        action => $o{action} // ($finding->{remedy}{action} // 'remediate-conformance'),
        disposition => 'auto', state => $o{state} // 'queued', pkg_status => $o{pkg_status} // 'pending',
        ledger_path => $o{ledger_path} // "packages/$id.md",
        write_set  => (exists $o{write_set} ? $o{write_set} : 'src/chat/Bubble.tsx'),
        test_paths => (exists $o{test_paths} ? $o{test_paths} : 'plugins/some-project/tests/'),
        deps => $o{deps} // [], model => $o{model} // 'sonnet', max_turns => $o{max_turns} // 60,
        mandated_means => $o{mandated_means} // ['libX'], signature => $o{signature} // 'sig-placeholder',
        finding => $finding, created_at => $ISO, updated_at => $ISO,
        history => [ { round => ($o{round} // 1), at => $ISO, event => 'authored', signature => 'sig-placeholder' } ],
        escalation_reason => $o{escalation_reason},
    };
}

sub mk_bump_runtime_finding {
    # write_set_for resolves via rung 2 (remedy.file); classify_finding's own
    # bump_runtime branch only checks remedy.to. A finding shape that is
    # genuinely fixable end-to-end, used as the "otherwise-fixable finding"
    # control across AC-5/AC-7's variants.
    return mk_finding(kind => 'eol_runtime', subject => 'node', detail => 'node 18 is EOL', evidence => {},
        remedy => { action => 'bump_runtime', runtime => 'node', from => '18', to => '20', file => '.devcontainer/Containerfile' });
}

sub mk_dag_stall_finding {
    # mirrors 60-dag-integrity.t's AC-38/AC-39 fixture exactly, per spec §4 AC-11.
    return {
        kind     => 'dag-stall',
        subject  => 'b01-blocker',
        detail   => "package 'b01-blocker' is 'blocked' and blocks 1 dependent package(s): "
                   . "b02-dependent — the run cannot progress until it reaches 'done'",
        evidence => { blocked_on => 'b01-blocker', blocker_status => 'blocked',
                      dependents => ['b02-dependent'], files => [] },
        remedy   => { action => 'remediate-conformance', package => 'b01-blocker' },
    };
}

sub mk_runs_verdict {
    my ($bpdir, $rel) = @_;
    $rel //= 'conformance-verdict.json';
    my $full = "$bpdir/runs/$rel";
    my $dir  = $full; $dir =~ s{/[^/]+$}{};
    make_path($dir);
    open(my $fh, '>', $full) or die "cannot write $full: $!";
    print $fh '{}';
    close $fh;
    return $full;
}

# ===========================================================================
# DC1 — no butler-internal path is ever emitted as a fallback (AC-1..AC-4)
# ===========================================================================

# ---- AC-1: _build_entry's test_paths carries no // 'plugins/butler/tests/' fallback
{
    my $entry = try1(sub { BpRemediate::_build_entry({
        id => 'remediation-x-r1', action => 'bump_runtime', finding => {}, ctx => {},
        finding_key => 'fk', round => 1, max_rounds => 2, write_set => 'a/b', signature => 'sig', now_iso => $ISO,
    }) });
    if (my $d = died($entry)) { fail('AC-1: _build_entry with ctx.test_paths absent does not fabricate a value'); diag($d); }
    else {
        is($entry->{test_paths}, undef,
           "AC-1: _build_entry's test_paths carries no 'plugins/butler/tests/' fallback when ctx.test_paths is absent");
    }
}

# ---- AC-2: ledger_text's test_paths local carries no fallback anywhere -----
{
    # entry.test_paths absent AND ctx.test_paths defined-and-valid: the OLD
    # code fell back to ctx.test_paths (tier 2) here; the fix's local is
    # strictly $entry->{test_paths} with NO ctx fallback of any kind, so this
    # must refuse (return undef) rather than silently substitute ctx's value.
    my $entry = mk_entry(test_paths => undef);
    delete $entry->{test_paths};
    my $ctx = mk_ctx(test_paths => 'a/real/valid/tests/');
    my $text = try1(sub { BpRemediate::ledger_text($entry, $ctx) });
    if (my $d = died($text)) { fail('AC-2: ledger_text does not die when entry.test_paths is absent'); diag($d); }
    else {
        is($text, undef,
           'AC-2: ledger_text never falls back to ctx.test_paths (or any literal) when entry.test_paths is absent');
    }
}

# ---- AC-3: rendered '## Done criteria' contains no 'prove' / 'plugins/butler/tests'
{
    my $entry = mk_entry(action => 'bump_runtime', finding => mk_bump_runtime_finding(), test_paths => 'a/valid/tests/');
    my $ctx = mk_ctx();
    my $text = try1(sub { BpRemediate::ledger_text($entry, $ctx) });
    if (my $d = died($text)) { fail('AC-3: ledger_text renders for a valid entry'); diag($d); }
    else {
        ok(defined $text, 'AC-3: ledger_text returns defined text for a fully valid entry');
        my ($dc) = ($text // '') =~ /^##\s+Done criteria\s*\n(.*?)(?=\n##\s|\z)/ms;
        ok(defined $dc, 'AC-3: a ## Done criteria section exists');
        unlike($dc // '', qr/\bprove\b/i, "AC-3: ## Done criteria contains no 'prove'");
        unlike($dc // '', qr{plugins/butler/tests}, "AC-3: ## Done criteria contains no 'plugins/butler/tests'");
    }
}

# ---- AC-4: static source scan for the two removed literals -----------------
{
    my $src_path = "$Bin/../../scripts/bp-remediate.pl";
    my $src = slurp($src_path);
    ok(defined $src && length $src, 'AC-4: bp-remediate.pl is readable for the static scan');
    my $n_path  = () = ($src // '') =~ m{plugins/butler/tests/}g;
    my $n_prove = () = ($src // '') =~ m{prove\s+-r}g;
    is($n_path, 0, "AC-4: bp-remediate.pl contains zero occurrences of the literal 'plugins/butler/tests/'");
    is($n_prove, 0, "AC-4: bp-remediate.pl contains zero occurrences of the literal 'prove -r'");
}

# ===========================================================================
# DC2 — refuse to author rather than emit an unsatisfiable package (AC-5..7)
# ===========================================================================

# ---- AC-5: ctx.test_paths unresolved (undef / non-string / whitespace-only)
for my $case (
    { label => 'undefined',    test_paths => undef },
    { label => 'a ref',        test_paths => [] },
    { label => 'whitespace',   test_paths => '   ' },
) {
    my $queue = try1(sub { BpRemediate::queue_new(mk_ctx()) });
    my $ctx = mk_ctx(test_paths => $case->{test_paths});
    delete $ctx->{test_paths} unless defined $case->{test_paths};
    $ctx->{test_paths} = $case->{test_paths} if defined $case->{test_paths};
    my $finding = mk_bump_runtime_finding();
    my $verdict = { schema => 'conformance-verdict/1', generated_at => $ISO, outcome => 'fail', findings => [$finding] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail("AC-5 ($case->{label}): plan() does not die"); diag($d); next; }
    is(scalar(@{ $plan->{author} || [] }), 0, "AC-5 ($case->{label}): author is empty when ctx.test_paths is unresolved");
    my @esc = @{ $plan->{escalate} || [] };
    is(scalar(@esc), 1, "AC-5 ($case->{label}): exactly one escalation");
    is(($esc[0] || {})->{escalation_reason}, 'test_paths_unresolved',
       "AC-5 ($case->{label}): escalation_reason is 'test_paths_unresolved'");
    # the refused attempt is NOT silently dropped: the triggering finding's
    # own identity survives in the escalation record.
    is(($esc[0] || {})->{subject}, $finding->{subject},
       "AC-5 ($case->{label}): the escalation still records the triggering finding's subject");
}

# ---- AC-6: remediate-conformance finding lacking remedy.means --------------
for my $case (
    { label => 'means absent', remedy => { action => 'remediate-conformance', package => 'b03' } },
    { label => 'means empty string', remedy => { action => 'remediate-conformance', package => 'b03', means => '' } },
) {
    my $queue = try1(sub { BpRemediate::queue_new(mk_ctx()) });
    my $ctx = mk_ctx();
    my $finding = mk_finding(remedy => $case->{remedy}, evidence => { files => ['src/b03/thing.ts'] });
    my $verdict = { schema => 'conformance-verdict/1', generated_at => $ISO, outcome => 'fail', findings => [$finding] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail("AC-6 ($case->{label}): plan() does not die"); diag($d); next; }
    is(scalar(@{ $plan->{author} || [] }), 0, "AC-6 ($case->{label}): author is empty when remedy.means is missing/empty");
    my @esc = @{ $plan->{escalate} || [] };
    is(scalar(@esc), 1, "AC-6 ($case->{label}): exactly one escalation");
    is(($esc[0] || {})->{escalation_reason}, 'means_missing',
       "AC-6 ($case->{label}): escalation_reason is 'means_missing'");
}

# ---- AC-7 (regression guard): write_set_for unresolvable -> unscopable, unchanged
{
    my $queue = try1(sub { BpRemediate::queue_new(mk_ctx()) });
    my $ctx = mk_ctx();
    # bump_runtime with no remedy.file, no evidence.files, no matching
    # pkg_write_sets entry: write_set_for has nothing to resolve from.
    my $finding = mk_finding(kind => 'eol_runtime', subject => 'unmatched-pkg', evidence => {},
        remedy => { action => 'bump_runtime', runtime => 'node', to => '20' });
    my $verdict = { schema => 'conformance-verdict/1', generated_at => $ISO, outcome => 'fail', findings => [$finding] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-7: plan() does not die on an unscopable finding'); diag($d); }
    else {
        is(scalar(@{ $plan->{author} || [] }), 0, 'AC-7: author is empty for an unscopable finding (unchanged)');
        my @esc = @{ $plan->{escalate} || [] };
        is(scalar(@esc), 1, 'AC-7: exactly one escalation (unchanged)');
        is(($esc[0] || {})->{escalation_reason}, 'unscopable', "AC-7: escalation_reason is still 'unscopable' (unchanged)");
    }
}

# ---- control: the legitimate happy path still authors normally -------------
# (refuse-too-much guard: a package that only ever refuses would pass a
# one-sided oracle — this pins that a genuinely satisfiable finding is NOT
# blocked by any of the new gates.)
{
    my $queue = try1(sub { BpRemediate::queue_new(mk_ctx()) });
    my $ctx = mk_ctx(test_paths => 'plugins/real-project/tests/');
    my $finding = mk_finding(remedy => { action => 'remediate-conformance', package => 'b03', means => 'libX' },
        evidence => { means => 'libX', files => ['src/chat/Bubble.tsx'] });
    my $verdict = { schema => 'conformance-verdict/1', generated_at => $ISO, outcome => 'fail', findings => [$finding] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('control: a legitimate finding still authors (plan does not die)'); diag($d); }
    else {
        is(scalar(@{ $plan->{author} || [] }), 1, 'control: a legitimate remediate-conformance finding still authors exactly one entry');
        is(scalar(@{ $plan->{escalate} || [] }), 0, 'control: a legitimate finding escalates nothing');
    }
}

# ===========================================================================
# DC3 — a cited originating verdict must exist (AC-8..10)
# ===========================================================================

# ---- AC-8: no verdict file under $bpdir/runs/ -> author_ledger refuses -----
{
    my $bpdir = "$ROOT/dc3-ac8"; make_path("$bpdir/packages", "$bpdir/runs");
    my $entry = mk_entry(id => 'remediation-dc3-ac8-r1');
    my $path = try1(sub { BpRemediate::author_ledger($bpdir, $entry, mk_ctx()) });
    if (my $d = died($path)) { fail('AC-8: author_ledger does not die when no verdict file exists'); diag($d); }
    else {
        is($path, undef, 'AC-8: author_ledger returns undef when neither verdict file exists');
    }
    ok(!-f "$bpdir/packages/remediation-dc3-ac8-r1.md", 'AC-8: no ledger file is written under packages/ when the verdict is absent');
}

# ---- AC-9: $bpdir/runs/conformance-verdict.json present --------------------
{
    my $bpdir = "$ROOT/dc3-ac9"; make_path("$bpdir/packages");
    my $verdict_path = mk_runs_verdict($bpdir, 'conformance-verdict.json');
    my $entry = mk_entry(id => 'remediation-dc3-ac9-r1');
    my $path = try1(sub { BpRemediate::author_ledger($bpdir, $entry, mk_ctx()) });
    if (my $d = died($path)) { fail('AC-9: author_ledger writes normally when the flat verdict path exists'); diag($d); }
    else {
        ok(defined $path && -f $path, 'AC-9: author_ledger writes a file when the flat verdict path exists');
        my $txt = slurp($path) // '';
        like($txt, qr/\Qoriginating verdict: $verdict_path\E/, 'AC-9: rendered ## Inputs cites the resolved flat verdict path verbatim')
            or diag("verdict_path=$verdict_path\ntext=$txt");
    }
}

# ---- AC-10: only $bpdir/runs/conformance/_run.verdict.json present ---------
{
    my $bpdir = "$ROOT/dc3-ac10"; make_path("$bpdir/packages");
    my $verdict_path = mk_runs_verdict($bpdir, 'conformance/_run.verdict.json');
    my $entry = mk_entry(id => 'remediation-dc3-ac10-r1');
    my $path = try1(sub { BpRemediate::author_ledger($bpdir, $entry, mk_ctx()) });
    if (my $d = died($path)) { fail('AC-10: author_ledger writes normally when only the nested verdict path exists'); diag($d); }
    else {
        ok(defined $path && -f $path, 'AC-10: author_ledger writes a file when only the nested verdict path exists');
        my $txt = slurp($path) // '';
        like($txt, qr/\Qoriginating verdict: $verdict_path\E/, 'AC-10: rendered ## Inputs cites the resolved nested verdict path verbatim')
            or diag("verdict_path=$verdict_path\ntext=$txt");
    }
}

# ===========================================================================
# DC4 — a scheduling state is not a defect (AC-11..13)
# ===========================================================================

# ---- AC-11: classify_finding on a dag-stall finding, fully resolvable ------
{
    my $find = mk_dag_stall_finding();
    my $c = try1(sub { BpRemediate::classify_finding($find, { pkg_write_sets => { 'b01-blocker' => 'packages/b01-blocker/**' } }) });
    if (my $d = died($c)) { fail('AC-11: classify_finding does not die on a dag-stall finding'); diag($d); }
    else {
        ok(ref $c eq 'HASH', 'AC-11: classify_finding returns a disposition hash');
        is($c->{disposition}, 'escalate', "AC-11: a fully-resolvable dag-stall finding still escalates, not 'auto'");
        is($c->{reason}, 'scheduling_state', "AC-11: the escalation reason is 'scheduling_state'");
    }
}

# ---- AC-12: plan() given the same dag-stall-shaped finding ------------------
{
    my $queue = try1(sub { BpRemediate::queue_new(mk_ctx()) });
    my $ctx = mk_ctx(pkg_write_sets => { 'b01-blocker' => 'packages/b01-blocker/**' });
    my $find = mk_dag_stall_finding();
    my $verdict = { schema => 'conformance-verdict/1', generated_at => $ISO, outcome => 'fail', findings => [$find] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-12: plan() does not die on a dag-stall finding'); diag($d); }
    else {
        is(scalar(@{ $plan->{author} || [] }), 0, 'AC-12: author is empty for a dag-stall finding');
        my @entries = @{ ($plan->{queue} || {})->{entries} || [] };
        my @dag_entries = grep { ref $_ eq 'HASH' && ref $_->{finding} eq 'HASH' && ($_->{finding}{kind} // '') eq 'dag-stall' } @entries;
        is(scalar(@dag_entries), 1, 'AC-12: the queue gains exactly one dag-stall entry (persisted, not dropped)');
        if (@dag_entries) {
            is($dag_entries[0]->{state}, 'escalated', "AC-12: the persisted dag-stall entry's state is 'escalated'");
            is($dag_entries[0]->{escalation_reason}, 'scheduling_state', "AC-12: the persisted entry's escalation_reason is 'scheduling_state'");
            is($dag_entries[0]->{no_package}, 1, 'AC-12: the persisted entry carries no_package == 1');
        }
    }
}

# ---- AC-13: no malformed criterion is reachable -----------------------------
{
    my $bpdir = "$ROOT/dc4-ac13"; make_path("$bpdir/packages");
    mk_runs_verdict($bpdir);
    my $entry = mk_entry(id => 'remediation-dc4-ac13-r1', action => 'remediate-conformance',
        finding => mk_finding(remedy => { action => 'remediate-conformance', package => 'b03', means => 'libX' }),
        mandated_means => ['libX']);
    my $path = try1(sub { BpRemediate::author_ledger($bpdir, $entry, mk_ctx()) });
    if (my $d = died($path)) { fail('AC-13: author_ledger writes normally for a fully-valid remediate-conformance entry'); diag($d); }
    else {
        my $txt = slurp($path) // '';
        unlike($txt, qr/the mandated means the mandated means/,
               "AC-13: rendered ## Done criteria never doubles 'the mandated means'");
        unlike($txt, qr/\[the mandated means\]/,
               'AC-13: rendered ## Done criteria never contains an unfilled [the mandated means] placeholder');
        like($txt, qr/\[libX\]/, 'AC-13: rendered ## Done criteria carries the actual mandated means, filled in');
    }
}

# ===========================================================================
# DC5 — the exact 2026-08-11 conditions, end to end (AC-14)
# ===========================================================================

{
    my $bpdir = "$ROOT/dc5-ac14"; make_path("$bpdir/packages", "$bpdir/runs");
    my $queue = try1(sub { BpRemediate::queue_new(mk_ctx()) });
    my $ctx = mk_ctx(pkg_write_sets => { 'b01-blocker' => 'packages/b01-blocker/**' });
    my $find = mk_dag_stall_finding();
    my $verdict = { schema => 'conformance-verdict/1', generated_at => $ISO, outcome => 'fail', findings => [$find] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-14: plan() does not die on the 2026-08-11 replica'); diag($d); }
    else {
        is(scalar(@{ $plan->{author} || [] }), 0, 'AC-14: the 2026-08-11 replica produces zero authored packages');
        for my $e (@{ $plan->{author} || [] }) {
            BpRemediate::author_ledger($bpdir, $e, $ctx);
        }
        opendir(my $dh, "$bpdir/packages") or die "opendir: $!";
        my @md = grep { /\.md$/ } readdir($dh);
        closedir $dh;
        is(scalar(@md), 0, 'AC-14: no ledger file exists under packages/ after the 2026-08-11 replica');
    }
}

# ===========================================================================
# §2.5 required companion: escalated NEW findings are persisted (AC-15)
# ===========================================================================

for my $case (
    { label => 'means_missing (call site :887)',
      finding => mk_finding(remedy => { action => 'remediate-conformance', package => 'b03' }, evidence => { files => ['x'] }) },
    { label => 'unscopable (call site :896)',
      finding => mk_finding(kind => 'eol_runtime', subject => 'unmatched', evidence => {},
                             remedy => { action => 'bump_runtime', runtime => 'node', to => '20' }) },
) {
    my $queue = try1(sub { BpRemediate::queue_new(mk_ctx()) });
    my $ctx = mk_ctx();
    my $verdict = { schema => 'conformance-verdict/1', generated_at => $ISO, outcome => 'fail', findings => [ $case->{finding} ] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail("AC-15 ($case->{label}): plan() does not die"); diag($d); next; }
    my @entries = @{ ($plan->{queue} || {})->{entries} || [] };
    is(scalar(@entries), 1, "AC-15 ($case->{label}): the escalated new finding leaves exactly one persisted entry in queue.entries");
    if (@entries) {
        is($entries[0]->{state}, 'escalated', "AC-15 ($case->{label}): the persisted entry's state is 'escalated'");
        is($entries[0]->{no_package}, 1, "AC-15 ($case->{label}): the persisted entry carries no_package == 1");
    }
}

done_testing();
