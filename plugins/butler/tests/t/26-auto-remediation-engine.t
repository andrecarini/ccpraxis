#!/usr/bin/env perl
# 26-auto-remediation-engine.t — b07-auto-remediation-engine
#
# Oracle for the auto-remediation engine, written from
# specs/08-auto-remediation-engine-spec.md (856 lines, AC-1..AC-37).
#
# TDD-RED BY DESIGN: plugins/butler/scripts/bp-remediate.pl does not exist yet, and
# bp-orchestrator.pl has not been wired for b07 (no remediation_merge/remediation_step
# seams, no verify_ready conjunct, no conformance_registry remediation exclusion, no
# remediation_rounds/remediation_cap tunables). Every AC below must FAIL for the right
# reason — a missing BpRemediate:: function or a genuine assertion failure — and must
# NEVER pass vacuously. Calls into not-yet-existing code go through try1() so a missing
# sub fails ITS OWN test with a diag instead of aborting the whole file.
#
# Strategy: pure/impure BpRemediate:: functions (finding_key, finding_signature,
# classify_finding, write_set_for, plan, merge_queue, author_ledger, read_queue,
# write_queue, rotate_verdict, remediation_outstanding, verify_ready) are exercised
# DIRECTLY — this is where nearly all of b07's decision logic lives, and it is fully
# testable without any orchestrator wiring. A handful of ACs are inherently about
# orchestrator-level WIRING (both verdict-ingestion call sites, the gate re-firing,
# the conformance_registry exclusion) and are exercised through BpOrch::run (the
# run_once/tryrun seam already used by 10-judges.t and 24-conformance-gate.t) or
# directly against the real (unmodified) BpOrch::ready_packages / conformance_registry
# functions fed hand-built %meta/%status maps — so a wiring bug (e.g. hooking only one
# ingestion site, or forgetting the remediation exclusion) is caught for real.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $BPR_OK = eval { require "$Bin/../../scripts/bp-remediate.pl"; 1 };
my $BPR_ERR = $@;
require "$Bin/../../scripts/bp-judge.pl";
require "$Bin/../../scripts/bp-orchestrator.pl";
diag("bp-remediate.pl did not load (expected during TDD-RED): $BPR_ERR") unless $BPR_OK;

my $J = JSON::PP->new->canonical;

# ---------------------------------------------------------------------------
# guards (copied idiom: 24-conformance-gate.t:28-45)
# ---------------------------------------------------------------------------
sub try1 {
    my ($code) = @_;
    my $r = eval { $code->() };
    return { _died => "$@" } if $@;
    return $r;
}
sub died { my $r = shift; return (ref $r eq 'HASH' && exists $r->{_died}) ? $r->{_died} : undef }

sub field_is {
    my ($got, $key, $want, $name) = @_;
    if (my $d = died($got)) { fail($name); diag("died: $d"); return }
    is(ref $got eq 'HASH' ? $got->{$key} : undef, $want, $name);
}

sub slurp { local $/; open my $f, '<', shift or return ''; <$f> }
sub jget  { my $p = shift; my $t = slurp($p); return undef unless length $t; return eval { JSON::PP->new->decode($t) } }
sub ls_json {
    my ($dir) = @_;
    # NOTE: always return a named array, never a bare `()`/map result — `return ()`
    # in scalar context yields undef (not 0), which would break every "expect zero
    # files" assertion regardless of implementation correctness.
    my @out;
    return @out unless -d $dir;
    if (opendir my $h, $dir) {
        my @f = sort grep { /\.json$/ } readdir $h;
        closedir $h;
        @out = map { "$dir/$_" } @f;
    }
    return @out;
}
sub find_tmp_files {
    my ($root) = @_;
    return () unless -d $root;
    require File::Find;
    my @hits;
    File::Find::find(sub { push @hits, $File::Find::name if /\.tmp/ }, $root);
    return @hits;
}

my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = 1_800_000_000;
my $ISO  = BpOrch::_iso($NOW);
my $bpn  = 0;

sub write_creds {
    my ($p) = @_;
    open my $f, '>:raw', $p or die;
    print $f $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 5 * 3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } });
    close $f;
}

# pkgs = [ { name, deps, status, write_set } ]
sub mk_bp {
    my ($pkgs) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    make_path("$dir/packages", "$dir/runs");
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Objective\n\nTest fixture.\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->{name} | d | " . ($_->{deps} // '—') . " | sonnet | $_->{status} |\n" for @$pkgs;
    close $b;
    for my $p (@$pkgs) {
        open my $l, '>', "$dir/packages/$p->{name}.md" or die;
        print $l "---\npackage: $p->{name}\nblueprint: T$bpn\nstatus: $p->{status}\n"
               . "write_set: " . ($p->{write_set} // 'src/') . "\ntest_paths: t/\n"
               . "last_updated: 2026-07-25T00:00:00Z\n---\n# $p->{name}\n\n## Next action\n\ngo\n";
        close $l;
    }
    write_creds("$dir/creds.json");
    return $dir;
}

sub base_tun {
    my %o = @_;
    return { ceil5 => 85, ceil7 => 90, drain => 600, max_par => 2, cap => 5, flat => 600,
             watch_tick => 0, keeper_int => 600, keeper_bo => 120, thresh_min => 60,
             jit_lo => 0, jit_hi => 0, tele_retry => 3, usage_fail => 60,
             busy_path => "$ROOT/busy.$bpn", harvest => 'audit', resolve_cap => 1,
             corr_cap => 1, judge_to => 1800, conformance_spawn_cap => 2, %o };
}

my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });

# one watch tick; returns what the injected seams captured
sub run_once {
    my ($dir, %o) = @_;
    my (@launched, @spawned, @builds);
    my $ok = eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            tunables  => ($o{tunables} || base_tun(%{ $o{tun} || {} })),
            once => 1, now => ($o{now} || sub { $NOW }), sleep => sub {},
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            launch    => sub { push @launched, $_[0]; 0 },
            spawn_judge => ($o{spawn_judge} || sub { push @spawned, $_[0]; 0 }),
            build_runner => (exists $o{build_runner} ? $o{build_runner}
                             : sub { push @builds, $_[0]; { ok => 1, exit => 0, stdout => '', stderr => '' } }),
            ($o{read_verdict} ? (read_verdict => $o{read_verdict}) : ()),
        });
        1;
    };
    return { launched => \@launched, spawned => \@spawned, builds => \@builds,
             err => ($@ ? "$@" : undef), ok => ($ok ? 1 : 0) };
}
sub tryrun      { return run_once(@_) }
sub conf_spawns { my $r = shift; return grep { ($_->{kind} // '') eq 'conformance' } @{ $r->{spawned} } }
sub verdict_of  { my $dir = shift; return jget("$dir/runs/conformance-verdict.json") }

# ---------------------------------------------------------------------------
# b07 fixture helpers (no shared helper module; copied per file — scout §6)
# ---------------------------------------------------------------------------

# a finding record shaped like the ones bp-judge.pl already emits (spec §2.2/§2.3)
sub mk_finding {
    my (%o) = @_;
    my %f = (
        kind    => (exists $o{kind}    ? $o{kind}    : 'conformance-deviation'),
        subject => (exists $o{subject} ? $o{subject} : 'b03'),
        detail  => (exists $o{detail}  ? $o{detail}  : 'means libX not evidenced'),
        evidence=> (exists $o{evidence}? $o{evidence}: { means => 'libX', files => ['src/chat/Bubble.tsx'] }),
        remedy  => (exists $o{remedy}  ? $o{remedy}  : { action => 'remediate-conformance', package => 'b03', means => 'libX' }),
    );
    $f{needs_justification} = $o{needs_justification} if exists $o{needs_justification};
    return \%f;
}

# %ctx per spec §2.10
sub mk_ctx {
    my (%o) = @_;
    return {
        now => $NOW, iso => $ISO, blueprint => 'T',
        rounds => (exists $o{rounds} ? $o{rounds} : 2),
        cap    => (exists $o{cap}    ? $o{cap}    : 6),
        pkg_write_sets => ($o{pkg_write_sets} // {}),
        pkg_status     => ($o{pkg_status} // {}),
        model     => ($o{model} // 'sonnet'),
        max_turns => ($o{max_turns} // 60),
        test_paths=> ($o{test_paths} // 'plugins/butler/tests/'),
        backpack_path => $o{backpack_path},
    };
}

# a full, schema-valid queue ENTRY object per spec §2.1 (every key mandatory)
sub mk_entry {
    my (%o) = @_;
    my $id      = $o{id} // 'remediation-test-r1';
    my $finding = $o{finding} // mk_finding();
    return {
        id            => $id,
        finding_key   => $o{finding_key} // 'test-finding',
        round         => $o{round} // 1,
        max_rounds    => $o{max_rounds} // 2,
        source        => $o{source} // 'conformance',
        action        => $o{action} // ($finding->{remedy}{action} // 'remediate-conformance'),
        disposition   => 'auto',
        state         => $o{state} // 'queued',
        pkg_status    => $o{pkg_status} // 'pending',
        ledger_path   => $o{ledger_path} // "packages/$id.md",
        write_set     => (exists $o{write_set} ? $o{write_set} : 'src/chat/Bubble.tsx'),
        test_paths    => $o{test_paths} // 'plugins/butler/tests/',
        deps          => $o{deps} // [],
        model         => $o{model} // 'sonnet',
        max_turns     => $o{max_turns} // 60,
        mandated_means=> $o{mandated_means} // [],
        signature     => $o{signature} // 'sig-placeholder',
        finding       => $finding,
        created_at    => $o{created_at} // $ISO,
        updated_at    => $o{updated_at} // $ISO,
        history       => $o{history} // [ { round => ($o{round} // 1), at => $ISO, event => 'authored', signature => 'sig-placeholder' } ],
        escalation_reason => $o{escalation_reason},
    };
}

# ===========================================================================
# PART 1 — pure decision core (§2.2, §2.3, §2.4)
# ===========================================================================

# ---- AC-1: finding_key determinism, discriminator, unclassified, format -----
{
    my $f1 = mk_finding(remedy => { action => 'bump_runtime', means => 'X' });
    my $k1a = try1(sub { BpRemediate::finding_key($f1) });
    my $k1b = try1(sub { BpRemediate::finding_key($f1) });
    if (died($k1a) || died($k1b)) { fail('AC-1: finding_key is deterministic across calls'); diag(died($k1a) // died($k1b)); }
    else { is($k1a, $k1b, 'AC-1: finding_key is deterministic across calls'); }

    my $f2 = mk_finding(remedy => { action => 'bump_runtime', means => 'Y' });
    my $k2 = try1(sub { BpRemediate::finding_key($f2) });
    if (died($k1a) || died($k2)) { fail('AC-1: findings differing only in remedy.means yield different keys'); }
    else { isnt($k1a, $k2, 'AC-1: findings differing only in remedy.means yield different keys'); }

    my $unc = try1(sub { BpRemediate::finding_key({}) });
    is($unc, 'unclassified', 'AC-1: a finding with no kind/subject/remedy yields the literal unclassified');

    for my $pair ([$k1a, 'k1'], [$k2, 'k2']) {
        my ($k, $label) = @$pair;
        next if died($k1a) || died($k2);
        like($k, qr/^[a-z0-9][a-z0-9-]*$/, "AC-1: finding_key($label) matches /^[a-z0-9][a-z0-9-]*\$/");
        cmp_ok(length($k // ''), '<=', 64, "AC-1: finding_key($label) is <=64 chars");
    }
}

# ---- AC-2: finding_signature byte-stable / sensitive to detail & evidence ---
{
    my $f1  = { kind => 'conformance-deviation', subject => 'b03', detail => 'd1', evidence => { means => 'libX' } };
    my $f1b = { kind => 'conformance-deviation', subject => 'b03', detail => 'd1', evidence => { means => 'libX' } };
    my $s1a = try1(sub { BpRemediate::finding_signature($f1) });
    my $s1b = try1(sub { BpRemediate::finding_signature($f1b) });
    if (died($s1a) || died($s1b)) { fail('AC-2: finding_signature is byte-stable across equal-but-distinct hashrefs'); diag(died($s1a) // died($s1b)); }
    else { is($s1a, $s1b, 'AC-2: finding_signature is byte-stable across equal-but-distinct hashrefs'); }

    my $f2 = { kind => 'conformance-deviation', subject => 'b03', detail => 'd2', evidence => { means => 'libX' } };
    my $s2 = try1(sub { BpRemediate::finding_signature($f2) });
    isnt($s1a, $s2, 'AC-2: finding_signature differs when detail differs, kind/subject equal') unless died($s1a) || died($s2);

    my $f3 = { kind => 'conformance-deviation', subject => 'b03', detail => 'd1', evidence => { means => 'libY' } };
    my $s3 = try1(sub { BpRemediate::finding_signature($f3) });
    isnt($s1a, $s3, 'AC-2: finding_signature differs when evidence differs, kind/subject equal') unless died($s1a) || died($s3);
}

# ---- AC-3: classify_finding reproduces the §2.3 dispatch table row for row --
{
    my $ctx_bp = mk_ctx(backpack_path => 'backpack.json');
    my $ctx    = mk_ctx();

    field_is(try1(sub { BpRemediate::classify_finding(mk_finding(remedy => { action => 'declare_backpack', runtime => 'node' }), $ctx_bp) }),
             'disposition', 'auto', 'AC-3: declare_backpack with a resolvable backpack_path => auto');
    field_is(try1(sub { BpRemediate::classify_finding(mk_finding(remedy => { action => 'create_lockfile', ecosystem => 'npm' }, evidence => {}), $ctx) }),
             'disposition', 'auto', 'AC-3: create_lockfile(npm, known ecosystem) => auto');
    field_is(try1(sub { BpRemediate::classify_finding(mk_finding(remedy => { action => 'commit_lockfile', file => 'package-lock.json' }), $ctx) }),
             'disposition', 'auto', 'AC-3: commit_lockfile(with file) => auto');
    field_is(try1(sub { BpRemediate::classify_finding(mk_finding(remedy => { action => 'remediate-conformance', package => 'b03', means => 'libX' },
                        evidence => { files => ['src/chat/Bubble.tsx'] }), $ctx) }),
             'disposition', 'auto', 'AC-3: remediate-conformance with a resolvable write_set => auto');

    my $rev = try1(sub { BpRemediate::classify_finding(mk_finding(remedy => { action => 'justify', subject => 'left-pad' }), $ctx) });
    field_is($rev, 'disposition', 'review', 'AC-3: justify => review');

    my $none = try1(sub { BpRemediate::classify_finding(mk_finding(remedy => { action => 'none' }), $ctx) });
    field_is($none, 'disposition', 'escalate', 'AC-3: none => escalate');
    field_is($none, 'reason', 'unfixable', 'AC-3: none => reason unfixable');

    my $abs = try1(sub { BpRemediate::classify_finding(mk_finding(remedy => undef), $ctx) });
    field_is($abs, 'disposition', 'escalate', 'AC-3: remedy absent => escalate');
    field_is($abs, 'reason', 'unfixable', 'AC-3: remedy absent => reason unfixable');

    my $str = try1(sub { BpRemediate::classify_finding(mk_finding(remedy => 'not-a-hash'), $ctx) });
    field_is($str, 'disposition', 'escalate', 'AC-3: remedy a plain string => escalate');
    field_is($str, 'reason', 'unfixable', 'AC-3: remedy a plain string => reason unfixable');

    my $wat = try1(sub { BpRemediate::classify_finding(mk_finding(remedy => { action => 'wat' }), $ctx) });
    field_is($wat, 'disposition', 'escalate', 'AC-3: an unrecognized action => escalate');
    field_is($wat, 'reason', 'unfixable', 'AC-3: an unrecognized action => reason unfixable (fail-closed, D4)');
}

# ---- AC-4: bump_runtime auto iff remedy.to is present and non-empty --------
{
    my $ctx = mk_ctx();
    my $ok = try1(sub { BpRemediate::classify_finding(mk_finding(remedy => { action => 'bump_runtime', runtime => 'node', from => '16', to => '20', file => '.devcontainer/Containerfile' }), $ctx) });
    field_is($ok, 'disposition', 'auto', 'AC-4: bump_runtime with a present, non-empty to => auto');

    for my $case ([ 'to absent', { action => 'bump_runtime', runtime => 'node', from => '16' } ],
                  [ 'to empty',  { action => 'bump_runtime', runtime => 'node', from => '16', to => '' } ],
                  [ 'to undef',  { action => 'bump_runtime', runtime => 'node', from => '16', to => undef } ]) {
        my ($label, $remedy) = @$case;
        my $r = try1(sub { BpRemediate::classify_finding(mk_finding(remedy => $remedy), $ctx) });
        field_is($r, 'disposition', 'escalate', "AC-4: bump_runtime with $label => escalate");
        field_is($r, 'reason', 'ambiguous', "AC-4: bump_runtime with $label => reason ambiguous (SYN-6)");
    }
}

# ---- AC-5: create_lockfile ecosystem lookup; unknown ecosystem escalates ----
{
    my $ctx = mk_ctx();
    my $f_npm = mk_finding(remedy => { action => 'create_lockfile', ecosystem => 'npm' }, evidence => {});
    my $ws = try1(sub { BpRemediate::write_set_for($f_npm, $ctx) });
    is($ws, 'package-lock.json', 'AC-5: create_lockfile(npm) with no evidence.files resolves to package-lock.json')
        or diag('got: ' . (died($ws) // ($ws // 'undef')));
    field_is(try1(sub { BpRemediate::classify_finding($f_npm, $ctx) }), 'disposition', 'auto', 'AC-5: create_lockfile(npm) => auto');

    my $f_bad = mk_finding(remedy => { action => 'create_lockfile', ecosystem => 'cobol-cpan' }, evidence => {});
    my $bad = try1(sub { BpRemediate::classify_finding($f_bad, $ctx) });
    field_is($bad, 'disposition', 'escalate', 'AC-5: create_lockfile with an ecosystem outside the §2.4 table => escalate');
    field_is($bad, 'reason', 'ambiguous', 'AC-5: out-of-table ecosystem => reason ambiguous');
}

# ---- AC-6: write_set_for ladder order + never empty/whitespace/padded ------
{
    my $ctx = mk_ctx(pkg_write_sets => { b09 => 'src/b09/' });

    my $w1 = try1(sub { BpRemediate::write_set_for(
        mk_finding(remedy => { action => 'remediate-conformance', package => 'b03', means => 'libX' },
                   evidence => { files => ['a.ts', ' ', 'a.ts', 'b.ts'] }), $ctx) });
    is($w1, 'a.ts:b.ts', 'AC-6: rung 1 (evidence.files) wins — deduped, non-empty only, joined with :');

    my $w2 = try1(sub { BpRemediate::write_set_for(mk_finding(remedy => { action => 'commit_lockfile', file => 'package-lock.json' }, evidence => {}), $ctx) });
    is($w2, 'package-lock.json', 'AC-6: rung 2 (action-specific) commit_lockfile uses remedy.file');

    my $w3 = try1(sub { BpRemediate::write_set_for(mk_finding(subject => 'b09', remedy => { action => 'remediate-build' }, evidence => {}), $ctx) });
    is($w3, 'src/b09/', 'AC-6: rung 3 falls back to ctx.pkg_write_sets by subject');

    my $w4 = try1(sub { BpRemediate::write_set_for(mk_finding(subject => 'ghost-pkg', remedy => { action => 'remediate-build' }, evidence => {}), $ctx) });
    ok(!died($w4) && !defined($w4), 'AC-6: nothing resolves => undef (rung 4), never an empty string');
    my $c4 = try1(sub { BpRemediate::classify_finding(mk_finding(subject => 'ghost-pkg', remedy => { action => 'remediate-build' }, evidence => {}), $ctx) });
    field_is($c4, 'disposition', 'escalate', 'AC-6: an unresolved write_set => escalate');
    field_is($c4, 'reason', 'unscopable', 'AC-6: an unresolved write_set => reason unscopable');

    for my $bad ([ 'empty evidence.files array', mk_finding(remedy => { action => 'remediate-conformance' }, evidence => { files => [] }) ],
                 [ 'whitespace-only evidence.files element', mk_finding(remedy => { action => 'remediate-conformance' }, evidence => { files => ['   '] }) ]) {
        my ($label, $f) = @$bad;
        my $w = try1(sub { BpRemediate::write_set_for($f, $ctx) });
        ok(!died($w) && !defined($w), "AC-6: $label => undef, never empty/whitespace (D2, landmine 1)")
            or diag('got: ' . (died($w) // ($w // 'undef')));
    }
}

# ---- AC-7: plan() scopes an authored entry to exactly the offending files --
{
    my $ctx = mk_ctx();
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    my $finding = mk_finding(kind => 'conformance-deviation', subject => 'b03',
        remedy => { action => 'remediate-conformance', package => 'b03', means => 'libX' },
        evidence => { files => ['src/chat/Bubble.tsx', 'src/chat/List.tsx'] });
    my $verdict = { schema => 'conformance-verdict/1', generated_at => $ISO, outcome => 'fail', findings => [$finding] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-7: plan authors exactly one entry'); diag("died: $d"); }
    else {
        is(scalar @{ $plan->{author} || [] }, 1, 'AC-7: plan authors exactly one entry for the finding');
        my $entry = $plan->{author}[0] || {};
        is($entry->{write_set}, 'src/chat/Bubble.tsx:src/chat/List.tsx',
           'AC-7: entry write_set is exactly the offending files, joined, nothing else');
    }
}

# ---- AC-8: author_ledger writes a ledger_fm-parseable ledger, status pending,
#           with all body headings in template order ------------------------
{
    my $bpdir = "$ROOT/ledger-ac8"; make_path("$bpdir/packages");
    my $finding = mk_finding(kind => 'eol_runtime', subject => 'node', detail => 'node 20 is EOL',
        remedy => { action => 'bump_runtime', runtime => 'node', from => '20', to => '22' }, evidence => {});
    my $entry = mk_entry(id => 'remediation-eol-runtime-node-r1', finding_key => 'eol-runtime-node',
        action => 'bump_runtime', write_set => '.devcontainer/Containerfile', finding => $finding, source => 'deps');
    my $path = try1(sub { BpRemediate::author_ledger($bpdir, $entry, mk_ctx()) });
    if (my $d = died($path)) { fail('AC-8: author_ledger returns a path'); diag("died: $d"); }
    else {
        ok(defined $path && -f $path, 'AC-8: author_ledger writes a file');
        for my $k (qw(package blueprint status model max_turns write_set test_paths mandated_means last_updated)) {
            ok(defined BpOrch::ledger_fm($bpdir, 'remediation-eol-runtime-node-r1', $k), "AC-8: ledger frontmatter carries '$k'");
        }
        is(BpOrch::ledger_fm($bpdir, 'remediation-eol-runtime-node-r1', 'status'), 'pending', 'AC-8: status: pending');
        my $txt = slurp($path);
        my @headings = ('## Scope', '## Done criteria', '## Inputs', '## Pipeline',
                        '## Decisions & attempt log', '## Next action', '## Outputs',
                        '## Escalation (when status: blocked)', '## Dispatch log (auto)');
        for my $h (@headings) { ok(index($txt, $h) >= 0, "AC-8: ledger body contains heading '$h'"); }
        my @idx = map { index($txt, $_) } @headings;
        if (!grep { $_ < 0 } @idx) {
            my @sorted = sort { $a <=> $b } @idx;
            is_deeply(\@idx, \@sorted, 'AC-8: body headings appear in template order');
        } else { fail('AC-8: body headings appear in template order'); }
    }
}

# ---- AC-9: the ## Inputs section carries the finding verbatim --------------
{
    my $bpdir = "$ROOT/ledger-ac9"; make_path("$bpdir/packages");
    my $finding = mk_finding(kind => 'conformance-deviation', subject => 'b03', detail => 'means libX not evidenced',
        evidence => { means => 'libX', files => ['src/chat/Bubble.tsx'] },
        remedy => { action => 'remediate-conformance', package => 'b03', means => 'libX' });
    my $entry = mk_entry(id => 'remediation-b03-conf-r1', finding_key => 'b03-conf',
        action => 'remediate-conformance', write_set => 'src/chat/Bubble.tsx', finding => $finding, mandated_means => ['libX']);
    my $path = try1(sub { BpRemediate::author_ledger($bpdir, $entry, mk_ctx()) });
    if (my $d = died($path)) { fail('AC-9: ledger ## Inputs section round-trips the finding'); diag("died: $d"); }
    else {
        my $txt = slurp($path);
        my ($inputs) = $txt =~ /^##\s+Inputs\s*\n(.*?)(?=\n##\s|\z)/ms;
        ok(defined $inputs, 'AC-9: an ## Inputs section exists');
        $inputs //= '';
        for my $needle ($finding->{kind}, $finding->{subject}, $finding->{detail}) {
            ok(index($inputs, $needle) >= 0, "AC-9: ## Inputs contains '$needle'");
        }
        my ($json_block) = $inputs =~ /```json\s*\n(.*?)\n```/s;
        ok(defined $json_block, 'AC-9: ## Inputs has a fenced json block');
        my $decoded = eval { JSON::PP->new->decode($json_block // '') };
        ok(!$@ && ref $decoded eq 'HASH', 'AC-9: the fenced json block parses to a hashref') or diag("json error: $@");
        is_deeply($decoded, $finding, 'AC-9: the decoded json is eq-deep to the verdict finding, verbatim') if ref $decoded eq 'HASH';
    }
}

# ---- AC-10: mandated_means rendering shape ---------------------------------
{
    my $bpdir = "$ROOT/ledger-ac10"; make_path("$bpdir/packages");
    my $e1 = mk_entry(id => 'remediation-b03-conf-r1', action => 'remediate-conformance', mandated_means => ['libX']);
    my $p1 = try1(sub { BpRemediate::author_ledger($bpdir, $e1, mk_ctx()) });
    if (died($p1)) { fail('AC-10: remediate-conformance ledger is authored'); diag(died($p1)); }
    else {
        my $raw1 = BpOrch::ledger_fm($bpdir, 'remediation-b03-conf-r1', 'mandated_means');
        my $parsed1 = try1(sub { BpJudge::parse_mandated_means($raw1) });
        field_is($parsed1, 'shape', 'flow', 'AC-10: remediate-conformance renders mandated_means as an inline flow list');
        is_deeply(($parsed1 || {})->{means}, ['libX'], 'AC-10: the flow list has exactly the one mandated means') unless died($parsed1);
    }
    my $e2 = mk_entry(id => 'remediation-eol-node-r1', action => 'bump_runtime', mandated_means => []);
    my $p2 = try1(sub { BpRemediate::author_ledger($bpdir, $e2, mk_ctx()) });
    if (died($p2)) { fail('AC-10: bump_runtime ledger is authored'); diag(died($p2)); }
    else {
        my $raw2 = BpOrch::ledger_fm($bpdir, 'remediation-eol-node-r1', 'mandated_means');
        my $parsed2 = try1(sub { BpJudge::parse_mandated_means($raw2) });
        field_is($parsed2, 'shape', 'flow_empty', 'AC-10: every other action renders mandated_means as an empty flow list []');
    }
}

# ---- AC-11: merge_queue superset key set, status fallback, no-overwrite ----
{
    my $ctx = mk_ctx();
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    unless (died($queue)) { push @{ $queue->{entries} }, mk_entry(id => 'remediation-eol-runtime-node-r1', state => 'queued', write_set => '.devcontainer/Containerfile'); }
    my %meta = ( A => { deps => [], write_set => 'src/a/' } );
    my %status = ( A => 'done' );
    my %ledger_status = ( 'remediation-eol-runtime-node-r1' => 'pending' );
    my $r = try1(sub { BpRemediate::merge_queue($queue, \%meta, \%status, \%ledger_status) });
    if (my $d = died($r)) { fail('AC-11: merge_queue merges a queued entry into %meta/%status'); diag($d); }
    else {
        ok(exists $meta{'remediation-eol-runtime-node-r1'}, 'AC-11: entry id merged into %meta');
        my %a_keys = map { $_ => 1 } keys %{ $meta{A} };
        my %r_keys = map { $_ => 1 } keys %{ $meta{'remediation-eol-runtime-node-r1'} || {} };
        ok(!(grep { !$r_keys{$_} } keys %a_keys), "AC-11: merged pkg's %meta key set is a superset of a blueprint pkg's")
            or diag('merged keys: ' . join(',', keys %r_keys) . ' | blueprint keys: ' . join(',', keys %a_keys));
        ok($meta{'remediation-eol-runtime-node-r1'}{remediation}, 'AC-11: merged pkg meta carries remediation=>1');
        is($status{'remediation-eol-runtime-node-r1'}, 'pending', 'AC-11: %status comes from ledger frontmatter when supplied');
    }
    my %meta2 = ( A => { deps => [], write_set => 'ORIGINAL' } );
    my %status2 = ( A => 'done' );
    my $queue2 = { entries => [ mk_entry(id => 'A', state => 'queued') ] };
    my $r2 = try1(sub { BpRemediate::merge_queue($queue2, \%meta2, \%status2, {}) });
    if (my $d = died($r2)) { fail('AC-11: a colliding id already in %meta is not overwritten'); diag($d); }
    else {
        is($meta2{A}{write_set}, 'ORIGINAL', 'AC-11: a colliding id already in %meta is NOT overwritten');
        my @sk = @{ $r2->{skipped} || [] };
        ok((grep { (ref $_ eq 'HASH' ? ($_->{id} // '') : $_) eq 'A' } @sk), 'AC-11: the collision is reported in skipped[]');
    }
    my %meta3 = (); my %status3 = ();
    my $queue3 = { entries => [ mk_entry(id => 'remediation-x-r1', state => 'queued') ] };
    my $r3 = try1(sub { BpRemediate::merge_queue($queue3, \%meta3, \%status3, {}) });
    is($status3{'remediation-x-r1'}, 'pending', 'AC-11: %status falls back to pending when no ledger frontmatter is readable') unless died($r3);
}

# ---- AC-12: empty/whitespace write_set is never merged; escalates unscopable
{
    for my $ws ('', '   ') {
        my $label = $ws eq '' ? 'empty string' : 'whitespace-only';
        my %meta = (); my %status = ();
        my $queue = { entries => [ mk_entry(id => 'remediation-empty-ws-r1', state => 'queued', write_set => $ws) ] };
        my $r = try1(sub { BpRemediate::merge_queue($queue, \%meta, \%status, {}) });
        if (my $d = died($r)) { fail("AC-12: $label write_set is not merged"); diag($d); next; }
        ok(!exists $meta{'remediation-empty-ws-r1'}, "AC-12: $label write_set entry is NOT merged into %meta (landmine 1)");
        my ($sk) = grep { (ref $_ eq 'HASH' ? ($_->{id} // '') : $_) eq 'remediation-empty-ws-r1' } @{ $r->{skipped} || [] };
        ok(defined $sk, "AC-12: $label write_set entry appears in skipped[]");
        is((ref $sk eq 'HASH' ? $sk->{reason} : undef), 'empty_write_set', "AC-12: $label write_set skip reason is empty_write_set") if ref $sk eq 'HASH';
    }
    # plan() itself never authors an entry with an unresolved write_set; it escalates instead.
    my $ctx = mk_ctx();
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    my $finding = mk_finding(subject => 'ghost-pkg', remedy => { action => 'remediate-build' }, evidence => {});
    my $verdict = { schema => 'conformance-verdict/1', generated_at => $ISO, outcome => 'fail', findings => [$finding] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-12: an unscopable finding is escalated, never authored with an empty write_set'); diag($d); }
    else {
        is(scalar @{ $plan->{author} || [] }, 0, 'AC-12: an unscopable finding is never authored');
        my ($esc) = @{ $plan->{escalate} || [] };
        ok(defined $esc, 'AC-12: the unscopable finding is escalated instead');
        is(($esc || {})->{escalation_reason}, 'unscopable', 'AC-12: escalation_reason=unscopable') if $esc;
    }
}

# ===========================================================================
# PART 2 — orchestrator-level wiring (§3.1, §3.4) via real, unmodified
# BpOrch:: functions fed hand-built state (no bp-orchestrator.pl edits needed
# to exercise these — they prove the DATA b07 must produce is consumable)
# ===========================================================================

# ---- AC-13: blueprint.md is never mutated, and at least one remediation
#             package is authored from a conformance FAIL finding ------------
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    my $dag_before = BpOrch::parse_dag(BpOrch::_read_file("$dir/blueprint.md"));
    my $before = slurp("$dir/blueprint.md");
    tryrun($dir, read_verdict => sub { { outcome => 'fail', findings => [ mk_finding() ] } });
    my @ledgers = grep { -f } glob("$dir/packages/remediation-*.md");
    cmp_ok(scalar @ledgers, '>=', 1, 'AC-13: at least one remediation package is authored from a conformance FAIL finding')
        or diag('packages/: ' . join(',', glob("$dir/packages/*.md")));
    is(slurp("$dir/blueprint.md"), $before, 'AC-13: blueprint.md is byte-identical after authoring remediation packages');
    is_deeply(BpOrch::parse_dag(BpOrch::_read_file("$dir/blueprint.md")), $dag_before,
              'AC-13: parse_dag(blueprint.md) returns the same key set as before');
}

# ---- AC-14: the UNMODIFIED ready_packages launches a merged remediation
#             package; deps_met holds for full package ids across rounds ----
{
    my $queue = { entries => [ mk_entry(id => 'remediation-x-r1', state => 'queued', write_set => 'src/x/file.ts', deps => []) ] };
    my %meta = ( A => { deps => [], write_set => 'src/a/' } );
    my %status = ( A => 'done' );
    my $mr = try1(sub { BpRemediate::merge_queue($queue, \%meta, \%status, {}) });
    if (my $d = died($mr)) { fail('AC-14: merge_queue succeeds so ready_packages can see the entry'); diag($d); }
    else {
        my @ready = BpOrch::ready_packages(\%meta, \%status, []);
        ok((grep { $_ eq 'remediation-x-r1' } @ready), 'AC-14: the unmodified ready_packages launches a merged remediation package');
    }
    my %meta2 = (); my %status2 = ('remediation-x-r1' => 'done');
    my $queue2 = { entries => [ mk_entry(id => 'remediation-x-r1', state => 'verified', write_set => 'src/x/file.ts'),
                                mk_entry(id => 'remediation-x-r2', state => 'queued', write_set => 'src/x/file.ts', deps => ['remediation-x-r1'], round => 2) ] };
    my $mr2 = try1(sub { BpRemediate::merge_queue($queue2, \%meta2, \%status2, {}) });
    if (my $d = died($mr2)) { fail('AC-14: round-2 entry merges so deps_met can be exercised'); diag($d); }
    else {
        ok(BpOrch::deps_met($meta2{'remediation-x-r2'}{deps}, \%status2),
           'AC-14: deps_met(round-2 deps=[round-1 FULL id]) is true — full ids, not short ids (landmine 2)');
    }
}

# ---- AC-15: a write-set overlap with a running package simply postpones
#             launch; the entry stays queued, no round consumed, no escalation
{
    my %meta = ( A => { deps => [], write_set => 'src/shared/' },
                 'remediation-x-r1' => { deps => [], write_set => 'src/shared/util.ts', remediation => 1, finding_key => 'x' } );
    my %status = ( A => 'running', 'remediation-x-r1' => 'pending' );
    my @ready = BpOrch::ready_packages(\%meta, \%status, ['A']);
    ok(!(grep { $_ eq 'remediation-x-r1' } @ready),
       'AC-15: a merged entry whose write_set overlaps a running package is not returned by ready_packages');

    my $ctx = mk_ctx();
    my $entry = mk_entry(id => 'remediation-x-r1', finding_key => 'x', state => 'queued', write_set => 'src/shared/util.ts');
    my $queue = { schema => 'remediation-queue/1', rounds_used => 1, rounds_cap => 6, gate_firings => 1,
                  entries => [$entry], escalated => [], notes => [],
                  last_verdict => { generated_at => 't0', outcome => 'fail', finding_keys => ['x'], findings => 1 } };
    my $verdict = { schema => 'conformance-verdict/1', generated_at => 't0', outcome => 'fail', findings => [] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-15: a queued-but-not-yet-launched entry is untouched by plan()'); diag($d); }
    else {
        my $e2 = $plan->{queue}{entries}[0] || {};
        is($e2->{state}, 'queued', 'AC-15: the entry stays queued after a tick with no new findings');
        is($plan->{queue}{rounds_used}, 1, 'AC-15: rounds_used is unchanged while the entry has simply not launched yet');
        is(scalar @{ $plan->{escalate} || [] }, 0, 'AC-15: nothing is escalated while the entry has simply not launched yet');
    }
}

# ---- AC-16: remediation_outstanding ----------------------------------------
{
    my $ctx = mk_ctx();
    my $q_empty = try1(sub { BpRemediate::queue_new($ctx) });
    is(try1(sub { BpRemediate::remediation_outstanding($q_empty) }), 0, 'AC-16: an empty queue => remediation_outstanding=0');
    is(try1(sub { BpRemediate::remediation_outstanding({ entries => [ mk_entry(state => 'queued') ] }) }), 1,
       'AC-16: a queued entry => remediation_outstanding=1');
    is(try1(sub { BpRemediate::remediation_outstanding({ entries => [ mk_entry(state => 'awaiting_verify') ] }) }), 1,
       'AC-16: an awaiting_verify entry => remediation_outstanding=1');
    is(try1(sub { BpRemediate::remediation_outstanding({ entries => [ mk_entry(state => 'verified'), mk_entry(id => 'r2', state => 'escalated') ] }) }), 0,
       'AC-16: all verified/escalated => remediation_outstanding=0');
}

# ---- AC-17: run_complete gains remediation_outstanding and STAYS PURE ------
{
    my $idle = { any_running => 0, outstanding => 0, resume_pending => 0, paused => 0, awaiting_human => 0, conformance_outstanding => 0 };
    is(BpOrch::run_complete({ %$idle, remediation_outstanding => 1 }), 0, 'AC-17: remediation_outstanding=1 => run_complete false');
    is(BpOrch::run_complete({ %$idle, remediation_outstanding => 0 }), 1, 'AC-17: remediation_outstanding=0, everything else idle => run_complete true');
    my $src = slurp("$Bin/../../scripts/bp-orchestrator.pl");
    my ($body) = $src =~ /\nsub\s+run_complete\s*\{(.*?)\n\}/s;
    ok(defined $body, 'AC-17: run_complete body located for the static purity scan');
    if (defined $body) {
        my @io = grep { $body =~ /(?<![\w:>])\Q$_\E\s*[\(\s]/ } qw(open opendir stat readdir unlink rename);
        push @io, '-e' if $body =~ /-e\s/;
        is_deeply(\@io, [], 'AC-17: run_complete body performs NO file I/O (purity, asserted not assumed)') or diag("found: @io");
    } else { fail('AC-17: run_complete body performs NO file I/O'); }
}

# ---- AC-18: the trigger fires at BOTH verdict-ingestion sites (:1862/:1930) -
{
    # (i) the :1862 path — a verdict that appears on a LATER tick
    my $dir1 = mk_bp([ { name => 'A', status => 'done' } ]);
    BpOrch::mark_judge_inflight("$dir1/runs", 'conformance', '_run', $NOW - 10);
    tryrun($dir1, read_verdict => sub { undef });
    tryrun($dir1, read_verdict => sub { { outcome => 'fail', findings => [ mk_finding() ] } });
    ok(-e "$dir1/runs/remediation-queue.json",
       'AC-18(i): the :1862 (later-tick) ingestion path invokes the remediation trigger');

    # (ii) the :1930 path — the verdict is already present at spawn time (same tick)
    my $dir2 = mk_bp([ { name => 'A', status => 'done' } ]);
    tryrun($dir2, read_verdict => sub { { outcome => 'fail', findings => [ mk_finding() ] } });
    ok(-e "$dir2/runs/remediation-queue.json",
       'AC-18(ii): the :1930 (same-tick) ingestion path invokes the remediation trigger');
}

# ---- AC-19: idempotence — two identical ticks => one entry, one ledger,
#             one notice, rounds_used==1 --------------------------------------
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    my $raw = { outcome => 'fail', findings => [ mk_finding() ] };
    tryrun($dir, read_verdict => sub { $raw });
    tryrun($dir, read_verdict => sub { $raw });
    my $q = jget("$dir/runs/remediation-queue.json");
    is(scalar @{ ($q || {})->{entries} || [] }, 1, 'AC-19: two identical-verdict ticks produce exactly one entry')
        or diag('queue file exists: ' . (-e "$dir/runs/remediation-queue.json" ? 'yes' : 'no'));
    my @ledgers = grep { -f } glob("$dir/packages/remediation-*.md");
    is(scalar @ledgers, 1, 'AC-19: exactly one ledger file is authored');
    my @notices = grep { my $o = jget($_); $o && ($o->{subject} // '') eq 'remediation package authored' } ls_json("$dir/runs/notices");
    is(scalar @notices, 1, 'AC-19: exactly one "remediation package authored" notice');
    is(($q || {})->{rounds_used}, 1, 'AC-19: rounds_used == 1');
}

# ---- AC-20: verify-pass path ------------------------------------------------
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    my $entry = mk_entry(id => 'remediation-eol-runtime-node-r1', finding_key => 'eol-runtime-node', state => 'awaiting_verify', action => 'bump_runtime');
    my $queue = { schema => 'remediation-queue/1', generated_at => $ISO, project => 'T', rounds_used => 1, rounds_cap => 6,
                  gate_firings => 1, last_verdict => { generated_at => 'earlier', outcome => 'fail', finding_keys => ['eol-runtime-node'], findings => 1 },
                  entries => [$entry], escalated => [], notes => [] };
    open my $w, '>', "$dir/runs/remediation-queue.json" or die; print $w $J->encode($queue); close $w;
    tryrun($dir, read_verdict => sub { { outcome => 'pass', findings => [] } });
    my $q2 = jget("$dir/runs/remediation-queue.json");
    is((($q2 || {})->{entries} || [])->[0]{state}, 'verified', 'AC-20: entry transitions to verified when its finding_key is gone from a later verdict');
    my @notices = grep { my $o = jget($_); $o && ($o->{subject} // '') eq 'remediation verified' && ($o->{source} // '') eq 'remediation-engine' } ls_json("$dir/runs/notices");
    is(scalar @notices, 1, 'AC-20: exactly one "remediation verified" notice with source=remediation-engine');
    is(try1(sub { BpRemediate::remediation_outstanding($q2 || {}) }), 0, 'AC-20: remediation_outstanding is 0 once verified');
    is(scalar(ls_json("$dir/runs/needs-you")), 0, 'AC-20: zero files under runs/needs-you/');
}

# ---- AC-21: rotate_verdict archives + re-arms b05's gate --------------------
{
    my $bpdir = "$ROOT/rotate1"; my $runs = "$bpdir/runs";
    make_path("$runs/conformance");
    open my $w1, '>', "$runs/conformance-verdict.json" or die; print $w1 '{"a":1}'; close $w1;
    open my $w2, '>', "$runs/conformance/_run.verdict.json" or die; print $w2 '{"b":2}'; close $w2;
    my $queue = { schema => 'remediation-queue/1', gate_firings => 0, rounds_used => 1, rounds_cap => 6, entries => [], escalated => [], notes => [] };
    my $res = try1(sub { BpRemediate::rotate_verdict($runs, $queue, $NOW) });
    if (my $d = died($res)) { fail('AC-21: rotate_verdict moves the verdict files'); diag($d); }
    else {
        ok(!-e "$runs/conformance-verdict.json", 'AC-21: conformance-verdict.json no longer at the old path');
        ok(!-e "$runs/conformance/_run.verdict.json", 'AC-21: _run.verdict.json no longer at the old path');
        ok(scalar(grep { -f } glob("$runs/remediation/round-*/conformance-verdict.json")),
           'AC-21: conformance-verdict.json is readable under runs/remediation/round-<n>/');
        ok(scalar(grep { -f } glob("$runs/remediation/round-*/_run.verdict.json")),
           'AC-21: _run.verdict.json is readable under runs/remediation/round-<n>/');
    }
    is($queue->{gate_firings}, 1, 'AC-21: gate_firings incremented by rotate_verdict');
    my $reg = BpOrch::read_registry($runs);
    is(($reg->{_run} || {})->{conformance_spawns}, 0, 'AC-21: registry _run.conformance_spawns reset to 0');

    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    BpOrch::update_registry_pkg("$dir/runs", '_run', { conformance_spawns => 0 });
    my $r = tryrun($dir, tun => { conformance_spawn_cap => 2 });
    is(scalar(conf_spawns($r)), 1, 'AC-21: once conformance_spawns is reset and no verdict is on disk, the unmodified b05 gate fires again');
}

# ---- AC-22: rounds exhausted -------------------------------------------------
{
    my $ctx = mk_ctx(rounds => 2, cap => 6);
    my $finding_v1 = mk_finding(subject => 'node', kind => 'eol_runtime', detail => 'node 18 is EOL',
        remedy => { action => 'bump_runtime', runtime => 'node', from => '18', to => '20' }, evidence => { files => ['.devcontainer/Containerfile'] });
    my $sig1 = try1(sub { BpRemediate::finding_signature($finding_v1) });
    my $entry1 = mk_entry(id => 'remediation-eol-runtime-node-r1', finding_key => 'eol-runtime-node', round => 1, max_rounds => 2,
        state => 'awaiting_verify', action => 'bump_runtime', signature => $sig1, finding => $finding_v1);
    my $queue = { schema => 'remediation-queue/1', rounds_used => 1, rounds_cap => 6, gate_firings => 1, entries => [$entry1], escalated => [], notes => [],
                  last_verdict => { generated_at => 't0', outcome => 'fail', finding_keys => ['eol-runtime-node'], findings => 1 } };
    my $finding_v2 = { %$finding_v1, detail => 'node 18 is EOL (first re-verify: still unbumped)' };
    my $verdict2 = { schema => 'conformance-verdict/1', generated_at => 't1', outcome => 'fail', findings => [$finding_v2] };
    my $plan2 = try1(sub { BpRemediate::plan($verdict2, $queue, $ctx) });
    if (my $d = died($plan2)) { fail('AC-22: a changed signature opens round 2'); diag($d); }
    else {
        my @entries2 = @{ $plan2->{queue}{entries} || [] };
        is(scalar @entries2, 2, 'AC-22: a changed signature opens round 2 (second entry)');
        my ($r2) = grep { ($_->{round} // 0) == 2 } @entries2;
        ok(defined $r2, 'AC-22: the round-2 entry exists');
        is_deeply(($r2 || {})->{deps}, ['remediation-eol-runtime-node-r1'], 'AC-22: round-2 deps = [round-1 full id]') if $r2;

        my $queue2 = $plan2->{queue};
        for my $e (@{ $queue2->{entries} }) { $e->{state} = 'awaiting_verify' if ($e->{round} // 0) == 2; }
        my $finding_v3 = { %$finding_v1, detail => 'node 18 is EOL (second re-verify: still unbumped)' };
        my $verdict3 = { schema => 'conformance-verdict/1', generated_at => 't2', outcome => 'fail', findings => [$finding_v3] };
        my $plan3 = try1(sub { BpRemediate::plan($verdict3, $queue2, $ctx) });
        if (my $d3 = died($plan3)) { fail('AC-22: rounds exhausted at max_rounds => escalated'); diag($d3); }
        else {
            my @entries3 = @{ $plan3->{queue}{entries} || [] };
            is(scalar @entries3, 2, 'AC-22: exactly 2 entries for this finding_key exist — never 3');
            my ($r2b) = grep { ($_->{round} // 0) == 2 } @entries3;
            is(($r2b || {})->{state}, 'escalated', 'AC-22: the round-2 entry is escalated once max_rounds is reached');
            is(($r2b || {})->{escalation_reason}, 'rounds_exhausted', 'AC-22: escalation_reason=rounds_exhausted');
        }
    }
}

# ---- AC-23: NP-1 (per-finding no-progress) ----------------------------------
{
    my $ctx = mk_ctx(rounds => 2, cap => 6);
    my $finding = mk_finding(subject => 'node', kind => 'eol_runtime', detail => 'node 18 is EOL',
        remedy => { action => 'bump_runtime', runtime => 'node', from => '18', to => '20' }, evidence => { files => ['.devcontainer/Containerfile'] });
    my $sig = try1(sub { BpRemediate::finding_signature($finding) });
    my $entry = mk_entry(id => 'remediation-eol-runtime-node-r1', finding_key => 'eol-runtime-node', round => 1, max_rounds => 2,
        state => 'awaiting_verify', action => 'bump_runtime', signature => $sig, finding => $finding);
    my $queue = { schema => 'remediation-queue/1', rounds_used => 1, rounds_cap => 6, gate_firings => 1, entries => [$entry], escalated => [], notes => [],
                  last_verdict => { generated_at => 't0', outcome => 'fail', finding_keys => ['eol-runtime-node'], findings => 1 } };
    my $verdict = { schema => 'conformance-verdict/1', generated_at => 't1', outcome => 'fail', findings => [ { %$finding } ] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-23: NP-1 escalates immediately with no round-2 entry'); diag($d); }
    else {
        my @entries = @{ $plan->{queue}{entries} || [] };
        is(scalar @entries, 1, 'AC-23: NP-1 creates no round-2 entry despite round(1) < max_rounds(2)');
        is($entries[0]{state}, 'escalated', 'AC-23: the entry escalates immediately on an identical signature');
        is($entries[0]{escalation_reason}, 'no_progress', 'AC-23: escalation_reason=no_progress');
    }
}

# ---- AC-24: global cap -------------------------------------------------------
{
    my $ctx = mk_ctx(cap => 1, rounds => 2);
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    my $f1 = mk_finding(subject => 'pkgA', detail => 'first', remedy => { action => 'remediate-conformance', package => 'pkgA', means => 'libX' }, evidence => { files => ['src/a.ts'] });
    my $f2 = mk_finding(subject => 'pkgB', detail => 'second', remedy => { action => 'remediate-conformance', package => 'pkgB', means => 'libY' }, evidence => { files => ['src/b.ts'] });
    my $verdict = { schema => 'conformance-verdict/1', generated_at => 't0', outcome => 'fail', findings => [$f1, $f2] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-24: global cap authors exactly one entry and escalates the rest'); diag($d); }
    else {
        is(scalar @{ $plan->{author} || [] }, 1, 'AC-24: exactly one entry authored when remediation_cap=1 with two fixable findings');
        is(scalar @{ $plan->{escalate} || [] }, 1, 'AC-24: exactly one finding escalated');
        is(($plan->{escalate}[0] || {})->{escalation_reason}, 'global_cap', 'AC-24: escalation_reason=global_cap') if @{ $plan->{escalate} || [] };
        is($plan->{queue}{rounds_used}, 1, 'AC-24: rounds_used == 1');
    }
}

# ---- AC-25: exactly one blocking decision -----------------------------------
{
    my $runs = "$ROOT/ac25/runs"; make_path($runs);
    my $ctx = mk_ctx();
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    my $f1 = mk_finding(subject => 's1', remedy => { action => 'none' });
    my $f2 = mk_finding(subject => 's2', remedy => { action => 'bump_runtime', runtime => 'node' });
    my $f3 = mk_finding(subject => 's3', remedy => { action => 'remediate-build' }, evidence => {});
    my $verdict = { schema => 'conformance-verdict/1', generated_at => 't0', outcome => 'fail', findings => [$f1, $f2, $f3] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-25: three findings produce three escalations'); diag($d); }
    else {
        is(scalar @{ $plan->{escalate} || [] }, 3, 'AC-25: three findings produce three escalations');
        my $rec = { kind => 'remediation-escalation', package => '_remediation', blueprint => 'T',
                    reason => 'auto-remediation could not close one or more characterized findings',
                    ts => $ISO, manual => 0, question => '3 findings could not be auto-remediated',
                    context => { findings => $plan->{escalate}, rounds_used => $plan->{queue}{rounds_used},
                                 rounds_cap => $ctx->{cap}, queue => 'runs/remediation-queue.json' },
                    created_at => $NOW };
        my $p1 = BpOrch::queue_needs_you($runs, $rec);
        my $p2 = BpOrch::queue_needs_you($runs, $rec);
        is($p1, $p2, 'AC-25: a second call in the same run returns the SAME file (package+kind dedupe, :718-719)');
        my @files = ls_json("$runs/needs-you");
        is(scalar @files, 1, 'AC-25: exactly one needs-you file for three escalated findings');
        my $o = @files ? jget($files[0]) : undef;
        for my $k (qw(kind package blueprint reason ts manual question context created_at)) {
            ok(defined $o && exists $o->{$k}, "AC-25: needs-you record has key '$k'");
        }
        is(($o || {})->{package}, '_remediation', 'AC-25: package == _remediation') if $o;
        is(($o || {})->{kind}, 'remediation-escalation', 'AC-25: kind == remediation-escalation') if $o;
        is(scalar @{ (($o || {})->{context} || {})->{findings} || [] }, 3, 'AC-25: context.findings has 3 entries') if $o;
        is_deeply([ sort @{ $plan->{queue}{escalated} || [] } ], [ sort map { $_->{finding_key} } @{ $plan->{escalate} } ],
                   'AC-25: queue.escalated lists all 3 finding_keys');
    }
}

# ---- AC-26: (i) all auto-fixed => empty needs-you; (ii) justify-only => empty
#             needs-you + one review; (iii) b07 never blocks/parks a ledger --
{
    my $runs = "$ROOT/ac26a/runs"; make_path($runs);
    my $ctx = mk_ctx();
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    my $f = mk_finding(subject => 'pkgA', remedy => { action => 'remediate-conformance', package => 'pkgA', means => 'libX' }, evidence => { files => ['src/a.ts'] });
    my $verdict = { schema => 'conformance-verdict/1', generated_at => 't0', outcome => 'fail', findings => [$f] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    is(scalar @{ (died($plan) ? [] : ($plan->{escalate} || [])) }, 0, 'AC-26(i): an auto-fixable finding produces zero escalations')
        or diag(died($plan));
    is(scalar(ls_json("$runs/needs-you")), 0, 'AC-26(i): runs/needs-you/ is empty when nothing escalates');
}
{
    my $ctx = mk_ctx();
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    my $f = mk_finding(subject => 'left-pad', kind => 'fresh_version', remedy => { action => 'justify' }, evidence => {});
    my $verdict = { schema => 'conformance-verdict/1', generated_at => 't0', outcome => 'fail', findings => [$f] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-26(ii): a justify finding => zero entries, zero escalations, one review'); diag($d); }
    else {
        is(scalar @{ $plan->{author} || [] }, 0, 'AC-26(ii): a justify finding authors zero entries');
        is(scalar @{ $plan->{escalate} || [] }, 0, 'AC-26(ii): a justify finding escalates nothing');
        is(scalar @{ $plan->{reviews} || [] }, 1, 'AC-26(ii): a justify finding produces exactly one review');
    }
}
{
    my $bpdir = "$ROOT/ac26c"; make_path("$bpdir/packages");
    my $any_authored = 0;
    for my $action (qw(bump_runtime declare_backpack create_lockfile commit_lockfile remediate-conformance remediate-build)) {
        (my $id = "remediation-check-$action-r1") =~ s/[^a-z0-9-]/-/g;
        my $entry = mk_entry(id => $id, action => $action);
        my $path = try1(sub { BpRemediate::author_ledger($bpdir, $entry, mk_ctx()) });
        next if died($path);
        $any_authored++;
        unlike(BpOrch::ledger_fm($bpdir, $id, 'status') // '', qr/^(blocked|parked)$/,
               "AC-26(iii): author_ledger never sets status blocked/parked for action=$action");
    }
    ok($any_authored >= 1, 'AC-26(iii): at least one ledger was authored to check status against') or fail('AC-26(iii): b07 never sets blocked/parked');
}

# ---- AC-27: deps BLOCKs end-to-end ------------------------------------------
{
    my $ctx = mk_ctx(backpack_path => 'backpack.json');
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    my @findings = (
        { kind => 'eol_runtime', severity => 'block', subject => 'node', detail => 'node 18 is EOL', evidence => {},
          remedy => { action => 'bump_runtime', runtime => 'node', from => '18', to => '20', file => '.devcontainer/Containerfile' }, needs_justification => 0 },
        { kind => 'undeclared_runtime', severity => 'block', subject => 'dart', detail => 'dart runtime undeclared', evidence => {},
          remedy => { action => 'declare_backpack', runtime => 'dart' }, needs_justification => 0 },
        { kind => 'lockfile_missing', severity => 'block', subject => 'npm', detail => 'package-lock.json missing', evidence => {},
          remedy => { action => 'create_lockfile', ecosystem => 'npm' }, needs_justification => 0 },
        { kind => 'lockfile_uncommitted', severity => 'block', subject => 'npm', detail => 'package-lock.json untracked', evidence => {},
          remedy => { action => 'commit_lockfile', file => 'package-lock.json' }, needs_justification => 0 },
    );
    my $verdict = { schema => 'conformance-verdict/1', generated_at => 't0', outcome => 'fail', findings => \@findings };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-27: all four deps-check BLOCK kinds are authored'); diag($d); }
    else {
        is(scalar @{ $plan->{author} || [] }, 4, 'AC-27: all four deps-check BLOCK kinds are auto-fixable and authored');
        for my $e (@{ $plan->{author} || [] }) {
            is($e->{source}, 'deps', "AC-27: entry for finding_key=$e->{finding_key} has source=deps");
            ok(defined $e->{write_set} && length($e->{write_set}) && $e->{write_set} !~ /^\s*$/,
               "AC-27: entry for finding_key=$e->{finding_key} has a non-empty write_set");
            my $bpdir = "$ROOT/ac27-" . $e->{finding_key}; make_path("$bpdir/packages");
            my $path = try1(sub { BpRemediate::author_ledger($bpdir, $e, $ctx) });
            ok(!died($path) && defined $path && -f $path, "AC-27: a valid ledger is authored for finding_key=$e->{finding_key}");
        }
    }
}

# ---- AC-28: git tolerance ----------------------------------------------------
{
    my $bpdir = "$ROOT/ac28"; make_path("$bpdir/packages");
    my $finding = { kind => 'lockfile_uncommitted', subject => 'npm', detail => 'package-lock.json untracked', evidence => {},
                    remedy => { action => 'commit_lockfile', file => 'package-lock.json' }, needs_justification => 0 };
    my $entry = mk_entry(id => 'remediation-lockfile-uncommitted-npm-r1', finding_key => 'lockfile-uncommitted-npm',
        action => 'commit_lockfile', write_set => 'package-lock.json', finding => $finding, source => 'deps');
    my $path = try1(sub { BpRemediate::author_ledger($bpdir, $entry, mk_ctx()) });
    if (my $d = died($path)) { fail('AC-28: commit_lockfile ledger carries the git-unavailable degradation clause'); diag($d); }
    else {
        my $txt = slurp($path);
        my ($inputs) = $txt =~ /^##\s+Inputs\s*\n(.*?)(?=\n##\s|\z)/ms;
        my ($next)   = $txt =~ /^##\s+Next action\s*\n(.*?)(?=\n##\s|\z)/ms;
        like($inputs // '', qr/git/i, 'AC-28: ## Inputs mentions git availability');
        like($next // '', qr/git/i, 'AC-28: ## Next action mentions git availability');
        like($inputs // '', qr/(unavailable|cannot run|may be unavailable)/i, 'AC-28: ## Inputs states the git-unavailable degradation clause');
    }
    my $src = -r "$Bin/../../scripts/bp-remediate.pl" ? slurp("$Bin/../../scripts/bp-remediate.pl") : '';
    ok(length $src, 'AC-28: bp-remediate.pl is readable for the static exec/system scan');
    unlike($src, qr/\bsystem\s*\(/, 'AC-28: no system() call in bp-remediate.pl');
    unlike($src, qr/\bexec\s*\(/, 'AC-28: no exec() call in bp-remediate.pl');
    unlike($src, qr/`[^`]*`/, 'AC-28: no backticks in bp-remediate.pl');
    unlike($src, qr/\bqx[\s({\/]/, 'AC-28: no qx// in bp-remediate.pl');
    unlike($src, qr/open\s*\(?\s*[^,)]*,?\s*['"]?\s*-\|/, 'AC-28: no piped-open (-|) in bp-remediate.pl');
    unlike($src, qr/\|-\s*['"]/, 'AC-28: no piped-open (|-) in bp-remediate.pl');
}

# ---- AC-29: notice provenance -------------------------------------------------
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    tryrun($dir, read_verdict => sub { { outcome => 'fail', findings => [ mk_finding() ] } });
    my @b05n = grep { my $o = jget($_); $o && ($o->{source} // '') eq 'conformance-gate' } ls_json("$dir/runs/notices");
    cmp_ok(scalar @b05n, '>=', 1, 'AC-29: b05 still writes its own conformance-gate notices in the same run');
    my @b07n = grep { my $o = jget($_); $o && ($o->{source} // '') eq 'remediation-engine' } ls_json("$dir/runs/notices");
    cmp_ok(scalar @b07n, '>=', 1, 'AC-29: b07 writes at least one remediation-engine notice in the same run')
        or diag('total notices: ' . scalar(ls_json("$dir/runs/notices")));
    for my $nf (ls_json("$dir/runs/notices")) {
        my $o = jget($nf); next unless $o;
        is($o->{schema}, 'notice/1', "AC-29: notice $nf has schema=notice/1");
    }
    my $before = -e "$Bin/../../scripts/bp-judge.pl" ? slurp("$Bin/../../scripts/bp-judge.pl") : undef;
    ok(defined $before, 'AC-29: bp-judge.pl exists to compare');
    is(slurp("$Bin/../../scripts/bp-judge.pl"), $before, 'AC-29: bp-judge.pl is byte-identical after the run (outside b07 write set)');
}

# ---- AC-30: review channel ----------------------------------------------------
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    my $f = { kind => 'fresh_version', subject => 'left-pad', detail => 'published 2 days ago', severity => 'block',
              evidence => {}, remedy => { action => 'justify' }, needs_justification => 1 };
    tryrun($dir, read_verdict => sub { { outcome => 'fail', findings => [$f] } });
    my @rev = ls_json("$dir/runs/review");
    is(scalar @rev, 1, 'AC-30: a justify finding writes exactly one review record');
    my $o = @rev ? jget($rev[0]) : undef;
    ok($o && ($o->{schema} // '') eq 'review/1', 'AC-30: the review has schema=review/1');
    ok($o && defined $o->{package} && length $o->{package}, 'AC-30: the review has a non-empty package');
    my $q = jget("$dir/runs/remediation-queue.json");
    ok(defined $q, 'AC-30: the remediation queue is written after ingestion (even with zero entries)');
    is(scalar @{ ($q || {})->{entries} || [] }, 0, 'AC-30: a justify finding produces zero entries');
    is(scalar(ls_json("$dir/runs/needs-you")), 0, 'AC-30: zero decisions (needs-you) for a justify-only finding');
    my $before = verdict_of($dir);
    tryrun($dir, read_verdict => sub { { outcome => 'fail', findings => [$f] } });
    my $after = verdict_of($dir);
    is(($after || {})->{outcome}, ($before || {})->{outcome}, 'AC-30: the verdict outcome is left untouched by remediation (Decision #21)');
}

# ---- AC-31: fail-closed queue -------------------------------------------------
{
    my $qdir = "$ROOT/ac31"; make_path($qdir);
    my %fixtures;
    { open my $w, '>', "$qdir/invalid.json" or die; print $w '{ this is not json'; close $w; }
    $fixtures{'invalid JSON'} = "$qdir/invalid.json";

    my $valid_entry = mk_entry(id => 'x', finding_key => 'x');
    my %missing_ws = %$valid_entry; delete $missing_ws{write_set};

    my @specs = (
        [ 'wrong schema', { schema => 'remediation-queue/0', entries => [ $valid_entry ], rounds_used => 0, rounds_cap => 6, gate_firings => 0, escalated => [], notes => [] } ],
        [ 'entries as hashref', { schema => 'remediation-queue/1', entries => { a => 1 }, rounds_used => 0, rounds_cap => 6, gate_firings => 0, escalated => [], notes => [] } ],
        [ 'entry missing write_set', { schema => 'remediation-queue/1', entries => [ \%missing_ws ], rounds_used => 0, rounds_cap => 6, gate_firings => 0, escalated => [], notes => [] } ],
    );
    for my $spec (@specs) {
        my ($label, $data) = @$spec;
        (my $fname = lc $label) =~ s/[^a-z0-9]+/-/g;
        my $f = "$qdir/$fname.json";
        open my $w, '>', $f or die; print $w $J->encode($data); close $w;
        $fixtures{$label} = $f;
    }

    for my $label (sort keys %fixtures) {
        my $q = try1(sub { BpRemediate::read_queue($fixtures{$label}) });
        if (died($q)) { fail("AC-31: read_queue detects corruption ($label)"); next; }
        ok(ref $q eq 'HASH' && $q->{_corrupt}, "AC-31: read_queue flags corruption for: $label")
            or diag('got: ' . $J->encode(ref $q eq 'HASH' ? $q : {}));
        my $ctx = mk_ctx();
        my $verdict = { schema => 'conformance-verdict/1', generated_at => 't0', outcome => 'fail', findings => [ mk_finding() ] };
        my $plan = try1(sub { BpRemediate::plan($verdict, $q, $ctx) });
        if (my $d = died($plan)) { fail("AC-31: plan handles a corrupt queue fail-closed ($label)"); diag($d); next; }
        is(scalar @{ $plan->{author} || [] }, 0, "AC-31: zero ledgers authored for a corrupt queue ($label)");
        my @notice_subjects = map { $_->{subject} } @{ $plan->{notices} || [] };
        ok((grep { /remediation queue corrupt/i } @notice_subjects), "AC-31: one 'remediation queue corrupt' notice ($label)");
        is(scalar @{ $plan->{escalate} || [] }, 1, "AC-31: exactly one escalation for a corrupt queue ($label)");
        is(($plan->{escalate}[0] || {})->{escalation_reason}, 'queue_corrupt', "AC-31: escalation_reason=queue_corrupt ($label)")
            if @{ $plan->{escalate} || [] };
        is($plan->{queue}{rounds_used}, $plan->{queue}{rounds_cap}, "AC-31: the persisted queue has rounds_used == rounds_cap ($label)");
    }
    my $missing = try1(sub { BpRemediate::read_queue("$qdir/does-not-exist.json") });
    ok(!(ref $missing eq 'HASH' && $missing->{_corrupt}), 'AC-31: a MISSING queue file is NOT flagged corrupt (normal on the first verdict)');
}

# ---- AC-32: recursion refusal ------------------------------------------------
{
    my $ctx = mk_ctx();
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    my $f = mk_finding(subject => 'remediation-foo-r1', remedy => { action => 'remediate-conformance', package => 'remediation-foo-r1', means => 'libX' }, evidence => { files => ['x.ts'] });
    my $verdict = { schema => 'conformance-verdict/1', generated_at => 't0', outcome => 'fail', findings => [$f] };
    my $plan = try1(sub { BpRemediate::plan($verdict, $queue, $ctx) });
    if (my $d = died($plan)) { fail('AC-32: recursion refusal'); diag($d); }
    else {
        is(scalar @{ $plan->{author} || [] }, 0, 'AC-32: a finding whose subject is a remediation package id authors zero entries');
        my @subjects = map { $_->{subject} } @{ $plan->{notices} || [] };
        ok((grep { /remediation recursion refused/i } @subjects), 'AC-32: one "remediation recursion refused" notice (D9)');
    }

    my %meta = ( A => { deps => [], write_set => 'src/a/' },
                 'remediation-foo-r1' => { deps => [], write_set => '.devcontainer/Containerfile', remediation => 1, finding_key => 'foo' } );
    my %status = ( A => 'done', 'remediation-foo-r1' => 'pending' );
    my $bpdir = "$ROOT/ac32bp"; make_path("$bpdir/packages");
    open my $l, '>', "$bpdir/packages/A.md" or die; print $l "---\npackage: A\nstatus: done\nwrite_set: src/a/\nlast_updated: x\n---\n# A\n"; close $l;
    my $cpkgs = BpOrch::conformance_registry($bpdir, \%meta, \%status);
    ok(!exists $cpkgs->{'remediation-foo-r1'}, 'AC-32: conformance_registry omits a package carrying meta.remediation');
    ok(exists $cpkgs->{A}, 'AC-32: a normal blueprint package is still present in conformance_registry');
    my $ready = BpJudge::conformance_ready($cpkgs);
    is($ready->{ready}, 1, 'AC-32: BpJudge::conformance_ready is unaffected by a pending remediation package once excluded');
}

# ---- AC-33: termination under adversity -------------------------------------
{
    my $bpdir33 = "$ROOT/ac33"; my $runs33 = "$bpdir33/runs";
    make_path("$runs33/conformance");
    open my $w1, '>', "$runs33/conformance-verdict.json" or die; print $w1 '{"seed":1}'; close $w1;
    open my $w2, '>', "$runs33/conformance/_run.verdict.json" or die; print $w2 '{"seed":1}'; close $w2;

    my $cap = 3;
    my $ctx33 = mk_ctx(cap => $cap, rounds => 2);
    my $queue33 = try1(sub { BpRemediate::queue_new($ctx33) });
    my $finding33 = mk_finding(subject => 'b03', remedy => { action => 'remediate-conformance', package => 'b03', means => 'libX' }, evidence => { files => ['src/chat/Bubble.tsx'] });
    my $verdict33 = { schema => 'conformance-verdict/1', generated_at => 'tick', outcome => 'fail', findings => [$finding33] };

    my $ticks_run = 0;
    for my $i (1 .. 20) {
        $ticks_run = $i;
        last if died($queue33);
        my $plan33 = try1(sub { BpRemediate::plan($verdict33, $queue33, $ctx33) });
        last if died($plan33);
        $queue33 = $plan33->{queue};
        for my $e (@{ $queue33->{entries} || [] }) { $e->{state} = 'awaiting_verify' if ($e->{state} // '') eq 'queued'; }
        if ($plan33->{rotate}) { try1(sub { BpRemediate::rotate_verdict($runs33, $queue33, $NOW) }); }
        try1(sub { BpRemediate::write_queue("$runs33/remediation-queue.json", $queue33) });
        if (@{ $plan33->{escalate} || [] }) {
            try1(sub { BpOrch::queue_needs_you($runs33, {
                kind => 'remediation-escalation', package => '_remediation', blueprint => 'T',
                reason => 'auto-remediation could not close one or more characterized findings',
                ts => $ISO, manual => 0, question => 'adversarial escalation',
                context => { findings => $plan33->{escalate}, rounds_used => $queue33->{rounds_used}, rounds_cap => $cap, queue => 'runs/remediation-queue.json' },
                created_at => $NOW }) });
        }
    }

    is($ticks_run, 20, 'AC-33: the harness drove all 20 ticks without hanging (loop terminates each tick)');
    my $n_entries = (ref $queue33 eq 'HASH') ? scalar @{ $queue33->{entries} || [] } : 0;
    cmp_ok($n_entries, '>=', 1, 'AC-33: at least one entry was actually authored (the loop did real work, not a vacuous stop)');
    cmp_ok($n_entries, '<=', $cap, 'AC-33: total entries never exceed remediation_cap');
    my $gf = (ref $queue33 eq 'HASH') ? ($queue33->{gate_firings} // 0) : 0;
    cmp_ok($gf, '<=', 1 + $cap, 'AC-33: gate_firings bounded by 1 + remediation_cap');
    my $ru = (ref $queue33 eq 'HASH') ? ($queue33->{rounds_used} // 0) : 0;
    cmp_ok($ru, '<=', $cap, 'AC-33: rounds_used bounded by remediation_cap');
    is(scalar(ls_json("$runs33/needs-you")), 1, 'AC-33: exactly one needs-you file survives 20 ticks of adversity');
    my $rout = try1(sub { BpRemediate::remediation_outstanding($queue33) });
    is($rout, 0, 'AC-33: remediation_outstanding is 0 once every entry has reached a terminal state');
    is(BpOrch::run_complete({ any_running => 0, outstanding => 0, resume_pending => 0, paused => 0, awaiting_human => 0,
                              conformance_outstanding => 0, remediation_outstanding => ($rout || 0) }), 1,
       'AC-33: run_complete finally returns 1');
}

# ---- AC-34: atomicity --------------------------------------------------------
{
    my @tmp = find_tmp_files($ROOT);
    is_deeply(\@tmp, [], 'AC-34: no *.tmp* files remain anywhere under the test tempdir after all scenarios above')
        or diag('found: ' . join(', ', @tmp));

    my $bpdir = "$ROOT/ac34"; my $runs = "$bpdir/runs"; make_path($runs);
    my $ctx = mk_ctx();
    my $queue = try1(sub { BpRemediate::queue_new($ctx) });
    unless (died($queue)) {
        try1(sub { BpRemediate::write_queue("$runs/remediation-queue.json", $queue) });
        $queue->{notes} = ['second write'];
        try1(sub { BpRemediate::write_queue("$runs/remediation-queue.json", $queue) });
    }
    my @qfiles = glob("$runs/remediation-queue*.json");
    ok(scalar(@qfiles) <= 1, 'AC-34: at most one remediation-queue.json after two writes, no accumulation');
    # This assertion is what stops AC-34 passing vacuously: the "no *.tmp*" and
    # "at most one queue file" checks above are both trivially true when nothing
    # was ever written, so the AC must also prove a write actually happened. A
    # missing sub is a FAILURE here, not a silent skip.
    if (my $d = died($queue)) { fail('AC-34: write_queue actually wrote the file'); diag("died: $d") }
    else { cmp_ok(scalar(@qfiles), '>=', 1, 'AC-34: write_queue actually wrote the file') }
}

# ---- AC-35: tunables ---------------------------------------------------------
{
    delete local $ENV{BP_REMEDIATION_ROUNDS};
    delete local $ENV{BP_REMEDIATION_CAP};
    my $base = BpOrch::_tunables_base();
    is($base->{remediation_rounds}, 2, 'AC-35: remediation_rounds defaults to 2 with the env var unset');
    is($base->{remediation_cap}, 6, 'AC-35: remediation_cap defaults to 6 with the env var unset');
}
{
    local $ENV{BP_REMEDIATION_ROUNDS} = '1';
    local $ENV{BP_REMEDIATION_CAP} = '3';
    my $base = BpOrch::_tunables_base();
    is($base->{remediation_rounds}, 1, 'AC-35: BP_REMEDIATION_ROUNDS=1 overrides the default');
    is($base->{remediation_cap}, 3, 'AC-35: BP_REMEDIATION_CAP=3 overrides the default');
}
{
    delete local $ENV{BP_REMEDIATION_ROUNDS};
    delete local $ENV{BP_REMEDIATION_CAP};
    my $runs = "$ROOT/ac35/runs"; make_path($runs);
    open my $w, '>', "$runs/.tunables" or die; print $w $J->encode({ remediation_rounds => 99 }); close $w;
    my $t = BpOrch::_tunables($runs);
    is($t->{remediation_rounds}, 2, 'AC-35: runs/.tunables cannot override remediation_rounds — not on the :979 whitelist (D10)');
}

# ---- AC-36: non-regression ----------------------------------------------------
{
    my $dir = mk_bp([ { name => 'A', status => 'done' } ]);
    ok(!-e "$dir/runs/remediation-queue.json", 'AC-36: fixture genuinely has no remediation queue');
    my $r = tryrun($dir, read_verdict => sub { { outcome => 'pass', findings => [] } });
    is(scalar(conf_spawns($r)), 1, 'AC-36: exactly one conformance spawn, same as pre-b07 behavior');
    my $v = verdict_of($dir) || {};
    is($v->{schema}, 'conformance-verdict/1', 'AC-36: conformance-verdict.json schema unchanged');
    is($v->{outcome}, 'pass', 'AC-36: outcome=pass is preserved with no remediation queue present');
    for my $nf (ls_json("$dir/runs/notices")) {
        my $o = jget($nf); next unless $o;
        is($o->{source} // '', 'conformance-gate', 'AC-36: every notice in a plain b05 run still carries source=conformance-gate');
    }
    is($r->{err}, undef, 'AC-36: the run exits cleanly with no error');
}

# ---- AC-37: doc gates ---------------------------------------------------------
{
    my $op = "$Bin/../../skills/orchestrator-protocol/SKILL.md";
    my $optxt = -r $op ? slurp($op) : '';
    ok(length $optxt, 'AC-37: orchestrator-protocol/SKILL.md is readable');
    like($optxt, qr/^#+.*Auto-remediation/m, 'AC-37: orchestrator-protocol/SKILL.md has an Auto-remediation section heading');
    for my $needle ('runs/remediation-queue.json', 'remediation_outstanding', 'BP_REMEDIATION_ROUNDS', 'BP_REMEDIATION_CAP', '_remediation') {
        like($optxt, qr/\Q$needle\E/, "AC-37: orchestrator-protocol/SKILL.md mentions '$needle'");
    }
    my $rp = "$Bin/../../skills/reporter/SKILL.md";
    my $rptxt = -r $rp ? slurp($rp) : '';
    ok(length $rptxt, 'AC-37: reporter/SKILL.md is readable');
    like($rptxt, qr/^#+.*[Rr]emediation/m, 'AC-37: reporter/SKILL.md has a Remediation section heading');
    for my $needle ('runs/remediation-queue.json', 'runs/notices/', 'runs/review/') {
        like($rptxt, qr/\Q$needle\E/, "AC-37: reporter/SKILL.md mentions '$needle'");
    }
}

done_testing();
