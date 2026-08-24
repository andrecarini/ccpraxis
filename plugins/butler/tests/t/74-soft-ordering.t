#!/usr/bin/env perl
# t/74-soft-ordering.t — immutable oracle for b22-soft-ordering-constraint.
# Tests C1..C9 from specs/b22-soft-ordering-constraint-spec.md §5 against the
# ready-set computation with INJECTED state (%meta/%status/$running passed
# directly). No orchestrator process, no launcher, no container is ever
# spawned — BpOrch is `require`d as a module and its subs called directly.
#
# C10 (t/08, t/11, t/60 stay green) is a validation command, not
# re-implemented here:
#   perl plugins/butler/tests/t/08-orchestrator-scenarios.t
#   perl plugins/butler/tests/t/11-simulation.t
#   perl plugins/butler/tests/t/60-dag-integrity.t
#
# `requires_clean_tree` is read via ledger_fm exactly like b44's `priority`,
# so its value as it lands in %meta is always a RAW STRING (or undef) as read
# from YAML-ish frontmatter text — never a Perl boolean. Positive fixtures
# below therefore use the string 'true', not 1, so an implementation that
# naively require()s a Perl-true value without recognizing the literal text
# still gets exercised correctly, and so that a loose truthiness check on the
# STRING 'false' (which is Perl-true!) is what C9 is actually probing.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use Storable qw(dclone);

my $ORCH_PATH = "$Bin/../../scripts/bp-orchestrator.pl";
my $ORCH_LOADED = do { local $@; eval { require $ORCH_PATH }; !$@ };
ok($ORCH_LOADED, 'setup: bp-orchestrator.pl requires cleanly as a module')
    or diag("require failed: $@");

# ── helpers ──────────────────────────────────────────────────────────────
sub try_ready {
    my ($meta, $status, $running) = @_;
    my @out;
    my $ok = eval { @out = BpOrch::ready_packages($meta, $status, $running); 1 };
    return $ok ? (\@out, undef) : (undef, $@);
}

sub capture_stderr {
    my ($code) = @_;
    my ($efh, $epath) = tempfile('t74-errXXXXXX', TMPDIR => 1);
    close $efh;
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDERR, '>:raw', $epath or do { open STDERR, '>&', $olderr; die "reopen STDERR: $!" };
    my @ret;
    my $ok = eval { @ret = $code->(); 1 };
    my $died = $@;
    open STDERR, '>&', $olderr or die "restore STDERR: $!";
    close $olderr;
    my $captured = do {
        open my $r, '<:raw', $epath or die "read stderr capture: $!";
        local $/; my $x = <$r>; close $r; defined $x ? $x : '';
    };
    unlink $epath;
    return (\@ret, $captured, $ok, $died);
}

# =============================================================================
# C1 — excluded while another package is running; vacuity gate: present when
# nothing is running.
# =============================================================================
{
    my $meta = {
        cons  => { deps => [], write_set => 'p/cons/', requires_clean_tree => 'true' },
        other => { deps => [], write_set => 'p/other/' },
    };
    my $status = { cons => 'pending', other => 'running' };

    my ($busy, $err1) = try_ready($meta, $status, ['other']);
    ok(defined $busy, 'C1: ready_packages callable while another package runs') or diag($err1);
    ok(!(grep { $_ eq 'cons' } @{ $busy // [] }),
        'C1: requires_clean_tree package is EXCLUDED from the ready set while another package runs');

    my $status2 = { cons => 'pending', other => 'pending' };
    my ($idle, $err2) = try_ready($meta, $status2, []);
    ok(defined $idle, 'C1 vacuity: ready_packages callable with nothing running') or diag($err2);
    ok((grep { $_ eq 'cons' } @{ $idle // [] }),
        'C1 vacuity gate: the SAME requires_clean_tree package IS in the ready set when nothing is running');
}

# =============================================================================
# C2 — becomes ready as soon as the running set empties (transition, not just
# two independent snapshots).
# =============================================================================
{
    my $meta = {
        cons  => { deps => [], write_set => 'p/cons/', requires_clean_tree => 'true' },
        busy  => { deps => [], write_set => 'p/busy/' },
    };
    my $status = { cons => 'pending', busy => 'running' };
    my ($r1, $e1) = try_ready($meta, $status, ['busy']);
    ok(defined $r1, 'C2: callable while busy is running') or diag($e1);
    ok(!(grep { $_ eq 'cons' } @{ $r1 // [] }), 'C2: cons blocked while busy still running');

    # busy goes terminal; the running set empties.
    $status->{busy} = 'done';
    my ($r2, $e2) = try_ready($meta, $status, []);
    ok(defined $r2, 'C2: callable once the running set empties') or diag($e2);
    ok((grep { $_ eq 'cons' } @{ $r2 // [] }),
        'C2: cons becomes ready the instant the running set empties');
}

# =============================================================================
# C3 — soft != hard. The conflicting package NEVER runs and NEVER reaches
# done; its status stays 'pending' for the whole assertion. A fix that quietly
# turns this into a DAG edge (cons depends_on other) would make cons wait for
# other to reach 'done' and this would fail.
# =============================================================================
{
    my $meta = {
        cons  => { deps => [], write_set => 'p/cons/', requires_clean_tree => 'true' },
        other => { deps => [], write_set => 'p/other/' },
    };
    my $status = { cons => 'pending', other => 'pending' };   # other NEVER runs
    my ($r, $err) = try_ready($meta, $status, []);            # running set is, and stays, empty
    ok(defined $r, 'C3: ready_packages callable when the conflicting package never runs') or diag($err);
    ok((grep { $_ eq 'cons' } @{ $r // [] }),
        'C3: cons becomes ready even though other never ran and never reached done (soft != hard)');
    is($status->{other}, 'pending', "C3: other's status is untouched (never became 'running' or 'done')");
}

# =============================================================================
# C4 — mutual constraint resolves: nothing running -> exactly one launched,
# chosen by order_ready, deterministic across repeated calls. With that one
# running, the other is not ready. Neither waits forever (goes ready once the
# first reaches a terminal state).
# =============================================================================
{
    my $meta = {
        aaa => { deps => [], write_set => 'p/aaa/', requires_clean_tree => 'true' },
        mmm => { deps => [], write_set => 'p/mmm/', requires_clean_tree => 'true' },
    };
    my $status = { aaa => 'pending', mmm => 'pending' };

    my ($r1, $e1) = try_ready($meta, $status, []);
    ok(defined $r1, 'C4: mutual constraint callable with nothing running') or diag($e1);
    is(scalar(@{ $r1 // [] }), 1, 'C4: exactly ONE of the two mutually-constrained packages is launched');
    is_deeply($r1, ['aaa'], 'C4: order_ready\'s deterministic pick (equal default priority -> alphabetical) is aaa');

    my ($r2) = try_ready($meta, $status, []);
    my ($r3) = try_ready($meta, $status, []);
    is_deeply($r2, $r1, 'C4: repeated call #2 picks the identical package (deterministic)');
    is_deeply($r3, $r1, 'C4: repeated call #3 picks the identical package (deterministic)');

    # aaa now running: mmm must not be ready.
    my $status_running = { aaa => 'running', mmm => 'pending' };
    my ($r4, $e4) = try_ready($meta, $status_running, ['aaa']);
    ok(defined $r4, 'C4: callable with aaa running') or diag($e4);
    ok(!(grep { $_ eq 'mmm' } @{ $r4 // [] }), 'C4: with aaa running, mmm is NOT ready');

    # aaa reaches a terminal state, running set empties -> mmm becomes ready. Not a permanent wait.
    my $status_done = { aaa => 'done', mmm => 'pending' };
    my ($r5, $e5) = try_ready($meta, $status_done, []);
    ok(defined $r5, 'C4: callable once aaa is terminal') or diag($e5);
    ok((grep { $_ eq 'mmm' } @{ $r5 // [] }), 'C4: mmm becomes ready once aaa goes terminal (neither waits forever)');
}

# =============================================================================
# C5 — invisible to parse_dag. parse_dag returns a graph IDENTICAL to the one
# it returns with no package declaring the field, asserted by deep equality
# of the returned structure (not a count). requires_clean_tree lives in
# ledger frontmatter, never in the blueprint.md table, so this is asserted
# two ways: (a) parse_dag's output shape for a fixed table matches a hardcoded
# expectation with no extra keys/columns, and (b) two on-disk blueprints whose
# tables are byte-identical but whose PACKAGE LEDGERS differ (one package
# additionally declares requires_clean_tree) still parse to identical DAGs.
# =============================================================================
{
    my $table = <<'MD';
# T

## Package status

| pkg | deliverable | depends_on | model | status |
|--|--|--|--|--|
| a | d | — | sonnet | pending |
| b | d | a | sonnet | pending |
MD
    my $dag = eval { BpOrch::parse_dag($table) };
    my $err = $@;
    ok(!$err, 'C5: parse_dag callable') or diag($err);
    is_deeply($dag, { a => [], b => ['a'] },
        'C5: parse_dag returns exactly the depends_on-derived graph, no extra requires_clean_tree keys/shape change');
}
{
    my $ROOT = tempdir(CLEANUP => 1);
    my $table = <<'MD';
# T

## Package status

| pkg | deliverable | depends_on | model | status |
|--|--|--|--|--|
| a | d | — | sonnet | pending |
| b | d | a | sonnet | pending |
MD
    sub _mk_bpdir {
        my ($root, $name, $table, $pkgs) = @_;   # $pkgs = { pkgname => extra_frontmatter_lines_or_'' }
        my $dir = "$root/$name";
        mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
        open my $b, '>', "$dir/blueprint.md" or die; print $b $table; close $b;
        for my $pkg (keys %$pkgs) {
            open my $l, '>', "$dir/packages/$pkg.md" or die;
            print $l "---\npackage: $pkg\nblueprint: T\nstatus: pending\nwrite_set: p/$pkg/\ntest_paths: p/$pkg/\n";
            print $l $pkgs->{$pkg} if length $pkgs->{$pkg};
            print $l "last_updated: 2026-06-24T00:00:00Z\n---\n# $pkg\n\n## Next action\n\ngo\n";
            close $l;
        }
        return $dir;
    }
    my $dirA = _mk_bpdir($ROOT, 'noField', $table, { a => '', b => '' });
    my $dirB = _mk_bpdir($ROOT, 'withField', $table, { a => "requires_clean_tree: true\n", b => '' });

    open my $fa, '<', "$dirA/blueprint.md" or die; local $/; my $mdA = <$fa>; close $fa;
    open my $fb, '<', "$dirB/blueprint.md" or die; my $mdB = <$fb>; close $fb;

    my $dagA = eval { BpOrch::parse_dag($mdA) };
    my $dagB = eval { BpOrch::parse_dag($mdB) };
    ok(!$@, 'C5: parse_dag callable over both on-disk blueprints') or diag($@);
    is_deeply($dagA, $dagB,
        'C5: parse_dag returns an IDENTICAL graph whether or not a sibling package ledger declares requires_clean_tree');
}

# =============================================================================
# C6 — drain rule: with a blocked requires_clean_tree package, NO new package
# is launched even though others are otherwise ready and slots are free.
# Vacuity gate: with nothing blocked, those same others ARE launched.
# =============================================================================
{
    my $meta = {
        cons   => { deps => [], write_set => 'p/cons/', requires_clean_tree => 'true' },
        other1 => { deps => [], write_set => 'p/o1/' },
        other2 => { deps => [], write_set => 'p/o2/' },
        busy   => { deps => [], write_set => 'p/busy/' },
    };
    my $status = { cons => 'pending', other1 => 'pending', other2 => 'pending', busy => 'running' };
    my ($r, $err) = try_ready($meta, $status, ['busy']);
    ok(defined $r, 'C6: ready_packages callable with a blocked constrained package') or diag($err);
    is_deeply([sort @{ $r // ['SENTINEL-NOT-CALLED'] }], [],
        'C6: no NEW package launched (drain/quiesce) while cons is otherwise-ready-but-blocked-by-running');

    # Vacuity gate: remove the constraint (cons absent from the pending pool
    # entirely) and confirm other1/other2 ARE launched under the identical
    # running-set shape. A fix that always returns [] would pass the negative
    # assertion above and fail here.
    my $meta_nc = {
        other1 => { deps => [], write_set => 'p/o1/' },
        other2 => { deps => [], write_set => 'p/o2/' },
        busy   => { deps => [], write_set => 'p/busy/' },
    };
    my $status_nc = { other1 => 'pending', other2 => 'pending', busy => 'running' };
    my ($r2, $err2) = try_ready($meta_nc, $status_nc, ['busy']);
    ok(defined $r2, 'C6 vacuity: callable with no constrained package blocked') or diag($err2);
    is_deeply([sort @{ $r2 // [] }], ['other1', 'other2'],
        'C6 vacuity gate: with nothing constrained blocked, other1/other2 ARE launched (proves C6 is not just "always return []")');
}

# =============================================================================
# C7 — quiescing is a suppression of launches, not a park: no package's
# status changes, nothing is written to runs/.paused, no decision is queued.
# Asserted here as: ready_packages neither mutates $status nor touches any
# filesystem path (a $runs tempdir never passed to it stays empty), during
# the very drain scenario exercised in C6.
# =============================================================================
{
    my $meta = {
        cons  => { deps => [], write_set => 'p/cons/', requires_clean_tree => 'true' },
        other => { deps => [], write_set => 'p/other/' },
        busy  => { deps => [], write_set => 'p/busy/' },
    };
    my $status = { cons => 'pending', other => 'pending', busy => 'running' };
    my $status_before = dclone($status);

    my $runs_dir = tempdir(CLEANUP => 1);
    mkdir "$runs_dir/escalations";

    my ($r, $err) = try_ready($meta, $status, ['busy']);
    ok(defined $r, 'C7: ready_packages callable during a drain') or diag($err);

    is_deeply($status, $status_before, 'C7: no package\'s status was mutated by the quiesce (hash unchanged after the call)');
    ok(!-e "$runs_dir/.paused", 'C7: no runs/.paused was written (ready_packages takes no runs path -- it cannot write one)');
    opendir(my $dh, "$runs_dir/escalations") or die $!;
    my @entries = grep { !/^\.\.?$/ } readdir $dh;
    closedir $dh;
    is_deeply(\@entries, [], 'C7: no decision file was queued in escalations/');
}

# =============================================================================
# C8 — multiple blocked requires_clean_tree packages are admitted ONE AT A
# TIME, in order_ready order (priority ascending, then name).
# =============================================================================
{
    my $meta = {
        c_z => { deps => [], write_set => 'p/cz/', requires_clean_tree => 'true', priority => 30 },
        c_a => { deps => [], write_set => 'p/ca/', requires_clean_tree => 'true', priority => 10 },
        c_m => { deps => [], write_set => 'p/cm/', requires_clean_tree => 'true', priority => 20 },
    };
    my $status = { c_z => 'pending', c_a => 'pending', c_m => 'pending' };

    my ($r1, $e1) = try_ready($meta, $status, []);
    ok(defined $r1, 'C8: callable with three mutually-constrained pending packages and nothing running') or diag($e1);
    is_deeply($r1, ['c_a'], 'C8: exactly the lowest-priority constrained package (c_a) is admitted first');

    # c_a now running: neither c_m nor c_z may be admitted (drain).
    my $status2 = { c_z => 'pending', c_a => 'running', c_m => 'pending' };
    my ($r2, $e2) = try_ready($meta, $status2, ['c_a']);
    ok(defined $r2, 'C8: callable with c_a running') or diag($e2);
    is_deeply([sort @{ $r2 // [] }], [], 'C8: with c_a running, neither remaining constrained package is admitted');

    # c_a goes terminal: the NEXT one by order_ready order (c_m, priority 20) is admitted -- not both.
    my $status3 = { c_z => 'pending', c_a => 'done', c_m => 'pending' };
    my ($r3, $e3) = try_ready($meta, $status3, []);
    ok(defined $r3, 'C8: callable once c_a is terminal') or diag($e3);
    is_deeply($r3, ['c_m'], 'C8: the next-in-order constrained package (c_m) is admitted alone, not c_z and not both');
}

# =============================================================================
# C9 — absent / false / malformed all behave exactly as today (not
# constrained), and malformed does not die (mirrors b44's malformed-priority
# handling). With no package declaring the field anywhere, ready_packages is
# byte-for-byte today's exact gate (pending + deps_met + write-set disjoint).
# =============================================================================
{
    # (a) absent: key not present at all.
    my $meta_absent = {
        pkg   => { deps => [], write_set => 'p/pkg/' },   # no requires_clean_tree key
        other => { deps => [], write_set => 'p/other/' },
    };
    my $status_absent = { pkg => 'pending', other => 'running' };
    my ($r_a, $e_a) = try_ready($meta_absent, $status_absent, ['other']);
    ok(defined $r_a, 'C9(absent): callable') or diag($e_a);
    ok((grep { $_ eq 'pkg' } @{ $r_a // [] }),
        "C9(absent): field absent behaves as today -- 'pkg' is ready despite another package running (disjoint write-sets)");

    # (b) the STRING 'false' (as ledger_fm would literally return it) -- Perl-true as a string!
    my $meta_false = {
        pkg   => { deps => [], write_set => 'p/pkg/', requires_clean_tree => 'false' },
        other => { deps => [], write_set => 'p/other/' },
    };
    my $status_false = { pkg => 'pending', other => 'running' };
    my ($r_f, $e_f) = try_ready($meta_false, $status_false, ['other']);
    ok(defined $r_f, 'C9(false): callable') or diag($e_f);
    ok((grep { $_ eq 'pkg' } @{ $r_f // [] }),
        "C9(false): the STRING 'false' is treated as NOT constrained -- 'pkg' is ready despite another package running");

    # (c) malformed: garbage text, treated as absent, must not die.
    for my $bad (qw(sometimes YES 1maybe)) {
        my $meta_bad = {
            pkg   => { deps => [], write_set => 'p/pkg/', requires_clean_tree => $bad },
            other => { deps => [], write_set => 'p/other/' },
        };
        my $status_bad = { pkg => 'pending', other => 'running' };
        my ($ret, $stderr, $ok, $died) = capture_stderr(sub { return try_ready($meta_bad, $status_bad, ['other']) });
        my ($r_b, $e_b) = @{ $ret || [] };
        ok($ok, "C9(malformed '$bad'): does not die") or diag("died: $died");
        ok(defined $r_b, "C9(malformed '$bad'): ready_packages returns (not undef on error)") or diag($e_b);
        ok((grep { $_ eq 'pkg' } @{ $r_b // [] }),
            "C9(malformed '$bad'): treated as absent -- 'pkg' is ready despite another package running");
    }

    # (d) with NO package anywhere declaring the field, ready_packages is
    # byte-for-byte today's gate: pinned expected output for a fixture that
    # exercises pending/deps_met/write-set-disjoint together.
    my $meta_today = {
        hi  => { deps => ['x'], write_set => 'p/hi/sub/' },
        x   => { deps => [],    write_set => 'p/x/' },
        run => { deps => [],    write_set => 'p/hi/' },     # overlaps hi's write-set prefix
        ok2 => { deps => [],    write_set => 'p/ok2/' },
        done_pkg => { deps => [], write_set => 'p/done/' },
    };
    my $status_today = { hi => 'pending', x => 'pending', run => 'running', ok2 => 'pending', done_pkg => 'done' };
    my ($r_today, $e_today) = try_ready($meta_today, $status_today, ['run']);
    ok(defined $r_today, 'C9(today): callable') or diag($e_today);
    is_deeply([sort @{ $r_today // [] }], ['ok2', 'x'],
        'C9(today): with no requires_clean_tree anywhere, the gate is byte-for-byte pending+deps_met+write-set-disjoint (hi excluded by write-set overlap with running run; done_pkg excluded by status)');
}

# =============================================================================
# C11/C12/C13 — MUTUAL EXCLUSION (spec §3, gates G2 and G3).
#
# Added by the coordinator after the first implementation went green on 54/54 and
# STILL did not prevent the incident this package exists for. The original spec
# stated only G1 ("a constrained package is not READY while anything else runs"),
# which guards the START of its run and nothing after. Probing the implementation
# directly showed both holes:
#
#   * empty running set -> ready set was [alpha, beta, e2e], so the orchestrator
#     could launch all three in one round and e2e runs alongside both;
#   * e2e already RUNNING -> ready set was [alpha, beta], so siblings launch and
#     edit the tree UNDERNEATH the running e2e. That case IS DAG-01 exactly:
#     package 05 editing shared code while 07's e2e ran.
#
# "My run needs the tree to compile" is a claim about the whole interval the run
# occupies, not about its starting instant.
# =============================================================================
{
    my %meta = (
        alpha => { deps => [], write_set => 'a/' },
        beta  => { deps => [], write_set => 'b/' },
        e2e   => { deps => [], write_set => 'e/', requires_clean_tree => 'true' },
    );

    # --- C11 (G2): nothing launches under a running constrained package -------
    my ($under, $e1) = try_ready(\%meta,
        { alpha => 'pending', beta => 'pending', e2e => 'running' }, ['e2e']);
    ok(defined $under, 'C11: ready_packages callable with a constrained package running') or diag($e1);
    is_deeply([sort @{ $under // ['UNCALLABLE'] }], [],
        'C11 (G2): with a requires_clean_tree package RUNNING, NO other package is ready -- siblings cannot edit the tree underneath it');

    # Vacuity gate: an UNCONSTRAINED package running must NOT suppress siblings,
    # or an implementation that returns nothing whenever anything runs would pass.
    my %plain = (%meta, e2e => { deps => [], write_set => 'e/' });
    my ($under_plain, $e2) = try_ready(\%plain,
        { alpha => 'pending', beta => 'pending', e2e => 'running' }, ['e2e']);
    ok(defined $under_plain, 'C11 vacuity: callable with an unconstrained package running') or diag($e2);
    is_deeply([sort @{ $under_plain // [] }], ['alpha', 'beta'],
        'C11 vacuity gate: an UNCONSTRAINED running package still lets siblings through -- the suppression is specific to the constraint');

    # --- C12 (G3): a constrained package is admitted ALONE -------------------
    my ($fresh, $e3) = try_ready(\%meta,
        { alpha => 'pending', beta => 'pending', e2e => 'pending' }, []);
    ok(defined $fresh, 'C12: ready_packages callable from an empty running set') or diag($e3);
    is_deeply([sort @{ $fresh // ['UNCALLABLE'] }], ['e2e'],
        'C12 (G3): from an EMPTY running set the constrained package is admitted ALONE -- launching it beside its siblings would violate its own constraint immediately');

    # Vacuity gate: with no constrained package, all three come back together,
    # or an implementation that always returns exactly one package would pass.
    my ($fresh_plain, $e4) = try_ready(\%plain,
        { alpha => 'pending', beta => 'pending', e2e => 'pending' }, []);
    ok(defined $fresh_plain, 'C12 vacuity: callable with no constrained package') or diag($e4);
    is_deeply([sort @{ $fresh_plain // [] }], ['alpha', 'beta', 'e2e'],
        'C12 vacuity gate: with NO requires_clean_tree anywhere, all three are ready together -- the single-admission is specific to the constraint');

    # --- C13: normal parallelism resumes -------------------------------------
    my ($after, $e5) = try_ready(\%meta,
        { alpha => 'pending', beta => 'pending', e2e => 'done' }, []);
    ok(defined $after, 'C13: callable once the constrained package is terminal') or diag($e5);
    is_deeply([sort @{ $after // [] }], ['alpha', 'beta'],
        'C13: once the constrained package is terminal the siblings are ready TOGETHER -- the constraint is an interval, not a permanent serialisation');
}

done_testing();
